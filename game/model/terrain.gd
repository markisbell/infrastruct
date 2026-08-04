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
## Rivers occupy valley tiles (level 0) where a second noise channel crosses
## zero — |n| below this fraction of the amplitude becomes water. 0.05 gives
## winding ribbons 2-4 tiles wide.
const RIVER_BAND := 0.05

var seed_value := 0
var _noise := FastNoiseLite.new()
var _river := FastNoiseLite.new()
var _overrides := {}       # Vector2i -> int (forced heights win)
## Baked real-DEM region (game/data/terrain/<name>.json, fetch_region.py):
## replaces the noise HEIGHTS only — rivers/overrides/serialization work
## unchanged ("" = noise mode; every old save and smoke is untouched).
var region := ""
var _region_levels := PackedInt32Array()
var _region_size := 0
var _water_overrides := {} # Vector2i -> bool (scenario hook; false = never water)


func _init(seed_arg: int = 0) -> void:
	set_seed(seed_arg)


func set_seed(seed_arg: int) -> void:
	seed_value = seed_arg
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = seed_arg
	_noise.frequency = 0.012  # features span ~80 tiles: broad, buildable plateaus
	_river.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_river.seed = seed_arg + 7331
	_river.frequency = 0.006  # long meanders, independent of the plateau field


func load_region(name: String) -> bool:
	var path := "res://data/terrain/%s.json" % name
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("levels"):
		return false
	region = name
	_region_size = int((parsed as Dictionary).get("size", 256))
	_region_levels.clear()
	for v: Variant in (parsed as Dictionary)["levels"]:
		_region_levels.append(int(v))
	return true


func height(pos: Vector2i) -> int:
	if _overrides.has(pos):
		return _overrides[pos]
	if region != "" and _region_size > 0:
		var cx := clampi(pos.x, 0, _region_size - 1)
		var cy := clampi(pos.y, 0, _region_size - 1)
		return _region_levels[cy * _region_size + cx]
	if seed_value == 0:
		return 0
	var n := _noise.get_noise_2d(float(pos.x), float(pos.y)) * 0.5 + 0.5
	return clampi(int(floor(n * (MAX_LEVEL + 1))), 0, MAX_LEVEL)


## Rivers: derived like heights (seed-only, nothing stored). seed 0 = no
## water anywhere — pre-river saves and smokes stay byte-identical. Water
## lives ONLY on valley tiles (level 0) and never under forced-height
## rectangles (scenario plateaus stay dry land).
func is_water(pos: Vector2i) -> bool:
	if _water_overrides.has(pos):
		return _water_overrides[pos]
	if seed_value == 0 or _overrides.has(pos) or height(pos) != 0:
		return false
	return absf(_river.get_noise_2d(float(pos.x), float(pos.y))) < RIVER_BAND


## Any water within `radius` (manhattan)? Wells near a river yield more.
func near_water(pos: Vector2i, radius: int) -> bool:
	for dx in range(-radius, radius + 1):
		for dy in range(-radius + absi(dx), radius - absi(dx) + 1):
			if is_water(pos + Vector2i(dx, dy)):
				return true
	return false


## Scenario/test hook: force a rectangle [a, b] to water (or dry land).
func force_water(a: Vector2i, b: Vector2i, water: bool = true) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			_water_overrides[Vector2i(x, y)] = water


func elevation_m(pos: Vector2i) -> float:
	return height(pos) * STEP_M


func visual_y(pos: Vector2i) -> float:
	return height(pos) * VISUAL_STEP


## Scenario/test hook: force a rectangle [a, b] (inclusive) to one level.
func force_height(a: Vector2i, b: Vector2i, level: int) -> void:
	for x in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
		for y in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
			_overrides[Vector2i(x, y)] = clampi(level, 0, MAX_LEVEL)


## Cheap change detector for the renderer (rebuild the mesh only on change).
func fingerprint() -> String:
	return "%d|%s|%d|%d" % [seed_value, region, _overrides.hash(),
		_water_overrides.hash()]


# ─── serialization (inside the WorldModel envelope) ───

func serialize() -> Dictionary:
	var overrides_out := {}
	for pos: Vector2i in _overrides:
		overrides_out["%d,%d" % [pos.x, pos.y]] = _overrides[pos]
	var water_out := {}
	for pos: Vector2i in _water_overrides:
		water_out["%d,%d" % [pos.x, pos.y]] = _water_overrides[pos]
	# water key is additive — old saves simply lack it (schema stays v5)
	# region key is additive too — noise saves simply lack it
	var out := {"seed": seed_value, "overrides": overrides_out, "water": water_out}
	if region != "":
		out["region"] = region
	return out


static func deserialize(data: Dictionary) -> Terrain:
	var terrain := Terrain.new(int(data.get("seed", 0)))
	if str(data.get("region", "")) != "":
		terrain.load_region(str(data["region"]))
	for key: String in data.get("overrides", {}):
		var parts := key.split(",")
		if parts.size() == 2:
			terrain._overrides[Vector2i(int(parts[0]), int(parts[1]))] = \
				int(data["overrides"][key])
	for key: String in data.get("water", {}):
		var parts := key.split(",")
		if parts.size() == 2:
			terrain._water_overrides[Vector2i(int(parts[0]), int(parts[1]))] = \
				bool(data["water"][key])
	return terrain


func equals(other: Terrain) -> bool:
	return seed_value == other.seed_value and region == other.region \
		and _overrides == other._overrides \
		and _water_overrides == other._water_overrides
