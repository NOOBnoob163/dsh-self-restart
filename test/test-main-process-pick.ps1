# 实测：「挑主进程」这个动作会不会挑错 —— 2026-10-10 那个真 bug 的回归测试。
#
# 背景（用户实测反馈"关的时候弹了一下报错"）：
#   DSH 有好几类进程都叫 `DeepSeek Harness.exe`，且命令行**都不含** `--type=`：
#     · Electron 主进程 —— **只有它持有窗口**
#     · Node 宿主（--expose-internals）
#     · Node 子工（dsh-subprocess-lo… / ego-cast-worker）
#   老判据是"**第一个**没有 --type= 的"，而 Get-Process **返回顺序不保证** ——
#   实测挑到了 PID 2504（一个子工，没有窗口）。
#   给没有窗口的进程发 taskkill（不带 /F），Windows 找不到窗口发 WM_CLOSE，
#   只能回 "can only be terminated forcefully" → 白等 12 秒 → 强杀 →
#   残留渲染进程闪一条报错。helper.log 里"优雅退出 0 次 / 强制 7 次"就是铁证。
#
# 本测试**不碰真 DSH**：自己造几个"同名不同型"的假进程来验判据。
#   关键是让它**复现老 bug 的顺序**：故意让"没有窗口的子工"先被枚举到。
#
# 用法：powershell -NoProfile -File test-main-process-pick.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-mainpick-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# 枚举某进程的**全部**顶层窗口（含隐藏）—— 判"有没有窗口可发 WM_CLOSE"必须看这个，
# 光看 Process.MainWindowHandle 只能看到**可见**的那个（DSH 主进程有 8 个窗口，
# 其中 7 个是隐藏的；而诱饵进程是 0 个，连隐藏的都没有）。
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class WQ {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public class Info { public string Cls; public bool Visible; }
  public static List<Info> ForPid(uint target) {
    var list = new List<Info>();
    EnumWindows((h, x) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target) {
        var cb = new StringBuilder(256); GetClassName(h, cb, 256);
        list.Add(new Info { Cls = cb.ToString(), Visible = IsWindowVisible(h) });
      }
      return true;
    }, IntPtr.Zero);
    return list;
  }
}
"@

# ── 一、逻辑回归：判据本身对不对（静态读代码 + 模拟）─────────────────────────
Write-Host "── 一、判据本身（防有人改回"第一个没有 --type= 的"）──"
$txt = [System.IO.File]::ReadAllText($helper, [System.Text.Encoding]::UTF8)
Check '★ 优先挑**持有窗口**的进程（MainWindowHandle）' ($txt -match 'MainWindowHandle -ne 0')
Check '★ 有退路：没窗口时按**命令行最短**挑（主进程参数最少）' ($txt -match 'Sort-Object Len')
Check '★ 注释里留了这次事故的来龙去脉（防后人"简化"回去）' ($txt -match 'could only be terminated forcefully|只能强制|can only be terminated')
Check '★ 礼貌关闭当场失败时不再白等' ($txt -match 'gracefulAsked')
# ★ 2026-10-10 第二次修：DSH **结构上不可能**被"礼貌关闭"弄退出 ——
#   它有 8 个顶层窗口，只有 1 个可见，其余 7 个是隐藏的功能窗口
#   （NotifyIconHost / PowerMessageWindow / IME…），WM_CLOSE 关不掉它们；
#   而 DSH 的退出条件是 window-all-closed（所有窗口都关）→ 永远不 quit。
#   实测证据：砍之前那次 taskkill **已经 SUCCESS**，却仍白等满 12 秒，
#   且那 12 秒里**没有任何**会话文件被写过（0 个）= 它根本没在做收尾。
$m = [regex]::Match($txt, '\$waited\s*-lt\s*(\d+)')
if ($m.Success) {
  $limit = [int]$m.Groups[1].Value
  Check '★ 优雅关闭的宽限期很短（≤6 秒；DSH 反正不自退，等久了纯浪费）' ($limit -le 6) ("宽限期 = $limit 秒")
} else {
  Check '★ 优雅关闭的宽限期很短（≤6 秒）' $false '没找到 $waited 循环'
}
Check '★ 注释写明了"隐藏窗口"这个结构性原因（防后人改回 12 秒）' `
  (($txt -match '隐藏窗口') -and ($txt -match 'window-all-closed'))

# ── 二、实机判据验证：真 DSH 上重放新旧两种选法，看结果是否不同 ────────────────
Write-Host "`n── 二、在**实机**上重放两种选法（只读，不关任何东西）──"
$all = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
Check '实机上确实有 DSH 进程可验' ($all.Count -ge 2) ("共 " + $all.Count + " 个")

