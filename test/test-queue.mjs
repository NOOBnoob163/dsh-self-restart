/**
 * test-queue.mjs —— 排队重启那批新逻辑的单元测试
 *
 * 2026-10-22 建立。配套决策：docs\decisions-restart-queue.md
 *
 * 【为什么要有它】
 *  这批改动里有三样东西的 bug 都是**静默**的 —— 不报错、只偶尔不对，
 *  而那正是这个插件历史上最贵的一类问题：
 *    ① 会话来源判据（判错 → 该等的不等，或该走的不走）；
 *    ② 标题标记（加错了 → 用户看到的和实际不符；摘不掉 → 永远挂着）；
 *    ③ 唤醒名单（漏人 → 排了队却醒不过来；重复 → 同一件活干两遍）。
 *
 * 【怎么跑】
 *  node test\test-queue.mjs          正常跑
 *  node test\test-queue.mjs --break  改坏自检：故意掰坏判据，确认断言会变红
 *
 * 退出码 0 = 全过；1 = 有失败；--break 模式下 0 = 成功变红（说明断言有效）。
 */

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(dirname(HERE), 'lib', 'index.js');
const BREAK = process.argv.includes('--break');

let pass = 0;
let fail = 0;
const failed = [];

function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; failed.push(name); console.log(`  ❌ ${name}  得到 ${JSON.stringify(got)}  期望 ${JSON.stringify(want)}`); }
}

// ── 从插件源码里把被测的纯函数抠出来（不加载整个插件模块）────────────────────
const src = readFileSync(LIB, 'utf8');

function extract(startNeedle, endNeedle) {
  const s = src.indexOf(startNeedle);
  if (s < 0) throw new Error(`找不到起点：${startNeedle}`);
  const e = src.indexOf(endNeedle, s);
  if (e < 0) throw new Error(`找不到终点：${endNeedle}`);
  return src.slice(s, e);
}

// ① 会话来源判据
const sourceFrag = extract('const UUID_RE =', '/**\n * 把 DSH 的会话 id 映射到盘上的会话记录文件');
if (BREAK) {
  // 掰坏：把所有带前缀的都当成 local
  console.log('\n*** 改坏自检：把"带前缀"的判成 local（预期下面会红）***\n');
}
const sourceMod = new Function(
  (BREAK ? sourceFrag.replace("if (UUID_RE.test(rpcId)) return 'local';", "return 'local';") : sourceFrag)
  + '\nreturn { sessionSourceOf };'
)();
const { sessionSourceOf } = sourceMod;

// ② 标题标记
// ⚠️ 直接从源码抠 `stripTitleMark` 与 `TITLE_MARKS` —— **不要在这里重写一份实现**。
//    重写会跟源码漂移：源码改了、测试还按老逻辑断言，于是"测试全绿但功能坏了"。
//
// ★ 2026-10-23：标记改成"只留图标"（♻️ / 🔴），并且剥离改成**循环剥**（能剥多个）。
//   所以这里抠的范围要跟着变：从 MARK_RECYCLE 开始，到 setSessionTitleMark 结束。
//   ⚠️ 原来抠的是 `const TITLE_MARKS =`，那段已经不存在了（改成 MARK_RECYCLE / MARK_FAILED
//      + LEGACY 列表），按老锚点抠会直接抛错 —— 这正是"锚点跟着实现走"的代价。
const markFrag = extract('const MARK_RECYCLE =', 'const readPendingPlan =');
// new Function 的**第一个字符串参数是形参列表**，函数体必须放最后。
// ⚠️ 2026-10-25：范围延到 `const readPendingPlan =`，把**源码里真的** setSessionTitleMark
//    也一起抠进来（以前这里抄了一份 applyMark，两边一改就漂移）。
//    它只依赖 `sessions` / `log` 两个闭包变量，用形参喂假实现即可。
const marksMod = new Function('sessions', 'log', markFrag + `
return { MARK_RECYCLE, MARK_FAILED, LEGACY_TITLE_MARKS, TITLE_MARK_PREFIXES,
         CHANNEL_LABELS, CHANNEL_PREFIXES, splitTitle, stripTitleMark, composeTitle,
         setSessionTitleMark };`)(
  // 假 sessions：就是上面 makeSess 造的那些，按 id 登记
  { get: (id) => SESS.get(id) },
  () => {},
);
const {
  MARK_RECYCLE, MARK_FAILED, LEGACY_TITLE_MARKS, TITLE_MARK_PREFIXES,
  CHANNEL_LABELS, CHANNEL_PREFIXES, splitTitle, stripTitleMark, composeTitle, setSessionTitleMark,
} = marksMod;

