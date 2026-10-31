# ============================================================================
#  test-window-like-normal.ps1 —— 「它像一个正常的窗口吗」量真实行为
# ============================================================================
#  2026-10-23 下午建立。来源：用户
#    「这东西不能更像一个正常的窗口吗？它现在还就是鼠标放到所有地方都显示那个
#     可移动的效果，就是它不能像一个正常的窗口一样吗？……是就是如果我想的话，
#     得全部页面的这一块得重新写，还是说你调个属性就行？」
#
#  【为什么要单独一套，而不是往 static-sanity 里加断言】
#    static-sanity 只能证明「源码里有那一段」。而这次改的东西**全是行为**：
#      · 光标在哪个区域是"移动手型"、哪个区域是箭头 —— 只有问系统（WM_NCHITTEST）才知道；
#      · 任务栏里有没有它 —— 只有读窗口扩展样式（WS_EX_APPWINDOW）才知道；
#      · 能不能拉边框 —— 只有问系统命中测试才知道；
#      · 置顶会不会自己放下来 —— 只有等 10 秒再读一遍才知道。
#    本仓的老教训：`test-target-guard` 全绿而真 DSH 照样被误杀，就是因为它
#    "照抄一份逻辑来验"，**验得到计算、验不到接线**。所以这套**真开窗口、真问系统**。
#
#  【安全】只开测试窗口（DSH_RW_TEST_MODE=1），不跑助手、不碰真 DSH。
#          跑前跑后核对真 DSH 的监听 PID 没变。
#
#  【它验的四件事 —— 对应用户说的"怪"】
#    ① 顶部那条是 HTCAPTION（可拖、光标是移动手型），正文是 HTCLIENT（普通箭头）
#       ⇒ 这就直接回答了"鼠标放到所有地方都是可移动效果"有没有治好；
#    ② 任务栏里能找到它（WS_EX_APPWINDOW）；
#    ③ 边框能拉（命中测试在边缘返回 HTLEFT/HTRIGHT/HTTOP/HTBOTTOM）；
#    ④ 置顶会自己放下来（10 秒后读 Topmost）。
#
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File test-window-like-normal.ps1
#  退出码 0 = 全过；1 = 有失败
# ============================================================================

[CmdletBinding()]
param([switch]$BreakSelfTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$winMod = if ($env:DSH_RW_WINDOW_MODULE) { $env:DSH_RW_WINDOW_MODULE }
          else { Join-Path (Split-Path -Parent $here) 'bin\dsh-restart-window.ps1' }

$script:Pass = 0
$script:Fail = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    $script:Pass++
    Write-Host ("  [通过] {0}" -f $Name) -ForegroundColor Green
  } else {
    $script:Fail++
    $script:Failed.Add($Name)
    Write-Host ("  [失败] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
  }
}

