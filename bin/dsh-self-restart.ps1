#requires -Version 5.1
<#
=======================================================================
 dsh-self-restart.ps1 — 把 DSH 关掉，再把它拉起来
=======================================================================
 【为什么必须"脱离进程"】
   这个脚本要亲手杀掉 DSH。如果它是 DSH 的子进程，杀 DSH 时它会被一起
   带走，就没人去把 DSH 拉起来了 —— 那才是真正的"自杀"。
   所以脚本启动后第一件事，是用 WMI 把自己**重新创建一遍**：
   WMI 建的进程父级是系统的 WmiPrvSE，不在 DSH 的进程树里，
   DSH 死了它照样活着。
   （本机已实测：WMI 创建的子进程 ParentProcessId = WmiPrvSE，
     且落在交互式会话 SessionId = 1。）

  【全程不出现黑框】（2026-10-08：早期版本会闪出两个窗口，观感很差）
    建进程时用 Win32_ProcessStartup 的 ShowWindow = 0（SW_HIDE）——
    注意**不能**只靠 `-WindowStyle Hidden`：那是先把控制台窗口建出来再隐藏，屏幕上仍会闪。
    调 taskkill 这类控制台程序也走 Invoke-Quiet（CreateNoWindow = true）。
    实测（test\test-silent-windows.ps1）：整条链路 3 个助手进程，可见窗口数 = 0。

 【三种身份（同一个脚本，靠参数切换）】
   ① 默认        —— 把自己脱离出去，然后立刻退出（只干这一件事）
   ② -Detached   —— 正主：等时间 → 等闲置 → 关 DSH → 拉起 → 验端口
   ③ -Watchdog   —— 保险丝：正主万一在"关掉之后、拉起之前"死掉，
                    它负责把 DSH 拉回来。正主在动手前就把它挂上。

 【正主的顺序】
   ① 挂上保险丝（-Watchdog）
   ② 等到计划时间（plan.scheduleAt）
   ③ 两段式等待（2026-10-08 定下的设计：等这一轮说完，然后去查还有没有别人）
      第一段：**只看发起会话自己**的会话记录 —— 连续 idleSeconds 秒没被写过，
              即视为这一轮说完。这一段*故意*不理会别人，否则自己一边写日志
              一边会让判定永不成立（实测踩过：白等到底）。
      第二段：这一轮说完了，这才去查**别人** —— 三种"忙"要分开：
              · **别的对话/会话**在忙                → **继续等**（2026-10-22 改：不再作废）
              · 只有**后台任务**在跑                  → **等它跑完**
              · **家务子代理**在跑（如某个插件的空闲复审子代理）→ **也是等**（没人在等它，是家务）
      ⚠️ 上面这条"继续等"是 2026-10-22 的**行为变更**（排队重启的核心）：
         老规矩是"别的会话在忙 → 当场放弃、不排队"（触发过 19 次），现在改成排上队一起等。
         代码见第 2347 行起那段 `从"作废"改成"继续等"`。
         ⚠️ 这段文件头注释 2026-10-23 才补对 —— 在它之前，注释还写着"放弃"，
            而代码早就是"等"了。**看注释判断行为会看反**，以代码为准。
              判据来源有两个，**两个都要过滤**（2026-10-08 只在一条路上过滤=没修）：
              a) 插件报的 state.json（runningSessions / runningSubagents）
              b) 本脚本自己扫盘（会话记录文件）+ 读 DSH 的身份档案认子代理
      ⚠️ 等不到 maxWaitMinutes 就**放弃**：DSH 一根汗毛都不动，结果记 skipped-busy，
         **不弹窗**（远程机器没人点），改由对话下一轮自己发现并转告用户。
         **绝不强制重启**（2026-10-08 定下的硬规则：宁可什么都不做，也不砍断正在干的活）
   ④ 关掉 DSH —— 先礼后兵：先 taskkill（不带 /F，请它自己退），
      等一会儿还不走再 /F
   ⑤ 确认进程清干净、端口释放
   ⑥ 把 DSH 重新拉起来（同样用 WMI，落在用户桌面会话）
   ⑦ 盯端口确认真的起来了；没起来就重试，最多 maxAttempts 次
   ⑧ 全程写日志；结果写 last-run.json（DSH 起来后插件会读它）

 【手动用法】（一般不用手动跑，插件会调它）
   powershell -NoProfile -ExecutionPolicy Bypass `
     -File dsh-self-restart.ps1 -PlanFile <计划文件.json>

 【退出码】
   0 = 成功（或已成功脱离）   1 = 失败（已尽力）   2 = 取消 / 计划有问题
=======================================================================
#>
[CmdletBinding()]
param(
  # 插件写下的计划文件（JSON）。所有参数都在里面，脚本自己不去猜。
  [Parameter(Mandatory = $true)][string]$PlanFile,
  # 内部用：标记"本进程已经是脱离出来的那一个了"，防止无限自我复制。
  [switch]$Detached,
  # 内部用：保险丝模式。
  [switch]$Watchdog,
  # ⚠️ 仅自测用：把"要关掉的目标进程名"换掉，这样自测可以在一个假的
  #    "应用"上跑完整的 关→拉 流程，而**绝不会碰到真的 DSH**。
  #    默认就是真 DSH 的进程名；自测脚本会传假名字。
  [string]$TargetProcessName = 'DeepSeek Harness',
  # ⚠️ 仅自测用：给"要关掉的目标"加一个命令行特征过滤（子串）。
  #    留空 = 不带这个过滤。自测用它精确锁定自己造的那个假应用，
  #    即使假应用和真 DSH 同名也不会误伤。
  [string]$TargetCommandMatch = '',
  # ══════════════════════════════════════════════════════════════════════════
  # ★ 2026-10-23 新增：干跑模式（只报告，不动手）
  #
  # 【它解决什么】
  #   这个脚本唯一不可接受的后果是"把真 DSH 关了却拉不起来"，这已经发生三次。
  #   而三次的根源都是同一个盲点：**动手之前，没人能先看见"它准备杀谁"**。
  #   干跑就是那个"先看一眼"的机会：完整走完等待、目标一致性、进程清点，
  #   把「准备关闭 DSH：共 N 个进程，主进程 PID=…（路径=…）」以及
  #   「准备拉起：…」全部打印出来，然后**立刻退出，一个进程都不碰**。
  #
  # 【为什么这比现有测试靠谱】
  #   test-target-guard.ps1 自己的注释写着"只把判断逻辑照抄一份来测"——
  #   照抄的是计算，丢掉的正是**接线**（算出来有没有人用）。
  #   干跑跑的是**真代码真路径**，所以它能验出"那段接线到底通没通"。
  #   2026-10-23 归零排查抓到的就是接线断了，而现有测试全绿。
  #
  # 【安全边界】
  #   · 干跑**不发任何 taskkill、不碰 WMI Create、不删 plan.json**；
  #   · 它在"准备关闭"之后、第一个 taskkill 之前退出；
  #   · 退出码用 0（这是成功完成了一次检查，不是失败）；
  #   · 退出前把结论写成一份 dry-run 报告，方便事后对照。
  # ══════════════════════════════════════════════════════════════════════════
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ── 日志 ────────────────────────────────────────────────────────────────────
$script:LogPath = $null
function Write-Log {
  param([string]$Text)
  $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
  try { Write-Host $line } catch { }
  if ($script:LogPath) {
    try {
      # 无 BOM 的 UTF-8 追加，避免 PS 5.1 把 BOM 反复写进文件中间
      [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    } catch { }
  }
}

# ══════════════════════════════════════════════════════════════════════════
#  外部通知钩子（notice hook）
# ══════════════════════════════════════════════════════════════════════════
#
# 本插件**不内置任何通知渠道**。这里只负责在正确的时机执行使用者自己配置的
# 一条命令（计划文件里的 `noticeCommand`），把事件内容通过环境变量交给它。
#
# 事件（环境变量 DSH_SR_EVENT）：
#   restart-queued-long  等太久还没发车
#   restart-done         重启成功
#   restart-failed       重启失败或被取消
# 正文在 DSH_SR_TEXT；另带 DSH_SR_PLANID 等标量字段。
#
# 【三条硬约束】
#   ① noticeCommand 为空 → 直接跳过，什么都不做（出厂默认就是空）。
#   ② 有超时（noticeTimeoutMs，默认 30 秒），超时就杀掉。
#   ③ **失败绝不影响重启**：整段 try/catch，只写日志。
#
# 【为什么命令走环境变量传参，而不是拼进命令行】
#   拼命令行就要处理引号转义，而文案里出现换行/引号会把命令截断
#   （这类"看起来发了、其实发不出去"的假成功踩过不止一次）。
#   走环境变量没有转义问题：命令原样执行，内容原样读取。

function Invoke-NoticeHook {
  param(
    [string]$Event,
    [string]$Text,
    [hashtable]$Data = @{}
  )

  try {
    $cmd = [string]$noticeCommand
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }   # 没配 = 不通知
    if ([string]::IsNullOrWhiteSpace($Event)) { return $false }

    $timeoutMs = if ($noticeTimeoutMs -gt 0) { [int]$noticeTimeoutMs } else { 30000 }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/c ' + $cmd
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['DSH_SR_EVENT'] = [string]$Event
    $psi.EnvironmentVariables['DSH_SR_TEXT'] = [string]$Text
    foreach ($k in @($Data.Keys)) {
      $v = $Data[$k]
      if ($null -eq $v) { continue }
      $name = 'DSH_SR_' + (([string]$k) -replace '[^A-Za-z0-9_]', '_').ToUpperInvariant()
      $psi.EnvironmentVariables[$name] = [string]$v
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($timeoutMs)) {
      try { $proc.Kill() } catch { }
      Write-Log ('[通知] 命令超时（{0}ms），已终止 —— 不影响重启' -f $timeoutMs)
      return $false
    }
    $out = ''
    try { $out = (([string]$stdoutTask.Result) + ([string]$stderrTask.Result)).Trim() } catch { }

    if ($proc.ExitCode -eq 0) {
      Write-Log ('[通知] 已执行（事件 {0}）' -f $Event)
      return $true
    }
    $tail = if ($out.Length -gt 200) { $out.Substring(0, 200) } else { $out }
    Write-Log ('[通知] 命令返回非零（{0}）：{1} —— 不影响重启' -f $proc.ExitCode, $tail)
    return $false
  } catch {
    Write-Log ('[通知] 执行时出异常（不影响重启）：{0}' -f $_.Exception.Message)
    return $false
  }
}

# ── 等太久还没发车 → 通知（同一趟最多一次，除非配了 notifyRepeat）────────────
function Send-WaitReminderIfDue {
  param(
    [double]$ElapsedMinutes,
    [string[]]$HardReasons
  )

  try {
    if ($notifyAfterMinutes -le 0) { return $false }         # 0 = 不提醒
    if ($ElapsedMinutes -lt $notifyAfterMinutes) { return $false }

    # 已经提醒过？看间隔决定要不要再提醒
    $prev = Read-JsonFile -Path $notifyStateFile
    if ($prev -and $prev.lastSentAt) {
      if (-not $notifyRepeat) { return $false }
      $last = [datetime]::MinValue
      try { $last = [datetime]::Parse([string]$prev.lastSentAt) } catch { }
      if (($last -ne [datetime]::MinValue) -and ((Get-Date) - $last).TotalMinutes -lt $notifyRepeatMinutes) {
        return $false
      }
    }

    $who = if ($script:Members.Count -gt 1) { "这趟车有 $($script:Members.Count) 个会话在等" } else { '有一个会话在等' }
    $why = if ($HardReasons -and $HardReasons.Count -gt 0) { $HardReasons -join '；' } else { '一直有动静' }
    $text = ('重启还在排队：已经等了 {0:N0} 分钟，{1}。挡着的是：{2}。它不会硬闯，会等到都闲下来。' -f $ElapsedMinutes, $who, $why) +
            '想取消就让那个对话调 restart_status(cancel: true)。'

    $ok = Invoke-NoticeHook -Event 'restart-queued-long' -Text $text -Data @{
      planId  = [string]$planId
      elapsed = [math]::Round($ElapsedMinutes, 1)
      reason  = ($HardReasons -join '；')
    }
    if (-not $ok) { return $false }

    try {
      $payload = [ordered]@{
        planId     = [string]$planId
        lastSentAt = (Get-Date).ToString('o')
        elapsedMin = [math]::Round($ElapsedMinutes, 1)
      }
      [void](Write-JsonFile -Path $notifyStateFile -Value $payload)
    } catch { }
    return $true
  } catch {
    Write-Log ('[通知] 发等待提醒时出异常（不影响重启）：{0}' -f $_.Exception.Message)
    return $false
  }
}

# ── 重启成功 → 只在"确实发过等待提醒"时补一条，闭合成对（不刷屏）──────────
function Send-SuccessReminderIfNeeded {
  param(
    [double]$TookSeconds,
    [double]$DownToUpSeconds
  )

  try {
    # ① 只有"确实发过等待提醒"才补发。没发过 → 静默跳过（不打扰）。
    $prev = Read-JsonFile -Path $notifyStateFile
    if (-not $prev -or -not $prev.lastSentAt) {
      Write-Log '[通知] 这次没发过"还在排队"提醒 → 成功后也不补发（不打扰）'
      return $false
    }
    # ② 同一趟只补一次（助手可能被重入）
    if ($prev.successSentAt) {
      Write-Log '[通知] 这条成功提醒已经发过了，不重复发'
      return $false
    }

    $whoN = @($script:Members).Count
    $who = if ($whoN -gt 1) { "$whoN 个会话" } else { '那个会话' }
    $waited = if ($TookSeconds -gt 0) { [math]::Round($TookSeconds / 60, 1) } else { 0 }
    $downUp = if ($DownToUpSeconds -gt 0) { [math]::Round($DownToUpSeconds, 1) } else { 0 }
    $text = ('重启成功了。从排上到现在一共 {0} 分钟（其中应用关掉到重新起来的 {1} 秒是真在重启）。' -f $waited, $downUp) +
            ('{0}会被唤醒接着干活，不用手动重开。' -f $who)

    $ok = Invoke-NoticeHook -Event 'restart-done' -Text $text -Data @{
      planId    = [string]$planId
      waitedMin = $waited
      downUpSec = $downUp
      members   = $whoN
    }
    if (-not $ok) { return $false }

    try {
      $payload = [ordered]@{
        planId          = [string]$planId
        lastSentAt      = [string]$prev.lastSentAt
        elapsedMin      = $prev.elapsedMin
        successSentAt   = (Get-Date).ToString('o')
        tookSeconds     = [math]::Round($TookSeconds, 1)
        downToUpSeconds = [math]::Round($DownToUpSeconds, 1)
      }
      [void](Write-JsonFile -Path $notifyStateFile -Value $payload)
    } catch { }
    return $true
  } catch {
    Write-Log ('[通知] 发成功提醒时出异常（不影响重启）：{0}' -f $_.Exception.Message)
    return $false
  }
}




#
#  【为什么必须重写】
#    老写法是：
#        if (-not (Test-Path $Path)) { return $null }
#        try { ...ReadAllText... } catch { return $null }
#    两个 `return $null` 把**两种完全不同的情况**合并成同一个结果：
#      · 文件真的不存在      → 正常情况（比如还没排重启）
#      · 文件正被占用读不开  → **异常情况，重试一下就能读到**
#    调用方无法区分，只能一律当成"什么都没有"。后果举例：
#      plan.json 正被插件写的那一刻，正主去读会拿到 $null，
#      而正主编译成"计划文件读不出来" → 直接 exit 2 走人（重启无声无息没了）。
#
#  【实测数据（2026-10-11，%TEMP%\lockprobe.ps1）】
#    写手 3 秒写 13,593 次 / 探测 5,170 次：
#      · Test-Path 报"不存在"    0 次      ← 存在性判断本身是可靠的
#      · File::Exists 报"不存在" 0 次
#      · ReadAllText 读失败       1,266 次  ← ★ 病全在这儿（约 24%）
#    所以：**病在读取，不在存在性判断**。修法就是把读失败重试掉。
#
#  【为什么重试是安全的】
#    写手每次都只占极短时间（实测写完一个文件是微秒级），隔十几毫秒再试几乎必成。
#    而且这里**绝不把"读失败"当成"没有"** —— 那是把异常当正常，正是老写法的错。
#
#  【返回值契约】（调用方按这个判）
#    返回 [pscustomobject]@{ Ok = $bool; Value = 解析结果; Reason = '不存在'|'读失败'|'空文件'|'坏JSON' }
#    · Ok=$true            → Value 可用
#    · Ok=$false / '不存在' → 确实没有这个文件（正常，不是错误）
#    · Ok=$false / 其它     → **出了状况**（重试过仍读不到），调用方应留痕，别当成"没有"
function Read-JsonResult {
  param(
    [string]$Path,
    [int]$MaxTry = 5,
    [int]$DelayMs = 20
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject]@{ Ok = $false; Value = $null; Reason = '不存在' }
  }

  $lastReason = '不存在'
  for ($try = 1; $try -le [Math]::Max(1, $MaxTry); $try++) {
    # ① 真的不存在 —— 这是正常情况，立刻返回，不浪费重试
    if (-not [System.IO.File]::Exists($Path)) {
      return [pscustomobject]@{ Ok = $false; Value = $null; Reason = '不存在' }
    }
    # ② 存在，试着读
    try {
      $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
      if ([string]::IsNullOrWhiteSpace($raw)) {
        # 空文件：可能正好被写手清空的那一瞬 → 也重试
        $lastReason = '空文件'
      } else {
        try {
          return [pscustomobject]@{ Ok = $true; Value = ($raw | ConvertFrom-Json); Reason = '' }
        } catch {
          # 内容不完整（写了一半）→ 重试
          $lastReason = '坏JSON'
        }
      }
    } catch {
      # ★ 被占用读不开 → 重试
      $lastReason = '读失败'
    }

    if ($try -lt $MaxTry) { Start-Sleep -Milliseconds $DelayMs }
  }

  return [pscustomobject]@{ Ok = $false; Value = $null; Reason = $lastReason }
}

# 兼容包装：绝大多数老调用点只关心"拿到东西没有"，继续返回 $null 或值。
# ⚠️ 但**需要区分**读失败与不存在的场合（尤其保险丝），请直接用 Read-JsonResult。
function Read-JsonFile {
  param([string]$Path)
  $r = Read-JsonResult -Path $Path
  if ($r.Ok) { return $r.Value }
  return $null
}

function Get-SubagentArchiveMap {
  <#
    建一张「会话 id → 是不是子代理」的全量映射（2026-10-10 加，修根因①）。

    为什么必须建映射、不能按 id 找文件：
      session_projcache_archive_manager_v2\sessions\ 里的文件名是**哈希**
      （形如 session__0Ws2d_SAjIE7W_-IOVetbUyWfOgX1yqGFGItoSgyQk.json），
      跟会话 id 没有任何可推导的关系（实测 sha1/sha256/base64url 全对不上）。
      所以只能**读每个文件的内容**，取 record.sessionId 当键。

    什么时候建：扫盘发现"有别人在写"时才建（不是每轮都建）——
      实测 PS 5.1 读 915 个文件约 1.8 秒。5 秒一轮的循环里每轮都建太浪费，
      而"认不出子代理"这个错只在**真正撞上写入时**才致命，所以按需建、建完缓存。
  #>
  param([string]$Root)
  $map = @{}
  if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return $map }
  try {
    foreach ($f in [System.IO.Directory]::GetFiles($Root, '*.json')) {
      try {
        $j = Read-JsonFile -Path $f
        if (-not $j) { continue }
        $rec = $j.record
        if (-not $rec) { continue }
        $id = [string]$rec.sessionId
        if (-not $id) { continue }
        # 归一化：会话记录里有的带 session- 前缀、有的不带，统一去掉前缀当键
        $key = $id -replace '^session-', ''
        $sub = $rec.rows.subagent
        $isSub = ($null -ne $sub -and $null -ne $sub.val -and $null -ne $sub.val.identity)
        # 同一个 id 只认一次；若重复出现，**只要有一个说是子代理就算子代理**
        # （同 id 代表同一个会话，身份不该有分歧；偏向"认出来"是安全方向，见函数头）
        if ($isSub -or -not $map.ContainsKey($key)) { $map[$key] = $isSub }
      } catch { }
    }
  } catch { }
  return $map
}

function Update-SubagentArchiveMap {
  <#
    按需建/刷新全量身份档案映射（见 Get-SubagentArchiveMap）。
    ⚠️ 只在**真要认子代理**的时候建（扫盘发现"有别人在写"、或插件报了会话清单），
      不在每轮循环里建 —— 读 915 个文件约 1.8 秒，白建会拖慢 5 秒一轮的等待循环。
    ⚠️ 建过一次就缓存（$script:SubagentArchiveMapBuilt = $true）：
      一份计划的生命周期只有几分钟，期间子代理身份不会变，
      重复读 915 个文件没有意义（真变了也只是保守方向：多等一轮）。
  #>
  if ($script:SubagentArchiveMapBuilt) { return }
  $script:SubagentArchiveMapBuilt = $true
  if (-not $script:SubagentArchiveRoot) {
    Write-Log '[正主] （参考）没有可用的全量身份档案目录，认子代理只走 GUI 投影缓存（会漏认一部分）。'
    $script:SubagentArchiveMap = @{}
    return
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $script:SubagentArchiveMap = Get-SubagentArchiveMap -Root $script:SubagentArchiveRoot
  $sw.Stop()
  $subCount = 0
  foreach ($k in $script:SubagentArchiveMap.Keys) { if ($script:SubagentArchiveMap[$k]) { $subCount++ } }
  Write-Log ('[正主] 已建身份档案映射：{0} 个会话（其中子代理 {1} 个），耗时 {2:N0} ms。' -f $script:SubagentArchiveMap.Count, $subCount, $sw.Elapsed.TotalMilliseconds)
}

function Test-IsSubagentSession {
  <#
    判断某个会话 id 是不是**子代理（家务）**，而不是"别人的真对话"。
    （2026-10-08 加；2026-10-10 修根因①：原来只认一个来源，漏认 320/619 个子代理。）

    两个来源**都查**，任一说是子代理就算（安全方向：认出来 = 可以等它跑完，不是砍它）：

      ① 全量档案 session_projcache_archive_manager_v2\sessions\
         文件名是哈希，靠 $script:SubagentArchiveMap（Get-SubagentArchiveMap 建的）查。
         **这是主判据**：覆盖 619/619 子代理、真对话 0 误判、近实时。
      ② GUI 投影缓存 session_projcache\sessions\<会话id>.json
         record.rows.subagent.val.identity 有值 = 子代理。
         保留作兜底（万一 ① 的目录不在，比如 DSH 版本变了目录名）。

    ⚠️ 这是**不依赖插件**的判据，故意做成这样：
      插件报的 runningSubagents 更准，但改动插件要重启宿主才生效；
      而这条路径**立刻**就能用。
    ⚠️ 判不出来时一律返回 $false（= 当成真对话，保守）：
      宁可多等一次，也不要把别人的对话当家务给砍了。

    ⚠️ 绝不能用 parentSession 是否等于发起会话来判断：
      实测本机有 25 个**真对话**带 parentSession（如 8c378e19，17 轮），
      但 origin 为空、delegationDepth 为 0 —— 它们是"派生的新对话"，不是子代理。
      拿 parentSession 当判据会把它们误认成家务 → **可能砍断别人的对话**（危险方向）。
      正确判据是 origin === 'subagent' 或 delegationDepth >= 1（实测 0 危险 0 漏网）。
  #>
  param([string]$SessionId, [string]$CacheRoot)
  if (-not $SessionId) { return $false }
  try {
    $bare = $SessionId -replace '^session-', ''

    # ① 全量档案（主判据）
    if ($script:SubagentArchiveMap) {
      if ($script:SubagentArchiveMap.ContainsKey($bare) -and $script:SubagentArchiveMap[$bare]) { return $true }
    }

    # ② GUI 投影缓存（兜底）
    if ($CacheRoot) {
      $f = Join-Path $CacheRoot ("{0}.json" -f $SessionId)
      if (-not (Test-Path -LiteralPath $f)) { $f = Join-Path $CacheRoot ("session-{0}.json" -f $bare) }
      if (Test-Path -LiteralPath $f) {
        $j = Read-JsonFile -Path $f
        if ($j) {
          $sub = $j.record.rows.subagent
          if ($null -ne $sub -and $null -ne $sub.val -and $null -ne $sub.val.identity) { return $true }
        }
      }
    }

    return $false
  } catch { return $false }
}

# ══════════════════════════════════════════════════════════════════════════════
# 【2026-10-24 加】"到底在等谁"—— 状态窗上那几行人话
#
# 【为什么加】用户原话：「我当时看不到他在哪个地方在跑」。
#   上一趟重启卡在记忆插件的复审子代理上，卡片只写「正在等：家务子代理 1 个」——
#   既不知道是哪个、属于哪儿，也不知道它是在干活还是卡住了，只能干等或打断整趟。
#
# 【数据从哪来】GUI 自己的投影缓存（session_projcache\sessions\<id>.json，纯 JSON）：
#   · rows.subagent.val.identity.label  → 某个插件生成的复审会话名这种名字
#   · rows.title.val                    → 没有 label 时的退路
#   · identity.cwd                      → 属于哪个工作区（"在哪个地方跑"问的就是这个）
#   · identity.createdAt                → 已经跑了多久
#   · 缓存文件自己的 mtime              → 最近一次动静（它随会话进展而更新）
#   ⇒ **不读会话正文**（那是 zstd 多帧，PS 解不了，也不该为一行提示去解）。
#
# 【出错怎么办】任何一步失败都返回空行 —— 提示少一行不影响重启；
#   绝不 because-of-一行字把整趟流程搞崩。
# ══════════════════════════════════════════════════════════════════════════════
function Format-DurationCn {
  param([double]$Seconds)
  if ($Seconds -lt 0) { $Seconds = 0 }
  if ($Seconds -lt 60) { return ('{0:N0} 秒' -f $Seconds) }
  $m = [math]::Floor($Seconds / 60)
  $s = [math]::Round($Seconds - ($m * 60))
  if ($m -lt 60) { return ('{0:N0} 分 {1:N0} 秒' -f $m, $s) }
  $h = [math]::Floor($m / 60)
  return ('{0:N0} 小时 {1:N0} 分' -f $h, ($m % 60))
}

function Get-SessionDisplayName {
  <#
    把一个会话 id 换成"人看得懂的名字"（就是 GUI 左边列表里那个标题）。
    ★ 2026-10-24 加，用户原话：「你给这个编号，我找不到是哪个呀。你得把重启会话的名字给我」。

    数据来源同 Get-SubagentWaitLine：GUI 投影缓存里的 rows.title.val（纯 JSON）。
    标题前可能带我们自己加的图标（♻️ / ⭕），先摘掉再显示。
    拿不到就返回空串 —— 调用方会退回显示 id（有 id 总比什么都没有好）。
  #>
  param([string]$SessionId, [string]$CacheRoot)
  if (-not $SessionId) { return '' }
  try {
    $bare = $SessionId -replace '^session-', ''
    $f = ''
    if ($CacheRoot) {
      foreach ($name in @(("{0}.json" -f $SessionId), ("{0}.json" -f $bare), ("session-{0}.json" -f $bare))) {
        $p = Join-Path $CacheRoot $name
        if (Test-Path -LiteralPath $p) { $f = $p; break }
      }
    }
    if (-not $f) { return '' }
    $j = Read-JsonFile -Path $f
    if (-not $j) { return '' }
    $t = [string]$j.record.rows.title.val
    if (-not $t) { return '' }
    # ★ 2026-10-24 加：标题有时是**被截断的 JSON**（DSH 生成标题过程中的中间态）。
    #   实测本机某会话的缓存里躺着这么 42 个字符（就是本用户当时正在看的那个会话）：
    #     {"currentTitle":"第二个继续写未显示对话名称而显示ID的原因","m
    #   直接当标题显示出来就是「{"currentTitle":"…」—— 比没有名字更难看，
    #   而且在卡片/日志里一眼看上去像程序崩了。
    #   处理：能整段解析就取 currentTitle；解析不了（被截断）就用正则从里面捞；
    #         连捞都捞不到 → 当作没名字，让调用方退回短 id。
    if ($t.TrimStart().StartsWith('{')) {
      $inner = ''
      try { $inner = [string](($t.TrimStart() | ConvertFrom-Json).currentTitle) } catch { }
      if (-not $inner) {
        # 退路：在**被截断**的文本里手工捞出 currentTitle。
        # ⚠️ 这里故意**不用正则**：这个模式本身含引号字符，写成一行会让引号个数变奇数，
        #    而 test-static-sanity 的"引号配平"粗筛正是查这个的 —— 实测被它报了一次红。
        #    改成手工扫：只在遇到未转义的引号时结束，遇到 \x 就原样吃进下一个字符。
        $q = [char]34
        $k = $t.IndexOf([string]$q + 'currentTitle' + [string]$q)
        if ($k -ge 0) {
          $p1 = $t.IndexOf(':', $k)
          $p2 = if ($p1 -ge 0) { $t.IndexOf($q, $p1 + 1) } else { -1 }
          if ($p2 -ge 0) {
            $sb = New-Object System.Text.StringBuilder
            for ($ci = $p2 + 1; $ci -lt $t.Length; $ci++) {
              $c = $t[$ci]
              if ($c -eq '\' -and ($ci + 1) -lt $t.Length) { $ci++; [void]$sb.Append($t[$ci]); continue }
              if ($c -eq $q) { break }
              [void]$sb.Append($c)
            }
            $inner = $sb.ToString()
          }
        }
      }
      if (-not $inner) { return '' }
      $t = $inner
    }
    # 摘掉标题前的图标（♻️ / ⭕ 之类）与零宽字符；emoji 变体选择符 U+FE0F 也去掉
    $t = ($t -replace '^[\s\p{So}\p{Sk}\p{Mn}\p{Me}\uFE0F]+', '').Trim()
    if (-not $t) { return '' }
    # 有的会话标题本身就是一串 id（比如"接着上个会话干"派生出来的），
    # 那种标题当"名字"显示毫无意义 → 当作没名字，让调用方退回短 id。
    if ($t -match '^session-[0-9a-fA-F-]{20,}$') { return '' }
    if ($t.Length -gt 28) { $t = $t.Substring(0, 28) + '…' }
    return $t
  } catch { return '' }
}

function Format-SessionNameList {
  <#
    把一串「会话目录名」拼成**人看得懂**的短名单（最多取前 N 个，顿号相连）。
    ★ 2026-10-24 加。用户原话：「当初要求显示对话名称嘛，现在为什么第二个栏目里没显示名称？」

    【病根】10-24 那次只改了其中**一条**理由（"还有 N 个别的会话在干活"改成显示名字），
      另一条理由「盘上有 N 个会话文件还在持续写」仍在用 `$_.Directory.Name` 直出 uuid。
      于是同一行日志里一半是「记忆看板重设计与提醒修复」、一半是 `session-1b64e629-…`，
      看着像是又退回去了 —— 其实是**两条路，只改了一条**。
      （同一个判定有多个来源时每个来源都要过同一套格式化，和当年"两条路都要过滤子代理"是同一条教训。）

    【拿不到名字怎么办】退回短 id（前 8 位），别拿一长串 uuid 糊人 —— 有据可查比好看重要。
  #>
  param([string[]]$Ids = @(), [string]$CacheRoot = '', [int]$Max = 3)
  if (-not $Ids) { return '' }
  $all = @($Ids | Where-Object { $_ })
  $out = @()
  foreach ($id in @($all | Select-Object -First $Max)) {
    $sid = [string]$id
    if (-not $sid) { continue }
    $n = Get-SessionDisplayName -SessionId $sid -CacheRoot $CacheRoot
    if ($n) {
      $out += ('「' + $n + '」')
    } else {
      $bare = $sid -replace '^session-', ''
      $short = if ($bare.Length -gt 8) { $bare.Substring(0, 8) } else { $bare }
      $out += ('会话 ' + $short)
    }
  }
  $s = $out -join '、'
  # 超出 Max 的用一个省略号交代（否则看着像"只有这几个"，实际还有 —— 那是误导）
  if ($all.Count -gt $Max) { $s += '…' }
  return $s
}

function Get-SubagentWaitLine {
  param([string]$SessionId, [string]$CacheRoot)
  if (-not $SessionId) { return '' }
  try {
    $bare = $SessionId -replace '^session-', ''
    $f = ''
    if ($CacheRoot) {
      foreach ($name in @(("{0}.json" -f $SessionId), ("{0}.json" -f $bare), ("session-{0}.json" -f $bare))) {
        $p = Join-Path $CacheRoot $name
        if (Test-Path -LiteralPath $p) { $f = $p; break }
      }
    }
    $label = ''
    $where = ''
    $elapsed = -1
    $quiet = -1
    if ($f) {
      $j = Read-JsonFile -Path $f
      if ($j) {
        try { $label = [string]$j.record.rows.subagent.val.identity.label } catch { }
        if (-not $label) { try { $label = [string]$j.record.rows.title.val } catch { } }
        try {
          $cwd = [string]$j.record.identity.cwd
          if ($cwd) { $where = Split-Path -Leaf $cwd }
        } catch { }
        try {
          $created = [double]$j.record.identity.createdAt
          if ($created -gt 0) { $elapsed = ([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - ($created / 1000) }
        } catch { }
      }
      try {
        $quiet = ((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalSeconds
      } catch { $quiet = -1 }
    }
    if (-not $label) { $label = '一个后台复审子代理' }
    # 名字太长会撑爆卡片：截断 + 省略号（中文按字符算，40 个足够）
    $label = $label.Trim()
    if ($label.Length -gt 40) { $label = $label.Substring(0, 40) + '…' }
    if ($label -match '^\[某个记忆插件') { $label = '记忆插件的复审子代理' }

    $bits = @("· $label")
    if ($where) { $bits += "（$where 工作区）" }
    if ($elapsed -ge 0) { $bits += ('已跑 {0}' -f (Format-DurationCn -Seconds $elapsed)) }
    if ($quiet -ge 0) { $bits += ('，最近 {0}没动静' -f (Format-DurationCn -Seconds $quiet)) }
    return ($bits -join '')
  } catch { return '' }
}

function Get-HousekeepingWaitDetail {
  param(
    [string[]]$Subagents = @(),
    [int]$JobsRunning = 0,
    [string]$CacheRoot = ''
  )
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('这一轮已经说完了，在等这些「家务」跑完（不是哪个对话在等你回话）：')
  $subs = @($Subagents | Where-Object { $_ } | Select-Object -First 4)
  foreach ($s in $subs) {
    $line = Get-SubagentWaitLine -SessionId $s -CacheRoot $CacheRoot
    if ($line) { $lines.Add($line) }
  }
  $more = (@($Subagents | Where-Object { $_ }).Count - $subs.Count)
  if ($more -gt 0) { $lines.Add(('· 另外还有 {0} 个子代理在跑' -f $more)) }
  if ($JobsRunning -gt 0) { $lines.Add(('· 后台任务 {0} 个（命令还在跑）' -f $JobsRunning)) }
  $lines.Add('不想等就点下面的「不等了，立刻重启」—— 那不是取消，是照样重启（安全检查一个都不省）。')
  return ($lines -join "`r`n")
}

# ══════════════════════════════════════════════════════════════════════════
#  写 JSON —— 【2026-10-11 改成"写草稿再整张换上"】
# ══════════════════════════════════════════════════════════════════════════
#
#  【为什么】
#    老写法是 `WriteAllText` **直接覆盖在目标文件上** —— 写的过程中文件是"半截"的，
#    别人这一刻读到就是半个 JSON。改成"先写草稿（.tmp），写完再整张换上"之后，
#    别人**要么看到旧的、要么看到新的，永远看不到半截**。
#
#  【用的是系统自带能力，没自己发明】
#    实测（PS 5.1）：`[System.IO.File]::Replace($tmp, $target, $bak)` 可用。
#    ⚠️ 踩过的坑：第三个参数（备份路径）传 `$null` 会报 `The path is not of a legal form`，
#       要传 `[NullString]::Value`。
#    ⚠️ `[System.IO.File]::Move()` 的三参数重载在 .NET Framework（5.1）**不存在**，别用。
#    目标文件还不存在时 Replace 会失败 → 退回直接 Move（首次创建的正常路径）。
#
#  【为什么必须容错】
#    这个函数在"正主准备重启"的关键路径上，写不进去只会返回 $false，绝不抛异常打断流程。
function Write-JsonFile {
  param([string]$Path, $Value)
  try {
    $json = $Value | ConvertTo-Json -Depth 8
    $enc = New-Object System.Text.UTF8Encoding $false
    $tmp = $Path + '.tmp'

    # ① 先写草稿
    [System.IO.File]::WriteAllText($tmp, $json, $enc)

    # ② 整张换上
    if ([System.IO.File]::Exists($Path)) {
      # 目标已存在 → 用 Replace 原子替换。
      # ⚠️ 第三个参数是"旧内容的备份路径"。传 $null 会报 `The path is not of a legal form`，
      #    实测要传 [NullString]::Value 才等于"不留备份"。
      # ★ 2026-10-11 选"不留备份"：因为这几个文件（plan/state/last-run）**不是数据**，
      #    而是"当前状态"。备份没有意义，只会在用户的
      #    `~\.dsh\self-restart\` 里堆一堆 .bak 垃圾（早期版本的 Save-Result 已经留过这种痕迹）。
      #    真正要留的历史在 helper.log 和 last-run.json 里。
      try {
        [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
      } catch {
        # Replace 有时会因权限/占用失败 → 退回"删旧的再换新的"
        # （这一步有极短的"目标不存在"窗口；保险丝那边已用 Test-PlanFileGone 双确认兜住）
        try { [System.IO.File]::Delete($Path) } catch { }
        [System.IO.File]::Move($tmp, $Path)
      }
    } else {
      # 目标还不存在 → 直接换名过去
      [System.IO.File]::Move($tmp, $Path)
    }
    return $true
  } catch {
    # 写失败时把草稿清掉，别留垃圾文件
    try { $t = $Path + '.tmp'; if ([System.IO.File]::Exists($t)) { [System.IO.File]::Delete($t) } } catch { }
    return $false
  }
}

# ── 状态窗（2026-10-10 加：需求是"留一个窗口在外面，能一直看到状态"）─────────────
#
# ★ 2026-10-11 新增：窗口模块函数"取不到"时的留痕器。
#   为什么需要它：原先所有 *Safe 包装都是「Get-Command 找不到 → 什么都不做」，
#   `Get-Command` 找不到**不抛异常**，再加 `-ErrorAction SilentlyContinue`，
#   于是"窗口功能整个失效"这件事**一行日志都不会留下** ——
#   这就是 2026-10-11 那个 bug（函数内点源）能潜伏这么久、直到窗口现象被直接观察到的原因。
#   现在：第一次碰到就写一行日志，之后不再重复（不刷屏）。
function Write-WinModMissingOnce {
  param([string]$FunctionName)
  if (-not $script:WinModMissingReported) {
    $script:WinModMissingReported = $true
    $why = '多半是窗口模块没点源上（见主脚本里"状态窗模块：顶层点源"那段的说明）'
    Write-Log ('[状态窗] 取不到模块函数「{0}」—— 阶段文字/打断按钮/收尾都不会生效。{1}' -f $FunctionName, $why)
  }
}
$script:WinModMissingReported = $false

# ⚠️ 只在**正主**里显示：保险丝平时睡 25 秒就撤，给它弹个窗口纯属添乱。
# ⚠️ 点源失败**绝不影响重启**：窗口是"锦上添花"，重启才是正事。
#
# ════════════════════════════════════════════════════════════════════════════
# ★★★ 2026-10-11 修的致命 bug：点源的位置（这一段是拿实际现象换来的）★★★
#
#   现象（2026-10-11 报告的原话）：
#     「会在重启已经开始了的阶段，就没法再点那个中断了，然后页面会变，但实际上没变」
#   即：窗口出来了、一直显示「等待中」、阶段文字从不更新、「打断」按钮从不禁用、点了也没用。
#
#   根因：**点源（. $winMod）原先写在 Initialize-RestartWindow 函数体内**。
#     PowerShell 里 `function { }` 会产生**函数作用域**，点源进去的函数随函数返回而消失：
#       · 函数内部：模块函数可用（所以窗口能显示 —— 造成"它在工作"的假象）
#       · 函数返回后：Set-RestartWindowStage / Disarm-RestartWindowAbort / Close-RestartWindow
#         **全部消失**
#     而下面所有 *Safe 包装都是 `Get-Command ... -ErrorAction SilentlyContinue` 判断：
#     **找不到不抛异常、直接跳过** → 全程静默，连一行日志都没有。
#     （对照：`try { }` 是语句块，**不产生新作用域** ——
#       所以测试脚本里在顶层 try 内点源，模块函数一直活着，20 套测试全绿也照不出这个 bug。
#       测试还直接调模块函数、不经过 *Safe 包装，等于完全没覆盖"主脚本→模块"这根线。）
#
#   实测证据（本次，与实机同序复刻）：
#     L870 等价调用 -> 窗口显示 = True
#     -> Disarm-RestartWindowAbortSafe     [静默跳过] 找不到
#     -> Set-RestartWindowStageSafe closing [静默跳过] 找不到
#     截图：脚本已执行完"正在关闭"的切换，窗口上仍是「等待中」+ 可点的「打断这次重启」
#
#   修法（2026-10-11）：把点源**挪到脚本顶层、只做一次**，见下面 Initialize-RestartWindow 之后。
#     为什么是"顶层一次"而不是"每次调用时点源"：
#       · 顶层点源后模块函数进**脚本作用域**，后面所有函数都看得见（已实测）；
#       · 重复点源会重复执行模块顶层代码（$script:DshRw 等会被重置），没必要。
#   ⚠️ 改动这块之前先读这两条：
#       ① 绝不要把 `. $winMod` 再挪回任何函数体内（那就是这个 bug）；
#       ② *Safe 包装里"取不到就静默跳过"的写法要保留**但必须留痕**（见下），
#          否则同类问题还会再次无声无息。
# ════════════════════════════════════════════════════════════════════════════
function Initialize-RestartWindow {
  param([string]$PlanFile, $Plan)
  try {
    $showWin = $true
    if ($null -ne $Plan.showWindow) { $showWin = [bool]$Plan.showWindow }
    if (-not $showWin) {
      Write-Log '[正主] 状态窗按计划要求关闭（showWindow=false）—— 静默重启，行为与老版本一致。'
      return $false
    }

    # 点源已在脚本顶层做过（见本文件"状态窗模块：顶层点源"那段）。这里只做结果检查。
    if (-not $script:WinModLoaded) {
      Write-Log '[正主] 状态窗模块没装上（顶层点源失败）—— 这次不显示窗口，重启照做。'
      return $false
    }
    # ⚠️ 把**取消标记文件**交给窗口：窗口上的「打断」按钮点下去就是写这个文件，
    #    和 restart_status(cancel=true) 走的是同一条路 —— 助手每轮循环都会查它。
    $ok = Show-RestartWindow -Port $port -Reason ([string]$Plan.reason) -LogFile $script:LogPath -CancelFile $cancelFile -ForceFile $forceFile
    if ($ok) { Write-Log '[正主] 状态窗已显示（不抢焦点；卡片可拖动；「打断」= 取消整趟，「不等了」= 跳过等家务）。' }
    else { Write-Log '[正主] 状态窗没显示出来（不影响重启）。' }
    return [bool]$ok
  } catch {
    Write-Log ('[正主] 状态窗初始化出错（不影响重启）：' + $_.Exception.Message)
    return $false
  }
}

function Update-RestartWindowSafe {
  # 把"现在在等什么"写到窗口上。失败一律吞掉（窗口坏了不许影响重启）。
  #
  # ⚠️ 名字**必须**和模块里的 Update-RestartWindowWait 不一样：
  #    模块是点源进来的，同名函数会把这里的定义**覆盖掉**，
  #    于是这个包装函数就变成"调用自己" → 无限递归（真踩到才发现）。
  #    规矩：主脚本里的包装一律带 Safe 后缀，别和模块里的重名。
  #
  # ★ 2026-10-11：原来这里是"取不到就**静默**跳过"，那是状态窗失效却查不出来的直接原因
  #   （详见本文件"状态窗模块：顶层点源"上方的长注释）。现在改成**只报一次**，
  #   既不刷屏、也不让故障无声无息。
  param([string]$Detail, [double]$ElapsedSeconds = 0, [double]$MaxWaitMinutes = 5, [switch]$CanForce)
  try {
    if (Get-Command Update-RestartWindowWait -ErrorAction SilentlyContinue) {
      Update-RestartWindowWait -Detail $Detail -ElapsedSeconds $ElapsedSeconds -MaxWaitMinutes $MaxWaitMinutes -CanForce:$CanForce
    } else {
      Write-WinModMissingOnce 'Update-RestartWindowWait'
    }
  } catch { }
}

function Set-RestartWindowForceSafe {
  # 点亮 / 熄灭状态窗上的「不等了，立刻重启」。
  # 失败一律吞掉（窗口坏了不许影响重启），但和别的包装一样**只报一次**。
  param([bool]$Enabled = $false, [string]$ForceFile = '')
  try {
    if (Get-Command Set-RestartWindowForce -ErrorAction SilentlyContinue) {
      Set-RestartWindowForce -Enabled $Enabled -ForceFile $ForceFile
    } else {
      Write-WinModMissingOnce 'Set-RestartWindowForce'
    }
  } catch { }
}

function Set-RestartWindowStageSafe {
  param([string]$Stage, [string]$Detail = '', [string]$EtaText = $null)
  try {
    if (Get-Command Set-RestartWindowStage -ErrorAction SilentlyContinue) {
      Set-RestartWindowStage -Stage $Stage -Detail $Detail -EtaText $EtaText
    } else {
      Write-WinModMissingOnce 'Set-RestartWindowStage'
    }
  } catch { }
}

function Disarm-RestartWindowAbortSafe {
  # 关掉「打断」按钮的可用性（过了"还能反悔"的阶段就调它）。
  # ⚠️ 为什么必须做：按钮一旦点下去就写取消标记，可那时 DSH 已经在被关了，
  #    "取消"根本来不及 —— 留着能点却做不到，比不给按钮更让人恼火。
  #    实测过这个取舍：宁可提前把它变成灰的并写明原因。
  #
  # ★ 2026-10-11：这个包装**没生效**正是实际出现的现象
  #   （「重启已经开始了的阶段，就没法再点那个中断了，页面会变但实际上没变」——
  #    真相是按钮**从没被禁用**、阶段文字**从没更新**）。原来取不到就静默跳过，
  #   现在改成留痕。
  try {
    if (Get-Command Disarm-RestartWindowAbort -ErrorAction SilentlyContinue) {
      Disarm-RestartWindowAbort
    } else {
      Write-WinModMissingOnce 'Disarm-RestartWindowAbort'
    }
  } catch { }
}

function Close-RestartWindowSafe {
  param([string]$FinalStage = '', [string]$FinalText = '', [int]$KeepSeconds = 0)
  try {
    if (Get-Command Close-RestartWindow -ErrorAction SilentlyContinue) {
      Close-RestartWindow -FinalStage $FinalStage -FinalText $FinalText -KeepSeconds $KeepSeconds
    } else {
      Write-WinModMissingOnce 'Close-RestartWindow'
    }
  } catch { }
}

# ── 小工具 ──────────────────────────────────────────────────────────────────
function Test-PortListening {
  param([int]$Port)
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(800)
    if ($ok -and $client.Connected) { return $true }
    return $false
  } catch {
    return $false
  } finally {
    if ($client) { try { $client.Close() } catch { } }
  }
}

# ══════════════════════════════════════════════════════════════════════════
#  ★ 2026-10-17：DSH 0.2.1-rc.2 起 GUI 端口改成动态分配，这里整段是新判据
# ══════════════════════════════════════════════════════════════════════════
#
#  【事故】升级到 0.2.1-rc.2 之后的一次自我重启，出现了"关了却打不开、还反复
#          被关掉"的连环故障。根因就一句话：
#
#            新版桌面端启动网页服务时写死 `--port 0`（让系统随机挑端口），
#            而本脚本判"起来了没有"靠的是**写死的 19387**。
#
#          于是：DSH 明明已经起来了（端口 14672 / 5165 / 4237 一路轮换），
#          脚本却一律判"没起来" → 重试前先 Kill-AllDsh 把刚起来的那个杀掉 →
#          保险丝又判"端口没人听 + 正主也没了"，每轮救援**第一件事也是
#          Kill-AllDsh** → 杀一轮、拉一个、再杀一轮…… 直到把所有人都杀掉。
#
#  【新判据】不再问"那个固定端口在不在"，改问两件事，任一成立就算活着：
#            ① 配置端口在听（老路径，自测全靠它，别删）
#            ② **这次拉起的那个进程树里，有没有人在监听端口**
#               —— DSH 的监听者不是主进程：实测主进程(37748) → 宿主(20924)
#                  才持有监听 socket。只盯主进程 PID 是看不到监听者的。
#
#  【为什么必须走到进程树】不能只看"进程还在"：刚拉起的 DSH 进程活了但端口
#          还没开，那不能算"起来了"（会让用户看到白屏）。要的是"真的在服务"。
function Get-ProcessTreePids {
  # 从一个根进程出发，把它的**所有后代** PID 收进来（广度优先，限深度）。
  # 为什么不用 TargetProcessName 过滤：DSH 的后代里有 GPU / 渲染 / 宿主等
  # 各种角色，按名字挑会漏；按父子关系走才完整。
  param([int]$RootPid, [int]$MaxDepth = 5)
  if ($RootPid -le 0) { return @() }
  $procs = @()
  try { $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId) } catch { return @($RootPid) }
  $childMap = @{}
  foreach ($p in $procs) {
    $pp = [int]$p.ParentProcessId
    if (-not $childMap.ContainsKey($pp)) { $childMap[$pp] = @() }
    $childMap[$pp] += [int]$p.ProcessId
  }
  $tree = @()
  $seen = @{}
  $frontier = @($RootPid)
  for ($depth = 0; $depth -le $MaxDepth -and $frontier.Count -gt 0; $depth++) {
    $next = @()
    foreach ($procId in $frontier) {
      if ($seen.ContainsKey($procId)) { continue }
      $seen[$procId] = $true
      $tree += $procId
      if ($childMap.ContainsKey($procId)) { $next += $childMap[$procId] }
    }
    $frontier = $next
  }
  return $tree
}

function Get-ListeningPortsOfPids {
  # 给定一组 PID，问出它们正在监听的 TCP 端口（去重）。
  # 拿不到（模块缺失 / 权限）就返回空数组 —— 调用方按"没验到"处理，
  # 会自然退回"配置端口"那条老路，不会因为这里报错就判成功。
  param([int[]]$ProcessIds)
  $ports = @()
  if (-not $ProcessIds -or $ProcessIds.Count -eq 0) { return @() }
  $set = @{}
  foreach ($procId in $ProcessIds) { $set[[int]$procId] = $true }
  try {
    foreach ($c in @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
      if ($set.ContainsKey([int]$c.OwningProcess)) { $ports += [int]$c.LocalPort }
    }
  } catch { return @() }
  return @($ports | Sort-Object -Unique)
}

function Test-DshAlive {
  # DSH **现在**是不是活着。给保险丝判"该不该我上场"用。
  #
  # ⚠️ 判据从"端口在听"改成"端口在听 **或** 进程还在"，这是本次修的核心：
  #    动态端口下"端口在听"永远是假，会让保险丝把**活得好好的 DSH** 当成死的。
  #    方向上也更安全：判"活着"宁可松一点 —— 松了最多少救一次，
  #    紧了就是杀一个正在干活的 DSH（那是本次连环杀的直接原因）。
  param([int]$ConfiguredPort = 0)
  if ($ConfiguredPort -gt 0 -and (Test-PortListening -Port $ConfiguredPort)) { return $true }
  try {
    if (@(Get-Process -Name $TargetProcessName -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  } catch { }
  return $false
}

function Test-IsOurOwnFamily {
  # 判断某个进程是不是"本脚本自己人"（正主、保险丝、或任何正在跑本脚本的进程）。
  #
  # ⚠️ 为什么必须有这个：自测时 TargetCommandMatch 会出现在**本脚本自己的
  #    命令行里**（因为要把它当参数传进来）。如果不过滤，助手会把自己、
  #    尤其会把**保险丝**当成目标杀掉 —— 保险丝正是"正主死了以后唯一能把
  #    DSH 拉回来"的那道保险，杀掉它等于把兜底拆了。
  #    实机场景下 DSH 的命令行不含本脚本路径，所以这个过滤不会误伤正常目标。
  param([string]$CommandLine)
  if (-not $CommandLine) { return $false }
  $selfName = 'dsh-self-restart.ps1'
  if ($CommandLine -like ('*' + $selfName + '*')) { return $true }
  return $false
}

# 目标进程的"命令行"缓存（由 Get-DshProcesses 一次查完填好）。
# ⚠️ 为什么要有它（2026-10-11 实测优化：重启越快越好）：
#   原来每需要一次命令行，就对**单个进程**发一次 CIM 查询 ——
#   实测 9 个进程要 **2,117 毫秒**；改成**一次查完**只要 **230 毫秒**。
#   一次重启里这个函数要跑 3~4 遍（动手前、清残留循环里），省下来约 6~8 秒。
$script:DshClCache = @{}

function Get-TargetProcessInfo {
  # 一次拿回"目标名字的所有进程"（含 CommandLine）。
  # ⚠️ CIM 的 Name 过滤**必须带扩展名**：'DeepSeek Harness' 查回 0 个，
  #    'DeepSeek Harness.exe' 才对（实测）。而 `Get-Process -Name` 不带 .exe 也能查 ——
  #    两者规则不同，这里要补上，否则会**静默查回空**、把 DSH 当成"没在跑"。
  $nameFilter = [string]$TargetProcessName
  if (-not $nameFilter) { return @() }
  if ($nameFilter -notmatch '\.exe$') { $nameFilter = $nameFilter + '.exe' }
  try {
    return @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $nameFilter) -ErrorAction SilentlyContinue)
  } catch { return @() }
}

function Get-CachedCommandLine {
  # 取某个进程的命令行（来自上面那次批量查询的缓存）。
  # 缓存里没有就返回空串 —— 调用方都按"拿不到命令行"的保守分支处理。
  param([int]$ProcId)
  try {
    if ($script:DshClCache -and $script:DshClCache.ContainsKey($ProcId)) {
      return [string]$script:DshClCache[$ProcId]
    }
  } catch { }
  return ''
}

function Get-DshProcesses {
  # 目标进程。默认就是 DSH 桌面版（主进程 + 渲染/GPU/工具进程 + 宿主同名）。
  # 自测时可以换成假名字，从而**绝不会碰到真的 DSH**。
  $all = @(Get-Process -Name $TargetProcessName -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { $script:DshClCache = @{}; return @() }

  # ★ 一次查完所有目标的命令行（原来逐个查，2.1 秒 → 0.23 秒）
  $info = Get-TargetProcessInfo
  $clMap = @{}
  foreach ($w in $info) { $clMap[[int]$w.ProcessId] = [string]$w.CommandLine }
  $script:DshClCache = $clMap

  $hit = @()
  foreach ($p in $all) {
    $cl = ''
    if ($clMap.ContainsKey($p.Id)) { $cl = $clMap[$p.Id] }

    # 永远不把"本脚本自己人"当目标
    if (Test-IsOurOwnFamily -CommandLine $cl) { continue }
    # 也不要自己的进程
    if ($p.Id -eq $PID) { continue }

    if ($TargetCommandMatch) {
      if ($cl -and $cl -like ('*' + $TargetCommandMatch + '*')) { $hit += $p }
    } else {
      $hit += $p
    }
  }
  return $hit
}

function Get-MainDshProcess {
  # 主进程 = 那个**持有窗口**的 Electron 主进程。
  #
  # ⚠️⚠️ 这里踩过一个真 bug（2026-10-10 实测：关闭时会闪一下报错）：
  #   原来选的是"**第一个**命令行里没有 --type= 的进程"，这个判据**不唯一** ——
  #   DSH 里有好几类进程的命令行都没有 --type=：
  #     ① Electron 主进程  '"…\DeepSeek Harness.exe"'                    ← 只有它持有窗口
  #     ② Node 宿主        '"…\DeepSeek Harness.exe" --expose-internals …'
  #     ③ Node 子工        '"…\DeepSeek Harness.exe" …dsh-subprocess-lo…'/ego-cast-worker
  #   而 `Get-Process` 的**返回顺序不保证**（实测这次第一个是 PID 2504，一个子工）。
  #   选中②③的后果：给一个**没有窗口**的进程发"请你自己关"（taskkill 不带 /F），
  #   Windows 找不到窗口可发 WM_CLOSE，只能回
  #     "ERROR: … could not be terminated. / This process can only be terminated forcefully"
  #   → **白等 12 秒**（下面那个重试循环）→ 再强杀主进程
  #   → 剩下的渲染进程一瞬间还活着，发现宿主没了 → 界面闪一条报错（界面上看到的就是它）。
  #   历史证据：helper.log 里"它自己退了（优雅退出）"**0 次**、"强制结束"**7 次** ——
  #   也就是**从来没优雅成功过**，每次都白等满 12 秒。
  #
  #   正确判据：**优先挑持有顶层窗口的进程**（MainWindowHandle ≠ 0）；
  #   万一它还没建好窗口（启动早期），再退回到"没有 --type= 且命令行最像主进程"的那个。
  $all = @(Get-DshProcesses)
  if ($all.Count -eq 0) { return $null }

  # ① 最优：有窗口的就是主进程（且**只有**它该收到"请自己关"）
  foreach ($p in $all) {
    try { if ($p.MainWindowHandle -ne 0) { return $p } } catch { }
  }

  # ② 退路：还没有窗口时，挑"命令行里没有 --type="的；
  #    再优先挑**命令行最短**的（主进程的参数最少，子工都带一长串脚本路径）。
  #    ⚠️ 命令行从 Get-DshProcesses 刚填好的缓存里取（别再逐个查，那要 2.1 秒）。
  $cand = @()
  foreach ($p in $all) {
    $cl = Get-CachedCommandLine -ProcId $p.Id
    if ($cl -notmatch '--type=') {
      $cand += [pscustomobject]@{ Proc = $p; Len = $cl.Length }
    }
  }
  if ($cand.Count -gt 0) {
    return ($cand | Sort-Object Len | Select-Object -First 1).Proc
  }
  return $null
}

function Start-DetachedProcess {
  # 用 WMI 创建进程：父级变成 WmiPrvSE，不在调用者的进程树里。
  # 这是"脚本能在 DSH 死后继续活着"的根本原因。
  #
  # ⚠️ ProcessStartupInformation + ShowWindow=0 是**治"闪黑框"的**（2026-10-08：
  #   "这个是两个脚本闪出来的，很难受，能不能让他们静默出来或者直接不出现"）。
  #   光用 `-WindowStyle Hidden` 不够：那个是**先建窗口再隐藏**，屏幕上仍会闪一下；
  #   ShowWindow=0（SW_HIDE）是**建进程那一刻就告诉 Windows 别显示**，窗口根本不出现。
  #   实测（test\archive\probe-window-selfreport.ps1，让子进程自己报 GetConsoleWindow+IsWindowVisible）：
  #     什么都不加 → 可见（对照组）；-WindowStyle Hidden → 不可见但窗口建过；
  #     StartUpInfo.ShowWindow=0 → 不可见且不建窗口 ✅。
  param([string]$CommandLine, [string]$WorkDir)
  $args = @{ CommandLine = $CommandLine }
  if ($WorkDir -and (Test-Path -LiteralPath $WorkDir)) { $args.CurrentDirectory = $WorkDir }
  try {
    $args.ProcessStartupInformation = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
  } catch { }
  try {
    return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $args -ErrorAction Stop
  } catch {
    # 兜底：万一本机不支持 ProcessStartupInformation，退回原来的建法（会闪，但功能不受影响）
    $plain = @{ CommandLine = $CommandLine }
    if ($args.CurrentDirectory) { $plain.CurrentDirectory = $args.CurrentDirectory }
    return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $plain -ErrorAction Stop
  }
}

function Get-SelfPaths {
  $selfPath = $PSCommandPath
  if (-not $selfPath) { $selfPath = $MyInvocation.MyCommand.Path }
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
  return @{ Self = $selfPath; Ps = $psExe }
}

function Start-Dsh {
  param([string]$Exe, [string]$WorkDir)
  $cmdLine = '"{0}"' -f $Exe
  return Start-DetachedProcess -CommandLine $cmdLine -WorkDir $WorkDir
}

function Wait-ForPort {
  # 盯"DSH 到底起来了没有"。起来了返回 $true。
  #
  # ★ 2026-10-17 改：判据从"配置端口在听"改成**两条任一成立**
  #   ① 配置端口在听（老路径：自测全是这条路，也兼容把端口写死的旧版本）
  #   ② **这次拉起的那个进程树里有人在监听**（新路径：动态端口全靠它）
  #
  #   为什么要看进程树而不是只看 $ProcId：DSH 的监听者不是主进程。
  #   实测（2026-10-17，主进程 37748）：主进程自己不监听，
  #   是它的子进程"宿主"（20924）持有 4237/4238/4239/8326。
  #   只盯主进程 PID → 永远看不到监听者 → 永远判"没起来"（这正是本次事故）。
  #
  #   procId 可选：进程没了就提前放弃（别白等）
  param([int]$Port, [int]$TimeoutSeconds, [int]$ProcId = 0)
  $waited = 0
  while ($waited -lt $TimeoutSeconds) {
    Start-Sleep -Seconds 2
    $waited += 2
    if (Test-PortListening -Port $Port) { return $true }
    if ($ProcId -gt 0) {
      $treePids = @(Get-ProcessTreePids -RootPid $ProcId)
      $livePorts = @(Get-ListeningPortsOfPids -ProcessIds $treePids)
      if ($livePorts.Count -gt 0) {
        Write-Log ('[正主]   它的进程树已经在服务了（PID {0} 名下监听端口 {1}）—— 这就是"起来了"。' -f $ProcId, ($livePorts -join ','))
        return $true
      }
      if ($waited -gt 15 -and -not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) {
        return $false   # 刚拉起的进程自己退了
      }
    }
  }
  return $false
}

function Invoke-Quiet {
  <#
    跑一条外部命令，且**不闪黑框**（2026-10-08：早期版本会闪出两个脚本窗口）。
    为什么需要：从 powershell 里调 taskkill.exe 这类**控制台程序**时，
    Windows 会给它建一个控制台窗口 —— 即使调用者自己是隐藏的，那个窗口也会闪一下。
    用 ProcessStartInfo.CreateNoWindow = true 才能压掉（这是 .NET 提供的正规开关）。

    ⚠️ 必须用 **Arguments 字符串**，不能用 ArgumentList：
      `ProcessStartInfo.ArgumentList` 是 .NET Core / PowerShell 7 才有的属性，
      在 **PowerShell 5.1**（也就是 powershell.exe，本脚本跑的这个）里是 $null，
      `$psi.ArgumentList.Add(...)` 会抛 "You cannot call a method on a null-valued expression"
      —— 实测踩到：taskkill 一次都没跑成，假应用没被关掉（test-helper 14/16）。
      所以这里自己拼参数串（命令行里的 PID/固定开关都由本脚本给出，没有引号风险）。

    返回：stdout+stderr 合并的文本数组；失败时返回一条说明。
  #>
  param([string]$FileName, [string[]]$Arguments)
  $out = New-Object System.Collections.Generic.List[string]
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    if ($Arguments -and $Arguments.Count -gt 0) {
      $psi.Arguments = ($Arguments -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true          # ★ 关键：不要控制台窗口
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # 先读流再等退出，避免管道缓冲区写满导致死锁
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    foreach ($line in ($stdout -split "`r?`n")) { if ($line) { $out.Add($line) } }
    foreach ($line in ($stderr -split "`r?`n")) { if ($line) { $out.Add($line) } }
  } catch {
    $out.Add(('（执行失败：{0}）' -f $_.Exception.Message))
  }
  return $out.ToArray()
}

function Kill-AllDsh {
  param([int]$ExceptPid = 0)
  foreach ($p in (Get-DshProcesses)) {
    if ($p.Id -eq $ExceptPid) { continue }
    try { [void](Invoke-Quiet -FileName 'taskkill.exe' -Arguments @('/F', '/PID', "$($p.Id)")) } catch { }
  }
}

# ══════════════════════════════════════════════════════════════════════════
#  保险丝专用：判断「计划文件是不是真的没了」
# ══════════════════════════════════════════════════════════════════════════
#
#  【为什么要单独一个函数，不直接 Test-Path】
#    因为 2026-10-11 把写入改成了"写草稿再整张换上"。
#    那个"换上"的兜底路径（Replace 失败时）是"先删旧的、再换新的"——
#    这中间有**极短的"目标文件不存在"窗口**（实测微秒级）。
#    保险丝如果正好在这一刻采样，就会以为"正主收工了"而**当场撤走** ——
#    正是它最不该走的时候。
#
#  【修法】"不存在"要**连着确认两次**（隔一小会儿），才算真的没了。
#    为什么要两次而不是加长单次等待：要区分的是
#      · 真的被删了（正主收工）→ 两次都看不到
#      · 瞬时的替换窗口    → 两次之间就回来了
#    ⚠️ 这个函数**只给保险丝**这种"看一眼就走"的判断用。
#       正主那边读完还要用内容，走 Read-JsonResult（自带重试），不需要它。
function Test-PlanFileGone {
  if ([System.IO.File]::Exists($PlanFile)) { return $false }
  # 第一次看不到 → 等 300 毫秒再确认一次（跨过"整张换上"的瞬时窗口）
  Start-Sleep -Milliseconds 300
  return (-not [System.IO.File]::Exists($PlanFile))
}

# ══════════════════════════════════════════════════════════════════════════
# 第 0 步：读计划（三种身份都要用）
# ══════════════════════════════════════════════════════════════════════════
# ★ 2026-10-11：这里改用 Read-JsonResult，因为**读失败和不存在必须分开对待**：
#   · 读失败（文件正被插件写）→ Read-JsonResult 内部已重试 5 次；
#     万一真的还失败，也要**说清楚是"读不到"而不是"计划坏了"**，别让排查的人被带偏。
#   · 不存在 → 才是真正的"没有计划"。
#   老写法两个都返回 $null、都报同一句"读不出来或不是合法 JSON"，
#   会把"撞上写入的一瞬间"误报成"计划文件坏了"。
$planRead = Read-JsonResult -Path $PlanFile
if (-not $planRead.Ok) {
  if ($planRead.Reason -eq '不存在') {
    Write-Host "计划文件不存在：$PlanFile"
  } else {
    Write-Host ("计划文件在，但读不出来（{0}，已重试）：{1}" -f $planRead.Reason, $PlanFile)
  }
  exit 2
}
$plan = $planRead.Value

# ── ★ 2026-10-22 新增：名单（members）—— 排队重启的地基 ────────────────────────
#
# 【为什么要这一层】
#   老的计划文件是"一份计划 = 一个人"。多个对话想重启时，后写的会**直接覆盖**
#   前一份（见 lib\index.js 的 planPath 与 docs\decisions-restart-queue.md 的 D7），
#   而等在外面的助手**只在启动时读一次计划、之后永不重读** —— 先来的人会静默失去自己的锁。
#
# 【兼容策略（必须守住，否则老计划全废）】
#   · 老计划没有 members → 用 requestedBy / sessionFile 现场合成一个单成员名单，
#     行为与改动前**完全一致**；
#   · 新计划带 members[] → 用它，老字段仍然保留作为 members[0] 的镜像（给旧代码兜底）。
#
# 【成员形状】
#   sessionId / sessionFile / reason / resume / joinedAt / source
#   ★ source = 该会话的来源（'local' 本地窗口 / 'im-direct' QQ私聊 / 'im-group' 群 / 'unknown'）
#     2026-10-22 定的判据：看 rpcId 有没有通道前缀（见决策记录 D9）。
#     这一层现在**只往下传、不参与判定** —— 判定留给下一步，先保证结构对。
# ⚠️⚠️ **必须返回"真数组"，不能返回 List 对象本身**（2026-10-23 抓到的真 bug）。
#
#   PowerShell 有一条坑人的管道展开规则：函数 `return $list` 把一个
#   **只有 1 个元素的 `List[object]`** 输出到管道时，会被**拆成那一个元素本身**。
#   于是调用方拿到的是**裸 PSCustomObject**，`.Count` 是 $null、`[0]` 也不对。
#
#   实测（同一段代码、两个版本，判据完全不同）：
#     PS 5.1 → 类型=PSCustomObject, Count=(空)      ← 助手真实际运行的就是 5.1！
#     PS 7.6 → 类型=PSCustomObject, Count=1         ← PS7 给单个对象也补 Count=1
#   ⇒ 这就是"在 pwsh 里跑测试全绿、跑批器（用 powershell.exe 5.1）却红 7 条"的原因。
#
#   ⚠️ 后果不是"测试红"，而是**产品线上的静默错**：
#     老计划（只有 requestedBy、没有 members[]）解析出来 Count 为空 →
#     `Save-Result` 里 `@($script:Members | ForEach-Object {...})` 只遍历那一个对象
#     （看起来"蒙对了"），但 `if ($newMembers.Count -ne $script:Members.Count)`
#     这种**数字比较会拿 $null 去比**，名单变化检测直接失效。
#     这类"单元素才出错"的 bug 平时多人排队时反而看不出来 —— 最容易混过实机验证。
#
#   修法：统一在 return 前 `@(...)` 包成真数组（空集合也得到 `@()`，Count=0）。
#   别改成 `,$list`（那会多套一层，变成"数组里装着一个 List"）。
function Get-PlanMembers {
  param($PlanObject)
  $list = New-Object System.Collections.Generic.List[object]
  if ($null -eq $PlanObject) { return @() }

  # 新结构：members[] 优先
  if ($PlanObject.members) {
    foreach ($m in @($PlanObject.members)) {
      if ($null -eq $m) { continue }
      $list.Add([pscustomobject]@{
        sessionId   = [string]$m.sessionId
        sessionFile = [string]$m.sessionFile
        reason      = [string]$m.reason
        resume      = $m.resume
        joinedAt    = [string]$m.joinedAt
        source      = if ($m.source) { [string]$m.source } else { 'unknown' }
      })
    }
    if ($list.Count -gt 0) {
      # ⚠️⚠️ 这里**不要**写 `return ,$list.ToArray()`（2026-10-23 晚修掉的真 bug）
      #
      # 【为什么这一行能毁掉整个多会话唤醒】
      #   逗号前缀 `,` 把数组**再包一层**，于是返回的是"一个元素：那个数组"。
      #   外层 `$script:Members = @(...)` 再包一次也救不回来 ——
      #   实测：2 个成员时 `$script:Members.Count` 是 **1**，`$script:Members[0]` 是 **Object[]**。
      #   接着 `Save-Result` 里 `$script:Members | ForEach-Object` 只跑**一次**，
      #   而 `[string]$_.sessionId` 对数组做**属性枚举 + 空格拼接** →
      #     `"session-AAAA session-BBBB"`（两个 id 粘成一个，谁都不是）
      #   ⇒ 插件重启后拿这个假 id 去 resolveAgent → `session/not-found` → 重试 40 多次全失败
      #     → 一行"本次重启已收尾但没能叫醒会话" → **排了队的人永远醒不过来**。
      #
      # 【证据】2026-10-23 20:36 那次实机重启（restart-mvkxiqhy，2 人）：
      #   last-run.json 里 members[0].sessionId = "session-6ae29222-… session-03568659-…"
      #   用真实助手 + 2 人假计划复现，同样压成一格。
      #   ⚠️ 这是个**潜伏很久**的 bug，只是以前从没真的让两个会话凑齐发过车，所以没暴露。
      #
      # 【正确写法（第一版我又改错了，这里记下来）】
      #   · `return $list.ToArray()`（**不带**逗号）在**只有 1 个元素**时，
      #     PowerShell 会把数组拆成"那一个对象"返回 → 调用方 `$x.Count` 变成空、
      #     `$x[0]` 变成对象本身。实测把 7 条单成员断言全打红。
      #   · `return ,$list.ToArray()`（带逗号）—— 1 人时正确，**≥2 人时会多包一层**。
      #   ⇒ 两头都错。真正的答案是：**函数返回 `,$arr` 保证"永远是数组"，
      #     而调用方 `@(...)` 那一层必须去掉**（两层加起来才变成数组套数组）。
      #     `,$arr` 里的逗号只抵消 PowerShell 的"单元素拆包"，
      #     一旦外面再 `@()`，就变成 `@(,@arr)` = 数组套数组。
      #
      #   ⚠️ 所以：**改这一行必须同时看调用点**。这正是"同一个判定写在两处、
      #      其中一处口径错"的典型 —— 本次事故就是两层各包一次。
      return ,$list.ToArray()
    }
  }

  # 老结构：requestedBy / sessionFile 视作 members[0]（行为与以前一致）
  if ($PlanObject.requestedBy -or $PlanObject.sessionFile) {
    $list.Add([pscustomobject]@{
      sessionId   = [string]$PlanObject.requestedBy
      sessionFile = [string]$PlanObject.sessionFile
      reason      = [string]$PlanObject.reason
      resume      = $PlanObject.resume
      joinedAt    = [string]$PlanObject.createdAt
      source      = 'unknown'
    })
  }
  return ,$list.ToArray()
}

# ⚠️⚠️ **不要在这里包 `@()`**（2026-10-23 晚，两层各包一次 = 整个多会话唤醒失效）
#
#   `Get-PlanMembers` 内部已经 `return ,$list.ToArray()` —— 那个逗号的作用就是
#   **抵消 PowerShell 的"单元素拆包"**，保证"不管几个人，返回的永远是数组"。
#   这里再 `@(...)` 等于 `@(,@arr)` = **数组里装着一个数组** →
#     `$script:Members.Count` 变成 1、`[0]` 是 Object[] →
#     Save-Result 里 `[string]$_.sessionId` 把成员列表**空格拼成一个假 id** →
#     插件 resolveAgent 全是 session/not-found → **排了队的人永远醒不过来**。
#
#   实机证据：2026-10-23 20:36 restart-mvkxiqhy（2 人）。
#   守门测试：test-members.ps1 的「3-b. 真实调用点的形状」那一组。
$script:Members = Get-PlanMembers -PlanObject $plan

# ── ★ 2026-10-22 新增：等太久发提醒用的参数 ──────────────────────────────────
#
# 用户在决策记录里定的是：**20 分钟**（可调）、**默认只提醒一次**、**不自动作废**。
# 原话：「这个最好改成可调的，默认给个半个小时吧……20 分钟吧，先给来个 20 分钟」
#       「重复提醒做成一个可选功能，但是默认不重复提醒」
#
# ⚠️ 提醒**必须在动手之前发**：真正重启那 40~130 秒里宿主是死的，
#    任何打宿主接口的通知渠道都必然失败（2026-10-22 实测确认）。
$notifyAfterMinutes = if ($null -ne $plan.notifyAfterMinutes) { [double]$plan.notifyAfterMinutes } else { 20 }
$notifyRepeat       = [bool]$plan.notifyRepeat
$notifyRepeatMinutes = if ($null -ne $plan.notifyRepeatMinutes) { [double]$plan.notifyRepeatMinutes } else { 60 }
# 外部通知命令（空 = 不通知）。与插件用同一份配置，避免两边行为不一致。
$noticeCommand      = [string]$plan.noticeCommand
$noticeTimeoutMs    = if ($null -ne $plan.noticeTimeoutMs) { [int]$plan.noticeTimeoutMs } else { 30000 }

$stateDir = Split-Path -Parent $PlanFile
if (-not $stateDir) { $stateDir = $PSScriptRoot }
# ⚠️ 「提醒过了没有」的记账文件必须**在 $stateDir 定义之后**才算路径。
#    2026-10-22 这里栽过一次：先写了 Join-Path $stateDir，而 $stateDir 在下一行才赋值，
#    于是 Join-Path 拿到 $null → **整个助手在启动时就崩了，且一个字日志都没写**。
#    表现是一堆测试"假应用没被杀 = 它动手了"的假红（看起来像逻辑错，其实是根本没跑起来）。
$notifyStateFile    = Join-Path $stateDir ('notify-' + [string]$plan.planId + '.json')
$script:LogPath = if ($plan.logFile) { [string]$plan.logFile } else { Join-Path $stateDir 'helper.log' }
$lastRunFile  = if ($plan.lastRunFile) { [string]$plan.lastRunFile } else { Join-Path $stateDir 'last-run.json' }
$cancelFile   = if ($plan.cancelFile) { [string]$plan.cancelFile } else { Join-Path $stateDir 'cancel.flag' }
# ★ 2026-10-24 新增：**人工放行标记**。
#   状态窗上「不等了，立刻重启」点下去就写这个文件；本脚本每轮都查它，
#   看到就**跳过"等家务"**（后台任务/子代理）这一段，继续往下走。
#   ⚠️ 它只跳过"等"，**不跳过"别的对话还在跑"那条硬理由**，更不跳过 preflight ——
#      换句话说：它能催，不能砍。状态窗那边也只在"只剩家务"时才点亮那个按钮。
$forceFile    = if ($plan.forceFile) { [string]$plan.forceFile } else { Join-Path $stateDir 'force.flag' }

$port            = if ($plan.port) { [int]$plan.port } else { 19387 }
$dshExe          = [string]$plan.dshExe
$dshWorkDir      = [string]$plan.dshWorkDir
$idleSeconds     = if ($plan.idleSeconds) { [int]$plan.idleSeconds } else { 12 }
# 用 double 不用 int：测试要能传 0.02 这种"几乎立刻放弃"的极小值。
# 用 [int] 会把 0.02 截成 0，而 0 的含义是"永远等"—— 正好相反，是个陷阱。
#
# ★ 2026-10-24 改兜底值 5 → 0（**和插件的 schema 默认保持一致**）。
#   【为什么改】原来是"插件默认 0（一直等）、助手兜底 5（最多等 5 分钟）"——
#   同一个参数在两层各有各的默认值，一旦 plan 里漏写这个字段，行为就**悄悄变了**，
#   而且**没有任何报错**。用户 问的正是这件事：
#     「现在已经有我这个手动关闭档了，那 30 分钟的硬上线是不是可以不设了？」
#   查下去才发现那 30 分钟不是默认值，是当时显式传的；真正的隐患是这个 5。
#   ⇒ 一个参数只能有一个含义、一个默认值。插件那边是 0，这里就必须也是 0。
#     0 = 一直等；上限由人的「打断」负责（用户 定的）。
$maxWaitMinutes  = if ($null -ne $plan.maxWaitMinutes) { [double]$plan.maxWaitMinutes } else { 0 }
$bootTimeout     = if ($plan.bootTimeoutSeconds) { [int]$plan.bootTimeoutSeconds } else { 90 }
$maxAttempts     = if ($plan.maxAttempts) { [int]$plan.maxAttempts } else { 3 }
$sessionFile     = [string]$plan.sessionFile
$stateFile       = [string]$plan.stateFile
$planId          = [string]$plan.planId
$script:PlanId   = $planId   # 干跑报告等处要用（原来只有 $planId 这个局部变量）

# ══════════════════════════════════════════════════════════════════════════════
# 【2026-10-23 加】封口助手：**一趟车结束时，计划文件要删、取消标记要清**
#
# 【为什么必须有它 —— 一次真事故换的】
#   2026-10-23 17:55，助手在"等空闲"分支收到取消标记后 `exit 2` 就走了，
#   **既没删 plan.json、也没清 cancel.flag**。后果有三层，每层都实际发生了：
#     ① `restart_status` 继续报「有待执行的重启」—— 而其实早就取消了
#        （另一个会话看到这个假状态，判断失误，把两个人的重启一起打掉了）；
#     ② 会话标题的 ♻️ 图标摘不掉（插件按"计划还在"算该戴标记）；
#     ③ 残留的 cancel.flag 会把**下一趟车**在上车那一刻就拦下来。
#   ⇒ 「已取消」和「待执行」不能同时成立。结束就是结束，收尾要做干净。
#
# 【为什么删之前先核对 planId】
#   老助手的计划是"启动时读一次"，中途可能有新的一班车已经写进同一个 plan.json。
#   这时**绝不能**把新班车的计划删掉 —— 那正是"静默把别人的锁抹掉"那类事故。
#   所以：只有"现在盘上这份确实还是我这一趟"才删；不是就只记一行日志、什么都不碰。
# ══════════════════════════════════════════════════════════════════════════════
function Close-Trip {
  param([switch]$KeepCancelFlag)
  # ① 计划文件：还是我这一趟才删
  try {
    if (Test-Path -LiteralPath $PlanFile) {
      $nowPlan = Read-JsonFile -Path $PlanFile
      $nowId = if ($nowPlan) { [string]$nowPlan.planId } else { '' }
      if ([string]::IsNullOrEmpty($nowId) -or $nowId -eq $planId) {
        Remove-Item -LiteralPath $PlanFile -Force
        Write-Log ('[正主] 已封口：计划文件已删（单号 {0}）—— 状态工具不会再报"有待执行的重启"。' -f $planId)
      } else {
        Write-Log ('[正主] 计划文件里换了新的一趟（现在是 {0}，我这一趟是 {1}）—— **不动它**，只清我自己该清的。' -f $nowId, $planId)
      }
    }
  } catch {
    Write-Log ("[正主] 删计划文件时出错（不致命）：{0}" -f $_.Exception.Message)
  }
  # ② 取消标记：默认一起清掉（它只对"还在等的那一趟"有意义）
  if (-not $KeepCancelFlag) {
    try {
      if (Test-Path -LiteralPath $cancelFile) {
        Remove-Item -LiteralPath $cancelFile -Force
        Write-Log '[正主] 已清掉 cancel.flag —— 不留到下一趟去拦人。'
      }
    } catch {
      Write-Log ("[正主] 清 cancel.flag 时出错（不致命）：{0}" -f $_.Exception.Message)
    }
  }
  # ③ 人工放行标记：同样默认清掉（它只对"还在等的那一趟"有意义，
  #    留着会把**下一趟**在开始等家务时立刻放行 —— 那不是用户的意思）
  if (-not $KeepCancelFlag) {
    try {
      if (Test-Path -LiteralPath $forceFile) {
        Remove-Item -LiteralPath $forceFile -Force
        Write-Log '[正主] 已清掉 force.flag —— 不留到下一趟去误放行。'
      }
    } catch {
      Write-Log ("[正主] 清 force.flag 时出错（不致命）：{0}" -f $_.Exception.Message)
    }
  }
}

# ── 状态窗模块：顶层点源，只做一次 ───────────────────────────────────────────
# ⚠️⚠️ 这段**必须在脚本顶层**（不能放进任何 function 里）——理由见下面 ～L302 的长注释，
#     那正是 2026-10-11 修掉的那个 bug（函数内点源 → 模块函数随函数返回消失 → 全程静默）。
# ⚠️ 位置也讲究：要**在 $script:LogPath 设好之后**（不然这里的诊断进不了 helper.log），
#     同时要**在三种身份分支之前**（保险丝/点火器/正主都看得见这些函数）。
$script:WinModLoaded = $false
try {
  $winMod = Join-Path $PSScriptRoot 'dsh-restart-window.ps1'
  if (Test-Path -LiteralPath $winMod) {
    . $winMod
    # 点源完立刻自检：模块的关键函数真的在不在？（不在就别让后面白忙）
    $need = @('Show-RestartWindow', 'Set-RestartWindowStage', 'Disarm-RestartWindowAbort', 'Close-RestartWindow', 'Set-RestartWindowForce')
    $missing = @($need | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) {
      $script:WinModLoaded = $true
    } else {
      Write-Log ('[状态窗] 顶层点源后仍缺函数：{0} —— 窗口功能不可用（重启照做）。' -f ($missing -join '、'))
    }
  } else {
    Write-Log ('[状态窗] 模块文件不在（{0}）—— 不显示窗口，重启照做。' -f $winMod)
  }
} catch {
  Write-Log ('[状态窗] 顶层点源出错（不影响重启）：' + $_.Exception.Message)
}

# 「别人在不在忙」的判断窗口（秒）。默认 120 秒。
#
# ⚠️ 为什么不能沿用 idleSeconds（2026-10-08 实测发现的漏洞）：
#   两段式是先等"这一轮说完"（要 idleSeconds 秒安静），**之后**才去看别人。
#   如果看别人也用同一个窗口，那么"和本脚本同时在干活的人"等到本脚本安静下来时，
#   对方的文件也已经老了 idleSeconds 秒 → **正好被漏掉**。
#   所以"没有权威数据时"看别人要用**更宽的窗口**（默认 2 分钟），才不会漏。
#
# ⚠️ 但**权威数据在场时不用它**（2026-10-08 修）：那时用窄窗口（idleSeconds），
#   否则会把"很久以前写过一次、早就停了"的会话误判成"正在干活"而白白放弃重启。
#   实际取哪个窗口在下面扫描处按 $stateAuthoritative 决定（见 ②-b）。
$othersWindowSec = if ($null -ne $plan.othersWindowSeconds) { [double]$plan.othersWindowSeconds } else { 120 }

# 会话记录根目录：用于"直接看盘上谁在写"那条独立判断（见闲置判定 ③）。
# 计划里没给就从会话文件反推；再不行退回 <DSH家目录>\sessions。
$sessionsRoot = [string]$plan.sessionsRoot
if (-not $sessionsRoot -and $sessionFile) {
  # 形如 ...\sessions\<工作区>\<会话id>\session*.jsonl.zstd → 往上三层就是 sessions
  try { $sessionsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $sessionFile)) } catch { }
}
if (-not $sessionsRoot) {
  $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $sessionsRoot = Join-Path $dshHome 'sessions'
}

# 会话"身份档案"目录：用来区分「子代理（家务）」和「别人的真对话」。
# DSH 自己写的，见 Test-IsSubagentSession 的说明。插件那侧报的 runningSubagents 更准，
# 但改动插件要重启宿主才生效 —— 这条路径**立刻**可用，作为兜底。
$subagentCacheRoot = if ($env:DSH_HOME) {
  Join-Path $env:DSH_HOME 'storages\session_projcache\sessions'
} else {
  Join-Path $env:USERPROFILE '.dsh\storages\session_projcache\sessions'
}
# 计划里可以覆盖（**仅自测用**：让测试指向假档案目录，绝不读到真实会话的身份档案）
if ($plan.subagentCacheRoot) { $subagentCacheRoot = [string]$plan.subagentCacheRoot }

# ── 「全覆盖身份档案」目录（2026-10-10 加，修根因①）────────────────────────────
# 为什么需要第二个来源：上面那个 session_projcache **只是 GUI 的投影缓存** ——
#   只有"在界面上列出来过"的会话才有档案。实测这台机器上它是 573 个，
#   而其中**只有 298 个子代理**认得出；实机 619 个子代理里有 320 个根本没档案
#   → Test-IsSubagentSession 返 $false → 被当成"别人的真对话" → 白白放弃重启
#   （2026-10-10 13:29 / 14:01 两次误判就是这么来的）。
#
# 而 session_projcache_archive_manager_v2 是**全量**的：实测 915 个档案 ≈ 915 个会话，
#   子代理覆盖 619/619（identity 有值 99%）、真对话误判 0/295，
#   而且**近实时**（档案 mtime 与会话文件 mtime 滞后中位 0 秒、最大 11 秒）。
#   → 拿它当主判据，认子代理当场就准。
#
# ⚠️ 它的文件名是**哈希**（session__0Ws2d_SAjIE7W…），拿会话 id 去拼路径或做 glob
#    **永远匹配不到**（当初就是在这里看错了，才以为"档案里没有"）。
#    所以必须读文件**内容**里的 record.sessionId 建映射 —— 这正是下面的 Get-SubagentArchiveMap。
$subagentArchiveRoot = if ($env:DSH_HOME) {
  Join-Path $env:DSH_HOME 'storages\session_projcache_archive_manager_v2\sessions'
} else {
  Join-Path $env:USERPROFILE '.dsh\storages\session_projcache_archive_manager_v2\sessions'
}
# 计划里可以覆盖（**仅自测用**，同上）
if ($plan.subagentArchiveRoot) { $subagentArchiveRoot = [string]$plan.subagentArchiveRoot }

function Save-Result {
  param([string]$Outcome, [string]$Detail, [double]$TookSeconds, [string]$Who = 'helper')
  $payload = [ordered]@{
    planId      = $planId
    outcome     = $Outcome          # success / failed / cancelled
    detail      = $Detail
    by          = $Who              # helper（正主）/ watchdog（保险丝）
    startedAt   = [string]$plan.createdAt
    finishedAt  = (Get-Date).ToString('o')
    tookSeconds = [math]::Round($TookSeconds, 1)
    forced      = [bool]$script:Forced
    newPid      = [int]$script:NewPid
    # ⚠️ 2026-10-24 修（维护记录里的一次事故）：这里原来写的是 `$port` —— 那是**计划里的端口**（重启前那个）。
    #   而上面 detail 里用的是 `$script:ActualPort`（重启后真端口）。同一次调用两个变量，
    #   于是出现"detail 写 9184、port 字段还是 1807"这种**会骗人**的记录。
    #   ⇒ 一律用 ActualPort。它在"没起来"的分支里仍是初值（= $port），所以失败/取消记录**行为不变**。
    port        = $script:ActualPort
    reason      = [string]$plan.reason
    pid         = $PID
    # ★ 2026-10-12 新增：**把"是哪个会话请求的重启"抄进结果里**
    #
    #   为什么要加这一个字段（2026-10-12 定下的设计）：
    #   重启完想让 Agent "自己醒过来接着干"，就得知道**该叫醒哪个会话**。
    #   这个信息重启前本来就有（计划文件里的 requestedBy），但重启一结束
    #   计划文件就被删了（见上面几处 Remove-Item $PlanFile），于是启动后就丢了。
    #
    #   ⚠️ 早期版本想"再开一个接力棒文件"，这个方案当场被否掉了：
    #      "不太想要这个接力棒文件，没有更好的方案吗？"
    #      —— 那个判断是对的：last-run.json 已经记着 reason（要干什么），
    #      只差"叫醒谁"。**补一个字段就够了，不该多一个文件、多一处要维护的状态。**
    requestedBy = [string]$plan.requestedBy
    # ── ★ 2026-10-22 新增：**把整份名单抄进结果里**（排队重启的唤醒依据）────────
    #
    # 【为什么必须抄一份】
    #   插件重启后要靠这份结果决定"叫醒谁"。老实现只抄了 requestedBy 一个人
    #   （一问一换一），排队之后那样会让其他人**排了队却永远醒不过来**。
    #
    # 【为什么不能等插件去读 plan.json】
    #   计划文件在发车前就被删了（全脚本 6 处 Remove-Item $PlanFile），回来时早没了。
    #   这也是 10-12 当年"再开一个接力棒文件"被否掉后定下的做法：**补字段，不新增文件**。
    #
    # 【每个人的 resume 都要带上】
    #   A 可能选了续接、B 选了不续接 —— 唤醒时要挨个看，不能一刀切。
    members     = @($script:Members | ForEach-Object {
                    [ordered]@{
                      sessionId   = [string]$_.sessionId
                      reason      = [string]$_.reason
                      resume      = $_.resume
                      source      = [string]$_.source
                    }
                  })
    # ★ 2026-10-13 新增：**本次要不要续接**（排重启时选的那一项，原样转交给插件）。
    #
    #   为什么要有它：续接在多数情况下是对的（活没干完），但**收尾型重启**不该叫醒 ——
    #   活已经干完了，把人叫起来反而莫名其妙。这个选择**由排重启的模型自己定**，
    #   写在计划里（plan.resume），但计划文件重启完就被删了，所以必须抄进结果文件，
    #   否则插件起来后无从知道"这一趟到底要不要叫醒"。
    #   缺字段时按 $null 走（= 老计划，交给插件用默认值判定，行为与以前一致）。
    #   ⚠️ 2026-10-22：有 members 时插件会**挨个看每个人的 resume**，这个字段只对老记录生效。
    resume      = $plan.resume
  }
  [void](Write-JsonFile -Path $lastRunFile -Value $payload)

  # ★ 2026-10-13 新增：**每次重启往 history.jsonl 追一行**（供人看趋势用）。
  #
  #   【为什么要有它】
  #     last-run.json 是"当前状态"，每次整张覆盖、**只留最后一次**；
  #     plugin.log 里那行"耗时 Ns"也不是每次都有（见 lib\index.js 里 reportLastRun 的说明）。
  #     于是"这台机器重启到底要多久、最近是不是变慢了"这种事**没有任何地方能查**。
  #     2026-10-12 提的"基准"方案虽然被否掉了（改成"起来了没有"就不需要猜时间了），
  #     但"**把每次的数字留一份**"这件事本身是有价值的 —— 它是**事实**，不是推测。
  #
  #   【为什么不新建一个文件、而是追加式】
  #     明确否掉过"再加一个状态文件"（原话是"不太想要这个接力棒文件"）。
  #     这里保持同样的克制：**只追加、不维护**，一行一个 JSON，坏了也不影响任何流程
  #     （读的人自己跳过错行）。所以它不是"又一处要维护的状态"，只是一本流水账。
  #
  #   【只记事实，不做推断】
  #     记：什么时候、什么结果、总耗时、**关掉→起来那一段**、是不是保险丝救的场。
  #     不记：平均值、基准、预测 —— 那些是读的人现算的（按需优于自刷）。
  #
  #   ⚠️ 追加失败**绝不许影响重启**：整段包 try/catch，而且放在 Save-Result 最前面做完的事之后。
  try {
    $downToUp = $null
    if ($script:DownAt -and $Outcome -eq 'success') {
      $downToUp = [math]::Round(((Get-Date) - $script:DownAt).TotalSeconds, 1)
    }
    $row = [ordered]@{
      planId      = $planId
      finishedAt  = (Get-Date).ToString('o')
      outcome     = $Outcome
      by          = $Who
      tookSeconds = [math]::Round($TookSeconds, 1)
      # 关掉 → 端口回来（秒）。只有成功重启才有值；其余为 $null。
      downToUpSeconds = $downToUp
      # ★ 2026-10-24 新增（维护记录里的一次事故）：**记下这次到底是哪个端口**。
      #   为什么补它：`restart_status` 报"这台机器重启要多久"时会读这本流水账，
      #   而端口是会变的（DSH 用 `--port 0` 自己挑，实测一次从 1807 整组换到 9184 整组）。
      #   没有这一项，事后翻流水账只能看到耗时、看不到"那次起来在哪个端口"。
      #   ⚠️ 与上面 last-run.json 的 port 字段**同一个来源**（$script:ActualPort），
      #      别一处改了一处忘了 —— 那正是本次要修的那类毛病。
      port        = $script:ActualPort
      reason      = [string]$plan.reason
    }
    $histPath = Join-Path (Split-Path -Parent $lastRunFile) 'history.jsonl'
    # ⚠️ 用 JSON 单行 + `n 追加（不是整张覆盖）。UTF-8 无 BOM。
    $line = ($row | ConvertTo-Json -Compress -Depth 4)
    [System.IO.File]::AppendAllText($histPath, $line + "`n", (New-Object System.Text.UTF8Encoding $false))
  } catch { }

  # ★ 2026-10-11 新增：**失败时在桌面写一份"给人看"的报告**（这是当时的明确需求）
  #
  #   需求原话："希望重启失败了，它能生成个报告什么的" + "报告直接放桌面"。
  #   为什么放桌面：DSH 起不来的时候，**桌面上能看到的东西才是可用的** ——
  #   报告藏在某个文件夹里得自己找过去，那正是最不方便的时候。
  #
  #   为什么挂在 Save-Result 里而不是各个调用点：
  #   失败出口有 4 处（正主前置闸没过 / 拉起失败 / 关完之后才发现 exe 没了 /
  #   保险丝也没救成），挂在这里**一处覆盖全部**，也不会漏。
  #
  #   ⚠️ 只有 failed 才写：skipped-busy（没做成但本设计故意不动）和 cancelled
  #      （主动取消的）都**不算故障**，不该在桌面堆文件吓人。
  #   ⚠️ 写报告失败**绝不许影响重启流程**：整段包 try/catch。
  #
  #   ★★ 自测保护（2026-10-11 加，被自己的测试坑出来的）★★
  #   自测会把主程序指向**假 exe**（甚至故意指向不存在的路径），于是必然走到 failed →
  #   报告就写到**真实的桌面**上去了。实测：跑几轮测试后桌面多出 4 份"DSH重启失败"的假报告，
  #   打开电脑的人会以为真出事了。
  #
  #   三道闸，任一生效就不写桌面（按优先级）：
  #     ① 计划字段 reportDir          —— 单个测试想指定落点时用
  #     ② 环境变量 DSH_SR_REPORT_DIR  —— 测试跑批设一次（保护"普通子进程"路径）
  #     ③ ★ **计划文件本身在系统临时目录里 = 自测** → 写到计划旁边
  #
  #   ⚠️ 为什么必须有第 ③ 条（实测踩到才知道）：
  #     原以为有 ② 就够了，结果测试**照样往桌面写**。
  #     真因：本脚本起来后会用 **WMI 再脱离一次**（那是它的核心机制），
  #     而 **WMI 创建的进程不继承调用方的环境变量** ——
  #     实测：普通子进程看到 `[C:\MARKER-VALUE]`，WMI 子进程看到 `[]`（空）。
  #     所以环境变量根本传不进去。只有"跟着计划文件走"的判据才拦得住。
  #     第 ③ 条用的就是计划文件自己的路径 —— 它必然在，且必然被传下去。
  #
  #   ⚠️ 第 ③ 条为什么安全（两个前提都实测过）：
  #     · 实机计划文件在 `~\.dsh\self-restart\plan.json` → **不在** TEMP 下 → 照旧写桌面 ✓
  #     · 实机 DSH_HOME（如 `C:\Users\<用户名>\.dsh`）→ **不在** TEMP 下 → 不会误判 ✓
  #     （万一以后有人把 DSH_HOME 设到 TEMP 下，这条会失效 —— 那种情况下
  #       报告会写到计划旁边而不是桌面。属于"少见的配置"，可以接受，但要记得。）
  #
  #   —— 通用教训：**凡是"往用户可见处写文件"的功能，自测都必须能改变它的落点。**
  #      而且"能不能改"要用**实测**确认（那次就是假设环境变量够用，结果不够）。
  if ($Outcome -eq 'failed') {
    $rptDir = ''
    if ($plan -and $plan.reportDir) { $rptDir = [string]$plan.reportDir }
    if (-not $rptDir -and $env:DSH_SR_REPORT_DIR) { $rptDir = [string]$env:DSH_SR_REPORT_DIR }
    if (-not $rptDir) {
      # ③ 计划文件落在系统临时目录 → 判定为自测，报告写到计划旁边
      try {
        $tmpRoot = [System.IO.Path]::GetTempPath()
        $planFull = [System.IO.Path]::GetFullPath($PlanFile)
        if ($planFull.StartsWith($tmpRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
          $rptDir = Split-Path -Parent $planFull
        }
      } catch { }
    }
    try { Write-FailureReport -Detail $Detail -Who $Who -TookSeconds $TookSeconds -OutDir $rptDir } catch { }
  }
}

