# Refactor & test-expansion plan (2026-08-04)

> Produced from an 11-agent code survey (7 subsystem readers, 3 coverage
> analysts, 1 regression-history miner). Baseline: 13.2k LOC game code,
> 112 GdUnit cases in 17 suites, ~21 smokes, Python contract suite.
> The big four files hold two thirds of the code: city_view.gd 2834,
> main.gd 2402 (mostly inline smokes), city.gd 1564, hud.gd 1131.

## Principles

- **Every step lands green** (GdUnit + targeted smokes; full battery at
  phase ends). No big-bang: each extraction is one PR-sized commit that
  ships WITH its new test suite — the extraction pays for itself
  immediately or it waits.
- Extract **pure logic into static/RefCounted model-layer classes**
  (headless-testable); autoload names and public APIs stay stable
  (City, GameClock, Orchestrator, CosimBridge, SidecarManager, SaveGame;
  CityView's tool/redraw/mouse_tile/focus_tile/sun_dir_world/
  tiles_screen_rect + signals; Hud privates that main.gd pokes:
  _save_slot/_load_slot/_open_tile_inspector).
- Every new `class_name` file needs the **editor import pass** before the
  headless GdUnit run (CLAUDE.md §5) — bake it into the loop.
- v5 save schema stays readable throughout; envelope fields don't move.

## Genuine bugs found by the survey (fix first, they're small)

1. **Contract schema contradicts shipped behavior**:
   `docs/contract/schemas/step-request.schema.json` pins
   `zone_demand.value` `minimum: 0`, but contract §4's power note (and
   the game since the 2026-08-01 LPG/PV rework) sends SIGNED net load.
   Unnoticed because the suite never validates step-requests against
   their schema (only step-result is validated — itself a gap). Fix the
   schema, then pin both: request/topology schema validation + a signed
   negative-demand golden step.
2. **Handshake minor rule unimplemented**: v1.md §2 says game-minor ≤
   backend-minor; `cosim_bridge.gd` only prefix-matches the version.
3. **Weak smoke gates** (assert-nothing hazards): `stress` passes on
   frame timing alone (`registered`/`houses` reported but not in the ok
   conjunction); `sidecars` accepts any handshake (never checks solver
   identity); `playtest` liveness counts only POWER statuses;
   `windless-week` collects `import_calm`/`import_windy` but never
   asserts their relation; `events` pipe-burst check can't distinguish
   "network down" from "registration never happened".

## Phase 1 — seams + gate hardening — DONE 2026-08-04

