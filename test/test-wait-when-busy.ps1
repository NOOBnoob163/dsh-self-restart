# 实测：**有别的会话在忙**时，助手会不会动手？
#
# 背景（用户 问）："他会确认有其他任务正在跑时不自动重启吗？"
#
# ⚠️ 2026-10-08 用户改了策略，**两种"忙"要分开**（本测试据此重写）：
#    · **别的会话/对话**在忙   → 直接放弃（机会作废，不排队等）   ← 本测试
#    · 只有**后台任务**在跑     → 等它跑完；这期间一旦有别的对话进来就放弃
#                                  ← 由 test-jobs-soft-wait.ps1 专门测
#
# 这个测试**不碰真 DSH**：用假目标（-TargetProcessName powershell + -TargetCommandMatch 标记），
# 计划里的 port 也指向假端口、sessionsRoot 指向空目录。要验的是**判断逻辑**：
#   ① 有别的会话在跑     → 放弃，绝不动手（假应用必须还活着）
#   ② state.json 过期（>30 秒没更新）→ **不**据此判忙，该动手就动手
#
# 用法：powershell -NoProfile -File test-wait-when-busy.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-busy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
# ★ 2026-10-21：身份档案目录必须隔离（见 test-static-sanity ⑤ 的说明）。
#   不隔离的话助手会去读真实会话档案（本机 1451 个，冷读可达 46 秒），
#   把本套测试的时序断言全冲垮 —— 而失败信息看起来像功能 bug，极难分辨。
$cacheRoot = Join-Path $tmpDir 'subagent-cache'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

$fakeTag  = 'BUSYTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58783

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

# 安全基线
$realBefore = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：$($realBefore.Count) 个进程，监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ⚠️ 必须把"扫盘"那条判据也隔离掉（2026-10-08 补）：
#    助手新增了判据 —— 直接扫 <DSH家目录>\sessions 看谁在写。
#    本测试若不隔离它，助手会扫到**真实会话**（用户正在用的那个），
#    于是"改成不忙就该动手"永远失败 —— 不是功能错，是测试没隔离。
#    给它一个空目录，本测试就只验"state.json 这条路"。
$emptySessions = Join-Path $tmpDir 'sessions-empty'
New-Item -ItemType Directory -Path $emptySessions -Force | Out-Null

# ⚠️ 第一段（等"我这一轮说完"）必须能**很快通过**，否则测试还没走到"查别人"就超时了。
#    原来这些测试传 sessionFile=''，助手的退化逻辑要等 idleSeconds*2（50 秒），
#    而 maxWaitMinutes=1 —— 结果**卡在第一段就超时**，根本没走到忙闲判断。
#    这正是旧版测试误报失败的真正原因（不是功能错，是测试没给第一段铺路）。
#    所以这里给一个"早就不动了"的会话文件：第一段几秒就能过。
$meDir = Join-Path $tmpDir 'sessions-me\session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# 假应用（占位，让助手有"目标"可找）
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

