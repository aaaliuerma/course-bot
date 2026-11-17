#requires -Version 5.1
<#
  lib.ps1 — 共享底层（被 chaoxing.ps1 / ocs-session.ps1 / login.ps1 / run.ps1 dot-source）

  内容：
    * DPI 感知 + Win32 P/Invoke（Ui / WinFind / SW 三个类）
    * 窗口定位（Get-MainWindow）与 UIA 按钮操作（Find/Invoke/StartBrowser）
    * Show-Win / Click-Point 通用窗口动作
    * Get-LoginStateFromTitle：登录态三态判定（login.ps1 与 run.ps1 共用同一判据）

  注意：本文件必须存成 UTF-8 with BOM（PowerShell 5.1 否则按 GBK 读中文注释会乱码）。
  各脚本以独立进程运行（powershell -File），dot-source 本文件不会造成 Add-Type 类型重复。
#>

# DPI aware：截图坐标与 GetWindowRect 统一为物理像素
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class DpiHelper{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();}'
[void][DpiHelper]::SetProcessDPIAware()

Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class Ui {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x,int y,int cx,int cy,uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

Add-Type @"
using System;using System.Runtime.InteropServices;
public class WinFind {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WRECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct WRECT { public int L,T,R,B; }
  // 关键：必须优先「可见」窗口。Tauri/Electron 常另有一个更大但不可见的幽灵窗，
  // 按面积选会选到它，UIA 读出来就是个空壳（如 'tray_icon_app'）。
  public static IntPtr BestVisible(string pname) {
    IntPtr best = IntPtr.Zero; long ba = 0;
    EnumWindows((h,p) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      try {
        var pr = System.Diagnostics.Process.GetProcessById((int)pid);
        if (pr.ProcessName == pname && IsWindowVisible(h)) {
          WRECT r; GetWindowRect(h, out r);
          long a = (long)(r.R-r.L)*(r.B-r.T);
          if (a > ba) { ba = a; best = h; }
        }
      } catch {} return true; }, IntPtr.Zero);
    return best;
  }
}
"@

Add-Type @"
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class SW {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WR r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x,int y,int cx,int cy,uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct WR { public int L,T,R,B; }

  // 列出所有可见的 chrome/msedge/chromium 窗口，按面积从大到小返回。
  // 不在这里挑「最大」——调用方必须再按 OCS 的 userDataDirs 命令行过滤，
  // 否则用户自己开的 Chrome 窗口更大时，点击/输入（含密码）会落进错误的浏览器。
  // 实测：页面跳转时标题会变空或乱码，Get-Process.MainWindowHandle 甚至会指向
  // 一个 703x32 的辅助窗口，靠标题或 MainWindowHandle 都不可靠，所以只按可见+面积排候选。
  public static List<IntPtr> FindAllBrowsers() {
    var list = new List<KeyValuePair<IntPtr,long>>();
    EnumWindows((h,p) => {
      if (!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      try {
        var pr = System.Diagnostics.Process.GetProcessById((int)pid);
        var pn0 = pr.ProcessName; if (pn0 != "chrome" && pn0 != "msedge" && pn0 != "chromium") return true;
        WR r; GetWindowRect(h, out r);
        long a = (long)(r.R-r.L)*(r.B-r.T);
        list.Add(new KeyValuePair<IntPtr,long>(h, a));
      } catch {} return true; }, IntPtr.Zero);
    list.Sort((x,y) => y.Value.CompareTo(x.Value));
    var res = new List<IntPtr>();
    foreach (var kv in list) res.Add(kv.Key);
    return res;
  }

  public static string TitleOf(IntPtr h) {
    var sb = new StringBuilder(300); GetWindowTextW(h, sb, 300); return sb.ToString();
  }
}
"@

function Get-MainWindow([string]$ProcName) {
    # 优先 Get-Process.MainWindowHandle（Chrome/OCS 的主窗只在这里正确，
    # EnumWindows 读到的是辅助窗）；但 Tauri 应用的 MainWindowHandle 可能是幽灵小窗，
    # 所以尺寸太小就回退到「可见最大窗」。
    $p = Get-Process $ProcName -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
        $r = New-Object Ui+RECT
        [void][Ui]::GetWindowRect($p.MainWindowHandle, [ref]$r)
        if ($r.R - $r.L -gt 300 -and $r.B - $r.T -gt 200) { return $p.MainWindowHandle }
    }
    return [WinFind]::BestVisible($ProcName)
}

# 用 UIA 精确找按钮，返回屏幕中心坐标。比按窗口百分比算稳得多：
# 窗口挪动/缩放都不影响，且不怕多显示器与 DPI 变化。
function Find-UiaButton([IntPtr]$h, [string[]]$Names) {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $all.Count; $i++) {
            $e = $all.Item($i)
            if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
            # 用「包含」而不是「完全等于」：不同版本按钮可能叫「启动」也可能叫「启动服务」，
            # 完全不等于就漏掉了。启动后按钮会变成「停止」，所以按「启动」匹配不会误点。
            $hit = $false
            foreach ($kw in $Names) {
                if ($e.Current.Name -and $e.Current.Name.Contains($kw)) { $hit = $true; break }
            }
            if (-not $hit) { continue }
            $r = $e.Current.BoundingRectangle
            if ($r.Width -gt 4 -and $r.Height -gt 4) {
                return @{
                    x    = [int]($r.X + $r.Width / 2)
                    y    = [int]($r.Y + $r.Height / 2)
                    name = $e.Current.Name
                }
            }
        }
    } catch { }
    return $null
}

