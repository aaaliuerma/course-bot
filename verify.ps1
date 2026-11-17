#requires -Version 5.1
<#
  verify.ps1 — 盯进度 + 验收

  A 道没有 CDP，拿不到 DOM，所以验收靠三样东西：
    1. 定时截图（证据）
    2. 帧间像素差异（判断页面有没有在动 / 是不是卡死了）
    3. 截图交给 AI 目视判断（页面是「已完成」还是卡在某个弹窗）

  用法
    .\verify.ps1 -Shot                     # 拍一张当证据
    .\verify.ps1 -Diff a.png b.png         # 比较两张图的差异
    .\verify.ps1 -Watch                    # 每 60 秒拍一张，输出差异，最多 30 张
    .\verify.ps1 -Watch -Interval 30 -MaxShots 10
    .\verify.ps1 -Report                   # 汇总最近一次 watch 的结果

  产物
    shots\watch-<运行id>\001-<时间>.png ...
    shots\watch-<运行id>\watch.log
#>
[CmdletBinding()]
param(
    [switch]$Shot,
    [string]$Diff,   # 两个路径用逗号分隔
    [switch]$Watch,
    [int]$Interval = 60,
    [int]$MaxShots = 30,
    [switch]$Report,
    [double]$StillThreshold = 0.3,   # 差异低于这个百分比，认为页面没动（%）
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Session = Join-Path $script:Root 'ocs-session.ps1'
$script:ShotDir = Join-Path $script:Root 'shots'

Add-Type -AssemblyName System.Drawing

function Take-Shot([string]$Name) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Session shot $Name 2>&1 | Out-String
    $m = [regex]::Match($out, '([A-Z]:\\[^\r\n]+?\.png)')
    if (-not $m.Success) { throw "截图失败：$out" }
    return $m.Groups[1].Value.Trim()
}

# 采样比较：每 N 像素取一个点，够判断"有没有变"，比逐像素快几十倍
function Compare-Image([string]$PathA, [string]$PathB, [int]$Step = 4) {
    $a = [System.Drawing.Bitmap]::FromFile($PathA)
    $b = [System.Drawing.Bitmap]::FromFile($PathB)
    try {
        if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
            return [pscustomobject]@{
                sameSize = $false; changedPct = 100.0
                note = "尺寸不同（$($a.Width)x$($a.Height) vs $($b.Width)x$($b.Height)）"
            }
        }
        $total = 0; $changed = 0
        for ($y = 0; $y -lt $a.Height; $y += $Step) {
            for ($x = 0; $x -lt $a.Width; $x += $Step) {
                $total++
                $pa = $a.GetPixel($x, $y); $pb = $b.GetPixel($x, $y)
                # 通道差超过 12 才算变，滤掉抗锯齿/光标闪烁的噪声
                if ([Math]::Abs($pa.R - $pb.R) -gt 12 -or
                    [Math]::Abs($pa.G - $pb.G) -gt 12 -or
                    [Math]::Abs($pa.B - $pb.B) -gt 12) { $changed++ }
            }
        }
        $pct = if ($total -gt 0) { [math]::Round(100.0 * $changed / $total, 2) } else { 0 }
        return [pscustomobject]@{ sameSize = $true; changedPct = $pct; note = '' }
    }
    finally { $a.Dispose(); $b.Dispose() }
}

function Invoke-OneShot {
    $name = "shot-$(Get-Date -Format HHmmss)"
    $path = Take-Shot $name
    # 输出格式和 ocs-session.ps1 shot 保持一致（文件/尺寸/标题/时间），
    # 免得读日志的人要记住两套字段。
    $w = ''; $ht = ''; $title = ''
    try {
        Add-Type -AssemblyName System.Drawing
        $bmp = [System.Drawing.Image]::FromFile($path)
        $w = $bmp.Width; $ht = $bmp.Height
        $bmp.Dispose()
    } catch { }
    $t2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Session title 2>$null
    if ($t2) { $title = ($t2 -split "`n")[0].Trim() }

    "文件 : $path"
    if ($w) { "尺寸 : ${w}x${ht}" }
    if ($title) { "标题 : $title" }
    "时间 : $(Get-Date -Format 'HH:mm:ss')"
}

