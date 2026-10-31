// 自测：把插件当普通模块加载，喂一个假的 ctx，验证
//   ① 模块能 import（依赖能解析）
//   ② Config 能解析默认值
//   ③ 两个工具的 JSON Schema 能通过 DSH 自己的校验器（最关键 —— 注册时它会抛）
//   ④ state.json 被写出来
//
// 用法：node selftest.mjs
import { pathToFileURL, fileURLToPath } from 'node:url';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ★ 2026-10-12 改成运行时解析：早先这里写死了一个绝对路径
//   （`C:/Users/<用户名>/.dsh/profiles/desktop/plugins/dsh-self-restart/lib/index.js`）
//   —— 换台机器 clone 下来直接跑不了，而且把使用者的目录结构写进了源码。
//
//   ⚠️ 但这里有个**必须保留的性质**（第一版改错、被自测抓出来）：
//   插件 import 了 `@deepseek-ai/schemastery`，这个依赖装在
//   **DSH 的 profiles/desktop/node_modules** 下（不在插件包里）。
//   所以如果从**开发区**加载，Node 顺着 lib/ 往上找不到 node_modules → import 直接失败。
//   ⇒ 必须**优先用"使用区"那份**（那里依赖能解析），开发区只在使用区没有时才兜底。
const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const INSTALLED = join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'lib', 'index.js');
const LOCAL = join(fileURLToPath(new URL('..', import.meta.url)), 'lib', 'index.js');
const PLUGIN = existsSync(INSTALLED) ? INSTALLED : LOCAL;
// 自测用的 JSON Schema 校验器：**从本机 DSH 程序包里现取**，仓库里不放它。
//
// ★ 2026-10-13 改：原先这里放着一个 161 KB 的文件（`fixtures/asar-dsh-tools.js`），
//   是从 DSH 的 app.asar 里连依赖一起抽出来、**提交进仓库**的。
//   问题有两个：① 那是 `@deepseek-ai/dsh-tools` 的代码，不是本插件的；
//   ② 抽出来时**没有带它的许可声明**（该包是 BSD-3-Clause）。
//   而任何能装上本插件的人，机器上必然有 DSH —— 那份代码本来就在。
//   所以改成**测试时现取**：`fixtures/extract-dsh-tools.mjs` 生成到 `.generated/`（不入档）。
const TOOLS_SRC = fileURLToPath(new URL('./fixtures/.generated/asar-dsh-tools.js', import.meta.url));

const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok, detail });
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
};

// ── ① import ────────────────────────────────────────────────────────────────
let mod;
try {
  mod = await import(pathToFileURL(PLUGIN).href);
  check('插件模块能 import', true, `导出: ${Object.keys(mod).join(', ')}`);
} catch (error) {
  check('插件模块能 import', false, String(error?.message ?? error));
  process.exit(1);
}

// ── ② Config ────────────────────────────────────────────────────────────────
// ★★ 2026-10-13 重要修正：**给假 ctx 跑的 Config 必须把 stateDir 指到临时目录** ★★
//
// 【为什么（这是我自己实测抓到的一个"假通过"）】
//   本文件下面会用**假 ctx** 调 `mod.apply(fakeCtx, config)` —— 那是真的在跑插件的
//   apply()，而 apply() 里第一件事就是 `writeState()`，把状态写进 `state.json`。
//   假 ctx 不影响写盘，于是：**selftest 会以新代码往真实 state.json 写一次 impl=4**。
//
//   后果很隐蔽：紧接着跑的 `verify-roots.mjs` 读到 impl=4 → **报"新代码在跑"（假通过）**，
//   可真正跑在宿主里的插件其实还是**旧的**（改 lib/index.js 必须重启宿主才进内存），
//   真宿主每 10 秒又把 state.json 覆盖回 impl=3。
//   ⇒ 一个本该回答"新代码生效了吗"的探针，被上一套测试自己喂了假答案。
//
//   修法：这里的 Config **不碰使用者的真实状态目录**（顺带也不会污染它的日志/state）。
//   真实目录只让**真宿主**去写 —— 那才是 verify-roots 该读的东西。
const tmpStateDir = join(process.env.TEMP ?? process.env.TMP ?? '.', `dsh-sr-selftest-${process.pid}`);
let config;
try {
  config = new mod.Config({ stateDir: tmpStateDir });
  const plain = JSON.parse(JSON.stringify(config));
  check('Config 能解析默认值', plain.port === 19387 && plain.enabled === true, JSON.stringify(plain));
  check('★ 自测不碰真实状态目录（否则会给 verify-roots 喂假答案）',
    plain.stateDir === tmpStateDir, plain.stateDir);
} catch (error) {
  check('Config 能解析默认值', false, String(error?.message ?? error));
}

