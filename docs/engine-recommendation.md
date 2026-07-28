# Engine recommendation (replacing the OpenTTD fork)

**Date:** 2026-07-20 · **Status:** ACCEPTED 2026-07-28 — Godot 4 chosen; ROADMAP.md rewritten to v2 accordingly
**Basis:** primary-source GitHub data in [engine-evaluation-notes.md](engine-evaluation-notes.md)
plus partial web research (see *Evidence quality* at the end).

## TL;DR

**Recommendation: build on Godot 4.** Zero fork risk, MIT license, built-in HTTP and
WebSocket clients that talk to rtpowerflow/rtheatflow directly (the entire C++
`cosim_bridge` module planned in ROADMAP.md §2.3 collapses into a few hundred lines of
GDScript/C#), an enormous documented ecosystem, and Python-like scripting that matches
your existing stack. The price: no city-builder mechanics for free — but the honest
accounting below shows most of what OpenTTD "gave us for free" was going to be heavily
rewritten anyway, while OpenTTD's biggest cost (map-array surgery for cables/pipes, the
#1 risk in the ROADMAP risk register) simply does not exist in Godot.

Runner-up if you want existing city mechanics: fork **LinCity-NG** (~10× smaller than
OpenTTD, actively maintained, already a city builder). Third option, tailored to your
team's existing skills: a **TypeScript/web stack**, since both of your backends already
ship React + Leaflet + WebSocket frontends.

---

## Requirements recap

City-builder on a 2D tile map with terrain; drag-built networks (cables, heat pipes,
water pipes); buildable plants/storages; save/load; overlays/UI; seasonal time; and — the
hard constraint — first-class integration with two (later three) **Python FastAPI sidecar
services** over localhost REST/WebSocket, externally clocked by the game (ROADMAP §2.2–2.5).
OSI license, Windows 11, actively maintained, hackable at solo/small-team scale.

---

## Ranked recommendation

### 1. Godot 4 — recommended

| Aspect | Assessment |
|---|---|
| License / health | MIT · 114k stars · pushed within days (verified 2026-07-20) |
| Language | GDScript (Python-like) and/or C#; C++ via GDExtension never needed here |
| Sidecar integration | **Built in:** `HTTPRequest`, `HTTPClient`, `WebSocketPeer`; JSON native. Launch/supervise sidecars with `OS.create_process()` |
| Tile map | `TileMapLayer` with native isometric mode; custom data layers per tile (network occupancy without any "map-bit scarcity") |
| Save/load | Straightforward custom serialization (game state is ours anyway) |
| UI/overlays | Control-node UI, CanvasLayers + shaders for voltage/temperature/pressure heatmaps — far better tooling than OpenTTD's widget system |
| Windows | First-class; also trivially exports Linux/macOS builds |

**What we give up vs. OpenTTD** — and what it really costs:

| OpenTTD freebie (ROADMAP §2.1 table) | In Godot | Real cost |
|---|---|---|
| Isometric map + terrain | TileMapLayer isometric; height/slopes are custom | Moderate — flat-with-elevation-attribute is fine for v1; water needs elevation as a number, not rendered slopes |
| Town/house growth logic | From scratch | Low — ROADMAP Phase 6 was rewriting it anyway (growth = f(happiness, supply margin)) |
| Calendar/seasons | From scratch | Trivial |
| Save/load framework | From scratch | Low |
| GUI, overlays | Godot's are better | Negative cost |
| Drag-build UX (roads as template) | From scratch | Moderate — but *this replaces the highest-risk OpenTTD item* (map-array surgery), turning risk into plain bounded work |

**Trade-offs:** you own every game mechanic; no existing city-builder codebase to crib
from on Godot (verified: nothing above toy-prototype level exists); rendering/simulation
performance is on us to architect (fine at our scale — the physics runs in the sidecars).

**Effort vs. OpenTTD fork:** roughly comparable total lines written, drastically lower
variance. No upstream to fight, no GPL-fork of a 14 MB codebase to rebase, no risk that a
core assumption (map bits, lockstep determinism) blocks the design in month three. The
ROADMAP's determinism concern (§6.1) also softens: no OpenTTD lockstep multiplayer to
preserve.

### 2. LinCity-NG fork — if existing city mechanics matter more than comfort

| Aspect | Assessment |
|---|---|
| License / health | GPL-2 · release 2.15.0 (2026-05) · 131 commits/yr (verified) |
| Size | ~1.4 MB C++ vs OpenTTD's ~14.6 MB — a fork you can actually hold in your head |
| Genre fit | It **is** a city builder; the original LinCity design even includes simple utility mechanics (power plants, power lines, wells — toy models our sidecars would replace). *Feature list to be re-verified before committing* |
| Sidecar integration | Same C++ bridge work as the OpenTTD plan (Phases 1–2 of ROADMAP survive unchanged) |

**Trade-offs:** small community and moderate bus factor; aging C++/SDL2 codebase of
wildly varying vintage; you still write the C++ HTTP/WS bridge; adding *new* network
layers (heat/water pipes) means learning and extending its map model — smaller surgery
than OpenTTD, but surgery. GPL-2 obligations on the fork (unproblematic, as with OpenTTD).

**Choose this if:** you want a playable-ish base in weeks, accept C++, and value existing
mechanics over long-term architectural freedom.

### 3. TypeScript web stack (PixiJS/Phaser; optionally MicropolisCore-WASM) — the "your team already does this" option

Both rtpowerflow and rtheatflow already ship **React + TypeScript + Leaflet frontends
consuming FastAPI WebSockets** — this option makes the game the same shape as software
you already build and maintain. Browser (or Electron/Tauri shell) + PixiJS or Phaser for
isometric rendering; the sidecar integration is *native* (your backends already stream to
browsers). MicropolisCore (GPL-3, actively developed, WASM + TS bindings of the original
SimCity engine) could optionally supply zoning/growth mechanics.

**Trade-offs:** the most build-it-yourself of the three for engine features (no editor,
no scene system, save/load, input, UI all manual or from libraries); MicropolisCore is a
one-person project (Don Hopkins) in active flux; performance ceilings in-browser are real
though probably sufficient. **Choose this if** maximizing skill reuse and web
distribution (a browser demo doubles as project dissemination — relevant for a research
context) outweigh engine comfort.

### Why not the rest (one line each, all primary-source verified)

Cytopia, Citybound, Egregoria: dead/stalled. Unknown Horizons: dormant (12 commits/yr).
FIFE: revived but bus factor = 1 (93/100 recent commits by one person). OpenLoco,
Simutrans: same transport-genre fork problem as OpenTTD (OpenLoco also needs proprietary
assets). Widelands, OpenRA, 0 A.D., Luanti: healthy but wrong genre — the retrofit cost
exceeds Godot's from-scratch cost. Bevy: healthy but no editor, younger ecosystem, Rust
learning curve — dominated by Godot for this project. MonoGame/libGDX/Heaps/LÖVE:
frameworks below Godot's abstraction level with no compensating advantage here.

---

## Impact on ROADMAP.md (if Godot is chosen)

The roadmap was built for this pivot (§2.3: "keeps the engine decision reversible").
What survives **unchanged**: the co-simulation contract (§5), puppet-mode work in both
backend repos, aggregation/supply-zone design (§2.4), time coupling (§2.5),
non-convergence-as-gameplay, water strategy (§2.7), all gameplay phases 3–7 in content,
the testing strategy and performance budgets.

What changes:
- **Phase 0** becomes: Godot isometric tile-map + drag-build spike (replaces map-bit
  spike A — the highest-risk item disappears); HTTP/WS latency spike from GDScript
  (replaces C++ client spike B); spike C (puppet mode) unchanged.
- **Phase 1–2**: `cosim_bridge` C++ module → a Godot autoload (GDScript or C#); sidecar
  lifecycle via `OS.create_process` + health polling; CI runs Godot headless export
  instead of MSVC builds. Fork-hygiene tasks vanish.
- **§6.1 determinism**: OpenTTD-lockstep concern gone; keep seeded reproducibility.
- Licensing: game code can be any license (MIT engine); GPL considerations vanish.

## Evidence quality & residual uncertainty

- **Verified primary-source (GitHub API, 2026-07-20):** all activity numbers, licenses,
  codebase sizes, bus factors, and the death/dormancy calls above.
- **Established engine knowledge, not re-verified this session:** Godot's HTTPRequest/
  WebSocketPeer/TileMapLayer capabilities (stable, documented features).
- **Unverified (research was stopped early at your request):** LinCity-NG's exact
  in-game utility feature set; Godot isometric best practices at large map sizes.
  Both are cheap to confirm and belong in the Phase 0 spikes regardless of decision.
- The paused deep-research run (cached, resumable this session only) would add adversarial
  verification of Godot/LinCity-NG web claims — nice-to-have, not decision-blocking.

## Proposed next step

Adopt **Godot 4** (decision gate ADR-001), rewrite ROADMAP.md Phases 0–2 accordingly,
and start the Phase 0 spikes — the first of which (isometric drag-build prototype)
doubles as the final feasibility check on this recommendation.
