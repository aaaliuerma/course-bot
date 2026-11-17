#requires -Version 5.1
<#
  install-deps.ps1 — 首次运行用的依赖安装器

  职责：检测 → 下载 → 静默安装 → 验证
  不负责：ZError 的题库 API Key（要用户自己去模型平台申请）、QQ 机器人接入

  用法
    .\install-deps.ps1 check           # 只检测，不安装
    .\install-deps.ps1 all             # 装 OCS + ZError
    .\install-deps.ps1 ocs             # 只装 OCS
    .\install-deps.ps1 zerror          # 只装 ZError
    .\install-deps.ps1 all -Version ocs=2.9.24   # 指定版本
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'all', 'ocs', 'zerror')]
    [string]$Action = 'check',

    [string[]]$Version = @(),   # 形如 ocs=3.9.1 zerror=2.2.5

    [string]$DownloadDir = "$env:TEMP\dsh-ocs-setup"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repos = @{
    ocs    = 'ocsjs/ocs-desktop'
    zerror = 'Miaozeqiu/ZError'
}

$DisplayNames = @{
    ocs    = 'OCS Desktop'
    zerror = 'ZError'
}

# 锁定版本：不装「最新」，装实测可用的版本。
# 3.9.1 的 Electron 暴露了无障碍树，脚本用 UIA 按名字定位按钮，不依赖像素坐标；
# 2.x 只能靠坐标，所以钉在 3.x 更省事。
# 想换版本：.\install-deps.ps1 ocs -Version ocs=<版本号>
$Pinned = @{
    ocs    = '3.9.1'    # 3.x 起 Electron 暴露无障碍树，可用 UIA 精确定位按钮
    zerror = '2.2.5'    # GitHub 上最新
}

# ───────────────── 已安装检测 ─────────────────
function Get-Installed([string]$Key) {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $pattern = if ($Key -eq 'ocs') { 'OCS Desktop' } else { '^ZError' }
    $reg = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match $pattern } | Select-Object -First 1
    if ($reg) {
        return [pscustomobject]@{
            installed = $true
            name      = $reg.DisplayName
            version   = $reg.DisplayVersion
            location  = ($reg.InstallLocation -replace '"', '')
        }
    }
    return [pscustomobject]@{ installed = $false; name = $null; version = $null; location = $null }
}

# ───────────────── 查最新版 ─────────────────
function Get-LatestRelease([string]$Key) {
    $repo = $Repos[$Key]
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 25 `
            -Headers @{ 'User-Agent' = 'dsh-ocs-setup' }
    } catch {
        throw "查询 $repo 最新版失败（网络问题？）：$($_.Exception.Message)"
    }
    $tag = $r.tag_name -replace '^v', ''
    $asset = $r.assets | Where-Object { $_.name -match 'win.*x64.*\.exe$' -or $_.name -match '^ZError_Setup_.*\.exe$' } |
             Select-Object -First 1
    if (-not $asset) { throw "$repo 的 $tag 里没找到 Windows 安装包" }
    return [pscustomobject]@{
        version = $tag
        url     = $asset.browser_download_url
        sizeMB  = [math]::Round($asset.size / 1MB, 1)
        name    = $asset.name
    }
}

function Get-RequestedVersion([string]$Key) {
    foreach ($v in $Version) {
        $kv = $v -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $Key) { return $kv[1].Trim() }
    }
    return $null
}

function Get-ReleaseByVersion([string]$Key, [string]$Ver) {
    $repo = $Repos[$Key]
    # tag 有的带 v 前缀有的不带（v2.12.0 带、2.9.33 不带），两种都试
    $r = $null
    foreach ($tag in @("v$Ver", $Ver)) {
        try {
            $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/$tag" -TimeoutSec 25 `
                -Headers @{ 'User-Agent' = 'dsh-ocs-setup' }
            break
        } catch { }
    }
    if (-not $r) { throw "$repo 上找不到 tag v$Ver 或 $Ver" }
    $asset = $r.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw "$repo v$Ver 里没有 exe" }
    return [pscustomobject]@{
        version = $Ver
        url     = $asset.browser_download_url
        sizeMB  = [math]::Round($asset.size / 1MB, 1)
        name    = $asset.name
    }
}

# ───────────────── 下载 ─────────────────
# GitHub 的文件下载域名（objects.githubusercontent.com）在国内多数网络不可达，
# 但 api.github.com 往往能通。所以查询用官方 API、下载走镜像兜底。
$Mirrors = @(
    '',
    'https://ghproxy.net/',
    'https://gh-proxy.com/',
    'https://ghfast.top/'
)

