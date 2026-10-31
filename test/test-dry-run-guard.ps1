# ============================================================================
#  test-dry-run-guard.ps1 —— 端到端验证「护栏真的会停手」+「干跑真的不动手」
# ============================================================================
#  2026-10-23 建立。来源：维护记录 归零排查（附件\归零排查报告-20261023.md）
#
#  【为什么必须有这一套 —— 它守的是前面几套守不到的东西】
#
#    2026-10-23 的归零排查抓到：第 3.5b 步「目标一致性护栏」把结论算出来了，
#    置了 $preflightOk = $false，但**后面没有任何代码读它** → 照样 taskkill。
#    两次误杀真 DSH（10-21、10-23）都是这个原因。
#
#    ⚠️ 而当时 test-target-guard.ps1 是**全绿**的。为什么？
#       它自己的注释写着：「只把护栏那段判断逻辑**照抄一份**在这里，用假的输入验它的真假值」。
#       ⇒ 照抄的是**计算**，丢掉的正是**接线**（算出来有没有人用）。
#
#    本套测试的定位：**跑真脚本、看真行为**，不照抄任何逻辑。
#    判据只有一条：**它有没有碰到不该碰的东西。**
#
#  【安全设计 —— 这一套绝不能杀掉真 DSH】
#
#    ⚠️⚠️ 本套是**唯一会真的执行助手脚本**的测试，所以安全边界必须最硬：
#      A. 用假的 sessionsRoot / stateFile / logFile / lastRunFile / cancelFile（全在临时目录）；
#      B. 目标进程名指向一个**不存在**的东西（`__dryrun_no_such_app__`）；
#      C. 计划里的 dshExe 指向一个**假的** exe（造一个带 MZ 头的临时文件）；
#      D. 跑前跑后核对**真 DSH 的监听 PID 没变**（这是最硬的判据，骗不了人）；
#      E. 干跑模式本来就不发 taskkill（源码里 exit 在第一个 taskkill 之前 45 行），
#         但**不依赖这个前提** —— D 条无论如何都要过。
#
#  【怎么跑】
#    pwsh -NoProfile -File test\test-dry-run-guard.ps1
#    pwsh -NoProfile -File test\test-dry-run-guard.ps1 -BreakSelfTest   # 改坏自检
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
  if ($Condition) {
    $script:Pass++
    Write-Host ("  [通过] {0}" -f $Name) -ForegroundColor Green
  } else {
    $script:Fail++
    $script:Failed.Add($Name)
    Write-Host ("  [失败] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
  }
}

if (-not (Test-Path -LiteralPath $helper)) {
  Write-Host "找不到助手脚本：$helper" -ForegroundColor Red
  exit 1
}
$helperText = Get-Content -LiteralPath $helper -Raw -Encoding UTF8

# ── 0. 源码结构检查（防"改了但没接上"重演）──────────────────────────────────
#
# ⚠️ 这几条**故意不做成"抄一份逻辑来验"** —— 那种做法正是当年漏掉接线的原因。
#   这里只钉"结构上该有的东西还在不在"，真行为留给下面 1、2 两组实际运行。
Write-Host ''
Write-Host '=== 0. 源码结构：该有的东西在不在 ===' -ForegroundColor Cyan

Check '源码里有 -DryRun 参数' ($helperText -match '\[switch\]\$DryRun')

# ★ 最关键的一条：护栏算出的结论**必须**被真的一次收尾块接住。
#   判据不是"有没有那句判断"，而是"那句判断之后有没有 exit"。
#   （当年就是只有判断、没有 exit。）
$guardBlockOk = $false
$m = [regex]::Match($helperText, '(?s)if \(-not \$preflightOk\) \{(.+?)\n\}')
if ($m.Success) { $guardBlockOk = ($m.Groups[1].Value -match '\bexit\s+\d') }
Check '★ 护栏判出不通过后**真的会 exit**（不只是写日志）' $guardBlockOk `
  '找到了 "if (-not $preflightOk) {" 但它里面没有 exit —— 说明算完还是没人停手'

# 干跑的退出必须落在第一个 taskkill **之前**（否则"干跑"会真动手）
$dryIdx  = $helperText.IndexOf('if ($DryRun) {')
$killIdx = $helperText.IndexOf("taskkill.exe' -Arguments @('/PID'")
$orderOk = ($dryIdx -ge 0) -and ($killIdx -ge 0) -and ($dryIdx -lt $killIdx)
Check '★ 干跑退出点在第一个 taskkill 之前' $orderOk `
  ("dry=$dryIdx kill=$killIdx")

