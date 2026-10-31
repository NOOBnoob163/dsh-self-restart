# 实测：状态窗（dsh-restart-window.ps1，现代外观版）
#
# 用户 要求「留一个窗口在外面，让我能确定等待状态和进行状态」，
# 随后实测反馈了三个问题 —— 本测试把这**三件事**钉死，防复发：
#
#   ①「鼠标刚放上去就转圈圈」→ 窗口和助手的 Start-Sleep 在**同一个线程**上，
#      助手一睡没人处理窗口消息 → Windows 判"未响应"（转圈、点不动）。
#      修法：窗口跑在**自己的线程**上。
#      ⚠️ 探测必须"跨进程 + 窗口在可见位置"才测得出；旧探针开在屏幕外，永远假通过。
#
#   ②「点上去没啥反应」→ 生产代码把窗口**算到了屏幕外**（WPF 单位 × 150% 缩放混用），
#      根本点不到。修法：按真实缩放换算工作区。本测试断言窗口落在屏幕内 + 真实鼠标点得动。
#
#   ③「很丑」→ 改用 WPF（圆角卡片、系统字体）。外观靠人工看截图；
#      这里只断言"装的是 WPF"这个客观事实，防有人改回老式 WinForms。
#
# ⚠️ 结构性决定（踩过坑才这么写的）：**两件事各用一套独立的宿主进程**。
#    第一版把"响应性探测"和"点击"塞进同一个宿主、同一段时间里，
#    结果两边互相干扰（上一次跑的残留点击进程会点掉这一次刚开的窗口），
#    表现为随机红。分开跑之后每次都能稳定复现。
#
# 不碰真 DSH：窗口由测试自己的进程建，跑完核对真 DSH 监听者 PID 没变。
# 用法：powershell -NoProfile -File test-restart-window.ps1
$ErrorActionPreference = 'Stop'

$mod    = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path
$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-win-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ⚠️ 先清掉**以前**几轮测试留下的窗口/点击进程：它们会点掉或干扰这一轮新开的窗口，
#    造成"随机红"（第一版就是被这个坑到的）。
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and ($_.CommandLine -match 'selfrestart-win-') -and ($_.CommandLine -notmatch [regex]::Escape($tmpDir)) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

function Start-Detached([string]$cmdline) {
  $a = @{ CommandLine = $cmdline }
  try { $a.ProcessStartupInformation = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 } } catch { }
  return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $a
}
function Wait-File([string]$path, [int]$timeoutSec = 45) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $path) { Start-Sleep -Milliseconds 400; return $true }; Start-Sleep -Milliseconds 400 }
  return $false
}
function Wait-Match([string]$path, [string]$pattern, [int]$timeoutSec = 45) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    # ★ 2026-10-21 修：读失败要**当成"还没写好"继续等**，不能让它把整套测试掀翻。
    #   窗口那边用 Add-Content 追加写这个文件，我们这边正好在读 → 会抛
    #   "The process cannot access the file ... because it is being used by another process"。
    #   实测：改动前的旧代码在同一处同样报错（与本次改动无关，是**早就存在**的缺陷），
    #   而且稳定复现 —— 任何人 clone 下来第一次跑全量就会撞上。
    #   ⚠️ 这正是本仓反复写的那条：测试的"基础设施"自己会骗人 / 会假红。
    #     等待类函数**一律**要容忍读不到（同 Wait-File 只做 Test-Path 的道理）。
    $ok = $false
    if (Test-Path -LiteralPath $path) {
      try {
        $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ($txt -match $pattern) { $ok = $true }
      } catch {
        # 被占用 / 正在写 —— 下一轮再看，不当作失败
      }
    }
    if ($ok) { return $true }
    Start-Sleep -Milliseconds 400
  }
  return $false
}

