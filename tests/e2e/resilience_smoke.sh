#!/usr/bin/env bash
# Phase 1 acceptance: kill a sidecar externally -> game shows DOWN, auto-restarts,
# recovers to healthy - no crash, no hang. Drives game --smoke=resilience.
# Linux port of resilience_smoke.ps1.
set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
godot="$root/.tools/godot/Godot_v4.7.1-stable_linux.x86_64"
log="${TMPDIR:-/tmp}/simgames_resilience.log"

port_owner() {  # pid listening on tcp port $1
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

rm -f "$log"
"$godot" --headless --path "$root/game" -- --smoke=resilience > "$log" 2>&1 &
game=$!

# wait for both sidecars healthy (game prints SMOKE_READY)
deadline=$((SECONDS + 240))
until grep -q "SMOKE_READY" "$log" 2>/dev/null; do
    if (( SECONDS > deadline )); then echo "FAIL: SMOKE_READY timeout"; kill -9 "$game"; exit 1; fi
    if ! kill -0 "$game" 2>/dev/null; then echo "FAIL: game exited early"; tail -5 "$log"; exit 1; fi
    sleep 0.5
done

# kill the power backend (the actual uvicorn python, via its listening port).
# The smoke runs on the STRESS ports and prints them in SMOKE_READY — parse
# the first one instead of assuming the live game's 8010.
port=$(grep -m1 "SMOKE_READY" "$log" | grep -oE '[0-9]+' | head -1)
owner=$(port_owner "$port")
if [[ -z "$owner" ]]; then echo "FAIL: no backend on $port"; kill -9 "$game"; exit 1; fi
echo "killing power backend pid $owner (port $port)"
kill -9 "$owner"

# the game must observe DOWN, restart it, and report recovery
deadline=$((SECONDS + 400))
while kill -0 "$game" 2>/dev/null; do
    if (( SECONDS > deadline )); then echo "FAIL: game did not finish"; kill -9 "$game"; exit 1; fi
    sleep 1
done
wait "$game"; code=$?
grep "SMOKE_" "$log"
exit "$code"
