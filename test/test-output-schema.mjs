/**
 * test-output-schema.mjs —— 「回包字段必须都在声明里」的守门测试
 *
 * 【它守的是哪一次事故】
 *   2026-10-23 17:54：`restart_self` 的**入队分支**返回了 `{ ok, message, planId, queueLength, busy }`，
 *   而 `output.schema` 里**没有** `queueLength`。宿主按 `additionalProperties: false` 处理，
 *   于是**整份回包被拒收**：
 *       Error: tool "restart_self" returned invalid output:
 *       "value.queueLength" is not a declared property (additionalProperties: false)
 *
 *   最恶劣的是：**副作用已经发生** —— 计划写了、助手点火了、队列真加上了。
 *   可调用方看到的是"失败"，于是它以为没排上，去查状态、去手工改文件，
 *   最后 `restart_status(cancel:true)` 把**两个人的**重启一起打掉。
 *
 * 【旧测试为什么没抓到】
 *   `selftest.mjs` 只验证「**声明的** schema 宿主认不认」（`validate(tool.output.schema)`）——
 *   声明本身是合法的，回包是非法的，那套测试永远绿。
 *   ⇒ 缺的是**另一个方向**：拿**实际返回值**去比对声明。
 *
 * 【怎么跑】
 *   node test\test-output-schema.mjs           正常跑（应全绿）
 *   node test\test-output-schema.mjs --break   改坏自检：在**临时副本**上真的掰坏两处，
 *                                              要求对应断言**变红**（红了才算测试有效）
 *
 * 退出码：正常模式 0 = 全过；--break 模式 0 = 成功变红。
 */

import { fileURLToPath, pathToFileURL } from 'node:url';
import { existsSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const BREAK = process.argv.includes('--break');

const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const INSTALLED = join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'lib', 'index.js');
const LOCAL = join(fileURLToPath(new URL('..', import.meta.url)), 'lib', 'index.js');
const REAL_PLUGIN = existsSync(INSTALLED) ? INSTALLED : LOCAL;

let pass = 0;
const fails = [];
const check = (name, ok, detail = '') => {
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fails.push(`${name}${detail ? ` — ${detail}` : ''}`); console.log(`  ❌ ${name}${detail ? ` — ${detail}` : ''}`); }
};

// ── --break：在**同目录**造一份掰坏的副本（同目录才能解析到 DSH 的 node_modules）──
//
// ⚠️ 为什么不用"改完再改回来"：中途崩了就留下一份坏代码在真插件目录里，
//    宿主热加载可能正好拣到它。用独立文件名 + 结束时删，风险最小。
let PLUGIN = REAL_PLUGIN;
let brokenCopy = null;
if (BREAK) {
  const orig = readFileSync(REAL_PLUGIN, 'utf8');
  let broken = orig;
  // 第 1 处：把 queueLength 的声明删掉（= 事故原样）
  const declLine = /^\s*queueLength:\s*\{\s*type:\s*'number'\s*\}\s*$/m;
  if (!declLine.test(broken)) {
    console.log('  ⚠️ 找不到 queueLength 的声明行 —— 锚点变了，--break 无法按预期掰坏');
  }
  broken = broken.replace(declLine, '');
  // 第 2 处：取消输出护栏的注册（把两个工具直接注册，绕过护栏）
  broken = broken
    .replace('ctx.tools.register(guardDeclaredFields(restartSelfTool))', 'ctx.tools.register(restartSelfTool)')
    .replace('ctx.tools.register(guardDeclaredFields(restartStatusTool))', 'ctx.tools.register(restartStatusTool)');
  // 第 3 处：把那句假承诺**塞回去**（模拟"文案又吹牛了"）
  //   锚点取它现在真实存在的那句，替换成事故当时的原文。
  const fakePromiseAnchor = 'Cancelling is ALL-OR-NOTHING: ';
  if (!broken.includes(fakePromiseAnchor)) {
    console.log('  ⚠️ 找不到取消语义那段的锚点 —— 说明文案变过，--break 只能掰两处');
  }
  broken = broken.replace(
    fakePromiseAnchor,
    'Every member can leave the queue on its own; when the last one leaves, the trip cancels itself and the app is never touched. ' +
      'Cancelling is ALL-OR-NOTHING: '
  );
  brokenCopy = join(dirname(REAL_PLUGIN), `.break-copy-${process.pid}.mjs`);
  writeFileSync(brokenCopy, broken, 'utf8');
  PLUGIN = brokenCopy;
  console.log(`*** 改坏自检：用掰坏的副本跑（${brokenCopy}）—— 下面必须有断言变红 ***\n`);
}

