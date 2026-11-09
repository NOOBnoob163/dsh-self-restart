/**
 * test-nudge.mjs —— 「排队太久，劝挡路的人一起上车」那套判定的单元测试
 *
 * 2026-11-09 建立。配套决策：docs\decisions-restart-nudge.md
 *
 * 【为什么要有它】
 *  这套改动的 bug 全都是**静默**的 —— 不报错、只是"该劝的没劝"或"不该劝的劝了"：
 *    ① 阈值判错 → 排队 10 分钟了还是一个人都不劝（等于功能不存在，但日志一片正常）；
 *    ② 来源判错 → 去劝 QQ 私聊，对方在用户手机上回一句"我先让一下"，而那边根本不该被碰；
 *    ③ 重复劝 → 同一趟车里反复注入，把人家刷屏；
 *    ④ 文案缺"失效声明" → 重启早就完成了，那句"快停下来"还被读到，白白停一次。
 *  这四条里**没有一条**会在跑起来时报错，所以必须靠这个文件钉住。
 *
 * 【怎么跑】
 *   node test\test-nudge.mjs          正常跑
 *   node test\test-nudge.mjs --break  改坏自检：故意掰坏判据，确认断言会变红
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

function checkTrue(name, got) {
  const ok = Boolean(got);
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; failed.push(name); console.log(`  ❌ ${name}  期望为真，实际 ${JSON.stringify(got)}`); }
}

// ── 从插件源码里把被测的纯函数抠出来（不加载整个插件模块）────────────────────
// ⚠️ 抠而不是 import：插件模块顶层 import 了 @deepseek-ai/schemastery，
//    那个依赖装在 profiles/desktop/node_modules 下，从开发区 import 会失败。
//    （test-queue.mjs 用的是同一套手法，见那边的说明。）
const src = readFileSync(LIB, 'utf8');

function extract(startNeedle, endNeedle) {
  const s = src.indexOf(startNeedle);
  if (s < 0) throw new Error(`找不到起点：${startNeedle}`);
  const e = src.indexOf(endNeedle, s);
  if (e < 0) throw new Error(`找不到终点：${endNeedle}`);
  return src.slice(s, e);
}

// 被测区间：从 pickNudgeTargets 开始，到 Config 定义之前结束
// （中间那一段就是 pickNudgeTargets + buildNudgeText 两个纯函数）。
// ⚠️ 锚点跟着实现走 —— 改了函数名/顺序，这里必须同步改，否则会直接抛错。
let frag = extract('function pickNudgeTargets', 'const Config = z.object({');

if (BREAK) {
  // 改坏点①：把"只劝 local"这条拆掉（预期 ② 组会红）
  // ⚠️ 替换串必须与源码**逐字一致**。第一版写成 `if (src !== 'local') continue;`
  //    —— 那行根本不存在，replace 静默什么都没做，于是"改坏自检"报全绿。
  //    教训：改坏自检自己不验一遍"真的改到了"，它就是个假的绿灯。
  const BROKEN = "if (src !== 'local') { skipped.push(`${id}:来源是 ${src}`); continue; }";
  if (!frag.includes(BROKEN)) {
    throw new Error('改坏自检的替换串对不上源码 —— 先用 grep 确认那一行现在长什么样');
  }
  frag = frag.replace(BROKEN, '/* 掰坏：来源不判了 */');
  console.log('\n*** 改坏自检：来源不判了（预期下面 ② 组会红）***\n');
}

const mod = new Function('now', frag + '\nreturn { pickNudgeTargets };')(Date.now);
const { pickNudgeTargets } = mod;

// ── 造场景的帮手 ─────────────────────────────────────────────────────────────
/** 一个正在跑的会话 */
const running = (id, source = 'local') => ({ sessionId: id, source, running: true, title: `会话-${id}` });

const basePlan = (over = {}) => ({
  planId: 'restart-test01',
  createdAt: new Date(Date.now() - 11 * 60e3).toISOString(), // 11 分钟前
  members: [{ sessionId: 'session-me', resume: true }],
  requestedBy: 'session-me',
  ...over,
});

const baseCfg = (over = {}) => ({
  nudgeAfterMinutes: 10,
  nudgeEnabled: true,
  ...over,
});

const baseState = (over = {}) => ({
  nudged: {},   // 记账：{ [planId]: { [sessionId]: 时间戳 } }
  ...over,
});

