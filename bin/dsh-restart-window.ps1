# ============================================================================
#  dsh-restart-window.ps1 —— 自我重启的"状态窗"（现代外观版）
# ============================================================================
#  【它解决什么问题】
#    自我重启的助手在后台静默干活，使用者看不到任何动静：排了重启之后不知道它在等什么、
#    还要等多久、是不是已经放弃了。所以需要一个不依赖 DSH 界面的进度窗口，
#    让等待状态和进行状态可见。
#
#  【为什么必须是"单独的窗口"，不能做进 DSH 界面】
#    重启的关键时刻 DSH 自己会被关掉 —— 做在它界面里的东西**正好在最该看的那几秒消失**。
#    这个窗口是助手进程自己画的，不在 DSH 里，DSH 死了它照样活着，
#    所以能把「等待 → 关闭中 → 已关闭 → 正在拉起 → 起来了」整条演完。
#
#  ────────────────────────────────────────────────────────────────────────────
#  【2026-10-10 重写：修"转圈、点不动"】
#    实测反馈：「鼠标刚放到那个窗口上就会转圈圈……点上去好像没啥反应」。
#
#    根因：窗口和"每轮 Start-Sleep 5 秒"的助手逻辑跑在**同一个线程**上。
#      助手一睡，就没人给它处理窗口消息（WM_MOUSEMOVE 等）→ Windows 判定"未响应"
#      → 鼠标变成转圈的等待光标，点击也送不进去。
#
#    正解（三条缺一不可）：
#      ① **窗口跑在自己的线程上**：那个线程只干"跑界面"这一件事（自带消息循环），
#         所以助手睡多久、在主线程干什么，都不影响窗口响应。
#      ② 用 **WPF**（不是老式 WinForms）：圆角、系统字体、扁平配色，跟 Win11 一致。
#      ③ `ShowActivated = false`：显示时不激活自己 → 不抢用户焦点（WPF 的原生做法）。
#
#    ⚠️ 教训（写在这里免得后人重犯）：**窗口的响应性和"谁在睡"直接相关**。
#      凡是"界面 + 长任务"在同一个线程里的写法，都会出现这种"转圈"。
#      以后加任何会阻塞的操作（等待、轮询、跑命令），都必须确认它不在窗口线程上。
#
#    ⚠️ 另一个教训（测试方法）：上一版的自测是**在窗口自己的进程里、且窗口开在屏幕外**
#      问它"你卡了吗" —— 屏幕外没有鼠标经过，Windows 根本不会产生鼠标消息，
#      于是**永远测不出卡**。复现这个 bug 必须：窗口在可见位置 + 从**另一个进程**探测。
#  ────────────────────────────────────────────────────────────────────────────
#
#  【它绝不能拖累重启】
#    画窗口这件事**只许成功、不许失败**：任何异常都被吞掉并记一行日志，
#    绝不让"窗口画不出来"变成"重启没做成"。所以每个公开函数都包了 try/catch。
#
#  【谁在用它】
#    bin\dsh-self-restart.ps1（正主）。等闲置时刷新文字，动手前切阶段，结束前收起。
#
#  【怎么被调起来】
#    正主是 WMI 脱离进程（SessionId=1 = 交互式桌面，实测过），所以这里在本进程里
#    起一个界面线程即可，不用再开子进程 —— 少一层，也少一个要清理的东西。
#
#  用法（给 bin\dsh-self-restart.ps1 内部用）：
#    . dsh-restart-window.ps1                       # 点源进来（只定义函数）
#    Show-RestartWindow -Port 19387 -Reason '...'   # 显示
#    Set-RestartWindowStage -Stage 'waiting' -Detail '...' -EtaText '...'
#    Close-RestartWindow -FinalStage 'done' -FinalText '✅ 重启完成' -KeepSeconds 8
# ============================================================================

# ── WPF 窗体（编译一次；跑在自己的 STA 线程上）───────────────────────────────
# ⚠️ 这段 C# 只能编译一次：PowerShell 里重复 Add-Type 同名类型会报
#    "type already exists"。所以用一个脚本级标志挡住第二次。
$script:DshRwTypeReady = $false