// ── 假 ctx + 临时状态目录（**绝不碰真实 state.json**）───────────────────────
const tmpStateDir = join(process.env.TEMP ?? process.env.TMP ?? '.', `dsh-sr-out-schema-${process.pid}`);
try { rmSync(tmpStateDir, { recursive: true, force: true }); } catch { /* 忽略 */ }
mkdirSync(tmpStateDir, { recursive: true });

const cleanup = () => {
  try { rmSync(tmpStateDir, { recursive: true, force: true }); } catch { /* 忽略 */ }
  if (brokenCopy) { try { rmSync(brokenCopy, { force: true }); } catch { /* 忽略 */ } }
};

const mod = await import(pathToFileURL(PLUGIN).href);
const config = new mod.Config({ stateDir: tmpStateDir });

const registered = [];
const logLines = [];
const fakeCtx = {
  logger: { info: (t) => { logLines.push(String(t)); }, warn: () => {}, error: () => {} },
  inject: () => {},
  effect: () => {},
  tools: { register(definition) { registered.push(definition); return () => {}; } }
};
mod.apply(fakeCtx, config);

const byName = Object.fromEntries(registered.map((t) => [t.name, t]));
check('注册了两个工具', registered.length === 2, registered.map((t) => t.name).join(', '));

const declaredOf = (tool) => new Set(Object.keys(tool?.output?.schema?.properties ?? {}));
const extrasOf = (tool, value) => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return [];
  const declared = declaredOf(tool);
  return Object.keys(value).filter((k) => !declared.has(k));
};

// ── ① 真调 execute（只调**不会动手**的分支），字段逐个对声明 ─────────────────
//
// ⚠️ 只调安全分支：
//    · confirm:false → 直接拒绝    · dry_run:true → 只出报告    · restart_status → 只读
//  入队分支会写计划、点火启动助手 —— 测试里跑它等于往实机队列塞一趟车，**绝对不行**。
//  所以它由 ② 的源码扫描补上；两条路合起来才盖得住。
console.log('\n=== ① 真调 execute：返回的每个字段都必须在声明里 ===');
for (const [name, args, label] of [
  ['restart_self', { confirm: false }, '不传 confirm（拒绝分支）'],
  ['restart_self', { confirm: true, dry_run: true, reason: '输出字段自测' }, '空跑分支'],
  ['restart_status', {}, '只读状态']
]) {
  const tool = byName[name];
  if (!tool) { check(`${name} 存在`, false); continue; }
  let value;
  try { value = await tool.execute(args, {}); }
  catch (error) { check(`${name} · ${label}：能跑完`, false, String(error?.message ?? error)); continue; }
  const extras = extrasOf(tool, value);
  check(`★ ${name} · ${label}：返回字段全在声明里`, extras.length === 0,
    extras.length ? `多出未声明字段 ${extras.join('、')} —— 宿主会**整份拒收**这条回包` : `字段 ${Object.keys(value).join(', ')}`);
}

