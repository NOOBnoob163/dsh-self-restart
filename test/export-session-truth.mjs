#!/usr/bin/env node
/**
 * 把"会话 → 是不是子代理"的地面真值导出成 TSV，供 PS 5.1 侧的测试读。
 *
 * 为什么不让 PowerShell 自己解 JSON：
 *   PS 5.1 里 `node ... | Out-String | ConvertFrom-Json` 拿到的是**一个**包着数组的对象
 *   （不枚举），`$all.Count` 会变成 1、逐项取属性直接失败。实测踩到：
 *   "真对话 0 个"这种**空集假通过**就是这么来的 —— 而它恰好掩盖了最危险的方向
 *   （真对话被误判成子代理）。所以真值一律在 node 侧算好，PS 侧只读平文本。
 *
 * 真值判据（2026-10-10 实测：0 危险 / 0 漏网）：
 *   header.origin === 'subagent' 或 header.delegationDepth >= 1
 *   —— 绝不用 parentSession（本机有 25 个真对话带 parentSession）。
 *
 * 用法：node export-session-truth.mjs <输出.tsv>
 */
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const DSH_HOME = process.env.DSH_HOME || path.join(process.env.USERPROFILE || '', '.dsh');
const SESS = path.join(DSH_HOME, 'sessions');
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const out = process.argv[2];
if (!out) { console.error('用法：node export-session-truth.mjs <输出.tsv>'); process.exit(2); }

function headerOf(file) {
  const size = fs.statSync(file).size;
  const fd = fs.openSync(file, 'r');
  const chunk = Buffer.alloc(Math.min(size, 65536));
  const n = fs.readSync(fd, chunk, 0, chunk.length, 0);
  fs.closeSync(fd);
  const buf = chunk.subarray(0, n);
  const offs = [];
  let i = 0;
  while ((i = buf.indexOf(MAGIC, i)) >= 0) { offs.push(i); i += 4; }
  if (!offs.length) return null;
  offs.push(buf.length);
  const parts = [];
  let k = 0;
  while (k < offs.length - 1 && parts.length < 2) {
    let end = k + 1, ok = false;
    while (end < offs.length && end - k <= 8) {
      try { parts.push(zlib.zstdDecompressSync(buf.subarray(offs[k], offs[end])).toString('utf8')); ok = true; break; }
      catch { end++; }
    }
    if (!ok) break;
    k = end;
  }
  const line = parts.join('').split('\n').find((l) => l.trim());
  try { return JSON.parse(line); } catch { return null; }
}

const lines = ['dir\tisSub\torigin\tdepth'];
let n = 0;
for (const ws of fs.readdirSync(SESS, { withFileTypes: true })) {
  if (!ws.isDirectory()) continue;
  for (const s of fs.readdirSync(path.join(SESS, ws.name), { withFileTypes: true })) {
    if (!s.isDirectory()) continue;
    const dir = path.join(SESS, ws.name, s.name);
    let files; try { files = fs.readdirSync(dir).filter((f) => /^session.*\.jsonl\.zstd$/.test(f)); } catch { continue; }
    if (!files.length) continue;
    const pick = files.map((f) => { const st = fs.statSync(path.join(dir, f)); return { p: path.join(dir, f), ver: (/\.v(\d+)\./.exec(f) || [, 0])[1], mtime: st.mtimeMs }; })
      .sort((a, b) => (b.ver - a.ver) || (b.mtime - a.mtime))[0];
    const h = headerOf(pick.p);
    const isSub = (h?.origin === 'subagent') || (Number(h?.delegationDepth ?? 0) >= 1);
    lines.push([s.name, isSub ? '1' : '0', String(h?.origin ?? ''), String(h?.delegationDepth ?? '')].join('\t'));
    n++;
  }
}
fs.writeFileSync(out, lines.join('\n') + '\n', 'utf8');
console.log(`已导出 ${n} 个会话的真值 → ${out}`);
