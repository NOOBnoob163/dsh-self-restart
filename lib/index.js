/**
 * dsh-self-restart — 让 Agent 能"自己重启自己"
 *
 * ## 这个插件解决什么问题
 *
 * DSH 桌面版是一个长驻进程：插件改动、配置改动、内存膨胀、偶尔的卡死，
 * 都需要"把应用关掉再打开"才能恢复。但关掉它 = 关掉正在干活的 Agent 自己，
 * 所以它没法自己动手 —— 除非有个**不在它进程树里**的东西替它做这件事。
 *
 * 本插件提供那个东西：
 *   ① 注册工具 `restart_self`（给 Agent 用）和 `restart_status`（看状态）
 *   ② 定期把"忙不忙"写进 state.json（后台任务数、在跑的会话数）
 *   ③ 被调用时写一份"计划文件"，然后启动一个**脱离进程**的助手脚本；
 *      助手用 WMI 创建，父级是 WmiPrvSE，DSH 死了它照样活着 —— 所以它
 *      能先杀掉 DSH、再把 DSH 拉起来、最后验端口确认真的起来了。
 *
 * ## 关掉它就等于关掉这个能力
 *
 * 工具是插件注册的：把本插件停用，`restart_self` 就从工具表里消失，
 * Agent 再也调不到。助手脚本不会被任何东西自动触发 —— 它只在插件
 * 写了计划文件、并主动启动它之后才跑。
 *
 * ## 为什么"等闲置"要做在插件里、也做在助手脚本里
 *
 * 插件这一侧知道得最准：`ctx.jobs.list()` 直接给后台任务，`ctx.agents.list()`
 * 直接给活着的会话及其 status，`ctx.agents.roots()` 还能区分**真对话**和**子代理**。
 * 但**插件本身也会随着 DSH 一起消失**，
 * 所以助手脚本必须能独立判断 —— 它读插件定期写下的 state.json，
 * 外加会话记录文件的修改时间（"这轮到底说完了没有"的硬证据），
 * 以及 DSH 自己写的会话身份档案（认得出"家务子代理"，见 Test-IsSubagentSession）。
 * 两边都判，才不会在 Agent 正写着文件的时候把它砍了。
 *
 * ## "闲下来"是两段式判的（2026-10-08 定的设计）
 *
 * 第一段只等**发起重启的那个会话**把这一轮说完（连续 idleSeconds 没写会话记录）——
 * 这一段故意不看别人，否则它自己一边写日志一边重置计时，会把自己等黄。
 * 第二段才去查别人，且三种"忙"分开处理：
 *   · 别的对话/会话在忙                 → 放弃（机会作废，不排队）
 *   · 只有后台任务在跑                   → 等它跑完（期间有对话进来就放弃）
 *   · 家务子代理在跑（如某个插件的空闲复审子代理）→ 也是等（没人在等它，是家务）
 *
 * ## 安全边界（刻意的）
 *
 * · 只在**本机桌面版**上工作：找不到主程序就明确失败，绝不乱猜路径
 * · 默认 `dryRun: false` 但工具的第一个参数就是 `confirm`，不传 true 不动手
 * · 助手全程写日志；结果写 last-run.json，DSH 起来后本插件会读出来汇报
 * · 保险丝：助手在动手前先挂一个 -Watchdog 进程，万一正主死在半路，
 *   保险丝负责把 DSH 拉回来。**任何情况下都不允许"关掉了却没人拉起来"**
 * · **不做强制重启**（设计取舍，2026-10-08）：等不到空闲就放弃，`forced` 永远 false
 * · **不弹窗**：这台机器常被远程驱动，弹窗没人点。没做成由对话下一轮自己发现并如实转告
 * · 助手进程**不出现黑框**（建进程时 ShowWindow=0）
 *
 * ## 配置（装配补丁里的 config 是默认值）
 *   enabled: true            总开关（false = 工具照样注册，但拒绝执行）
 *   port: 19387              判定"活着"用的端口
 *   dshExe: ''               主程序路径；留空自动探测
 *   idleSeconds: 12          连续这么久没动静才算"闲"（2026-10-10 从 25 调短）
 *   maxWaitMinutes: 5        最多等多久（分钟级）。**等不到就放弃，绝不强制重启**（设计取舍，2026-10-08）
 *   othersWindowSeconds: 120 第二段查"别人"时的窗口：会话记录在这段时间内被写过就算别人在忙。
 *                            比 idleSeconds 宽是有意的 —— 等完自己那一轮才去查别人，
 *                            别人刚好同时在写的话，用同样窄的窗口会看不出他在忙。
 *   bootTimeoutSeconds: 90   拉起后等端口多久算超时
 *   maxAttempts: 3           拉起失败重试几次
 *   checkSeconds: 10         多久刷新一次 state.json
 *   wakeMessage: true        重启完成后是否把唤醒消息直接投进原会话（false = 不叫醒，要人手动开）
 *   wakeMessageMaxChars: 600 唤醒消息里"重启前那条 reason"最多带多少字符（超了截断，防撑坏会话）
 *   stateDir: ''             状态目录，默认 <DSH 家目录>/self-restart
 *
 * 【日志】<stateDir>/plugin.log
 *
 * @module dsh-self-restart
 */
import { readFileSync, writeFileSync, mkdirSync, appendFileSync, existsSync, rmSync, readdirSync, renameSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import z from '@deepseek-ai/schemastery';
import { createSerialNoticeRunner } from './notice-hook.js';

export const name = 'dsh-self-restart';

// 必须声明要用 tools：Cordis 里没在 inject 里声明的服务，直接访问 ctx.tools
// 会抛 "cannot get property tools without inject" —— 表现是工具**静默没注册上**，
// 界面里一切正常，只是 restart_self 根本不存在。（2026-10-08 实机踩到）
// jobs / agents 用动态 ctx.inject([...]) 拿，不需要写在这里。
export const inject = ['tools'];

/** DSH 家目录：先认 $DSH_HOME，没有才回退到 ~/.dsh */
const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const HERE = dirname(fileURLToPath(import.meta.url));
/** 助手脚本：插件包的 bin/ 目录 */
const HELPER = resolve(HERE, '..', 'bin', 'dsh-self-restart.ps1');

/**
 * 本实现的版本号 —— 一个**不会自然出现的数**，专门用来回答"跑的是新代码吗"。
 *
 * ⚠️ 为什么必须有它（2026-10-11 的教训）：改完 lib/index.js 之后，热加载**不会**重载
 * 模块代码，但插件日志照样打印「插件已挂上」—— 看着像生效了，其实际运行的是旧代码。
 * 所以这个数会写进 state.json 的 `impl` 字段，也会出现在唤醒消息里（"醒来先自检"有东西可对）。
 *   1 = 老实现（读失败即当"没有"、直接覆盖写、插件会写 last-run.json）
 *   2 = 2026-10-11 新实现（读失败重试、整张换上、插件只写自己的 reported.json）
 *   3 = 2026-10-13 新实现（汇报并进心跳、restart_status 现算流水账分布）
 *   4 = 2026-10-13 晚：**唤醒从"排定时提醒"改成"直接投递消息"**（不再依赖 schedule）
 *   5 = 2026-10-13 深夜：**工具说明改成"delay_seconds 一律填 0、重启放这一轮最后一个动作"**
 *       （旧口径"按回复长度填 30~60"被推翻 —— 等"说完"是机制那道闸的活，不是参数的活）
 *   6 = 2026-10-13 深夜②：**"这一轮说完没有"改用权威状态**（agent.status=idle），
 *       不再只靠"会话文件静默 12 秒"猜（实测等工具时可静默 83 秒 → 会误判）。
 *       同时：agent/status 变化即时落盘 + 助手轮询 5s→2s。
 *   7 = 2026-10-13 深夜③：**新增 `resume` 参数 —— 续不续接由模型自己选**
 *       （用户要求："让在干活的模型自己选续不续接"）。收尾型重启传 resume=false 就不叫醒。
 *       ⚠️ 判定必须写 `=== false`：老计划没这个字段，`-not` 会把老记录全误判成"不续接"。
 *   8 = 2026-10-17 深夜：**端口不再写死，改用 webServer.port 问真实端口**。
 *       （DSH 0.2.1-rc.2 起桌面端用 `--port 0` 动态分配；写死 19387 导致助手判
 *        "没起来" → Kill-AllDsh → 保险丝接力 → 一晚连环杀掉全部 DSH 实例。
 *        详见 维护记录）
 *   9 = 2026-10-22：**排队重启**（这一版改得最多）：
 *       ① 不再因"别人在忙"拒绝 → 入队继续等；默认 maxWaitMinutes=0（一直等）；
 *       ② plan.json 支持 members[] 名单；同会话重复排只更新、不覆盖车次；
 *       ③ 唤醒改成按名单挨个喊（逐人记账 `resume:<planId>:<会话id>`）；
 *       ④ 会话来源判据（rpcId → local / im-direct / im-group / unknown）；
 *       ⑤ 会话标题标记 `♻️ 待重启 · `（照抄 dsh-im，不用 rename）；
 *       ⑥ 等超过 notifyAfterMinutes 交给外部通知钩子。
 *       ⚠️ 这一版**必须重启宿主**才生效（前面几版也改了 bin\*.ps1，那些是现读的）。
 *   14 = 2026-10-23 下午：**排队重启的四处硬伤**（一次真事故换的，用户 17:57 报的那次）：
 *       ① 入队回包多了 `queueLength`，而输出 schema 没声明它 → 宿主按
 *          `additionalProperties:false` **整份拒收**。副作用（写计划）已经发生，
 *          但调用方看到的是"报错" → 它以为没排上，四处折腾。
 *          修法：补字段 + **注册时套一层"声明外字段一律剔除并记日志"**
 *          （宁可少一个字段，也不能"活干了却回一句失败"）。
 *       ② 工具说明里写着 `Every member can leave the queue on its own`，
 *          代码里**从来没有这个能力**（只有整批 cancel）。说明书骗人 → 改成整批语义。
 *       ③ `restart_status` 只印"第一个人的理由"，第二个人看不到名单 →
 *          会把别人的旧任务当成"这趟不该有" → 误点取消（这次就是这么翻车的）。
 *          修法：列出**整份名单**（谁、各自的理由、你在不在里面），并识别僵尸计划。
 *       ④ 取消之后 `plan.json` / `cancel.flag` 都没删 → "已取消"和"待执行"同时成立。
 *          修法：助手在取消分支**封口**（删计划 + 清标记）。
 *   16 = 2026-10-25：**标题不再和 dsh-im 互相抢**（实机事故，用户报的）：
 *       QQ 会话标题每 10 秒长一层 `QQ · ♻️ QQ · ♻️ … 原标题`，6 拍长到 6 层。
 *       病根：我们只剥"开头自己的图标"、dsh-im 只认"开头是不是 `QQ · `"，
 *       两边都把对方的标记顶到最前 → 互相喂，永不收敛。
 *       修法：标题拆成「频道前缀 + 图标 + 正文」，图标**排在频道前缀后面**
 *       （`QQ · ♻️ 原标题`）；剥离时两段都认，历史脏标题也能一次还原。
 *   17 = 2026-10-25 晚：**「重启成功但没叫醒」的通知会误报**（用户实机收到）：
 *       插件热重载时 `plan.json` 里有一趟**还在排队、没发车**的重启，旧判据
 *       `sawPendingPlan`（= 见过计划文件）就把它当"这趟没叫醒"，5 分钟后发出通知，
 *       报的却是 6 小时前那趟（而那趟唤醒成功了）。
 *       修法：收工提醒要三条同时成立 —— 确实有该叫醒的人 + 那趟**真完成**了
 *       （last-run 是本进程内的新记录）+ 没投成。口径抽成 shouldNotifyWakeFailure。
 *   18 = 2026-11-01：**不再内置任何通知渠道** —— 原先写死的私聊投递改成
 *       通用的 
oticeCommand（默认空 = 不通知）。理由：渠道属于用户环境，
 *       写死渠道等于要求每个使用者装同样的东西，不装就静默失败。
 *   19 = 2026-11-01：加 restart_status(leave: true) ——「我自己下车」。
 *       以前只有整趟取消，只想让自己不被叫醒就不得不打掉别人的重启。
 *       现在只摘自己：车上还有别人就照开（只是不叫我），摘完没人就不发车。
 * 改这个数字的意义就是"让'跑的是旧代码'这件事一眼可见"。
 * ⚠️ 改了这里，记得同步改 test/verify-roots.mjs 里的 EXPECTED_IMPL。
 */
export const IMPL_VERSION = 19;

/**
 * 造一条**完整合法**的用户消息 —— 投递唤醒消息时必须用它，**绝不许直接塞字符串**。
 *
 * 【为什么这个函数必须存在，而不是随手拼个对象】（2026-10 那次事故的根因）
 *   当年 某个早期插件版本 把**字符串**喂给 `agent.followup()`：
 *   inbox 的 `mutate()` 对插入项**没有任何类型检查**（只查了 `message.id` 有没有重复，
 *   而字符串的 `.id` 是 `undefined`，单个能过）→ 于是"没有 id、没有 content 的货"
 *   被原样 append 进会话账本 → 界面按消息对象的形状去读它 → 崩，
 *   两个会话直接打不开、整个会话列表变空白。
 *
 *   ⇒ 分水岭不是"followup 危险"（DSH 自己的服务就在用），而是**喂了什么**：
 *     喂字符串 = 必坏；喂一条形状齐全的真消息对象 = 正常入库。
 *
 * 【所以这里逐项补齐必需字段】
 *   id      —— 唯一标识。用 randomUUID，格式与官方 createUserMessage 一致（它就是 randomUUID）。
 *              ⚠️ 必须有：inbox 去重、界面按 id 认消息都靠它。
 *   role    —— 固定 'user'（这是"用户角色消息"这一档，和"谁说的"是两件事，见 source）。
 *   content —— 必须是**数组**，元素是 { type:'text', text }。空串会被会话准入拒掉。
 *   source  —— **我们自己盖的戳**：kind='self-restart'。**绝不写 'user'**：
 *              DSH 用 kind==='user' 判"这句话是不是人说的"（如 goal 的 complete 需要
 *              "有人类输入"才放行）。写自己的戳 = 不冒充使用者、不继承人类授权。
 *
 * 【为什么自己造、不用官方的 createUserMessage】
 *   官方那两个函数在 `@deepseek-ai/dsh-llm` 包里，而那个包**只存在于 app.asar 内部**
 *   （本机 profiles/desktop/node_modules 下没有它）—— 插件在 profile 目录里 import 不到，
 *   硬 import 会让整个插件在链接期就崩。所以这里**照它的形状自己造**：
 *   实测（2026-10-13）两者产出的对象逐字段等价，唯一区别是 id 的"品牌"只是编译期标记
 *   （官方 brandString() 的实现就是 `return value`，运行时不做任何转换）。
 *
 * @param text - 要投递的纯文本（调用方保证非空、已限长）。
 * @returns 一条可安全投进 inbox 的用户角色消息对象（深冻结，防投递后被改）。
 */
function makeWakeMessage(text) {
  return deepFreeze({
    id: randomUUID(),
    role: 'user',
    content: [{ type: 'text', text: String(text ?? '') }],
    source: {
      kind: 'self-restart',
      // ⚠️ 这里**故意不叫 `plugin`**：`plugin` 是会话格式 V3 时代的**旧字段名**
      //    （V3→V4 迁移器会把它读成"这是老式插件来源"并改写 kind）。新写的消息
      //    不该去用那个退休的名字，免得将来哪次迁移把它当成别的意思。
      //    V4 的规矩是"kind 非空且不等于 'plugin'，其余自有字段一律保留"——
      //    所以我们用自己的字段名，安全且语义清楚：这条是哪个生产方投的。
      producer: 'dsh-self-restart',
      impl: IMPL_VERSION
    }
  });
}

/**
 * 递归冻结一个对象 —— 官方 createUserMessage 会 deepFreeze（对象在发布前冻住，
 * 之后谁都不能改它）。我们照做：投进 inbox 的消息应当是只读的，
 * 免得后面某处无意改一下，让"账本里存的和当时投的不一样"。
 */
function deepFreeze(value, seen = new Set()) {
  if (value === null || typeof value !== 'object' || seen.has(value)) return value;
  seen.add(value);
  for (const key of Object.keys(value)) deepFreeze(value[key], seen);
  return Object.freeze(value);
}

const Config = z.object({
  enabled: z.boolean().default(true),
  port: z.number().default(19387),
  dshExe: z.string().default(''),
  idleSeconds: z.number().default(12),
  // ⚠️ 2026-10-10 默认值 25 → 12（25 秒的等待体感偏长）。
  //    与 cordis.patch.yml 里那个值保持一致，这里是"没配置时"的兜底。
  //
  // 2026-10-11 新增：排完重启后的缓冲秒数（原来写死 8 秒）。
  //   设计意图：默认重排等待时间留 5 秒、确认窗再留 10 秒给使用者确定，
  //   最后直接重启 —— 重启得越快，对正常要一直挂着的工具影响越小。
  //   所以：缓冲 5 秒（计划延迟）+ 助手那边的 10 秒确认窗 = 一共约 15 秒。
  confirmBufferSeconds: z.number().default(5),
  // 2026-10-11 新增：动手前的确认窗秒数（默认 10）。
  //   这段时间屏幕上会显示倒计时，**「打断」按钮仍然可点** —— 是最后的反悔机会。
  //   设计意图：确认窗留 10 秒给使用者确定，之后直接重启。
  confirmSeconds: z.number().default(10),
  // ★ 2026-10-22 改：默认从 5 分钟改成 **0 = 一直等**。
  //
  //   为什么改：用户的诉求是"想要这个重启自动在空闲时间进行"——他不守着。
  //   老默认值 5 分钟意味着"只要这 5 分钟里没空闲就作废"，而他睡一觉回来会发现
  //   重启根本没发生，还以为是插件坏了。
  //
  //   语义（助手侧早已支持，本次没有改代码）：
  //     > 0 → 最多等这么多分钟，等不到就放弃（绝不强制重启）
  //     <=0 → 一直等下去（另有 12 小时硬上限兜底，防止无限挂）
  //   配套的"等太久让你知道"由 notifyAfterMinutes 负责（默认 20 分钟触发一次通知钩子）。
  maxWaitMinutes: z.number().default(0),
  // 第二段（查"别人在不在忙"）用的窗口。第一段只等自己那一轮，用 idleSeconds；
  // 等完自己再去查别人时，别人可能正好同时在写 —— 窗口太窄会看漏，故默认放宽到 120s。
  othersWindowSeconds: z.number().default(120),

  // ── ★ 2026-10-22 新增（排队重启那一批）。每个配置项对应决策记录里的一条。──────

  // 等多久还没发车就发一条提醒。0 = 不提醒。
  // 依据：记录里成功重启的中位耗时只有 46 秒、最长 134 秒 —— 等 20 分钟还没动，
  // 基本是被长活拖住了，值得说一声。
  notifyAfterMinutes: z.number().default(20),
  // 提醒过一次之后要不要再提醒。默认**不要**（重复提醒容易变成刷屏）。
  notifyRepeat: z.boolean().default(false),
  // 重复提醒的间隔（只有 notifyRepeat=true 时才有效）。
  notifyRepeatMinutes: z.number().default(60),

  // ── 外部通知：本插件**不内置任何通知渠道** ─────────────────────────────
  //
  // 插件只在事件发生时执行下面这条命令，告诉它发生了什么；发不发、发给谁，
  // 全在命令里。留空（默认）= 完全不通知，也不执行任何外部命令。
  //
  // 可用事件（环境变量 DSH_SR_EVENT）：
  //   restart-queued-long  等太久还没发车
  //   restart-done         重启成功
  //   wake-failed          重启成功但没叫醒排队的会话
  //   restart-failed       重启失败或被取消
  // 正文放在 DSH_SR_TEXT；另外带上 DSH_SR_PLANID 等标量字段。
  //
  // 例：noticeCommand: 'node C:\\tools\\notify.mjs'
  noticeCommand: z.string().default(''),
  // 命令超时（毫秒）。超时就杀掉，绝不让通知卡住重启流程。
  noticeTimeoutMs: z.number().default(30000),

  // 要不要把即时通讯（IM）的**私聊**也算成"有人在用"从而拦住重启。
  //
  // 默认 true：私聊那头随时可能来人，按"有人在用"处理更保守。
  // ⚠️ 副作用：如果你有大量私聊会话，默认值下「自动找空闲重启」可能经常等不到。
  //    真嫌慢，第一个该调的就是它。
  waitForImDirect: z.boolean().default(true),
  // 要不要"所有会话都 idle"才动手（包括群聊那种机器人自己在聊的）。
  // 默认 false：群聊里的机器人对话不算"有人在用"。
  waitForAllSessions: z.boolean().default(false),
  // 队列最多几个人。0 = 不设上限。
  // 纯防呆：真实历史里从没出现过两个人同时排（46 次重启的申请者全是同一个会话）。
  queueMaxMembers: z.number().default(8),
  // ★ 2026-10-13 改：唤醒机制从"排一条定时提醒"换成"**直接把消息投进原会话**"。
  //
  //   为什么换（这次调研的结论）：我们原先用的 schedule 提醒，**底层跑的就是"注入会话"**
  //   —— 官方 dsh-schedule 内部做的正是 resolveAgent → 造消息 → followup → flush，
  //   只不过外面包了一层定时器、盖的是 kind:'schedule' 的戳。所以这不是"换方案"，
  //   而是**绕开定时器这一层中间商**。收益：
  //     · 不再依赖实验 bundle（@deepseek-ai/dsh-experimental-schedule-bundle）；
  //     · 不再有 3~20 秒的服务就位等待（实测 schedule 比插件晚到过 20 秒）；
  //     · 唤醒消息在会话里是**正常的一行**，不再显示成"定时提醒"。
  //
  //   ⚠️ 安全边界（必须守住，当年翻过车）：
  //     ① 只喂**真消息对象**（有 id、有 role、有 content、有 source），
  //        **绝不喂字符串** —— 喂字符串会把"没有 id、没有 content 的货"写进会话账本，
  //        界面按消息对象形状去读它就崩、整个会话列表变空白（一次消息对象形状的事故根因）。
  //     ② source.kind 写**我们自己的** 'self-restart'，**不写 'user'**：
  //        DSH 用 kind === 'user' 判"这句话是不是人说的"（hasDirectHumanInput），
  //        某些操作（如 goal 的 complete/blocked）要"有人类输入"才放行。
  //        写自己的戳 = 不冒充使用者、不继承人类授权。
  //     ③ followup 之后必须 `sessions.flush()` 确认落盘（官方 schedule 同款做法）。
  //
  //   wakeMessage = false 就整个关掉这个功能（重启完不叫醒，要人手动开）。
  wakeMessage: z.boolean().default(true),
  // ★ 2026-10-13 新增：投递唤醒消息前等几秒（纯时长，默认 3）。
  //
  //   为什么这么短：投递发生在**重启之后**，那时 DSH 必然活着、插件也加载完了。
  //   留 3 秒只是让宿主把刚开始那点接线跑完，不是为了"防重启还没起来"。
  //   （对比：曾经想在重启**之前**排提醒，为防"还没起来"得留 3 分钟 —— 那个窗口本身
  //     不确定，定死 3 分钟要么被提前吃掉、要么长得离谱，所以从一开始就否掉了。）
  //
  //   ⚠️ 这里**不设下限**：0 就是立刻投（等下一拍轮询，最多 3 秒）。
  //      老实现在 resumeDelaySeconds 上用 Math.max(5, …) 兜底，把"填 1、2、3"悄悄改成 5 ——
  //      "配了不生效"最误导人，所以这版老老实实：填几就是几。
  wakeDelaySeconds: z.number().default(3),
  // 唤醒消息里要原样带回"重启前写的那条 reason"。给它一个上限（默认 600 字符）：
  // 这段文字会进会话账本，写太长（比如有人把整篇报告塞进 reason）既没必要也撑坏上下文。
  // 参考：别人那个插件对同类文案的取值是 交接 600 / 原因 300。
  wakeMessageMaxChars: z.number().default(600),
  // ★ 2026-10-12 新增（脱敏配套）：唤醒文案里想附带的一句提示（比如"去看你的进度笔记 X"）。
  //
  //   为什么要有它：原先唤醒文案里**写死了**某个开发机上笔记文件的绝对路径 ——
  //   装在别人机器上那是条瞎路，而且把使用者的目录结构泄进了源码。
  //   现在改成空白默认（谁都不提），要用的人自己填自己的。
  //   例：`resumeHint: '去看 D:\\notes\\进度.md'`
  resumeHint: z.string().default(''),
  bootTimeoutSeconds: z.number().default(90),
  maxAttempts: z.number().default(3),
  checkSeconds: z.number().default(10),
  stateDir: z.string().default('')
});

/** 从配置解析出状态目录（含兜底与建目录）。 */
function resolveStateDir(config) {
  const dir = (config.stateDir ?? '').trim() || join(HOME_DSH, 'self-restart');
  try { mkdirSync(dir, { recursive: true }); } catch { /* 建不出来时下面写入会失败，日志里能看到 */ }
  return dir;
}

/**
 * 探测 DSH 桌面版主程序路径。
 *
 * 只在**本机已知的安装位置**里找，找不到就返回 undefined 让调用方明确失败 ——
 * 绝不"猜一个最像的"，因为猜错的代价是"关掉了却拉不起来"。
 */
function detectDshExe(config) {
  const configured = (config.dshExe ?? '').trim();
  if (configured) return configured;

  const local = process.env.LOCALAPPDATA ?? '';
  const candidates = [
    local ? join(local, 'Programs', 'DeepSeek Harness', 'DeepSeek Harness.exe') : '',
    // 便携版 / 其它安装位置的常见形态
    'C:\\Program Files\\DeepSeek Harness\\DeepSeek Harness.exe'
  ].filter(Boolean);

  for (const candidate of candidates) {
    try { if (existsSync(candidate)) return candidate; } catch { /* 忽略 */ }
  }
  return undefined;
}

/**
 * 读 JSON —— 【2026-10-11 重写】区分「读失败」与「不存在」，读失败就重试。
 *
 * 老写法是一句 `try { JSON.parse(readFileSync(...)) } catch { return null }`，
 * 把两种完全不同的情况合并成同一个结果：
 *   · 文件本来就不存在    → 正常（比如还没排过重启）
 *   · 文件正被占用/正在写  → **异常，重试一下就能读到**
 * 调用方无法区分，只能一律当成"什么都没有"。
 *
 * 实测（2026-10-11，PS 侧同款对照）：一边写一边读时，
 * 「只读一次」有约 43% 读不到；「重试 5 次 / 隔 20 毫秒」降到 0.8%。
 * 所以病在读取，不在判断 —— 修法就是把读失败重试掉。
 *
 * @returns {{ok: boolean, value: any, reason: '不存在'|'读失败'|'空文件'|'坏JSON'|''}}
 */
function readJsonResult(path, maxTry = 5, delayMs = 20) {
  let reason = '不存在';
  for (let i = 0; i < Math.max(1, maxTry); i++) {
    // ① 真不存在 —— 正常情况，立刻返回，不浪费重试
    let raw;
    try {
      raw = readFileSync(path, 'utf8');
    } catch (error) {
      if (error && (error.code === 'ENOENT' || error.code === 'ENOTDIR')) {
        return { ok: false, value: null, reason: '不存在' };
      }
      // 被占用 / 权限 / 别的 IO 问题 → 重试
      reason = '读失败';
      if (i < maxTry - 1) sleepSync(delayMs);
      continue;
    }
    if (!raw || !raw.trim()) { reason = '空文件'; if (i < maxTry - 1) sleepSync(delayMs); continue; }
    try {
      return { ok: true, value: JSON.parse(raw), reason: '' };
    } catch {
      // 半截 JSON → 重试
      reason = '坏JSON';
      if (i < maxTry - 1) sleepSync(delayMs);
    }
  }
  return { ok: false, value: null, reason };
}

/** 同步睡一会儿（只在读取重试里用，最多几十毫秒，不影响事件循环的可接受性）。 */
function sleepSync(ms) {
  try {
    const shared = new SharedArrayBuffer(4);
    Atomics.wait(new Int32Array(shared), 0, 0, ms);
  } catch {
    // 退路：忙等（极少走到；重试总量只有几十毫秒）
    const until = Date.now() + ms;
    while (Date.now() < until) { /* spin */ }
  }
}

/**
 * 兼容包装：老调用点只关心"拿到东西没有"，继续返回 null 或值。
 * ⚠️ 需要区分"读失败"与"不存在"的场合，请直接用 readJsonResult。
 */
function readJson(path) {
  const r = readJsonResult(path);
  return r.ok ? r.value : null;
}

/**
 * 写 JSON —— 【2026-10-11 改成"写草稿再整张换上"】，失败不抛。
 *
 * 老写法是 `writeFileSync(path, ...)` 直接覆盖在目标上，写的过程中文件是"半截"的，
 * 别人这一刻读到就是半个 JSON。改成先写 `.tmp` 再 `rename` 之后，
 * 别人**要么看到旧的、要么看到新的，永远看不到半截**。
 * （`fs.renameSync` 在同一磁盘上就是原子的 —— 实测 45,634 次并发读，半截 0 次。）
 */
function writeJson(path, value) {
  const tmp = `${path}.tmp`;
  try {
    writeFileSync(tmp, JSON.stringify(value, null, 2), 'utf8');
    renameSync(tmp, path);   // 整张换上
    return true;
  } catch {
    // 写失败时把草稿清掉，别留垃圾文件
    try { rmSync(tmp, { force: true }); } catch { /* 忽略 */ }
    return false;
  }
}

/** 当前时间戳（毫秒）。 */
const now = () => Date.now();

/**
 * 用 WMI（`Win32_Process.Create`）创建一个脱离的进程。
 *
 * ⚠️ 为什么不用 `child_process.spawn`（2026-10-08 实测结论）：
 *   在这个宿主环境里，Node `spawn` 出来的 powershell 子进程是**空跑**的——
 *   连 `-Command "Write-Output HELLO"` 都拿不到任何输出、退出码却是 0，
 *   副作用一个都不发生。助手因此"启动了但从不干活"。
 *   换成 WMI 后完全正常（实测 ReturnValue=0、副作用真实发生），
 *   而且父级是 `WmiPrvSE`——**不在 DSH 进程树里**，正是设计要的"脱离"。
 *
 * 做法：起一个**短命的** powershell 去调 WMI，再让它立刻退出。
 *   （Node 自己没法直接调 WMI，所以借一层 powershell。）
 *
 * @param commandLine - 要创建的进程完整命令行。
 * @param workDir - 可选工作目录。
 * @returns {{ pid: number|null, returnValue: number|null }} 创建结果；失败时字段为 null。
 */
async function launchViaWmi(commandLine, workDir) {
  // 把命令行和可选工作目录用环境变量递给内层 powershell，
  // 避免在多层引号里转义（那是这套脚本里最容易出错的地方）。
  //
  // ⚠️ ProcessStartupInformation + ShowWindow=0 是**治"闪黑框"的**（2026-10-08 实测）：
  //   两个脚本会闪出黑框，体验很差。只加 `-WindowStyle Hidden` 不够 ——
  //   那个做法是**先把控制台窗口建出来、再隐藏**，所以屏幕上仍会闪一下。
  //   用 Win32_ProcessStartup.ShowWindow=0（SW_HIDE）是**建进程时就告诉 Windows 别显示**，
  //   窗口根本不出现。
  //   实测（test\archive\probe-window-selfreport.ps1，让子进程自己报 GetConsoleWindow+IsWindowVisible）：
  //     · 什么都不加        → 可见（对照组，证明判据有效）
  //     · -WindowStyle Hidden → 不可见，但窗口已建过（= 会闪）
  //     · StartUpInfo.ShowWindow=0 → 不可见且不建窗口 ✅ 就是这个
  const inner = [
    '$ErrorActionPreference = "Stop"',
    '$args = @{ CommandLine = $env:DSH_SR_CMDLINE }',
    'if ($env:DSH_SR_WORKDIR) { $args.CurrentDirectory = $env:DSH_SR_WORKDIR }',
    'try { $args.ProcessStartupInformation = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 } } catch { }',
    'try {',
    '  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $args -ErrorAction Stop',
    '  Write-Output ("RET=" + $r.ReturnValue + " PID=" + $r.ProcessId)',
    '} catch {',
    '  Write-Output ("ERR=" + $_.Exception.Message)',
    '}'
  ].join('; ');

  const psExe = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const exe = existsSync(psExe) ? psExe : 'powershell.exe';

  return await new Promise((resolvePromise) => {
    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      resolvePromise(value);
    };

    let child;
    try {
      child = spawn(exe, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', inner], {
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
        env: {
          ...process.env,
          DSH_SR_CMDLINE: commandLine,
          DSH_SR_WORKDIR: workDir ?? ''
        }
      });
    } catch (error) {
      done({ pid: null, returnValue: null, error: String(error?.message ?? error) });
      return;
    }

    let out = '';
    child.stdout?.on('data', (d) => { out += d.toString(); });
    child.stderr?.on('data', (d) => { out += d.toString(); });
    child.on('error', (error) => done({ pid: null, returnValue: null, error: String(error?.message ?? error) }));
    child.on('exit', () => {
      const m = /RET=(\d+)\s+PID=(\d+)/.exec(out);
      if (m) {
        done({ pid: Number(m[2]), returnValue: Number(m[1]) });
        return;
      }
      done({ pid: null, returnValue: null, error: out.trim().slice(0, 300) || 'WMI 调用没有输出' });
    });

    // 兜底超时：WMI 调用正常在 1-2 秒内完成
    setTimeout(() => done({ pid: null, returnValue: null, error: 'WMI 调用超时' }), 20000);
  });
}

