# 实测（2026-10-10 修根因②）：「写过一次」≠「正在忙」
#
# 病根回放（2026-10-08 20:21:17 那次）：
#   插件 3 秒前刚更新过 state.json，明说"没有别人在跑"（权威），
#   可盘上有个会话文件"刚被写过" → 助手判"别人在忙" → **当场放弃**重启。
#   而那个文件是写了一次就再没动过的（大小一直冻结）。
#
# 修法（**不是**按"事件类型豁免 session/end-seed" —— 那不安全）：
#   同一个会话，**两轮扫盘各写一次、且时间戳还在往前走**才算"真的在动"。
#   三种情况分得很清楚：
#     · 第一次看见        → 待确认：既不放行也不放弃，再等一轮（**绝不直接动手**）
#     · 见过 + 时间戳变新 → 真的在写 → 放弃（安全方向，不退化）
#     · 见过 + 时间戳没变 → 写了一次就停 → 无害，忽略
#
# ⚠️ 为什么不能用"按事件类型豁免"（实测反例，别再走这条回头路）：
#   全机 233 个含 session/end-seed 的会话里，**163 个在它之后又继续干活了**
#   （end-seed 有 77% 出现在会话**中段**，根本不是终态标记）。
#   按类型豁免 = 可能在一个还会继续说话的会话正跑着时把 DSH 关掉 —— 用户最不能接受的方向。
#
# 不碰真 DSH：假目标 exe / 假端口 / 假会话目录 / 假身份档案目录。
# 用法：powershell -NoProfile -File test-single-write-vs-ongoing.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-single-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$fakeTag  = 'SINGLETEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58913

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ── 假会话目录 ─────────────────────────────────────────────────────────────
$sessions = Join-Path $tmpDir 'sessions'
$ws = Join-Path $sessions 'ws'

$meDir = Join-Path $ws 'session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)   # 我这一轮早说完了

# 角色①：**只写一次**的会话（模拟 session/end-seed 那种收尾写入）
$onceDir = Join-Path $ws 'session-WROTE-ONCE'
New-Item -ItemType Directory -Path $onceDir -Force | Out-Null
$onceFile = Join-Path $onceDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $onceFile -Value ('y' * 500) -Encoding ascii
(Get-Item $onceFile).LastWriteTime = (Get-Date).AddSeconds(-2)   # ★ 落在窗口**内**（这才是关键）

# 角色②：**持续在写**的会话（真在干活，必须拦住）
$ongoingDir = Join-Path $ws 'session-ONGOING'
New-Item -ItemType Directory -Path $ongoingDir -Force | Out-Null
$ongoingFile = Join-Path $ongoingDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $ongoingFile -Value ('z' * 500) -Encoding ascii

# 假身份档案目录（空的：本轮测的不是"认子代理"，是"忙闲判据"）
$fakeArchive = Join-Path $tmpDir 'archive-empty'
$fakeCache   = Join-Path $tmpDir 'cache-empty'
New-Item -ItemType Directory -Path $fakeArchive -Force | Out-Null
New-Item -ItemType Directory -Path $fakeCache -Force | Out-Null

# ── 假应用（安全目标）──────────────────────────────────────────────────────
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag)
`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $fakePort)
`$l.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8

function Start-FakeApp {
  $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag) -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 3
  return $p
}
$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

