# ============================================================================
#  test-target-guard.ps1 —— 「要杀的」和「要拉起的」必须是同一个程序
# ============================================================================
#  2026-10-22 建立。来源：历史事故 DSH）
#
#  【那次事故】
#    排错时手工跑助手，命令里漏了 -TargetProcessName / -TargetCommandMatch。
#    助手默认目标就是真 DSH，于是：
#      · 把正在运行的 DeepSeek Harness（PID 44204）杀了；
#      · 计划里的 dshExe 指向测试用的 fake.exe（十几字节的文本文件）→ 拉起失败；
#      · **DSH 被关掉却没人拉起来** —— 这个工具唯一不可接受的后果。
#
#  【这套测试守什么】
#    护栏的核心判据：动手关之前，`Get-MainDshProcess` 选出来的进程的**可执行文件全路径**
#    必须等于计划里的 `$dshExe`。不一致 → 原地退出、一个进程都不碰。
#
#  ⚠️ 本测试**绝不真跑助手、绝不碰真进程**：它只把护栏那段判断逻辑**照抄一份**在这里，
#     用假的输入验它的真假值。真正的端到端验证靠 test-wait-when-busy 等安全测试。
#     （为什么要照抄而不 import：助手脚本是"点源即有副作用"的线性脚本，
#      没法只加载其中一段。照抄的代价是可能跟源码漂移 —— 所以下面有一条断言专门
#      检查"源码里确实还有这段逻辑"，漂了就变红。）
#
#  用法：
#    pwsh -NoProfile -File test\test-target-guard.ps1
#    pwsh -NoProfile -File test\test-target-guard.ps1 -BreakSelfTest   # 改坏自检
# ============================================================================

[CmdletBinding()]
param([switch]$BreakSelfTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$helper = Join-Path (Split-Path -Parent $here) 'bin\dsh-self-restart.ps1'

$script:Pass = 0
$script:Fail = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) { $script:Pass++; Write-Host ("  [通过] {0}" -f $Name) -ForegroundColor Green }
  else { $script:Fail++; $script:Failed.Add($Name); Write-Host ("  [失败] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $helper)) { Write-Host "找不到助手脚本：$helper" -ForegroundColor Red; exit 1 }
$helperText = Get-Content -LiteralPath $helper -Raw -Encoding UTF8

# ── 0. 源码里必须真的还有这套护栏（防"测试绿了但护栏被删了"）──────────────
Write-Host ''
Write-Host '=== 源码检查：护栏还在吗 ===' -ForegroundColor Cyan
Check '源码里有"目标一致性"这句判据' ($helperText -match '要关掉的进程和计划里的主程序不是同一个')
# 匹配 `$runningExe... -ne $dshExe` 这个比较（中间可能有 Trim/Trim('"') 等修饰）；
# 用宽松一点的写法，别为了"精确"把断言写成一次性正则 —— 上面那次就是写得太紧导致假红。
Check '源码里比对了 runningExe 与 dshExe' ($helperText -match '\$runningExe[^\r\n]*-ne\s+\$dshExe')
Check '源码在拿不到路径时**当失败**（不是当通过）' ($helperText -match '读不出它的可执行文件路径')

# ── 1. 护栏判断逻辑（照抄源码，输入造假）──────────────────────────────────
# 这段必须和 bin\dsh-self-restart.ps1 里"第 3.5b 步"保持一致。
function Test-TargetGuard {
  param(
    [string]$RunningExe,          # Get-MainDshProcess 选出来的进程的可执行文件路径（'' = 读不出）
    [string]$PlannedExe,          # 计划里的 $dshExe
    [bool]$BreakIt = $false
  )
  if ($BreakIt) { return $true }   # 改坏模式：永远放行

  $ok = $true
  $why = @()
  if (-not $RunningExe) {
    $ok = $false
    $why += '读不出它的可执行文件路径'
  } elseif ($RunningExe.Trim().Trim('"') -ne $PlannedExe.Trim().Trim('"')) {
    $ok = $false
    $why += '要关掉的进程和计划里的主程序不是同一个'
  }
  return [pscustomobject]@{ Ok = $ok; Why = $why }
}

Write-Host ''
Write-Host '=== 护栏判断（目标一致性）===' -ForegroundColor Cyan
$real = 'C:\Users\x\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
$fake = 'C:\Users\x\AppData\Local\Temp\guard-test\fake.exe'

$g1 = Test-TargetGuard -RunningExe $real -PlannedExe $real
Check '同一个程序 → 放行' ($g1.Ok -eq $true)

$g2 = Test-TargetGuard -RunningExe $real -PlannedExe $fake
Check '★ 事故现场复刻（在跑真 DSH、计划要拉起 fake.exe）→ **必须拦住**' ($g2.Ok -eq $false)
Check '拦下时给的理由说得清"不是同一个"' (($g2.Why -join ' ') -match '不是同一个')

$g3 = Test-TargetGuard -RunningExe $real.ToUpper() -PlannedExe $real.ToLower()
Check '大小写不同 → 仍算同一个（Windows 路径不区分大小写）' ($g3.Ok -eq $true)

$g4 = Test-TargetGuard -RunningExe ('"' + $real + '"') -PlannedExe $real
Check '一侧带引号 → 仍算同一个' ($g4.Ok -eq $true)

$g5 = Test-TargetGuard -RunningExe '' -PlannedExe $real
Check '★ 读不出正在跑的进程路径 → **必须拦住**（不能当通过）' ($g5.Ok -eq $false)

$g6 = Test-TargetGuard -RunningExe $real -PlannedExe ''
Check '计划里没写要拉起什么 → 必须拦住' ($g6.Ok -eq $false)

# ── 2. 那次事故的"另一条腿"：fake.exe 体积检查本来就拦不住 ────────────────
# 2026-10-22 现场：测试脚本用 Set-Content -Value 'MZ placeholder' 造了个十几字节的文件。
# 老护栏只查"在不在、是不是 0 字节" → **放行**。这条断言把这个事实钉住，
# 免得以后有人以为"体积检查已经够了"。
Write-Host ''
Write-Host '=== 为什么老护栏不够（把事实钉住）===' -ForegroundColor Cyan
$tmpFake = Join-Path $env:TEMP ('guardshape-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')
try {
  Set-Content -LiteralPath $tmpFake -Value 'MZ placeholder' -NoNewline
  $len = (Get-Item -LiteralPath $tmpFake).Length
  Check '这种假文件**不是** 0 字节（所以旧检查会放行）' ($len -gt 0) "实际 $len 字节"
  $head = [System.IO.File]::ReadAllBytes($tmpFake)[0..1]
  Check '它的开头两字节确实是 "MZ"（所以"看 PE 头"也拦不住）' ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)
} finally {
  Remove-Item -LiteralPath $tmpFake -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($BreakSelfTest) {
  # 改坏自检：把护栏改成"永远放行"，再跑最关键的那条断言，看它会不会红。
  $gb = Test-TargetGuard -RunningExe $real -PlannedExe $fake -BreakIt $true
  if ($gb.Ok -eq $false) {
    Write-Host '*** 改坏自检失败：掰坏了却没放行 → 断言有问题 ***' -ForegroundColor Red
    exit 3
  }
  Write-Host '*** 改坏自检通过：护栏被掰坏后，"事故现场"那条确实会放行 →'
  Write-Host '    说明正常模式下的 [拦下] 是真判据，不是恒真的摆设 ***' -ForegroundColor Yellow
  exit 0
}

Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
  Write-Host '失败的断言：' -ForegroundColor Red
  $script:Failed | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
  exit 1
}
exit 0
