// 校验两份 YAML 的结构没被改坏：
//   ① 本插件自带的 bundle patch（cordis.patch.yml）—— 这是"能不能启用"的关键
//   ② 用户 profile 的 cordis.patch.yml —— 只查结构（能读、无 Tab、条目在），
//      **不再查"self-restart 段还在"**：2026-10-12 起那段手写 insert 已迁进
//      ① 这份 bundle patch，profile 里不该再有（别的用户可能留 config 覆盖，所以只验结构）。
// 只做**结构性**检查（不引入 YAML 库）：缩进用空格、条目形态对、关键行在位。
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

let pass = 0;
let fail = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
  if (ok) pass += 1; else fail += 1;
};

// ── ① 本插件的 bundle patch（必须存在、结构正确）───────────────────────────
// ⚠️ 这是 1.0.0 发布前的关键检查：缺 cordis.patch.yml 或 id 写错，
//    表现是"插件装上了但不会启用"，而且**没有任何报错**。
const bpText = readFileSync(new URL('../cordis.patch.yml', import.meta.url), 'utf8');
const bpLines = bpText.split(/\r?\n/);
check('bundle 的 cordis.patch.yml 能读到', bpLines.length > 0);
check('bundle patch 没有 Tab 缩进', !bpLines.some((l) => /^\t/.test(l)));
check('bundle patch 有 - insert: 条目', /^- insert:/m.test(bpText));
check('bundle patch 的 id 是 self-restart', /^\s*-\s*id:\s*self-restart\s*$/m.test(bpText));
check('bundle patch 的 name 指向 dsh-self-restart', /name:\s*'dsh-self-restart'/.test(bpText));

// ── ② 本包的 package.json 里 bundle 声明在位 ───────────────────────────────
const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
check('package.json 声明了 dsh.bundle.patch', typeof pkg.dsh?.bundle?.patch === 'string');
check('dsh.bundle.patch 指向 cordis.patch.yml', /cordis\.patch\.yml$/.test(String(pkg.dsh?.bundle?.patch ?? '')));

// ── ③ 用户的 profile 补丁（能读到就查结构，读不到跳过）─────────────────────
// ⚠️ 它不属于本插件仓库 —— 别的机器上可能没有，缺失时**跳过**而不是失败。
const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const p = join(HOME_DSH, 'profiles', 'desktop', 'cordis.patch.yml');

if (!existsSync(p)) {
  console.log('（跳过 ③：装配补丁不在，它不是本插件的一部分）', p);
} else {
  const text = readFileSync(p, 'utf8');
  const lines = text.split(/\r?\n/);
  const tabLines = lines.map((l) => l).filter((l) => /^\t/.test(l));
  const topEntries = lines.filter((l) => /^- (id:|insert:)/.test(l));

  console.log('文件:', p);
  console.log('总行数:', lines.length, '/ 顶层条目:', topEntries.length,
    '/ 含 Tab 的行:', tabLines.length, tabLines.length ? `(首个 ${tabLines[0]})` : '');

  check('装配补丁能读到', lines.length > 0);
  check('装配补丁没有 Tab 缩进（YAML 禁用）', tabLines.length === 0);
  check('装配补丁顶层条目还在', topEntries.length > 0);

  // 过时说法不该再出现在这个文件里
  const stale = ['弹框', '必须先问过用户', '不许自行发起'].filter((s) => text.includes(s));
  check('没有过时说法残留', stale.length === 0, stale.length ? stale.join('、') : '');
}

// ⚠️ 最后这一行要带"汇总"，好让 run-all-tests.ps1 认出结果（它按"汇总"抓）
console.log(`\n===== 汇总：${pass}/${pass + fail} 通过 =====`);
process.exit(fail === 0 ? 0 : 1);
