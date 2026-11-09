# 验证 历史事故 修复：真跑一次"关掉 → 拉起来"，看 last-run.json / history.jsonl 记的是不是真端口
#
# 【为什么必须真跑，不能只靠静态断言】
#   这次的 bug 就是"同一次调用里用了两个变量"。静态断言只能证明"代码里写着 ActualPort"，
#   证明不了"真跑起来那一刻，ActualPort 里装的确实是新端口"。
#   本仓的老教训：test-target-guard 全绿而真 DSH 照样被误杀 —— 因为它验得到计算、验不到接线。
#
# 【怎么造出"计划端口 ≠ 真实端口"】
#   计划里写 $planPort（一个没人听的端口），但假 exe 启动后监听 $realPort。
#   助手会：
#     ① 盯 $planPort —— 没人听
#     ② 但 Wait-ForPort 带 ProcId，会看"它的进程树在服务了没有"
#     ③ 一旦发现进程树在监听（$realPort），就把 ActualPort 改成 $realPort
#   这正是实机上的情形（1807 → 9184）。
#
# 【安全】全程假目标：假 exe、假进程名、假端口、假会话目录。
#   跑前跑后核对真 DSH 的监听 PID 没变。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File test-result-port-live.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work   = Join-Path $env:TEMP ('sr-port-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  $mark = if ($Ok) { '✅' } else { '❌' }
  Write-Host "$mark $Name$(if ($Detail) { " — $Detail" })"
}

# 计划端口（没人听）与真实端口（假 exe 起来后监听这个）
$planPort = 58881
$realPort = 58882
$fakeTag  = 'FAKEPORT-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

Write-Host "临时目录：$work"
Write-Host "计划端口：$planPort（故意没人听）  真实端口：$realPort（假 exe 监听这个）`n"

# ── 真 DSH 基线 ─────────────────────────────────────────────────────────────
# ⚠️ 只取"主进程 PID"和"GUI 端口监听者 PID"两个稳的东西。
#   **不要取进程总数** —— 子工本来就会生灭，拿它当判据会误报（本仓记过这条）。
$realMainBefore = (Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -notmatch '--type=' } |
  Sort-Object { $_.CommandLine.Length } | Select-Object -First 1).ProcessId
$realListenerBefore = (Get-NetTCPConnection -LocalPort 9184 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：主进程 PID=$realMainBefore，9184 监听者 PID=$realListenerBefore`n"

# ── 造假 exe：它监听 $realPort（**忽略传进来的参数**，这样计划端口和真实端口必然不同）──
$fakeExe = Join-Path $work 'fake-port-app.exe'
$src = @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
public class FakePortApp {
    public static void Main(string[] a) {
        // 故意忽略命令行参数：无论助手盯哪个端口，我都监听 $realPort。
        // 这模拟"DSH 用 --port 0 自己挑了一个新端口"。
        var l = new TcpListener(IPAddress.Loopback, $realPort);
        try { l.Start(); } catch { Environment.Exit(3); }
        Thread.Sleep(120000);
        l.Stop();
    }
}
"@
Add-Type -TypeDefinition $src -OutputAssembly $fakeExe -OutputType ConsoleApplication `
  -ReferencedAssemblies 'System.dll','System.Core.dll' -ErrorAction Stop
Check '假 exe 编译成功（监听固定真实端口，忽略参数）' (Test-Path $fakeExe) $fakeExe

# ── ★ 关键：先把"旧实例"跑起来，助手才有东西可关 ────────────────────────────
#   ⚠️ 第一版漏了这一步，结果是护栏当场拦下（"找不到主进程，不知道要关哪个"）——
#      **护栏是对的**，但验证就停在了动手前，根本没走到写结果那一步（7/12）。
#   本仓的护栏判据是"要杀的 == 要拉起的"：目标名/匹配串必须**真能匹配到一个在跑的进程**。
#   所以这里先用同一个 exe 起一个进程，命令行里带 $fakeTag，再用它当 TargetCommandMatch。
$oldApp = Start-Process -FilePath $fakeExe -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
$oldAlive = [bool](Get-Process -Id $oldApp.Id -ErrorAction SilentlyContinue)
$oldListening = @(Get-NetTCPConnection -LocalPort $realPort -State Listen -ErrorAction SilentlyContinue)
Check '旧实例已起来（助手有东西可关）' ($oldAlive -and $oldListening.Count -gt 0) `
  "PID=$($oldApp.Id) 监听=$($oldListening.Count)"
# 清场保险：万一没起来，别继续跑下去
if (-not $oldAlive) {
  Write-Host '旧实例没起来，验证无法继续（不会动任何真东西）' -ForegroundColor Red
  exit 1
}

# ── 写计划 ──────────────────────────────────────────────────────────────────
$lastRunFile = Join-Path $work 'last-run.json'
$histFile    = Join-Path $work 'history.jsonl'
$logFile     = Join-Path $work 'helper.log'
$sessionsRoot = Join-Path $work 'sessions'
New-Item -ItemType Directory -Path $sessionsRoot -Force | Out-Null

$planFile = Join-Path $work 'plan.json'
$plan = [ordered]@{
  planId = 'restart-portlive-test'
  createdAt = (Get-Date).ToString('o')
  scheduleAt = (Get-Date).ToString('o')
  reason = '历史事故 真跑验证（假目标）：确认 port 字段记的是真端口'
  port = $planPort
  dshExe = $fakeExe
  dshWorkDir = $work
  idleSeconds = 1
  confirmSeconds = 0
  maxWaitMinutes = 0.1
  othersWindowSeconds = 5
  bootTimeoutSeconds = 20
  maxAttempts = 1
  sessionFile = ''
  sessionsRoot = $sessionsRoot
  stateFile = (Join-Path $work 'state.json')
  logFile = $logFile
  lastRunFile = $lastRunFile
  cancelFile = (Join-Path $work 'cancel.flag')
  helperPid = 0
}
[IO.File]::WriteAllText($planFile, ($plan | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
Check '计划文件已写（port = 计划端口，不是真实端口）' (Test-Path $planFile)

# ── 真跑助手（-Detached 让它在自己进程里跑完，拿得到退出码）──────────────
#   ⚠️ 目标名指向不存在的东西：Kill-AllDsh 打不到任何真进程
Write-Host "`n--- 真跑助手（假目标，全程不碰真 DSH）---"
# ⚠️ 目标名必须是**那个假 exe 的真实文件名**（不带 .exe 也行，Get-Process 按名匹配）。
#   用 'FakePortApp-Absolutely-Not-Real' 会被护栏拦下（找不到主进程）——
#   第一版就是这么写的，验证停在动手前，什么也没验到。
#   这里的判据：**要关的（fake-port-app）== 要拉起的（$fakeExe）**，护栏会放行。
$out = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper `
  -PlanFile $planFile -Detached `
  -TargetProcessName 'fake-port-app' `
  -TargetCommandMatch 'fake-port-app' 2>&1 | Out-String
Write-Host $out

# ── 核对结果 ────────────────────────────────────────────────────────────────
Write-Host '--- 核对 ---'
Check '助手写出了 last-run.json' (Test-Path $lastRunFile)

if (Test-Path $lastRunFile) {
  $r = Get-Content $lastRunFile -Raw -Encoding UTF8 | ConvertFrom-Json
  Check '结果是 success（真的拉起来了）' ($r.outcome -eq 'success') "outcome=$($r.outcome)"
  Check '★ last-run.json 的 port 是真端口（不是计划里那个）' `
    ([int]$r.port -eq $realPort) "port=$($r.port)  期望=$realPort  计划=$planPort"
  Check '★ port 字段与 detail 里写的一致' `
    ([int]([regex]::Match([string]$r.detail, '端口 (\d+)').Groups[1].Value) -eq [int]$r.port) `
    "detail=$($r.detail)"
  # 反向：如果还留着老 bug，port 会是 $planPort
  Check '★ 没退回旧行为（port 不是计划端口）' ([int]$r.port -ne $planPort) "port=$($r.port)"
}

