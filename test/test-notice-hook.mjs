// test-notice-hook.mjs —— 外部通知钩子（notice hook）跑得对不对
//
// 【这一套要证明什么】
//   插件不内置任何通知渠道，只在事件发生时执行用户配置的那条命令。
//   所以这里验的是四件事：
//     ① 没配命令 → 什么都不执行（出厂默认行为）；
//     ② 配了命令 → 真的执行了，且事件能通过环境变量传进去；
//     ③ 命令失败 / 超时 → 如实返回 false，**绝不抛出**（不能拖累重启）；
//     ④ 同一事件同一趟只通知一次（防刷屏）。
//
// 【为什么跑真进程而不是查源码】
//   "源码里写着会执行"证明不了"命令真的跑起来了"。
//   这里起一个真的子进程，让它把收到的环境变量写进文件，再看文件里有什么。
//
// 用法：node test-notice-hook.mjs
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const MOD = join(ROOT, 'lib', 'notice-hook.js');

let pass = 0;
let fail = 0;
const check = (name, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`✅ ${name}${detail ? ' — ' + detail : ''}`); }
  else { fail += 1; console.log(`❌ ${name}${detail ? ' — ' + detail : ''}`); }
};

console.log(`（加载的实现：${MOD}）\n`);

const { runNoticeHook, createSerialNoticeRunner, NOTICE_EVENTS } = await import(pathToFileURL(MOD).href);

const workDir = mkdtempSync(join(tmpdir(), 'notice-hook-'));

// 一个"假通知程序"：把收到的环境变量原样写进 out.json
const sink = join(workDir, 'sink.mjs');
writeFileSync(sink, `
import { writeFileSync } from 'node:fs';
const payload = {
  event: process.env.DSH_SR_EVENT ?? '',
  text: process.env.DSH_SR_TEXT ?? '',
  planId: process.env.DSH_SR_PLANID ?? '',
  count: process.env.DSH_SR_COUNT ?? '',
};
writeFileSync(process.argv[2], JSON.stringify(payload), 'utf8');
`, 'utf8');

const outFile = join(workDir, 'out.json');
const sinkCmd = `"${process.execPath}" "${sink}" "${outFile}"`;

// ── ① 没配命令 → 不执行任何东西 ───────────────────────────────────────────
console.log('=== ① 出厂默认：没配命令就什么都不做 ===');
{
  const r = await runNoticeHook({ command: '', event: 'restart-done', text: 'x' });
  check('空命令 → skipped=true', r.skipped === true, JSON.stringify(r));
  check('空命令 → ok=false', r.ok === false);
  const r2 = await runNoticeHook({ command: '   ', event: 'restart-done', text: 'x' });
  check('全空白命令同样跳过（不能拿空白当命令）', r2.skipped === true);
}
{
  const r = await runNoticeHook({ command: sinkCmd, event: '不存在的-事件', text: 'x' });
  check('未知事件 → 跳过，不执行命令', r.skipped === true && r.ok === false);
}

// ── ② 配了命令 → 真的执行，事件传得进去 ───────────────────────────────────
console.log('\n=== ② 配了命令：真的跑起来，内容传得进去 ===');
{
  if (existsSync(outFile)) rmSync(outFile);
  const r = await runNoticeHook({
    command: sinkCmd,
    event: 'restart-queued-long',
    text: '排队 21 分钟了',
    data: { planId: 'restart-abc', count: 2 },
  });
  check('命令执行成功 → ok=true', r.ok === true, JSON.stringify(r));
  check('子进程真的写了文件（证明进程确实起来了）', existsSync(outFile));
  if (existsSync(outFile)) {
    const got = JSON.parse(readFileSync(outFile, 'utf8'));
    check('事件名传进 DSH_SR_EVENT', got.event === 'restart-queued-long', got.event);
    check('正文传进 DSH_SR_TEXT', got.text === '排队 21 分钟了', got.text);
    check('data 的 planId 变成 DSH_SR_PLANID（大写归一）', got.planId === 'restart-abc', got.planId);
    check('data 的 count 变成 DSH_SR_COUNT', got.count === '2', got.count);
  }
}

// ── ③ 失败与超时：如实返回，绝不抛出 ─────────────────────────────────────
console.log('\n=== ③ 失败不抛出、超时会杀掉 ===');
{
  let threw = null;
  let r = null;
  try {
    r = await runNoticeHook({ command: '"不存在的程序-xyz"', event: 'restart-done', text: 'x', timeoutMs: 5000 });
  } catch (error) { threw = error; }
  check('命令起不来 → 不抛异常（重启不能被通知拖死）', threw === null, String(threw?.message ?? ''));
  check('命令起不来 → ok=false', r?.ok === false, JSON.stringify(r));
}
{
  const logs = [];
  const r = await runNoticeHook({
    command: `"${process.execPath}" -e "setTimeout(()=>{}, 60000)"`,
    event: 'restart-done',
    text: 'x',
    timeoutMs: 1500,
    log: (m) => logs.push(String(m)),
  });
  check('超时 → ok=false', r.ok === false, JSON.stringify(r));
  check('超时 → 日志里写明超时且说明不影响重启',
    logs.some((l) => l.includes('超时') && l.includes('不影响重启')), logs.join(' | '));
}

// ── ④ 并发守卫：同一时刻只跑一条 ─────────────────────────────────────────
console.log('\n=== ④ 并发守卫：后来的那条被跳过 ===');
{
  const run = createSerialNoticeRunner();
  const slowCmd = `"${process.execPath}" -e "setTimeout(()=>{}, 1200)"`;
  const first = run({ command: slowCmd, event: 'restart-done', text: '第一条', timeoutMs: 10000 });
  const second = await run({ command: slowCmd, event: 'restart-done', text: '第二条', timeoutMs: 10000 });
  check('第二条被跳过（skipped=true）', second.skipped === true, JSON.stringify(second));
  const firstResult = await first;
  check('第一条照常跑完', firstResult.ok === true, JSON.stringify(firstResult));
}

// ── ⑤ 事件表：README 里写的事件名必须在这里都有 ─────────────────────────
console.log('\n=== ⑤ 事件表自洽 ===');
check('事件表里有 restart-queued-long', Boolean(NOTICE_EVENTS['restart-queued-long']));
check('事件表里有 restart-done', Boolean(NOTICE_EVENTS['restart-done']));
check('事件表里有 wake-failed', Boolean(NOTICE_EVENTS['wake-failed']));

// ── ⑥ 源码层面：插件本体里不许再出现任何具体通知渠道 ────────────────────
console.log('\n=== ⑥ 插件本体不绑定任何通知渠道 ===');
{
  const src = readFileSync(join(ROOT, 'lib', 'index.js'), 'utf8');
  check('index.js 里没有 qq-say 之类的具体渠道路径', !/qq-say|delivery\/messages/i.test(src));
  check('index.js 里没有 notifyTarget 这类渠道专属配置', !/notifyTarget/.test(src));
  check('index.js 用的是通用通知入口', /noticeCommand/.test(src) && /notifyByHook/.test(src));
}

try { rmSync(workDir, { recursive: true, force: true }); } catch { /* 忽略 */ }

console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
process.exit(fail === 0 ? 0 : 1);