const SESS = new Map();

const makeSess = (title) => {
  const events = [{ type: 'session/title', data: { title, messageSeqs: [], source: { kind: 'fallback' } } }];
  const sess = {
    snapshotEvents: () => events,
    append: (type, data) => { events.push({ type, data }); return events.length; },
    _events: events,
  };
  return sess;
};

/** 造一个登记进假 sessions 的会话，返回 [id, sess] */
const newSess = (id, title) => {
  const s = makeSess(title);
  SESS.set(id, s);
  return s;
};

// ⚠️ 这里**不再抄一份实现**，直接调源码里那个 setSessionTitleMark（2026-10-25 改）。
const applyMark = (sess, mark, id = 'sid') => {
  SESS.set(id, sess);
  return setSessionTitleMark(id, mark);
};
const lastTitle = (sess) => sess.snapshotEvents().at(-1).data.title;

// ── 模拟「频道插件」给标题加前缀的行为（判据取自常见实现）──────────────
//   if (labels.some((label) => title.startsWith(`${label} · `))) return title;
//   return `${label} · ${title}`;
// 这一段**故意照抄**：要测的就是"两个插件同时跑会不会互相喂"。
const dshImDecorate = (title, label = 'QQ') => {
  if (title.startsWith(`${label} · `)) return title;
  return `${label} · ${title}`;
};

console.log('\n=== ① 会话来源判据（rpcId）===');
const ev = (rpcId, conv) => {
  const out = [{ type: 'user/message', data: { source: { kind: 'user', rpcId } } }];
  if (conv) out.push({ type: 'user/message', data: { content: [{ text: `"conversationType":"${conv}"` }] } });
  return out;
};
check('纯 UUID → local', sessionSourceOf({ snapshotEvents: () => ev('b7b237f0-cd9d-46b0-9a32-905eddd3e07a') }), 'local');
check('qq 私聊 → im-direct', sessionSourceOf({ snapshotEvents: () => ev('qq-d9d1eeee-6fe2-4b0e-a634-30f7582f398a', 'direct') }), 'im-direct');
check('qq 群聊 → im-group', sessionSourceOf({ snapshotEvents: () => ev('qq-abc', 'group') }), 'im-group');
check('有前缀但不知类型 → im-direct（保守：会等）', sessionSourceOf({ snapshotEvents: () => ev('qq-xyz') }), 'im-direct');
check('没有 rpcId → unknown', sessionSourceOf({ snapshotEvents: () => ev(undefined) }), 'unknown');
check('空事件 → unknown', sessionSourceOf({ snapshotEvents: () => [] }), 'unknown');
check('不是数组 → unknown', sessionSourceOf({ snapshotEvents: () => null }), 'unknown');
check('没有 snapshotEvents 也没有 events → unknown', sessionSourceOf({}), 'unknown');

console.log('\n=== ② 标题标记 ===');
// ★ 2026-10-23 改：标记只剩「图标」，不再带「待重启」四个字。
check('★ 在重启的标记 = 只有图标，不含文字', MARK_RECYCLE, '♻️ ');
check('★ 失败标记 = 只有图标，不含文字', MARK_FAILED, '⭕ ');
check('旧版带字前缀仍被认（用于剥掉历史标记）', LEGACY_TITLE_MARKS.includes('♻️ 待重启 · '), true);
check('三个标记都在前缀清单里', TITLE_MARK_PREFIXES.length, 2 + LEGACY_TITLE_MARKS.length);

