# ============================================================================
#  窗口"不蹦"的行为验证（2026-10-13）
#
#
#
#  病根：原来是 `Show()` 之后才 Set 长文字 → 窗口**先矮后高**，看着就是蹦一下。
#  修法：首屏内容当参数传进 Start()，在建控件时就赋值 → 第一次出现即最终尺寸。
#
#  判据（行为层，不是看代码）：
#     **窗口第一次能被量到时的高度 == 内容稳定后的高度**  ⇒ 说明它没在出现之后长过。
#
#  ⚠️ 为什么必须单独测这一条：
#     static-sanity 那两条断言只证明"代码结构对"（Start 带了首屏内容），
#     证明不了"窗口真的没有先矮后高"。**结构对 ≠ 行为对**——这正是本仓反复强调的。
#     而且第一版窗口就是因为"只读代码没量坐标"才把窗口摆到了屏幕外。
# ============================================================================
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check($n, $ok, $d) {
  if ($ok) { $script:pass++; Write-Host ('  [OK] ' + $n) }
  else { Write-Host ('  [NG] ' + $n + '   ' + $d); $script:fail++ }
}

$winMod = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path

Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Write-Host ('屏幕工作区(物理): ' + $wa.Width + 'x' + $wa.Height)

# 把窗口模块点源进来（和另外几套窗口测试同一手法；它自带 Show-RestartWindow）
. $winMod
$env:DSH_RW_TEST_MODE = '1'
if (-not (Initialize-DshRwType)) { Write-Host '  [SKIP] 窗口类型没编译出来'; exit 0 }

# 用一段**足够长的 reason**（复现用户看到的"长一截"）
$longReason = ('这是一段很长的重启原因，用来把窗口撑高，复现"先矮后高蹦一下"的场景。' * 12)
$logPath = Join-Path $env:TEMP ('rw-firstpaint-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.log')

Write-Host ''
Write-Host '=== 用带长 reason 的 Show-RestartWindow 开窗（这就是真实路径）===' -ForegroundColor Cyan
$ok = $false
try {
  $ok = Show-RestartWindow -Port 19387 -Reason $longReason -LogFile $logPath
} catch {
  Write-Host ('  Show-RestartWindow 抛错: ' + $_.Exception.Message)
}
Check '窗口起得来（真实入口）' $ok ('返回 ' + $ok)
if (-not $ok) { exit 1 }

# ── 量第一次能看到的矩形（Start 已返回=窗口已 Loaded，这是"首次出现"的最早可量时刻）
$first = $null
try {
  $s = $script:DshRw.WindowRect()
  if ($s) { $p = $s -split ','; $first = @{ T = [int]$p[1]; B = [int]$p[3] } }
} catch { }
Write-Host ('  首次量到: ' + $(if ($first) { 'T=' + $first.T + ' B=' + $first.B + ' 高=' + ($first.B - $first.T) } else { '(拿不到)' }))

# ── 等它彻底稳定，再量一次
function Get-TB($w) {
  try { $s = $w.WindowRect(); if (-not $s) { return $null }; $p = $s -split ','; return @{ T = [int]$p[1]; B = [int]$p[3] } } catch { return $null }
}
$prev = $null; $stable = 0; $settled = $null
$deadline = (Get-Date).AddSeconds(4)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 100
  $cur = Get-TB $script:DshRw
  if (-not $cur) { continue }
  if ($prev -and $prev.T -eq $cur.T -and $prev.B -eq $cur.B) { $stable++; if ($stable -ge 3) { $settled = $cur; break } }
  else { $stable = 0 }
  $prev = $cur
}
if (-not $settled) { $settled = $prev }
Write-Host ('  稳定后:   ' + $(if ($settled) { 'T=' + $settled.T + ' B=' + $settled.B + ' 高=' + ($settled.B - $settled.T) } else { '(拿不到)' }))

