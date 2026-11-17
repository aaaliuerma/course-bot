#requires -Version 5.1
<#
  chaoxing.ps1 — 学习通作业 / 刷课 工作流工具箱（A 道：OCS 原生启动）

  设计原则
    * 不硬编码任何本机路径、浏览器 uid、账号 —— 全部自动发现或读 config.json
    * 环境不对时报清楚哪一步缺什么，而不是抛一个看不懂的异常

  用法
    .\chaoxing.ps1 discover    # 只读：显示自动发现到的环境
    .\chaoxing.ps1 probe       # 只读：全链路探活
    .\chaoxing.ps1 start       # 起 ZError + 浏览器 + 校验
    .\chaoxing.ps1 up-z        # 只起 ZError
    .\chaoxing.ps1 up-a        # 只起浏览器
    .\chaoxing.ps1 status      # 当前状态
    .\chaoxing.ps1 focus       # 浏览器提到前台
    .\chaoxing.ps1 down-a      # 关浏览器
    .\chaoxing.ps1 calibrate    # 截 OCS 窗口到 calibration\ 并打印尺寸，用于重新标定
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('discover', 'probe', 'start', 'up-z', 'up-a', 'status', 'focus', 'down-a', 'calibrate')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 共享底层（DPI / P/Invoke / UIA / 登录判定）已抽到 lib.ps1，与 ocs-session.ps1 共用
. (Join-Path $script:Root 'lib.ps1')

# ───────────────────────── 配置 ─────────────────────────
function Get-Cfg {
    $p = Join-Path $script:Root 'config.json'
    if (-not (Test-Path $p)) { $p = Join-Path $script:Root 'config.example.json' }
    if (-not (Test-Path $p)) { throw "缺少配置文件：$p" }
    return Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ───────────────────────── 路径探测 ─────────────────────────
function Find-OcsExe([string]$Hint) {
    if ($Hint -and (Test-Path $Hint)) { return $Hint }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\OCS Desktop\OCS Desktop.exe'),
        (Join-Path $env:ProgramFiles 'OCS Desktop\OCS Desktop.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'OCS Desktop\OCS Desktop.exe')
    )
    $hit = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($hit) { return $hit }
    # 退回注册表
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $reg = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'OCS Desktop' } | Select-Object -First 1
    if ($reg) {
        $loc = ($reg.InstallLocation -replace '"', '')
        if ($loc -and (Test-Path (Join-Path $loc 'OCS Desktop.exe'))) { return (Join-Path $loc 'OCS Desktop.exe') }
    }
    return $null
}

function Find-ZErrorExe([string]$Hint) {
    if ($Hint -and (Test-Path $Hint)) { return $Hint }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'ZError\zerror.exe'),
        (Join-Path $env:ProgramFiles 'ZError\zerror.exe')
    )
    $hit = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if ($hit) { return $hit }
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $reg = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^ZError' } | Select-Object -First 1
    if ($reg) {
        $loc = ($reg.InstallLocation -replace '"', '')
        if ($loc -and (Test-Path (Join-Path $loc 'zerror.exe'))) { return (Join-Path $loc 'zerror.exe') }
    }
    return $null
}

# ───────────────────────── OCS 环境（自动发现）─────────────────────────
function Get-OcsConfigPath { Join-Path $env:APPDATA 'OCS Desktop\config.json' }

