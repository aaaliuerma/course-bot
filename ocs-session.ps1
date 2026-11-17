#requires -Version 5.1
<#
  ocs-session.ps1 — 浏览器「手眼层」

  给 AI 用的最小操作集：截图、读标题、点击、打字、按键、导航。
  所有坐标都相对「浏览器窗口」而非屏幕，换分辨率/换机器不用改代码。

  用法
    .\ocs-session.ps1 shot [名字]        截浏览器窗口 → shots\<名字>.png
    .\ocs-session.ps1 title              读当前窗口标题（粗判在哪一页）
    .\ocs-session.ps1 click 0.5 0.3      按相对坐标点（0~1，窗口宽高的百分比）
    .\ocs-session.ps1 clickpx 500 300    按窗口内像素点
    .\ocs-session.ps1 type "要输入的字"   粘贴式输入（支持中文）
    .\ocs-session.ps1 key ctrl+l         发送组合键
    .\ocs-session.ps1 url "https://..."  地址栏直达
    .\ocs-session.ps1 wait 2000          等待毫秒
    .\ocs-session.ps1 rect               打印窗口位置尺寸（标定用）
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('shot', 'title', 'click', 'clickpx', 'type', 'key', 'url', 'wait', 'rect')]
    [string]$Action,

    [Parameter(Position = 1)][string]$A1,
    [Parameter(Position = 2)][string]$A2
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ShotDir = Join-Path $script:Root 'shots'
if (-not (Test-Path $script:ShotDir)) { New-Item -ItemType Directory -Path $script:ShotDir -Force | Out-Null }

# 共享底层（DPI / P/Invoke / SW 窗口枚举）已抽到 lib.ps1，与 chaoxing.ps1 共用
. (Join-Path $script:Root 'lib.ps1')

function Get-BrowserWinHandle {
    # 候选窗口按面积从大到小，再逐个按 OCS profile 命令行过滤——
    # 不能直接拿「可见最大的 Chrome」：用户自己的 Chrome 窗口更大时，
    # 点击/输入（含账号密码）会落进错误的浏览器。判据与 chaoxing.ps1 的 Get-BrowserProcs 一致。
    $cands = [SW]::FindAllBrowsers()
    if (-not $cands -or $cands.Count -eq 0) {
        throw "没找到浏览器窗口。先跑 chaoxing.ps1 up-a 把浏览器拉起来。"
    }
    foreach ($h in $cands) {
        $wpid = [uint32]0
        [void][SW]::GetWindowThreadProcessId($h, [ref]$wpid)
        $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$wpid" -ErrorAction SilentlyContinue).CommandLine
        if ($cl -and $cl -match 'OCS Desktop\\userDataDirs') { return $h }
    }
    throw "找到 $($cands.Count) 个浏览器窗口，但都不是 OCS 启动的（你自己的 Chrome/Edge 不会被操作）。先跑 chaoxing.ps1 up-a。"
}

function Get-BrowserTile {
    # 标题单独从窗口句柄读，仅用于展示/粗判，不参与窗口定位
    $h = Get-BrowserWinHandle
    $sb = New-Object System.Text.StringBuilder 300
    [void][SW]::GetWindowTextW($h, $sb, 300)
    return $sb.ToString()
}

function Get-BrowserWin { return Get-BrowserWinHandle }
function Get-BrowserTitle { return Get-BrowserTile }

function Focus-Win([IntPtr]$h) {
    [void][SW]::ShowWindow($h, 9)
    Start-Sleep -Milliseconds 400
    [void][SW]::SetForegroundWindow($h)
    [void][SW]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0001 -bor 0x0040)  # TOPMOST
    Start-Sleep -Milliseconds 400
}

function Unfocus-Win([IntPtr]$h) {
    [void][SW]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0001)              # NOTOPMOST
}

function Get-Rect([IntPtr]$h) {
    # 最小化窗口的 rect 是 199x34 这类鬼尺寸，宽高都要检查
    $r = New-Object SW+WR
    [void][SW]::GetWindowRect($h, [ref]$r)
    if (($r.R - $r.L) -lt 300 -or ($r.B - $r.T) -lt 300) {
        throw "窗口尺寸异常（$($r.R-$r.L)x$($r.B-$r.T)），窗口可能被最小化。先 chaoxing.ps1 focus 或手动还原。"
    }
    return $r
}

