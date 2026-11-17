#requires -Version 5.1
<#
  login.ps1 — 登录检查 + 自动登录

  思路：登录不是每次都做。先打开平台入口看落在哪一页，
        掉线了才走登录流程；没掉线直接跳过。

  用法
    .\login.ps1 -Platform chaoxing              # 检查，掉线则自动登录
    .\login.ps1 -Platform chaoxing -CheckOnly   # 只检查，不登录
    .\login.ps1 -Platform chaoxing -Force       # 强制走一遍登录流程
    .\login.ps1 -Platform chaoxing -User X -Pass Y   # 临时指定账号

  账号来源优先级：命令行参数 > config.json 的 accounts.<平台id> > 都没有则报错

  首次使用某个平台时没有登录布局坐标，脚本会把登录页截图给你，
  标定后写进 config.json 的 loginLayout.<平台id>，之后就能全自动。
#>
[CmdletBinding()]
param(
    [string]$Platform = 'chaoxing',
    [switch]$CheckOnly,
    [switch]$Force,
    [string]$User,
    [string]$Pass
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Session = Join-Path $script:Root 'ocs-session.ps1'

# 共享底层（登录判定 Get-LoginStateFromTitle 等）
. (Join-Path $script:Root 'lib.ps1')

function SS {
    param([string[]]$ArgList)
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $script:Session @ArgList 2>&1 | Out-String).Trim()
}

