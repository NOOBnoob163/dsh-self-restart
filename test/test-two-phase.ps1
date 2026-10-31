# 测"两段式"等待逻辑（2026-10-08 定下的设计）
#
# 要解决的缺陷：发起重启的那个会话自己会把重启等黄 ——
#   它排完重启还得说话/干活，自己的写入不断重置静默计时 → 白排。
#
# 规则（"改成等这一轮说完，然后去查还有没有别人"）：
#   第一段：只等**发起会话自己**把这一轮说完（别人的活动不参与判断）
#   第二段：这一轮说完了，再去查有没有别人在跑；有 → 放弃（不排队）
#
# ⚠️ 本测试的写法教训（2026-10-08 自己踩的）：
#   · 断言别用宽泛的词（如"别的会话"）—— 成功文案里也含这几个字，会误判。
#   · 每个场景要有**自己的**假目标：跑赢的场景会把假目标杀掉，后面的场景就没得用了。
#   · 判"有没有动手"要看日志里有没有「准备关闭 DSH」，比查进程存活可靠。
#
# 用法：powershell -NoProfile -File test-two-phase.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmpDir = Join-Path $env:TEMP ('selfrestart-2ph-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
# ★ 2026-10-21：身份档案目录必须隔离（见 test-static-sanity ⑤ 的说明）。
#   不隔离的话助手会去读真实会话档案（本机 1451 个，冷读可达 46 秒），
#   把本套测试的时序断言全冲垮 —— 而失败信息看起来像功能 bug，极难分辨。
$cacheRoot = Join-Path $tmpDir 'subagent-cache'
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$fakeTag  = 'TWOPH-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$portBase = 58811

$realBefore = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerBefore = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Write-Host "真 DSH 基线：$($realBefore.Count) 个进程，监听者 PID=$realListenerBefore"
Write-Host "临时目录：$tmpDir`n"

# ── 假会话目录：一个"我的"、一个"别人的" ─────────────────────────────────────
$sess = Join-Path $tmpDir 'sessions'
$meDir    = Join-Path $sess '--fake-ws--\session-ME'
$otherDir = Join-Path $sess '--fake-ws--\session-OTHER'
New-Item -ItemType Directory -Path $meDir, $otherDir -Force | Out-Null
$meFile    = Join-Path $meDir 'session.v4.jsonl.zstd'
$otherFile = Join-Path $otherDir 'session.v4.jsonl.zstd'