check('剥标记：新图标能剥', stripTitleMark(MARK_RECYCLE + '原标题'), '原标题');
check('剥标记：失败图标能剥', stripTitleMark(MARK_FAILED + '原标题'), '原标题');
check('★ 剥标记：旧版带字前缀也能剥（老会话树兼容）', stripTitleMark('♻️ 待重启 · 原标题'), '原标题');
check('★ 剥标记：叠了两层也能一次剥干净（循环剥）', stripTitleMark(MARK_RECYCLE + MARK_FAILED + 'x'), 'x');
check('★ 剥标记：旧+新混着叠也能剥干净', stripTitleMark('♻️ 待重启 · ' + MARK_RECYCLE + 'x'), 'x');
check('剥标记：没标记时原样', stripTitleMark('原标题'), '原标题');
check('剥标记：别的前缀不误伤', stripTitleMark('QQ · 示例群聊'), 'QQ · 示例群聊');

// ── ★ 2026-10-25：和别的插件抢标题的回归测试（见 lib/index.js 那段注释）──
console.log('\n=== ②-b 与频道前缀共存（不许互相喂）===');
check('拆标题：无前缀', splitTitle('示例群聊'), { channel: '', body: '示例群聊' });
check('拆标题：QQ 前缀', splitTitle('QQ · 示例群聊'), { channel: 'QQ · ', body: '示例群聊' });
check('拆标题：图标在频道前缀前面（旧 bug 形状）', splitTitle('♻️ QQ · 示例群聊'),
  { channel: 'QQ · ', body: '示例群聊' });
check('拆标题：图标在频道前缀后面（新形状）', splitTitle('QQ · ♻️ 示例群聊'),
  { channel: 'QQ · ', body: '示例群聊' });
check('★ 拆标题：历史脏标题（叠了 6 层）也能剥回原样',
  splitTitle('QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · ♻️ QQ · 示例会话'),
  { channel: 'QQ · ', body: '示例会话' });
check('拆标题：正文里的「A · B」不当频道前缀（微信在 QQ 后面 → 正文）',
  splitTitle('QQ · 微信 · 正文'), { channel: 'QQ · ', body: '微信 · 正文' });
check('★ 频道标签清单认全（常见渠道标签都在里面）',
  CHANNEL_LABELS.length, 16);
check('频道前缀按长度从长到短排（企业微信不会被微信截胡）',
  CHANNEL_PREFIXES[0].length >= CHANNEL_PREFIXES.at(-1).length, true);

check('★ 加图标：图标排在「QQ · 」**后面**（频道前缀判据要成立）',
  composeTitle('QQ · 示例群聊', MARK_RECYCLE), 'QQ · ♻️ 示例群聊');
check('加图标：本地会话（无前缀）图标仍在最前', composeTitle('原标题', MARK_RECYCLE), MARK_RECYCLE + '原标题');
check('摘图标：QQ 前缀留着', composeTitle('QQ · ♻️ 示例群聊', null), 'QQ · 示例群聊');
check('★★ 加图标后频道插件不会再补一个前缀（这正是互相抢的判据）',
  dshImDecorate(composeTitle('QQ · 示例群聊', MARK_RECYCLE)), 'QQ · ♻️ 示例群聊');
check('★★ 历史脏标题：加一次图标就收敛成两层（不再增长）',
  composeTitle('QQ · ♻️ QQ · ♻️ QQ · 示例会话', MARK_RECYCLE), 'QQ · ♻️ 示例会话');
check('★★ 历史脏标题：摘图标直接还原成干净标题',
  composeTitle('QQ · ♻️ QQ · ♻️ QQ · 示例会话', null), 'QQ · 示例会话');

