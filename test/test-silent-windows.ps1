# 实测：改了静默建进程之后，助手那一串进程**真的没有可见窗口**吗？
#
# 为什么要测：用户的诉求就是"别闪黑框"。改完必须**用数据确认**，
# 而不是"我改了 ShowWindow=0 所以应该不闪了"（那只是推断）。
#
# 做法：起一个真的助手（在假目标上跑），在它活着的时候，
# 用 Win32 API 枚举它**名下所有可见窗口** —— 一个都不该有。
# 顺带验"没有可见窗口也不影响它干活"（日志照写、该动手还是动手）。
#
# 用法：powershell -NoProfile -File test-silent-windows.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-silent-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$fakeTag  = 'SILENTTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$fakePort = 58891
$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# 枚举窗口的帮手：某个 PID 名下有几个**可见**的顶层窗口
$winHelper = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class WinScan {
  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
  public static List<string> VisibleWindows(int targetPid) {
    var found = new List<string>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == (uint)targetPid && IsWindowVisible(h)) {
        int len = GetWindowTextLength(h);
        var sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        found.Add(sb.ToString());
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@
Add-Type -TypeDefinition $winHelper -ErrorAction Stop
Check '窗口枚举帮手已就绪' $true

# 假会话目录（第一段要能快速通过）
$meDir = Join-Path $tmpDir 'sessions-me\session-ME'
New-Item -ItemType Directory -Path $meDir -Force | Out-Null
$meFile = Join-Path $meDir 'session.v4.jsonl.zstd'
Set-Content -LiteralPath $meFile -Value 'x' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-10)

$emptySessions = Join-Path $tmpDir 'sessions-empty'
New-Item -ItemType Directory -Path $emptySessions -Force | Out-Null

# 假应用
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag, [int]`$Port)
try { `$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$Port); `$l.Start() } catch { exit 9 }
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
$fake = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fakeScript,'-Tag',$fakeTag,'-Port',$fakePort) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

# 计划：正常路径（会走"点火器 → 正主 → 保险丝"三跳）
$planPath = Join-Path $tmpDir 'plan.json'
[ordered]@{
  planId             = 'silenttest'
  createdAt          = (Get-Date).ToString('o')
  scheduleAt         = (Get-Date).AddSeconds(6).ToString('o')   # 留点时间给我们观察
  reason             = '实测：整条链路不许有可见窗口'
  port               = $fakePort
  dshExe             = $fakeExe
  dshWorkDir         = $tmpDir
  idleSeconds        = 5
  maxWaitMinutes     = 1
  bootTimeoutSeconds = 4
  maxAttempts        = 1
  # ⚠️ 2026-10-10：状态窗（2026-10-10 加）是**有意显示**的窗口，
  #    它一出现就会让本测试的"可见窗口数=0"断言失败 —— 那不是 bug，是两条要求打架：
  #      · 2026-10-08 定：助手那一串进程**不许闪黑框**（本测试守的是这条）
  #      · 2026-10-10 定：重启时**要**留一个窗口显示状态（状态窗）
  #    两者其实不冲突：黑框（控制台窗口）一个都不该有；状态窗是**有内容的 UI**，该有。
  #    所以本测试显式关掉状态窗，只验"没有黑框"这件事。
  #    状态窗本身（响应性/摆位/点击）由 test-restart-window.ps1 专门验。
  showWindow         = $false
  sessionFile        = $meFile
  sessionsRoot       = $emptySessions
  stateFile          = Join-Path $tmpDir 'state.json'
  logFile            = Join-Path $tmpDir 'silent.log'
  lastRunFile        = Join-Path $tmpDir 'silent-lastrun.json'
  cancelFile         = Join-Path $tmpDir 'cancel.flag'
  requestedBy        = 'session-ME'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding utf8

Write-Host '--- 起助手（正常入口：它会自己脱离成 正主 + 保险丝）---'
Start-Process -FilePath $psExe -ArgumentList @(
  '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
  '-File',$helper,'-PlanFile',$planPath,
  '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
) -WindowStyle Hidden | Out-Null

# 在这几秒里，把"我们自己这一串"的每个进程都扫一遍窗口
function Get-OurPids {
  @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'dsh-self-restart\.ps1' } |
    Select-Object -ExpandProperty ProcessId)
}

$allVisible = @()
$seenPids = @()
for ($i = 0; $i -lt 14; $i++) {
  Start-Sleep -Milliseconds 700
  foreach ($p in (Get-OurPids)) {
    if ($seenPids -notcontains $p) { $seenPids += $p }
    $vis = [WinScan]::VisibleWindows([int]$p)
    foreach ($v in $vis) { $allVisible += ('PID {0}: 「{1}」' -f $p, $v) }
  }
}
Write-Host ("观察到的助手进程（共 $($seenPids.Count) 个）：" + ($seenPids -join ', '))
Check '观察期间确实有助手进程在跑' ($seenPids.Count -ge 1) "PID: $($seenPids -join ', ')"
Check '★ 整串助手的**可见窗口数 = 0**' ($allVisible.Count -eq 0) $(if ($allVisible.Count) { $allVisible -join ' | ' } else { '一个可见窗口都没有' })
# ★ 证明"0 个可见窗口"是**因为状态窗被关掉了**，而不是"窗口根本没接线/没生效"
#   （否则这条断言会变成"因为功能坏了所以通过"——那种假绿最危险）
$silentLog0 = if (Test-Path (Join-Path $tmpDir 'silent.log')) { Get-Content (Join-Path $tmpDir 'silent.log') -Raw -Encoding UTF8 } else { '' }
Check '★ 状态窗确实是**被计划关掉**的（不是没接线导致假通过）' ($silentLog0 -match '状态窗按计划要求关闭')

# 等它跑完，确认"静默"没有影响功能
$lastP = Join-Path $tmpDir 'silent-lastrun.json'
$deadline = (Get-Date).AddSeconds(70)
while ((Get-Date) -lt $deadline -and -not (Test-Path $lastP)) { Start-Sleep -Milliseconds 800 }
$log = if (Test-Path (Join-Path $tmpDir 'silent.log')) { Get-Content (Join-Path $tmpDir 'silent.log') -Raw -Encoding UTF8 } else { '' }

Check '★ 静默之后功能照常（日志照写）' ($log -match '开始执行|准备关闭 DSH')
Check '★ 静默之后**真的动手了**（关掉了假目标）' (-not [bool](Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)) "假应用 PID=$($fake.Id)"
Check '★ 脱离子进程的父级仍是 WmiPrvSE（脱离机制没被改坏）' ($log -match '父进程=WmiPrvSE')

# 收尾
Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
foreach ($p in (Get-OurPids)) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
