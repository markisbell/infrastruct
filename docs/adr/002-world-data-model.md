# ADR-002: Logical world model as source of truth; TileMapLayers as views

**Status:** accepted · **Phase:** 0 (validated by Spike A)

## Context

Godot's `TileMapLayer` stores per-cell source/atlas/alternative ids — fine for
rendering, wrong as a data model for networks that must be diffed, serialized,
and pushed to solvers. OpenTTD's map-bit scarcity (v1's top risk) must not be
re-imported as "TileMap custom-data scarcity".

## Decision

- All game state lives in plain GDScript objects under `game/model/`
  (`WorldModel` and successors): dictionaries keyed by `Vector2i`, typed values,
  no scene-node dependencies. This is the ONLY authority.
- `TileMapLayer`s (terrain, per-network overlays) are rebuilt/updated *from* the
  model; input tools write to the model first, view second.
- Serialization: versioned JSON envelope (`{"version": N, ...}`), coords as
  `"x,y"` string keys. Save/load rebuilds views from the model.
- Elevation: per-tile height integer in the model (terrain layer renders it;
  the water solver consumes it as junction elevation from Phase 5).

## Consequences

- Model code is headless-unit-testable (GdUnit4 suite runs in CI without a GPU) —
  proven by `game/tests/test_world_model.gd`.
- Topology diffing for `/net/patch` operates on model dictionaries, never on
  TileMap internals.
- Spike A measured the cost of the indirection: locked 60 fps (p99 frame
  16.73 ms) while painting 5 tiles/frame on a 256×256 map with model + view
  double-write; JSON round-trip lossless. No performance concern at this scale;
  chunked layers remain the Phase 8 fallback for 1024²+ maps.