function Get-OcsConfig {
    $p = Get-OcsConfigPath
    if (-not (Test-Path $p)) {
        throw "找不到 OCS 配置：$p`n   → 先安装 OCS Desktop，并至少手动运行一次"
    }
    return Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-BrowserList {
    $out = @()

    # 2.x：浏览器列表是明文 JSON，能直接读
    try {
        $j = Get-OcsConfig
        if ($j.render -and $j.render.browser -and $j.render.browser.root.children) {
            foreach ($p in $j.render.browser.root.children.PSObject.Properties) {
                $v = $p.Value
                $out += [pscustomobject]@{
                    uid = $v.uid; name = $v.name; cachePath = $v.cachePath
                    exists = (Test-Path $v.cachePath)
                }
            }
        }
    } catch { }

    # 3.x：config 里的 render 被加密了（一长串密文），读不到列表。
    # 但 profile 目录还在，目录名就是 uid，数量也对得上。
    if (-not $out.Count) {
        $dirs = Join-Path $env:APPDATA 'OCS Desktop\userDataDirs'
        if (Test-Path $dirs) {
            $idx = 0
            Get-ChildItem $dirs -Directory | ForEach-Object {
                $idx++
                $out += [pscustomobject]@{
                    uid       = $_.Name
                    name      = "(第 $idx 个浏览器)"
                    cachePath = $_.FullName
                    exists    = $true
                }
            }
            Write-Host "  [提示] OCS 3.x 配置文件已加密，浏览器名字读不到，改用 profile 目录推断" -ForegroundColor DarkGray
        }
    }

    if (-not $out.Count) { throw "OCS 里还没有任何浏览器。打开 OCS 新建一个再跑。" }
    return $out
}

function Resolve-Browser([string]$Name) {
    $list = Get-BrowserList
    if ($Name) {
        $hit = $list | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($hit) { return $hit }
        # 3.x 读不到名字（配置加密），此时配置里的名字仍然有效——
        # 启动时按名字走 UIA 定位，不需要 uid 精确匹配
        if ($list.Count -and $list[0].name -like '*(第 *') {
            # 3.x 配置加密，读不到真名，只能用配置里写的名字去 UIA 匹配。
            # 这里必须吭声：名字对不上时 UIA 会静默失效，最后报成「需要重新标定」，
            # 把「改配置字符串」的问题包装成「量像素坐标」的问题，很容易死循环。
            Write-Host "  [注意] 读不到 OCS 里的浏览器真名，将用配置里的 '$Name' 去界面匹配。" -ForegroundColor Yellow
            Write-Host "         如果之后 UIA 点不中，先用 shot 看一眼卡片上写的名字是否一致。" -ForegroundColor Yellow
            return [pscustomobject]@{ uid = $list[0].uid; name = $Name; cachePath = $list[0].cachePath; exists = $true }
        }
        Write-Warning "没找到名为 '$Name' 的浏览器，退回第一个：'$($list[0].name)'"
    }
    return $list[0]
}

# ───────────────────────── 运行时对象 ─────────────────────────
$script:Cfg = $null
$script:OcsExe = $null
$script:ChromeExe = $null
$script:ExtDir = $null
$script:Browser = $null
$script:ZErrorExe = $null
$script:ZErrorPort = 3000

function Initialize-Env {
    $script:Cfg = Get-Cfg
    if ($script:Cfg.zerror.port) { $script:ZErrorPort = [int]$script:Cfg.zerror.port }

    $script:OcsExe = Find-OcsExe $script:Cfg.ocs.exePath
    if (-not $script:OcsExe) { throw "没找到 OCS Desktop.exe。装了但路径不同就在 config.json 里填 ocs.exePath。" }

    $ocsHome = Split-Path $script:OcsExe -Parent
    # 内置浏览器位置随版本变：
    #   2.x → <安装目录>\resources\bin\chrome\chrome\chrome.exe
    #   3.x → %APPDATA%\OCS Desktop\bin\chrome\chrome\chrome.exe（挪到用户数据目录了）
    $script:ChromeExe = $null
    if ($script:Cfg.ocs.chromePath -and (Test-Path $script:Cfg.ocs.chromePath)) {
        $script:ChromeExe = $script:Cfg.ocs.chromePath
    } else {
        $cands = @(
            (Join-Path $env:APPDATA 'OCS Desktop\bin\chrome\chrome\chrome.exe'),
            (Join-Path $ocsHome 'resources\bin\chrome\chrome\chrome.exe')
        )
        $script:ChromeExe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $script:ChromeExe) { $script:ChromeExe = $cands[0] }   # 都不存在时留个路径方便报错
    }
    $script:ExtDir = Join-Path $env:APPDATA 'OCS Desktop\downloads\extensions\scriptcat'

    $script:Browser = Resolve-Browser $script:Cfg.ocs.browserName
    $script:ZErrorExe = Find-ZErrorExe $script:Cfg.zerror.exePath

    # 标定值覆盖：OCS / ZError 升级后界面变了，在 config.json 的 calibration 段改这里，
    # 不用动脚本。量法见 calibrate 动作。
    if ($script:Cfg.calibration) {
        $cal = $script:Cfg.calibration
        foreach ($k in @('ocsBrowserRun', 'zErrorStartBtn')) {
            $v = $cal.$k
            if (-not $v) { continue }
            if ($v.PSObject.Properties.Name -contains 'right') {
                $Rel[$k] = @{ right = [int]$v.right; top = [int]$v.top }
            } elseif ($v.PSObject.Properties.Name -contains 'x') {
                $Rel[$k] = @{ x = [double]$v.x; y = [double]$v.y }
            }
        }
    }
}

