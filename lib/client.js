/**
 * dsh-self-restart — Browser half（浏览器端半边）
 *
 * 在「插件 → 已安装 → self-restart」详情页里渲染一块配置面板。
 *
 * ── 它为什么存在 ────────────────────────────────────────────────────────────
 *   宿主的插件详情页调不了这个插件的设置，所以这一半必须自己写。
 *   而宿主**不会**自动把插件的 config schema 渲染成表单（实测那个页面点不了、
 *   调不了），所以这一半必须自己写。
 *
 * ── 数据从哪来 ──────────────────────────────────────────────────────────────
 *   走宿主那侧自建的 `/api/dsh-self-restart/settings`：
 *     GET  → { ok, impl, editable, values, ... }
 *     POST → { ok, applied, values }（整批校验，有一项不合法就整批不生效）
 *
 *   ⚠️ 为什么不用宿主的 `form.state` / `form.mutate`：那要求把配置项声明成
 *      宿主认识的形状；本插件 20 多项且带"0 = 关掉"这类语义，自建路由更直白
 *      （dsh-free-search 也是这么做的，可以对照它的 lib/client.js）。
 *
 * ── 视觉 ────────────────────────────────────────────────────────────────────
 *   全部走 `--dsw-alias-*` 主题变量，**不自己配色** —— 深浅两套主题下都不用改代码。
 *   （dsh-open-obsidian 的第一版自己写死颜色，深色模式白底白字看不见，改过一轮。）
 */
