class_name WorldModel
extends RefCounted
## Logical world model — single source of truth (ADR-002). Pure data +
## (de)serialization; no scene-node dependencies (headless-testable).
## v2 (Phase 3): roads, residential zoning, houses, buildings with
## footprints — on top of v1's cable layer.

const SCHEMA_VERSION := 2

var cables: Dictionary = {}          # Vector2i -> int (kind; 1 = LV cable)
var roads: Dictionary = {}           # Vector2i -> true
var zoning: Dictionary = {}          # Vector2i -> int (1 = residential)
var houses: Dictionary = {}          # Vector2i -> {"level": int}
var buildings: Dictionary = {}       # id (String) -> {"kind": String, "anchor": Vector2i}
var next_building_id := 1

## Vector2i -> building id — derived from `buildings`, rebuilt on load.
var building_tiles: Dictionary = {}


# ─── occupancy ───

func is_tile_free(pos: Vector2i) -> bool:
	return not (roads.has(pos) or houses.has(pos) or building_tiles.has(pos)
		or cables.has(pos))


func can_place_building(kind: String, anchor: Vector2i) -> bool:
	for tile: Vector2i in BuildingDefs.footprint(kind, anchor):
		if not is_tile_free(tile):
			return false
	return true


# ─── mutations (all return success) ───

func set_cable(pos: Vector2i, kind: int) -> bool:
	if roads.has(pos) or houses.has(pos) or building_tiles.has(pos):
		return false
	cables[pos] = kind
	return true


func remove_cable(pos: Vector2i) -> void:
	cables.erase(pos)


func has_cable(pos: Vector2i) -> bool:
	return cables.has(pos)


func set_road(pos: Vector2i) -> bool:
	if not is_tile_free(pos):
		return false
	roads[pos] = true
	return true


func remove_road(pos: Vector2i) -> void:
	roads.erase(pos)


func set_zone(pos: Vector2i, kind: int = 1) -> bool:
	# zoning is paint — allowed anywhere except on buildings/roads/cables;
	# it coexists with houses (that's what spawned them)
	if roads.has(pos) or building_tiles.has(pos) or cables.has(pos):
		return false
	zoning[pos] = kind
	return true


func remove_zone(pos: Vector2i) -> void:
	zoning.erase(pos)


func spawn_house(pos: Vector2i) -> bool:
	if not zoning.has(pos) or houses.has(pos) or not _adjacent_to_road(pos):
		return false
	houses[pos] = {"level": 1}
	return true


func remove_house(pos: Vector2i) -> void:
	houses.erase(pos)


func place_building(kind: String, anchor: Vector2i, rot: int = 0) -> String:
	if not BuildingDefs.DEFS.has(kind) or not can_place_building(kind, anchor):
		return ""
	var id := "%s_%d" % [kind, next_building_id]
	next_building_id += 1
	# rot (0-3, quarter turns) is VISUAL only — footprints stay square-ish and
	# the electrical topology never sees it
	buildings[id] = {"kind": kind, "anchor": anchor, "rot": rot % 4}
	for tile: Vector2i in BuildingDefs.footprint(kind, anchor):
		building_tiles[tile] = id
	return id


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
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if roads.has(pos + offset):
			return true
	return false


## Free zoned tiles adjacent to a road within `radius` of `center` — house
## spawn candidates (growth + zoning tools).
func spawn_candidates(center: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for pos: Vector2i in zoning:
		if houses.has(pos):
			continue
		if absi(pos.x - center.x) + absi(pos.y - center.y) > radius:
			continue
		if _adjacent_to_road(pos):
			out.append(pos)
	out.sort()  # deterministic order for seeded growth
	return out


# ─── serialization ───

func to_json() -> String:
	return JSON.stringify({
		"version": SCHEMA_VERSION,
		"cables": _dict_to_keys(cables),
		"roads": _dict_to_keys(roads),
		"zoning": _dict_to_keys(zoning),
		"houses": _dict_to_keys(houses),
		"buildings": _buildings_out(),
		"next_building_id": next_building_id,
	})


static func from_json(text: String) -> WorldModel:
	var model := WorldModel.new()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		push_error("WorldModel.from_json: invalid JSON")
		return model
	var dict: Dictionary = parsed
	model.cables = _keys_to_dict(dict.get("cables", {}), TYPE_INT)
	if int(dict.get("version", 1)) < 2:
		return model  # v1 saves carried cables only
	model.roads = _keys_to_dict(dict.get("roads", {}), TYPE_BOOL)
	model.zoning = _keys_to_dict(dict.get("zoning", {}), TYPE_INT)
	model.houses = _keys_to_dict(dict.get("houses", {}), TYPE_DICTIONARY)
	model.next_building_id = int(dict.get("next_building_id", 1))
	for id: String in dict.get("buildings", {}):
		var raw: Dictionary = dict["buildings"][id]
		var anchor := _parse_key(str(raw.get("anchor", "0,0")))
		model.buildings[id] = {"kind": str(raw["kind"]), "anchor": anchor,
			"rot": int(raw.get("rot", 0))}
		for tile: Vector2i in BuildingDefs.footprint(str(raw["kind"]), anchor):
			model.building_tiles[tile] = id
	return model


func equals(other: WorldModel) -> bool:
	return cables == other.cables and roads == other.roads \
		and zoning == other.zoning and houses == other.houses \
		and buildings == other.buildings


func _buildings_out() -> Dictionary:
	var out := {}
	for id: String in buildings:
		var entry: Dictionary = buildings[id]
		out[id] = {"kind": entry["kind"],
			"anchor": "%d,%d" % [entry["anchor"].x, entry["anchor"].y],
			"rot": entry.get("rot", 0)}
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