function Get-WindowTitle([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 300
    [void][SW]::GetWindowTextW($h, $sb, 300)
    return $sb.ToString()
}

function Ensure-Window([IntPtr]$h) {
    [void][SW]::ShowWindow($h, 9)   # SW_RESTORE
    Start-Sleep -Milliseconds 600
}

switch ($Action) {

    'rect' {
        $h = Get-BrowserWin
        Ensure-Window $h
        $r = Get-Rect $h
        [pscustomobject]@{
            标题 = Get-BrowserTitle
            左上 = "$($r.L),$($r.T)"
            宽高 = "$($r.R - $r.L)x$($r.B - $r.T)"
            handle = $h
        } | Format-List
    }

    'title' {
        $h = Get-BrowserWin
        Get-BrowserTitle
    }

    'shot' {
        $h = Get-BrowserWin
        Ensure-Window $h
        $r = Get-Rect $h
        Add-Type -AssemblyName System.Drawing
        $w = $r.R - $r.L; $ht = $r.B - $r.T
        $bmp = New-Object System.Drawing.Bitmap($w, $ht)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
        $name = if ($A1) { $A1 } else { "shot-$(Get-Date -Format HHmmss)" }
        if ($name -notmatch '\.png$') { $name += '.png' }
        $path = Join-Path $script:ShotDir $name
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        [pscustomobject]@{
            文件 = $path
            尺寸 = "${w}x${ht}"
            标题 = Get-BrowserTitle
        } | Format-List
    }

    'click' {
        if (-not $A1 -or -not $A2) { throw "用法：click <相对x 0~1> <相对y 0~1>" }
        $h = Get-BrowserWin
        $r = Get-Rect $h
        $x = [int]($r.L + [double]$A1 * ($r.R - $r.L))
        $y = [int]($r.T + [double]$A2 * ($r.B - $r.T))
        Focus-Win $h
        [void][SW]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 200
        [SW]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 90
        [SW]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Unfocus-Win $h
        "clicked $x,$y  (相对 $A1,$A2)"
    }

    'clickpx' {
        if (-not $A1 -or -not $A2) { throw "用法：clickpx <窗口内x> <窗口内y>" }
        $h = Get-BrowserWin
        $r = Get-Rect $h
        $x = [int]($r.L + [int]$A1)
        $y = [int]($r.T + [int]$A2)
        Focus-Win $h
        [void][SW]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 200
        [SW]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 90
        [SW]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Unfocus-Win $h
        "clicked $x,$y  (窗口内 $A1,$A2)"
    }

    'type' {
        if ($null -eq $A1) { throw "用法：type <文本>" }
        Add-Type -AssemblyName System.Windows.Forms
        $h = Get-BrowserWin
        Focus-Win $h

        # 纯 ASCII（账号、密码、URL 这类）直接用 SendKeys 逐字符，不碰剪贴板——
        # 剪贴板会被其它程序抢占，实测报 "Clipboard operation did not succeed"。
        # 含中文才走剪贴板，并带重试。
        $hasNonAscii = [bool]($A1 -match '[^\x00-\x7F]')
        if (-not $hasNonAscii) {
            $esc = $A1 -replace '([+^%~()\{\}\[\]])', '{$1}'
            [System.Windows.Forms.SendKeys]::SendWait($esc)
        } else {
            $ok = $false
            for ($i = 0; $i -lt 3 -and -not $ok; $i++) {
                try { Set-Clipboard -Value $A1; $ok = $true } catch { Start-Sleep -Milliseconds 400 }
            }
            if (-not $ok) { throw "写剪贴板失败（被其它程序占用）" }
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.SendKeys]::SendWait('^v')
        }
        Start-Sleep -Milliseconds 300
        Unfocus-Win $h
        "typed $($A1.Length) 字 ($(if($hasNonAscii){'剪贴板'}else{'直输'}))"
    }

    'key' {
        if (-not $A1) { throw "用法：key ctrl+l / key enter / key tab" }
        Add-Type -AssemblyName System.Windows.Forms
        $h = Get-BrowserWin
        Focus-Win $h
        $map = @{
            'ctrl+l' = '^l'; 'ctrl+a' = '^a'; 'ctrl+c' = '^c'; 'ctrl+v' = '^v'
            'enter'  = '{ENTER}'; 'tab' = '{TAB}'; 'esc' = '{ESC}'
            'backspace' = '{BACKSPACE}'; 'delete' = '{DELETE}'; 'f5' = '{F5}'
            'ctrl+w' = '^w'; 'ctrl+t' = '^t'; 'alt+left' = '%{LEFT}'
        }
        $seq = if ($map.ContainsKey($A1.ToLower())) { $map[$A1.ToLower()] } else { $A1 }
        [System.Windows.Forms.SendKeys]::SendWait($seq)
        Start-Sleep -Milliseconds 300
        Unfocus-Win $h
        "sent $A1"
    }

    'url' {
        if (-not $A1) { throw "用法：url <地址>" }
        Add-Type -AssemblyName System.Windows.Forms
        $h = Get-BrowserWin
        Focus-Win $h
        # 时序要留足：Ctrl+L 后地址栏要真正获得焦点，剪贴板写入也要时间，
        # 否则 Enter 会在空地址栏上触发，页面纹丝不动。
        $origTitle = Get-WindowTitle $h
        [System.Windows.Forms.SendKeys]::SendWait('^l')
        Start-Sleep -Milliseconds 700
        # URL 一定是 ASCII，直接打，不碰剪贴板——剪贴板常被别的程序占用，
        # 实测 Set-Clipboard 会抛 "Clipboard operation did not succeed"。
        $esc = $A1 -replace '([+^%~()\{\}\[\]])', '{$1}'
        [System.Windows.Forms.SendKeys]::SendWait($esc)
        Start-Sleep -Milliseconds 700
        # 连发两次 Enter：第一次常被地址栏的自动补全下拉吃掉（只是选建议，不导航），
        # 第二次才真正提交。少了这一下就会出现「地址栏有 URL 但页面没动」。
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Start-Sleep -Seconds 4

        # 校验真的跳走了。SendKeys 会静默失败（焦点被抢、下拉吃掉 Enter 等），
        # 不校验就会「打印 navigated 但页面纹丝不动」，把排错方向带偏。
        # 判据要看「从哪里出发」，否则两头都会误判：
        #   ① 从导航页出发（正常首次导航）→ 必须真的脱离导航页
        #   ② 已经在平台内部页 → 只有标题变了才算跳转；没变就当"已在目标页/刷新"
        # 没法读 URL（A 道无 CDP），所以 ② 只能保守处理，不阻塞。
        $wasNavPage = $origTitle -match '导航页|bookmarks'
        $jumped = $false
        $badSearch = $false
        $lastTitle = $origTitle
        for ($k = 0; $k -lt 3; $k++) {
            Start-Sleep -Seconds 2
            $now = Get-WindowTitle $h
            if (-not $now) { continue }
            $lastTitle = $now
            # URL 被当成搜索词的特征
            if ($now -match 'Google 搜索|Google Search|^Bing|百度搜索') { $badSearch = $true; break }
            if ($wasNavPage) {
                if ($now -notmatch '导航页|bookmarks') { $jumped = $true; break }
            } else {
                if ($now -ne $origTitle -and $now -notmatch '导航页|bookmarks') { $jumped = $true; break }
            }
        }
        # 已经在平台内部、且标题没变：当作"本来就在目标页"，不阻塞
        if (-not $jumped -and -not $badSearch -and -not $wasNavPage) { $jumped = $true }
        Unfocus-Win $h

        if ($jumped) {
            "navigated → $A1"
        } elseif ($badSearch) {
            "⚠ 这个地址被浏览器当成搜索词了（域名拼错或打不开）——检查 $A1"
            exit 4
        } else {
            "⚠ 导航可能没生效（当前标题：$lastTitle）——先进浏览器确认地址栏，再重跑本条"
            exit 4
        }
    }

    'wait' {
        $ms = if ($A1) { [int]$A1 } else { 1000 }
        Start-Sleep -Milliseconds $ms
        "waited ${ms}ms"
    }
}
