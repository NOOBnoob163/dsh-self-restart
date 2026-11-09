# ============================================================================
#  test-relaunch-stop.ps1 —— 「拉起阶段叫停」真的会停（端到端）
# ============================================================================
#  2026-10-23 建立。
#    起因：拉起阶段缺一个叫停入口 —— 一旦陷入「反复尝试拉起」就只能干等。
#    叉号的语义：点叉号等于终止重启；如果当前阶段无法终止，那就做完了再停下。
#
#  【测的是什么】
#    助手在「DSH 已被关掉、正在反复尝试拉起」这一段，每轮之间会查 cancel.flag。
#    本测试在**第 1 次尝试之后**丢下 cancel.flag，验证：
#      · 它没有闷头试满 maxAttempts 次，而是在下一轮之前停住
#      · 结果记成 failed（这样插件才会给那几个会话贴 ⭕ 标记）
#      · 说法是"你按了停止"，而不是"机器坏了"
#
#  【为什么必须端到端跑真脚本】
#    这段逻辑埋在助手的拉起循环里，靠读代码证明不了"它会不会真的停"。
#
#  【安全边界（这一套会真的执行关闭/拉起动作，所以最关键）】
#    ① 目标进程名用**唯一假名** `__dshfake__`：
#       Get-DshProcesses 是 `Get-Process -Name $TargetProcessName` 过滤出来的，
#       Kill-AllDsh 又只杀这个列表 —— 所以物理上碰不到真 DSH。
#    ② 假"DSH"= 一份 ping.exe 的副本，改名 __dshfake__.exe，用 -t 常驻。
#    ③ dshExe 指向同一个假 exe → 3.5b 目标一致性会通过（要杀的==要拉起的）
#    ④ port 用一个没人听的端口 + bootTimeout 3 秒 → 每次尝试快速失败
#    ⑤ 跑前跑后核对真 DSH 监听 PID 没变
#    ⑥ ⚠️ TargetProcessName / TargetCommandMatch 必须走**命令行参数**，
#       绝不能写进 plan.json 的字段里（那是 历史事故 误杀的直接原因：
#       写进 JSON 是空操作，脚本仍用默认目标 = 真 DSH）
#
#  用法：powershell -NoProfile -File test\test-relaunch-stop.ps1
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

$FAKE = '__dshfake__'          # 唯一假名：实机上不可能有同名进程

# ── 0. 源码结构 ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '=== 0. 源码结构：叫停点还在不在 ===' -ForegroundColor Cyan
$helperText = [IO.File]::ReadAllText($helper)

Check '拉起重试之间查了 cancelFile' ($helperText -match '收到停止请求（打完第')
Check '叫停也会记 failed（插件才会贴 ⭕）' ($helperText -match 'stoppedByUser')
Check '叫停的说法是「你按了停止」（不是机器坏了）' ($helperText -match '你按了停止')

# ---------------------------------------------------------------------------
# 安全前置：真 DSH 的监听 PID 记下来，最后要一模一样
# ---------------------------------------------------------------------------
function Get-RealDshPid {
  try {
    $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
    $ports = @()
    if (Test-Path -LiteralPath $st) {
      $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
      if ($p) { $ports += [int]$p }
    }
    $ports += @(12249, 2254)
    foreach ($pp in ($ports | Select-Object -Unique)) {
      $o = (Get-NetTCPConnection -LocalPort $pp -State Listen -EA SilentlyContinue |
            Select-Object -First 1).OwningProcess
      if ($o) { return $o }
    }
  } catch { }
  return 0
}

$realBefore = Get-RealDshPid
Check '能读到真 DSH 的监听 PID（读不到就没法证明没碰它）' ($realBefore -gt 0) "读到 $realBefore"

