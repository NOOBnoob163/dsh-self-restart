// test-history-summary.mjs —— 「重启流水账汇总」的逻辑测试（2026-10-13 新增）
//
// 【为什么要有这一套】
//   test-resume-after-restart.ps1 里那些是**字串断言**（"代码里有没有这句话"），
//   证明不了**算得对不对** —— 中位数、过滤、坏行容错，任何一处写反都看不出来。
//   而这个项目已经吃过"只验字串 = 假保险网"的亏（曾经有一次：
//   把 `if (...) return` 改成空语句，测试照样全绿）。
//
//   所以这里用**真源码 + 假数据**：真的 import lib/index.js，真的调 apply()，
//   真的接住 restart_status 工具，真的执行它，然后看输出的数字对不对。
//
// 【做法】把 stateDir 指到一个临时目录，往里面放一份"各形态都有"的 history.jsonl：
//   · 正常的成功记录
//   · 失败/取消的（不该进"关掉→起来"的样本）
//   · downToUpSeconds 为 null 的（老记录 / 非成功）
//   · 一行**坏 JSON**（追加写可能被撞断 —— 必须能跳过而不是整体崩）
//   · 一行空行
//   然后断言：样本数只数该数的、最快/最慢/中位算对、且**坏行没把整件事搞崩**。
//
// 用法：node test-history-summary.mjs
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
};

const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(process.env.USERPROFILE ?? '', '.dsh');
const INSTALLED = join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'lib', 'index.js');
const LOCAL = join(fileURLToPath(new URL('..', import.meta.url)), 'lib', 'index.js');

// ⚠️⚠️ 这里**必须优先用开发区那份**（跟 selftest.mjs 相反），2026-10-13 踩到才知道：
//   selftest.mjs 优先用 INSTALLED，是因为开发区解析不到 `@deepseek-ai/schemastery`
//   （那个依赖装在 DSH 的 profiles/desktop/node_modules 下，不在插件包里）。
//   我照抄了那个顺序 → 结果这个测试**一直在测使用区的旧代码** →
//   我新加的 readHistorySummary 根本不在里面 → 6 条断言全红，
//   而我差点以为是"逻辑写错了"去改本来正确的代码。
//   **测试跑的是哪份代码，必须一眼看得出来、而且必须是"我刚改的那份"。**
//   现在：开发区能解析就用开发区（本地建过 node_modules 联接即可），
//   解析不了才退回使用区 —— 并且**打印出来**用的是哪份，不含糊。
let PLUGIN = LOCAL;
let pluginWhich = '开发区（我刚改的那份）';
try {
  // 试着解析一下依赖在不在：不在就退回使用区
  await import(pathToFileURL(LOCAL).href);
} catch {
  PLUGIN = INSTALLED;
  pluginWhich = '使用区（开发区解析不到依赖，退回）';
}
console.log(`（本次测试跑的是：${pluginWhich}）\n${PLUGIN}\n`);

// ── 造一份"什么形态都有"的流水账 ─────────────────────────────────────────────
const dir = mkdtempSync(join(tmpdir(), 'dsh-sr-hist-'));
const histPath = join(dir, 'history.jsonl');
// 成功的"关掉→起来"样本：12, 24, 16, 18  → 排序 12,16,18,24 → 中位 = (16+18)/2 = 17
const lines = [
  JSON.stringify({ planId: 'r1', outcome: 'success', tookSeconds: 67.2, downToUpSeconds: 12, reason: 'a' }),
  JSON.stringify({ planId: 'r2', outcome: 'success', tookSeconds: 70.2, downToUpSeconds: 24, reason: 'b' }),
  JSON.stringify({ planId: 'r3', outcome: 'success', tookSeconds: 55.0, downToUpSeconds: 16, reason: 'c' }),
  JSON.stringify({ planId: 'r4', outcome: 'success', tookSeconds: 60.0, downToUpSeconds: 18, reason: 'd' }),
  // 非成功：不该进样本
  JSON.stringify({ planId: 'r5', outcome: 'skipped-busy', tookSeconds: 80.0, downToUpSeconds: null, reason: 'e' }),
  JSON.stringify({ planId: 'r6', outcome: 'failed', tookSeconds: 30.0, reason: 'f' }),
  // 成功但没有 downToUpSeconds（老记录）：不该进样本
  JSON.stringify({ planId: 'r7', outcome: 'success', tookSeconds: 40.0, reason: 'g' }),
  '',                                  // 空行：必须跳过
  '{ 坏掉的半截 JSON',                  // 坏行：必须跳过而不是崩掉
];
writeFileSync(histPath, lines.join('\n') + '\n', 'utf8');

// ── 用真的插件源码 ───────────────────────────────────────────────────────────
let mod;
try {
  mod = await import(pathToFileURL(PLUGIN).href);
  check('插件模块能 import', true);
} catch (error) {
  check('插件模块能 import', false, String(error?.message ?? error));
  process.exit(1);
}

const registered = [];
const fakeCtx = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: () => {},          // 不注入任何服务：本测试只验汇总，不碰 schedule/jobs
  effect: () => {},
  tools: { register(def) { registered.push(def); return () => {}; } }
};

