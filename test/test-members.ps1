# ============================================================================
#  test-members.ps1 —— 名单（members）结构的单元测试
# ============================================================================
#  2026-10-22 建立。配套决策：docs\decisions-restart-queue.md 的 D7（先补地基）。
#
#  【它测什么】
#    `Get-PlanMembers` 是排队重启的地基函数：它把"一份计划"翻译成"一份名单"。
#    这个函数一旦写错，后果是**静默的**：
#      · 老计划解析不出成员 → 助手以为"没人在等" → 可能不该发车却发车；
#      · 新计划漏掉成员     → 有人排了队却永远等不到自己的那次重启。
#    两种错都不会报错、不会崩，只会"偶尔不对" —— 那正是这个插件历史上最贵的一类 bug。
#
#  【怎么跑】
#    pwsh -NoProfile -File test\test-members.ps1
#    退出码 0 = 全过；非 0 = 有断言失败（末尾会列出哪几条）。
#
#  【本仓硬规矩：新断言必须"改坏一次、看它变红"才算数】
#    所以这个文件同时支持 `-BreakSelfTest`：它会**故意把被测函数掰坏**，
#    然后确认断言真的变红。全部变红才算这套测试可信（见末尾）。
# ============================================================================

[CmdletBinding()]
param(
  [switch]$BreakSelfTest
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$helper = Join-Path (Split-Path -Parent $here) 'bin\dsh-self-restart.ps1'

$script:Pass = 0
$script:Fail = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    $script:Pass++
    Write-Host ("  [通过] {0}" -f $Name) -ForegroundColor Green
  } else {
    $script:Fail++
    $script:Failed.Add($Name)
    Write-Host ("  [失败] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
  }
}

if (-not (Test-Path -LiteralPath $helper)) {
  Write-Host "找不到助手脚本：$helper" -ForegroundColor Red
  exit 1
}

# ── 把被测函数从助手脚本里抠出来（只加载这个函数，不跑整个脚本）──────────────
$text = Get-Content -LiteralPath $helper -Raw -Encoding UTF8
$start = $text.IndexOf('function Get-PlanMembers {')
if ($start -lt 0) {
  Write-Host '找不到 Get-PlanMembers —— 函数被改名或删掉了（本测试需要同步更新）' -ForegroundColor Red
  exit 1
}
# ⚠️ 必须先找**行首**的调用点：函数体内部的注释里也出现了这个串
#   （解释"为什么要套 @()"那段），裸 IndexOf 会切在注释中间 → 函数体截断 → 崩。
$end = -1
foreach ($line in [regex]::Matches($text.Substring($start), '(?m)^\$script:Members = .*Get-PlanMembers -PlanObject')) {
  $end = $start + $line.Index
  break
}
if ($end -lt 0) { $end = $text.Length }
# ⚠️ 2026-10-23：调用点外面套了 `@(...)` 用来兜住"单元素被拆成裸对象"，
#   所以这里不能再用 `$script:Members = Get-PlanMembers` 整串当结束标记
#   （套上 @() 之后那串就不存在了 → IndexOf 返回 -1 → 函数体空 → 测试自己崩）。
#   改成只认"调用"这一段，与外面包不包 @() 无关。
$funcText = $text.Substring($start, $end - $start)

if ($BreakSelfTest) {
  # ★ 故意掰坏：把"老结构兼容分支"的条件改成永远为假。
  #   如果断言是有效的，下面"老计划解析出 1 个成员"那条必须变红。
  $needle = '  if ($PlanObject.requestedBy -or $PlanObject.sessionFile) {'
  if (-not $funcText.Contains($needle)) {
    Write-Host '（掰坏失败：找不到要替换的那一行，测试自身需要更新）' -ForegroundColor Yellow
    exit 2
  }
  $funcText = $funcText.Replace($needle, '  if ($false) {')
  Write-Host ''
  Write-Host '*** 这是"改坏自检"模式：函数已被故意掰坏，下面的失败是预期的 ***' -ForegroundColor Yellow
  Write-Host ''
}

Invoke-Expression $funcText