# 用 UIA 的 InvokePattern 直接触发按钮，不碰鼠标。
# 好处：不怕窗口被遮挡、不怕坐标漂移、不需要置顶。ZError（Tauri/WebView2）支持。
function Invoke-UiaButton([IntPtr]$h, [string[]]$Names) {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $all.Count; $i++) {
            $e = $all.Item($i)
            if ($e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) { continue }
            # 用「包含」而不是「完全等于」：不同版本按钮可能叫「启动」也可能叫「启动服务」，
            # 完全不等于就漏掉了。启动后按钮会变成「停止」，所以按「启动」匹配不会误点。
            $hit = $false
            foreach ($kw in $Names) {
                if ($e.Current.Name -and $e.Current.Name.Contains($kw)) { $hit = $true; break }
            }
            if (-not $hit) { continue }
            $br = $e.Current.BoundingRectangle
            if ($br.Width -lt 4) { continue }
            try {
                $inv = $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                $inv.Invoke()
                return @{ ok = $true; name = $e.Current.Name }
            } catch {
                return @{ ok = $false; name = $e.Current.Name; reason = $_.Exception.Message }
            }
        }
    } catch { }
    return $null
}

# 用 UIA 按「浏览器名字」定位并触发它的「启动」按钮。
# 3.9.1+ 的 Electron 终于暴露了无障碍树（2.x 是 0 个元素），可以彻底不依赖坐标：
# 找到名字文本的 Y 坐标，再找同一卡片里 Y 最接近的「启动」按钮。
function Invoke-UiaStartBrowser([IntPtr]$h, [string]$Name) {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        $nameY = $null
        $buttons = @()
        for ($i = 0; $i -lt $all.Count; $i++) {
            $e = $all.Item($i)
            $n = $e.Current.Name
            if (-not $n) { continue }
            $r = $e.Current.BoundingRectangle
            $ct = $e.Current.ControlType
            if ($ct -eq [System.Windows.Automation.ControlType]::Text -and $n.Trim() -eq $Name -and $r.Width -gt 0) {
                $nameY = $r.Y
            }
            if ($ct -eq [System.Windows.Automation.ControlType]::Button -and $n -eq '启动' -and $r.Width -gt 0) {
                $buttons += [pscustomobject]@{ el = $e; y = $r.Y }
            }
        }
        if ($null -eq $nameY -or -not $buttons) { return $false }
        $best = $buttons | Sort-Object { [Math]::Abs($_.y - $nameY) } | Select-Object -First 1
        # 差值太大说明匹配到别的卡片了，宁可不点
        if ([Math]::Abs($best.y - $nameY) -gt 80) { return $false }
        $inv = $best.el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $inv.Invoke()
        return $true
    } catch { return $false }
}

function Show-Win([IntPtr]$h, [switch]$TopMost) {
    if ($h -eq [IntPtr]::Zero) { return }
    [void][Ui]::ShowWindow($h, 9)   # RESTORE
    Start-Sleep -Milliseconds 600
    [void][Ui]::SetForegroundWindow($h)
    if ($TopMost) { [void][Ui]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0040) }
    Start-Sleep -Milliseconds 500
}

function Click-Point([int]$x, [int]$y, [string]$Label) {
    [void][Ui]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200
    [Ui]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [Ui]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    Write-Host "  [click] $Label → ($x,$y)" -ForegroundColor DarkGray
}

# ── 登录态三态判定（login.ps1 与 run.ps1 共用，判据只此一份）──
# 只有「标题明确是登录页」才是强信号。首页不含「登录」字样 ≠ 已登录
# （比如中国大学MOOC 未登录时首页标题也很正常），所以其余情况按排除法兜底：
# 标题既不像登录页、又不是浏览器自身/导航页 → 大概率已登录（学习通登录后
# 标题直接是所属院校名称，各校不同、无从枚举）。判不了就返回 unknown 交给截图。
function Get-LoginStateFromTitle([string]$Title, $Plat) {
    $outMark = @('登录', '登陆', 'login', 'sign in', 'signin', '欢迎登录', '扫码登录')
    $hitOut = $outMark | Where-Object { $Title -match [regex]::Escape($_) }
    if ($hitOut) {
        return [pscustomobject]@{ state = 'loggedOut'; title = $Title; reason = "标题像登录页（$($hitOut -join ',')）" }
    }

    if ($Plat -and $Plat.detect -and $Plat.detect.titleContains) {
        $hitIn = @($Plat.detect.titleContains) | Where-Object { $Title -match [regex]::Escape($_) }
        if ($hitIn) {
            return [pscustomobject]@{ state = 'loggedIn'; title = $Title; reason = "命中已登录特征（$($hitIn -join ',')）" }
        }
    }

    $neutral = @('OCS', '导航页', 'Chrome', 'Edge', 'about:blank', '新标签页')
    $isNeutral = $false
    foreach ($n in $neutral) { if ($Title -match [regex]::Escape($n)) { $isNeutral = $true; break } }
    if ($Title -and -not $isNeutral) {
        return [pscustomobject]@{ state = 'loggedIn'; title = $Title; reason = "标题不是登录页也不是导航页（$Title），判定已进入平台内部页" }
    }

    return [pscustomobject]@{ state = 'unknown'; title = $Title; reason = '没有可用特征，需看截图确认' }
}