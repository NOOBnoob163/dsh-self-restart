# ══════════════════════════════════════════════════════════════════════════
#  实测：保险丝（-Watchdog）**到底会不会真的救场**
# ══════════════════════════════════════════════════════════════════════════
#
#  【为什么必须有这一套（2026-10-11 立的）】
#    这个插件唯一的不可接受后果是「DSH 被关了却没人拉起来」，
#    而保险丝是那件事的**唯一**兜底。
#    可是实测 24 次真实运行：**救场 0 次、判过"该我管" 0 次** ——
#    24 次全是「端口已经在监听 —— DSH 活着，没我事，我撤」。
#    而正主真正断电实测在它上岗后 24~237 秒，也就是说它**每次都提前离场**。
#
#    根因：老逻辑每轮第一件事就是"端口在听 → exit 0"，
#    可**正主等待期间端口本来就是通的** —— 于是它永远在危险窗口之前就走了。
#
#    20 套测试里 `-Watchdog` 出现 0 次：这个唯一的救命装置**从没被验证过**。
#    所以这里补上，而且必须验两个方向：
#      A. 不该插手时**留在场上**（别提前离场 → 否则需要它时它不在）
#      B. 该动手时**真的会救**（这是它存在的全部意义）
#
#  ⚠️ 全程假目标：假端口 + 假主程序（真 .exe，因为产品用 WMI 创建、只认可执行文件）
#     + 假计划文件。真 DSH 绝不触碰（-TargetProcessName 指向一个不存在的名字）。
#
#  用法：powershell -NoProfile -File test-watchdog-rescue.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

# 跑之前先记下真 DSH 的监听者 PID（跑完要核对没变）
$realBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess

