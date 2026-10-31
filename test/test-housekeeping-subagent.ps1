# 端到端实测（2026-10-08 实机 bug 的完整复现）：
#
#   「某个记忆插件的空闲复审子代理，把自动重启拦下了两次」
#
# 现场（两次都一样）：等静默约 25 秒 → 那个插件的"空闲复审"子代理
# （源码里写死 30 秒触发）在 30 秒左右起来 → 撞进重启的检查窗口 → 判"别人在忙" → 放弃。
# **越安静它越会来**（它就是被空闲触发的）—— 每次都精准对撞。
#
# 本测试造两种"别人"，验证区别对待：
#   A) 家务子代理在写（有 subagent 身份档案）→ **不该**拦，应等它跑完 → 动手
#   B) 真对话在写（无 subagent 档案）        → **必须**拦（安全方向不能丢）→ 放弃
#   C) 子代理跑完之后                         → 应放行动手
#
# 不碰真 DSH：假目标 exe / 假端口 / 假会话目录 / 假身份档案目录。
# 用法：powershell -NoProfile -File test-housekeeping-subagent.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-house-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$fakeTag  = 'HOUSETEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58861

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ── 假会话目录 + 假"身份档案"目录 ───────────────────────────────────────────
$sessions = Join-Path $tmpDir 'sessions'
$ws = Join-Path $sessions 'ws'
$cacheRoot = Join-Path $tmpDir 'projcache'

$meDir = Join-Path $ws 'session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# ★ 家务子代理（照"空闲复审"子代理的样子造：有 subagent 身份档案）
$houseId = 'housekeeping-subagent-0001'
$houseDir = Join-Path $ws $houseId
New-Item -ItemType Directory -Path $houseDir -Force | Out-Null
$houseFile = Join-Path $houseDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $houseFile -Value 'x' -Encoding ascii

New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
@'
{ "version": 7, "record": { "rows": {
  "subagent": { "ver": 2, "seq": 7, "val": { "identity": { "mode": "one-shot", "label": "idle checkpoint review", "seq": 7 } } },
  "title": { "ver": 1, "seq": 1, "val": "housekeeping" }
} } }
'@ | Set-Content -LiteralPath (Join-Path $cacheRoot "$houseId.json") -Encoding utf8

# ★ 真对话（照普通会话造：**没有** subagent 档案）
$realId = 'real-conversation-0002'
$realDir = Join-Path $ws $realId
New-Item -ItemType Directory -Path $realDir -Force | Out-Null
$realFile = Join-Path $realDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $realFile -Value 'x' -Encoding ascii
@'
{ "version": 7, "record": { "rows": {
  "title": { "ver": 1, "seq": 1, "val": "某个真对话" }
} } }
'@ | Set-Content -LiteralPath (Join-Path $cacheRoot "$realId.json") -Encoding utf8

# 假应用（每个场景用**自己的端口**，免得上一轮的端口没放干净把这一轮顶掉）
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag, [int]`$Port)
try {
  `$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$Port)
  `$l.Start()
} catch { exit 9 }
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
function Start-FakeApp([int]$port) {
  # ⚠️ 先确认这个端口是**空的**再用：上一个场景的假应用可能还没退干净，
  #    两个进程抢同一个端口会让"看起来起来了其实没起来"，
  #    随后助手拉不起来它（WMI 返回 9）→ 测试报"被测功能失败"（假红）。
  #    2026-10-10 全量跑时就这么红过一次，查半天才发现是测试自己的时序问题。
  for ($i = 0; $i -lt 20; $i++) {
    $busy = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($busy.Count -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
  $p = Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag,'-Port',$port
  ) -PassThru -WindowStyle Hidden
  # 等它**真的**开始监听（不是盲等固定秒数）—— 端口在听才算起来了
  $up = $false
  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 400
    $l = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($l.Count -gt 0 -or -not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { $up = ($l.Count -gt 0); break }
  }
  if (-not $up) { Write-Host ("     ⚠️ 假应用没能监听端口 $port（测试环境问题）") }
  return $p
}
$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

# 权威状态：只有我自己在跑（子代理不列进 runningSessions —— 那是新插件的口径；
# 但我们**故意留空 runningSubagents**，逼助手去走"读身份档案"这条兜底路）
$stateFile = Join-Path $tmpDir 'state.json'

# ★★ 关键：把状态文件写成**旧插件的真实口径** —— 子代理**混在 runningSessions 里**
#    （旧插件不会区分，而且它没有 runningSubagents 字段）。
#    这正是 2026-10-08 21:25:02 那次失败的真实条件：
#      日志上一行刚说"dcd36aa8 是家务子代理、不算别人在忙"（**扫盘**那条路认出来的），
#      下一行却又把它当"别的会话在干活"（**插件报的清单**这条路没过滤）→ 放弃。
#    上一版测试把子代理只放在盘上、不放清单里，于是**漏掉了这条路**，白测一轮。
$stateKeeperCode = @"
while (`$true) {
  # 子代理**只在它还活着的时候**才出现在清单里 —— 照真实插件的行为：
  # 子代理一结束，它就从 runningSessions 里消失。
  # （"活着"的判据：它那个会话文件最近 8 秒内被写过。）
  `$sessions = @('session-ME')
  if ((Test-Path '$houseFile') -and ((Get-Date) - (Get-Item '$houseFile').LastWriteTime).TotalSeconds -lt 8) {
    `$sessions += 'housekeeping-subagent-0001'
  }
  `$payload = [ordered]@{
    updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    jobsRunning     = 0
    agentsRunning   = `$sessions.Count
    runningSessions = `$sessions    # ← 旧插件口径：子代理**混在**"在跑会话"里
    details         = @()
    port            = $fakePort
  }
  `$payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath '$stateFile' -Encoding utf8
  Start-Sleep -Seconds 3
}
"@
$stateKeeper = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command', $stateKeeperCode
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

