/**
 * test-settings-bridge.mjs —— 「网页上那个设置页」的后端通道测试
 *
 * 2026-11-10 建立。配套决策：docs\decisions-restart-nudge.md §7
 *
 * 【为什么必须单测这条通道】
 *  它是**唯一一条能从网页改插件配置的路**。写错一个地方就是安全漏洞，
 *  而不是"功能不好用"：
 *    ① 不校验来源 → 反代出去之后，整张网都能点那个"保存"；
 *    ② 允许 GET 写 → 浏览器预取/缓存会把配置改掉；
 *    ③ 整份合并（`{...config, ...body}`）→ 调用方能塞 dshExe 这种"指向任意
 *      可执行文件"的字段，下次重启就执行它；
 *    ④ 不校验类型 → 把 `notifyRepeat` 塞成字符串 "false"（真值），行为悄悄反过来。
 *  这四条全都**不会报错**，只会让状态慢慢变错。所以逐条钉住。
 *
 * 【怎么跑】
 *   node test\test-settings-bridge.mjs
 *   node test\test-settings-bridge.mjs --break   （改坏自检）
 */

import { readFileSync, readdirSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(dirname(HERE), 'lib', 'index.js');
const CLIENT = join(dirname(HERE), 'lib', 'client.js');
const PKG = join(dirname(HERE), 'package.json');
const BREAK = process.argv.includes('--break');

let pass = 0;
let fail = 0;
const failed = [];

function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (ok) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; failed.push(name); console.log(`  ❌ ${name}  得到 ${JSON.stringify(got)}  期望 ${JSON.stringify(want)}`); }
}
function checkTrue(name, got) {
  if (got) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; failed.push(name); console.log(`  ❌ ${name}  期望为真，实际 ${JSON.stringify(got)}`); }
}

const src = readFileSync(LIB, 'utf8');
const clientSrc = readFileSync(CLIENT, 'utf8');
const pkg = JSON.parse(readFileSync(PKG, 'utf8'));

function extract(startNeedle, endNeedle) {
  const s = src.indexOf(startNeedle);
  if (s < 0) throw new Error(`找不到起点：${startNeedle}`);
  const e = src.indexOf(endNeedle, s);
  if (e < 0) throw new Error(`找不到终点：${endNeedle}`);
  return src.slice(s, e);
}

// 抠出「白名单 + 来源判定 + 校验 + 修改」这几段纯逻辑（不启动插件）。
// ⚠️ 终点锚在 `if (webServer &&` 之前 —— 那之后是真正的路由注册（副作用），不要。
//    第一版锚在 readBodyJson 上，结果 describeSettings/mutateSettings 全被截在外面，
//    测试直接 ReferenceError。锚点跟着实现顺序走，改了顺序要同步改这里。
let frag = extract('const EDITABLE_SETTINGS = {', 'if (webServer && typeof webServer.register');

if (BREAK) {
  // 改坏点①：把"整批校验失败就不生效"改成"能过的就过"（预期 ③ 组会红）
  const BROKEN = "if (rejected.length > 0) {";
  if (!frag.includes(BROKEN)) throw new Error('改坏自检的替换串对不上源码');
  frag = frag.replace(BROKEN, 'if (false) {');
  console.log('\n*** 改坏自检：校验失败也放行（预期 ③ 组会红）***\n');
}

const mod = new Function(
  'now', 'config', 'log', 'readReported', 'writeJson', 'reportedPath', 'stateDir', 'planPath', 'readJson',
  'IMPL_VERSION',
  frag + '\nreturn { EDITABLE_SETTINGS, isLocalRequest, mutateSettings, describeSettings };'
)(
  Date.now, {}, () => {}, () => ({}), () => true, '/tmp/reported.json', '/tmp/state', '/tmp/plan.json', () => null,
  9999,
);
const { EDITABLE_SETTINGS, isLocalRequest, mutateSettings } = mod;