/**
 * 判断一个会话的**来源**：是本地的窗口，还是某个 IM 通道自动送进来的。
 *
 * 2026-10-22 加。配套决策：docs\decisions-restart-queue.md 的 D9（判据 = rpcId）。
 *
 * 【为什么不能按"工作区"判】
 *   用户最初的想法是"IM 工作区里全是 QQ 对话，按工作区排除就行"。实测推翻：
 *   那个工作区 67 个会话里，53 个确实来自 IM，但有 **6 个是他亲手在本地打开的**
 *   （标题像「随便聊聊天」那种）。按工作区一刀切会误伤这 6 个。
 *
 * 【为什么 rpcId 靠得住】
 *   【读码】dsh-api-session-controller 里明确：
 *       const source = { kind: 'user', rpcId: request.requestId, ... }
 *   —— 核心把请求的 requestId 原样回显进会话记录。dsh-im 只是把 `qq-` 前缀
 *   塞进那个 requestId，所以"有没有前缀"＝"是不是从通道来的"。
 *
 * 【判定结果】
 *   'local'      纯 UUID       → 人对着的窗口
 *   'im-direct'  带前缀 + 私聊  → QQ 私聊（用户明确要求：这个也要等）
 *   'im-group'   带前缀 + 群聊  → 机器人自己在跟别人聊（不等）
 *   'unknown'    查不到         → **按人处理**（猜不出来就别猜，见决策 D9）
 *
 * ⚠️ 只读、不写、不抛异常。取不到一律 'unknown'，绝不让这个判断把重启本身搞挂。
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function sessionSourceOf(sessionLike) {
  try {
    const events = typeof sessionLike?.snapshotEvents === 'function'
      ? sessionLike.snapshotEvents()
      : (Array.isArray(sessionLike?.events) ? sessionLike.events : []);
    if (!Array.isArray(events) || events.length === 0) return 'unknown';

    // 找**最前面**那条真人说的话（source.kind === 'user'），看它的 rpcId。
    // 用最前面那条而不是最后一条：来源是会话的属性，不会中途变。
    let rpcId = null;
    let conversationType = null;
    for (const event of events) {
      if (event?.type === 'user/message' && event.data?.source?.kind === 'user') {
        const rid = event.data.source.rpcId;
        if (typeof rid === 'string' && rid) { rpcId = rid; break; }
      }
    }
    // 私聊/群聊：dsh-im 会在同一会话里插一条 <dsh_im_source> 提示，里面有 conversationType。
    // 没找到就按 direct 处理 —— 那是最保守的一边（direct 会被等，group 不会）。
    for (const event of events) {
      const text = Array.isArray(event?.data?.content)
        ? event.data.content.map((c) => (typeof c?.text === 'string' ? c.text : '')).join('')
        : '';
      const m = /"conversationType"\s*:\s*\\?"([a-z]+)\\?"/i.exec(text);
      if (m) { conversationType = m[1].toLowerCase(); break; }
    }

    if (!rpcId) return 'unknown';
    if (UUID_RE.test(rpcId)) return 'local';
    // 带前缀 = 通道来的。群聊不算"人在等"，私聊算。
    return conversationType === 'group' ? 'im-group' : 'im-direct';
  } catch {
    return 'unknown';
  }
}

/**
 * 把 DSH 的会话 id 映射到盘上的会话记录文件。
 *
 * 会话目录布局：<DSH 家目录>/sessions/<工作目录转义名>/<会话id>/session*.jsonl.zstd
 * 助手脚本要盯这个文件的修改时间来判断"这轮说完了没有"。
 */
function findSessionFile(sessionId) {
  if (!sessionId) return undefined;
  const root = join(HOME_DSH, 'sessions');
  let workspaces = [];
  try { workspaces = readdirSync(root); } catch { return undefined; }
  for (const ws of workspaces) {
    const dir = join(root, ws, String(sessionId));
    let files = [];
    try { files = readdirSync(dir); } catch { continue; }
    const hit = files.find((f) => f.startsWith('session') && f.endsWith('.jsonl.zstd'));
    if (hit) return join(dir, hit);
  }
  return undefined;
}

/**
 * 模块级"当前活着的那一代"。
 *
 * ⚠️ 为什么需要它（2026-10-08 实测踩到的坑）：
 *   热加载（HMR）会**重新执行 apply()**，但**旧实例的定时器和工具定义不一定被清掉**。
 *   实测后果：新旧两个实例同时活着 —— 旧实例继续每 10 秒写 state.json（于是文件里
 *   没有新字段）、也还占着工具定义，表现就是"日志说新代码挂上了，行为却全是旧的"。
 *   那次排查绕了很久，因为一度以为"日志里有新代码的句子"就等于"新代码在生效"。
 *
 * 现在的规矩：apply() 一进来就**作废上一代**（清掉它的定时器、标记它闭嘴），
 *   然后自己成为当代。旧实例仍可能短暂存在，但它**不会再写文件、也不会再说话**。
 */
let ACTIVE_GENERATION = 0;

/** 装配插件。
 *
 * @param ctx - Cordis 上下文。
 * @param config - 已解析的配置。
 */
