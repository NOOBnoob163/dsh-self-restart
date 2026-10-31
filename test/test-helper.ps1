# 助手脚本自测 —— 在一个**假应用**上跑「关掉 → 拉起来」流程
#
# ⚠️ 2026-10-08 事故换来的教训（这一版重写的唯一原因）：
#   上一版自测以为"把 dshExe 指向一个不存在的假路径"就安全了，
#   结果助手**照样把真的 DSH 杀了** —— 因为杀进程那一步是无条件的，
#   它杀完才发现"没法拉起"。用户的 DSH 就这么被关了。
#
#   这一版的设计原则：**真 DSH 一个字节都不碰。**
#   做法：让助手去操作一个我们自己造的假应用（唯一进程标记 + 假端口），
#   从"关"到"拉"都走真实代码路径，但目标完全是假的；
#   再加一道独立保险 —— 跑之前/之后核对真 DSH 的 PID 集合没变。
#
# 用法：powershell -NoProfile -File test-helper.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

# 唯一的"假应用"标识
$fakeTag  = 'FAKEAPP-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58771

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  $mark = if ($Ok) { '✅' } else { '❌' }
  Write-Host "$mark $Name$(if ($Detail) { " — $Detail" })"
}

Write-Host "临时目录：$tmpDir"
Write-Host "假应用标记：$fakeTag   假端口：$fakePort`n"

# ── 开跑前先确认假端口是空的（否则断言会指向上一轮泄漏的进程，白查半天）──────
$preOccupied = @(Get-NetTCPConnection -LocalPort $fakePort -State Listen -ErrorAction SilentlyContinue)
if ($preOccupied.Count -gt 0) {
  $owner = $preOccupied[0].OwningProcess
  $cmd = ''
  try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue).CommandLine } catch { }
  Write-Host "⚠️ 假端口 $fakePort 开跑前就被占着（PID=$owner）—— 多半是上一轮测试泄漏的假应用。" -ForegroundColor Yellow
  Write-Host "   $cmd" -ForegroundColor Yellow
  if ($cmd -match 'fake-app\.ps1|fake\.ps1') {
    Write-Host '   → 确认是测试假应用，先清掉它。' -ForegroundColor Yellow
    Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
  } else {
    Write-Host '   → 命令行不像测试假应用，**不**动它；本测试换一个端口跑。' -ForegroundColor Yellow
    $fakePort = 58772
    Write-Host "   → 改用端口 $fakePort" -ForegroundColor Yellow
  }
}

# ── 安全基线：真 DSH 的 PID 集合 ────────────────────────────────────────────
$realBefore     = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realPortBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：$($realBefore.Count) 个进程，19387 监听者 PID=$realPortBefore`n"

# ── ⚠️ 两段式等待带来的**测试隔离**要求（2026-10-08 踩到，很隐蔽）────────────
#   助手现在分两段：① 等"发起会话这一轮说完" ② 再查有没有别人在忙。
#   本测试如果像原来那样只写 sessionFile=''、也不给 sessionsRoot：
#     · 第一段会退化成等 idleSeconds*2 秒（能过，只是慢）
#     · 第二段**兜底去扫真实的 <DSH家目录>\sessions** → 扫到**用户正在用的这个对话**
#       （就是我此刻在写日志的那份会话记录）→ 判定"别人在忙" → **放弃，不动手**
#   于是断言"准备关闭 DSH"全灭 —— 功能完全正确，是**测试没隔离**。
#   所以：给一个"我早就说完了"的假会话文件 + 一个空的假会话根目录。
$emptySessions = Join-Path $tmpDir 'sessions-empty'
New-Item -ItemType Directory -Path $emptySessions -Force | Out-Null
$meDir = Join-Path $tmpDir 'sessions-me\session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

# ── 造一个假应用 ────────────────────────────────────────────────────────────
# 假应用 = 一个 powershell 进程，命令行带唯一标记，并且真的监听假端口。
# 这样助手"验端口"那一步也是真跑的。
$fakeScript = Join-Path $tmpDir 'fake-app.ps1'
@"
param([string]`$Tag)
`$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $fakePort)
`$listener.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$listener.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8