# ── 失败报告：写一份"给人看"的纯文字说明，放桌面 ────────────────────────────
#
#  写给谁的：**没有技术背景的使用者**，而且是在"DSH 已经起不来"的最坏时刻。
#  所以要求：
#    · 第一段先说"现在该做什么"（点哪个图标），别一上来就是技术细节
#    · 用大白话，不出现端口号、PID、planId 这类词（那些放后半段给维护者）
#    · 文件名带时间，一眼知道是哪一次
#    · **绝不写密钥**（本报告只有路径和状态，没有凭据）
function Write-FailureReport {
  # ⚠️ $OutDir 是**给自测用的**：正常情况不传，报告就写到桌面（产品设计的默认落点）。
  #    自测传一个临时目录，免得测试在你桌面上堆一堆"重启失败"的假报告吓人。
  param([string]$Detail, [string]$Who, [double]$TookSeconds, [string]$OutDir = '')

  # 桌面路径：优先用系统的"桌面"位置（该位置可能被改过），拿不到就退回默认
  $desk = $OutDir
  if (-not $desk) {
    try {
      $desk = [Environment]::GetFolderPath('Desktop')
    } catch { }
    if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $path  = Join-Path $desk ("DSH重启失败-$stamp.txt")

  # ★ 同一秒内可能写第二份（例：正主先失败、紧接着保险丝也失败）——
  #   文件名精确到秒会撞上，**后一份把前一份覆盖掉**（2026-10-11 自测抓到）。
  #   所以撞了就加 -2、-3… 一直到不撞为止。绝不覆盖已有报告。
  if (Test-Path -LiteralPath $path) {
    for ($i = 2; $i -le 99; $i++) {
      $alt = Join-Path $desk ("DSH重启失败-$stamp-$i.txt")
      if (-not (Test-Path -LiteralPath $alt)) { $path = $alt; break }
    }
  }

  $byText = if ($Who -eq 'watchdog') { '保险丝' } else { '重启助手' }
  $lines = New-Object System.Collections.Generic.List[string]

  $lines.Add('DSH 自动重启失败')
  $lines.Add('=' * 46)
  $lines.Add('')
  $lines.Add(('时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
  $lines.Add(('谁报的：{0}' -f $byText))
  $lines.Add('')
  $lines.Add('【现在该做什么】')
  $lines.Add('')
  $lines.Add('  双击桌面上的「DeepSeek Harness」图标，把 DSH 打开就行。')
  $lines.Add('')
  $lines.Add('  （如果用的是便携版 / 绿色版，就到你放它的那个文件夹里双击主程序。）')
  $lines.Add('')
  $lines.Add('  打开之后，这次没做成的原因会自动出现在对话里。')
  $lines.Add('')
  $lines.Add('【出了什么事】')
  $lines.Add('')
  $lines.Add(('  {0}' -f $Detail))
  $lines.Add('')
  $lines.Add('【给维护者看的信息】')
  $lines.Add('')
  $lines.Add(('  单号      ：{0}' -f $planId))
  $lines.Add(('  结果      ：failed（{0}）' -f $byText))
  $lines.Add(('  耗时      ：{0} 秒' -f [math]::Round($TookSeconds, 1)))
  $lines.Add(('  主程序    ：{0}' -f $dshExe))
  $lines.Add(('  端口      ：{0}' -f $port))
  $lines.Add(('  重启原因  ：{0}' -f ([string]$plan.reason)))
  $lines.Add('')
  $lines.Add(('  详细日志  ：{0}' -f $script:LogPath))
  $lines.Add(('  上次结果  ：{0}' -f $lastRunFile))
  $lines.Add('')
  $lines.Add('【可能的原因（按常见程度排）】')
  $lines.Add('')
  $lines.Add('  · 主程序被移动或删掉了 —— 报告上面"主程序"那行就是它期望的位置')
  $lines.Add('  · 杀毒软件拦了启动动作')
  $lines.Add('  · 端口被别的程序占了（少见）')
  $lines.Add('  · 机器太忙，没能在规定时间内起来')
  $lines.Add('')
  $lines.Add('（这份报告由 DSH 自我重启插件自动生成，可以随时删除。）')

  $enc = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllLines($path, $lines, $enc)
  Write-Log ('[报告] 已写失败报告：{0}' -f $path)
  return $path
}

# ══════════════════════════════════════════════════════════════════════════
# 身份③：保险丝
#   正主在"关掉 DSH 之后、拉起之前"这个窗口里死掉的话，就没人管了。
#   保险丝只做一件事：过一会儿看看端口在不在；不在就把 DSH 拉起来。
# ══════════════════════════════════════════════════════════════════════════
if ($Watchdog) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $script:Forced = $false
  $script:NewPid = 0
  # ★ 2026-10-17：新进程树实际在听的端口。初值 = 计划里的端口（老行为），
  #   救起来之后会被 Wait-ForPort 那段改成真值。
  $script:ActualPort = $port
  $myPidNum = $PID
  Write-Log ("[保险丝] 上岗 PID={0}：开始守候（不再是『盲睡 25 秒就撤』，见下面的说明）。" -f $myPidNum)

  # ⚠️ 保险丝的职责边界（2026-10-08 定下"绝不强制重启"后重新划清）：
  #    它**只**该管一件事 —— 正主把 DSH 关掉之后自己死了，没人拉起来。
  #    它**绝不能**在正主还在"等空闲"的时候插手，否则就成了"绕过等待的强制重启"。
  #
  #    怎么分辨这两种情况？
  #      · 正主还在等 → DSH **还活着**（端口在听）→ 保险丝什么都不做（**但继续守着**）。
  #      · 正主已关掉 DSH 后死了 → 端口**没人听** + 正主也不在了 → 这才轮到保险丝。
  #    所以下面这个循环**必须**先确认"正主已经不在跑了"，再考虑动手。
  #    另外：正主放弃时会写 outcome=skipped-busy 到 last-run.json，
  #    保险丝看到它就该收工，不能自己补一刀。

  # ══════════════════════════════════════════════════════════════════════
  #  ★★★ 2026-10-11 重写观测循环：从"盲睡 25 秒 + 最多 4 轮"改成"守到本次重启确实结束" ★★★
  #
  #  【为什么必须改 —— 实测证据，不是推测】
  #    老逻辑每轮第 ① 件事就是：`if (端口在听) { 本进程撤 }`。
  #    可是**正主等待期间端口本来就是通的** —— 所以保险丝几乎总是刚醒就撤。
  #    实测 24 次运行：**救场 0 次、判过"该它管" 0 次**，
  #    24 次全是同一句「端口已经在监听 —— DSH 活着，跟它无关，它撤」。
  #    而正主真正断电的时刻，实测在保险丝上岗后 **24～237 秒**（11 次样本）
  #    —— 也就是说它**每一次都在危险窗口之前就走了**。
  #    唯一该救命的装置，从来不在该在的位置上。
  #
  #  【正确的心智模型（这才是"守到 DSH 自己打开"）】
  #    · 「端口还在听」≠「没事了」，只等于「**这一轮不用本进程插手**」。
  #      因为正主随时可能把 DSH 关掉 —— **那一刻才是需要它的时候**。
  #    · 保险丝该退场的**唯一正常理由**是：这次重启**已经结束了**（计划文件没了）。
  #    · 需要它动手的**唯一场面**是：端口没人听 **且** 正主也不在了。
  #
  #  【守多久 —— 按这次计划实际允许的时长算，不再拍脑袋】
  #    正主最多等 maxWaitMinutes，然后确认窗、关进程、清残留、等端口释放，
  #    再算上拉起重试的总上限。给它配够预算，并留余量。
  #    另设硬上限，防"计划文件被泄漏/没人删"时永远不退（那是孤儿进程的来源）。
  # ══════════════════════════════════════════════════════════════════════
  $confirmSec = 10
  if ($null -ne $plan.confirmSeconds) { try { $confirmSec = [int]$plan.confirmSeconds } catch { } }

  # 分步算，别写成一整个跨行表达式：
  #   PowerShell 里跨行表达式虽然合法，但**表达式中间夹 # 注释**会让解析器报
  #   "表达式中缺少右括号"（本次实测踩到）。分步写还更好读。
  $waitBudget  = [int]($maxWaitMinutes * 60)              # 正主最多等这么久
  $closeBudget = 60                                       # 关进程 + 清残留 + 等端口释放（给充裕）
  $bootBudget  = [int]($bootTimeout * $maxAttempts)       # 拉起重试的总上限
  $watchBudgetSec = $waitBudget + $confirmSec + $closeBudget + $bootBudget + 60
  if ($watchBudgetSec -lt 120) { $watchBudgetSec = 120 }        # 底线 2 分钟
  $hardCapSec = 20 * 60                                          # 硬上限 20 分钟
  if ($watchBudgetSec -gt $hardCapSec) { $watchBudgetSec = $hardCapSec }
  # ★ 2026-10-17：这行日志原来写"只要端口在听我就不插手"，现在判据已放宽成
  #   "DSH 还活着"（端口在听 或 进程还在），措辞跟着改 —— 否则日志会骗人。
  Write-Log ("[保险丝] 守候预算 {0} 秒（按这次计划算出来的）。这段时间里只要 DSH 还活着我就不插手，但不走人。" -f $watchBudgetSec)

  $rounds = 0
  $fixed = $false
  $rescueTries = 0
  $maxRescueTries = [Math]::Max(1, $maxAttempts)
  $watchStart = Get-Date
  $noPidLogged = $false

  while ($true) {
    $rounds++
    $elapsedSec = [int]((Get-Date) - $watchStart).TotalSeconds

    # ⓪ 这次重启已经结束？—— 保险丝**唯一**的正常退场理由
    if (Test-PlanFileGone) {
      Write-Log ('[保险丝] 计划文件已经没了（这次重启已结束）—— 我撤。共守了 {0} 秒。' -f $elapsedSec)
      exit 0
    }

    # ⓪-b 超预算 → 退场。⚠️ 这是**安全方向**：宁可少做一次救援，
    #      也不能变成一个永远赖着不走的孤儿进程（2026-10-08 实测留下过孤儿）。
    if ($elapsedSec -gt $watchBudgetSec) {
      Write-Log ('[保险丝] 已经守了 {0} 秒（预算 {1} 秒），端口/正主状态仍不清楚 —— 我撤，不再等。' -f $elapsedSec, $watchBudgetSec)
      exit 0
    }

    # ① 每轮**重读**计划：正主可能刚写回 helperPid。
    #    ⚠️ 老逻辑用的是启动那一刻的快照（$plan），25 秒后还在用旧值 —— 会判断错。
    $planNow = Read-JsonFile -Path $PlanFile
    $mainPid = 0
    if ($planNow -and $null -ne $planNow.helperPid) {
      try { $mainPid = [int]$planNow.helperPid } catch { $mainPid = 0 }
    }

    # ② DSH 还在正常服务 → **这一轮不插手，但也不走人**。
    #    ★ 这就是本次修的核心：老逻辑在这里 `exit 0`，于是永远提前离场。
    #
    #    ★★ 2026-10-17 再改：判据从"配置端口在听"放宽成 Test-DshAlive
    #       （端口在听 **或** 进程还在）。原因见上面 Test-DshAlive 的注释：
    #       新版 GUI 端口是动态的，"19387 在不在听"永远为假 ——
    #       保险丝于是把活得好好的 DSH 判成死的，接着每轮救援先 Kill-AllDsh
    #       再拉一个，一轮一轮把所有人的 DSH 全杀掉（当晚真实发生）。
    #       方向上也对：这里判"活着"宁可松 —— 松了最多少救一次，
    #       紧了就是杀一个正在干活的 DSH。
    if (Test-DshAlive -ConfiguredPort $port) {
      if ($rounds -eq 1) {
        Write-Log '[保险丝] 上岗：DSH 活着（配置端口在听，或进程还在）—— 我不插手，继续守着。'
      } elseif ($rounds % 12 -eq 0) {
        Write-Log ('[保险丝] …仍在守（已 {0} 秒，DSH 还活着）。' -f $elapsedSec)
      }
      Start-Sleep -Seconds 5
      continue
    }

    # ── 端口没人听了 ──────────────────────────────────────────────────
    #    两种可能，含义完全相反：
    #      · 正主正在关/拉（正常）→ 它活着，别抢
    #      · 正主已经死了（异常）  → **这才是需要它上场的场面**
    $mainAlive = $false
    if ($mainPid -gt 0) {
      $mainAlive = [bool](Get-Process -Id $mainPid -ErrorAction SilentlyContinue)
    }

    # ③ 正主是不是"主动放弃/被取消"了？—— 只有**这次**的结果才算数。
    #    ⚠️ 老逻辑在这里有个坑：没核对单号，**上一次**残留的 cancelled/skipped-busy
    #       会让保险丝立刻误判"这次被取消了"而走人。所以必须比 planId。
    $last = Read-JsonFile -Path $lastRunFile
    if ($last -and ([string]$last.planId -eq $planId)) {
      if ($last.outcome -eq 'skipped-busy') {
        Write-Log '[保险丝] 正主是因为"一直有任务在跑"主动放弃的 —— 那就不该重启，我撤。'
        exit 0
      }
      if ($last.outcome -eq 'cancelled') {
        Write-Log '[保险丝] 正主是被取消的 —— 不该重启，我撤。'
        exit 0
      }
      if ($last.outcome -eq 'success') {
        Write-Log '[保险丝] 正主已经报成功了（计划文件却没删）—— 没我的事，我撤。'
        exit 0
      }
    }

    # ④ 判断不了正主 PID → 按安全方向：**不插手**，但继续守着
    #    （老逻辑这里是 exit 0，等于"判不了就走人"，会漏掉该救的场面）
    if ($mainPid -le 0) {
      if (-not $noPidLogged) {
        $noPidLogged = $true
        Write-Log '[保险丝] 计划里还没有正主 PID（它可能正在脱离/启动中）—— 我判断不了，先不插手，继续守。'
      }
      Start-Sleep -Seconds 5
      continue
    }

    # ⑤ 端口没人听、但正主还活着 → 它正在关或正在拉，别抢
    if ($mainAlive) {
      Write-Log ("[保险丝] 端口没人听，但正主还在（PID={0}）—— 它正在干活，我不插手。" -f $mainPid)
      Start-Sleep -Seconds 5
      continue
    }

    # ⑥ 轮到它上场了：端口没人听 + 正主也没了
    $rescueTries++
    if ($rescueTries -gt $maxRescueTries) {
      Write-Log ('[保险丝] 已经试过 {0} 次都没能拉起 DSH —— 不再重试，交给人处理。' -f $maxRescueTries)
      break
    }

    Write-Log ("[保险丝] 第 {0} 次救援：端口 {1} 没人听、正主（PID={2}）也没了 —— 这是该我管的场面。" -f $rescueTries, $port, $mainPid)
    if (-not (Test-Path -LiteralPath $dshExe)) {
      Write-Log ("[保险丝] 找不到主程序 {0}，无能为力。" -f $dshExe)
      break
    }
    # 先把可能卡住的残留清掉，免得撞端口
    Kill-AllDsh
    Start-Sleep -Seconds 2

    try {
      $created = Start-Dsh -Exe $dshExe -WorkDir $dshWorkDir
      if ($created -and $created.ReturnValue -eq 0) {
        $script:NewPid = [int]$created.ProcessId
        Write-Log ("[保险丝] 已创建进程 PID={0}，等端口…" -f $script:NewPid)
        if (Wait-ForPort -Port $port -TimeoutSeconds $bootTimeout -ProcId $script:NewPid) {
          # ★ 2026-10-17：记下新进程树**实际**在听的端口（重启后端口会重新分配）
          $newPorts = @(Get-ListeningPortsOfPids -ProcessIds @(Get-ProcessTreePids -RootPid $script:NewPid))
          if ($newPorts.Count -gt 0) { $script:ActualPort = [int]$newPorts[0] }
          Write-Log ('[保险丝] ✅ DSH 已恢复（端口 {0}）。' -f $script:ActualPort)
          $fixed = $true
          break
        }
        Write-Log '[保险丝] 这一轮没起来。'
      } else {
        $code = if ($created) { $created.ReturnValue } else { 'unknown' }
        Write-Log ("[保险丝] WMI 创建失败，返回 {0}。" -f $code)
      }
    } catch {
      Write-Log ("[保险丝] 出错：{0}" -f $_.Exception.Message)
    }
    Start-Sleep -Seconds 5
  }

  if ($fixed) {
    Save-Result -Outcome 'success' -Detail '保险丝把 DSH 拉回来了（正主确实中途失败了）' -TookSeconds $watch.Elapsed.TotalSeconds -Who 'watchdog'
    Write-Log '[保险丝] DSH 已由保险丝恢复。'
    exit 0
  }

  # ★ 2026-10-11 修：**不再无条件写 failed**。
  #
  #   老逻辑是 `if ($fixed) {...} else { Save-Result failed; exit 1 }`，
  #   也就是说：只要它没救场（含"根本没轮到它救，正主自己成功了"这种情况），
  #   就写一条" restart 失败"。
  #   后果：正主明明成功了，保险丝随后把这个成功**覆盖成 failed** →
  #   插件读到 failed → 在对话里报"自动重启失败，需要手动打开 DSH" →
  #   **假警报**，而且会让对话白白去手动开一个已经开着的 DSH。
  #
  #   正确做法：先看这次重启**到底什么结果**（以 last-run.json 里同单号的结果为准）：
  #     · 正主已报成功        → 本进程没活干，静静退场，**不写任何结果**
  #     · 正主已放弃/被取消   → 同上，那是它的决定，不覆盖
  #     · 正主没报结果且它没救成 → 才写 failed（这才是该它负责的场面）
  $final = Read-JsonFile -Path $lastRunFile
  if ($final -and ([string]$final.planId -eq $planId)) {
    Write-Log ('[保险丝] 这次重启已经有结论了（{0}），不需要我再写结果 —— 我撤。' -f ([string]$final.outcome))
    exit 0
  }

  Write-Log '[保险丝] 没能把 DSH 拉起来，而且正主也没留下结论 —— 需要人工介入。'
  Save-Result -Outcome 'failed' -Detail '保险丝也没能拉起 DSH，请手动打开' -TookSeconds $watch.Elapsed.TotalSeconds -Who 'watchdog'
  exit 1
}

# ══════════════════════════════════════════════════════════════════════════
# 身份①：还没脱离 → 把自己脱离出去，然后立刻退出
#
# ★ 2026-10-23：**干跑模式跳过脱离，就在当前进程里跑完**。
#   为什么：脱离的目的是"DSH 死了它还能活"。干跑根本不动 DSH，不需要这项能力，
#   而脱离会让输出和退出码都跑到子进程里 —— 调用方（人或测试）看不到结论，
#   干跑就失去了"先看一眼"的意义。
# ══════════════════════════════════════════════════════════════════════════
if (-not $Detached -and -not $DryRun) {
  try {
    $paths = Get-SelfPaths
    # 自测用的两个开关必须原样传给脱离出来的自己，否则它会退回默认值去关真 DSH
    $extra = ''
    if ($TargetProcessName -ne 'DeepSeek Harness') { $extra += (' -TargetProcessName "{0}"' -f $TargetProcessName) }
    if ($TargetCommandMatch) { $extra += (' -TargetCommandMatch "{0}"' -f $TargetCommandMatch) }
    $cmdLine = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -PlanFile "{2}" -Detached{3}' -f $paths.Ps, $paths.Self, $PlanFile, $extra

    $created = $null
    try { $created = Start-DetachedProcess -CommandLine $cmdLine -WorkDir $PSScriptRoot }
    catch { $created = Start-DetachedProcess -CommandLine $cmdLine }

    if ($created -and $created.ReturnValue -eq 0) {
      Write-Log ("已脱离：新进程 PID={0}（父级是 WmiPrvSE，DSH 死了它还在）" -f $created.ProcessId)

      # ⚠️ 脱离成功后**不要立刻退出**（2026-10-08 实测踩到）：
      #   点火器一 exit，刚出生的子进程有时会被**一起带走** —— 表现是
      #   helper.log 只留一行"已脱离"，之后啥都没有（子进程没来得及认领计划就死了）。
      #   对照实验：直接启动"脱离版"完全正常，只有"让它自己脱离"这条路会死。
      #   所以这里等子进程站稳（确认它真的把 PID 写回计划文件），再退出。
      try {
        $deadline = (Get-Date).AddSeconds(20)
        $childPid = [int]$created.ProcessId
        $standUp = $false
        while ((Get-Date) -lt $deadline) {
          Start-Sleep -Milliseconds 500
          # 子进程把 helperPid 写回计划文件 = 它已经站稳并认领了
          $p = Read-JsonFile -Path $PlanFile
          if ($p -and $p.helperPid) {
            $standUp = $true
            Write-Log ("脱离成功并已站稳（子进程 PID={0} 已认领计划）—— 点火器功成身退。" -f $p.helperPid)
            break
          }
          # 子进程自己没了 → 这次脱离白费，如实记下来（外面会判为失败）
          if ($childPid -gt 0 -and -not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) {
            Write-Log ("脱离出来的子进程（PID={0}）已经退出、且没认领计划 —— 这次脱离无效。" -f $childPid)
            break
          }
        }
        if ($standUp -and $childPid -gt 0) {
          # 再多给 2 秒，确保它彻底独立于本进程
          Start-Sleep -Seconds 2
        }
      } catch {
        Write-Log ("等待子进程站稳时出错（不影响它继续跑）：{0}" -f $_.Exception.Message)
        Start-Sleep -Seconds 3
      }
      exit 0
    } else {
      $code = if ($created) { $created.ReturnValue } else { 'unknown' }
      Write-Log ("脱离失败：WMI 返回 {0}。为安全起见不再往下走（否则可能杀掉 DSH 却没人拉起）。" -f $code)
      exit 2
    }
  } catch {
    Write-Log ("脱离时出错：{0}。为安全起见不再往下走。" -f $_.Exception.Message)
    exit 2
  }
}

# ══════════════════════════════════════════════════════════════════════════
# 身份②：正主
# ══════════════════════════════════════════════════════════════════════════
$myPid = $PID
$parentName = '?'
try {
  $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$myPid" -ErrorAction SilentlyContinue).ParentProcessId
  if ($parent) { $parentName = (Get-Process -Id $parent -ErrorAction SilentlyContinue).ProcessName }
} catch { }

Write-Log ('=' * 62)
Write-Log ("[正主] 开始执行：PID={0}，父进程={1}（不是 DSH 就对了）" -f $myPid, $parentName)
Write-Log ("[正主] 计划 {0}｜原因：{1}" -f $planId, $plan.reason)

# ── 状态窗：让"在等什么 / 进行到哪一步"可见（2026-10-10）────────────────────
# ⚠️ 在**认领计划之后、等闲置之前**就显示：排完重启最想看到的就是"它收到没有"。
#    放太晚（比如等闲置结束才显示）会让人对着空桌面干等。
# ⚠️ 这一步失败绝不拦路 —— Initialize-RestartWindow 内部已全部 try/catch。
$script:WindowShown = Initialize-RestartWindow -PlanFile $PlanFile -Plan $plan

# ── 单主锁：同一份计划只允许一个"正主"（2026-10-08 实测踩到）────────────────
# 为什么必须有：重复启动会造出**多个正主抢着杀 DSH**——实测出现过 3 个同时跑同一份
# 计划。它们会各自挂保险丝、各自判断、各自动手，场面完全失控。
# 锁的判据：计划文件里的 helperPid 是不是已经被**另一个还活着的**进程占了。
#   · 空 / 是自己   → 本进程来当正主
#   · 别人且还活着  → 已经有正主了，退出（让先来的干）
#   · 别人但已死掉  → 那个正主半路没了，接管（这不算抢）
try {
  $owner = $null
  if ($null -ne $plan.helperPid) { $owner = [int]$plan.helperPid }
  if ($owner -and $owner -ne $myPid) {
    $ownerAlive = [bool](Get-Process -Id $owner -ErrorAction SilentlyContinue)
    if ($ownerAlive) {
      Write-Log ("[正主] 已有正主在管这份计划（PID={0}，还活着）—— 我退出，不跟它抢。" -f $owner)
      exit 0
    }
    Write-Log ("[正主] 上一个正主（PID={0}）已经不在了 —— 我接管。" -f $owner)
  }
} catch {
  Write-Log ("[正主] 读锁失败（继续，按无锁处理）：{0}" -f $_.Exception.Message)
}

# 把自己的 PID 写回计划文件：既是**单主锁**，也让保险丝能分辨"正主还在等"还是"正主已经死了"。
# 不写的话保险丝没法判断，只能瞎猜 —— 而瞎猜的后果是绕过等待去强制重启。
try {
  $plan | Add-Member -NotePropertyName 'helperPid' -NotePropertyValue $myPid -Force
  [void](Write-JsonFile -Path $PlanFile -Value $plan)
  Write-Log ("[正主] 已认领这份计划（PID={0} 写回计划文件，供锁与保险丝用）。" -f $myPid)
} catch {
  Write-Log ("[正主] 写回 PID 失败（保险丝会退化为保守模式）：{0}" -f $_.Exception.Message)
}

$script:Forced = $false
# ★ 2026-10-24：用户点了「不等了」→ 跳过"等家务"这一段（不是强制关别人的对话）。
#   单独一个变量，别复用 $script:Forced（那个是保险丝救场的语义）。
$script:ForceSkipped = $false
$script:NewPid = 0
# ★ 2026-10-17：新进程树实际在听的端口（初值 = 计划里的端口，起来后改成真值）。
#   为什么需要：新版端口是动态的，重启后**不一定**还是计划里那个 ——
#   日志和 last-run.json 里必须写真的那个，否则报的是一个根本不存在的端口号。
$script:ActualPort = $port
# ★ 2026-10-13 新增：**"开始关掉 DSH"那一刻**，专门用来量"关掉 → 重新起来"这一段。
#   为什么单独量这一段：总耗时（tookSeconds）的大头是"等这一轮说完"+确认窗，
#   那两段跟机器快慢无关、每次差很多；**真正反映这台机器重启速度的只有这一段**，
#   它也是唯一有参考价值的数（历史实测 12~24 秒，中位 16 秒）。
$script:DownAt = $null
$script:SubagentArchiveRoot = $subagentArchiveRoot
$script:SubagentArchiveMap = @{}
$script:SubagentArchiveMapBuilt = $false
$watch = [System.Diagnostics.Stopwatch]::StartNew()

# ── 第 1 步：先把保险丝挂上 ────────────────────────────────────────────────
try {
  $paths = Get-SelfPaths
  # 自测开关同样要传给保险丝，否则它会拿默认进程名去找"真 DSH"
  $extra = ''
  if ($TargetProcessName -ne 'DeepSeek Harness') { $extra += (' -TargetProcessName "{0}"' -f $TargetProcessName) }
  if ($TargetCommandMatch) { $extra += (' -TargetCommandMatch "{0}"' -f $TargetCommandMatch) }
  $wdCmd = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -PlanFile "{2}" -Watchdog{3}' -f $paths.Ps, $paths.Self, $PlanFile, $extra
  $wd = Start-DetachedProcess -CommandLine $wdCmd
  if ($wd -and $wd.ReturnValue -eq 0) {
    Write-Log ("[正主] 保险丝已挂上（PID={0}）：万一我在关掉之后出事，它负责把 DSH 拉回来。" -f $wd.ProcessId)
  } else {
    Write-Log '[正主] 保险丝没挂上（不致命，但没有兜底了）。'
  }
} catch {
  Write-Log ("[正主] 挂保险丝出错（继续）：{0}" -f $_.Exception.Message)
}

# ── 第 2 步：等到计划时间 ──────────────────────────────────────────────────
if ($plan.scheduleAt) {
  try {
    $target = [datetime]::Parse([string]$plan.scheduleAt)
    $waitSec = ($target - (Get-Date)).TotalSeconds
    if ($waitSec -gt 1) {
      Write-Log ("[正主] 先等到 {0}（还有 {1:N0} 秒）" -f $target.ToString('HH:mm:ss'), $waitSec)
      $deadline = $target
      while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $cancelFile) {
          Write-Log '[正主] 等待期间收到取消标记 → 放弃（DSH 不动）。'
          Save-Result -Outcome 'cancelled' -Detail '等待计划时间期间被取消' -TookSeconds $watch.Elapsed.TotalSeconds
          Close-RestartWindowSafe -FinalStage 'cancelled' -FinalText '这次重启已经取消了，DSH 没有被动过。' -KeepSeconds 6
          Close-Trip   # ★ 2026-10-23：封口（见函数说明）
          exit 2
        }
        # 状态窗：告诉用户"在等什么、还有多久"（这个阶段可能等几十秒）——
        # 不给数字的话，会以为卡住了。
        $left = [int](($deadline - (Get-Date)).TotalSeconds)
        Set-RestartWindowStageSafe -Stage 'waiting' `
          -Detail ('已经收到重启请求，' + "`r`n" + '正在等到预定时间再动手。') `
          -EtaText ('大约还要 {0} 秒' -f ([Math]::Max(0, $left)))
        Start-Sleep -Seconds 3
      }
    }  } catch {
    Write-Log ("[正主] 计划时间看不懂（{0}），跳过等待。" -f $plan.scheduleAt)
  }
}