# ── 每个场景起一个自己的假应用（会被前一个场景杀掉的，不能复用）──────────────
$fakeScript = Join-Path $tmpDir 'fake.ps1'
@"
param([string]`$Tag, [int]`$Port)
`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, `$Port)
`$l.Start()
try { while (`$true) { Start-Sleep -Seconds 1 } } finally { `$l.Stop() }
"@ | Set-Content -LiteralPath $fakeScript -Encoding utf8
$fakeExe = Join-Path $tmpDir 'fake.exe'
Set-Content -LiteralPath $fakeExe -Value 'MZ placeholder' -Encoding ascii

function Start-Fake([int]$port) {
  $p = Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',$fakeScript,'-Tag',$fakeTag,'-Port',$port
  ) -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 3
  return $p
}

function Run-Helper([string]$label, [int]$port) {
  $planPath = Join-Path $tmpDir "plan-$label.json"
  $logPath  = Join-Path $tmpDir "log-$label.txt"
  $plan = [ordered]@{
    planId             = "2ph-$label"
    createdAt          = (Get-Date).ToString('o')
    scheduleAt         = (Get-Date).AddSeconds(-1).ToString('o')
    reason             = "两段式测试 $label"
    port               = $port
    dshExe             = $fakeExe
    dshWorkDir         = $tmpDir
    idleSeconds        = 4
    maxWaitMinutes     = 0.35
    othersWindowSeconds = 20          # 测试用窗口，跑得快（给用户默认 120）
    bootTimeoutSeconds = 4
    maxAttempts        = 1
    sessionFile        = $meFile
    sessionsRoot       = $sess
    subagentCacheRoot  = $cacheRoot   # ★ 指向空目录，绝不读真实会话档案
    stateFile          = (Join-Path $tmpDir "state-$label.json")
    logFile            = $logPath
    lastRunFile        = (Join-Path $tmpDir "lastrun-$label.json")
    cancelFile         = (Join-Path $tmpDir "cancel-$label.flag")
    showWindow          = $false   # 测试不许弹窗（状态窗是 restart-window 那套专测的）
    requestedBy        = 'session-ME'
  }
  [System.IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))

  # 用 -Detached 直接起正主（本测试只验判定逻辑，避开脱离环节）
  Start-Process -FilePath $psExe -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,
    '-PlanFile',$planPath,'-Detached',
    '-TargetProcessName','powershell','-TargetCommandMatch',$fakeTag
  ) -WindowStyle Hidden | Out-Null

  # ★ 2026-10-23 改：从"死等 20 秒"改成"**等结果出现**"（最多 75 秒）。
  #
  # 【为什么必须改 —— 这是测试自己的脆弱，不是功能回归】
  #   原写法固定睡 20 秒就去读 lastrun。而助手这一轮实测**第 22 秒**才写出结果：
  #     · 18:22:58 起跑 → 18:23:20 才落 skipped-busy（中间建身份档案映射花了 2.8s、
  #       轮询粒度 2s、还有"两轮确认是不是还在写"那道安全设计要多吃一轮）
  #   ⇒ 读早了 → outcome 读到空 → 断言报红，可**功能其实完全正确**
  #     （A/B 两个场景事后核对：outcome 都是 skipped-busy，假应用都活着）。
  #   这正是本仓反复记的教训：断言失败先问"是功能坏了，还是我等早了"。
  #
  # 判据取"助手的结论落盘了没有"（lastrun 文件出现 + 可解析），不取固定秒数。
  # 仍然保留上限：超时就带着空结果返回，让断言如实报红（不静默放过）。
  $lr = Join-Path $tmpDir "lastrun-$label.json"
  $deadline = (Get-Date).AddSeconds(75)
  $outcome = ''
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $lr) {
      try {
        $o = (Get-Content $lr -Raw -Encoding UTF8 | ConvertFrom-Json).outcome
        if ($o) { $outcome = [string]$o; break }
      } catch { /* 正被写，下一拍再读 */ }
    }
  }
  # 结论出来后再等 1.5 秒，让"已封口 / 保险丝撤"这类收尾日志也落进去（它们紧跟其后）
  Start-Sleep -Milliseconds 1500
  $log = if (Test-Path $logPath) { Get-Content $logPath -Raw -Encoding UTF8 } else { '' }
  return @{ Log = $log; Outcome = $outcome }
}

Write-Host "--- 场景 A：我还在写 + 别人也在写 → 第一段只该等我，绝不提别人 ---"
$fa = Start-Fake $portBase
Set-Content -LiteralPath $meFile -Value 'a' -Encoding ascii
(Get-Item $meFile).LastWriteTime = (Get-Date)
Set-Content -LiteralPath $otherFile -Value 'a' -Encoding ascii
(Get-Item $otherFile).LastWriteTime = (Get-Date)
$rA = Run-Helper 'A' $portBase
Write-Host $rA.Log
Check 'A: 报了「还在等这一轮说完」' ($rA.Log -match '还在等这一轮说完')
# 第一段的不变量：等「这一轮说完」期间，绝不该拿别人的活动当理由。
# 注意不能整篇日志扫「还有别人在忙」—— 场景 A 里第二段本来就该报这句话（正是它拦下了这次重启）。
$phase1A = ($rA.Log -split '这一轮已经说完了|准备关闭 DSH')[0]
Check '★ A: 第一段**没提**别人在忙（只看第一段）' ($phase1A -notmatch '还有别人在忙|别人在忙')
Check '★ A: 第一段报的理由是「我自己还在写」' ($phase1A -match '还在等这一轮说完（这一轮还在写')
Check '★ A: 别人忙时**没有**动手' ($rA.Log -notmatch '准备关闭 DSH')
Check '★ A: 假应用还活着（真的没碰它）' ([bool](Get-Process -Id $fa.Id -ErrorAction SilentlyContinue)) "PID=$($fa.Id)"
Check 'A: 结果也记 skipped-busy（第二段拦下的）' ($rA.Outcome -eq 'skipped-busy') "outcome=$($rA.Outcome)"

Write-Host "`n--- 场景 B：我早已说完 + 别人在写 → 第二段该发现并放弃，绝不动手 ---"
$fb = Start-Fake ($portBase + 1)
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-5)
Set-Content -LiteralPath $otherFile -Value 'b' -Encoding ascii
(Get-Item $otherFile).LastWriteTime = (Get-Date)
$rB = Run-Helper 'B' ($portBase + 1)
Write-Host $rB.Log
Check 'B: 第二段发现了别人在忙' ($rB.Log -match '还有别人在忙|一直有人在忙')
Check 'B: 结果记 skipped-busy' ($rB.Outcome -eq 'skipped-busy') "outcome=$($rB.Outcome)"
Check '★ B: **没有**动手（日志里没有「准备关闭 DSH」）' ($rB.Log -notmatch '准备关闭 DSH')
Check '★ B: 假应用还活着（真的没碰它）' ([bool](Get-Process -Id $fb.Id -ErrorAction SilentlyContinue)) "PID=$($fb.Id)"

Write-Host "`n--- 场景 C：我说完了 + 别人也没在忙 → 该动手 ---"
$fc = Start-Fake ($portBase + 2)
(Get-Item $meFile).LastWriteTime = (Get-Date).AddMinutes(-5)
(Get-Item $otherFile).LastWriteTime = (Get-Date).AddMinutes(-5)
$rC = Run-Helper 'C' ($portBase + 2)
Write-Host $rC.Log
Check 'C: 两段都过 → 动手' ($rC.Log -match '可以动手了|准备关闭 DSH')

# ── 收尾 & 安全断言 ─────────────────────────────────────────────────────────
foreach ($p in @($fa, $fb, $fc)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$realAfter = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id | Sort-Object)
$realListenerAfter = (Get-NetTCPConnection -LocalPort 19387 -State Listen -ErrorAction SilentlyContinue).OwningProcess
Check '★ 真 DSH 毫发无伤（监听者 PID 没变）' ($realListenerBefore -eq $realListenerAfter) "之前 PID=$realListenerBefore → 现在 PID=$realListenerAfter"

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
Write-Host "`n日志留在：$tmpDir"
if ($failed.Count) { exit 1 }
exit 0