// ── ③ 工具注册（用真校验器） ─────────────────────────────────────────────────
// DSH 的 tools.register 会 assertSupportedJsonSchema(output.schema) 并检查
// output.render 是函数。这里把从本机 DSH 取来的 dsh-tools 当模块加载，
// 直接调它的校验函数，确保注册不会在运行时抛。
let validate = null;
try {
  // 没有就先生成（幂等：已存在直接跳过）—— 别人 clone 下来跑测试不用先看文档
  const gen = fileURLToPath(new URL('./fixtures/extract-dsh-tools.mjs', import.meta.url));
  if (!existsSync(TOOLS_SRC)) {
    const { spawnSync } = await import('node:child_process');
    spawnSync(process.execPath, [gen], { stdio: 'inherit' });
  }
  const tools = await import(pathToFileURL(TOOLS_SRC).href);
  validate = tools.assertSupportedJsonSchema;
  check('能加载 DSH 的 schema 校验器', typeof validate === 'function');
} catch (error) {
  check('能加载 DSH 的 schema 校验器', false, String(error?.message ?? error));
  console.log('   ↳ 这份文件由 fixtures\\extract-dsh-tools.mjs 从本机 DSH 现取，需要本机装有 DSH 桌面版。');
}

// 收集插件注册的工具
const registered = [];
const fakeCtx = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: () => {},
  effect: () => {},
  tools: {
    register(definition) {
      registered.push(definition);
      return () => {};
    }
  }
};

try {
  mod.apply(fakeCtx, config);
  check('apply() 能跑完不抛', true, `注册了 ${registered.length} 个工具`);
} catch (error) {
  check('apply() 能跑完不抛', false, String(error?.message ?? error));
}

for (const tool of registered) {
  const label = `工具 ${tool.name}`;
  // 名字
  if (typeof tool.name !== 'string' || !tool.name) { check(`${label} 名字合法`, false); continue; }
  // output.render 必须是函数
  const renderOk = tool.output && typeof tool.output.render === 'function';
  // 输出 schema 必须过校验
  let outOk = false, outDetail = '';
  if (validate) {
    try { validate(tool.output.schema); outOk = true; }
    catch (error) { outDetail = String(error?.message ?? error); }
  }
  // 参数 schema 必须过校验（参数是裸 JSON Schema，同样受这套子集约束）
  let paramOk = false, paramDetail = '';
  if (validate) {
    try { validate(tool.parameters); paramOk = true; }
    catch (error) { paramDetail = String(error?.message ?? error); }
  }
  // execute 必须是函数
  const execOk = typeof tool.execute === 'function';

  check(`${label}: output.render 是函数`, renderOk);
  check(`${label}: 输出 schema 过校验`, outOk, outDetail);
  check(`${label}: 参数 schema 过校验`, paramOk, paramDetail);
  check(`${label}: execute 是函数`, execOk);

  // 参数名与实际使用是否一致（防止 schema 声明了但代码读错字段）
  if (tool.name === 'restart_self') {
    const props = Object.keys(tool.parameters.properties ?? {});
    const expect = ['confirm', 'delay_seconds', 'reason', 'max_wait_minutes', 'dry_run'];
    const missing = expect.filter((k) => !props.includes(k));
    check(`${label}: 参数齐全`, missing.length === 0, missing.length ? `缺 ${missing.join(',')}` : props.join(', '));
    check(`${label}: confirm 是必填`, Array.isArray(tool.parameters.required) && tool.parameters.required.includes('confirm'));
  }
  if (tool.name === 'restart_status') {
    const props = Object.keys(tool.parameters.properties ?? {});
    check(`${label}: 参数齐全`, props.includes('cancel'), props.join(', '));
  }
}

