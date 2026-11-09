# 实测：助手脚本 + 状态窗模块的**静态体检**
#
# 为什么必须有这一套（2026-10-10 血泪）：
#   给状态窗加"失败文案"时，两处把引号写歪了（单双引号混用 + `r`n 拼字符串），
#   结果**整个脚本语法崩掉** —— 而 bin\*.ps1 是"改完不用重启、直接生效"的，
#   也就是说这种错会**在真重启那一刻**才炸，而那时正主已经把自己脱离出去了，
#   用户只会看到"重启没动静"，极难排查。
#
#   所以：把"语法必须干净"和"结构必须完好"做成**秒级**的静态断言，进全量测试，
#   以后一改就查出来，不用等实弹。
#
# 用法：powershell -NoProfile -File test-static-sanity.ps1
$ErrorActionPreference = 'Stop'

$binDir  = (Resolve-Path (Join-Path $PSScriptRoot '..\bin')).Path
$helper  = Join-Path $binDir 'dsh-self-restart.ps1'
$winMod  = Join-Path $binDir 'dsh-restart-window.ps1'
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

# ── ① 两个脚本都要能通过语法解析 ───────────────────────────────────────────
foreach ($pair in @(@('助手脚本', $helper), @('状态窗模块', $winMod))) {
  $label = $pair[0]; $path = $pair[1]
  if (-not (Test-Path -LiteralPath $path)) { Check "$label 存在" $false $path; continue }
  Check "$label 存在" $true (Split-Path -Leaf $path)
  $tokens = $null; $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
  $bad = @($errs)
  Check "★ $label 语法干净（0 个解析错误）" ($bad.Count -eq 0) $(if ($bad.Count) { "L$($bad[0].Extent.StartLineNumber): $($bad[0].Message)" } else { "token 数 $($tokens.Count)" })
}

# ── ② 引号配平：逐行粗筛"奇数个引号"的行 ──────────────────────────────────
# ⚠️ 这条正是上面那个事故的直接形态：某行单/双引号数量为奇数 = 极可能少了/多了引号。
#    跳过三类行（它们的引号本来就不成对，会误报）：
#      · 注释行、<# #> 块
#      · here-string 起止行（@' / @' / '@ / "@）—— 实测误报过：@' 只有一个单引号
#      · here-string **内部**的行（C# 代码里有 { } 和 ' 字符）
function Get-UnbalancedLines([string]$path) {
  $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
  $out = New-Object System.Collections.Generic.List[string]
  $inBlock = $false     # <# #> 注释块
  $inHere = $false      # here-string
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]; $t = $l.Trim()

    # here-string 内部：整段跳过（直到独自成行的 '@ 或 "@）
    if ($inHere) {
      if ($t -eq "'@" -or $t -eq '"@') { $inHere = $false }
      continue
    }
    if ($t.StartsWith('<#')) { $inBlock = $true }
    if ($inBlock) { if ($t.EndsWith('#>')) { $inBlock = $false }; continue }
    if ($t.StartsWith('#')) { continue }
    # here-string 起始行：@' 或 @"（通常跟在 -TypeDefinition / -Command 之类的参数后面）
    if ($t -match "@'$" -or $t -match '@"$') { $inHere = $true; continue }
    # 纯 here-string 结束行
    if ($t -eq "'@" -or $t -eq '"@') { continue }

    $sq = ([regex]::Matches($l, "(?<!')'(?!')")).Count
    $dq = ([regex]::Matches($l, '(?<!")"(?!")')).Count
    if (($sq % 2) -ne 0 -or ($dq % 2) -ne 0) {
      $out.Add(('L{0}（单引号 {1} 双引号 {2}）: {3}' -f ($i + 1), $sq, $dq, $t))
    }
  }
  return $out
}

