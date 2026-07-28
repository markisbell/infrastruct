# Phase 2 acceptance: kill the heat backend mid-cosim-run -> supply-disturbance
# event + automatic reset-recovery, power network unaffected, no corruption.
# Drives game --smoke=cosim-kill (which asserts and exits 0/1 itself).
$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$godot = Join-Path $root ".tools\godot\Godot_v4.7.1-stable_win64_console.exe"
$game = Join-Path $root "game"
$log = Join-Path $env:TEMP "simgames_cosim_kill.log"

Remove-Item $log -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $godot `
    -ArgumentList "--headless", "--path", "`"$game`"", "--", "--smoke=cosim-kill" `
    -RedirectStandardOutput $log -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds(300)
while (-not (Select-String -Path $log -Pattern "SMOKE_READY" -Quiet -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) { Write-Output "FAIL: SMOKE_READY timeout"; Stop-Process -Id $proc.Id -Force; exit 1 }
    if ($proc.HasExited) { Write-Output "FAIL: game exited early"; Get-Content $log -Tail 8; exit 1 }
    Start-Sleep -Milliseconds 500
}

# let the run get ~15 in-game steps in, then kill the heat backend (port 8011 owner)
Start-Sleep -Seconds 15
$owner = (Get-NetTCPConnection -LocalPort 8011 -State Listen -ErrorAction SilentlyContinue).OwningProcess | Select-Object -First 1
if (-not $owner) { Write-Output "FAIL: no heat backend on 8011"; Stop-Process -Id $proc.Id -Force; exit 1 }
Write-Output "killing heat backend pid $owner"
Stop-Process -Id $owner -Force

if (-not $proc.WaitForExit(480000)) {
    Write-Output "FAIL: game did not finish"; Stop-Process -Id $proc.Id -Force; exit 1
}
Get-Content $log | Select-String "SMOKE_"
exit $proc.ExitCode