function Initialize-DshRwType {
  if ($script:DshRwTypeReady) { return $true }
  try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    # 也加载 WinForms：只用它的 Screen.WorkingArea 拿"物理像素"屏幕尺寸
    # （WPF 的 SystemParameters.WorkArea 在 150% 缩放下口径不一致，见 Start() 里的说明）
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Interop;
using System.Windows.Threading;
using WinForms = System.Windows.Forms;

/// <summary>
/// 自我重启的状态窗（现代外观、独立线程、不抢焦点）。
///
/// 关键设计（改动前请先读懂，否则很容易把"转圈"那个 bug 改回来）：
///   · 整个窗口 + 消息循环都在**自己 new 出来的 STA 线程**里（见 Start()）。
///     宿主线程只通过 Dispatcher.BeginInvoke 把"改文字"这类小事投递进来，
///     所以宿主就算睡 10 分钟，窗口照样跟手。
///   · ShowActivated = false → 冒出来时不抢焦点。
///   · 所有写界面的操作都走 Ui()，并且全程 try/catch：界面出错不许影响重启。
/// </summary>
public class DshRestartStatusWindow
{
    private Thread _thread;
    private Window _win;
    private Border _card;
    private TextBlock _title;
    private TextBlock _stage;
    private TextBlock _detail;
    private TextBlock _eta;
    private Button _abort;
    // ★ 2026-10-24 新增：「不等了，立刻重启」—— 跳过"等家务（后台任务/子代理）"这一段。
    //
    // 【为什么要有它】（用户原话，2026-10-24）
    //   「我当时看不到他在哪个地方在跑」「给我一个手动强制进行下一步的按钮」
    //   上一趟重启卡在记忆插件的复审子代理上，等了 3 分多钟；状态窗只能说
    //   "家务子代理 1 个"，既看不出是谁、也没有"别等了"的出口 —— 只能打断整趟。
    //   这个按钮就是那个出口：**只跳过"等"，不跳过"能不能拉起"的安全检查**。
    //   点击后写一个 force 标记文件；助手每轮都会查它，看到就往下走（仍然有 10 秒确认窗）。
    private Button _force;
    private volatile bool _forceArmed;
    private volatile string _forceFile;
    // ★ 2026-10-23 新增：右上角的「×」（像真窗口那样关掉；重启还在跑时同时要求停止）
    private Button _close;
    // 「打断」按钮的可用性：只有"还能反悔"的阶段才让它可用（见 ArmAbort 的说明）
    private volatile bool _abortArmed;
    private volatile string _cancelFile;
    // 拖动状态（见 _card 上那三个事件里的说明）
    private bool _dragging;
    private Point _grabPoint;
    // 拖动计数（给自动化验收看：三个事件到底有没有触发）
    private int _downCount, _moveCount, _upCount;
    private readonly object _ready = new object();
    private volatile bool _isUp;
    // 屏幕工作区的**逻辑尺寸**（设备无关单位），在摆位时算好，供 KeepOnScreen 用。
    private double _screenLogicalW;
    private double _screenLogicalH;
    // 用户是否手动拖过窗口。拖过之后**不再自动贴右下角** —— 否则他刚拖到顺手的位置，
    // 下一次内容更新就被拽回去，那是帮倒忙。（只保留"别越出屏幕"的兜底。）
    private bool _userMoved;
    // ★ 首屏内容（在 Show 之前就填好，避免"先矮后高"蹦一下，见 Start 的说明）
    private string _pendingStage;
    private string _pendingDetail;
    private string _pendingEta;

    // ══ 2026-10-23 下午：把它做成"正常窗口"用的常量与状态 ══════════════════
    //
    // 【CaptionHeightPx = 40】顶部这么高的一条交给系统当标题栏（能拖、光标是移动手型）。
    //   取值的依据不是随手取整：卡片内边距上 14 + 标题字号 12 ≈ 文字占 14~28；
    //   ✕ 按钮距顶 8、高 22 → 占 8~30。取 40 把这两样都框进来，
    //   又不会吃掉下面「等待中」那行大字。实测（WM_NCHITTEST 探针）：
    //   距顶 15/40 → HTCAPTION，距顶 120 → HTCLIENT。
    private const double CaptionHeightPx = 40;

    // 【ShadowPad = 12】卡片四边的留白，让 BlurRadius=16 的阴影画得开。
    //   以前卡片直接当窗口 Content、没有边距 → 阴影被窗口矩形硬裁，看着是"硬切边"。
    //   ⚠️ 只加外边距、不动内边距：内容位置和以前一样，测试坐标不受影响。
    private const double ShadowPad = 12;

    // WindowChrome 有没有挂上（false = 退回老式"整卡拖动"，功能不坏、只是没那么像正常窗口）
    private bool _chromeOk = true;

    // 置顶状态：前 TopmostSeconds 秒置顶（保证你看得见），之后放下来（正常窗口不会被别人盖住）
    //   ★ 用户 定：「只在前 10 秒置顶，之后放下来」
    //   ⚠️ 为什么不一直置顶：他说这窗口"太奇怪了"，永远压在最上面是其中一份。
    //   ⚠️ 为什么不干脆不置顶：重启开始后卡片可能被挡住，就看不到「打断」按钮了；
    //      前 10 秒置顶正好覆盖"刚弹出来、你还在看"的那段。
    private const double TopmostSeconds = 10;
    private System.Windows.Threading.DispatcherTimer _topmostTimer;

    /// <summary>
    /// 置顶**是否已经放下来**了（供测试与排查读）。
    ///   判据必须是"真去读了窗口的 Topmost"，不是"定时器走完了" ——
    ///   定时器走完但赋值失败的情况，只有读窗口状态才看得出来。
    /// </summary>
    public bool TopmostDropped = false;

    /// <summary>
    /// WindowChrome 是否挂上了（供测试读）。false = 退回老式"整卡拖动"。
    /// 测试判据：**必须是 true** —— 退回老路径虽然能用，但那正是"像不像正常窗口"没做到。
    /// </summary>
    public bool ChromeOk { get { return _chromeOk; } }

    /// <summary>
    /// **首次渲染时**窗口的高度（设备无关单位）；拿不到时为 0。
    ///
    /// 为什么要有它（2026-10-13，一条"测不出来"的坑）：
    ///   我要验的判据是"窗口第一次出现时就已经是最终高度"（不蹦）。
    ///   但在**外面**量是不行的 —— `Start()` 返回时，老写法的 `Set()` 也已经执行完了，
    ///   外部测试量到的永远是最终高度，**改坏了也不报红**（实测确认过这种假绿）。
    ///   所以必须由窗口自己在 `ContentRendered`（首次渲染）那一刻记下来。
    ///   判据：`FirstPaintHeight` ≈ 稳定后的高度 ⇒ 没蹦。
    /// </summary>
    public double FirstPaintHeight;
    /// <summary>首次渲染时的宽度（同上，供诊断）。</summary>
    public double FirstPaintWidth;

    /// <summary>
    /// **Loaded 那一刻**的窗口高度（设备无关单位）。
    ///
    /// 判据用它：Loaded 在 `Start()` 返回**之前**触发；首屏内容若已填好（新写法），
    /// 此刻高度就已是最终高度；老写法要到 `Start()` 返回后才 `Set()`，
    /// 所以此刻还是"只有标题+阶段"的矮高度 —— **两者能区分开**。
    /// （为什么不用 ContentRendered：内容更新的优先级高于渲染，老写法下它记到的已是最终高度。）
    /// </summary>
    public double LoadedHeight;
    /// <summary>Loaded 那一刻详情文字的字符数（0 = 首屏详情还没填 = 老写法）。</summary>
    public int LoadedDetailChars;

    /// <summary>
    /// 从窗口**自己的线程**读当前高度（设备无关单位）；拿不到时返回 0。
    ///
    /// 为什么不能直接读 `ActualHeight`：那是 WPF 控件属性，**跨线程读会拿到默认值 0**
    /// （窗口跑在它自己的 STA 线程上，属性必须在那个线程里问）。第一版测试就是直接读，
    /// 结果第一次比对拿到 409.2 vs 0，报了个**看起来像真问题、其实是测试自己写错**的红。
    /// 所以提供这个方法：内部用 Dispatcher.Invoke 回到窗口线程去取值。
    /// </summary>
    public double HeightNow()
    {
        double h = 0;
        try
        {
            if (_win == null) return 0;
            _win.Dispatcher.Invoke(new Action(() =>
            {
                try { h = _win.ActualHeight; } catch { }
            }));
        }
        catch { }
        return h;
    }

    /// <summary>
    /// 把窗口**按它当前的真实高度**贴回屏幕内（右下角，留边距）。
    ///
    /// 【为什么必须有这个函数】（2026-10-13 用户报："展开以后会有一部分到屏幕外被挡到看不见"）
    ///   窗口是 `SizeToContent = Height` —— **内容有多高它就长多高**。
    ///   而摆位那里原来用的是**写死的估算高度**（`logicalBottom - 170 - 110`），
    ///   于是内容一变长（比如 `reason` 很长、或详情行变多），
    ///   窗口就**从那个固定位置往下长，直接长出屏幕底部**，被任务栏/屏幕边缘切掉。
    ///   本机实测：工作区逻辑高约 679 单位，那个估算只给它留了 280 单位 —— 超了必溢出。
    ///
    /// 【为什么在这里做、而不是只改那个估算值】
    ///   内容长度是**动态**的（阶段文案/耗时/原因都会变），任何写死的值都只是把
    ///   溢出阈值挪一挪，迟早还会越界。所以要**每次都按实际高度重算**。
    ///
    /// 安全边界：
    ///   · 拿不到屏幕尺寸（探测失败）→ 什么都不做，保持原样（宁可不动，也别乱摆）。
    ///   · 窗口比屏幕还高（内容极长）→ 顶到上边距，让它从顶部开始排；
    ///     下沿仍可能超出，但**标题/阶段/按钮这些关键行一定看得见**（比整块看不见好）。
    /// </summary>
    private void KeepOnScreen()
    {
        try
        {
            if (_win == null) return;
            if (_screenLogicalW <= 0 || _screenLogicalH <= 0) return;

            double margin = 40;          // 与初始摆位保持一致的右边距
            double bottomGap = 24;       // 下边留一点，别贴着任务栏

            // ★★ 2026-10-23 深夜：**先把窗口高度夹进屏幕，再摆位**
            //
            // 【为什么必须夹】(window-extreme 实机报红：底边 1052 vs 屏幕 1019)
            //   内容是 1028 字的 reason，窗口自然高度**超过屏幕**。
            //   下面那段"顶边贴 margin"的降级只保证了标题可见，
            //   **底边照样出屏 33 像素** —— 用户要的是"展开后不许有部分跑到屏幕外"。
            //   现在：内容区已经套了 ScrollViewer（见 cardRoot 那段），
            //   所以这里可以放心把高度限死，多出来的内容自己滚。
            //
            // 上限 = 屏幕逻辑高 − 上下各留一点（底部 bottomGap、顶部至少 margin）
            double maxH = _screenLogicalH - bottomGap - margin;
            if (maxH > 0 && _win.MaxHeight != maxH)
            {
                try { _win.MaxHeight = maxH; } catch { }
            }

            double h = _win.ActualHeight > 0 ? _win.ActualHeight : _win.Height;
            if (h <= 0) return;

            // 纵向：**从屏幕底部往上数**（用户 的建议，也是这套算法的本意）——
            //   先定"底边贴在哪"，再由底边减掉窗口自身高度得出顶边。
            //   这样窗口长高时顶边自己往上让，**底边始终不动**，视觉上就是"从下往上长"，
            //   而不是"从一个固定顶边往下长、长到屏幕外面去"。
            double top = _screenLogicalH - h - bottomGap;

            if (_userMoved)
            {
                // 用户拖过：**只保证不越出屏幕**，不强行拉回右下角。
                double curTop = _win.Top;
                if (curTop + h > _screenLogicalH - bottomGap) curTop = _screenLogicalH - h - bottomGap;
                if (curTop < margin) curTop = margin;
                _win.Top = curTop;
                if (_win.Left < margin) _win.Left = margin;
                if (_win.Left + _win.Width > _screenLogicalW - margin)
                    _win.Left = _screenLogicalW - _win.Width - margin;
                return;
            }

            // 横向：保持右边距，但也别越出左边界
            double left = _screenLogicalW - _win.Width - margin;
            if (left < margin) left = margin;
            _win.Left = left;

            // 窗口比屏幕还高（内容极长）→ 顶到上边距，从顶部开始排：
            // 下沿仍可能超出，但**标题/阶段/按钮这些关键行一定看得见**（比整块看不见好）。
            if (top < margin) top = margin;
            _win.Top = top;
        }
        catch { /* 摆位失败不该影响重启本身 */ }
    }

    /// <summary>
    /// 拖动的诊断信息（给自动化验收用）："down=N move=M up=K dragging=bool"。
    /// 为什么需要：拖动失败时，"**事件根本没触发**"和"触发了但**坐标算错**"是两种
    /// 完全不同的病，修法也完全不同。看不到这个就只能猜 ——
    /// 2026-10-11 全量跑时拖不动，就是靠它才分清是哪一种。
    /// </summary>
    public string DragDebug()
    {
        return string.Format("down={0} move={1} up={2} dragging={3}", _downCount, _moveCount, _upCount, _dragging);
    }

    /// <summary>
    /// 当前窗口的实际缩放比（1.0 = 100%、1.5 = 150%）。
    ///
    /// 为什么需要：WPF 的 `Left/Top` 用**设备无关单位**，而 `PointToScreen` /
    /// `Screen.WorkingArea` 给的是**物理像素**。本机 150% 缩放，两套口径差 1.5 倍，
    /// 混用会把窗口算飞（摆位那里已经踩过一次，拖动这里是同一个坑）。
    /// 拿不到时返回 1.0（宁可差一点点，也不能抛异常把拖动搞崩）。
    /// </summary>
    private double GetWindowScale()
    {
        try
        {
            var src = PresentationSource.FromVisual(_win);
            if (src != null && src.CompositionTarget != null)
            {
                var m = src.CompositionTarget.TransformToDevice;
                if (m.M11 > 0) return m.M11;
            }
        }
        catch { }
        return 1.0;
    }

    /// <summary>窗口线程里出的错（拿不到就说明没出错）。给宿主写日志用。</summary>
    public volatile string LastError = null;

    public bool IsUp { get { return _isUp; } }

    /// <summary>
    /// 告诉窗口"现在还能不能打断"。
    /// armed=true 且 cancelFile 非空时，按钮才可点；点了就写那个文件。
    /// ⚠️ 一旦助手开始关 DSH，宿主会调 ArmAbort(false, ...) 把按钮禁掉并改文案 ——
    ///    因为那时"取消"已经没意义了，留着能点却做不到更糟。
    /// </summary>
    // ════════════════════════════════════════════════════════════════════════
    // ★ 2026-10-23 新增：**测试专用**——在 UI 线程上真的触一下右上角的 ✕
    //
    // 【为什么必须由模块自己提供这个入口】
    //   自动化测试想验"点 ✕ 会不会写 cancel.flag、会不会关窗"，试过三种办法全失败：
    //     ① UI Automation 按标题找窗口 → 找不到（我们的窗口是 WindowStyle=None 的自绘卡片）
    //     ② 从外部 Dispatcher.Invoke 一个 PowerShell 脚本块 → **卡死**
    //        （WPF 的 UI 线程里没有 PowerShell Runspace，脚本块无法执行）
    //     ③ 反射读 Content → 拿到空字符串（跨线程读 WPF 依赖属性不可靠）
    //   ⇒ 唯一稳的办法：让**窗口自己**在它自己的 UI 线程上执行这一下。
    //
    // 【它做什么】就是真的调一次 `_close.RaiseEvent(Click)` ——
    //   走的是和鼠标点击**完全同一条**事件链，测的是真行为，不是模拟返回值。
    //
    // 【怎么判断结果】调用方看两样东西：
    //   · cancelFile 有没有被创建（这就是"点了要停止"的信号）
    //   · 窗口 IsUp 有没有变 false（点了就该关）
    // ════════════════════════════════════════════════════════════════════════
    public void ClickCloseForTest()
    {
        Ui(() =>
        {
            try
            {
                if (_close == null) return;
                _close.RaiseEvent(new RoutedEventArgs(
                    System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            }
            catch (Exception ex) { LastError = "ClickCloseForTest: " + ex.Message; }
        });
    }

    public void ArmAbort(bool armed, string cancelFile)
    {
        _cancelFile = cancelFile;
        _abortArmed = armed;
        Ui(() =>
        {
            try
            {
                if (armed)
                {
                    _abort.IsEnabled = true;
                    if (!string.IsNullOrEmpty(cancelFile)) _abort.Content = "打断这次重启";
                }
                else
                {
                    _abort.IsEnabled = false;
                    // 只改文案，不改阶段标题（阶段由宿主自己管）
                    if (string.IsNullOrEmpty(cancelFile)) _abort.Content = "打断这次重启（暂不可用）";
                    else _abort.Content = "已经开始关了，来不及打断";
                }
            }
            catch { }
        });
    }

    /// <summary>
    /// 告诉窗口"现在能不能点「不等了，立刻重启」"。
    ///
    /// armed=true 且 forceFile 非空时才可点；点了写那个文件（助手看到就跳过"等家务"）。
    /// ⚠️ 只有"这一轮说完了、只剩家务在跑"的阶段才该 armed —— 别的阶段点亮它，
    ///    等于给了一个"可以砍断别人对话"的按钮，那是设计上绝不能出现的。
    /// </summary>
    public void ArmForce(bool armed, string forceFile)
    {
        _forceFile = forceFile;
        _forceArmed = armed;
        Ui(() =>
        {
            try
            {
                if (_force == null) return;
                _force.IsEnabled = armed;
                if (armed) _force.Content = "不等了，立刻重启";
                else if (string.IsNullOrEmpty(forceFile)) _force.Content = "不等了，立刻重启（暂不可用）";
                else _force.Content = "不等了（现在没有可跳过的家务）";
            }
            catch { }
        });
    }

    /// <summary>
    /// 「不等了」按钮中心点的屏幕物理坐标（"x,y"）。给自动化验收用（理由同 AbortButtonCenter）。
    /// </summary>
    public string ForceButtonCenter()
    {
        string s = "";
        try
        {
            _win.Dispatcher.Invoke(new Action(() =>
            {
                try
                {
                    if (_force == null) return;
                    var p = _force.PointToScreen(new Point(_force.ActualWidth / 2, _force.ActualHeight / 2));
                    s = ((int)Math.Round(p.X)) + "," + ((int)Math.Round(p.Y));
                }
                catch { }
            }));
        }
        catch { }
        return s;
    }

    /// <summary>
    /// 测试专用：在 UI 线程上真的点一下「不等了，立刻重启」（走和鼠标点击同一条事件链）。
    /// </summary>
    public void ClickForceForTest()
    {
        Ui(() =>
        {
            try
            {
                if (_force == null) return;
                _force.RaiseEvent(new RoutedEventArgs(
                    System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            }
            catch (Exception ex) { LastError = "ClickForceForTest: " + ex.Message; }
        });
    }

    /// <summary>
    /// 测试专用：在 UI 线程上真的点一下「打断这次重启」（同上，走真事件链）。
    /// 加它的原因：2026-10-24 加了「不等了」之后，必须证明「打断」的原有行为没被带坏 ——
    /// 而"读代码"证明不了点了真的写标记。
    /// </summary>
    public void ClickAbortForTest()
    {
        Ui(() =>
        {
            try
            {
                if (_abort == null) return;
                _abort.RaiseEvent(new RoutedEventArgs(
                    System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            }
            catch (Exception ex) { LastError = "ClickAbortForTest: " + ex.Message; }
        });
    }

    /// <summary>当前是不是暗色主题（供宿主写日志/排查用）。</summary>
    public bool IsDarkTheme = false;

    /// <summary>
    /// 在独立线程上建窗口并显示。返回是否成功起来了。
    ///
    /// ★ 2026-10-13 加 initialDetail / initialStage：**把首屏内容在显示之前就填好**。
    ///
    /// 【为什么必须这样】（用户报的现象："窗口刚弹出来时闪了一下，突然长一截"）
    ///   原来是 `_win.Show()` 之后才调 `Set()` 去填"原因：…"那段长文字 ——
    ///   于是窗口**先以很矮的样子出现，内容一到就啪地长高**，看着就是"蹦一下"。
    ///   更糟的是显示瞬间的高度是按**空内容**量的，`KeepOnScreen` 那一贴也贴在了错的高度上。
    ///   现在：首屏内容**在 Show 之前**就赋值 —— 窗口第一次出现就是最终尺寸，不闪不蹦。
    ///
    /// （实测背景：用户 亲眼看到"突然弹出来长一截的内容，我没看清就跳过去了"。）
    /// </summary>
    public bool Start(string title, string initialStage = null, string initialDetail = null, string initialEta = null)
    {
        _pendingStage = initialStage;
        _pendingDetail = initialDetail;
        _pendingEta = initialEta;
        _thread = new Thread(() =>
        {
            try
            {
                // ── 主题（亮色 / 暗色）──────────────────────────────────────
                // 跟随系统设置：HKCU\...\Themes\Personalize\AppsUseLightTheme
                //   1 = 亮色（默认），0 = 暗色。
                // 两套配色都定义好，切换时**重新赋值**（WPF 改 属性值 会即时重绘）。
                bool dark = false;
                try
                {
                    using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                        @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    {
                        if (key != null)
                        {
                            object v = key.GetValue("AppsUseLightTheme");
                            if (v != null) dark = Convert.ToInt32(v) == 0;
                        }
                    }
                }
                catch { }
                // ⚠️ 仅测试用：允许用环境变量把主题**强制**成亮色，
                //    好在"系统是暗色"的机器上也能把亮色那一套也测出来
                //    （否则亮色配色只有在别人机器上才会被用到，等于没测）。
                //    产品流程不会设这个变量。
                try
                {
                    if (Environment.GetEnvironmentVariable("DSH_RW_FORCE_LIGHT") == "1") dark = false;
                    if (Environment.GetEnvironmentVariable("DSH_RW_FORCE_DARK") == "1") dark = true;
                }
                catch { }
                IsDarkTheme = dark;

                // 主题色板
                Color colCard   = dark ? Color.FromRgb(0x2B, 0x2B, 0x2B) : Color.FromRgb(0xFB, 0xFB, 0xFD);
                Color colBorder = dark ? Color.FromRgb(0x44, 0x44, 0x48) : Color.FromRgb(0xDC, 0xE0, 0xE6);
                Color colTitle  = dark ? Color.FromRgb(0xA0, 0xA0, 0xA0) : Color.FromRgb(0x70, 0x70, 0x70);
                Color colDetail = dark ? Color.FromRgb(0xE6, 0xE6, 0xE6) : Color.FromRgb(0x28, 0x28, 0x28);
                Color colEta    = dark ? Color.FromRgb(0x96, 0x96, 0x96) : Color.FromRgb(0x8A, 0x8A, 0x8A);
                Color colBtnBg  = dark ? Color.FromRgb(0x3A, 0x3A, 0x3D) : Color.FromRgb(0xF5, 0xF5, 0xF5);
                Color colBtnBd  = dark ? Color.FromRgb(0x55, 0x55, 0x59) : Color.FromRgb(0xD6, 0xD6, 0xD6);
                Color colBtnFg  = dark ? Color.FromRgb(0xEC, 0xEC, 0xEC) : Color.FromRgb(0x30, 0x30, 0x30);

                // ── 里层内容 ────────────────────────────────────────────────
                var stack = new StackPanel { Margin = new Thickness(18, 14, 18, 14) };

                _title = new TextBlock
                {
                    Text = title,
                    FontSize = 12,                    FontWeight = FontWeights.Normal,
                    Foreground = new SolidColorBrush(colTitle),
                    TextTrimming = TextTrimming.CharacterEllipsis
                };

                _stage = new TextBlock
                {
                    // ★ 首屏内容在**建控件时**就填好（不是 Show 之后再补）——
                    //   这样窗口第一次量尺寸就是最终高度，不会"先矮后高"蹦一下。
                    Text = string.IsNullOrEmpty(_pendingStage) ? "等待中" : _pendingStage,
                    FontSize = 19,
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(0, 8, 0, 0),
                    Foreground = new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0))
                };

                _detail = new TextBlock
                {
                    Text = _pendingDetail ?? "",
                    FontSize = 12.5,
                    Margin = new Thickness(0, 10, 0, 0),
                    TextWrapping = TextWrapping.Wrap,
                    LineHeight = 19,
                    Foreground = new SolidColorBrush(colDetail)
                };

                _eta = new TextBlock
                {
                    Text = _pendingEta ?? "",
                    FontSize = 11.5,
                    Margin = new Thickness(0, 10, 0, 0),
                    // ★ 2026-10-24：加换行 —— "不等了"那版 ETA 比原来长，不换行会被卡片边缘切掉
                    //   （实测截图：右半边直接没了，看着像"话说一半"）。
                    TextWrapping = TextWrapping.Wrap,
                    LineHeight = 17,
                    Foreground = new SolidColorBrush(colEta)
                };

                // 「打断」按钮（把原来那个没用的"藏起来"改成能打断）。
                //
                // 语义：**取消这次自动重启**，DSH 不动。
                // ⚠️ 只在"还能反悔"的阶段有效 —— 一旦已经动手关 DSH，按钮会自己禁用
                //    并改文案（"已经在关了，来不及了"）。理由：那半秒里 DSH 正在被关，
                //    "取消"没有意义，承诺了却做不到比不给按钮更糟。
                // 实现：按钮只**写一个取消标记文件**（和 restart_status(cancel=true) 用的同一个），
                //    助手每轮循环都会查它 → 看到就放弃，DSH 一根汗毛不动。
                _abort = new Button
                {
                    Content = "打断这次重启",
                    FontSize = 12,
                    Padding = new Thickness(12, 4, 12, 4),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 6, 0, 0),
                    Cursor = Cursors.Hand,
                    BorderThickness = new Thickness(1)
                    // ⚠️⚠️ **故意不在这里设 Background / Foreground / BorderBrush**！
                    //    WPF 的取值优先级里，**局部设的值 > 模板触发器**（local value 最高）。
                    //    第一版就在这里设了颜色，结果我自己写的"禁用样子"（模板触发器）
                    //    **根本生效不了** —— 实测采样出来禁用时底色还是"可点"那套
                    //    RGB(58,58,61)，跟我想要的 (51,51,54) 对不上，才发现是这个原因。
                    //    所以：颜色一律交给下面的模板触发器给，按钮本体不设。
                };

                // ⚠️⚠️ **必须自己定义"禁用"时的样子**（2026-10-10 实测反馈：
                //    "变灰的时候，因为是白底白字，辨识度好像很差"）。
                //
                //    病根：WPF 按钮的**内置禁用样式会覆盖**我们的配色 ——
                //    它把底色画成浅色、文字调成极浅的灰。
                //    实测（采样渲染出来的真实像素、按 WCAG 算对比度）：
                //      可点时 底色 RGB(58,58,61) 文字 RGB(236,236,236) → 9.60:1 ✅
                //      禁用时 **底色 RGB(244,244,244) 文字 RGB(244,244,244) → 1.00:1** ❌
                //      1.00:1 = 白底白字，**等于什么都没有**（反馈里说的"看不清字"就是这个）。
                //
                //    修法：挂一个 ControlTemplate，在里面用触发器**明确指定**
                //    IsEnabled=True / False 两套配色，并且按钮本体不设这些属性
                //    （否则又会被局部值压住，见上面的说明）。
                //    禁用配色要求：对比度 ≥ 4.5:1（读得清）**且**一眼看得出"不可用"。
                var abortTemplate = new ControlTemplate(typeof(Button));
                var borderFactory = new FrameworkElementFactory(typeof(Border));
                borderFactory.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
                borderFactory.SetValue(Border.BorderThicknessProperty, new Thickness(1));
                borderFactory.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Button.BackgroundProperty));
                borderFactory.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Button.BorderBrushProperty));
                var contentFactory = new FrameworkElementFactory(typeof(ContentPresenter));
                contentFactory.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
                contentFactory.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
                contentFactory.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(Button.PaddingProperty));
                borderFactory.AppendChild(contentFactory);
                abortTemplate.VisualTree = borderFactory;

                // 可点时的样子
                var trigEnabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = true };
                trigEnabled.Setters.Add(new Setter(Button.BackgroundProperty, new SolidColorBrush(colBtnBg)));
                trigEnabled.Setters.Add(new Setter(Button.ForegroundProperty, new SolidColorBrush(colBtnFg)));
                trigEnabled.Setters.Add(new Setter(Button.BorderBrushProperty, new SolidColorBrush(colBtnBd)));
                trigEnabled.Setters.Add(new Setter(FrameworkElement.CursorProperty, Cursors.Hand));
                abortTemplate.Triggers.Add(trigEnabled);

                // ★ 禁用时的样子：**必须一眼看出"它不可用"**，同时文字还得读得清。
                //   两套都按 WCAG 算过对比度，都在 4.5:1 以上。
                //
                //   ⚠️ 暗色第一版只把底色改深了一点点（58→51），实测"可点/禁用"
                //      两态的亮度差只有 0.009 —— **几乎看不出区别**，就不知道能不能点。
                //      现在改成：底色更暗（趋近卡片）+ **文字明显变灰**（236→154），
                //      两态靠"文字亮度"就能分辨（实测差的倍率 2.3 倍）。
                Color disBg = dark ? Color.FromRgb(0x2E, 0x2E, 0x31) : Color.FromRgb(0xEC, 0xEC, 0xEC);
                Color disFg = dark ? Color.FromRgb(0x9A, 0x9A, 0x9F) : Color.FromRgb(0x69, 0x69, 0x69);
                Color disBd = dark ? Color.FromRgb(0x3C, 0x3C, 0x3F) : Color.FromRgb(0xD8, 0xD8, 0xD8);
                var trigDisabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
                trigDisabled.Setters.Add(new Setter(Button.BackgroundProperty, new SolidColorBrush(disBg)));
                trigDisabled.Setters.Add(new Setter(Button.ForegroundProperty, new SolidColorBrush(disFg)));
                trigDisabled.Setters.Add(new Setter(Button.BorderBrushProperty, new SolidColorBrush(disBd)));
                // ⚠️ CursorProperty 在 FrameworkElement 上，不在 UIElement 上
                //    （写错会编译失败："UIElement 并不包含 CursorProperty 的定义"）
                trigDisabled.Setters.Add(new Setter(FrameworkElement.CursorProperty, Cursors.Arrow));
                abortTemplate.Triggers.Add(trigDisabled);

                _abort.Template = abortTemplate;
                _abort.Click += (s, e) =>
                {
                    try
                    {
                        if (_abortArmed && !string.IsNullOrEmpty(_cancelFile))
                        {
                            System.IO.File.WriteAllText(_cancelFile,
                                "aborted from status window at " + DateTime.Now.ToString("o") + "\r\n");
                            _abort.IsEnabled = false;
                            _abort.Content = "已打断（DSH 不会被关）";
                            // 「不等了」随之作废：整趟都取消了，还留着"继续重启"的按钮就是骗人
                            if (_force != null) { _force.IsEnabled = false; _force.Content = "已经取消，不用再等也不用重启"; }
                            _stage.Text = "已打断";
                            _stage.Foreground = new SolidColorBrush(Color.FromRgb(0x76, 0x76, 0x76));
                            _detail.Text = "这次自动重启已经取消，DSH 没有被动过。";
                            _eta.Text = "想让 DSH 重启，随时再排一次就行。";
                        }
                    }
                    catch { }
                };
                _abort.IsEnabled = false;   // 等宿主给取消标记路径 + "还能反悔"的许可

                // ══════════════════════════════════════════════════════════════
                // ★ 2026-10-24 新增：「不等了，立刻重启」
                //
                // 【它和「打断」的区别】**必须一眼看懂，写在这行按钮上**：
                //   · 「不等了，立刻重启」= 别再等家务了，**继续重启**（DSH 会被关掉重开）
                //   · 「打断这次重启」    = **取消整趟**（DSH 一根汗毛都不动）
                //   两个按钮放在一起、文案都写明后果 —— 用户是来"催"的，不是来"取消"的，
                //   把两者混成一个按钮，等于让他自己猜。
                //
                // 【什么时候能点】只有"这一轮已经说完、只剩下家务在跑"那一段（宿主调 ArmForce(true)）。
                //   别的时候（比如还在等别的对话）按钮是灰的，并写明"暂不可用" ——
                //   绝不给一个点了会砍断别人对话的按钮。
                //
                // 【点了之后】只写一个 force 标记文件。**关什么、怎么关、能不能拉起来，
                //   还是助手那一套检查说了算**：preflight（主程序在不在）+ 目标一致性
                //   + 10 秒确认窗一个都不跳过。这个按钮只跳过"等"。
                // ══════════════════════════════════════════════════════════════
                _force = new Button
                {
                    Content = "不等了，立刻重启（暂不可用）",
                    FontSize = 12,
                    Padding = new Thickness(12, 4, 12, 4),
                    // ★ 2026-10-24（用户反馈之后）：两个按钮**横着排**，不上下叠。
                    //   原来一竖排，卡片被撑得又高又散；横排后整张卡矮一截，也像正常的对话框。
                    Margin = new Thickness(0, 0, 8, 0),
                    Cursor = Cursors.Hand,
                    BorderThickness = new Thickness(1)
                    // 配色同样交给模板触发器（理由见上面「打断」那段：局部值会压住触发器）
                };
                // 复用「打断」那个模板（WPF 的 ControlTemplate 可以给多个按钮共用）
                _force.Template = abortTemplate;
                _force.Click += (s, e) =>
                {
                    try
                    {
                        if (_forceArmed && !string.IsNullOrEmpty(_forceFile))
                        {
                            System.IO.File.WriteAllText(_forceFile,
                                "force from status window at " + DateTime.Now.ToString("o") + "\r\n");
                            _forceArmed = false;
                            _force.IsEnabled = false;
                            _force.Content = "已经按你说的：不家务了，继续重启";
                            _stage.Text = "准备重启";
                            _stage.Foreground = new SolidColorBrush(Color.FromRgb(0x00, 0x67, 0xC0));
                            _detail.Text = "不再等家务了。接下来助手会先做安全检查（主程序在不在、要关的是不是它），"
                                         + "然后进入 10 秒确认窗 —— 那 10 秒里仍然可以点「打断」。";
                            _eta.Text = "";
                        }
                    }
                    catch { }
                };
                _force.IsEnabled = false;   // 等宿主确认"现在只剩家务在跑"才点亮

                // ── 两个按钮**左右并排**（2026-10-24 用户反馈"不太好看、别上下叠"）──
                //   横排：左边「不等了，立刻重启」，右边「打断这次重启」。
                //   竖向顺序原来的语义没变（先"催"、再"停"），只是从上下改成左右。
                var btnRow = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Margin = new Thickness(0, 10, 0, 0)
                };
                _abort.HorizontalAlignment = HorizontalAlignment.Left;
                _abort.Margin = new Thickness(0);
                btnRow.Children.Add(_force);
                btnRow.Children.Add(_abort);

                stack.Children.Add(_title);
                stack.Children.Add(_stage);
                stack.Children.Add(_detail);
                stack.Children.Add(_eta);
                stack.Children.Add(btnRow);

                // ══════════════════════════════════════════════════════════════
                // ★ 2026-10-23 新增：右上角的「×」—— 像真窗口那样随手能关
                //
                // 【用户原话】
                //   「我想要的是一个就是右上角的类似于窗口的关闭的按钮」
                //   「点叉号等于终止重启，如果当前阶段无法终止，那就完成当前阶段，
                //     停在下一阶段前」
                //
                // 【它和「打断」按钮什么关系】
                //   不是替代，是**更顺手的第二个入口**：
                //     · 「打断」= 文字按钮，写明语义，适合"我读懂了，我要停"
                //     · 「×」   = 像关窗一样自然，适合"看一眼就觉得不对"
                //   两者写的是**同一个取消标记**（_cancelFile），行为必然一致 ——
                //   绝不能出现"点这个停、点那个不停"。
                //
                // 【为什么不用系统标题栏自带的叉号】
                //   这张卡片是 WindowStyle=None + 自绘圆角阴影。套上标题栏会变成
                //   另一个视觉风格，而且拖动是自己算坐标实现的，换标题栏会把那套废掉。
                //
                // 【点击语义（用户 定）】
                //   · 还能停的阶段       → 立刻停（DSH 不动）
                //   · 正在关 DSH         → 记下"要停"，这一步做完就停（排队生效）
                //   · 已关掉、在拉起重试 → 做完当前这次尝试就不再重试
                //   这些全靠 cancel.flag 传递，助手每轮都查它。
                // ══════════════════════════════════════════════════════════════
                _close = new Button
                {
                    Content = "✕",
                    FontSize = 12,
                    Width = 22,
                    Height = 22,
                    Padding = new Thickness(0),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 6, 8, 0),
                    Cursor = Cursors.Hand,
                    BorderThickness = new Thickness(0),
                    ToolTip = "关掉这个窗口；如果重启还在进行，会同时要求它停止"
                };
                // ⚠️⚠️ 颜色**必须**在触发器里给"肯定值"，而且两个状态都要给。
                //
                // 【2026-10-23 实测抓到的两个 bug，别改回去】
                //   ① 第一版的条件写的是 `IsMouseOver = false` —— 本意是"平时"，
                //      但 WPF 的 Trigger 是**条件成立才应用**，鼠标一移上去它就不成立了，
                //      于是前景色**没有被设值** → 落到按钮默认色（深色主题的深灰）。
                //      结果实测对比度只有 **1.68:1**（标准 3.0 起），用户一眼就说
                //      "叉号好像没跟随夜间模式" —— 他不是看错，是真几乎看不见。
                //   ② 底色设了 Transparent、模板 Border 又绑到 Button.Background，
                //      于是"透明底 + 深灰字"，在暗色卡片上彻底糊成一团。
                //
                //   ⇒ 正确做法（照抄 _abort 的成功经验）：
                //      用 **IsMouseOver = true / false 两个触发器各给一套完整颜色**，
                //      保证任何时候都有确定的前景/背景色。
                //
                // 【对比度预算】暗色卡片 RGB(21,21,23)，亮度约 21：
                //      前景取 (0xCC,0xCC,0xD0) → 亮度约 204 → 对比度约 7.4:1 ✅
                //      悬停取 (0xFF,0xFF,0xFF) → 对比度约 11:1 ✅
                //   亮色卡片 RGB(251,251,253)，亮度约 251：
                //      前景取 (0x66,0x66,0x6A) → 对比度约 5.6:1 ✅（不会被浅底吃掉）
                {
                    var closeTemplate = new ControlTemplate(typeof(Button));
                    var cbdr = new FrameworkElementFactory(typeof(Border));
                    cbdr.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
                    cbdr.SetValue(Border.BackgroundProperty,
                        new TemplateBindingExtension(Button.BackgroundProperty));
                    var ctxt = new FrameworkElementFactory(typeof(ContentPresenter));
                    ctxt.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
                    ctxt.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
                    cbdr.AppendChild(ctxt);
                    closeTemplate.VisualTree = cbdr;

                    // ── 平时（鼠标不在上面）：本身就清楚，不是"等悬停才看得见" ──
                    //
                    // ⚠️ 亮色那档吃过一次回头账（2026-10-23）：第一版取 0x66/0x66/0x6A
                    //    （亮度 102）配亮色卡片底（亮度 251）→ 对比度只有 **2.45:1**，
                    //    低于图形线 3.0。改成 0x44 后是 3.67:1。
                    //    暗色那档 0xCC 配亮度 43 的底 = 4.75:1，够。
                    var ctNormal = new Trigger { Property = UIElement.IsMouseOverProperty, Value = false };
                    ctNormal.Setters.Add(new Setter(Button.ForegroundProperty,
                        new SolidColorBrush(dark ? Color.FromRgb(0xCC, 0xCC, 0xD0) : Color.FromRgb(0x44, 0x44, 0x48))));
                    ctNormal.Setters.Add(new Setter(Button.BackgroundProperty, Brushes.Transparent));
                    // ── 悬停：更亮 + 一点点底色，让"能点"这件事看得见 ──
                    var ctHover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
                    ctHover.Setters.Add(new Setter(Button.ForegroundProperty,
                        new SolidColorBrush(dark ? Color.FromRgb(0xFF, 0xFF, 0xFF) : Color.FromRgb(0x1A, 0x1A, 0x1C))));
                    ctHover.Setters.Add(new Setter(Button.BackgroundProperty,
                        new SolidColorBrush(dark ? Color.FromRgb(0x3A, 0x3A, 0x3D) : Color.FromRgb(0xE8, 0xE8, 0xEA))));
                    closeTemplate.Triggers.Add(ctNormal);
                    closeTemplate.Triggers.Add(ctHover);
                    _close.Template = closeTemplate;
                }
                _close.Click += (s, e) =>
                {
                    try
                    {
                        // 写取消标记（与「打断」同一条路）。没有标记路径就只关窗。
                        if (!string.IsNullOrEmpty(_cancelFile))
                        {
                            try { System.IO.File.WriteAllText(_cancelFile, "closed at " + DateTime.Now.ToString("o") + "\n"); } catch { }
                        }
                        // ══════════════════════════════════════════════════════
                        // ⚠️ 这里**不要调 Close()**，因为它会让 UI 线程白卡 2 秒。
                        //
                        // 【实测事实（2026-10-23，别凭印象改）】
                        //   我们此刻就在窗口**自己的 UI 线程**上（这是 Click 处理器）。
                        //   Close() 的实现里有 `_thread.Join(2000)`。
                        //   线程 Join 自己**不会抛异常、也不会死锁** —— 实测它
                        //   **等满 2000ms 超时后返回 False**（跑了一次计时：2011ms）。
                        //   也就是说老写法能用，只是"点一下 ✕ → 窗口卡住 2 秒"。
                        //
                        //   我一开始误判成"永久卡死、_isUp 永远执行不到"，
                        //   后来实测证伪 —— 它是慢，不是死。这里按事实写。
                        //
                        // 【为什么还是要改】点关闭让界面白卡 2 秒，用户体感就是"点了没反应"，
                        //   而这段时间窗口正在消失 —— 很怪。改成只**请求**关闭 + 立刻置位
                        //   `_isUp`，人手点下去是即时的；线程回收交给外部 Close() 做。
                        // ══════════════════════════════════════════════════════
                        try { if (_win != null) _win.Close(); } catch { }
                        _isUp = false;
                        // 顺手把"点了要停止"显示出来：窗口若还没来得及消失，
                        // 用户能看到自己那一按生效了，而不是"点了没反应"。
                        try
                        {
                            _stage.Text = "已要求停止";
                            _stage.Foreground = new SolidColorBrush(Color.FromRgb(0x76, 0x76, 0x76));
                        }
                        catch { }
                    }
                    catch { }
                };

                // ★ 2026-10-23：卡片内容改成 Grid —— stack 铺满，× 叠在右上角。
                //
                // ⚠️ 不能直接把 _close 塞进 stack：stack 是竖向排列的，
                //    塞进去会变成"文字下面的第 6 行"，不是右上角。
                //    要做到"浮在文字上方、贴右上角"，必须用 Grid 叠加。
                //
                // ★★ 2026-10-23 深夜：stack 外面再套一层 ScrollViewer（修 window-extreme 越界）
                //
                // 【为什么需要它 —— 是我自己套 WindowChrome 时压出来的退化】
                //   `window-extreme` 拿实机那条 1028 字的 reason 撑窗口时，
                //   底边报 1052 vs 屏幕下沿 1019（**越出 33 像素**）。
                //   量了才明白：套上 WindowChrome 之后，窗口比"内容高度"多了
                //   一条标题栏（CaptionHeight=40）和一圈阴影留白，
                //   于是原来刚好塞得下的长内容现在塞不下了。
                //   实测：逻辑高 661.2，屏幕逻辑高 679.3 →
                //   `top = 679.3 - 661.2 - 24 = -5.9` → 被夹到 margin=40 →
                //   底边 = 60 + 992 = 1052，溢出 33。
                //
                // 【为什么用 ScrollViewer 而不是"把内容截断"】
                //   reason 是给人看的关键信息（为什么这趟重启卡住了），截掉就等于藏证据。
                //   加滚动条：窗口永远塞得进屏幕，长内容自己滚 —— 信息一条不少。
                //   ⚠️ `_close` **不**放进去（它要一直浮在右上角，不能跟着滚）。
                var scroll = new ScrollViewer
                {
                    Content = stack,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    // 滚动条别把内容挤窄（Auto 时只在需要时出现）
                    Padding = new Thickness(0)
                };
                var cardRoot = new Grid();
                cardRoot.Children.Add(scroll);
                // × 保留一点上边距，压在标题行右侧；它只有 22×22，不会挡住正文。
                _close.Margin = new Thickness(0, 8, 10, 0);
                cardRoot.Children.Add(_close);
                // 给标题留出右侧空间，免得长标题钻到 × 底下看不清
                _title.Margin = new Thickness(0, 0, 26, 0);

                _card = new Border
                {
                    Background = new SolidColorBrush(colCard),
                    BorderBrush = new SolidColorBrush(colBorder),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Child = cardRoot,
                    Effect = new DropShadowEffect
                    {
                        Color = Colors.Black,
                        BlurRadius = 16,
                        ShadowDepth = 2,
                        Opacity = dark ? 0.45 : 0.16
                    }
                };

                // ══════════════════════════════════════════════════════════════
                // 【2026-10-23 下午】**让它像一个正常的窗口**（用户报：「还就是鼠标放到
                //   所有地方都显示那个可移动的效果，它不能像一个正常的窗口一样吗」）
                //
                // 【以前怪在哪（读代码确认过的九条）】
                //   ① `_card.Cursor = Cursors.SizeAll` —— 光标设在**整张卡片**这个容器上，
                //      里面的文字会继承它 → 鼠标放到任何地方都是四向箭头；
                //   ② 拖动事件也挂在**整张卡片**上 → 整张卡都能拖（正常窗口只有标题栏能拖）；
                //   ③ `WindowStyle = None` 且没有 WindowChrome → 系统完全不认它是普通窗口：
                //      没有标题栏、Alt+F4 无效、任务栏里找不到（ShowInTaskbar=false 也算一份）、
                //      ResizeMode=NoResize 不能拉边框；
                //   ④ 卡片直接当窗口 Content、**没留边距** → BlurRadius=16 的阴影被窗口矩形
                //      硬裁掉，看起来是"硬切边"而不是柔和阴影。
                //
                // 【修法：套 WindowChrome，而不是改成 WindowStyle=Normal】
                //   为什么不用 Normal：那会把圆角/自绘配色/阴影全丢掉，跟 DSH 界面风格不搭
                //   （方案 C，代价最高）。WindowChrome 的作用正是"**保留自绘外观，
                //   但把系统窗口行为接回来**"。
                //
                // ⚠️ 位置要求：**必须在 `_win` 创建之后**挂（它要拿 _win 做参数）。
                //    第一版写在这儿（_win 还没建）会在运行时抛 NullReference，
                //    被 catch 兜住 → 悄悄退回老式整卡拖动 —— 看着"没生效"却不知道为啥。
                //
                // 【实测依据（不凭印象）】独立探针在 150% 缩放下量过 `WM_NCHITTEST`：
                //   · 不加 WindowChrome：距顶 15/40/120/底 8px 全部返回 HTCLIENT；
                //   · 加上之后：距顶 15px、40px → **HTCAPTION**（系统拖动区，
                //     光标自动变"移动"手型、按住就是拖窗口）；距顶 120px → HTCLIENT（普通箭头）。
                //   ⇒ 这正是我们要的"上面一条能拖、正文区是普通光标"。
                //
                // 【CaptionHeight = 40 是怎么定的】不是随手取整：
                //   卡片内边距上 14 + 标题 FontSize 12 ≈ 文字占 14~28；
                //   ✕ 按钮距顶 8、高 22 → 占 8~30。
                //   取 40 把这两样都框进可拖区，同时**不会吃掉**「等待中」那行大字（它在更下面）。
                //
                // 【为什么不设 UseAeroCaptionButtons = true】
                //   我们已经有自己画的 ✕（语义是"关窗 + 请求停止"，和系统 ✕ 的裸关闭不同），
                //   开着系统按钮会出现**两个叉**，而且系统那个不会写取消标记。
                // ══════════════════════════════════════════════════════════════

                // ── 阴影边距（修 ④：以前阴影被窗口矩形硬裁）───────────────
                // 给卡片四边留出 BlurRadius 的量，阴影才画得开。
                // ⚠️ 只加外边距、不动内边距 —— 内容的位置和以前**一模一样**（测试坐标不受影响）。
                _card.Margin = new Thickness(ShadowPad);

                // ══════════════════════════════════════════════════════════════
                // ★ 2026-10-23 下午改：**只有顶部那一条能拖，正文区是普通箭头**
                //
                // 【以前是什么样（用户报的）】「鼠标放到所有地方都显示那个可移动的效果」
                //   因为拖动事件和 SizeAll 光标都挂在 `_card`（整张卡片）上。
                //   正常窗口只有标题栏能拖、正文区是普通箭头 —— 这就是"怪"的来源之一。
                //
                // 【现在的两条路】
                //   · **WindowChrome 挂上了**（正常情况）→ 拖动交给系统（CaptionHeight=40 那条
                //     自动是 HTCAPTION），我们**不再自己接管鼠标**，也不设 SizeAll。
                //     ⇒ 光标由系统给：标题条是"移动"手型、正文是箭头，和任何正常窗口一样。
                //   · **WindowChrome 没挂上**（极少数，见上面的 catch）→ 退回老办法（整卡可拖）。
                //     宁可"有点怪但能用"，也不能"拖不动"。
                //
                // ⚠️ 为什么保留下面这套自己算坐标的实现：兜底 + 老路径。
                //    历史上 WPF 自带的 `Window.DragMove()` **偶尔完全不生效**
                //    （实测 DRAG_HIT_OURS=True 但 DRAG_DELTA=0,0，异常还被吞掉），
                //    所以兜底这条路**不能**改成 DragMove()。
                // ══════════════════════════════════════════════════════════════
                _card.MouseLeftButtonDown += (s, e) =>
                {
                    try
                    {
                        if (e.ChangedButton != MouseButton.Left) return;
                        // ★ 挂了 WindowChrome：拖动归系统管，这里**什么都别做**。
                        //   （系统已经把顶部 40px 当标题栏，我们再去 CaptureMouse 会打架。）
                        if (_chromeOk) return;
                        _downCount++;
                        _grabPoint = e.GetPosition(_card);   // 物理换算要用的相对锚点
                        _dragging = true;
                        _card.CaptureMouse();
                        e.Handled = true;
                    }
                    catch { }
                };
                _card.MouseMove += (s, e) =>
                {
                    try
                    {
                        if (!_dragging) return;
                        _moveCount++;
                        double sc = GetWindowScale();
                        var phys = _card.PointToScreen(e.GetPosition(_card));   // 光标屏幕物理像素
                        _win.Left = phys.X / sc - _grabPoint.X;
                        _win.Top = phys.Y / sc - _grabPoint.Y;
                    }
                    catch { }
                };
                _card.MouseLeftButtonUp += (s, e) =>
                {
                    try
                    {
                        if (e.ChangedButton != MouseButton.Left) return;
                        _upCount++;
                        _dragging = false;
                        // ★ 用户挪过窗口了 → 之后**不再自动贴右下角**（只兜底"别越出屏幕"）。
                        //   否则他刚拖到顺手的位置，下一次内容更新就被拽回去。
                        if (_moveCount > 0) _userMoved = true;
                        _card.ReleaseMouseCapture();
                    }
                    catch { }
                };
                // 鼠标被别人抢走（比如按了 Alt+Tab）也要收手，否则窗口会黏着光标跑
                _card.LostMouseCapture += (s, e) => { try { _dragging = false; } catch { } };

                // ══════════════════════════════════════════════════════════════
                // ★ 2026-10-23 下午：**这一行就是"到处都是四向箭头"的病根**
                //
                //   原来无条件写 `_card.Cursor = Cursors.SizeAll`（十字箭头 = 暗示"这里可以拖"）。
                //   但 Cursor 是**可继承**属性：设在整张卡片上，里面的标题/正文/ETA 全继承它
                //   → 鼠标放到窗口任何地方都是四向箭头。正常窗口只有标题栏是那个样子。
                //
                //   现在：**挂了 WindowChrome 就不设它** —— 光标交给系统按区域给
                //   （标题条 = 移动手型，正文 = 箭头），跟任何正常窗口一致。
                //   只有兜底路径（没挂上）才保留整卡可拖的暗示，免得"连拖不拖得动都看不出来"。
                // ══════════════════════════════════════════════════════════════
                if (!_chromeOk) { _card.Cursor = Cursors.SizeAll; }

                // ── 窗口本体 ────────────────────────────────────────────────
                _win = new Window
                {
                    // ★ 2026-10-11：这个 Title 是**系统认的窗口标题**（任务栏/枚举工具看到的就是它）。
                    //   原来写死成 "DSH 自我重启"，于是自测画窗口时，
                    //   从标题根本看不出"这是测试" —— 两个窗口一起冒出来会让人以为 DSH 出事了。
                    //   现在跟着传进来的 title 走（自测时宿主会传带【测试】前缀的那句）。
                    Title = string.IsNullOrEmpty(title) ? "DSH 自我重启" : title,
                    Content = _card,
                    Width = 440,
                    SizeToContent = SizeToContent.Height,
                    WindowStyle = WindowStyle.None,        // 去掉老式标题栏 → 现代扁平外观
                    AllowsTransparency = true,             // 配合 None 才能做圆角+阴影
                    Background = Brushes.Transparent,
                    ResizeMode = ResizeMode.CanResize,     // ★ 2026-10-23：像正常窗口一样能拉边框
                    ShowInTaskbar = true,                  // ★ 2026-10-23：任务栏里能找到它
                    Topmost = true,                        // ★ 前 10 秒置顶，之后由定时器放下来（见下）
                    ShowActivated = false,                 // ★ 显示时不抢焦点
                    WindowStartupLocation = WindowStartupLocation.Manual
                };
                _win.FontFamily = new FontFamily("Microsoft YaHei UI, Segoe UI, Microsoft YaHei");

                // ── 挂 WindowChrome（必须在 _win 创建之后）─────────────────────
                try
                {
                    var chrome = new System.Windows.Shell.WindowChrome
                    {
                        CaptionHeight = CaptionHeightPx,
                        // 边框可拉伸：留 4（逻辑单位）。设 0 就完全不可拉；
                        // 留一点是为了"像正常窗口"，又不会让窄卡片误触到底边。
                        ResizeBorderThickness = new Thickness(4),
                        GlassFrameThickness = new Thickness(0),
                        UseAeroCaptionButtons = false,
                        CornerRadius = new CornerRadius(8)
                    };
                    System.Windows.Shell.WindowChrome.SetWindowChrome(_win, chrome);
                }
                catch (Exception ex)
                {
                    // ⚠️ 窗口只许帮忙、不许坏事：WindowChrome 挂不上就退化成老样子（还能用），
                    //    但要把原因留下来 —— 别再用静默 catch 害排查只能靠猜。
                    LastError = "WindowChrome 挂载失败（退回老式整卡拖动）：" + ex.GetType().Name + ": " + ex.Message;
                    _chromeOk = false;
                    try { _card.Cursor = Cursors.SizeAll; } catch { }
                }

                // ══════════════════════════════════════════════════════════════
                // ★ 2026-10-23 下午：**让 Alt+F4 / 点 ✕ 也走同一套语义**
                //
                // 【以前】窗口是 WindowStyle=None 且没接管 Closing：
                //   Alt+F4 **完全没用**（用户试过），只有我们自己画的 ✕ 能关。
                //   换上 WindowChrome 之后 Alt+F4 会真的发关闭请求了 —— 但那还不够：
                //   直接关掉 = **取消标记不会被写**，助手会以为窗口还好好的、继续等或继续重启。
                //
                // 【现在】拦下 Closing，先写取消标记（和 ✕ / 「打断」同一条路），再放行。
                //   这样"任何方式关掉这张卡片"都等于"要求停止"，语义统一，
                //   不会出现"点 ✕ 会停、按 Alt+F4 不停"这种自相矛盾。
                //
                // ⚠️ 为什么能拦：WPF 的 `Window.Closing` 可以在 `Cancel` 上做手脚；
                //   我们这里**不取消**（窗口该关就关），只做副作用。
                // ⚠️ 别在这里调 `Close()`（会递归）。这是已经要关的时候。
                // ══════════════════════════════════════════════════════════════
                _win.Closing += (s3, e3) =>
                {
                    try
                    {
                        if (!string.IsNullOrEmpty(_cancelFile))
                        {
                            try
                            {
                                System.IO.File.WriteAllText(
                                    _cancelFile,
                                    "closed via window chrome at " + DateTime.Now.ToString("o") + "\n");
                            }
                            catch { }
                        }
                    }
                    catch { }
                };

                // ── 置顶：前 10 秒置顶，之后放下来（用户 定）────────────
                //
                // 【为什么这么定】
                //   · 一直置顶 = 永远压在别人上面，这正是他觉得"怪"的一份（正常窗口不这样）；
                //   · 完全不置顶 = 重启开始后卡片可能被别的窗口挡住，就看不到「打断」按钮了；
                //   ⇒ 折中：**刚弹出来的那 10 秒**保证你看得见（那时也是最该看的时候），
                //     之后老实让位。10 秒后窗口**不会消失**，只是不再抢着盖别人。
                //
                // ⚠️ 用 DispatcherTimer 而不是 Thread.Sleep：这是 UI 线程上的事，
                //    Sleep 会把整个窗口卡住（那样连"放下来"都做不到了）。
                // ⚠️ 日志走 LastError 那条路（C# 类里没有 PowerShell 的日志函数，
                //    第一版直接写了 Write-RestartWindowLog(...) —— 那是 PS 函数，C# 里编译不过）。
                try
                {
                    _topmostTimer = new System.Windows.Threading.DispatcherTimer();
                    _topmostTimer.Interval = TimeSpan.FromSeconds(TopmostSeconds);
                    _topmostTimer.Tick += (s2, e2) =>
                    {
                        try
                        {
                            _topmostTimer.Stop();
                            if (_win != null) _win.Topmost = false;
                            TopmostDropped = true;
                        }
                        catch { }
                    };
                    _topmostTimer.Start();
                }
                catch { /* 定时器起不来就保持一直置顶（安全方向：至少看得见） */ }

                // 摆到工作区右下角（避开任务栏）。
                //
                // ⚠️⚠️ 这里有个**踩过的坑**（2026-10-10，实测环境是 150% 缩放）：
                //    WPF 的 Left/Top 用的是**设备无关单位**（会随系统缩放变），
                //    而 `SystemParameters.WorkArea` 在这个环境里给的是**物理像素**口径
                //    （实测：屏幕物理 1707x1067、缩放 150%，而 WorkArea 报 R=1706.7）
                //    —— 两套口径混用会把窗口算到**屏幕外**：
                //      按 1707 算 Left = 1707-440-40 = 1227（"单位"），
                //      乘上 1.5 缩放 = 物理 1840 > 屏幕宽 1707 → 窗口大半在屏幕右边外面，
                //      看不到、也点不到。
                //    修法：**先拿到本窗口真实的缩放比**，把物理工作区换算成"单位"后再摆。
                //    （旧的 WinForms 版没这问题，因为 WinForms 全程用物理像素。）
                try
                {
                    // 用 WinForms 的屏幕信息（物理像素，最可靠）；拿不到再退回 WPF 的值
                    double physRight, physBottom, scale = 1.0;
                    try
                    {
                        var wfWa = WinForms.Screen.PrimaryScreen.WorkingArea;
                        physRight = wfWa.Right;
                        physBottom = wfWa.Bottom;
                    }
                    catch
                    {
                        Rect wa0 = SystemParameters.WorkArea;
                        physRight = wa0.Right;
                        physBottom = wa0.Bottom;
                    }

                    // 取"物理像素 → 设备无关单位"的缩放比（100%=1.0，150%=1.5）。
                    //
                    // ⚠️ 用一个**隐藏的 1x1 HwndSource** 来问，**不要**靠"先把窗口 Show 出来
                    //    看一眼 DPI 再 Hide"—— 那样做会把 Loaded 事件提前触发掉，
                    //    宿主那边的"启动成功"等待会跟真实的显示时序错开（实测踩到过：
                    //    窗口明明在建，宿主却报 SHOW=False）。隐藏探测窗口干净、无副作用。
                    try
                    {
                        var probeParams = new HwndSourceParameters("dshRestartDpiProbe");
                        probeParams.Width = 1;
                        probeParams.Height = 1;
                        probeParams.WindowStyle = 0;   // 不显示
                        using (var probe = new HwndSource(probeParams))
                        {
                            var m = probe.CompositionTarget.TransformToDevice;
                            if (m != null && m.M11 > 0) scale = m.M11;
                        }
                    }
                    catch { }

                    double logicalRight = physRight / scale;
                    double logicalBottom = physBottom / scale;
                    // 屏幕工作区的逻辑尺寸（算"能不能放得下"要用它，见 KeepOnScreen）
                    _screenLogicalW = logicalRight;
                    _screenLogicalH = logicalBottom;

                    _win.Left = logicalRight - _win.Width - 40;
                    _win.Top = logicalBottom - 170 - 110;

                    // ⚠️ 仅测试用：允许把窗口挪到别处，免得**两套测试的窗口都摆在
                    //    右下角同一个位置**而互相盖住（实测踩过：一套的窗口盖在另一套上，
                    //    拖动/点击落到别人身上，报出一堆莫名其妙的假红）。
                    //    产品流程不会设这个变量。取值：''（默认右下角）| 'topleft'
                    try
                    {
                        string pos = Environment.GetEnvironmentVariable("DSH_RW_TEST_POS");
                        if (pos == "topleft")
                        {
                            _win.Left = 40;
                            _win.Top = 40;
                        }
                        else if (pos == "topright")
                        {
                            _win.Left = logicalRight - _win.Width - 40;
                            _win.Top = 40;
                        }
                    }
                    catch { }

                    // 兜底：万一还是落到屏幕外（或负坐标），贴到左上角去，保证看得见
                    if (_win.Left < 0 || _win.Left > logicalRight - 100) _win.Left = 40;
                    if (_win.Top < 0 || _win.Top > logicalBottom - 100) _win.Top = 60;
                }
                catch
                {
                    try { _win.Left = 60; _win.Top = 60; } catch { }
                }

                _win.Loaded += (s, e) =>
                {
                    // ★ 记下 **Loaded 时刻**的高度 —— 这是"首屏是否已经填好"的**唯一可靠判据**。
                    //
                    //   为什么要专门记 Loaded 这一刻（两个坑逼出来的，值得看完）：
                    //     ① 在**外面**量不行：`Start()` 返回时窗口已经显示，外部测试第一次量到的
                    //        往往已经是最终高度 —— 把 Start 改回老写法，测试照样绿（假绿）。
                    //     ② 用 `ContentRendered` 也不行：实测老写法下它记到的仍是**最终**高度
                    //        （409.2）。原因是 `Set()` 走 `Dispatcher.BeginInvoke(Normal)`，
                    //        而渲染优先级更低，于是**内容更新先于首次渲染被处理** ——
                    //        窗口根本没在"矮"的状态下渲染过，ContentRendered 就量不出来了。
                    //     ⇒ `Loaded` 在 `Start()` 返回**之前**触发，而老写法的 `Set()` 是在
                    //        `Start()` 返回**之后**才调 —— 两者顺序天然错开，所以只有
                    //        Loaded 这一刻能如实区分"内容是在显示前填好的、还是显示后才补的"。
                    try
                    {
                        LoadedHeight = _win.ActualHeight;
                        LoadedDetailChars = _detail == null ? 0 : (_detail.Text ?? "").Length;
                    }
                    catch { }
                    lock (_ready) { _isUp = true; Monitor.PulseAll(_ready); }
                };

                // ★★ 2026-10-13：**记下"首次排完版"时的高度** —— 给"不蹦"这条判据留证据。
                //
                //   为什么需要（这正是一条**测不出来**的坑）：
                //     我原先写的首屏回归测试，是在 `Start()` 返回之后才第一次量窗口 ——
                //     而那已经太晚了：老写法的 `Set()` 在 Start 返回后立刻执行，
                //     等测试去量的时候它早就是最终高度了。**改坏也不会报红 = 假绿。**
                //     （我实测过：把 Start 改回不带首屏内容，那条测试照样 3/3 通过。）
                //   正确做法：在**窗口自己**记录"第一次排版完成"的高度与时刻。
                //     判据变成：ContentRendered（首次渲染）时的高度 是否等于 最终高度。
                //     首屏内容在 Show 之前就填好 → 首次渲染即最终高度 → 差值 0；
                //     老写法 → 首次渲染是矮的 → 差值 = 后填那段文字撑出来的高度。
                _win.ContentRendered += (s, e) =>
                {
                    try
                    {
                        if (FirstPaintHeight <= 0)
                        {
                            FirstPaintHeight = _win.ActualHeight;
                            FirstPaintWidth = _win.ActualWidth;
                        }
                    }
                    catch { }
                };

                // ★★ 2026-10-13：**每次窗口尺寸变化后都贴回屏幕内**（用户报的"展开后有一截看不见"）。
                //
                //   为什么挂在 SizeChanged 上：窗口是 `SizeToContent = Height`，
                //   **内容一变长窗口就自己往下/往上长**；只有"长完之后"才知道真实高度，
                //   所以在这个事件里按**实际高度**重算位置。
                //
                //   为什么不在别处补一次就行：内容长度是动态的（阶段文案、耗时、原因都会变），
                //   任何一次性修正都只是碰运气。挂在这里 = **每次变化都重新贴边**。
                //
                //   ⚠️ 拖动之后不要再自动摆位！否则用户刚拖到顺手的位置，
                //      下一次内容更新就被拽回右下角 —— 那是帮倒忙。
                //      所以一旦用户拖过（_userMoved = true），这里就只做"别越出屏幕"的兜底。
                _win.SizeChanged += (s, e) =>
                {
                    try
                    {
                        KeepOnScreen();
                    }
                    catch { }
                };

                _win.Show();

                // 首帧之后再贴一次：SizeChanged 有时在首帧前就触发了，
                // 那时 ActualHeight 还是 0（拿不到真实高度），这里补一发。
                _win.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
                {
                    try { KeepOnScreen(); } catch { }
                }));

                // ★ 这个线程从此只跑界面循环 —— 它永远在，所以窗口永远响应。
                Dispatcher.Run();
            }
            catch (Exception ex)
            {
                // ⚠️ 别把异常吞掉：上次就是"静默失败"，害得排查时只能靠猜。
                //    把消息留下来，宿主会写进日志。
                LastError = ex.GetType().Name + ": " + ex.Message;
                lock (_ready) { _isUp = false; Monitor.PulseAll(_ready); }
            }
        });
        _thread.SetApartmentState(ApartmentState.STA);   // WPF 要求 STA
        _thread.IsBackground = true;                     // 别让窗口线程拖住进程退出
        _thread.Start();

        lock (_ready) { if (!_isUp) Monitor.Wait(_ready, 6000); }
        return _isUp;
    }

    /// <summary>把改界面的动作投递到窗口线程去执行（宿主线程绝不直接碰控件）。</summary>
    private void Ui(Action a)
    {
        try
        {
            if (_win == null) return;
            _win.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a);
        }
        catch { }
    }

    public void Set(string stage, string detail, string eta, string colorHex)
    {
        Ui(() =>
        {
            try
            {
                if (stage != null) _stage.Text = stage;
                if (colorHex != null)
                {
                    try { _stage.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colorHex)); }
                    catch { }
                }
                if (detail != null) _detail.Text = detail;
                if (eta != null) _eta.Text = eta;
            }
            catch { }
        });
    }

    public void HideWindow() { Ui(() => { try { _win.Hide(); } catch { } }); }

    /// <summary>
    /// 「打断」按钮中心点的**屏幕物理坐标**（"x,y"）。给自动化验收用。
    ///
    /// 为什么要暴露这个：早期验收靠"猜按钮在哪"（按边距估算），屡次点歪，
    /// 还误判成"按钮点不动"。让窗口自己报坐标，测试就不会猜错。
    ///
    /// ⚠️ `Visual.PointToScreen` 返回的**已经是物理像素**（.NET 文档：
    ///    "screen coordinates"），所以**不要再乘缩放比**！
    ///    第一版乘了一次 → 150% 缩放下报出 2760（真实 1840），
    ///    测试照着点就点到了屏幕外，又白折腾一轮。踩过，记下。
    /// </summary>
    public string AbortButtonCenter()
    {
        string s = "";
        try
        {
            _win.Dispatcher.Invoke(new Action(() =>
            {
                try
                {
                    var p = _abort.PointToScreen(new Point(_abort.ActualWidth / 2, _abort.ActualHeight / 2));
                    s = ((int)Math.Round(p.X)) + "," + ((int)Math.Round(p.Y));
                }
                catch { }
            }));
        }
        catch { }
        return s;
    }

    /// <summary>窗口左上角的屏幕物理坐标（"x,y"），给验收用（同上，已经是物理像素）。</summary>
    public string WindowTopLeft()
    {
        string s = "";
        try
        {
            _win.Dispatcher.Invoke(new Action(() =>
            {
                try
                {
                    var p = _win.PointToScreen(new Point(0, 0));
                    s = ((int)Math.Round(p.X)) + "," + ((int)Math.Round(p.Y));
                }
                catch { }
            }));
        }
        catch { }
        return s;
    }

    /// <summary>
    /// 窗口在屏幕上的**物理像素**矩形："left,top,right,bottom"（拿不到时返回空串）。
    ///
    /// 为什么要有它（2026-10-13）：用户报"展开后会有一部分到屏幕外被挡到看不见"。
    /// 要验"有没有越界"，就必须能**量出真实坐标**——靠读代码推断是验不出这种问题的
    /// （第一版窗口就是因为只看了代码、没量坐标，才把窗口摆到了屏幕外）。
    /// 用物理像素返回，调用方不必再操心 150% 缩放的单位换算。
    /// </summary>
    public string WindowRect()
    {
        string s = "";
        try
        {
            _win.Dispatcher.Invoke(new Action(() =>
            {
                try
                {
                    var tl = _win.PointToScreen(new Point(0, 0));
                    var br = _win.PointToScreen(new Point(_win.ActualWidth, _win.ActualHeight));
                    s = ((int)Math.Round(tl.X)) + "," + ((int)Math.Round(tl.Y)) + ","
                      + ((int)Math.Round(br.X)) + "," + ((int)Math.Round(br.Y));
                }
                catch { }
            }));
        }
        catch { }
        return s;
    }

    public void Close()
    {
        Ui(() => { try { _win.Close(); } catch { } });
        try { if (_thread != null) _thread.Join(2000); } catch { }
        _isUp = false;
    }
}
'@ -ErrorAction Stop

    $script:DshRwTypeReady = $true
    return $true
  } catch {
    # 极少数环境下 WPF 不可用（如无桌面会话）—— 静默失败，重启照做
    return $false
  }
}

