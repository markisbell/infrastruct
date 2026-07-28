class_name Terrain
extends RefCounted
## Per-tile integer heights (ADR-002, Phase 5 task 3). Seeded low-frequency
## noise quantized to plateau levels — deterministic, derived on demand, so
## saves carry only the seed (+ scenario overrides), never 65k tiles.
##
## seed 0 = FLAT everywhere: the default keeps every pre-terrain save and
## smoke byte-identical in behavior. force_height() is the scenario/test
## hook (and the seam terraforming would use later).
##
## Physics vs look: one level is STEP_M meters for the solvers (junction
## elevation_m) and VISUAL_STEP world units for the renderer — the visual
## scale is ~1.5x exaggerated (0.2 units would be true 1:25) so hills read.

const STEP_M := 5.0        # meters of real elevation per level (water physics)
const VISUAL_STEP := 0.3   # world units per level (renderer)
const MAX_LEVEL := 5

var seed_value := 0
var _noise := FastNoiseLite.new()
var _overrides := {}       # Vector2i -> int (forced heights win)


func _init(seed_arg: int = 0) -> void:
	set_seed(seed_arg)


func set_seed(seed_arg: int) -> void:
	seed_value = seed_arg
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = seed_arg
	_noise.frequency = 0.012  # features span ~80 tiles: broad, buildable plateaus


func height(pos: Vector2i) -> int:
	if _overrides.has(pos):
		return _overrides[pos]
	if seed_value == 0:
		return 0
	var n := _noise.get_noise_2d(float(pos.x), float(pos.y)) * 0.5 + 0.5
	return clampi(int(floor(n * (MAX_LEVEL + 1))), 0, MAX_LEVEL)


func elevation_m(pos: Vector2i) -> float:
	return height(pos) * STEP_M


func visual_y(pos: Vector2i) -> float:
	return height(pos) * VISUAL_STEP


## Scenario/test hook: force a rectangle [a, b] (inclusive) to one level.
func force_height(a: Vector2i, b: Vector2i, level: int) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			_overrides[Vector2i(x, y)] = clampi(level, 0, MAX_LEVEL)


func clear_overrides() -> void:
	_overrides.clear()


## Cheap change detector for the renderer (rebuild the mesh only on change).
func fingerprint() -> String:
	return "%d|%d" % [seed_value, _overrides.hash()]


# ─── serialization (inside the WorldModel envelope) ───

func serialize() -> Dictionary:
	var overrides_out := {}
	for pos: Vector2i in _overrides:
		overrides_out["%d,%d" % [pos.x, pos.y]] = _overrides[pos]
	return {"seed": seed_value, "overrides": overrides_out}


static func deserialize(data: Dictionary) -> Terrain:
	var terrain := Terrain.new(int(data.get("seed", 0)))
	for key: String in data.get("overrides", {}):
		var parts := key.split(",")
		if parts.size() == 2:
			terrain._overrides[Vector2i(int(parts[0]), int(parts[1]))] = \
				int(data["overrides"][key])
	return terrain


func equals(other: Terrain) -> bool:
	return seed_value == other.seed_value and _overrides == other._overrides