# ── 第 3 步：等"真闲下来" ──────────────────────────────────────────────────
# ⚠️ maxWaitMinutes 的语义（2026-10-08 澄清，原来是个坑）：
#    · > 0  → 最多等这么多分钟，等不到就**放弃**（绝不强制重启）
#    · 0    → **永远等**（一直等下去，绝不放弃、也绝不动手）
#    · < 0  → 非法，按"永远等"处理
#    原来 0 的含义没写清楚，容易被误读成"立刻放弃"。这里明确成"永远等"，
#    因为"永远等"是安全方向：宁可永远不重启，也不砍断正在干的活。
#    想让它"判忙就立刻放弃"的测试，应当传一个极小正数（如 0.01），而不是 0。
$waitForever = ($maxWaitMinutes -le 0)
if ($waitForever) {
  Write-Log ("[正主] 开始等闲置：**首选权威状态**（本会话 agent.status=idle 即视为这一轮说完）；" +
             "权威不可用时退回「连续 {0} 秒没有新动静」。maxWaitMinutes={1} → **一直等下去**（不会强制重启）。" -f $idleSeconds, $maxWaitMinutes)
} else {
  Write-Log ("[正主] 开始等闲置：**首选权威状态**（本会话 agent.status=idle 即视为这一轮说完）；" +
             "权威不可用时退回「连续 {0} 秒没有新动静」。最多等 {1} 分钟；等不到就放弃（不强制重启）。" -f $idleSeconds, $maxWaitMinutes)
}

