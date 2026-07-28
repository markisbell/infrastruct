# Engine re-evaluation — interim notes (research paused 2026-07-20)

> **CLOSED 2026-07-28:** decision made — **Godot 4** (see engine-recommendation.md,
> accepted). The paused deep-research workflow does not need to be resumed; the open
> questions below that still matter were folded into ROADMAP.md v2 Phase 0 spikes.

Context: user considers forking OpenTTD too risky (see ROADMAP.md §2.1 / ADR-001 gate).
A deep-research workflow comparing open-source engine alternatives was paused mid-run
due to an internet outage.

**Resume:** in the same Claude Code session, resume with
`Workflow({scriptPath: "C:\Users\bell\.claude\projects\C--Users-bell-Documents-Forschungsprojekte-Drittmittel-simgames\4a3de138-8f4a-4e40-a35f-b274b8570151\workflows\scripts\deep-research-wf_e3f64ed4-4c2.js", resumeFromRunId: "wf_e3f64ed4-4c2"})`
(completed research agents return cached results). In a new session, just re-run the
engine research; the hard data below still stands.

## Ground truth from GitHub API (fetched 2026-07-20, primary source)

| Repo | Lang | License | Last push | Commits/52wk | Latest release | Verdict |
|---|---|---|---|---|---|---|
| OpenTTD/OpenTTD | C++ | GPL-2.0 | 2026-07-20 | — | — | baseline; fork risk is the concern |
| godotengine/godot | C++ (games: GDScript/C#) | MIT | 2026-07-18 | — | — | very healthy general engine |
| bevyengine/bevy | Rust | MIT/Apache-2.0 | 2026-07-20 | — | — | very healthy general engine |
| lincity-ng/lincity-ng | C++/SDL2 | GPL-2.0 | 2026-05-28 | 131 | 2.15.0 (2026-05-09) | **alive**, maintained OSS city builder |
| SimHacker/MicropolisCore | TS + C++/WASM | (GPL-3 w/ naming terms — verify) | 2026-07-18 | 98 | none | active; browser/WASM-oriented rewrite of SimCity classic |
| fifengine/fifengine | C++ w/ Python scripting | LGPL-2.1 | 2026-07-13 | 615 | 0.4.3 (2026-03-28) | revived isometric engine, native Python; tiny ecosystem |
| unknown-horizons/unknown-horizons | Python | ? | 2026-04-14 | 12 | 2019-dev (2019) | dormant (maintenance only) |
| CytopiaTeam/Cytopia | C++ | GPL-3.0 | 2025-12-26 | 0 | v0.2.1 (2020) | dead |
| citybound/citybound | Rust | AGPL-3.0 | 2023-01-07 | — | — | dead |
| Uriopass/Egregoria | Rust | GPL-3.0 | 2025-06-02 | — | — | stalled |
| widelands/widelands | C++ | GPL-2.0 | 2026-07-19 | 245 | 2026-07-16 | healthy, but Settlers-like genre |
| OpenRA/OpenRA | C# | GPL-3.0 | 2026-07-19 | 342 | playtest 2026-02 | healthy, but RTS genre |
| OpenLoco/OpenLoco | C++ | MIT | 2026-07-20 | — | — | active, but needs proprietary assets + same transport-fork problem |
| 0ad (0ad/0ad mirror) | C++ | mixed | archived mirror | — | — | moved to own Gitea; RTS genre |
| luanti-org/luanti | C++ | LGPL-2.1 | 2026-07-17 | — | — | healthy, but 3D voxel first-person genre |
| aburch/simutrans | C++ | Artistic | 2026-07-19 | — | — | active; same transport-genre fork surgery as OpenTTD |

GitHub search for Godot/Bevy city-builder starters: **nothing mature exists** — all
results are <40-star abandoned prototypes. A general engine = zero fork risk but all
city mechanics built from scratch.

## Trade-off crystallizing (pending workflow verification)

- Bases **with** city mechanics (OpenTTD, LinCity-NG, MicropolisCore) → fork/surgery risk.
- Bases **without** (Godot, Bevy) → build-it-yourself cost, but no upstream fights,
  huge docs/community, and built-in HTTP/WebSocket clients (Godot: HTTPRequest,
  WebSocketPeer) that replace the planned C++ cosim bridge (ROADMAP §2.3) almost for free.
- Python angle: backends are Python (FastAPI). FIFE embeds Python natively; a Python-first
  stack could even import the solvers in-process — but FIFE's bus factor is a real risk.

## Update 2026-07-20 (second pause, user request — resource limits)

- Research narrowed on user request: adversarial verification now restricted to the two
  front-runners **Godot** and **LinCity-NG** (focus filter edited into the workflow script,
  see resume command above — script at
  `...\workflows\scripts\deep-research-wf_e3f64ed4-4c2.js`, run id `wf_e3f64ed4-4c2`,
  ~99 agent results cached in journal.jsonl; pass the original question as `args` again
  when resuming, otherwise the script exits with "No research question provided").
- New primary-source findings since first pause:
  - **LinCity-NG is ~10× smaller than OpenTTD** (~1.4 MB C++ vs ~14.6 MB C++/C) — fork
    surgery far more tractable, and it is already a city builder.
  - **MicropolisCore license**: code is GPL-3; EA trademark clause on "SimCity" +
    separate "Micropolis" name license → code freely usable under your own game name.
  - **FIFE bus factor = 1**: 93 of last 100 commits by a single developer (Jens A. Koch).
    Demoted despite high activity numbers.
- Standing shortlist: **Godot** (zero fork risk, built-in HTTPRequest/WebSocketPeer for the
  Python sidecars, build city layer from scratch) vs **LinCity-NG** (small, actively maintained GPL-2 C++
  city builder, fork + add networks/IPC). Ruled out: Cytopia, Citybound, Egregoria (dead/
  stalled), Unknown Horizons (dormant), FIFE (bus factor), OpenLoco/Simutrans (same
  transport-fork problem as OpenTTD), OpenRA/Widelands/0AD/Luanti (genre mismatch).

## Open questions for the resumed research

1. Godot: best-practice isometric TileMapLayer workflow for drag-built networks; savegame
   story for large tile worlds; GDScript vs C# for this project.
2. LinCity-NG: codebase size/architecture — how hard to add new network layers + IPC?
   Compare to OpenTTD map-bit surgery. Maintainer receptiveness to such a fork?
3. MicropolisCore license terms (EA/Micropolis naming clause) and desktop (non-browser)
   viability; is the C++ core usable standalone?
4. Verify FIFE revival depth (who is committing, roadmap) and Windows build health.
5. Any engines/frameworks missed (Heaps, MonoGame, libGDX, LÖVE, Phaser/web).