if (Test-Path $histFile) {
  $lines = @(Get-Content $histFile -Encoding UTF8 | Where-Object { $_.Trim() })
  Check '流水账写出了 1 行' ($lines.Count -ge 1) "$($lines.Count) 行"
  $row = $lines[-1] | ConvertFrom-Json
  Check '★ history.jsonl 里**有** port 字段（历史事故 前压根没有）' `
    ($null -ne $row.PSObject.Properties['port']) "字段：$(($row.PSObject.Properties.Name) -join ',')"
  if ($null -ne $row.PSObject.Properties['port']) {
    Check '★ history 的 port 也是真端口' ([int]$row.port -eq $realPort) "port=$($row.port)  期望=$realPort"
  }
} else {
  Check '流水账写出了 1 行' $false 'history.jsonl 不存在'
}

# ── 收尾：清掉假进程 ────────────────────────────────────────────────────────
Get-CimInstance Win32_Process -Filter "Name LIKE 'fake-port-app%'" -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# ── 真 DSH 毫发无伤 ─────────────────────────────────────────────────────────
# ⚠️⚠️ 第一版这里用"进程总数没少"当判据，**全量跑时误报过**（10 → 9，红了一条）。
#   那是本仓早就记过的坑：「别用进程总数当判据（会正常波动而误报）」——
#   DSH 名下的子工（subprocess / ego-cast 之类）本来就会自然生灭。
#   ⇒ 现在的判据只有两条，都是**稳的**：
#     ① 主进程（命令行最短、持窗口那个）PID 还在；
#     ② 真 GUI 端口的监听者 PID 没变。
$mainBefore = (Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -notmatch '--type=' } |
  Sort-Object { $_.CommandLine.Length } | Select-Object -First 1).ProcessId
$mainAlive = [bool](Get-Process -Id $mainBefore -ErrorAction SilentlyContinue)
$realListenerAfter = (Get-NetTCPConnection -LocalPort 9184 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 主进程还活着（PID 没消失）' $mainAlive "主进程 PID=$mainBefore"
Check '★ 真 DSH 监听者 PID 没变' ($realListenerBefore -eq $realListenerAfter) "$realListenerBefore → $realListenerAfter"

# ── 汇总 ────────────────────────────────────────────────────────────────────
$passed = @($results | Where-Object { $_.Ok }).Count
$total  = $results.Count
Write-Host "`n===== 汇总：$passed/$total 通过 ====="
if ($passed -ne $total) {
  Write-Host '失败项：' -ForegroundColor Red
  $results | Where-Object { -not $_.Ok } | ForEach-Object { Write-Host "  · $($_.Name)（$($_.Detail)）" -ForegroundColor Red }
  Write-Host "`n日志留在：$work" -ForegroundColor Yellow
  exit 1
}
Write-Host "日志留在：$work"
exit 0
