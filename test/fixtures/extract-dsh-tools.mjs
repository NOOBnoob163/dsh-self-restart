// 从本机 DSH 的 app.asar 里取出 `@deepseek-ai/dsh-tools` 的打包产物，供自测使用。
//
// 【为什么是"现取"而不是"抄一份放进仓库"】（2026-10-13 改）
//   自测里有一项要验"插件给工具写的 JSON Schema 能不能过 DSH 自己的校验器"，
//   而那个校验器（`assertSupportedJsonSchema`）在 DSH 内部，不在插件包里。
//   最初的写法是把它连依赖一起从程序包里抽出来、**提交进仓库**（161 KB）——
//   那是**别人的代码**（`@deepseek-ai/dsh-tools`），而且抽出来时**没有带任何许可声明**。
//   但任何能装上本插件的人，机器上必然有 DSH —— 那份代码本来就在他机器上。
//   所以：**测试时现取**，不往仓库里放别人的东西。
//
// 【怎么取】
//   app.asar 的格式：`[4 字节][4 字节 header 长度][header JSON][数据段]`，
//   header 里每个文件带 `offset`（相对数据段起点）与 `size`。
//   这是只读操作，不动程序包。
//
// 【取出来的东西放哪】
//   `test/fixtures/.generated/`（已在 .gitignore 里）—— 每次自测自动生成，不入档。
//
// 用法：
//   node extract-dsh-tools.mjs            # 需要时生成，已存在则跳过
//   node extract-dsh-tools.mjs --force    # 强制重新生成
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(HERE, '.generated');
const OUT_FILE = join(OUT_DIR, 'asar-dsh-tools.js');

/** 找 DSH 装在哪：优先环境变量，再按常见安装位置找。 */
function findAsar() {
  const candidates = [];
  const local = process.env.LOCALAPPDATA ?? '';
  if (local) candidates.push(join(local, 'Programs', 'DeepSeek Harness', 'resources', 'app.asar'));
  candidates.push('C:\\Program Files\\DeepSeek Harness\\resources\\app.asar');
  for (const c of candidates) {
    try { if (existsSync(c)) return c; } catch { /* 忽略 */ }
  }
  return undefined;
}

/** 读 asar 的目录树（返回根节点）。 */
function readAsarTree(asarPath) {
  const buf = readFileSync(asarPath);
  const headerSize = buf.readUInt32LE(4);
  const header = buf.subarray(8, 8 + headerSize).toString('utf8');
  const json = JSON.parse(header.slice(header.indexOf('{')));
  return { buf, json, dataStart: 8 + headerSize };
}

/** 按路径取一个文件的内容。 */
function readAsarFile(tree, parts) {
  let node = tree.json;
  for (const part of parts) {
    node = node?.files?.[part];
    if (!node) return undefined;
  }
  if (node.offset === undefined) return undefined;
  const off = tree.dataStart + Number(node.offset);
  return tree.buf.subarray(off, off + Number(node.size)).toString('utf8');
}

function main() {
  const force = process.argv.includes('--force');
  if (!force && existsSync(OUT_FILE)) {
    console.log(`[跳过] 已存在：${OUT_FILE}（要重新生成加 --force）`);
    return 0;
  }

  const asarPath = findAsar();
  if (!asarPath) {
    console.error('[失败] 没找到 DSH 的 app.asar —— 自测需要本机装有 DSH 桌面版。');
    console.error('       找过：%LOCALAPPDATA%\\Programs\\DeepSeek Harness\\resources\\app.asar');
    console.error('              C:\\Program Files\\DeepSeek Harness\\resources\\app.asar');
    return 1;
  }

  let tree;
  try {
    tree = readAsarTree(asarPath);
  } catch (error) {
    console.error(`[失败] 读不了 app.asar：${String(error?.message ?? error)}`);
    return 1;
  }

  // dsh-tools 的打包产物：一个文件里含它全部内部模块，只需外部依赖（由 fixtures\node_modules 的替身提供）
  const source = readAsarFile(tree, ['dsh', 'node_modules', '@deepseek-ai', 'dsh-tools', 'lib', 'index.js']);
  if (!source) {
    console.error('[失败] app.asar 里没找到 @deepseek-ai/dsh-tools/lib/index.js');
    console.error('       （DSH 版本变了？先确认这个路径还在不在。）');
    return 1;
  }
  if (!source.includes('assertSupportedJsonSchema')) {
    console.error('[失败] 取到的内容里没有 assertSupportedJsonSchema —— 自测要用的校验器不在这里。');
    return 1;
  }

  mkdirSync(OUT_DIR, { recursive: true });
  // 头部加一行说明：这是**生成物**，不要提交（免得哪天有人误把它存回仓库）。
  // ⚠️ 不要写来源的绝对路径（含用户名）—— 这份文件虽然是生成物、已在 .gitignore 里，
  //    但万一被误提交，绝对路径就把使用者的目录结构带出去了。
  const banner = [
    '// ⚠️ 自动生成，请勿提交（见 test/fixtures/extract-dsh-tools.mjs）。',
    '// 内容取自本机 DSH 程序包里的 @deepseek-ai/dsh-tools，仅用于自测。',
    ''
  ].join('\n');
  writeFileSync(OUT_FILE, banner + source, 'utf8');
  console.log(`[完成] 已生成：${OUT_FILE}（${source.length} 字符）`);
  console.log(`       来源：${asarPath}`);
  return 0;
}

process.exit(main());