# ───────────────────────── 基础工具 ─────────────────────────
function Test-Port([int]$Port) {
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(700)
        $r = ($ok -and $c.Connected); $c.Close(); return $r
    } catch { return $false }
}

function Wait-Port([int]$Port, [int]$TimeoutSec = 40) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-Port $Port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (Test-Port $Port)
}

# OCS 支持两种内核：自带的 Chromium（进程名 chrome.exe）和系统 Edge（msedge.exe）。
# 用户可以在 OCS 设置里切换，所以不能只认 chrome.exe。
$script:BrowserExeNames = @('chrome.exe', 'msedge.exe', 'chromium.exe')

function Get-BrowserProcs {
    # 按「OCS 的 userDataDirs 路径」匹配，而不是具体 uid。
    # 3.x 配置加密后 uid 拿不准；换内核后进程名也不一样，两者都靠路径兜住。
    $rows = @()
    foreach ($n in $script:BrowserExeNames) {
        $rows += Get-CimInstance Win32_Process -Filter "Name='$n'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'OCS Desktop\\userDataDirs' }
    }
    return $rows
}

# Get-MainWindow / Find-UiaButton / Invoke-UiaButton / Invoke-UiaStartBrowser /
# Click-Point / Show-Win 已移入 lib.ps1（与 ocs-session.ps1 共享同一份实现）

function Click-Rel([IntPtr]$h, [hashtable]$Pos, [string]$Label = '') {
    if ($h -eq [IntPtr]::Zero) { throw "窗口不存在：$Label" }
    # 必须强制置顶：目标窗口常被微信/浏览器整屏压住，
    # 单纯 SetForegroundWindow 会被前台的其它程序抢回，点击就落到别人身上。
    Show-Win $h -TopMost
    $r = New-Object Ui+RECT
    [void][Ui]::GetWindowRect($h, [ref]$r)
    if ($r.R - $r.L -lt 200) { throw "窗口未恢复，无法点击：$Label" }
    if ($Pos.ContainsKey('right') -or $Pos.ContainsKey('top')) {
        # 像素模式：距右边缘 / 距顶部固定像素
        $x = [int]($r.R - [int]$Pos.right)
        $y = [int]($r.T + [int]$Pos.top)
    } else {
        # 百分比模式（兼容旧配置）
        $x = [int]($r.L + [double]$Pos.x * ($r.R - $r.L))
        $y = [int]($r.T + [double]$Pos.y * ($r.B - $r.T))
    }
    [void][Ui]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200
    [Ui]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 90
    [Ui]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    [void][Ui]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0001)   # 取消置顶
    Write-Host "  [click] $Label → ($x,$y)  窗口=($($r.L),$($r.T))-($($r.R),$($r.B))" -ForegroundColor DarkGray
}

