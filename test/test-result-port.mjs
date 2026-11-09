// test-result-port.mjs —— 「重启记录里的端口，必须写真的那个」（2026-10-24 新增，历史事故）
//
// 【为什么要有这一套】
//   2026-10-24 14:35 那次重启，last-run.json 长这样：
//       "detail": "DSH 已重新起来，端口 9184 正常监听（第 1 次尝试）。"   ← 真的
//       "port":   1807                                                ← 重启前那个
//   同一次调用里用了**两个变量**：detail 用 $script:ActualPort，port 字段用 $port。
//   后果不大（人看 detail 就知道真端口），但它是个**会骗人的字段** —— 将来谁拿它当权威就中招。
//   而且这不是孤例：流水账 history.jsonl 的 port **压根没写过**（57 行 0 行有它）。
//
// 【为什么用"结构断言"而不是"字串断言"】
//   本仓踩过：把 `AppendAllText($histPath` 断言改成 `$histPath + ".off"`（写错文件）**照样通过**。
//   所以这里不查"有没有出现某个字串"，而是：
//     ① 把 Save-Result 的 payload 块**切出来**，确认 port 那一行赋的是 $script:ActualPort；
//     ② 把追加流水账的 $row 块**切出来**，确认里面有 port 项、且同一个来源；
//     ③ 反过来确认 `port = $port`（旧写法）**一处都不剩**；
//     ④ 交叉核对：detail 用的也是 ActualPort —— 两个字段同源，不许一处改了一处忘了。
//
// 【它防的是什么】
//   将来谁"顺手整理"这段代码，把 port 改回 $port（看起来更直观），或者补流水账字段时漏掉 port，
//   这套会立刻红。改坏自检已做过（见文件末尾注释）。
//
// 用法：node test-result-port.mjs
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
};

// ── 找助手脚本（bin\dsh-self-restart.ps1）────────────────────────────────────
// 优先开发区（我刚改的那份）；不在就退回使用区。**打印出来用的是哪份** ——
// 本仓踩过"一直在测没改过的旧代码"，所以这一行不许省。
const LOCAL_DIR = fileURLToPath(new URL('..', import.meta.url));
const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(process.env.USERPROFILE ?? '', '.dsh');
const CANDIDATES = [
  { path: join(LOCAL_DIR, 'bin', 'dsh-self-restart.ps1'), which: '开发区（我刚改的那份）' },
  { path: join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'bin', 'dsh-self-restart.ps1'), which: '使用区（开发区那份不在，退回）' }
];

let helperPath = null;
let which = '';
for (const c of CANDIDATES) {
  if (existsSync(c.path)) { helperPath = c.path; which = c.which; break; }
}
if (!helperPath) {
  console.log('❌ 找不到 bin\\dsh-self-restart.ps1（开发区和使用区都没有）');
  process.exit(1);
}
console.log(`（本次测试跑的是：${which}）\n${helperPath}\n`);

const text = readFileSync(helperPath, 'utf8');

