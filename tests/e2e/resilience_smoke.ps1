# Phase 1 acceptance: kill a sidecar externally -> game shows DOWN, auto-restarts,
# recovers to healthy - no crash, no hang. Drives game --smoke=resilience.
$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$godot = Join-Path $root ".tools\godot\Godot_v4.7.1-stable_win64_console.exe"
$game = Join-Path $root "game"
$log = Join-Path $env:TEMP "simgames_resilience.log"

Remove-Item $log -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $godot `
    -ArgumentList "--headless", "--path", "`"$game`"", "--", "--smoke=resilience" `
    -RedirectStandardOutput $log -PassThru -NoNewWindow

# wait for both sidecars healthy (game prints SMOKE_READY)
$deadline = (Get-Date).AddSeconds(240)
while (-not (Select-String -Path $log -Pattern "SMOKE_READY" -Quiet -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) { Write-Output "FAIL: SMOKE_READY timeout"; Stop-Process -Id $proc.Id -Force; exit 1 }
    if ($proc.HasExited) { Write-Output "FAIL: game exited early"; Get-Content $log -Tail 5; exit 1 }
    Start-Sleep -Milliseconds 500
}

# kill the power backend (the actual uvicorn python, via its listening port)
$owner = (Get-NetTCPConnection -LocalPort 8010 -State Listen).OwningProcess | Select-Object -First 1
Write-Output "killing power backend pid $owner"
Stop-Process -Id $owner -Force

# the game must observe DOWN, restart it, and report recovery
if (-not $proc.WaitForExit(400000)) {
    Write-Output "FAIL: game did not finish"; Stop-Process -Id $proc.Id -Force; exit 1
}
Get-Content $log | Select-String "SMOKE_"
exit $proc.ExitCode