foreach ($pair in @(@('助手脚本', $helper), @('状态窗模块', $winMod))) {
  $bad = @(Get-UnbalancedLines $pair[1])
  Check "★ $($pair[0]) 引号配平（没有奇数引号的行）" ($bad.Count -eq 0) $(if ($bad.Count) { $bad[0] } else { '' })
  if ($bad.Count) { $bad | Select-Object -First 5 | ForEach-Object { Write-Host "     $_" } }
}

# ── ③ 状态窗的接线必须齐全（漏一个，用户就看到"窗口卡在某个阶段"）──────────
$helperText = [System.IO.File]::ReadAllText($helper, [System.Text.Encoding]::UTF8)
foreach ($fn in @(
  @('Initialize-RestartWindow',  '显示窗口'),
  @('Set-RestartWindowStageSafe', '切换阶段'),
  @('Update-RestartWindowSafe',   '刷新等待信息'),
  @('Close-RestartWindowSafe',    '收起窗口')
)) {
  Check "助手脚本有 $($fn[1]) 的接线（$($fn[0])）" ($helperText -match [regex]::Escape($fn[0]))
}

# 点源那一行必须存在，否则这些包装全是空转（Get-Command 查不到就不做事）
Check '★ 助手脚本真的点源了状态窗模块（否则窗口永远不会出现）' ($helperText -match 'dsh-restart-window\.ps1')

# ── ③-a2 【2026-10-11 新增】自测画窗口时必须能一眼看出"这是测试" ─────────────
# ⚠️ 为什么要有这条（用户亲历，不可接受）：
#   跑全量测试时，test-restart-window（右下角）和 test-window-contrast（左上角）挨着跑，
#   用户**同时在屏幕上看到两个**标题写着「DSH 正在自我重启」、内容写着「正在关闭 DSH」的窗口，
#   以为自己的 DSH 出事了 —— 其实 DSH 好好的，那是测试用假目标画的。
#   修法：自测时窗口标题带【测试】前缀（两条判据：计划里的 isTest / 环境变量 DSH_RW_TEST_MODE）。
#
# ⚠️ 注意位置：这几条要看 $winText（状态窗模块的正文），
#    而 $winText 在下面 ④ 段才定义 —— 所以这一组断言**必须放在它之后**。
#    （2026-10-11 第一版放在前面，$winText 还是空的，白红了 2 条。
#      教训：静态体检里"新增断言"要先确认它依赖的变量**此刻已经取到**。）

# ── ③-b 【2026-10-11 新增】点源必须在**脚本顶层**，不能在函数体内 ──────────────
# ⚠️ 这一条是本次事故的直接形态，必须存在：
#    PowerShell 的 `function { }` 产生**函数作用域**，点源进去的函数会**随函数返回而消失**。
#    原来 `. $winMod` 写在 Initialize-RestartWindow 函数体内 →
#      函数内可用（窗口能显示，造成"它在工作"的假象）
#      函数返回后 Set-RestartWindowStage / Disarm-RestartWindowAbort / Close-RestartWindow 全没了
#    → 窗口永远停在「等待中」、「打断」按钮从不禁用、点了也没用，而且**全程静默无日志**。
#    （2026-10-11 用户实拍：'重启已经开始了的阶段，就没法再点那个中断了，然后页面会变，但实际上没变'）
#
#    ⚠️ 为什么 20 套测试全绿也没发现：测试脚本是在**顶层 try 里**点源的
#       （`try { }` 是语句块，**不产生新作用域** → 模块函数一直活着），
#       而且测试**直接调模块函数**、不经过 *Safe 包装 ——
#       等于完全没覆盖"主脚本→模块"这根线。所以这里必须用**结构断言**补上。
#    用 AST 解析器判断（比正则可靠：正则分不清注释里的点源和真的点源）。
#    ⚠️ 实测：点源语句的 GetCommandName() 返回的是**空字符串**（不是 '.'），
#       所以判据用「CommandAst 的文本形如 `. $winMod`」而不是拿命令名比。
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$null)
$dotSources = @($ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
  $node.Extent.Text -match '^\s*\.\s+\$winMod'
}, $true))