$waitDeadline = if ($waitForever) { [datetime]::MaxValue } else { (Get-Date).AddMinutes($maxWaitMinutes) }

# 不管上面怎么设，都再压一道硬上限：助手进程不能无限期挂着。
# 到点就放弃（同样**不**强制重启），免得机器上长期躺着一个等待进程。
$hardCapHours = 12
$hardDeadline = (Get-Date).AddHours($hardCapHours)

$lastChangeAt = Get-Date
$lastMtime = $null
$tick = 0
# ★ 2026-10-23：上一轮算出的"别人在忙"的原因，留给**总超时文案**用。
#
# 【为什么需要它】总超时的判断（下面 `$now -ge $waitDeadline`）在循环里**靠前**，
#   而"别人在忙"的判定靠后。于是到点那一刻，超时分支拿不到忙因，
#   只能退化成"后台任务 N 个一直没跑完" —— 实测就出现过：
#   真正的拦路者是"还有 1 个别的会话在干活"，日志却只怪后台任务，**文案会骗人**。
$lastBusyText = ''
# 上一轮看到的后台任务数（超时文案要用它区分"没等到这一轮"和"后台任务没跑完"）。
$jobsRunning = 0
# 上一轮看到的家务子代理（同上；循环里每轮会重建，这里先给个空表免得超时分支读到 $null）。
$subagents = New-Object System.Collections.Generic.List[string]
# "把写过但已停的会话排除掉"这条参考信息，每份计划只记一次（见 ②-b）。
$staleNoticeLogged = $false
# "盘上在写的是家务子代理"这条参考信息，每份计划只记一次。
$subagentSeen = $false
# ★ 2026-10-10（修根因②）：上一轮扫盘时，每个会话文件的写入时间。
#   用来区分"写过一次就不动了"（单次无害写入，如 session/end-seed）和"还在持续写"（真在干活）：
#   只有**两轮之间时间戳还在往前走**才算"真的在动"。
#   见循环里 ②-b 的说明 —— 只在权威数据在场时用（那时不会漏掉真在跑的对话）。
$prevWrites = @{}
# 这一轮"第一次看见、还没确认"的会话数（>0 时**必须再等一轮**，绝不直接动手）。
# ⚠️ 必须先在这里声明：扫盘那段在 try 里，万一 sessionsRoot 不存在整段被跳过，
#    下面的判定会读到未定义变量 —— 那会让"待确认"静默失效、直接动手（危险方向）。
$pendingCount = 0

