// 实测：插件的 survey() 真能拿到 roots() 吗？报出来的"根会话/子代理"分得对吗？
//
// 为什么必须实测而不是看代码：这次整个修法都压在"roots() 能区分真对话和子代理"上。
// 拿不到（或拿到空集）就会**退化**成"全是根会话"→ 又变回"子代理也算别人在忙" → 没修好。
// 这个脚本直接断言 state.json 里已经带了 runningSubagents 字段、且两栏都合理。
//
// 用法：node verify-roots.mjs
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const statePath = join(homedir(), '.dsh', 'self-restart', 'state.json');
let pass = 0;
let fail = 0;

function check(name, ok, detail = '') {
  if (ok) { pass += 1; console.log(`✅ ${name}${detail ? ' — ' + detail : ''}`); }
  else { fail += 1; console.log(`❌ ${name}${detail ? ' — ' + detail : ''}`); }
}

console.log('=== 读插件写的 state.json ===');
if (!existsSync(statePath)) {
  console.log('❌ 没有 state.json —— 插件没在跑？');
  process.exit(1);
}
const s = JSON.parse(readFileSync(statePath, 'utf8'));
console.log(JSON.stringify({
  updatedAt: s.updatedAt,
  jobsRunning: s.jobsRunning,
  agentsRunning: s.agentsRunning,
  runningSessions: s.runningSessions,
  runningSubagents: s.runningSubagents
}, null, 2));

const ageSec = Date.now() / 1000 - Number(s.updatedAt) / 1000;
check('state.json 是新鲜的（<30s）', ageSec <= 30, `${Math.round(ageSec)} 秒前写的`);
check('带了 runningSubagents 字段（= 新代码在跑）', Object.prototype.hasOwnProperty.call(s, 'runningSubagents'));
check('runningSessions 是数组（根会话栏）', Array.isArray(s.runningSessions));
check('runningSubagents 是数组（子代理栏）', Array.isArray(s.runningSubagents));

// ★★ 2026-10-13 加：**这份 state.json 必须是"真宿主"写的，不是哪套测试代写的** ★★
//
//   【为什么必须验这一条】这道探针的任务是回答"真宿主里跑的是新代码吗"。
//   而"有没有别的进程也写 state.json"决定了这个答案可不可信：
//     · 插件自己带着 `pid: process.pid`（真宿主那支就是 DSH 的进程号）；
//     · 而在**测试**里跑 apply() 的那个 node 进程，写出的 pid 是**它自己**。
//   实测踩到（2026-10-13）：`verify-inject.mjs` / `selftest.mjs` 都用默认配置调过 apply()，
//   于是它们**以新代码往真实 state.json 写了一次 impl=4** → 紧接着跑的本脚本读到 4 →
//   报"新代码在跑"（**假通过**），可真正的宿主里跑的还是旧代码。
//   ⇒ 修法有两层：① 那两套测试改成写临时目录（已修）；② **这里自己也加一道**，
//     用 pid 交叉核对"写这份文件的进程，是不是真的在监听那个端口的那一支"。
const listeners = (() => {
  try {
    const out = execFileSync('powershell', ['-NoProfile', '-Command',
      `(Get-NetTCPConnection -LocalPort ${Number(s.port)} -State Listen -ErrorAction SilentlyContinue).OwningProcess`],
      { encoding: 'utf8', timeout: 15000, windowsHide: true });
    return String(out).split(/\s+/).filter(Boolean).map(Number).filter(Number.isFinite);
  } catch { return null; }
})();

if (listeners === null || listeners.length === 0) {
  console.log(`⚠️  读不到端口 ${s.port} 的监听者 PID —— 跳过"这份 state.json 是不是真宿主写的"这一条`);
} else {
  const hostPid = Number(s.pid);
  const isHost = listeners.includes(hostPid);
  check('★★ state.json 是**真宿主**写的（pid 就是监听该端口的那一支，不是测试代写）',
    isHost,
    isHost ? `pid=${hostPid} 正是监听者` :
      `state.json 里的 pid=${hostPid}，而端口监听者是 ${listeners.join(',')} —— ` +
      '这份文件是别处（多半是某套测试）写的，impl 探针的结论**不可信**');
}

