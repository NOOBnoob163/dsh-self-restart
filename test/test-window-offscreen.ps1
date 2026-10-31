# ============================================================================
#  窗口越界修复 —— 实测验收（2026-10-13）
#
#  用户原话："右下角那个窗口，正常启动以后它会展开嘛？展开以后，
#  会有一部分到屏幕外被挡到看不见。"
#
#  病根：窗口 SizeToContent=Height（内容多高就长多高），而摆位用**写死的估算高度**
#        （logicalBottom - 170 - 110）→ 内容一变长就从那个固定顶边往下长，长出屏幕。
#
#  本测试**真开窗口、喂超长内容、量真实坐标**（用窗口新暴露的 WindowRect，物理像素），
#  判据只有一条：**底边不许越出屏幕工作区**。
# ============================================================================
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check($name, $ok, $detail) {
  if ($ok) { $script:pass++; Write-Host ('  [OK] ' + $name) }
  else { $script:fail++; Write-Host ('  [NG] ' + $name + '   ' + $detail) }
}

$winMod = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path

Write-Host ''
Write-Host '=== 物理屏幕工作区 ===' -ForegroundColor Cyan
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Write-Host ('  工作区: ' + $wa.Width + ' x ' + $wa.Height + '  @(' + $wa.X + ',' + $wa.Y + ')')
Write-Host ('  下沿 Y = ' + $wa.Bottom + '，右沿 X = ' + $wa.Right)

. $winMod
$env:DSH_RW_TEST_MODE = '1'
if (-not (Initialize-DshRwType)) { Write-Host '  [SKIP] 窗口类型没编译出来'; exit 0 }

$win = New-Object DshRestartStatusWindow
Write-Host ''
Write-Host '=== 开窗口 ===' -ForegroundColor Cyan
$up = $win.Start('【测试】窗口越界验收')
Start-Sleep -Milliseconds 700
Check '窗口起得来' $up ('Start=' + $up)
if (-not $up) { exit 1 }

function Get-Rect($w) {
  $s = $w.WindowRect()
  if (-not $s) { return $null }
  $p = $s -split ','
  if ($p.Count -lt 4) { return $null }
  return @{ L = [int]$p[0]; T = [int]$p[1]; R = [int]$p[2]; B = [int]$p[3] }
}

# ⚠️ 2026-10-13 修偶发红：**必须等尺寸稳定再量**。
#   病根：`Set()` 是投递到窗口线程的异步动作，而窗口是 `SizeToContent=Height`
#   —— 内容一变长，WPF 要重新排版、窗口才长高。固定 `Start-Sleep 700ms`
#   在机器忙时**量到的是"还没长完"的中间状态**，于是偶发报红（实测三套连跑时
#   window-offscreen 出现 8/8 → 5/8 的假红，而单独跑必绿）。
#   修法：轮询到"两个连续采样完全一致"再返回 —— 也就是**排版真的停下来了**。
#   这与"别用固定秒数等异步动作"是同一个教训（本仓在唤醒投递那里吃过一次）。
function Wait-StableRect($w, $timeoutMs = 4000) {
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  $prev = $null
  $stable = 0
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 120
    $cur = Get-Rect $w
    if (-not $cur) { continue }
    if ($prev -and $prev.T -eq $cur.T -and $prev.B -eq $cur.B -and $prev.L -eq $cur.L) {
      $stable++
      if ($stable -ge 2) { return $cur }   # 连续两次一致 = 稳定
    } else { $stable = 0 }
    $prev = $cur
  }
  return $prev
}

Write-Host ''
Write-Host '=== 场景 1：短内容 ===' -ForegroundColor Cyan
$win.Set('等待中', '短内容。', '已经等了 5 秒', '#7A7A7A')
$r1 = Wait-StableRect $win
if ($r1) {
  Write-Host ('  矩形 L=' + $r1.L + ' T=' + $r1.T + ' R=' + $r1.R + ' B=' + $r1.B)
  Check '短内容：左边在屏内' ($r1.L -ge 0 -and $r1.R -le $wa.Right + 2) ('L=' + $r1.L + ' R=' + $r1.R)
  Check '短内容：底边不越界' ($r1.B -le $wa.Bottom + 2) ('B=' + $r1.B + ' vs ' + $wa.Bottom)
} else { Check '能读到窗口矩形' $false 'WindowRect 返回空' }

Write-Host ''
Write-Host '=== 场景 2：超长内容（复现用户报的问题）===' -ForegroundColor Cyan
$longReason = ('这是一段很长的原因，用来把窗口撑高，模拟真实重启里 reason 很长的情况。' * 20)
$win.Set('等待中', $longReason, '已经等了 12 秒；要是 300 秒内一直安静不下来，就放弃（这不是倒计时，安静了就立刻动手）', '#7A7A7A')
$r2 = Wait-StableRect $win
if ($r2) {
  Write-Host ('  矩形 L=' + $r2.L + ' T=' + $r2.T + ' R=' + $r2.R + ' B=' + $r2.B)
  Write-Host ('  窗口高度(物理) = ' + ($r2.B - $r2.T) + '，屏幕可用高度 = ' + $wa.Height)
  Check '★★ 超长内容：底边不越出屏幕' ($r2.B -le $wa.Bottom + 2) ('底边 ' + $r2.B + ' vs 屏幕下沿 ' + $wa.Bottom)
  Check '★★ 超长内容：顶边没跑到屏幕上方外' ($r2.T -ge 0) ('T=' + $r2.T)
  Check '超长内容：右边仍在屏内' ($r2.R -le $wa.Right + 2) ('R=' + $r2.R)
  Check '超长内容：左边仍在屏内' ($r1.L -ge 0) ('L=' + $r2.L)
  # 关键对比：修复前的算法会把顶边钉在"屏幕底 - 280×缩放"，底边于是冲出屏幕
  $sc = 1.5
  try { $sc = $wa.Width / 1138.0 } catch { }
  $oldTop = $wa.Bottom - (280 * $sc)
  Write-Host ('  （参考：修复前顶边大约钉在 ' + [int]$oldTop + '，内容高过 ' + [int]($wa.Bottom - $oldTop) + ' 物理像素就会溢出）')
} else { Check '能读到窗口矩形（长内容）' $false 'WindowRect 返回空' }

Write-Host ''
Write-Host '=== 场景 3：内容再变（验证"每次变化都重贴"）===' -ForegroundColor Cyan
$win.Set('✅ 重启完成', '短句。', '', '#4CAF50')
$r3 = Wait-StableRect $win
if ($r3) {
  Write-Host ('  矩形 L=' + $r3.L + ' T=' + $r3.T + ' R=' + $r3.R + ' B=' + $r3.B)
  Check '内容变短后仍在屏内' ($r3.B -le $wa.Bottom + 2 -and $r3.L -ge 0) ('B=' + $r3.B)
}

$win.Close()
Start-Sleep -Milliseconds 300
Remove-Item Env:\DSH_RW_TEST_MODE -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('===== 汇总：' + $pass + '/' + ($pass + $fail) + ' 通过 =====')
if ($fail -gt 0) { exit 1 } else { exit 0 }