# ── 造一个"硬忙"的 state.json：**有别的会话**在跑（这才是"放弃"的理由）──────
#    注意 runningSessions 要真的列出"别的"会话：助手只数**除发起者之外**的会话，
#    光写 agentsRunning=2 不够准（那是兜底估算路径）。
$stateFile = Join-Path $tmpDir 'state.json'
[ordered]@{
  updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
  jobsRunning     = 3
  agentsRunning   = 2
  runningSessions = @('session-ME', 'session-SOMEONE-ELSE')
  details         = @('后台任务 job-x 在跑')
  port            = $fakePort
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding utf8

$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'busytest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '实测：有别的会话在忙时必须放弃'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5           # 第一段快过
  # ⚠️ 2026-10-23 改：原来是 1（=60 秒），而本场景只等 30 秒就检查。
  #   旧代码"一见到忙就作废"时它能过，但那是**假的** —— 上限从来没被真的等过
  #   （生产日志 09:10：写着"最多等 60 分钟"，实际 20 秒就放弃）。
  #   修好"到点才作废"之后，1 分钟在 30 秒窗口内到不了点 → 必然等满超时。
  #   改成 0.3 分钟（18 秒），本场景才是在真的测"到点作废"。
  maxWaitMinutes     = 0.3
  othersWindowSeconds = 20
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile     # 第一段有据可依 → 几秒就过
  sessionsRoot       = $emptySessions   # 隔离扫盘判据，避免扫到真实会话
  subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
  stateFile          = $stateFile
  logFile            = Join-Path $tmpDir 'busy.log'
  lastRunFile        = Join-Path $tmpDir 'busy-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host "--- 场景 A：state.json 说「还有 1 个别的会话在跑」→ 必须放弃、绝不动手 ---"
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planPath,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

Start-Sleep -Seconds 30
$stillAlive = [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)
$log = if (Test-Path (Join-Path $tmpDir 'busy.log')) { Get-Content (Join-Path $tmpDir 'busy.log') -Raw -Encoding UTF8 } else { '' }
$outcomeA = ''
if (Test-Path (Join-Path $tmpDir 'busy-lastrun.json')) {
  $outcomeA = (Get-Content (Join-Path $tmpDir 'busy-lastrun.json') -Raw -Encoding UTF8 | ConvertFrom-Json).outcome
}

Check '★ 有别的会话时**没有**动手（假应用还活着）' $stillAlive "PID=$($fake.Id)"
Check '★ 日志说明有人在忙' ($log -match '还有 \d+ 个别的会话在干活|还有别人在忙')
# ★ 2026-10-22 改：这条测的是**设了等待上限**（maxWaitMinutes=1）时的老语义 ——
#   到点仍然作废（这是有意保留的：想设上限的人就该得到"到点放弃"）。
#   "默认一直等"那条新语义由下面场景 A2 负责测（它用 maxWaitMinutes=0）。
#   ⚠️ 两条都留着：一条测"有上限时到点作废"，一条测"没上限时一直等"，别合并。
Check '★ 设了上限时，到点仍记 skipped-busy（保留的老语义）' ($outcomeA -eq 'skipped-busy') "outcome=$outcomeA"
Check '日志里说"不重启了"（到点放弃）' ($log -match '这次不重启了')
Check '日志**没有**出现"可以动手了"' ($log -notmatch '可以动手了')

# ── 场景 A2（2026-10-22 新增）：**默认值 maxWaitMinutes=0 = 一直等**────────────────
# 这是排队重启的核心新语义：别人在忙 → 不作废、继续等，永远不动手。
# ⚠️ 为什么必须单独测：上面场景 A 用的是 maxWaitMinutes=1（正数），走的是"到点作废"分支，
#    **根本没覆盖默认值那条路** —— 而默认值才是用户天天会遇到的那条。
Write-Host "`n--- 场景 A2：maxWaitMinutes=0（默认）→ 别人在忙就**一直等**，不许作废 ---"
$planA2 = Join-Path $tmpDir 'plan-a2.json'
$fakeA2 = $fake
# ⚠️ 必须**重新写一份新鲜的 state.json**：场景 A 那份此刻已经放了半分钟，
#    助手会判它"过期不可信"，于是退回扫盘；而扫盘目录是空的 → 它认为没人在忙 → 直接发车。
#    第一版就栽在这里（日志原文：「状态文件已 33 秒没更新（不算忙，改看盘上谁在写）」→「可以动手了」）。
$stateA2 = Join-Path $tmpDir 'state.json'
[ordered]@{
  updatedAt       = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds)
  jobsRunning     = 0               # 只要"别人在忙"，不要后台任务干扰
  agentsRunning   = 2
  runningSessions = @('session-ME', 'session-SOMEONE-ELSE')
  details         = @('会话 session-SOMEONE-ELSE 正在跑')
  port            = $fakePort
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateA2 -Encoding utf8
[ordered]@{
  planId             = 'a2test'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).ToString('o')
  reason             = '实测：默认值下别人在忙要一直等'
  port               = 59999
  dshExe             = (Join-Path $tmpDir 'fake.exe')
  dshWorkDir         = $tmpDir
  idleSeconds        = 1
  confirmSeconds     = 0
  maxWaitMinutes     = 0          # ← 默认值：一直等
  bootTimeoutSeconds = 2
  maxAttempts        = 1
  showWindow         = $false
  requestedBy        = 'session-ME'
  sessionFile        = $meFile
  # ⚠️ 隔离扫盘：指向空目录，绝不扫到真实会话（跟场景 A 同一套隔离）
  sessionsRoot       = $emptySessions
  subagentCacheRoot  = $cacheRoot
  stateFile          = $stateA2
  logFile            = Join-Path $tmpDir 'a2.log'
  lastRunFile        = Join-Path $tmpDir 'a2-lastrun.json'
  # ⚠️ 取消文件必须**跟场景 B 用不同的名字**：
  #    第一版沿用了 'cancel.flag'，A2 收尾时写的那一下把接着跑的**场景 B 一起取消了**。
  cancelFile         = (Join-Path $tmpDir 'cancel-a2.flag')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planA2 -Encoding utf8
Remove-Item -LiteralPath (Join-Path $tmpDir 'cancel-a2.flag') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $tmpDir 'a2-lastrun.json') -Force -ErrorAction SilentlyContinue

