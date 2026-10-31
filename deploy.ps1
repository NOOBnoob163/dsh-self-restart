# ============================================================================
#  dsh-self-restart 的「开发区 → 使用区」同步 + 对账
# ============================================================================
#
#  ⚠️ 这个脚本是**开发/自测用**的（本机把源码同步到 DSH 真正加载的位置），
#     发布出去了也用得上：改完源码，用它一键同步 + 对账。
#
#  【为什么需要它】
#    这个插件的源码在你的开发目录里，而 DSH 实际加载的是
#    `%DSH_HOME%\profiles\desktop\plugins\` 下的那一份 —— 两者是分开的：
#      · 开发区（本脚本所在的目录，默认取脚本自己的位置）
#      · 使用区 `%DSH_HOME%\profiles\desktop\plugins\dsh-self-restart\`
#        （DSH 启动时真正加载的那份）
#
#  【方向是单向的】开发区 → 使用区。本脚本**绝不**反向覆盖开发区。
#
#  【为什么要对账】
#    最容易踩的坑是"改了开发区、实际跑的还是旧代码" —— 这种事故**没有任何报错**，
#    只是行为不对。所以提供 -Check：两边不一致就报出来并以退出码 5 结束。
#
#  用法：
#    pwsh -NoProfile -File deploy.ps1 -Check     # 只对账，不改任何东西（退出码 0=一致 / 5=不一致）
#    pwsh -NoProfile -File deploy.ps1 -DryRun    # 预演：会复制哪些文件
#    pwsh -NoProfile -File deploy.ps1            # 真正部署（开发区 → 使用区）
#
#  ⚠️ 踩过的坑（写这个脚本时注意的）：
#    1. 只复制**插件本身**该有的东西：package.json / lib / bin / test。
#       不要把 .git、node_modules 之类带过去。
#    2. 复制必须**逐字节**，不能"读字符串再写回"（换行符被毁过）。
#       这里用 [System.IO.File]::Copy，是字节级复制，不碰换行符。
#    3. PowerShell 变量名大小写不敏感：开关参数 -Check 会和局部变量 $check 撞车
#       （实测过，报"无法将 Hashtable 转换为 SwitchParameter"）。所以下面一律不叫 $check。
# ============================================================================
param(
  [switch]$Check,
  [switch]$DryRun,
  # 开发区默认就是**脚本自己所在的目录** —— 不再写死某台机器的路径。
  [string]$DevDir  = '',
  [string]$LiveDir = ''
)

$ErrorActionPreference = 'Stop'

# 开发区：没指定就用脚本自己所在的目录
if (-not $DevDir) { $DevDir = $PSScriptRoot }

if (-not $LiveDir) {
  $homeDsh = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $LiveDir = Join-Path $homeDsh 'profiles\desktop\plugins\dsh-self-restart'
}

# 同步的白名单（只这些进使用区）
#
# ⚠️ 2026-10-12 补：`cordis.patch.yml` 必须在名单里 —— 它是 bundle 的挂载声明，
#    缺了它插件"装上了但不会启用"，而且**没有任何报错**。这个坑是切换 bundle 时发现的。
$Include = @('package.json', 'cordis.patch.yml', 'lib', 'bin', 'test',
             'README.md', 'CHANGELOG.md', 'LICENSE')

function Get-FileMap {
  param([string]$Root)
  $map = @{}
  foreach ($item in $Include) {
    $p = Join-Path $Root $item
    if (Test-Path -LiteralPath $p) {
      if ((Get-Item -LiteralPath $p).PSIsContainer) {
        Get-ChildItem -LiteralPath $p -Recurse -File -Force | ForEach-Object {
          $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
          $map[$rel] = $_.FullName
        }
      } else {
        $map[$item] = (Get-Item -LiteralPath $p).FullName
      }
    }
  }
  return $map
}

Write-Output ''
Write-Output '=========================================================='
Write-Output '  dsh-self-restart 开发区 → 使用区'
Write-Output '=========================================================='
Write-Output "  开发区  $DevDir"
Write-Output "  使用区  $LiveDir"
Write-Output ''

if (-not (Test-Path -LiteralPath $DevDir)) { throw "开发区不存在：$DevDir" }
if (-not (Test-Path -LiteralPath $LiveDir)) { throw "使用区不存在：$LiveDir" }

