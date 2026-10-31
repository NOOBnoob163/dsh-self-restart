# 一键跑完全部测试，并汇总结果。
#
# 为什么要这个：这些测试合起来要跑 15 分钟左右，一个个手敲命令很烦，
#   （⚠️ 数字别写死在这儿就不管了 —— 2026-10-11 发现这里一直写着"12 套"，
#     而当时实际已经有 21 套。2026-10-22 又加了两套（members / queue），
#     2026-10-24 加了一套（force-button），现在是 **41 套**（实测 `$suites` 条数，
#     不是估的 —— 用 `Select-String -Pattern '^\s*@\{ Name = '` 数一遍）。要改的时候顺手核对一下。）
# 而且**哪些是"常用测试"、哪些是历史证据**容易搞混。这个脚本只跑常用测试。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-all-tests.ps1
#   powershell ... -File run-all-tests.ps1 -Only 'test-helper','test-two-phase'   # 只跑指定的
#
# ⚠️ 全程**不碰真 DSH**：所有测试都用假目标（假 exe / 假端口 / 假会话目录），
#    每套末尾都有"真 DSH 监听者 PID 没变"的独立断言兜底。
#    跑完请核对它打印的监听者 PID 前后一致。
#
# ⚠️ param() 必须是**第一条可执行语句**（PowerShell 语法要求），所以它在注释之后、别的东西之前。
param([string[]]$Only)

$ErrorActionPreference = 'Stop'
# ★ 2026-10-13 修：原生命令往 stderr 写字（PowerShell 7 默认把它包成 ErrorRecord）
#   会在 $ErrorActionPreference='Stop' 下**直接把整个跑批掀翻**。
#   实测：`restart-window` 里 Get-Content 撞上一次文件占用（`stages-res` 正被写），
#   报了一句 RemoteException —— 于是**后面 8 套根本没跑**（包括新加的两套），
#   而汇总表只列了跑到一半的那几套，看起来像"全绿收工"。
#   ⇒ 跑批器必须比被测套件更皮实：单套失败/报错**只记账、继续跑**。
#   （这里改的是"跑批器自己的容错"，各套件内部仍然该严格。）
$ErrorActionPreference = 'Continue'