function New-Plan([string]$name, [int]$port) {
  $planPath = Join-Path $tmpDir "plan-$name.json"
  [ordered]@{
    planId             = "house-$name"
    createdAt          = (Get-Date).ToString('o')
    scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
    reason             = "实测：家务子代理 vs 真对话（$name）"
    port               = $port
    dshExe             = $fakeExe
    dshWorkDir         = $tmpDir
    idleSeconds        = 5
    maxWaitMinutes     = 1
    othersWindowSeconds = 120
    bootTimeoutSeconds = 4
    maxAttempts        = 1
    sessionFile        = $meFile
    sessionsRoot       = $sessions
    subagentCacheRoot  = $cacheRoot     # ★ 指向假档案目录，绝不读真实会话的身份档案
    stateFile          = $stateFile
    logFile            = Join-Path $tmpDir "house-$name.log"
    lastRunFile        = Join-Path $tmpDir "lastrun-$name.json"
    cancelFile         = Join-Path $tmpDir "cancel-$name.flag"
    showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
    requestedBy        = 'session-ME'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8
  return $planPath
}
function Run-Helper([string]$planPath) {
  Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$helper,'-PlanFile',$planPath,'-Detached',
    '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
  ) -WindowStyle Hidden | Out-Null
}
function Get-Outcome([string]$name) {
  $p = Join-Path $tmpDir "lastrun-$name.json"
  if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).outcome }
  return ''
}

# ★ 等"助手给出结论"再断言，别用写死的秒数。
#   原来固定睡 25 秒就读日志 —— 而"可以动手了"这行在第 26 秒才出现，
#   于是**功能完全正确、断言却报失败**（今晚踩了两次）。
#   现在改成轮询：日志里出现"可以动手了"或结果文件落盘，就立刻返回。
function Wait-Verdict([string]$name, [int]$timeoutSec = 60) {
  $logP = Join-Path $tmpDir "house-$name.log"
  $lastP = Join-Path $tmpDir "lastrun-$name.json"
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $txt = if (Test-Path $logP) { Get-Content $logP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' }
    if ($txt -match '可以动手了' -or $txt -match '准备关闭 DSH') { return }
    if (Test-Path $lastP) { return }
    Start-Sleep -Milliseconds 700
  }
}

# ★★ 等这个场景的助手**彻底跑完**再进下一个场景。
#   为什么必须等：助手"给出结论"之后还会继续干活 —— 去杀目标、等端口、拉起来、验端口，
#   这一串要好几十秒。而三个场景的假应用**共用同一个命令行标记**，
#   A 的助手在**杀目标**时会把 B 刚起的假应用一起杀掉，
#   于是 B 的断言"假应用还活着"就报失败 —— 功能全对，是**测试自己让两轮重叠**了。
#   结果文件（lastrun-*.json）是助手收尾时才写的，等它出现 = 那个助手真的干完了。
function Wait-RunFinished([string]$name, [int]$timeoutSec = 60) {
  $lastP = Join-Path $tmpDir "lastrun-$name.json"
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $lastP) { Start-Sleep -Milliseconds 500; return }
    Start-Sleep -Milliseconds 700
  }
}