Check '★ 助手脚本里能找到点源语句（. $winMod）' ($dotSources.Count -ge 1) "找到 $($dotSources.Count) 处"

# 逐处往上找祖先：只要有任何一处的祖先里出现 FunctionDefinitionAst，就是在函数体内 → 不合格
$insideFunction = @()
foreach ($ds in $dotSources) {
  $p = $ds.Parent
  while ($p) {
    if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
      $insideFunction += ('L{0} 在函数 {1}() 内' -f $ds.Extent.StartLineNumber, $p.Name)
      break
    }
    $p = $p.Parent
  }
}
Check '★★ 点源必须在脚本顶层（不能在任何 function 内 —— 否则窗口阶段/打断按钮会静默失效）' `
  ($insideFunction.Count -eq 0) `
  $(if ($insideFunction.Count) { $insideFunction -join '；' } else { '全部在顶层' })

# 顶层点源之后，*Safe 包装里的"取不到就跳过"必须留痕（否则同类故障再次无声无息）
Check '★ 窗口包装函数"取不到"时会留痕（Write-WinModMissingOnce）' ($helperText -match 'Write-WinModMissingOnce')

# ── ③-c 【2026-10-13 新增】首屏内容必须"先填好再显示"（否则窗口闪一下、蹦一截）────
# ⚠️ 为什么要有这条（用户亲历）：
#   "它刚刚好像有闪烁，突然弹出来长一截的内容，我没看清是什么就跳过去了。"
#   病根：原来是 `_win.Show()` 之后才 Set() 去填"原因：…"那段长文字 ——
#         窗口先以**矮**的样子出现，内容一到就**长高**，看着就是蹦一下。
#   修法：首屏内容当参数传给 Start()，**在 Show 之前**就赋值 —— 窗口第一次出现即最终尺寸。
#
# ⚠️ 变量顺序（这里栽过一次）：`$winText` 原来是在**④ 那一节**才赋值的，
#    而这段断言写在它前面 → 用了个 null 变量 → **恒假报红**。
#    所以本段自己读文件（不依赖后面才定义的变量）。
$winmodTextForPending = [System.IO.File]::ReadAllText($winMod, [System.Text.Encoding]::UTF8)

# 判据（两条一起才成立）：
#   ① 窗口模块调 Start 时**带了**首屏内容（不是先 Start 再 Set）
#   ② 窗口模块在建控件时就用了那几个 _pending* 值
# ⚠️ 文件也要找对：`$win.Start(...)` 这个调用在**窗口模块**里，不在助手主脚本里；
#    一开始拿 $helperText 去匹配，必然恒假 —— 断言要钉"事实在哪"，别钉"我以为它在哪"。
Check '★ 窗口调 Start 时带上了首屏内容（不再 Show 完再 Set）' `
  ($winmodTextForPending -match '\$win\.Start\(\s*\$winTitle\s*,\s*\$firstStageText')
# ⚠️ 正则别咬太死：写 `Text\s*=\s*_pendingDetail` 会把正确的
#    `Text = _pendingDetail ?? "",` 判成错的 —— **假红比漏测更烦人**（修的人会去改好代码）。
Check '★ 窗口模块用 _pending* 在**建控件时**填首屏（不是 Show 之后补）' `
  (($winmodTextForPending -match '(?m)^\s*Text\s*=[^\r\n]*_pendingDetail') -and
   ($winmodTextForPending -match '_pendingDetail\s*=\s*initialDetail'))