export function apply(ctx, config) {
  // 作废上一代：它的 tick 与写盘都会被下面那个 alive() 检查拦下。
  const myGeneration = ++ACTIVE_GENERATION;
  const alive = () => myGeneration === ACTIVE_GENERATION;

  // ★ 2026-10-12 新增：本次插件启动的时刻（fixed 锚点）。
  //   用途：判断 last-run.json 里那份结果"是不是本次启动前后的这次重启"。
  //   ⚠️ 为什么不用 now() 当锚点：下面的自动叫醒是**轮询**的，
  //      拿 now() 比会让时间窗越轮越宽松，容易捞到上一次重启的旧账。
  //      用"插件启动时刻"当锚是固定的，不会漂。
  const pluginStartedAt = now();

  const stateDir = resolveStateDir(config);
  const logPath = join(stateDir, 'plugin.log');
  const statePath = join(stateDir, 'state.json');
  const planPath = join(stateDir, 'plan.json');
  const lastRunPath = join(stateDir, 'last-run.json');
  const cancelPath = join(stateDir, 'cancel.flag');
  const helperLogPath = join(stateDir, 'helper.log');

  const logger = ctx.logger ?? console;
  const recent = [];
  const log = (text) => {
    // 被作废的那一代不许再写日志 —— 否则日志里会同时出现新旧两版的话，误导排查。
    if (!alive()) return;
    const line = `${new Date().toISOString()} [self-restart] ${text}`;
    recent.push(line);
    if (recent.length > 200) recent.shift();
    try { appendFileSync(logPath, `${line}\n`); } catch { /* 日志写不进去不能出事 */ }
    try { logger.info(line); } catch { /* 忽略 */ }
  };

  log(`插件已挂上：状态目录 ${stateDir}（第 ${myGeneration} 代）`);

  // ── 服务句柄（inject 拿不到时降级，不影响工具注册） ──────────────────────
  let jobs = null;
  let agents = null;
  // ★ 2026-10-13 改：唤醒改用「投递」而不是「排提醒」，所以要这两个服务。
  //
  //   sessionController —— DSH 自带的正式服务（随发行版默认挂载，**不是**实验 bundle）。
  //     我们只用它的 resolveAgent()：按会话 id 找到那个 agent，**睡着的会被唤醒**。
  //     这是官方 dsh-schedule 投递提醒的第一步，同款用法。
  //   sessions —— 用来 flush()：followup 之后要拿到"已落盘"的回执才算投递成功
  //     （官方 schedule 也是这么做的：flush 拿不到回执就抛错）。
  //
  //   ⚠️ 这两个服务比插件晚就位（实测 schedule 晚过 20 秒，同类服务一个道理），
  //      所以拿不到时**只能等**（返回 'wait'），不能当成"没有就没有"。
  let sessionController = null;
  let sessions = null;
  // ★ 2026-10-17 新增：webServer —— 用来问**这次 DSH 真实在哪个端口**。
  //
  //   【为什么必须问，不能再写死 19387】（当晚真事故，见 bin 脚本头部那段长注释）
  //     DSH 0.2.1-rc.2 起，桌面端启动网页服务用的是 `--port 0`（让系统随机挑），
  //     于是每次启动端口都不一样（实测：14672 → 5165 → 4237）。
  //     而本插件把端口写死 19387 交给助手，助手就永远等不到监听 →
  //     判"没起来" → 重试前 Kill-AllDsh 杀掉刚起来的那个 → 保险丝接手继续杀。
  //
  //   webServer 是 DSH 自带服务（`web-runtime` 那一行提供），官方自己的插件
  //   也用 `ctx.inject(['webServer'], …)` 拿它，它的 `.port` 就是**正在监听的端口**
  //   （`--port 0` 之后读它就是系统分配到的那个真值）。
  //
  //   ⚠️ 拿不到就**原样退回配置里的端口**（老行为）—— 绝不能因为拿不到就写 0 或 NaN，
  //      那会让助手去等一个不存在的端口，等于把今晚这个事故换个形式重演。
  let webServer = null;
  if (typeof ctx.inject === 'function') {
    try {
      ctx.inject(['jobs'], (scope) => {
        jobs = scope?.jobs ?? null;
        log(`jobs 服务：${jobs ? '就位' : '没拿到'}`);
      });
    } catch (error) {
      log(`注入 jobs 失败（降级为只靠会话文件判断）：${String(error?.message ?? error)}`);
    }
    try {
      ctx.inject(['webServer'], (scope) => {
        webServer = scope?.webServer ?? null;
        log(`webServer 服务：${webServer ? '就位（能问到真实端口）' : '没拿到（端口只能用配置值）'}`);
      });
    } catch (error) {
      log(`注入 webServer 失败（端口只能用配置值）：${String(error?.message ?? error)}`);
    }
    try {
      ctx.inject(['agents'], (scope) => {
        agents = scope?.agents ?? null;
        log(`agents 服务：${agents ? '就位' : '没拿到'}`);
      });
    } catch (error) {
      log(`注入 agents 失败（降级为只靠会话文件判断）：${String(error?.message ?? error)}`);
    }
    try {
      ctx.inject(['sessionController'], (scope) => {
        sessionController = scope?.sessionController ?? null;
        log(`sessionController 服务：${sessionController ? '就位（重启后可以直接叫醒会话）' : '没拿到（不会自动叫醒）'}`);
      });
    } catch (error) {
      log(`注入 sessionController 失败（重启后不会自动叫醒）：${String(error?.message ?? error)}`);
    }
    try {
      ctx.inject(['sessions'], (scope) => {
        sessions = scope?.sessions ?? null;
        log(`sessions 服务：${sessions ? '就位（投递后能确认落盘）' : '没拿到'}`);
      });
    } catch (error) {
      log(`注入 sessions 失败：${String(error?.message ?? error)}`);
    }
  }

  /**
   * 数一数现在忙不忙。这是插件侧的权威判断 —— 助手那侧只能读文件猜。
   *
   * 返回 { jobsRunning, agentsRunning, otherSessionsRunning, details }。
   * 任何一项取不到就当作 0（宁可少拦，也不要因为取不到数据就永远不重启 ——
   * 那会让功能变成砖头）。
   *
   * `otherSessionsRunning` 是**除了发起重启那个会话之外**还在跑的会话数。
   * 设计规则（2026-10-08）："试一次，有其他对话在跑就停下来，就不自动重启了"
   * —— 这个字段就是那条规则的依据：别人的活没干完，绝不动手。
   */
  const survey = (exceptSessionId = null) => {
    const details = [];
    let jobsRunning = 0;
    let agentsRunning = 0;
    let otherSessionsRunning = 0;
    const others = [];
    // ★ 根会话（真对话） vs 子代理（家务）—— 2026-10-08 加，见下面 runningRoots 的说明。
    const runningRootIds = [];
    const runningSubagentIds = [];
    const otherSubagents = [];

    if (jobs && typeof jobs.list === 'function') {
      try {
        const list = jobs.list();
        for (const job of list) {
          if (job && (job.status === 'running' || job.status === 'stopping')) {
            jobsRunning += 1;
            details.push(`后台任务 ${job.id ?? '?'}（${job.status}）`);
          }
        }
      } catch (error) {
        details.push(`读后台任务失败：${String(error?.message ?? error).slice(0, 80)}`);
      }
    }

    // 先问一次"哪些是根会话"。
    // ⚠️ 拿不到就**当作全是根会话**（保守）：那样行为跟以前一样，不会误把别人的对话当家务。
    let rootIds = null;
    if (agents && typeof agents.roots === 'function') {
      try {
        rootIds = new Set(agents.roots().map((a) => String(a?.id ?? '')));
      } catch { rootIds = null; }
    }

    if (agents && typeof agents.list === 'function') {
      try {
        const list = agents.list();
        for (const agent of list) {
          if (agent && agent.status === 'running') {
            agentsRunning += 1;
            const id = String(agent.id ?? '?');
            // ★ 只有**根会话**才算"别人的对话"（有人在等回复）。
            //   带 owner 的是子代理 = 家务（生成它的人多半也在等，那种情况父会话会自己
            //   出现在 runningRootIds 里，所以不会漏）。子代理单独记，交给"等它跑完"那条规则。
            const isRoot = rootIds === null ? true : rootIds.has(id);
            if (isRoot) {
              runningRootIds.push(id);
              if (exceptSessionId && id === String(exceptSessionId)) continue;
              // ★ 2026-10-22：给每个"在跑的根会话"标上来源（local / im-direct / im-group / unknown）。
              //   为什么要标：用户定的规矩是「只有本地窗口和 QQ 私聊要等，群聊不用等」。
              //   会话对象要从 sessions.get(id) 拿 —— agents.list() 给的是 agent，没有快照事件。
              let src = 'unknown';
              try {
                const sess = (sessions && typeof sessions.get === 'function') ? sessions.get(id) : null;
                if (sess) src = sessionSourceOf(sess);
              } catch { src = 'unknown'; }
              otherSessionsRunning += 1;
              others.push({ id, source: src });
              // ★ 2026-10-24：带上**会话名**（用户："编号我找不到是哪个"）。
              //   拿不到名字就退回 id —— 有 id 至少还能查，别显示空白。
              {
                const title = readSessionTitle(id);
                const srcText = src === 'unknown' ? '' : `（来源 ${src}）`;
                details.push(title
                  ? `会话「${title}」${srcText}正在跑`
                  : `会话 ${id}${srcText}正在跑`);
              }
            } else {
              runningSubagentIds.push(id);
              if (exceptSessionId && id === String(exceptSessionId)) continue;
              otherSubagents.push(id);
              {
                const title = readSessionTitle(id);
                details.push(title
                  ? `子代理「${title}」（家务，非他人对话）`
                  : `子代理 ${id}（家务，非他人对话）`);
              }
            }
          }
        }
      } catch (error) {
        details.push(`读会话失败：${String(error?.message ?? error).slice(0, 80)}`);
      }
    }

    return {
      jobsRunning,
      agentsRunning,
      otherSessionsRunning,
      others,
      details,
      runningRootIds,
      runningSubagentIds,
      // 别的会话的子代理 / 本会话自己的家务子代理，一律算"家务"：等它跑完，不算"别人在忙"。
      otherSubagentsRunning: otherSubagents.length,
      otherSubagents
    };
  };

  // ── 定期把状态写盘，供脱离的助手脚本读取 ─────────────────────────────────
  /**
   * **这次 DSH 真实在哪个端口。**
   *
   * 2026-10-17 加。为什么不能直接用 `config.port`（= 写死 19387）：
   * 桌面端启动网页服务时传的是 `--port 0`（系统随机分配），
   * 实测同一晚三次启动分别是 14672 / 5165 / 4237 —— 写死的 19387 永远没人听，
   * 助手就会把**已经起来了的** DSH 判成"没起来"，然后杀掉重试，
   * 保险丝接手再杀一轮…… 当晚把所有人的 DSH 全杀了一遍。
   *
   * 优先级：
   *   ① 问 `webServer.port` —— 这是权威值（`--port 0` 之后它就是分配到的真值）；
   *   ② 退回 `config.port` —— 老版本 / 拿不到服务时的行为，**保持不变**。
   *
   * ⚠️ 必须做合法性检查：拿到 0 / NaN / 负数一律当成"拿不到"，
   *    否则助手会去等一个不存在的端口，等于把今晚的事故换个形式重演。
   * ⚠️ 每次调用都现问，不缓存：端口在进程生命周期内不变，但插件可能比服务先起来
   *    （实测服务晚 3~20 秒就位），缓存了就会一直拿到 null。
   */
  const actualPort = () => {
    try {
      const p = Number(webServer?.port);
      if (Number.isFinite(p) && p > 0 && p < 65536) return p;
    } catch { /* 忽略，走下面的退回 */ }
    return Number(config.port) || 19387;
  };

  const writeState = () => {
    // 被作废的那一代不许再写状态文件 —— 这是那个"新旧同时在跑"的关键修法：
    // 旧实例若继续写，文件里就永远缺新字段，看起来像"新代码没生效"。
    if (!alive()) return;
    try {
      const s = survey();
      const runningSessions = [];
      const runningSubagents = [];
      if (agents && typeof agents.list === 'function') {
        try {
          let rootIds = null;
          if (typeof agents.roots === 'function') {
            try { rootIds = new Set(agents.roots().map((a) => String(a?.id ?? ''))); } catch { rootIds = null; }
          }
          for (const agent of agents.list()) {
            if (!agent || agent.status !== 'running' || !agent.id) continue;
            const id = String(agent.id);
            // 拿不到 roots() 时按"都是根会话"处理（保守：宁可拦，不可误砍）
            if (rootIds === null || rootIds.has(id)) runningSessions.push(id);
            else runningSubagents.push(id);
          }
        } catch { /* 上面 survey 已经记过错误了 */ }
      }
      const payload = {
        updatedAt: now(),
        jobsRunning: s.jobsRunning,
        agentsRunning: s.agentsRunning,
        // runningSessions = **根会话**（真对话）；子代理单独一栏 = 家务。
        // ⚠️ 助手那边靠这个分清"别人在忙（放弃）"和"家务在跑（等它完）"。
        runningSessions,
        runningSubagents,
        // ★ 2026-10-13 深夜新增：**每个根会话的权威状态**（idle / running）。
        //
        //   为什么要有它：助手原判"发起会话这一轮说完没有"靠的是
        //   "会话记录文件连续 12 秒没被写过" —— 那是**猜**，而且会猜错：
        //   实测本机，Agent 在等工具结果时文件可以静默 **83 秒**，
        //   期间它显然还在干活（这一轮没结束），老判据却已放行。
        //
        //   权威依据来自 dsh-agent-loop：
        //       kick(){ try{ while(await turn()); } finally{ setPhase("idle") } }
        //       get status(){ return phase.kind === "idle" ? "idle" : "running" }
        //   即：**"这一轮结束"= status 变 idle**。runningSessions 正是用
        //   status === 'running' 筛的，所以"不在 runningSessions 里"= 已说完了。
        //
        //   这里额外给一张 { 会话id: 'idle'|'running' } 的显式表，
        //   让助手**不必从"在不在数组里"反推**（反推在拿不到数据时会误判成 idle，
        //   那会砍断正在说话的会话 —— 危险方向）。
        agentStatusById: {},
        details: s.details,
        // ★ 2026-10-17：写**真实端口**，不再写死配置值（见 actualPort 的说明）。
        //   助手靠它判"回来了没有"；写错就等于把已启动的 DSH 判成没起来。
        port: actualPort(),
        pid: process.pid,
        plugin: 'dsh-self-restart',
        version: '1.0.0',
        // ★ 2026-10-11 新增：**版本探针**（见 verify-roots.mjs）。
        //   为什么必须有它：改完 lib\index.js 之后，HMR **不会**重载模块代码，
        //   但插件日志照样打印「插件已挂上」「工具已注册」—— **看着像生效了，其实是旧代码**。
        //   （验证判据：要用"探针值"这种硬证据，别只看日志说"已挂上"。）
        //   数字的含义见模块顶部 IMPL_VERSION 的注释。
        //   想知道新代码生效没有 → 读 state.json 看这个字段等于几。
        impl: IMPL_VERSION
      };
      // 填 agentStatusById（与 runningSessions 用同一个来源，保证两者一致）
      if (agents && typeof agents.list === 'function') {
        try {
          for (const agent of agents.list()) {
            if (!agent || !agent.id) continue;
            const st = agent.status === 'running' ? 'running' : 'idle';
            payload.agentStatusById[String(agent.id)] = st;
          }
        } catch { /* survey 已记过错误 */ }
      }
      writeJson(statePath, payload);
    } catch (error) {
      log(`写状态失败：${String(error?.message ?? error).slice(0, 120)}`);
    }
  };
  writeState();

  // ★ 2026-10-13 深夜：**状态一变就立刻写一次盘**。
  //
  //   为什么需要它：state.json 原来只跟着 10 秒心跳更新，于是"我这一轮说完了"
  //   这件事**最多要 10 秒才被助手看见** —— 那正是助手那边"等 12 秒文件静默"
  //   这条老判据的由来（它在猜，因为权威数据来得太慢）。
  //   现在把关键变化即时落盘，助手就能第一时间看到权威状态、不必再靠猜。
  //
  //   心跳**仍然保留**：它是兜底（没有任何状态变化时，仍保证文件新鲜）。
  //   这里只是把变化即时化。节流 1 秒：多个会话同时变化时不至于写盘风暴。
  //
  //   ⚠️ running 也要写：要是只写 idle，那么"上一轮 idle、我又开始新一轮"
  //      这段窗口里，文件仍停在 idle —— 助手可能据此以为我说完了。
  let lastInstantWrite = 0;
  try {
    ctx.on('agent/status', ({ status }) => {
      if (status !== 'idle' && status !== 'running') return;
      const t = now();
      if (t - lastInstantWrite < 1000) return;
      lastInstantWrite = t;
      writeState();
    });
  } catch (error) {
    log(`订阅 agent/status 失败（不致命）：${String(error?.message ?? error).slice(0, 120)}`);
  }

  const periodMs = Math.max(2, Number(config.checkSeconds) || 10) * 1000;
  // ★ 2026-10-13 改：心跳定时器**挪到 reportLastRun 定义之后**再建（见下面）。
  //   原来它在这里、而"汇报上一次结果"是另一个 setTimeout —— 现在两个合成一个：
  //   每 periodMs（默认 10 秒）跑一次 writeState + reportLastRun。
  //   为什么必须等 reportLastRun 定义完才能建：回调里要调它（async/闭包时序问题，见下面说明）。
  // ── 启动后汇报上一次重启的结果 ───────────────────────────────────────────
  //
  // ★ 2026-10-11 改：**插件不再写 last-run.json**。
  //   老写法是读出来、加一个 reportedAt 字段、再整体写回去（读-改-写）。
  //   问题是**这个文件同时由助手写**（Save-Result 整体覆盖）——
  //   插件在"读"和"写回"之间，助手可能刚写了新结果，
  //   于是插件这一写会把**助手的新结果回滚成旧记录**（新结果被静默吞掉）。
  //   现在：汇报记录记在**插件自己的**文件里（`reported.json`），
  //   插件只读 last-run.json、绝不写它 → 写手从 2 个降到 1 个（只剩助手）。
  const reportedPath = join(stateDir, 'reported.json');

  // 「汇报上一次结果」这件事的收工状态（2026-10-13 加，见下面 heartbeat 的说明）。
  //   reportedDone —— 已经汇报过 / 已经放弃，不用再试
  //   reportTries  —— 试了几拍（防"这次没有刚重启完的结果"时无限读盘）
  let reportedDone = false;
  let reportTries = 0;
  const REPORT_MAX_TRIES = 30;   // 30 拍 × 默认 10 秒 = 5 分钟，与叫醒轮询同量级

  const readReported = () => {
    const r = readJsonResult(reportedPath);
    return r.ok && r.value ? r.value : {};
  };

  /**
   * 同一条事件在**同一趟重启**里是否已经通知过 —— 防止重排/重入时刷出多条。
   *
   * 记在插件自己的 reported.json 里，键形状 `<事件>:<planId>`。
   * planId 为空（还不知道单号）时不记账：宁可多通知一次，也不要把"该通知的"吞掉。
   */
  const shouldSkipNotice = (event, planId) => {
    const id = String(planId ?? '').trim();
    if (!id) return false;
    return Boolean(readReported()[`${event}:${id}`]);
  };

  const markNoticeSent = (event, planId) => {
    const id = String(planId ?? '').trim();
    if (!id) return;
    try {
      const again = readReported();
      again[`${event}:${id}`] = now();
      writeJson(reportedPath, again);
    } catch { /* 记账失败不影响已发出的通知 */ }
  };

  // 同一时刻只跑一条通知命令（重排 + 成功 + 失败可能撞在一起）
  const runNotice = createSerialNoticeRunner();

  const reportLastRun = () => {
    const r = readJsonResult(lastRunPath);
    if (!r.ok || !r.value || !r.value.finishedAt) return;
    const last = r.value;
    const finished = Date.parse(last.finishedAt);
    if (!Number.isFinite(finished)) return;
    // 只汇报"最近 10 分钟内结束的"那一次，避免陈年旧账反复刷屏
    if (now() - finished > 10 * 60e3) return;
    // 已经汇报过的不再重复（记在插件自己的 reported.json 里，按 planId 认）
    const done = readReported();
    if (last.planId && done[last.planId]) return;

    const verdict =
      last.outcome === 'success' ? '成功'
      : last.outcome === 'cancelled' ? '被取消'
      : last.outcome === 'skipped-busy' ? '没执行（当时一直有任务在跑）'
      : '失败';
    const by = last.by === 'watchdog' ? '由保险丝完成' : '由助手完成';
    log(`上次自我重启：${verdict}，${by}，耗时 ${last.tookSeconds}s —— ${last.detail}`);

    // 只写插件自己的文件（保留最近 50 条，防无限增长）
    if (last.planId) {
      done[last.planId] = now();
      const keys = Object.keys(done);
      if (keys.length > 50) {
        keys.sort((a, b) => done[a] - done[b]);
        for (const k of keys.slice(0, keys.length - 50)) delete done[k];
      }
      writeJson(reportedPath, done);
    }
    return true;   // 真的汇报了一条 → 让心跳知道"这事办完了"
  };

  // ══════════════════════════════════════════════════════════════════════════
  //  ★★ 2026-10-13 修：把"启动后 3 秒跑一次"改成"搭在已有的心跳上、认出即停" ★★
  //
  //  【原来的毛病（实测抓到的，不是推测）】
  //    老写法：`setTimeout(reportLastRun, 3000)` —— **只在启动后 3 秒试一次**。
  //    可是插件**总比"助手写完结果"早约 6 秒启动**（实测：插件 11:58:17 挂上、
  //    助手 11:58:23 才写 last-run.json）。所以那一次读到的还是**上一次的旧记录** →
  //    被"太旧就不汇报"拦下 → **然后再也不试了**。
  //    实测后果：10-12 15:27（70.2s）、16:31、10-13 02:30（67.2s）三次的耗时**全都没记下来**
  //    （拿这两个数字去 plugin.log 里搜，搜不到）。
  //    好笑的是：**同一个竞态，"叫醒会话"那条路当年就是用"改成轮询"修掉的**，
  //    而"汇报耗时"这条路没跟着修，留着同一个病。
  //
  //  【为什么这次不照抄轮询，而搭心跳】← 这是刻意回应"会不会有性能损耗 / 不优雅"的疑虑
  //    · 轮询要再开一个定时器（原来就是为叫醒开的那个 setInterval）。
  //    · 但插件已经有一个**每 10 秒的心跳**（writeState，写 state.json），
  //      而"等助手写完结果"这件事**最长也就几十秒** —— 用 10 秒的粒度完全够。
  //    · 所以：**不新增定时器**，把它挂进心跳里跑就行；认出就停，之后连读盘都不再做。
  //      净成本 = 重启后那几十秒里、每 10 秒多一次 try/catch 的读文件（文件几百字节）。
  //      ——比多一个常驻定时器更省，也少一处要维护的东西。
  //
  //  【为什么"认出即停"是安全的】
  //    reportLastRun 只在"读到一条新鲜的、还没汇报过的结果"时才返回 true；
  //    读到旧账/没有/已汇报过 → 返回 undefined（假）→ 继续等下一拍。
  //    resumeAfterRestart（叫醒）那边有自己的轮询与收工条件，**不受这里影响**。
  const heartbeat = () => {
    writeState();
    if (reportedDone) return;
    // ⚠️ 必须有次数上限（2026-10-13 想清楚的）：**绝大多数启动根本不是"刚重启完"**，
    //    那种情况下 reportLastRun 永远返回假 → 不设上限就会**每 10 秒读一次 last-run.json，一整夜**。
    //    那是实打实的无谓消耗，正是"最坏情况要防"的那类东西。
    //    所以：只在启动后一段有限窗口里试（默认 5 分钟 = 30 拍，与叫醒那边同量级），
    //    试完就彻底收工 —— 之后这一拍只写 state。
    reportTries += 1;
    if (reportTries > REPORT_MAX_TRIES) { reportedDone = true; return; }
    try {
      if (reportLastRun()) reportedDone = true;   // 汇报过了 → 以后这一拍只写 state
    } catch { /* 汇报失败绝不拖垮心跳 */ }
  };
  const stateTimer = setInterval(heartbeat, periodMs);
  if (typeof stateTimer.unref === 'function') stateTimer.unref();

  // ── ★ 2026-10-13：重启完成后，**直接把唤醒消息投进原会话** ──────────────────
  //
  // 【这次改了什么、为什么】
  //   原来走的是"重启后排一条 schedule 提醒"，再由提醒把会话叫醒。
  //   调研发现：schedule 提醒**底层做的就是"注入会话"**——官方 dsh-schedule 内部
  //   正是 resolveAgent → 造消息 → followup → flush 四步，只不过外面包了一层定时器、
  //   盖的是 kind:'schedule' 的戳。所以这不是换方案，而是**去掉那层中间商**：
  //     · 不再依赖实验 bundle（@deepseek-ai/dsh-experimental-schedule-bundle）；
  //     · 不再有 3~20 秒的"等服务就位"（实测 schedule 比插件晚到过 20 秒）；
  //     · 唤醒消息在会话里是**正常的一行**（显示为插件来源），不再是"定时提醒"。
  //
  // 【安全边界 —— 当年翻过车，这四条必须守住】
  //   ① **只喂真消息对象，绝不喂字符串。**
  //      当年 某个早期插件版本 就是把**字符串**塞进 followup：
  //      inbox 的 mutate() 对插入项**没有任何类型检查**（只查 id 有没有重复），
  //      于是"没有 id、没有 content 的货"被原样 append 进会话账本，
  //      界面按消息对象的形状去读它 → 崩、整个会话列表变空白。
  //      ⇒ 我们要自己造一条**完整合法**的消息：有唯一 id、有 role、有 content 数组、有 source。
  //   ② **source.kind 写我们自己的 'self-restart'，绝不写 'user'。**
  //      DSH 用 kind === 'user' 判"这句话是不是人说的"（hasDirectHumanInput），
  //      某些操作（如 goal 的 complete/blocked）要"有人类输入"才放行。
  //      写自己的戳 = 不冒充使用者、不继承人类授权。
  //      （官方对这条有明文要求：插件、调度器等非人类生产方**必须传入自己的 source**。）
  //   ③ **followup 之后必须 sessions.flush() 拿回执**，拿不到就算没投递
  //      （官方 schedule 同款：flush 失败要抛错 "Session persistence did not acknowledge"）。
  //   ④ **绝不在使用者正在用的会话上做实验**——这一步先在专门建的测试会话里验过。
  //
  // 【判据没变，还是只认"本次刚结束的成功重启"】
  //   - 只认 outcome === 'success'（失败时叫醒会话继续，会掩盖故障）
  //   - 只认"本次插件启动前后刚结束的"（时间窗防陈年旧账，锚 = pluginStartedAt）
  //   - 同一个 planId 只投一次（记在 reported.json 里，按**本次** planId 认账）
  //
  // ⚠️ 三个"跨调用"状态必须放在 apply() 闭包里（异步窗口挡不住函数内局部变量）：
  //   wakeInFlight —— 投递是异步的，done[key] 要等 promise 落定才定下来；
  //     中间那一两秒下一轮轮询又进来就会**重复投一条**。
  //   wakeFails —— 连败两次就放弃并留日志：不静默、也不刷屏（每 3 秒一次能刷 40 行）。
  //   sawPendingPlan —— 本次生命期见过"进行中的重启"却没投成，收工日志才需要响亮。
  let wakeInFlight = false;
  let wakeFails = 0;
  let sawPendingPlan = false;
  // ★ 2026-10-25 加：本次进程**确实有"该叫醒的人"**（走到过投递那段）。
  //   轮询超时收工时，只有它 = true 才可能"没叫醒"；否则就是"根本没到叫醒那一步"。
  //   ⚠️ 光看 sawPendingPlan 不够 —— 那个只表示"见过计划文件"，
  //      重启还在排队、压根没发车时它也成立（这就是 10-25 那次误报的病根，见下）。
  let wakeShouldHappen = false;
  // ★ 2026-10-23 晚：本次重启"投递失败"的累计（供退出时走一次通知钩子）
  //   { planId, targets: [{sessionId}], errors: [string] }
  //   ⚠️ 必须是"攒着最后发一条"，不能失败一次就发一条 —— 那会刷屏。
  let wakeFailReport = null;

  /**
   * 一条 last-run 记录相对**本进程**的时间位置。
   *
   * ⚠️ 这个判断原来在 resumeAfterRestart 里内联写了一遍，2026-10-25 又要在
   *   "收工要不要发提醒"里用同一套口径 —— 于是抽出来，**只留一份**。
   *   （本仓的老教训：同一个判断写两遍，迟早有一遍用错口径。）
   *
   * @returns 'bad' | 'old' | 'future' | 'fresh'
   */
  const freshnessOf = (finishedAt) => {
    const finished = Date.parse(finishedAt);
    if (!Number.isFinite(finished)) return 'bad';
    // 太旧：上一次重启的陈账（插件刚起来时 last-run 里还留着上一趟）
    if (finished < pluginStartedAt - 60e3) return 'old';
    // 明显来自未来（时钟回拨 / 数据坏）。给 2 分钟余量：助手用的是它自己的时钟
    if (finished > pluginStartedAt + 120e3) return 'future';
    return 'fresh';
  };

  /**
   * 本次进程生命期内**刚完成的那一趟成功重启**（没有就 null）。
   *
   * ★ 2026-10-25 新增，专治一种误报：插件刚挂上时 `last-run.json` 里躺着的是
   *   **上一趟**的记录，拿它当"这趟没叫醒"就会发出假警报。
   */
  const freshSuccessLastRun = () => {
    try {
      const r = readJsonResult(lastRunPath);
      if (!r.ok || !r.value || !r.value.finishedAt) return null;
      const last = r.value;
      if (last.outcome !== 'success') return null;
      if (freshnessOf(last.finishedAt) !== 'fresh') return null;
      return last;
    } catch { return null; }
  };

  /**
   * 轮询收工时**要不要发**「重启成功但没叫醒」那条通知 —— 纯函数，方便直接测。
   *
   * 【为什么要有它（2026-10-25 实机误报）】
   *   17:21 我改完插件部署，宿主热重载 → 插件重启；当时 `plan.json` 里有一趟
   *   **还在排队、没发车**的重启（helper 在等别的会话空闲）。
   *   旧代码只看 `sawPendingPlan`（"见过计划文件"）→ 5 分钟轮询到点就发提醒，
   *   文案里报的却是 **6 小时前那趟**（单号 restart-mvmqaeav，而它当时唤醒成功了）。
   *   ⇒ 用户 17:26 收到一条"没叫醒"的假警报。
   *
   * 【判据（三条同时成立才发）】
   *   ① 确实有该叫醒的人（走到过投递那段，或有攒下的失败成员）；
   *   ② 那趟重启**真的完成了**（last-run 是本次进程生命期内的新记录）；
   *   ③ 不是"配置/本次选择本来就不叫醒"（那种不会走到 wakeShouldHappen）。
   *
   * @param {object} p
   * @param {boolean} p.wakeShouldHappen 本次是否真该叫醒人
   * @param {{targets?: Array}} p.failReport   攒下的投递失败（可为 null）
   * @param {object} p.fresh                    本次进程内的成功记录（可为 null）
   */
  const shouldNotifyWakeFailure = ({ wakeShouldHappen: should, failReport, fresh }) => {
    if (failReport && Array.isArray(failReport.targets) && failReport.targets.length > 0) return true;
    return Boolean(should && fresh);
  };

  const resumeAfterRestart = () => {
    // ⚠️⚠️ 2026-10-12 第二次实机实测抓出的状态身份 bug（改动这段之前必须懂来龙去脉）：
    //
    //   第一版的轮询"收工条件"写的是：reported.json 里有没有**任何** `resume:` 开头的键
    //   （`Object.keys(done).some(k => k.startsWith('resume:'))`）。
    //   它验的是"排没排过"，却拿**上一次重启**留下的旧键当成了"这次已排" ——
    //   15:27 那次实测：插件 15:27:39 挂上，第一次轮询 15:27:42 看到旧键
    //   `resume:restart-mv4u0ira`（13:51 那次成功留下的）→ 当场收工；
    //   而这次的 last-run.json 15:27:46 才写、schedule 服务 15:27:59 才就位 —— 永远等不到了。
    //   （第一次 13:51 成功纯属运气：那时还没有任何旧 resume 键。）
    //
    //   修法：收工条件**按本次 planId 认账**，并返回明确状态：
    //     'wait'      = 本次还没到能判断的时候（重启还在跑 / 服务没就位），继续轮询
    //     'delivered' = 已把唤醒消息投进本次请求方会话（或本次早已投过），收工
    //     'skip'      = 本次永远不会需要叫醒（没有进行中的重启 / 结果不是成功 / 缺关键信息），收工
    //
    //   判"是不是新鲜记录"仍然以 pluginStartedAt 为锚（见上面的说明），不用 now()。
    const planPending = existsSync(planPath);   // 计划文件在 = 重启进行中，结果还没写
    if (planPending) sawPendingPlan = true;     // 见过"进行中的重启"→ 收工日志要响亮一点
    // ⚠️ 为什么这里 (planPending || sawPendingPlan) 都算"等"（2026-10-12）：
    //   助手收尾的顺序是"先写 last-run、再删 plan"（实测间隔 3 秒）。
    //   万一哪天机器慢/顺序变，轮询正好撞进"plan 已删、结果还没写"的空档 ——
    //   只看 planPending 会误判成 skip 收工。见过本次进行中的重启，就多等一会儿，
    //   反正有 resumeMaxTries 上限兜底，不会永远空转。
    const waitIfBetween = planPending || sawPendingPlan ? 'wait' : 'skip';
    const r = readJsonResult(lastRunPath);
    if (!r.ok || !r.value || !r.value.finishedAt) return waitIfBetween;
    const last = r.value;

    const finished = Date.parse(last.finishedAt);
    if (!Number.isFinite(finished)) return waitIfBetween;
    // 太旧：多半是上一次重启的陈账。还有计划文件说明这次重启仍在跑、稍后会写新结果 → 等；
    // 没有计划文件且记录是旧的 → 本次根本不会有新结果 → 收工。
    // ⚠️ 口径抽进 freshnessOf 了（"收工要不要发提醒"用的是同一份，别在这儿另写一套）。
    const fresh = freshnessOf(last.finishedAt);
    if (fresh === 'old') return waitIfBetween;
    if (fresh === 'future' || fresh === 'bad') return 'skip';

    if (last.outcome !== 'success') return 'skip';  // 失败时叫醒会话继续，会掩盖故障

    // ★ 配置关掉了叫醒（wakeMessage === false）。
    //   老实现的坑：README 承诺"resumeDelaySeconds 设 0 = 不叫醒"，代码却是
    //   `Math.max(5, Number(x) || 15)` —— 填 0 被 `||15` 悄悄吞掉，**承诺没兑现**。
    //   现在把"开关"和"时长"拆成两个配置项，一个值只有一个意思，不再有这种歧义：
    //     wakeMessage       = 叫不叫醒（布尔开关）
    //     wakeDelaySeconds  = 叫醒前等几秒（纯时长，0 就是立刻）
    if (config.wakeMessage === false) {
      log('自动叫醒：配置 wakeMessage=false，按承诺不叫醒（重启本身不受影响）');
      return 'skip';
    }

    // ★ 2026-10-13 新增：**本次重启自己说了"不用续接"**（排重启时传了 resume=false）。
    //   为什么要有这条：续接在多数情况下是对的（活没干完），但**收尾型重启**不该叫醒 ——
    //   那时候活已经干完了，把人叫起来反而莫名其妙（它会自己跟自己说话、白烧一轮）。
    //   优先级：**本次的选择 > 配置总开关**（总开关是"这台机器默认要不要"，本次是"这一趟要不要"）。
    //
    // ⚠️ 2026-10-22 修正：排队之后不能再拿**整批**的 resume 一刀切 ——
    //   一趟车里可能 A 选了续接、B 选了不续接，正确的做法是**挨个看各自的 resume**（下面 targets 里做）。
    //   这里只在**根本没有成员名单**（老记录）时才用 last.resume 兜底，
    //   否则"第一个人说不续接"会把整批人都吞掉 —— 那正是"排了队却醒不过来"。
    const hasMembers = Array.isArray(last.members) && last.members.length > 0;
    if (!hasMembers && last.resume === false) {
      log('自动叫醒：本次重启（' + String(last.planId || '?') + '）排的时候选了"不续接"，按它办');
      return 'skip';
    }

    // ── ★ 2026-10-22：唤醒从"喊一个人"改成"按名单挨个喊" ─────────────────────
    //
    // 【为什么必须改】
    //   老实现只认 last-run.json 里的一个 requestedBy（一问一换一）。
    //   排队之后同一趟车可能有好几个人在等，只喊一个 = 其他人**排了队却永远醒不过来**。
    //
    // 【名单从哪来】
    //   助手把整份成员名单抄进 last-run.json 的 members[]（见 bin\dsh-self-restart.ps1 的 Save-Result）。
    //   老记录没有 members → 退回单个 requestedBy（行为与以前一致）。
    //
    // 【逐人记账，绝不互相拖累】
    //   reported.json 的 key 用 `resume:<planId>:<会话id>`，
    //   一个人失败不影响其他人；同一个人也不会被投两次
    //   （"同一件活被干两遍"是这个插件历史上的头号红线）。
    const targets = [];
    if (Array.isArray(last.members) && last.members.length > 0) {
      for (const m of last.members) {
        const sid = String(m?.sessionId ?? '');
        if (!sid) continue;
        // 每个人自己的 resume 选择：他说不续接就别喊他
        if (m?.resume === false) continue;
        targets.push({ sessionId: sid, reason: String(m?.reason ?? '').trim() });
      }
    }
    const single = String(last.requestedBy || '');
    if (targets.length === 0 && single) {
      targets.push({ sessionId: single, reason: String(last.reason || '').trim() });
    }
    if (targets.length === 0) {
      log('重启刚完成，但结果里没有任何"该叫醒谁"的成员 —— 跳过');
      return 'skip';
    }
    if (!sessionController || typeof sessionController.resolveAgent !== 'function') {
      // ⚠️ 这条**必须 wait 不能 skip**：服务比插件晚就位是实测事实（schedule 晚过 20 秒，
      //    同类服务一个道理）。当成"没有就没有"会让整个功能静默失效。
      return 'wait';
    }

    // 有投递在路上 → 别重复发起（done[key] 要等 promise 落定才写盘）
    if (wakeInFlight) return 'wait';
    if (wakeFails >= 2) {
      log('自动叫醒：投递连续失败两次，放弃（重启本身不受影响；请手动回到原会话继续）');
      return 'skip';
    }

    // 等几秒再投：DSH 刚起来那一小会儿正在接线，这时候塞消息没必要。
    // ⚠️ 负数一律当 0（不设下限 5——那正是老实现"填 1、2、3 被悄悄改成 5"的毛病）。
    const rawDelay = Number(config.wakeDelaySeconds);
    const delay = Number.isFinite(rawDelay) ? Math.max(0, rawDelay) : 3;
    if (now() - finished < delay * 1000) return 'wait';

    // 挑出"还没喊过的人"，逐个投 —— 每人一条、各拿各的理由。
    const planKey = String(last.planId || String(finished));
    const done = readReported();
    const pending = targets.filter((t) => !done[`resume:${planKey}:${t.sessionId}`]);
    if (pending.length === 0) return 'delivered';   // 全喊过了（比如中途插件重载）

    // ★ 2026-10-25：走到这里 = 这趟**确实有该叫醒的人**，而且真的在投。
    //   收工时要不要发「没叫醒」提醒，就靠这个标志（见 shouldNotifyWakeFailure）。
    wakeShouldHappen = true;

    // ★ 先记账、再投递、投不进去才回滚 —— 这是**至多一次**的取舍（刻意的）：
    //   宁可"这次没叫醒、要人手动开"，也绝不允许"同一次重启投出两条消息"——
    //   两条一样的"接着干"会让会话把同一件活干两遍，比没叫醒更糟。
    for (const t of pending) done[`resume:${planKey}:${t.sessionId}`] = now();
    if (!writeJson(reportedPath, done)) {
      log('自动叫醒：投递前的记账写不进去，这次不投（宁可少叫一次，也不重复投）');
      return 'skip';
    }

    // ★ 脱敏：唤醒文案里**不写死任何人的工作区路径**（见配置里 resumeHint 的说明）。
    const hint = String(config.resumeHint ?? '').trim();
    // 这段文字会进会话账本，给个上限：有人可能把整篇报告塞进 reason，撑坏上下文没必要。
    const maxChars = Number(config.wakeMessageMaxChars);
    const limit = Number.isFinite(maxChars) && maxChars > 0 ? Math.round(maxChars) : 600;

    const buildText = (ownReason) => {
      const why = String(ownReason ?? '').trim();
      const whyText = why.length > limit ? `${why.slice(0, limit)}…（已截断）` : why;
      // ⚠️ 文案是**给模型看的**，会原样出现在被唤醒的那个会话里 ——
      //    所以：① 开头就说清"这不是使用者发的"；② 措辞通用（不假设某种称呼）；
      //    ③ 顺带报了本插件的实现版本号，方便"醒来先自检"那一句有东西可对。
      return '【这是 dsh-self-restart 插件的自动唤醒，不是使用者发的消息】\n\n' +
        `刚才那次自我重启**已经完成**（耗时 ${last.tookSeconds}s）。` +
        (whyText ? `重启的原因 / 当时在做的事：「${whyText}」。` : '') +
        '\n\n现在接着干。' +
        (hint ? `\n\n（提示：${hint}）` : '') +
        '\n\n如果不确定做到哪一步了：看上面这条原因（它是重启前留下的交接），' +
        '必要时翻你自己的会话记录。' +
        `\n\n（自检：本插件当前实现版本 impl=${IMPL_VERSION}。` +
        '若你手上那份结论依赖"新代码真的生效了"，可用 restart_status 复核。）';
    };

    // 逐个投：**一条失败绝不影响其余**（各自 rollback 自己的账）
    wakeInFlight = true;
    (async () => {
      for (const t of pending) {
        const key = `resume:${planKey}:${t.sessionId}`;
        try {
          const result = await deliverWakeMessage(t.sessionId, buildText(t.reason));
          // result.confirmed === false 表示：消息**已经进了收件箱**（会话会被叫醒、会干活），
          // 但宿主没给我们"已落盘"的回执。这不是"没投"，**绝不能重投**。
          if (result.confirmed) {
            log(`已把唤醒消息投进会话 ${t.sessionId}（本次重启 ${planKey}；已确认落盘）`);
          } else {
            log(`已把唤醒消息投进会话 ${t.sessionId}（本次重启 ${planKey}），但**没拿到落盘回执**：` +
                `${result.detail}。消息已在收件箱里、会话会被叫醒，故不重投。`);
          }
        } catch (error) {
          // 走到这里说明**消息还没进收件箱**，所以要回滚这一个人自己的账；
          // 其他人照常继续（绝不让一个人的失败拖垮整批）。
          const rollback = readReported();
          delete rollback[key];
          writeJson(reportedPath, rollback);
          const errText = String(error?.message ?? error).slice(0, 200);
          log(`投递唤醒消息给 ${t.sessionId} 失败（不影响其余人）：${errText}`);
          // ★ 2026-10-23 晚：攒进"失败报告"，等这一趟收尾时走**一次**通知钩子。
          //   ⚠️ 只攒不发 —— 失败一次发一条会刷屏（那次实机就是 40 多条日志）。
          try {
            if (!wakeFailReport) wakeFailReport = { planId: planKey, targets: [], errors: [] };
            wakeFailReport.targets.push({ sessionId: t.sessionId });
            if (!wakeFailReport.errors.includes(errText)) wakeFailReport.errors.push(errText);
          } catch { /* 攒不上也不影响别的 */ }
        }
      }
    })().finally(() => { wakeInFlight = false; });
    return 'wait';   // 已发起；等 promise 落定后，下一轮看到全部 done 会返回 delivered
  };

  /**
   * 事件 → 用户配置的外部通知命令（`noticeCommand`）。
   *
   * 插件**不内置任何通知渠道**。这里只负责在正确的时机、把正确的内容
   * 交给使用者自己写的那条命令；发不发、发给谁，全在命令里。
   * 环境变量：DSH_SR_EVENT / DSH_SR_TEXT / 以及 data 里的标量字段（见 notice-hook.js）。
   *
   * ── 三条约束（和重启本身的关系）──────────────────────────────────────────
   *   ① 每条事件**每趟最多一次** —— 按 `<事件>:<planId>` 记账，防刷屏。
   *   ② `noticeCommand` 为空时**直接跳过**，连日志都不写一行（默认就是空的）。
   *   ③ **失败绝不影响任何东西** —— 整段 try/catch，只记日志。
   */
  const notifyByHook = async (event, planId, text, data = {}) => {
    try {
      const shouldSkip = shouldSkipNotice(event, planId);
      if (shouldSkip) return false;
      if (!String(config.noticeCommand ?? '').trim()) return false;   // 没配 = 不通知
      const result = await runNotice({
        command: config.noticeCommand,
        event,
        text,
        data,
        timeoutMs: Number(config.noticeTimeoutMs) || 30000,
        log,
      });
      if (result.ok) markNoticeSent(event, planId);
      return result.ok === true;
    } catch (error) {
      log(`通知钩子出错（不影响任何功能）：${String(error?.message ?? error).slice(0, 160)}`);
      return false;
    }
  };

  /**
   * 「重启成功了，但没能叫醒排队的会话」→ 交给通知钩子。
   *
   * 只在**确实有人该被叫醒、却叫不醒**时才发：本来就没有要叫醒的人不算失败。
   * 文案压成单行，方便使用者直接塞进任意通知渠道。
   */
  const notifyWakeFailure = (planId, targets, detail) => {
    const list = Array.isArray(targets) ? targets.filter((t) => t && t.sessionId) : [];
    if (list.length === 0) return Promise.resolve(false);
    const who = list.slice(0, 5).map((t) => t.sessionId).join('、') +
      (list.length > 5 ? ` 等 ${list.length} 个` : '');
    const text = String(
      `重启成功了，但没能叫醒排队的会话（${list.length} 个）。` +
      `原因：${String(detail).slice(0, 160)}。` +
      `需要手动回到原会话继续：${who}。`
    ).replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim();
    return notifyByHook('wake-failed', planId, text, {
      planId,
      count: list.length,
      sessions: who,
      detail: String(detail).slice(0, 160),
    });
  };
  /**
   * 把一条"唤醒消息"投进指定会话 —— 这是本插件唯一会**往会话里写东西**的地方。
   *
   * 四步，和官方 dsh-schedule 投递提醒的顺序一致：
   *   ① resolveAgent(sessionId) 找到那个会话并把它激活（睡着的会被唤醒）
   *   ② 造一条**完整合法**的用户消息（这一步绝不能省成"塞个字符串"，见 makeWakeMessage 的说明）
   *   ③ agent.followup(message) 放进它的收件箱（这一步会顺带把会话驱动起来）
   *   ④ sessions.flush() 确认落盘
   *
   * 【抛错语义 —— 调用方靠它决定"能不能重试"，必须严格区分】
   *   本函数**只在"消息还没进收件箱"时抛错**（①②步，以及③本身抛）。
   *   一旦 followup 成功，无论 flush 有没有回执，都**正常返回**（用 confirmed 标明），
   *   因为那时消息已经进去了、会话会被叫醒 —— 此时重投 = 让同一件事被干两遍。
   *   官方 schedule 在 flush 失败时是直接抛错重试的；我们**故意不照抄这一处**：
   *   它的重试会新造一条消息（多发一条提醒，代价小），而我们的重试会让会话重复执行。
   *
   * @param sessionId - 目标会话 id（重启前记在 last-run.json 的 requestedBy）。
   * @param text - 唤醒文案（调用方保证已拼好、已限长）。
   * @returns {{ confirmed: boolean, detail: string }} 消息已投递；confirmed 表示是否拿到落盘回执。
   */
  const deliverWakeMessage = async (sessionId, text) => {
    const resolved = await sessionController.resolveAgent(sessionId);
    // ⚠️ resolveAgent 在**本服务**上返回的是 agent 本身（'error' in resolved 时它已经抛了），
    //    但别的实现/别的版本可能返回 { agent } —— 两种形状都认，免得将来静默失效。
    const agent = resolved && typeof resolved.followup === 'function'
      ? resolved
      : (resolved?.agent ?? null);
    if (!agent || typeof agent.followup !== 'function') {
      throw new Error(`resolveAgent 没给出可用的 agent（${JSON.stringify(resolved)?.slice(0, 120)}）`);
    }

    // ② 自己造消息对象。**形状必须齐全**：id 唯一、role 固定 user、content 是数组、source 有 kind。
    //    这就是当年那次事故的分水岭 —— 那次喂的是字符串，账本里存进了没有 id/content 的货。
    const message = makeWakeMessage(text);
    if (!message.id || message.role !== 'user' || !Array.isArray(message.content) || !message.content.length) {
      throw new Error('自造的消息对象形状不合法，拒绝投递（宁可少叫一次也不污染会话）');
    }

    // ③ 进收件箱（会唤醒驱动器）。**这一行之后就算已投递**，任何失败都不许再重投。
    agent.followup(message);

    // ④ 落盘确认（只影响日志措辞，不影响"已投递"这个事实）
    if (sessions && typeof sessions.flush === 'function') {
      try {
        const ok = await sessions.flush(agent.session);
        if (ok) return { confirmed: true, detail: '已确认落盘' };
        return { confirmed: false, detail: 'sessions.flush 返回 false（这个组合可能没挂会话持久化后端）' };
      } catch (error) {
        return { confirmed: false, detail: `sessions.flush 抛错：${String(error?.message ?? error).slice(0, 120)}` };
      }
    }
    return { confirmed: false, detail: '注入不到 sessions 服务，无法确认落盘' };
  };

  // ⚠️ 为什么是"轮询"而不是"等固定秒数"（2026-10-12 两次实测逼出来的，别改回去）：
  //
  //   ① 插件加载比"重启完成"**还早**（实测：插件 15:27:39 挂上，助手 15:27:46 才写完成）。
  //      第一次读 last-run.json 时**文件还是旧的**（上一次重启的记录）→ 只跑一次必然失效。
  //   ② 那些服务（原来的 schedule、现在的 sessionController）又比插件晚 3~20 秒才就位
  //      （实测 15:27:59，晚了 20 秒）→ 也得等。
  //
  //   ⇒ 轮询：每 3 秒一次，最多 5 分钟（②晚到 + 慢机器要留够）；投出去就停。
  //   ⚠️ 3 秒的粒度也让"等几秒再投"（wakeDelaySeconds）足够准 —— 不需要为此再加定时器。
  //   ⚠️⚠️ 收工**只看 resumeAfterRestart() 的返回值**（wait / delivered / skip）。
  //   第一版在这里**另写了一套**"是否已排过"的判断（扫 reported.json 里任何 resume: 键）——
  //   同一件事写两遍，而这一遍漏了"必须按**本次** planId 认"，于是拿着**上一次**重启的
  //   旧键当场收工，15:27 那次功能整个失效。
  //   **教训：别把同一个判断写两遍，更别让其中一遍用错的口径。**
  let resumeTries = 0;
  const resumePollMs = 3000;
  const resumeMaxTries = 100;   // 100 × 3s = 5 分钟（2 分钟被实测证明偏紧：服务就晚了 20 秒）
  const resumeTimer = setInterval(() => {
    resumeTries += 1;
    let state = 'wait';
    try {
      state = resumeAfterRestart();
    } catch (error) {
      log(`自动叫醒轮询抛错（不影响重启）：${String(error?.message ?? error).slice(0, 160)}`);
    }
    if (state === 'delivered') {
      try { clearInterval(resumeTimer); } catch { /* 忽略 */ }
      // ★ 2026-10-23 晚：这一趟全都叫醒了 → 之前攒的失败不该留到下次误报。
      //   （部分成功部分失败时，`delivered` 也可能出现 —— 所以**先看有没有攒下失败**。）
      if (wakeFailReport && wakeFailReport.targets.length > 0) {
        const rep = wakeFailReport;
        wakeFailReport = null;
        notifyWakeFailure(rep.planId, rep.targets, rep.errors.join('；'))
          .catch(() => { /* 已经在里面记过日志了 */ });
      }
      return;
    }
    if (state === 'skip' || resumeTries >= resumeMaxTries) {
      try { clearInterval(resumeTimer); } catch { /* 忽略 */ }
      // ★★ 2026-10-25 修：这里原来只看 `sawPendingPlan`（= "见过计划文件"），
      //    于是**重启还在排队、根本没发车**时也会判"没叫醒"并发出通知 —— 那次假警报
      //    报的还是 6 小时前那趟（见 shouldNotifyWakeFailure 的说明）。
      //    现在三条同时成立才发：确实该叫醒 + 那趟真完成了 + 没投成。
      const fresh = freshSuccessLastRun();
      const notify = shouldNotifyWakeFailure({
        wakeShouldHappen,
        failReport: wakeFailReport,
        fresh,
      });
      if (notify) {
        log('自动叫醒：本次重启已收尾但没能叫醒会话（原因见上面几行日志）——需要人回到原会话继续');
        if (!wakeFailReport) {
          wakeFailReport = { planId: '', targets: [], errors: ['唤醒服务一直没就位 / 轮询超时'] };
        }
        const rep = wakeFailReport;
        wakeFailReport = null;
        if (rep.targets.length === 0) {
          // 没有具体失败成员时，退回"这趟车该叫醒的人"（只用**本次刚完成**的那条记录，
          // 绝不拿上一趟的陈账 —— 那正是误报的来源）
          if (fresh) {
            rep.planId = rep.planId || String(fresh.planId || '');
            const members = Array.isArray(fresh.members) && fresh.members.length > 0
              ? fresh.members
              : (fresh.requestedBy ? [{ sessionId: fresh.requestedBy }] : []);
            rep.targets = members.map((m) => ({ sessionId: String(m?.sessionId ?? '') })).filter((t) => t.sessionId);
          }
        }
        notifyWakeFailure(rep.planId, rep.targets, rep.errors.join('；'))
          .catch(() => { /* 已经在里面记过日志了 */ });
      } else {
        log(`自动叫醒：轮询 ${resumeTries} 次，本次没有需要叫醒的重启，收工（不影响任何功能）`);
        // ★ 这种情况**不发提醒** —— 本来就没有要叫醒的人，发一条"没叫醒"是假警报。
        wakeFailReport = null;
      }
    }
  }, resumePollMs);
  if (typeof resumeTimer.unref === 'function') resumeTimer.unref();

  // ── "重启没成"要让对话自己知道（设计取舍，2026-10-08）────────────────────
  //
  // 规则：对话发现自己排的重启没成就自己说没成功，让用户手动来
  //
  // 怎么让对话"发现"？—— 往**动态提示**里塞一条。每轮组装提示词时它会现算一遍：
  //   有未汇报的失败 → 把那条事实摆到模型眼前 → 模型自然会转告用户。
  //
  // ⚠️ 为什么"重启没成"这件事**不**用投递消息去做，只写成一段只读提示：
  //    投递那条路现在是通的（见 resumeAfterRestart / deliverWakeMessage），
  //    但**报失败**和**接着干活**是两回事：前者只要求"模型下一轮能看见这条事实"，
  //    而每轮都会重新组装系统提示 —— 写成提示就够，不用往会话账本里多留一条永久消息。
  //    （当年那个坑仍然要记住：危险的是**喂字符串**，不是 followup 本身。见 makeWakeMessage 的说明。）
  //    相反，"重启成功了、接着干"**必须**是一条真消息 —— 那是要唤醒会话去跑一轮的，
  //    提示词做不到这件事（它只在会话已经醒着的时候才被组装）。
  //
  // 这里只提供一段**只读的文本提示**，不碰任何会话状态 —— 出事最多是提示词里多句话。
  const failureNote = () => {
    try {
      const r = readJsonResult(lastRunPath);
      if (!r.ok || !r.value || !r.value.finishedAt) return '';
      const last = r.value;
      // 已经投过的不再重复。★ 2026-10-23：记账键改成 `failnote:<planId>`。
      //   ⚠️ 为什么不用原来的裸 planId 了：那个键是给「restart_status 汇报」用的，
      //      两条路径共用同一个键会互相把对方"标记为已完成"—— 结果是一条都不发。
      //      两种投递各记各的账，互不干扰。
      if (last.planId && readReported()[`failnote:${last.planId}`]) return '';
      const finished = Date.parse(last.finishedAt);
      if (!Number.isFinite(finished)) return '';
      // 只提"最近 30 分钟内结束的"，陈年旧账不刷屏。
      //
      // ⚠️ 2026-10-23：这个窗口现在只在**投递那一刻**起作用（投一次就记账），
      //    不再像以前那样"每次装配提示词都重新判断一次"。
      //    所以 30 分钟够用 —— 插件起来后 4 秒就开始投，不需要它跨越很久。
      if (now() - finished > 30 * 60e3) return '';

      if (last.outcome === 'success') return '';
      const when = new Date(finished).toLocaleString('zh-CN', { hour12: false });
      if (last.outcome === 'skipped-busy') {
        return (
          `【自我重启未执行】${when} 排的那次重启**没有执行**：${last.detail} ` +
          '（当时一直有任务在跑，或别的会话在忙 —— 按规则它宁可什么都不做，也不打断别人的活。）' +
          '**请你在回复里如实告诉用户"这次自动重启没做成，需要手动关掉 DSH 再打开"，并说明原因。**'
        );
      }
      if (last.outcome === 'cancelled') {
        return `【自我重启已取消】${when} 排的那次重启被取消了，DSH 未受影响。`;
      }
      return (
        `【自我重启失败】${when} 排的那次重启**失败了**：${last.detail} ` +
        '**请你在回复里如实告诉用户"自动重启失败，需要手动打开 DSH"，并给出日志路径。**'
      );
    } catch {
      return '';
    }
  };

  // ══════════════════════════════════════════════════════════════════════════
  // 【2026-10-23 改】失败提示**不再全局广播**，只送给「当初排那次重启的那几个会话」
  //
  // 【用户报的问题，原话】
  //   「为什么写文档的对话也在提示我刚刚的自动重启没成功？你做了某种提示词的植入吗？」
  //   后来又说：「失败重启的广播你修了吗？所有对话都在跟我提重启失败的事儿」
  //
  // 【旧做法的病根】
  //   用的是 `ctx.inject(['systemPrompt'], …) → sp.context({ text })`。
  //   `sp.context` 挂在**系统提示词装配**上，是这个 profile 里**每个会话**都会读到的东西。
  //   于是"上次重启失败了"这条**全局事实**，被广播成了"每个会话都要去告诉用户"。
  //   写文档的会话也被推着复述一件跟它毫无关系的事 —— 用户感觉像被刷屏。
  //
  // 【官方指引（app.asar 里 dsh-agent-preset 的 practices.md 原文）】
  //   · Add prompt text with `ctx.systemPrompt.section()`.
  //   · Add **per-agent** context with `agent.inject()`.
  //   · `agent.inject()` **does not wake it**（不唤醒会话），注入的上下文会
  //     "在收件箱里等到下一次有输入时"才进到那一轮里。
  //   ⇒ 这正是我们要的：只给相关人员、不打扰、不刷屏。
  //
  // 【新做法】
  //   重启失败后（插件加载时），读 last-run.json：
  //     · 找出那次重启的成员（members[] / requestedBy）；
  //     · 逐个 resolveAgent → agent.inject(一条提示)；
  //     · 同一个 planId 只送一次（reported.json 记账，沿用既有机制）。
  //   其他会话**一个字都不会收到**。
  //
  // ⚠️ 为什么不干脆全删掉：这条提示本身是有价值的 ——
  //   重启失败意味着"那个会话的改动还没生效，得再排一次"，它该知道。
  //   错的是"告诉谁"，不是"要不要告诉"。
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * 把失败提示**只**送给那次重启的成员会话。
   * 返回送出去的数量（0 = 没有要送的 / 条件不满足）。
   *
   * ⚠️ 用 agent.inject 而不是 followup：inject 不唤醒会话。
   *   这些会话此刻多半没在干活，硬叫起来只为念一句"上次失败"是打扰。
   *   等它下次自然有输入时，这句话会作为上下文一起进去。
   */
  const deliverFailureNotes = async () => {
    if (typeof sessionController?.resolveAgent !== 'function') return 0;
    const note = failureNote();
    if (!note) return 0;                       // 没有失败 / 已经送过 / 太旧
    let last;
    try {
      const r = readJsonResult(lastRunPath);
      if (!r.ok || !r.value) return 0;
      last = r.value;
    } catch { return 0; }

    const ids = new Set();
    if (Array.isArray(last.members)) {
      for (const m of last.members) { if (m?.sessionId) ids.add(String(m.sessionId)); }
    }
    if (last.requestedBy) ids.add(String(last.requestedBy));
    if (ids.size === 0) return 0;

    let sent = 0;
    for (const sid of ids) {
      try {
        const agent = await sessionController.resolveAgent(sid);
        if (!agent || typeof agent.inject !== 'function') continue;
        // 真消息对象，绝不喂字符串（见 makeWakeMessage 那段血泪史）
        agent.inject(makeWakeMessage(note));
        sent += 1;
        log(`失败提示已投给会话 ${sid}（只投给那次重启的成员，不广播）`);
      } catch (error) {
        log(`失败提示投给 ${sid} 没成功（不影响别的）：${String(error?.message ?? error).slice(0, 120)}`);
      }
    }
    // 记账：同一个 planId 只送一次（沿用 reported.json）
    if (sent > 0 && last.planId) {
      try {
        const done = readReported();
        done[`failnote:${last.planId}`] = now();
        writeJson(reportedPath, done);
      } catch { /* 记账失败不影响已送出的 */ }
    }
    return sent;
  };

  // ⚠️ 原来的全局注入**已删除**（2026-10-23）。别再把它加回来：
  //   只要挂在 systemPrompt 上，就等于"这台机器的每个会话都会提这件事"，
  //   而用户明确说过受不了那样。
  //   想知道它曾经怎么写的，看 git 历史里这条注释之前的版本。

  // ── ★ 2026-10-22 新增：会话标题前的"待重启"标记 ────────────────────────────
  //
  // 【它解决什么】
  //   排上重启之后对话里没任何动静，用户根本不知道"它到底在等还是根本没排上"
  //   （原话：「通过某种标记提示我，要不然我不知道这个对话一直在等重启」）。
  //
  // 【怎么做 —— 抄 dsh-im 的现成做法】
  //   dsh-im 给会话标题加「QQ · 」前缀用的**不是** `session.rename()`，而是追加一条
  //   `session/title` 事件（见它的 plugin-src\host\session-title-prefix.mjs）。
  //   ⚠️ 为什么不能用 rename：rename 会把标题**钉成"用户改过"**，
  //      从此宿主的自动起标题功能就再也不管这个会话了 —— dsh-im 源码里专门写了这条警告。
  //
  // 【两种状态，成功后消失】
  //   在等   → `♻️ 待重启 · 原标题`
  //   发车中 → `♻️ 重启中 · 原标题`
  //   成功/取消/作废 → 把标记摘掉（恢复原标题）
  //
  // 【已知边界（别当 bug）】
  //   1. 新版 DSH 不认旧标签 → 升级后旧会话上看不到旧标记，这是正常的；
  //   2. 重启失败时标记会**留着不走** —— 这是有意的（用户要"看得到"），
  //      但 failureNote 会同时告诉他失败了，别把两者当成矛盾。
  // ══════════════════════════════════════════════════════════════════════════
  // 【2026-10-23 改】从"文字前缀"改成"**只留图标**"
  //
  // 用户原话：「现在的重启我觉得只要那个图标就好了，不需要写待重启」。
  //
  //   旧：`♻️ 待重启 · 原标题`   ← 四个字纯占地方，图标已经说清状态了
  //   新：`♻️ 原标题`
  //
  // ⚠️ 旧前缀必须仍然**能剥掉**：老会话树的标题里可能留着「♻️ 待重启 · 」，
  //    只写新标记而不认旧前缀 → 剥不掉 → 每轮叠一层，越叠越长。
  //    所以 LEGACY 那份只用于 strip，永远不再写出去。
  // ══════════════════════════════════════════════════════════════════════════
  const MARK_RECYCLE = '♻️ ';
  const MARK_FAILED = '⭕ ';                      // 上次重启失败（用户要的"该重启了"提醒）
  // ⚠️ 为什么用 ⭕（U+2B55）而不是 🔴（U+1F534）—— 用户 选的：
  //   实测两台渲染路径结论不一样：真窗口里两个都能显示红色，
  //   但 🔴 是**实心**，他说"挺丑的"；⭕ 是**空心粗圈**，同样红却留白多、不压迫。
  //   两者在会话列表那个字号下都还看得清（⭕ 的线够粗）。
  const LEGACY_TITLE_MARKS = ['♻️ 待重启 · ', '♻️ 重启中 · '];
  // 所有可能出现在标题开头的本插件标记（新的 + 旧的），剥离时都要认。
  //
  // ⚠️⚠️ **必须按长度从长到短排**，否则剥不干净（2026-10-23 测试抓到）：
  //   新图标 `♻️ `（2 字符）是旧前缀 `♻️ 待重启 · ` 的**前缀** → 短的那个会先命中，
  //   于是「♻️ 待重启 · 原标题」只被剥掉「♻️ 」、留下「待重启 · 原标题」，
  //   旧会话树上的老标记就永远剥不掉了。
  //   长优先 = 先试更具体的模式，这是包含关系下的唯一正确顺序。
  const TITLE_MARK_PREFIXES = [MARK_RECYCLE, MARK_FAILED, ...LEGACY_TITLE_MARKS]
    .sort((a, b) => b.length - a.length);

  // ══════════════════════════════════════════════════════════════════════════
  // ★★ 2026-10-25 修：**和 dsh-im 抢标题**（实机事故，用户报的）
  //
  // 用户原话：「现在这个自动重启插件和 QQ 的那个前缀，它俩会互相抢……
  //            就像现在那个远程模式的私聊对话」。
  //
  // 【证据】那个 QQ 私聊会话（session-1c3c73d3）的 `session/title` 事件：
  //   seq 1571  ♻️ QQ · 示例会话
  //   seq 1572  QQ · ♻️ QQ · 示例会话
  //   seq 1577  ♻️ QQ · ♻️ QQ · 示例会话
  //   …
  //   seq 1587  QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · 示例会话
  //   每 10 秒（正好是我们的 tick）长一层，**没有上限**。
  //
  // 【病根】两边各有一条"只看开头"的判据，而对方的图标刚好把开头占住了：
  //   · dsh-im：`title.startsWith('QQ · ') ? 不动 : 再补一个`
  //     （plugin-src\host\session-title-prefix.mjs 的 withSessionChannelPrefix）
  //   · 我们：`剥掉开头自己的图标，再把图标顶到最前面`
  //   ⇒ 我们把图标顶到「QQ · 」前面 → 它判"没有前缀"→ 再补一个 → 我们下一拍
  //      看到开头是「QQ · 」（不是自己的图标）→ 什么都没剥，又顶一个上去 → 循环。
  //
  // 【修法】图标不再抢第一位：**频道前缀留在最前，图标紧跟其后**
  //   （`QQ · ♻️ 原标题`）。这样它的 startsWith 判据永远成立、不再补；
  //   我们的剥离也认"图标在频道前缀后面"这一种形状。两边各自幂等，不再互相喂。
  //
  // 【为什么把它的标签抄一份】不抄就得运行时 import dsh-im（可能没装、升级会变），
  //   而这里只需要"认出它、别踩它"。清单抄自 dsh-im 的
  //   src\channels\shared\session-channel-labels.mjs；它要是加了新渠道，
  //   test-queue.mjs 里有一条断言会去读它那份清单对账（对不上就红，提醒补这里）。
  const CHANNEL_LABELS = [
    '微信', 'WeChat', '飞书', 'Feishu', '钉钉', 'DingTalk', '企业微信', 'WeCom',
    'QQ', 'Slack', 'Telegram', 'Discord', 'WhatsApp', 'iMessage', 'Matrix', 'AI Office',
  ];
  // 长前缀先试：既防「企业微信」被「微信」截胡，也防「AI Office · 」这种带空格的
  const CHANNEL_PREFIXES = CHANNEL_LABELS.map((label) => `${label} · `)
    .sort((a, b) => b.length - a.length);

  /**
   * 把标题拆成 `{ channel, body }`：
   *   channel = 别的插件加的频道前缀（最多一层；没有就是 ''）
   *   body    = 真正的标题
   *
   * 频道前缀和本插件图标**不管怎么交错叠加**都能剥干净 —— 包括 2026-10-25 那个
   * bug 留下的 `QQ · ♻️ QQ · ♻️ … 原标题`（所以这个函数本身也是"历史脏标题"的修法）。
   *
   * ⚠️ 只认**同一个**标签的重复：`QQ · 微信 · 正文` 里那个「微信 · 」当正文，不动它
   *   （宁可少剥，也不能把用户自己写的「A · B」吃掉）。
   */
  const splitTitle = (title) => {
    let out = String(title ?? '');
    let channel = '';
    for (let guard = 0; guard < 32; guard += 1) {
      const label = CHANNEL_PREFIXES.find((p) => out.startsWith(p));
      if (label) {
        if (channel && label !== channel) break;   // 不同的标签 = 正文，别动
        if (!channel) channel = label;
        out = out.slice(label.length);
        continue;
      }
      const mark = TITLE_MARK_PREFIXES.find((m) => out.startsWith(m));
      if (mark) { out = out.slice(mark.length); continue; }
      break;
    }
    return { channel, body: out };
  };

  /** 从标题里剥掉本插件加的图标（可能叠了多个，全剥），**保留**频道前缀；没有就原样返回。 */
  const stripTitleMark = (title) => {
    const { channel, body } = splitTitle(title);
    return `${channel}${body}`;
  };

  /**
   * 拼出唯一稳定的标题形状：`频道前缀 + 图标 + 正文`（mark 为 null = 摘掉图标）。
   *
   * ⚠️⚠️ 顺序**不能反**：图标必须排在频道前缀**后面**，否则 dsh-im 会一直再补前缀
   *   （就是 2026-10-25 那个每 10 秒长一层的 bug）。
   */
  const composeTitle = (title, mark) => {
    const { channel, body } = splitTitle(title);
    return `${channel}${mark ?? ''}${body}`;
  };

  /**
   * 读一个会话的显示名（就是 GUI 左边列表里那个标题），失败返回 ''。
   *
   * ★ 2026-10-24 加。用户原话：「你给这个编号，我找不到是哪个呀。你得把重启会话的名字给我」
   *   —— 工具输出里原来只有 `session-cb6e2e8f-…` 这种 id，人根本对不上号。
   *
   * 只读最后一个 `session/title` 事件（和 setSessionTitleMark 同一条路），并剥掉本插件加的图标。
   * ⚠️ 带 30 秒缓存：survey() 每几秒就跑一次，每次都翻一遍事件太浪费；
   *    标题变了最多晚 30 秒显示，代价可以接受。
   */
  const titleCache = new Map();
  const readSessionTitle = (sessionId) => {
    try {
      if (!sessionId) return '';
      if (!sessions || typeof sessions.get !== 'function') return '';
      const key = String(sessionId);
      const hit = titleCache.get(key);
      if (hit && now() - hit.at < 30000) return hit.title;
      let title = '';
      const sess = sessions.get(key);
      const events = typeof sess?.snapshotEvents === 'function'
        ? sess.snapshotEvents()
        : (Array.isArray(sess?.events) ? sess.events : []);
      const latest = Array.isArray(events)
        ? [...events].reverse().find((e) => e?.type === 'session/title')
        : null;
      const raw = String(latest?.data?.title ?? '');
      title = stripTitleMark(raw).trim();
      if (title.length > 32) title = `${title.slice(0, 32)}…`;
      titleCache.set(key, { title, at: now() });
      return title;
    } catch { return ''; }
  };

  /**
   * 给一个会话的标题打上（或摘掉）标记。
   * @param sessionId 目标会话
   * @param mark      null = 摘掉；否则是要加的前缀
   * @returns true = 真的改了（或已经是目标状态）
   */
  const setSessionTitleMark = (sessionId, mark) => {
    try {
      if (!sessions || typeof sessions.get !== 'function') return false;
      const sess = sessions.get(String(sessionId));
      if (!sess) return false;
      const events = typeof sess.snapshotEvents === 'function'
        ? sess.snapshotEvents()
        : (Array.isArray(sess.events) ? sess.events : []);
      if (!Array.isArray(events) || events.length === 0) return false;
      const latest = [...events].reverse().find((e) => e?.type === 'session/title');
      if (!latest?.data || typeof latest.data.title !== 'string' || !latest.data.title.trim()) return false;

      // ⚠️ 用 composeTitle 而不是 `mark + strip(...)`：图标必须排在频道前缀**后面**
      //    （`QQ · ♻️ 原标题`），否则 dsh-im 判"没有前缀"、再补一个 → 每 10 秒长一层。
      const { body } = splitTitle(latest.data.title);
      if (!body.trim()) return false;
      const want = composeTitle(latest.data.title, mark);
      if (want === latest.data.title) return true;   // 已经是目标状态，不重复追加

      if (typeof sess.append !== 'function') return false;
      sess.append('session/title', { ...structuredClone(latest.data), title: want });
      return true;
    } catch (error) {
      // 标记只是"看一眼"，任何失败都不该影响重启本身
      log(`（不影响重启）给会话 ${sessionId} 加标题标记失败：${String(error?.message ?? error).slice(0, 120)}`);
      return false;
    }
  };

  /** 当前有没有待执行的重启 → 返回计划（或 null）。 */
  const readPendingPlan = () => {
    try {
      const p = readJson(planPath);
      return (p && typeof p === 'object' && p.planId) ? p : null;
    } catch { return null; }
  };

  /** 把一批会话的标题标记同步成 `mark`（null = 摘掉）。 */
  const syncTitleMarksFor = (ids, mark) => {
    let n = 0;
    for (const id of ids) { if (setSessionTitleMark(id, mark)) n += 1; }
    return n;
  };

  /** 从计划里取出"该带标记的会话"（members[] + requestedBy）。 */
  const titleMarkIdsOf = (plan) => {
    const ids = new Set();
    if (!plan) return ids;
    if (Array.isArray(plan.members)) {
      for (const m of plan.members) { if (m?.sessionId) ids.add(String(m.sessionId)); }
    }
    if (plan.requestedBy) ids.add(String(plan.requestedBy));
    return ids;
  };

  /** 把计划里所有成员的标记同步成 `mark`（null = 摘掉）。 */
  const syncTitleMarks = (plan, mark) => {
    if (!plan) return 0;
    return syncTitleMarksFor(titleMarkIdsOf(plan), mark);
  };

  // ══════════════════════════════════════════════════════════════════════════
  // ★★ 2026-10-23 修：**图标撤不掉**（用户在 09:08 报的）
  //
  //   原话：「现在别的对话重启完之后好像那个图标不会被撤掉」
  //
  // 【病根：摘标记的时候不知道要摘谁】
  //   旧逻辑是：`计划还在 → 加上；计划没了 → 摘掉`。
  //   但"摘掉"必须知道**摘哪些会话**，而它当时唯一的来源就是**计划文件本身**。
  //   重启一成功，助手就把 `plan.json` 删了；于是下一拍 tick 读到 pending=null，
  //   算出的待摘名单是**空集** → `syncTitleMarksFor([], null)` 空转 → n 永远是 0。
  //   ⇒ 图标一旦加上，除非用户手工改标题，否则**永远摘不掉**。
  //
  //   证据（plugin.log 全量翻一遍）：`已给…加上` 出现 8 次，`已摘掉` **0 次**。
  //   注意这不是 2026-10-23 引入的 —— 从有标记那天起就没生效过，
  //   只是以前标记少、不容易被注意到。
  //
  // 【为什么不能靠"扫所有会话"解决】
  //   会话 500+ 个，逐个 `sessions.get()` 拿标题太贵（list 一次实测十几秒），
  //   而且 10 秒一拍会把它变成常态开销 —— 违反"按需优于自刷"。
  //
  // 【修法：自己记一本小账】
  //   `title-marks.json` 记住"**我给谁戴过图标、还没摘**"。
  //   之后每一拍做两件事：
  //     ① 该戴的戴上，并记进账；
  //     ② 账上有、这次不该戴的 → 摘掉并从账上划掉。
  //   账很小（几个人名），只在**变化时**写盘，不构成后台自刷。
  // ══════════════════════════════════════════════════════════════════════════
  const titleMarksPath = join(stateDir, 'title-marks.json');
  // 一次性修理清单：升级后用它把"以前摘不掉的"清干净
  const stripRepairPath = join(stateDir, 'strip-title-marks.json');

  // 摘不掉的会话要重试，但**不能无限重试**：每 10 秒一次、一天 8640 次。
  // 超过这个数就认了（多半是那个会话再也不会被打开），留一行日志说明。
  const MAX_STRIP_TRIES = 8640;

  const readMarkedIds = () => {
    try {
      const v = readJson(titleMarksPath);
      return new Set(Array.isArray(v?.marked) ? v.marked.map(String) : []);
    } catch { return new Set(); }
  };
  /** 读"每个会话摘失败了几次"（键是会话 id，值是次数）。 */
  const readStripFails = () => {
    try {
      const v = readJson(titleMarksPath);
      const raw = v?.fails;
      const out = new Map();
      if (raw && typeof raw === 'object') {
        for (const [k, n] of Object.entries(raw)) {
          const num = Number(n);
          if (Number.isFinite(num)) out.set(String(k), num);
        }
      }
      return out;
    } catch { return new Map(); }
  };
  const writeMarkedIds = (set, fails) => {
    try {
      const failsObj = {};
      if (fails) for (const [k, v] of fails) failsObj[k] = v;
      writeJson(titleMarksPath, { marked: [...set], fails: failsObj, at: new Date().toISOString() });
    } catch { /* 记账失败不影响标题本身 */ }
  };

  /**
   * 一次性修理：把 `strip-title-marks.json` 里列出的会话标题图标摘掉，然后删掉清单。
   *
   * 【为什么需要它】
   *   账本是"从这一版起"才有的。升级之前加上的那些图标，账上没有记录，
   *   光靠账本永远摘不掉（用户看到的就是"重启完了图标还在"）。
   *   所以留一个**手动投喂**的接口：谁发现残留，就把会话 id 写进这个文件，
   *   插件下一拍（≤10 秒）自动摘干净。
   *
   * 【格式】{ "ids": ["session-xxx", ...] }
   */
  const tryRepairStrips = () => {
    try {
      if (!existsSync(stripRepairPath)) return;
      const v = readJson(stripRepairPath);
      const ids = Array.isArray(v?.ids) ? v.ids.map(String) : [];
      if (ids.length === 0) { try { rmSync(stripRepairPath, { force: true }); } catch { } return; }

      let n = 0;
      const failed = [];
      for (const id of ids) {
        // ⚠️ 摘不掉是**正常情况之一**：那个会话可能此刻没被宿主加载（sessions.get 拿不到）。
        //    这种时候绝不能把清单删掉，否则修理就白做了 —— 留着下一拍再试。
        if (setSessionTitleMark(id, null)) n += 1; else failed.push(id);
      }

      // 只把**真的摘掉了**的从账上划掉
      const marked = readMarkedIds();
      let ledgerChanged = false;
      for (const id of ids) {
        if (failed.includes(id)) continue;
        if (marked.delete(id)) ledgerChanged = true;
      }
      if (ledgerChanged) writeMarkedIds(marked);

      if (failed.length === 0) {
        try { rmSync(stripRepairPath, { force: true }); } catch { }
        log(`一次性修理：摘掉 ${n}/${ids.length} 个会话的标题图标（清单已删）`);
      } else {
        // 保留清单继续试；同一份清单反复刷日志会吵，所以只在数字变化时说一句
        const sig = `${n}/${ids.length}`;
        if (tryRepairStrips._lastSig !== sig) {
          tryRepairStrips._lastSig = sig;
          log(`一次性修理：这一拍摘掉 ${n}/${ids.length}，还有 ${failed.length} 个会话没加载到（清单留着，下一拍再试）`);
        }
      }
    } catch { /* 修理失败不影响正常对账 */ }
  };

  /**
   * 标题标记的**对账纯函数**（没有副作用，方便直接测）。
   *
   * 「该戴的戴上、账上有但这次不该戴的摘掉」全部在这里算，
   * 真正去改标题由 `apply(id, mark)` 负责（null = 摘掉）。
   *
   * @param desired 这次应该戴标记的会话集合
   * @param marked  账本上"已经戴过、还没摘"的集合
   * @param want    这次要戴的图标（null = 这次谁都不戴）
   * @param apply   (id, mark) => boolean
   * @returns {{next: Set<string>, added: number, stripped: number}}
   *
   * ⚠️ 关键约定（2026-10-23 修正过一次，别改回去）：
   *   **摘失败就留在账上**，下一拍再试 —— 因为 `apply` 失败最常见的
   *   原因**不是"会话被删了"，而是"那个会话当前没被宿主加载"**
   *   （只有打开的对话才在内存里，`sessions.get` 才拿得到）。
   *   第一版写成"不管成没成功都划账"，后果是：没打开的会话 → 摘失败 → 划账 →
   *   **那个图标就永远没人再管了**。这正是用户报的"图标撤不掉"的第二种形态。
   *   为了不让它变成"每 10 秒重试一次、永远失败"的暗耗，调用方会用 fails 计数
   *   兜一个上限（见 tick 里的 MAX_STRIP_TRIES），超了才放弃并留一行日志。
   */
  const reconcileMarked = ({ desired, marked, want, apply }) => {
    const next = new Set(marked);
    let added = 0;
    let stripped = 0;
    const stripFailed = [];
    if (want) {
      for (const id of desired) {
        if (apply(id, want)) {
          if (!next.has(id)) { next.add(id); added += 1; }
        }
      }
    }
    for (const id of [...next]) {
      if (desired.has(id)) continue;
      if (apply(id, null)) {
        next.delete(id);
        stripped += 1;
      } else {
        stripFailed.push(id);   // 留着，下一拍再试
      }
    }
    return { next, added, stripped, stripFailed };
  };

  // ── ★ 2026-10-23 新增：**失败标记**（用户要的「提醒我这个会话需要重启」）──────
  //
  // 【为什么需要】
  //   重启失败之后，会话标题上什么都不显示 —— 用户只能靠碰巧看见那条失败提示。
  //   而失败意味着"这个会话的改动还没生效，得再重启一次"，这正是该被提醒的事。
  //
  // 【为什么必须**按会话**判断，不能全局贴】
  //   失败是全局事实，但"该重启"只针对**当初排这次重启的那个会话**
  //   （last-run.json 的 members[] / requestedBy）。给所有会话贴红点 = 噪音，
  //   等于把「该重启」这个信号稀释掉。
  //
  // 【判据（不引入新账本）】
  //   · last-run.json 的 outcome **不是** success/cancelled；
  //   · 且 finishedAt 在 **2 小时内**（再久就不是"该重启"而是"陈年旧账"了）；
  //   · 且**当前没有**待执行计划（有的话以 ♻️ 为准，别同时贴两个）。
  //
  // 【什么时候自动消失】
  //   · 一旦这个会话成功排上一次重启（有 pending plan 且它在名单里）→ ♻️ 顶掉 🔴；
  //   · 或者超过 2 小时；
  //   · 或者手动把标题上的标记删掉（用户自己清）—— stripTitleMark 会认。
  const FAIL_MARK_TTL_MS = 2 * 60 * 60 * 1000;
  const failedSessionIds = () => {
    try {
      const r = readJsonResult(lastRunPath);
      if (!r.ok || !r.value || !r.value.finishedAt) return null;
      const last = r.value;
      if (last.outcome === 'success' || last.outcome === 'cancelled') return null;
      const finished = Date.parse(last.finishedAt);
      if (!Number.isFinite(finished)) return null;
      if (now() - finished > FAIL_MARK_TTL_MS) return null;
      const ids = new Set();
      if (Array.isArray(last.members)) {
        for (const m of last.members) { if (m?.sessionId) ids.add(String(m.sessionId)); }
      }
      if (last.requestedBy) ids.add(String(last.requestedBy));
      return ids.size > 0 ? ids : null;
    } catch { return null; }
  };

  // 每 10 秒对齐一次（跟 state.json 的心跳同一个节拍）。
  //
  // ⚠️⚠️ 2026-10-23 改：**必须有账本**（`title-marks.json`）。
  //   旧注释写的是"不记录任何跨调用的状态，这样插件重载后自然收敛" ——
  //   这句话是错的：没有账本，计划文件一消失就**没人知道该摘谁**，
  //   于是"收敛"从来没发生过（日志里 8 次加上、0 次摘掉）。
  //   现在改成"账本 + 每拍对账"，插件重载/重启后照样收敛（账在盘上）。
  let lastTitleMarkValue = null;
  // 摘失败的次数（内存计数，插件重启后重置 —— 只是为了不让重试无限进行下去）
  const stripFailStreak = new Map();
  const tickTitleMarks = () => {
    try {
      const pending = readPendingPlan();
      // 三种状态（2026-10-23 定）：
      //   有计划        → ♻️（在等 / 正在重启）
      //   没计划但刚失败 → ⭕（该重启；只贴给那次排队的会话）
      //   其余          → 摘掉
      const failed = pending ? null : failedSessionIds();
      const want = pending ? MARK_RECYCLE : (failed ? MARK_FAILED : null);
      const desired = pending ? titleMarkIdsOf(pending) : (failed ?? new Set());

      // ① 一次性修理：升级后把"以前摘不掉的"清掉（见文件头说明）
      tryRepairStrips();

      const marked = readMarkedIds();

      // ⚠️⚠️ 2026-10-23：**这里原来有个"内容没变就 return"的短路，必须去掉。**
      //   它会连"摘失败要重试"一起挡掉：摘不掉的会话（没被宿主加载）每拍都应再试一次，
      //   而内容签名不变 → 直接返回 → 永远不再试 → 图标永远留着。
      //   去掉之后每拍拍一次对账：加/摘都是幂等的，代价就是几个 get()，可忽略。
      const { next, added, stripped, stripFailed } = reconcileMarked({
        desired,
        marked,
        want,
        apply: setSessionTitleMark
      });

      // 摘失败的：留着下一拍再试，但**不能无限试**（见 MAX_STRIP_TRIES 的说明）。
      // 计数放内存里就够 —— 插件重启后重新计一轮，代价只是多试一会儿。
      let gaveUp = false;
      for (const id of stripFailed) {
        const n = (stripFailStreak.get(id) ?? 0) + 1;
        if (n >= MAX_STRIP_TRIES) {
          next.delete(id);
          stripFailStreak.delete(id);
          gaveUp = true;
          log(`图标：会话 ${id} 连试 ${MAX_STRIP_TRIES} 次都没加载到 —— 放弃摘除，那个图标会一直留着`);
        } else {
          stripFailStreak.set(id, n);
        }
      }
      // 已经成功摘掉/不再需要的，把失败计数清掉
      for (const id of [...stripFailStreak.keys()]) { if (!next.has(id)) stripFailStreak.delete(id); }

      if (added > 0 || stripped > 0 || gaveUp) {
        writeMarkedIds(next);
        const what = want === MARK_RECYCLE ? '在重启' : (want === MARK_FAILED ? '重启失败' : '');
        if (added > 0) log(`已给 ${added} 个会话标题加上「${what}」图标`);
        if (stripped > 0) log(`已摘掉 ${stripped} 个会话的标题图标`);
      }
    } catch { /* 标记失败绝不拖累主线 */ }
  };
  const titleTimer = setInterval(tickTitleMarks, Math.max(2, Number(config.checkSeconds) || 10) * 1000);
  if (typeof titleTimer.unref === 'function') titleTimer.unref();
  // 启动时先对齐一次（重启回来的第一件事就是把刚才那批标记摘掉）
  setTimeout(tickTitleMarks, 3000);

  // ── ★ 2026-10-23：失败提示**只投给相关会话**（取代原来的全局广播）──────────
  //
  // 为什么要等：sessionController 比插件晚就位是实测事实（schedule 那代晚过 20 秒）。
  //   用「隔几秒试一次、最多试 N 次」而不是固定等一个猜出来的时长 ——
  //   本仓的老教训：跨组件启动顺序**永远不要假设**。
  //
  // 为什么不是常驻定时器：这件事**一辈子只做一次**（投完记账就收工）。
  //   常驻轮询会被当成"后台自刷"，用户明确不喜欢。
  (() => {
    const MAX_TRIES = 20;          // 20 次 × 5 秒 = 100 秒，覆盖服务晚就位的实测区间
    const EVERY_MS = 5000;
    let tries = 0;
    let done = false;
    const tick = async () => {
      if (done) return;
      tries += 1;
      if (tries > MAX_TRIES) {
        done = true;
        // 只在这一件事上留一行痕迹：没服务就永远是 0，不该静默说不清
        if (tries > MAX_TRIES) log('失败提示：等了 100 秒仍没等到 sessionController，本次不投（重启本身不受影响）');
        return;
      }
      try {
        const n = await deliverFailureNotes();
        if (n > 0) { done = true; return; }
        // n === 0 有两种可能：① 根本没失败 ② 服务还没就位。
        // 分不清就继续试 —— 最多 100 秒，代价可忽略（每 5 秒读一次小 JSON）。
        if (!failureNote()) { done = true; return; }   // 没东西可送，立刻收工，不用耗满
      } catch { /* 投递失败不影响任何东西 */ }
      if (!done) { const t = setTimeout(tick, EVERY_MS); if (typeof t.unref === 'function') t.unref(); }
    };
    const first = setTimeout(tick, 4000);
    if (typeof first.unref === 'function') first.unref();
  })();


  //
  // 设计目标：既不新增常驻轮询、也不做后台统计（轮询会被认为不优雅，且有无谓的性能开销）。
  //
  // 所以这里刻意**不做**任何"后台统计"：
  //   · 助手每次重启**追加一行**到 history.jsonl（只追加，不维护）；
  //   · 插件**不读它、不算它** —— 只有人/Agent 调 restart_status 时，才现场读一遍算个大概。
  // 这就是"按需优于自刷"的原则：**状态在被读取那一刻产生**。
  // 它也不写任何文件（纯读），所以不存在"假新鲜"的问题。
  //
  // 为什么只报"关掉 → 起来"那一段的中位数、而不是总耗时：
  //   总耗时 = 给本轮回复留的时间 + 等这一轮说完 + 确认窗 + 关掉到起来，
  //   前两项**每次差很多**（取决于回复多长），拿它当"这台机器重启要多久"完全是误导。
  //   真正反映机器速度的就是"关掉 → 端口回来"这一段。
  const readHistorySummary = () => {
    // ⚠️ 这里**不能**用 readJsonResult：它是给"整份 JSON"用的，
    //    而 history.jsonl 是**一行一个 JSON**（追加式流水账），整份解析必然失败。
    //    （第一版真这么写过 —— 读失败会被当成"没有流水账"。）
    try {
      const raw = readFileSync(join(stateDir, 'history.jsonl'), 'utf8');
      const rows = [];
      for (const line of raw.split(/\r?\n/)) {
        const t = line.trim();
        if (!t) continue;
        try {
          const o = JSON.parse(t);
          if (o && typeof o === 'object') rows.push(o);
        } catch { /* 坏行跳过 —— 追加写可能撞上半截，不值得为它报错 */ }
      }
      if (rows.length === 0) return null;
      const ups = rows
        .filter((o) => o.outcome === 'success' && Number.isFinite(Number(o.downToUpSeconds)))
        .map((o) => Number(o.downToUpSeconds))
        .sort((a, b) => a - b);
      const okCount = rows.filter((o) => o.outcome === 'success').length;
      if (ups.length === 0) {
        return { total: rows.length, ok: okCount, samples: 0 };
      }
      const mid = ups.length % 2 === 1
        ? ups[(ups.length - 1) / 2]
        : Math.round(((ups[ups.length / 2 - 1] + ups[ups.length / 2]) / 2) * 10) / 10;
      return {
        total: rows.length,
        ok: okCount,
        samples: ups.length,
        fastest: ups[0],
        slowest: ups[ups.length - 1],
        median: mid
      };
    } catch {
      return null;   // 没有这个文件 = 正常（还没记过），不是错误
    }
  };

  // ── 工具：restart_self ───────────────────────────────────────────────────
  const restartSelfTool = {
    name: 'restart_self',
    description:
      'Restart this DSH desktop application (the app hosting you) once it is genuinely idle. ' +
      'Use it when you have just finished something that needs a host restart to take effect (a newly installed plugin, a config change) and you want to verify it — ' +
      'or when the user asks you to restart yourself. You do NOT need to ask the user first: this is a normal maintenance action. ' +
      'The restart runs in a detached helper process that survives the app being killed, waits for background jobs and running turns to finish, ' +
      'then relaunches the app and verifies the port comes back. ' +
      'It will not disturb other conversations: if another session is running, it does not barge in — it QUEUES and keeps waiting ' +
      '(as of 2026-10-22: the old "that attempt is spent, not queued" behaviour is gone; a waiting attempt is now kept, not thrown away). ' +
      'Multiple sessions can queue on the same trip; they all leave together once everyone is idle, and each one is woken with its own reason. ' +
      // ★ 2026-10-23 改：原文写的是 `Every member can leave the queue on its own; when the last one
      //   leaves, the trip cancels itself` —— **那两件事代码里从来没有**（只有整批 cancel）。
      //   说明书吹牛比没写更糟：agent 照着它去"只退出自己"，实际会把整趟车取消，
      //   连带把另一个正在等的会话一起打掉。现在如实写成整批语义。
      'Cancelling is ALL-OR-NOTHING: restart_status(cancel: true) cancels the WHOLE trip — ' +
      'every session waiting on it, not just you. There is no per-session opt-out. ' +
      'So before calling cancel, use restart_status() to read the FULL member list: ' +
      'if other sessions are on the list, cancelling will also drop THEIR restart. ' +
      'A pending trip whose own reason does not match yours may simply be an earlier requester on the SAME trip — ' +
      'check the member list, do not assume it is a stale leftover. ' +
      'It NEVER forces either: if the machine stays busy, it keeps waiting (default max_wait_minutes = 0 means wait indefinitely, with a 12-hour hard cap) ' +
      'and, if the host has a noticeCommand configured, runs that command once after notifyAfterMinutes. ' +
      'If it ends up not restarting, a notice is surfaced to you at the start of your next turn — report it to the user then. ' +
      'NOTE: this ends your current process. On a SUCCESSFUL restart the plugin DELIVERS a wake-up message straight into THIS session ' +
      'a few seconds after the app is back, and hands your `reason` straight to you in it — write `reason` as instructions to your future self and you resume automatically. ' +
      '(The message is stamped as coming from the plugin, not from the user; only if the session controller is unavailable ' +
      'or wakeMessage is set to false is there no auto-wake — then the user reopens the session.) ' +
      'Before arming: finish your reply, and after arming keep quiet — the idle timer restarts on every write to this session, ' +
      'so any extra tool call between arming and the kill is pure added waiting for the user.',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        confirm: {
          type: 'boolean',
          description:
            'Must be true. It means "I have decided this restart is worth doing" — a deliberate second thought, not a record of user consent. ' +
            'No user approval is required (this app is often driven remotely and there is no dialog to click).'
        },
        delay_seconds: {
          type: 'number',
          description:
            'Extra seconds before the idle wait begins. Leave it at the default 0. ' +
            '★ This is NOT a "let the user finish reading" setting. A restart is a mid-task step, ' +
            'not a farewell: the user is waiting on the result, not reading a sign-off. ' +
            'The plugin already waits for your turn to end (idleSeconds) before it does anything, ' +
            'and then shows a 10s confirm window — so padding this only makes the user wait longer. ' +
            '★ Call restart_self as the LAST action of your turn, after every wrap-up step ' +
            '(commits, archives, status refreshes), then stop writing: any further write resets ' +
            'the idle countdown and delays the restart. ' +
            'The owner raised this twice (2026-10-12 on a 120s setting, 2026-10-13 on a 40s one).'
        },
        reason: {
          type: 'string',
          description:
            'Short reason recorded in the log, e.g. "verifying a newly installed plugin". ' +
            '★ It is ALSO handed back to you in the wake-up reminder after the restart, ' +
            'so write what the next turn should pick up (not just "test").'
        },
        max_wait_minutes: {
          type: 'number',
          description:
            'How long to keep waiting for idleness before GIVING UP. ' +
            'OMIT IT (recommended): the default is 0 = wait indefinitely (12-hour safety cap only). ' +
            'The user can cancel at any time from the status card, so an endless wait is not a lock-in. ' +
            'Pass a positive number only for the rare case where nobody will be around to cancel: ' +
            'the wait then gives up after that many minutes. ' +
            'Giving up does NOT force a restart: the app is left untouched, the outcome is recorded as skipped-busy, and a note is posted into the conversation.'
        },
        dry_run: {
          type: 'boolean',
          description: 'When true, only report what WOULD happen (idle check, resolved paths) and start nothing.'
        },
        resume: {
          type: 'boolean',
          description:
            'Whether the restart should wake THIS session afterwards to carry on (default true). ' +
            '★ YOU decide this per restart — it is not a setting. ' +
            'Use true when the task is unfinished and you must continue after the restart ' +
            '(the usual case: you installed something and must now verify it). ' +
            'Use false when the restart is the FINAL step and nothing remains to do — waking you then ' +
            'would just make you talk to yourself and burn a turn for nothing. ' +
            'It is independent of the profile setting wakeMessage: that value is this machine\'s default, ' +
            'this parameter is THIS restart\'s choice, and the choice wins.'
        }
      },
      required: ['confirm']
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          ok: { type: 'boolean' },
          message: { type: 'string' },
          planId: { type: 'string' },
          scheduledAt: { type: 'string' },
          helperPid: { type: 'number' },
          busy: { type: 'array', items: { type: 'string' } },
          dshExe: { type: 'string' },
          // ★ 2026-10-23 补：入队分支会返回"这趟车现在几个人"。
          //   ⚠️ 之前这里漏声明它 → 宿主的输出校验按 additionalProperties:false
          //   **整份拒收**，报 `value.queueLength is not a declared property`。
          //   后果是最恶劣的一种：**副作用已经发生（真排上了），但调用方收到的是报错** ——
          //   于是它以为没排上，去查状态、去手工改文件，最后误把整趟队列取消掉。
          //   （2026-10-23 17:54 实机事故，见 IMPL_VERSION 14 的说明。）
          queueLength: { type: 'number' }
        },
        required: ['ok', 'message']
      },
      render: (_args, value) => [{ type: 'text', text: value.message }]
    },
    async execute(args, exec) {
      if (args.confirm !== true) {
        return {
          ok: false,
          message: '没有动手：restart_self 会结束当前 DSH 进程，必须显式传 confirm: true。'
        };
      }

      if (config.enabled === false) {
        return { ok: false, message: '插件配置里 enabled=false，自我重启被关掉了。改配置或让用户在设置页打开。' };
      }

      const dshExe = detectDshExe(config);
      if (!dshExe) {
        return {
          ok: false,
          message:
            '没找到 DSH 主程序，不敢动手 —— 关了却拉不起来是最坏的结果。' +
            '请把正确路径写进插件配置的 dshExe，或确认桌面版装在默认位置。'
        };
      }

      if (!existsSync(HELPER)) {
        return { ok: false, message: `助手脚本不在：${HELPER}。插件装得不完整，自我重启不可用。` };
      }

      // 发起重启的是哪个会话？用它把"自己"从"别的会话"里排除掉。
      //
      // ⚠️ 2026-10-08 修：**不能读 process.env.DSH_SESSION_ID**。
      //    那个环境变量属于"跑工具的那个短命子进程"，**不属于长驻的宿主进程**——
      //    宿主里读到的是空的。实测后果：计划文件里 requestedBy / sessionFile 都是空的，
      //    于是助手「找不到会话记录文件」，只能退化成纯计时（少了一道安全判据）。
      //    正确来源是 exec.agent.id（调用这个工具的 agent 就是发起会话）。
      const requesterSessionId = String(exec?.agent?.id ?? '');
      const s = survey(requesterSessionId);
      const busy = [...s.details];

      // ★ 2026-10-22：发起者自己是什么来源（本地窗口 / QQ私聊 / 群 / 查不到）。
      //   写进成员里，将来"该叫醒谁 / 要不要通知"要用；取不到就 unknown，绝不抛。
      let requesterSource = 'unknown';
      try {
        const mySession = (sessions && typeof sessions.get === 'function')
          ? sessions.get(requesterSessionId)
          : null;
        if (mySession) requesterSource = sessionSourceOf(mySession);
      } catch { requesterSource = 'unknown'; }

      // 会话记录文件：助手用它判断"这轮说完了没有"
      // （同样要用 exec.agent.id，不能读环境变量 —— 见上面 requestedBy 的说明）
      let sessionFile;
      try {
        sessionFile = findSessionFile(requesterSessionId);
      } catch (error) {
        log(`找会话文件失败（不致命）：${String(error?.message ?? error).slice(0, 120)}`);
      }

      const delaySec = Number.isFinite(args.delay_seconds) ? Math.max(0, Number(args.delay_seconds)) : 0;
      // 自动叫醒的口径**只在这里算一次**（execute 里的成功回话、空跑回话都用它），
      // 和 resumeAfterRestart() 里的闸保持一致 —— 两处口径不同就又变成"嘴上说会叫、实际不会"。
      // ⚠️ 2026-10-13 改：开关和时长拆成两个配置项（wakeMessage / wakeDelaySeconds），
      //    一个值只有一个意思。消息**投递**出去之后到会话被叫醒之间还隔着模型启动的时间，
      //    所以对外一律说"约 N 秒后投递"，不承诺"N 秒后它已经在干活了"。
      const wakeOff = config.wakeMessage === false;
      const rawWakeDelay = Number(config.wakeDelaySeconds);
      const wakeIn = Number.isFinite(rawWakeDelay) ? Math.max(0, Math.round(rawWakeDelay)) : 3;
      // 能不能叫醒取决于服务在不在（服务比插件晚就位是实测事实，故用"当前拿没拿到"判断）。
      const wakeOn = !wakeOff && Boolean(sessionController);
      // 兜底也用配置值，别再写死 120 —— 已按设计改成分钟级（2026-10-08）。
      // ★ 2026-10-24 改兜底 5 → 0，和 schema 默认对齐：
      //   原来这里写 5，意味着"配置读不出来时悄悄变成最多等 5 分钟"，
      //   而 schema 声明的默认明明是 0（一直等）。**一个参数只能是同一个意思**，
      //   否则一旦走到兜底分支，行为就变了、还不报错。
      //   （同一天助手脚本里那个 `else { 5 }` 也一并改成 0 —— 一处漏改等于没改。）
      const configuredMaxWait = Number(config.maxWaitMinutes);
      const maxWaitFallback = Number.isFinite(configuredMaxWait) ? Math.max(0, configuredMaxWait) : 0;
      const maxWait = Number.isFinite(args.max_wait_minutes)
        ? Math.max(0, Number(args.max_wait_minutes))
        : maxWaitFallback;

      // 计划时间 = 延迟 + 缓冲。
      // ⚠️ 2026-10-11 定的新口径（"重启越快，对一直挂着的工具影响越小"）：
      //    缓冲从写死的 8 秒改成**可配置**（默认 5 秒）。
      //    那 8 秒原本是"让当前这轮回复先落盘"的保险；实测 5 秒足够，
      //    而且助手在真正动手前还有一道"等你这一轮说完"的闸兜着
      //    （会话记录连续 idleSeconds 秒没新动静），不会因为缓冲短就打断回复。
      const bufferSec = Number.isFinite(Number(config.confirmBufferSeconds))
        ? Math.max(0, Number(config.confirmBufferSeconds))
        : 5;
      const scheduledAt = new Date(now() + (delaySec + bufferSec) * 1000).toISOString();

      // ── 别的会话在跑？现在就不排（设计取舍，2026-10-08）──────────────────
      // "试一次，有其他对话在跑就停下来，就不自动重启了" —— 这条在**排之前**就判，
      // 而不是排上之后再等：既然别人的活没干完，这次机会就作废，不占着坑。
      // 助手里还有第二道同名判断（它读 state.json 的 runningSessions），
      // 因为从"现在"到"真动手"之间，别的会话随时可能开始干活。
      const otherSessions = s.otherSessionsRunning;
      // ★ 2026-10-22 改：**不再因为"别人在忙"就拒绝**，而是把它入队继续等。
      //   老行为（2026-10-08 定的）是"有别的会话在跑 → 当场拒绝，连号都不拿"，
      //   动机是宁可永远不重启、也绝不砍断别人的活。实测这条规矩触发了 19 次（10-13~10-22），
      //   每次都是"想重启 → 被拒 → 过一会儿再来一次"，白折腾。
      //   新的规矩保持同样的底线（**绝不强闯**），只是把"作废"换成"排队等" ——
      //   见 docs\decisions-restart-queue.md 的 D3 / D4。
      //
      //   ⚠️ 判定"要不要等"仍然由插件说了算（它是权威）：这里不拒绝，
      //      但会在下面把"谁在忙、什么来源"写进计划，交给助手在等待循环里逐个等。
      if (args.dry_run === true) {
        const lines = [
          '【空跑】什么都没启动。真跑的话会是这样：',
          `· 主程序：${dshExe}`,
          // ⚠️ 2026-10-23 修：这里原来写 config.port（= 写死的 19387）。
          //   DSH 0.2.1-rc.2 起桌面端用 `--port 0` 随机分配（今天实测 2254），
          //   于是空跑报的端口和真计划里的不是一个 —— 真计划早就用 actualPort() 了，
          //   只有这两处显示漏掉。后果不是重启坏掉，而是**人照着空跑的数字去核对，核到的是错的**。
          //   显示与实际必须同源。
          `· 端口：${actualPort()}`,
          `· 助手脚本：${HELPER}`,
          `· 计划动手时间：${scheduledAt}（延迟 ${delaySec}s + ${bufferSec}s 缓冲）`,
          `· 第一段：只等你这一轮说完（连续 ${config.idleSeconds}s 没新动静）`,
          // ⚠️ 这行必须显示出来：确认窗（默认 10 秒）是既定设计，
          //    空跑里看不见它，就没法确认这个设置到底生效没有。
          `· 动手前确认窗：${Math.max(0, Number(config.confirmSeconds ?? 10) || 0)} 秒（这期间卡片上有倒计时，「打断」按钮仍可点）`,
          `· 等待名单：任何人都在等（${config.othersWindowSeconds ?? 120}s 内写过会话也算在动）`,
          `· 最多等 ${maxWait} 分钟；等不到就**提醒并继续等**（2026-10-22 改：不再设"作废"上限）`,
          `· 别的会话在跑时：**照常排上、一起等**（现在有 ${otherSessions} 个在跑：${s.others.slice(0, 3).map((o) => `${o.id}(${o.source})`).join('、') || '无'}）`,
          `· 等超过 ${Number(config.notifyAfterMinutes) || 20} 分钟还没发车 → 跑一次 noticeCommand（没配就不通知，默认只通知一次）`,
          `· 会话记录文件：${sessionFile ?? '（没找到 —— 助手会退化为纯计时）'}`,
          s.jobsRunning > 0 ? `· 此刻有 ${s.jobsRunning} 个后台任务在跑` : '· 此刻没有后台任务',
          // 空跑也要说清"醒不醒得来"：这是"装到别人机器上能不能直接用"的第一手体检单
          wakeOn ? `· 重启成功后：约 ${wakeIn}s 后把唤醒消息投进本会话（把 reason 原样带回；标注为插件发的，不冒充使用者）`
                 : '· 重启成功后：**不会**自动叫醒（sessionController 没就位 / wakeMessage=false），需手动重开会话'
        ];
        return {
          ok: true,
          message: lines.join('\n'),
          scheduledAt,
          busy,
          dshExe
        };
      }

      const planId = `restart-${now().toString(36)}`;
      // ★ 2026-10-13：本次要不要续接（见工具参数 resume 的说明）。
      //   规则：模型明说了就听模型的；没说则看配置默认（wakeMessage）。
      const resumeWanted = typeof args.resume === 'boolean'
        ? args.resume
        : config.wakeMessage !== false;

      // ── ★ 2026-10-22：判断"现在要不要排队"，以及这一趟车是不是已经开动了 ──────────
      //
      // 【为什么这一段必须写在这里、而且必须这么写】
      //   老的 plan.json 是"一份计划 = 一个人"，写之前**不检查是否已有待执行的计划**，
      //   后写的**直接覆盖**前一份（docs\decisions-restart-queue.md 的 D7 / 10-14 调研 §1.1）。
      //   而等在外面的助手只在启动时读一次计划 —— 于是先来的人会**静默失去自己的锁**，
      //   保险丝也救不了（它看 helperPid 判断"正主还在不在"）。
      //
      //   新的规矩（三条，缺一不可）：
      //     ① 已经有一趟车在等（plan.json 在）→ **只增补成员，绝不改 planId / helperPid**；
      //     ② 只有**第一个上车的人**才点火启动助手（否则会"每来一个人开一辆车" —— 那是旧事故模式）；
      //     ③ 同一会话重复排 → 只更新它自己的理由，不重复占位。
      const existingRaw = readJson(planPath);
      // ══════════════════════════════════════════════════════════════════════
      // 【2026-10-23 加】先确认"那条计划点名的助手还活着"，否则它是**僵尸计划**
      //
      // 【为什么必须有这一步 —— 拿一次真实的"功能假活"换的】
      //   2026-10-23 00:36 实机验证时，助手启动、认领计划（helperPid=5108）、开始等空闲，
      //   然后在 00:41 因为一个未捕获异常**静默死掉**（见 bin 脚本里那段说明），
      //   但 plan.json 留在盘上没人清。
      //
      //   后果不是"重启失败"，而是**重启功能变成假的**：
      //     · 下一个人来排重启 → 看到 plan.json 有 planId → 走"入队"分支
      //       → 只往 members[] 里追加一个名字，**永远不会点火**（因为点火只在
      //         "没有既有计划"时发生）；
      //     · 于是它会一直显示"已排进队列，助手已经在等了"—— 而根本没人等。
      //   这比明确报错恶劣得多：它**报告成功，实际什么都不做**。
      //   （本仓已有同型教训：跑批器的假绿、dry-run 的假端口。判据一样 ——
      //     "它说排上了"不等于"有人会动手"。）
      //
      // 【判据】计划里有 helperPid，但那进程已经不在了 → 视为僵尸，清掉重开。
      //   · helperPid 为空 = 还在点火/握手阶段，按既有逻辑处理（不在这里抢）；
      //   · 我们**只清计划文件，绝不去杀任何进程**（那条进程已经死了，没有可杀的）。
      //   · 清之前记一行日志，并把它存进 last-run.json 的 outcome='stale-plan'，
      //     让"为什么这次重启会多等/重开"有据可查。
      // ══════════════════════════════════════════════════════════════════════
      let existingOk = Boolean(existingRaw && typeof existingRaw === 'object' && existingRaw.planId);
      // ══════════════════════════════════════════════════════════════════════
      // 【2026-10-23 加】盘上有 cancel.flag = 这趟车**已经被叫停**，不能再往上面加人
      //
      // 【为什么这一条必须在这里 —— 同一天第二起实机事故】
      //   17:55:06 有人调了 `restart_status(cancel:true)`（写 cancel.flag）；
      //   17:55:12 另一个会话又调 `restart_self` → 插件看到 plan.json 还在
      //            → 走"入队"分支 → **排进了一趟已经死掉的车**。
      //   6 秒后助手看到取消标记就退出了，可新一轮"上车"的记录已经写进计划，
      //   于是它以为自己在等，其实那趟车永远不会开。
      //
      // 【判据】取消标记在 = 这一趟已经作废。
      //   · 绝不把新来的人塞进一趟死车（那是"报告成功、实际什么都不做"，最恶劣的一类）；
      //   · 也绝不把死车的成员名单带进新的一趟（他们的重启已经明确被取消了）；
      //   ⇒ 记一笔账、清掉旧计划与标记，**当作没有既有计划**，让下面开一趟新车。
      // ══════════════════════════════════════════════════════════════════════
      if (existingOk && existsSync(cancelPath)) {
        // ⚠️ 这里要分两种情形 —— 判错会引出更糟的后果（连续重启两次）：
        //
        //   · 助手**还活着**：它每轮都查取消标记，1~2 秒内会自己走 Close-Trip 封口。
        //     此刻绝不能开新车 —— 否则旧助手可能已经过了"还能反悔"的关口、
        //     正要把 DSH 关掉，而新助手同时挂上来，就会**连着重启两次**。
        //     ⇒ 如实回绝："这趟正在被叫停，几秒后重排一次"。
        //   · 助手**已经不在了**（或计划里还没写 PID）：这趟车真的没人开。
        //     那就清掉它、给这次请求开一趟新的（真实事故就是这种：
        //     17:55:11 助手已经退出，17:55:12 另一个会话才来排）。
        const cancelPid = Number(existingRaw.helperPid);
        const cancelHelperAlive = Number.isFinite(cancelPid) && cancelPid > 0
          ? (() => { try { process.kill(cancelPid, 0); return true; } catch { return false; } })()
          : null;
        if (cancelHelperAlive !== false) {
          log(
            `拒绝上车：这趟车（planId=${existingRaw.planId}）已经被叫停，助手` +
            `${cancelHelperAlive === true ? ` PID=${cancelPid} 还活着、正在收尾` : '正在点火'} —— ` +
            '不往死车上加人，也不提前开新车（会连着重启两次）。'
          );
          return {
            ok: false,
            message: [
              `这次没排上：盘上那趟重启（单号 ${existingRaw.planId}）**正在被取消**` +
              `${cancelHelperAlive === true ? '，助手还在收尾' : ''}。`,
              '· 我没有把你的请求塞进那趟车（它不会发车了），也没有另开一趟 ——',
              '  因为旧的助手可能已经走到"正在关闭 DSH"那一步，同时再开一辆会**连着重启两次**。',
              '· 等几秒（助手收尾是秒级的），再调一次 `restart_self` 就行。',
              `· 想确认收干净了：调 \`restart_status()\`，看 plan.json / cancel.flag 是不是都没了。`
            ].join('\n'),
            busy
          };
        }
        log(
          `发现"已被叫停但计划文件还留着"的一趟车：planId=${existingRaw.planId}，` +
          '点名的助手已经不在了 —— 清掉它，给这次请求开一趟新的。'
        );
        try {
          writeJson(lastRunPath, {
            planId: existingRaw.planId,
            outcome: 'cancelled',
            detail: '这趟重启已经被取消且助手已退出（cancel.flag 还在），计划被清理；新来的请求另开一趟。',
            by: 'plugin',
            updatedAt: new Date().toISOString(),
            port: actualPort()
          });
        } catch { /* 记账失败不影响主流程 */ }
        try { rmSync(planPath, { force: true }); } catch { /* 忽略 */ }
        try { rmSync(cancelPath, { force: true }); } catch { /* 忽略 */ }
        try { syncTitleMarks(existingRaw, null); } catch { /* 忽略 */ }
        existingOk = false;
      }
      if (existingOk) {
        const pid = Number(existingRaw.helperPid);
        const alive = Number.isFinite(pid) && pid > 0
          ? (() => { try { process.kill(pid, 0); return true; } catch { return false; } })()
          : null;   // null = 还没握手，不能判死
        if (alive === false) {
          log(
            `发现僵尸计划：planId=${existingRaw.planId} 点名的助手 PID=${pid} 已经不在了 —— ` +
            '清掉它并重新点火（否则新请求会一直"入队"到一个没人等的队列里）'
          );
          try {
            writeJson(lastRunPath, {
              planId: existingRaw.planId,
              outcome: 'stale-plan',
              detail: `助手 PID=${pid} 已不在，计划被清理并重开。原因：助手在等待途中异常退出且没留退出记录。`,
              by: 'plugin',
              updatedAt: new Date().toISOString(),
              port: actualPort()
            });
          } catch { /* 记账失败不影响主流程 */ }
          try { rmSync(planPath, { force: true }); } catch { /* 忽略 */ }
          // 僵尸计划的"待重启"标题标记也要摘掉（新的一轮会重新加）
          try { syncTitleMarks(existingRaw, null); } catch { /* 忽略 */ }
          existingOk = false;
        }
      }
      const queueMax = Math.max(0, Number(config.queueMaxMembers ?? 8) || 0);
      const myMember = {
        sessionId: requesterSessionId,
        sessionFile: sessionFile ?? '',
        reason: (args.reason ?? '').trim() || 'Agent 请求重启',
        resume: resumeWanted,
        joinedAt: new Date().toISOString(),
        // 让助手知道"这个人是什么来源"，将来做 notify / 显示时要用
        source: requesterSource
      };

      if (existingOk) {
        // ── ② 有人在等了 → 追加进名单，绝不覆盖车次 ──────────────────────────
        const prevMembers = Array.isArray(existingRaw.members) ? existingRaw.members.slice() : [];
        // 兼容老计划（只有 requestedBy）：先把"已经上车的那个人"补成成员
        if (prevMembers.length === 0 && existingRaw.requestedBy) {
          prevMembers.push({
            sessionId: existingRaw.requestedBy,
            sessionFile: existingRaw.sessionFile ?? '',
            reason: existingRaw.reason ?? '',
            resume: existingRaw.resume,
            joinedAt: existingRaw.createdAt ?? '',
            source: 'unknown'
          });
        }

        const sameIdx = prevMembers.findIndex((m) => String(m?.sessionId ?? '') === String(requesterSessionId));
        if (sameIdx >= 0) {
          // 同一个会话又按了一次 → 只更新理由，不重复占位（也不改别人的）
          prevMembers[sameIdx] = { ...prevMembers[sameIdx], ...myMember };
        } else {
          if (queueMax > 0 && prevMembers.length >= queueMax) {
            log(`队列已满（${prevMembers.length}/${queueMax}），拒绝 ${requesterSessionId} 上车`);
            return {
              ok: false,
              message: `这趟重启的队列已经满了（${prevMembers.length}/${queueMax} 人）。` +
                '要么等这一趟发车，要么把配置里的 queueMaxMembers 调高（设 0 = 不设上限）。',
              busy
            };
          }
          prevMembers.push(myMember);
        }

        const merged = {
          ...existingRaw,
          members: prevMembers,
          // 老字段跟着更新成"第一个成员"，让只认老结构的代码仍然读得到人
          requestedBy: prevMembers[0]?.sessionId ?? existingRaw.requestedBy,
          sessionFile: prevMembers[0]?.sessionFile ?? existingRaw.sessionFile,
          resume: prevMembers[0]?.resume,
          // ⚠️ planId / helperPid / createdAt **一律不动**：那是这一趟车的身份，
          //    改了等于换一辆车，会把已经在等的那个助手变成孤儿。
          updatedAt: new Date().toISOString()
        };
        if (!writeJson(planPath, merged)) {
          return { ok: false, message: `排进队列失败：计划文件写不进去（${planPath}）。` };
        }
        log(`入队：${requesterSessionId}（这趟车现在 ${prevMembers.length} 人，planId=${existingRaw.planId}）`);
        // 把"车上现在有谁"直接写在回话里 —— 这是第二个排的人**判断"我在不在队里"的唯一依据**。
        // ⚠️ 2026-10-23：原来这里只说"现在 2 人"，它接着去 restart_status 只看到第一个人的
        //    理由 → 以为那是旧车 → 点了取消，把两个人一起打掉。回话里就把名单摊开。
        const rosterLines = prevMembers.map((m, i) => {
          const who = i === 0 ? '（最早排的）' : '';
          const mine = String(m?.sessionId ?? '') === String(requesterSessionId) ? ' ← 你' : '';
          const why = String(m?.reason ?? '').replace(/\s+/g, ' ').slice(0, 60);
          return `   ${i + 1}. ${m?.sessionId ?? '?'}${who}${mine}\n      理由：${why}${String(m?.reason ?? '').length > 60 ? '…' : ''}`;
        });
        return {
          ok: true,
          message: [
            `已经排进队列了（这趟车现在 ${prevMembers.length} 人）。`,
            `· 单号：${existingRaw.planId}（**就是这趟车**，不是别人的旧车 —— 你已经在上面了）`,
            '· 车上的人：',
            ...rosterLines,
            '· 助手已经在等了，不会再点火一次 —— 所有人等齐了才一起重启。',
            '· ⚠️ 取消是**整趟**的：`restart_status(cancel: true)` 会把上面**所有人**的这次重启一起作废。',
            '  只有在你确认这趟车确实该散的时候才调它；你没法"只退出自己"。',
            '· 等的时候想知道进度：调 `restart_status()`（不带 cancel）看名单和已等时长。'
          ].join('\n'),
          planId: existingRaw.planId,
          queueLength: prevMembers.length,
          busy
        };
      }

      const plan = {
        planId,
        createdAt: new Date().toISOString(),
        scheduleAt: scheduledAt,
        reason: (args.reason ?? '').trim() || 'Agent 请求重启',
        // ★ 2026-10-22：第一个上车的人 —— 名单里也放一份，格式统一
        members: [myMember],
        // ★ 2026-10-17：计划里写**真实端口**（`--port 0` 之后系统分配的那个）。
        //   这是本次事故的正解：助手拿着它才等得到监听。
        //   拿不到 webServer 时自动退回 config.port（老行为，不会更糟）。
        port: actualPort(),
        dshExe,
        dshWorkDir: dirname(dshExe),
        idleSeconds: Math.max(5, Number(config.idleSeconds) || 12),
        // 动手前的确认窗秒数（默认 10 秒；这期间「打断」仍可点）。
        // 传 0 就跳过（测试用）。
        confirmSeconds: Math.max(0, Number(config.confirmSeconds ?? 10) || 0),
        maxWaitMinutes: maxWait,
        // 第二段查"别人"用的窗口（助手那侧也有同值兜底，缺省 120s）。
        othersWindowSeconds: Math.max(10, Number(config.othersWindowSeconds) || 120),
        bootTimeoutSeconds: Math.max(20, Number(config.bootTimeoutSeconds) || 90),
        maxAttempts: Math.max(1, Number(config.maxAttempts) || 3),
        sessionFile: sessionFile ?? '',
        // 会话记录根目录：助手拿它做"直接看盘上谁在写"的独立判断，
        // 这样即使插件没加载 / 状态文件过期，也不会漏掉别的会话在干活。
        sessionsRoot: join(HOME_DSH, 'sessions'),
        stateFile: statePath,
        logFile: helperLogPath,
        lastRunFile: lastRunPath,
        cancelFile: cancelPath,
        requestedBy: requesterSessionId,
        // ★ 2026-10-13：**本次重启要不要续接**（由排重启的模型自己选，见 resume 参数说明）。
        //   写进计划 → 助手写进 last-run.json → 插件起来后按它决定叫不叫醒。
        //   默认 true（绝大多数情况活没干完，要接着干）。
        resume: resumeWanted,
        // ── 这几项要让助手也看得到（它要按同样的规则判断"等多久该提醒"）──────
        notifyAfterMinutes: Math.max(0, Number(config.notifyAfterMinutes ?? 20) || 0),
        notifyRepeat: config.notifyRepeat === true,
        notifyRepeatMinutes: Math.max(1, Number(config.notifyRepeatMinutes ?? 60) || 60),
        // 外部通知命令（空 = 不通知）。助手和插件用同一份，避免两边行为不一致。
        noticeCommand: String(config.noticeCommand ?? ''),
        noticeTimeoutMs: Math.max(1000, Number(config.noticeTimeoutMs) || 30000),
        waitForImDirect: config.waitForImDirect !== false,
        waitForAllSessions: config.waitForAllSessions === true,
        queueMaxMembers: queueMax
      };

      if (!writeJson(planPath, plan)) {
        return { ok: false, message: `计划文件写不进去：${planPath}。检查磁盘与权限。` };
      }
      // 清掉上一次可能遗留的取消标记，否则助手一上来就退出
      try { rmSync(cancelPath, { force: true }); } catch { /* 忽略 */ }

      log(`收到重启请求：planId=${planId}，计划时间 ${scheduledAt}，原因「${plan.reason}」，来源 ${requesterSource}`);

      // ── 启动脱离的助手（用 WMI，**不要**用 Node 的 spawn）───────────────────
      //
      // ⚠️ 2026-10-08 实机实测踩到的大坑，这里是最终修法：
      //
      //   插件原先用 `spawn(powershell, ['-File', HELPER, ...], {stdio:'ignore'})`。
      //   现象：spawn **返回了 PID**、进程退出码还是 0，但助手**什么都没干**
      //   （从不写 helper.log、从不认领计划）。而同一个脚本、同一个计划，
      //   手工在 shell 里跑就完全正常。
      //
      //   逐步排查排除掉的：正/反斜杠路径（都能跑）、沙箱写权限（能写）、
      //   -WindowStyle Hidden（无影响）。
      //   最后定位到：**在这个宿主环境里，Node spawn 出来的 powershell 子进程
      //   实际上是"空跑"的** —— 连最朴素的 `-Command "Write-Output HELLO"` 都
      //   拿不到任何输出，退出码却是 0。
      //   对照实验：**WMI 创建进程完全正常**（ReturnValue=0，副作用真实发生）。
      //
      //   所以改成 WMI 创建（`Win32_Process.Create`）——这也正好和助手脚本
      //   自己"脱离进程"用的是同一套机制，行为一致、少一层不确定性。
      const psExe = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      const launcher = existsSync(psExe) ? psExe : 'powershell.exe';
      const cmdLine = `"${launcher}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "${HELPER}" -PlanFile "${planPath}"`;

      // 计划里先清掉 helperPid，避免把上一次的旧 PID 当成"已有人认领"。
      plan.helperPid = null;
      writeJson(planPath, plan);

      try {
        const created = await launchViaWmi(cmdLine, dirname(HELPER));
        const launcherPid = created?.pid ?? null;

        // 等握手：助手一启动就会把 helperPid 写回计划文件。
        // 最多等 15 秒（它要先脱离，再写回，正常 1-3 秒）。
        let claimed = null;
        const waitUntil = now() + 15000;
        while (now() < waitUntil) {
          await new Promise((r) => setTimeout(r, 400));
          const p = readJson(planPath);
          if (p && p.helperPid) { claimed = p.helperPid; break; }
        }

        if (!claimed) {
          const msg =
            '助手没有认领这份计划（等了 15 秒没等到握手）—— 所以**这次没排上，DSH 未受影响**。' +
            `WMI 返回值=${created?.returnValue ?? '?'}，点火器 PID=${launcherPid ?? '?'}。` +
            '请看 ' + helperLogPath + ' 与 ' + logPath + '。';
          log(`启动助手失败：等待握手超时（WMI 返回 ${created?.returnValue ?? '?'}，点火器 PID=${launcherPid ?? '?'}）`);
          try { rmSync(planPath, { force: true }); } catch { /* 忽略 */ }
          return { ok: false, message: msg, busy };
        }

        log(`助手已认领：planId=${planId}，助手 PID=${claimed}（点火器 PID=${launcherPid ?? '?'}）`);

        const lines = [
          `已安排自我重启（单号 ${planId}）。`,
          `· 计划动手时间：${scheduledAt}（给你 ${delaySec}s + ${bufferSec}s 缓冲先把这轮回复落盘）`,
          `· 第一段先等你这一轮说完（连续 ${plan.idleSeconds}s 没新动静）`,
          `· 第二段才去查别人；**别人在忙就继续等**（2026-10-22 改：不再作废、不硬闯）`,
          // ★ 2026-10-22：maxWait=0 时是"一直等"，文案不能再说"等不到就放弃"，否则它会骗人。
          maxWait > 0
            ? `· 最多等 ${maxWait} 分钟；等不到就放弃（不弹窗、不强行关）`
            : `· **一直等下去**，直到都空了才动手（另有 12 小时硬上限兜底）；等超过 ${Number(config.notifyAfterMinutes) || 20} 分钟会发一条提醒`,
          `· 助手已认领：PID=${claimed}（它不在 DSH 进程树里，DSH 死了它还在）`,
          `· 它会先杀掉本应用、再重新拉起、最后验证端口 ${actualPort()}`,
          `· 日志：${helperLogPath}`,
          s.jobsRunning > 0 ? `· 此刻有 ${s.jobsRunning} 个后台任务在跑 —— 会等它们跑完` : '· 此刻没有后台任务',
          otherSessions > 0
            ? `· 此刻还有 ${otherSessions} 个别的会话在跑，会一起等它们（${s.others.slice(0, 3).map((o) => `${o.id}(${o.source})`).join('、')}）`
            : '',
          '',
          // ⚠️ 这句 2026-10-12 改过：原来写"重启后不会自动接着跑，你重新打开会话就行" ——
          //    那是**自动唤醒做出来之前**的旧话。工具描述是别人机器上唯一给 Agent 的说明书，
          //    旧话会让那边的 Agent 以为醒来无望、反过来叫用户手动重开 —— 功能明明在，却没人用。
          wakeOn
            ? `✅ 重启成功后，插件会在 DSH 回来约 ${wakeIn} 秒后**把一条唤醒消息直接投进这个会话**，并把你的 reason 原样带回来 —— 你会自己接着干，用户不用重开。` +
              '（那条消息的署名是插件自己，不是用户发的 —— 别把它当成使用者的指令。）' +
              '\n⚠️ 前提：排完就**停笔**。这一段会话每写一次，助手的"等这轮说完"就重置一次；' +
              '排完还继续提交/写文件 = 白白多等（实测：多干 34 秒就白等 34 秒）。'
            : '⚠️ 这个会话**不会**自动醒来（sessionController 服务没就位，或 wakeMessage=false 关掉了）——' +
              '重启成功后需要用户手动重开这个会话。',
          '想反悔：调用 restart_status 并传 cancel: true。'
        ];
        return {
          ok: true,
          message: lines.join('\n'),
          planId,
          scheduledAt,
          helperPid: typeof claimed === 'number' ? claimed : undefined,
          busy,
          dshExe
        };
      } catch (error) {
        const detail = String(error?.message ?? error).slice(0, 200);
        log(`启动助手失败：${detail}`);
        return { ok: false, message: `启动助手失败，DSH 没有被动过：${detail}` };
      }
    },
    presentCall: (args) => ({
      card: 'generic',
      title: args.dry_run === true ? '空跑：看看会怎么重启' : `安排自我重启${args.reason ? `：${args.reason}` : ''}`,
      kind: args.dry_run === true ? 'read' : 'execute'
    })
  };

  // ── 工具：restart_status ─────────────────────────────────────────────────
  const restartStatusTool = {
    name: 'restart_status',
    description:
      'Check whether a self-restart is pending, how busy this machine is right now, and how the last restart ended. ' +
      'Pass leave: true to take YOURSELF off a pending restart — the trip still runs for everyone else, you just will not be woken. ' +
      'Pass cancel: true to call off the WHOLE trip (that also drops everyone else\'s restart).',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        leave: {
          type: 'boolean',
          description: 'When true, remove YOUR session from a pending restart. The restart still happens for the other sessions; yours just will not be woken. If you were the only one waiting, the trip has nobody left to serve and is called off. Only affects you.'
        },
        cancel: {
          type: 'boolean',
          description: 'When true, cancel the WHOLE pending restart — everyone on the trip loses it. Use leave: true if you only want out yourself.'
        }
      }
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          ok: { type: 'boolean' },
          message: { type: 'string' },
          pending: { type: 'boolean' },
          jobsRunning: { type: 'number' },
          agentsRunning: { type: 'number' }
        },
        required: ['ok', 'message', 'pending', 'jobsRunning', 'agentsRunning']
      },
      render: (_args, value) => [{ type: 'text', text: value.message }]
    },
    async execute(args, exec) {
      const lines = [];
      const s = survey();

      // ── 下车：只把自己从这趟重启里摘掉 ───────────────────────────────────
      //
      // 【它和 cancel 是两件完全不同的事】
      //   leave  = "这车跟我没关系了" —— 只影响调用者自己：
      //            车上还有别人 → 照常发车，只是不叫醒我；
      //            摘完没人了 → 这趟本来就没人为它等了，自然不发车。
      //   cancel = "这趟别开了" —— 影响整趟车上的所有人。
      //
      // 【为什么不干脆用 cancel 代替】
      //   因为那样"我不想被叫醒"会误伤别人：一个会话不想被叫醒，就把整趟车打掉。
      //   这不是假设 —— 排队之后车上可能同时有好几个会话，各排各的事。
      if (args.leave === true) {
        const pending = readJson(planPath);
        const me = String(exec?.agent?.id ?? '').trim();
        if (!pending) {
          return {
            ok: true,
            pending: false,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: '当前没有待执行的重启 —— 你不用下车（本来就不在车上）。'
          };
        }
        if (!me) {
          return {
            ok: false,
            pending: true,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: '读不到当前会话 id，没法确定"我"是谁 —— 这次不摘。'
          };
        }

        const members = Array.isArray(pending.members) && pending.members.length > 0
          ? pending.members.slice()
          : (pending.requestedBy ? [{ sessionId: pending.requestedBy, reason: pending.reason }] : []);
        const idx = members.findIndex((m) => String(m?.sessionId ?? '') === me);
        if (idx < 0) {
          return {
            ok: true,
            pending: true,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: `你本来就不在这趟重启的名单上，不用下车。\n` +
              `（车上还有 ${members.length} 个会话，跟你无关。）`
          };
        }

        const rest = members.filter((m) => String(m?.sessionId ?? '') !== me);

        // 摘完没人了 → 这趟车没有服务对象，直接封口（不发车）。
        // ⚠️ 这里**不是"取消别人的重启"** —— 剩下 0 个人，本来就没有别人。
        if (rest.length === 0) {
          try { rmSync(planPath, { force: true }); } catch { /* 忽略 */ }
          try {
            if (existsSync(cancelPath)) rmSync(cancelPath, { force: true });
          } catch { /* 忽略 */ }
          // 助手读不到计划文件会自己退出（见 bin 里"计划文件已经没了 → 我退出"那段）
          log(`下车：${me} 是名单上最后一个人 → 这趟没人等了，直接封口（不发车）`);
          return {
            ok: true,
            pending: false,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: '你是这趟车上的最后一个人，摘完就没有人等它了 —— 所以这次重启直接作罢，不会发车。\n' +
              '（DSH 没有被动过；要重启的话重新排一次即可。）'
          };
        }

        // 车上还有别人 → 只摘自己，车照开
        const nextPlan = { ...pending, members: rest };
        // 老字段 requestedBy 是 members[0] 的镜像；摘掉的正是它时要重新指一个，否则名单/镜像会打架。
        if (String(pending.requestedBy ?? '') === me) {
          nextPlan.requestedBy = String(rest[0]?.sessionId ?? '');
          nextPlan.sessionFile = rest[0]?.sessionFile ?? '';
          nextPlan.reason = rest[0]?.reason ?? '';
          nextPlan.resume = rest[0]?.resume;
        }
        if (!writeJson(planPath, nextPlan)) {
          return {
            ok: false,
            pending: true,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: `名单写不回去（${planPath}）—— 这次没摘成，你还在车上。`
          };
        }
        // 标题图标：摘掉自己的（下一拍对账也会兜底摘，这里当场摘掉更跟手）
        let unstripped = false;
        try { unstripped = !setSessionTitleMark(me, null); } catch { unstripped = true; }
        log(`下车：${me} 已从名单摘掉（还剩 ${rest.length} 人，车照开）`);
        return {
          ok: true,
          pending: true,
          jobsRunning: s.jobsRunning,
          agentsRunning: s.agentsRunning,
          message: `已经把你从这趟重启里摘掉了 —— 车照常开，只是**不会叫醒你**。\n` +
            `（车上还剩 ${rest.length} 个会话：${rest.slice(0, 5).map((m) => m?.sessionId).join('、')}` +
            `${rest.length > 5 ? ' 等' : ''}）` +
            (unstripped ? '\n（标题图标还没摘掉，下一拍会自动重试。）' : '')
        };
      }

      // 取消
      if (args.cancel === true) {
        const pending = readJson(planPath);
        if (!pending) {
          // ★ 2026-10-23：顺手把**残留的取消标记**清掉。
          //   没有待执行的计划 = 没什么可取消的，可 cancel.flag 若还留着，
          //   会把**下一趟车**在上车那一刻就拦下来（2026-10-23 实际踩到过）。
          let cleaned = false;
          try { if (existsSync(cancelPath)) { rmSync(cancelPath, { force: true }); cleaned = true; } } catch { /* 忽略 */ }
          return {
            ok: true,
            pending: false,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: '当前没有待执行的重启，不用取消。' +
              (cleaned ? '\n（顺手清掉了上一趟留下的 cancel.flag —— 留着它会把下一次重启也拦下来。）' : '')
          };
        }
        // 取消是**整趟**的 —— 先把车上几个人说清楚，别让它在不知情的情况下打掉别人。
        const members = Array.isArray(pending.members) && pending.members.length > 0
          ? pending.members
          : [{ sessionId: pending.requestedBy, reason: pending.reason }];
        try {
          writeFileSync(cancelPath, `cancelled at ${new Date().toISOString()}\n`, 'utf8');
          log(`用户/Agent 取消了重启：planId=${pending.planId}（整趟 ${members.length} 人）`);
          // ★ 2026-10-23：**兜底封口**。
          //   正常的收尾由助手的 Close-Trip 做（删计划 + 清标记），但它可能已经不在、
          //   或者正卡在某个 sleep 里 —— 那盘上就会留下"已取消 + 待执行"这对矛盾。
          //   实测后果：另一个会话看到假状态，判断失误，把两个人的重启一起打掉。
          //   ⇒ 这里给一个**限时**兜底：只在助手已经不在（或超过 60 秒还没收）时，
          //     由插件自己把这一趟封口。绝不在助手还活着时抢它的计划文件。
          let swept = false;
          try {
            const hpid = Number(pending.helperPid);
            // ⚠️ 三种状态要分开：
            //   · helperPid 有值且进程不在 → 僵尸，可以封口（这是我们唯一该动手的情况）
            //   · helperPid 有值且进程还在 → 交给它自己（它每轮都查取消标记）
            //   · helperPid 还是空的     → 正在点火/握手，**绝不许抢**：
            //     此刻删计划会把刚启动的助手变成孤儿（它读不到计划就退出）。
            const hasPid = Number.isFinite(hpid) && hpid > 0;
            const helperAlive = hasPid
              ? (() => { try { process.kill(hpid, 0); return true; } catch { return false; } })()
              : null;
            if (helperAlive === false) {
              rmSync(planPath, { force: true });
              swept = true;
              log('取消兜底：计划点名的助手已经不在 → 插件自己把计划文件封口了（避免"已取消+待执行"同时成立）');
            } else if (helperAlive === true) {
              log(`取消兜底：助手 PID=${hpid} 还在，交给它自己封口（它会删计划 + 清标记）`);
            } else {
              log('取消兜底：计划里还没有助手 PID（正在点火/握手）—— 不抢，交给它启动后自己看取消标记');
            }
          } catch (e) {
            log(`取消兜底失败（不影响取消本身）：${String(e?.message ?? e).slice(0, 120)}`);
          }
          return {
            ok: true,
            pending: false,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: `已取消待执行的重启（单号 ${pending.planId}）。` +
              `⚠️ 这是**整趟取消**：车上 ${members.length} 个人的这次重启**一起作废**：` +
              members.map((m, i) => `${i + 1}) ${m?.sessionId ?? '?'}`).join('；') +
              '。助手会在动手前看到取消标记并退出，DSH 不受影响。' +
              (swept ? '\n（这次助手已经不在，我已经替它把计划文件收干净了。）' : '')
          };
        } catch (error) {
          return {
            ok: false,
            pending: true,
            jobsRunning: s.jobsRunning,
            agentsRunning: s.agentsRunning,
            message: `写取消标记失败：${String(error?.message ?? error).slice(0, 160)}`
          };
        }
      }

      // 待执行的重启
      const pending = readJson(planPath);
      if (pending && pending.planId) {
        const when = pending.scheduleAt ?? '（没写时间）';
        // ── ★ 2026-10-23 新增：**把整份名单摊开**（这次事故的正解）──────────────
        //
        // 【为什么必须在这里列出所有人】
        //   17:54 那次：B 会话排上了，工具回包却被判非法（queueLength 没声明）→
        //   它来查状态，看到的只有 `pending.reason`（= **A 的理由**，夜间模式那个）。
        //   于是它得出"这是一趟跟我无关的旧车"→ cancel → **把 A 和它自己一起打掉**。
        //   它当时的推理没有错，是**这条状态信息不足**：只印第一个人的理由，
        //   第二个人在这里根本看不到自己的名字。
        //
        // 【新口径】
        //   · 逐条列出 members[]：谁、什么理由、是不是"你"（调用者自己）；
        //   · 明确写"取消是整趟的"；
        //   · 顺带识别**僵尸计划**（点名的助手已经不在）—— 那种情况要劝它别糟蹋这趟车，
        //     而是按"重开一趟"处理。
        const reqBy = String(pending.requestedBy ?? '');
        const callerId = String(exec?.agent?.id ?? '');
        const members = Array.isArray(pending.members) && pending.members.length > 0
          ? pending.members.slice()
          : [{ sessionId: reqBy, reason: pending.reason ?? '', resume: pending.resume, joinedAt: pending.createdAt, source: 'unknown' }];
        lines.push(`有待执行的重启：单号 ${pending.planId}（这趟车 ${members.length} 人）`);
        lines.push(`· 计划动手时间：${when}`);
        // 已等多久：从 createdAt 现算（"按需优于自刷"—— 不落盘、每次读时算）
        const createdMs = Date.parse(String(pending.createdAt ?? ''));
        if (Number.isFinite(createdMs)) {
          const waitedMin = Math.max(0, (now() - createdMs) / 60000);
          lines.push(`· 已经等了 ${waitedMin < 1 ? `${Math.round(waitedMin * 60)} 秒` : `${waitedMin.toFixed(1)} 分钟`}` +
            `（它一直在等"所有人都闲下来"，**没有动手**）`);
        }
        lines.push('· 车上的人（每人一条，各是各的理由）：');
        for (let i = 0; i < members.length; i++) {
          const m = members[i];
          const sid = String(m?.sessionId ?? '?');
          const isMe = callerId && sid === callerId;
          const why = String(m?.reason ?? '（没写）').replace(/\s+/g, ' ');
          // ★ 2026-10-24：名字优先、短 id 垫后 —— 人看名字，Agent 需要 id 时还在。
          const mTitle = readSessionTitle(sid);
          const sidShort = sid.length > 16 ? `${sid.slice(0, 8)}…${sid.slice(-4)}` : sid;
          lines.push(`   ${i + 1}. ${mTitle ? `「${mTitle}」` : '(没拿到名字)'}  ${sidShort}${isMe ? '  ← **你**' : ''}`);
          lines.push(`      理由：${why.length > 100 ? `${why.slice(0, 100)}…` : why}`);
        }
        // 僵尸计划：计划里点名的助手 PID 已经不在了 → 这趟车其实没人开
        const helperPid = Number(pending.helperPid);
        let helperAlive = null;   // null = 还没握手 / 无法判断
        if (Number.isFinite(helperPid) && helperPid > 0) {
          try { process.kill(helperPid, 0); helperAlive = true; } catch { helperAlive = false; }
        }
        if (helperAlive === false) {
          lines.push('· ⚠️ **僵尸计划**：点名的助手进程（PID=' + helperPid + '）已经不在了 —— ' +
            '这趟车**没人会开**。下一次 `restart_self` 会自动清掉它并重开一趟；' +
            '**不要**用 cancel 来处理它（那只是空转一圈，还会把别人一起带走）。');
        } else if (helperAlive === true) {
          lines.push(`· 助手在跑：PID=${helperPid}（它不在 DSH 进程树里，DSH 死了它还在）`);
        }
        lines.push(`· 判据：先等每个人这一轮说完（连续 ${pending.idleSeconds}s${helperAlive === false ? '；这是计划里写的值' : ''}），再查别人；` +
          `${Number(pending.maxWaitMinutes) > 0 ? `最多等 ${pending.maxWaitMinutes} 分钟` : '**一直等下去**（12 小时硬上限）'}`);
        // 让用户/Agent 一眼知道"起来后叫不叫得醒"（口径和排重启时一致：服务在且没被配置关掉）
        const rawRd = Number(config.wakeDelaySeconds);
        const wakeOk = config.wakeMessage !== false && Boolean(sessionController);
        lines.push(wakeOk
          ? `· 起来后约 ${Number.isFinite(rawRd) ? Math.max(0, Math.round(rawRd)) : 3}s 把唤醒消息投进**名单上每个人**的会话（各拿各的理由；署名是插件自己）`
          : '· 起来后**不会**自动叫醒（sessionController 没就位 / wakeMessage=false）—— 需手动重开会话');
        lines.push(`· ⚠️ 想反悔：调 restart_status 并传 cancel: true —— 那会取消**整趟车（上面 ${members.length} 个人一起作废）**。`);
        if (members.length > 1) {
          lines.push('  也就是说：你要是这趟车上的第二个人，取消 = 把**第一个人的重启也打掉**。' +
            '只想等它开走，就什么都别做。');
        }
      } else {
        lines.push('当前没有待执行的重启。');
      }

      // 现在忙不忙
      lines.push('');
      if (s.jobsRunning === 0 && s.agentsRunning === 0) {
        lines.push('此刻：没有后台任务、没有在跑的会话 —— 是重启的好时机。');
      } else {
        lines.push(`此刻：${s.jobsRunning} 个后台任务、${s.agentsRunning} 个会话在跑。`);
        // ★ 2026-10-22：把"放弃"改成"一起等"，措辞必须同步改 ——
        //   工具说明是别的机器上**唯一**给 Agent 的说明书，文案不改就是骗人。
        lines.push('· 后台任务：会等它跑完');
        lines.push('· 别的会话在跑：**照常排上，等它们也闲下来一起发车**（不再作废）');
        for (const d of s.details) lines.push(`· ${d}`);
      }

      // 上次重启的结果
      const last = readJson(lastRunPath);
      if (last && last.finishedAt) {
        const verdict =
          last.outcome === 'success' ? '成功'
          : last.outcome === 'cancelled' ? '被取消'
          : last.outcome === 'skipped-busy' ? '没执行（当时一直有任务在跑）'
          : '失败';
        lines.push('');
        lines.push(`上次自我重启：${verdict}（${last.finishedAt}，耗时 ${last.tookSeconds}s，${last.by === 'watchdog' ? '由保险丝完成' : '由助手完成'}）`);
        lines.push(`· ${last.detail}`);
      }

      // ★ 2026-10-13 加：重启流水账的汇总 —— **在这里现算**（不在后台统计，见 readHistorySummary 的说明）
      const hist = readHistorySummary();
      if (hist && hist.samples > 0) {
        lines.push('');
        lines.push(`重启流水账：共记 ${hist.total} 次（成功 ${hist.ok} 次）`);
        lines.push(`· 「关掉 → 重新起来」这段：最快 ${hist.fastest}s / 最慢 ${hist.slowest}s / 中位 ${hist.median}s（${hist.samples} 次样本）`);
        lines.push('· （这段才是这台机器的重启速度。总耗时里的大头是"等我这一轮说完"，跟机器快慢无关。）');
      } else if (hist && hist.total > 0) {
        lines.push('');
        lines.push(`重启流水账：共记 ${hist.total} 次，其中成功 ${hist.ok} 次（还没有可用的"关掉→起来"样本）。`);
      }

      return {
        ok: true,
        pending: Boolean(pending && pending.planId),
        jobsRunning: s.jobsRunning,
        agentsRunning: s.agentsRunning,
        message: lines.join('\n')
      };
    },
    presentCall: (args) => ({
      card: 'generic',
      title: args.cancel === true ? '取消待执行的重启' : '查看自我重启状态',
      kind: args.cancel === true ? 'execute' : 'read'
    })
  };

  // ══════════════════════════════════════════════════════════════════════════
  // 【2026-10-23 加】输出护栏：**声明之外的字段一律剔除，并在日志里喊一声**
  //
  // 【为什么需要这一层 —— 一次真事故换的】
  //   插件返回 `{ ok, message, planId, …, queueLength }`，而 `output.schema` 里
  //   没声明 `queueLength`。宿主的输出校验按 `additionalProperties: false` 处理，
  //   于是**整份回包被拒**：Agent 收到的是一句
  //       Error: tool "restart_self" returned invalid output:
  //       "value.queueLength" is not a declared property (additionalProperties: false)
  //
  //   最恶劣的地方在于**副作用已经发生了**：计划写了、助手点火了、队列真加上了 ——
  //   可调用方看到的是"失败"。于是它以为没排上，去查状态、去手工改文件，
  //   最后把整趟队列取消掉（2026-10-23 17:54 实机事故：两个人一起被打了）。
  //
  //   ⇒ 方向要对：**"活干了却回一句失败"比"少返回一个字段"危险得多。**
  //     所以这里宁可少一个字段，也绝不让整份回包被拒；同时把"漏声明"记进日志，
  //     让它在测试与实机里都留下证据（静默剔除又变成另一种"假绿"，不干）。
  //
  //   ⚠️ 只处理**顶层**字段：这次的事故形态就是顶层多字段，深一层的东西照原样过。
  //      真需要改深层结构时，应当先补 schema，别指望这层兜。
  // ══════════════════════════════════════════════════════════════════════════
  const guardDeclaredFields = (tool) => {
    const declared = new Set(Object.keys(tool?.output?.schema?.properties ?? {}));
    if (declared.size === 0 || typeof tool?.execute !== 'function') return tool;
    const inner = tool.execute;
    return {
      ...tool,
      execute: async function guardedExecute(args, exec) {
        const value = await inner(args, exec);
        if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
        const extra = Object.keys(value).filter((k) => !declared.has(k));
        if (extra.length === 0) return value;
        log(
          `⚠️ 输出里有 ${extra.length} 个字段没在 output.schema 里声明，已剔除（否则宿主会整份拒收）：` +
          `${extra.join('、')} —— 请把它们补进 ${tool.name} 的 output.schema`
        );
        const clean = {};
        for (const k of declared) {
          if (Object.prototype.hasOwnProperty.call(value, k)) clean[k] = value[k];
        }
        return clean;
      }
    };
  };

  const disposers = [];
  try {
    disposers.push(ctx.tools.register(guardDeclaredFields(restartSelfTool)));
    disposers.push(ctx.tools.register(guardDeclaredFields(restartStatusTool)));
    log('工具已注册：restart_self / restart_status（输出字段护栏已启用）');
  } catch (error) {
    log(`注册工具失败：${String(error?.message ?? error)}`);
  }

  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => {
      try { clearInterval(stateTimer); } catch { /* 忽略 */ }
      // ⚠️ 这一圈**不许删**（2026-10-13 改上面那段时误删过一次）：
      //    它注销两个工具。少了它，热加载后新旧两代工具会并存（旧的那份还占着工具表）。
      for (const dispose of disposers) {
        try { dispose(); } catch { /* 忽略 */ }
      }
      log('插件已卸载：自我重启能力已移除。');
    });
  }
}

// ⚠️ 导出这些是为了**可测试性**（本模块的测试直接 import 它们，而不是去抠源码文本）：
//   · makeWakeMessage —— 投递用的消息对象长什么样，是"当年那次事故会不会重演"的关键，
//     必须能用真函数验，而不是靠正则去猜。见 test/test-wake-message.mjs。
//   · IMPL_VERSION  —— "跑的是新代码吗"的探针，测试要对账。
export { Config, detectDshExe, HELPER, HOME_DSH, makeWakeMessage, deepFreeze };