console.log('\n=== ① 白名单：危险的键不许从网页改 ===');
{
  // ★ 这条最重要：dshExe 指向任意可执行文件，让它能被网页改 = 远程执行
  check('dshExe 不在白名单里', Boolean(EDITABLE_SETTINGS.dshExe), false);
  check('stateDir 不在白名单里', Boolean(EDITABLE_SETTINGS.stateDir), false);
  check('port 不在白名单里', Boolean(EDITABLE_SETTINGS.port), false);
  check('noticeCommand 不在白名单里（它能执行任意命令）', Boolean(EDITABLE_SETTINGS.noticeCommand), false);
  check('resumeHint 不在白名单里', Boolean(EDITABLE_SETTINGS.resumeHint), false);
  check('★ 劝停的两个键在白名单里', [Boolean(EDITABLE_SETTINGS.nudgeEnabled), Boolean(EDITABLE_SETTINGS.nudgeAfterMinutes)], [true, true]);
}

console.log('\n=== ② 来源判定：只认本机 ===');
{
  const mk = (addr) => ({ socket: { remoteAddress: addr } });
  check('127.0.0.1 → 允许', isLocalRequest(mk('127.0.0.1')), true);
  check('::1 → 允许', isLocalRequest(mk('::1')), true);
  check('★ ::ffff:127.0.0.1（IPv4 映射）→ 允许', isLocalRequest(mk('::ffff:127.0.0.1')), true);
  check('★ 192.168.1.5 → 拒绝', isLocalRequest(mk('192.168.1.5')), false);
  check('★ 8.8.8.8 → 拒绝', isLocalRequest(mk('8.8.8.8')), false);
  check('没有 socket → 拒绝（保守）', isLocalRequest({}), false);
  check('null → 拒绝', isLocalRequest(null), false);
  checkTrue('★ 只看 Host 头是不够的（源码里不许有"单凭 host 就放行"）',
    !/req\.headers\.host[^\n]*return true/.test(src));
}

console.log('\n=== ③ 类型与范围校验（错一项整批不生效）===');
{
  {
    const r = mutateSettings({ nudgeAfterMinutes: 5 });
    check('合法数字 → ok', r.ok, true);
    check('返回值带 applied', r.applied, { nudgeAfterMinutes: 5 });
  }
  {
    const r = mutateSettings({ nudgeEnabled: 'yes' });
    check('★ 布尔位塞字符串 → 拒绝', r.ok, false);
  }
  {
    const r = mutateSettings({ nudgeAfterMinutes: -1 });
    check('★ 超出范围（负数）→ 拒绝', r.ok, false);
  }
  {
    const r = mutateSettings({ nudgeAfterMinutes: 99999 });
    check('★ 超出范围（过大）→ 拒绝', r.ok, false);
  }
  {
    const r = mutateSettings({ dshExe: 'C:\\evil.exe' });
    check('★ 不在白名单的键 → 拒绝', r.ok, false);
  }
  {
    // ★ 这一条是"整批"语义的核心：一个坏的不许连累好的，但也不许放过好的
    const r = mutateSettings({ nudgeEnabled: true, dshExe: 'C:\\evil.exe' });
    check('★ 一半合法一半非法 → 整批都不生效', r.ok, false);
    check('★ 而且 applied 里空空如也（不许部分成功）', r.applied, {});
  }
  {
    const r = mutateSettings({});
    check('空对象 → 拒绝（没东西可改）', r.ok, false);
  }
  {
    const r = mutateSettings(null);
    check('null → 拒绝', r.ok, false);
  }
  {
    const r = mutateSettings([1, 2, 3]);
    check('★ 数组 → 拒绝（不是对象）', r.ok, false);
  }
  {
    const r = mutateSettings({ notifyAfterMinutes: '30' });
    check('★ 数字位传字符串 "30" → 接受并转成数字（网页 input 会给字符串）',
      [r.ok, r.applied?.notifyAfterMinutes], [true, 30]);
  }
}

console.log('\n=== ④ 每个可调项都声明了 [类型, 范围, 中文名] ===');
{
  const bad = [];
  for (const [k, spec] of Object.entries(EDITABLE_SETTINGS)) {
    if (spec.type !== 'boolean' && spec.type !== 'number') bad.push(`${k}: 类型错`);
    if (!spec.label || typeof spec.label !== 'string') bad.push(`${k}: 没中文名`);
    if (spec.type === 'number') {
      if (!Number.isFinite(spec.min) || !Number.isFinite(spec.max)) bad.push(`${k}: 没范围`);
      if (spec.min > spec.max) bad.push(`${k}: 范围反了`);
    }
  }
  check('★ 全部合规（网页上那个表单靠它渲染）', bad, []);
  checkTrue('可调项数量合理（至少 10 项）', Object.keys(EDITABLE_SETTINGS).length >= 10);
}

