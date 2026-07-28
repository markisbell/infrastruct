# ADR-001: Engine = Godot 4

**Status:** accepted (user decision 2026-07-28) · **Phase:** 0

## Context

The v1 roadmap planned a fork of OpenTTD. The user judged the fork risk too high;
a structured evaluation of open-source alternatives was run
([engine-recommendation.md](../engine-recommendation.md),
[engine-evaluation-notes.md](../engine-evaluation-notes.md) — GitHub-API-verified
activity/license/size data for ~20 candidates plus partial adversarially-verified
web research).

## Decision

Build on **Godot 4.x** (4.7.1-stable at time of writing), MIT license, GDScript
first (see ADR-004). Runner-up was a LinCity-NG fork (alive, ~10× smaller than
OpenTTD, already a city builder) — rejected because it retains fork/upstream risk
and the C++ bridge work, while Godot removes both.

## Consequences

- No fork to maintain; no copyleft obligation on game code; all city mechanics
  built by us (accepted, scoped minimally in Phase 3).
- The C++ cosim bridge from roadmap v1 becomes a GDScript autoload using the
  built-in HTTP/WebSocket clients (validated by Spike B: WS round-trip p99
  0.75 ms — see ADR-003).
- Phase 0 spikes validated the riskiest engine assumptions on 2026-07-28:
  isometric drag-build at locked 60 fps (Spike A), transport latency negligible
  (Spike B), puppet mode equivalence in rtpowerflow (Spike C). No blocker found;
  the decision stands.
