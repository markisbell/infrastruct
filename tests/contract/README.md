# Contract test suite (co-simulation contract v1)

Backend-agnostic golden-file tests for the game↔backend contract
([docs/contract/v1.md](../../docs/contract/v1.md), ROADMAP §6.2). The same
suite runs against **any** backend that implements the `/gb/*` surface —
rtpowerflow, rtheatflow, later rtwaterflow — and against the in-memory
[`mock_backend.py`](mock_backend.py), which doubles as the game's unit-test
backend.

## Running

```powershell
cd tests/contract
../../.venv/Scripts/python.exe -m pytest test_contract.py -q          # all registered backends
../../.venv/Scripts/python.exe -m pytest test_contract.py -q -k mock  # mock only
```

Backends whose fixture file, working directory, or interpreter do not exist
are **skipped** with the reason shown in the pytest summary. The suite spawns
each backend itself (ports 8020–8029 — never 8000/8001/8010/8011), polls
`/health` for up to 120 s (numba JIT imports), runs the assertions, then kills
the process tree.

Python deps (in `../../.venv`): `pytest`, `jsonschema`, `websocket-client`,
and for the mock `fastapi`/`uvicorn`/`websockets`.

## What is asserted, in order (per backend)

| stage | assertion |
|---|---|
| a | `GET /gb/version`: contract major = 1, `external_clock: true` |
| b | `POST /gb/net/reset` with the fixture topology → `ok: true`, `n_zones`/`n_devices` match, `warmup_solve_ms` numeric |
| c | fixture script stepped over **WebSocket `/gb/ws`**: per step `t` echoes, `status` ∈ `allowed_statuses`, result validates against [step-result.schema.json](../../docs/contract/schemas/step-result.schema.json) |
| d | idempotency: last step re-sent over **HTTP `POST /gb/step`** → byte-equal result (minus `solve_ms`); out-of-order `t+5` → HTTP **409** and WS error frame with `status: "error"`, `error: "out_of_order"` |
| e | `GET /gb/result/latest` equals the last result (minus `solve_ms`) |
| f | golden ranges evaluated on the final step's result |
| g | `/gb/net/patch`: `add_device`/`remove_device` round-trip of `patch_probe`; removing an unknown id is listed in `errors` (HTTP 200, tolerant per v1.md §3.2) |

## Registry: `backends.json`

```json
{"backends": [
  {"id": "power",
   "python": "../../.venv/Scripts/python.exe",
   "module": "netzsim.main",
   "cwd": "../../backends/rtpowerflow",
   "port": 8020,
   "env": {"NETZSIM_EXTERNAL_CLOCK": "true", "NETZSIM_PORT": "8020", "NETZSIM_HOST": "127.0.0.1"},
   "fixture": "fixtures/power_fixture.json"}
]}
```

All paths are relative to `tests/contract/`. The backend is launched as
`<python> -m <module>` with `cwd` set and `env` merged over the parent
environment. Pick an unused port in **8020–8029**.

## Fixture format (`fixtures/*.json`)

```jsonc
{
  // Topology document per docs/contract/schemas/topology.schema.json —
  // sent verbatim as the POST /gb/net/reset body.
  "topology": { "contract": "1.0", "network_kind": "power", "...": "..." },

  // Boundary-condition script: the suite builds one step request per
  // t in 0..steps-1 and sends it over WS /gb/ws.
  "script": {
    "steps": 8,          // number of steps to run
    "dt_s": 900,         // dt_s of every step request

    // Every series below is EITHER a JSON array of exactly `steps` values
    // (indexed by t) OR {"const": v} (same value every step).

    // zone_demand_kw: zone id -> series; becomes zone_demand.<id>.value.
    // Unit follows the network kind (power kW_el, heat kW_th, water m3/h).
    "zone_demand_kw": {"z0": {"const": 120.0}, "z1": [40, 45, 50, 55, 60, 65, 70, 75]},

    // device_setpoints: device id -> {setpoint key -> series}; keys are
    // kind-specific per v1.md §3.1 (generator/pv/wind: p_kw; chp/heat_pump/
    // boiler: q_kw).
    "device_setpoints": {"gen1": {"p_kw": {"const": 100.0}}},

    // weather: any of wind_ms / ghi_wm2 / temp_c -> series. Omit keys the
    // fixture does not care about.
    "weather": {"temp_c": {"const": 10.0}}
  },

  // Statuses every scripted step result must have (usually just converged;
  // add "degraded" for fixtures that exercise a retry ladder).
  "allowed_statuses": ["converged"],

  // Golden ranges: dotted path into the FINAL step's result -> [min, max],
  // inclusive on both ends.
  "golden": {"zones.z0.detail.v_pu": [0.9, 1.05]},

  // A device spec that is safe to add and then remove via /gb/net/patch
  // (id must not collide with a topology device).
  "patch_probe": {"id": "probe_gen", "kind": "generator", "node": "b2",
                  "params": {"p_max_kw": 50}}
}
```

Fixtures in this directory:

- `mock_fixture.json` — trivial 2-zone power document for the mock backend
  (authored with the suite).
- `heat_fixture.json` — rtheatflow: a minimal 3-consumer star net (zones
  hz0–hz2, slack-bound CHP device, morning-peak demand script, −5→8 °C
  weather ramp). Generated — never hand-edit — by
  `fixtures/gen_heat_fixture.py` (deterministic, stdlib-only).
- `power_fixture.json` — rtpowerflow: 5-bus 0.4-kV NAYY-chain feeder, 10
  zones (3/2/2/3 over b1–b4), slack/generator/pv/wind/coupling_load devices,
  one scripted 96-step day (double-peak zone demands 10–40 kW, midday PV
  bell, varied wind, weather series). Generated — never hand-edit — by
  `fixtures/gen_power_fixture.py` (deterministic, stdlib-only); the golden
  window (final-step zone voltages + slack band) is calibrated against a
  live rtpowerflow run.

## Mock backend

`mock_backend.py` is the in-memory reference implementation of contract v1:
full `/gb/*` surface, no physics. Results are fabricated but semantically
correct — idempotent last-`t` cache, out-of-order 409/error frame, zone
sample-and-hold, setpoint echo with `clamped` violations, slack balancing,
and coupling sign conventions (CHP `p_el_kw` ≤ 0 feeds the grid, heat pump
`p_el_kw` > 0 draws). Run it standalone with

```powershell
../../.venv/Scripts/python.exe -m mock_backend   # MOCK_HOST/MOCK_PORT env
```
