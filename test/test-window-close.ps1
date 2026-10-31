# ============================================================================
#  test-window-close.ps1 —— 右上角 ✕ 真的能点、真的会写取消标记、真的关窗
# ============================================================================
#  2026-10-23 建立。来源：用户「我认为现在这个窗口还缺一个打断功能……
#  或者让它像正常窗口一样，右上角有个叉号能关掉这种感觉」
#
#  【为什么单独一套】
#    这个功能**只存在于真实窗口里** —— 它是 WPF 的按钮点击，不是纯函数。
#    靠读代码或读返回值都验不出来"点了到底发不生效"。
#    2026-10-23 试过三种自动化办法全失败（UI Automation 找不到无边框窗口 /
#    外部 Dispatcher 调 PowerShell 脚本块会卡死 / 跨线程读 Content 拿到空值），
#    所以窗口模块自己提供了 Invoke-RestartWindowCloseClick（真的 RaiseEvent）。
#
#  【安全】只开一个测试窗口（DSH_RW_TEST_MODE=1），不跑助手、不碰真 DSH。
# ============================================================================

[CmdletBinding()]
param([switch]$BreakSelfTest)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# ⚠️ 允许用环境变量指定窗口模块 —— **只**给 -BreakSelfTest 的子进程用：
#   改坏自检必须在**新进程**里跑改坏的副本，因为在同一进程里二次点源模块时
#   C# 类型已经编译进内存（$script:DshRwTypeReady 缓存），改了源码也不会重新编译，
#   于是"改坏"根本不生效 —— 那就成了假自检（绿得毫无意义）。
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

# ── 0. 源码结构：该有的东西在不在 ──────────────────────────────────────────
Write-Host ''
Write-Host '=== 0. 源码结构 ===' -ForegroundColor Cyan
$winText = [IO.File]::ReadAllText($winMod)

Check '窗口类里有 _close 字段' ($winText -match 'private Button _close;')
Check '窗口类暴露了 ClickCloseForTest（测试入口）' ($winText -match 'public void ClickCloseForTest')
Check '有 PowerShell 包装函数 Invoke-RestartWindowCloseClick' ($winText -match 'function Invoke-RestartWindowCloseClick')
Check '★ 点 ✕ 会写取消标记（File.WriteAllText(_cancelFile）' ($winText -match 'File\.WriteAllText\(_cancelFile')
Check '★ 点 ✕ 会关窗（调 Close）' ($winText -match '(?s)_close\.Click.*?Close\(\);')
Check '★ 平时那态也给了确定的前景色（对比度不再靠悬停）' `
  ($winText -match 'ctNormal\.Setters\.Add\(new Setter\(Button\.ForegroundProperty')

# ── 1. 实际运行：开窗 → 点 ✕ → 验取消标记 + 关窗 ─────────────────────────────
Write-Host ''
Write-Host '=== 1. 实际运行：点右上角 ✕ ===' -ForegroundColor Cyan

$tmp = Join-Path $env:TEMP ('winclose-' + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$cancelFile = Join-Path $tmp 'cancel.flag'
$env:DSH_RW_TEST_MODE = '1'          # 让窗口标题带测试标记，绝不会被当成真重启

$realBefore = $null
try {
  $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
  if (Test-Path -LiteralPath $st) {
    $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
    if ($p) { $realBefore = (Get-NetTCPConnection -LocalPort ([int]$p) -State Listen -EA SilentlyContinue | Select-Object -First 1).OwningProcess }
  }
} catch { }

. $winMod

$shown = $false
try {
  $shown = Show-RestartWindow -Title '叉号点击验收' `
             -InitialStage '等待中' `
             -InitialDetail '即将自动点一下右上角的 ✕。' `
             -InitialEta '3 秒' `
             -CancelFile $cancelFile `
             -ShowWindow $true
} catch {
  Write-Host ("  开窗失败: " + $_.Exception.Message) -ForegroundColor Red
}

Check '窗口能起来（否则后面全是假通过）' $shown
Start-Sleep -Seconds 2

Check '★ 点之前：取消标记**不存在**' (-not (Test-Path -LiteralPath $cancelFile))