# 标定说明见 SKILL.md 第五节
# 标定用「距窗口右边缘 / 距窗口顶部的固定像素」，不用百分比。
# 百分比是按窗口高度算的，窗口一高一矮就偏——按钮其实固定在顶部工具栏下方，
# 和窗口高度无关。实测：窗口高 691 和 750 时按钮都在距顶约 233px 处。
# 单位：像素。窗口缩放/移动都不影响。
$Rel = @{
    ZErrorStartBtn = @{ right = 126; top = 104 }
    OcsBrowserRun  = @{ right = 64;  top = 233 }
}

# ───────────────────────── 动作 ─────────────────────────
function Ensure-Env { if (-not $script:Browser) { Initialize-Env } }

function Invoke-Calibrate {
    Ensure-Env
    $h = Get-MainWindow 'OCS Desktop'
    if ($h -eq [IntPtr]::Zero) { throw "OCS 没在运行。先跑 chaoxing.ps1 up-a" }
    Show-Win $h
    $r = New-Object Ui+RECT
    [void][Ui]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    Add-Type -AssemblyName System.Drawing
    $calDir = Join-Path $script:Root 'calibration'
    if (-not (Test-Path $calDir)) { New-Item -ItemType Directory -Path $calDir -Force | Out-Null }
    $path = Join-Path $calDir 'ocs-window.png'
    $bmp = New-Object System.Drawing.Bitmap($w, $ht)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "=== OCS 窗口已截图 ===" -ForegroundColor Cyan
    "  截图 : $path"
    "  窗口 : ($($r.L),$($r.T))  宽高 ${w}x${ht}"
    "  现标定: ocsBrowserRun right=$($Rel.OcsBrowserRun.right) top=$($Rel.OcsBrowserRun.top)（距右/距顶像素）"
    Write-Host ""
    Write-Host "  下一步：在图里量出「11」那行 ▶ 按钮的中心像素 (px, py)，" -ForegroundColor Yellow
    Write-Host "  按钮中心距窗口右边缘 = ${w} - px，距顶部 = py，写进 config.json 的 calibration.ocsBrowserRun 的 right / top" -ForegroundColor Yellow
}

function Invoke-Discover {
    Initialize-Env
    Write-Host "=== 自动发现结果 ===" -ForegroundColor Cyan
    "OCS 可执行文件 : $script:OcsExe"
    "内置 Chrome    : $script:ChromeExe  (存在=$(Test-Path $script:ChromeExe))"
    "脚本管理器目录 : $script:ExtDir  (存在=$(Test-Path $script:ExtDir))"
    "ZError 可执行  : $(if($script:ZErrorExe){$script:ZErrorExe}else{'未找到'})"
    "ZError 端口    : $script:ZErrorPort"
    Write-Host "`n=== OCS 里的浏览器 ===" -ForegroundColor Cyan
    Get-BrowserList | Select-Object @{n='名字';e={$_.name}}, @{n='uid';e={$_.uid}}, @{n='profile存在';e={$_.exists}} | Format-Table -AutoSize
    "本次将使用：'$($script:Browser.name)' ($($script:Browser.uid))"
    Write-Host "`n=== 账号 ===" -ForegroundColor Cyan
    $acc = $script:Cfg.accounts
    if ($acc) {
        $acc.PSObject.Properties | Where-Object { $_.Name -notmatch '^_' } | ForEach-Object {
            $u = $_.Value.user
            # 账号打码再输出：discover 的输出会被 run.ps1 写进 run.log，
            # 之前手机号明文进日志，把日志发给别人排错就泄露了。
            $masked = if ($u -and $u.Length -ge 7) { $u.Substring(0,3) + '****' + $u.Substring($u.Length-4) } else { $u }
            "  {0,-12} {1}" -f $_.Name, $(if ($u) { $masked } else { '未填' })
        }
    } else { "  config 里没有 accounts 段" }
}