# 反向钉子：不许再出现"Show 之后紧接着 Set-RestartWindowStage 首屏"的老写法
Check '★ 老写法不许回归（Show 完立刻 Set 首屏那段已删）' `
  (-not ($helperText -match 'Set-RestartWindowStage\s+-Stage\s+.waiting.\s+-Detail\s+\$d'))

# ── ④ 阶段文案必须覆盖助手实际用到的每一个阶段 ─────────────────────────────
# ⚠️ 漏一个的后果：窗口上显示成"进行中"（兜底值），用户看不出到哪一步了。
$winText = [System.IO.File]::ReadAllText($winMod, [System.Text.Encoding]::UTF8)

# ── ④-a2 【2026-10-11 新增】自测画窗口时必须能一眼看出"这是测试" ──────────────
# ⚠️ 为什么要有这条（用户亲历，不可接受）：
#   跑全量测试时，test-restart-window（右下角）和 test-window-contrast（左上角）挨着跑，
#   用户**同时在屏幕上看到两个**标题写着「DSH 正在自我重启」、内容写着「正在关闭 DSH」的窗口，
#   以为自己的 DSH 出事了 —— 其实 DSH 好好的，那是测试用假目标画的。
#   修法：自测时窗口标题带【测试】前缀（判据：计划里的 isTest / 环境变量 DSH_RW_TEST_MODE）。
#   （本组断言必须放在 $winText 取到**之后** —— 第一版放前面白红了 2 条。）
Check '★ 状态窗标题支持"测试模式"标记（自测时能一眼分辨，不会吓到用户）' `
  ($winText -match 'DSH_RW_TEST_MODE' -and $winText -match '【测试】')
Check '★ 状态窗的系统窗口标题跟着参数走（不是写死的，否则改不了）' `
  ($winText -match 'Title\s*=\s*string\.IsNullOrEmpty\(title\)')
# 两套"会画窗口"的测试都必须打开测试模式，否则标题还是骗人的
foreach ($wf in @('test-restart-window.ps1', 'test-window-contrast.ps1')) {
  $p = Join-Path $PSScriptRoot $wf
  if (Test-Path $p) {
    $wt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    Check "★ $wf 打开了测试模式（否则用户会看到假的重启窗口）" ($wt -match "DSH_RW_TEST_MODE\s*=\s*'1'")
  }
}
$used = @('waiting','ready','closing','closed','starting','done','failed','cancelled')
$missing = @()
foreach ($st in $used) {
  # 在 Get-DshRwStageText 的 switch 里找 '阶段' { ... }
  if ($winText -notmatch ("'" + [regex]::Escape($st) + "'\s*\{")) { $missing += $st }
}
Check '★ 状态窗覆盖所有阶段文案' ($missing.Count -eq 0) $(if ($missing.Count) { '缺：' + ($missing -join ', ') } else { "$($used.Count) 个阶段都在" })

# ── ★★ ④-b 「像一个正常的窗口」（2026-10-23 下午，实机反馈的）──────────────────
#
# 【需求】「这东西不能更像一个正常的窗口吗？它现在还就是鼠标放到所有地方
#   都显示那个可移动的效果，就是它不能像一个正常的窗口一样吗？」
#
# 【这一组钉什么】四条改动，每条都是"读代码能看对、跑起来才看得出"的东西：
#   ① 整张卡片的 SizeAll 光标**必须**已经改成有条件（挂上 WindowChrome 就不设）；
#   ② WindowChrome 真的挂了（CaptionHeight / ResizeBorderThickness 有值）；
#   ③ 任务栏能看见它、边框能拉（ShowInTaskbar / ResizeMode）；
#   ④ 置顶是**限时**的（有放下来的定时器），不是永远压着。
#
# ⚠️ 这些断言只担保"代码里有这一段"；"真的生效"由
#    `test-window-nowindow-chrome.ps1`（量真实窗口的 WM_NCHITTEST）担保。
#    两层分开写，是因为静态断言改坏容易假绿，必须配一条量真实窗口的。
Check '★ 整张卡片的 SizeAll 光标改成有条件了（挂上 WindowChrome 就不设）' `
  ($winText -match 'if\s*\(!\s*_chromeOk\)\s*\{\s*_card\.Cursor\s*=\s*Cursors\.SizeAll')