# ── 权威状态：插件说"没有别人在跑"（关键前提）──────────────────────────────
# ⚠️ 必须**持续刷新**：只写一次的话，跑第二个场景时状态已过期 → 助手退回宽窗口
#    保守判断 → 测的就不是本修法那条路了（test-stale-vs-active 里踩过这个坑）。
function Start-StateKeeper([string]$path) {
  $code = @"
while (`$true) {
  `$j = [ordered]@{
    updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    jobsRunning     = 0
    agentsRunning   = 1
    runningSessions = @('session-ME')
    runningSubagents = @()
    details         = @()
    port            = $fakePort
  } | ConvertTo-Json -Depth 5
  Set-Content -LiteralPath '$path' -Value `$j -Encoding utf8
  Start-Sleep -Seconds 3
}
"@
  return Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',$code) -PassThru -WindowStyle Hidden
}

function New-Plan([string]$name, [string]$statePath) {
  $planPath = Join-Path $tmpDir "plan-$name.json"
  [ordered]@{
    planId              = "single-$name"
    createdAt           = (Get-Date).ToString('o')
    scheduleAt          = (Get-Date).AddSeconds(-1).ToString('o')
    reason              = "实测：写过一次 vs 还在写（$name）"
    port                = $fakePort
    dshExe              = $fakeExe
    dshWorkDir          = $tmpDir
    # idleSeconds=25：第一段要连续 25 秒没动静才过，之后每 5 秒扫一次盘。
    # ⚠️ 这个值同时决定了"写过一次"的文件能在窗口里待多久 —— 至少要能覆盖**两次**
    #    扫盘（≈10 秒），否则文件在第二轮就掉出窗口，"两轮比对"这条逻辑根本测不到
    #    （第一版就是这么假通过的：文件在判定时已老化出窗口，走的是另一条分支）。
    idleSeconds         = 25
    maxWaitMinutes      = 1
    othersWindowSeconds = 120
    bootTimeoutSeconds  = 4
    maxAttempts         = 1
    sessionFile         = $meFile
    sessionsRoot        = $sessions
    stateFile           = $statePath
    subagentCacheRoot   = $fakeCache
    subagentArchiveRoot = $fakeArchive
    logFile             = (Log-Path $name)
    lastRunFile         = (LastRun-Path $name)
    cancelFile          = Join-Path $tmpDir "cancel-$name.flag"
    showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
    requestedBy         = 'session-ME'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8
  return $planPath
}

# ⚠️ 路径构造函数要**唯一**，调用方一律用它拼，不许再手写 "$name.log"。
#    第一版就是这里写岔了（调用方传 'A'、文件却叫 'singleA.log'）：
#    断言读的是空日志 → 全部报失败，而生产代码其实是对的。测试自己的 bug 最难看出来。
function Log-Path([string]$name)    { return (Join-Path $tmpDir "single-$name.log") }
function LastRun-Path([string]$name){ return (Join-Path $tmpDir "lastrun-$name.json") }

function Run-Helper([string]$planPath) {
  Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$helper,'-PlanFile',$planPath,'-Detached',
    '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
  ) -WindowStyle Hidden | Out-Null
}

function Wait-Verdict([string]$name, [int]$timeoutSec = 90) {
  $logP = Log-Path $name
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $logP) {
      $c = Get-Content $logP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
      if ($c -match '可以动手了|还有别人在忙|准备关闭 DSH') { Start-Sleep -Seconds 3; return }
    }
    Start-Sleep -Milliseconds 700
  }
}
function Get-Log([string]$name) {
  $p = Log-Path $name
  if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8) } else { return '' }
}
function Get-Outcome([string]$name) {
  $p = LastRun-Path $name
  if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).outcome } else { return '' }
}

$stateFresh = Join-Path $tmpDir 'state-fresh.json'
$stateKeeper = Start-StateKeeper $stateFresh
Start-Sleep -Seconds 4

# ══ 场景 A：权威说没别人 + 有个文件"只写过一次" → **不该**拦 ═══════════════
Write-Host '--- 场景 A：有个会话"只写过一次" → 不该当"别人在忙" ---'
$fakeA = Start-FakeApp

# ★ 掐点"只写一次"，而且**只戳一下**。
#   两个坑都踩过，记下来别再犯：
#    ① 提前设好时间戳 → 助手要等"这一轮说完"（idleSeconds=25 秒）才开始扫盘，
#       等它扫到时文件已老化出窗口 → 走的是"写过的已停"那条**老**分支，
#       根本没测到"两轮比对"（假通过）。
#    ② 每隔 9 秒戳一次 → 两次扫盘（间隔 5 秒）之间时间戳**又变了** → 被判"还在持续写"，
#       于是场景 A 反而失败（其实生产逻辑是对的，是测试把"只写一次"造歪了）。
#   所以改成：**盯着日志**等它进入扫盘阶段，再戳**一下**，然后就不动了。
#   这样第一轮扫盘看见"刚写过一次"（待确认），第二轮看见"时间戳没变"（无害）→ 放行。
$helperLogA = Log-Path 'A'
$toucher = Start-Job -ScriptBlock {
  param($logP, $file)
  # 等助手打完"开始等闲置"这一行（= 它马上要进入扫盘阶段了）
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    if ((Test-Path $logP) -and ((Get-Content $logP -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -match '开始等闲置')) { break }
    Start-Sleep -Milliseconds 400
  }
  # "开始等闲置"之后约 25 秒开始第一轮扫盘；在第 20 秒戳一下：
  # 第一轮看见它（年龄 5 秒，在窗口内）→ 待确认；第二轮（5 秒后）时间戳没变 → 无害放行。
  Start-Sleep -Seconds 20
  if (Test-Path $file) { (Get-Item $file).LastWriteTime = (Get-Date) }
} -ArgumentList $helperLogA, $onceFile

$planA = New-Plan 'A' $stateFresh
Run-Helper $planA
Wait-Verdict 'A'
$logA = Get-Log 'A'
$outA = Get-Outcome 'A'

Check '★ A: 认出了"只看见一次"并说明了在再等一轮' ($logA -match '只看见一次')
Check '★ A: 没有把它算成"别人在忙"' ($outA -ne 'skipped-busy') "outcome=$outA"
Check '★ A: 放行了（出现"可以动手了"）' ($logA -match '可以动手了')
Check '★ A: **没有**说出"还在持续写"（它就写了一次）' ($logA -notmatch '还在持续写')
if ($toucher) { Stop-Job $toucher -ErrorAction SilentlyContinue; Remove-Job $toucher -Force -ErrorAction SilentlyContinue }

Stop-Process -Id $fakeA.Id -Force -ErrorAction SilentlyContinue
Wait-Process -Id $fakeA.Id -Timeout 10 -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ══ 场景 B：权威说没别人，但盘上**真有人在不停地写** → **必须**拦住 ═══════
Write-Host "`n--- 场景 B：真有人在持续写 → 必须拦住（安全方向不许退化）---"
$fakeB = Start-FakeApp
$writer = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',
  "while (`$true) { Add-Content -LiteralPath '$ongoingFile' -Value 'tick' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }"
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
Check '（B 前置）有人在不停写' ((Get-Item $ongoingFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))

$planB = New-Plan 'B' $stateFresh
Run-Helper $planB
Wait-Verdict 'B'
# ★ 2026-10-24 修测试时序（不是改被测行为）：
#   Wait-Verdict 看到"还有别人在忙"就返回了，可那时助手**还没放弃** ——
#   2026-10-22 起，有人忙就继续等，直到 maxWaitMinutes 上限（本套 1 分钟）才落 outcome。
#   原来紧接着就读 outcome → 读到空 → 断言"认出还在持续写并放弃"假红。
#   现在明确等结果文件出现（最多 90 秒）。
$lastB = LastRun-Path 'B'
$deadlineB = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadlineB -and -not (Test-Path $lastB)) { Start-Sleep -Milliseconds 700 }
Start-Sleep -Seconds 1
$logB = Get-Log 'B'
$outB = Get-Outcome 'B'
$aliveB = [bool](Get-Process -Id $fakeB.Id -ErrorAction SilentlyContinue)

Check '★ B: 认出"还在持续写"并放弃' ($outB -eq 'skipped-busy') "outcome=$outB"
Check '★ B: 放弃理由指向"还在持续写"' ($logB -match '还在持续写')
Check '★ B: **没有**动手（假应用还活着）' $aliveB "PID=$($fakeB.Id)"
Check '★ B: 第一轮**没有**抢跑（日志里出现过"只看见一次…再等一轮确认"）' ($logB -match '只看见一次')

Stop-Process -Id $writer.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $fakeB.Id -Force -ErrorAction SilentlyContinue

# ══ 收尾 & 安全断言 ════════════════════════════════════════════════════════
Stop-Process -Id $stateKeeper.Id -Force -ErrorAction SilentlyContinue
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
