class_name WorldModel
extends RefCounted
## Logical world model — single source of truth (ADR-002). Pure data +
## (de)serialization; no scene-node dependencies (headless-testable).
## v2 (Phase 3): roads, residential zoning, houses, buildings with
## footprints — on top of v1's cable layer.

const SCHEMA_VERSION := 5

## Zone paint kinds + auto-spawned commercial lot types (commercial pass
## 2026-08-06): industry grows on COMMERCIAL paint, gated by substation
## headroom (City owns the gate; DemandModel owns the per-type draws).
const ZONE_RESIDENTIAL := 1
const ZONE_COMMERCIAL := 2
const COMMERCIAL_GENERAL := 1  # mechanical production: high elec, low heat/water
const COMMERCIAL_FOOD := 2     # food production: high heat (process!) + water
const COMMERCIAL_MALL := 3     # retail: high elec + water, medium heat

var terrain := Terrain.new()         # per-tile heights (v5; seed 0 = flat)
var cables: Dictionary = {}          # Vector2i -> int (kind; 1 = LV cable)
var heat_pipes: Dictionary = {}      # Vector2i -> int (kind; 1 = DH pipe pair, v3)
var water_pipes: Dictionary = {}     # Vector2i -> int (kind; 1 = water main, v4)
var roads: Dictionary = {}           # Vector2i -> true
var zoning: Dictionary = {}          # Vector2i -> int (ZONE_* kind)
var commercial: Dictionary = {}      # Vector2i -> int (COMMERCIAL_* type; auto-spawned)
var houses: Dictionary = {}          # Vector2i -> {"level": int}
var buildings: Dictionary = {}       # id (String) -> {"kind": String, "anchor": Vector2i}
## Tiles the bulldozer cleared of environment props (trees/stones are
## DERIVED from the seed, so removal must be remembered explicitly).
var deco_cleared: Dictionary = {}    # Vector2i -> true
var next_building_id := 1

## Vector2i -> building id — derived from `buildings`, rebuilt on load.
var building_tiles: Dictionary = {}


# ─── occupancy ───

func is_tile_free(pos: Vector2i) -> bool:
	return not (roads.has(pos) or houses.has(pos) or building_tiles.has(pos)
		or cables.has(pos) or heat_pipes.has(pos) or water_pipes.has(pos)
		or terrain.is_water(pos))


## Buried lines (kind LINE_UNDERGROUND) may run under ROADS and share the
## street cross-section with other buried networks; nothing ever runs under
## houses or building footprints — and nothing crosses RIVERS (no bridges
## yet: water constrains routing). Surface builds keep the strict rules.
func _line_blocked(pos: Vector2i, buried: bool) -> bool:
	if houses.has(pos) or building_tiles.has(pos) or terrain.is_water(pos):
		return true
	return not buried and roads.has(pos)


## Does this layer hold a SURFACE entry here (blocks everything)?
func _surface_entry(layer: Dictionary, pos: Vector2i) -> bool:
	return layer.has(pos) and int(layer[pos]) != BuildingDefs.LINE_UNDERGROUND


## Cross-network conflict for a new entry: surface entries conflict with
## ANY other network entry; buried entries only with surface ones.
func _other_lines_conflict(pos: Vector2i, buried: bool,
		others: Array[Dictionary]) -> bool:
	for layer: Dictionary in others:
		if buried:
			if _surface_entry(layer, pos):
				return true
		elif layer.has(pos):
			return true
	return false


func can_place_building(kind: String, anchor: Vector2i) -> bool:
	# buildings need level ground: every footprint tile at the anchor's height
	var level := terrain.height(anchor)
	for tile: Vector2i in BuildingDefs.footprint(kind, anchor):
		if not is_tile_free(tile) or terrain.height(tile) != level:
			return false
	return true


# ─── mutations (all return success; can_* are the dry-run twins the
# drag-and-draw ghost path uses to color tiles before anything is built) ───

## One rule for all three line layers (cable/heat/water differ only in
## which OTHER two layers they must not conflict with).
func _can_set_line(pos: Vector2i, kind: int, others: Array[Dictionary]) -> bool:
	var buried := kind == BuildingDefs.LINE_UNDERGROUND
	return not (_line_blocked(pos, buried)
		or _other_lines_conflict(pos, buried, others))