console.log('\n=== ① 阈值：没到点不许劝 ===');
{
  const plan0 = basePlan({ createdAt: new Date(Date.now() - 60e3).toISOString() }); // 1 分钟
  check('刚排上 1 分钟 → 不劝', pickNudgeTargets({ plan: plan0, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}
{
  const plan5 = basePlan({ createdAt: new Date(Date.now() - 5 * 60e3).toISOString() }); // 5 分钟
  check('排了 5 分钟、阈值 10 → 不劝', pickNudgeTargets({ plan: plan5, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() }); // 11 分钟
  const r = pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] });
  check('排了 11 分钟、阈值 10 → 劝 1 个', r.targets.map((t) => t.sessionId), ['session-a']);
}
{
  const plan6 = basePlan({ createdAt: new Date(Date.now() - 6 * 60e3).toISOString() }); // 6 分钟
  const r = pickNudgeTargets({ plan: plan6, cfg: baseCfg({ nudgeAfterMinutes: 5 }), state: baseState(), runningSessions: [running('session-a')] });
  check('阈值改成 5、排了 6 分钟 → 劝 1 个（阈值真被读到了）', r.targets.map((t) => t.sessionId), ['session-a']);
}
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  check('★ 阈值设 0 = 关掉（0 是"不劝"，不是"立刻劝"）',
    pickNudgeTargets({ plan: plan11, cfg: baseCfg({ nudgeAfterMinutes: 0 }), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  check('★ 总开关关掉 → 一个都不劝',
    pickNudgeTargets({ plan: plan11, cfg: baseCfg({ nudgeEnabled: false }), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}

console.log('\n=== ② 来源：只劝本地窗口 ===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  check('QQ 私聊 → 不劝', pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-q', 'im-direct')] }).targets, []);
  check('QQ 群聊 → 不劝', pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-g', 'im-group')] }).targets, []);
  check('★ 来源 unknown → 也不劝（猜不出来就别碰）', pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-u', 'unknown')] }).targets, []);
  check('本地窗口 → 劝', pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-l', 'local')] }).targets.map((t) => t.sessionId), ['session-l']);
  check('★ 混在一起：只挑出那个 local',
    pickNudgeTargets({
      plan: plan11, cfg: baseCfg(), state: baseState(),
      runningSessions: [running('session-q', 'im-direct'), running('session-l', 'local'), running('session-g', 'im-group')],
    }).targets.map((t) => t.sessionId),
    ['session-l']);
}

console.log('\n=== ③ 车上的人不劝（他本来就在等这趟）===');
{
  const plan11 = basePlan({
    createdAt: new Date(Date.now() - 11 * 60e3).toISOString(),
    members: [{ sessionId: 'session-me' }, { sessionId: 'session-already' }],
  });
  check('已经在 members[] 里的人 → 不劝',
    pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-already')] }).targets, []);
  check('★ 发起人自己（requestedBy）→ 不劝', 
    pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-me')] }).targets, []);
}

console.log('\n=== ④ 同一趟车：同一个人只劝一次 ===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  const st = baseState({ nudged: { 'restart-test01': { 'session-a': Date.now() } } });
  check('已经劝过 → 不再劝（同一趟车只劝一次）',
    pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: st, runningSessions: [running('session-a')] }).targets, []);
  check('★ 换了另一趟车（不同 planId）→ 可以再劝',
    pickNudgeTargets({
      plan: basePlan({ planId: 'restart-test02', createdAt: new Date(Date.now() - 11 * 60e3).toISOString() }),
      cfg: baseCfg(), state: st, runningSessions: [running('session-a')],
    }).targets.map((t) => t.sessionId),
    ['session-a']);
}

console.log('\n=== ⑤ 没有待执行的重启 → 一个都不劝 ===');
{
  check('plan 为 null', pickNudgeTargets({ plan: null, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
  check('plan 没有 planId', pickNudgeTargets({ plan: {}, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}

console.log('\n=== ⑥ createdAt 坏掉时不许乱劝（保守方向）===');
{
  check('createdAt 缺失 → 不劝', pickNudgeTargets({ plan: basePlan({ createdAt: undefined }), cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
  check('createdAt 是乱码 → 不劝', pickNudgeTargets({ plan: basePlan({ createdAt: '不是时间' }), cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
  check('★ createdAt 在未来（时钟歪了）→ 不劝', pickNudgeTargets({ plan: basePlan({ createdAt: new Date(Date.now() + 60e3).toISOString() }), cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets, []);
}

console.log('\n=== ⑦ 文案：必须带"失效声明"，且不冒充用户 ===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  const r = pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] });
  const one = r.targets[0];
  checkTrue('① 有 text 字段且非空', typeof one?.text === 'string' && one.text.length > 50);
  checkTrue('★ ② 说了"不是使用者发的"', /不是使用者发的|不是用户发的/.test(one?.text ?? ''));
  checkTrue('★ ③ 带了失效声明（重启已完成就忽略）', /已完成.{0,20}忽略|若.*已完成.*忽略|已经完成.*忽略/.test(one?.text ?? ''));
  checkTrue('★ ④ 教它先查一下 restart_status（别看到旧话就排一次）', /restart_status/.test(one?.text ?? ''));
  checkTrue('⑤ 说了"上车之后会被一起叫醒"', /叫醒|唤醒/.test(one?.text ?? ''));
  checkTrue('★ ⑥ 说了"手头有长任务就不用停"（劝不住的事就别劝）', /长任务|跑完/.test(one?.text ?? ''));
  checkTrue('★ ⑦ 提醒了 goal 要先结束（否则永远等不到空闲）', /goal|目标/.test(one?.text ?? ''));
  checkTrue('⑧ 提到 restart_self 这个工具名（它得知道怎么上车）', /restart_self/.test(one?.text ?? ''));
}

console.log('\n=== ⑧ 文案里不许出现会误导的绝对化措辞 ===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  const one = pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [running('session-a')] }).targets[0];
  checkTrue('★ 不许写成"必须停下来"（那样就不是"由它判断"了）', !/必须停下来|立刻停止|马上停下/.test(one?.text ?? ''));
  checkTrue('★ 不许写成"作废/丢弃"（它这一轮是收尾，不是作废）', !/这一轮作废|本轮作废|丢弃这一轮/.test(one?.text ?? ''));
}

console.log('\n=== ⑨ 字段来源：不许把"没在跑"的会话当成目标 ===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  check('来源里 running=false 的 → 不劝',
    pickNudgeTargets({ plan: plan11, cfg: baseCfg(), state: baseState(), runningSessions: [{ sessionId: 'session-a', source: 'local', running: false }] }).targets, []);
}

console.log('\n=== ⑩ 多个目标：一次全挑出来（不许只挑第一个）===');
{
  const plan11 = basePlan({ createdAt: new Date(Date.now() - 11 * 60e3).toISOString() });
  const r = pickNudgeTargets({
    plan: plan11, cfg: baseCfg(), state: baseState(),
    runningSessions: [running('session-a'), running('session-b'), running('session-c')],
  });
  check('★ 三个挡路的 → 三个都要劝', r.targets.map((t) => t.sessionId).sort(), ['session-a', 'session-b', 'session-c']);
}

console.log('\n=== ⑪ 接线与清理：功能写了，得真的接上、还得拆干净 ===');
{
  // ★ 2026-11-09 加这一组的原因（真踩到了）：
  //   判定函数和文案都写对了、32 条断言全绿，**但定时器没登记进清理段** ——
  //   插件热加载时旧那一代的 nudgeTimer 会继续每 10 秒跑一次。
  //   本插件恰恰有"新旧两代同时活着"的历史坑（ACTIVE_GENERATION），
  //   而纯函数的断言**一条都抓不到这种问题**。
  //   ⇒ 接线类的东西只能靠读源码 + 断言钉住，光测纯函数是"测了但没测全"。
  const dispStart = src.indexOf('ctx.effect(() => () => {');
  const dispBlock = dispStart >= 0 ? src.slice(dispStart, dispStart + 900) : '';
  checkTrue('① 定时器变量真的建了（nudgeTimer）', /const nudgeTimer = setInterval\(/.test(src));
  checkTrue('★ ② nudgeTimer 建在 apply() 内部（不是模块顶层，否则每代都多一个）',
    src.indexOf('const nudgeTimer = setInterval(') > src.indexOf('export function apply(ctx, config)'));
  checkTrue('③ 真的读了 config.nudgeEnabled', /config\.nudgeEnabled/.test(src));
  checkTrue('④ 真的读了 config.nudgeAfterMinutes', /config\.nudgeAfterMinutes/.test(src));
  checkTrue('★ ⑤ 卸载时把它停掉（漏了就是旧一代继续跑）', dispBlock.includes('clearInterval(nudgeTimer)'));
  checkTrue('★ ⑥ 用 inject 而不是 followup（不许把人家叫醒）',
    /target\.inject\(makeWakeMessage\(t\.text\)\)/.test(src));
  checkTrue('★ ⑦ 记账只在投递成功之后（失败不许记，否则那一拍永远不重试）',
    src.indexOf('target.inject(makeWakeMessage(t.text));') < src.indexOf('done[bucketKey][t.sessionId] = now();'));
}

// ── 收尾 ─────────────────────────────────────────────────────────────────────
// ⚠️ 最后一行必须含「汇总」两个字 —— 跑批器（run-all-tests.ps1）就是靠
//    `汇总|inject 验证|结果：通过` 这几个词抓汇总行的，抓不到就报"可能异常退出"。
//    第一版这里写的是「合计：32 过 / 0 失败」，于是功能明明全过，跑批表里却是红的。
console.log('');
if (BREAK) {
  if (fail > 0) {
    console.log(`改坏自测汇总：${fail} 条断言变红（说明这些断言真的能抓到问题）`);
    process.exit(0);
  }
  console.log('❌ 改坏自检失败：掰坏了居然全绿 —— 说明断言没抓到东西，等于没测');
  process.exit(1);
} else {
  console.log(`===== 汇总：${pass}/${pass + fail} 通过 =====`);
  if (fail > 0) { console.log('失败项：\n  - ' + failed.join('\n  - ')); process.exit(1); }
  process.exit(0);
}
