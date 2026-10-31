# 真实场景测试：助手能不能正确识别"用户机器上真的有活在跑"？
#
# 为什么单独写这个（2026-10-08 用户质疑）：
#   上一版 test-wait-when-busy.ps1 用的是**我自己造的假 state.json**，
#   而且中途是**我的测试脚本**把它改成"不忙"的 —— 那 50 秒跟用户机器上
#   有没有任务**毫无关系**。用户的质疑是对的，那个测试证明不了真实识别能力。
#
#   这一版改成：**读真实的 state.json**（插件正在写的那份），
#   看助手读到的东西跟插件写的是否一致。不造假文件。
#
# 用法：powershell -NoProfile -File test-real-state.ps1
$ErrorActionPreference = 'Stop'

# ★ 2026-10-12 脱敏：不写死某个人的 DSH 家目录。
#   认 $DSH_HOME，没有才回退 ~\.dsh（与插件本体同一套规则）。
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME.Trim() } else { Join-Path $env:USERPROFILE '.dsh' }
$realState = Join-Path $dshHome 'self-restart\state.json'
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-real-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
# ★ 2026-10-21：身份档案目录必须隔离（见 test-static-sanity ⑤ 的说明）。
#   不隔离的话助手会去读真实会话档案（本机 1451 个，冷读可达 46 秒），
#   把本套测试的时序断言全冲垮 —— 而失败信息看起来像功能 bug，极难分辨。
$cacheRoot = Join-Path $tmpDir 'subagent-cache'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$fakeTag  = 'REALTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58791

$realBefore = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：$($realBefore.Count) 个进程，监听者 PID=$realListenerBefore`n"

# 这个测试**故意**让助手读真实的 state.json（验的就是"认不认得真实状态"）。
# 但"扫盘"那条判据要指向空目录：否则助手会扫到真实会话，
# 那样测的就变成"扫盘"而不是"读 state.json"了，两个变量混在一起说不清。
$emptySessions = Join-Path $tmpDir 'sessions-empty'
New-Item -ItemType Directory -Path $emptySessions -Force | Out-Null

# ⚠️ 第一段（等"我这一轮说完"）得能**很快通过**，否则还没走到读 state.json 就超时了。
#    原来传 sessionFile=''，助手的退化逻辑要等 idleSeconds*2 = 50 秒，
#    而这里 maxWait 只有 1.2 秒 —— **卡死在第一段**，根本没读到状态文件。
#    这就是这个测试原先误报失败的真正原因（不是功能错，是没给第一段铺路）。
$meDir = Join-Path $tmpDir 'sessions-me\session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# ── 读取真实的插件状态 ──────────────────────────────────────────────────────
$live = Get-Content $realState -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host '=== 插件此刻写的真实状态 ==='
Write-Host ($live | ConvertTo-Json -Depth 4)
Write-Host ''

$liveAgeSec = ([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - ([double]$live.updatedAt / 1000)
Check '真实 state.json 是新鲜的（<30 秒）' ($liveAgeSec -le 30) "$([math]::Round($liveAgeSec)) 秒前写的"
Check '插件确实报告了在跑的会话' ([int]$live.agentsRunning -gt 0) "agentsRunning=$($live.agentsRunning)"

# ── 按插件写的真实内容，算出"助手应该怎么做"（同一套规则）────────────────────
#    这样断言就不是写死的，而是"助手的行为 == 插件写的事实推出来的预期"。
$liveSessions = @($live.runningSessions | Where-Object { $_ })
$requester = if ($liveSessions.Count -gt 0) { [string]$liveSessions[0] } else { '' }
$realOthers = @($liveSessions | Where-Object { [string]$_ -ne $requester })
if ($null -eq $live.runningSessions -and [int]$live.agentsRunning -gt 1) {
  $realOthers = @('（agentsRunning-1 估算路径）')
}
$realJobs = [int]$live.jobsRunning

# ★★ 2026-10-21 修：**第一段必须能过，否则这个测试测的根本不是它要测的东西** ★★
#
# 【病根】2026-10-13 深夜起，助手判"这一轮说完没有"**首选权威状态**
#   （读 state.json 的 agentStatusById[requestedBy]，`idle` 才算说完）。
#   而本测试的 requestedBy 取的是 `$live.runningSessions[0]` —— 那是**真实在跑**的会话，
#   它在 agentStatusById 里就是 `running`。
#   ⇒ 助手每次都在第一段等到 maxWaitMinutes 用尽 → 记 skipped-busy（理由还是"没等到这一轮说完"）
#     → **永远走不到第二段**，于是"认不认得出别的会话在忙"这条根本没被验证到。
#   ⚠️ 而它最后还是会记成 `skipped-busy`，**跟"正确放弃"的 outcome 一模一样** ——
#     于是老版本上这套测试是**假绿**：它测的是"超时放弃"，不是"认出别人在忙"。
#     决定性判据：拿改动前的旧代码（无权威判据）跑同一套 = 7/7 全绿；
#                 拿现在的代码跑 = 5/7，红的正是这两条。
#
# 【修法】第一段的权威状态要"说得过去"：把 **requestedBy 那个会话**在
#   `agentStatusById` 里临时改成 `idle`，其余会话保持真实值 ——
#   这恰好模拟了真实场景"我这一轮已经说完，现在去查别人"。
#   ⚠️ 不改真实 state.json（那是插件的文件、别的会话也在读）：造一份**副本**给它读，
#     副本只改这一个字段，其余字段全部照抄真实值 ——
#     这样"读 state.json 这条路"仍然是在验真实数据。
$requesterIsRunning = $false
if ($requester -and $live.agentStatusById) {
  $p = $live.agentStatusById.PSObject.Properties[$requester]
  if ($p -and [string]$p.Value -eq 'running') { $requesterIsRunning = $true }
}

$stateForHelper = $realState
if ($requesterIsRunning) {
  $stateForHelper = Join-Path $tmpDir 'state-me-idle.json'
  $copy = $live | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $copy.agentStatusById.$requester = 'idle'
  $copy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateForHelper -Encoding utf8
  Write-Host ("注意：请求者 {0} 此刻在 agentStatusById 里是 running —— 造一份副本、只把它改成 idle，" -f $requester)
  Write-Host '      否则助手会卡在第一段（那测的就是超时，不是"认不认得出别人在忙"）。'
  Write-Host ''
}
$expect = if ($realOthers.Count -gt 0) { 'give-up' } elseif ($realJobs -gt 0) { 'wait-jobs' } else { 'act' }
Write-Host ("预期（按真实状态推）：别的会话 {0} 个、后台任务 {1} 个 → {2}" -f $realOthers.Count, $realJobs, $expect)
Write-Host ''

# ── 假应用（占位目标，保证测试绝不动真 DSH）────────────────────────────────
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

# ── 用真实的 state.json 跑助手，看它认不认 ──────────────────────────────────
# 关键：stateFile 指向**真实的** state.json（不是造的）。
#       requestedBy 设成"真实在跑的那个会话" —— 模拟"就是这个对话请求的重启"，
#       这样助手会把"我自己"排除掉，只看**别的**会话（跟真实运行时的口径一致）。
#       idleSeconds 要小（第一段才过得快），maxWait 要够（让它有机会走到第二段）。
$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'realtest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '真实场景：能不能识别用户机器上真的在跑任务'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 3          # 会话文件是 10 分钟前的 → 第一段几秒就过
  maxWaitMinutes     = 1          # 够走到第二段（第二段是在第一段通过后**同一轮**里做的）
  othersWindowSeconds = 20
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile            # ★ 有据可依，第一段才过得去
  sessionsRoot       = $emptySessions      # 隔离扫盘判据，本测试只验"读 state.json 这条路"
  subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
  stateFile          = $stateForHelper        # ★ 真实状态（请求者若不是 idle，则用"只改它一格"的副本）
  logFile            = Join-Path $tmpDir 'real.log'
  lastRunFile        = Join-Path $tmpDir 'real-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = $requester          # 真实在跑的那个会话 = "我"
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host '--- 用真实状态跑助手（先等这一轮说完，再查状态）---'
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planPath,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

Start-Sleep -Seconds 30
$log = if (Test-Path (Join-Path $tmpDir 'real.log')) { Get-Content (Join-Path $tmpDir 'real.log') -Raw -Encoding UTF8 } else { '' }
Write-Host "`n--- 助手日志 ---`n$log----------------`n"

