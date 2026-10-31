# 实测（用户 亲自定的规则）：
#   「等后台任务等一段时间，期间要是有新的对话进来，就放弃。」
#
# 两种"忙"要分开：
#   · **只有后台任务**在跑 → **等它**（不放弃），这期间一旦有别的会话进来 → 放弃
#   · **有别的会话**在忙   → 立刻放弃（由 test-wait-when-busy.ps1 测）
#
# 本测试不碰真 DSH：假目标 exe / 假端口 / 假会话目录。
#
# 用法：powershell -NoProfile -File test-jobs-soft-wait.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-jobs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$fakeTag  = 'JOBSTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58811

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# 会话目录：一开始只有"我"，稍后会有"别人"出现
$sessions = Join-Path $tmpDir 'sessions'
$meDir   = Join-Path $sessions 'ws\session-ME'
$otherDir = Join-Path $sessions 'ws\session-NEWCOMER'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# ★★ 2026-10-21 补：身份档案目录必须隔离（本仓红线，这两套漏了）★★
#
# 【为什么】助手判"盘上那个会话是子代理还是别人的真对话"时，会去读
#   `%DSH_HOME%\storages\session_projcache_archive_manager_v2\sessions\` 建映射。
#   本测试的会话全是自己造的假会话，**没有任何理由**去翻真实档案；
#   而同仓 `test-housekeeping-subagent.ps1` / `test-single-write-vs-ongoing.ps1`
#   早就传了 `subagentCacheRoot`，只有这里漏了 —— 属于补齐红线，不是新功能。
#   ⚠️ 它**不是**那次报红的原因（实测冷读 46 秒、热读 3 秒，去掉隔离照样能过）；
#      留着是因为"测试不该读真实数据"这条本身要守，且能省掉每次 3 秒的冷读开销。
$cacheRoot = Join-Path $tmpDir 'subagent-cache'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

# 假应用
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag)
`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $fakePort)
`$l.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
$fake = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

# state.json：**只有后台任务**在跑，没有别的会话
$stateFile = Join-Path $tmpDir 'state.json'
function Write-State([int]$Jobs, [object[]]$Sessions) {
  $all = @('session-ME') + @($Sessions)
  # ★ 2026-10-21 补 `agentStatusById`：助手判"这一轮说完没有"**首选权威状态**
  #   （读这个字段里 requestedBy 那一格）。不写它就会退回"文件静默 N 秒"那条兜底，
  #   兜底要多等一轮、把测试的时序搅乱。这里显式声明"ME 已经 idle"，
  #   把变量收敛到"后台任务"这一个（字段口径同插件 writeState()：{ 会话id: 'idle'|'running' }）。
  $statusById = [ordered]@{ 'session-ME' = 'idle' }
  foreach ($s in @($Sessions)) { $statusById[[string]$s] = 'running' }
  [ordered]@{
    updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
    jobsRunning     = $Jobs
    agentsRunning   = 1 + @($Sessions).Count
    runningSessions = $all
    agentStatusById = $statusById
    details         = @()
    port            = $fakePort
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8
}
Write-State 2 @()

$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'jobstest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '实测：后台任务该等，新对话进来该放弃'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5
  maxWaitMinutes     = 1           # ★ 2026-10-24 改：不再"看到别人忙就立刻作废"（10-22 改成排队等），
                                   #   所以这条测的是"等到上限才放弃"。1 分钟足够短，又能先证明它肯等。
  othersWindowSeconds = 120        # 用真实默认值：靠扫盘发现"新人"
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile
  sessionsRoot       = $sessions
  subagentCacheRoot  = $cacheRoot    # ★ 指向空目录，绝不读真实会话的身份档案（见上面的说明）
  stateFile          = $stateFile
  logFile            = Join-Path $tmpDir 'jobs.log'
  lastRunFile        = Join-Path $tmpDir 'jobs-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host "--- 场景：只有后台任务在跑 → 它应该**等**（不放弃、不动手） ---"
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planPath,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

# 等 20 秒：这段时间它必须"继续等后台任务"，绝不放弃、绝不动手
Start-Sleep -Seconds 20
$log1 = if (Test-Path (Join-Path $tmpDir 'jobs.log')) { Get-Content (Join-Path $tmpDir 'jobs.log') -Raw -Encoding UTF8 } else { '' }
$aliveDuring = [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)

Check '★ 只有后台任务时**不放弃**（日志没有"机会作废"）' ($log1 -notmatch '机会作废')
# 文案 2026-10-08 改成同时能说后台任务和家务子代理，所以这里放宽成"说到还没跑完、还在等"。
Check '★ 日志写明"还没跑完，继续等"' ($log1 -match '(后台任务|家务子代理) .*还没跑完，继续等')
Check '★ 等待期间**没有**动手（假应用还活着）' $aliveDuring "PID=$($fake.Id)"

Write-Host "`n--- 场景续：这时**有新的对话进来** → 它应该继续等，到上限才放弃 ---"
# "新对话"出现：盘上多一个别的会话文件，刚被写过（= 有人在用那个对话）
New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
$otherFile = Join-Path $otherDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $otherFile -Value 'y' -Encoding ascii
(Get-Item $otherFile).LastWriteTime = (Get-Date)

# ★ 2026-10-24：10-22 起"别人在忙"不再当场作废，而是**排队等**（等到 maxWait 才放弃）。
#   所以这里改成"等结果文件出现"（最多 75 秒），不再盲等 25 秒就断言 ——
#   原来那版在改行为之后必然读到空结果（功能对、断言抢跑）。
$deadline = (Get-Date).AddSeconds(75)
while ((Get-Date) -lt $deadline -and -not (Test-Path (Join-Path $tmpDir 'jobs-lastrun.json'))) {
  Start-Sleep -Milliseconds 700
}
$log2 = if (Test-Path (Join-Path $tmpDir 'jobs.log')) { Get-Content (Join-Path $tmpDir 'jobs.log') -Raw -Encoding UTF8 } else { '' }
$outcome = ''
if (Test-Path (Join-Path $tmpDir 'jobs-lastrun.json')) {
  $outcome = (Get-Content (Join-Path $tmpDir 'jobs-lastrun.json') -Raw -Encoding UTF8 | ConvertFrom-Json).outcome
}
$aliveAfter = [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)

Check '★ 有新对话时继续等（不作废）' (($log2 -match '继续等，不硬闯' -or $log2 -match '还有别人在忙') -and ($log2 -notmatch '机会作废')) '应看到「继续等，不硬闯」'
Check '★ 到上限才放弃（记 skipped-busy）' ($outcome -eq 'skipped-busy') "outcome=$outcome"
Check '★ 放弃的理由指向**别人**，不是后台任务' ($log2 -match '还有别人在忙|盘上有.*会话文件刚被写过')
Check '★ 放弃之后**没有**动手（假应用还活着）' $aliveAfter "PID=$($fake.Id)"
Check '★ 计划文件已清掉（这一趟结束，不留假状态）' (-not (Test-Path $planPath))

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