function Invoke-Diff([string[]]$Pair) {
    if (-not $Pair -or $Pair.Count -ne 2) { throw "用法：-Diff a.png,b.png（两个路径用逗号分隔）" }
    $r = Compare-Image $Pair[0] $Pair[1]
    [pscustomobject]@{
        图A       = $Pair[0]
        图B       = $Pair[1]
        尺寸一致  = $r.sameSize
        变化像素  = "$($r.changedPct) %"
        判断      = if ($r.changedPct -lt $StillThreshold) { '页面基本没动' } else { '页面有变化' }
        备注      = $r.note
    } | Format-List
}

function Invoke-Watch {
    if (-not $RunId) { $RunId = Get-Date -Format 'yyyyMMdd-HHmmss' }
    $dir = Join-Path $script:ShotDir "watch-$RunId"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = Join-Path $dir 'watch.log'

    "开始监控：每 ${Interval}s 一张，最多 $MaxShots 张" | Tee-Object -FilePath $log
    "输出目录：$dir`n" | Tee-Object -FilePath $log -Append

    $prev = $null
    $stillCount = 0
    for ($i = 1; $i -le $MaxShots; $i++) {
        $ts = Get-Date -Format 'HHmmss'
        $name = ("{0:D3}-{1}" -f $i, $ts)
        try {
            $path = Take-Shot $name
            # Take-Shot 存到 shots\，移进本次 watch 目录
            $dest = Join-Path $dir (Split-Path $path -Leaf)
            if ($path -ne $dest) { Move-Item $path $dest -Force }
        } catch {
            "第 $i 张截图失败：$($_.Exception.Message)" | Tee-Object -FilePath $log -Append
            Start-Sleep -Seconds $Interval
            continue
        }

        $line = "第 $i 张：$dest"
        if ($prev) {
            $d = Compare-Image $prev $dest
            $line += "  差异 $($d.changedPct)%"
            if ($d.changedPct -lt $StillThreshold) {
                $stillCount++
                $line += "  ⚠连续静止 $stillCount 次"
            } else {
                $stillCount = 0
            }
        }
        $line | Tee-Object -FilePath $log -Append
        $prev = $dest

        # 连续 3 次没动 → 可能卡死了，提前结束并提示
        if ($stillCount -ge 3) {
            "`n⚠ 连续 3 次画面无变化，可能卡住了。请读最新截图确认。" | Tee-Object -FilePath $log -Append
            break
        }
        if ($i -lt $MaxShots) { Start-Sleep -Seconds $Interval }
    }

    "`n监控结束。截图与日志：$dir" | Tee-Object -FilePath $log -Append
    "下一步：读最后一张截图，判断任务是否完成；重点看有没有「已完成/已提交」或卡在弹窗上。" | Tee-Object -FilePath $log -Append
}

function Invoke-Report {
    $runs = Get-ChildItem $script:ShotDir -Directory -Filter 'watch-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if (-not $runs) { "还没有任何 watch 记录。先跑 .\verify.ps1 -Watch" ; return }
    $r = $runs | Select-Object -First 1
    $log = Join-Path $r.FullName 'watch.log'
    $shots = @(Get-ChildItem $r.FullName -Filter '*.png' | Sort-Object Name)
    "=== 最近一次监控：$($r.Name) ==="
    "截图 $($shots.Count) 张，目录 $($r.FullName)"
    if ($shots.Count -ge 2) {
        $first = $shots[0].FullName
        $last = $shots[-1].FullName
        $d = Compare-Image $first $last
        "首尾差异：$($d.changedPct) %"
    }
    "最新截图：$(if($shots.Count){$shots[-1].FullName}else{'无'})"
    if (Test-Path $log) {
        ""
        "--- 日志 ---"
        Get-Content $log -Encoding UTF8
    }
}

if ($Shot) { Invoke-OneShot; return }
if ($Diff) {
    $pair = $Diff -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    Invoke-Diff $pair
    return
}
if ($Watch) { Invoke-Watch; return }
if ($Report) { Invoke-Report; return }

Write-Host "用法：-Shot | -Diff a.png,b.png | -Watch [-Interval 60 -MaxShots 30] | -Report"