# ── 状态窗的"人话"文案 ─────────────────────────────────────────────────────
# 这里一律用非技术的词，不出现 idleSeconds / runningSessions 之类。
function Get-DshRwStageText {
  param([string]$Stage)
  switch ($Stage) {
    'waiting'   { return '等待中' }
    'ready'     { return '准备动手' }
    'closing'   { return '正在关闭 DSH' }
    'closed'    { return 'DSH 已关闭' }
    'starting'  { return '正在重新打开' }
    'done'      { return '✅ 重启完成' }
    'failed'    { return '❌ 没能完成' }
    'cancelled' { return '已取消' }
    default     { return '进行中' }
  }
}

function Get-DshRwStageColor {
  param([string]$Stage)
  switch ($Stage) {
    'waiting'   { return '#0067C0' }   # 蓝：在等
    'ready'     { return '#C87800' }   # 橙：要动手了
    'closing'   { return '#C87800' }
    'closed'    { return '#C87800' }
    'starting'  { return '#C87800' }
    'done'      { return '#0F7B33' }   # 绿：成了
    'failed'    { return '#C42B1C' }   # 红：没成
    'cancelled' { return '#767676' }   # 灰：取消
    default     { return '#0067C0' }
  }
}

# ── 窗体句柄（挂脚本级变量，方便全脚本读写）────────────────────────────────
$script:DshRw = $null