let config;
try {
  config = new mod.Config({ stateDir: dir });
  check('Config 能指定 stateDir 指到临时目录', true, dir);
} catch (error) {
  check('Config 能指定 stateDir', false, String(error?.message ?? error));
  process.exit(1);
}

try {
  mod.apply(fakeCtx, config);
  check('apply() 能跑完不抛', true, `注册了 ${registered.length} 个工具`);
} catch (error) {
  check('apply() 能跑完不抛', false, String(error?.message ?? error));
}

const statusTool = registered.find((t) => t.name === 'restart_status');
check('接住了 restart_status 工具', Boolean(statusTool));
if (!statusTool) { console.log('\n无法继续：没拿到工具'); process.exit(1); }

// ── 执行它，看输出的数字 ─────────────────────────────────────────────────────
let msg = '';
try {
  const r = await statusTool.execute({}, {});
  msg = String(r?.message ?? '');
  check('restart_status 能执行出结果', msg.length > 0);
} catch (error) {
  check('restart_status 能执行出结果', false, String(error?.message ?? error));
}

console.log('\n--- restart_status 实际输出（只看流水账那几行）---');
// ⚠️ 前缀**不能用 `·`**（2026-10-13 被 run-all-tests 的汇总逻辑抓到）：
//   那个跑批器把"^\s+·"开头的行**当成失败项**收集（它是各套测试报失败清单的约定）。
//   我这里只是打印"实际输出长什么样"，用 · 会让 13/13 全绿的一套被判成失败。
for (const l of msg.split('\n')) if (l.includes('流水账') || l.includes('关掉')) console.log('    > ' + l);
console.log('------------------------------------------------\n');

// ── 断言：算得对不对 ─────────────────────────────────────────────────────────
// 总数 = 9 行里去掉 1 个空行、去掉 1 个坏行 = 7 条
check('★ 总条数 = 7（空行与坏 JSON 都被跳过，没把整件事搞崩）', msg.includes('共记 7 次'), msg.match(/共记 \d+ 次/)?.[0] ?? '（没找到）');
// 成功 = r1..r4 + r7 = 5 次
check('★ 成功次数 = 5', msg.includes('成功 5 次'), msg.match(/成功 \d+ 次/)?.[0] ?? '（没找到）');
// 样本 = 只有带 downToUpSeconds 的 4 次
check('★ 样本数 = 4（只有"关掉→起来"有值的才算）', msg.includes('（4 次样本）'), msg.match(/（\d+ 次样本）/)?.[0] ?? '（没找到）');
check('★ 最快 = 12s', msg.includes('最快 12s'), msg.match(/最快 [\d.]+s/)?.[0] ?? '（没找到）');
check('★ 最慢 = 24s', msg.includes('最慢 24s'), msg.match(/最慢 [\d.]+s/)?.[0] ?? '（没找到）');
// 偶数个样本 → 取中间两个的平均：(16+18)/2 = 17
check('★ 中位 = 17s（偶数样本取中间两个的平均，不是简单取一个）', msg.includes('中位 17s'), msg.match(/中位 [\d.]+s/)?.[0] ?? '（没找到）');

// ── 反向：不能把"总耗时"当机器速度报出去 ─────────────────────────────────────
// 这批数据里 tookSeconds 是 67.2 / 70.2 / …，如果代码错拿了它，会报出 55~80 这种数。
check('★ 报的不是 tookSeconds（67.2/70.2/55/80 都不该出现在汇总里）',
  !/最快 (55|60|67\.2|70\.2|80)s/.test(msg) && !/中位 (55|60|67\.2|70\.2|80)s/.test(msg));

// ── 空目录：不能报错、不能瞎编 ───────────────────────────────────────────────
const dir2 = mkdtempSync(join(tmpdir(), 'dsh-sr-hist2-'));
const registered2 = [];
const ctx2 = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: () => {}, effect: () => {},
  tools: { register(d) { registered2.push(d); return () => {}; } }
};
try {
  mod.apply(ctx2, new mod.Config({ stateDir: dir2 }));
  const t2 = registered2.find((t) => t.name === 'restart_status');
  const r2 = await t2.execute({}, {});
  const m2 = String(r2?.message ?? '');
  check('★ 没有流水账时：正常出结果、且不显示"流水账"那一节',
    m2.length > 0 && !m2.includes('流水账'), m2.includes('流水账') ? '竟然显示了流水账' : '');
} catch (error) {
  check('★ 没有流水账时不该抛错', false, String(error?.message ?? error));
}

// 清理
try { rmSync(dir, { recursive: true, force: true }); } catch { /* 忽略 */ }
try { rmSync(dir2, { recursive: true, force: true }); } catch { /* 忽略 */ }

const failed = results.filter((r) => !r.ok);
console.log(`\n===== 汇总：${results.length - failed.length}/${results.length} 通过 =====`);
if (failed.length) {
  console.log('失败项：');
  for (const f of failed) console.log(`  · ${f.name} ${f.detail}`);
  process.exit(1);
}
process.exit(0);