if (-not (Get-Command Get-PlanMembers -ErrorAction SilentlyContinue)) {
  Write-Host '被测函数没能加载 —— 测试自身坏了，不能把它当成"通过"' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '=== 名单解析（Get-PlanMembers） ===' -ForegroundColor Cyan

# ── 1. 老结构：没有 members，只有 requestedBy / sessionFile ──────────────────
#    兼容性是最要紧的一条：改完之后，**盘上已有的老计划必须照常能跑**。
$old = [pscustomobject]@{
  planId      = 'restart-old'
  requestedBy = 'session-aaa'
  sessionFile = 'C:\tmp\session-aaa\session.v4.jsonl.zstd'
  reason      = '装插件 A'
  resume      = $true
  createdAt   = '2026-10-22T10:00:00.000Z'
}
$mOld = Get-PlanMembers -PlanObject $old
Check '老计划能解析出 1 个成员' ($mOld.Count -eq 1) "实际 $($mOld.Count)"
# ⚠️ 取值一律加"数量够不够"的前置判断：断言失败时数组可能是空的，
#    直接 $mOld[0].xxx 会抛"不能为空数组建立索引"，把后面所有断言一起带崩 ——
#    那样改坏自检只会停在第一行，看不到其余断言到底有没有效（2026-10-22 实际踩到）。
$o0 = if ($mOld.Count -ge 1) { $mOld[0] } else { [pscustomobject]@{ sessionId = ''; reason = ''; resume = $null; source = '' } }
Check '老计划的 sessionId 来自 requestedBy' ($o0.sessionId -eq 'session-aaa') "实际 $($o0.sessionId)"
Check '老计划的理由被带上' ($o0.reason -eq '装插件 A') "实际 $($o0.reason)"
Check '老计划的 resume 被带上' ($o0.resume -eq $true) "实际 $($o0.resume)"
Check '老计划的来源标为 unknown（猜不出来就别猜）' ($o0.source -eq 'unknown') "实际 $($o0.source)"

# ── 2. 新结构：members[] 多人 ────────────────────────────────────────────────
$new = [pscustomobject]@{
  planId  = 'restart-new'
  reason  = '车主理由'
  members = @(
    [pscustomobject]@{ sessionId = 'session-aaa'; reason = '装A'; resume = $true;  source = 'local' }
    [pscustomobject]@{ sessionId = 'session-bbb'; reason = '装B'; resume = $false; source = 'im-direct' }
    [pscustomobject]@{ sessionId = 'session-ccc'; reason = '装C'; resume = $true;  source = 'im-group' }
  )
}
$mNew = Get-PlanMembers -PlanObject $new
Check '新计划解析出 3 个成员' ($mNew.Count -eq 3) "实际 $($mNew.Count)"
# 同样：断言失败时数组可能短，逐个安全取
$n0 = if ($mNew.Count -ge 1) { $mNew[0] } else { [pscustomobject]@{ sessionId=''; reason=''; resume=$null; source='' } }
$n1 = if ($mNew.Count -ge 2) { $mNew[1] } else { [pscustomobject]@{ sessionId=''; reason=''; resume=$null; source='' } }
$n2 = if ($mNew.Count -ge 3) { $mNew[2] } else { [pscustomobject]@{ sessionId=''; reason=''; resume=$null; source='' } }
Check '第 1 个是 aaa' ($n0.sessionId -eq 'session-aaa') "实际 $($n0.sessionId)"
Check '第 2 个是 bbb' ($n1.sessionId -eq 'session-bbb') "实际 $($n1.sessionId)"
Check '第 3 个是 ccc' ($n2.sessionId -eq 'session-ccc') "实际 $($n2.sessionId)"
Check '每个人的理由各归各（不是同一个）' `
  (($n0.reason -eq '装A') -and ($n1.reason -eq '装B') -and ($n2.reason -eq '装C'))
Check '每个人的 resume 各归各（可不同）' `
  (($n0.resume -eq $true) -and ($n1.resume -eq $false) -and ($n2.resume -eq $true))
Check 'source 原样保留' `
  (($n0.source -eq 'local') -and ($n1.source -eq 'im-direct') -and ($n2.source -eq 'im-group'))

# ── ★★ 3-b. 【2026-10-23 晚补】必须验「套了 @() 之后」的形状 ──────────────────
#
# 【为什么这一组必须单独存在 —— 它守的是本仓最贵的一类 bug（静默错）】
#   2026-10-23 实机：两个人凑齐发车，结果**谁都醒不过来**。
#   last-run.json 里 `members[0].sessionId` 是
#     `"session-6ae29222-… session-03568659-…"` —— 两个 id 被空格粘成一个。
#
#   病根：`Get-PlanMembers` 当时用 `return ,$list.ToArray()`（逗号多包了一层），
#   于是返回"一个元素：那个数组"。真实调用点是 `$script:Members = @(Get-PlanMembers …)`，
#   再包一次也救不回来 —— `@()` 之后 Count 是 **1**、`[0]` 是 **Object[]**。
#   接着 `Save-Result` 里 `$script:Members | ForEach-Object` 只跑**一次**，
#   而 `[string]$_.sessionId` 对数组做**属性枚举 + 空格拼接** → 假 id。
#
#   ⚠️ **上面那些断言为什么没抓到它**：它们直接写 `$mNew = Get-PlanMembers …`，
#      **没有 `@()`**。PowerShell 在这种情况下会把 `,$array` 自动展开成 3 个，
#      所以双层数组照样"看起来正常"。
#      ⇒ 判据必须和**真实调用点同形**：`@(Get-PlanMembers …)`。
#      这是"断言要钉事实在哪，别钉我以为它在哪"的又一例。
Write-Host ''
Write-Host '=== 3-b. 真实调用点的形状 ===' -ForegroundColor Cyan
#
# ⚠️⚠️ **这一组必须"照着源码怎么调，我就怎么调"**，不能由测试自己决定。
#
# 【为什么 —— 这个坑我当场踩了一次】
#   第一版：测试写 `@(Get-PlanMembers ...)`（猜的），而源码那时**已经改成不包**。
#   ⇒ 掰坏自检（把源码的 @() 加回去）跑下来，**行为断言一条都没红**，
#     只有"源码钉子"那条红了 —— 因为测试调的形态和源码根本不是一个。
#     那种断言在真事故里救不了人：源码套了 @()、测试没套，测试照样全绿。
#   ⇒ 正确做法：**从源码里读出调用点到底包没包 @()，再照那个形态调**。
#     这样源码一旦退回"两层各包一次"，行为断言就会如实变红。
$callLine = ''
foreach ($ln in [regex]::Matches($text, '(?m)^\s*\$script:Members\s*=\s*.+$')) { $callLine = $ln.Value; break }
$srcWraps = ($callLine -match '@\s*\(\s*Get-PlanMembers')
Write-Host ("  源码调用点 = " + $callLine.Trim())
Write-Host ("  源码包了 @() 吗 = " + $srcWraps + "（测试就照这个形态调）")

if ($srcWraps) {
  $got1 = @(Get-PlanMembers -PlanObject $new)
  $gotSingle = @(Get-PlanMembers -PlanObject ([pscustomobject]@{ members = @([pscustomobject]@{ sessionId = 'session-only'; reason = '就一个' }) }))
} else {
  $got1 = Get-PlanMembers -PlanObject $new
  $gotSingle = Get-PlanMembers -PlanObject ([pscustomobject]@{ members = @([pscustomobject]@{ sessionId = 'session-only'; reason = '就一个' }) })
}

# 把"形状"直接量出来：Count + 元素类型 + 有没有空格拼接
$shapeCount = if ($null -eq $got1) { 0 } else { @($got1).Count }
$elemType = if ($shapeCount -gt 0) { @($got1)[0].GetType().Name } else { '(空)' }
$spaceHits = if ($shapeCount -gt 0) { @(@($got1) | Where-Object { [string]$_.sessionId -match '\s' }).Count } else { 0 }
Write-Host ("  实测形状：Count=$shapeCount  元素类型=$elemType  含空格=$spaceHits")

Check '★★ 按源码的真实形态调，3 个成员仍是 3 个（没被压成 1）' ($shapeCount -eq 3) "实际 $shapeCount"
Check '★★ 每个元素是成员对象（不是 Object[] —— 那是两层 @() 的症状）' `
  ($elemType -eq 'PSCustomObject' -or $elemType -eq 'pscustomobject') "实际 $elemType"
Check '★★★ sessionId 之间没有空格拼接（那次事故的直接表现）' ($spaceHits -eq 0) `
  $(if ($shapeCount -gt 0) { "第一个 = [$(@($got1)[0].sessionId)]" } else { '(取不到)' })

$singleCount = if ($null -eq $gotSingle) { 0 } else { @($gotSingle).Count }
Check '★ 只有 1 个人时**也**是数组（Count=1，不是裸对象）' ($singleCount -eq 1) "实际 $singleCount"
Check '★ 单人的 sessionId 正确' ($singleCount -eq 1 -and @($gotSingle)[0].sessionId -eq 'session-only') `
  $(if ($singleCount -eq 1) { "实际 $(@($gotSingle)[0].sessionId)" } else { '(取不到)' })

# 源码钉子：两层各包一次的那个组合绝不许回来
$badCall = @([regex]::Matches($text, '(?m)^\s*\$script:Members\s*=\s*@\(\s*Get-PlanMembers'))
Check '★ 源码里调用点**没有**再套 @()（套了就和 ,$arr 叠成两层）' ($badCall.Count -eq 0) `
  "命中 $($badCall.Count) 处"
$badRet = @([regex]::Matches($text, '(?m)^\s*return\s+\$list\.ToArray\(\)'))
Check '★ 源码里 return 仍然带逗号（不带的话单人会被拆成裸对象）' ($badRet.Count -eq 0) `
  "命中 $($badRet.Count) 处写成裸 return"

# ── 3. 边界：空计划 / 空 members 数组 / 缺字段 ───────────────────────────────
$mEmpty = Get-PlanMembers -PlanObject ([pscustomobject]@{})
Check '空计划 → 0 个成员（不是崩、也不是 1 个）' ($mEmpty.Count -eq 0) "实际 $($mEmpty.Count)"

$mEmptyArr = Get-PlanMembers -PlanObject ([pscustomobject]@{ members = @() })
Check 'members 是空数组 → 退回老结构判定' ($mEmptyArr.Count -eq 0) "实际 $($mEmptyArr.Count)"

$mEmptyArrWithOld = Get-PlanMembers -PlanObject ([pscustomobject]@{
    members = @(); requestedBy = 'session-zzz'; reason = '兜底'
  })
Check 'members 空但 requestedBy 在 → 仍然解析出那 1 个（不丢人）' `
  ($mEmptyArrWithOld.Count -eq 1 -and $mEmptyArrWithOld[0].sessionId -eq 'session-zzz') `
  "实际 $($mEmptyArrWithOld.Count)"

$mNoSource = Get-PlanMembers -PlanObject ([pscustomobject]@{
    members = @([pscustomobject]@{ sessionId = 'session-x'; reason = 'r' })
  })
Check '成员缺 source → 标 unknown（不崩、不猜）' `
  ($mNoSource.Count -eq 1 -and $mNoSource[0].source -eq 'unknown') `
  "实际 $(if ($mNoSource.Count) { $mNoSource[0].source } else { '(空)' })"

# ── 4. null 安全：整个计划是 $null 时不能抛──────���─────────────────────────────
$threw = $false
try { $mNull = Get-PlanMembers -PlanObject $null } catch { $threw = $true }
Check '传 $null 不抛异常' (-not $threw)
Check '传 $null 得到 0 个成员' ((-not $threw) -and $mNull.Count -eq 0)

Write-Host ''
if ($BreakSelfTest) {
  # 改坏模式下：**必须有失败**才算这套断言有效。
  if ($script:Fail -gt 0) {
    Write-Host ("*** 改坏自检通过：{0} 条变红了 —— 说明这些断言真的盯着代码，不是摆设 ***" -f $script:Fail) -ForegroundColor Yellow
    exit 0
  }
  Write-Host '*** 改坏自检失败：掰坏了却一条都没红 → 这套断言是假的 ***' -ForegroundColor Red
  exit 3
}

Write-Host ("结果：通过 {0} 条，失败 {1} 条" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
  Write-Host '失败的断言：' -ForegroundColor Red
  $script:Failed | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
  exit 1
}
exit 0
