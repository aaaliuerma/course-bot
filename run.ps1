#requires -Version 5.1
<#
  run.ps1 — 一条命令走完「阶段①启动编排」

  做什么：检查环境 → 起 ZError → 起 OCS → 拉起浏览器 → 打开平台首页 → 截图 → 报告状态
  不做什么：不点作业、不点课程、不答题。那些交给你（AI）看截图后决定。

  用法
    .\run.ps1                         # 默认学习通
    .\run.ps1 -Platform zhihuishu     # 指定平台（见 platforms.json）
    .\run.ps1 -SkipZError             # 题库已经在跑，跳过
    .\run.ps1 -NoNav                  # 只起环境，不开平台首页

  产物
    logs\<时间戳>\run.log        完整执行日志
    shots\01-entry.png          平台首页截图
#>
[CmdletBinding()]
param(
    [string]$Platform = 'chaoxing',
    [switch]$SkipZError,
    [switch]$NoNav
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 共享底层（登录判定 Get-LoginStateFromTitle 等）
. (Join-Path $script:Root 'lib.ps1')

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $script:Root "logs\$runId"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'run.log'

# 旧产物清理：日志留最近 5 次运行，watch 截图留最近 3 次（目录名即时间戳，按名排序）
Get-ChildItem (Join-Path $script:Root 'logs') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -Skip 5 |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $script:Root 'shots') -Directory -Filter 'watch-*' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -Skip 3 |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Text, [string]$Color = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Text
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $Text -ForegroundColor $Color
}

$script:StepFailed = 0

function Invoke-Step([string]$Name, [scriptblock]$Body) {
    Write-Log "── $Name" 'Cyan'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $err = $null
    try {
        $out = & $Body 2>&1
        # 关键：调用外部 powershell 时，非零退出码不会变成异常。
        # 必须手动检查 $LASTEXITCODE，否则失败也会打绿色对勾（实测踩过）。
        $code = $LASTEXITCODE
        $out | ForEach-Object {
            if ($_ -is [string]) { Add-Content $logFile $_ -Encoding UTF8 }
            else { Add-Content $logFile ($_ | Out-String) -Encoding UTF8 }
        }
        if ($null -ne $code -and $code -ne 0) {
            $err = "子进程退出码 $code"
        }
        # 输出里出现我们自己的报错标记也算失败
        $joined = ($out | Out-String)
        if (-not $err -and $joined -match '\[失败\]|ERR:|✗ |throw ') { $err = "输出里有错误标记" }
    } catch {
        $err = $_.Exception.Message
        Add-Content $logFile ($_ | Out-String) -Encoding UTF8
    }

    if ($err) {
        Write-Log "   ✗ 失败：$err（$([math]::Round($sw.Elapsed.TotalSeconds,1))s）" 'Red'
        $script:StepFailed++
        return $false
    }
    Write-Log "   ✓ 完成（$([math]::Round($sw.Elapsed.TotalSeconds,1))s）" 'Green'
    return $true
}

Write-Log "========== 运行 $runId ==========" 'White'
Write-Log "平台：$Platform  跳过ZError：$([bool]$SkipZError)  跳过导航：$([bool]$NoNav)"

# ── 0. 平台是否存在 ──
$pfPath = Join-Path $script:Root 'platforms.json'
if (-not (Test-Path $pfPath)) { Write-Log "缺少 platforms.json" 'Red'; exit 1 }
$pf = Get-Content $pfPath -Raw -Encoding UTF8 | ConvertFrom-Json
$plat = $pf.platforms | Where-Object { $_.id -eq $Platform } | Select-Object -First 1
if (-not $plat) {
    Write-Log "platforms.json 里没有 id=$Platform。可选：$(($pf.platforms | ForEach-Object { $_.id }) -join ', ')" 'Red'
    exit 1
}
Write-Log "平台名称：$($plat.name)   入口：$($plat.entry)   已验证：$($plat.verified)"
if (-not $plat.verified) {
    Write-Log "⚠ 这个平台的入口还没实测过，可能不准。到页面后请立刻截图确认。" 'Yellow'
}

# ── 1. 环境自检 ──
$null = Invoke-Step "环境自检" {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\chaoxing.ps1" discover
}

# ── 2. 起 ZError + OCS + 浏览器 ──
if ($SkipZError) {
    $null = Invoke-Step "起浏览器（跳过 ZError）" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\chaoxing.ps1" up-a
    }
} else {
    $null = Invoke-Step "起 ZError + 浏览器" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\chaoxing.ps1" start
    }
}

# ── 3. 打开平台首页 ──
# （原来这里还有一步「等浏览器就绪」，但 up-a 内部已经轮询到页面可操作才返回，重复了）
if (-not $NoNav) {
    $null = Invoke-Step "打开 $($plat.name)" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\ocs-session.ps1" url $plat.entry
        Start-Sleep -Seconds 2   # url 内部已轮询校验跳转，这里只留页面加载缓冲
    }
}

# ── 4. 截图 ──
$shotPath = $null
$null = Invoke-Step "截图" {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\ocs-session.ps1" shot "01-entry"
    $out | ForEach-Object { Write-Output $_ }
    $line = ($out | Out-String)
    if ($line -match '([A-Z]:\\[^\r\n]+\.png)') { $script:shotPath = $Matches[1] }
}

# ── 5. 状态汇总 ──
Write-Log "`n========== 结果 ==========" 'White'
$title = & powershell -NoProfile -ExecutionPolicy Bypass -File "$script:Root\ocs-session.ps1" title 2>$null
Write-Log "窗口标题：$title"
Write-Log "日志目录：$logDir"
if ($shotPath) { Write-Log "首页截图：$shotPath" }

# 登录断言：本脚本只起环境 + 导航，**不含登录**。
# 不说清楚的话，四个绿勾会让人以为「已经能干活了」，其实还停在登录页。
# 与 login.ps1 同一套三态判定（lib.ps1 的 Get-LoginStateFromTitle），不再两处各写一份判据
$loginState = Get-LoginStateFromTitle $title $plat
$needLogin = ($loginState.state -ne 'loggedIn')

if ($needLogin) {
    Write-Log "`n⚠ 当前还没登录（标题：$title）" 'Yellow'
    Write-Log "  本脚本只负责起环境 + 导航，登录要单独一步：" 'Yellow'
    Write-Log "    powershell -NoProfile -ExecutionPolicy Bypass -File .\login.ps1 -Platform $Platform" 'Yellow'
    Write-Log "  或者：go.cmd login" 'Yellow'
} else {
    Write-Log "`n✓ 已登录，可以直接交给 OCS 干活。" 'Green'
}
if ($script:StepFailed -gt 0) {
    Write-Log "`n⚠ 有 $($script:StepFailed) 个步骤失败，先看上面的红字再往下走。" 'Red'
    exit 1
}
Write-Log "`n下一步：读首页截图，判断当前在哪个页面、是否需要登录，然后决定点哪里。" 'Yellow'
Write-Log "所有操作请用 ocs-session.ps1 的 clickpx / click / type / key，每次动作后截图确认。" 'Yellow'
