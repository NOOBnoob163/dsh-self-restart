# 测"不依赖插件的独立判断"：状态文件过期时，助手还能不能看出别的会话在干活？
#
# 为什么写这个（2026-10-08）：
#   之前助手只有两条判据，都依赖插件活着 + state.json 新鲜。
#   一旦插件没加载或状态文件过期，它就只剩"盯发起重启那一个会话文件"——
#   **别的会话在干活它看不见**，可能在别人正写着的时候把 DSH 砍了。
#   这正是用户最担心的事，所以补了第三条：直接扫盘上所有会话文件。
#
# 这个测试就专门构造"状态文件过期 + 别的会话很活跃"这种最坏组合，
# 看助手认不认得出。用假目标，不碰真 DSH。
#
# 用法：powershell -NoProfile -File test-session-scan.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-scan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

$fakeTag  = 'SCANTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58799

$realBefore = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：$($realBefore.Count) 个进程，监听者 PID=$realListenerBefore`n"

# ── 造一个"完全独立的假会话目录"：状态文件说"不忙"且已过期，
#    但里面有个会话文件正在被高频写入 —— 助手该靠第三条认出来 ──────────────
$fakeSessions = Join-Path $tmpDir 'sessions'
$fakeWs = Join-Path $fakeSessions '--fake-workspace--'
$fakeSess = Join-Path $fakeWs 'session-FAKEACTIVE-0001'
New-Item -ItemType Directory -Path $fakeSess -Force | Out-Null
$fakeSessionFile = Join-Path $fakeSess 'session.v4.jsonl.zstd'

# ⚠️ 第一段（等"我这一轮说完"）得能**很快通过**，否则还没走到扫盘判据就超时了。
#    原来传 sessionFile=''，助手的退化逻辑要等 idleSeconds*2 = 50 秒，
#    而 maxWait 只有 3 秒 —— **卡死在第一段**，扫盘判据根本没机会跑。
#    这就是这个测试原先误报失败的真正原因（不是功能错，是没给第一段铺路）。
$meDir = Join-Path $tmpDir 'sessions-me\session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# 起一个后台写入器，模拟"另一个会话正在干活"
$writer = Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',
  "while (`$true) { Add-Content -LiteralPath '$fakeSessionFile' -Value 'tick' -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }"
) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Check '假会话文件正在被高频写入' ((Get-Item $fakeSessionFile).LastWriteTime -gt (Get-Date).AddSeconds(-2))