$typed = @{}; $noTypeList = @(); $withWinList = @()
foreach ($p in $all) {
  $cl = ''
  try { $cl = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine } catch { }
  # ★ 用"全部顶层窗口数（含隐藏）"来判 —— 这才是能不能发 WM_CLOSE 的真依据；
  #   MainWindowHandle 只看可见窗口，会把"有隐藏窗口"的进程也当成没窗口。
  $wc = [WQ]::ForPid([uint32]$p.Id).Count
  if ($cl -match '--type=') { $typed[$p.Id] = $true }
  else { $noTypeList += [pscustomobject]@{ Id = $p.Id; Len = $cl.Length; WinCount = $wc; HasWin = ($wc -gt 0) } }
  if ($wc -gt 0) { $withWinList += $p.Id }
}

# 实机上必须存在"没有窗口但也不带 --type="的进程 —— 否则本判据无从谈起
$trap = @($noTypeList | Where-Object { -not $_.HasWin })
Check '★ 实机上确实存在"没窗口、却不带 --type="的诱饵进程（老 bug 的温床）' ($trap.Count -ge 1) ("诱饵 " + $trap.Count + " 个：PID " + (($trap | ForEach-Object { $_.Id }) -join ', '))

# 老选法 = 第一个没有 --type= 的（顺序不保证）
$oldPick = $noTypeList[0]
# 新选法 = 优先有窗口的
$newPickId = if ($withWinList.Count -gt 0) { $withWinList[0] } else { ($noTypeList | Sort-Object Len | Select-Object -First 1).Id }
$newPick = $noTypeList | Where-Object { $_.Id -eq $newPickId } | Select-Object -First 1

Write-Host ("   老选法 → PID {0}（有窗口={1}）" -f $oldPick.Id, $oldPick.HasWin)
Write-Host ("   新选法 → PID {0}（有窗口={1}）" -f $newPickId, $(if ($newPick) { $newPick.HasWin } else { (Get-Process -Id $newPickId -EA SilentlyContinue).MainWindowHandle -ne 0 }))
Check '★ 新选法选中的进程**确实持有窗口**（能给 WM_CLOSE）' `
  ([bool](@($withWinList) -contains $newPickId)) ("选中 PID $newPickId；有窗口的是 " + (($withWinList) -join ', '))
# ⚠️ 关于老选法：**不能断言"它这次一定选错"** ——
#   它的成败取决于 Get-Process 的返回顺序（不保证），也就是**碰运气**：
#     运气好时第一个恰好是主进程 → 看着"没事"；运气差时选中子工 → 必然失败。
#   所以这里要断言的是"**存在选错的机会**"（诱饵确实在候选名单里），
#   而不是"此刻正好选错了"。第一版写成后者，于是当顺序恰好正确时就误报红 ——
#   那会把"碰运气"错当成"没问题"，方向正好反了。
$canPickWrong = ($trap.Count -ge 1)
Check '★ 老选法**有选错的机会**（诱饵在候选里；不是"每次必错"，是碰运气）' $canPickWrong `
  ("诱饵 " + $trap.Count + " 个在候选里；这次老选法恰好选中 PID " + $oldPick.Id + "（有窗口=" + $oldPick.HasWin + "）")