$base = $PSScriptRoot
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 常用测试清单（顺序按"快 → 慢"排，出错时能更早看到）
$suites = @(
  # ── ★ 2026-10-22 排队重启那一批（最快，放最前，改坏了 2 秒就知道）──────────
  @{ Name = 'target-guard';          Kind = 'ps';   File = 'test-target-guard.ps1';          Desc = '★ 要杀的==要拉起的（维护记录 事故的护栏，最重要的一套）' }
  # ★ 2026-10-23 加：这一套**跑真脚本**，是唯一能验出"护栏算完有没有人停"的测试。
  #   当年 target-guard 全绿却仍在误杀，就是因为它"照抄一份逻辑来验"，验不到接线。
  @{ Name = 'dry-run-guard';         Kind = 'ps';   File = 'test-dry-run-guard.ps1';         Desc = '★★ 端到端：护栏真的会停手 + 干跑真的不动手（跑真脚本，不抄逻辑）' }
  # ★ 2026-10-23 加：叉号是 WPF 按钮，**只能**在真窗口里验它点下去生不生效。
  #   读代码、读返回值都证明不了"点了到底关不关窗、写不写取消标记"。
  @{ Name = 'window-close';          Kind = 'ps';   File = 'test-window-close.ps1';          Desc = '★ 右上角 ✕：点了真的写取消标记 + 真的关窗（开真窗口验证）' }
  # ★ 2026-10-24 加：「不等了，立刻重启」= 这次"等家务等到没完"事故的出口。
  #   按钮是 WPF 控件，只能开真窗口真点一下才算验过 —— 读源码证明不了它写不写标记。
  @{ Name = 'force-button';          Kind = 'ps';   File = 'test-force-button.ps1';          Desc = '★ 「不等了」：没点亮不写、点亮只写 force 不写 cancel（开真窗口验证）' }
  # ★ 2026-10-23 下午加：用户报「鼠标放到所有地方都显示那个可移动的效果，能不能像正常窗口」。
  #   这套**真开窗口、真问系统**（WM_NCHITTEST / 扩展样式），不是读源码猜 ——
  #   因为要验的全是行为：光标分区、任务栏、可拉伸、置顶会自己放下来。
  @{ Name = 'window-like-normal';    Kind = 'ps';   File = 'test-window-like-normal.ps1';    Desc = '★★ 像不像正常窗口：光标分区/任务栏/可拉伸/置顶限时（真问系统）' }
  # ★ 2026-10-23 加：用户最怕的那个场景——"关掉了却一直拉不起来，我没办法终止"。
  #   这一套用假 exe 走完真实流程，验证「第 N 次之后停下、不再重试、记 failed」。
  @{ Name = 'relaunch-stop';         Kind = 'ps';   File = 'test-relaunch-stop.ps1';         Desc = '★ 拉起阶段叫停：不是试满次数，而是在下一轮之前停住' }
  @{ Name = 'members';               Kind = 'ps';   File = 'test-members.ps1';               Desc = '名单解析：老计划兼容 / 多人 / 边界（排队重启的地基）' }
  @{ Name = 'queue';                 Kind = 'node'; File = 'test-queue.mjs';                 Desc = '会话来源判据(rpcId) + 标题标记（两项都可能静默出错）' }
  # ★ 2026-10-23 加：守「回包字段必须都在声明里」。
  #   17:54 那次事故：入队分支多返回 queueLength，宿主整份拒收 →
  #   副作用已发生、调用方却看到"失败" → 它去误取消，把两个人的重启一起打掉。
  #   旧 selftest 只验"声明的 schema 合不合法"，**永远抓不到实际回包多了字段**。
  @{ Name = 'output-schema';         Kind = 'node'; File = 'test-output-schema.mjs';         Desc = '★ 回包字段必须都在声明里（+ 输出护栏接线；17:54 事故的守门测试）' }
  @{ Name = 'selftest';              Kind = 'node'; File = 'selftest.mjs';                   Desc = '插件侧单元自测' }
  @{ Name = 'verify-inject';         Kind = 'node'; File = 'verify-inject.mjs';              Desc = 'inject 静态声明检查' }
  @{ Name = 'verify-yaml';           Kind = 'node'; File = 'verify-yaml-intact.mjs';         Desc = '装配补丁 YAML 结构没被改坏' }
  @{ Name = 'verify-roots';          Kind = 'node'; File = 'verify-roots.mjs';              Desc = '插件新代码在跑吗（读真实 state.json）' }
  @{ Name = 'static-sanity';         Kind = 'ps';   File = 'test-static-sanity.ps1';         Desc = '语法/引号配平/窗口接线（秒级静态体检）' }
  @{ Name = 'session-kind';          Kind = 'ps';   File = 'test-session-kind.ps1';          Desc = '子代理判据（对全部真实档案交叉核对）' }
  @{ Name = 'silent-windows';        Kind = 'ps';   File = 'test-silent-windows.ps1';        Desc = '整串助手无可见窗口 + 功能照常' }
  @{ Name = 'jobs-soft-wait';        Kind = 'ps';   File = 'test-jobs-soft-wait.ps1';        Desc = '后台任务该等、新对话进来就放弃' }
  @{ Name = 'wait-when-busy';        Kind = 'ps';   File = 'test-wait-when-busy.ps1';        Desc = '有别的会话在忙 → 放弃；状态过期不判忙' }
  @{ Name = 'real-state';            Kind = 'ps';   File = 'test-real-state.ps1';            Desc = '读真实 state.json，行为与事实一致' }
  @{ Name = 'session-scan';          Kind = 'ps';   File = 'test-session-scan.ps1';          Desc = '扫盘独立判断（不依赖插件）' }
  @{ Name = 'stale-vs-active';       Kind = 'ps';   File = 'test-stale-vs-active.ps1';       Desc = '写过一次就停了 ≠ 在忙' }
  @{ Name = 'single-write';          Kind = 'ps';   File = 'test-single-write-vs-ongoing.ps1'; Desc = '「只写过一次」≠ 在忙（两轮比对；2026-10-10 修根因②）' }
  @{ Name = 'housekeeping-subagent'; Kind = 'ps';   File = 'test-housekeeping-subagent.ps1'; Desc = '家务子代理该等（两条路都过滤）' }
  @{ Name = 'helper';                Kind = 'ps';   File = 'test-helper.ps1';                Desc = '假应用上跑完整 关→拉 流程' }
  @{ Name = 'two-phase';             Kind = 'ps';   File = 'test-two-phase.ps1';             Desc = '两段式等待 A/B/C 三场景' }
  @{ Name = 'restart-window';        Kind = 'ps';   File = 'test-restart-window.ps1';        Desc = '状态窗：响应性/拖动/打断/不抢焦点' }
  @{ Name = 'window-contrast';       Kind = 'ps';   File = 'test-window-contrast.ps1';       Desc = '状态窗文字对比度（亮/暗 × 可点/禁用，采样真实像素）' }
  @{ Name = 'window-offscreen';      Kind = 'ps';   File = 'test-window-offscreen.ps1';      Desc = '状态窗越界：内容撑高后底边不许出屏（2026-10-13 用户报的问题）' }
  @{ Name = 'window-extreme';        Kind = 'ps';   File = 'test-window-extreme.ps1';        Desc = '状态窗越界（极端）：用实机最长 reason 撑，底边仍不许出屏' }
  @{ Name = 'window-taller';         Kind = 'ps';   File = 'test-window-taller-than-screen.ps1'; Desc = '状态窗：内容比屏幕还高时的降级路径（保住顶部）' }
  @{ Name = 'window-firstpaint';     Kind = 'ps';   File = 'test-window-firstpaint.ps1';     Desc = '状态窗"不蹦"：首屏内容必须在显示前填好（2026-10-13 用户报的闪烁）' }
  @{ Name = 'main-process-pick';     Kind = 'ps';   File = 'test-main-process-pick.ps1';     Desc = '挑主进程不许挑错（挑错则优雅关闭必失败、界面闪报错）' }
  @{ Name = 'confirm-window';        Kind = 'ps';   File = 'test-confirm-window.ps1';        Desc = '动手前的确认窗：走完才动手；中途「打断」立刻停手' }
  @{ Name = 'watchdog-rescue';       Kind = 'ps';   File = 'test-watchdog-rescue.ps1';       Desc = '保险丝真会救场吗（2026-10-11 新增；此前 24 次真实运行救场 0 次）' }
  @{ Name = 'failure-report';        Kind = 'ps';   File = 'test-failure-report.ps1';        Desc = '重启失败报告（内容/大白话/不写密钥/不互相覆盖）' }
  @{ Name = 'resume-after-restart';  Kind = 'ps';   File = 'test-resume-after-restart.ps1';  Desc = '重启完自己叫醒自己（判据+逻辑表；2026-10-13 改直接投递）' }
  @{ Name = 'wake-message';          Kind = 'node'; File = 'test-wake-message.mjs';          Desc = '投进会话那条消息的形状（真函数验，防重演当年污染账本）' }
  @{ Name = 'notice-hook';         Kind = 'node'; File = 'test-notice-hook.mjs';         Desc = '★ 外部通知钩子：没配不跑 / 配了真跑 / 失败超时不抛 / 并发只跑一条' }
  @{ Name = 'history-summary';       Kind = 'node'; File = 'test-history-summary.mjs';        Desc = '重启流水账汇总：中位数/过滤/坏行容错（2026-10-13 新增，真源码+假数据）' }
  @{ Name = 'result-port';           Kind = 'node'; File = 'test-result-port.mjs';            Desc = '★ 重启记录里的 port 必须是真端口（维护记录 对、字段错的守门测试）' }
  @{ Name = 'result-port-live';      Kind = 'ps';   File = 'test-result-port-live.ps1';      Desc = '★ 维护记录 真跑验证：假应用换端口（计划58881→实际58882），port 必须记真的' }
)