function Invoke-Probe {
    Initialize-Env
    [pscustomobject]@{
        ZError进程           = [bool](Get-Process zerror -ErrorAction SilentlyContinue)
        ZError端口           = (Test-Port $script:ZErrorPort)
        OCS进程              = [bool](Get-Process 'OCS Desktop' -ErrorAction SilentlyContinue)
        OCS端口              = (Test-Port 15319)
        浏览器进程数         = @(Get-BrowserProcs).Count
        目标浏览器           = $script:Browser.name
        OCS可执行文件存在    = (Test-Path $script:OcsExe)
        Chrome存在           = (Test-Path $script:ChromeExe)
        脚本管理器存在       = (Test-Path $script:ExtDir)
        ZError可执行文件     = [bool]$script:ZErrorExe
    } | Format-List
}

function Invoke-StartZError {
    Ensure-Env
    if (Test-Port $script:ZErrorPort) { Write-Host "[ZError] 已在运行 ($($script:ZErrorPort))" -ForegroundColor Green }
    else {
        if (-not $script:ZErrorExe) { throw "没找到 zerror.exe。装了但路径不同就在 config.json 里填 zerror.exePath。" }
        Write-Host "[ZError] 启动中..." -ForegroundColor Cyan
        & explorer.exe $script:ZErrorExe
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 25 -and -not (Get-Process zerror -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 500 }
        Start-Sleep -Seconds 3
        if (-not (Test-Port $script:ZErrorPort)) {
            $h = Get-MainWindow 'zerror'
            if ($h -ne [IntPtr]::Zero) {
                Show-Win $h
                $res = Invoke-UiaButton $h @('启动', '开始', '运行', 'Start')
                if ($res -and $res.ok) {
                    Write-Host "[ZError] 已通过 UIA Invoke 启动『$($res.name)』" -ForegroundColor Green
                }
                else {
                    Write-Host "[ZError] UIA Invoke 不可用，退回鼠标点击" -ForegroundColor Yellow
                    Click-Rel $h $Rel.ZErrorStartBtn 'ZError(坐标兜底)'
                }
            }
            if (-not (Wait-Port $script:ZErrorPort 20)) { throw "ZError 服务没起来（端口 $($script:ZErrorPort)）" }
        }
        Write-Host "[ZError] 就绪" -ForegroundColor Green
    }
    # 题库自检
    try {
        $u = "http://127.0.0.1:$($script:ZErrorPort)/query?title=" + [uri]::EscapeDataString('中国的首都是哪个城市') +
             "&options=" + [uri]::EscapeDataString('A.上海 B.北京 C.广州 D.深圳') + "&type=" + [uri]::EscapeDataString('单选题')
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $j = $wc.DownloadString($u) | ConvertFrom-Json
        if ($j.code -eq 1) { Write-Host "[ZError] 题库自检通过 → $($j.data.answer) (ai=$($j.data.is_ai))" -ForegroundColor Green }
        else { Write-Host "[ZError] 题库返回异常：$($j.message)" -ForegroundColor Yellow; Write-Host "   → 去 ZError 界面检查模型 API Key" -ForegroundColor Yellow }
    } catch { Write-Host "[ZError] 自检失败：$($_.Exception.Message)" -ForegroundColor Yellow }
}

