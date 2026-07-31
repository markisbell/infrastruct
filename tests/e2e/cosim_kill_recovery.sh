#!/usr/bin/env bash
# Phase 2 acceptance: kill the heat backend mid-cosim-run -> supply-disturbance
# event + automatic reset-recovery, power network unaffected, no corruption.
# Drives game --smoke=cosim-kill (which asserts and exits 0/1 itself).
# Linux port of cosim_kill_recovery.ps1.
set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
godot="$root/.tools/godot/Godot_v4.7.1-stable_linux.x86_64"
log="${TMPDIR:-/tmp}/simgames_cosim_kill.log"

port_owner() {  # pid listening on tcp port $1
    ss -ltnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2
}

rm -f "$log"
"$godot" --headless --path "$root/game" -- --smoke=cosim-kill > "$log" 2>&1 &
game=$!

deadline=$((SECONDS + 300))
until grep -q "SMOKE_READY" "$log" 2>/dev/null; do
    if (( SECONDS > deadline )); then echo "FAIL: SMOKE_READY timeout"; kill -9 "$game"; exit 1; fi
    if ! kill -0 "$game" 2>/dev/null; then echo "FAIL: game exited early"; tail -8 "$log"; exit 1; fi
    sleep 0.5
done

# let the run get ~15 in-game steps in, then kill the heat backend (port 8015
# owner — the cosim smokes run on the stress ports, never the live game's)
sleep 15
owner=$(port_owner 8015)
if [[ -z "$owner" ]]; then echo "FAIL: no heat backend on 8015"; kill -9 "$game"; exit 1; fi
echo "killing heat backend pid $owner"
kill -9 "$owner"

deadline=$((SECONDS + 480))
while kill -0 "$game" 2>/dev/null; do
    if (( SECONDS > deadline )); then echo "FAIL: game did not finish"; kill -9 "$game"; exit 1; fi
    sleep 1
done
wait "$game"; code=$?
grep "SMOKE_" "$log"
exit "$code"
