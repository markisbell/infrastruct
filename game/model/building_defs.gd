class_name BuildingDefs
extends RefCounted
## Building catalog (Phase 3). Colors feed the procedural tile atlas;
## `device` rows become contract devices (docs/contract/v1.md §3.1).

const TILE_M := 25.0  # one tile edge in meters (cable lengths derive from it)

## `network`: which solver a def's device belongs to ("power" | "heat");
## heat plants may ALSO touch cables — their electric coupling then lands on
## the power net as the aggregated "cpl_heat" coupling_load (contract §4).
const DEFS := {
	"substation": {
		"size": Vector2i(1, 1), "cost": 12_000, "device": "", "network": "power",
		"color": Color(0.25, 0.75, 0.85), "zone_radius": 12, "house_capacity": 40,
	},
	"heat_exchanger": {
		"size": Vector2i(1, 1), "cost": 15_000, "device": "", "network": "heat",
		"color": Color(0.85, 0.45, 0.2), "zone_radius": 12, "house_capacity": 40,
	},
	"boiler_plant": {
		# the budget plant: LOW supply temperature — long networks go cold at
		# the far end in deep winter (t_flow_c feeds the slack producer)
		"size": Vector2i(2, 2), "cost": 60_000, "device": "boiler", "network": "heat",
		"params": {"eta": 0.95}, "t_flow_c": 66.0, "color": Color(0.6, 0.4, 0.25),
	},
	"chp_plant": {
		"size": Vector2i(2, 2), "cost": 110_000, "device": "chp", "network": "heat",
		"params": {"pq_ratio": 0.5}, "dispatch_q_kw": 150.0, "t_flow_c": 85.0,
		"color": Color(0.5, 0.3, 0.35),
	},
	"heat_pump_plant": {
		"size": Vector2i(2, 2), "cost": 85_000, "device": "heat_pump", "network": "heat",
		"params": {"eta_g": 0.5, "t_cold_source": "air"}, "t_flow_c": 70.0,
		"color": Color(0.35, 0.55, 0.5),
	},
	"heat_storage": {
		"size": Vector2i(1, 1), "cost": 45_000, "device": "storage_heat", "network": "heat",
		"params": {"e_kwh": 500.0, "p_max_kw": 100.0}, "color": Color(0.75, 0.55, 0.3),
	},
	"grid_connection": {
		"size": Vector2i(2, 2), "cost": 30_000, "device": "slack", "network": "power",
		"params": {"vm_pu": 1.0}, "capacity_kw": 250.0,
		"color": Color(0.85, 0.3, 0.3),
	},
	"gas_plant": {
		"size": Vector2i(2, 2), "cost": 90_000, "device": "generator", "network": "power",
		"params": {"p_max_kw": 500.0}, "color": Color(0.55, 0.42, 0.3),
	},
	"wind_farm": {
		"size": Vector2i(2, 2), "cost": 70_000, "device": "wind", "network": "power",
		"params": {"p_rated_kw": 300.0}, "color": Color(0.92, 0.93, 0.95),
	},
	"solar_park": {
		"size": Vector2i(2, 2), "cost": 50_000, "device": "pv", "network": "power",
		"params": {"p_rated_kw": 200.0}, "color": Color(0.2, 0.3, 0.55),
	},
	"battery": {
		"size": Vector2i(1, 1), "cost": 40_000, "device": "battery", "network": "power",
		"params": {"e_kwh": 200.0, "p_max_kw": 100.0}, "color": Color(0.6, 0.35, 0.75),
	},
	"water_station": {
		# zone definer, like substation/heat_exchanger — a district metering hub
		"size": Vector2i(1, 1), "cost": 14_000, "device": "", "network": "water",
		"color": Color(0.2, 0.55, 0.8), "zone_radius": 12, "house_capacity": 40,
	},
	"well": {
		# gravity-fed spring/well field: modest yield, no electricity needed;
		# yield_factor setpoint carries the drought state
		"size": Vector2i(1, 1), "cost": 25_000, "device": "well", "network": "water",
		"params": {"rated_m3_h": 15.0}, "color": Color(0.35, 0.5, 0.45),
	},
	"pumping_station": {
		# the workhorse: high yield + head, but draws grid power (cpl_water);
		# a blackout at the pump means pressure collapse downstream
		"size": Vector2i(2, 2), "cost": 55_000, "device": "water_pump", "network": "water",
		"params": {"rated_m3_h": 20.0, "head_m": 45.0, "eta": 0.6},
		"color": Color(0.25, 0.45, 0.7),
	},
	"water_tower": {
		# pressure boundary + buffer: tower_height_m is folded into the
		# junction's elevation_m by WaterTopology (contract §3.1 water notes)
		"size": Vector2i(1, 1), "cost": 65_000, "device": "water_tower", "network": "water",
		"params": {"volume_m3": 200.0, "tower_height_m": 25.0},
		"color": Color(0.55, 0.65, 0.75),
	},
}

const HEAT_PLANT_KINDS: Array[String] = ["boiler_plant", "chp_plant", "heat_pump_plant"]
const WATER_SOURCE_KINDS: Array[String] = ["well", "pumping_station", "water_tower"]

const COSTS := {"road": 40, "cable": 120, "zone": 10, "heat_pipe": 350, "water_pipe": 180}


static func get_def(kind: String) -> Dictionary:
	return DEFS.get(kind, {})


static func footprint(kind: String, anchor: Vector2i) -> Array[Vector2i]:
	var size: Vector2i = DEFS[kind]["size"]
	var tiles: Array[Vector2i] = []
	for dx in size.x:
		for dy in size.y:
			tiles.append(anchor + Vector2i(dx, dy))
	return tiles
