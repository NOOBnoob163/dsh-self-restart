# 实测：状态窗在**亮色/暗色**、**可点/禁用**四种组合下的**文字可读性**（对比度）。
#
# 为什么要有这一套（2026-10-10 实测反馈，血泪）：
#   反馈原话：「变灰的时候，因为是白底白字，辨识度好像很差」。
#   一测吓一跳：**白底白字，对比度 1.00:1，等于什么都没有**。
#
#   两个连环坑，都不是"没设颜色"那么简单：
#     ① WPF 按钮的**内置禁用样式会覆盖**我们设的 Background/Foreground
#        → 禁用时被它画成浅底 + 极浅的字。
#     ② 更阴的是：**局部设的值优先级高于模板触发器** ——
#        我写好"禁用配色"之后按钮**仍然没变**，因为按钮本体上设的
#        Background/Foreground（局部值）把触发器压住了。
#        症状是"我明明设了灰色，量出来还是原色"，只能靠**采样像素**才发现。
#
#   所以本测试**不靠读代码、不靠肉眼看截图**，而是：
#     把窗口渲染出来 → 截图 → 采样按钮区域的真实像素 → 按 WCAG 算对比度。
#   这也正是当初唯一能发现这个 bug 的办法（肉眼看代码是完全正确的）。
#
# 亮度口径用 WCAG 相对亮度；正文阈值 4.5:1、大字 3.0:1。
# 不碰真 DSH：窗口由测试自己的进程建；跑完核对真 DSH 监听者 PID 没变。
# 用法：powershell -NoProfile -File test-window-contrast.ps1
$ErrorActionPreference = 'Stop'

$mod    = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-contrast-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# 清掉以前留下的测试窗口进程（它们会盖住这一轮的窗口导致采样错）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and ($_.CommandLine -match 'selfrestart-contrast-') -and ($_.CommandLine -notmatch [regex]::Escape($tmpDir)) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400

function Start-Detached([string]$cmdline) {
  $a = @{ CommandLine = $cmdline }
  try { $a.ProcessStartupInformation = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 } } catch { }
  return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a
}

# ── 采样+对比度工具（本进程用，不依赖窗口）──────────────────────────────────
Add-Type -AssemblyName System.Drawing
function Get-Lum([System.Drawing.Color]$c) {
  $f = { param($v) $s = $v / 255.0; if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow((($s + 0.055) / 1.055), 2.4) } }
  return 0.2126 * (& $f $c.R) + 0.7152 * (& $f $c.G) + 0.0722 * (& $f $c.B)
}
function Get-Contrast([System.Drawing.Color]$a, [System.Drawing.Color]$b) {
  $la = Get-Lum $a; $lb = Get-Lum $b
  $hi = [Math]::Max($la, $lb); $lo = [Math]::Min($la, $lb)
  return ($hi + 0.05) / ($lo + 0.05)
}

# ── 探针脚本：按给定"主题 + 按钮状态"渲染窗口并截图 ─────────────────────────
$app = Join-Path $tmpDir 'app.ps1'
@'
param([string]$Mod, [string]$InfoFile, [string]$PngFile, [string]$Mode, [string]$Theme)
$ErrorActionPreference = 'Stop'
function N([string]$t) { Add-Content -LiteralPath $InfoFile -Value $t -Encoding UTF8 }

# 测亮色时**临时改注册表**是不行的（会影响用户系统）——
# 改成：让模块自己读到的值受一个环境变量控制（只测试用）。
if ($Theme -eq 'light') { $env:DSH_RW_FORCE_LIGHT = '1' } else { Remove-Item Env:\DSH_RW_FORCE_LIGHT -ErrorAction SilentlyContinue }
# ★ 把窗口摆到**左上角**，别和 restart-window 那套挤在右下角 ——
#   两套都会开窗口，位置相同就会互相盖住、采样到别人的像素（实测全量跑时踩到：
#   一套报 20/23、一套报 6/9，单独跑却都是满分）。
$env:DSH_RW_TEST_POS = 'topleft'
# ★ 2026-10-11：让窗口标题带「【测试】」前缀。
#   为什么：用户跑测试时在屏幕上看到两个写着「DSH 正在自我重启 / 正在关闭 DSH」的窗口，
#   以为自己的 DSH 出事了 —— 其实那是这两套测试画的假窗口。
#   这两套测试**必须**显示真窗口（要验响应性/对比度/拖动），所以只能靠标题区分。
$env:DSH_RW_TEST_MODE = '1'