// ★ 真·互相喂模拟：两个插件各跑 N 轮，标题长度必须收敛（不是每轮 +5）
{
  let title = '示例会话';
  const lengths = [];
  for (let i = 0; i < 6; i += 1) {
    // 我们这一拍：加上 ♻️（源码里真函数，走 append）
    const sess = makeSess(title);
    applyMark(sess, MARK_RECYCLE, 'war');
    title = lastTitle(sess);
    // 频道插件看到 session/title 事件后的反应
    title = dshImDecorate(title);
    lengths.push(title.length);
  }
  check('★★ 两个插件交替跑 6 轮：标题长度收敛（不每轮增长）',
    new Set(lengths.slice(1)).size, 1);
  check('★★ 收敛后的标题形状正确', title, 'QQ · ♻️ 示例会话');
}

let s = newSess('s-main', '排队重启机制设计讨论');
check('加标记返回值', applyMark(s, MARK_RECYCLE, 's-main'), true);
check('加标记后的标题', lastTitle(s), MARK_RECYCLE + '排队重启机制设计讨论');
check('摘标记返回值', applyMark(s, null, 's-main'), true);
check('摘标记后的标题', lastTitle(s), '排队重启机制设计讨论');

// ★ 状态切换：⭕ → ♻️ 必须能换过去（不留两个图标）
s = newSess('s-failed', '失败过的会话');
applyMark(s, MARK_FAILED, 's-failed');
check('先挂失败图标', lastTitle(s), MARK_FAILED + '失败过的会话');
applyMark(s, MARK_RECYCLE, 's-failed');
check('★ 失败图标能被「在重启」顶替（不会两个都在）', lastTitle(s), MARK_RECYCLE + '失败过的会话');

s = newSess('s-idem', '待重启的会话');
applyMark(s, MARK_RECYCLE, 's-idem');
const n1 = s._events.length;
applyMark(s, MARK_RECYCLE, 's-idem');
check('重复加是幂等的（不追加第二条）', s._events.length, n1);

s = newSess('s-qq', 'QQ · 示例群聊');
applyMark(s, MARK_RECYCLE, 's-qq');
check('★ 与「QQ · 」前缀共存（图标在后）', lastTitle(s), 'QQ · ♻️ 示例群聊');
const n2 = s._events.length;
applyMark(s, MARK_RECYCLE, 's-qq');
check('★ QQ 会话重复加也幂等（不会每拍追加）', s._events.length, n2);
applyMark(s, null, 's-qq');
check('摘掉后频道前缀还在', lastTitle(s), 'QQ · 示例群聊');

check('没有标题的会话 → 不改', applyMark({ snapshotEvents: () => [], append: () => 1 }, MARK_RECYCLE, 's-empty'), false);
check('会话没有 append → 不崩',
  applyMark({ snapshotEvents: () => [{ type: 'session/title', data: { title: 'x' } }] }, MARK_RECYCLE, 's-noappend'), false);

// ── ③ 标题标记的**对账**（2026-10-23 修「重启完图标撤不掉」后加的）──────────
//
// 病根：旧逻辑只有"计划文件"一个数据来源。重启成功后助手把 plan.json 删了，
//       下一拍算出的待摘名单是空集 → 谁都摘不掉 → 图标永远挂着。
//       （证据：plugin.log 里「已给…加上」8 次，「已摘掉」0 次。）
// 修法：记账本 `title-marks.json`，每拍对账。
//
// ⚠️ 这里测的是**源码里那个真函数**（reconcileMarked），不是抄一份逻辑 ——
//    抄一份就只能验"我理解的规则"，验不到"代码是不是这么做的"。
console.log('\n=== ③ 标题标记对账（图标能不能撤掉）===');
const recFrag = extract('const reconcileMarked = ', '\n  };');
// ⚠️ extract 的终点是那个 `};`，所以抠出来的片段**缺函数收尾**，要补回去
const reconcileMarked = new Function(recFrag + '\n  };' + '\nreturn reconcileMarked;')();

// 造一个"会记事"的 apply：记录每次调用，模拟会话标题
const makeApply = () => {
  const calls = [];
  return {
    calls,
    fn: (id, mark) => { calls.push([id, mark]); return true; }
  };
};