Write-Host ''
Write-Host '=== 用量窗口**自己记录的**首次渲染高度（外部量不到"首次"，见下）===' -ForegroundColor Cyan
# ⚠️⚠️ 这里踩过一个坑，写下来免得下次重犯：
#   第一版测试是在 `Show-RestartWindow` 返回后才第一次量窗口 —— **那是假绿**。
#   因为老写法的 `Set()` 就在 Start 返回后**立刻**执行，等外部去量时它早就是最终高度了。
#   实测确认：把 Start 改回"不带首屏内容"，那条测试照样 3/3 通过（**改坏也不报红**）。
#   正确做法：窗口自己在 ContentRendered 那一刻记下高度 → 外部只读那个值来比。
$firstPaint = 0.0
try { $firstPaint = [double]$script:DshRw.FirstPaintHeight } catch { }
$loadedH = 0.0
try { $loadedH = [double]$script:DshRw.LoadedHeight } catch { }
$loadedChars = 0
try { $loadedChars = [int]$script:DshRw.LoadedDetailChars } catch { }

# ⚠️ 判据为什么用 **LoadedHeight**（两轮踩坑换来的，别改回去）：
#   目标是证明"窗口第一次出现时，首屏长文字**已经填好了**"（= 不蹦）。
#   · 在**外面**量 → 不准：Start 返回时窗口已显示，外部量到的常是最终高度 → 假绿。
#   · 用 **ContentRendered** → 也不行：`Set()` 走 BeginInvoke(Normal)，优先级**高于渲染**，
#     老写法下内容更新先于首次渲染被处理 → 量到的仍是最终高度（实测 409.2）→ 假绿。
#   · 用 **Loaded** → 对：它在 `Start()` 返回**之前**触发，而老写法的 `Set()` 在返回**之后**，
#     两者天然错开 → 新写法此刻已填好（详情非空、高度=最终），老写法此刻是矮的（详情为空）。
$finalLogical = 0.0
$prevH = -1.0; $stableH = 0
$deadlineH = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $deadlineH) {
  Start-Sleep -Milliseconds 120
  $curH = 0.0
  try { $curH = [double]$script:DshRw.HeightNow() } catch { }
  if ($curH -le 0) { continue }
  if ([math]::Abs($curH - $prevH) -lt 0.5) {
    $stableH++
    if ($stableH -ge 4) { $finalLogical = $curH; break }
  } else { $stableH = 0 }
  $prevH = $curH
}
if ($finalLogical -le 0) { $finalLogical = $curH }

Write-Host ('  Loaded 时刻高度(逻辑单位):     ' + [math]::Round($loadedH, 1))
Write-Host ('  Loaded 时刻详情字符数:        ' + $loadedChars + '   （0 = 首屏详情还没填 = 老写法）')
Write-Host ('  首次渲染高度(诊断用):          ' + [math]::Round($firstPaint, 1))
Write-Host ('  稳定后高度(逻辑单位):          ' + [math]::Round($finalLogical, 1))

Write-Host ''
if ($loadedH -gt 0 -and $finalLogical -gt 0) {
  $grewLogical = $finalLogical - $loadedH
  Write-Host ('  Loaded → 最终 的高度差(逻辑单位): ' + [math]::Round($grewLogical, 1))
  Check '★★ 首屏详情在显示前就填好了（Loaded 时刻非空）' ($loadedChars -gt 0) `
    ('Loaded 时详情字符数=' + $loadedChars + '（0 = 内容是在显示之后才补的 = 会用"蹦"的方式出现）')
  Check '★★ Loaded 时刻已是最终高度（差 ≤2 逻辑单位 = 没蹦）' `
    ([math]::Abs($grewLogical) -le 2) `
    ('差 ' + [math]::Round($grewLogical, 1) + ' —— 窗口出现之后又长过（正是"蹦一下"）')
  if ($settled) { Check '★ 窗口在屏幕内（底边不越界）' ($settled.B -le $wa.Bottom + 2) ('B=' + $settled.B + ' vs ' + $wa.Bottom) }
} else {
  Check '窗口自记了 Loaded 高度' ($loadedH -gt 0) ('LoadedHeight=' + $loadedH)
  Check '能读到最终高度' ($finalLogical -gt 0) ('final=' + $finalLogical)
}

# 收尾
try { Close-RestartWindow } catch { }
Start-Sleep -Milliseconds 300
Remove-Item $logPath -Force -ErrorAction SilentlyContinue
Remove-Item Env:\DSH_RW_TEST_MODE -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('===== 汇总：' + $pass + '/' + ($pass + $fail) + ' 通过 =====')
if ($fail -gt 0) { exit 1 } else { exit 0 }