function Save-Installer($Release, [string]$Key) {
    if (-not (Test-Path $DownloadDir)) { New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null }
    $dest = Join-Path $DownloadDir $Release.name
    # 完整性按 release 声明的大小校验（±2%），不再用「>5MB 就算完整」——
    # 旧判断会把下到一半的残包当完整包直接静默安装。
    $expected = [long]($Release.sizeMB * 1MB)
    $minOk = if ($expected -gt 0) { [long]($expected * 0.98) } else { 5MB }
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -ge $minOk)) {
        Write-Host "  已有完整安装包，跳过下载：$dest" -ForegroundColor DarkGray
        return $dest
    }
    if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }   # 残包删掉重下
    Write-Host "  下载 $($Release.name)（$($Release.sizeMB) MB）..." -ForegroundColor Cyan

    # 下载源优先级：OCS 官方 CDN（国内一般可直连，不经第三方镜像）→ 直连 GitHub → 镜像兜底
    $sources = @()
    if ($Key -eq 'ocs') {
        $sources += @{ url = "https://cdn.ocsjs.com/app/download/$($Release.name)"; label = 'OCS 官方 CDN' }
    }
    $sources += @{ url = $Release.url; label = '直连 GitHub' }
    foreach ($m in $Mirrors) {
        if ($m) { $sources += @{ url = ($m + $Release.url); label = $m.TrimEnd('/') } }
    }

    foreach ($s in $sources) {
        try {
            Write-Host "    试 $($s.label) ..." -ForegroundColor DarkGray
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest $s.url -OutFile $dest -TimeoutSec 1800 -UseBasicParsing
            if ((Test-Path $dest) -and (Get-Item $dest).Length -ge $minOk) {
                $mb = [math]::Round((Get-Item $dest).Length / 1MB, 1)
                Write-Host "    成功：$mb MB，用时 $([math]::Round($sw.Elapsed.TotalSeconds))s" -ForegroundColor Green
                return $dest
            }
            Write-Host "    文件不完整（期望约 $($Release.sizeMB) MB），换下一个源" -ForegroundColor DarkGray
        } catch {
            Write-Host "    失败：$(($_.Exception.Message -split "`n")[0])" -ForegroundColor DarkGray
        }
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
    }
    throw "所有下载源都失败了。可以手动下载后放到：$DownloadDir"
}

# ───────────────── 安装 ─────────────────
function Install-Package([string]$Key, $Release, [string]$InstallerPath) {
    # 装前验数字签名：第三方镜像下载的包理论上可能被调包，至少把签名状态亮出来
    $sig = Get-AuthenticodeSignature $InstallerPath
    if ($sig.Status -eq 'Valid') {
        Write-Host "  签名有效：$($sig.SignerCertificate.Subject)" -ForegroundColor DarkGray
    } else {
        Write-Host "  ⚠ 安装包签名状态：$($sig.Status)（签名者：$(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '无' })）" -ForegroundColor Yellow
        Write-Host "    镜像来源的包建议先手动核对来源再装；继续静默安装..." -ForegroundColor Yellow
    }
    Write-Host "  静默安装（NSIS /S）..." -ForegroundColor Cyan
    $p = Start-Process -FilePath $InstallerPath -ArgumentList '/S' -PassThru -Wait -ErrorAction Stop
    Write-Host "  安装进程退出码：$($p.ExitCode)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 3

    $now = Get-Installed $Key
    if ($now.installed) {
        Write-Host "  ✓ $($now.name) $($now.version)" -ForegroundColor Green
        return $true
    }
    Write-Host "  ✗ 安装后没检测到注册表记录" -ForegroundColor Red
    Write-Host "    可能原因：静默参数不被支持、被安全软件拦截、或需要管理员权限" -ForegroundColor Yellow
    Write-Host "    兜底：手动运行 $InstallerPath" -ForegroundColor Yellow
    return $false
}

# ───────────────── 主流程 ─────────────────
function Invoke-Check {
    Write-Host "=== 当前安装状态 ===" -ForegroundColor Cyan
    foreach ($k in @('ocs', 'zerror')) {
        $i = Get-Installed $k
        if ($i.installed) {
            "  {0,-12} 已装  版本 {1}" -f $DisplayNames[$k], $i.version
        } else {
            "  {0,-12} 未装" -f $DisplayNames[$k]
        }
    }
    Write-Host "`n=== 版本对照 ===" -ForegroundColor Cyan
    foreach ($k in @('ocs', 'zerror')) {
        $pin = $Pinned[$k]
        try {
            $latest = (Get-LatestRelease $k).version
            "  {0,-12} 将安装 {1}（锁定）   上游最新 {2}" -f $DisplayNames[$k], $pin, $latest
        } catch {
            "  {0,-12} 将安装 {1}（锁定）   最新版查询失败" -f $DisplayNames[$k], $pin
        }
    }
}

function Invoke-Install([string[]]$Keys) {
    foreach ($k in $Keys) {
        Write-Host "`n=== $($DisplayNames[$k]) ===" -ForegroundColor Cyan
        $cur = Get-Installed $k
        if ($cur.installed) {
            Write-Host "  已安装：$($cur.version)，跳过" -ForegroundColor Green
            continue
        }
        $want = Get-RequestedVersion $k
        if (-not $want) { $want = $Pinned[$k] }
        $rel = Get-ReleaseByVersion $k $want
        Write-Host "  目标版本：$($rel.version)（锁定版，非最新）" -ForegroundColor DarkGray
        $path = Save-Installer $rel $k
        [void](Install-Package $k $rel $path)
    }

    Write-Host "`n=== 安装后复核 ===" -ForegroundColor Cyan
    Invoke-Check

    Write-Host "`n=== 还需要你手动做的 ===" -ForegroundColor Yellow
    Write-Host "  1. ZError：打开它，进入『设置 → 模型配置』填 AI 平台的 API Key" -ForegroundColor Yellow
    Write-Host "     （阿里云百炼 / 智谱 / DeepSeek 任选，需要你自己去平台注册拿 Key）" -ForegroundColor Yellow
    Write-Host "  2. OCS：首次打开它会让你初始化，按提示走完，然后新建一个浏览器" -ForegroundColor Yellow
    Write-Host "  3. OCS 里那个浏览器要手动登录一次各网课平台（之后靠 cookie 免登录）" -ForegroundColor Yellow
}

switch ($Action) {
    'check'  { Invoke-Check }
    'all'    { Invoke-Install @('ocs', 'zerror') }
    'ocs'    { Invoke-Install @('ocs') }
    'zerror' { Invoke-Install @('zerror') }
}