func _set_line(layer: Dictionary, pos: Vector2i, kind: int,
		others: Array[Dictionary]) -> bool:
	if not _can_set_line(pos, kind, others):
		return false
	layer[pos] = kind
	return true


func can_set_cable(pos: Vector2i, kind: int) -> bool:
	return _can_set_line(pos, kind, [heat_pipes, water_pipes])


func set_cable(pos: Vector2i, kind: int) -> bool:
	return _set_line(cables, pos, kind, [heat_pipes, water_pipes])


func remove_cable(pos: Vector2i) -> void:
	cables.erase(pos)


func can_set_heat_pipe(pos: Vector2i, kind: int) -> bool:
	return _can_set_line(pos, kind, [cables, water_pipes])


func set_heat_pipe(pos: Vector2i, kind: int) -> bool:
	return _set_line(heat_pipes, pos, kind, [cables, water_pipes])


func remove_heat_pipe(pos: Vector2i) -> void:
	heat_pipes.erase(pos)


func can_set_water_pipe(pos: Vector2i, kind: int) -> bool:
	return _can_set_line(pos, kind, [cables, heat_pipes])


func set_water_pipe(pos: Vector2i, kind: int) -> bool:
	return _set_line(water_pipes, pos, kind, [cables, heat_pipes])


func remove_water_pipe(pos: Vector2i) -> void:
	water_pipes.erase(pos)


func has_cable(pos: Vector2i) -> bool:
	return cables.has(pos)


func can_set_road(pos: Vector2i) -> bool:
	# paving OVER existing buried lines is fine; surface lines block
	if roads.has(pos) or houses.has(pos) or building_tiles.has(pos) \
			or terrain.is_water(pos):
		return false
	for layer: Dictionary in [cables, heat_pipes, water_pipes]:
		if _surface_entry(layer, pos):
			return false
	return true


func set_road(pos: Vector2i) -> bool:
	if not can_set_road(pos):
		return false
	# paving CONSUMES zoning paint (playtest-monkey finding: the zone
	# survived under the asphalt and growth put a house on the road)
	zoning.erase(pos)
	roads[pos] = true
	return true


func remove_road(pos: Vector2i) -> void:
	roads.erase(pos)


func can_set_zone(pos: Vector2i) -> bool:
	# zoning is paint — allowed anywhere except on buildings/roads/lines
	# (houses may NOT sit over any line, buried or not); it coexists with
	# houses (that's what spawned them)
	return not (roads.has(pos) or building_tiles.has(pos) or cables.has(pos)
		or heat_pipes.has(pos) or water_pipes.has(pos)
		or terrain.is_water(pos))


func set_zone(pos: Vector2i, kind: int = 1) -> bool:
	if not can_set_zone(pos):
		return false
	zoning[pos] = kind
	return true


func remove_zone(pos: Vector2i) -> void:
	zoning.erase(pos)


## Shared buildability predicate — growth, the spawn-candidate list and the
## zone overlay must agree on whether a lot can take a house RIGHT NOW.
## Lines may legally cross ZONED land, but a house must never grow on top
## of one (playtest-monkey finding); road access needs the same terrain
## height (no driveway up a cliff — a mismatch stalled a real town).
## `kind` (commercial pass 2026-08-06): a lot only takes what its PAINT
## allows — houses on residential, industry on commercial.
func lot_buildable(pos: Vector2i, kind: int = ZONE_RESIDENTIAL) -> bool:
	return zoning.get(pos, 0) == kind and not houses.has(pos) \
		and not commercial.has(pos) and not roads.has(pos) \
		and not cables.has(pos) and not heat_pipes.has(pos) \
		and not water_pipes.has(pos) and _adjacent_to_road(pos)


func spawn_house(pos: Vector2i) -> bool:
	if not lot_buildable(pos):
		return false
	houses[pos] = {"level": 1}
	return true


func remove_house(pos: Vector2i) -> void:
	houses.erase(pos)


## A commercial lot hosts ONE business of a COMMERCIAL_* type (spawned by
## growth like houses, but on commercial paint and gated by the zone
## substation's headroom — City owns that gate).
func spawn_commercial(pos: Vector2i, ctype: int) -> bool:
	if not lot_buildable(pos, ZONE_COMMERCIAL):
		return false
	commercial[pos] = ctype
	return true


func remove_commercial(pos: Vector2i) -> void:
	commercial.erase(pos)


