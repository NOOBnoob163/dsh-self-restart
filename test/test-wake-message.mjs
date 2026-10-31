// test-wake-message.mjs —— 「投进会话的那条消息，形状对不对」
//
// ★ 2026-10-13 新增（唤醒机制从"排定时提醒"改成"直接投递消息"时配套加的）。
//
// 【为什么这一套必须存在，而且必须是"真函数"而不是"正则查源码"】
//   2026-10 出过一次事故：有人把**字符串**喂给 agent.followup()，
//   而 inbox 的 mutate() 对插入项**没有任何类型检查**（只查 message.id 有没有重复，
//   字符串的 .id 是 undefined，单个能过）→ "没有 id、没有 content 的货"
//   被原样 append 进会话账本 → 界面按消息对象的形状去读它 → 崩，
//   两个会话直接打不开、整个会话列表变空白。
//
//   ⇒ "喂进去的到底是不是一条合法消息"这件事，**值得用真函数验**。
//     源码里的正则只能证明"代码里写着这几个字段名"，证明不了产出的对象真的对。
//     所以本文件直接 import 插件导出的 makeWakeMessage，把它产出的对象逐字段称重。
//
// 用法：node test-wake-message.mjs
//   ⚠️ 和 selftest.mjs 一样，**优先加载"使用区"那份**：插件 import 了
//      @deepseek-ai/schemastery，那个依赖装在 DSH 的 profiles/desktop/node_modules 下，
//      从开发区加载会因为找不到 node_modules 而 import 失败。
import { pathToFileURL, fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const INSTALLED = join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'lib', 'index.js');
const LOCAL = join(fileURLToPath(new URL('..', import.meta.url)), 'lib', 'index.js');
const PLUGIN = existsSync(INSTALLED) ? INSTALLED : LOCAL;

let pass = 0;
let fail = 0;
const check = (name, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`✅ ${name}${detail ? ' — ' + detail : ''}`); }
  else { fail += 1; console.log(`❌ ${name}${detail ? ' — ' + detail : ''}`); }
};

console.log(`（加载的实现：${PLUGIN}）\n`);

const mod = await import(pathToFileURL(PLUGIN).href);

check('插件导出了 makeWakeMessage（可被真函数验证，而不是靠正则猜）',
  typeof mod.makeWakeMessage === 'function');
if (typeof mod.makeWakeMessage !== 'function') {
  console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
  process.exit(1);
}

const text = '【这是 dsh-self-restart 插件的自动唤醒，不是使用者发的消息】\n\n刚才那次自我重启已经完成。';
const m = mod.makeWakeMessage(text);

console.log('\n=== 产出的消息对象 ===');
console.log(JSON.stringify(m, null, 2));
console.log('');

// ── ★★ 最要紧的一条：是对象，不是字符串 ★★
//    当年就是喂了字符串才炸的（账本里存进"没有 id、没有 content 的货"）。
check('★★ 产出的是对象，不是字符串（当年事故的根因）',
  typeof m === 'object' && m !== null && typeof m !== 'string',
  `typeof = ${typeof m}`);

// ── id：必须有、必须唯一 ──
//    inbox 的去重检查就是拿 id 做的；id 缺失会让"两个没 id 的货"互相撞成重复。
check('有非空字符串 id', typeof m.id === 'string' && m.id.length > 0, String(m.id));
check('id 是 UUID 形状（与官方 createUserMessage 的 randomUUID 一致）',
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(String(m.id)), String(m.id));
const m2 = mod.makeWakeMessage(text);
check('★ 两次调用 id 不同（否则第二条会被判"重复"而拒收或撞车）', m.id !== m2.id);

// ── role / content：消息体的基本形状 ──
check("role 是 'user'（用户角色消息这一档；注意这和\"谁说的\"是两件事）", m.role === 'user', String(m.role));
check('content 是非空数组', Array.isArray(m.content) && m.content.length >= 1,
  Array.isArray(m.content) ? `长度 ${m.content.length}` : `实际是 ${typeof m.content}`);