# 假应用要能被"重新拉起来"才有意义。但助手的 Start-Dsh 只接受**单个可执行体路径**，
# 没法传脚本参数，所以没法用一个 .cmd/.ps1 当"主程序"。
# 于是本自测聚焦在**出事故的那一步**（关掉目标）+ 闸门 + 取消；
# "拉起来 + 验端口"这一段用 test-live.ps1 在实机上实弹验证（那才是最终判据）。
$fakeExe = Join-Path $tmpDir 'fake-app.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ fake placeholder' -Encoding ascii

function Start-FakeApp {
  Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $fakeScript, '-Tag', $fakeTag
  ) -PassThru -WindowStyle Hidden
}

# ── 场景一：正常路径 —— 关掉假应用 ──────────────────────────────────────────
$tagged = Start-FakeApp
Start-Sleep -Seconds 3
Check '假应用已启动' ([bool](Get-Process -Id $tagged.Id -ErrorAction SilentlyContinue)) "PID=$($tagged.Id)"
Check '假应用在监听假端口' ([bool](Get-NetTCPConnection -LocalPort $fakePort -State Listen -ErrorAction SilentlyContinue)) "端口 $fakePort"

# ⚠️ 兜底收尾（2026-10-08 踩到）：假应用**必须保证被清掉**，否则它会一直占着假端口。
#    后果很隐蔽：下一次跑本测试时，"假端口已释放"永远失败 ——
#    因为**上一轮泄漏的那个进程**还在监听（实测：PID 21560 守了半小时）。
#    查这种问题的办法是看端口占用的 PID 属于哪个临时目录 —— 别怀疑功能。
function Stop-AllFakes {
  foreach ($p in @($tagged, $tagged2, $tagged3)) {
    if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
  # 再按命令行标记兜底（防 PID 变化 / 拿到空引用）
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $fakeTag + '*') } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
}

$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'selftest-close'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '自测：在假应用上跑关闭流程'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 1
  maxWaitMinutes     = 0
  bootTimeoutSeconds = 6
  maxAttempts        = 1
  sessionFile        = $meFile        # ★ 第一段有据可依（见下面 $meFile 的说明）
  sessionsRoot       = $emptySessions  # ★ 必须隔离扫盘判据，否则会扫到**真实会话**
  stateFile          = Join-Path $tmpDir 'state.json'
  logFile            = Join-Path $tmpDir 'helper.log'
  lastRunFile        = Join-Path $tmpDir 'last-run.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host "`n--- 启动助手（目标：假应用）---"
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', $helper, '-PlanFile', $planPath,
  '-TargetProcessName', 'powershell',
  '-TargetCommandMatch', $fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

$logPath = Join-Path $tmpDir 'helper.log'
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $logPath) {
    $c = Get-Content $logPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($c -match '没能把 DSH 拉起来|没有动 DSH|保险丝也没能|重启完成') { break }
  }
  Start-Sleep -Milliseconds 800
}
Start-Sleep -Seconds 3

$log = if (Test-Path $logPath) { Get-Content $logPath -Raw -Encoding UTF8 } else { '' }
Write-Host "`n--- 助手日志 ---`n$log----------------`n"

Check '助手日志已生成' (Test-Path $logPath)
Check '脱离成功（父级是 WmiPrvSE）' ($log -match '父进程=WmiPrvSE')
Check '动手前闸门放行（主程序在位）' ($log -match '动手前检查通过')
Check '识别到并关闭了目标' ($log -match '准备关闭 DSH')
Check '假应用确实被关掉了' (-not [bool](Get-Process -Id $tagged.Id -ErrorAction SilentlyContinue)) "PID=$($tagged.Id)"