// ── ② 入队分支：源码扫描（跑它会真点火）─────────────────────────────────────
console.log('\n=== ② 入队分支的字段（源码扫描，因为跑它会真点火）===');
const src = readFileSync(PLUGIN, 'utf8');
const enqueueAt = src.indexOf('log(`入队：');
check('找到入队分支', enqueueAt > 0, enqueueAt > 0 ? `位置 ${enqueueAt}` : '源码里搜不到 `log(`入队：`');
if (enqueueAt > 0) {
  const tail = src.slice(enqueueAt, enqueueAt + 4000);
  const retStart = tail.indexOf('return {');
  const retEnd = tail.indexOf('\n        };', retStart);
  const retBlock = retStart >= 0 ? tail.slice(retStart, retEnd > 0 ? retEnd : retStart + 1500) : '';
  check('入队分支能定位到 return 块', Boolean(retBlock), retBlock ? '' : '没找到 return {…}');
  check('★ 入队分支会返回 queueLength', /queueLength\s*:/.test(retBlock), '分支结构变了，扫描锚点要跟着改');
  const declared = declaredOf(byName.restart_self);
  check('★ restart_self 的输出 schema 声明了 queueLength', declared.has('queueLength'),
    `已声明：${[...declared].join(', ')}`);
}

// ── ③ 输出护栏：声明外字段一律剔除 + **日志留痕** ───────────────────────────
// 【为什么这条最重要】
//   补 queueLength 只解决**这一个**字段。真正要防的是"以后又有人加字段忘了声明"。
//   插件里加了 guardDeclaredFields 那一层，这里验它**真的在工作**。
//   ⚠️ 判据必须两条：① 值被剔除；② **日志里有一行**。
//      只验"被剔除"会养出"静默吞掉"的坏习惯 —— 那和假绿没区别。
console.log('\n=== ③ 输出护栏（声明外字段一律剔除 + 日志留痕）===');
{
  const gStart = src.indexOf('const guardDeclaredFields = (');
  const gEnd = src.indexOf('\n  };', gStart);
  const gSrc = gStart >= 0 ? src.slice(gStart, gEnd + 6) : '';
  check('源码里能找到 guardDeclaredFields 护栏', Boolean(gSrc), gSrc ? '' : '护栏被删了？');

  if (gSrc) {
    const collected = [];
    // 源码里它用的是闭包里的 log，这里给个假的收集器
    const factory = new Function('log', 'return (function () { ' + gSrc + '\nreturn guardDeclaredFields; })();');
    const guard = factory((t) => collected.push(String(t)));

    const fakeTool = {
      name: 'fake_tool',
      output: { schema: { type: 'object', additionalProperties: false, properties: { ok: { type: 'boolean' }, message: { type: 'string' } } } },
      render: () => [],
      execute: async () => ({ ok: true, message: 'hi', rogue: 'should be dropped' })   // ← 故意多一个
    };
    const guarded = guard(fakeTool);
    const out = await guarded.execute({}, {});
    check('★ 未声明字段被剔除（不会让宿主整份拒收）', out.rogue === undefined, JSON.stringify(out));
    check('★ 声明过的字段原样保留', out.ok === true && out.message === 'hi', JSON.stringify(out));
    check('★ 剔除时**日志留痕**（不许静默吞掉）',
      collected.some((l) => l.includes('rogue')), collected.join(' | ') || '（日志为空）');

    const cleanTool = {
      name: 'clean_tool',
      output: { schema: { type: 'object', additionalProperties: false, properties: { ok: { type: 'boolean' } } } },
      render: () => [],
      execute: async () => ({ ok: true })
    };
    const before = collected.length;
    const out2 = await guard(cleanTool).execute({}, {});
    check('合规回包原样通过（不多事、不刷日志）', out2.ok === true && collected.length === before, JSON.stringify(out2));
  }

  // 注册出去的那两个工具**必须是被护栏包过的**（否则上面验的护栏根本没接线）
  //
  // ⚠️ 这条要验"接线"，不能只验"护栏函数本身能用" —— 本仓吃过这个亏：
  //    test-target-guard 全绿而真 DSH 照样被误杀，就是因为那套"照抄一份逻辑来验"，
  //    验得到计算、验不到接线（算出来的结论有没有人用）。
  //
  // 判据取**注册出来的那个对象**（不是源码）：护栏包过之后，execute 的源码里
  // 一定会出现 `guardedExecute` 这个函数名；没包过就还是原来的方法体。
  // 这样"忘了包"会立刻变红，而不是靠人记得。
  for (const name of ['restart_self', 'restart_status']) {
    const t = byName[name];
    const fnSrc = typeof t?.execute === 'function' ? String(t.execute) : '';
    check(`★ ${name} 注册时真的套了输出护栏（接线检查）`, fnSrc.includes('guardedExecute'),
      fnSrc ? (fnSrc.includes('guardedExecute') ? '' : `execute 源码里没有 guardedExecute —— 护栏没接上：${fnSrc.slice(0, 80)}`) : '没有 execute');
  }

  const noWarn = logLines.filter((l) => l.includes('没在 output.schema 里声明')).length;
  check('干净回包不会触发"漏声明"告警', noWarn === 0, `告警 ${noWarn} 条`);
}

