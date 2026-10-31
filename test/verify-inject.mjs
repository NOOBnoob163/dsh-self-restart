// 验证 inject 修复：确认插件模块导出的 inject 声明里有 'tools'。
//
// 为什么单独测这个：Cordis 的 inject 是**静态导出**，在插件加载时读一次。
// 上一版写成 `export const inject = []`，结果实机上访问 ctx.tools 抛
// "cannot get property tools without inject" —— 工具静默没注册上，
// 而我的假 ctx 自测完全测不出来（假 ctx 不做权限检查）。
//
// 用法：node verify-inject.mjs
import { pathToFileURL, fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync } from 'node:fs';

// ★ 2026-10-12 脱敏：不写死安装路径。
//
//   ⚠️ 但**必须优先用"使用区"那份**（第一版改成开发区、被测试抓出来）：
//   插件 import 了 `@deepseek-ai/schemastery`，这个依赖装在
//   **DSH 的 profiles/desktop/node_modules** 下（不在插件包里）。
//   从开发区加载的话，Node 顺着 lib/ 往上找不到 node_modules → import 直接失败。
const HOME_DSH = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh');
const INSTALLED = join(HOME_DSH, 'profiles', 'desktop', 'plugins', 'dsh-self-restart', 'lib', 'index.js');
const LOCAL = join(fileURLToPath(new URL('..', import.meta.url)), 'lib', 'index.js');
const PLUGIN = existsSync(INSTALLED) ? INSTALLED : LOCAL;

let failed = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failed++;
};

const mod = await import(pathToFileURL(PLUGIN).href);

// ① inject 必须是数组且包含 tools
const inject = mod.inject;
check('导出了 inject', Array.isArray(inject), JSON.stringify(inject));
check("inject 里包含 'tools'（否则 ctx.tools 会抛）", Array.isArray(inject) && inject.includes('tools'), JSON.stringify(inject));

// ② 不该把 jobs / agents 写进静态 inject —— 它们用动态 ctx.inject 拿。
//    写进去会让插件在服务缺失时整个不激活（更脆），所以故意不写。
check("inject 里没有 'jobs'（用动态注入更稳）", Array.isArray(inject) && !inject.includes('jobs'), JSON.stringify(inject));
check("inject 里没有 'agents'（用动态注入更稳）", Array.isArray(inject) && !inject.includes('agents'), JSON.stringify(inject));

// ③ 名字与导出齐全
check('导出 name = dsh-self-restart', mod.name === 'dsh-self-restart', String(mod.name));
check('导出 apply 是函数', typeof mod.apply === 'function');
check('导出 Config', typeof mod.Config === 'function');

// ④ 实机用的 ctx：只提供 inject 里声明过的服务，模拟 Cordis 的权限检查。
//    这样如果 inject 漏了 tools，这里就会**真的抛**，而不是假通过。
//
// ★★ 2026-10-13 重要修正：**必须把 stateDir 指到临时目录** ★★
//    下面会真调 `mod.apply()`，而 apply() 第一件事就是 writeState() ——
//    用默认配置跑，它就**以新代码往使用者真实的 state.json 写 impl=4**。
//    后果极隐蔽：紧接着跑的 verify-roots.mjs 读到 4 → 报"新代码在跑"（**假通过**），
//    而真宿主里跑的还是旧代码（改 lib/index.js 必须重启宿主才进内存）。
//    实测佐证：跑批到 verify-roots 时它是绿的，可真 state.json 的 impl 是 3。
//    （同一处坑我在 selftest.mjs 也修了 —— 这两套都会调 apply()。）
const { join: joinPath } = await import('node:path');
const { rmSync } = await import('node:fs');
const TMP_STATE = joinPath(process.env.TEMP ?? process.env.TMP ?? '.', `dsh-sr-inject-${process.pid}`);

const registered = [];
let toolsAccessWithoutInjectThrew = false;

const strictCtx = {
  logger: { info: () => {}, warn: () => {}, error: () => {} },
  inject: () => {},
  effect: () => {},
  get tools() {
    // 模拟 Cordis：没在静态 inject 里声明就不给
    if (!(Array.isArray(mod.inject) && mod.inject.includes('tools'))) {
      toolsAccessWithoutInjectThrew = true;
      throw new Error('cannot get property "tools" without inject');
    }
    return {
      register(definition) { registered.push(definition); return () => {}; }
    };
  }
};

try {
  mod.apply(strictCtx, new mod.Config({ stateDir: TMP_STATE }));
  check('在"严格 ctx"下 apply 成功（工具真的注册上了）', registered.length === 2, `注册了 ${registered.length} 个`);
} catch (error) {
  check('在"严格 ctx"下 apply 成功（工具真的注册上了）', false, String(error?.message ?? error));
}
check('没有触发 "without inject" 错误', !toolsAccessWithoutInjectThrew);

// ★ 确认这一套**没碰**使用者的真实状态目录（不然它会给 verify-roots 喂假答案，见 ④ 的说明）
const { existsSync: existsSync2 } = await import('node:fs');
const { homedir: homedir2 } = await import('node:os');
const HOME_DSH_2 = (process.env.DSH_HOME ?? '').trim() || joinPath(homedir2(), '.dsh');
check('★ 临时状态目录里写出了 state.json（说明真的是往那儿写的）',
  existsSync2(joinPath(TMP_STATE, 'state.json')), TMP_STATE);

// 收尾：清掉临时目录
try { rmSync(TMP_STATE, { recursive: true, force: true }); } catch { /* 清不掉不影响结论 */ }

console.log(failed === 0 ? '\n===== inject 验证全部通过 =====' : `\n===== ${failed} 项失败 =====`);
process.exit(failed === 0 ? 0 : 1);