func place_building(kind: String, anchor: Vector2i, rot: int = 0,
		params_override: Dictionary = {}, flip: bool = false) -> String:
	if not BuildingDefs.DEFS.has(kind) or not can_place_building(kind, anchor):
		return ""
	var id := "%s_%d" % [kind, next_building_id]
	next_building_id += 1
	# rot (0-3, quarter turns) and flip (mirror on the horizontal axis) are
	# VISUAL only (all footprints are square); params_override (v4) merges
	# over the catalog params in the topology builders (per-building sizing)
	buildings[id] = {"kind": kind, "anchor": anchor, "rot": rot % 4,
		"flip": flip, "params": params_override}
	for tile: Vector2i in BuildingDefs.footprint(kind, anchor):
		building_tiles[tile] = id
	return id


## Catalog params merged with the building's own overrides.
func building_params(id: String) -> Dictionary:
	var def := BuildingDefs.get_def(buildings[id]["kind"])
	var params: Dictionary = def.get("params", {}).duplicate()
	params.merge(buildings[id].get("params", {}), true)
	return params


func remove_building(id: String) -> void:
	if not buildings.has(id):
		return
	var entry: Dictionary = buildings[id]
	for tile: Vector2i in BuildingDefs.footprint(entry["kind"], entry["anchor"]):
		building_tiles.erase(tile)
	buildings.erase(id)