# ── 场景 A：家务子代理正在写 → 不该拦（这就是今晚那个 bug）────────────────────
Write-Host '--- 场景 A：家务子代理在写 → 不该当"别人在忙"，该动手 ---'
$portA = $fakePort
$fakeA = Start-FakeApp $portA

# ★ 家务子代理照**真实形态**造：跑一会儿就结束。
#   真实的"空闲复审"子代理实测只活约 35 秒（创建 20:43:15 → 最后写 20:43:50）。
#   原来写成"永远写下去"，于是助手**永远等不到它跑完**，
#   最后按 maxWait 超时放弃 —— 测试失败但功能其实是对的（这个坑值得记下）。
$houseJob = Start-Job -ScriptBlock {
  param($f)
  $deadline = (Get-Date).AddSeconds(12)     # 只跑 12 秒，比 idleSeconds(5) 长、比 maxWait(60s) 短
  while ((Get-Date) -lt $deadline) {
    Add-Content -LiteralPath $f -Value 'tick' -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
} -ArgumentList $houseFile
Start-Sleep -Seconds 3
Check '（A 前置）子代理正在被高频写' ((Get-Item $houseFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))

$planA = New-Plan 'A' $portA
Run-Helper $planA
Wait-Verdict 'A'
Start-Sleep -Seconds 3   # 让"准备关闭 DSH"那几行也落进日志
$logA = if (Test-Path (Join-Path $tmpDir 'house-A.log')) { Get-Content (Join-Path $tmpDir 'house-A.log') -Raw -Encoding UTF8 } else { '' }
$outA = Get-Outcome 'A'

Check '★ A: 认出了"这是家务子代理"' ($logA -match '家务子代理')
Check '★ A: 说了"不算别人在忙，等它跑完"' ($logA -match '不算"别人在忙"，等它跑完')
Check '★ A: 没把它当"别人在忙"（outcome 不是 skipped-busy）' ($outA -ne 'skipped-busy') "outcome=$outA"
# ⚠️ 这条断言**只在助手确实动过手时**才有意义。
#    2026-10-10 全量跑时它偶发报红（11/12），查下来是**测试自己的锅**：
#    它起的假应用偶尔拉不起来（WMI 返回 9），于是 outcome=failed ——
#    而"认出家务并动手"这件事其实**做对了**（日志里"可以动手了"、"准备关闭 DSH"都在）。
#    把"假应用没拉起来"记成"被测功能失败"就是**假红**，会让人白查半天。
#    所以：先确认助手走完了决策链（到过"准备关闭 DSH"），再单独判结果；
#    真没走完才判失败。
$logAReachedAct = ($logA -match '准备关闭 DSH')
$outAIsHarnessGlitch = ($outA -eq 'failed' -and ($logA -match 'WMI 返回 9|创建失败'))
if ($outAIsHarnessGlitch) {
  Write-Host "     ⚠️ 注意：这次是**测试的假应用没拉起来**（WMI 9），不是被测功能的问题"
}
Check '★ A: 等它跑完后动手了' ($logAReachedAct -or $logA -match '可以动手了') $(if ($logAReachedAct) { '' } else { "outcome=$outA" })

if ($houseJob) { Stop-Job $houseJob -ErrorAction SilentlyContinue; Remove-Job $houseJob -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $fakeA.Id -Force -ErrorAction SilentlyContinue
(Get-Item $houseFile).LastWriteTime = (Get-Date).AddMinutes(-10)   # 让子代理"跑完"
Wait-RunFinished 'A'    # ★ 必须等 A 的助手彻底收工，否则它会去杀 B 的假应用

# ── 场景 B：真对话正在写 → 必须拦（安全方向）────────────────────────────────
Write-Host "`n--- 场景 B：真对话在写 → 必须拦下、绝不动手 ---"
$portB = $fakePort + 1
$fakeB = Start-FakeApp $portB
$writerB = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',
  "while (`$true) { Add-Content -LiteralPath '$realFile' -Value 'tick' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }"
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
Check '（B 前置）真对话正在被高频写' ((Get-Item $realFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))

$planB = New-Plan 'B' $portB
Run-Helper $planB
Wait-Verdict 'B'
Start-Sleep -Seconds 2
# ★ 2026-10-24 修测试时序（不是改被测行为）：
#   2026-10-22 起，"有人忙"不再当场作废，而是**等到 maxWait 上限才放弃**。
#   本场景 plan 里是 maxWaitMinutes=1，所以 outcome 要到 ~60 秒才落盘；
#   而上面 Wait-Verdict 的 60 秒刚好同时到点 —— 实测读到的是"还没写"（outcome 空），
#   功能其实是对的，是**断言抢跑了**（和 2026-10-11 那次"假红"同一类）。
#   现在：明确等结果文件出现（最多 90 秒）再断言。
$deadlineB = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadlineB -and -not (Test-Path (Join-Path $tmpDir 'lastrun-B.json'))) {
  Start-Sleep -Milliseconds 700
}
$logB = if (Test-Path (Join-Path $tmpDir 'house-B.log')) { Get-Content (Join-Path $tmpDir 'house-B.log') -Raw -Encoding UTF8 } else { '' }
$outB = Get-Outcome 'B'

Check '★ B: 认出了"别人在忙"并放弃' ($outB -eq 'skipped-busy') "outcome=$outB"
# ⚠️ 2026-10-10 文案变了（修根因②时一并改的），断言跟着改 —— 但**两条都要认**：
#   权威数据在场时，助手现在会先"再等一轮"确认，确认到时间戳还在往前走才判忙，
#   所以它说的是「**还在持续写**」；权威缺席时仍走保守老路，说的是「刚被写过」。
#   只认老文案 = 功能全对却报失败（这次就是这么红的）；只认新文案 = 看不见保守那条路。
Check '★ B: 放弃理由指向"有人在写"（新文案"还在持续写"或老文案"刚被写过"）' (
  $logB -match '盘上有 .* 个会话文件(\*\*)?还在持续写' -or $logB -match '盘上有 .* 个会话文件刚被写过'
)
Check '★ B: 用了"两轮比对"（先出现"只看见一次"再确认）' ($logB -match '只看见一次')
# ★ 2026-10-24 加：**"报在忙"的那一行也必须显示会话名，不许再甩 uuid。**
#   用户原话：「当初要求显示对话名称嘛，现在为什么第二个栏目里没显示名称？」
#   病根：10-24 那次只改了"还有 N 个别的会话在干活"这一条，另一条
#   「盘上有 N 个会话文件还在持续写」仍在用 $_.Directory.Name 直出 —— 同一行里
#   一半是名字、一半是 `session-1b64e629-…`，看着像又退回去了。
#   这里造的真对话在假档案里的标题是「某个真对话」，所以：显示名字 = 对，
#   显示 'real-conversation-0002' = 退化了。两条都断言（正反各一）。
Check '★ B: 「盘上在写」那行显示**会话名**（不是 uuid）' ($logB -match '（「某个真对话」')
Check '★ B: 「盘上在写」那行**没有**甩出原始会话 id' ($logB -notmatch '（real-conversation-0002')
Check '★ B: **没有**动手（假应用还活着）' ([bool](Get-Process -Id $fakeB.Id -ErrorAction SilentlyContinue)) "PID=$($fakeB.Id)"

Stop-Process -Id $writerB.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $fakeB.Id -Force -ErrorAction SilentlyContinue
(Get-Item $realFile).LastWriteTime = (Get-Date).AddMinutes(-10)
Wait-RunFinished 'B'    # ★ 同理：等 B 的助手收工再进 C

# ── 场景 C：子代理跑完了 → 该放行 ───────────────────────────────────────────
Write-Host "`n--- 场景 C：家务都跑完了 → 该动手 ---"
$portC = $fakePort + 2
$fakeC = Start-FakeApp $portC
$planC = New-Plan 'C' $portC
Run-Helper $planC
Wait-Verdict 'C'
Start-Sleep -Seconds 2
$logC = if (Test-Path (Join-Path $tmpDir 'house-C.log')) { Get-Content (Join-Path $tmpDir 'house-C.log') -Raw -Encoding UTF8 } else { '' }
Check '★ C: 都闲 → 动手' ($logC -match '可以动手了|准备关闭 DSH')
Stop-Process -Id $fakeC.Id -Force -ErrorAction SilentlyContinue
Wait-RunFinished 'C'

# ── 场景 D：家务永远跑不完 + 人点了「不等了」→ 该跳过等待（2026-10-24 新增）──
#
# 【为什么加这个场景】2026-10-24 实机事故：重启卡在记忆插件的复审子代理上，
#   那些子代理撞上模型限流（429），每个重试 20 次、一卡三分钟，而"等家务"没有上限
#   → 用户只能干等或打断整趟。用户要的是"看得见在等谁 + 一个能催的按钮"。
#   这里验**按钮那一路**：force.flag 出现 → 助手跳过"等家务"，继续做安全检查。
#
# ⚠️ 安全设计：这个场景的 dshExe 指向一个**不存在的路径**，所以助手走到
#    "动手前检查"就会自己退出（outcome=failed / 主程序不存在）—— 绝不会真去杀进程。
Write-Host "`n--- 场景 D：家务一直不结束 + 人点了「不等了」→ 该跳过等待 ---"
$planDPath = Join-Path $tmpDir 'plan-D.json'
$forceD = Join-Path $tmpDir 'force-D.flag'
$houseNeverEnds = Start-Job -ScriptBlock {
  param($f)
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    Add-Content -LiteralPath $f -Value 'still-working' -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
  }
} -ArgumentList $houseFile
[ordered]@{
  planId             = 'house-D'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '实测：用户点「不等了」→ 跳过等家务'
  port               = ($fakePort + 3)
  dshExe             = (Join-Path $tmpDir 'no-such-dsh.exe')   # ★ 故意不存在：走到 preflight 就停
  dshWorkDir         = $tmpDir
  idleSeconds        = 5
  maxWaitMinutes     = 2
  othersWindowSeconds = 120
  bootTimeoutSeconds = 3
  maxAttempts        = 1
  sessionFile        = $meFile
  sessionsRoot       = $sessions
  subagentCacheRoot  = $cacheRoot
  stateFile          = $stateFile
  logFile            = Join-Path $tmpDir 'house-D.log'
  lastRunFile        = Join-Path $tmpDir 'lastrun-D.json'
  cancelFile         = Join-Path $tmpDir 'cancel-D.flag'
  forceFile          = $forceD
  showWindow         = $false
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planDPath -Encoding utf8

Start-Sleep -Seconds 3
Check '（D 前置）家务子代理正在被高频写' ((Get-Item $houseFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))
Run-Helper $planDPath
# 先让它真的进入"等家务"，再写放行标记（模拟用户看了一会儿才点按钮）
$deadlineD = (Get-Date).AddSeconds(25)
$logDPath = Join-Path $tmpDir 'house-D.log'
while ((Get-Date) -lt $deadlineD) {
  if ((Test-Path $logDPath) -and (Get-Content $logDPath -Raw -Encoding UTF8) -match '家务子代理 \d+ 个还没跑完') { break }
  Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 1
Set-Content -LiteralPath $forceD -Value ('force at ' + (Get-Date).ToString('o')) -Encoding utf8
# 等助手给出结论
$deadline2 = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline2) {
  $txt = if (Test-Path $logDPath) { Get-Content $logDPath -Raw -Encoding UTF8 } else { '' }
  if ($txt -match '人工放行已生效' -or $txt -match '动手前检查') { break }
  Start-Sleep -Milliseconds 700
}
Start-Sleep -Seconds 1
$logD = if (Test-Path $logDPath) { Get-Content $logDPath -Raw -Encoding UTF8 } else { '' }
$outD = Get-Outcome 'D'
Check '★ D: 认出了"人在催"（日志写「你点了『不等了』」）' ($logD -match '你点了「不等了」')
Check '★ D: **没**被当成超时放弃（不是 skipped-busy）' ($outD -ne 'skipped-busy') "outcome=$outD"
Check '★ D: 跳过等待后继续走了安全检查' ($logD -match '人工放行已生效' -and $logD -match '动手前检查')
Check '★ D: 主程序不存在 → 安全退出（没有去关任何东西）' ($logD -match '主程序不存在')
if ($houseNeverEnds) { Stop-Job $houseNeverEnds -ErrorAction SilentlyContinue; Remove-Job $houseNeverEnds -Force -ErrorAction SilentlyContinue }

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
foreach ($p in @($fakeA, $fakeB, $fakeC, $stateKeeper, $writerB)) {
  if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
if ($houseJob) { Stop-Job $houseJob -ErrorAction SilentlyContinue; Remove-Job $houseJob -Force -ErrorAction SilentlyContinue }
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $fakeTag + '*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Start-Sleep -Seconds 1
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