. $Mod
$null = Show-RestartWindow -Port 19387 -Reason '对比度实测' -LogFile (Join-Path (Split-Path $InfoFile) 'win.log') -CancelFile (Join-Path (Split-Path $InfoFile) 'c.flag')
Set-RestartWindowStage -Stage 'closing' -Detail '正在关闭 DSH（此时按钮已被禁用）' -EtaText '接下来十几秒 DSH 会消失一下'
Start-Sleep -Seconds 1
if ($Mode -eq 'disabled') { Disarm-RestartWindowAbort }
Start-Sleep -Seconds 2

N ("TOPL=" + (Get-RestartWindowTopLeft))
N ("BTN=" + (Get-RestartWindowAbortButtonPos))

Add-Type -AssemblyName System.Drawing
$topl = (Get-RestartWindowTopLeft) -split ','
$wx = [int]$topl[0]; $wy = [int]$topl[1]
$pad = 20
$sx = [Math]::Max(0, $wx - $pad); $sy = [Math]::Max(0, $wy - $pad)
$sw = 780; $sh = 320
$bmp = New-Object System.Drawing.Bitmap($sw, $sh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size($sw, $sh)))
$g.Dispose()
$bmp.Save($PngFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
N ("ORIGIN=$sx,$sy")
N 'READY=1'
Start-Sleep -Seconds 4
Close-RestartWindow -KeepSeconds 0
'@ | Set-Content -LiteralPath $app -Encoding UTF8

function Measure-Case([string]$theme, [string]$mode) {
  $tag  = "$theme-$mode"
  $info = Join-Path $tmpDir "info-$tag.txt"
  $png  = Join-Path $tmpDir "$tag.png"
  [void](Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Mod "{2}" -InfoFile "{3}" -PngFile "{4}" -Mode {5} -Theme {6}' -f $psExe, $app, $mod, $info, $png, $mode, $theme))
  $deadline = (Get-Date).AddSeconds(25)
  while ((Get-Date) -lt $deadline) {
    if ((Test-Path $info) -and ((Get-Content $info -Raw -Encoding UTF8 -Encoding UTF8) -match 'READY=1')) { break }
    Start-Sleep -Milliseconds 350
  }
  Start-Sleep -Seconds 5   # 等截图那一步落盘

  if (-not (Test-Path $png)) { return $null }
  $meta = @(Get-Content -LiteralPath $info -Encoding UTF8)
  $txt = $meta -join "`n"
  $btn = [regex]::Match($txt, 'BTN=(\d+),(\d+)')
  $org = [regex]::Match($txt, 'ORIGIN=(-?\d+),(-?\d+)')
  if (-not $btn.Success -or -not $org.Success) { return $null }
  $lx = [int]$btn.Groups[1].Value - [int]$org.Groups[1].Value
  $ly = [int]$btn.Groups[2].Value - [int]$org.Groups[2].Value

  $bmp = [System.Drawing.Bitmap]::FromFile($png)
  if ($lx -lt 60 -or $ly -lt 20 -or $lx -ge ($bmp.Width - 60) -or $ly -ge ($bmp.Height - 20)) {
    # 按钮不在图内：把采样区域夹回图内（仍能取到按钮局部）
    $lx = [Math]::Min([Math]::Max(60, $lx), $bmp.Width - 60)
    $ly = [Math]::Min([Math]::Max(20, $ly), $bmp.Height - 20)
  }

  $counts = @{}
  $best = -1.0; $bg = $null; $fg = $null
  for ($y = $ly - 13; $y -le $ly + 13; $y++) {
    for ($x = $lx - 70; $x -le $lx + 70; $x++) {
      if ($x -lt 0 -or $y -lt 0 -or $x -ge $bmp.Width -or $y -ge $bmp.Height) { continue }
      $c = $bmp.GetPixel($x, $y)
      $k = '{0},{1},{2}' -f $c.R, $c.G, $c.B
      if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
    }
  }
  # 出现最多的 = 底色；与底色对比度最大的 = 文字（取"最像文字"的那个）
  $top = $counts.GetEnumerator() | Sort-Object Value -Descending
  $bgKey = $top[0].Key
  $b = $bgKey -split ','
  $bg = [System.Drawing.Color]::FromArgb(255, [int]$b[0], [int]$b[1], [int]$b[2])
  foreach ($kv in $counts.GetEnumerator()) {
    $p = $kv.Key -split ','
    $c = [System.Drawing.Color]::FromArgb(255, [int]$p[0], [int]$p[1], [int]$p[2])
    $cr = Get-Contrast $bg $c
    # 只把"占比≥0.2% 且颜色明显不同于底色"的当作文字候选，避免把抗锯齿噪点当文字
    if ($kv.Value -ge ($counts.Values | Measure-Object -Sum).Sum * 0.002 -and $cr -gt $best) { $best = $cr; $fg = $c }
  }
  $bmp.Dispose()
  return [pscustomobject]@{ Tag=$tag; Png=$png; Bg=$bg; Fg=$fg; Contrast=$best; Top=$top }
}

Write-Host "── 四种组合，量按钮文字对比度 ──"
$cases = @()
foreach ($theme in @('dark','light')) {
  foreach ($mode in @('armed','disabled')) {
    $r = Measure-Case $theme $mode
    if ($null -eq $r) { Check "$theme / $mode 能量到" $false '窗口没起来或截图失败'; continue }
    $cases += $r
    $pass = $r.Contrast -ge 4.5
    Write-Host ("   {0,-16} 底 RGB({1},{2},{3})  文字 RGB({4},{5},{6})  对比度 {7:N2}:1" -f `
      $r.Tag, $r.Bg.R, $r.Bg.G, $r.Bg.B, $r.Fg.R, $r.Fg.G, $r.Fg.B, $r.Contrast)
    Check "★ $($r.Tag)：文字读得清（对比度 ≥ 4.5:1）" $pass ('{0:N2}:1' -f $r.Contrast)
  }
}

# ★ 最关键的一条：**禁用态绝不能是"白底白字"**（用户报的就是这个）
$disabled = @($cases | Where-Object { $_.Tag -like '*-disabled' })
foreach ($d in $disabled) {
  Check "★ $($d.Tag)：禁用时**不是**白底白字（对比度 > 2:1）" ($d.Contrast -gt 2.0) ('{0:N2}:1' -f $d.Contrast)
}
# 禁用态与可点态**要能区分**（否则用户不知道能不能点）
if ($cases.Count -eq 4) {
  foreach ($theme in @('dark','light')) {
    $a = $cases | Where-Object { $_.Tag -eq "$theme-armed" } | Select-Object -First 1
    $dd = $cases | Where-Object { $_.Tag -eq "$theme-disabled" } | Select-Object -First 1
    if ($a -and $dd) {
      # ⚠️ 只比"底色亮度差"是不够的：暗色第一版底色只差 0.009，但**文字**从 236 灰到 154，
      #    用户其实是靠"字变灰"看出来的。所以两边都比（底 or 字任一明显不同即算可区分）。
      $bgDiff = [Math]::Abs((Get-Lum $a.Bg) - (Get-Lum $dd.Bg))
      $fgDiff = [Math]::Abs((Get-Lum $a.Fg) - (Get-Lum $dd.Fg))
      $visible = ($bgDiff -gt 0.02) -or ($fgDiff -gt 0.06)
      Check "★ $theme：可点/禁用两态**看得出区别**（底或字有明显变化）" $visible ('底色亮度差 {0:N3}；文字亮度差 {1:N3}' -f $bgDiff, $fgDiff)
    }
  }
}

# ── 收尾 ───────────────────────────────────────────────────────────────────
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $tmpDir + '*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n截图留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