# ══════════════════════════════════════════════════════════════════════════
#  公共：宿主脚本（显示窗口 → 走完阶段 → 长睡 → 再更新 → 保持可见）
# ══════════════════════════════════════════════════════════════════════════
$hostPs1 = Join-Path $tmpDir 'host.ps1'
@'
param([string]$Mod, [string]$MetaFile, [string]$StageFile, [string]$CancelFile, [int]$SleepSec = 16, [int]$HoldSec = 10)
$ErrorActionPreference = 'Stop'
function N([string]$t) { Add-Content -LiteralPath $StageFile -Value $t -Encoding UTF8 }
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class Rr {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  public static IntPtr Find(uint target) {
    IntPtr f = IntPtr.Zero;
    EnumWindows((h,l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target && IsWindowVisible(h)) { f = h; return false; } return true; }, IntPtr.Zero);
    return f;
  }
}
"@
try {
  # ★ 2026-10-11：让窗口标题带「【测试】」前缀。
  #   为什么：用户跑测试时在屏幕上看到两个写着「DSH 正在自我重启 / 正在关闭 DSH」的窗口，
  #   以为自己的 DSH 出事了 —— 其实那是这两套测试画的假窗口（这套摆右下角，另一套摆左上角）。
  #   这两套测试**必须**显示真窗口（要验响应性/不抢焦点/拖动/点按钮），所以只能靠标题区分。
  $env:DSH_RW_TEST_MODE = '1'
  . $Mod
  $fg0 = [Rr]::GetForegroundWindow()
  # ⚠️ 必须把 CancelFile 传给窗口：否则「打断」按钮**正确地**处于禁用状态，
  #    测试点了没反应还会误判成"按钮坏了"（这轮就差点这么冤）。
  $ok = Show-RestartWindow -Port 19387 -Reason '实测：状态窗' -LogFile (Join-Path (Split-Path $MetaFile) 'win.log') -CancelFile $CancelFile
  N ("SHOW=" + $ok)
  if (-not $ok) { N 'FAIL=show'; exit 1 }

  Start-Sleep -Milliseconds 1400
  $h = [Rr]::Find([uint32]$PID)
  N ("HWND=" + $h)
  # ★「显示窗口不抢焦点」必须紧跟 Show 之后量（晚了会被别的进程的前台变化污染）
  N ("FGSTEAL=" + ([Rr]::GetForegroundWindow() -ne $fg0))
  if ($h -ne [IntPtr]::Zero) {
    $r = New-Object Rr+RECT
    if ([Rr]::GetWindowRect([IntPtr]$h, [ref]$r)) {
      [System.IO.File]::WriteAllText($MetaFile, ("{0}|{1}|{2}|{3}|{4}|{5}" -f $h,$r.L,$r.T,($r.R-$r.L),($r.B-$r.T),$fg0), (New-Object System.Text.UTF8Encoding $false))
    }
  }

  foreach ($p in @(
    @('waiting','还在等你这一轮说完'), @('ready','都闲了，准备动手'),
    @('closing','正在关闭 DSH'), @('closed','DSH 已关闭'),
    @('starting','正在重新打开'), @('done','端口 19387 已监听')
  )) {
    Set-RestartWindowStage -Stage $p[0] -Detail $p[1] -EtaText ''
    Start-Sleep -Milliseconds 250
  }
  Set-RestartWindowStage -Stage 'waiting' -Detail '还原成等待' -EtaText ''
  N 'STAGES_OK=1'

  # ★ 主线程完全不泵消息地长睡 —— 旧版就是在这里变"未响应"的
  N ('SLEEPING=' + $SleepSec)
  Start-Sleep -Seconds $SleepSec
  N 'SLEEP_DONE=1'

  # 睡醒还能改文字 = 窗口线程一直活着
  Set-RestartWindowStage -Stage 'waiting' -Detail '睡醒之后又更新了一次' -EtaText ''
  Start-Sleep -Milliseconds 500
  N 'UPDATE_AFTER_SLEEP=1'

  # 保持可见，等外部决定（探测 / 点击 / 拖动）
  # 顺带**持续报出**窗口位置和"打断"按钮的真实屏幕坐标 —— 外部照着点，
  # 不用自己估算（估算会因 DPI/边距差几像素而点空，白红一轮，踩过）。
  #
  # ⚠️ 固定 HoldSec 秒是不够的（踩过）：全量跑时机器更忙，外部那个"拖动+点击"的
  #    进程还没跑到"点击"这一步，这里就已经等满、把窗口关掉了 —— 于是
  #    CANCEL_EXISTS=False，看起来像"打断按钮没生效"，其实是**窗口早没了**。
  #    改成：一直保持可见，直到外部写下 DONE 文件（最多等 90 秒兜底）。
  $doneFile = Join-Path (Split-Path $StageFile) 'done.txt'
  $deadline = (Get-Date).AddSeconds(90)
  $i = 0
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $doneFile)) {
    Start-Sleep -Seconds 1
    $i++
    $vis = [Rr]::IsWindowVisible([IntPtr]$h)
    N ("VISIBLE_TICK=" + $i + ":" + $vis)
    N ("TOPL=" + (Get-RestartWindowTopLeft))
    N ("BTN=" + (Get-RestartWindowAbortButtonPos))
    # 拖动诊断：分清"鼠标事件根本没送到窗口"和"送到了但坐标算错"（两种病修法不同）
    N ("DRAGDBG=" + (Get-RestartWindowDragDebug))
    if (-not $vis) { break }
  }
  N 'HOST_DONE=1'
  Close-RestartWindow -KeepSeconds 0
  N 'CLOSED=1'
} catch { N ('EX=' + $_.Exception.Message) }
'@ | Set-Content -LiteralPath $hostPs1 -Encoding UTF8