// ── 小工具：按"括号配对"切出一段代码块 ───────────────────────────────────────
// 为什么不用正则截：`[ordered]@{ ... }` 里面还嵌着 `@{ ... }`（members 那段），
// 正则数不清层数。这里老老实实数花括号，从 `{` 数到配对的 `}`。
function sliceBalanced(src, startIdx) {
  const open = src.indexOf('{', startIdx);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const ch = src[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  return null;
}

// ── ① 把 Save-Result 的 payload 块切出来 ─────────────────────────────────────
// ⚠️⚠️ 这里踩过一次，记下来：**全文件里 `$payload = [ordered]@{` 不止一处** ——
//   QQ 通知函数（约 L205）也有一个同名变量，里面有个 `port = $sendPort`。
//   第一版直接 `text.indexOf('$payload = ...')` → 切到了**那个**块 →
//   断言红着说"port 赋的是 $sendPort"，看起来像代码改坏了，其实**是测试找错了地方**。
//   （本仓的老教训。）
//   ⇒ 现在先定位 `function Save-Result`，**从它之后**再找 $payload。
const saveResultAt = text.indexOf('function Save-Result');
check('找得到 function Save-Result', saveResultAt >= 0);
const payloadAt = saveResultAt >= 0 ? text.indexOf('$payload = [ordered]@{', saveResultAt) : -1;
check('找得到 Save-Result 里的 $payload 块（不是别处同名变量）', payloadAt >= 0);
const payloadBlock = payloadAt >= 0 ? sliceBalanced(text, payloadAt) : null;
check('$payload 块能完整切出来（括号配对）', !!payloadBlock && payloadBlock.length > 100,
  payloadBlock ? `${payloadBlock.length} 字符` : '切不出来');

// ── ② payload 里 port 那一行，必须赋 $script:ActualPort ──────────────────────
// 只认"行首（可缩进）port = ..."，避免匹配到注释里提到的 port。
const portAssign = payloadBlock ? payloadBlock.match(/^\s*port\s*=\s*(.+)$/m) : null;
check('$payload 里有 port 字段', !!portAssign, portAssign ? portAssign[0].trim() : '没有');
check('★ port 字段赋的是 $script:ActualPort（不是 $port）',
  !!portAssign && /\$script:ActualPort/.test(portAssign[1]),
  portAssign ? `实际：${portAssign[1].trim()}` : '');

// ── ③ 追加流水账的 $row 块，必须也有 port，且同一个来源 ──────────────────────
const rowAt = text.indexOf('$row = [ordered]@{');
check('找得到追加流水账的 $row 块', rowAt >= 0);
const rowBlock = rowAt >= 0 ? sliceBalanced(text, rowAt) : null;
check('$row 块能完整切出来', !!rowBlock && rowBlock.length > 50,
  rowBlock ? `${rowBlock.length} 字符` : '切不出来');
const rowPort = rowBlock ? rowBlock.match(/^\s*port\s*=\s*(.+)$/m) : null;
check('★ 流水账 $row 里有 port 字段（历史事故 前压根没有）', !!rowPort,
  rowPort ? rowPort[0].trim() : '没有 —— 流水账会继续缺端口');
check('★ 流水账的 port 与 last-run 的 port 同源（都是 $script:ActualPort）',
  !!rowPort && /\$script:ActualPort/.test(rowPort[1]),
  rowPort ? `实际：${rowPort[1].trim()}` : '');

// ── ④ 旧写法必须一处不剩 ─────────────────────────────────────────────────────
// `port = $port` 是那个 bug 的原样。它不许在任何"写结果"的地方出现。
// ⚠️ 只查 payload / row 两个块 —— 别处的 $port 是正常用法（盯端口、判监听），不能误伤。
const oldInPayload = payloadBlock ? /^\s*port\s*=\s*\$port\s*$/m.test(payloadBlock) : false;
const oldInRow = rowBlock ? /^\s*port\s*=\s*\$port\s*$/m.test(rowBlock) : false;
check('★ 旧写法 `port = $port` 在 payload 里已消失', !oldInPayload);
check('★ 旧写法 `port = $port` 在 $row 里已消失', !oldInRow);

// ── ⑤ 交叉核对：detail 里报的端口必须也是 ActualPort ─────────────────────────
// 这一条是"同一次调用两个变量"那个病的**正面钉子**：
// 两个字段都写 ActualPort，才不会出现"detail 说 9184、port 说 1807"。
const detailLine = text.match(/端口 \{0\} 正常监听[^\n]*/);
check('找得到 detail 那句（端口 {0} 正常监听）', !!detailLine);
check('★ detail 报的端口也来自 $script:ActualPort（两处同源）',
  !!detailLine && /\$script:ActualPort/.test(detailLine[0]),
  detailLine ? detailLine[0].trim() : '');

// ── ⑥ 别改坏别的：ActualPort 必须仍然在"起来之后"被改成真值 ──────────────────
// 如果哪天有人把 ActualPort 的赋值删了，上面几条会全绿（因为都写着 ActualPort），
// 但实际写出来的永远是计划里那个端口 —— **那就变成了另一种假绿**。
//
// ⚠️⚠️ 第一版这条只查"字串在不在"，**改坏自检当场证明它是假保险网**：
//   我把 `if ($newPorts.Count -gt 0) { $script:ActualPort = ... }` 掰成
//   `if ($false) { $script:ActualPort = ... }` —— 字串还在，**14/14 照样全绿**，
//   而功能已经死了（永远写计划值）。这正是本仓反复记的"只验字串存在 = 假保险网"。
//   ⇒ 现在连**守卫条件**一起钉：赋值那行必须同时带着 `$newPorts.Count -gt 0`。
//      删掉整行 → 红；改成恒假条件 → 红；把条件改成语义相同的写法 → 才可能误红（可接受）。
const actualAssignLines = text.split(/\r?\n/).filter((l) => /\$script:ActualPort\s*=\s*\[int\]\$newPorts\[0\]/.test(l));
check('★ ActualPort 仍会在"起来之后"被改成真端口（赋值那行还在）', actualAssignLines.length > 0,
  `${actualAssignLines.length} 处`);
const allGuarded = actualAssignLines.length > 0
  && actualAssignLines.every((l) => /\$newPorts\.Count\s*-gt\s*0/.test(l));
check('★ 那行赋值的守卫条件不是恒假（必须真是"新进程树有端口才改"）', allGuarded,
  actualAssignLines.length ? actualAssignLines[0].trim().slice(0, 90) : '没有赋值行');

// ── 汇总 ─────────────────────────────────────────────────────────────────────
const passed = results.filter((r) => r.ok).length;
const total = results.length;
console.log(`\n===== 汇总：${passed}/${total} 通过 =====`);
if (passed !== total) {
  console.log('\n失败项：');
  for (const r of results.filter((x) => !x.ok)) {
    console.log(`  · ${r.name}${r.detail ? `（${r.detail}）` : ''}`);
  }
  process.exit(1);
}
process.exit(0);

// ── 改坏自检记录（2026-10-24，按本仓规矩：不证明会变红就不算数）───────────────
//   实测（每次都先断言"掰坏后 needle 真的变了"，防止假掰坏）：
//   ① payload 的 `port = $script:ActualPort` 改回 `port = $port`
//      → **11/15**，红 4 条（port 赋错值 / 两处不同源 / 两个块都有旧写法）
//      ⚠️ 如实记：这次 `[regex]::Replace(...,1)` 的第 4 个参数被当成 RegexOptions.IgnoreCase，
//         于是**两处一起被替换了**（不是只换第一处）。不影响结论 —— 断言确实会红。
//   ② 删掉流水账 $row 里那行 port
//      → **13/15**，红 2 条（流水账没 port / 不同源）
//   ③ 守卫条件 `$newPorts.Count -gt 0` 改成 `$false`
//      → **14/15**，红 1 条（守卫恒假）
//   还原后 **15/15**，且文件哈希与备份一致。
//
//   ⚠️ 第 ③ 条是第一版**假绿**的证据：第一版只查"赋值那行字串在不在"，
//      掰成 `if ($false) { ... }` 时字串还在 → **14/14 全绿**，而功能已死。
//      ⇒ 这就是本仓那句"只验字串存在 = 假保险网"的又一例，已改成连守卫条件一起钉。
