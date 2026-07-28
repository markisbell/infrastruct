# ADR-005: The view layer goes native 3D; the model stays a 2D tile grid

**Status:** accepted (user art-direction decision 2026-07-28) · **Phase:** 3.5 (visual foundation pass)

## Context

Phase 3 shipped with procedural flat 2D diamonds. The user wants individual
tiles with a "3D feel" before further mechanics, and chose the Kenney CC0
kits — City Kit (Suburban) for residential, City Kit (Industrial) for
commercial/plants, Factory Kit for the Phase 4/5 heat & water buildings —
which are **3D glTF model kits**, not sprite sheets.

## Decision

- **The game world renders in real 3D** (Godot Node3D scene) with a locked
  isometric-style orthographic camera and directional-light shadows.
  No sprite-baking pipeline: the GLB models are instanced natively.
- **Nothing above the view changes.** The logical world model (ADR-002)
  remains a 2D `Vector2i` tile grid; solver contract, gameplay, and tests are
  untouched. One tile = 1.0 world unit on the ground plane (y = 0).
- Kits vendored under `game/assets/kenney/` (CC0, license files included):
  suburban (40 GLB) · industrial (25) · roads (72, modular autotile set) ·
  factory (143, reserved for Phases 4–5).
- Buildings without a kit model (wind turbine, solar park, battery,
  substation, grid connection) are procedural low-poly primitives in the same
  flat-shaded style — swappable per catalog entry.
- Overlays become 3D primitives: cable wires tinted by line loading, torus
  voltage rings at substations; unpowered houses render as dark silhouettes
  (shared material override).
- Terrain stays flat; per-tile elevation (ADR-002) arrives with Phase 5.

## Alternative considered

Pre-rendering the kits to 2D isometric sprites (bake pipeline + TileMapLayer
tall sprites). Rejected: the bake step is extra machinery for a strictly
worse result — native 3D gives real lighting/shadows for free, uses the kits
unmodified, and Godot's 3D renderer handles this world size trivially.

## Consequences

- `city_view.gd` is rewritten (same class name + public API: `Tool`, `tool`,
  `overlays_visible`, `redraw()`, `mouse_tile()`); tile picking becomes a
  mouse-ray/ground-plane intersection.
- First `--import` processes ~280 GLBs once (minutes); CI cache unaffected.
- Headless smokes and GdUnit model tests are unaffected by construction;
  the screenshot/bench modes use a small `focus_tile()` camera API.