Landed: schema fixes (signed zone_demand; topology schema was ALSO stale —
pinned contract "1.0" and lacked all water device kinds, caught by the new
suite validation on first run), handshake minor rule (all three backends
echo 1.1; game now requires it; +test_cosim_guards.gd), mock passes signed
power through, DemandModel reset_caches/set_pack_override (+seam test),
City trafo_streak/topo_warned to members (warning dedup now resets
per-city), 4 dead-code sites deleted, WorldModel line-layer triplication
collapsed, all 5 weak gates hardened. Calibration notes: the solved fire
sag is 0.09 bar (pinned 0.07 — the 48 m³/h is served from the TOWER, pump
holds rated duty, so flow-based assertions don't work there); stress
layout deterministically yields 47 houses (pinned >= 40). Verified: GdUnit
117/117, contract suite 4/4, smokes sidecars/events/windless-week/stress/
playtest/overload green.

- Fix the three bug groups above.
- DemandModel: `reset_for_test()` clearing the static pack/profile
  caches + explicit weather injection seam (statics are today's
  cross-suite leak).
- City: move `get_meta("trafo_streak")`/`("topo_warned")` state into
  member dicts covered by `reset_for_scenario` (meta state is invisible
  to serialize/reset today).
- Delete the 4 grep-verified dead-code sites in the model layer.
- Collapse WorldModel's can_set/set/remove line-layer triplication.

## Phase 2 — city.gd: the game brain becomes unit-testable — DONE 2026-08-04

Landed as planned (table below was the plan): telemetry_rings.gd,
satisfaction.gd, economy_books.gd (ALL tariff/rate constants moved;
City.STEP_H stays an alias), protection.gd, dispatch.gd (incl. the peak
EMA), capacity_signals.gd (threshold classifier table; marker assembly
stayed in City — it reads too much live state to be worth parameterizing),
growth.gd (interval tiers, margin gate, abandon victim), plus the NetSync
inner class collapsing _register_async. City keeps back-compat properties
(satisfaction/econ_*/loans/registered/_last_*_doc_json) for hud, smokes
and the save envelope — envelope keys unchanged. city.gd 1564 -> 1491
lines with ~480 lines of rules now in 7 pure model files. Verified:
GdUnit 163/163 (was 112 at Phase-1 start), contract suite 4/4, FULL
battery green (19 standalone smokes + resilience + cosim-kill), economy
CSV numerically pure vs pre-refactor (modulo the documented summer
heat-cell solver noise). GdUnit gotcha learned: never read state in a
chained assert argument that the asserted call itself mutates — evaluation
order bit once (test_dispatch).

Extract to `game/model/`, dependency order, each WITH its suite:

| Extraction | LOC | New suite pins |
|---|---|---|
| `telemetry_rings.gd` | 40 | NAN gaps; backwards-restore blanks yesterday instead of showing the future day |
| `satisfaction.gd` | 70 | per-network hurt/recovery constants (power −9·hurt, water −12, +0.06 recovery); happiness blend 0.45/0.25/0.3 with empty-network exclusion |
| `economy_books.gd` | 150 | delivered-only income; positive-import-only billing; blackout day books €0 elec; CHP/boiler fuel from SOLVED outputs; Grundgebühr; loan interest/repay clamp |
| `protection.gd` | 80 | strict >120 % for 3 (line) / 4 (trafo) / 2 (grid) consecutive steps; AWAITING_CREW no-self-heal; tripped substation → zone demand 0 |
| `dispatch.gd` | 130 | battery EMA seed + discharge clamp; heat-storage charge 00–05 h / discharge min(p_max, 0.6·demand) 06–10 h; well yield=drought_factor; pump enabled only when energized |
| `capacity_signals.gd` | 90 | thresholds ≥80 % lines / ≥70 % trafos / ≥80 % grid / heat < min+4 °C / water < 2.4 bar |
| `growth.gd` | 45 | interval tiers by happiness (≥90/75/60), margin gating, abandonment picks worst-outage zone |

Plus: collapse the `_register_async` per-network triplication into one
NetSync struct (stays in the autoload). City keeps async
register/reset, signal plumbing, cross-autoload glue (~900 LOC left).

## Phase 3 — main.gd: smokes become a framework — DONE 2026-08-04

Landed: game/smokes/<name>.gd per smoke over class_name SmokeBase
(waits, _run_steps, _fail, reference towns, result readers, _econ_delta);
main.gd 2402 -> ~535 lines (mode dispatch + boot + bench + visual
probes); registry dispatch with CLI byte-identical (cosim-kill = the
cosim file with kill_mode set via the registry; --seed forwarded with
set(), a silent no-op on smokes without the property). SmokeBase gained
the opt-in check()/failed_checks()/verdict() per-assertion reporting
(existing smokes keep their verbatim verdicts — migrate opportunistically
when a smoke is next touched) and _repo_file() with INFRA_OUT_DIR
override for the two dev-only CSV writes. Verified: GdUnit 163/163, full
battery 21/21. One extraction miss (economy's _econ_net) was caught by
the battery and fixed — when moving function groups, grep the moved
bodies for helper CALLS not in the move spec.

- `game/smokes/smoke_base.gd`: `_run_steps`, fresh-scenario pattern,
  forced-weather helpers, deadline polling — plus **named per-assertion
  reporting** (today's verdicts are single ANDed booleans of up to 13
  terms; failures aren't attributable without re-reading the smoke).
- Move the ~19 `_smoke_*` bodies to `game/smokes/*.gd`; registry
  dispatch in main.gd. CLI contract unchanged (`--smoke=<name>`, one
  JSON line, exit 0/1) so tests/e2e wrappers and CI don't move.
- Replace the two repo-layout writes (`globalize_path("res://") + ../`
  in yearcurves + economy) with explicit paths — they break in exports.
- main.gd lands ~600 LOC (mode dispatch + visual probes).

## Phase 4 — orchestration test rig — DONE 2026-08-04

Landed: bridge_override/health_override seams + reset_for_test on
Orchestrator (duck-typed via _bridge()/_healthy(); production leaves
them null); game/tests/fakes/fake_cosim_bridge.gd (scripted,
request-recording, hold_frames suspends a step across sim steps) +
fake_sidecar_health.gd; test_orchestrator.gd pins one-step lag, wire-t
resync (boundary at GAME t, wire at last_t+1), missed-step counting,
coupling summing (incl. never routing a net's own output back),
down-skip latching, recovery (re-handshake + reset + resume wire),
error-frame non-storage, failed escalation at 3. SidecarManager's spawn
became static build_launch_command(os_name, ...) +
translate_python_path — both OS branches unit-tested on Linux
(test_sidecar_launch.gd pins the exec-pid trick, the cmd.exe tree
shape, and the never-resolve-venv-symlink lesson). Caveat documented in
the seam: in-process fakes bypass wire float coercion — the Python
contract suite stays the wire authority. Verified: GdUnit 176/176 +
sidecars/cosim smokes + resilience wrapper green against real backends.

- 12-LOC bridge-injection seam in Orchestrator + a scripted,
  request-recording `FakeCosimBridge` → new `test_orchestrator.gd`:
  one-step lag; missed-step skip COUNTING (needs a coroutine fake that
  holds a step unresolved across a sim step); coupling routing
  (coupling_out A@t−1 → `cpl_A` loads of B@t); wire-t resync as
  last_t+1; recovery re-registration path.
- SidecarManager: extract the pure launch-command builder; unit-test
  BOTH OS branches' command shapes + the venv path translation (pins
  the `Path.resolve()` symlink-escape lesson).
- Caveat to document in the suite: an in-process fake bypasses JSON
  wire float coercion — the Python contract suite stays the wire
  authority; the GDScript fake tests orchestration logic only.

## Phase 5 — city_view.gd rendering split — DONE 2026-08-05
## (daylight-curve extraction deferred: cosmetic-only, no decision logic)

Landed in four commits (5a-5e), city_view.gd 2857 -> 1640 lines, all
verified against pre-refactor screenshots (identical-run noise floor
~0.05/255; the recurring confound is the substation-tool ghost coverage
overlay anchored to the PHYSICAL MOUSE CURSOR — it moves between
capture runs; wind arrows/clouds/rotors/bubbles drift with wall-clock):
- 5a BuildingModels (~750 loc statics; shared material cache; colors +
  PIPE_HEIGHT authoritative there; one real drift caught: 0.38 retyped
  as 0.4).
- 5b DecoScatter + first-ever tests for the scatter (was headless-
  unreachable); cluster noise is INDEPENDENT of terrain heights.
- 5c TerrainMeshBuilder returning Packed arrays; plateau-cap semantics
  pinned (lower tile capped at its own plateau; 1-level steps stitch
  sub-step SEAMS — expected, distinguish skirts by SPAN not count).
- 5d LineSpecs: predicates + road table + cable/buried specs + cache
  keys; 7 regression pins (staircase, parallel, Kabelendmast key, all
  16 road masks, single-tap, road plates).
- 5e pipe_spec + one merged _orient_surface_pipe (heat double / water
  single); _make_water_pipe nearly lost in the splice — caught by grep
  of _diff callers. GdUnit 196/196.

1. `rendering/building_models.gd` — the 15 `_make_*` builders +
   `_pole_visual`/`_termination_hardware`/`_wire_segment` (~750 LOC,
   reads no state, purely mechanical; keep 1-line delegates for hud's
   thumbnail/gallery calls). Add `_cyl` helper, dedupe banded stacks.
2. `rendering/terrain_mesh.gd` (static) — corner smoothing, stitch
   quads, face normals returning Packed arrays. Tests: corner capped at
   plateau; 1-level step emits slope not skirt; ≥2-level cliff emits
   stitch; `vertex_color_is_srgb` stays true (pins the Forward+
   bleach lesson).
3. `rendering/deco_scatter.gd` (static) — scatter classification is
   deterministic pure logic but sits behind a headless early-return:
   **unreachable by any test today**. Tests: per-(tile,seed)
   determinism, occupancy filter, `deco_cleared`, riparian strip.
4. `rendering/line_specs.gd` (static) — the regression hot spot.
   Move linkage/orientation DECISIONS (not mesh building): tests pin
   the staircase/parallel-run rule, Kabelendmast neighbor-KIND cache
   key, the road-piece mask table (flipped twice historically), and
   the two-ring dirty-refresh contract.
5. Merge `_orient_pipe`/`_orient_water_pipe` (parameterized); extract
   the daylight curve (sun azimuth sweep + SUN_QUANT_DEG quantization
   → angle-math unit test).

city_view.gd lands ~1300 LOC (scene graph, materials, input, camera).

## Phase 6 — hud componentization — DONE 2026-08-05 (logic extractions;
## panel-shell moves deferred — pure UI assembly, no decision logic)

Landed: game/scenes/hud/inspector_config.gd (per-kind config tables +
the sampled-house series builder as pure statics over WorldModel/
WeatherSystem params), CompassRose to its own file,
Hud.popup_position() static (callout clamping geometry),
ProfileGraph.y_range() static (padding rules). test_hud_components.gd
(6 cases): placement clamping (note: bottom clamping cannot trigger for
on-screen anchors — the panel opens upward), config tables (grid cap
limit, trafo/soc key conventions), house-series determinism + secondary
axis, y-range rules, money format, and a palette-table validation sweep
(fields, known kinds, unique tools/hotkeys). Deferred: BuildPalette/
SaveSlotUI/ScenarioUI/InspectorPanel shell components + thumbnail
factory move. Visual gates: inspector panel + palette regions
pixel-identical (NEW CONFOUND documented: the async palette-thumbnail
render races the screenshot capture — the row flips between monograms
and icons run-to-run; compare same-stage captures). GdUnit 202/202.

- `InspectorConfig` static (config tables + house-series builder) +
  table test; `InspectorPanel` component — with a regression test for
  the 2026-08-04 dismissal semantics (toggle/click-away/Esc/✕).
- `BuildPalette` component + palette-table validation test (every tool
  has kind/cost/desc; kinds exist in BuildingDefs).
- SaveSlotUI, ScenarioUI, BreakdownPanel (+ pure budget aggregation),
  CompassRose to its own file, money/status format statics + tests.
- ProfileGraph: extract y-range/pad math, take telemetry by parameter
  instead of reading City — unit-test the range algorithm.

## Phase 7 — topology consolidation (LAST: highest risk, ~1 wk)

- **Safety net first**: golden-file topo docs for 3–4 fixture cities
  captured BEFORE any change; diff after every commit.
- `NetGraph` shared library: run walk, BFS, service edges, bus tiles,
  `assign_houses` (nearest-station tie-break test) — the three builders
  keep only their per-network semantics.
- Split backend-payload assembly from graph extraction (water reads
  terrain inside junction emission today).
- Direct tests for the water booster two-phase BFS: suction-faces-head,
  bypassed-loop warning, head preference well > pump, by-id ordering.
- DemandModel property tests on the pure core: energy conservation,
  world-seed independence of house sampling, rot normalization
  (negative rot!), pv fleet distribution never N-facing roofs.

## Contract-suite expansion (Python; parallel track, anytime)

Pin: signed power demand (post schema fix) · `status: failed` as data
(HTTP 200, supplied→0) via a forcing fixture · forced heat `degraded`
tier · coupling_in forwarding · sample-and-hold on missing zone ·
reset clears last_t + resume at ANY t · out-of-order error payload
`{expected: [last_t, last_t+1]}` · negative surface (step-before-reset
400, malformed topology 400) · SoC replay param at reset · edges
presence for power (City protection starves silently without them) ·
`clamped` violation semantics · water `station` device target ·
**validate topology + step-request against their own schemas**.

New integration: run the game headless against
`tests/contract/mock_backend.py` (ports 8020s) — registration + a few
steps + telemetry ingestion, no real solvers. Today the game has ZERO
tests against the mock; also unit-test the game's CONSUMER side of
step-results (telemetry key vocabulary dev:/soc:/q:/t:/pb:).

## New smokes (integration gaps the survey found)

1. **Booster blackout**: inline pumping station bridging a run, grid
   trip → station_modes off → downstream zone dry → recovery.
2. **Save/load mid-event**: envelope v4 claims event-RNG position and
   trips survive loads — nothing pins a load DURING an active storm/
   burst with a tripped line.
3. **Region terrain headless**: `load_region(kraichgau)` + build a
   small town + one solve on real-DEM levels (today region terrain is
   screenshot-only).
4. **Power-backend kill**: cosim-kill only ever kills HEAT; power
   carries the coupling — add the variant (e2e wrapper param).
5. **Buried-cable overload** (8.7 MVA rating path) and/or PV-facing
   end-to-end (E vs S park yield shift visible in dispatch).

## Regression pinning (history mining → `test_regressions.gd`)

Backwards-`GameClock.restore` current_t resync · road-piece rotation
table · corner_y plateau cap · Kabelendmast cache key on neighbor kind
flip · two-ring dirty refresh · event-feed label lifetime (>6 queued)
· typed-array `.assign()` paths · per-port log paths · sun quantization
angle math. Visual-only lessons (vertex srgb, shadow crawl) get
property-value pins + a note that eyeballs remain the real check.

## Order & verification gates

1 → 2 → 3 → 4 (rig) → 5/6 in either order → 7 last (best safety net by
then). Contract track runs in parallel anytime. Gate per commit:
import pass → GdUnit → targeted smokes; per phase: full smoke battery;
Phase 7 additionally: golden topo diffs. Push milestones per CLAUDE.md.

## Expected landing

- LOC: city_view 2834→~1300 · main 2402→~600 · city 1564→~900 ·
  hud 1131→~500; new `game/model/*` + `game/scenes/rendering/*` +
  `game/smokes/*` files, each small and owned by one concern.
- Tests: 112 → ~260–290 GdUnit cases (28 unit gaps + 17 smoke-derived
  unit pins + ~10 regression pins + per-extraction suites), contract
  suite +13–16 cases, +4–5 smokes with per-assertion reporting.