$fakeAlive = [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)
$lastRunPath = Join-Path $tmpDir 'real-lastrun.json'
$outcome = ''
if (Test-Path $lastRunPath) { $outcome = (Get-Content $lastRunPath -Raw -Encoding UTF8 | ConvertFrom-Json).outcome }

# ── 断言：助手的行为要跟"插件写的真实事实"一致（按同一套规则推出来的）────────
#    ★ 一律不许动手 —— 这个测试的目标是**假应用**，动它就说明逻辑错了。
#    （真 DSH 另有监听者 PID 断言兜底。）
if ($expect -eq 'give-up') {
  Check '★ 认出了真实状态里"别的会话在忙"' ($log -match '还有 \d+ 个别的会话在干活')
  Check '★ 别的会话在忙 → 放弃（不重启）' ($outcome -eq 'skipped-busy') "outcome=$outcome"
  Check '★ 放弃后**没有**动手（假应用还活着）' $fakeAlive "PID=$($fake.Id)"
  Check '日志里没有"强制动手"' ($log -notmatch '强制动手')
} elseif ($expect -eq 'wait-jobs') {
  Check '★ 只有后台任务 → 它选择"继续等"而不是放弃' ($log -match '后台任务还没跑完，继续等')
  Check '★ 等待期间**没有**动手（假应用还活着）' $fakeAlive "PID=$($fake.Id)"
  Check '日志里没有"强制动手"' ($log -notmatch '强制动手')
} else {
  Check '★ 真实状态是"闲" → 它会动手（出现"可以动手了"）' ($log -match '可以动手了')
  Check '★ 它动的是**假应用**，真 DSH 另有 PID 断言兜底' (-not $fakeAlive) "假应用 PID=$($fake.Id) 已被关掉"
}

# ── 安全断言 ────────────────────────────────────────────────────────────────
Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
$realAfter = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
# 判据用"端口监听者 PID 没变"，不用进程总数（总数会因 DSH 的临时子进程波动，会误报）
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