# ── 1. 实际运行：护栏不通过时必须停手（且不碰真 DSH）────────────────────────────
Write-Host ''
Write-Host '=== 1. 实际运行：目标对不上 → 必须停手、不杀任何东西 ===' -ForegroundColor Cyan

$tmp1 = Join-Path $env:TEMP ('dryguard-fail-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp1 | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp1 'sessions') | Out-Null
# 造一个"像 exe"的假文件（MZ 头），让 3.5 那道闸放行、逼它走到 3.5b
$fakeExe = Join-Path $tmp1 'fake.exe'
[IO.File]::WriteAllBytes($fakeExe, [byte[]](0x4D, 0x5A, 0x00, 0x00))

function Get-RealDshPid {
  # 真 DSH 宿主（网页服务）的监听进程。读不到就返回 0。
  try {
    $ports = @(2254, 12249)
    try {
      $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
      if (Test-Path -LiteralPath $st) {
        $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
        if ($p) { $ports += [int]$p }
      }
    } catch { }
    foreach ($p in ($ports | Select-Object -Unique)) {
      $o = (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1).OwningProcess
      if ($o) { return $o }
    }
  } catch { }
  return 0
}

$realBefore = Get-RealDshPid

$plan1 = [ordered]@{
  planId = 'restart-dryguard-fail'
  createdAt = (Get-Date).ToString('o')
  scheduleAt = (Get-Date).ToString('o')
  reason = '端到端：护栏不通过必须停手'
  port = 1
  dshExe = $fakeExe                      # 假 exe → 与真正在跑的 DSH 不一致
  dshWorkDir = $tmp1
  idleSeconds = 1
  confirmSeconds = 0                     # 别在测试里等 10 秒确认窗
  maxWaitMinutes = 0.3
  othersWindowSeconds = 5
  bootTimeoutSeconds = 5
  maxAttempts = 1
  sessionsRoot = (Join-Path $tmp1 'sessions')
  stateFile = (Join-Path $tmp1 'state.json')
  logFile = (Join-Path $tmp1 'helper.log')
  lastRunFile = (Join-Path $tmp1 'last-run.json')
  cancelFile = (Join-Path $tmp1 'cancel.flag')
  requestedBy = 'session-dryguard'
  resume = $false
}
$plan1Path = Join-Path $tmp1 'plan.json'
($plan1 | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $plan1Path -Encoding UTF8

if ($BreakSelfTest) {
  # 改坏自检：把那句 exit 从源码里临时拿掉（模拟"护栏算完没人停"的旧 bug）
  Write-Host ''
  Write-Host '*** 改坏自检：把护栏里的 exit 去掉，下面第 1 组应当变红 ***' -ForegroundColor Yellow
  $broken = $helperText -replace '(?s)(if \(-not \$preflightOk\) \{).*?\bexit\s+\d', '$1'
  $brokenPath = Join-Path $tmp1 'helper-broken.ps1'
  [IO.File]::WriteAllText($brokenPath, $broken)
  $runHelper = $brokenPath
} else {
  $runHelper = $helper
}

# 跑：**用真目标名 + 开干跑**。
#
# ⚠️⚠️ 为什么必须用真目标名（2026-10-23 改坏自检时发现的漏洞）：
#   第一版这里传的是假目标名 `__dryguard_no_such_app__`，结果改坏自检时
#   「真 DSH 的监听 PID 没变」照样是绿的 —— 因为假名字**连挑都挑不到真 DSH**，
#   这条最硬的断言在这里等于没验。
#   ⇒ 要验"护栏能不能拦住杀真 DSH 的手"，就必须让它**真有机会走到那一步**。
#
# ✅ 为什么开干跑就安全（这是本套测试能这么做的唯一依据）：
#   干跑会在第一个 taskkill 之前 exit（源码位置已由第 0 组钉死）。
#   所以即便护栏失效、流程一路往下走，也会在干跑那里停住 —— **不会真杀**。
#   两层保护：护栏先拦（验的是它），干跑兜底（保证测试自身安全）。
$out1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runHelper `
          -PlanFile $plan1Path -DryRun 2>&1 | Out-String
$code1 = $LASTEXITCODE

$realAfter = Get-RealDshPid

Check '★ 真 DSH 的监听 PID 跑前跑后没变（最硬的安全判据）' `
  ($realBefore -eq $realAfter -and $realAfter -gt 0) `
  ("跑前=$realBefore 跑后=$realAfter")

Check '它确实停下来了（退出码 1 = 检查没过、主动退出）' ($code1 -eq 1) "实际退出码=$code1"

Check '日志里明说「没有动 DSH」' ($out1 -match '没有动 DSH')

Check '★ 它是在**护栏**那里停的，不是靠干跑兜底' `
  ($out1 -match '不是同一个') `
  '它没被护栏拦住（虽然靠干跑兜住了，但那说明护栏失效）'

Check '日志里**没有**真正动手的痕迹（准备关闭/taskkill/已完全退出）' `
  (-not ($out1 -match '准备关闭 DSH|taskkill|已完全退出')) `
  '它已经动手了！'

# ── 2. 实际运行：干跑在"目标一致"时也只报告不动手 ───────────────────────────────
Write-Host ''
Write-Host '=== 2. 实际运行：目标一致 + 干跑 → 列出要杀的、但一步不动 ===' -ForegroundColor Cyan

$tmp2 = Join-Path $env:TEMP ('dryguard-ok-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp2 'sessions') | Out-Null

# 这次让 dshExe 指向**真 DSH** —— 目标一致性会通过，从而真正走到"准备关闭"那一步，
# 这才是干跑最关键的位置。若干跑失效，这一组会真杀 DSH，所以 A/E 两条边界必须成立。
$realExe = ''
try {
  $mainCl = Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
  if ($mainCl) { $realExe = [string](Get-Process -Id $mainCl.ProcessId).Path }
} catch { }

if (-not $realExe -or -not (Test-Path -LiteralPath $realExe)) {
  Write-Host '  [SKIP] 找不到真 DSH 的可执行文件路径 —— 跳过第 2 组（不强猜）' -ForegroundColor Yellow
} else {
  $realBefore2 = Get-RealDshPid

  $plan2 = [ordered]@{
    planId = 'restart-dryguard-ok'
    createdAt = (Get-Date).ToString('o')
    scheduleAt = (Get-Date).ToString('o')
    reason = '端到端：干跑只报告不动手'
    port = 1
    dshExe = $realExe
    dshWorkDir = (Split-Path $realExe)
    idleSeconds = 1
    confirmSeconds = 0
    maxWaitMinutes = 0.3
    othersWindowSeconds = 5
    bootTimeoutSeconds = 5
    maxAttempts = 1
    sessionsRoot = (Join-Path $tmp2 'sessions')
    stateFile = (Join-Path $tmp2 'state.json')
    logFile = (Join-Path $tmp2 'helper.log')
    lastRunFile = (Join-Path $tmp2 'last-run.json')
    cancelFile = (Join-Path $tmp2 'cancel.flag')
    requestedBy = 'session-dryguard'
    resume = $false
  }
  $plan2Path = Join-Path $tmp2 'plan.json'
  ($plan2 | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $plan2Path -Encoding UTF8

  if ($BreakSelfTest) {
    $out2 = ''
    $code2 = -1
    Check '（改坏自检时跳过第 2 组）' $false '预期的红'
  } else {
    # ⚠️ 这里**不传** -TargetProcessName → 用默认值（= 真 DSH 的名字），
    #    这是唯一能走到"准备关闭"的路径。所以下面必须核 PID。
    $out2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper `
              -PlanFile $plan2Path -DryRun 2>&1 | Out-String
    $code2 = $LASTEXITCODE

    Check '干跑退出码 0（检查完成，不是失败）' ($code2 -eq 0) "实际=$code2"
    Check '干跑报告里有「准备关闭 DSH：共 N 个进程」' ($out2 -match '准备关闭 DSH：共 \d+ 个进程')
    Check '报告里列出了具体 PID' ($out2 -match 'PID=\s*\d+')
    Check '报告里明说「一个都没有被动过」' ($out2 -match '一个都没有被动过')
    Check '生成了 dry-run-report.txt' (Test-Path (Join-Path $tmp2 'dry-run-report.txt'))
    Check '它**没有**真去 taskkill' (-not ($out2 -match 'taskkill:|taskkill /F'))
  }

  $realAfter2 = Get-RealDshPid
  Check '★ 第 2 组跑完，真 DSH 的监听 PID 仍没变' `
    ($realBefore2 -eq $realAfter2 -and $realAfter2 -gt 0) `
    ("跑前=$realBefore2 跑后=$realAfter2")
}

# ── 收尾：清临时目录（走回收站，本机红线）──────────────────────────────────
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($d in @($tmp1, $tmp2)) {
  if ($d -and (Test-Path -LiteralPath $d)) {
    try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($d, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
  }
}

# ── 汇总 ────────────────────────────────────────────────────────────────────
Write-Host ''
if ($script:Fail -gt 0) {
  Write-Host '失败的断言：' -ForegroundColor Red
  $script:Failed | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
  Write-Host ''
  Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Red
  exit 1
}
Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Green
exit 0