{
  // 场景 A：重启成功——计划没了，账上有这个人 → 必须摘掉
  const a = makeApply();
  const r = reconcileMarked({
    desired: new Set(),
    marked: new Set(['s1']),
    want: null,
    apply: a.fn
  });
  check('★ 计划消失后，账上的人被摘掉', r.stripped, 1);
  check('★ 摘的时候传的是 null（= 去掉图标）', a.calls[0], ['s1', null]);
  check('★ 摘完账本清空（下次不会再摘）', [...r.next], []);
}

{
  // 场景 B：排队中——该戴的要戴上、并记账
  const a = makeApply();
  const r = reconcileMarked({
    desired: new Set(['s1', 's2']),
    marked: new Set(),
    want: MARK_RECYCLE,
    apply: a.fn
  });
  check('待重启：两个人都戴上', r.added, 2);
  check('待重启：账本记下两个人', [...r.next].sort(), ['s1', 's2']);
  check('待重启：戴的是 ♻️', a.calls[0], ['s1', MARK_RECYCLE]);
}

{
  // 场景 C：重复对账——已经戴好的不再重复写事件（幂等）
  const a = makeApply();
  const r = reconcileMarked({
    desired: new Set(['s1']),
    marked: new Set(['s1']),
    want: MARK_RECYCLE,
    apply: a.fn
  });
  check('重复对账：不重复计新增', r.added, 0);
  check('重复对账：不摘任何人', r.stripped, 0);
}

{
  // 场景 D：摘不掉（apply 永远返回 false）→ **留在账上继续试**，不能划掉。
  //
  // ⚠️ 这条断言在 2026-10-23 上午被**反过来了**，原因是实测推翻了当时的判断：
  //    当时以为"apply 失败 = 会话被删了"，所以划账以免无休止重试。
  //    但实机跑出来的是另一种：会话只是**没被宿主加载**（只有打开的对话才在内存里，
  //    sessions.get 拿不到）→ 摘失败 → 划账 → **那个图标就再也没人管了**。
  //    这正好是「图标撤不掉」的第二种形态。
  //    现在的规矩：摘失败留着下一拍再试；真的无限试不过去，由调用方的
  //    MAX_STRIP_TRIES 兜底放弃（那是 tick 的事，不在这个纯函数里）。
  const dead = { fn: () => false, calls: [] };
  const r = reconcileMarked({
    desired: new Set(),
    marked: new Set(['gone']),
    want: null,
    apply: dead.fn
  });
  check('★ 摘失败要**留在账上**（下次还会再试）', [...r.next], ['gone']);
  check('★ 摘失败要报出来（调用方据此计重试次数）', r.stripFailed, ['gone']);
  check('摘失败不算"已摘"', r.stripped, 0);
}

{
  // 场景 E：♻️ 转 ⭕（失败）——同一个人，图标换掉、账不重复
  const a = makeApply();
  const r = reconcileMarked({
    desired: new Set(['s1']),
    marked: new Set(['s1']),
    want: MARK_FAILED,
    apply: a.fn
  });
  check('♻️ 转 ⭕：不新增、不摘除', [r.added, r.stripped], [0, 0]);
  check('♻️ 转 ⭕：调了 apply 换成失败图标', a.calls[0], ['s1', MARK_FAILED]);
}

{
  // 场景 F：多人排队 → 只有没说话的那个成功重启了，另一个还在等？
  //   实际语义是"计划还在就都戴"，所以这里验"部分人退出"：
  const a = makeApply();
  const r = reconcileMarked({
    desired: new Set(['s1']),
    marked: new Set(['s1', 's2']),
    want: MARK_RECYCLE,
    apply: a.fn
  });
  check('★ 有人不在名单里了 → 只摘他一个', r.stripped, 1);
  check('★ 剩下那个继续戴着', [...r.next], ['s1']);
  check('被摘的正是走掉的那个', a.calls.filter((c) => c[1] === null).map((c) => c[0]), ['s2']);
}