# 再加一道：确认现在**没有**叫这个名字的进程。
# ⚠️ 有残留多半是上一次跑挂了留下的假 exe（名字是本测试专属，实机不会有）。
#    先清掉再继续；清不掉才中止 —— 否则一次失败会让后面每次都被"撞名"挡住。
$preExisting = @(Get-Process -Name $FAKE -ErrorAction SilentlyContinue)
if ($preExisting.Count -gt 0) {
  Write-Host ("  [提示] 发现 $($preExisting.Count) 个残留的假进程（多半是上次跑挂的），先清掉") -ForegroundColor Yellow
  foreach ($p in $preExisting) {
    try {
      # 只清**命令行里带这个假名路径**的（进一步保险：绝不误杀同名但无关的东西）
      $cl = ''
      try { $cl = [string](Get-CimInstance Win32_Process -Filter ("ProcessId=$($p.Id)") -EA SilentlyContinue).CommandLine } catch { }
      if ($cl -like ('*' + $FAKE + '*')) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
    } catch { }
  }
  Start-Sleep -Milliseconds 600
  $preExisting = @(Get-Process -Name $FAKE -ErrorAction SilentlyContinue)
}
Check "假名 $FAKE 现在干净（清不掉就中止，不冒险）" ($preExisting.Count -eq 0) `
  "还有 $($preExisting.Count) 个同进程"
if ($preExisting.Count -gt 0) {
  Write-Host '  假名撞车，为安全起见不继续。' -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP ('relaunchstop-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'sessions') | Out-Null

$fakeExe = Join-Path $tmp "$FAKE.exe"
Copy-Item -LiteralPath "$env:SystemRoot\System32\ping.exe" -Destination $fakeExe -Force
Check '假 exe 造好了（ping 的副本，改名为唯一假名）' (Test-Path -LiteralPath $fakeExe)

# 起一个常驻的假"DSH"，让助手有东西可"关"
$dummy = Start-Process -FilePath $fakeExe -ArgumentList '-t', '127.0.0.1' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 900
$alive = @(Get-Process -Name $FAKE -ErrorAction SilentlyContinue)
Check '假 DSH 已经在跑（助手能找到目标）' ($alive.Count -ge 1) "找到 $($alive.Count) 个"

$cancelFile = Join-Path $tmp 'cancel.flag'
$planPath = Join-Path $tmp 'plan.json'
$lastRun = Join-Path $tmp 'last-run.json'
$logFile = Join-Path $tmp 'helper.log'

$plan = [ordered]@{
  planId              = 'restart-relaunchstop'
  createdAt           = (Get-Date).ToString('o')
  scheduleAt          = (Get-Date).ToString('o')
  reason              = '端到端：拉起阶段叫停必须真的停'
  port                = 59991
  dshExe              = $fakeExe
  dshWorkDir          = $tmp
  idleSeconds         = 1
  confirmSeconds      = 0
  maxWaitMinutes      = 0.2
  othersWindowSeconds = 2
  bootTimeoutSeconds  = 3
  maxAttempts         = 3
  sessionsRoot        = (Join-Path $tmp 'sessions')
  stateFile           = (Join-Path $tmp 'state.json')
  logFile             = $logFile
  lastRunFile         = $lastRun
  cancelFile          = $cancelFile
  requestedBy         = 'session-relaunchstop'
  resume              = $false
}
($plan | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $planPath -Encoding UTF8

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1. 实际运行：第 1 次拉起失败后丢下 cancel.flag ===' -ForegroundColor Cyan

if ($BreakSelfTest) {
  # 改坏：把「叫停检查」的条件换成 $false（保持语法完整），再用副本跑同一套断言。
  #
  # ⚠️ 第一版是直接用正则删掉那几行 —— 结果留下孤立的 `}`，副本语法就崩了，
  #    子进程报的是 ParserError 而不是"断言变红"，等于没验到东西。
  #    换成"条件恒假"：语法照旧，但叫停功能确实没了。
  Write-Host '  *** 改坏自检：把叫停检查的条件改成恒假 ***' -ForegroundColor Yellow
  $ln = $helperText -split "`n"
  $markIdx = -1
  for ($i = 0; $i -lt $ln.Count; $i++) {
    if ($ln[$i] -match '收到停止请求（打完第') { $markIdx = $i; break }
  }
  $patched = $false
  if ($markIdx -ge 0) {
    # 从标记行往上找最近的那个 if 条件行
    for ($i = $markIdx; $i -ge 0; $i--) {
      if ($ln[$i] -match 'if \(Test-Path -LiteralPath \$cancelFile\)') {
        $ln[$i] = $ln[$i] -replace 'Test-Path -LiteralPath \$cancelFile', '$false'
        $patched = $true
        break
      }
    }
  }
  $broken = ($ln -join "`n")
  $brokenPath = Join-Path $tmp 'helper-broken.ps1'
  [IO.File]::WriteAllText($brokenPath, $broken)
  $runHelper = $brokenPath

  $cntBefore = ([regex]::Matches($helperText, 'Test-Path -LiteralPath \$cancelFile')).Count
  $cntAfter = ([regex]::Matches($broken, 'Test-Path -LiteralPath \$cancelFile')).Count
  Check '改坏自检的前提：恰好废掉了一处叫停检查' ($patched -and $cntAfter -eq ($cntBefore - 1)) `
    "改坏前 $cntBefore 处、改坏后 $cntAfter 处（patched=$patched）"

  # 副本语法必须干净，否则"红"是解析错误造成的假红
  $berr = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($brokenPath, [ref]$null, [ref]$berr)
  Check '改坏副本语法干净（红必须是断言造成的，不是解析错误）' (@($berr).Count -eq 0) `
    "解析错误 $((@($berr)).Count) 个"
} else {
  $runHelper = $helper
}