function Show-RestartWindow {
  param(
    [int]$Port = 19387,
    [string]$Reason = '',
    [string]$LogFile = '',
    # 「打断」按钮要写的取消标记文件（和 restart_status(cancel=true) 用的是同一个）
    [string]$CancelFile = '',
    # ★ 2026-10-24：「不等了，立刻重启」按钮要写的放行标记文件（助手看到就跳过"等家务"）
    [string]$ForceFile = ''
  )
  if (-not (Initialize-DshRwType)) {
    # 窗口不可用不是错误 —— 退化成"没有窗口的静默重启"（老行为）
    return $false
  }
  try {
    # 记日志用（模块自己写，不依赖主脚本的 Write-Log）
    if ($LogFile) { $script:DshRwLog = $LogFile }
    if ($script:DshRw -and $script:DshRw.IsUp) { return $true }

    $win = New-Object DshRestartStatusWindow
    # ★★ 2026-10-11：窗口标题要能区分"真的在重启"和"自测在画窗口"。
    #
    #   为什么要改（2026-10-11 亲历）：跑全量测试时，
    #   test-restart-window（右下角）和 test-window-contrast（左上角）挨着跑，
    #   **屏幕上会同时出现两个**标题写着「DSH 正在自我重启」、
    #   内容写着「正在关闭 DSH」的窗口 —— 而 DSH **根本没在重启**，是测试画的假窗口。
    #   这种"测试让人以为出事了"是**不可接受**的。
    #
    #   为什么不能干脆不显示：这两套测试要验的正是"窗口可见时的行为"——
    #   响应性、不抢焦点、真实像素对比度、拖动、点按钮，隐藏了就全测不了。
    #   所以**折中**：测试的窗口标题带一个显眼的 `【测试】` 前缀，
    #   一眼就知道"这不是真重启，是助手在自测"。
    #
    #   判据（两条任一即可，因为测试调用的方式不同）：
    #     ① 计划里带 `isTest=true`  —— 走主脚本的场合
    #     ② 环境变量 `DSH_RW_TEST_MODE=1` —— 直接调 Show-RestartWindow 的测试用这个
    #        （那两套窗口测试是直接点源模块调用的，手里没有计划文件）
    $winTitle = 'DSH 正在自我重启'
    $isTestRun = $false
    if ($Plan -and $Plan.isTest) { $isTestRun = [bool]$Plan.isTest }
    try { if ($env:DSH_RW_TEST_MODE -eq '1') { $isTestRun = $true } } catch { }
    if ($isTestRun) { $winTitle = '【测试】这不是真的在重启（助手在自测窗口）' }

    # ★ 2026-10-13：**首屏内容先算好，再一起交给 Start() 去建窗口**。
    #   原来的顺序是"先 Show 一个空窗口 → 再 Set 内容"，于是窗口先以矮的样子出现、
    #   内容一到就长高 —— 用户看到的就是"闪一下、突然弹出来长一截"。
    #   现在把首屏内容当参数传进去，窗口**第一次出现就是最终尺寸**。
    $firstDetail = '已经收到重启请求，正在等"闲下来"再动手。'
    if ($Reason) { $firstDetail += "`r`n原因：" + $Reason }
    $firstStageText = Get-DshRwStageText -Stage 'waiting'
    $ok = $win.Start($winTitle, $firstStageText, $firstDetail, $null)
    if (-not $ok) {
      $why = ''
      try { $why = [string]$win.LastError } catch { }
      if (-not $why) { $why = '（窗口线程没说原因）' }
      Write-RestartWindowLog ('状态窗启动失败（不影响重启）：' + $why)
      return $false
    }
    $script:DshRw = $win

    # 记下主题（排查"暗色模式为什么没生效"时有用）
    try { Write-RestartWindowLog ('主题：' + $(if ($win.IsDarkTheme) { '暗色' } else { '亮色' })) } catch { }
    Write-RestartWindowLog ('已显示（不抢焦点；按钮 = 打断这次重启；整张卡片可以拖动）')

    # ★ 打断按钮：现在就可点（还在"等待"阶段，DSH 一根汗毛都没动，随时能反悔）
    if ($CancelFile) { $win.ArmAbort($true, $CancelFile) }
    else { $win.ArmAbort($false, '') }

    # ★ 2026-10-24：「不等了」按钮先灰着 —— 只有助手确认"这一轮说完、只剩家务在跑"时才点亮
    if ($ForceFile) { $win.ArmForce($false, $ForceFile) }
    else { $win.ArmForce($false, '') }

    # ★ 2026-10-24：把这个按钮的位置也报出来（日志里有据可查；测试也用得上）
    try { Write-RestartWindowLog ('「不等了」按钮位置：' + $win.ForceButtonCenter()) } catch { }

    return $true
  } catch {
    Write-RestartWindowLog ('状态窗显示失败（不影响重启）：' + $_.Exception.Message)
    return $false
  }
}

