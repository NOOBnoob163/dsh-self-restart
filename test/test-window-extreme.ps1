# ============================================================================
#  极端情况实测：用**实机这次那条超长 reason** 撑窗口，量真实坐标
#
#  为什么还要再量一次：test-window-offscreen 用的是"重复 20 遍"的合成长文本；
#  而实机这条 reason 更长（它是真的长），属于测试没覆盖到的极端。
#  用户的要求是"展开后不许有部分跑到屏幕外" —— 那就得拿最长的真实内容验。
# ============================================================================
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check($n, $ok, $d) {
  if ($ok) { $script:pass++; Write-Host ('  [OK] ' + $n) } else { $script:fail++; Write-Host ('  [NG] ' + $n + '   ' + $d) }
}

$winMod = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
Write-Host ('屏幕工作区: ' + $wa.Width + 'x' + $wa.Height + '  下沿=' + $wa.Bottom)

. $winMod
$env:DSH_RW_TEST_MODE = '1'
if (-not (Initialize-DshRwType)) { Write-Host '[SKIP] 窗口类型没编译出来'; exit 0 }

# ── 实机那条 reason 的**实际文本**（从 plan.json 读，保证一字不差）──
$planPath = Join-Path $env:DSH_HOME 'self-restart\plan.json'
$realReason = ''
if (Test-Path $planPath) {
  try { $realReason = (Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json).reason } catch { }
}
if (-not $realReason) {
  # 计划文件已被清掉（重启完成后会删）→ 从 helper.log 里捞那条最长的
  $log = Join-Path $env:DSH_HOME 'self-restart\helper.log'
  $cand = Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue |
          Where-Object { $_ -match '计划 .*｜原因：' } |
          Sort-Object { $_.Length } -Descending | Select-Object -First 1
  if ($cand) { $realReason = ($cand -split '原因：', 2)[1] }
}
Write-Host ('实机 reason 长度: ' + $realReason.Length + ' 字符')

$win = New-Object DshRestartStatusWindow
if (-not $win.Start('【测试】极端长内容越界')) { Write-Host '[SKIP] 窗口起不来'; exit 1 }
Start-Sleep -Milliseconds 700

function Get-Rect($w) {
  $s = $w.WindowRect(); if (-not $s) { return $null }
  $p = $s -split ','; if ($p.Count -lt 4) { return $null }
  return @{ L = [int]$p[0]; T = [int]$p[1]; R = [int]$p[2]; B = [int]$p[3] }
}

Write-Host ''
Write-Host '=== 用实机那条 reason 撑满 ===' -ForegroundColor Cyan
$win.Set('等待中', $realReason, '已经等了 12 秒；要是 300 秒内一直安静不下来，就放弃（这不是倒计时，安静了就立刻动手）', '#7A7A7A')
Start-Sleep -Milliseconds 1200
$r = Get-Rect $win
if ($r) {
  $h = $r.B - $r.T
  Write-Host ('  矩形 L=' + $r.L + ' T=' + $r.T + ' R=' + $r.R + ' B=' + $r.B)
  Write-Host ('  窗口高(物理)=' + $h + '   屏幕可用高=' + $wa.Height)
  Check '★ 底边不越出屏幕' ($r.B -le $wa.Bottom + 2) ('底边 ' + $r.B + ' vs ' + $wa.Bottom)
  Check '★ 顶边不小于 0' ($r.T -ge 0) ('T=' + $r.T)
  Check '★ 右边不越出' ($r.R -le $wa.Right + 2) ('R=' + $r.R)
  Check '★ 左边不小于 0' ($r.L -ge 0) ('L=' + $r.L)
  if ($h -gt $wa.Height) {
    Write-Host '  （内容比屏幕还高：顶边贴 40，关键行仍可见 —— 这是设计内的降级）'
  }
} else { Check '读到窗口矩形' $false 'WindowRect 空' }

$win.Close()
Start-Sleep -Milliseconds 300
Remove-Item Env:\DSH_RW_TEST_MODE -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('===== 汇总：' + $pass + '/' + ($pass + $fail) + ' 通过 =====')
if ($fail -gt 0) { exit 1 } else { exit 0 }
