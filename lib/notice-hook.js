/**
 * 外发通知钩子（notice hook）—— 本插件**不内置任何通知渠道**。
 *
 * 插件只做一件事：在特定事件发生时，**可选地**执行一条用户自己指定的命令，
 * 并把事件内容通过环境变量交给它。发不发、发给谁、用什么发，全在命令里。
 *
 * ── 为什么这样做（设计取舍）────────────────────────────────────────────────
 *   1. 通知渠道是**用户环境**的事，不是插件的事。写死某个渠道，等于要求每个
 *      使用者都装同样的东西；不装就静默失败，比没有通知更糟。
 *   2. 命令由**使用者**写在自己的配置里，插件不拼命令行、不做参数转义。
 *      因此这里没有注入面：能被注入的内容只有使用者自己提供的那条命令本身。
 *   3. 默认 `noticeCommand` 为空 —— 出厂状态下本插件不执行任何外部命令。
 *
 * ── 安全边界（使用者需要知道的）────────────────────────────────────────────
 *   · 插件**只**执行 `noticeCommand` 这一条字符串指定的程序；
 *     **不**执行 payload 里的任何内容，payload 只以环境变量形式传入。
 *   · 有超时（默认 30 秒）、有并发上限（同时最多 1 条在跑）、失败只记日志。
 *   · **失败绝不影响重启本身**：重启是该做的事，通知是锦上添花。
 */
import { spawn } from 'node:child_process';

/** 事件名 → 会传给命令的中文说明。命令可以按 `DSH_SR_EVENT` 分支。 */
export const NOTICE_EVENTS = {
  'restart-queued-long': '重启排在队里等了很久还没动手',
  'restart-done': '重启成功完成',
  'wake-failed': '重启成功了但没能叫醒排队的会话',
  'restart-failed': '重启失败或被取消',
};

/**
 * 把一次事件投给用户配置的命令。
 *
 * @param {object} p
 * @param {string} p.command      用户配置的命令（为空 = 不通知，直接返回 false）
 * @param {string} p.event        事件名，取值见 NOTICE_EVENTS
 * @param {string} p.text         人类可读的一句话正文
 * @param {object} [p.data]       结构化补充字段（数字、单号等），全部转成字符串进环境变量
 * @param {number} [p.timeoutMs]  超时，默认 30000
 * @param {(msg: string) => void} [p.log] 日志回调
 * @returns {Promise<{ ok: boolean, skipped?: boolean, exitCode?: number|null, error?: string }>}
 */
export function runNoticeHook({ command, event, text, data = {}, timeoutMs = 30000, log = () => {} } = {}) {
  const cmd = String(command ?? '').trim();
  if (!cmd) return Promise.resolve({ ok: false, skipped: true, error: 'noticeCommand 未配置' });
  if (!NOTICE_EVENTS[event]) return Promise.resolve({ ok: false, skipped: true, error: `未知事件：${event}` });

  // 环境变量：固定几个 + 事件里的标量字段。
  // ⚠️ 只取**字符串/数字/布尔**，对象和数组一律跳过 —— 避免把不可预期的结构塞进环境变量。
  const env = { ...process.env };
  env.DSH_SR_EVENT = event;
  env.DSH_SR_TEXT = String(text ?? '');
  for (const [k, v] of Object.entries(data)) {
    if (v === null || v === undefined) continue;
    if (typeof v === 'object') continue;
    env[`DSH_SR_${k.replace(/[^A-Za-z0-9_]/g, '_').toUpperCase()}`] = String(v);
  }

  return new Promise((resolvePromise) => {
    let settled = false;
    const done = (value) => { if (!settled) { settled = true; resolvePromise(value); } };

    let child;
    try {
      // ⚠️ 用 shell 执行整条命令：使用者写的是**命令**（可以带参数、管道、重定向），
      //    不是"可执行文件 + 参数数组"。这是有意的选择 —— 限制成数组形式会让
      //    "把正文从环境变量取出来传给某个 CLI"这种事变得写不出来。
      //    风险边界：命令来自使用者自己的配置，不是来自会话内容或网络。
      child = spawn(cmd, {
        shell: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
        env,
      });
    } catch (error) {
      done({ ok: false, error: String(error?.message ?? error) });
      return;
    }

    let out = '';
    const cap = (d) => { if (out.length < 4000) out += d.toString(); };
    child.stdout?.on('data', cap);
    child.stderr?.on('data', cap);

    const timer = setTimeout(() => {
      try { child.kill(); } catch { /* 忽略 */ }
      log(`通知钩子超时（${timeoutMs}ms），已终止 —— 不影响重启`);
      done({ ok: false, error: 'timeout' });
    }, Math.max(1000, Number(timeoutMs) || 30000));
    if (typeof timer.unref === 'function') timer.unref();

    child.on('error', (error) => {
      clearTimeout(timer);
      log(`通知钩子起不来（${String(error?.message ?? error).slice(0, 160)}）—— 不影响重启`);
      done({ ok: false, error: String(error?.message ?? error) });
    });

    child.on('exit', (code) => {
      clearTimeout(timer);
      const ok = code === 0;
      if (ok) log(`通知钩子已执行（事件 ${event}）`);
      else log(`通知钩子返回非零（${code}）：${out.slice(0, 200)} —— 不影响重启`);
      done({ ok, exitCode: code ?? null, error: ok ? undefined : `exit ${code}` });
    });
  });
}

/**
 * 同一时刻只允许一条钩子在跑 —— 防止"重排 + 成功 + 失败"三个事件同时刷出去。
 * 后来的直接跳过并记日志（丢一条通知 < 卡住重启流程）。
 */
export function createSerialNoticeRunner() {
  let busy = false;
  return async function runOnce(args) {
    if (busy) {
      (args.log ?? (() => {}))(`通知钩子正忙，跳过这次（事件 ${args.event}）`);
      return { ok: false, skipped: true, error: 'busy' };
    }
    busy = true;
    try {
      return await runNoticeHook(args);
    } finally {
      busy = false;
    }
  };
}
