// test-leave.mjs —— 「我自己下车」：只把自己从这趟重启里摘掉
//
// 【它和 cancel 是两件不同的事（这是本套测试要守住的语义）】
//   leave  = 这车跟我没关系了。只影响调用者自己：
//              · 车上还有别人 → 车照开，只是**不叫醒我**
//              · 摘完没人了   → 这趟本来就没人为它等了 → **不发车**（封口）
//   cancel = 这趟别开了。影响整趟车上的所有人。
//
//   ⚠️ 所以本套最重要的一条断言是：**下车不许把别人的重启打掉。**
//      如果哪天有人图省事把 leave 实现成 cancel，这条会立刻变红。
//
// 用法：node test-leave.mjs
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const PLUGIN = join(ROOT, 'lib', 'index.js');

let pass = 0;
let fail = 0;
const check = (name, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`✅ ${name}${detail ? ' — ' + detail : ''}`); }
  else { fail += 1; console.log(`❌ ${name}${detail ? ' — ' + detail : ''}`); }
};

console.log(`（加载的实现：${PLUGIN}）\n`);

// ── 造一个隔离的状态目录，假装"盘上有一趟待执行的重启" ─────────────────────
const dir = mkdtempSync(join(tmpdir(), 'sr-leave-'));
const planPath = join(dir, 'plan.json');
const cancelPath = join(dir, 'cancel.flag');

const mod = await import(pathToFileURL(PLUGIN).href);

/** 起一个插件实例：拿到它注册的工具表 */
async function boot(cfg = {}) {
  const tools = new Map();
  const fakeCtx = {
    tools: {
      register(tool) {
        tools.set(tool.name, tool);
        // 插件注册时会给工具套一层"声明外字段剔除"，这里必须把那层也走一遍，
        // 否则测出来的返回形状和真机不一样。
        return tool;
      }
    },
    logger: () => ({ debug() {}, info() {}, warn() {}, error() {}, log() {} }),
    // 插件用 ctx.inject 动态拿服务；测试里给个永不触发的桩即可
    inject() { return { dispose() {} }; },
    on() { return { dispose() {} }; },
    effect() { return { dispose() {} }; },
    get() { return undefined; },
    provide() {},
  };
  await mod.apply(fakeCtx, {
    enabled: true,
    stateDir: dir,
    port: 59999,
    idleSeconds: 1,
    ...cfg,
  });
  return tools;
}

/** 写一份"待执行的重启"计划 */
function writePlan(members) {
  const plan = {
    planId: 'leave-test',
    createdAt: new Date().toISOString(),
    scheduleAt: new Date(Date.now() - 1000).toISOString(),
    reason: '测试下车',
    port: 59999,
    members,
    requestedBy: members[0]?.sessionId ?? '',
    sessionFile: members[0]?.sessionFile ?? '',
    resume: true,
    helperPid: null,
    stateFile: join(dir, 'state.json'),
    cancelFile: cancelPath,
    logFile: join(dir, 'helper.log'),
    lastRunFile: join(dir, 'last-run.json'),
  };
  writeFileSync(planPath, JSON.stringify(plan, null, 2), 'utf8');
  return plan;
}

const readPlan = () => {
  if (!existsSync(planPath)) return null;
  try { return JSON.parse(readFileSync(planPath, 'utf8')); } catch { return null; }
};
const clean = () => {
  for (const p of [planPath, cancelPath]) {
    try { if (existsSync(p)) rmSync(p, { force: true }); } catch { /* 忽略 */ }
  }
};

const tools = await boot();
const statusTool = tools.get('restart_status');
check('restart_status 注册成功', Boolean(statusTool));
check('★ 参数里有 leave', Boolean(statusTool?.parameters?.properties?.leave));
check('参数里仍然有 cancel（没被改动）', Boolean(statusTool?.parameters?.properties?.cancel));

const as = (id) => ({ agent: { id } });

/** 跑一次 leave，返回 { value, plan } */
async function runLeave(myId) {
  const value = await statusTool.execute({ leave: true }, as(myId));
  return { value, plan: readPlan() };
}

// ── ① 车上还有别人 → 只摘自己，车照开 ─────────────────────────────────────
console.log('\n=== ① 车上还有别人：车照开，只是不叫我 ===');
clean();
writePlan([
  { sessionId: 'session-A', reason: 'A 的事', resume: true },
  { sessionId: 'session-B', reason: 'B 的事', resume: true },
]);
{
  const { value, plan } = await runLeave('session-A');
  check('返回 ok=true', value.ok === true, JSON.stringify(value).slice(0, 160));
  check('★ 计划还在（车没被取消）', Boolean(plan), plan ? `planId=${plan.planId}` : '计划被删掉了 —— 这就是"把别人一起打掉"');
  check('★ 名单里只剩别人', JSON.stringify((plan?.members ?? []).map((m) => m.sessionId)) === JSON.stringify(['session-B']),
    JSON.stringify((plan?.members ?? []).map((m) => m.sessionId)));
  check('★ 没有写 cancel.flag（不许连累别人）', !existsSync(cancelPath));
  check('回包里说清"不会叫醒你"', /不会叫醒你|不会.*叫醒/.test(String(value.message)), value.message.split('\n')[0]);
  check('回了 pending=true（车还在，别人还要重启）', value.pending === true);
}