// ── ④ 干跑一次 execute（不真重启）───────────────────────────────────────────
for (const tool of registered) {
  if (tool.name === 'restart_self') {
    try {
      const r = await tool.execute({ confirm: false }, {});
      check('restart_self 不传 confirm 会拒绝', r.ok === false, String(r.message).slice(0, 60));
    } catch (error) {
      check('restart_self 不传 confirm 会拒绝', false, String(error?.message ?? error));
    }
    try {
      const r = await tool.execute({ confirm: true, dry_run: true, reason: '自测空跑' }, {});
      const good = r.ok === true && String(r.message).includes('空跑');
      check('restart_self 空跑模式能出报告', good, good ? '' : String(r.message).slice(0, 200));
      if (good) console.log('\n--- 空跑输出 ---\n' + r.message + '\n----------------\n');
    } catch (error) {
      check('restart_self 空跑模式能出报告', false, String(error?.message ?? error));
    }
  }
  if (tool.name === 'restart_status') {
    try {
      const r = await tool.execute({}, {});
      check('restart_status 能出状态', typeof r.message === 'string' && r.message.length > 0, '');
      console.log('\n--- 状态输出 ---\n' + r.message + '\n----------------\n');
    } catch (error) {
      check('restart_status 能出状态', false, String(error?.message ?? error));
    }
  }
}

// ── ⑤ state.json 是否写出来 ─────────────────────────────────────────────────
// ★ 2026-10-13 改：读**临时目录**那份（上面 Config 指定的），不是使用者的真实状态目录。
//   理由见 ② 那段的长注释：自测以新代码写真实 state.json 会让 verify-roots 假通过。
const statePath = join(tmpStateDir, 'state.json');
check('state.json 已写出（在临时目录里，没碰真实状态目录）', existsSync(statePath), statePath);
if (existsSync(statePath)) {
  try {
    const s = JSON.parse(readFileSync(statePath, 'utf8'));
    check('state.json 内容合理', typeof s.updatedAt === 'number' && typeof s.jobsRunning === 'number',
      `jobsRunning=${s.jobsRunning} agentsRunning=${s.agentsRunning}`);
    check('★ 这份 state.json 的 impl 就是本代码的版本（探针自洽）',
      Number(s.impl) === Number(mod.IMPL_VERSION), `impl=${s.impl} vs IMPL_VERSION=${mod.IMPL_VERSION}`);
  } catch (error) {
    check('state.json 内容合理', false, String(error?.message ?? error));
  }
}

// 收尾：把临时目录清掉（走回收站不合用于 %TEMP%，这里直接删自己刚建的目录）
try {
  const { rmSync } = await import('node:fs');
  rmSync(tmpStateDir, { recursive: true, force: true });
} catch { /* 清不掉不影响结论 */ }

// ── 汇总 ────────────────────────────────────────────────────────────────────
const failed = results.filter((r) => !r.ok);
console.log(`\n===== 自测汇总：${results.length - failed.length}/${results.length} 通过 =====`);
if (failed.length) {
  console.log('失败项：');
  for (const f of failed) console.log(`  · ${f.name} ${f.detail}`);
  process.exit(1);
}
process.exit(0);