# 让「打断」按钮变成不可点（过了"还能反悔"的阶段就调它）
function Disarm-RestartWindowAbort {
  param([string]$Note = '')
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return }
    # 传一个非空 cancelFile 让文案走"来不及"那条
    $script:DshRw.ArmAbort($false, $(if ($Note) { $Note } else { 'already-started' }))
    # ★ 2026-10-24：「不等了」一起禁掉 —— 都开始关了，"跳过等待"就更没意义了
    try { $script:DshRw.ArmForce($false, 'already-started') } catch { }
  } catch { }
}

# ★ 2026-10-24 新增：点亮 / 熄灭「不等了，立刻重启」。
#   只在"这一轮说完了、只剩下家务在跑"那一段点亮（宿主负责判断）。
#   按钮本身只写标记文件，真正的"要不要动手"仍由助手那套检查说了算。
function Set-RestartWindowForce {
  param(
    [bool]$Enabled = $false,
    [string]$ForceFile = ''
  )
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return }
    $script:DshRw.ArmForce($Enabled, $ForceFile)
  } catch { }
}

# 给自动化验收用：报出「不等了」按钮中心的屏幕物理坐标（"x,y"）。
function Get-RestartWindowForceButtonPos {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return '' }
    return [string]$script:DshRw.ForceButtonCenter()
  } catch { return '' }
}