# 状态文件：说"不忙"，且时间戳是 10 分钟前（过期）
$staleState = Join-Path $tmpDir 'stale-state.json'
[ordered]@{
  updatedAt     = [long]((([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - 600) * 1000)
  jobsRunning   = 0
  agentsRunning = 0
  details       = @()
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $staleState -Encoding utf8

# 假应用（安全目标）
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

# ── 跑助手：状态文件过期、"不忙"，但假会话目录里有活跃文件 ────────────────
$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'scantest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '实测：状态过期时靠扫盘认出活跃会话'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5             # 第一段快过（会话文件是 10 分钟前的）
  maxWaitMinutes     = 1
  othersWindowSeconds = 120
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile        # ★ 有据可依，第一段才过得去
  sessionsRoot       = $fakeSessions  # ★ 指向我们的假会话目录
  subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
  stateFile          = $staleState    # ★ 过期且说"不忙"
  logFile            = Join-Path $tmpDir 'scan.log'
  lastRunFile        = Join-Path $tmpDir 'scan-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host "`n--- 跑助手（状态过期说不忙，但假会话目录有活跃文件）---"
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planPath,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

# ★ 2026-10-24 修测试时序（不是改被测行为）：
#   原来写死 `Start-Sleep -Seconds 30` 就去读结果 —— 而 2026-10-22 起，
#   「有人忙」不再当场作废，而是**等到 maxWaitMinutes 上限才放弃**（本套是 1 分钟），
#   outcome 要到 ~60 秒才落盘，30 秒时读到的是"还没有"，断言必然假红。
#   取证实录：拿改动前的助手跑同一套，红的还是这几条 —— 老账，不是 10-24 那次改坏的。
$scanLastRun = Join-Path $tmpDir 'scan-lastrun.json'
$scanDeadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $scanDeadline -and -not (Test-Path $scanLastRun)) { Start-Sleep -Milliseconds 700 }
Start-Sleep -Seconds 1
$log = if (Test-Path (Join-Path $tmpDir 'scan.log')) { Get-Content (Join-Path $tmpDir 'scan.log') -Raw -Encoding UTF8 } else { '' }
Write-Host "`n--- 助手日志 ---`n$log----------------`n"

$fakeAlive = [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)

Check '★ 靠扫盘认出了活跃会话' ($log -match '盘上有 \d+ 个会话文件刚被写过')
Check '★ 认出忙 → 没有动手' $fakeAlive "PID=$($fake.Id)"
Check '结果记为 skipped-busy' (
  (Test-Path (Join-Path $tmpDir 'scan-lastrun.json')) -and
  ((Get-Content (Join-Path $tmpDir 'scan-lastrun.json') -Raw -Encoding UTF8 | ConvertFrom-Json).outcome -eq 'skipped-busy')
)
Check '没有强制重启的痕迹' ($log -notmatch '强制动手')

# ── 反面对照：别人"早就不写了" → 应该放行（证明它不是无脑拦着）────────────
Write-Host "`n--- 反面对照：别的会话早就不写了 → 应该放行 ---"
Stop-Process -Id $writer.Id -Force -ErrorAction SilentlyContinue

# ⚠️ 光"停掉写入器"不够：第二段判的是"**最近 othersWindowSeconds 秒内**有没有被写过"，
#    刚停下来的文件仍在窗口内 → 仍算别人在忙 → 放弃。这是**设计如此**（宽窗口是有意的）。
#    要测"真的没人写了"，得把时间戳推到窗口之外（模拟"别人十分钟前就收工了"）。
(Get-Item $fakeSessionFile).LastWriteTime = (Get-Date).AddMinutes(-10)
Check '假会话文件已推到窗口之外（模拟早收工）' ((Get-Item $fakeSessionFile).LastWriteTime -lt (Get-Date).AddSeconds(-60))

$plan2 = Join-Path $tmpDir 'plan2.json'
$fake2Tag = 'SCANTEST2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
[ordered]@{
  planId             = 'scantest2'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '反面对照：没人在写就该放行'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5
  maxWaitMinutes     = 1
  othersWindowSeconds = 120
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile      # 第一段照样要过得去
  sessionsRoot       = $fakeSessions
  subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
  stateFile          = $staleState
  logFile            = Join-Path $tmpDir 'scan2.log'
  lastRunFile        = Join-Path $tmpDir 'scan2-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $plan2 -Encoding utf8

Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$plan2,'-Detached',
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

# ★ 同理：别写死 25 秒 —— 轮询"日志里出现结论"，最多等 90 秒。
#   （这一路应该几秒内就放行，但轮询比固定睡更稳，也不会因为机器慢就假红。）
$log2Path = Join-Path $tmpDir 'scan2.log'
$deadline2 = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline2) {
  $t2 = if (Test-Path $log2Path) { Get-Content $log2Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { '' }
  if ($t2 -match '可以动手了|还有别人在忙|准备关闭 DSH') { break }
  Start-Sleep -Milliseconds 700
}
Start-Sleep -Seconds 1
$log2 = if (Test-Path $log2Path) { Get-Content $log2Path -Raw -Encoding UTF8 } else { '' }
Check '★ 没人在写 → 它放行了（出现"可以动手了"）' ($log2 -match '可以动手了')

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
foreach ($p in @($fake)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $writer.Id -Force -ErrorAction SilentlyContinue
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