$devMap  = Get-FileMap -Root $DevDir
$liveMap = Get-FileMap -Root $LiveDir

# ── 逐字节对账（用哈希比内容）────────────────────────────────
function Get-HashSafe {
  param([string]$Path)
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '<读不到>' }
}

$onlyDev  = @()   # 开发区有、使用区没有  -> 需要复制过去
$onlyLive = @()   # 使用区有、开发区没有  -> 提示（只提示，不删）
$differ   = @()   # 两边都有但内容不同    -> 需要复制过去

foreach ($rel in $devMap.Keys) {
  if (-not $liveMap.ContainsKey($rel)) { $onlyDev += $rel; continue }
  if ((Get-HashSafe $devMap[$rel]) -ne (Get-HashSafe $liveMap[$rel])) { $differ += $rel }
}
foreach ($rel in $liveMap.Keys) {
  if (-not $devMap.ContainsKey($rel)) { $onlyLive += $rel }
}

$total = $devMap.Count
$same  = $total - $onlyDev.Count - $differ.Count

Write-Output '----------------------------------------------------------'
Write-Output ("  开发区共 {0} 个文件；两边内容一致 {1} 个" -f $total, $same)
if ($differ.Count)   { Write-Output ("  [不同] {0} 个（开发区较新，应部署）：" -f $differ.Count) }
if ($onlyDev.Count)  { Write-Output ("  [缺]   {0} 个（开发区有、使用区没有）：" -f $onlyDev.Count) }
if ($onlyLive.Count) { Write-Output ("  [多]   {0} 个（使用区有、开发区没有 —— 只提示，不删）：" -f $onlyLive.Count) }

foreach ($r in ($differ + $onlyDev | Sort-Object)) { Write-Output "      · $r" }
foreach ($r in ($onlyLive | Sort-Object))          { Write-Output "      ? $r" }
Write-Output '----------------------------------------------------------'
Write-Output ''

# ── -Check：只对账 ───────────────────────────────────────────
if ($Check) {
  if ($differ.Count -eq 0 -and $onlyDev.Count -eq 0) {
    Write-Output '  [通过] 两边内容一致，DSH 跑的就是开发区这份。'
    Write-Output ''
    exit 0
  } else {
    Write-Output '  [不一致] 使用区落后了！DSH 跑的不是开发区那份。'
    Write-Output '           跑一次不带 -Check 的本脚本即可部署过去。'
    Write-Output ''
    exit 5
  }
}

# ── ★ 2026-10-22 新增：语法闸门（部署前必须过）────────────────
#
# 【为什么加这一道】
#   2026-10-22 实机踩到：我把一段**有语法错误**的 lib\index.js 直接部署到了使用区。
#   当时 `node --check` 明明报了错，但那条命令和部署是两行、中间没有拦，
#   于是坏代码照样盖了过去。没出事的原因只是运气 ——
#   插件模块是宿主**启动时**读进内存的，改磁盘不影响正在跑的那份。
#   而那意味着：**下一次重启宿主时，插件会加载失败，自我重启功能当场消失**，
#   偏偏那正是需要它的时候（改了插件 → 要重启 → 它正好坏了）。
#
# 【这道闸做什么】
#   · lib\*.js  → `node --check`（Node 的语法检查，只解析不执行）
#   · bin\*.ps1 → PowerShell 自己的 Parser（`ParseFile`，同样只解析不执行）
#   任何一处不过 → **直接退出（码 6），一个文件都不复制**。
#
# 【位置很要紧：必须在 -DryRun / 真部署**之前**】
#   第一版把闸门写在了 -DryRun 后面，结果**空跑根本不检查**（2026-10-22 当场测出来的）——
#   而"空跑一下看看"恰恰是改完代码后最常用的动作，闸门放错地方等于没装。
#   ⚠️ 一起改这里时记住：-Check（只对账）在更前面，它不改文件，可以不过闸。
function Test-DevSyntax {
  param([string]$Root)
  $bad = New-Object System.Collections.Generic.List[string]

  # —— JS：node --check ——
  $jsFiles = @()
  $libDir = Join-Path $Root 'lib'
  if (Test-Path -LiteralPath $libDir) {
    $jsFiles += @(Get-ChildItem -LiteralPath $libDir -Recurse -File -Filter '*.js' -ErrorAction SilentlyContinue)
  }
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($jsFiles.Count -gt 0 -and -not $nodeExe) {
    $bad.Add('找不到 node，无法检查 JS 语法（请确认 node 在 PATH 里）')
  } elseif ($nodeExe) {
    foreach ($f in $jsFiles) {
      $out = & $nodeExe --check $f.FullName 2>&1
      if ($LASTEXITCODE -ne 0) {
        $bad.Add(("lib\{0}：{1}" -f $f.Name, (($out | Select-Object -First 3) -join ' / ')))
      }
    }
  }

  # —— PowerShell：只解析不执行 ——
  $psFiles = @()
  $binDir = Join-Path $Root 'bin'
  if (Test-Path -LiteralPath $binDir) {
    $psFiles += @(Get-ChildItem -LiteralPath $binDir -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
  }
  foreach ($f in $psFiles) {
    $errs = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
      $first = $errs | Select-Object -First 1
      $bad.Add(("bin\{0} 第 {1} 行：{2}" -f $f.Name, $first.Extent.StartLineNumber, $first.Message))
    }
  }

  return ,$bad
}