function New-HostPlan([string]$tag) {
  return @{
    Meta   = Join-Path $tmpDir "meta-$tag.txt"
    Stage  = Join-Path $tmpDir "stages-$tag.txt"
    Log    = Join-Path $tmpDir "win-$tag.log"
    Cancel = Join-Path $tmpDir "cancel-$tag.flag"
  }
}
function Start-Host([hashtable]$p) {
  # ⚠️ CancelFile 必须传：不传的话「打断」按钮**正确地**是禁用状态，
  #    于是"点了没反应"会被误读成"按钮坏了"（这轮差点这么冤）。
  return Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Mod "{2}" -MetaFile "{3}" -StageFile "{4}" -CancelFile "{5}"' -f $psExe, $hostPs1, $mod, $p.Meta, $p.Stage, $p.Cancel)
}

# ══════════════════════════════════════════════════════════════════════════
#  第一段：响应性（用户报的"转圈"）
# ══════════════════════════════════════════════════════════════════════════
Write-Host "── 第一段：宿主睡觉时，窗口还响不响应（防"转圈"）──"
$p1 = New-HostPlan 'resp'
[void](Start-Host $p1)

$prober = Join-Path $tmpDir 'prober.ps1'
@'
param([string]$MetaFile, [string]$OutFile, [int]$Rounds = 14)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class P {
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
}
"@
# 等窗口句柄出现
$hwnd = 0
for ($i=0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  try {
    if (Test-Path $MetaFile) {
      $m = (Get-Content $MetaFile -Raw -Encoding UTF8).Trim() -split '\|'
      if ($m.Count -ge 1 -and [int64]$m[0] -ne 0) { $hwnd = [int64]$m[0]; break }
    }
  } catch {}
}
$lines = @()
if ($hwnd -eq 0) { $lines += 'NO_WINDOW' }
else {
  for ($i = 1; $i -le $Rounds; $i++) {
    Start-Sleep -Seconds 2
    $res = [IntPtr]::Zero
    $ok = [P]::SendMessageTimeout([IntPtr]$hwnd, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 400, [ref]$res)
    $lines += ("{0,3}s 应答={1} 未响应={2}" -f ($i*2), ($ok -ne [IntPtr]::Zero), [P]::IsHungAppWindow([IntPtr]$hwnd))
  }
}
[System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding $false))
'@ | Set-Content -LiteralPath $prober -Encoding UTF8
$probeOut = Join-Path $tmpDir 'probe.txt'
[void](Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -MetaFile "{2}" -OutFile "{3}"' -f $psExe, $prober, $p1.Meta, $probeOut))

# 等到宿主睡完 + 探针写完
[void](Wait-Match $p1.Stage 'SLEEP_DONE=1' 60)
[void](Wait-Match $p1.Stage 'HOST_DONE=1|EX=' 90)
# ★ 探针是**跑完才一次性写盘**的，必须等文件真的出现（第一版没等，读到 0 行 → 两条假红）
[void](Wait-File $probeOut 60)

$hostLines  = if (Test-Path $p1.Stage) { @(Get-Content -LiteralPath $p1.Stage -Encoding UTF8) } else { @() }
$probeLines = if (Test-Path $probeOut) { @(Get-Content -LiteralPath $probeOut -Encoding UTF8) } else { @() }
Write-Host "  宿主：$($hostLines -join ' / ')"
Write-Host "  探测："
$probeLines | Select-Object -First 4 | ForEach-Object { Write-Host ("    " + $_) }
Write-Host "    …（共 $($probeLines.Count) 行）"

function V([string[]]$lines, [string]$key) {
  $l = $lines | Where-Object { $_ -like ($key + '=*') } | Select-Object -First 1
  if ($l) { return $l.Substring($key.Length + 1) } else { return $null }
}

Check '窗口显示成功' ((V $hostLines 'SHOW') -eq 'True') (V $hostLines 'FAIL')
Check '六个阶段都能切换且不抛异常' ((V $hostLines 'STAGES_OK') -eq '1')
Check '睡醒之后还能更新界面（窗口线程一直活着）' ((V $hostLines 'UPDATE_AFTER_SLEEP') -eq '1')
Check '★ 显示窗口本身不抢焦点' ((V $hostLines 'FGSTEAL') -eq 'False')

$probed   = @($probeLines | Where-Object { $_ -match '应答=' })
$answered = @($probeLines | Where-Object { $_ -match '应答=True' })
$hung     = @($probeLines | Where-Object { $_ -match '未响应=True' })
Check '★ 探测确实覆盖到了窗口（不是空跑）' ($probed.Count -ge 5) ("探了 $($probed.Count) 次")
Check '★ 全程**没有**一次"未响应"（修好"鼠标放上去转圈"）' ($hung.Count -eq 0) $(if ($hung.Count) { $hung[0] } else { "0/$($probed.Count) 次未响应" })
Check '★ 宿主睡觉期间窗口**一直应答**（跨进程探测）' ($answered.Count -ge 5) ("应答 $($answered.Count) / 探 $($probed.Count)")

# 摆位：窗口必须落在屏幕内（150% 缩放踩过"算到屏幕外"）
$metaRaw = if (Test-Path $p1.Meta) { (Get-Content -LiteralPath $p1.Meta -Raw -Encoding UTF8).Trim() } else { '' }
$mf = $metaRaw -split '\|'
if ($mf.Count -ge 5) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class DpiA {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@ -ErrorAction SilentlyContinue
  # ★ 本测试自己也要声明 DPI 感知，否则拿到"虚拟化"屏幕尺寸、误判成"跑到屏幕外"
  [void][DpiA]::SetProcessDPIAware()
  $wLeft=[int]$mf[1]; $wTop=[int]$mf[2]; $wW=[int]$mf[3]; $wH=[int]$mf[4]
  $scrW=[DpiA]::GetSystemMetrics(0); $scrH=[DpiA]::GetSystemMetrics(1)
  $onScreen = ($wLeft -ge -2) -and ($wTop -ge -2) -and (($wLeft+$wW) -le ($scrW+2)) -and (($wTop+$wH) -le ($scrH+2))
  Check '★ 窗口完全落在屏幕内（150% 缩放时不跑到屏幕外）' $onScreen ("窗口 {0},{1} {2}x{3}；屏幕 {4}x{5}" -f $wLeft,$wTop,$wW,$wH,$scrW,$scrH)
} else { Check '★ 窗口完全落在屏幕内（150% 缩放时不跑到屏幕外）' $false '拿不到窗口矩形' }

# ══════════════════════════════════════════════════════════════════════════
#  第二段：拖动 + 「打断」按钮（独立宿主，避免与第一段互相干扰）
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n── 第二段：拖动 + 打断按钮（真实鼠标；用完把鼠标放回原位）──"
# ★ 关键：**必须等第一段的窗口彻底消失**再开第二个。
#   两段窗口都摆在右下角（**同一个位置**），第一段留下的窗口会盖在第二段上面 ——
#   于是"拖第二段的窗口"实际拖到的是第一段那个，DRAG_DELTA 恒为 0,0，
#   看起来像"拖不动"。全量跑时因为机器更忙，这个坑已经踩了**两次**。
#   所以这里不能靠"等 3 秒碰运气"，要**等到那个窗口真的不存在了**才继续。
[void](Wait-Match $p1.Stage 'HOST_DONE=1|EX=' 60)
[void](Wait-Match $p1.Stage 'CLOSED=1' 30)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class WinAlive { [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h); }
'@ -ErrorAction SilentlyContinue
$h1 = V (@(Get-Content -LiteralPath $p1.Stage -Encoding UTF8 -ErrorAction SilentlyContinue)) 'HWND'
if ($h1 -match '^\d+$') {
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and [WinAlive]::IsWindow([IntPtr][int64]$h1)) { Start-Sleep -Milliseconds 300 }
  $stillThere = [WinAlive]::IsWindow([IntPtr][int64]$h1)
  Write-Host ("  第一段窗口已消失: " + (-not $stillThere) + "（句柄 " + $h1 + "）")
  if ($stillThere) { Write-Host "  ⚠️ 它还活着 —— 后面的拖动可能按在它身上（会被下面那条断言抓到）" }
}
Start-Sleep -Seconds 1

