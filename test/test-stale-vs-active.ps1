# 实测（2026-10-08 用户报的真 bug）：
#   「它刚刚好像没正确识别对话有没有结束」
#
# 真实现场回放（20:21:17 那次）：
#   · 插件 3 秒前刚更新过 state.json，runningSessions **只有我自己**
#     → 权威地说"没有别人在跑"
#   · 但助手扫盘发现"有个别的会话文件 **101 秒前**被写过"
#     → 判"别人在忙" → **放弃**
#   而那个文件其实 20:19:36 写了一次就再没动过（大小冻结 61,058 字节）——
#   它只是"最近被写过"，不是"正在干活"。
#   **错在拿"猜的"(看时间戳) 去推翻"权威的"(插件直接问服务)。**
#
# 本测试就复现这一条，并验证修好之后：
#   ① 权威数据在 → "写过一次就停了"的文件**不该**拦着重启
#   ② 权威数据在 → "**正在不停地写**"的文件**必须**拦住（安全方向不能丢）
#   ③ 权威数据**缺席/过期** → 仍然退回宽窗口保守判断（宁可漏做，不砍断别人的活）
#
# 不碰真 DSH：假目标 exe / 假端口 / 假会话目录。
# 用法：powershell -NoProfile -File test-stale-vs-active.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-stale-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
# ★ 2026-10-21：身份档案目录必须隔离（见 test-static-sanity ⑤ 的说明）。
#   不隔离的话助手会去读真实会话档案（本机 1451 个，冷读可达 46 秒），
#   把本套测试的时序断言全冲垮 —— 而失败信息看起来像功能 bug，极难分辨。
$cacheRoot = Join-Path $tmpDir 'subagent-cache'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

$fakeTag  = 'STALETEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58831

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ── 假会话目录：一个"我"，一个"别人（写过一次就停了）"，一个"别人（还在写）"──
$sessions = Join-Path $tmpDir 'sessions'
$ws = Join-Path $sessions 'ws'

$meDir = Join-Path $ws 'session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# ★ 关键角色：写过一次就停了的"别人"（复现真实现场）
$staleDir = Join-Path $ws 'session-STALE-ONCE'
New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
$staleFile = Join-Path $staleDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $staleFile -Value ('x' * 1000) -Encoding ascii
(Get-Item $staleFile).LastWriteTime = (Get-Date).AddSeconds(-101)   # ★ 就是当时的 101 秒

$activeDir = Join-Path $ws 'session-ACTIVELY-WRITING'
New-Item -ItemType Directory -Path $activeDir -Force | Out-Null
$activeFile = Join-Path $activeDir 'session.v4.jsonl.zstd'

# 假应用
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag, [int]`$Port)
`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$Port)
`$l.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
# ⚠️ 每个场景都要**起自己的假应用**：场景 A 成功动手后会把它关掉，
#    若 B/C 复用同一个进程对象，断言就会拿一个"已经被 A 杀掉"的旧进程去判断（踩过一次）。
function Start-FakeApp {
  $p = Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag,'-Port',$fakePort
  ) -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 3
  return $p
}
$fakeA = Start-FakeApp

$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

# ── 权威状态：**只有我自己在跑**（照实况写）──────────────────────────────────
$stateFresh = Join-Path $tmpDir 'state-fresh.json'
function Write-FreshState([string]$Path) {
  [ordered]@{
    updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    jobsRunning     = 0
    agentsRunning   = 1
    runningSessions = @('session-ME')       # ★ 只有我 → 权威地说"没有别人"
    details         = @()
    port            = $fakePort
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
}
Write-FreshState $stateFresh

# ⚠️ 场景 A/B 要验的是"**权威数据在场**时的行为"，所以这份状态必须**一直是新鲜的**。
#    原来只写一次，等 B 跑到时已经过了 30 多秒 → 助手判它"过期"→ 走了宽窗口那条路
#    → 测的根本不是我想测的分支（踩过一次）。
#    真插件每 10 秒刷新一次，这里就用一个后台刷新器照做（3 秒一次，更宽裕）。
$stateKeeper = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',
  "while (`$true) { `$j = [ordered]@{ updatedAt = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds); jobsRunning = 0; agentsRunning = 1; runningSessions = @('session-ME'); details = @(); port = $fakePort } | ConvertTo-Json -Depth 5; Set-Content -LiteralPath '$stateFresh' -Value `$j -Encoding utf8; Start-Sleep -Seconds 3 }"
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 4
$keeperAge = ([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - (([double]((Get-Content $stateFresh -Raw -Encoding UTF8 | ConvertFrom-Json).updatedAt)) / 1000)
Check '（前置）权威状态保持新鲜' ($keeperAge -lt 10) "$([math]::Round($keeperAge)) 秒前"

function New-Plan([string]$name, [string]$statePath, [string]$logName, [int]$idle = 5, [int]$others = 120) {
  $planPath = Join-Path $tmpDir "plan-$name.json"
  [ordered]@{
    planId             = "stale-$name"
    createdAt          = (Get-Date).ToString('o')
    scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
    reason             = "实测：写过一次就停了 vs 正在写（$name）"
    port               = $fakePort
    dshExe             = $fakeExe
    dshWorkDir         = $tmpDir
    idleSeconds        = $idle
    maxWaitMinutes     = 1
    othersWindowSeconds = $others
    bootTimeoutSeconds = 4
    maxAttempts        = 1
    sessionFile        = $meFile
    sessionsRoot       = $sessions
    subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
    stateFile          = $statePath
    logFile            = Join-Path $tmpDir $logName
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

# ★ 2026-10-24 加：等"结果真的落盘"再断言，别用写死的 25 秒。
#   病根（不是被测代码的问题，是测试抢跑）：
#     2026-10-22 起，「有人忙」不再当场作废，而是**一直等到 maxWaitMinutes 上限**才放弃。
#     本套 plan 里是 maxWaitMinutes=1 → outcome 要到 ~60 秒才写盘。
#     而这里原来是 `Start-Sleep -Seconds 25` 就去读 → 读到空 → 断言"不是 skipped-busy"失败。
#   取证实录：拿改动前的助手（E 盘备份）跑**同一套**，红的是同样三条 —— 是**老账**，
#     跟 10-24 那次"会话名"改动无关。（同一类假红 10-24 已在 housekeeping 场景 B 修过一次。）
#   修法照 housekeeping 的写法：明确轮询结果文件，给足 90 秒。
function Wait-Result([string]$name, [int]$timeoutSec = 90) {
  $p = Join-Path $tmpDir "lastrun-$name.json"
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $p) { Start-Sleep -Milliseconds 600; return }
    Start-Sleep -Milliseconds 700
  }
}
function Read-Outcome([string]$name) {
  $p = Join-Path $tmpDir "lastrun-$name.json"
  if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).outcome }
  return ''
}

