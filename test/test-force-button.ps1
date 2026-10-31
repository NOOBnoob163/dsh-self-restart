# 状态窗「不等了，立刻重启」按钮的端到端验证（2026-10-24 新增）
#
# 【为什么需要这一套】
#   2026-10-24 实机：一趟重启卡在记忆插件的复审子代理上，卡片只写「等家务子代理 1 个」，
#   用户既不知道在等谁、也没有"别等了"的出口，只能打断整趟。
#   于是加了第二个按钮。按钮是 WPF 控件，**读源码证明不了它点下去真的写标记** ——
#   必须开真窗口、真点一下、看文件。
#
# 【验什么】
#   ① 没被"点亮"之前，点它**什么都不写**（防误触：绝不能一点就跳）
#   ② 点亮之后点它 → 写 force.flag，**不写** cancel.flag（这是"催"，不是"取消"）
#   ③ 「打断」按钮的原有行为没被带坏（仍然写 cancel.flag）
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File test-force-button.ps1
$ErrorActionPreference = 'Stop'

$mod = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\dsh-restart-window.ps1')).Path
. $mod

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  Write-Host "$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })"
}

$tmp = Join-Path $env:TEMP ('rw-force-btn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$env:DSH_RW_TEST_MODE = '1'   # 标题带【测试】，别人一眼知道这不是真重启

try {
  # ── 第 1 段：没点亮 → 点了也不写 ────────────────────────────────────────
  $cancel1 = Join-Path $tmp 'cancel-1.flag'
  $force1  = Join-Path $tmp 'force-1.flag'
  $okShow = Show-RestartWindow -Port 65531 -Reason '自测：不等了按钮（不是真重启）' `
    -LogFile (Join-Path $tmp 'win-1.log') -CancelFile $cancel1 -ForceFile $force1
  Check '（前置）状态窗能起来' $okShow
  Start-Sleep -Milliseconds 900

  Check '（前置）拿到了「不等了」按钮的坐标' ((Get-RestartWindowForceButtonPos) -match '^\d+,\d+$') (Get-RestartWindowForceButtonPos)
  [void](Invoke-RestartWindowForceClick)
  Start-Sleep -Milliseconds 700
  Check '★ 没点亮时点它：**不写** force.flag（不许一点就跳）' (-not (Test-Path $force1))
  Check '★ 没点亮时点它：也没有误写 cancel.flag' (-not (Test-Path $cancel1))

  # ── 第 2 段：点亮 → 点它写 force.flag（而不是 cancel）─────────────────────
  Set-RestartWindowForce -Enabled $true -ForceFile $force1
  Start-Sleep -Milliseconds 400
  [void](Invoke-RestartWindowForceClick)
  Start-Sleep -Milliseconds 900
  Check '★ 点亮后点它：真的写下 force.flag' (Test-Path $force1)
  Check '★ 写的是"催"不是"取消"（cancel.flag 不存在）' (-not (Test-Path $cancel1))
  $content = if (Test-Path $force1) { Get-Content $force1 -Raw -Encoding UTF8 } else { '' }
  Check '★ 标记里带得出来源（写着从哪里点的）' ($content -match 'status window')

  # ── 第 3 段：「打断」原有行为没被带坏 ────────────────────────────────────
  $cancel2 = Join-Path $tmp 'cancel-2.flag'
  $force2  = Join-Path $tmp 'force-2.flag'
  Close-RestartWindow
  Start-Sleep -Milliseconds 500
  $okShow2 = Show-RestartWindow -Port 65532 -Reason '自测：打断按钮回归（不是真重启）' `
    -LogFile (Join-Path $tmp 'win-2.log') -CancelFile $cancel2 -ForceFile $force2
  Check '（前置）第二次开窗成功' $okShow2
  Start-Sleep -Milliseconds 900
  # 直接点窗口自己的「打断」——和鼠标点击走同一条事件链
  [void](Invoke-RestartWindowAbortClick)
  Start-Sleep -Milliseconds 900
  Check '★ 「打断」仍然写 cancel.flag（原有行为没被带坏）' (Test-Path $cancel2)
  Check '★ 「打断」**不**会写 force.flag' (-not (Test-Path $force2))
}
finally {
  Close-RestartWindow
  Remove-Item Env:DSH_RW_TEST_MODE -ErrorAction SilentlyContinue
}

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "`n===== 汇总：$($results.Count - $failed.Count)/$($results.Count) 通过 ====="
if ($failed.Count) {
  Write-Host '失败项：'
  foreach ($f in $failed) { Write-Host "  · $($f.Name) $($f.Detail)" }
}
Write-Host "`n日志留在：$tmp"
if ($failed.Count) { exit 1 }
exit 0