// ★ 2026-10-11 新增：**实现版本探针**
//   为什么必须有：改完 lib\index.js 之后 HMR **不会**重载模块代码，
//   但插件日志照样打印「插件已挂上」—— 看着像生效了，实际执行的仍是旧代码。
//   所以新实现会往 state.json 写一个 impl 字段（老实现根本没这个字段）。
//   ⚠️ 这条**失败通常不是你写错了代码，而是"改了插件没重启宿主"** ——
//      看到它红，先重启 DSH 让新代码进内存，再跑一次。
//   ★ 2026-10-13：数字从 2 提到 3（那天的改动：汇报并进心跳 + restart_status 现算流水账分布）。
//   ★ 2026-10-13 晚：3 提到 4（唤醒从"排定时提醒"改成"直接把消息投进会话"，不再依赖 schedule）。
//   ★ 2026-10-13 深夜：4 提到 5（工具说明改成"delay_seconds 一律填 0、重启放最后一个动作"；
//     旧口径"按回复长度填 30~60"被推翻）。改这个数字的意义就是"让'跑的是旧代码'一眼可见"。
//   ★ 2026-10-13 深夜②：5 提到 6（"这一轮说完没有"改用权威状态 agent.status，
//     不再只靠文件静默猜；并加 agentStatusById 字段 + agent/status 即时落盘 + 轮询 5s→2s）。
//   ★ 2026-10-13 深夜③：6 提到 7（新增 resume 参数：续不续接由模型自己选；收尾型重启可不叫醒）。
//   ★ 2026-10-17 深夜：7 提到 8（端口不再写死 19387，改用 webServer.port 问真实端口——
//     DSH 0.2.1-rc.2 起 GUI 端口是 --port 0 动态分配，写死会让助手判"没起来"后连环杀 DSH）。
//   ★ 2026-10-22：8 提到 9（排队重启：入队继续等 / 默认一直等 / members 名单 /
//     按名单挨个喊 / 会话来源判据 rpcId / 标题标记 / QQ 提醒）。
//   ★ 2026-10-23 下午：9/10~13 之后提到 14（排队重启的四处硬伤：入队回包字段没声明
//     导致宿主整份拒收 → 第二个排的人以为没排上，误取消把两个人一起打掉；
//     说明里"每人可自己退出"是假的；restart_status 不显示名单；取消后不封口）。
//   ★ 2026-10-24 晚：14 → 15（`max_wait_minutes` 三层默认值统一成 0「一直等」：
//     schema 本来就 0，但 lib 兜底和助手 else 都是 5；工具说明还谎称 default 5 minutes）。
//     ⚠️ 改这个数字的意义：**它就是"新代码进内存了没有"的唯一判据** ——
//     这次差点漏掉（改完 lib 忘了提版本，重启后没法验证），代价是白重启一趟。
//   ★ 2026-10-25：15 → 16（标题不再和 dsh-im 的「QQ · 」前缀互相抢：
//     图标改排在频道前缀**后面**，历史脏标题一次还原）。
//   ★ 2026-10-25 晚：16 → 17（「重启成功但没叫醒」的 QQ 提醒会误报：改成
//     三条同时成立才发 —— 真该叫醒 + 那趟真完成 + 没投成）。
const EXPECTED_IMPL = 18;
check(`★ 实现版本探针 impl === ${EXPECTED_IMPL}（= 当前这版实现已在跑）`,
  Number(s.impl) === EXPECTED_IMPL,
  Number(s.impl) === EXPECTED_IMPL
    ? `impl=${EXPECTED_IMPL} ✓`
    : `impl=${s.impl === undefined ? '（字段不存在 = 跑的还是老代码）' : s.impl} —— 改了 lib/index.js 就必须重启 DSH`);


// 关键断言：两栏加起来应该正好等于"在跑的 agent 总数"
const sum = (s.runningSessions?.length ?? 0) + (s.runningSubagents?.length ?? 0);
check('两栏之和 == agentsRunning（分类没漏、没重复）', sum === Number(s.agentsRunning), `${sum} vs ${s.agentsRunning}`);

// 根会话应当时刻至少有一个（就是当前这个对话）——除非此刻完全空闲
console.log('\n=== 解读 ===');
console.log(`根会话（真对话）: ${JSON.stringify(s.runningSessions)}`);
console.log(`子代理（家务）  : ${JSON.stringify(s.runningSubagents)}`);
if ((s.runningSubagents?.length ?? 0) > 0) {
  console.log('→ 此刻正有家务子代理在跑；按新规则**不该**拦重启，而应等它跑完。');
} else {
  console.log('→ 此刻没有家务子代理；可直接重启（若无别的对话）。');
}

console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
process.exit(fail ? 1 : 0);