Write-Output '  [语法检查] 部署前先确认代码本身没写错…'
$syntaxBad = Test-DevSyntax -Root $DevDir
if ($syntaxBad.Count -gt 0) {
  Write-Output ''
  Write-Output '  [拦住] 开发区里有语法错误，**一个文件都没复制**。'
  foreach ($b in $syntaxBad) { Write-Output "        $b" }
  Write-Output ''
  Write-Output '  说明：这道闸是 2026-10-22 加的 —— 那天真把坏代码部署出去过一次，'
  Write-Output '        而它只在**下次重启宿主**时才爆，那时自我重启功能就没了。'
  Write-Output ''
  exit 6
}
Write-Output '  [通过] 语法检查没问题。'
Write-Output ''

# ── -DryRun：只预演 ──────────────────────────────────────────
if ($DryRun) {
  $plan = @($differ + $onlyDev | Sort-Object)
  if ($plan.Count -eq 0) {
    Write-Output '  [空跑] 没有需要复制的文件（两边已经一致）。'
  } else {
    Write-Output ("  [空跑] 会把这 {0} 个文件复制到使用区：" -f $plan.Count)
    foreach ($r in $plan) { Write-Output "      · $r" }
  }
  Write-Output ''
  Write-Output '  （没有改动任何文件）'
  Write-Output ''
  exit 0
}

# ── 真正部署 ────────────────────────────────────────────────
$toCopy = @($differ + $onlyDev | Sort-Object)
if ($toCopy.Count -eq 0) {
  Write-Output '  两边已经一致，不需要复制。'
  Write-Output ''
  exit 0
}

$copied = 0
$failed = @()
foreach ($rel in $toCopy) {
  $src = $devMap[$rel]
  $dst = Join-Path $LiveDir $rel
  try {
    $dstDir = Split-Path -Parent $dst
    if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
      New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
    }
    # ★ 字节级复制（不碰换行符/编码）
    [System.IO.File]::Copy($src, $dst, $true)
    $copied++
  } catch {
    $failed += "$rel  ($($_.Exception.Message))"
  }
}

Write-Output ("  已复制 {0} 个文件到使用区。" -f $copied)
if ($failed.Count) {
  Write-Output ("  [失败] {0} 个：" -f $failed.Count)
  foreach ($x in $failed) { Write-Output "      · $x" }
}
Write-Output ''

# ── 复制完立刻复查 ───────────────────────────────────────────
$reDev  = Get-FileMap -Root $DevDir
$reLive = Get-FileMap -Root $LiveDir
$still = 0
foreach ($rel in $reDev.Keys) {
  if (-not $reLive.ContainsKey($rel)) { $still++; continue }
  if ((Get-HashSafe $reDev[$rel]) -ne (Get-HashSafe $reLive[$rel])) { $still++ }
}
if ($still -eq 0) {
  Write-Output '  [通过] 复查：两边内容已完全一致（逐字节）。'
} else {
  Write-Output ("  [警告] 复查发现仍有 {0} 个文件不一致。" -f $still)
  exit 1
}
Write-Output ''
Write-Output '  提示：改的是 bin\*.ps1 或配置值时不用重启 DSH；'
Write-Output '        改 lib\index.js（插件本体）需要重启宿主才生效。'
Write-Output ''
