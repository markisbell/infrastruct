class_name BuildingDefs
extends RefCounted
## Building catalog (Phase 3). Colors feed the procedural tile atlas;
## `device` rows become contract devices (docs/contract/v1.md §3.1).

const TILE_M := 25.0  # one tile edge in meters (cable lengths derive from it)

const DEFS := {
	"substation": {
		"size": Vector2i(1, 1), "cost": 12_000, "device": "",
		"color": Color(0.25, 0.75, 0.85), "zone_radius": 12, "house_capacity": 40,
	},
	"grid_connection": {
		"size": Vector2i(2, 2), "cost": 30_000, "device": "slack",
		"params": {"vm_pu": 1.0}, "capacity_kw": 250.0,
		"color": Color(0.85, 0.3, 0.3),
	},
	"gas_plant": {
		"size": Vector2i(2, 2), "cost": 90_000, "device": "generator",
		"params": {"p_max_kw": 500.0}, "color": Color(0.55, 0.42, 0.3),
	},
	"wind_farm": {
		"size": Vector2i(2, 2), "cost": 70_000, "device": "wind",
		"params": {"p_rated_kw": 300.0}, "color": Color(0.92, 0.93, 0.95),
	},
	"solar_park": {
		"size": Vector2i(2, 2), "cost": 50_000, "device": "pv",
		"params": {"p_rated_kw": 200.0}, "color": Color(0.2, 0.3, 0.55),
	},
	"battery": {
		"size": Vector2i(1, 1), "cost": 40_000, "device": "battery",
		"params": {"e_kwh": 200.0, "p_max_kw": 100.0}, "color": Color(0.6, 0.35, 0.75),
	},
}

const COSTS := {"road": 40, "cable": 120, "zone": 10}


static func get_def(kind: String) -> Dictionary:
	return DEFS.get(kind, {})


static func footprint(kind: String, anchor: Vector2i) -> Array[Vector2i]:
	var size: Vector2i = DEFS[kind]["size"]
	var tiles: Array[Vector2i] = []
	for dx in size.x:
		for dy in size.y:
			tiles.append(anchor + Vector2i(dx, dy))
	return tiles