Check '★ 老写法「无条件 _card.Cursor = SizeAll」不许回来' `
  (-not ($winText -match '(?m)^\s*_card\.Cursor\s*=\s*Cursors\.SizeAll\s*;\s*(//|$)'))
Check '★ 挂了 WindowChrome（保留自绘外观 + 接回系统窗口行为）' `
  ($winText -match 'new\s+System\.Windows\.Shell\.WindowChrome' -and $winText -match 'SetWindowChrome')
Check '★ WindowChrome 给了标题栏高度（没有它就拖不动）' `
  ($winText -match 'CaptionHeight\s*=\s*CaptionHeightPx')
Check '★ 任务栏里能找到它（ShowInTaskbar = true）' ($winText -match 'ShowInTaskbar\s*=\s*true')
Check '★ 边框可拉伸（ResizeMode = CanResize）' ($winText -match 'ResizeMode\s*=\s*ResizeMode\.CanResize')
Check '★ 置顶是**限时**的（前 N 秒置顶，之后放下来）' `
  ($winText -match '_topmostTimer' -and $winText -match '_win\.Topmost\s*=\s*false')
Check '★ 置顶放下来的秒数是约定的 10 秒' ($winText -match 'TopmostSeconds\s*=\s*10')
Check '★ Alt+F4 / 系统关闭也写取消标记（Closing 里写 _cancelFile）' `
  ($winText -match '_win\.Closing' -and $winText -match 'File\.WriteAllText\(')
Check '★ 阴影留了边距（以前被窗口矩形硬裁，看着是硬切边）' ($winText -match '_card\.Margin\s*=\s*new\s+Thickness\(ShadowPad\)')
Check '★ 拖动事件在挂上 WindowChrome 时让位给系统（不再自己抢鼠标）' `
  ($winText -match '(?s)MouseLeftButtonDown.*?if\s*\(_chromeOk\)\s*return')