if ($BreakSelfTest) {
  Write-Host ''
  Write-Host '*** 改坏自检 ***' -ForegroundColor Yellow
  Write-Host '    把「写取消标记」那行从模块里抠掉，然后**用新进程**跑同一套断言。' -ForegroundColor Yellow
  Write-Host '    期望结果：子进程**变红**（说明断言真的盯着那行代码）。' -ForegroundColor Yellow

  # ⚠️ 必须在新进程里跑（见文件头 DSH_RW_WINDOW_MODULE 的说明：
  #    同进程二次点源不会重新编译 C# 类型，改坏不生效 = 假自检）
  $brokenText = $winText -replace '(?m)^\s*try \{ System\.IO\.File\.WriteAllText\(_cancelFile.*$', '   // (broken on purpose)'
  $brokenPath = Join-Path $tmp 'win-broken.ps1'
  [IO.File]::WriteAllText($brokenPath, $brokenText)

  # ⚠️ 模块里有**两处**写取消标记：①「打断」按钮（行~531）② 叉号（行~649）。
  #    改坏只该抠掉叉号那处，所以判据是"处数恰好少 1"，不是"一处都不剩"。
  #    （第一版写成"一处都不剩"，于是被 ① 的存在骗红 —— 假红最浪费时间。）
  $cntBefore = ([regex]::Matches($winText, 'File\.WriteAllText\(_cancelFile')).Count
  $cntAfter = ([regex]::Matches($brokenText, 'File\.WriteAllText\(_cancelFile')).Count
  Check '改坏自检的前提：恰好抠掉了叉号那一处（打断按钮那处不动）' `
    ($cntAfter -eq ($cntBefore - 1)) `
    ("改坏前 $cntBefore 处、改坏后 $cntAfter 处 —— 替换没按预期生效，后面结论不作数")

  try { Close-RestartWindow } catch { }
  Start-Sleep -Milliseconds 500

  # 用环境变量把**子进程**指向改坏的模块副本
  $env:DSH_RW_WINDOW_MODULE = $brokenPath
  try {
    $childOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                   -File $PSCommandPath 2>&1 | Out-String
    $childCode = $LASTEXITCODE
  } finally {
    Remove-Item Env:\DSH_RW_WINDOW_MODULE -ErrorAction SilentlyContinue
  }

  Check '★ 改坏之后子进程确实变红（证明断言真的盯着那行代码）' ($childCode -ne 0) `
    ("子进程退出码=$childCode —— 代码改坏了它还绿，说明断言没盯住")

  Write-Host ''
  Write-Host '  子进程输出（末几行）：' -ForegroundColor DarkGray
  ($childOut -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 7) |
    ForEach-Object { Write-Host ('    ' + $_.Trim()) -ForegroundColor DarkGray }
} else {
  # 真点
  $clicked = Invoke-RestartWindowCloseClick
  Check '测试入口调得动（返回 true）' $clicked
  Start-Sleep -Seconds 2

  Check '★ 点之后：取消标记**被创建了**（这就是"点了要停止"的信号）' `
    (Test-Path -LiteralPath $cancelFile)
  if (Test-Path -LiteralPath $cancelFile) {
    $body = Get-Content -LiteralPath $cancelFile -Raw -Encoding UTF8
    Check '取消标记内容非空（不是建了个空文件）' ([bool]($body -and $body.Trim()))
  }

  # ⚠️ 注意返回类型：窗口关掉后 Get-RestartWindowAbortButtonPos 返回的是**空字符串 ''**，
  #    不是 $null。第一版断言写成 `$null -eq $pos` → 恒假 → 假红了一轮。
  #    判断"窗口还开着吗"要按"非空字符串"来判，别拿 $null 比。
  $pos = Get-RestartWindowAbortButtonPos
  $stillUp = [bool]($pos -and ([string]$pos).Trim())
  Check '★ 点之后：窗口**已经关掉**（IsUp 变 false）' (-not $stillUp) `
    ('窗口还开着 —— 点了 ✕ 却不关，和「像正常窗口一样」不符；pos=[' + [string]$pos + ']')
}

# ── 2. 安全核对：真 DSH 没被碰 ─────────────────────────────────────────────
Write-Host ''
Write-Host '=== 2. 真 DSH 安全核对 ===' -ForegroundColor Cyan
$realAfter = $null
try {
  $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
  if (Test-Path -LiteralPath $st) {
    $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
    if ($p) { $realAfter = (Get-NetTCPConnection -LocalPort ([int]$p) -State Listen -EA SilentlyContinue | Select-Object -First 1).OwningProcess }
  }
} catch { }

Check '★ 真 DSH 的监听 PID 跑前跑后没变' `
  ($realBefore -eq $realAfter -and $realAfter -gt 0) `
  ("跑前=$realBefore 跑后=$realAfter")

# ── 收尾 ────────────────────────────────────────────────────────────────────
try { Close-RestartWindow } catch { }
Remove-Item Env:\DSH_RW_TEST_MODE -ErrorAction SilentlyContinue
Add-Type -AssemblyName Microsoft.VisualBasic
if (Test-Path -LiteralPath $tmp) {
  try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($tmp, 'OnlyErrorDialogs', 'SendToRecycleBin') } catch { }
}

Write-Host ''
if ($script:Fail -gt 0) {
  Write-Host '失败的断言：' -ForegroundColor Red
  $script:Failed | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
  Write-Host ''
  Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Red
  exit 1
}
Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor Green
exit 0