window.__ModuleLoader__.load({
  id: 'dsh-self-restart',
  factory: (require) => {
    try {
      var module = { exports: {} };
      var exports = module.exports;
      var React = require('react');

      var ROUTE = '/api/dsh-self-restart/settings';

      // ── 样式：只注入一次 ───────────────────────────────────────────────────
      if (typeof document !== 'undefined' && document.querySelector('style[data-plugin-css="dsh-self-restart"]') === null) {
        var style = document.createElement('style');
        style.dataset.plugin = 'dsh-self-restart';
        style.dataset.pluginCss = 'dsh-self-restart';
        style.textContent = [
          '.sr-card{display:flex;flex-direction:column;gap:14px;color:var(--dsw-alias-label-primary);font-size:13px;line-height:1.6}',
          '.sr-head{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
          '.sr-title{font-weight:600;font-size:14px}',
          '.sr-sub{color:var(--dsw-alias-label-secondary);font-size:12px}',
          '.sr-pill{display:inline-flex;align-items:center;gap:5px;padding:2px 9px;border-radius:999px;font-size:11.5px;border:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.3))}',
          '.sr-pill-ok{color:var(--dsw-alias-label-primary)}',
          '.sr-pill-warn{color:var(--dsw-alias-label-secondary)}',
          '.sr-dot{width:6px;height:6px;border-radius:50%;background:currentColor;opacity:.75}',
          '.sr-group{display:flex;flex-direction:column;gap:2px;border:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.22));border-radius:10px;overflow:hidden}',
          '.sr-grouphead{padding:8px 14px;font-weight:600;font-size:12.5px;background:var(--dsw-alias-bg-secondary,rgba(128,128,128,.06));border-bottom:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.18))}',
          '.sr-row{display:flex;align-items:flex-start;gap:14px;padding:11px 14px;border-top:1px solid var(--dsw-alias-border-tertiary,rgba(128,128,128,.1))}',
          '.sr-row:first-of-type{border-top:0}',
          '.sr-rowbody{flex:1 1 auto;min-width:0}',
          '.sr-label{font-size:13px}',
          '.sr-hint{color:var(--dsw-alias-label-secondary);font-size:11.5px;margin-top:2px}',
          '.sr-control{flex:0 0 auto;display:flex;align-items:center;gap:8px;padding-top:1px}',
          '.sr-input{width:88px;padding:4px 8px;font:inherit;font-size:12.5px;border-radius:7px;border:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.3));background:var(--dsw-alias-bg-primary,transparent);color:inherit;text-align:right}',
          '.sr-input:focus{outline:2px solid var(--dsw-alias-link,#4176e6);outline-offset:-1px}',
          '.sr-unit{color:var(--dsw-alias-label-secondary);font-size:11.5px;min-width:2.5em}',
          '.sr-switch{position:relative;width:38px;height:22px;border-radius:999px;border:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.35));background:transparent;cursor:pointer;padding:0;transition:background 140ms}',
          '.sr-switch[data-on="1"]{background:var(--dsw-alias-link,#4176e6);border-color:transparent}',
          '.sr-knob{position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;background:var(--dsw-alias-bg-primary,#fff);transition:transform 140ms;box-shadow:0 1px 2px rgba(0,0,0,.25)}',
          '.sr-switch[data-on="1"] .sr-knob{transform:translateX(16px)}',
          '.sr-foot{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
          '.sr-btn{padding:5px 14px;font:inherit;font-size:12.5px;border-radius:8px;cursor:pointer;border:1px solid var(--dsw-alias-border-secondary,rgba(128,128,128,.35));background:transparent;color:inherit}',
          '.sr-btn:hover:not(:disabled){background:var(--dsw-alias-bg-secondary,rgba(128,128,128,.08))}',
          '.sr-btn:disabled{opacity:.42;cursor:default}',
          '.sr-btn-main{border-color:transparent;background:var(--dsw-alias-link,#4176e6);color:#fff}',
          '.sr-btn-main:hover:not(:disabled){filter:brightness(1.08);background:var(--dsw-alias-link,#4176e6)}',
          '.sr-msg{font-size:12px}',
          '.sr-msg-ok{color:var(--dsw-alias-label-primary)}',
          '.sr-msg-err{color:var(--dsw-alias-danger,#d33)}',
          '.sr-loading{color:var(--dsw-alias-label-secondary);font-size:12.5px;padding:6px 0}',
        ].join('\n');
        document.head.appendChild(style);
      }

      // ── 分组：把 13 个可调项按"什么时候用得上"排，不按字母顺序 ─────────────
      var GROUPS = [
        {
          title: '排队与劝停',
          hint: '重启在等别人时怎么办',
          keys: ['nudgeEnabled', 'nudgeAfterMinutes', 'maxWaitMinutes'],
        },
        {
          title: '唤醒',
          hint: '重启完成后把会话叫回来',
          keys: ['wakeMessage', 'wakeDelaySeconds'],
        },
        {
          title: '提醒',
          hint: '排太久了告诉你一声',
          keys: ['notifyAfterMinutes', 'notifyRepeat', 'notifyRepeatMinutes'],
        },
        {
          title: '何时算"空闲"',
          hint: '这几个决定它什么时候敢动手，改小会更急、改大会更稳',
          keys: ['idleSeconds', 'othersWindowSeconds', 'confirmSeconds'],
        },
        // ★ 2026-11-10 删掉一整组：「等谁空了才动手」（原来挂 waitForImDirect / waitForAllSessions）。
        //
// 【为什么删】本地部署没有「只等某类会话」这种使用场景，留着只会误导。
        //   查代码还发现它们**从来没接上**：写进计划文件了，但助手脚本读的 33 个字段里
        //   根本没有它们 —— 拨哪个都一样，实际行为永远是"本地窗口 + QQ私聊 + 群聊全都等"。
        //   摆两个不起作用的开关，比不摆更糟（会让人以为自己调过、以为生效了）。
        //
        // 【以后要加回来，别只加界面】
        //   需要三处一起改才真的生效，少一处就是"看着做了、其实没通"：
        //     ① 插件写 state.json 时，给每个 runningSession 带上它的 source（群/私聊/本地）
        //     ② 助手脚本判"别人忙"那一段，按 source 过滤（②-a 插件清单 / ②-b 扫盘 两条路都要）
        //     ③ 界面开关 + 计划文件透传
        //   ① 现在是缺的 —— `runningSessions` 只有 ID，没有 source，所以想做也做不了。
      ];

      var UNITS = {
        nudgeAfterMinutes: '分钟',
        maxWaitMinutes: '分钟',
        wakeDelaySeconds: '秒',
        notifyAfterMinutes: '分钟',
        notifyRepeatMinutes: '分钟',
        idleSeconds: '秒',
        othersWindowSeconds: '秒',
        confirmSeconds: '秒',
      };

      var ZERO_MEANS = {
        nudgeAfterMinutes: '0 = 关掉这项',
        maxWaitMinutes: '0 = 一直等',
        notifyAfterMinutes: '0 = 不提醒',
        confirmSeconds: '0 = 跳过确认窗',
      };

      function Switch(props) {
        return React.createElement(
          'button',
          {
            type: 'button',
            className: 'sr-switch',
            'data-on': props.value ? '1' : '0',
            role: 'switch',
            'aria-checked': props.value ? 'true' : 'false',
            'aria-label': props.label,
            disabled: props.disabled,
            onClick: function () { props.onChange(!props.value); },
          },
          React.createElement('span', { className: 'sr-knob' })
        );
      }

      function Row(props) {
        var spec = props.spec;
        var isBool = spec.type === 'boolean';
        var unit = UNITS[props.name] || '';
        var zero = ZERO_MEANS[props.name] || '';
        var hint = [props.hint, zero].filter(Boolean).join(' · ');
        return React.createElement(
          'div',
          { className: 'sr-row' },
          React.createElement(
            'div',
            { className: 'sr-rowbody' },
            React.createElement('div', { className: 'sr-label' }, spec.label),
            hint ? React.createElement('div', { className: 'sr-hint' }, hint) : null
          ),
          React.createElement(
            'div',
            { className: 'sr-control' },
            isBool
              ? React.createElement(Switch, {
                  value: Boolean(props.value),
                  label: spec.label,
                  disabled: props.disabled,
                  onChange: function (v) { props.onChange(props.name, v); },
                })
              : React.createElement('input', {
                  type: 'number',
                  className: 'sr-input',
                  value: props.value === undefined || props.value === null ? '' : String(props.value),
                  min: spec.min,
                  max: spec.max,
                  disabled: props.disabled,
                  onChange: function (e) {
                    var raw = e.target.value;
                    props.onChange(props.name, raw === '' ? '' : Number(raw));
                  },
                }),
            !isBool && unit ? React.createElement('span', { className: 'sr-unit' }, unit) : null
          )
        );
      }

      function Panel() {
        var state = React.useState({ loading: true, error: '', data: null });
        var s = state[0];
        var setS = state[1];
        var draft = React.useState({});
        var d = draft[0];
        var setD = draft[1];
        var saving = React.useState(false);
        var isSaving = saving[0];
        var setIsSaving = saving[1];
        var msg = React.useState(null);
        var m = msg[0];
        var setM = msg[1];

        var load = React.useCallback(function () {
          fetch(ROUTE, { method: 'GET', headers: { 'cache-control': 'no-cache' } })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              if (!j || j.ok !== true) throw new Error((j && j.message) || '读不到设置');
              setS({ loading: false, error: '', data: j });
              setD({});
            })
            .catch(function (e) {
              setS({ loading: false, error: String(e && e.message ? e.message : e), data: null });
            });
        }, []);

        React.useEffect(function () { load(); }, [load]);

        // ★ 2026-11-10 随改随存：改动停下 700ms 就自动保存，不用再点"保存"。
        //
        // ⚠️⚠️ **这个 useEffect 必须待在这儿 —— 两个提前 return 之前。**
        //   2026-11-10 真踩过：一开始写在下面（`function save()` 后面），
        //   而上面有 `if (s.loading) return …` / `if (s.error) return …`。
        //   于是**第一次渲染只跑 5 个 hook，加载完跑 6 个**，
        //   React 抛 `Rendered more hooks than during the previous render`，
        //   **整个设置页直接白屏消失**。
        //   hook 数量必须在每次渲染中完全一致 —— 提前 return 之后的代码不算数。
        //
        // 【为什么要 debounce，而不是 change 里直接发】
        //   数字框是逐字符 onChange 的：改 "10" 会先经过 "1"。
        //   直接发 = 先存 1 秒再存 10 秒，中间那个值会真的生效一下（比如 idleSeconds=1
        //   会让它以为"1 秒没动静就算说完"，可能抢在你打字中间动手）。
        //   等 700ms 就是在等"手停"。
        //
        // 【为什么空串要跳过】
        //   用户在把 "10" 清空准备重打时，中间会经过 ""。
        //   那个值服务端会拒（不是合法数字），但拒了会弹红字，很吵。等它打完再说。
        //
        // 【保存中不禁用输入框】
        //   一开始想的是"存的时候锁住"，但输入框被 disabled 会**丢焦点** ——
        //   打字打到一半焦点跳走，比不锁更烦。所以这里只是后台发请求。
        //
        // 【`save` 能用吗】能 —— 它是函数声明（`function save() {}`），会被提升到作用域顶部。
        React.useEffect(function () {
          var keys = Object.keys(d);
          if (keys.length === 0) return undefined;
          for (var i = 0; i < keys.length; i += 1) {
            if (d[keys[i]] === '') return undefined;
          }
          var timer = setTimeout(function () { save(); }, 700);
          return function () { clearTimeout(timer); };
        }, [d]);

        if (s.loading) return React.createElement('div', { className: 'sr-loading' }, '正在读取插件设置…');
        if (s.error) {
          return React.createElement(
            'div',
            { className: 'sr-card' },
            React.createElement('div', { className: 'sr-msg sr-msg-err' }, '读不到设置：' + s.error),
            React.createElement(
              'div',
              null,
              React.createElement('button', { type: 'button', className: 'sr-btn', onClick: load }, '重试')
            )
          );
        }

        var values = s.data.values || {};
        var editable = s.data.editable || {};
        var dirty = Object.keys(d).length > 0;
        var effective = Object.assign({}, values, d);

        function change(key, value) {
          setM(null);
          setD(function (prev) {
            var next = Object.assign({}, prev);
            next[key] = value;
            return next;
          });
        }

        function save() {
          // ★ 2026-11-10 随改随存：先把这次要提交的内容**拍个快照**。
          //   为什么要快照：请求飞在路上的时候用户可能又改了一个开关，
          //   如果成功回调用 `setD({})` 一把清空，**后来那次改动就没了**（看着像没生效）。
          //   所以只清"发出去时是这个值、回来还是这个值"的键。
          var payload = d;
          if (Object.keys(payload).length === 0) return;
          setIsSaving(true);
          setM(null);
          fetch(ROUTE, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(payload),
          })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              setIsSaving(false);
              if (j && j.ok === true) {
                setM({ ok: true, text: '已保存，立即生效' });
                setS(function (prev) {
                  return Object.assign({}, prev, { data: Object.assign({}, prev.data, { values: j.values }) });
                });
                setD(function (prev) {
                  var next = Object.assign({}, prev);
                  Object.keys(payload).forEach(function (k) {
                    if (next[k] === payload[k]) delete next[k];
                  });
                  return next;
                });
              } else {
                var why = j && j.rejected && j.rejected.length
                  ? j.rejected.map(function (x) { return x.key + '：' + x.reason; }).join('；')
                  : (j && j.message) || '保存失败';
                setM({ ok: false, text: why });
              }
            })
            .catch(function (e) {
              setIsSaving(false);
              setM({ ok: false, text: '保存请求失败：' + String(e && e.message ? e.message : e) });
            });
        }

        // ⚠️⚠️ 自动保存那个 useEffect **不在这里** —— 它必须放在上面的
        //   `if (s.loading) return` / `if (s.error) return` **之前**。
        //   放在这儿（提前 return 之后）会让"第一次渲染 5 个 hook、加载完 6 个"，
        //   React 直接抛 `Rendered more hooks than during the previous render`，
        //   **整个设置页白屏消失**。2026-11-10 真踩过，见下面 useAutoSave 的位置。

        var pending = s.data.pendingPlanId || '';
        var notice = s.data.notice || { configured: false, enabled: false, armed: false };
        // 三种状态（2026-11-10 双钥匙）：
        //   命令没配            → 未配置
        //   配了但开关关着      → 已配置，未启用（不会执行）
        //   配了且开关开着      → 已启用（会执行）
        var noticeLabel = !notice.configured
          ? '通知通道：未配置'
          : (notice.armed ? '通知通道：已启用' : '通知通道：已配置 · 未启用');
        var noticeOk = notice.armed === true;

        return React.createElement(
          'div',
          { className: 'sr-card' },
          React.createElement(
            'div',
            { className: 'sr-head' },
            React.createElement('div', { className: 'sr-title' }, '自我重启 · 设置'),
            React.createElement(
              'span',
              { className: 'sr-pill ' + (pending ? 'sr-pill-warn' : 'sr-pill-ok') },
              React.createElement('span', { className: 'sr-dot' }),
              pending ? '正在排队：' + pending : '此刻没有待执行的重启'
            ),
            React.createElement(
              'span',
              { className: 'sr-pill ' + (noticeOk ? 'sr-pill-ok' : 'sr-pill-warn') },
              React.createElement('span', { className: 'sr-dot' }),
              noticeLabel
            ),
            React.createElement('span', { className: 'sr-sub' }, 'impl ' + (s.data.impl || '?'))
          ),
          noticeOk
            ? React.createElement(
                'div',
                { className: 'sr-hint' },
                '到点会执行你配的那条命令（超时 ' + Math.round((notice.timeoutMs || 30000) / 1000) + ' 秒），正文通过环境变量 DSH_SR_TEXT 交给它。'
              )
            : React.createElement(
                'div',
                { className: 'sr-hint' },
                !notice.configured
                  ? '「通知通道」没配：插件不会执行任何通知命令，所以下面**提醒**那一组的设置即使填了也不会发出任何消息。'
                  : '「通知命令已配、但开关关着」：**不会执行**。要真的发通知，请在下面打开「允许执行通知命令」。'
              ),
          // ★ 双钥匙的第二把（第一把是配置文件里的 noticeCommand）。
          //   命令本身故意不放在页面上 —— 那是"会被执行的代码"，不远程可写。
          !notice.configured
            ? React.createElement(
                'div',
                { className: 'sr-hint' },
                '要配命令：在配置文件的 noticeCommand 里填（该项故意不放在这个页面上）。'
              )
            : null,
          React.createElement(
            'div',
            { className: 'sr-sub' },
            '改一下自动保存，立即生效，不用重启 DSH。'
          ),

          GROUPS.map(function (g) {
            var keys = g.keys.filter(function (k) { return editable[k]; });
            if (keys.length === 0) return null;
            return React.createElement(
              'div',
              { className: 'sr-group', key: g.title },
              React.createElement(
                'div',
                { className: 'sr-grouphead' },
                g.title,
                g.hint ? React.createElement('span', { className: 'sr-sub', style: { fontWeight: 400, marginLeft: 8 } }, g.hint) : null
              ),
              keys.map(function (k) {
                return React.createElement(Row, {
                  key: k,
                  name: k,
                  spec: editable[k],
                  value: effective[k],
                  // ★ 保存中**不锁**输入框：disabled 会丢焦点，打字打到一半焦点跳走更烦。
                  //   请求在后台飞，用户继续改；回来的那次只清"没被再改过"的键。
                  disabled: false,
                  onChange: change,
                });
              })
            );
          }),

          React.createElement(
            'div',
            { className: 'sr-foot' },
            // ★ 2026-11-10：不摆"保存"按钮了 —— 改一下就自动存（见上面的 useEffect）。
            //   这里只报状态。存失败时把按钮换成「重试」，让用户有办法手动再推一次。
            isSaving
              ? React.createElement('span', { className: 'sr-sub' }, '保存中…')
              : (dirty
                ? React.createElement('span', { className: 'sr-sub' }, '待保存…')
                : React.createElement('span', { className: 'sr-sub sr-msg-ok' }, '✓ 已是保存状态')),
            (m && m.ok === false && dirty)
              ? React.createElement(
                'button',
                { type: 'button', className: 'sr-btn sr-btn-main', disabled: isSaving, onClick: save },
                '重试'
              )
              : null,
            React.createElement(
              'button',
              {
                type: 'button',
                className: 'sr-btn',
                disabled: !dirty || isSaving,
                onClick: function () { setD({}); setM(null); },
              },
              '放弃修改'
            ),
            React.createElement(
              'button',
              { type: 'button', className: 'sr-btn', disabled: isSaving, onClick: load },
              '重新读取'
            ),
            m ? React.createElement('span', { className: 'sr-msg ' + (m.ok ? 'sr-msg-ok' : 'sr-msg-err') }, m.text) : null
          )
        );
      }

      function summaryText() {
        return '自我重启 · 排队、劝停、唤醒、提醒的设置';
      }

      // ⚠️ inject 必须声明 slots —— 不声明就拿不到，且**不会报错**，
      //    只是那个页面永远不出现（dsh-open-obsidian 踩过这个坑）。
      exports.inject = ['slots'];

      exports.apply = function (ctx) {
        var slots = ctx.slots || (typeof ctx.get === 'function' ? ctx.get('slots') : null);
        if (!slots) {
          console.error('[dsh-self-restart] slots 服务不可用 —— 设置页没挂上');
          return;
        }
        function render(props) {
          return props && props.view === 'summary'
            ? summaryText()
            : React.createElement(Panel, null);
        }
        try {
          // ① 组合包自己的页面（描述与行之间）
          slots.inject('plugins.bundle.config', function () {
            return slots.register(
              { name: 'plugins.bundle.config', key: 'dsh-self-restart' },
              render
            );
          });
          // ② 行级入口（老版本宿主用这个位置）—— 两个都挂，谁的页面在哪个位置都能看见
          slots.inject('plugins.row.config', function () {
            return slots.register(
              { name: 'plugins.row.config', key: 'dsh-self-restart#self-restart' },
              render
            );
          });
        } catch (err) {
          console.error('[dsh-self-restart] client apply 失败：', err);
        }
      };

      return module.exports;
    } catch (err) {
      console.error('[dsh-self-restart] 浏览器端半边加载失败：', err);
      return { apply: function () {} };
    }
  },
});