$work = Join-Path $env:TEMP ('wd-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# ── 开场先清场：把上次可能留下的假 DSH 收掉 ─────────────────────────────
#  为什么：这类"占端口的假程序"一旦残留，会**把结论搞反** ——
#  保险丝看到端口在听就不去救（它是对的），而这个测试却以为"救成功了"。
#  2026-10-11 实测踩到过，排查了一轮。所以开场先自我清理，别指望上次清干净。
Get-CimInstance Win32_Process -Filter "Name LIKE 'FakeDSH%'" -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

function New-FakeDshExe([string]$dir, [int]$port) {
  # ⚠️ 每个场景用**各自的文件名**：同一个 exe 被上一个场景的进程占着时，
  #    Add-Type 会报「另一个程序正在使用此文件，进程无法访问」（2026-10-11 实测踩到）。
  $exe = Join-Path $dir ("FakeDSH-$port.exe")
  $src = @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
public class FakeDsh$port {
    public static void Main(string[] a) {
        int port = $port;
        if (a.Length > 0) { int.TryParse(a[0], out port); }
        var l = new TcpListener(IPAddress.Loopback, port);
        try { l.Start(); } catch { Environment.Exit(3); }
        Thread.Sleep(300000);
        l.Stop();
    }
}
"@
  Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType ConsoleApplication `
    -ReferencedAssemblies 'System.dll','System.Core.dll' -ErrorAction Stop
  return $exe
}

function Write-PlanFile([string]$path, [hashtable]$overrides) {
  $plan = [ordered]@{
    planId = 'restart-wd-test'
    createdAt = (Get-Date).ToString('o')
    scheduleAt = (Get-Date).ToString('o')
    reason = '保险丝自测（假目标）'
    port = 19999
    dshExe = ''
    dshWorkDir = $work
    idleSeconds = 12
    confirmSeconds = 0
    maxWaitMinutes = 0.05
    othersWindowSeconds = 120
    bootTimeoutSeconds = 15
    maxAttempts = 1
    sessionFile = ''
    sessionsRoot = (Join-Path $work 'sessions')
    stateFile = (Join-Path $work 'state.json')
    logFile = (Join-Path $work 'helper.log')
    lastRunFile = (Join-Path $work 'last-run.json')
    cancelFile = (Join-Path $work 'cancel.flag')
    helperPid = 0
  }
  foreach ($k in $overrides.Keys) { $plan[$k] = $overrides[$k] }
  $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Start-Watchdog([string]$planFile) {
  return Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
    '-File', $helper, '-PlanFile', $planFile, '-Watchdog',
    # 指向一个**不存在**的进程名：这样 Kill-AllDsh 打不到任何真东西
    '-TargetProcessName','FakeDSH-Absolutely-Not-Real',
    '-TargetCommandMatch','FakeDSH-Absolutely-Not-Real'
  ) -PassThru -WindowStyle Hidden
}

# ══════════════════════════════════════════════════════════════════════════
Write-Host '=== A. DSH 还活着（端口在听）+ 正主在等 → 应当「留在场上」、「不插手」 ==='
# ══════════════════════════════════════════════════════════════════════════
#
# ⚠️⚠️ 这一套的靶子必须**端口真的有人在听**（2026-10-11 第一版写错了，记在这里）：
#    第一版把"端口没人听"当成场景 A，结果**测不出那个 bug** ——
#    因为老代码的毛病是「看到端口在听就 exit 0」，
#    端口没人听时它根本不走那条分支，于是"坏的版本"也照样通过，
#    这个测试就成了**假的保险网**。
#    真实世界的形态恰恰是：**正主还在等闲下来，所以 DSH 还开着、端口是通的** ——
#    这时老保险丝会立刻"没我事，我撤"走人；而它一走，后面正主真断电时就没兜底了。
#    所以：先起一个假 DSH 占住端口，再验保险丝**留不留在场上**。
$planA = Join-Path $work 'planA.json'
$logA  = Join-Path $work 'helperA.log'
$portA = 19901
# 起一个真占端口的假 DSH（模拟"DSH 还活着、正主还在等"）
$fakeDshA = New-FakeDshExe -dir $work -port $portA
$fakeProcA = Start-Process -FilePath $fakeDshA -ArgumentList "$portA" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
$portAUp = $false
try { $c = New-Object System.Net.Sockets.TcpClient; $portAUp = $c.ConnectAsync('127.0.0.1',$portA).Wait(1200) -and $c.Connected; $c.Close() } catch { }
Check 'A0 前置：假 DSH 已占住端口（否则这套测不出目标 bug）' $portAUp "端口 $portA 有人听 = $portAUp"

# 用一个真活着的进程冒充"正主"（就用本脚本的 PID —— 它确实活着）
Write-PlanFile $planA @{ planId = 'restart-wd-A'; port = $portA; helperPid = $PID; logFile = $logA }
$pa = Start-Watchdog $planA
Write-Host ("   保险丝 PID={0}，观察 22 秒…" -f $pa.Id)
Start-Sleep -Seconds 22
$aliveAfter = -not $pa.HasExited
if ($aliveAfter) { Stop-Process -Id $pa.Id -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $fakeProcA.Id -Force -ErrorAction SilentlyContinue

$logAText = if (Test-Path $logA) { Get-Content $logA -Raw -Encoding UTF8 } else { '' }
Check 'A1 观察期内保险丝仍在场上（= 没有提前离场）' $aliveAfter $(if ($aliveAfter) { '22 秒时仍存活' } else { '已经退出了 ← 这正是老 bug 的形态' })
Check 'A2 它明说了"端口在听、继续守着"' ($logAText -match '继续守着|仍在守|不插手')
Check 'A3 没有出现老的"没我事，我撤"提前离场' (-not ($logAText -match '没我事，我撤'))
Check 'A4 它没有去动任何进程（日志里没有救援动作）' (-not ($logAText -match '该我管的场面|次救援'))

# ══════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '=== B. 端口没人听 + 正主已死 → 应当「真的去救」，并且写对结果 ==='
# ══════════════════════════════════════════════════════════════════════════
$planB = Join-Path $work 'planB.json'
$logB  = Join-Path $work 'helperB.log'
$lastB = Join-Path $work 'last-run.json'
$portB = 19902
$fakeExe = New-FakeDshExe -dir $work -port $portB

# ★ 前置断言：这个端口**起测前必须没人听**。
#   为什么必须查（2026-10-11 实测踩到，排查了一轮）：
#   上一次跑测试留下的假 DSH 没被清干净（我的清理过滤写的是 Name='FakeDSH.exe'，
#   而按端口命名的文件叫 'FakeDSH-19902.exe'，**匹配不上**）→ 端口一直有人听 →
#   保险丝于是"正确地"判定端口在听、不需要救援 →
#   而我的 B2 又把这个**残留端口**当成"救成功了" → 出现
#   「B1 说没救援、B2 说端口是通的」这种自相矛盾的结果。
#   教训：**测试自己要先验前置条件**，否则残留状态会把结论搞反。
$occupied = $false
try { $c = New-Object System.Net.Sockets.TcpClient; $occupied = $c.ConnectAsync('127.0.0.1',$portB).Wait(900) -and $c.Connected; $c.Close() } catch { }
Check 'B0 前置：这个端口起测前没人听（否则本场景结论不可信）' (-not $occupied) "端口 $portB 起测前有人听 = $occupied"
if ($occupied) {
  Write-Host '   ⚠️ 端口被占（多半是上次跑的假 DSH 没清掉）—— 本场景跳过，不给出错误结论' -ForegroundColor Yellow
}

# 造一个"已死的正主"
$dead = Start-Process -FilePath $psExe -ArgumentList '-NoProfile','-Command','exit 0' -PassThru -WindowStyle Hidden
$dead.WaitForExit(); $deadPid = $dead.Id
Start-Sleep -Milliseconds 300

Write-PlanFile $planB @{
  planId = 'restart-wd-B'; port = $portB; dshExe = $fakeExe
  helperPid = $deadPid; logFile = $logB; lastRunFile = $lastB
}
$pb = Start-Watchdog $planB
Write-Host ("   保险丝 PID={0}，最多等 70 秒…" -f $pb.Id)
$pb.WaitForExit(70000) | Out-Null
if (-not $pb.HasExited) { Stop-Process -Id $pb.Id -Force -ErrorAction SilentlyContinue }

$logBText = if (Test-Path $logB) { [System.IO.File]::ReadAllText($logB, [System.Text.Encoding]::UTF8) } else { '' }
$portUp = $false
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $portUp = $c.ConnectAsync('127.0.0.1', $portB).Wait(1200) -and $c.Connected
  $c.Close()
} catch { }
$lastBText = if (Test-Path $lastB) { Get-Content $lastB -Raw -Encoding UTF8 } else { '' }

Check 'B1 它认定"这是该我管的场面"' ($logBText -match '该我管的场面|次救援')
Check 'B2 它把假 DSH 真的拉起来了（端口有人听了）' $portUp
Check 'B3 结果文件写了 success' ($lastBText -match '"outcome":\s*"success"')
Check 'B4 结果署名是 watchdog（保险丝）' ($lastBText -match '"by":\s*"watchdog"')

# ══════════════════════════════════════════════════════════════════════════
Write-Host ''
Write-Host '=== C. 正主正常收工（计划文件被删）→ 保险丝应当**立刻退场**，不当孤儿 ═══'
# ══════════════════════════════════════════════════════════════════════════
#  为什么也要测这个方向：2026-10-08 实测留下过孤儿进程。
#  本次把守候时间拉长了很多（守到本次重启结束），必须确认"结束"能被及时发现，
#  否则修好了一个毛病（提前离场）会换来另一个毛病（赖着不走）。
$planC = Join-Path $work 'planC.json'
$logC  = Join-Path $work 'helperC.log'
$portC = 19903
$fakeDshC = New-FakeDshExe -dir $work -port $portC
$fakeProcC = Start-Process -FilePath $fakeDshC -ArgumentList "$portC" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2

Write-PlanFile $planC @{ planId = 'restart-wd-C'; port = $portC; helperPid = $PID; logFile = $logC }
$pc = Start-Watchdog $planC
Start-Sleep -Seconds 3      # 让它先跑起来（此时端口在听 → 它应当"继续守着"）
$aliveBeforeDelete = -not $pc.HasExited

# 模拟"正主收工"：删掉计划文件
Remove-Item -LiteralPath $planC -Force -ErrorAction SilentlyContinue
# 给它最多 15 秒发现并退场（Test-PlanFileGone 要双确认，最多多等 0.3 秒 + 一轮 5 秒）
$exitedInTime = $pc.WaitForExit(15000)
if (-not $pc.HasExited) { Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $fakeProcC.Id -Force -ErrorAction SilentlyContinue

$logCText = if (Test-Path $logC) { Get-Content $logC -Raw -Encoding UTF8 } else { '' }
Check 'C1 删计划前它确实在场上（前置）' $aliveBeforeDelete
Check 'C2 计划文件一消失，它在 15 秒内就退场了（不当孤儿）' $exitedInTime $(if ($exitedInTime) { '及时退场' } else { '还在跑 ← 孤儿风险' })
Check 'C3 日志说明了退场理由（计划已经没了）' ($logCText -match '计划文件已经没了|已结束')

# ── 清理假 DSH ─────────────────────────────────────────────────────────────
# ⚠️ 必须用 **LIKE 'FakeDSH%'** 而不是 `Name='FakeDSH.exe'`：
#    假 exe 是按端口命名的（FakeDSH-19902.exe），精确匹配**匹配不到** →
#    进程留在场上占着端口 → 下一次跑测试时前置条件被污染、
#    甚至得出"保险丝没救、但端口是通的"这种自相矛盾的结论（2026-10-11 实测踩到）。
Get-CimInstance Win32_Process -Filter "Name LIKE 'FakeDSH%'" -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 收尾再确认一次：测试用过的端口都该空出来了
foreach ($p in @($portA, $portB, $portC)) {
  $stillUp = $false
  try { $c = New-Object System.Net.Sockets.TcpClient; $stillUp = $c.ConnectAsync('127.0.0.1',$p).Wait(500) -and $c.Connected; $c.Close() } catch { }
  if ($stillUp) { Write-Host ("   ⚠️ 端口 {0} 测试后仍被占用（可能有残留进程）" -f $p) -ForegroundColor Yellow }
}

# ── 真 DSH 必须毫发无伤 ────────────────────────────────────────────────────
Start-Sleep -Milliseconds 500
$realAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realBefore -eq $realAfter) ("$realBefore -> $realAfter")

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
if ($failed.Count) { exit 1 }
exit 0