function Invoke-StartBrowser {
    Ensure-Env
    $run = @(Get-BrowserProcs)
    if ($run.Count) { Write-Host "[Browser] '$($script:Browser.name)' 已在运行（$($run.Count) 进程）" -ForegroundColor Green; return }

    if (-not (Get-Process 'OCS Desktop' -ErrorAction SilentlyContinue)) {
        Write-Host "[OCS] 启动中..." -ForegroundColor Cyan
        & explorer.exe $script:OcsExe
        if (-not (Wait-Port 15319 40)) { throw "OCS 没起来（15319 未监听）" }
    }
    Write-Host "[OCS] 服务就绪" -ForegroundColor Green

    $wait = 25; if ($script:Cfg.behavior.windowWaitSeconds) { $wait = [int]$script:Cfg.behavior.windowWaitSeconds }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h = [IntPtr]::Zero
    while ($sw.Elapsed.TotalSeconds -lt $wait -and $h -eq [IntPtr]::Zero) {
        $h = Get-MainWindow 'OCS Desktop'
        if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 600 }
    }
    if ($h -eq [IntPtr]::Zero) { throw "找不到 OCS 主窗口" }

    $boot = 60; if ($script:Cfg.behavior.browserBootSeconds) { $boot = [int]$script:Cfg.behavior.browserBootSeconds }
    $started = $false

    # 优先 UIA：不受窗口尺寸/位置/DPI 影响，也不用标定
    $hUia = Get-MainWindow 'OCS Desktop'
    if ($hUia -ne [IntPtr]::Zero) {
        Show-Win $hUia
        if (Invoke-UiaStartBrowser $hUia $script:Browser.name) {
            Write-Host "[OCS] 已通过 UIA 启动『$($script:Browser.name)』" -ForegroundColor Green
            $swU = [Diagnostics.Stopwatch]::StartNew()
            while ($swU.Elapsed.TotalSeconds -lt $boot) {
                if (@(Get-BrowserProcs).Count -gt 0) { $started = $true; break }
                Start-Sleep -Milliseconds 800
            }
        } else {
            Write-Host "[OCS] UIA 读不到启动按钮，退回坐标法" -ForegroundColor Yellow
        }
    }

    if (-not $started) {
    Write-Host "[OCS] 点『$($script:Browser.name)』的启动按钮（坐标法）" -ForegroundColor Cyan

    # OCS 是 Electron，界面内容对 UIA 完全不可见（实测后代元素 0 个），只能靠坐标。
    # 因此每次点击后必须用「chrome 进程是否出现」验证真的点中了，没中就微调再试。
    # 重试的微调也要跟着标定模式走：像素模式调 top±15px，百分比模式调 y±0.02。
    # （之前这里写死百分比，切到像素模式后算出过 (0,-15) 这种坐标）
    $base = $Rel.OcsBrowserRun
    $attempts = @()
    if ($base.ContainsKey('right')) {
        $attempts += @{ pos = $base; label = 'OCS-浏览器' }
        $attempts += @{ pos = @{ right = [int]$base.right; top = [int]$base.top - 15 }; label = 'OCS-浏览器(上移15px)' }
        $attempts += @{ pos = @{ right = [int]$base.right; top = [int]$base.top + 15 }; label = 'OCS-浏览器(下移15px)' }
    } else {
        $attempts += @{ pos = $base; label = 'OCS-浏览器' }
        $attempts += @{ pos = @{ x = [double]$base.x; y = [double]$base.y - 0.02 }; label = 'OCS-浏览器(上移)' }
        $attempts += @{ pos = @{ x = [double]$base.x; y = [double]$base.y + 0.02 }; label = 'OCS-浏览器(下移)' }
    }
    $started = $false
    for ($k = 0; $k -lt $attempts.Count; $k++) {
        Click-Rel $h $attempts[$k].pos $attempts[$k].label
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        while ($sw2.Elapsed.TotalSeconds -lt $boot) {
            if (@(Get-BrowserProcs).Count -gt 0) { $started = $true; break }
            Start-Sleep -Milliseconds 800
        }
        if ($started) { break }
        if ($k -lt $attempts.Count - 1) { Write-Host "  没反应，换个位置再试" -ForegroundColor Yellow }
    }
    }   # ← 结束 if (-not $started) 的坐标法分支

    if (-not $started) {
        Write-Host ""
        Write-Host "[Browser] 三次点击都没起来。" -ForegroundColor Yellow
        Write-Host "          先按顺序查，别急着量坐标：" -ForegroundColor Yellow
        Write-Host "            1) config.json 的 ocs.browserName 是否和 OCS 卡片上的名字一字不差（最常见）" -ForegroundColor Yellow
        Write-Host "            2) OCS 窗口是不是被「欢迎使用」弹窗挡住了" -ForegroundColor Yellow
        Write-Host "            3) OCS 里到底有没有这个浏览器（跑 discover 看）" -ForegroundColor Yellow
        Write-Host "            4) 以上都对，才轮到坐标漂了（仅 2.x 需要）" -ForegroundColor Yellow
        Write-Host "          下面自动截图，供你判断：" -ForegroundColor Yellow
        Write-Host ""
        try { Invoke-Calibrate } catch { Write-Host "  （自动截图失败：$($_.Exception.Message)）" -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "  把量出的 right / top 写进 config.json 的 calibration.ocsBrowserRun，" -ForegroundColor Yellow
        Write-Host "  然后重跑：.\chaoxing.ps1 up-a" -ForegroundColor Yellow
        throw "坐标需要重新标定（已自动截图）"
    }

    Write-Host "[Browser] 已启动（$(@(Get-BrowserProcs).Count) 进程）" -ForegroundColor Green
    Write-Host "   等页面就绪..." -ForegroundColor DarkGray

    # 真正等到页面可操作再返回，否则调用方不知道什么时候能动手。
    # 判据：窗口标题不再是空的，且出现导航页/个人空间/登录页这类关键字。
    $sessionPs = Join-Path $script:Root 'ocs-session.ps1'
    $sw3 = [Diagnostics.Stopwatch]::StartNew()
    $readyTitle = $null
    while ($sw3.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 1500
        $title = & powershell -NoProfile -ExecutionPolicy Bypass -File $sessionPs title 2>$null
        if ($title -and $title -match '导航页|个人空间|用户登录|超星|MOOC|智慧') {
            $readyTitle = $title
            break
        }
    }
    if ($readyTitle) {
        Write-Host "[Browser] 页面就绪：$readyTitle" -ForegroundColor Green
    } else {
        Write-Host "[Browser] 90 秒内没等到可辨认的页面，先 shot 看一眼" -ForegroundColor Yellow
    }
}

