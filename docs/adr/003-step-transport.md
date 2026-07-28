# ADR-003: WebSocket for the step channel, HTTP for the control plane

**Status:** accepted · **Phase:** 0 (decided by Spike B + Spike C data)

## Context

The orchestrator calls `/gb/step` once per sim-step (default: one per 15
in-game minutes; several per second at fast-forward). ROADMAP §6.3 budgets
p99 ≤ 50 ms for the full round-trip on 100–500-node networks.

## Measurements (2026-07-28, this machine, localhost)

Transport only — 1000 sequential calls, ~100-zone payloads, stub FastAPI
(`tests/e2e/stub_backend.py` + `spike_b_client.gd`):

| Transport | p50 | p99 | worst |
|---|---|---|---|
| HTTP keep-alive (`HTTPClient`) | 3.85 ms | 5.17 ms | 6.5 ms |
| WebSocket (`WebSocketPeer`) | 0.48 ms | **0.75 ms** | 1.2 ms |

Solver share — `Simulator.run_step` on reference grids, warm-started, numba
(`tests/e2e/spike_c_timing.py`):

| Grid | Buses | p50 | p99* |
|---|---|---|---|
| ieee_33bw | 33 | 10.5 ms | (3.1 s = one-time numba JIT) |
| kerber_vorstadtnetz | 294 | 33.2 ms | 66.6 ms |
| ieee_european_lv | 907 | 77.7 ms | 135 ms |

## Decision

- **Step channel: WebSocket** (`WebSocketPeer`), persistent connection per
  backend. ~7× less transport overhead than HTTP and no per-request uvicorn
  parsing; also the natural channel for pushed degradation warnings later.
- **Control plane: HTTP** (`/gb/version`, `/gb/health`, `/gb/net/reset`,
  `/gb/net/patch`) — infrequent, benefits from plain request/response
  semantics and curl-ability.
- **JIT warmup rule:** after every `/net/reset`, the backend fires one
  throwaway solve so the numba JIT cost (~3 s) never lands on a live step.
- **Budget check:** at the mandated zone scale (§2.4), solver p50 + WS
  transport ≈ 11–34 ms — inside budget. The 294-bus p99 (67 ms) slightly
  exceeds 50 ms; acceptable because the orchestrator's one-step-lag +
  skip-and-interpolate degradation (§2.5/§8) absorbs occasional overruns.
  Keep default zone counts ≤ ~300 per network; 907-bus-class networks are
  confirmed out of per-step budget and stay behind aggregation.

## Consequences

Contract v1 (Phase 2) specifies the step exchange as WS messages mirroring the
POST body/response; `/gb/step` over HTTP remains as a debugging fallback.
The current gamebridge slice (rtpowerflow branch `gamebridge`) implements the
HTTP fallback; the WS step channel is Phase 2 work.