# 给自动化验收用：在 UI 线程上真的点一下「不等了」（走和鼠标点击同一条事件链）。
function Invoke-RestartWindowForceClick {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return $false }
    $script:DshRw.ClickForceForTest()
    return $true
  } catch { return $false }
}

# 给自动化验收用：在 UI 线程上真的点一下「打断这次重启」。
function Invoke-RestartWindowAbortClick {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return $false }
    $script:DshRw.ClickAbortForTest()
    return $true
  } catch { return $false }
}

# 给自动化验收用：报出「打断」按钮中心的**屏幕物理坐标**（"x,y"）。
# ⚠️ 只测试会用；产品流程里没人调它。
# ★ 2026-10-23：给自动化验收用——在 UI 线程上真的点一下右上角的 ✕。
# ⚠️ 只测试会用；产品流程里没人调它（用户点的是真鼠标）。
# 返回 $true = 已经把点击事件发出去了（不代表业务结果，业务结果看 cancel 文件）。
function Invoke-RestartWindowCloseClick {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return $false }
    $script:DshRw.ClickCloseForTest()
    return $true
  } catch { return $false }
}

function Get-RestartWindowAbortButtonPos {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return '' }
    return [string]$script:DshRw.AbortButtonCenter()
  } catch { return '' }
}

