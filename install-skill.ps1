#requires -Version 5.1
<#
  install-skill.ps1 — 把 SKILL.md 注册成 DSH 技能（ocs-course-bot）

  原理：复制本仓库 SKILL.md 到 DSH_HOME\skills\ocs-course-bot\SKILL.md。
  注册后，任何 DSH 会话（包括 QQ/微信 IM 机器人）里用户说「帮我做网课作业/刷课」，
  agent 会按描述自动路由到本技能，照 SKILL.md 干活。

  DSH_HOME 取值：环境变量 DSH_HOME 优先，否则默认 ~/.dsh。

  用法
    .\install-skill.ps1           # 注册；已注册且内容一致则跳过
    .\install-skill.ps1 -Force    # 仓库版本覆盖已注册版本（升级技能时用）

  注意：会话模型必须支持图像输入——技能核心循环是读截图。
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $root 'SKILL.md'
if (-not (Test-Path $src)) { throw "找不到 SKILL.md：$src" }

# 注意：PowerShell 里 $HOME 是只读自动变量，这里用 $dshHome
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$destDir = Join-Path $dshHome 'skills\ocs-course-bot'
$dest = Join-Path $destDir 'SKILL.md'

if ((Test-Path $dest) -and -not $Force) {
    $a = Get-Content $src -Raw -Encoding UTF8
    $b = Get-Content $dest -Raw -Encoding UTF8
    if ($a -eq $b) {
        Write-Host "✓ 技能已注册且与仓库版本一致：$dest" -ForegroundColor Green
        exit 0
    }
    Write-Host "已注册的技能与仓库版本不同。" -ForegroundColor Yellow
    Write-Host "  已注册：$dest" -ForegroundColor Yellow
    Write-Host "  要更新成仓库版本：.\install-skill.ps1 -Force" -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Copy-Item $src $dest -Force
Write-Host "✓ 已注册 DSH 技能：$dest" -ForegroundColor Green
Write-Host "  新会话里说「帮我做网课作业/刷课」即自动路由到本技能。" -ForegroundColor DarkGray
Write-Host "  提醒：会话模型必须支持图像输入（技能靠读截图工作）。" -ForegroundColor Yellow