# 直接跑助手（带目标名指向"那个带 fakeTag 的 powershell 假应用"，绝不碰真 DSH）
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\dsh-self-restart.ps1'
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planA2,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 24
$aliveA2 = [bool](Get-Process -Id $fakeA2.Id -ErrorAction SilentlyContinue)
$logA2 = if (Test-Path (Join-Path $tmpDir 'a2.log')) { Get-Content (Join-Path $tmpDir 'a2.log') -Raw -Encoding UTF8 } else { '' }
# ⚠️ 必须在**发取消标记之前**就把"有没有结果文件"记下来。
#    第一版是在收尾之后才判，而收尾的取消标记会让助手写下 outcome=cancelled →
#    这条断言必然红（2026-10-22 实测踩到）。
$hadResultA2 = Test-Path (Join-Path $tmpDir 'a2-lastrun.json')
$outcomeA2 = ''
if ($hadResultA2) {
  $outcomeA2 = (Get-Content (Join-Path $tmpDir 'a2-lastrun.json') -Raw -Encoding UTF8 | ConvertFrom-Json).outcome
}
# 收尾：发取消标记让它退出，别留孤儿进程。
# ⚠️ 用 **A2 自己的** cancel-a2.flag，别碰场景 B 要用的那个（2026-10-22 踩过：
#    第一版这里写的是 cancel.flag，把紧接着跑的**场景 B 一起取消了**）。
'manual cleanup' | Set-Content -LiteralPath (Join-Path $tmpDir 'cancel-a2.flag') -Encoding utf8
Start-Sleep -Seconds 3

Check 'A2: 默认值下**没有**动手（假应用还活着）' $aliveA2 "PID=$($fakeA2.Id)"
Check 'A2: ★ 没有作废（不该写 skipped-busy）' ($outcomeA2 -ne 'skipped-busy') "outcome=$outcomeA2"
# ★ 2026-10-22：这条原来断言日志里出现"继续等"三个字，实测**太脆** ——
#   "继续等"那句日志有 `$tick % 5 -eq 1` 的节流，而循环每轮 sleep 5 秒，
#   24 秒窗口里可能只打出一两条；测试等不到就假红。
#   改成断言**不变量**（才真正说明"它还在等、没走"）：
#     ① 没写过任何结果文件（作废/失败/成功都会写）；
#     ② 日志里没有任何"动手"的迹象；
#     ③ 日志里有"一直在等"的启动声明（maxWaitMinutes=0 那一行），证明走的是"一直等"分支。
$logA2Flat = $logA2 -replace '\s+', ''
Check 'A2: ★ 没写过结果文件（说明它还在等，没结束）' (-not $hadResultA2)
Check 'A2: ★ 日志里**没有**"可以动手了"' ($logA2 -notmatch '可以动手了')
Check 'A2: 日志里**没有**关闭进程的迹象' ($logA2 -notmatch '准备关闭|taskkill|已完全退出')
Check 'A2: 走的是"一直等下去"分支（maxWaitMinutes=0）' ($logA2Flat -match 'maxWaitMinutes=0')

Write-Host "`n--- 场景 B：state.json 过期（模拟 DSH 卡死），不该据此判忙 ---"
$staleFile = Join-Path $tmpDir 'state-stale.json'
[ordered]@{
  updatedAt     = [long]((([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds) - 600) * 1000   # 10 分钟前
  jobsRunning   = 9
  agentsRunning = 9
  details       = @()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $staleFile -Encoding utf8

$plan2 = Join-Path $tmpDir 'plan2.json'
$fake2 = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2

[ordered]@{
  planId             = 'staletest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '实测：过期状态不该判忙'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5
  maxWaitMinutes     = 1
  othersWindowSeconds = 20
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile
  sessionsRoot       = $emptySessions   # 同上：隔离扫盘判据
  subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
  stateFile          = $staleFile
  logFile            = Join-Path $tmpDir 'stale.log'
  lastRunFile        = Join-Path $tmpDir 'stale-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $plan2 -Encoding utf8

Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$plan2,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

Start-Sleep -Seconds 30
$log2 = if (Test-Path (Join-Path $tmpDir 'stale.log')) { Get-Content (Join-Path $tmpDir 'stale.log') -Raw -Encoding UTF8 } else { '' }
$staleGone = -not [bool](Get-Process -Id $fake2.Id -ErrorAction SilentlyContinue)

Check '过期状态被判为「没更新」而不是「忙」' ($log2 -match '没更新')
Check '★ 过期状态**不**阻止重启（它动手了）' $staleGone
Check '日志里没有把 9 个任务当成"在跑"' ($log2 -notmatch '还有 9 个后台任务')

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
foreach ($p in @($fake, $fake2)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$realAfter = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
# 判据用"端口监听者 PID 没变"，**不用进程总数**：
# 进程总数会因为 DSH 给自己起的临时子进程（跑命令用的）而波动，那是正常现象，
# 拿它当"有没有被破坏"的判据会误报（2026-10-08 实测踩到）。
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