console.log('\n=== ④ 「重启成功但没叫醒」的提醒：什么时候该发（2026-10-25 误报后加的）===');
// 病根（实机 17:26 那条假警报）：插件热重载时 plan.json 里有一趟**还在排队、
// 没发车**的重启，旧判据 sawPendingPlan（= 见过计划文件）就当成"这趟没叫醒"，
// 5 分钟后发出通知，报的却是 6 小时前那趟（单号 restart-mvmqaeav，而它唤醒成功了）。
//
// ⚠️ 测的是源码里那个真函数（shouldNotifyWakeFailure），不是抄一份。
const notifyFrag = extract('const shouldNotifyWakeFailure = ', '\n  };');
const shouldNotifyWakeFailure = new Function(
  notifyFrag + '\n  };' + '\nreturn shouldNotifyWakeFailure;'
)();

// ① 本次根本没到叫醒那步（重启还在排队）→ 不许发
check('★★ 重启还在排队（没到叫醒那步）→ 不发提醒（就是 10-25 那次误报）',
  shouldNotifyWakeFailure({ wakeShouldHappen: false, failReport: null, fresh: null }), false);
check('★★ 排队中 + 盘上有上一趟的陈账 → 也不许发（误报的另一种形态）',
  shouldNotifyWakeFailure({
    wakeShouldHappen: false,
    failReport: null,
    fresh: null,          // 陈账不是 fresh，所以这里是 null
  }), false);
// ② 真的该叫醒、那趟也真完成了，但没投成 → 必须发
check('★ 该叫醒 + 那趟真完成 + 没投成 → 发',
  shouldNotifyWakeFailure({
    wakeShouldHappen: true,
    failReport: null,
    fresh: { planId: 'restart-x' },
  }), true);
// ③ 有攒下的具体失败成员 → 直接发（哪怕 fresh 没读到）
check('★ 有具体投递失败成员 → 发',
  shouldNotifyWakeFailure({
    wakeShouldHappen: false,
    failReport: { targets: [{ sessionId: 's1' }] },
    fresh: null,
  }), true);
check('失败成员为空数组 → 不算（避免"0 个人失败"也发）',
  shouldNotifyWakeFailure({
    wakeShouldHappen: false,
    failReport: { targets: [] },
    fresh: null,
  }), false);
// ④ 该叫醒但还没完成（fresh 为 null）→ 不发
check('该叫醒但重启还没写完结果 → 不发（等下一拍）',
  shouldNotifyWakeFailure({ wakeShouldHappen: true, failReport: null, fresh: null }), false);

// ⑤ freshnessOf 的口径：陈账必须被判 old，新账判 fresh
const freshFrag = extract('const freshnessOf = ', '\n  };');
const makeFreshness = new Function('pluginStartedAt',
  freshFrag + '\n  };' + '\nreturn freshnessOf;');
{
  const startedAt = 1_800_000_000_000;   // 假起点
  const freshnessOf = makeFreshness(startedAt);
  const at = (ms) => new Date(ms).toISOString();
  check('★ 6 小时前的陈账 → old（10-25 误报里那趟就是 6 小时前）',
    freshnessOf(at(startedAt - 6 * 3600e3)), 'old');
  check('★ 本进程启动后完成的 → fresh',
    freshnessOf(at(startedAt + 30e3)), 'fresh');
  check('启动前 1 分钟内完成的 → 仍算 fresh（插件比结果晚挂是实测事实）',
    freshnessOf(at(startedAt - 30e3)), 'fresh');
  check('明显来自未来 → future', freshnessOf(at(startedAt + 10 * 60e3)), 'future');
  check('时间戳坏了 → bad', freshnessOf('not-a-date'), 'bad');
}

console.log('');
if (BREAK) {
  if (fail > 0) {
    console.log(`*** 改坏自检通过：${fail} 条变红了 —— 断言真的盯着代码 ***`);
    process.exit(0);
  }
  console.log('*** 改坏自检失败：掰坏了却一条没红 → 这套断言是假的 ***');
  process.exit(3);
}

console.log(`结果：通过 ${pass} 条，失败 ${fail} 条`);
if (fail > 0) {
  console.log('失败的断言：');
  for (const f of failed) console.log(`  · ${f}`);
  process.exit(1);
}
process.exit(0);