console.log('\n=== ⑤ 路由本身：方法白名单 + 注册时机 + CSRF ===');
{
  checkTrue('★ 只允许 GET / POST（不许 GET 写、不许 PUT/DELETE）',
    /req\.method === 'GET' \|\| req\.method === 'HEAD'/.test(src) && /req\.method !== 'POST'/.test(src));
  checkTrue('★ 路由路径写死成常量（不拼接用户输入）', /const SETTINGS_ROUTE = '\/api\/dsh-self-restart\/settings'/.test(src));

  // ★★★ 2026-11-10 实测补的：这条是**安全闸**，不是格式挑剔，别当垃圾删掉。
  //   我原来只做"只认本机 IP"，并以为能挡网页 CSRF —— 实测挡不住：
  //   浏览器里任何页面发的请求，remoteAddress 都是 127.0.0.1。
  //   实测用 text/plain 当简单请求 POST，真的把 nudgeAfterMinutes 改成了 5。
  //   现在要求 application/json ⇒ 跨站必须先过 CORS 预检，而本路由不响应 OPTIONS。
  const postBlock = (() => {
    const i = src.indexOf("if (req.method !== 'POST')");
    return i >= 0 ? src.slice(i, i + 1600) : '';
  })();
  checkTrue('★★ 找到了 POST 处理那一段（锚点还在）', postBlock.length > 400);
  checkTrue('★★ POST 必须校验 content-type 是 application/json（CSRF 闸）',
    /req\.headers\?\.\['content-type'\]/.test(postBlock) && /startsWith\('application\/json'\)/.test(postBlock));
  checkTrue('★★ 不合规时回 415 且**不往下走**（有 return）',
    /415[\s\S]{0,200}return;/.test(postBlock));
  checkTrue('★ 注释里写明了"这不是格式挑剔、是 CSRF 防护"（防后人删）',
    /CSRF/.test(postBlock));

  checkTrue('★ 注册在 ctx.effect 里（插件卸载时会摘掉）',
    /ctx\.effect\(\(\) => server\.register\(\{/.test(src));
  // ★★ 2026-11-10 实机踩到的坑，专门钉一条：
  //   第一版把注册写成 `if (webServer && …) { 注册 } else { 记一行日志 }`，
  //   而 apply() 执行那一刻 webServer 还是 null（实测服务晚 21 秒就位）→
  //   **路由从来没注册过**，网页 fetch 拿到 404（鉴权已过、只是路由不存在）。
  //
  //   ⚠️ 这条断言前两版都**不够强**，两次都是"掰坏了照样绿"：
  //      第一版：文件里有没有 `ctx.inject(['webServer']` → 我把 else 改成 `else if (false)` 照样绿（文本还在）；
  //      第二版：截出一段再找同样的文本 → 同一个毛病。
  //      第三版（现在）：**把分支条件本身也钉住** —— `} else {` 必须紧跟 `try { ctx.inject(['webServer']`。
  //      把 else 改掉，正则立刻失配 → 变红。这是"零宽条件"类断言唯一可靠的写法：
  //      不要问"这段代码在不在"，要问"**它是不是真的挂在那个分支上**"。
  const regStart = src.indexOf('const registerSettingsRoute');
  const regEnd = src.indexOf('const survey = (');
  const regBlock = (regStart >= 0 && regEnd > regStart) ? src.slice(regStart, regEnd) : '';
  checkTrue('★ 找到了注册那一段（锚点还在）', regBlock.length > 400);
  checkTrue('★★ 服务晚到时**真的会走到**注入兜底（不是"代码里提过一句"）',
    /\} else \{\s*\n\s*try \{\s*\n\s*ctx\.inject\(\['webServer'\]/.test(regBlock));
  checkTrue('★ 已经有 webServer 时也走同一个注册函数（两条路不许写两遍实现）',
    /if \(webServer\) \{\s*\n\s*registerSettingsRoute\(webServer\);/.test(regBlock));
  checkTrue('★ 响应带 no-store（改配置的接口不许被缓存）', /'cache-control': 'no-store'/.test(src));
}

console.log('\n=== ⑥ 浏览器端半边：接线正确 ===');
{
  check('package.json 有 exports["./client"]', pkg.exports?.['./client'], './lib/client.js');
  check('package.json 声明了 dsh.client.platform', pkg.dsh?.client?.platform, 'web');
  checkTrue('★ client.js 用 __ModuleLoader__ 格式', /window\.__ModuleLoader__\.load\(/.test(clientSrc));
  checkTrue('★ 声明了 inject = ["slots"]（不声明就静默不显示）', /exports\.inject = \['slots'\]/.test(clientSrc));
  checkTrue('★ 挂在 plugins.bundle.config（插件详情页）', /'plugins\.bundle\.config'/.test(clientSrc));
  checkTrue('★ key 是包名本身', /key: 'dsh-self-restart'/.test(clientSrc));
  checkTrue('★ 也挂了 plugins.row.config（老宿主的位置）', /'plugins\.row\.config'/.test(clientSrc));
  checkTrue('★ summary 视图返回字符串（宿主用它显示一行摘要）', /props\.view === 'summary'/.test(clientSrc));
  checkTrue('★ 用的是 --dsw-alias 主题变量，不写死颜色',
    /--dsw-alias-label-primary/.test(clientSrc) && !/background:#fff[^-]/.test(clientSrc));
  checkTrue('★ CSS 只注入一次（靠 data-plugin-css 判重）', /data-plugin-css="dsh-self-restart"/.test(clientSrc));
  checkTrue('★ 请求的是同一条路由（不硬编码别的前缀）', /\/api\/dsh-self-restart\/settings/.test(clientSrc));
  checkTrue('★ 失败时有可见的错误提示（不静默）', /读不到设置/.test(clientSrc) && /sr-msg-err/.test(clientSrc));
}

console.log('\n=== ⑥b 随改随存（2026-11-10：不要手点保存）===');
{
  // 【为什么这条要钉住】
  //
  //   改成自动保存以后，最容易犯的回归不是"不会自动存了"，而是**这套存法有三个坑**，
  //   每一个都不报错、只是"偶尔改动丢了"或"中间值生效了一下"：
  //     ① 请求飞在路上时用户又改了一个 → 成功后一把 setD({}) 会把**后改的那次吞掉**
  //     ② 数字框逐字符 onChange，不 debounce 会先存半截（"10" 先存成 "1"）
  //     ③ 清空重打经过空串，直接存会被服务端拒、弹红字
  //   下面逐条断言它们都在。

  checkTrue('★★ 有自动保存（useEffect 里起定时器调 save）',
    /React\.useEffect\(function \(\) \{[\s\S]{0,600}?setTimeout\(function \(\) \{ save\(\); \}/.test(clientSrc));

  checkTrue('★★ 保存前先拍快照（payload），不是直接发 d',
    /var payload = d;/.test(clientSrc) && /body: JSON\.stringify\(payload\)/.test(clientSrc));

  checkTrue('★★ 成功后只清"没被再改过"的键（不能一把 setD({})）',
    /if \(next\[k\] === payload\[k\]\) delete next\[k\]/.test(clientSrc));

  checkTrue('★★ 数字空串不自动存（正在清空重打，等它打完）',
    /d\[keys\[i\]\] === ''\) return undefined/.test(clientSrc));

  checkTrue('★ 保存中不锁输入框（disabled: isSaving 会丢焦点）',
    !/disabled: isSaving,\s*\n\s*onChange: change/.test(clientSrc));

  checkTrue('★ 手动"保存"按钮已撤，只剩状态文案',
    !/>'保存'/.test(clientSrc) && /已是保存状态/.test(clientSrc));

  checkTrue('★ 存失败时给"重试"按钮（不是只能刷新页面）',
    /'重试'/.test(clientSrc));

  // ★ 2026-11-10 约定：那两个开关**不要了**（「本地就没这个使用条件」）。
  //   而且查明它们从来没接上过 —— 摆着只会让人以为自己调过、以为生效了。
  //   所以这里反过来钉：**界面上不许再出现它们**。
  //   要加回来，先看 client.js 里那段「三处一起改」的说明 —— 少一处就是假开关。
  checkTrue('★★ 那两个假开关已从界面撤掉（不许只剩一半）',
    !/waitForImDirect/.test(clientSrc.replace(/\/\/[^\n]*/g, ''))
    && !/waitForAllSessions/.test(clientSrc.replace(/\/\/[^\n]*/g, '')));

  checkTrue('★★ 也不许留在可调项白名单里（留着 = 设置页会把它渲染出来）',
    !/waitForImDirect/.test(src.replace(/\/\/[^\n]*/g, ''))
    && !/waitForAllSessions/.test(src.replace(/\/\/[^\n]*/g, '')));
}

console.log('\n=== ⑥c ★★ hook 顺序（2026-11-10 设置页白屏的真凶）===');
{
  // 【为什么这条最重要】
  //   2026-11-10 实机反馈「设置那个页面不见了」。真因是：
  //   我新加的自动保存 useEffect 写在了 `if (s.loading) return` **之后** ——
  //   第一次渲染只跑 5 个 hook，加载完跑 6 个，React 抛
  //   `Rendered more hooks than during the previous render`，**整个面板白屏**。
  //
  //   ⚠️ 这种 bug **语法检查、正则搜、甚至"跑一次渲染"都抓不到** ——
  //   必须**跑两次渲染再比 hook 数量**。下面两个断言缺一不可：
  //   ① 便宜的：所有 hook 调用必须出现在第一个提前 return 之前；
  //   ② 真的：真跑两次（loading 一次、加载完一次），比较 hook 次数。

  // ① 静态：Panel 函数里，第一个 `if (s.loading) return` 之后不许再出现 hook
  //   ⚠️ 范围必须**只切 Panel 这一个函数**（到下一个 `      function ` 为止）。
  //      第一版切到文件末尾，把后面 Switch/Row/summary 里的 hook 也扫进来了 → 误报。
  //   ⚠️ 锚点要用**真代码**（`if (s.loading) return React.createElement`），
  //      不能只搜 `if (s.loading)` —— 注释里也写过这几个字，会定位到注释上（第二版就这么误报的）。
  const panelStart = clientSrc.indexOf('function Panel(');
  const nextFn = clientSrc.indexOf('\n      function ', panelStart + 1);
  const panelBody = panelStart >= 0 && nextFn > panelStart
    ? clientSrc.slice(panelStart, nextFn)
    : '';
  const guardIdx = panelBody.indexOf('if (s.loading) return React.createElement');
  checkTrue('★★ 找得到 Panel 函数体与那个提前 return', panelBody.length > 0 && guardIdx > 0);
  checkTrue('★★ 静态：提前 return 之后没有 hook 调用',
    guardIdx > 0 && !/React\.use(State|Effect|Callback|Ref|Memo)\(/.test(panelBody.slice(guardIdx)));

  // ② 真跑两次渲染
  const countHooks = (stateValue) => {
    let calls = 0;
    const seq = [stateValue, {}, false, null];
    let i = 0;
    const FakeReact = {
      createElement: (t, p) => ({ type: t, props: p }),
      useState: (init) => {
        calls += 1;
        const n = i++;
        return [n < seq.length ? seq[n] : (typeof init === 'function' ? init() : init), () => {}];
      },
      useEffect: () => { calls += 1; },
      useCallback: (f) => { calls += 1; return f; },
      useRef: (v) => { calls += 1; return { current: v }; },
      useMemo: (f) => { calls += 1; return f(); },
    };
    let captured = null;
    const fakeWindow = { __ModuleLoader__: { load: (m) => { captured = m; } } };
    new Function('module', 'exports', 'window', 'document', 'require', clientSrc)(
      { exports: {} }, {}, fakeWindow, undefined,
      (n) => { if (n === 'react') return FakeReact; throw new Error('unexpected require: ' + n); },
    );
    const exp = captured.factory((n) => {
      if (n === 'react') return FakeReact;
      throw new Error('unexpected require: ' + n);
    });
    let render = null;
    const slots = {
      inject: (name, cb) => { cb(); },
      register: (spec, fn) => { if (spec.name === 'plugins.bundle.config') render = fn; return () => {}; },
    };
    exp.apply({ slots, get: (n) => (n === 'slots' ? slots : null) });
    if (!render) throw new Error('没注册 plugins.bundle.config');
    const el = render({ view: 'config' });
    i = 0;
    calls = 0;
    el.type(null);      // 真跑组件函数
    return calls;
  };

  const loadedState = {
    loading: false,
    error: '',
    data: {
      values: { nudgeEnabled: true, notifyRepeat: false },
      editable: { nudgeEnabled: { type: 'boolean', label: 'A', hint: 'a' } },
      pendingPlanId: '',
      notice: { configured: false, enabled: false, armed: false },
    },
  };

  let nLoading = -1;
  let nLoaded = -1;
  let err = '';
  try {
    nLoading = countHooks({ loading: true, error: '', data: null });
    nLoaded = countHooks(loadedState);
  } catch (e) {
    err = String(e && e.message ? e.message : e);
  }

  checkTrue('★★ 两次渲染都跑得通（组件没抛错）', err === '', err);
  check('★★★ 加载中与加载完的 hook 数量必须相等（不相等 = 白屏）', nLoaded, nLoading);
}

console.log('\n=== ⑦ 前后端路由必须一致 ===');
{
  const hostRoute = /const SETTINGS_ROUTE = '([^']+)'/.exec(src)?.[1];
  const clientRoute = /var ROUTE = '([^']+)'/.exec(clientSrc)?.[1];
  check('★ 两边写的是同一个路径', hostRoute, clientRoute);
  checkTrue('两边都不为空', Boolean(hostRoute) && Boolean(clientRoute));
}

console.log('\n=== ⑧ ★★ 双钥匙：配了命令也不许自己跑 ===');
{
  // 【需求 2026-11-10】「设置选项里要有一个配置，就是命令的这个选项，
  //   它可以默认是关掉的，手动开启才可以去执行这个配置好的指令」
  //
  // 【为什么这是一组而不是一条】
  //   这个设计有**两个独立的执行点**：插件侧的 notifyByHook（DSH 活着时）
  //   和助手侧的 Invoke-NoticeHook（助手脱离后）。只在其中一处检查 = 等于没加锁，
  //   因为另一处照样会执行。所以**两处都要断言**。
  const helperSrc = readFileSync(join(dirname(HERE), 'bin', 'dsh-self-restart.ps1'), 'utf8');

  // ① 配置项本身：默认必须是关的
  checkTrue('★ 1) 有 noticeEnabled 配置项', /noticeEnabled: z\.boolean\(\)\.default\(false\)/.test(src));
  checkTrue('★★ 配置项默认是 false（安全方向的默认值必须是"不执行"）',
    /noticeEnabled: z\.boolean\(\)\.default\(false\)/.test(src));

  // ② 插件侧执行点
  const hookBlock = (() => {
    const i = src.indexOf('const notifyByHook');
    return i >= 0 ? src.slice(i, i + 900) : '';
  })();
  checkTrue('★ 3) 找到了插件侧执行点（notifyByHook）', hookBlock.length > 300);
  checkTrue('★★ 插件侧：命令为空 → 不执行', /noticeCommand[\s\S]{0,80}return false;/.test(hookBlock));
  checkTrue('★★ 插件侧：开关不是 true → 也不执行（第二把钥匙）',
    /config\.noticeEnabled !== true[\s\S]{0,40}return false;/.test(hookBlock));

  // ③ 助手侧执行点（这才是真正 spawn 进程的地方）
  const invBlock = (() => {
    const i = helperSrc.indexOf('function Invoke-NoticeHook');
    return i >= 0 ? helperSrc.slice(i, i + 1400) : '';
  })();
  checkTrue('★ 5) 找到了助手侧执行点（Invoke-NoticeHook）', invBlock.length > 500);
  checkTrue('★★ 助手侧：命令为空 → 不执行', /IsNullOrWhiteSpace\(\$cmd\)[\s\S]{0,60}return \$false/.test(invBlock));
  checkTrue('★★★ 助手侧：开关关着 → 也不执行（漏了这一行 = 助手照样会跑那条命令）',
    /if \(-not \$noticeEnabled\) \{ return \$false \}/.test(invBlock));

  // ④ 计划文件里必须把这个开关传下去（否则助手那侧永远拿到 false/undefined）
  checkTrue('★★ 计划文件里写了 noticeEnabled（不传 = 助手侧双钥匙失效）',
    /noticeEnabled: config\.noticeEnabled === true/.test(src));
  checkTrue('★★ 助手解析计划时默认取 false（老计划里没这个字段 → 不执行）',
    /if \(\$null -ne \$plan\.noticeEnabled\) \{ \[bool\]\$plan\.noticeEnabled \} else \{ \$false \}/.test(helperSrc));

  // ⑤ 命令本身仍然不许从网页写（第一把钥匙只从配置文件来）
  check('★★ noticeCommand 仍然不在白名单里', Boolean(EDITABLE_SETTINGS.noticeCommand), false);
  check('★ 但"开关"在白名单里（用户就是要在页面上开它）',
    EDITABLE_SETTINGS.noticeEnabled?.type, 'boolean');
}

console.log('\n=== ⑨ ★★★ 所有 .ps1 必须带 UTF-8 BOM（2026-11-10 因此翻过车）===');
{
  // 【真事：这次差点把重启功能整个弄坏】
  //   我为了验"拆掉双钥匙会不会变红"，用
  //       [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
  //   把助手脚本「还原」回去 —— 那个 $false 就是「**不要 BOM**」。
  //   于是文件变成无 BOM 的 UTF-8，而 **PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码**
  //   → 中文全变乱码 → 引号配对失败 → 脚本**解析错误、一启动就退出**。
  //
  //   表现极有迷惑性：`restart_self` 返回「WMI 返回 0 但助手没认领计划」——
  //   看起来像进程创建失败，其实是**它起来了、然后立刻死在语法错误上**。
  //   连续两次失败我才去手动跑脚本，一眼看到满屏乱码。
  //
  //   更迷惑的是：我用 `PSParser::Tokenize` 校验过「语法 OK」——
  //   那一次是**在文件已经坏掉之后**用错方式读的（读成字符串又按 UTF8 解回来），
  //   正好自洽。⇒ 校验编码**必须看字节**，不能看"读出来的文本对不对"。
  // ⚠️ 路径要算对：本文件在 test/ 里，HERE = <plugin>/test，
  //    dirname(HERE) = <plugin>（插件根）才有 bin/；ps1 全在两个地方：
  //      <plugin>/bin/*.ps1 和 <plugin>/test/*.ps1
  const pluginRoot = dirname(HERE);
  const testDir = HERE;
  const binDir = join(pluginRoot, 'bin');
  const collect = (dir) => readdirSync(dir).filter((f) => f.endsWith('.ps1'))
    .map((f) => ({ name: f, path: join(dir, f) }));
  const all = [...collect(testDir), ...collect(binDir)];
  const noBom = [];
  for (const f of all) {
    const b = readFileSync(f.path);
    if (!(b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf)) noBom.push(f.name);
  }
  checkTrue(`★★ 所有 .ps1 都有 BOM（共检查 ${all.length} 个）`, all.length >= 30 && noBom.length === 0);
  if (noBom.length > 0) console.log('     缺 BOM 的：' + noBom.join(', '));
  checkTrue('★★ 助手脚本本身有 BOM（它坏了 = 重启功能整个不能用）',
    readFileSync(join(binDir, 'dsh-self-restart.ps1'))[0] === 0xef);
}

console.log('');
if (BREAK) {
  if (fail > 0) {
    console.log(`改坏自测汇总：${fail} 条断言变红（说明这些断言真的能抓到问题）`);
    process.exit(0);
  }
  console.log('❌ 改坏自检失败：掰坏了居然全绿');
  process.exit(1);
} else {
  console.log(`===== 汇总：${pass}/${pass + fail} 通过 =====`);
  if (fail > 0) { console.log('失败项：\n  - ' + failed.join('\n  - ')); process.exit(1); }
  process.exit(0);
}