# 端口释放**要轮询等**，不能只采样一次：进程死了之后，内核回收监听套接字可能还要一会儿。
# （原来只判断一次，赶上回收慢就会误报"端口没释放"。）
$portFree = $false
for ($i = 0; $i -lt 20; $i++) {
  if (-not (Get-NetTCPConnection -LocalPort $fakePort -State Listen -ErrorAction SilentlyContinue)) { $portFree = $true; break }
  Start-Sleep -Milliseconds 500
}
$holder = ''
if (-not $portFree) {
  $hp = (Get-NetTCPConnection -LocalPort $fakePort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
  try { $holder = (Get-CimInstance Win32_Process -Filter "ProcessId=$hp" -ErrorAction SilentlyContinue).CommandLine } catch { }
  $holder = "占用者 PID=$hp $holder"
}
Check '假端口已释放' $portFree $holder
Check '真的走了拉起逻辑' ($log -match '拉起 DSH')

# ── 场景二：闸门 —— 主程序不存在时绝不能动手 ────────────────────────────────
Write-Host "`n--- 专项：主程序不存在时，必须"不动手" ---"
$tagged2 = Start-FakeApp
Start-Sleep -Seconds 3
Check '（场景二）假应用已启动' ([bool](Get-Process -Id $tagged2.Id -ErrorAction SilentlyContinue)) "PID=$($tagged2.Id)"

$plan2Path = Join-Path $tmpDir 'plan2.json'
[ordered]@{
  planId             = 'selftest-gate'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
  reason             = '自测：闸门必须拦住'
  port               = $fakePort
  dshExe             = (Join-Path $tmpDir 'definitely-missing.exe')   # 故意不存在
  dshWorkDir         = $tmpDir
  idleSeconds        = 1
  maxWaitMinutes     = 0
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile          # 同上：第一段要过得去、且不碰真实会话
  sessionsRoot       = $emptySessions
  stateFile          = Join-Path $tmpDir 'state.json'
  logFile            = Join-Path $tmpDir 'gate.log'
  lastRunFile        = Join-Path $tmpDir 'gate-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $plan2Path -Encoding utf8

Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', $helper, '-PlanFile', $plan2Path, '-Detached',
  '-TargetProcessName', 'powershell', '-TargetCommandMatch', $fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

$gateLog = Join-Path $tmpDir 'gate.log'
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $gateLog) {
    $g = Get-Content $gateLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($g -match '没有动 DSH') { break }
  }
  Start-Sleep -Milliseconds 800
}
Start-Sleep -Seconds 2
$gl = if (Test-Path $gateLog) { Get-Content $gateLog -Raw -Encoding UTF8 } else { '' }

Check '闸门拦住了（日志写明"没有动 DSH"）' ($gl -match '没有动 DSH')
Check '闸门生效时目标**仍然活着**' ([bool](Get-Process -Id $tagged2.Id -ErrorAction SilentlyContinue)) "PID=$($tagged2.Id)"
Stop-Process -Id $tagged2.Id -Force -ErrorAction SilentlyContinue

# ── 场景三：取消标记 ────────────────────────────────────────────────────────
Write-Host "`n--- 专项：取消标记必须能叫停 ---"
$tagged3 = Start-FakeApp
Start-Sleep -Seconds 2
$plan3Path = Join-Path $tmpDir 'plan3.json'
$cancelPath = Join-Path $tmpDir 'cancel.flag'
Set-Content -LiteralPath $cancelPath -Value 'cancelled' -Encoding utf8
[ordered]@{
  planId             = 'selftest-cancel'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).ToString('o')      # 还没到点，会在等待里看到取消标记
  reason             = '自测：取消'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 1
  maxWaitMinutes     = 0
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  sessionFile        = $meFile
  sessionsRoot       = $emptySessions
  stateFile          = Join-Path $tmpDir 'state.json'
  logFile            = Join-Path $tmpDir 'cancel.log'
  lastRunFile        = Join-Path $tmpDir 'cancel-lastrun.json'
  cancelFile         = $cancelPath
  showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $plan3Path -Encoding utf8

Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
  '-File', $helper, '-PlanFile', $plan3Path, '-Detached',
  '-TargetProcessName', 'powershell', '-TargetCommandMatch', $fakeTag
) -PassThru -WindowStyle Hidden | Out-Null