# 同上：报出窗口左上角的屏幕物理坐标
function Get-RestartWindowTopLeft {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return '' }
    return [string]$script:DshRw.WindowTopLeft()
  } catch { return '' }
}

# 给自动化验收用：报出拖动的诊断计数（"down=N move=M up=K dragging=bool"）。
# ⚠️ 只测试会用；产品流程里没人调它。
# 拖动失败时靠它分清"事件没触发"还是"坐标算错"——两种病的修法完全不同。
function Get-RestartWindowDragDebug {
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return '' }
    return [string]$script:DshRw.DragDebug()
  } catch { return '' }
}

# 自己写日志：窗口模块不依赖主脚本的 Write-Log（免得点源的顺序问题）
function Write-RestartWindowLog {
  param([string]$Text)
  try {
    if ($script:DshRwLog) {
      $line = '{0} [状态窗] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
      [System.IO.File]::AppendAllText($script:DshRwLog, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    }
  } catch { }
}

function Set-RestartWindowStage {
  param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [string]$Detail = '',
    [string]$EtaText = $null
  )
  try {
    if (-not $script:DshRw -or -not $script:DshRw.IsUp) { return }
    $text = Get-DshRwStageText -Stage $Stage
    $color = Get-DshRwStageColor -Stage $Stage
    $script:DshRw.Set($text, $Detail, $EtaText, $color)
  } catch { }
}