# 助手用到的阶段，模块里都得有（反向核对：助手写了但模块没定义 = 显示"进行中"）
$helperStages = @([regex]::Matches($helperText, "-Stage\s+'(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$undefined = @($helperStages | Where-Object { $used -notcontains $_ })
Check '★ 助手用的阶段名都在模块里定义过' ($undefined.Count -eq 0) $(if ($undefined.Count) { '未定义：' + ($undefined -join ', ') } else { ($helperStages -join ', ') })

# ── ⑤ 关键护栏还在（这两条是拿真事故换来的，谁删了谁负责）──────────────────
Check '★ 动手前"拉得起来"那道闸还在（第 ④ 步）' ($helperText -match '动手前检查' -and $helperText -match 'preflightOk')
Check '★ 状态窗失败不许拦路（每一步都包了容错）' (($winText -match 'catch') -and ($helperText -match 'function Close-RestartWindowSafe'))

# ── ⑤-b ★ 2026-10-23：失败提示**不许**回到"全局广播"──────────────────────────
#
#
# 旧做法把提示挂在 systemPrompt 上（ctx.inject(['systemPrompt']) → sp.context），
# 那是**这个 profile 里每个会话**都会读到的东西 → 写文档的对话也来复述一遍。
#
# 现在改成 agent.inject()，只投给那次重启的 members[]/requestedBy。
# ⚠️ 这条断言守的是"别改回去"——挂回 systemPrompt 又是全机刷屏。
$libPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\index.js'
$libText = ''
if (Test-Path -LiteralPath $libPath) { $libText = [System.IO.File]::ReadAllText($libPath) }

# 只看真代码行（排除注释），否则我们解释"旧做法是什么"的注释会把断言骗红
$libCodeLines = @($libText -split "`r?`n" | Where-Object { $_ -notmatch '^\s*//' -and $_ -notmatch '^\s*\*' })
$libCode = ($libCodeLines -join "`n")

Check '★ 失败提示不再挂全局 systemPrompt（否则每个会话都会被刷）' `
  (-not ($libCode -match "ctx\.inject\(\['systemPrompt'\]" -or $libCode -match 'sp\.context\(')) `
  '源码里还有全局注入 —— 用户明确说过"所有对话都在提"受不了'

Check '★ 失败提示改走 agent.inject（只投相关会话）' `
  ($libCode -match 'agent\.inject\(' -and $libCode -match 'deliverFailureNotes')

Check '★ 失败提示的记账键与"汇报上次结果"分开（否则互相把对方标记成已完成）' `
  ($libCode -match 'failnote:') `
  '两条投递路径共用同一个 reported.json 键会导致一条都不发'

# ── ⑥ 【2026-10-11 新增】"抠函数"类测试的依赖必须齐备 ────────────────────────
# ⚠️ 这条是当天真踩到的：
#    test-session-kind.ps1 用正则把 `function Read-JsonFile { ... }` 抠出来单独跑。
#    那天给 Read-JsonFile 加了"读失败要重试"，它于是开始调用新函数 Read-JsonResult ——
#    而那个测试**只抠了 Read-JsonFile**，没抠依赖 → 调用不存在的函数 → 抛异常 →
#    Test-IsSubagentSession 里的 catch 把异常吞掉 → 一律返回"不是子代理" →
#    全量核对报"不一致 298 个"。**看起来像判据坏了，其实是被测函数的依赖变了。**
#
#    教训：抠函数的测试很脆，**被测函数的依赖一变就会静默误判**。
#    这里做一道静态防线：凡是"被别的测试抠出来跑"的函数，列在下面，
#    并且检查它引用的其它函数也都存在于同一个文件里（不能只存在于调用方的心智里）。
$extractedByTests = @{
  'Read-JsonFile'          = @('Read-JsonResult')      # test-session-kind.ps1 抠它
  'Read-JsonResult'        = @()                       # 底层，无依赖
  'Test-IsSubagentSession' = @('Read-JsonFile')        # test-session-kind.ps1 抠它
}
$depProblems = @()
foreach ($fn in $extractedByTests.Keys) {
  # ① 这个函数本身还在吗
  if ($helperText -notmatch ("(?m)^function\s+" + [regex]::Escape($fn) + "\b")) {
    $depProblems += "$fn 本身不见了（有测试在抠它）"
    continue
  }
  # ② 它声明的依赖也还在吗
  foreach ($dep in $extractedByTests[$fn]) {
    if ($helperText -notmatch ("(?m)^function\s+" + [regex]::Escape($dep) + "\b")) {
      $depProblems += "$fn 依赖的 $dep 不见了"
    }
  }
}
Check '★ "抠函数"测试的依赖齐备（缺了会让判据静默退化、看起来像判据坏了）' `
  ($depProblems.Count -eq 0) `
  $(if ($depProblems.Count) { $depProblems -join '；' } else { "$($extractedByTests.Count) 个被抠的函数及依赖都在" })

# 依赖清单自己不能过期：如果 Read-JsonFile 又调用了别的新函数，这里要能发现
# （做法：把 Read-JsonFile 函数体抠出来，看它调用了哪些本文件内定义的函数名）
$readFnBody = [regex]::Match($helperText, '(?s)function Read-JsonFile\s*\{.*?\n\}').Value
$allFns = @([regex]::Matches($helperText, '(?m)^function\s+([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
$calledInRead = @($allFns | Where-Object { $_ -ne 'Read-JsonFile' -and $readFnBody -match ("\b" + [regex]::Escape($_) + "\b") })
$undeclared = @($calledInRead | Where-Object { $extractedByTests['Read-JsonFile'] -notcontains $_ })
Check '★ Read-JsonFile 的依赖清单没过期（它调的其它本文件函数都已登记）' `
  ($undeclared.Count -eq 0) `
  $(if ($undeclared.Count) { '未登记：' + ($undeclared -join ', ') } else { '无新增依赖' })

# ── ⑤ 【2026-10-21 新增】"测试不许读真实会话档案"必须被钉住 ──────────────────
# ⚠️ 为什么要有这条（这次真栽了）：
#   助手判"盘上这个会话是子代理还是别人的真对话"时，会去读
#   `%DSH_HOME%\storages\session_projcache_archive_manager_v2\sessions\`（本机 1451 个档案）。
#   哪套测试忘了传 `subagentCacheRoot`，就会去翻真实档案 ——
#   冷读实测 **46 秒**（热读 3 秒），足以把"先等 20 秒"这类时序断言全冲垮。
#   而它失败时报的是**功能类的红**（"没识别出别人在忙"），跟真 bug 长得一模一样，
#   极难分辨 —— 这正是本仓反复写的"看到绿灯先问绿灯怎么来的"，反过来也成立：
#   **看到红灯，先问这个红是怎么来的。**
#   ⇒ 把"必须隔离"变成静态断言：漏了就在秒级的这套里报红，不用等 13 分钟全量。
$isolationProblems = @()
# ★ 名单**自动发现**，不手写：凡是"真启动助手 + 造了别的会话场景"的套件都要求隔离。
#   （手写名单会漏 —— 第一版就是手写的，结果漏了 4 套、还多算了一套只读源码的。）
#   判据三条同时成立：
#     ① 文件里 `Start-Process` 且真的把 $helper 当脚本跑（`'-File',$helper`，常被拆成多行）；
#     ② 造了 plan（有 sessionsRoot）；
#     ③ 造了"别的会话"场景（否则根本走不到"认子代理"那一步，隔离了也是白写）。
$suitesWithRealSessions = @()
foreach ($p in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File)) {
  $t = [System.IO.File]::ReadAllText($p.FullName, [System.Text.Encoding]::UTF8)
  $startsHelper = ($t -match 'Start-Process' -and $t -match '-File''?\s*,\s*\$helper')
  $writesPlan   = ($t -match 'sessionsRoot\s*=')
  $makesOthers  = ($t -match 'runningSessions|NEWCOMER|别的会话')
  if ($startsHelper -and $writesPlan -and $makesOthers) { $suitesWithRealSessions += $p.Name }
}
# 自检：这条断言自己不许"发现 0 套"就报绿 —— 那是最典型的假通过（本仓反复踩过）。
Check '★ 隔离断言自己先自检：确实找到了要检查的套件（0 套 = 假通过）' `
  ($suitesWithRealSessions.Count -ge 3) `
  "发现 $($suitesWithRealSessions.Count) 套：$($suitesWithRealSessions -join ', ')"
foreach ($f in $suitesWithRealSessions) {
  $p = Join-Path $PSScriptRoot $f
  $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  # 判据：计划里得真的把 subagentCacheRoot 赋给了一个值（不是注释里提一句）
  if ($t -notmatch '(?m)^\s*subagentCacheRoot\s*=\s*\$\w+') {
    $isolationProblems += "$f 没传 subagentCacheRoot（会去读真实会话档案）"
  }
}
Check '★ 启真助手的测试都隔离了身份档案目录（漏了会读真实档案、冷读 46 秒）' `
  ($isolationProblems.Count -eq 0) `
  $(if ($isolationProblems.Count) { $isolationProblems -join '；' } else { "自动发现的 $($suitesWithRealSessions.Count) 套都传了" })

# 反向钉子：助手那边必须**认**这个字段（否则测试传了也没用，静默读真实档案）
Check '★ 助手支持用计划里的 subagentCacheRoot 覆盖真实档案目录' `
  ($helperText -match '\$plan\.subagentCacheRoot')

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
if ($failed.Count) { exit 1 }
exit 0
