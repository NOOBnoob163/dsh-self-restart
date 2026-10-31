# 实测：Test-IsSubagentSession 认得准不准？
#
# 这个判据决定"重启该放弃还是该等它跑完"，判错两种后果都严重：
#   · 把真对话当家务 → 可能砍断别人正在写的活（用户最担心的事）
#   · 把家务当真对话 → 自动重启永远做不成（就是这次的 bug）
#
# 所以拿**真实数据**验：用 DSH 自己写的身份档案，逐个核对判据结论。
#
# 用法：powershell -NoProfile -File test-session-kind.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

# 把助手里的那些函数**原样抠出来**跑（保证测的就是生产代码，不是副本）
$src = Get-Content -LiteralPath $helper -Raw -Encoding UTF8
$fnMatch = [regex]::Match($src, '(?s)function Test-IsSubagentSession\s*\{.*?\n\}')
if (-not $fnMatch.Success) { Write-Host '❌ 抠不出 Test-IsSubagentSession'; exit 1 }

# ⚠️ 2026-10-11：Read-JsonFile 现在**依赖 Read-JsonResult**（读失败要重试），
#    所以两个都得抠出来，只抠 Read-JsonFile 会让它调用一个不存在的函数 →
#    Test-IsSubagentSession 里那个 catch 会把异常吞掉 → 一律返回"不是子代理" →
#    大面积误判（实测报"不一致 298 个"，差点被当成判据坏了）。
#    这类"抠函数"的测试很脆：**只要被测函数的依赖变了，就必须同步补上**。
$jsonResultFnMatch = [regex]::Match($src, '(?s)function Read-JsonResult\s*\{.*?\n\}')
if (-not $jsonResultFnMatch.Success) { Write-Host '❌ 抠不出 Read-JsonResult'; exit 1 }

$jsonFnMatch = [regex]::Match($src, '(?s)function Read-JsonFile\s*\{.*?\n\}')
if (-not $jsonFnMatch.Success) { Write-Host '❌ 抠不出 Read-JsonFile'; exit 1 }

Invoke-Expression $jsonResultFnMatch.Value
Invoke-Expression $jsonFnMatch.Value
Invoke-Expression $fnMatch.Value
Write-Host '（已从生产脚本抠出 Read-JsonResult / Read-JsonFile / Test-IsSubagentSession）'

# ★ 抠完立刻自检：依赖真的都在吗？（缺了要**当场报错**，不能让它悄悄退化成误判）
foreach ($need in @('Read-JsonResult', 'Read-JsonFile', 'Test-IsSubagentSession')) {
  if (-not (Get-Command $need -ErrorAction SilentlyContinue)) {
    Write-Host "❌ 抠函数失败：$need 没定义（后面的判据会静默退化）" -ForegroundColor Red
    exit 1
  }
}
# 再验一次"真的能读到文件"（拿本脚本自己当靶子），确认读取链路是通的
$selfRead = Read-JsonFile -Path (Join-Path $PSScriptRoot 'no-such-file-probe.json')
if ($null -ne $selfRead) { Write-Host '❌ 读取链路自检异常：不存在的文件竟然读出了内容' -ForegroundColor Red; exit 1 }
Write-Host '（读取链路自检通过：依赖齐备、不存在时返回 $null）'

$realRoot = Join-Path $env:USERPROFILE '.dsh\storages\session_projcache\sessions'
Check '本机有 DSH 的身份档案目录（没有就只跑合成用例）' (Test-Path $realRoot) $realRoot

# ── 用**合成档案**验判据（不依赖本机任何真实会话 id）─────────────────────────
# ★ 2026-10-13 改：原先这里硬编码了本机两个真实会话 id（一个子代理、一个真对话）。
#   问题是：① 那是使用者本机的数据，进公开仓库不合适；
#   ② 换台机器那两个 id 根本不存在 → 这两条断言必然失败（别人 clone 下来跑不过）。
#   改成造一份假的档案目录：判据读的是"档案里的 subagent.identity 有没有值"，
#   用合成数据完全能验同一件事，而且到哪台机器都跑得通。
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-sr-sessionkind-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$fixtureSub  = 'aaaa1111-2222-3333-4444-555566667777'
$fixtureReal = 'bbbb8888-9999-0000-1111-222233334444'
# ⚠️ 文件名有两种形态（本机真实档案实测：573 个里 272 个带 `session-` 前缀）：
#   判据的查找顺序是「先按传入 id 找 `<id>.json`，找不到再找 `session-<去掉前缀的id>.json`」，
#   所以两种命名都得造出来才算测全。
$subBody = @"
{ "version": 7, "record": { "rows": {
  "subagent": { "ver": 2, "seq": 7, "val": { "identity": { "mode": "one-shot", "label": "idle checkpoint review" } } },
  "title": { "ver": 1, "seq": 1, "val": "housekeeping" }
} } }
"@
$realBody = @"
{ "version": 7, "record": { "rows": {
  "title": { "ver": 1, "seq": 1, "val": "a real conversation" }
} } }
"@
# 不带前缀的档案（判据直接按 `<id>.json` 命中）
Set-Content -LiteralPath (Join-Path $fixtureRoot "$fixtureSub.json")  -Value $subBody  -Encoding UTF8
Set-Content -LiteralPath (Join-Path $fixtureRoot "$fixtureReal.json") -Value $realBody -Encoding UTF8
# 带前缀的档案（判据走第二条路：`session-<bare>.json`）
$fixtureSubPrefixed = 'cccc2222-3333-4444-5555-666677778888'
Set-Content -LiteralPath (Join-Path $fixtureRoot "session-$fixtureSubPrefixed.json") -Value $subBody -Encoding UTF8

Check '把「有 subagent.identity 的会话」判为子代理' (Test-IsSubagentSession -SessionId $fixtureSub -CacheRoot $fixtureRoot) $fixtureSub
Check '把「没有 subagent 栏的会话」判为**不是**子代理' (-not (Test-IsSubagentSession -SessionId $fixtureReal -CacheRoot $fixtureRoot)) $fixtureReal
# 档案文件名带 session- 前缀时，用带前缀的 id 去问也要认得出来
Check '档案名带 session- 前缀时同样认得出' (Test-IsSubagentSession -SessionId "session-$fixtureSubPrefixed" -CacheRoot $fixtureRoot) "session-$fixtureSubPrefixed"

# ── 边界：不存在的会话 / 空 id → 一律当"真对话"（保守，绝不误砍）──
Check '不存在的会话 → 当"不是子代理"（保守）' (-not (Test-IsSubagentSession -SessionId 'no-such-session-12345' -CacheRoot $fixtureRoot))
Check '空 id → 当"不是子代理"（保守）' (-not (Test-IsSubagentSession -SessionId '' -CacheRoot $fixtureRoot))
Check '档案目录不存在 → 当"不是子代理"（保守）' (-not (Test-IsSubagentSession -SessionId $fixtureSub -CacheRoot 'C:\no\such\dir'))

try { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force } catch { }

# ── 全量交叉核对：判据结论 vs 档案里的事实，看有没有反例 ──
# 这一段用**本机真实档案**（如果有）：它不依赖任何硬编码 id，
# 而是把每个档案都喂给判据，看结论与档案自己的记录是否一致。
if (Test-Path $realRoot) {
  $cacheRoot = $realRoot
  Write-Host "`n--- 全量交叉核对（判据 vs 本机档案事实）---"
  $total = 0; $subs = 0; $reals = 0; $mismatch = @()
  Get-ChildItem $cacheRoot -File -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
    $id = $_.BaseName
    try {
      $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $sub = $j.record.rows.subagent
      $truthIsSub = ($null -ne $sub -and $null -ne $sub.val -and $null -ne $sub.val.identity)
      $guessIsSub = Test-IsSubagentSession -SessionId $id -CacheRoot $cacheRoot
      $total++
      if ($truthIsSub) { $subs++ } else { $reals++ }
      if ($truthIsSub -ne $guessIsSub) {
        $mismatch += [pscustomobject]@{ Id = $id; 档案说 = $truthIsSub; 判据说 = $guessIsSub }
      }
    } catch { }
  }
  Write-Host ("档案总数 $total（子代理 $subs、真对话 $reals）")
  Check "★ 判据与档案**完全一致**（0 个反例）" ($mismatch.Count -eq 0) ("不一致 " + $mismatch.Count + " 个")
  if ($mismatch.Count -gt 0) { $mismatch | Select-Object -First 5 | Format-Table -AutoSize | Out-String | Write-Host }
} else {
  Write-Host "`n（本机没有 DSH 档案目录，跳过全量交叉核对 —— 这只说明没数据，不是失败）"
}

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
if ($failed.Count) { exit 1 }
exit 0