# 给"等待中"用的一句话（主脚本每轮循环调它，把"在等什么"说清楚）
function Update-RestartWindowWait {
  param(
    [string]$Detail = '',
    [double]$ElapsedSeconds = 0,
    [double]$MaxWaitMinutes = 5,
    # ★ 2026-10-24：现在只剩家务在跑、卡片上已经有可点的「不等了」时传 true，
    #   把 ETA 那句"会一直等下去"换成"不想等就点那个按钮" —— 否则两句话互相打架。
    [switch]$CanForce
  )
  try {
    # ⚠️ 2026-10-12 改文案（旧文案有歧义，实测被误读过）：
    #
    #   旧文案：「已等 N 秒　最多再等 M 秒（等不到就放弃，绝不强关）」
    #   实测反馈：看到"M 秒"，会以为**还要倒数 M 秒才动手**。
    #
    #   **这不是看错，是文案本身有歧义** —— "最多再等"里的"最多"两个字
    #   夹在数字前面，很容易被读成"还要等"。而这个窗口是唯一能看到进度的地方，
    #   读错了就等于"给出的信息是错的"。**界面上的字被误解，是界面的问题，不是人的问题。**
    #
    #   新文案把三件事分开写，且明确"不是倒计时"：
    #     · 已等多久      → 过去时
    #     · 在等什么      → 条件是"没动静"，不是"到点"
    #     · 什么情况下放弃 → 上限，并显式声明"不是倒计时"
    $eta = ''
    if ($ElapsedSeconds -gt 0) { $eta = ('已经等了 {0:N0} 秒' -f $ElapsedSeconds) }
    if ($MaxWaitMinutes -gt 0) {
      $left = [Math]::Max(0, ($MaxWaitMinutes * 60) - $ElapsedSeconds)
      # 关键：说清"我们不是在等时间到"，而是"等它安静下来"。
      # 括号里那句显式否认倒计时 —— 就是冲着这次误解加的。
      $eta += ('；要是 {0:N0} 秒内一直安静不下来，就放弃（这不是倒计时，安静了就立刻动手）' -f $left)
    } else {
      $eta += '；会一直等下去（等不到就不动手）'
    }
    if ($CanForce) {
      # 只在"只剩家务"那段加这句：按钮就在下面，文案要和它一致。
      # ⚠️ 这里只提一句"可以点"，完整解释在明细里（明细会换行、放得下）——
      #    两处都写长句会显得啰嗦，而且 ETA 那行本来就窄。
      $eta += '；不想等就点「不等了」'
    }
    Set-RestartWindowStage -Stage 'waiting' -Detail $Detail -EtaText $eta
  } catch { }
}

function Close-RestartWindow {
  param(
    [string]$FinalStage = '',
    [string]$FinalText = '',
    [int]$KeepSeconds = 0
  )
  try {
    if (-not $script:DshRw) { return }
    if ($FinalStage) { Set-RestartWindowStage -Stage $FinalStage -Detail $FinalText -EtaText '' }

    if ($KeepSeconds -gt 0) {
      # 成功/失败都停留一下再自动消失（不然窗口一闪而过，等于没有）
      Start-Sleep -Seconds $KeepSeconds
    }
    $script:DshRw.Close()
    $script:DshRw = $null
  } catch {
    try { $script:DshRw = $null } catch { }
  }
}