function Log([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

# ── 读配置 ──
$pf = Get-Content (Join-Path $script:Root 'platforms.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$plat = $pf.platforms | Where-Object { $_.id -eq $Platform } | Select-Object -First 1
if (-not $plat) { throw "platforms.json 里没有 id=$Platform" }

$cfgPath = Join-Path $script:Root 'config.json'
$cfg = $null
if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }

# ── 账号 ──
if (-not $User) {
    if ($cfg -and $cfg.accounts -and $cfg.accounts.$Platform) { $User = $cfg.accounts.$Platform.user }
}
if (-not $Pass) {
    if ($cfg -and $cfg.accounts -and $cfg.accounts.$Platform) { $Pass = $cfg.accounts.$Platform.pass }
}

# ── 登录态判断（三态）──
# 只有"标题明确是登录页"才是强信号。首页不含"登录"字样 ≠ 已登录
# （比如中国大学MOOC 未登录时首页标题也很正常），所以其余情况一律 unknown，
# 交给截图由 AI 目视确认。
function Get-LoginState([object]$Plat) {
    # 判据统一在 lib.ps1 的 Get-LoginStateFromTitle（与 run.ps1 共用），这里只负责取标题
    $title = SS @('title')
    return Get-LoginStateFromTitle $title $Plat
}

# -CheckOnly 表示「只看不登」。既然只看，就不该导航——否则会把用户从
# 正在看的页面踢回平台首页，名不副实。直接读当前窗口的标题判断。
if ($CheckOnly) {
    Log "=== [$($plat.name)] 检查当前页面登录态（不导航）" 'Cyan'
} else {
    Log "=== [$($plat.name)] 打开入口：$($plat.entry)" 'Cyan'
    $navOut = SS @('url', $plat.entry)
    if ($navOut -match '导航可能没生效') {
        Log "  入口页可能没打开：$navOut" 'Red'
        Log "  先跑一次 ocs-session.ps1 title 看当前在哪，或直接看浏览器。" 'Red'
    }
    Start-Sleep -Seconds 2   # url 动作内部已校验跳转，这里只留页面加载缓冲
}

$state = Get-LoginState $plat
$shotNow = SS @('shot', "state-$Platform")
$shotPath = ($shotNow -split "`n" | Where-Object { $_ -match '\.png' } | Select-Object -First 1)
Log "  当前标题：$($state.title)"
Log "  脚本粗判：$($state.state)（$($state.reason)）"
Log "  当前页面截图：$shotPath"

if ($CheckOnly) {
    $map = @{ 'loggedIn' = '已登录'; 'loggedOut' = '未登录'; 'unknown' = '判不了，看图确认' }
    Log "`n判定结果：$($map[$state.state])" 'Yellow'
    exit $(if ($state.state -eq 'loggedIn') { 0 } elseif ($state.state -eq 'loggedOut') { 1 } else { 3 })
}

if ($state.state -eq 'loggedIn' -and -not $Force) {
    Log "`n✓ 已登录，不需要登录。" 'Green'
    exit 0
}

if ($state.state -eq 'unknown' -and -not $Force) {
    # 首跑几乎一定落在登录页，而新 profile 的标题未必带「登录」字样，
    # 于是判成 unknown。这种情况下自动再打开一次登录页并走填表流程，
    # 而不是丢一句「加 -Force 重跑」让人白跑一趟。
    Log "`n判断不了登录态（首跑常见）。自动尝试走一遍登录流程..." 'Yellow'
    $Force = $true
}

if ($state.state -eq 'loggedOut' -and -not $Force) {
    Log "`n检测到未登录，继续走登录流程。" 'Yellow'
}

# ── 走登录流程 ──
if (-not $plat.loginUrl) { throw "$($plat.name) 没配 loginUrl，不知道去哪登录" }
if (-not $User -or -not $Pass) {
    throw "缺账号密码。用 -User/-Pass，或在 config.json 的 accounts.$Platform 里填。"
}

Log "`n=== 打开登录页：$($plat.loginUrl)" 'Cyan'
[void](SS @('url', $plat.loginUrl))
Start-Sleep -Seconds 2   # url 内部已轮询校验跳转

$layout = $null
if ($cfg -and $cfg.loginLayout -and $cfg.loginLayout.$Platform) { $layout = $cfg.loginLayout.$Platform }

if (-not $layout) {
    $shot = SS @('shot', "login-page-$Platform")
    $path = ($shot -split "`n" | Where-Object { $_ -match '\.png' } | Select-Object -First 1)
    Log "`n⚠ 这个平台还没标定登录表单位置。" 'Yellow'
    Log "  登录页截图：$path" 'Yellow'
    # 注意：这里必须整段用括号包住拼接结果。
    # 写成 Log 'xxx' + $Platform + 'yyy' 'Yellow' 会把 '+' 当成 -ForegroundColor 的参数，
    # 直接抛 ParameterBindingException，exit 2 永远执行不到（实测踩过）。
    Log "  请读这张图，量出下面几个点（相对页面 0~1 比例），写进 config.json：" 'Yellow'
    $skeleton = @()
    $skeleton += ('    "loginLayout": {')
    $skeleton += ('      "' + $Platform + '": {')
    $skeleton += '        "account":  { "x": …, "y": … },'
    $skeleton += '        "password": { "x": …, "y": … },   // 只在 useTabForPassword:false 时才用'
    $skeleton += '        "submit":   { "x": …, "y": … },'
    $skeleton += '        "agreement":{ "x": …, "y": … }    // 有协议勾选框才要，可省略'
    $skeleton += '      }'
    $skeleton += '    }'
    foreach ($ln in $skeleton) { Log $ln 'Yellow' }
    Log "  量完填进 config.json 再重跑本命令。" 'Yellow'
    exit 2
}

# 有布局：按顺序操作
function ClickStep([string]$name, $pos) {
    if (-not $pos) { return }
    Log "  点 $name ($($pos.x), $($pos.y))" 'DarkGray'
    [void](SS @('click', "$($pos.x)", "$($pos.y)"))
    Start-Sleep -Milliseconds 600
}

if ($layout.agreement) {
    Log "  勾选协议" 'DarkGray'
    ClickStep 'agreement' $layout.agreement
}

# 关键：点进输入框后必须先 Ctrl+A 全选。浏览器可能已经自动填充过账号密码，
# 直接粘贴会变成「原内容+新内容」拼接，导致「账号或密码错误」。
Log "  填账号" 'DarkGray'
ClickStep 'account' $layout.account
[void](SS @('key', 'ctrl+a'))
Start-Sleep -Milliseconds 200
[void](SS @('type', $User))
Start-Sleep -Milliseconds 500

# 密码框优先用 Tab 切换：点击第二个坐标容易失手落到别的控件上
# （实测出现过密码被填进账号框）。layout 里写 useTabForPassword:false 可强制用点击。
Log "  填密码" 'DarkGray'
$useTab = $true
if ($layout.PSObject.Properties.Name -contains 'useTabForPassword') { $useTab = [bool]$layout.useTabForPassword }
if ($useTab) {
    [void](SS @('key', 'tab'))
    Start-Sleep -Milliseconds 300
} else {
    ClickStep 'password' $layout.password
}
[void](SS @('key', 'ctrl+a'))
Start-Sleep -Milliseconds 200
[void](SS @('type', $Pass))
Start-Sleep -Milliseconds 500

Log "  提交" 'DarkGray'
ClickStep 'submit' $layout.submit
# 轮询等登录完成（最多 20s），代替固定睡 8 秒：成了早走，败了多等
$swSubmit = [Diagnostics.Stopwatch]::StartNew()
while ($swSubmit.Elapsed.TotalSeconds -lt 20) {
    Start-Sleep -Seconds 1
    $tNow = SS @('title')
    if ((Get-LoginStateFromTitle $tNow $plat).state -eq 'loggedIn') { break }
}

# ── 验证结果 ──
$after = Get-LoginState $plat
Log "`n=== 登录结果 ===" 'Cyan'
Log "  标题：$($after.title)"
# 别把 unknown 当成功。只有 loggedIn 才算真的登上；
# unknown 要显式提示「可能成了但没验证到」，让人去看图。
if ($after.state -eq 'loggedIn') {
    Log "  ✓ 登录成功" 'Green'
    $shot = SS @('shot', "login-done-$Platform")
    Log "  截图：$(($shot -split "`n" | Where-Object { $_ -match '\.png' }) -join '')"
    exit 0
} else {
    Log "  ✗ 仍未登录" 'Red'
    $shot = SS @('shot', "login-fail-$Platform")
    Log "  截图：$(($shot -split "`n" | Where-Object { $_ -match '\.png' }) -join '')"
    Log "  常见原因：账号密码错、需要验证码/滑块、布局坐标不准、页面加载慢" 'Yellow'
    exit 1
}