# ── 三、受控实验：给"**一个窗口都没有**"的进程发 taskkill 会怎样（用替身，不碰 DSH）──
#
# ⚠️ 这一条**必须用 GUI 型进程**（比如 DSH 自己那种 Chromium 程序），
#    不能用 powershell.exe / node.exe 当替身 —— 那两个即使加了 -WindowStyle Hidden，
#    也仍然有一个**隐藏的控制台窗口**（ConsoleWindowClass, visible=False），
#    taskkill 照样能往上发 WM_CLOSE 并返回 SUCCESS。
#    第一版就是这么写的，对照组"失败"，差点以为前面的结论是错的。
#    真正"一个窗口都没有"的进程，taskkill 才会报 forcefully —— 那正是 DSH 那 3 个
#    Node 子工的情形（实测：WinCount = 0，连隐藏窗口都没有）。
Write-Host "`n── 三、受控实验：给**真正零窗口**的进程发 taskkill（替身，不碰 DSH）──"
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source }
Write-Host ("  node 可执行体: " + $nodeExe)
if ($nodeExe) {
  # ⚠️ 要造出"**一个顶层窗口都没有**"的进程，只加 -WindowStyle Hidden 或 ShowWindow=0
  #    都**不够** —— 实测那样仍会带一个 ConsoleWindowClass（隐藏的控制台），
  #    于是 taskkill 照样能成功，对照组就永远验不出来（我试了两轮才发现）。
  #    必须用 CreateProcess 的 **CREATE_NO_WINDOW**（0x08000000）：根本不创建控制台。
  #    这也正是 DSH 那些 Node 子工的处境（它们由 Electron 拉起，天生没有控制台）。
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class NoWin {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
    uint flags, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  public static int Start(string exe, string args) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
    PROCESS_INFORMATION pi;
    const uint CREATE_NO_WINDOW = 0x08000000;
    if (!CreateProcess(exe, "\"" + exe + "\" " + args, IntPtr.Zero, IntPtr.Zero, false,
        CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi)) return 0;
    return pi.dwProcessId;
  }
}
"@
  $decoyPid = [NoWin]::Start($nodeExe, '-e "setTimeout(function(){},90000)"')
  Start-Sleep -Seconds 3
  if ($decoyPid -eq 0) {
    Check '★（对照组）拿到了一个零窗口替身' $false 'CreateProcess 失败'
  } else {
    $wc = [WQ]::ForPid([uint32]$decoyPid).Count
    Write-Host ("  替身 PID=" + $decoyPid + "  顶层窗口数=" + $wc)
    if ($wc -eq 0) {
      # ⚠️ taskkill 失败时会把 ERROR 写到 stderr，而 PowerShell 5.1 遇到原生命令的
      #    stderr 会抛 NativeCommandError（即使已经 2>&1 重定向）。
      #    这里要的**恰恰是**那条报错，所以把 $ErrorActionPreference 临时降到 Continue。
      $eap = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      $out = & taskkill.exe /PID $decoyPid 2>&1
      $ErrorActionPreference = $eap
      $nl = ($out | ForEach-Object { $_.ToString() }) -join ' '
      Write-Host ("  taskkill 说: " + $nl.Substring(0,[Math]::Min(140,$nl.Length)))
      Check '★（对照组）**真正零窗口**的进程确实收到 "can only be terminated forcefully"' ($nl -match 'forcefully') $nl
    } else {
      Write-Host "  ⚠️ 这个替身仍有 $wc 个窗口 → 跳过对照组（它证明不了那条机制）"
      Check '★（对照组）拿到了一个零窗口替身' $false ("窗口数=$wc")
    }
    Stop-Process -Id $decoyPid -Force -ErrorAction SilentlyContinue
  }
}
Write-Host "   含义：这不是"DSH 不肯退"，而是"问错了人"—— 给一个没有窗口的进程发关闭请求。"

# ── 四、受控实验：给"有窗口"的进程发 taskkill，应当 SUCCESS 并优雅退出 ────────
Write-Host "`n── 四、受控实验：给**有窗口**的进程发 taskkill（替身）──"
$gui = Join-Path $tmpDir 'gui.ps1'
@'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = 'mainpick-decoy'
$f.Size = New-Object System.Drawing.Size(280,180)
$f.Show()
[System.Windows.Forms.Application]::Run($f)
'@ | Set-Content -LiteralPath $gui -Encoding UTF8
$gp = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$gui) -PassThru
Start-Sleep -Seconds 4
$hasWin = $false
try { $hasWin = ((Get-Process -Id $gp.Id -ErrorAction SilentlyContinue).MainWindowHandle -ne 0) } catch { }
Write-Host ("   替身 PID=" + $gp.Id + "  持有窗口=" + $hasWin)
$out2 = & taskkill.exe /PID $gp.Id 2>&1
$nl2 = ($out2 -join ' ')
Write-Host ("   taskkill 说: " + $nl2.Substring(0,[Math]::Min(120,$nl2.Length)))
if ($hasWin) {
  Check '★（正向）有窗口的进程能收到 SUCCESS 并被优雅关闭' ($nl2 -match 'SUCCESS') $nl2
  $gone = $false
  for ($i=0; $i -lt 12; $i++) { Start-Sleep -Milliseconds 500; if (-not (Get-Process -Id $gp.Id -EA SilentlyContinue)) { $gone = $true; break } }
  Check '★（正向）它真的自己退了（优雅关闭确实可行）' $gone
}
Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue

# ── 收尾 ────────────────────────────────────────────────────────────────────
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $tmpDir + '*') } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
if ($failed.Count) { exit 1 }
exit 0