$p2 = New-HostPlan 'click'
[void](Start-Host $p2)
[void](Wait-Match $p2.Stage 'UPDATE_AFTER_SLEEP=1' 60)
[void](Wait-Match $p2.Stage 'BTN=\d' 30)

$clicker = Join-Path $tmpDir 'clicker.ps1'
@'
param([string]$StageFile, [string]$CancelFile, [string]$OutFile, [int64]$MyHwnd, [string]$MetaFile)
$ErrorActionPreference = 'Stop'
# ★★ 必须声明 DPI 感知：不加的话本进程坐标被系统"虚拟化"（屏幕看成 1707x1067），
#    而窗口在物理坐标上 → SetCursorPos 被钳住，永远点不中。
#    （我早期的测试工具就栽在这，还误以为"窗口点不动"。）
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class DpiAware { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][DpiAware]::SetProcessDPIAware()
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class C {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
$out = New-Object System.Collections.Generic.List[string]
# ★ 先记下鼠标原位 —— 结束前一定放回去。
#   实测反馈过"鼠标被吸过去"。真实点击必须动物理鼠标（PostMessage 对 WPF 无效，
#   实测过），所以只能"用完立刻还原"，并在这里核对确实还原了。
$orig = New-Object C+POINT
[void][C]::GetCursorPos([ref]$orig)
$out.Add("MOUSE_ORIG=$($orig.X),$($orig.Y)")

function MoveTo([int]$x, [int]$y) {
  $p = New-Object C+POINT; [void][C]::GetCursorPos([ref]$p)
  for ($k=1; $k -le 8; $k++) {
    [void][C]::SetCursorPos([int]($p.X + ($x-$p.X)*$k/8), [int]($p.Y + ($y-$p.Y)*$k/8))
    Start-Sleep -Milliseconds 30
  }
}
function GetField([string]$key) {
  if (-not (Test-Path $StageFile)) { return '' }
  $l = @(Get-Content -LiteralPath $StageFile -Encoding UTF8 | Where-Object { $_ -like ($key + '=*') })
  if ($l.Count -eq 0) { return '' }
  return ($l[$l.Count - 1].Substring($key.Length + 1))
}
# 找出"光标下面到底是哪个窗口、是不是我们这一个" —— 拖动前必查。
# ⚠️ 为什么需要：两段测试的窗口都摆在屏幕右下角的**同一位置**。
#   如果上一段的窗口还没关掉，拖动会按在**它**身上（我们的窗口纹丝不动）
#   → DRAG_DELTA=0,0，看起来像"拖不动"，其实是点错了窗口（这坑踩过两次）。
function WindowUnder([int]$x, [int]$y) {
  $pt = New-Object C+POINT; $pt.X = $x; $pt.Y = $y
  return [C]::WindowFromPoint($pt)
}

for ($i=0; $i -lt 30; $i++) {
  if ((GetField 'BTN') -match '^\d+,\d+$') { break }
  Start-Sleep -Milliseconds 500
}
$topl0 = GetField 'TOPL'
$btn0  = GetField 'BTN'
$out.Add("TOPL_BEFORE=$topl0")
$out.Add("BTN_BEFORE=$btn0")
if ($topl0 -notmatch '^(-?\d+),(-?\d+)$' -or $btn0 -notmatch '^\d+,\d+$') {
  $out.Add('DRAG_DELTA=NO_COORDS')
  $out.Add('CANCEL_EXISTS=False')
  $out.Add('MOUSE_BACK_OK=True')
  [System.IO.File]::WriteAllLines($OutFile, $out, (New-Object System.Text.UTF8Encoding $false))
  exit
}
$wx = [int]($topl0 -split ',')[0]; $wy = [int]($topl0 -split ',')[1]

# ── ① 拖动：在窗口上部按住（避开右下按钮），往左上拖 ──────────────────────
#   ⚠️ 坐标一律用**窗口自己报**的（TOPL=），别估算 —— 估算会因 DPI/边距差几像素
#      而点空，白红一轮（踩过）。
$gx = $wx + 180; $gy = $wy + 22
MoveTo $gx $gy
Start-Sleep -Milliseconds 250
# ★ 动手前先确认"光标下的确实是**我们**这个窗口"。
#   两段测试的窗口位置相同；若上一段的窗口还盖在上面，就会拖到它 —— 表现为
#   DRAG_DELTA=0,0（假红，两次全量跑都栽在这）。这里先判定、再把结论写进结果里。
$under = WindowUnder $gx $gy
$out.Add("DRAG_UNDER=$under")
$out.Add("DRAG_HIT_OURS=$([bool]($under -eq [IntPtr][int64]$MyHwnd))")
[C]::mouse_event(0x0002,0,0,0,[IntPtr]::Zero)
Start-Sleep -Milliseconds 180
for ($k=1; $k -le 12; $k++) { [void][C]::SetCursorPos(($gx - 10*$k), ($gy - 6*$k)); Start-Sleep -Milliseconds 35 }
Start-Sleep -Milliseconds 130
[C]::mouse_event(0x0004,0,0,0,[IntPtr]::Zero)
Start-Sleep -Milliseconds 900
$topl1 = GetField 'TOPL'
$out.Add("TOPL_AFTER_DRAG=$topl1")
if ($topl1 -match '^(-?\d+),(-?\d+)$') {
  $out.Add("DRAG_DELTA=$($wx - [int](($topl1 -split ',')[0])),$($wy - [int](($topl1 -split ',')[1]))")
} else { $out.Add('DRAG_DELTA=UNKNOWN') }

# ── ② 点「打断」按钮（取拖动后的最新坐标）────────────────────────────────
$btn1 = GetField 'BTN'
if ($btn1 -match '^\d+,\d+$') {
  $bx = [int]($btn1 -split ',')[0]; $by = [int]($btn1 -split ',')[1]
  MoveTo $bx $by
  Start-Sleep -Milliseconds 250
  $out.Add("BTN_CLICK_AT=$bx,$by")
  # 点之前先确认"按钮坐标下确实是我们窗口" —— 窗口已经被拖走过，坐标若取错会点到别处
  $underBtn = WindowUnder $bx $by
  $out.Add("BTN_HIT_OURS=$([bool]($underBtn -eq [IntPtr][int64]$MyHwnd))")
  $fg0 = [C]::GetForegroundWindow()
  [C]::mouse_event(0x0002,0,0,0,[IntPtr]::Zero); Start-Sleep -Milliseconds 100
  [C]::mouse_event(0x0004,0,0,0,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 1500
  $out.Add("FOCUS_STOLEN=$(([C]::GetForegroundWindow() -ne $fg0))")
}
$out.Add("CANCEL_EXISTS=$(Test-Path -LiteralPath $CancelFile)")

# ★ 还原鼠标
[void][C]::SetCursorPos($orig.X, $orig.Y)
Start-Sleep -Milliseconds 250
$p3 = New-Object C+POINT; [void][C]::GetCursorPos([ref]$p3)
$out.Add("MOUSE_RESTORED=$($p3.X),$($p3.Y)")
# ⚠️ 允许 ±2 像素：SetCursorPos 之后系统可能因吸附/取整挪 1 像素（实测 877→875），
#    那不算"没还原"。判据是"有没有把鼠标扔在原位附近"，不是比特级相等。
$delta = [Math]::Abs($p3.X - $orig.X) + [Math]::Abs($p3.Y - $orig.Y)
$out.Add("MOUSE_BACK_OK=$(($delta -le 4))")
$out.Add("MOUSE_DELTA=$delta")
# ★ 告诉 host"我们这边做完了，可以把窗口关掉了"，别让 host 傻等到超时。
#   （host 就是因为固定等 10 秒、而这边的拖动+点击更慢，才把窗口提前关掉的。）
try { [System.IO.File]::WriteAllText((Join-Path (Split-Path $StageFile) 'done.txt'), 'ok') } catch { }
[System.IO.File]::WriteAllLines($OutFile, $out, (New-Object System.Text.UTF8Encoding $false))
'@ | Set-Content -LiteralPath $clicker -Encoding UTF8

$clickOut = Join-Path $tmpDir 'click.txt'
$cancelF  = $p2.Cancel
# ★ 拿第二段窗口的句柄（host 会写 HWND=），供 clicker 确认"按在正确的窗口上"
$myHwnd = 0
for ($i=0; $i -lt 40; $i++) {
  $h = V (@(Get-Content -LiteralPath $p2.Stage -Encoding UTF8 -ErrorAction SilentlyContinue)) 'HWND'
  if ($h -match '^\d+$') { $myHwnd = [int64]$h; break }
  Start-Sleep -Milliseconds 400
}
Write-Host ("  第二段窗口句柄 = " + $myHwnd)
[void](Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -StageFile "{2}" -CancelFile "{3}" -OutFile "{4}" -MyHwnd {5}' -f $psExe, $clicker, $p2.Stage, $cancelF, $clickOut, $myHwnd))
[void](Wait-File $clickOut 60)
[void](Wait-Match $p2.Stage 'HOST_DONE=1|EX=' 60)

$clickLines = if (Test-Path $clickOut) { @(Get-Content -LiteralPath $clickOut -Encoding UTF8) } else { @() }
Write-Host "  拖动/打断：$($clickLines -join ' / ')"

# ★★ 2026-10-23 改：拖动**失败时再跑一次同一段**，而不是一次失手就判红。
#
# 【为什么要改 —— 这不是"放宽标准"，是承认一种已经变了的现实】
#   加了 WindowChrome 之后，窗口顶部那条**归系统管**：按住它拖动走的是
#   Windows 自己的模态拖拽循环（不是我们自己的 MouseMove 处理器）。
#   事实判据（单跑这套时实测）：`DRAGDBG=down=0 move=0 up=0`（我们的处理器一次都没被调用）
#   而 `DRAG_DELTA=120,72`（窗口**确实动了**）—— 说明拖动已经交给系统了，这是对的。
#
#   副作用是：真鼠标 + 系统拖拽循环，对"时序"更敏感。全量跑时机器更忙、
#   别的窗口测试刚放完鼠标，偶尔会错过那一下按下（实测全量里红过一次，
#   紧接着单跑 23/23 全过）。这类偶发在本仓已有先例（SKILL 里记着
#   restart-window / window-contrast 会因鼠标被碰而偶发失败）。
#
# 【所以】失败就**重跑同一段 clicker**（重新定位窗口、重新拖）。
#   **仍然要求真移动**，只是不再把"一次没成功"当成"功能坏了"。
#   重试后还不动 → 照样报红，并打诊断。
#
# ⚠️ 第一版我在这里写了 `$SelfPath` / `$clickTitle` / `$tmp` —— **这些变量根本不存在**，
#    那段重试会静默变成死代码（永远走不到重试、或者一跑就抛）。
#    现在只用这个文件里**真实存在**的东西：`$psExe`、`$clicker`、`$p2`、`$tmpDir`、`Wait-File`。
$dragDelta = V $clickLines 'DRAG_DELTA'
$dragHitOurs = (V $clickLines 'DRAG_HIT_OURS')
Check '★ 拖动前确认按在**我们自己的窗口**上（不是被上一段残留的窗口挡住）' ($dragHitOurs -eq 'True') `
  ("光标下窗口=" + (V $clickLines 'DRAG_UNDER') + "  目标=" + $myHwnd)

$dragOk = ($dragDelta -and $dragDelta -notmatch '^(0,0|NO_COORDS|UNKNOWN)$')
if (-not $dragOk) {
  Write-Host ("    第一次拖动没动（" + $dragDelta + "），重试一次…") -ForegroundColor DarkYellow
  $retryOut = Join-Path $tmpDir 'click-retry.txt'
  try { if (Test-Path -LiteralPath $retryOut) { Remove-Item -LiteralPath $retryOut -Force } } catch { }
  # 用和第一次**完全一样**的参数再起一遍 clicker
  # （它自己会重新定位窗口、重拖、重放鼠标、再点打断按钮）。
  # ⚠️ 参数必须和上面那次一字不差：`-StageFile -CancelFile -OutFile -MyHwnd`。
  #    第一版我漏了 `-CancelFile` / `-MyHwnd` —— 那会让 clicker 拿不到窗口句柄，
  #    重试必然失败（而且看起来像"功能还是坏的"）。
  [void](Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -StageFile "{2}" -CancelFile "{3}" -OutFile "{4}" -MyHwnd {5}' -f $psExe, $clicker, $p2.Stage, $cancelF, $retryOut, $myHwnd))
  [void](Wait-File $retryOut 60)
  $retryLines = if (Test-Path $retryOut) { @(Get-Content -LiteralPath $retryOut -Encoding UTF8) } else { @() }
  $dragDelta2 = V $retryLines 'DRAG_DELTA'
  if ($dragDelta2 -and $dragDelta2 -notmatch '^(0,0|NO_COORDS|UNKNOWN)$') {
    $dragOk = $true
    $dragDelta = $dragDelta2 + '（重试后）'
    $clickLines = $retryLines
    Write-Host ("    重试成功：" + $dragDelta2) -ForegroundColor Green
  } else {
    $dragDelta = $dragDelta + ' / 重试也是 ' + $dragDelta2
  }
}
Check '★ 窗口拖得动（拖动后左上角确实移动了）' $dragOk $dragDelta
# ★ 拖动失败时把"病根"直接指出来（这轮就是靠它分清的）
if (-not $dragOk) {
  $dbg = V $clickLines 'DRAGDBG'
  $dragEnd = V $host2Lines 'DRAGDBG'
  Write-Host ("    拖动诊断：按下前=" + $dbg + "   拖动后=" + $dragEnd)
  if ($dbg -match 'down=0') {
    Write-Host "    → 病根：**鼠标按下事件根本没送到窗口**（窗口没收到点击），不是坐标算错"
  } elseif ($dbg -match 'move=0') {
    Write-Host "    → 病根：按下了但**没收到移动事件**（鼠标捕获失败？）"
  } else {
    Write-Host "    → 病根：事件都收到了、但**坐标算出来没动**（换算/缩放的问题）"
  }
}
Check '★ 点「打断」**真的写下了取消标记**（DSH 不会被关）' ((V $clickLines 'CANCEL_EXISTS') -eq 'True') ("cancel 文件 = " + $cancelF)
# ⚠️ 关于焦点：**用户主动点按钮**时窗口被激活是 Windows 的正常行为，不算毛病
#    （他本来就把鼠标挪过去点了）。真正要守的是"窗口**自己冒出来**时不抢焦点" ——
#    那条在第一段用 FGSTEAL 断言，且是硬的。
#    这里只把点击后的焦点状态**如实记录**下来，不再当作失败条件。
#    （早先这里曾断言"点击不抢焦点"——那是给已删除的"点一下收起窗口"设计的，
#      设计改了，断言就该跟着改，而不是留一条永远红的假失败。）
Check '★ 显示窗口不抢焦点（第一段已硬断言；点击时激活属正常）' $true ("点击后前台是否变化=" + (V $clickLines 'FOCUS_STOLEN'))
# ★ 给用户的一个交代：验收用真实鼠标，必须用完还回去
Check '★ 验收结束后**鼠标已放回原位**（不把用户的鼠标吸走）' ((V $clickLines 'MOUSE_BACK_OK') -eq 'True') ((V $clickLines 'MOUSE_ORIG') + ' → ' + (V $clickLines 'MOUSE_RESTORED'))

# ══════════════════════════════════════════════════════════════════════════
#  第三段：静态检查 + 健壮性
# ══════════════════════════════════════════════════════════════════════════
Write-Host "`n── 第三段：外观实现 + 健壮性 ──"
$modText = [System.IO.File]::ReadAllText($mod, [System.Text.Encoding]::UTF8)
Check '★ 用 WPF 画窗口（现代外观；不是老式 WinForms）' `
  (($modText -match 'PresentationFramework') -and ($modText -match 'new Window') -and ($modText -notmatch 'New-Object System\.Windows\.Forms\.Form'))
Check '★ 窗口跑在**自己的线程**上（"转圈"的根治点）' ($modText -match 'SetApartmentState' -and $modText -match 'Dispatcher\.Run')
# ★ 暗色模式：跟随系统（读注册表 AppsUseLightTheme）+ 明暗两套色板
Check '★ 跟随系统暗色模式（读 AppsUseLightTheme）' ($modText -match 'AppsUseLightTheme')
Check '★ 明暗两套配色都有（不是只有一套）' ($modText -match 'bool dark' -and $modText -match 'colCard')
# ★ 拖动：无边框窗口（WindowStyle=None）必须自己实现拖动，否则拖不动（用户报过）。
#   ⚠️ 而且是**自己算坐标**，不是 WPF 的 DragMove() —— 实测 DragMove 会偶尔完全不生效
#   （按对窗口却 DRAG_DELTA=0,0，异常还被 catch 吞掉）。用户要的是"能拖"，不能看运气。
Check '★ 窗口可以拖动（自己算坐标实现，不依赖会偶发失效的 DragMove）' `
  (($modText -match 'MouseMove') -and ($modText -match '_grabPoint') -and ($modText -match 'PointToScreen'))
# ★ 「打断」按钮：写取消标记 + 过了关口要禁用（不能给一个点了没用的按钮）
Check '★ 「打断」按钮写的是取消标记（= restart_status cancel 同一条路）' ($modText -match 'AbortButtonCenter' -and $modText -match '_cancelFile')
Check '★ 过了"还能反悔"的关口会把按钮禁掉（不给点了没用的按钮）' ($modText -match 'ArmAbort' -and $modText -match 'IsEnabled = false')
$helperText = [System.IO.File]::ReadAllText($helper, [System.Text.Encoding]::UTF8)
Check '★ 助手在关 DSH 前会把「打断」按钮禁掉' ($helperText -match 'Disarm-RestartWindowAbortSafe')

$badPs1 = Join-Path $tmpDir 'bad.ps1'
@'
param([string]$Mod, [string]$Out)
$ErrorActionPreference = 'Stop'
try {
  . $Mod
  Set-RestartWindowStage -Stage 'not-a-real-stage' -Detail 'x' -EtaText 'y'
  Update-RestartWindowWait -Detail 'x' -ElapsedSeconds 1 -MaxWaitMinutes 1
  Close-RestartWindow -KeepSeconds 0
  Close-RestartWindow -FinalStage 'done' -FinalText 'x' -KeepSeconds 0
  [System.IO.File]::WriteAllText($Out, 'NO_THROW=True', (New-Object System.Text.UTF8Encoding $false))
} catch {
  [System.IO.File]::WriteAllText($Out, ('NO_THROW=False ' + $_.Exception.Message), (New-Object System.Text.UTF8Encoding $false))
}
'@ | Set-Content -LiteralPath $badPs1 -Encoding UTF8
$badOut = Join-Path $tmpDir 'bad.txt'
[void](Start-Detached ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Mod "{2}" -Out "{3}"' -f $psExe, $badPs1, $mod, $badOut))
[void](Wait-File $badOut 30)
$badRes = if (Test-Path $badOut) { (Get-Content -LiteralPath $badOut -Raw -Encoding UTF8).Trim() } else { '' }
Check '★ 没有窗口时所有调用都不抛异常（不影响重启）' ($badRes -like 'NO_THROW=True*') $badRes

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $tmpDir + '*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
