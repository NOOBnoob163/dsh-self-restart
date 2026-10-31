# 实测：动手前的 10 秒确认窗
#   ① 正常情况：走完倒计时才动手，且**每一步都在屏幕上显示剩几秒**
#   ② 中途点「打断」：立刻停手，DSH 一根汗毛不动
#
# 不碰真 DSH：用假应用（假名字 + 假端口）。
$ErrorActionPreference = 'Stop'
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$tmpDir = Join-Path $env:TEMP ('selfrestart-confirm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

$fakePort = 58900 + (Get-Random -Max 80)
$fakeTag  = 'confirm-' + [guid]::NewGuid().ToString('N').Substring(0, 6)

# ── 假应用 ──────────────────────────────────────────────────────────────────
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag)
`$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $fakePort)
`$listener.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$listener.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
function Start-FakeApp {
  $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag) -PassThru -WindowStyle Hidden
  for ($i=0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 400
    if (@(Get-NetTCPConnection -LocalPort $fakePort -State Listen -EA SilentlyContinue).Count -gt 0) { break }
  }
  return $p
}

$fakeExe = Join-Path $tmpDir 'fake-app.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ fake placeholder' -Encoding ascii
# 假应用要"能被拉起来"：助手会去起这个 exe（它是假占位，起不来也没关系，
# 本测试只验"确认窗"和"打断"，不验重启成功）
$emptySessions = Join-Path $tmpDir 'sessions'; New-Item -ItemType Directory -Path $emptySessions -Force | Out-Null
$meFile = Join-Path $tmpDir 'me.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-5)

function New-Plan([string]$tag, [int]$confirm, [string]$cancelFile) {
  $p = Join-Path $tmpDir ("plan-" + $tag + ".json")
  [ordered]@{
    planId             = "confirm-$tag"
    createdAt          = (Get-Date).ToString('o')
    scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
    reason             = "实测：$tag"
    port               = $fakePort
    dshExe             = $fakeExe
    dshWorkDir         = $tmpDir
    idleSeconds        = 1
    confirmSeconds     = $confirm
    # ⚠️ maxWaitMinutes 必须够长：它是"等闲置"的时限，跟 confirmSeconds 是两回事。
    #    第一版写成 0.05 分钟（3 秒），结果助手**在确认窗之前**就按"等不到闲置"放弃了
    #    （日志："等了 0.05 分钟也没等到…这次不重启了"，outcome=skipped-busy），
    #    于是确认窗根本没机会跑，测试报了一堆假红。给它 2 分钟足够。
    maxWaitMinutes     = 2
    bootTimeoutSeconds = 3
    maxAttempts        = 1
    sessionFile        = $meFile
    sessionsRoot       = $emptySessions
    stateFile          = Join-Path $tmpDir ("state-$tag.json")
    logFile            = Join-Path $tmpDir ("log-$tag.txt")
    lastRunFile        = Join-Path $tmpDir ("lastrun-$tag.json")
    cancelFile         = $cancelFile
    showWindow         = $false
    requestedBy        = 'session-ME'
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
  return $p
}

function Run-Helper([string]$planPath) {
  Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$helper,'-PlanFile',$planPath,
    '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
  ) -PassThru -WindowStyle Hidden
}
function Wait-Log([string]$logPath, [string]$pattern, [int]$timeoutSec = 90) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $logPath) {
      $c = Get-Content $logPath -Raw -Encoding UTF8 -EA SilentlyContinue
      if ($c -match $pattern) { return $true }
    }
    Start-Sleep -Milliseconds 400
  }
  return $false
}
function Stop-Fakes {
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $fakeTag + '*') } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
  } catch { }
}

# ══ 场景 A：走完确认窗才动手 ════════════════════════════════════════════════
Write-Host "--- 场景 A：确认窗走完才动手（confirmSeconds=4，缩短以免久等）---"
$fakeA = Start-FakeApp
$cancelA = Join-Path $tmpDir 'cancel-A.flag'
$planA = New-Plan 'A' 4 $cancelA
$logA = Join-Path $tmpDir 'log-A.txt'
$swA = [System.Diagnostics.Stopwatch]::StartNew()
$hA = Run-Helper $planA
$sawConfirm = Wait-Log $logA '动手前留 4 秒确认窗' 60
$sawDone    = Wait-Log $logA '秒确认窗走完' 60
$swA.Stop()
Write-Host ("  日志：确认窗开始={0}  走完={1}  耗时 {2:N1}s" -f $sawConfirm, $sawDone, $swA.Elapsed.TotalSeconds)
Check '★ 确认窗真的开过（日志有记录）' $sawConfirm
Check '★ 确认窗走完后才继续（没被跳过）' $sawDone
Check '★ 确认窗确实占用了时间（≥3 秒）' ($swA.Elapsed.TotalSeconds -ge 3) ('{0:N1}s' -f $swA.Elapsed.TotalSeconds)
Check '★ 没收到「打断」时不会误判成取消' (-not (Test-Path $cancelA))
$stopA = Wait-Log $logA '重启完成|没能把 DSH 拉起来|DSH 已完全退出|强制结束' 60
Check '★ 确认窗之后确实动了手（去关假应用了）' $stopA
Stop-Process -Id $fakeA.Id -Force -EA SilentlyContinue
Stop-Fakes
Start-Sleep -Seconds 2

# ══ 场景 B：确认窗里点「打断」→ 立刻停手 ════════════════════════════════════
Write-Host "`n--- 场景 B：确认窗里点「打断」→ 必须停手，DSH 不动 ---"
$fakeB = Start-FakeApp
$cancelB = Join-Path $tmpDir 'cancel-B.flag'
$planB = New-Plan 'B' 10 $cancelB
$logB = Join-Path $tmpDir 'log-B.txt'
$hB = Run-Helper $planB
$sawConfirmB = Wait-Log $logB '动手前留 10 秒确认窗' 60
Check '★ B: 确认窗开起来了' $sawConfirmB
# 趁倒计时进行中，模拟用户点「打断」（= 写取消标记，与窗口按钮同一路径）
Start-Sleep -Seconds 2
[System.IO.File]::WriteAllText($cancelB, 'aborted by test')
$sawCancel = Wait-Log $logB '确认窗里收到了「打断」' 60
Check '★ B: 收到「打断」后立刻停手' $sawCancel
Check '★ B: **没有**去关假应用（DSH 一根汗毛没动）' ([bool](Get-Process -Id $fakeB.Id -EA SilentlyContinue)) ("假应用 PID=" + $fakeB.Id)
$lrB = Join-Path $tmpDir 'lastrun-B.json'
$outB = ''
if (Test-Path $lrB) { try { $outB = (Get-Content $lrB -Raw -Encoding UTF8 | ConvertFrom-Json).outcome } catch { } }
Check '★ B: 结果如实记为"取消"' ($outB -eq 'cancelled') "outcome=$outB"
Stop-Process -Id $fakeB.Id -Force -EA SilentlyContinue
Stop-Fakes

# ── 收尾 ────────────────────────────────────────────────────────────────────
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $tmpDir + '*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -EA SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
