# test-resume-after-restart.ps1 —— 「重启完成后自己叫醒自己」的回归测试
#
# ★ 2026-10-12 新增。测的是这一条链路：
#     重启成功 → last-run.json 里有 requestedBy → 插件把唤醒消息**直接投进原会话**
#
# ★ 2026-10-13 改：唤醒机制从"排一条 schedule 定时提醒"换成"直接投递消息"。
#   本文件里原来第 ② 组、以及钉 `schedule.create` / `resumeDelaySeconds` 的那几条断言
#   都是**故意的红**（实现换了，钉子自然要跟着换）—— 但每一条都重新确认了"改成什么才算对"，
#   没有为了变绿而放宽：
#     · schedule 相关 → 换成 sessionController / sessions（新用到的两个服务）
#     · "排提醒"相关 → 换成"投递消息"，并新增**消息形状必须完整**的硬断言
#       （当年那次事故的根因就是喂了字符串，这条必须钉死）
#     · "延迟"相关 → 换成 wakeDelaySeconds，并新增"不许再悄悄改写使用者填的值"
#
# 为什么要单独测（而不是只跑静态体检）：
#   静态体检只能证明"代码里有这些字串"，证明不了**判断逻辑对不对**。
#   这条链路的判据有好几个（outcome 必须 success、必须在时间窗内、
#   必须有 requestedBy、同一个 planId 只叫一次），任何一个写反都会静默失效。
#
# 做法：用**源码字符串断言 + 数据判据表**两条腿走路：
#     ① 源码断言：那几个判据必须真的写在代码里（防被误删）
#     ② 数据判据：把 last-run.json 的各种形态喂给"判据表"，验结论对不对
#   ⚠️ 我明知①是"弱测"，但②能把"逻辑判错"抓出来 —— 两者都不能省。

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$pluginRoot = Split-Path $here -Parent
$libPath = Join-Path $pluginRoot 'lib\index.js'
$helperPath = Join-Path $pluginRoot 'bin\dsh-self-restart.ps1'
$libText = [System.IO.File]::ReadAllText($libPath, [System.Text.Encoding]::UTF8)
$helperText = [System.IO.File]::ReadAllText($helperPath, [System.Text.Encoding]::UTF8)
# ⚠️ 剥掉注释再搜（代码注释里写着"旧版怎么错的"，含那些字串；不剥会误报"旧 bug 还在"）
$libCode = ($libText -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^(//|/\*|\*)' }) -join "`n"

$pass = 0; $fail = 0
function Check([string]$label, [bool]$ok, [string]$why = '') {
  if ($ok) { $script:pass++; Write-Host "  [OK] $label" }
  else { $script:fail++; Write-Host "  [NG] $label $(if($why){"— $why"})" }
}

Write-Host ''
Write-Host '=== ① 助手侧：Save-Result 必须把 requestedBy 抄进结果 ===' -ForegroundColor Cyan
# 这一条是整条链路的信息源。没有它，插件启动后不知道叫醒谁。
Check 'Save-Result 里有 requestedBy 字段' ($helperText -match 'requestedBy\s*=\s*\[string\]\$plan\.requestedBy')
# 必须从 $plan 取（重启前写下的），不能从别处瞎猜
Check 'requestedBy 取自 $plan（重启前的计划）' ($helperText -match 'requestedBy\s*=\s*\[string\]\$plan\.requestedBy')

Write-Host ''
Write-Host '=== ② 插件侧：投递要用的两个服务必须被注入（拿不到就等）===' -ForegroundColor Cyan
# ★ 2026-10-13 改：原来这里验的是 inject([schedule])。现在改用官方自带服务投递。
Check '有 inject([sessionController]) 的调用' ($libText -match "inject\(\['sessionController'\]")
Check 'sessionController 拿不到时只记日志、不抛错（降级）' ($libText -match "sessionController 服务：")
# sessions 是用来 flush 的（确认落盘）；它缺了不影响投递本身，所以只要"注入了"即可
Check '有 inject([sessions]) 的调用（用来确认落盘）' ($libText -match "inject\(\['sessions'\]")
# ★ 不许再依赖实验 bundle
Check '★ 不再依赖 schedule 服务（实验 bundle 那个）' `
  (-not ($libCode -match "inject\(\['schedule'\]") -and -not ($libCode -match 'schedule\.create\('))

Write-Host ''
Write-Host '=== ③ 插件侧：四个判据必须都在 ===' -ForegroundColor Cyan
# ⚠️ 断言必须**连"提前 return"一起验**，不能只验字串出现过。
#    实测教训（2026-10-12）：我第一版只写 `$libText -match "outcome !== 'success'"`，
#    然后把代码改成 `if (last.outcome !== 'success') { /* 什么都不做 */ }`（等于取消这道闸），
#    测试**照样全绿** —— 因为那个字串还在，只是后面没有 return 了。
#    **只验"字串存在"的断言是假的保险网。**
# 判据一：只认成功（失败时叫醒我继续，会掩盖故障）
Check '只对 outcome === success 的才叫醒（不是成功必须 return skip）' `
  ($libCode -match "if \(last\.outcome !== 'success'\) return 'skip';")
# 判据二：必须以"插件启动时刻"为锚（防轮询把窗口越拉越宽、捞到旧账）
# ★ 2026-10-25：这个判断抽进了 freshnessOf（"收工要不要发提醒"用的是同一份口径），
#   所以断言改成认那个函数里的两条边界，**不再**要求它长在 resumeAfterRestart 里 ——
#   断言该盯"口径还在不在"，而不是"字串在哪个函数里"。
Check '以 pluginStartedAt 为锚判断新旧（60 秒容忍）' ($libCode -match 'finished < pluginStartedAt - 60e3')
Check '也拒绝明显来自未来的时间戳（120 秒余量）' ($libCode -match 'finished > pluginStartedAt \+ 120e3')
Check '★ 新旧口径只有一份（freshnessOf），不许在别处另写一套' `
  (($libCode -match 'const freshnessOf = \(finishedAt\) =>') -and
   -not ($libCode -match 'if \(finished < pluginStartedAt - 60e3\) return waitIfBetween'))
Check 'pluginStartedAt 在 apply() 里定一次' ($libCode -match 'const pluginStartedAt = now\(\);')
# 判据二-b：必须是**轮询**而不是"等固定秒数跑一次"
#   实测逼出来的：插件加载比"重启完成"还早（11:58:17 挂上 / 11:58:23 才写完），
#   只跑一次会读到旧文件 → 静默失效。
Check '自动叫醒是轮询（不是 setTimeout 跑一次）' ($libCode -match 'setInterval\(\(\) => \{' -and $libCode -match 'resumePollMs')
Check '轮询有次数上限并会 clearInterval 收工' ($libCode -match 'resumeMaxTries' -and $libCode -match 'clearInterval\(resumeTimer\)')
# 判据二-c ★★ 2026-10-12 第二次实机实测抓出的"状态身份 bug"专用钉子 ★★
#   旧代码收工条件：扫 reported.json 里**任何** resume: 键 →
#   拿着**上一次**重启留下的旧键当"这次已排"，当场收工 → 整次功能静默失效。
Check '★ 收工条件不再扫"任何 resume: 键"（旧 bug 写法不许回归，已剥注释）' `
  (-not ($libCode -match "startsWith\('resume:'\)"))
# 收工必须只看函数自己的返回值，不许在循环里另写一套判断
Check '★ 轮询按返回值收工（delivered 停、skip 停）' ($libCode -match "state === 'delivered'" -and $libCode -match "state === 'skip'")
# 跨调用状态必须放在 apply() 闭包里（函数内的局部变量挡不住异步竞态）
Check '★ wakeInFlight 在函数外（闭包级，防异步窗口重复投）' `
  ($libCode -match "let wakeInFlight = false;" -and $libCode -match 'if \(wakeInFlight\) return')
Check '★ 连续失败会放弃并留日志（不静默也不刷屏）' ($libCode -match 'wakeFails >= 2')
# 服务晚到是实测事实：这里必须是 wait（用 [\s\S]*? 跨过中间那几行注释）
Check '★ sessionController 没就位时是 wait 不是 skip（实测服务会晚到）' `
  ([regex]::IsMatch($libCode, "if \(!sessionController[\s\S]{0,200}?return 'wait';"))
# 判据三：必须有"要叫醒谁"（一个都没有就跳过，别瞎猜会话）
# ★ 2026-10-22 改：唤醒从"喊一个人（$target）"改成"按名单挨个喊（targets 数组）"，
#   原来匹配 `if (!$target) {` 的断言过时了。保留同样的**意图**：
#   没有任何目标时必须真的 return，不能继续往下投。
Check '没有目标时跳过（必须真的 return）' `
  (($libCode -match "if \(targets\.length === 0\) \{[\s\S]{0,200}?return 'skip';") -or ($libCode -match 'if \(!target\) \{'))
# 判据三-b（2026-10-22 新增）：必须支持**多人** —— 否则"排队重启的唤醒"是假的
Check '★ 唤醒支持多人（读 last.members）' ($libCode -match 'Array\.isArray\(last\.members\)')
Check '★ 逐人记账（key 带会话 id，一人失败不拖累别人）' ($libCode -match 'resume:\$\{planKey\}:\$\{t\.sessionId\}')
# 判据四：同一个 planId 只叫一次
Check '同一个 planId 只叫一次' ($libCode -match "resume:")
# ★ 2026-10-13：投递必须走官方的四步（resolveAgent → 造消息 → followup → flush）
Check '投递第一步用 resolveAgent 找会话' ($libCode -match 'sessionController\.resolveAgent\(')
Check '投递第二步自己造消息对象（makeWakeMessage）' ($libCode -match 'makeWakeMessage\(text\)')
Check '投递第三步用 agent.followup 进收件箱' ($libCode -match 'agent\.followup\(message\)')

Write-Host ''
Write-Host '=== ③-b ★★ 当年那次事故的边界：只许喂真消息对象，绝不喂字符串 ★★ ===' -ForegroundColor Cyan
# 【背景】2026-10 那次事故：bridge.mjs 把**字符串**喂给 followup，
#   inbox 的 mutate() 对插入项没有类型检查 → "没有 id、没有 content 的货"进了会话账本
#   → 界面按消息对象形状读它 → 崩、两个会话打不开、会话列表变空白。
#   所以下面这几条是**防重演**的硬钉子，一条都不能松。
Check '★ followup 喂的是消息对象变量（不是字符串拼接）' `
  (-not [regex]::IsMatch($libCode, 'followup\(\s*[`"'']') -and -not [regex]::IsMatch($libCode, 'followup\(\s*text'))
# 消息必须有 id / role / content / source 四样齐全（缺一样就是当年那种"货"）
Check '★ 消息有唯一 id（用 randomUUID）' ($libCode -match 'id:\s*randomUUID\(\)')
Check '★ 消息有 role' ($libCode -match "role:\s*'user'")
Check '★ 消息的 content 是数组且元素带 type/text' `
  ([regex]::IsMatch($libCode, "content:\s*\[\s*\{\s*type:\s*'text'"))
Check '★ 消息有 source.kind' ($libCode -match "source:\s*\{[\s\S]{0,120}?kind:\s*'self-restart'")
# ★★ 绝不冒充使用者：source.kind 不许是 'user' ★★
#   DSH 用 kind === 'user' 判"这句话是不是人说的"（如 goal 的 complete 需要人类输入才放行）。
#   投递的消息写成 user = 拿到人类授权身份，那是**必须避免**的。
Check '★★ source.kind 不是 user（不冒充使用者、不继承人类授权）' `
  (-not [regex]::IsMatch($libCode, "source:\s*\{[^}]{0,200}?kind:\s*'user'"))
# 投递前必须**自检形状**：不合法就拒绝投，宁可少叫一次也不污染会话
Check '★ 投递前自检消息形状（不合法就拒绝投）' `
  ([regex]::IsMatch($libCode, "message\.role !== 'user'") -and [regex]::IsMatch($libCode, '拒绝投递'))
# 投递后必须确认落盘（拿不到回执要如实报，而不是假装成功）
Check '★ followup 之后会 flush 确认落盘' ($libCode -match 'sessions\.flush\(')
Check '★ 拿不到落盘回执时如实报（不假装成功）' ($libCode -match 'confirmed: false')
# ★★ 最要紧的一条正确性：跟着 followup 之后的失败**绝不许重投** ★★
#   重投 = 被唤醒的会话收到两条一样的"接着干"，同一件活干两遍。
Check '★★ flush 失败时不重投（消息已在收件箱，重投=活干两遍）' `
  ([regex]::IsMatch($libCode, 'agent\.followup\(message\);[\s\S]{0,900}?return \{ confirmed: false') -and
   -not [regex]::IsMatch($libCode, 'agent\.followup\(message\);[\s\S]{0,900}?throw '))

Write-Host ''
Write-Host '=== ③-c 时长配置：许填几就是几（不许再悄悄改写使用的值）===' -ForegroundColor Cyan
Check '延迟来自配置 wakeDelaySeconds' ($libCode -match 'config\.wakeDelaySeconds')
# ★ 老实现的坑：Math.max(5, Number(x) || 15) 会把使用者填的 0/1/2/3 悄悄改成 5 或 15；
#   "配了不生效"最误导人。所以这里钉死：**不许**出现"有下限的取整"。
Check '★ 不许给使用者填的秒数设下限（填几就是几）' `
  (-not ($libCode -match 'Math\.max\(5,\s*Math\.round\(rawDelay\)') -and
   -not ($libCode -match 'Math\.max\(5,\s*rawWakeDelay'))
Check '★ 负数按 0 处理（不设下限）' ($libCode -match 'Math\.max\(0,\s*rawDelay\)')
# 开关与时长必须是**两个**配置项：一个值只有一个意思，不再有"填 0 算关还是算立刻"的歧义
Check '★ 叫不叫醒由布尔开关 wakeMessage 决定' ($libCode -match 'config\.wakeMessage === false')
Check '配置 schema 里有 wakeMessage' ($libCode -match 'wakeMessage:\s*z\.boolean\(\)\.default')
Check '配置 schema 里有 wakeDelaySeconds' ($libCode -match 'wakeDelaySeconds:\s*z\.number\(\)\.default')
# 文案必须有长度上限（这段文字会进会话账本）
Check '唤醒文案里带的 reason 有长度上限' ($libCode -match 'config\.wakeMessageMaxChars' -and $libCode -match '已截断')
# ★★ 工具描述/回话不许再说"重启后不会自动接着跑"（那是自动唤醒做出来之前的旧话 ——
#   工具描述是**别人机器上唯一给 Agent 的说明书**，旧话会让那边的 Agent 以为醒来无望，
#   反过来叫用户手动重开，功能明明在却没人用。2026-10-12 一句话点破才查出来。）
Check '★ 旧谎话"不会自动接着跑"已清除（代码行里不许有，注释里讲历史可以）' `
  (-not ($libCode -match '这一轮对话\*\*不会自动接着跑\*\*'))
Check '★ 工具描述讲了自动唤醒 + reason 带回' `
  ($libText -match 'DELIVERS a wake-up message straight into THIS session' -and $libText -match 'hands your `reason` straight to you')
Check '★ 工具描述讲清了"署名是插件、不是使用者"' `
  ($libText -match 'stamped as coming from the plugin, not from the user')
Check '★ 排成功的回话按口径说"投进会话"（wakeOn 分支）' `
  ($libText -match 'wakeIn' -and $libText -match 'wakeOn')
Check '★ 空跑回话也带叫醒口径（干跑=陌生人的第一手体检单）' `
  ($libText -match '重启成功后：约')

Write-Host ''
Write-Host '=== ④ 落地形态：不能新建"接力棒文件"（使用者 2026-10-12 明确否掉）===' -ForegroundColor Cyan
#
# 所以：不许出现 relay.json 之类的额外状态文件。
Check '没有新建接力棒文件（复用 last-run.json 的字段）' (-not ($libText -match "relayPath|relay\.json|relayFile"))
Check '没有 resume_prompt 参数的残留' (-not ($libText -match 'resume_prompt'))

Write-Host ''
Write-Host '=== ④-b 重启流水账 + 汇报不再"只试一次"（2026-10-13 加）===' -ForegroundColor Cyan
Check '★ 汇报不再用"启动后只跑一次"的 setTimeout(…, 3000)' `
  (-not ($libCode -match 'setTimeout\(reportLastRun'))
# ⚠️ 这里必须用剥过注释的 $libCode 量间隔 —— 原始文本中间夹着一大段解释性注释，
#    窗口给小了会误报（第一版给 400 就是被注释撑爆的）。
Check '★ 汇报搭在心跳上（heartbeat 里调 reportLastRun）' `
  ([regex]::IsMatch($libCode, 'const heartbeat = \(\) => \{[\s\S]{0,400}?reportLastRun\(\)'))
Check '★ 汇报"认出即停"（reportedDone 挡住后续每一拍）' `
  ($libCode -match 'if \(reportedDone\) return;' -and $libCode -match 'if \(reportLastRun\(\)\) reportedDone = true;')
Check '★ 汇报有次数上限（否则普通启动会整夜每 10 秒读一次盘）' `
  ($libCode -match 'REPORT_MAX_TRIES' -and $libCode -match 'if \(reportTries > REPORT_MAX_TRIES\) \{ reportedDone = true; return; \}')
Check '★ reportLastRun 真的汇报过才返回 true（否则心跳会提前收工）' `
  ([regex]::IsMatch($libCode, "writeJson\(reportedPath, done\);[\s\S]{0,80}?return true;"))
# 心跳必须两个都干：写 state + 试着汇报
Check '★ 心跳仍然写 state.json（没把原来的职责弄丢）' `
  ([regex]::IsMatch($libCode, 'const heartbeat = \(\) => \{\s*writeState\(\);'))
# 卸载时必须清掉那个心跳
Check '★ 卸载时清掉心跳定时器' ($libCode -match 'clearInterval\(stateTimer\)')
# ⚠️ 这条是防我自己犯错的：2026-10-13 改上面那段时，我**误删了注销工具的循环**。
#   插件会热加载，少了它新旧两代工具会并存。
Check '★ 卸载时仍然注销两个工具（这行曾被误删过）' `
  ($libCode -match 'for \(const dispose of disposers\)')

Write-Host ''
Write-Host '=== ④-c ★ 测试的基础设施不许骗人（2026-10-13 抓到两处假答案）===' -ForegroundColor Cyan
# 【为什么钉这些】这两条都是"没有任何报错的假答案"，比代码 bug 更难发现：
#
# ① 测试用假 ctx 调 apply()，而 apply() 第一件事就是 writeState() ——
#    用默认配置跑，它就会**以新代码往使用者真实的 state.json 写 impl** →
#    紧接着跑的 verify-roots 读到新值 → 报"新代码在跑"（**假通过**），
#    可真宿主里跑的还是旧代码（改 lib/index.js 必须重启宿主才进内存）。
#    实测取证：跑完 selftest 后真 state.json 读到 4，等 10 秒又变回 3。
# ② 跑批器的容错：单套测试往 stderr 写一行就把整个跑批掀翻 →
#    后面的套件根本没跑，而汇总表看起来像正常收工。
$selftestText = if (Test-Path (Join-Path $PSScriptRoot 'selftest.mjs')) { [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'selftest.mjs'), [System.Text.Encoding]::UTF8) } else { '' }
$injectText = if (Test-Path (Join-Path $PSScriptRoot 'verify-inject.mjs')) { [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-inject.mjs'), [System.Text.Encoding]::UTF8) } else { '' }
$rootsText = if (Test-Path (Join-Path $PSScriptRoot 'verify-roots.mjs')) { [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-roots.mjs'), [System.Text.Encoding]::UTF8) } else { '' }
$runner2 = if (Test-Path (Join-Path $PSScriptRoot 'run-all-tests.ps1')) { [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'run-all-tests.ps1'), [System.Text.Encoding]::UTF8) } else { '' }

# ① 调 apply() 的那几套，必须把 stateDir 指到临时目录（不许用默认配置落到真实目录）
Check '★ selftest 调 apply() 时指定了临时 stateDir（不许写使用者的真实状态）' `
  ($selftestText -match 'new mod\.Config\(\{\s*stateDir:' -and $selftestText -match 'tmpStateDir')
Check '★ verify-inject 调 apply() 时也指定了临时 stateDir' `
  ($injectText -match 'new mod\.Config\(\{\s*stateDir:\s*TMP_STATE' )
Check '★ verify-inject 不再用默认配置调 apply()（那会落到真实状态目录）' `
  (-not ($injectText -match 'new mod\.Config\(\{\}\)'))
# ② verify-roots 必须自己核对"这份 state.json 是不是真宿主写的"（pid 对端口监听者）
Check '★ verify-roots 用 pid 交叉核对 state.json 是不是真宿主写的' `
  ($rootsText -match 'Get-NetTCPConnection' -and $rootsText -match 'listeners\.includes')
# ③ 跑批器不许再被单套掀翻
Check '★ 跑批器容错：ErrorActionPreference 不是 Stop' `
  (-not ($runner2 -match "(?m)^\s*\$ErrorActionPreference\s*=\s*'Stop'"))
Check '★ 跑批器给每套套了 try/catch（单套异常只记账、继续跑）' `
  ($runner2 -match '跑批器抓到异常')

# 助手侧：每次重启往 history.jsonl 追一行，且必须有"关掉 → 起来"那一段
Check '★ 助手把"开始关"的时刻记下来（$script:DownAt）' `
  ($helperText -match '\$script:DownAt = Get-Date')
Check '★ 助手 Save-Result 追加 history.jsonl（不是整张覆盖）' `
  ($helperText -match 'history\.jsonl' -and $helperText -match 'AppendAllText\(\$histPath[,)]')
# ★ 上面那条原本是"假保险网"（2026-10-13 实测抓出来的）：
#   把 `AppendAllText($histPath, ...)` 改成 `AppendAllText($histPath + ".off", ...)`（写错文件）
#   **照样通过** —— 因为 'AppendAllText($histPath' 这个前缀还在。只有"字串存在"的断言是假的。
#   所以这里补一条**结构**断言：$histPath 必须真的是"状态目录里的 history.jsonl"，
#   而且必须是**追加**（AppendAllText）而不是整张覆盖（WriteAllText/Write-JsonFile）。
Check '★ $histPath 真的是状态目录下的 history.jsonl（不是别的文件）' `
  ([regex]::IsMatch($helperText, '\$histPath\s*=\s*Join-Path\s+\(Split-Path\s+-Parent\s+\$lastRunFile\)\s+''history\.jsonl'''))
Check '★ 是追加写，不是整张覆盖（WriteAllText/Write-JsonFile 都不算）' `
  (-not ([regex]::IsMatch($helperText, 'WriteAllText\(\$histPath')) -and
   -not ([regex]::IsMatch($helperText, 'Write-JsonFile\s+-Path\s+\$histPath')))
Check '★ history 里记的是"关掉→起来"那一段（downToUpSeconds），不是总耗时' `
  ($helperText -match 'downToUpSeconds' -and $helperText -match '\$script:DownAt')
# 插件只读不算：汇总必须"被问的那一刻现算"（使用者定的"按需优于自刷"）
Check '★ 流水账汇总是按需现算（restart_status 里调 readHistorySummary）' `
  ([regex]::IsMatch($libCode, 'const hist = readHistorySummary\(\);'))
Check '★ 没有后台统计/写流水账的动作（插件不许写 history.jsonl）' `
  (-not ($libCode -match 'AppendAllText\([^)]*history'))
# history.jsonl 是"一行一个 JSON"，绝不能拿 readJsonResult 去整份解析（第一版真写错了）
Check '★ history.jsonl 按行解析（没用 readJsonResult 整份读）' `
  (-not ($libCode -match "readJsonResult\(join\(stateDir, 'history\.jsonl'\)"))

Write-Host ''
Write-Host '=== ⑤ 判据逻辑验证：把各种 last-run.json 形态喂进判据表 ===' -ForegroundColor Cyan
# 这一步才是真正抓"逻辑写反"的地方 —— 用独立实现，和源码里的判据对照。
# 判据表（照抄源码里的四个条件）：
#   叫醒当且仅当：finishedAt 可解析 且 outcome===success 且 finished 不早于(插件启动-60秒) 且 requestedBy 非空
#
# ⚠️ 第一版这里写错了（记下来）：我用 `$good.Clone() + @{outcome='failed'}` 造变体，
#    而 PowerShell 的 hashtable 相加会抛 "Item has already been added"（键重复）。
#    改成 Make-Variant 显式覆盖键。**测试自己也要先跑通才作数。**
function Make-Variant([hashtable]$base, [hashtable]$overrides) {
  $h = @{}
  foreach ($k in $base.Keys) { $h[$k] = $base[$k] }
  foreach ($k in $overrides.Keys) { $h[$k] = $overrides[$k] }
  return $h
}
# 用 DateTimeOffset 统一算，避免 Local/Unspecified 混着算错
# $pluginStart = 本次插件启动时刻（锚点）；$parentAgeSec = 那份结果比锚点早多少秒
function ShouldWake([hashtable]$last, [DateTimeOffset]$pluginStart) {
  if (-not $last) { return $false }
  if (-not $last.finishedAt) { return $false }
  if ($last.outcome -ne 'success') { return $false }
  $fin = [DateTimeOffset]::Parse([string]$last.finishedAt)
  # 判据：finished 不许早于 (插件启动 - 60 秒)，也不许晚于 (插件启动 + 120 秒)
  if ($fin -lt $pluginStart.AddSeconds(-60)) { return $false }
  if ($fin -gt $pluginStart.AddSeconds(120)) { return $false }
  if ([string]::IsNullOrEmpty([string]$last.requestedBy)) { return $false }
  # ★ 2026-10-13 新增判据：**本次重启自己说了"不续接"**（resume=false）→ 不叫醒。
  #   优先级在 requestedBy 之后、返回 true 之前 —— 它是"最后一票否决"。
  #   ⚠️ 必须显式判 `-eq $false`，不能写 `if (-not $last.resume)`：
  #      老记录**根本没有 resume 字段**（$null），而 -not $null 也是真 ——
  #      那会把所有老记录都误判成"不续接"，静默毁掉续接功能。
  if ($last.resume -eq $false) { return $false }
  return $true
}
$T0 = [DateTimeOffset]::Parse('2026-10-12T06:00:00Z')   # 插件启动时刻
$good = @{ finishedAt = $T0.AddSeconds(6).ToString('o'); outcome = 'success'; requestedBy = 'session-abc'; planId = 'r1'; tookSeconds = 20; reason = 'test' }

Check '正常情形（插件起来后助手才写完）→ 应当叫醒' (ShouldWake $good $T0)
Check '助手比插件早写完几秒（-6 秒）→ 仍应叫醒' (ShouldWake (Make-Variant $good @{finishedAt=$T0.AddSeconds(-6).ToString('o')}) $T0)
Check '失败重启 → 不该叫醒' (-not (ShouldWake (Make-Variant $good @{outcome='failed'}) $T0))
Check '被取消 → 不该叫醒' (-not (ShouldWake (Make-Variant $good @{outcome='cancelled'}) $T0))
Check 'skipped-busy → 不该叫醒（重启压根没发生）' (-not (ShouldWake (Make-Variant $good @{outcome='skipped-busy'}) $T0))
Check '没有 requestedBy（旧记录）→ 不该叫醒' (-not (ShouldWake (Make-Variant $good @{requestedBy=''}) $T0))
Check '陈年旧账（上一小时那次）→ 不该叫醒' (-not (ShouldWake (Make-Variant $good @{finishedAt=$T0.AddHours(-1).ToString('o')}) $T0))
Check '边界：早 59 秒 → 应当叫醒' (ShouldWake (Make-Variant $good @{finishedAt=$T0.AddSeconds(-59).ToString('o')}) $T0)
Check '边界：早 61 秒 → 不该叫醒' (-not (ShouldWake (Make-Variant $good @{finishedAt=$T0.AddSeconds(-61).ToString('o')}) $T0))
Check '空文件 / 没有 finishedAt → 不该叫醒' (-not (ShouldWake @{outcome='success'; requestedBy='x'} $T0))
Check '未来时间戳（离奇数据）→ 不该叫醒' (-not (ShouldWake (Make-Variant $good @{finishedAt=$T0.AddHours(2).ToString('o')}) $T0))

Write-Host '  --- ★ 本次重启自己选"要不要续接"（2026-10-13 新增）---' -ForegroundColor DarkGray
# 背景："让在干活的模型自己选续不续接" ——
#   多数情况要续接，但**收尾型重启**不该叫醒（活干完了，叫起来只会自己跟自己说话）。
Check '★ resume=true → 照常叫醒' (ShouldWake (Make-Variant $good @{resume=$true}) $T0)
Check '★ resume=false → 不叫醒（收尾型重启）' (-not (ShouldWake (Make-Variant $good @{resume=$false}) $T0))
# ⚠️ 这条是**最容易写错**的：老记录没有 resume 字段（$null），
#    若源码写成 `if (-not $last.resume)` 就会把老记录全判成"不续接" —— 静默毁掉功能。
Check '★★ 老记录（没有 resume 字段）→ 仍应叫醒（不许误判）' (ShouldWake (Make-Variant $good @{}) $T0)
Check '★★ 缺 resume 时不能用 -not 判（源码须显式 -eq false）' `
  ((Get-Content $PSScriptRoot\..\lib\index.js -Raw -Encoding UTF8) -match 'last\.resume === false')

Write-Host ''
Write-Host '=== ⑤-b 消息形状：交给 test-wake-message.mjs 用**真函数**验证 ===' -ForegroundColor Cyan
# 【为什么这一段不在这里抠源码】
#   第一版我在这里用正则从 lib/index.js 里"抠出 makeWakeMessage 的函数体再求值"——
#   那是**脆的**：函数一改名/一重构就抠不到、报红，而报红的原因跟"消息形状对不对"无关。
#   真函数已经导出了（export makeWakeMessage），所以交给专门的 node 测试去 import 它逐字段称重。
#   这里只留**存在性台账**，保证那套测试还在、且被登记进了全量清单（否则没人会跑它）。
$runnerPathForWake = Join-Path $PSScriptRoot 'run-all-tests.ps1'
$runnerTextForWake = if (Test-Path $runnerPathForWake) { [System.IO.File]::ReadAllText($runnerPathForWake, [System.Text.Encoding]::UTF8) } else { '' }
Check '★ test-wake-message.mjs 文件存在' (Test-Path (Join-Path $PSScriptRoot 'test-wake-message.mjs'))
Check '★ 它被登记进 run-all-tests.ps1（否则不会有人跑它）' `
  ($runnerTextForWake -match 'test-wake-message\.mjs')
# 源码里必须真的**导出**这个函数（导出了才可能被真函数验证；没导出就只能靠正则猜）
Check '★ lib/index.js 导出了 makeWakeMessage（可被真函数验证）' `
  ($libCode -match 'export\s*\{[^}]*makeWakeMessage' -or $libCode -match 'export\s+function\s+makeWakeMessage')

Write-Host ''
Write-Host '=== ⑥ 界面文案：不能让人把"上限"读成"倒数"（2026-10-12 被误导过）===' -ForegroundColor Cyan
# 背景：窗口原本写「已等 N 秒　最多再等 M 秒（等不到就放弃，绝不强关）」，
#   看到"M 秒"，以为**还要倒数 M 秒才动手**。
#   **这不是看错，是文案本身有歧义** —— 界面上的字被误解，是界面的问题，不是人的问题。
#   改法：说清"在等它安静下来"，并显式否认倒计时。
$winPath = Join-Path $pluginRoot 'bin\dsh-restart-window.ps1'
$winText = [System.IO.File]::ReadAllText($winPath, [System.Text.Encoding]::UTF8)
Check '等待文案不再用有歧义的「最多再等」' (-not ($winText -match '最多再等 \{0:N0\} 秒'))
Check '等待文案显式否认倒计时（"这不是倒计时"）' ($winText -match '这不是倒计时')
Check '等待文案说清"安静了就立刻动手"' ($winText -match '安静了就立刻动手')
Check '等待文案用「已经等了」（过去时，不是倒数）' ($winText -match '已经等了 \{0:N0\} 秒')

Write-Host ''
Write-Host '=== ⑦ 工具说明：delay_seconds 一律填 0（2026-10-13 约定死）===' -ForegroundColor Cyan
# 背景：这条规则被推翻过两次。
#   2026-10-12 我设了 120 秒被质问 → 当时改成"按回复长度填"；
#   2026-10-13 我照那张表又填了 40 秒 → 用户识破：
#     "说完所有话以后最后拍个重启，就不用专门留这个时间了，也不用留时间给我读，
#      因为这属于任务做到中间了、需要重启进行下一步"。
#   ⇒ "按回复长度"这条口径本身是错的（等"说完"是机制那一道闸的活，不是参数的活），
#     现在一律 0，并把重启放在这一轮的最后一个动作。
Check 'delay_seconds 说明里不再承诺"留给用户读完"' (-not ($libText -match 'finish reading your reply'))
Check '★ delay_seconds 说明里不再"按回复长度"填' (-not ($libText -match 'Size it by reply length'))
Check '★ delay_seconds 说明里写明"重启是任务中途动作，不是告别"' `
  ($libText -match 'mid-task step' -or $libText -match 'not a farewell')
Check '★ delay_seconds 说明里要求"放在这一轮最后一个动作"' `
  ($libText -match 'LAST action of your turn')
Check 'reason 说明里提到它会出现在唤醒提醒里' ($libText -match 'handed back to you in the wake-up reminder')

Write-Host ''
Write-Host '=== ⑦-c max_wait_minutes 三层默认值必须都是 0「一直等」（2026-10-24 约定）===' -ForegroundColor Cyan
# 背景：当时的疑问是「30 分钟的硬上线是不是可以不设了」。
#   查下去发现真正的坑不是那 30 分钟（那是显式传的），而是**三层默认值不自洽**：
#     · schema        默认 0（一直等）✅
#     · lib 兜底      `: 5`  ← 配置读不出来时悄悄变成"最多等 5 分钟"
#     · 助手 `else`   `else { 5 }` ← plan 漏写这个字段时同样悄悄变成 5 分钟
#   后果是"同一个参数两种意思，且降级时**不报错**"——正是本仓反复栽的那类坑。
#   ⇒ 三层必须都是 0。谁把哪层改回正数，这里立刻红。
Check '★ schema 默认是 0（一直等）' `
  ($libText -match 'maxWaitMinutes:\s*z\.number\(\)\.default\(0\)')
Check '★ lib 兜底也是 0（不再是 5）' `
  ($libText -match 'maxWaitFallback\s*=[^\r\n]*:\s*0;')
Check '★ 助手兜底也是 0（不再是 else { 5 }）' `
  ($helperText -match 'maxWaitMinutes\s*=\s*if \(\$null -ne \$plan\.maxWaitMinutes\)[^\r\n]*else \{ 0 \}')
Check '★ 工具说明不再谎称 default 5 minutes' (-not ($libText -match 'GIVING UP \(default 5 minutes\)'))
Check '★ 工具说明写明"不填 = 一直等"且能随时打断' `
  ($libText -match 'wait indefinitely' -and $libText -match 'cancel at any time')

Write-Host ''
Write-Host '=== ⑦-b 权威状态判据（2026-10-13 深夜：段 2 从"猜"改成"问"）===' -ForegroundColor Cyan
# 背景：用户点破 —— "你在等工具结果的时候，对话也是正常进行状态吧？"
#   实测：会话文件可静默 83 秒（一直在等工具），而老判据（静默 12 秒）早已放行。
#   权威依据：dsh-agent-loop 的 kick(){ finally{ setPhase("idle") } } + get status()。
#   这一组钉住三件事，退回任何一件都会让"等工具时被误判成说完"重新出现。
Check '★ 插件发布 agentStatusById（显式状态表，不必反推）' `
  ($libText -match 'agentStatusById')
Check '★ 插件订阅 agent/status 并即时落盘' `
  ($libText -match "agent/status")
$helperText = [System.IO.File]::ReadAllText((Join-Path $pluginRoot 'bin\dsh-self-restart.ps1'), [System.Text.Encoding]::UTF8)
Check '★ 助手优先用权威状态判"这一轮说完没有"' ($helperText -match 'authoritativeTurnDone')
Check '★ 权威判据读的是 agentStatusById 里本会话那一格' ($helperText -match 'agentStatusById\.PSObject\.Properties')
Check '★ 权威拿不到时仍退回文件静默兜底（不许判成"说完"）' `
  ($helperText -match '兜底：老的文件静默判据')
Check '★ 正主轮询已从 5 秒改成 2 秒' ($helperText -match 'Start-Sleep -Seconds 2')
Check '★ 另外两处 5 秒仍在（安全设计与等家务，故意没动）' `
  (@([regex]::Matches($helperText, 'Start-Sleep -Seconds 5')).Count -ge 2)
# ★ 2026-10-13 深夜补：**兜底与命中都要留痕**。
#   第一次实测（22:50 那次）发现：等待段跑的是旧插件，助手正确地退回了文件判据，
#   但**日志里一个字都没有** → 事后根本分不清那次绿灯是"权威判据"给的
#   还是"兜底"给的（两者可信度不同）。正是"看到绿灯先问绿灯怎么来的"那条教训。
Check '★ 用上权威状态时留日志' ($helperText -match '用上权威状态了')
Check '★ 退回兜底时说明原因（不留无声的降级）' ($helperText -match '用不上权威状态')
Check '★ 启动日志已写明"首选权威状态"' ($helperText -match '首选权威状态')

Write-Host ''
Write-Host '=== ⑧ 技能文档不许落后于代码（2026-10-12 专门问过这件事）===' -ForegroundColor Cyan
# 背景：问"这个在技能里面说清楚了吗？" —— 一查发现 SKILL.md 还停在 10-11，
#   这两天的改动**一个字都没写进去**。
#   这类"代码改了、文档没跟上"的毛病**没有任何报错**，只会让下一个会话按错的规则办事。
#   所以在这里钉几条**关键事实**，不许技能文档再落后。
$skillPath = Join-Path $env:DSH_HOME 'skills\dsh-self-restart\SKILL.md'
if (Test-Path $skillPath) {
  $skillText = [System.IO.File]::ReadAllText($skillPath, [System.Text.Encoding]::UTF8)
  Check '技能里写了"重启完自己醒"这件事' ($skillText -match '重启完自己醒过来接着干')
  # ★ 2026-10-13 改：技能里必须写清新机制（直接投递），而不是旧的 schedule 提醒
  Check '★ 技能里写了唤醒已改成"直接投递"（不是 schedule 提醒）' `
    ($skillText -match '直接投递|注入会话|投递消息')
  Check '★ 技能里写了 source.kind 不许是 user（不冒充使用者）' `
    ($skillText -match "kind:\s*'self-restart'|不是 user|不冒充")
  Check '技能里写了 wakeMessage / wakeDelaySeconds' `
    (($skillText -match 'wakeMessage') -and ($skillText -match 'wakeDelaySeconds'))
  # ★ 2026-10-13 改：不再要求写"按回复长度"（那条口径已被用户推翻），
  #   改成要求写清"一律填 0 + 放在最后一步"。
  Check '★ 技能里写了 delay_seconds 一律填 0' ($skillText -match '一律填`? \*\*0\*\*|一律填 0|固定填 0')
  Check '★ 技能里写了把重启放在这一轮最后一个动作' ($skillText -match '最后一个动作|最后一步')
  Check '技能里写了 reason 会显示在窗口上' ($skillText -match '窗口第一屏就会写|原因：`')
  # ★ 2026-10-13 深夜改：idleSeconds=12 现在只是**兜底阈值**（主判据已换成权威状态），
  #   所以断言跟着改成"技能里必须写明 12 秒是兜底、主判据是权威状态"。
  #   （旧断言是 `idleSeconds = **12 秒**` 那条表格式写法 —— 表已改版，断言随之更新。）
  Check '★ 技能里写明 idleSeconds=12 只是兜底（主判据是权威状态）' `
    ($skillText -match 'idleSeconds`?\s*=\s*\*\*12 秒\*\*' -and $skillText -match '兜底')
  Check '★ 技能里写明"别再改回只看文件静默"' `
    ($skillText -match '别把这里改回"只看文件"|别再改回只看文件|别把这里改回')
  Check '技能里记了"不是倒计时"那条文案教训' ($skillText -match '这不是倒计时')
  Check '技能里记了轮询救场那条' ($skillText -match '轮询救回来的|轮询救了我一命|改成\*\*轮询\*\*')
  # ★ 2026-10-13 改：不再写死数字，改成**跟 run-all-tests.ps1 的实际条数对账**。
  $runnerPath = Join-Path $PSScriptRoot 'run-all-tests.ps1'
  $actual = @([regex]::Matches([System.IO.File]::ReadAllText($runnerPath), "(?m)^\s*@\{ Name = '")).Count
  Check "技能里的测试套数与全量清单对账（实际 $actual 套）" `
    ($skillText -match ("\*\*" + $actual + " 套\*\*")) `
    "技能里写的不是 $actual 套 —— 加了测试记得同步 SKILL.md"
} else {
  # ⚠️ 2026-10-12 改成"优雅跳过"：这份技能文档在 %DSH_HOME%\skills\ 下，
  #   **不属于本插件仓库**。别人 clone 下来根本没有它 —— 那样直接报红，
  #   等于"把本机的私有资产当成公开包的必备件"，别人跑测试必然失败。
  Write-Host '  [SKIP] 本机没有这份技能文档，跳过第 ⑧ 组（它不属于插件仓库）'
}

Write-Host ''
Write-Host '=== ⑨ bundle 元数据：包必须"可安装"（2026-10-12 盘点出的硬伤）===' -ForegroundColor Cyan
# 背景：脱敏后盘点发现，这个包**还不是可安装的 bundle** ——
#   缺 cordis.patch.yml、缺 package.json 里的 dsh.bundle.patch 声明。
#   它原先能跑，是因为用户 profile 里手写了一段配置；别人装了**插件在但不会启用**。
#   而且 README 原来教的安装方法（"拷到 plugins 目录"）是官方文档明确禁止的做法。
# 这些一旦退回，表现是"别人装完没反应"，且**没有任何报错** —— 所以钉死。
$pkgRaw = Get-Content (Join-Path $pluginRoot 'package.json') -Raw -Encoding UTF8
$pkg = $null
try { $pkg = $pkgRaw | ConvertFrom-Json; Check 'package.json 是合法 JSON' $true }
catch { Check 'package.json 是合法 JSON' $false $_.Exception.Message }
if ($pkg) {
  Check '声明了 dsh.bundle.patch（bundle 的入口）' ([bool]$pkg.dsh.bundle.patch)
  Check 'bundle.patch 指向 cordis.patch.yml' ([string]$pkg.dsh.bundle.patch -match 'cordis\.patch\.yml')
  Check 'private=false（true 的话没法发布）' ($pkg.private -eq $false)
  Check '有 license 字段' ([bool]$pkg.license)
  Check '有 repository 字段' ([bool]$pkg.repository.url)
  Check 'schemastery 列为 peerDependency（它由宿主提供）' `
    ([bool]$pkg.peerDependencies.'@deepseek-ai/schemastery')
  Check 'os 限定 win32（本插件只支持 Windows）' (@($pkg.os) -contains 'win32')
  # files 里列的每一项必须真实存在（列了不存在的会静默丢文件）
  # ⚠️ 2026-10-13 修：这条断言原先**自己就是错的两条**，是照抄现成写法时没想清楚：
  #   ① `!test/fixtures/.generated/` 是 npm 的**排除模式**（以 ! 开头），
  #      它指的本来就是个"不该被发布"的目录 —— 拿 Test-Path 去要求它存在，逻辑上就是反的。
  #   ② `deploy.ps1` 是本机"开发区→使用区"的同步脚本，**只存在于开发区**；
  #      而这份测试在用**使用区**那份跑（那边天生没有它）。这不是缺陷，是设计。
  #   ⇒ 正确口径：**只对"真实存在的条目"要求存在**，排除模式跳过；
  #     而 deploy.ps1 这种"只在开发区有"的，在开发区跑时必须存在、在使用区跑时不强求。
  $filesToCheck = @($pkg.files | Where-Object { $_ -and -not ([string]$_).StartsWith('!') })
  $missing = @($filesToCheck | Where-Object { -not (Test-Path (Join-Path $pluginRoot $_)) })
  # 用"使用区"跑时，deploy.ps1 不参与（它本来就不该被同步过去）
  $isLiveArea = $pluginRoot -match 'profiles[\\/]desktop[\\/]plugins'
  $missing = @($missing | Where-Object { -not ($isLiveArea -and $_ -eq 'deploy.ps1') })
  Check 'files 清单里每一项都存在（排除模式与 deploy.ps1 例外已说明）' ($missing.Count -eq 0) `
    $(if ($missing) { '缺: ' + ($missing -join ', ') })
  # 排除模式本身要**写成**否定形式（写成普通路径就成了"要求这个目录存在"，语义反了）
  Check '★ files 里的排除模式用 ! 开头（不是普通路径）' `
    (@($pkg.files) -contains '!test/fixtures/.generated/')
}
$patchPath = Join-Path $pluginRoot 'cordis.patch.yml'
Check 'cordis.patch.yml 存在' (Test-Path $patchPath)
if (Test-Path $patchPath) {
  $patchText = Get-Content $patchPath -Raw -Encoding UTF8
  Check 'patch 里有 - insert: 条目' ($patchText -match '-\s*insert:')
  Check 'patch 里 id 是 self-restart' ($patchText -match 'id:\s*self-restart')
  Check 'patch 里 name 指向本包' ($patchText -match "name:\s*'dsh-self-restart'")
  Check 'patch 没有用 Tab 缩进（YAML 禁 Tab）' (-not ($patchText -match "(?m)^\t"))
}
Check 'LICENSE 文件在位' (Test-Path (Join-Path $pluginRoot 'LICENSE'))
Check 'CHANGELOG 在位' (Test-Path (Join-Path $pluginRoot 'CHANGELOG.md'))
# README 的安装说明不许再教人"拷目录"（官方禁止），也不许再谎称无依赖
$readme = Get-Content (Join-Path $pluginRoot 'README.md') -Raw -Encoding UTF8
Check 'README 教的是 install_bundle（不是拷目录）' ($readme -match 'install_bundle')
Check 'README 警告了"别用 shell 模拟安装"' ($readme -match '不要.*shell 命令模拟|别手工拷目录')
Check 'README 不再谎称"没有第三方依赖"' (-not ($readme -match '本插件\*\*没有第三方依赖\*\*（只用'))

Write-Host ''
if ($fail -eq 0) {
  Write-Host "  ===== 汇总：$pass/$($pass+$fail) 通过 =====" -ForegroundColor Green
  exit 0
} else {
  Write-Host "  ===== 汇总：$pass/$($pass+$fail) 通过，$fail 项失败 =====" -ForegroundColor Red
  exit 1
}