check("content[0] 是 { type:'text', text } 文本块",
  m.content?.[0]?.type === 'text' && typeof m.content?.[0]?.text === 'string');
check('文本原样带回（没有截断/转义问题）', m.content?.[0]?.text === text);

// ── source：我们自己的戳，且**绝不是 user** ──
//    DSH 用 source.kind === 'user' 判"这句话是不是人说的"（如 goal 的 complete 要人类输入才放行）。
//    写成 user = 冒充使用者、继承人类授权 —— 那是必须避免的。
check('★ 有 source 对象', typeof m.source === 'object' && m.source !== null);
check("★★ source.kind 是我们自己的 'self-restart'，**不是 'user'**",
  m.source?.kind === 'self-restart', String(m.source?.kind));
check('★ source.kind 明确不等于 user（不冒充使用者、不继承人类授权）', m.source?.kind !== 'user');
// ⚠️ 也不许叫 'plugin'：那是会话格式 V3 的旧字段名，V3→V4 迁移器会把它读成
//    "这是老式插件来源"并改写 kind。新消息不该占用那个退休的名字。
check("★ 有 producer 字段标出生产方（且不叫 'plugin'，那是 V3 旧名字）",
  m.source?.producer === 'dsh-self-restart' && !('plugin' in (m.source ?? {})),
  `producer=${m.source?.producer}`);
check('source 里带了实现版本号（醒来时自检有东西可对）', Number.isInteger(m.source?.impl), String(m.source?.impl));

// ── 冻结：投进去之后谁都不能改 ──
//    官方 createUserMessage 会 deepFreeze。照着做，免得后面某处无意改一下，
//    让"账本里存的和当时投的不一样"。
check('★ 消息被冻结（不能改）', Object.isFrozen(m));
check('★ 内容块也被冻结（深冻结，不是只冻外层）', Object.isFrozen(m.content?.[0]));
check('★ 冻结是真的生效（改它会失败）', (() => {
  try { m.content[0].text = 'tampered'; return m.content[0].text !== 'tampered'; }
  catch { return true; }   // 严格模式下抛错也算"改不动"
})());

// ── 边界：空文本 / 非字符串输入不许产出"空内容的消息" ──
//    会话准入会拒空内容；与其投一条被拒的消息，不如产出时就可预期。
check('空文本也能产出结构合法的对象（有 id/role/content）',
  (() => {
    const e = mod.makeWakeMessage('');
    return typeof e.id === 'string' && e.role === 'user' && Array.isArray(e.content) && e.content.length >= 1;
  })());
check('undefined 输入不会产出畸形的 content（text 至少是空串）',
  (() => {
    const e = mod.makeWakeMessage(undefined);
    return e.content?.[0]?.type === 'text' && typeof e.content?.[0]?.text === 'string';
  })());

// ── 形状清单：和"当年那种货"逐项对照 ──
console.log('\n=== 与当年事故的对照 ===');
const shape = {
  '是对象（不是字符串）': typeof m === 'object' && typeof m !== 'string',
  '有 id': typeof m.id === 'string' && m.id.length > 0,
  '有 role': typeof m.role === 'string' && m.role.length > 0,
  'content 是数组': Array.isArray(m.content),
  'content 非空': Array.isArray(m.content) && m.content.length > 0,
  '有 source.kind': typeof m.source?.kind === 'string' && m.source.kind.length > 0,
  'kind 不是 user': m.source?.kind !== 'user',
  'kind 不是 plugin（V3 旧名，迁移器会改写）': m.source?.kind !== 'plugin'
};
for (const [k, v] of Object.entries(shape)) console.log(`  ${v ? '✅' : '❌'} ${k}`);
check('★ 形状清单全绿（这七项全中，投进去才不会污染会话账本）',
  Object.values(shape).every(Boolean));

console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
process.exit(fail ? 1 : 0);