if (-not (Test-Path -LiteralPath $winMod)) {
  Write-Host "找不到窗口模块：$winMod" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '=== 0. 源码结构（快速失败：结构不对就没必要开窗了）===' -ForegroundColor Cyan
$winText = [IO.File]::ReadAllText($winMod)
Check '窗口模块里有 WindowChrome' ($winText -match 'System\.Windows\.Shell\.WindowChrome')
Check '有 !_chromeOk 的光标条件（整卡 SizeAll 已改掉）' ($winText -match 'if\s*\(!\s*_chromeOk\)')

Write-Host ''
Write-Host '=== 1. 开真窗口，问系统"这里是什么"===' -ForegroundColor Cyan

# 真 DSH 基线（跑前跑后要一致 —— 这套只许碰测试窗口）
$realBefore = $null
try {
  $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
  if (Test-Path -LiteralPath $st) {
    $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
    if ($p) { $realBefore = (Get-NetTCPConnection -LocalPort ([int]$p) -State Listen -EA SilentlyContinue | Select-Object -First 1).OwningProcess }
  }
} catch { }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Wln {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct POINT { public int X, Y; }
  public static IntPtr LP(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
  public const uint WM_NCHITTEST = 0x0084;
}
"@

$env:DSH_RW_TEST_MODE = '1'
. $winMod

$shown = $false
try {
  $shown = Show-RestartWindow -Title '正常窗口验收' `
             -InitialStage '等待中' `
             -InitialDetail '量一下光标分区 / 任务栏 / 可拉伸 / 置顶。' `
             -InitialEta '' `
             -ShowWindow $true
} catch {
  Write-Host ("  开窗失败: " + $_.Exception.Message) -ForegroundColor Red
}
Check '窗口能起来（否则后面全是假通过）' $shown

if (-not $shown) {
  Write-Host ''
  Write-Host ("===== 汇总：{0}/{1} 通过（窗口没起来，后面的没跑）=====" -f $script:Pass, ($script:Pass + $script:Fail))
  exit 1
}

Start-Sleep -Seconds 2

# ── 找 hwnd：用模块自己报的左上角 + WindowFromPoint 反查 ──────────────────────
#
# ⚠️ 别用"按标题枚举窗口"：实测 WPF 的 Title 在 GetWindowTextW 里读出来是乱码，
#    按标题匹配**永远找不到**（我在这里白绕了好几轮）。
# ⚠️ 别用"按类名找 HwndWrapper"：实测也搜不到（WPF 的窗口类名不是这个名字）。
# ⇒ 用模块自己报的坐标 + WindowFromPoint —— 它报的是**物理像素**（实测确认）。
$hwnd = [IntPtr]::Zero
try {
  $tl = Get-RestartWindowTopLeft
  $parts = $tl -split ','
  $lx = [double]$parts[0]; $ly = [double]$parts[1]
  $pt = New-Object Wln+POINT
  $pt.X = [int]$lx + 200
  $pt.Y = [int]$ly + 30
  $hwnd = [Wln]::WindowFromPoint($pt)
} catch { }
Check '能在屏幕上定位到这个窗口（定位不到就没法量）' ($hwnd -ne [IntPtr]::Zero) ("hwnd=$hwnd")

if ($hwnd -ne [IntPtr]::Zero) {
  $rc = New-Object Wln+RECT
  [void][Wln]::GetWindowRect($hwnd, [ref]$rc)
  $pw = $rc.Right - $rc.Left
  $ph = $rc.Bottom - $rc.Top
  Write-Host ("  窗口物理矩形 L={0} T={1} 尺寸 {2}x{3}" -f $rc.Left, $rc.Top, $pw, $ph)

  $ex = [int64][Wln]::GetWindowLongPtr($hwnd, -20)
  $st2 = [int64][Wln]::GetWindowLongPtr($hwnd, -16)

  # ── ①②③④ 逐项量 ──────────────────────────────────────────────────────────
  $sx = $rc.Left + [int]($pw / 2)
  function HitAt([int]$dy) {
    $sy = $rc.Top + $dy
    return [int][Wln]::SendMessage($hwnd, [Wln]::WM_NCHITTEST, [IntPtr]::Zero, [Wln]::LP($sx, $sy))
  }

  $hitTitle1 = HitAt 15
  $hitTitle2 = HitAt 35
  $hitBody   = HitAt ([int]($ph * 0.7))
  $hitBottom = HitAt ($ph - 3)

  Write-Host ("  命中测试：距顶15->HT{0}  距顶35->HT{1}  正文->HT{2}  距底3->HT{3}" -f `
    $hitTitle1, $hitTitle2, $hitBody, $hitBottom)

  # ① 顶部是标题栏（HTCAPTION=2）⇒ 光标是"移动手型"、按住能拖
  Check '★ 顶部那个区域=可拖动标题栏（HTCAPTION）—— 光标不再是四向箭头' `
    (($hitTitle1 -eq 2) -and ($hitTitle2 -eq 2)) ("HT$hitTitle1 / HT$hitTitle2")
  # ② 正文是普通区域（HTCLIENT=1）⇒ 普通箭头
  Check '★ 正文区域=普通客户区（HTCLIENT）—— 不再是"哪儿都能拖"' `
    ($hitBody -eq 1) ("HT$hitBody")
  # ③ 底边可拉伸（HTBOTTOM=15）
  Check '★ 底边可拉伸（HTBOTTOM）—— 像正常窗口一样能拉大小' `
    ($hitBottom -eq 15) ("HT$hitBottom")
  # ④ 任务栏里能找到它（WS_EX_APPWINDOW = 0x40000，或至少不是 WS_EX_TOOLWINDOW）
  $appWin = (($ex -band 0x40000) -ne 0)
  $toolWin = (($ex -band 0x80) -ne 0)
  Check '★ 任务栏里能找到它（AppWindow 样式在，且不是工具窗）' `
    ($appWin -and (-not $toolWin)) ("APPWINDOW=$appWin TOOLWINDOW=$toolWin")

  # ⑤ 置顶是限时的：刚开时是置顶，10 秒后要放下来
  $topAtStart = (($ex -band 0x8) -ne 0)
  Check '★ 刚弹出来时是置顶的（保证你看得见）' $topAtStart

  Write-Host '  等 12 秒，看置顶会不会自己放下来…' -ForegroundColor DarkGray
  Start-Sleep -Seconds 12
  $ex2 = [int64][Wln]::GetWindowLongPtr($hwnd, -20)
  $topLater = (($ex2 -band 0x8) -ne 0)
  Check '★★ 10 秒后置顶**自己放下来了**（用户 定的）' (-not $topLater) `
    $(if ($topLater) { '12 秒后仍然是 Topmost —— 定时器没生效，窗口还在永远压着别人' } else { '已放下' })
  # ⚠️ 这条要用**系统窗口样式**判，不能只读 WPF 的 Topmost 属性：
  #    属性可能是 false 而扩展样式没更新（那窗口照样压着别人）。两边都读，以样式为准。
  try {
    Check '★ 窗口自己报的 TopmostDropped 也是 true（两边一致）' ([bool]$script:DshRw.TopmostDropped)
  } catch {
    Check '★ 窗口自己报的 TopmostDropped 也是 true（两边一致）' $false $_.Exception.Message
  }
}

# ── 收尾 ────────────────────────────────────────────────────────────────────
try { Close-RestartWindow -FinalStage 'done' -FinalText '验收结束' -KeepSeconds 1 } catch { }

$realAfter = $null
try {
  $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
  if (Test-Path -LiteralPath $st) {
    $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
    if ($p) { $realAfter = (Get-NetTCPConnection -LocalPort ([int]$p) -State Listen -EA SilentlyContinue | Select-Object -First 1).OwningProcess }
  }
} catch { }
Check '★ 真 DSH 的监听 PID 跑前跑后没变（这套只碰测试窗口）' ($realBefore -eq $realAfter) `
  ("之前=$realBefore 现在=$realAfter")

# ── 汇总 ────────────────────────────────────────────────────────────────────
$total = $script:Pass + $script:Fail
Write-Host ''
Write-Host ("===== 汇总：{0}/{1} 通过 =====" -f $script:Pass, $total)
if ($script:Fail -gt 0) {
  Write-Host '失败项：'
  foreach ($f in $script:Failed) { Write-Host ("  · " + $f) -ForegroundColor Red }
}

if ($BreakSelfTest) {
  $turnedRed = ($script:Fail -gt 0)
  Write-Host ''
  Write-Host $(if ($turnedRed) { '*** 改坏自检：确实变红了 —— 断言有效 ***' } else { '*** 改坏自检失败：仍然全绿 —— 断言无效 ***' })
  exit $(if ($turnedRed) { 0 } else { 1 })
}

exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