func buildings_of_kind(kind: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in buildings:
		if buildings[id]["kind"] == kind:
			out.append(id)
	return out


func _adjacent_to_road(pos: Vector2i) -> bool:
	# a road across a terrain step doesn't serve this lot (no driveway up a cliff)
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n := pos + offset
		if roads.has(n) and terrain.height(n) == terrain.height(pos):
			return true
	return false


## Free zoned tiles adjacent to a road within `radius` of `center` — house
## spawn candidates (growth + zoning tools).
func spawn_candidates(center: Vector2i, radius: int,
		kind: int = ZONE_RESIDENTIAL) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for pos: Vector2i in zoning:
		if absi(pos.x - center.x) + absi(pos.y - center.y) > radius:
			continue
		if lot_buildable(pos, kind):
			out.append(pos)
	out.sort()  # deterministic order for seeded growth
	return out


## Structural invariants — the playtest monkey (and any test) can call this
## after arbitrary mutations; every returned string is a bug.
func check_invariants() -> Array[String]:
	var problems: Array[String] = []
	# building_tiles is exactly the union of building footprints
	var expected_tiles := {}
	for id: String in buildings:
		for tile: Vector2i in BuildingDefs.footprint(
				buildings[id]["kind"], buildings[id]["anchor"]):
			if expected_tiles.has(tile):
				problems.append("footprint overlap at %s (%s vs %s)"
					% [tile, expected_tiles[tile], id])
			expected_tiles[tile] = id
	for tile: Vector2i in expected_tiles:
		if building_tiles.get(tile, "") != expected_tiles[tile]:
			problems.append("building_tiles desync at %s" % tile)
	for tile: Vector2i in building_tiles:
		if not expected_tiles.has(tile):
			problems.append("stale building_tiles entry at %s" % tile)
	# nothing on water, nothing under houses/buildings, surface rules
	for layer_pair: Array in [["cable", cables], ["heat", heat_pipes],
			["water", water_pipes]]:
		var layer: Dictionary = layer_pair[1]
		for pos: Vector2i in layer:
			if terrain.is_water(pos):
				problems.append("%s on water at %s" % [layer_pair[0], pos])
			if houses.has(pos) or building_tiles.has(pos):
				problems.append("%s under a building/house at %s" % [layer_pair[0], pos])
			if roads.has(pos) and int(layer[pos]) != BuildingDefs.LINE_UNDERGROUND:
				problems.append("surface %s under a road at %s" % [layer_pair[0], pos])
	for pos: Vector2i in roads:
		if terrain.is_water(pos):
			problems.append("road on water at %s" % pos)
		if houses.has(pos) or building_tiles.has(pos):
			problems.append("road under a building/house at %s" % pos)
	for pos: Vector2i in houses:
		if not zoning.has(pos):
			problems.append("house without zoning at %s" % pos)
	for pos: Vector2i in commercial:
		if zoning.get(pos, 0) != ZONE_COMMERCIAL:
			problems.append("commercial lot without commercial zoning at %s" % pos)
		if houses.has(pos):
			problems.append("commercial lot on a house at %s" % pos)
	for pos: Vector2i in zoning:
		if terrain.is_water(pos):
			problems.append("zone on water at %s" % pos)
	for id: String in buildings:
		for tile: Vector2i in BuildingDefs.footprint(
				buildings[id]["kind"], buildings[id]["anchor"]):
			if terrain.is_water(tile):
				problems.append("building %s on water at %s" % [id, tile])
	return problems


# ─── serialization ───

func to_json() -> String:
	return JSON.stringify({
		"version": SCHEMA_VERSION,
		"terrain": terrain.serialize(),
		"cables": _dict_to_keys(cables),
		"heat_pipes": _dict_to_keys(heat_pipes),
		"water_pipes": _dict_to_keys(water_pipes),
		"roads": _dict_to_keys(roads),
		"zoning": _dict_to_keys(zoning),
		"houses": _dict_to_keys(houses),
		"commercial": _dict_to_keys(commercial),  # additive (old saves lack it)
		"buildings": _buildings_out(),
		"deco_cleared": _dict_to_keys(deco_cleared),  # additive (old saves lack it)
		"next_building_id": next_building_id,
	})


static func from_json(text: String) -> WorldModel:
	var model := WorldModel.new()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		push_error("WorldModel.from_json: invalid JSON")
		return model
	var dict: Dictionary = parsed
	model.terrain = Terrain.deserialize(dict.get("terrain", {}))  # pre-v5: flat
	model.cables = _keys_to_dict(dict.get("cables", {}), TYPE_INT)
	if int(dict.get("version", 1)) < 2:
		return model  # v1 saves carried cables only
	model.heat_pipes = _keys_to_dict(dict.get("heat_pipes", {}), TYPE_INT)
	model.water_pipes = _keys_to_dict(dict.get("water_pipes", {}), TYPE_INT)
	model.roads = _keys_to_dict(dict.get("roads", {}), TYPE_BOOL)
	model.zoning = _keys_to_dict(dict.get("zoning", {}), TYPE_INT)
	model.houses = _keys_to_dict(dict.get("houses", {}), TYPE_DICTIONARY)
	model.commercial = _keys_to_dict(dict.get("commercial", {}), TYPE_INT)
	model.deco_cleared = _keys_to_dict(dict.get("deco_cleared", {}), TYPE_BOOL)
	model.next_building_id = int(dict.get("next_building_id", 1))
	for id: String in dict.get("buildings", {}):
		var raw: Dictionary = dict["buildings"][id]
		var anchor := _parse_key(str(raw.get("anchor", "0,0")))
		model.buildings[id] = {"kind": str(raw["kind"]), "anchor": anchor,
			"rot": int(raw.get("rot", 0)),
			"flip": bool(raw.get("flip", false)),
			"params": raw.get("params", {})}
		for tile: Vector2i in BuildingDefs.footprint(str(raw["kind"]), anchor):
			model.building_tiles[tile] = id
	return model


func equals(other: WorldModel) -> bool:
	return cables == other.cables and heat_pipes == other.heat_pipes \
		and water_pipes == other.water_pipes and roads == other.roads \
		and zoning == other.zoning and houses == other.houses \
		and buildings == other.buildings and terrain.equals(other.terrain) \
		and deco_cleared == other.deco_cleared


func _buildings_out() -> Dictionary:
	var out := {}
	for id: String in buildings:
		var entry: Dictionary = buildings[id]
		out[id] = {"kind": entry["kind"],
			"anchor": "%d,%d" % [entry["anchor"].x, entry["anchor"].y],
			"rot": entry.get("rot", 0), "flip": entry.get("flip", false),
			"params": entry.get("params", {})}
	return out


static func _dict_to_keys(source: Dictionary) -> Dictionary:
	var out := {}
	for key: Vector2i in source:
		out["%d,%d" % [key.x, key.y]] = source[key]
	return out


static func _keys_to_dict(source: Dictionary, value_type: int) -> Dictionary:
	var out := {}
	for key: String in source:
		var pos := _parse_key(key)
		match value_type:
			TYPE_INT:
				out[pos] = int(source[key])
			TYPE_BOOL:
				out[pos] = true
			_:
				var value: Dictionary = source[key] if source[key] is Dictionary else {}
				if value.has("level"):
					value["level"] = int(value["level"])
				out[pos] = value
	return out


static func _parse_key(key: String) -> Vector2i:
	var parts := key.split(",")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO
