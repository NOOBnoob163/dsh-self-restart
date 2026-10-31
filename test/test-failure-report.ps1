# ══════════════════════════════════════════════════════════════════════════
#  实测：重启失败报告（Write-FailureReport）
# ══════════════════════════════════════════════════════════════════════════
#
#  【为什么要有这一套（2026-10-11）】
#    设计目标：重启失败时留下一份人能直接看懂的说明，并且**放在桌面**。
#    为什么特别重要：DSH 起不来的时候，用户**只能看到桌面** ——
#    这是唯一还能把"出了什么事、现在点哪"递到他眼前的通道。
#    之前因为状态窗那个 bug（点源在函数内），失败提示**从来没显示过**，
#    所以这份报告是"断线之后还留个话"的兜底，必须可靠。
#
#  用法：powershell -NoProfile -File test-failure-report.ps1
$ErrorActionPreference = 'Stop'

$helper = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-self-restart.ps1')).Path

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

# ── 用 AST 精确取出函数定义（不靠正则，避免被注释里的花括号截断）──────────
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errs)
$fn = $ast.FindAll({
  param($n)
  $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-FailureReport'
}, $true) | Select-Object -First 1
Check '能从助手脚本里取出 Write-FailureReport' ($null -ne $fn)
if (-not $fn) { Write-Host '取不到函数，后续无法验证'; exit 1 }

# ── 造它需要的上下文（都不碰真环境）─────────────────────────────────────
$work = Join-Path $env:TEMP ('fr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$planId = 'restart-test-report'
$dshExe = 'C:\Program Files\Fake\DeepSeek Harness.exe'
$port = 19387
$lastRunFile = Join-Path $work 'last-run.json'
$script:LogPath = Join-Path $work 'helper.log'
$plan = [pscustomobject]@{ reason = '自测用：想验证报告长什么样' }
$logLines = New-Object System.Collections.Generic.List[string]
function Write-Log { param([string]$Text) $logLines.Add($Text) | Out-Null }

Invoke-Expression $fn.Extent.Text
Check '函数能被加载（语法/依赖没问题）' $true

# ── ① 生成一份，检查它真的落到指定目录 ──────────────────────────────────
$p = Write-FailureReport -Detail '试了 3 次都没能把 DSH 拉起来。' -Who 'helper' -TookSeconds 92.4 -OutDir $work
Check '① 报告文件生成了' (Test-Path -LiteralPath $p) (Split-Path -Leaf $p)
Check '① 文件名带时间戳（一眼知道哪一次）' ((Split-Path -Leaf $p) -match 'DSH重启失败-\d{8}-\d{6}\.txt') (Split-Path -Leaf $p)

$txt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)

# ── ② 内容要求：先说"现在干什么"，且用大白话 ────────────────────────────
Check '② 第一段就告诉用户"现在该做什么"' ($txt -match '【现在该做什么】')
Check '② 明确说双击桌面图标' ($txt -match 'DeepSeek Harness.{0,4}图标')
# 备选打开方式：2026-10-12 脱敏时把"重启DSH.cmd"（本机私有文件夹里的脚本）
#   换成了通用说法（便携版/绿色版去自己的文件夹找）。这条断言跟着改 ——
#   它的本意是"报告里要有桌面图标之外的第二条路"，不是绑定某个本机专有文件名。
Check '② 备选打开方式提到"便携版/自己的文件夹"' ($txt -match '便携版|绿色版')
# 大白话：前半段（给用户的）不该出现端口号/PID/单号这些词
$userPart = ($txt -split '【给维护者看的信息】')[0]
$jargon = @()
foreach ($w in @('PID', 'planId', '单号', '端口', 'json', 'WMI')) {
  if ($userPart -match [regex]::Escape($w)) { $jargon += $w }
}
Check '② 给用户那段没有技术黑话（端口/PID/单号…）' ($jargon.Count -eq 0) $(if ($jargon.Count) { '混进了: ' + ($jargon -join ', ') } else { '干净' })

# ── ③ 给维护者的信息必须齐（出事时要能查）────────────────────────────────
foreach ($k in @('单号', '结果', '耗时', '主程序', '端口', '重启原因', '详细日志')) {
  Check "③ 含维护者需要的『$k』" ($txt -match [regex]::Escape($k))
}
Check '③ 日志路径写的是真 LogPath' ($txt -match [regex]::Escape($script:LogPath))

# ── ④ 给失败原因猜测（用户最想知道的"为什么"）────────────────────────────
Check '④ 有"可能的原因"一节' ($txt -match '可能的原因')
Check '④ 提到了"主程序被移动/删掉"这个最常见原因' ($txt -match '主程序被移动或删掉')

# ── ⑤ 安全：绝不能写进任何凭据/密钥类内容 ────────────────────────────────
$bad = @()
foreach ($w in @('token', 'api_key', 'apikey', 'secret', 'password', '密码', '密钥', 'Bearer')) {
  if ($txt -match ('(?i)' + [regex]::Escape($w))) { $bad += $w }
}
Check '⑤ 报告里没有密钥类字眼' ($bad.Count -eq 0) $(if ($bad.Count) { '命中: ' + ($bad -join ', ') } else { '干净' })

# ── ⑥ 署名要能分辨是谁报的（助手 / 保险丝）──────────────────────────────
$p2 = Write-FailureReport -Detail '保险丝也没能拉起 DSH。' -Who 'watchdog' -TookSeconds 30 -OutDir $work
$txt2 = [System.IO.File]::ReadAllText($p2, [System.Text.Encoding]::UTF8)
Check '⑥ 保险丝报的会署名"保险丝"' ($txt2 -match '谁报的：保险丝')
Check '⑥ 助手报的会署名"重启助手"' ($txt -match '谁报的：重启助手')

# ── ⑦ 连生两份不会互相覆盖（同一秒内也不行）──────────────────────────────
#  ⚠️ 这条是自测**真的抓到过 bug** 的：文件名原本精确到秒，
#     正主失败后紧接着保险丝也失败时，第二份会**覆盖**第一份 ——
#     用户只能看到一份，另一份的原因就丢了。
Check '⑦ 两次生成是两份不同文件（不会覆盖）' ($p -ne $p2) ("$([System.IO.Path]::GetFileName($p)) vs $([System.IO.Path]::GetFileName($p2))")
Check '⑦ 两份都还在（第一份没被覆盖）' ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $p2))

# ── ⑧ 写日志留痕（出事时要查得到"报告写到哪了"）──────────────────────────
Check '⑧ 生报告时往日志里留了一行' (($logLines -join "`n") -match '已写失败报告')

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) { Write-Host '失败项：'; foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" } }
if ($failed.Count) { exit 1 }
exit 0