# ══════════════════════════════════════════════════════════════════════════════
# 【2026-10-23 加】等待循环的"死亡记录"
#
# 【为什么必须有它 —— 拿一次真实的静默死亡换的】
#   2026-10-23 00:36 那次实机验证：助手正常启动、正常等空闲、每 5 秒记一行
#   "…已等 N 分钟；还有别人在忙 —— 继续等"，然后 **00:41:06 之后突然一个字都不写了**，
#   进程消失、**没有任何退出记录**，状态窗也跟着不见了。
#   表现看起来像"重启取消了"，用户完全不知道发生了什么。
#
# 【根因（两个叠在一起才会静默）】
#   ① 本脚本第 82 行设了 `$ErrorActionPreference = 'Stop'` —— 任何一条命令出错
#      都会当致命错误抛出；
#   ② 这个 while 循环**整体没有任何 try/catch 包着**，于是等待途中任何一个小异常
#      （读状态文件、扫盘、问 CIM 进程……）都会**直接穿出脚本**；
#   ③ 脚本又跑在 `-WindowStyle Hidden` 下 —— 错误文本没有地方可去，就这么没了。
#   ⇒ 三条加起来 = 「静默死亡」。这正是本仓反复记的那条："失败必须留痕，不能靠猜"。
#
# 【这里做的两件事（都不改变任何判定逻辑）】
#   ① 把"正在等"这件事定期落到 last-run.json（outcome=waiting）——
#      这样**即使脚本被硬杀**，盘上也留着"它活到哪一秒、当时在等谁"。
#   ② 把整个等待循环包进 try/catch：单轮出错**只记一笔、继续等**，
#      绝不让一次读文件失败把整趟重启静默带走。
#      例外：如果出错是因为"计划文件被删了/被取消"，那本来就该退，正常走。
# ══════════════════════════════════════════════════════════════════════════════