function Invoke-Status {
    Initialize-Env
    Write-Host "=== ZError ===" -ForegroundColor Cyan
    "  进程=$([bool](Get-Process zerror -ErrorAction SilentlyContinue))  端口$($script:ZErrorPort)=$(Test-Port $script:ZErrorPort)"
    Write-Host "=== OCS ===" -ForegroundColor Cyan
    "  进程=$([bool](Get-Process 'OCS Desktop' -ErrorAction SilentlyContinue))  15319=$(Test-Port 15319)"
    Write-Host "=== 浏览器 '$($script:Browser.name)' ===" -ForegroundColor Cyan
    "  进程数=$(@(Get-BrowserProcs).Count)"
    Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne '' } |
        Select-Object @{n='窗口标题';e={$_.MainWindowTitle}} | Format-Table -AutoSize
}

function Invoke-Focus {
    Initialize-Env
    $c = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne '' } | Select-Object -First 1
    if (-not $c) { throw "没有 chrome 窗口" }
    Show-Win $c.MainWindowHandle -TopMost
    "已前置：$($c.MainWindowTitle)"
}

function Invoke-DownBrowser {
    Initialize-Env
    $p = @(Get-BrowserProcs)
    if (-not $p.Count) { Write-Host "[down] 浏览器没在跑" -ForegroundColor Yellow; return }
    Write-Host "[down] 关闭 $($p.Count) 个进程" -ForegroundColor Cyan
    $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    "[down] 剩余 $(@(Get-BrowserProcs).Count)"
}

switch ($Action) {
    'discover' { Invoke-Discover }
    'probe'    { Invoke-Probe }
    'start'    { Invoke-StartZError; Invoke-StartBrowser; Invoke-Status }
    'up-z'     { Invoke-StartZError }
    'up-a'     { Invoke-StartBrowser }
    'status'   { Invoke-Status }
    'focus'    { Invoke-Focus }
    'down-a'   { Invoke-DownBrowser }
    'calibrate' { Invoke-Calibrate }
}
