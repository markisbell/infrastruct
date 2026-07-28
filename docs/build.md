# Build & development setup

Verified on Windows 11 (2026-07-28). Linux equivalents in parentheses where they differ.

## Prerequisites

| Tool | Version | Where |
|---|---|---|
| Godot | **4.7.1-stable** (editor binary, no export templates needed for dev) | `.tools/godot/` (gitignored) — download `Godot_v4.7.1-stable_win64.exe.zip` from the [official GitHub release](https://github.com/godotengine/godot/releases/tag/4.7.1-stable) and extract |
| Python | **3.12** (backends; the scientific stack lags newer Pythons) | `py -3.12` via the Windows launcher |
| Git | ≥ 2.40, with `core.longpaths=true` recommended on Windows | — |

## First-time setup

```bash
git clone <repo> simgames && cd simgames
git submodule update --init            # backends/rtpowerflow, rtheatflow, rtwaterflow
# ONE VENV PER BACKEND — pandapipes 0.14.0 pins pandapower 3.3.3, which
# conflicts with rtpowerflow's pandapower; sidecars are separate processes
# with separate environments by design (orchestration/sidecars.json).
py -3.12 -m venv .venv       && .venv/Scripts/pip install -e "./backends/rtpowerflow[dev]" numba
py -3.12 -m venv .venv-heat  && .venv-heat/Scripts/pip install -e "./backends/rtheatflow[dev]" numba
# Godot: extract the 4.7.1 zip into .tools/godot/, then import the project once:
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --import --path game
```

> numba is optional for pandapower/pandapipes but gives a large per-step
> speedup; the very first solve then pays a one-time ~3 s JIT cost (fire a
> throwaway solve after net load — see ADR-003 notes).

## Sidecars

`orchestration/sidecars.json` defines the backends the game supervises
(SidecarManager autoload): venv python, module, cwd, port, env. Game sidecars
use **dedicated ports 8010 (power) / 8011 (heat)** — never the backends' own
dev defaults 8000/8001, so a running dev instance of rtpowerflow/rtheatflow
does not collide with the game (learned the hard way in Phase 1). Sidecar
stdout/stderr land in `orchestration/logs/<id>.log` (gitignored).

Phase 1 acceptance smokes (headless, print one JSON line, exit 0/1):

```bash
# spawn both backends in puppet mode, handshake /gb/version, step each solver once
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path game -- --smoke=sidecars

# save -> wipe -> load round-trip of model + clock
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path game -- --smoke=saveload
```

```bash
# kill-a-backend-externally -> auto-restart -> recovered (drives --smoke=resilience)
powershell -File tests/e2e/resilience_smoke.ps1
```

## Everyday commands

```bash
# Run the game (editor-less)
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --path game

# Game unit tests (GdUnit4, headless)
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path game \
  -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests --ignoreHeadlessMode

# Backend tests (rtpowerflow, incl. gamebridge/puppet-mode suite)
cd backends/rtpowerflow && ../../.venv/Scripts/python.exe -m pytest -q

# Spike A benchmark (opens a window ~10 s, writes a JSON report)
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --path game -- --bench --out=<abs-path>.json

# Spike B latency bench: start the stub backend, then the headless client
.venv/Scripts/python.exe -m uvicorn stub_backend:app --port 8123 --app-dir tests/e2e &
.tools/godot/Godot_v4.7.1-stable_win64_console.exe --headless --path game \
  -s "res://../tests/e2e/spike_b_client.gd" -- --out=<abs-path>.json

# Spike C solver timing on reference grids
.venv/Scripts/python.exe tests/e2e/spike_c_timing.py ieee_33bw kerber_vorstadtnetz
```

## Puppet mode (external clock)

Run rtpowerflow under the game's clock (branch `gamebridge`):

```bash
NETZSIM_EXTERNAL_CLOCK=true .venv/Scripts/python.exe -m netzsim.main
# then: POST /gb/step advances exactly one step; GET /gb/version is the handshake
```

## Packaging (validated early, Phase 1)

PyInstaller onedir freeze of rtpowerflow works out of the box with
`--collect-all pandapower --collect-all numba --collect-all llvmlite
--collect-all netzsim` + the uvicorn hidden imports (see the `freeze-smoke`
CI job for the exact invocation). Result: ~335 MB per backend (LLVM/numba +
scipy stack), boots and serves `/health` + `/gb/version` in puppet mode.
Full installer packaging remains Phase 8; the risk is retired.

## CI

`.github/workflows/ci.yml`: game unit tests (GdUnit4 headless, Windows + Linux)
+ backend pytest (Python 3.12). Requires submodules (`submodules: recursive`).