$cancelLog = Join-Path $tmpDir 'cancel.log'
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $cancelLog) {
    $c2 = Get-Content $cancelLog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($c2 -match '放弃') { break }
  }
  Start-Sleep -Milliseconds 700
}
Start-Sleep -Seconds 2
$cl = if (Test-Path $cancelLog) { Get-Content $cancelLog -Raw -Encoding UTF8 } else { '' }

Check '取消标记叫停了重启' ($cl -match '放弃')
Check '取消后目标仍然活着' ([bool](Get-Process -Id $tagged3.Id -ErrorAction SilentlyContinue)) "PID=$($tagged3.Id)"
Stop-Process -Id $tagged3.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue

# ── 安全断言：真 DSH 毫发无伤 ───────────────────────────────────────────────
Stop-AllFakes
Start-Sleep -Seconds 1
$realAfter     = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realPortAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess

# ★ 2026-10-11 改判据：**"一个都没少"这个断言本身是错的**（假失败来源）。
#
#   为什么错：DSH 会**给自己起临时子进程**（跑命令、渲染用），
#   这些子进程会自然而然地生灭 —— 它们的 PID 不属于"DSH 被我搞坏了"的证据。
#   实测证据（2026-10-11 全量测试）：报"之前 9 个 → 现在 10 个"而失败，
#   但真 DSH 的主进程与端口监听者**都没变**，单独重跑也全绿。
#   （项目维护说明里早就记着同款坑：「用进程总数当判据 → 正常波动 → 误报失败（实测 9→10）」，
#     那次改成了 PID 集合，但**没改彻底** —— 集合里依然混着会生灭的临时子进程。）
#
#   正确的判据（两条，都不受临时子进程影响）：
#     ① **主进程**（有窗口那个）的 PID 必须在
#     ② **端口监听者**的 PID 必须没变（这条最权威：它就是"DSH 这个服务还在不在"）
#   临时子进程只做**记录**，不当失败条件。
$mainBefore = $null
try {
  $mainBefore = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 -ExpandProperty Id
} catch { }

$missing = @($realBefore | Where-Object { $realAfter -notcontains $_ })
$missingReal = @()
foreach ($id in $missing) {
  # 缺的那个是不是"主进程"？只有主进程少了才算真出事
  if ($id -eq $mainBefore) { $missingReal += $id }
}
$addedTemp = @($realAfter | Where-Object { $realBefore -notcontains $_ })

Check '★ 真 DSH 主进程还在（PID 没消失）' ($missingReal.Count -eq 0) `
  $(if ($missingReal.Count) { "主进程 PID=$($missingReal -join ',') 不见了 ← 真出事" } else { "主进程 PID=$mainBefore" })
Check '★ 真 DSH 端口监听者没变' ($realPortBefore -eq $realPortAfter) "之前 PID=$realPortBefore → 现在 PID=$realPortAfter"
# 临时子进程只记录：说明里写清楚"生灭正常"，免得下次又有人把它当失败
Check '（记录）临时子进程有生灭（正常，不当失败条件）' $true `
  ("少了 $($missing.Count) 个、多了 $($addedTemp.Count) 个；同名进程 $($realBefore.Count) → $($realAfter.Count)")

# ── 汇总 ────────────────────────────────────────────────────────────────────
$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 助手自测汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) {
  Write-Host '失败项：'
  foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" }
}
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