if ($Only) {
  # ⚠️ `powershell -File 脚本.ps1 -Only a,b` 里的 a,b 会被当成**一个字符串**（不是数组）——
  #    这是 -File 传参的固有行为（实测踩到：过滤后 0 个，报"没有一个匹配"）。
  #    所以这里自己按逗号拆开，顺手去掉空白，两种传法都能用。
  $wanted = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $allNames = @($suites | ForEach-Object { $_.Name })
  $suites = @($suites | Where-Object { $wanted -contains $_.Name })
  if ($suites.Count -eq 0) {
    Write-Host "❌ -Only 里没有一个匹配的测试名。可用的名字：" -ForegroundColor Red
    Write-Host ("   " + ($allNames -join ', ')) -ForegroundColor Yellow
    exit 2
  }
}

# ★ 2026-10-23 修：原来这里写死 19387，而 DSH 0.2.1-rc.2 起桌面端用 `--port 0`
#   随机分配（今天实测是 2254）。于是这一行在**今天的机器上恒为 $null**，
#   后面的"真 DSH 毫发无伤（监听者 PID 没变）"就成了 $null -eq $null ——
#   **永远绿，什么也没验到**。这正是本文件反复记的那条：看到绿灯先问它怎么来的。
#   现在改成"从 config.port 与 state.json 里拿候选，再挑真的在听的那个"。
function Get-RealDshListenerPid {
  $cands = New-Object System.Collections.Generic.List[int]
  try {
    $st = Join-Path $env:USERPROFILE '.dsh\self-restart\state.json'
    if (Test-Path -LiteralPath $st) {
      $p = (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).port
      if ($p) { $cands.Add([int]$p) }
    }
  } catch { }
  # 兜底：把所有 DSH 进程持有的监听端口都看一遍
  try {
    $dshPids = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
      if ($dshPids -contains $c.OwningProcess) { $cands.Add([int]$c.LocalPort) }
    }
  } catch { }
  foreach ($p in $cands) {
    $owner = (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
    if ($owner) { return $owner }
  }
  return $null
}