# 观察者：5 秒后丢下取消标记（第 1 次尝试失败之后、第 2 次之前）
$dropper = Start-Job -ScriptBlock {
  param($f, $delay)
  Start-Sleep -Seconds $delay
  try { [IO.File]::WriteAllText($f, "stop request at " + (Get-Date).ToString('o') + "`n") } catch { }
} -ArgumentList $cancelFile, 5

$sw = [System.Diagnostics.Stopwatch]::StartNew()
# ⚠️⚠️ 两个关键点（都踩过）：
#   ① 目标名/匹配串**必须**走命令行参数（写进 plan.json 是空操作 → 默认目标=真 DSH）
#   ② 必须加 `-Detached`：不加的话脚本会**再把自已脱离成一个后台子进程**，
#      父进程立刻 exit 0，我们测到的只是"点火器"——拿不到真正干活的退出码、
#      也等不到它写完 last-run.json（第一版就是这么假绿的：5.4 秒就"跑完了"）。
#      -Detached 是脚本本来就有的开关，意思是"我就是那个被脱离出来的进程，直接干活"。
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runHelper `
         -PlanFile $planPath -Detached `
         -TargetProcessName $FAKE `
         -TargetCommandMatch $FAKE 2>&1 | Out-String
$code = $LASTEXITCODE
$sw.Stop()

Wait-Job $dropper -Timeout 20 | Out-Null
Remove-Job $dropper -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('  助手退出码 = ' + $code + '，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' 秒')
# 留个尾巴：万一不按预期走，这里能直接看到它卡在哪一步（省一轮瞎猜）
Write-Host '  ── 助手输出（末 8 行）──' -ForegroundColor DarkGray
($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) |
  ForEach-Object { Write-Host ('    ' + $_.Trim()) -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. 断言 ===' -ForegroundColor Cyan

$logText = ''
if (Test-Path -LiteralPath $logFile) { $logText = [IO.File]::ReadAllText($logFile) }

$stopped = [bool]($logText -match '收到停止请求（打完第 (\d+) 次尝试后）')
Check '★ 日志里明确记了「收到停止请求」' $stopped `
  '没有这句 —— 说明它要么没查到标记，要么根本没看'

if ($stopped) {
  $m = [regex]::Match($logText, '收到停止请求（打完第 (\d+) 次尝试后）')
  $atAttempt = [int]$m.Groups[1].Value
  Check "★ 是在第 $atAttempt 次之后停的（没试满 3 次）" ($atAttempt -lt 3) `
    "试了 $atAttempt 次 —— 意味着它没停，一路试到底了"
  # 丢标记是 5 秒后，第 1 次尝试约 3 秒结束 → 应当在第 1 次之后就能看到，
  # 保守一点允许第 2 次（时序有抖动）
  Check "停止点不算太晚（第 $atAttempt 次 ≤ 2）" ($atAttempt -le 2) "第 $atAttempt 次"
}

$result = $null
if (Test-Path -LiteralPath $lastRun) {
  try { $result = Get-Content -LiteralPath $lastRun -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
Check '结果文件写出来了' ($null -ne $result)
if ($result) {
  Check '★ 结果记为 failed（插件据此给会话贴 ⭕）' ($result.outcome -eq 'failed') "实际 $($result.outcome)"
  Check '★ 说法是「你按了停止」（不是"机器坏了"）' ([bool]($result.detail -match '你按了停止')) `
    "实际：$($result.detail)"
}

Check '★ 假 DSH 已被清理（没留下垃圾进程）' `
  (@(Get-Process -Name $FAKE -ErrorAction SilentlyContinue).Count -eq 0) `
  '还有残留进程 —— 后面要手工清'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 3. 真 DSH 安全核对 ===' -ForegroundColor Cyan
$realAfter = Get-RealDshPid
Check '★★ 真 DSH 的监听 PID 跑前跑后没变' ($realBefore -eq $realAfter) `
  "跑前=$realBefore 跑后=$realAfter"

# ---------------------------------------------------------------------------
# 收尾
foreach ($p in @(Get-Process -Name $FAKE -ErrorAction SilentlyContinue)) {
  try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
}
Add-Type -AssemblyName Microsoft.VisualBasic
if (Test-Path -LiteralPath $tmp) {
  try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($tmp, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}

Write-Host ''
if ($BreakSelfTest) {
  # 改坏自检：改成"必须变红才算成功"由调用方判断；这里直接报红
  Write-Host '（改坏自检：上面应当在「收到停止请求」那条变红）' -ForegroundColor Yellow
}
if ($script:Fail -gt 0) {
  Write-Host '失败的断言：' -ForegroundColor Red
  $script:Failed | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
  Write-Host ''
  Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Red
  exit 1
}
Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Green
exit 0