# 记录"活到哪一秒"的最小账本。
#
# ⚠️⚠️ **绝不能写 last-run.json**（第一版差点这么写，被本仓既有铁律拦住）：
#   lib\index.js 里写得很清楚 —— 插件**只读** last-run.json、绝不写它，
#   为的是把"谁写这个文件"从 2 个降到 1 个（只剩助手），避免读-改-写把新结果回滚。
#   助手这边如果拿心跳去覆盖它，就等于把"上次重启的真实结果"亲手擦掉，
#   `restart_status` 读到的会是假的。⇒ 心跳单开一个文件 helper-heartbeat.json。
#
# 这个文件的用途只有一个：**出事以后能知道它活到哪一秒、当时在等谁**。
# 产品逻辑不依赖它（插件不读），所以它坏了也不会影响重启。
$waitHeartbeatSeconds = 30
$lastHeartbeatAt = Get-Date
function Write-WaitHeartbeat {
  param([string]$Detail, [double]$Elapsed)
  try {
    if (-not $PlanFile) { return }
    if (-not (Test-Path -LiteralPath $PlanFile)) { return }
    $hb = [ordered]@{
      planId     = $planId
      state      = 'waiting'
      detail     = $Detail
      updatedAt  = (Get-Date).ToString('o')
      waitedSecs = [math]::Round($Elapsed, 1)
      pid        = $PID
    }
    $hbPath = Join-Path (Split-Path -Parent $lastRunFile) 'helper-heartbeat.json'
    # 原子写：先写 .tmp 再 Move（本仓既有做法，防别人读到半截 JSON）
    $tmp = $hbPath + '.tmp'
    ($hb | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $hbPath -Force
    $script:LastHeartbeatAt = Get-Date
  } catch {
    # 心跳失败绝不能影响重启本身（也不许把 $ErrorActionPreference='Stop' 引爆）
  }
}

while ($true) {
  $tick++
  # 循环体整体包 try：单轮出错只记账、下一轮继续等（见循环末尾 catch 里的说明）。
  # ⚠️ exit 不受影响 —— exit 不是异常，会正常穿出去。
  try {
  if (Test-Path -LiteralPath $cancelFile) {
    Write-Log '[正主] 收到取消标记 → 放弃（DSH 不动）。'
    if (@($script:Members).Count -gt 1) {
      Write-Log ('[正主] ⚠️ 这趟车上有 {0} 个人 —— 取消是**整趟**的，他们的这次重启一起作废。' -f @($script:Members).Count)
    }
    Save-Result -Outcome 'cancelled' -Detail '闲置等待期间被取消' -TookSeconds $watch.Elapsed.TotalSeconds
    Close-RestartWindowSafe -FinalStage 'cancelled' -FinalText '这次重启已经取消了，DSH 没有被动过。' -KeepSeconds 6
    Close-Trip     # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）—— 不做就会"已取消"和"待执行"同时成立
    exit 2
  }

  # 计划文件不见了 = 这次重启已经结束（被别处收尾/清理了）→ 立刻退出，别当孤儿。
  # （2026-10-08 实测：清理测试后留下了没退干净的正主进程，就是缺这一条。）
  if (-not (Test-Path -LiteralPath $PlanFile)) {
    Write-Log '[正主] 计划文件已经没了 —— 这次重启已被收尾，我退出。'
    exit 0
  }

  # ── ★ 2026-10-22 新增：**循环里重读计划**（排队重启的地基）────────────────
  #
  # 【为什么必须有这一段】
  #   老代码只在启动时读一次计划（上面 $plan = $planRead.Value），之后永不重读。
  #   排队重启时，**别人会往同一份计划里追加成员** —— 不重读就看不见他们，
  #   于是"等齐所有人再动手"这件事从根上做不到（这是 10-14 调研里
  #   标注为"整个改动里最容易漏的一处"，见决策记录 D7）。
  #
  # 【失败了怎么办】
  #   读失败（正被写、锁住）**绝不能当成"没人了"** —— 那会让它在别人正入队的瞬间发车。
  #   所以：读失败就保留上一轮的名单，并记一行日志，这一轮继续按老名单等。
  $planReread = Read-JsonFile -Path $PlanFile
  if ($null -ne $planReread) {
    # ⚠️ 同样**不要**包 `@()` —— 理由见上面 `$script:Members = Get-PlanMembers ...` 那段长注释。
    #    函数内部已经 `,$arr` 保证了"永远是数组"，外面再包一层就变成数组套数组。
    $newMembers = Get-PlanMembers -PlanObject $planReread
    if ($newMembers.Count -ne $script:Members.Count) {
      Write-Log ('[正主] 名单有变化：{0} → {1} 人（新来的会一起等）' -f $script:Members.Count, $newMembers.Count)
    }
    if ($newMembers.Count -gt 0) {
      $script:Members = $newMembers
      # 成员可能带着自己的理由；窗口文案要用"所有人的理由"，不是只有第一个人的
      if ($planReread.reason) { $plan = $planReread }
    }
  } elseif ($tick % 10 -eq 1) {
    Write-Log '[正主] （注意）这一轮计划文件读不出来，名单沿用上一轮 —— 不据此放行。'
  }

  $now = Get-Date
  $reasons = New-Object System.Collections.Generic.List[string]
  $quiet = $true

  # ① 【第一段：只等"发起重启的这个会话把这一轮说完"】
  #
  # ⚠️ 2026-10-08 发现的判据缺陷（真实踩到）：
  #   原来的判据是"盘上任何会话文件在 N 秒内被写过就算忙"，而**发起重启的会话
  #   自己**也在这个统计里。于是出现死结：
  #       排完重启 → 本脚本开始等 25 秒静默 → 但"排"完之后还要说话/干活
  #       → 发起会话自己的写入不断重置计时 → **把自己的重启等黄了**。
  #   实测就是这么发生的（helper.log：18:54:10 / 18:55:56 两次"会话记录刚写过"，
  #   都是发起会话自己的活动），最后靠运气停了 26 秒才成。
  #
  # 定下的新规矩（照方案一）：
  #   **先只等"这一轮说完"，等到了再去查有没有别人。**
  #   所以这一段**只看发起会话自己的文件**，别人在忙什么此刻不参与判断。
  # ★ 2026-10-13 深夜：**先用权威状态判"我这一轮说完没有"，文件时间只作兜底**。
  #
  #   为什么改（用户的话点破的）："你在等工具结果的时候，对话也是正常进行状态吧？
  #   应该属于被拦下来的状态？" —— 对。等工具时这一轮没结束，但**文件不写**。
  #   实测：本机 Agent 在等工具结果时，会话文件可以静默 **83 秒**，
  #   而老判据（静默 12 秒）早就放行了 —— 会砍断正在干活的会话。
  #
  #   权威依据（dsh-agent-loop 源码）：
  #       kick(){ try{ while(await turn()); } finally{ setPhase("idle") } }
  #       get status(){ return phase.kind === "idle" ? "idle" : "running" }
  #   ⇒ "这一轮结束"= status 变 idle，这正是我们要问的那件事。
  #
  #   ⚠️ 只在"权威数据新鲜且确实有这个会话"时才采信；
  #      拿不到就**退回老的文件判据**（保守方向，行为与以前一致）。
  #
  #   ⚠️ 位置注意：这一段在 ②-a 之前，$stateAuthoritative 那时还没算出来，
  #      所以这里**自己读一次** state.json（1~2KB，每轮一次，成本可忽略）。
  $authoritativeTurnDone = $null
  $reqId = [string]$plan.requestedBy
  if ($reqId) {
    $early = Read-JsonResult -Path $stateFile
    if ($early.Ok -and $early.Value) {
      $earlyAge = 9999
      try {
        if ($null -ne $early.Value.updatedAt) {
          # updatedAt 是 JS 的 Date.now()（UTC 毫秒）—— 必须用 UtcNow 减（见 ②-a 的教训）
          $earlyAge = ([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - ([double]$early.Value.updatedAt / 1000)
        }
      } catch { }
      if ($earlyAge -le 30 -and $early.Value.agentStatusById) {
        # 用 PSObject.Properties 取，别用 .$var —— 会话 id 里带连字符，按属性名直取不可靠
        $prop = $early.Value.agentStatusById.PSObject.Properties[$reqId]
        if ($prop) {
          $mine = [string]$prop.Value
          if ($mine -eq 'idle') { $authoritativeTurnDone = $true }
          elseif ($mine -eq 'running') { $authoritativeTurnDone = $false }
        }
      }
    }
  }

  if ($null -ne $authoritativeTurnDone) {
    # 走权威判据：不再看文件时间
    if (-not $script:AuthLogged) {
      Write-Log ('[正主] ✓ 用上权威状态了（本会话 agent.status={0}）—— 不再靠"文件静默"猜。' -f $(if ($authoritativeTurnDone) { 'idle' } else { 'running' }))
      $script:AuthLogged = $true
    }
    if ($authoritativeTurnDone -eq $false) {
      $quiet = $false
      $reasons.Add('权威状态：这一轮还在跑（不是靠文件静默猜的）')
    }
    # 落一下 lastChangeAt，让后面的计时语义保持一致
    if ($authoritativeTurnDone -eq $true) { $lastChangeAt = $now }
  } elseif ($sessionFile -and (Test-Path -LiteralPath $sessionFile)) {
    # 兜底：老的文件静默判据（权威数据拿不到时）
    #
    # ⚠️ 2026-10-13 深夜补：**兜底必须留痕**。
    #   第一次实测时这里没有日志，结果事后完全看不出"到底用了哪条判据"——
    #   那个绿灯可能是权威判据给的，也可能是兜底给的，两者可信度**不一样**。
    #   这正是本文档反复写的那条教训："看到绿灯时先问一句这绿灯是怎么来的"。
    if (-not $script:FallbackLogged) {
      $why = if (-not $reqId) { '计划里没有 requestedBy（不知道要问哪个会话）' }
        else {
          $e = Read-JsonResult -Path $stateFile
          if (-not $e.Ok) { '读不到 state.json' }
          elseif (-not $e.Value) { 'state.json 是空的' }
          elseif (-not $e.Value.agentStatusById) { 'state.json 没有 agentStatusById 字段（插件还是旧版？）' }
          else { '本会话不在 agentStatusById 里' }
        }
      Write-Log ('[正主] （注意）用不上权威状态：{0} → 退回「文件连续 {1} 秒没写」。' -f $why, $idleSeconds)
      $script:FallbackLogged = $true
    }
    try {
      $mtime = (Get-Item -LiteralPath $sessionFile).LastWriteTime
      if ($null -eq $lastMtime -or $mtime -ne $lastMtime) {
        $lastMtime = $mtime
        $lastChangeAt = $now
      }
      $age = ($now - $mtime).TotalSeconds
      if ($age -lt $idleSeconds) {
        $quiet = $false
        $reasons.Add(('这一轮还在写（会话记录 {0:N0} 秒前刚写过）' -f $age))
      }
    } catch { }
  } else {
    if (($now - $lastChangeAt).TotalSeconds -lt ($idleSeconds * 2)) {
      $quiet = $false
      $reasons.Add('找不到会话记录文件、也没有权威状态，按更保守的节奏等')
    }
  }

  # ★ "这一轮说完了没有"是第一道门。没过这道门，**不看别人、也不计时**，
  #   免得把"发起会话还在干活"和"别人在干活"混在一起（那就分不清该等谁了）。
  if ($null -ne $authoritativeTurnDone) {
    $myTurnDone = $authoritativeTurnDone
  } else {
    $myTurnDone = $quiet -and ($now - $lastChangeAt).TotalSeconds -ge $idleSeconds
  }

  # 超时/硬上限的检查**必须在第一道门之前**：万一这一轮迟迟说不完
  #   （比如会话里一直有人在打字），也得按 maxWait 放弃，不能无限期卡着。
  $hitHardCap = ($now -ge $hardDeadline)
  if ($now -ge $waitDeadline -or $hitHardCap) {
    $why = if ($reasons.Count -gt 0) { $reasons -join '；' } else { '一直有动静' }
    $waitedText = if ($hitHardCap -and $waitForever) { "一直等（超过 $hardCapHours 小时硬上限）" } else { "等了 $maxWaitMinutes 分钟" }
    # 三种超时要分清（2026-10-08，第二种是实测报错文案时发现的）：
    #   ① 第一段没过                       → "没等到这一轮说完"
    #   ② 这一轮早说完了、只是**家务**没跑完   → "家务（后台任务/子代理）还在跑"
    #   ③ 这一轮早说完了、一直有别人在忙       → 那条在下面 ③ 单独处理（更早返回）
    # 原来只有 ① 一个分支，于是"这一轮早说完了、只是子代理一直在跑"也会被写成
    # "没等到这一轮说完" —— **文案会骗人**，排查时会被带偏（实测踩到）。
    # ★ 2026-10-23：把"上一轮看到的忙因"也带上。
    #   否则会出现"真凶是别人在忙、文案却只怪后台任务"（实测踩到，会把人带偏）。
    $busyTail = if ($lastBusyText) { ('；另外还有别人在忙（{0}）' -f $lastBusyText) } else { '' }
    $whatHeld = if ($myTurnDone -and ($jobsRunning -gt 0 -or $subagents.Count -gt 0)) {
      $parts = @()
      if ($jobsRunning -gt 0) { $parts += ('后台任务 {0} 个' -f $jobsRunning) }
      if ($subagents.Count -gt 0) { $parts += ('家务子代理 {0} 个' -f $subagents.Count) }
      ('我这一轮早说完了，但{0}一直没跑完{1}' -f ($parts -join '、'), $busyTail)
    } elseif ($myTurnDone -and $lastBusyText) {
      ('这一轮早说完了，但一直有人在忙（{0}）' -f $lastBusyText)
    } else {
      ('没等到这一轮说完（{0}）{1}' -f $why, $busyTail)
    }
    $msg = ('{0}也没等到：{1}，所以**这次不重启了**。' -f $waitedText, $whatHeld) +
           '需要重启的话，请手动关掉 DSH 再打开（双击桌面图标就行）。'
    Write-Log ("[正主] ⏹ $msg")
    Save-Result -Outcome 'skipped-busy' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds
    # 状态窗：把"为什么没做成"说清楚再自己关掉。
    # ⚠️ 先拼好字符串再传参 —— 直接在参数里混用引号和 `r`n 很容易写错引号配平
    #    （第一版就在这儿少了一个引号，整个脚本语法都崩了，parse 才查出来）。
    $winFailText = '这次没重启：' + "`r`n" + $whatHeld + "`r`n`r`n" + 'DSH 没有被动过。想重启请手动双击桌面图标。'
    Close-RestartWindowSafe -FinalStage 'failed' -FinalText $winFailText -KeepSeconds 12
    Close-Trip   # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）
    exit 3
  }

  if (-not $myTurnDone) {
    if ($tick % 10 -eq 1) {
      $what = if ($reasons.Count -gt 0) { $reasons -join '；' } else { '等这一轮说完' }
      Write-Log ('[正主] …还在等这一轮说完（{0}）' -f $what)
      # 状态窗：解释为什么要等 —— 这是最需要知道的
      # （注释里别写直引号，会提前结束上面的字符串；用「」）
      Update-RestartWindowSafe -Detail ('正在等你这边这一轮说完（免得把你正打的字打断）。' + "`r`n" + $what) `
        -ElapsedSeconds $watch.Elapsed.TotalSeconds -MaxWaitMinutes $maxWaitMinutes
    }
    # ★ 2026-10-13 深夜：5 秒 → 2 秒。
    #   只影响"多快发现这一轮说完了"，不改判据本身。
    #   实测：5 秒粒度让"发现已说完"平均多等 ~2.5 秒；2 秒粒度降到 ~1 秒。
    #   ⚠️ 另外两处 5 秒（L1957 / L2003）**故意不动**：
    #      L1957 是"两轮确认是不是还在写"的安全设计（变快会削弱它）；
    #      L2003 是等后台任务/家务子代理，它们本来就要跑几十秒，粒度无所谓。
    Start-Sleep -Seconds 2
    continue
  }

  # ② 【第二段：这一轮说完了，现在去查"还有没有别人在干活"】
  #    ⚠️ 两种"忙"要分开对待（2026-10-08 定下的规则，别混成一件）：
  #       · **别的对话**在忙          → 直接放弃（机会作废，不排队等）
  #       · 只有**后台任务**在跑      → 等它跑完（那是正在干的活）；
  #                                    但这期间**一旦有别的对话进来**，立刻放弃。
  #    分开的理由：后台任务常常是"会话自己刚起的命令"，等它几分钟就好了；
  #    而别人的对话是"有人在等回复"，那是不能打断的。
  #    （原来把两者都算"别人在忙 → 立刻放弃"，结果插件里印的是"会等它们完事"，
  #      两边说法不一致 —— 就是这处矛盾暴露出来的。）
  $others = New-Object System.Collections.Generic.List[string]
  $busyReasons = New-Object System.Collections.Generic.List[string]
  $jobsRunning = 0
  # ★ 家务子代理（如某个插件的空闲复审子代理）：等它跑完，不算"别人在忙"。
  $subagents = New-Object System.Collections.Generic.List[string]
  # ★ 每轮**都要重置**"待确认"计数（它在扫盘那段里被赋值；扫盘被跳过时必须是 0，
  #   否则会用上一轮的旧值把这一轮白白挡住 —— 那会让重启永远等不到头）。
  $pendingCount = 0

  # ②-a 插件写的 state.json（最准：能精确排除发起会话自己）
  #    $stateAuthoritative = "这份状态够新鲜，可以当权威依据"。
  #    它决定下面扫盘用**窄**窗口还是**宽**窗口（见 ②-b 的说明）。
  #
  # ★ 2026-10-11：改用 Read-JsonResult，**区分"读失败"与"不存在"**。
  #   为什么这里也要改：state.json 是"权威数据"，而权威数据的**缺席**会让扫盘
  #   从窄窗口切到宽窗口（判断口径整个变掉）。如果只是"读的这一瞬间撞上写入失败"
  #   就被当成"权威数据不在"，那这一轮会莫名其妙变保守 —— 而且没有任何痕迹。
  #   现在：读失败会留一行日志，让人事后查得出"那几秒权威数据只是没读到"。
  $stateRead = Read-JsonResult -Path $stateFile
  if (-not $stateRead.Ok -and $stateRead.Reason -ne '不存在') {
    Write-Log ('[正主] （注意）state.json 一时读不到（{0}，已重试）—— 这一轮按"没有权威数据"处理，扫盘会用宽窗口（更保守）。' -f $stateRead.Reason)
  }
  $state = $stateRead.Value
  $stateAuthoritative = $false
  if ($state) {
    $stateAge = 9999
    try {
      if ($null -ne $state.updatedAt) {
        # ⚠️ updatedAt 是 JS 的 Date.now()，即 **UTC** 毫秒。
        #    必须用 UtcNow 去减；用本地时间（Get-Date）会凭空多出 8 小时
        #    （2026-10-08 实测：算出 28,802 秒，真值 4 秒），
        #    结果这句"过期"判断**永远成立** → 下面的忙闲检查从来没生效过。
        $stateAge = ([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds - ([double]$state.updatedAt / 1000)
      }
    } catch { }

    if ($stateAge -gt 30) {
      # ⚠️ 状态文件过期 ≠ 忙（可能 DSH 卡住或插件没加载）。
      #    这里**只记日志、不算忙** —— 否则一旦插件没起来，就会把它判成"别人在忙"
      #    而直接放弃重启。真正的兜底交给下面的文件扫描（它不依赖插件）。
      Write-Log ('[正主] 状态文件已 {0:N0} 秒没更新（不算忙，改看盘上谁在写）' -f $stateAge)
    } else {
      # 状态新鲜 → 它是权威依据（能精确列出"谁在跑"，比看时间戳猜准得多）
      $stateAuthoritative = $true
      if ([int]$state.jobsRunning -gt 0) {
        # 后台任务**不算"放弃"的理由**，只算"再等等"的理由（见上面 ② 的说明）。
        $jobsRunning = [int]$state.jobsRunning
        $busyReasons.Add(('后台还有 {0} 个任务在跑' -f $jobsRunning))
      }
      # ★ 只数"**别的**会话"：发起重启的那个会话**自己**肯定在跑（它刚说完话），
      #   必须排除掉，否则这条判断会永远成立、永远重启不了。
      if ($null -ne $state.runningSessions) {
        $req = [string]$plan.requestedBy
        # 要认出子代理了 —— 这时才建全量档案映射（按需，见 Update-SubagentArchiveMap）
        if (@($state.runningSessions).Count -gt 0) { Update-SubagentArchiveMap }
        foreach ($sid in @($state.runningSessions)) {
          $s = [string]$sid
          if (-not $s) { continue }
          if ($req -and $s -eq $req) { continue }
          # ⚠️⚠️ **必须再过一遍"家务"判据**（2026-10-08 实机第二次踩到）：
          #   旧版插件写的 runningSessions 里**混着子代理**（它还不会区分），
          #   21:25:02 那次就是这样被拦下的：日志上一行刚说"dcd36aa8 是家务子代理、
          #   不算别人在忙"（那是**扫盘**那条路认出来的），下一行却又把它当"别的会话"
          #   —— 因为**这条路（插件报的清单）当时还没过滤**。
          #   两条路都得摘，漏一条就等于没修。
          if (Test-IsSubagentSession -SessionId $s -CacheRoot $subagentCacheRoot) {
            if (-not $subagents.Contains($s)) { $subagents.Add($s) }
            continue
          }
          $others.Add($s)
        }
      } elseif ([int]$state.agentsRunning -gt 1) {
        $others.Add('（未知，按 agentsRunning-1 估算）')
      }

      # ★ 子代理（家务）**不算**"别人在忙"，只算"等它跑完"（2026-10-08 实机撞出来的）。
      #
      # 病根：记忆插件在"这一轮说完" **30 秒后**必起一个"空闲复审"子代理
      #   （源码写死 idleReviewMs=3e4，约每 10 分钟一次，实测已生成 235 个）。
      #   而本脚本的静默窗口是 25 秒 —— 两者时间上几乎必然重叠，
      #   于是每次自动重启都被这个"打扫卫生"的子代理拦下，判"别人在忙"放弃两次。
      #   更要命的是：**越安静，它越会来**（它正是被"空闲"触发的）。
      #
      # 为什么不把它当"别人在忙"：**没人在等它**。它是家务，随时可以等它跑完再动手；
      #   而"别人的对话"是有人在等回复，绝不能打断。两者性质不同，规则也该不同。
      # 判据来自 DSH 自己的 agents 服务（不是猜文件名）：
      #   roots() 只返回**没有 owner** 的顶层会话 = 真对话；
      #   带 owner 的（子代理）全部归"家务"。见 lib/index.js 的 survey()。
      if ($null -ne $state.runningSubagents) {
        foreach ($sub in @($state.runningSubagents)) {
          $s = [string]$sub
          if (-not $s) { continue }
          $subagents.Add($s)
        }
      }
    }
  }

  # ②-b 【不依赖插件的独立判断】直接看盘上**所有**会话文件，谁刚被写过 = 谁在干活。
  #
  # 为什么要有这一条：
  #   ②-a 依赖插件活着且 state.json 新鲜。万一插件没加载 / 状态文件过期，
  #   助手就只剩"盯发起重启那一个会话文件"——**别的会话在干活它就看不见了**，
  #   于是可能在别人正写着的时候把 DSH 砍了。这一条直接读文件系统，补上那个盲区。
  # ⚠️ 注意：它扫的是**全部**会话文件，**包括 QQ 群**。
  #   2026-10-08 定下的选择："算：群在聊也不重启" —— 所以这是**要的行为**，别改成排除 QQ。
  #   开销实测：742 个会话文件全扫一遍约 130 ms，相对 5 秒一次的循环可以忽略。
  #
  # ⚠️⚠️ 窗口分两种（2026-10-08 实机踩到：报的是"没认出来对话结束了"）：
  #   这次实况：20:21:17 判定时，**插件 3 秒前刚更新过 state.json**，
  #   里面 runningSessions **只有发起会话自己**（= 权威地说"没有别人在跑"）；
  #   可扫盘却因为"有个别的会话文件 101 秒前被写过"判了别人在忙 → 放弃。
  #   而那个文件其实 20:19:36 写了一次就再没动过（大小一直冻结 61,058 字节）——
  #   它只是"最近被写过"，不是"正在干活"（多半是手动重启后 DSH 打开/列会话时碰了一下）。
  #   **错在拿"猜的"(看时间戳) 去推翻"权威的"(插件直接问服务)。**
  #
  #   所以：权威数据在场时，扫盘只认**近 idleSeconds 秒内**的写入（真在干活的人
  #   每隔几秒就会写一次）；只有在权威数据缺席/过期时，才退回用**更宽的**
  #   othersWindowSec 保守猜测 —— 那时没别的依据，宁可漏做一次重启，也不砍断别人的活。
  $scanWindow = if ($stateAuthoritative) { $idleSeconds } else { $othersWindowSec }
  if ($sessionsRoot -and (Test-Path -LiteralPath $sessionsRoot)) {
    try {
      $cut = $now.AddSeconds(-$scanWindow)
      $act = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'session*.jsonl.zstd' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $cut })
      # 排除发起会话自己的文件（它刚刚才安静下来，别把它又算成"别人在忙"）
      $reqDir = ''
      if ($sessionFile) { try { $reqDir = Split-Path -Parent $sessionFile } catch { } }
      $actOthers = @($act | Where-Object { -not $reqDir -or $_.DirectoryName -ne $reqDir })

      # ★ 再从里面把**家务子代理**摘出去（2026-10-08 实机撞出来的，见上面 ②-a 的说明）。
      #   会话目录名 == 会话 id，所以能跟插件报的 runningSubagents 对得上。
      #   摘出去之后它归"等它跑完"，不算"别人在忙"。
      #
      # ⚠️ 2026-10-10 修根因①：认子代理必须先建**全量档案映射**（那个才是准的）。
      #   原来只查 session_projcache，漏认 320/619 个子代理 —— 13:29 / 14:01
      #   两次误判就是它没认出"发起会话自己的子代理"造成的。
      if ($actOthers.Count -gt 0) { Update-SubagentArchiveMap }
      $actReal = @()
      foreach ($f in $actOthers) {
        $dirName = [string]$f.Directory.Name
        # 两条判据都试：① 插件报的 runningSubagents（更准，但要新插件）；
        #              ② 直接读 DSH 的身份档案（立刻可用，不依赖插件）。
        $isHousekeepingSub = ($subagents.Count -gt 0 -and ($subagents -contains $dirName)) -or
                             (Test-IsSubagentSession -SessionId $dirName -CacheRoot $subagentCacheRoot)
        if ($isHousekeepingSub) {
          if (-not $subagentSeen) {
            $subagentSeen = $true
            Write-Log ('[正主] （参考）盘上在写的是**家务子代理**（{0}），不算"别人在忙"，等它跑完。' -f $dirName)
          }
          # 也算进"家务"清单，好让它参与"还在等什么"的日志
          if (-not ($subagents -contains $dirName)) { $subagents.Add($dirName) }
          continue
        }
        $actReal += $f
      }

      # ★★★ 2026-10-10 修根因②：把"写过一次"和"还在持续写"分开 ★★★
      #
      # 病根：原来只要有个别人的会话文件落在窗口内，就判"别人在忙"→ **当场放弃**。
      #   而盘上大量存在"写一下就再也不动"的**单次写入**（如 session/end-seed），
      #   它们根本不是"有人在干活"。2026-10-08 20:21 那次就是这么黄掉的：
      #   一个会话 20:19:36 写了一次（判定时已过 101 秒、大小一直冻结），却把它当成
      #   "别人在忙"放弃了重启。
      #
      # ⚠️ 为什么**不能**按事件类型豁免 session/end-seed：
      #   实测全机 233 个含 end-seed 的会话里，**163 个在它之后又继续干活了**
      #   （end-seed 有 77% 出现在会话**中段**，不是终态标记）。
      #   按事件类型豁免 = 可能在一个还会继续说话的会话正跑着时把 DSH 关掉 —— 那是
      #   绝不能接受的方向。所以这里**不认事件类型**，只认"盘上是不是还在动"。
      #
      # 正确判法：**同一个会话，两轮扫盘各写了一次且时间戳在往前走**才算"真的在动"。
      #   只看 mtime 是否变新，不数事件、不看类型 —— 单次写入第二轮还是老时间戳 → 不算忙。
      #   三种情况分得很清楚（这是本轮的关键，别简化）：
      #     · 第一次看见        → "待确认"：**既不放行也不放弃**，再等一轮看它动不动
      #     · 见过且时间戳变新  → **真的在写** → 放弃（安全方向，维持原样）
      #     · 见过且时间戳没变  → 写了一次就停了 → 无害，忽略
      #
      # ⚠️⚠️ "第一次看见"**绝对不能直接放行**：那样一个刚开口说话、插件还没来得及
      #   把它列进 runningSessions 的真对话就会被漏掉，可能在它正要干活时把 DSH 关掉。
      #   所以它必须挡住这一轮（最多多等一个 5 秒周期），等下一轮看清了再决定。
      #
      # ⚠️ 为什么**只在权威数据在场时**才这么做：
      #   $stateAuthoritative = 插件刚更新过 state.json、它直接问过 agents 服务。
      #   那种情况下"正在干活"的会话**本来就该出现在 runningSessions 里**（②-a 拦），
      #   实测本机 34 个"安静 >8 秒"的会话里，插件报 running 的 = 0 个，
      #   说明"插件清单"与"文件在写"是**两道独立**的闸，不是同一个信息的两份拷贝。
      #   ⇒ 权威在场时放宽扫盘，不会漏掉真正在跑的对话（它由 ②-a 兜着）。
      #   反过来，权威**缺席/过期**时一律维持原样（一次就算忙）—— 那时没有别的依据，
      #   宁可漏做一次重启，也绝不砍断别人的活。
      $confirmedReal = @()      # 确认真在写 → 放弃
      $pendingReal = @()        # 第一次看见 → 再等一轮
      $pendingCount = 0
      if ($stateAuthoritative) {
        foreach ($f in $actReal) {
          $key = [string]$f.Directory.Name
          if (-not $prevWrites.ContainsKey($key)) {
            $pendingReal += $f                       # 第一次看见：先别下结论
          } elseif ($f.LastWriteTime -gt $prevWrites[$key]) {
            $confirmedReal += $f                     # 时间戳在往前走 = 真的在写
          }
          # 见过、且时间戳没变 = 写了一次就停了 → 什么都不做（无害）
        }
        $pendingCount = $pendingReal.Count
      } else {
        # 没有权威依据：维持原判（单次也算忙，保守）
        $confirmedReal = $actReal
      }
      # 记下这一轮看到的写入时间，供下一轮比对
      foreach ($f in $actReal) { $prevWrites[[string]$f.Directory.Name] = $f.LastWriteTime }

      if ($pendingReal.Count -gt 0) {
        $pn = Format-SessionNameList -Ids @($pendingReal | ForEach-Object { $_.Directory.Name }) -CacheRoot $subagentCacheRoot
        Write-Log ('[正主] （参考）{0} 个会话刚被写过、但**只看见一次**（{1}）；权威数据说没人在跑 —— 再等一轮确认它动不动，先不下结论。' -f $pendingReal.Count, $pn)
      }

      if ($confirmedReal.Count -gt 0) {
        $names = Format-SessionNameList -Ids @($confirmedReal | ForEach-Object { $_.Directory.Name }) -CacheRoot $subagentCacheRoot
        # ⚠️ 文案必须**如实反映是哪条路判的**（不然事后查日志会被带偏）：
        #   权威在场 → 已确认"两轮都在写、时间戳在往前走" → 才敢说"还在持续写"；
        #   权威缺席 → 只看到"写过一次"，那就照实说"刚被写过"（保守判法）。
        if ($stateAuthoritative) {
          $busyReasons.Add(('盘上有 {0} 个会话文件**还在持续写**（{1}）' -f $confirmedReal.Count, $names))
        } else {
          $busyReasons.Add(('盘上有 {0} 个会话文件刚被写过（{1}）' -f $confirmedReal.Count, $names))
        }
      }
      # 权威数据在场时，把"最近写过、但已经停了"的记进日志（便于事后核对判据是否合理）。
      # ⚠️ 每份计划**只记一次**：原来写成"每 6 个 tick 记一次"，结果恰好在前几轮就动手时
      #    一次都不会打 —— 事后排查"它为什么这次没拦"就看不到任何解释（这次故障就是这么被绕住的）。
      if ($stateAuthoritative -and -not $staleNoticeLogged) {
        $wideCut = $now.AddSeconds(-$othersWindowSec)
        $stale = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter 'session*.jsonl.zstd' -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -gt $wideCut -and $_.LastWriteTime -le $cut } |
          Where-Object { -not $reqDir -or $_.DirectoryName -ne $reqDir })
        if ($stale.Count -gt 0) {
          $staleNoticeLogged = $true
          $sn = Format-SessionNameList -Ids @($stale | ForEach-Object { $_.Directory.Name }) -CacheRoot $subagentCacheRoot
          Write-Log ('[正主] （参考）有 {0} 个会话文件在 {1}s 内写过、但已停了 {2}s 以上，不算"在忙"：{3}' -f $stale.Count, $othersWindowSec, $idleSeconds, $sn)
        }
      }
    } catch { }
  }

  # ③ 判定 —— 两种"忙"分开处理（2026-10-08 定）：
  #    · 有别人在忙（别的会话 / 盘上有别的会话在写）→ **放弃**（不排队等）
  #    · 只有后台任务在跑                           → **继续等**，等它跑完
  #      ⚠️ 但等待期间一旦有人进来（别人开始写会话），下一轮循环就会落到上面那条 → 放弃。
  #         这正是要的行为："等后台任务等一段时间，期间要是有新的对话进来，就放弃。"
  #
  # ★ 2026-10-10（修根因②）：先处理"待确认"的写入 —— 它**既不放行也不放弃**，
  #   只把这一轮挡住，下一轮再看一眼（见 ②-b 的完整说明）。
  #   ⚠️ 必须在下面"动手"判定**之前**处理：否则第一次看见的写入会直接放行 → 可能砍到
  #      一个刚开口的真对话。这是本轮改动里最容易写错的一处。
  if ($pendingCount -gt 0) {
    if ($tick % 3 -eq 1) {
      Write-Log ('[正主] …{0} 个会话刚被写过、但只看过一次，再等一轮确认它是不是还在写' -f $pendingCount)
    }
    if ($tick % 3 -eq 1) {
      Update-RestartWindowSafe -Detail ('有个会话刚被写过，先看一眼它是不是还在动（免得误判成"有人在忙"）。') `
        -ElapsedSeconds $watch.Elapsed.TotalSeconds -MaxWaitMinutes $maxWaitMinutes
    }
  # 每 30 秒落一次「我还活着、在等谁」（出事以后能查；产品逻辑不依赖它）
  if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge $waitHeartbeatSeconds) {
    Write-WaitHeartbeat -Detail ($reasons -join '；') -Elapsed $watch.Elapsed.TotalSeconds
  }
    Start-Sleep -Seconds 5
    continue
  }

  $hardReasons = @()
  if ($others.Count -gt 0) {
    # ★ 2026-10-24：显示**会话名**，不是一串 id（用户说"编号我找不到是哪个"）。
    #   拿不到名字的，仍退回显示 id —— 有据可查比好看重要。
    $othersNamed = @($others | ForEach-Object {
      $sid = [string]$_
      $n = Get-SessionDisplayName -SessionId $sid -CacheRoot $subagentCacheRoot
      if ($n) { '「' + $n + '」' } else {
        # 没名字就显示短 id（前 8 位），别拿一长串 uuid 糊人
        $bare = $sid -replace '^session-', ''
        $short = if ($bare.Length -gt 8) { $bare.Substring(0, 8) } else { $bare }
        '会话 ' + $short
      }
    })
    $hardReasons += ('还有 {0} 个别的会话在干活（{1}）' -f $others.Count, (($othersNamed | Select-Object -First 3) -join '、'))
  }
  # 盘上扫到的"别人刚写过会话文件"也算硬理由：文件在动 = 有人在交互。
  $hardReasons += @($busyReasons | Where-Object { $_ -like '盘上有*' })

  # ★ 2026-10-23：把这轮的忙因记下来，供**总超时文案**引用
  #   （总超时的判断在循环靠前，那时还拿不到这些信息 —— 见上面 $lastBusyText 的说明）
  if ($hardReasons.Count -gt 0) { $lastBusyText = ($hardReasons -join '；') }

  if ($hardReasons.Count -gt 0) {
    # ★ 2026-10-24：有**真人对话**在跑时，「不等了」必须熄灭 ——
    #   这个按钮只允许跳过"家务"，永远不允许跳过"有人在等回复"。
    Set-RestartWindowForceSafe -Enabled $false
    # ── ★ 2026-10-22：**从"作废"改成"继续等"**（排队重启的核心行为变更）────────────
    #
    # 【为什么改】
    #   老规矩（2026-10-08）：别的会话在跑 → 当场放弃，这次机会作废、不排队。
    #   实测数据：这条规矩在 10-13 ~ 10-22 之间触发了 **19 次**，每次都是
    #   "想重启 → 被拒 → 过一会儿再试一遍"，白白折腾（插件日志「未排重启」）。
    #   用户要的是"我没在的时候它自己找空档干完"，而作废意味着**永远不会自己找到空档**。
    #
    # 【底线没变】
    #   **绝不强闯**：只要名单上还有人没闲着，就一直等，绝不动手。
    #   变的只是"等不到怎么办"：以前是扔掉，现在是留着继续等。
    #
    # 【谁来兜底不无限挂】
    #   · maxWaitMinutes > 0 → 到点放弃（老行为，保留给想设上限的人）；
    #   · maxWaitMinutes <= 0 → 一直等，但有 $hardDeadline（12 小时硬上限）兜底。
    #   这两条在上面的超时检查里，不受本次改动影响。
    #
    # 【最多等多久才提醒】
    #   由 notifyAfterMinutes 负责（默认 20 分钟发一条 QQ）——见下面。
    # ══════════════════════════════════════════════════════════════════════════
    # ★★ 2026-10-23 修：**"上限"被当成了"一见到忙就作废"**
    #
    # 【用户报的问题，原话】
    #   「我发现重启稍微等一小会就失效了，就像刚刚那个对话拉起的重启，
    #     现在似乎已经失败了，没有"一直等"」
    #
    # 【实测证据（helper.log 09:10 那次）】
    #   09:10:12 开始等闲置，日志明说「最多等 60 分钟；等不到就放弃」
    #   09:10:32 ⏹ 放弃 —— **实际只等了 20 秒**
    #   放弃理由写的是「按你设的 60 分钟上限，这次不重启了」
    #   ⇒ 那句"60 分钟"根本没被等过，看到有人忙就立刻按了作废。
    #
    # 【病根】
    #   老代码这里是 `if ($maxWaitMinutes -gt 0) { 作废 }`。
    #   它的本意是"有人设了上限 → 到点作废"，但**少了"到点"这个条件**：
    #   只要上限 > 0，第一次发现有人忙就直接作废（20 秒内）。
    #   于是 maxWaitMinutes 从"最多等 60 分钟"变成了"设了它就等于只等 20 秒"，
    #   跟 2026-10-22 那条"改成继续等"的核心改动正好互相抵消 ——
    #   而默认配置是 0（永远等），所以平时看不出来，只有传了显式上限才会犯。
    #
    # 【修法】
    #   把"到点"真正接上：**只有真的到了截止时间（或 12 小时硬上限）才作废**；
    #   没到点就继续等 —— 这才是"上限"这个词的意思。
    # ══════════════════════════════════════════════════════════════════════════
    $deadlineHit = ($now -ge $waitDeadline -or $hitHardCap)
    if ($maxWaitMinutes -gt 0 -and $deadlineHit) {
      # 真的等满了才作废（保留给"明确设了上限"的人，不偷偷改成永远等）
      $msg = ('这一轮已经说完了，但现在还有别人在忙（{0}）—— 已经等满你设的 {1} 分钟上限，这次不重启了。' -f ($hardReasons -join '；'), $maxWaitMinutes)
      Write-Log ("[正主] ⏹ $msg")
      Save-Result -Outcome 'skipped-busy' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds
      $winFailText = '这次没重启：还有别人在忙。' + "`r`n" + ($hardReasons -join '；') +
                     "`r`n`r`n" + 'DSH 没有被动过。想重启请手动双击桌面图标。'
      Close-RestartWindowSafe -FinalStage 'failed' -FinalText $winFailText -KeepSeconds 12
      Close-Trip   # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）
      exit 3
    }

    # 还没到点（或压根没设上限 = 永远等）→ 继续等，不硬闯
    if ($tick % 5 -eq 1) {
      $waitedMin = [math]::Round($watch.Elapsed.TotalMinutes, 1)
      # ⚠️ 文案里必须写清"会不会到点放弃" —— 09:10 那次日志说"最多等 60 分钟"
      #    结果 20 秒就放弃，就是被这种不准确的提示带偏的。
      $capText = if ($maxWaitMinutes -gt 0) {
        ('（最多等到 {0} 分钟，到点才放弃）' -f $maxWaitMinutes)
      } else {
        ('（一直等下去，只有 {0} 小时硬上限）' -f $hardCapHours)
      }
      Write-Log ('[正主] …已等 {0} 分钟；还有别人在忙（{1}）—— 继续等，不硬闯{2}' -f $waitedMin, ($hardReasons -join '；'), $capText)
      Update-RestartWindowSafe -Detail ('已经等 {0} 分钟了，还有别人在忙：{1}。' -f $waitedMin, ($hardReasons -join '；')) `
        -ElapsedSeconds $watch.Elapsed.TotalSeconds -MaxWaitMinutes $maxWaitMinutes
    }
    # ★ 等太久 → 发一条 QQ 提醒（默认 20 分钟一次；默认不重复）
    Send-WaitReminderIfDue -ElapsedMinutes $watch.Elapsed.TotalMinutes -HardReasons $hardReasons | Out-Null
  # 每 30 秒落一次「我还活着、在等谁」（出事以后能查；产品逻辑不依赖它）
  if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge $waitHeartbeatSeconds) {
    Write-WaitHeartbeat -Detail ($reasons -join '；') -Elapsed $watch.Elapsed.TotalSeconds
  }
    Start-Sleep -Seconds 5
    continue
  }

  # 只剩"家务"（后台任务 / 子代理）→ 可以动手；否则继续等它们。
  if ($jobsRunning -le 0 -and $subagents.Count -eq 0) {
    Write-Log ('[正主] 这一轮说完了、别的会话也没在跑 → 可以动手了。')
    Set-RestartWindowForceSafe -Enabled $false
    break
  }

  # ══════════════════════════════════════════════════════════════════════════
  # ★ 2026-10-24：只剩家务这一段 —— 「说清楚在等谁」+「给一个人工放行的出口」
  #
  #   用户原话：「我当时看不到他在哪个地方在跑」「给我一个手动强制进行下一步的按钮」。
  #   以前的卡片只有一句「正在等：家务子代理 1 个」，等多久没个头，只能整趟打断。
  #   现在：每 5 秒刷新一次明细（谁、哪个工作区、跑了多久、多久没动静），
  #   并点亮「不等了，立刻重启」。点了就写 force.flag，下面这一小段看到就跳过"等"。
  #
  #   ⚠️ 位置很关键：必须放在**硬理由（别的对话在跑）之后**。
  #      这保证"人工放行"永远不可能跳过"有人正在等回复"那条线 ——
  #      它能催，不能砍。
  # ══════════════════════════════════════════════════════════════════════════
  Set-RestartWindowForceSafe -Enabled $true -ForceFile $forceFile
  $hkDetail = Get-HousekeepingWaitDetail -Subagents @($subagents) -JobsRunning $jobsRunning -CacheRoot $subagentCacheRoot
  Update-RestartWindowSafe -Detail $hkDetail -ElapsedSeconds $watch.Elapsed.TotalSeconds -MaxWaitMinutes $maxWaitMinutes -CanForce

  if (Test-Path -LiteralPath $forceFile) {
    $whoParts = @()
    if ($subagents.Count -gt 0) { $whoParts += ('家务子代理 {0} 个' -f $subagents.Count) }
    if ($jobsRunning -gt 0) { $whoParts += ('后台任务 {0} 个' -f $jobsRunning) }
    $whoText = if ($whoParts.Count -gt 0) { ($whoParts -join '、') } else { '剩下的家务' }
    Write-Log ('[正主] ★ 你点了「不等了」：不再等 {0} —— 继续往下走（动手前的安全检查一个都不省）。' -f $whoText)
    Set-RestartWindowStageSafe -Stage 'waiting' `
      -Detail ('按你说的：不等{0}了，正在做动手前检查（主程序在不在、要关的是不是它）。' -f $whoText) `
      -EtaText '检查通过会进入 10 秒确认窗，那 10 秒里仍然可以点「打断」。'
    $script:ForceSkipped = $true
    break
  }

  # ── 走到这里 = 第一段过了、也没有别人在忙，只是**后台任务还没跑完**。
  #    继续等（2026-10-08 定的："等后台任务等一段时间"）——
  #    等它的过程中若有人进来说话，下一轮就会被上面 ③ 的硬理由拦下 → 放弃。
  #    ⚠️ 不再弹窗（2026-10-08 定）：这台机器常被**远程**驱动，弹窗没人点，
  #      反而可能在无人值守时卡住一个对话框。改成"写结果文件 + 对话自己说"。
  if ($tick % 3 -eq 1) {
    $waits = @()
    if ($jobsRunning -gt 0) { $waits += ('后台任务 {0} 个' -f $jobsRunning) }
    if ($subagents.Count -gt 0) { $waits += ('家务子代理 {0} 个' -f $subagents.Count) }
    Write-Log ('[正主] …{0}还没跑完，继续等；这期间若有别的对话进来就放弃' -f ($waits -join '、'))
    # ★ 2026-10-24：状态窗的明细**已经在本轮上面统一刷新过**（含"在等谁/多久没动静"），
    #   这里不再用短句覆盖它 —— 否则每 15 秒就把明细打回"家务子代理 1 个"。
  }

  # 每 30 秒落一次「我还活着、在等谁」（出事以后能查；产品逻辑不依赖它）
  if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge $waitHeartbeatSeconds) {
    Write-WaitHeartbeat -Detail ($reasons -join '；') -Elapsed $watch.Elapsed.TotalSeconds
  }
  Start-Sleep -Seconds 5
  } catch {
    # ══════════════════════════════════════════════════════════════════════════
    # 【2026-10-23 加】单轮出错**不许静默带走整趟重启**
    #
    # 背景见循环前面那段长注释：$ErrorActionPreference='Stop' + 循环没有 try/catch
    # + -WindowStyle Hidden 三条叠起来，任何一个小异常都会让助手**无声消失**，
    # 2026-10-23 00:41 真的发生过一次（用户只看到状态窗"不见了"）。
    #
    # 这里的规矩：
    #   · 记一笔完整错误（类型/消息/出错行号）到 helper.log —— 下次出事能直接定位；
    #   · 把错误也算进心跳的 detail，这样在 last-run.json 里看得到"它死前遇到什么"；
    #   · **本轮作废、下一轮继续等** —— 等待本身是安全方向（宁可多等，也不硬闯）；
    #   · 例外：如果计划文件已经没了，那是正常收尾，交回循环开头处理。
    # ══════════════════════════════════════════════════════════════════════════
    $errMsg = $_.Exception.Message
    $errType = $_.Exception.GetType().Name
    $errLine = $_.InvocationInfo.ScriptLineNumber
    Write-Log ('[正主] （注意）这一轮判定出错，已跳过、继续等：{0} — {1}（脚本第 {2} 行）' -f $errType, $errMsg, $errLine)
    try {
      Write-WaitHeartbeat -Detail ('等待中出错（已跳过这一轮）：{0} — {1}' -f $errType, $errMsg) `
        -Elapsed $watch.Elapsed.TotalSeconds
    } catch { }
    # 出错也不能变成"忙等"刷屏
    Start-Sleep -Seconds 5
  }
}

# ★ 2026-10-24：走到这里 = 不用再等了（自己等完了，或者用户点了「不等了」）。
#   两种情况下这个按钮都不该再能点 —— 再点一次也不会更快。
Set-RestartWindowForceSafe -Enabled $false
if ($script:ForceSkipped) {
  Write-Log ('[正主] 人工放行已生效：从"等家务"跳到这里（总共等了 {0:N0} 秒）。后面的安全检查照常做。' -f $watch.Elapsed.TotalSeconds)
}

# ══════════════════════════════════════════════════════════════════════════
# 第 3.5 步：动手前的最后一道闸
# ══════════════════════════════════════════════════════════════════════════

# ── 第 3.5 步：动手前的最后一道闸 ──────────────────────────────────────────
# ⚠️ 这道闸是拿真事故换来的（2026-10-08）：自测时计划里写了一个**不存在的**
#    主程序路径，助手照样把 DSH 杀了，杀完才发现"没法拉起" —— 应用被关了，
#    却没人能把它拉回来。这是本工具最坏、也最不可接受的结果。
#
#    规矩改成：**先确认一定拉得起来，才允许动手关。**
#    拉不起来就原地退出，DSH 一根汗毛都不动。
$preflightOk = $true
$preflightWhy = @()

if (-not (Test-Path -LiteralPath $dshExe -PathType Leaf)) {
  $preflightOk = $false
  $preflightWhy += ('主程序不存在：{0}' -f $dshExe)
}

# 顺手确认它确实是个能执行的程序（有扩展名且不是目录），别是个被改名占位的空壳
if ($preflightOk) {
  try {
    $item = Get-Item -LiteralPath $dshExe -ErrorAction Stop
    if ($item.Length -le 0) {
      $preflightOk = $false
      $preflightWhy += ('主程序是 0 字节：{0}' -f $dshExe)
    }
  } catch {
    $preflightOk = $false
    $preflightWhy += ('主程序读不到：{0}' -f $_.Exception.Message)
  }
}

if (-not $preflightOk) {
  $msg = '动手前检查没过 —— ' + ($preflightWhy -join '；') +
         '。为了不出现"关掉了却拉不起来"，这次**没有动 DSH**。'
  Write-Log ("[正主] ✋ $msg")
  Save-Result -Outcome 'failed' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds
  Close-RestartWindowSafe -FinalStage 'failed' -FinalText ($msg + "`r`n`r`nDSH 没有被动过。") -KeepSeconds 15
  Close-Trip   # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）
  exit 1
}
Write-Log ('[正主] 动手前检查通过：主程序在位（{0}）。' -f $dshExe)

# ── 第 3.5b 步：★ 2026-10-22 新增的硬护栏 —— "要杀的"和"要拉起的"必须是同一个东西 ──
#
# 【这条是拿真事故换来的，写在最前面】
#   2026-10-22 21:32：我自己在排错时手工跑了一次助手，命令里**漏了**
#   `-TargetProcessName` / `-TargetCommandMatch` 两个开关。助手的默认目标就是**真 DSH**，
#   于是它把正在运行的 DeepSeek Harness（PID 44204）杀了；而计划里的 "dshExe" 指向的是
#   测试用的 `fake.exe`（一个 16 字节的文本文件），拉起必然失败 → **DSH 被关掉却没人拉起来**。
#   那是这个工具唯一不可接受的后果。最后是用户手动点桌面图标救回来的。
#
# 【为什么原来的护栏没拦住】
#   上面 3.5 步只检查"**要拉起的程序**在不在、是不是 0 字节"，
#   从来没检查"**马上要关掉的那个进程**"跟"计划要拉起的程序"是不是同一个。
#   所以 plan.dshExe = fake.exe、实际关掉 DeepSeek Harness.exe，护栏照样放行。
#
# 【现在的规矩】
#   动手关之前，把 `Get-MainDshProcess` 选出来的那个进程的**可执行文件全路径**
#   跟 `$dshExe` 比；不一致就**原地退出，一个进程都不碰**。
#
#   理由（报告里写的，我同意）：**只要还靠"记得传开关"，同类事故就会复发。**
#   补上这条以后，就算谁（包括未来的我）忘了传 `-TargetProcessName`，
#   也只会得到"目标不匹配，我没动手"，而不会杀到真 DSH。
$preflightOk = $true
$preflightWhy = @()

# ★ 2026-10-23：操作员**显式**指定了别的目标名 → 用户明确知道自己在打谁（自测/特殊场景）。
#
# 【为什么必须区分】护栏的失败提示自己写着"如果这是自测，请显式传 -TargetProcessName"，
#   但那时候传了也不放行 —— 提示和判据自相矛盾。
#   实测后果（09:16 的 test-wait-when-busy）：8 套用假目标跑真助手的测试**全部**
#   卡在这道闸上，日志里全是「✋ 要关掉的进程和计划里的主程序不是同一个」。
#
# 【安全边界没变】真正的误杀场景是"想传假目标、但传法无效 → 用了默认名"，
#   那种情况 $TargetProcessName 仍是默认的 'DeepSeek Harness' → 照旧拦下。
#   所以放松只作用于"确实显式换了目标名"这一种。
$explicitTarget = ($TargetProcessName -ne 'DeepSeek Harness')

if ($preflightOk) {
  try {
    $mainProc = Get-MainDshProcess
    if (-not $mainProc) {
      $preflightOk = $false
      $preflightWhy += ('找不到主进程（目标名 "{0}"）—— 不知道要关哪个，不敢动' -f $TargetProcessName)
    } else {
      $runningExe = ''
      try { $runningExe = [string]$mainProc.Path } catch { $runningExe = '' }
      if (-not $runningExe) {
        # 拿不到路径时**必须当失败**：这正是"分不清是不是同一个东西"的场合
        $preflightOk = $false
        $preflightWhy += ('拿到主进程 PID={0} 但读不出它的可执行文件路径 —— 分不清它是不是"{1}"，不敢动' -f $mainProc.Id, $dshExe)
      } elseif ($runningExe.Trim().Trim('"') -ne $dshExe.Trim().Trim('"')) {
        if ($explicitTarget) {
          # 显式换过目标名 → 允许"要关的 exe"和"要拉起的 exe"不同（自测就是这样）
          Write-Log ('[正主] ⚠ 目标一致性：正在跑的是「{0}」(PID={1})，计划里要拉起的是「{2}」—— 两者不同，但你**显式指定**了目标名 "{3}"，按自测/特殊场景放行。' -f $runningExe, $mainProc.Id, $dshExe, $TargetProcessName)
        } else {
          $preflightOk = $false
          $preflightWhy += ('**要关掉的进程和计划里的主程序不是同一个**：正在跑的是「{0}」(PID={1})，计划里要拉起的是「{2}」。' -f $runningExe, $mainProc.Id, $dshExe) +
                           '如果这是自测，请显式传 -TargetProcessName / -TargetCommandMatch 指向那个假目标。'
        }
      } else {
        Write-Log ('[正主] ★ 目标一致性检查通过：即将关闭的「{0}」(PID={1}) 正是计划里要拉起的那个程序。' -f $runningExe, $mainProc.Id)
      }
    }
  } catch {
    $preflightOk = $false
    $preflightWhy += ('目标一致性检查本身出错（{0}）—— 宁可不重启也不敢赌' -f $_.Exception.Message)
  }
}

# 再补一条很弱的额外保险：检查要拉起的程序有没有 PE 头（MZ）。
#
# ⚠️ **这条挡不住 2026-10-22 那次事故** —— 实测过：测试脚本造的假文件是
#    `Set-Content -Value 'MZ placeholder'`，**开头两字节真的是 MZ**，所以照样放行。
#    留着它只是因为它顺手、能挡住"路径填成一个 .txt/.log"这类更离谱的误配，
#    **不要把它当成安全依据**。真正的护栏是上面那条"目标一致性"。
if ($preflightOk) {
  try {
    $fs = [System.IO.File]::OpenRead($dshExe)
    try {
      $buf = New-Object byte[] 2
      $n = $fs.Read($buf, 0, 2)
      if ($n -lt 2 -or $buf[0] -ne 0x4D -or $buf[1] -ne 0x5A) {
        $preflightOk = $false
        $preflightWhy += ('要拉起的程序不像可执行文件（开头不是 MZ）：{0}' -f $dshExe)
      }
    } finally { $fs.Dispose() }
  } catch {
    $preflightOk = $false
    $preflightWhy += ('读不出主程序文件头（{0}）：{1}' -f $dshExe, $_.Exception.Message)
  }
}

# ══════════════════════════════════════════════════════════════════════════
# ★★★ 2026-10-23：把「护栏算出来的结论」真的接上 ★★★
#
# 【为什么必须有这一段 —— 这是两次误杀的真凶】
#   第 3.5b 步算出了「要关的」和「要拉起的」是不是同一个，判出不一致时
#   把 $preflightOk 置成了 $false …… 然后**没有任何代码读它**。
#   下面 2700 行起照样 taskkill。
#
#   也就是说：**那道护栏从写出来到现在，一次都没生效过。**
#   2026-10-21 21:32 和 2026-10-23 00:59 两次误杀真 DSH，都是这个原因。
#   判据（不是推测）：
#     · helper.log 里「★ 目标一致性检查通过」出现 0 次；
#     · 「不是同一个」0 次；
#     · 本文件 2658 行之后 $preflightOk 出现 0 次。
#   ⇒ 无论它算出通过还是不通过，对后续流程都毫无影响。
#
# 【这一段做什么】把"不通过"变成真的停手 —— 与上面 3.5 步的收尾完全同款
#   （同样的记录、同样的窗口文案、同样的清理、同样的退出码），
#   免得出现"两处都说检查、只有一处真的停"这种半吊子。
#
# ⚠️ 位置必须在这里：**在 10 秒确认窗之前**。
#   确认窗的语义是"给你最后 10 秒反悔"，前提是"检查都过了"。
#   如果放到确认窗之后，用户会先看到倒计时、以为要重启了，最后才被拒 —— 那是骗人。
# ══════════════════════════════════════════════════════════════════════════
if (-not $preflightOk) {
  $msg = '动手前检查没过 —— ' + ($preflightWhy -join '；') +
         '。为了不出现"关掉了却拉不起来"，这次**没有动 DSH**。'
  Write-Log ("[正主] ✋ $msg")
  try { Save-Result -Outcome 'failed' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds } catch { }
  Close-RestartWindowSafe -FinalStage 'failed' -FinalText ($msg + "`r`n`r`nDSH 没有被动过。") -KeepSeconds 15
  Close-Trip   # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）；保险丝那一侧另有"计划没了就撤"的护栏
  exit 1
}


# ── 第 3.6 步：动手前的 10 秒确认窗（2026-10-11）────────────────────────
#
# 设计意图："默认重排等待时间留个 5 秒，再留个 10 秒确认窗，
#            最后直接重启 —— 重启得越快，对正常要一直挂着的工具影响越小。"
#
# 为什么这样是安全的（两条一起看）：
#   ① 这 10 秒里**「打断」按钮仍然可点** —— 它就是最后的反悔机会。
#      所以 Disarm 必须放在**这 10 秒之后**（原来在它之前，等于把反悔权提前收走了）。
#   ② 这 10 秒是**最后一道人工确认**，之后的关闭就是不可逆的了。
#
# ⚠️ 为什么要做成"看着倒计时"而不是"静默 10 秒"：
#   要点就是"供确认"。屏幕上必须**显示还剩几秒**，否则根本不知道有这么个机会。
#
# ⚠️ 这 10 秒**不替代**前面两道闸（2026-10-11 定下"保留两道"）：
#   这一轮没说完 → 不重启；别的对话在忙 → 不重启。这 10 秒只是动手前的最后一次确认。
# ⚠️ 默认值取 **0**（= 没有确认窗），不是 10 —— 这是有意的：
#   · 实机路径上，**插件一定会把这个字段填上**（它发 10），所以照样会看到确认窗；
#   · 而自测是**手写计划**的，它们没这个字段 → 拿到 0 → 不会平白多等 10 秒，
#     各测试原有的时间假设（超时、断言）都不受影响。
#   反过来若这里默认 10，就得去改 9 个测试文件 —— 那种批量改动的风险更大
#   （2026-10-10 用错正则把 9 个测试文件清成过 0 字节）。
$confirmSeconds = 0
if ($null -ne $plan.confirmSeconds) {
  try { $confirmSeconds = [int]$plan.confirmSeconds } catch { }
}
if ($confirmSeconds -gt 0) {
  Write-Log ('[正主] 动手前留 {0} 秒确认窗（这期间还能点「打断」反悔）。' -f $confirmSeconds)
  $confirmed = $true
  for ($c = $confirmSeconds; $c -ge 1; $c--) {
    # 每一秒都查一次取消标记 —— 点了「打断」就立刻停手
    if (Test-Path -LiteralPath $cancelFile) {
      $confirmed = $false
      break
    }
    Set-RestartWindowStageSafe -Stage 'ready' `
      -Detail ('检查都过了，{0} 秒后开始关闭 DSH。' -f $c + "`r`n" + '想反悔就点右下角的「打断这次重启」。') `
      -EtaText ('倒计时 {0} 秒' -f $c)
    Start-Sleep -Seconds 1
  }
  if (-not $confirmed -or (Test-Path -LiteralPath $cancelFile)) {
    Write-Log '[正主] 确认窗里收到了「打断」→ 放弃（DSH 一根汗毛没动）。'
    Save-Result -Outcome 'cancelled' -Detail '用户在动手前的确认窗里点了「打断」' -TookSeconds $watch.Elapsed.TotalSeconds
    Close-RestartWindowSafe -FinalStage 'cancelled' -FinalText '这次重启已经取消了，DSH 没有被动过。' -KeepSeconds 6
    Close-Trip   # ★ 2026-10-23：封口（删计划 + 清 cancel.flag）
    exit 2
  }
  Write-Log ('[正主] {0} 秒确认窗走完，没收到「打断」→ 开始关闭。' -f $confirmSeconds)
}

# ── 第 4 步：关掉 DSH ──────────────────────────────────────────────────────
# ★ 从这里开始，窗口是**唯一**还在显示状态的东西（DSH 自己的界面马上要没了）——
#   这正是当初选"单独一个窗口"而不是做进 DSH 界面的原因。
# ★ 同时：过了这一点就**来不及打断**了（下一步就是发关闭请求）。
#   所以先把「打断」按钮禁掉、并写明原因 —— 留着能点却做不到比不给按钮更糟。
Disarm-RestartWindowAbortSafe
Set-RestartWindowStageSafe -Stage 'closing' -Detail ('检查都过了，正在关闭 DSH（要重启的原因：{0}）。' -f ([string]$plan.reason)) -EtaText '接下来十几秒 DSH 会消失一下，这是正常的。'

# ★ 2026-10-13：**记下"开始关"的时刻** —— 这是"关掉→起来"那一段的起点（见 Save-Result 的 history.jsonl）。
#   ⚠️ 放在这里而不是"发第一个 taskkill 之前"：两者只差几毫秒，
#      但放在这里能覆盖"DSH 本来就不在跑"那条分支（那时也该从这一刻起算）。
$script:DownAt = Get-Date

$procs = Get-DshProcesses
if ($procs.Count -eq 0) {
  Write-Log '[正主] DSH 已经不在跑了 —— 不用关，直接进入"把它拉起来"。'
} else {
  $main = Get-MainDshProcess
  if (-not $main) { $main = $procs | Select-Object -First 1 }
  Write-Log ('[正主] 准备关闭 DSH：共 {0} 个进程，主进程 PID={1}。' -f $procs.Count, $main.Id)
  Set-RestartWindowStageSafe -Stage 'closing' -Detail ('正在关闭 DSH（共 {0} 个进程）。' -f $procs.Count) -EtaText '这是正常的，稍等十几秒。'

  # ══════════════════════════════════════════════════════════════════════════
  # ★★★ 2026-10-23：干跑在这里停 —— **最后一个安全点**
  #
  # 位置是刻意的：必须在「准备关闭」日志之后（这样报告里有真实 PID 和路径），
  # 且必须在第一个 taskkill 之前（这是唯一还没动手的时刻）。
  # 再往前挪就没有"要杀谁"的信息，再往后挪就已经动手了。
  # ══════════════════════════════════════════════════════════════════════════
  if ($DryRun) {
    $pathList = @()
    foreach ($p in $procs) {
      $exe = ''
      try { $exe = [string]$p.Path } catch { }
      $pathList += ('    PID={0,6}  {1}' -f $p.Id, $(if ($exe) { $exe } else { '（读不到路径）' }))
    }
    $report = @()
    $report += '================ 干跑报告（什么都没动）================'
    $report += ('单号      ：' + $script:PlanId)
    $report += ('计划里要拉起：' + $dshExe)
    $report += ('  该文件存在：' + (Test-Path -LiteralPath $dshExe))
    $report += ''
    $report += ('将关闭 {0} 个进程（主进程 PID={1}）：' -f $procs.Count, $main.Id)
    $report += $pathList
    $report += ''
    $report += ('目标一致性：{0}' -f $(if ($preflightOk) { '通过' } else { '**不通过**（真跑的话会被拦下，DSH 不会被动）' }))
    if (-not $preflightOk) { $report += ('  原因：' + ($preflightWhy -join '；')) }
    $report += ''
    $report += '⚠️ 以上进程**一个都没有被动过**，DSH 照常运行。'

    foreach ($line in $report) { Write-Log ('[干跑] ' + $line) }
    # 同时落一份文件，方便贴给别人/事后对照
    try {
      $rp = Join-Path (Split-Path -Parent $PlanFile) 'dry-run-report.txt'
      ($report -join "`r`n") | Set-Content -LiteralPath $rp -Encoding UTF8
      Write-Log ('[干跑] 报告已写到：' + $rp)
    } catch { }

    Close-RestartWindowSafe -FinalStage 'cancelled' -FinalText ("干跑完成，什么都没动。`r`n将关闭 " + $procs.Count + ' 个进程，详见日志。') -KeepSeconds 8
    # 干跑不删 plan.json（它没执行这次重启，计划该留着由人决定要不要真跑）
    exit 0
  }

  # 先礼：不带 /F 的 taskkill 相当于请它自己退（能优雅收尾）
  # 用 Invoke-Quiet 走 —— 直接 `& taskkill.exe` 会闪一下黑框（踩到过）。
  #
  # ⚠️⚠️ 判据（2026-10-10 修）：**只有"请求成功发出去了"才值得等**。
  #   如果 taskkill 当场就报 "could not be terminated / can only be terminated
  #   forcefully"，那说明**根本没人可关**（典型原因：选错了进程，见 Get-MainDshProcess
  #   的注释）——此时再傻等纯属浪费：看到的会是"卡住十几秒"，
  #   而日志里只会留下一句让人以为"DSH 不肯退"的错话。
  #   所以：请求失败 → 直接进"后兵"，不再等。
  $gracefulAsked = $false
  try {
    foreach ($line in (Invoke-Quiet -FileName 'taskkill.exe' -Arguments @('/PID', "$($main.Id)"))) {
      Write-Log ("[正主]   taskkill: {0}" -f $line)
      if ($line -match 'SUCCESS') { $gracefulAsked = $true }
    }
  } catch { Write-Log ("[正主]   taskkill 出错：{0}" -f $_.Exception.Message) }

  # ★★★ 2026-10-10 第二次修：把这里的等待从 12 秒砍到 4 秒 ★★★
  #
  #   为什么砍（实测证据，别凭印象改回去）：
  #     19:31:57 taskkill **SUCCESS**（挑对进程后第一次成功）
  #     19:32:09 还是"它没自己退 → 强制结束" —— 白白等了满 12 秒
  #   查清了根因，**是结构性的，不是偶发**：
  #     ① taskkill 不带 /F 的机制 = 给窗口发 WM_CLOSE；对 Electron 来说
  #        WM_CLOSE 只关**那一个窗口**，不等于退出进程。
  #     ② DSH 的退出条件是源码里的
  #          app.on('window-all-closed', () => { if (platform !== 'darwin') app.quit(); })
  #        —— 要**所有**窗口都关才 quit。
  #     ③ 而主进程实测有 **8 个**顶层窗口：可见的只有 1 个（Chrome_WidgetWin_1），
  #        另外 7 个是隐藏的功能窗口（NotifyIconHost / PowerMessageWindow /
  #        MSFTFIME UI / IME …）。这些**根本不会**被外部关闭请求关掉。
  #     ⇒ 结论：DSH 在结构上就**不可能**被"礼貌关闭"弄退出，等多久都一样。
  #     旁证：那 12 秒里**没有任何**会话文件被写过（0 个）—— 它没在做任何收尾。
  #
  #   那为什么还留 4 秒（不是 0）：
  #     礼貌关闭对**别的**程序/别的 DSH 版本可能是有效的（比如主进程只有可见窗口时，
  #     关掉窗口就会 window-all-closed → quit）。留一个很短的宽限期，
  #     既不会白等，又不会在"其实能优雅退出"的情况下硬砍。
  $waited = 0
  if (-not $gracefulAsked) {
    Write-Log '[正主] 礼貌关闭没能发出去（多半是挑错了进程）—— 不再等，直接强制结束。'
  } else {
    while ($waited -lt 4 -and (Get-Process -Id $main.Id -ErrorAction SilentlyContinue)) {
      Start-Sleep -Seconds 1; $waited += 1
    }
    if (Get-Process -Id $main.Id -ErrorAction SilentlyContinue) {
      # ⚠️ Write-Log 只有一个 [string]$Text 参数（没有 -NoNewline），
      #    所以这里要把整句**拼好再传**，别写成两次调用（会多出一行时间戳）。
      Write-Log ('[正主] 礼貌关闭已发出，但它没退（等了 {0} 秒）—— DSH 有 7 个隐藏窗口，结构上就不会因"关窗口"而退出，所以直接强制结束（不再多等）。' -f $waited)
    }
  }

  # 后兵：还不走就强杀。
  # 注意：不用 /T —— 保险丝不在 DSH 的进程树里，用 /T 反而可能误伤。
  if (Get-Process -Id $main.Id -ErrorAction SilentlyContinue) {
    Write-Log '[正主] 它没自己退 → 强制结束。'
    try {
      foreach ($line in (Invoke-Quiet -FileName 'taskkill.exe' -Arguments @('/F', '/PID', "$($main.Id)"))) {
        Write-Log ("[正主]   taskkill /F: {0}" -f $line)
      }
    } catch { }
  } else {
    Write-Log '[正主] 它自己退了（优雅退出）。'
  }

  # 清理残余（渲染进程等可能还挂着）
  $leftover = 0
  while ($leftover -lt 20) {
    $rest = Get-DshProcesses
    if ($rest.Count -eq 0) { break }
    Kill-AllDsh -ExceptPid $myPid
    Start-Sleep -Seconds 2; $leftover += 2
  }

  $rest = Get-DshProcesses
  if ($rest.Count -gt 0) {
    Write-Log ('[正主] 警告：还有 {0} 个 DSH 进程没清掉（PID: {1}）。' -f $rest.Count, (($rest | ForEach-Object { $_.Id }) -join ','))
  } else {
    Write-Log '[正主] DSH 已完全退出。'
    Set-RestartWindowStageSafe -Stage 'closed' -Detail 'DSH 已经完全关闭。' -EtaText '马上重新打开，请稍等。'
  }
}

# 等端口释放
$pw = 0
while ($pw -lt 30 -and (Test-PortListening -Port $port)) { Start-Sleep -Seconds 1; $pw++ }
if (Test-PortListening -Port $port) { Write-Log ('[正主] 警告：端口 {0} 还被占着。' -f $port) }
else { Write-Log ('[正主] 端口 {0} 已释放。' -f $port) }

# ── 第 5 步：把 DSH 拉起来（并确认真的起来了）───────────────────────────────
if (-not (Test-Path -LiteralPath $dshExe)) {
  $msg = ('找不到 DSH 主程序：{0} —— 没法拉起，请手动打开。' -f $dshExe)
  Write-Log ("[正主] $msg")
  Save-Result -Outcome 'failed' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds
  Close-RestartWindowSafe -FinalStage 'failed' -FinalText ($msg + "`r`n`r`n请手动双击桌面图标打开 DSH。") -KeepSeconds 60
  exit 1
}
Set-RestartWindowStageSafe -Stage 'starting' -Detail '正在重新打开 DSH…' -EtaText '起来之后这个窗口会自己关掉。'

$attempt = 0
$launched = $false
while ($attempt -lt $maxAttempts -and -not $launched) {
  $attempt++
  Write-Log ('[正主] 第 {0}/{1} 次拉起 DSH：{2}' -f $attempt, $maxAttempts, $dshExe)
  Set-RestartWindowStageSafe -Stage 'starting' -Detail ('正在重新打开 DSH（第 {0} 次尝试）…' -f $attempt) -EtaText '起来之后这个窗口会自己关掉。'
  try {
    $created = Start-Dsh -Exe $dshExe -WorkDir $dshWorkDir
    if ($created -and $created.ReturnValue -eq 0) {
      $script:NewPid = [int]$created.ProcessId
      Write-Log ('[正主]   已创建进程 PID={0}，盯端口 {1} 或它的进程树（最多 {2} 秒）…' -f $script:NewPid, $port, $bootTimeout)
      if (Wait-ForPort -Port $port -TimeoutSeconds $bootTimeout -ProcId $script:NewPid) {
        $launched = $true
        # ★ 2026-10-17：新实例的端口不一定还是计划里那个（模块内端口是空的，
        #   重启后会重新分配）。所以这里把**新进程树实际在听的端口**问出来记下，
        #   后面写结果、打日志都用它 —— 否则日志会报一个根本不存在的端口号。
        $newPorts = @(Get-ListeningPortsOfPids -ProcessIds @(Get-ProcessTreePids -RootPid $script:NewPid))
        if ($newPorts.Count -gt 0) { $script:ActualPort = [int]$newPorts[0] }
        Write-Log ('[正主]   ✅ DSH 起来了：端口 {0} 已监听。' -f $script:ActualPort)
        break
      }
      Write-Log ('[正主]   第 {0} 次没成功（端口和进程树都没起来）。' -f $attempt)
    } else {
      $code = if ($created) { $created.ReturnValue } else { 'unknown' }
      Write-Log ('[正主]   创建失败，WMI 返回 {0}。' -f $code)
    }
  } catch {
    Write-Log ('[正主]   拉起时出错：{0}' -f $_.Exception.Message)
  }

  if (-not $launched -and $attempt -lt $maxAttempts) {
    # ══════════════════════════════════════════════════════════════════════════
    # ★★ 2026-10-23 新增：**重试之间的"排队生效"停止点**（用户要的「点叉号就停」）
    #
    # 【用户定的语义，原话】
    #   「点叉号等于终止重启，如果当前阶段无法终止，那就完成当前阶段，停在下一阶段前」
    #
    #   具体到这一段：
    #     · 正在关 DSH  → **不能停**（停手会留下半个 DSH，更糟）→ 这一阶段做完
    #     · 已关掉、正在拉起 → **把当前这次尝试做完**，但**不再试下一次** ← 就是这里
    #   所以检查点必须放在"这一轮已经做完、下一轮还没开始"的位置 —— 正是这里。
    #
    # 【为什么复用 cancel.flag 而不新增文件】
    #   取消标记本来就是这个脚本的"停下"信号，前三个阶段（等计划时间、等空闲、
    #   确认窗）都在查它。这里把同一个信号**延伸到拉起阶段**，
    #   不需要第二个文件、也不需要第二套判断 —— 少一处状态就少一处会过期的东西。
    #
    # 【为什么这比原来强】
    #   原来一旦进入"关掉→拉起"，用户**完全没有任何办法干预**：
    #   拉起失败会闷头重试最多 3 次，每次等满 bootTimeout（默认 90 秒），
    #   最长能干耗约 4 分半，而屏幕上那个「打断」按钮已经灰了。
    #   现在：点一下，它做完当前这次就停，并如实报告"要我手动开"。
    # ══════════════════════════════════════════════════════════════════════════
    if (Test-Path -LiteralPath $cancelFile) {
      Write-Log ('[正主] 收到停止请求（打完第 {0} 次尝试后）→ 不再重试，停下。' -f $attempt)
      break
    }
    Kill-AllDsh          # 清掉没起来的残留，免得下次撞端口
    Start-Sleep -Seconds 3
  }
}

if ($launched) {
  Write-Log '[正主] 重启完成。'
  # ★ 2026-10-24：如果是用户点了「不等了」才提前动手的，把这件事记进结果里
  #   —— 事后看 last-run.json 时，要能分清"自己等到了"和"人催的"。
  $doneDetail = ('DSH 已重新起来，端口 {0} 正常监听（第 {1} 次尝试）。' -f $script:ActualPort, $attempt)
  if ($script:ForceSkipped) { $doneDetail += '（人工放行：没等家务跑完，是在状态窗上点的「不等了，立刻重启」。）' }
  Save-Result -Outcome 'success' -Detail $doneDetail -TookSeconds $watch.Elapsed.TotalSeconds
  # 干完了：撤掉取消标记和计划文件，让插件知道"这次结束了"
  Close-Trip   # ★ 2026-10-23：统一走封口（删计划 + 清 cancel.flag，删前核对 planId）

  # ★ 2026-10-23 晚：**发过"还在排队"提醒的话，补一条"成了"**
  #
  # 【为什么放在这里（顺序讲究，别挪）】
  #   · 必须在新宿主**已经活着**之后 —— 早一秒 `qq-say` 打宿主接口就没地方打；
  #   · 必须在 `Close-Trip` **之后** —— 那一步删计划文件，不能让通知影响封口；
  #   · 必须在 `exit 0` **之前**，但也不能卡太久：函数内部自己最多等 ~10 秒拿端口。
  #     整个函数包了 try/catch，**发不出去绝不影响重启本身**（这是本插件的硬规矩）。
  #
  # ⚠️ `$downToUp` 在 Save-Result 里是**局部变量**，外面拿不到 ——
  #    所以这里按同一个口径（`$script:DownAt` → 现在）**重算一次**，
  #    别去改 Save-Result 的签名（那会牵动 history.jsonl 那段已验证的代码）。
  $downToUpForNotice = 0
  if ($script:DownAt) {
    try { $downToUpForNotice = [math]::Round(((Get-Date) - $script:DownAt).TotalSeconds, 1) } catch { }
  }
  try {
    [void](Send-SuccessReminderIfNeeded -TookSeconds $watch.Elapsed.TotalSeconds -DownToUpSeconds $downToUpForNotice)
  } catch {
    Write-Log ('[提醒] 成功提醒这一步出错（不影响重启）：{0}' -f $_.Exception.Message)
  }

  # 状态窗：让"成了"在屏幕上停一下再自己消失（一闪而过等于没显示）。
  # ⚠️ 必须放在最后：DSH 已经起来了，这个窗口是收尾，不是阻塞。
  Close-RestartWindowSafe -FinalStage 'done' `
    -FinalText ('DSH 已经重新打开，可以继续用了。' + "`r`n`r`n这次重启的原因：`r`n" + [string]$plan.reason) `
    -KeepSeconds 8
  exit 0
} else {
  # ── 没拉起来：分清"它自己试完了"还是"用户叫停的"（2026-10-23 加）──────────
  #
  # ⚠️ 为什么一定要分开：这两种情况**都要记 failed**（因为结果都是"DSH 没起来"），
  #    但说法不同 —— 用户叫停的，不能让他以为是机器坏了。
  #
  # ★ 用户 特别交代：「这个时候应该就给那些等待被唤醒的对话
  #   换一个重启失败的标记」。也就是说：**中途停下也必须贴 🔴**，
  #   否则那些会话永远不知道自己还得再重启一次。
  #   这里写 outcome='failed'，插件侧的 failedSessionIds() 就会按 members[] 贴 🔴 ——
  #   所以"停下"和"真失败"走同一条记账路径，标记行为天然一致。
  $stoppedByUser = (Test-Path -LiteralPath $cancelFile)
  if ($stoppedByUser) {
    $msg = ('你按了停止（第 {0} 次尝试后不再重试）。DSH 现在**是关着的**，请手动双击桌面图标打开。' -f $attempt)
  } else {
    $msg = ('试了 {0} 次都没能把 DSH 拉起来。请手动双击桌面图标打开。' -f $maxAttempts)
  }
  Write-Log ("[正主] $msg")
  Save-Result -Outcome 'failed' -Detail $msg -TookSeconds $watch.Elapsed.TotalSeconds
  Close-Trip   # ★ 2026-10-23：封口 —— 这一趟到此结束，别把 cancel.flag 留给下一趟去拦车

  # 不弹窗（2026-10-08 定）。这一格是"DSH 已经关了又拉不起来"，
  # 此刻对话也随 DSH 一起没了，**没有任何会话通道能通知用户**。
  # 所以不靠弹窗，靠两条：
  #   ① last-run.json 记 outcome=failed（上面 Save-Result 已写）
  #   ② 手动把 DSH 打开后，插件加载 → 下一轮对话开头会看到失败提示
  #      （插件里的 failureNote() 就是干这个的）→ 对话自己如实转告用户
  # 弹窗在无人值守的远程机器上没人点，还会留一个卡住的窗口，故去掉。
  exit 1
}