// ── ④ 工具说明不许再吹牛（这次事故的第 2 个病根）──────────────────────────────
//
// 【它守哪一句话】
//   原说明：`Every member can leave the queue on its own; when the last one leaves,
//            the trip cancels itself and the app is never touched.`
//   —— **代码里从来没有"每人自己退出"这个能力**，只有整批 cancel。
//   agent 照着这句去"只退出自己"，实际会把整趟车取消、连带打掉另一个正在等的会话。
//   （2026-10-23 17:54 实机：就是这么把两个人的重启一起送走的。）
//
// ⇒ 钉住两件事，缺一不可：
//      ① 那句假承诺**不许回来**（regression guard）；
//      ② 必须**明确写出**"取消是整趟的"（否则又变成"没说清 = 说明书缺一半"）。
console.log('\n=== ④ 工具说明与实现一致（不许再吹"每人可自己退出"）===');
{
  const desc = String(byName.restart_self?.description ?? '');
  check('说明里不再有"每个人可以自己退出队列"那句假承诺',
    !/Every member can leave the queue on its own/i.test(desc),
    desc.includes('leave the queue on its own') ? '那句假承诺又回来了' : '');
  check('说明里不再有"最后一个人退出就整趟取消"这句（同样没实现）',
    !/when the last one leaves/i.test(desc));
  check('★ 说明里明确写了"取消是整趟（ALL-OR-NOTHING）"',
    /ALL-OR-NOTHING|cancels the WHOLE trip/i.test(desc),
    '说明没写清取消范围 —— agent 会以为自己只取消自己的');
  check('★ 说明里提醒"取消前先读名单"（否则会误以为别人的理由是旧残骸）',
    /FULL member list|restart_status\(\)/i.test(desc));
}

// ── 汇总 ────────────────────────────────────────────────────────────────────
const total = pass + fails.length;
// ⚠️ 这行必须含「汇总」二字 —— 跑批器（run-all-tests.ps1）靠 `汇总|inject 验证|^结果：通过`
//    定位 Node 套件的汇总行；找不到就判"可能异常退出"→ 整套算失败（第一次就这么假红了）。
console.log(`\n===== 回包字段自测汇总：${pass}/${total} 通过 =====`);
if (fails.length) {
  console.log('失败项：');
  for (const f of fails) console.log(`  · ${f}`);
}

cleanup();

if (BREAK) {
  // 掰坏的副本里：① queueLength 声明没了、② 护栏没接上。
  //  ⇒ 正常模式下必绿的断言这里必须变红，否则说明这些断言是无效的。
  const turnedRed = fails.length > 0;
  console.log(turnedRed
    ? `\n*** 改坏自检：掰坏之后确实变红了（${fails.length} 条）✅ —— 这套断言有效 ***`
    : '\n*** 改坏自检失败：掰坏之后仍然全绿 ❌ —— 这套断言是假的，不算数 ***');
  process.exit(turnedRed ? 0 : 1);
}

process.exit(fails.length === 0 ? 0 : 1);