$realBefore = Get-RealDshListenerPid

# ★ 2026-10-11 加：把"失败报告"的落点改到临时目录，别写到用户真实桌面。
#   为什么：所有测试都用**假目标**（假主程序、甚至故意指向不存在的路径），
#   于是重启必然"失败" → 插件就会往桌面写一份"DSH重启失败"的报告。
#   实测跑几轮后用户桌面多出 4 份假报告，打开电脑会以为真出事了。
#   产品代码认这个环境变量（见 dsh-self-restart.ps1 的 Save-Result）；
#   子进程会继承它，所以在这里设一次就覆盖全部测试套件。
$env:DSH_SR_REPORT_DIR = Join-Path $env:TEMP 'dsh-self-restart-test-reports'
New-Item -ItemType Directory -Force -Path $env:DSH_SR_REPORT_DIR | Out-Null

Write-Host "=================================================="
Write-Host " 自我重启 · 全量测试（$($suites.Count) 套）"
Write-Host " 真 DSH 监听者 PID（跑前）: $realBefore"
Write-Host " 预计耗时 6~8 分钟，请勿关闭窗口"
Write-Host " 失败报告落点（测试用，不是桌面）: $env:DSH_SR_REPORT_DIR"
Write-Host "==================================================`n"

$rows = @()
$startedAll = Get-Date
foreach ($s in $suites) {
  $path = Join-Path $base $s.File
  Write-Host ("▶ {0,-22} {1}" -f $s.Name, $s.Desc) -ForegroundColor Cyan
  $t0 = Get-Date
  $out = ''
  # ★ 2026-10-13 加：单套外面套一层 try —— 任何一条原生命令往 stderr 写字、
  #   或哪个套件自己抛错，都只影响这一套的记账，**绝不让它中断后面还没跑的套件**。
  try {
    if ($s.Kind -eq 'node') {
      $out = (node $path 2>&1 | Out-String)
    } else {
      $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String)
    }
  } catch {
    $out = "（跑批器抓到异常：$($_.Exception.Message)）`n$out"
  }
  $took = [int]((Get-Date) - $t0).TotalSeconds

  # 抓"汇总"那一行；抓不到就认为异常
  #
  # ★ 2026-10-23 修：汇总行有**三种**写法，原来只认一种，于是两套新测试永远报红
  #   （而且红得莫名其妙：断言明明全过）。
  #   · `===== 自测汇总：22/22 通过 =====`      ← selftest / verify-roots 等 Node 套件
  #   · `结果：通过 12 条，失败 0 条`            ← members / target-guard 等 [通过]/[失败] 套件
  #   · `inject 验证…`                          ← verify-inject
  #   实测：test-members / test-target-guard / test-queue 三套**单独跑全绿**，
  #   跑批器却一律报"没找到汇总行 —— 可能异常退出"，看起来像套件崩了。
  #   ⚠️ 这与本文件第 20~26 行记的，是同一类错误（"看到的绿灯/红灯是怎么来的"）。
  $sumLine = ($out -split "`r?`n" | Where-Object { $_ -match '汇总|inject 验证|^结果：通过' } | Select-Object -Last 1)
  if (-not $sumLine) { $sumLine = '（没找到汇总行 —— 可能异常退出）' }

  # ★ 2026-10-13 修：失败行有**两种**写法，原来只认一种，于是漏判。
  #   · PowerShell 套件失败项以 `  · ` 开头（`$failedItems` 那套）；
  #   · **Node 套件**（verify-roots / selftest / wake-message…）失败项以 `❌` 开头。
  #   实测漏判：verify-roots 明明打了 `❌ ★ 实现版本探针 impl === 4 … impl=3`，
  #   汇总也是 `6/7 通过`，可跑批器判它**通过**（因为没找到 `·` 开头的行）——
  #   于是一个"新代码没生效"的真红灯，被跑批器显示成了绿灯。
  #   ⇒ 三种都认：`·` 行、`❌` 行，以及**汇总行本身写着"x/y 通过"但 x≠y**。
  #
  # ★ 2026-10-23 再补第四种：`结果：通过 12 条，失败 0 条`（members / target-guard 的格式）。
  #   ⚠️ 这条**必须与上面 $sumLine 的新匹配同时加**：只加匹配、不加判据，
  #   就会把"7 条失败"的 members 判成绿 —— 比原来误判成红**危险得多**
  #   （红至少会有人去看；假绿会让"名单解析坏了"一路带进真重启）。
  $failedItems = @($out -split "`r?`n" | Where-Object { $_ -match '^\s+·' -or $_ -match '^\s*❌' })
  $sumMismatch = $false
  $m = [regex]::Match($sumLine, '(\d+)\s*/\s*(\d+)\s*(?:通过|项)')
  if ($m.Success) { $sumMismatch = ($m.Groups[1].Value -ne $m.Groups[2].Value) }
  # `结果：通过 X 条，失败 Y 条` → Y 不为 0 就是失败
  $m2 = [regex]::Match($sumLine, '通过\s*(\d+)\s*条，失败\s*(\d+)\s*条')
  if ($m2.Success -and [int]$m2.Groups[2].Value -ne 0) { $sumMismatch = $true }

  # ⚠️ 2026-10-13 补：跑批器抓到异常也算失败（否则"异常+没汇总行"可能被漏判）
  $isFail = ($failedItems.Count -gt 0) -or ($sumLine -match '没找到汇总行') `
            -or ($out -match '跑批器抓到异常') -or $sumMismatch
  $rows += [pscustomobject]@{
    测试 = $s.Name; 结果 = $sumLine.Trim(); 耗时秒 = $took; 通过 = (-not $isFail)
  }
  $color = if ($isFail) { 'Red' } else { 'Green' }
  Write-Host ("   {0}  {1}  ({2}s)" -f $(if ($isFail) { '❌' } else { '✅' }), $sumLine.Trim(), $took) -ForegroundColor $color
  if ($failedItems.Count) { $failedItems | ForEach-Object { Write-Host ("      " + $_.Trim()) -ForegroundColor Red } }
  Write-Host ''
}

$realAfter = Get-RealDshListenerPid
$totalTook = [int]((Get-Date) - $startedAll).TotalSeconds
$bad = @($rows | Where-Object { -not $_.通过 })

Write-Host "=================================================="
Write-Host (" 合计 {0} 套，失败 {1} 套，用时 {2} 秒" -f $rows.Count, $bad.Count, $totalTook)
Write-Host "--------------------------------------------------"
$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host (" 真 DSH 监听者 PID（跑后）: {0}" -f $realAfter)
if ($realBefore -eq $realAfter) {
  Write-Host " ✅ 真 DSH 毫发无伤（监听者 PID 没变）" -ForegroundColor Green
} else {
  Write-Host " ⚠️ 监听者 PID 变了 —— 请检查是否有测试误伤了真 DSH！" -ForegroundColor Red
}
Write-Host "=================================================="

if ($bad.Count -or $realBefore -ne $realAfter) { exit 1 }
Write-Host "`n全部通过。" -ForegroundColor Green
exit 0