// ── ② 摘掉的是 requestedBy（老字段镜像）→ 要重新指向剩下的人 ──────────────
console.log('\n=== ② 摘掉的是 requestedBy：老字段要跟着改指向 ===');
clean();
writePlan([
  { sessionId: 'session-A', reason: 'A 的事', resume: true },
  { sessionId: 'session-B', reason: 'B 的事', resume: true },
]);
{
  const { plan } = await runLeave('session-A');
  check('★ requestedBy 指向剩下那个人（不是还挂着 A）', String(plan?.requestedBy) === 'session-B', String(plan?.requestedBy));
  check('reason 也换成剩下那位的', String(plan?.reason) === 'B 的事', String(plan?.reason));
}

// ── ③ 摘完没人了 → 不发车（封口，且不动 DSH）──────────────────────────────
console.log('\n=== ③ 最后一个人下车：这趟直接作罢 ===');
clean();
writePlan([{ sessionId: 'session-A', reason: 'A 的事', resume: true }]);
{
  const { value, plan } = await runLeave('session-A');
  check('返回 ok=true', value.ok === true);
  check('★ 计划文件被删（助手会据此退出，不发车）', plan === null, plan ? '计划还在 —— 空车还会发出去' : '');
  check('pending=false', value.pending === false);
  check('文案说明"不会发车"', /不会发车|作罢/.test(String(value.message)), value.message.split('\n')[0]);
}

// ── ④ 我不在车上 → 什么都不动 ─────────────────────────────────────────────
console.log('\n=== ④ 本来就不在车上：不许动名单 ===');
clean();
writePlan([
  { sessionId: 'session-A', reason: 'A 的事', resume: true },
  { sessionId: 'session-B', reason: 'B 的事', resume: true },
]);
{
  const { value, plan } = await runLeave('session-OTHER');
  check('返回 ok=true（不算错）', value.ok === true);
  check('★ 名单原封不动', (plan?.members ?? []).length === 2, JSON.stringify((plan?.members ?? []).map((m) => m.sessionId)));
  check('文案说清"你本来就不在"', /本来就不在/.test(String(value.message)), value.message.split('\n')[0]);
}

// ── ⑤ 没有待执行的重启 → 友好返回，不报错 ────────────────────────────────
console.log('\n=== ⑤ 压根没有待执行的重启 ===');
clean();
{
  const { value } = await runLeave('session-A');
  check('ok=true 且 pending=false', value.ok === true && value.pending === false, JSON.stringify(value).slice(0, 120));
  check('文案说清"本来就不在车上"', /本来就不在/.test(String(value.message)), value.message.split('\n')[0]);
}

// ── ⑥ 读不到会话 id → 明确拒绝（不许瞎摘）────────────────────────────────
console.log('\n=== ⑥ 不知道自己是谁：拒绝，不猜 ===');
clean();
writePlan([{ sessionId: 'session-A', reason: 'A 的事', resume: true }]);
{
  const value = await statusTool.execute({ leave: true }, {});
  check('ok=false', value.ok === false, JSON.stringify(value).slice(0, 120));
  check('★ 计划没被动过', readPlan() !== null);
}

// ── ⑦ 语义护栏：leave 与 cancel 的代码路径必须是两回事 ────────────────────
console.log('\n=== ⑦ 源码层面：leave 绝不许偷偷走 cancel 那条路 ===');
{
  const src = readFileSync(PLUGIN, 'utf8');
  const leaveAt = src.indexOf('if (args.leave === true)');
  check('源码里能找到 leave 分支', leaveAt > 0);
  if (leaveAt > 0) {
    const cancelAt = src.indexOf('if (args.cancel === true)', leaveAt);
    const block = cancelAt > leaveAt ? src.slice(leaveAt, cancelAt) : '';
    check('leave 分支边界清晰（能找到它到 cancel 之间那段）', block.length > 200, `${block.length} 字节`);
    check('★ leave 分支里**不写** cancel.flag', !/writeFileSync\(\s*cancelPath/.test(block));
    check('★ leave 只从 members 里摘自己（不动整车）', /members\.filter|rest\b/.test(block));
  }
}

// ── ⑧ 真机上 cancel 的语义没被改坏 ──────────────────────────────────────
console.log('\n=== ⑧ cancel 仍然是整趟（这次没动它）===');
{
  clean();
  writePlan([
    { sessionId: 'session-A', reason: 'A', resume: true },
    { sessionId: 'session-B', reason: 'B', resume: true },
  ]);
  const value = await statusTool.execute({ cancel: true }, as('session-A'));
  check('cancel 后 ok=true', value.ok === true, JSON.stringify(value).slice(0, 120));
  check('★ 写了 cancel.flag（整趟叫停照旧）', existsSync(cancelPath));
}

clean();
try { rmSync(dir, { recursive: true, force: true }); } catch { /* 忽略 */ }

console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
process.exit(fail === 0 ? 0 : 1);
