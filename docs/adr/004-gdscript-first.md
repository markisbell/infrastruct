# ADR-004: GDScript first; C# only behind a measured trigger

**Status:** accepted · **Phase:** 0

## Context

Godot 4 supports GDScript and C# as first-class languages. The team's daily
stack is Python (both simulation backends are Python/FastAPI); the game's
heavy numerics live in the backends, not the game.

## Decision

- **GDScript for everything** initially: Python-like syntax (lowest friction
  for the team), zero-build iteration, one runtime fewer to package.
- **Static typing is mandatory in `game/model/`** (typed vars, typed loops,
  typed returns — enforced in review); strongly encouraged elsewhere. This is
  the mitigation for GDScript's dynamic-typing bug class (risk register §6.5).
- **C# escape hatch** — considered only when a profiled hot path in game code
  (not solver code) exceeds its frame budget after algorithmic fixes and
  typed-GDScript optimization, e.g. topology diffing on 1024²+ maps. A switch
  is per-module, never wholesale.

## Consequences

- No .NET SDK in the toolchain until the trigger fires; CI and packaging stay
  simple (Godot standard build, not the Mono build).
- Spike A/B code already follows the typed-GDScript convention and doubles as
  the style reference.