# ── 场景 A：权威数据在 + "别人"写过一次就停了 → **不该**拦着，应该动手 ────────
Write-Host "--- 场景 A：权威说没别人 + 某文件 101 秒前写过一次 → 不该拦（这就是那个 bug）---"
$planA = New-Plan 'A' $stateFresh 'staleA.log'
Run-Helper $planA
Wait-Result 'A'
$logA = if (Test-Path (Join-Path $tmpDir 'staleA.log')) { Get-Content (Join-Path $tmpDir 'staleA.log') -Raw -Encoding UTF8 } else { '' }
$outA = Read-Outcome 'A'

Check '★ A: 没再拿"101 秒前写过"当别人在忙' ($outA -ne 'skipped-busy') "outcome=$outA"
Check '★ A: 它动手了（出现"可以动手了"）' ($logA -match '可以动手了')
Check 'A: 日志解释了"写过但已停的不算在忙"' ($logA -match '已停了|不算"在忙"')

# ── 场景 B：权威数据在 + "别人"**正在不停地写** → **必须**拦住（安全方向）────
Write-Host "`n--- 场景 B：权威说没别人，但盘上真有人在**不停地写** → 必须拦住 ---"
$fakeB = Start-FakeApp          # ★ 自己的假应用（A 那个已经被关掉了）
$writer = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',
  "while (`$true) { Add-Content -LiteralPath '$activeFile' -Value 'tick' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }"
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
Check '（B 前置）有人在不停写' ((Get-Item $activeFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))

$planB = New-Plan 'B' $stateFresh 'staleB.log'
Run-Helper $planB
Wait-Result 'B'
$logB = if (Test-Path (Join-Path $tmpDir 'staleB.log')) { Get-Content (Join-Path $tmpDir 'staleB.log') -Raw -Encoding UTF8 } else { '' }
$outB = Read-Outcome 'B'
$aliveB = [bool](Get-Process -Id $fakeB.Id -ErrorAction SilentlyContinue)

Check '★ B: 认出"有人正在写"并放弃' ($outB -eq 'skipped-busy') "outcome=$outB"
Check '★ B: 放弃理由是"有人正在写"' ($logB -match '正在不停写|刚被写过')
Check '★ B: **没有**动手（假应用还活着）' $aliveB "PID=$($fakeB.Id)"

Stop-Process -Id $writer.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $fakeB.Id -Force -ErrorAction SilentlyContinue

# ── 场景 C：权威数据**过期** + 同一个"写过一次就停"的文件 → 该保守（宽窗口）──
Write-Host "`n--- 场景 C：权威数据过期 → 退回宽窗口保守判断（宁可漏做，不砍断别人的活）---"
# ⚠️ 先把刷新器停掉，否则状态会一直是新鲜的，就测不到"过期"这条路。
Stop-Process -Id $stateKeeper.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 把那个文件的"年龄"退回 101 秒（场景 B 的 writer 动过它，这里重新造一个干净的）
(Get-Item $staleFile).LastWriteTime = (Get-Date).AddSeconds(-101)
$stateStale = Join-Path $tmpDir 'state-stale.json'
[ordered]@{
  updatedAt       = [long]((([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - 600) * 1000)  # 10 分钟前
  jobsRunning     = 0
  agentsRunning   = 1
  runningSessions = @('session-ME')
  details         = @()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateStale -Encoding utf8

$fakeC = Start-FakeApp          # ★ 自己的假应用
$planC = New-Plan 'C' $stateStale 'staleC.log'
Run-Helper $planC
Wait-Result 'C'
$logC = if (Test-Path (Join-Path $tmpDir 'staleC.log')) { Get-Content (Join-Path $tmpDir 'staleC.log') -Raw -Encoding UTF8 } else { '' }
$outC = Read-Outcome 'C'

Check 'C: 状态过期时明确记了"没更新"' ($logC -match '没更新')
Check '★ C: 过期 → 保守放弃（宽窗口仍然生效）' ($outC -eq 'skipped-busy') "outcome=$outC"
Check '★ C: 保守放弃时**没有**动手（假应用还活着）' ([bool](Get-Process -Id $fakeC.Id -ErrorAction SilentlyContinue)) "PID=$($fakeC.Id)"

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
foreach ($p in @($fakeA, $fakeB, $fakeC, $stateKeeper, $writer)) {
  if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
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
