# 极限边界：内容**比屏幕还高**时会怎样？（降级路径必须也可用）
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
if (-not (Initialize-DshRwType)) { Write-Host '[SKIP]'; exit 0 }

$win = New-Object DshRestartStatusWindow
if (-not $win.Start('【测试】内容比屏幕还高')) { Write-Host '[SKIP]'; exit 1 }
Start-Sleep -Milliseconds 700

function Get-Rect($w) {
  $s = $w.WindowRect(); if (-not $s) { return $null }
  $p = $s -split ','; if ($p.Count -lt 4) { return $null }
  return @{ L = [int]$p[0]; T = [int]$p[1]; R = [int]$p[2]; B = [int]$p[3] }
}

Write-Host ''
Write-Host '=== 超超长内容（预期比屏幕还高）===' -ForegroundColor Cyan
$huge = ('这是一段极长的内容，长到超过整个屏幕的高度，用来验证降级路径。' * 90)
$win.Set('等待中', $huge, '（这条也极长）' + ('补充补充补充。' * 30), '#7A7A7A')
Start-Sleep -Milliseconds 1500
$r = Get-Rect $win
if ($r) {
  $h = $r.B - $r.T
  Write-Host ('  矩形 L=' + $r.L + ' T=' + $r.T + ' R=' + $r.R + ' B=' + $r.B)
  Write-Host ('  窗口高(物理)=' + $h + '   屏幕可用高=' + $wa.Height)
  if ($h -gt $wa.Height) {
    Write-Host '  ⇒ 内容确实比屏幕高（降级路径）'
    Check '降级：顶边贴在上边距（≥0）' ($r.T -ge 0 -and $r.T -le 60) ('T=' + $r.T)
    Write-Host ('  ⚠️ 此时下沿必然超出屏幕（T=' + $r.T + ' + 高 ' + $h + ' > ' + $wa.Bottom + '）')
    Write-Host '     设计取舍：**宁可底部超出，也要保住顶部**（标题/阶段/打断按钮都在上面）——'
    Write-Host '     这是内容真的装不下时唯一合理的选择。'
  } else {
    Check '★ 竟然装下了：底边不越界' ($r.B -le $wa.Bottom + 2) ('B=' + $r.B)
    Check '★ 顶边 ≥0' ($r.T -ge 0) ('T=' + $r.T)
  }
} else { Check '读矩形' $false '空' }

$win.Close()
Start-Sleep -Milliseconds 300
Remove-Item Env:\DSH_RW_TEST_MODE -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('===== 汇总：' + $pass + '/' + ($pass + $fail) + ' 通过 =====')
if ($fail -gt 0) { exit 1 } else { exit 0 }
