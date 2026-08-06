class_name WaterTopology
extends RefCounted
## Extracts the drinking-water network from the tile world and builds the
## contract topology document for the water backend (rtwaterflow native
## five-file bundle: network_structure/pipes/consumers/supply/environment).
## Mirrors HeatTopology's tile-graph walk over model.water_pipes.
##
## Rules (contract v1.1 §3.1 water notes + gamebridge interface pin):
## - the HEAD source provides the pressure boundary; preference
##   water_tower > well > pumping_station, by id within a kind; it is
##   ordered FIRST in doc.devices and mirrored as the single ext_grid in
##   native.supply (p_bar 0.5 for towers — elevation carries the head —
##   else 4.0 for a pressurized feed)
## - junction elevation_m = BASE + terrain elevation (per-tile heights,
##   Terrain.STEP_M per level) + tower_height_m folded in for towers
##   (tank bottom sits at node elevation) — hilltop towers genuinely help
## - water_station buildings define water zones (one consumer per zone,
##   mapped by NAME); houses join the nearest head-reachable station

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const BASE_ELEVATION_M := 300.0
const PIPE_DIAMETER_MM := 150.0
const PIPE_K_MM := 0.1
const PN_BAR := 4.0
## head preference order (index = priority)
const SOURCE_PRIORITY: Array[String] = ["water_tower", "well", "pumping_station"]
## Wells within this manhattan radius of a river tile yield more (richer
## aquifer) — the incentive to site wells along the water.
const WELL_WATER_RADIUS := 3
const WELL_RIVER_BONUS := 1.5

var doc := {}                    # contract topology document ({} if no source)
var pipe_tiles := {}             # "P<idx>" -> Array[Vector2i]
var zones_info := {}             # zone_id -> {sub: building_id, houses: int, center: Vector2i}
var house_zone := {}             # Vector2i -> zone_id
var connected := {}              # building_id -> bool (head-reachable)
var has_source := false
var warnings: Array[String] = []


static func build(model: WorldModel, tripped: Dictionary) -> WaterTopology:
	var topo := WaterTopology.new()
	topo._build(model, tripped)
	return topo


func _relevant(model: WorldModel, id: String) -> bool:
	var kind: String = model.buildings[id]["kind"]
	return BuildingDefs.get_def(kind).get("network", "") == "water"


func _build(model: WorldModel, tripped: Dictionary) -> void:
	var pipe := NetGraph.live_layer(model.water_pipes, tripped, false)

	# 1. bus tiles: water-building connection points + junctions. A pipe
	# tile adjacent to SEVERAL water buildings serves them ALL (service
	# edges below) — first-wins orphaned e.g. a second station teeing off
	# the same tile as the well (user report)
	# single service connection per building (user correction 2026-08-02);
	# ONLY the water layer grants the pumping_station two-tap allowance
	var tile_buildings := NetGraph.tap_map(model, pipe, "water", "pumping_station")
	# INLINE boosters (user request 2026-08-02): a pumping_station with TWO
	# pipe taps splits into two nodes (its taps) joined by a StationSpec
	# pump branch — pressure is boosted ALONG the run. Single-tap pumps
	# keep their source-with-head duty (implicit intake), so pumpblackout
	# and old saves are untouched.
	var pump_split := {}   # id -> {"a": tile (key id), "b": tile (key id#dis)}
	for id: String in model.buildings_of_kind("pumping_station"):
		var taps := PowerTopology.connection_tiles(model, id, pipe, "pumping_station")
		if taps.size() == 2:
			pump_split[id] = {"a": taps[0], "b": taps[1]}
	var bus_tiles := {}
	for pos: Vector2i in pipe:
		if tile_buildings.has(pos):
			var owner: String = tile_buildings[pos][0]
			if pump_split.has(owner) and pos == pump_split[owner]["b"]:
				bus_tiles[pos] = owner + "#dis"
			else:
				bus_tiles[pos] = owner
		elif NetGraph.degree(pipe, pos) >= 3:
			bus_tiles[pos] = "j:%d,%d" % [pos.x, pos.y]

	# 2. walk pipe runs between bus tiles + service edges (NetGraph, Phase 7)
	var raw_pipes := NetGraph.run_edges(pipe, bus_tiles, tile_buildings)

	# 3. head choice + reachability from the head
	var source_ids: Array[String] = []
	for kind: String in SOURCE_PRIORITY:
		for sid: String in model.buildings_of_kind(kind):
			if not pump_split.has(sid):  # an inline booster is no source
				source_ids.append(sid)
	has_source = not source_ids.is_empty()
	if not has_source:
		return
	var head_id: String = source_ids[0]
	var adjacency := NetGraph.adjacency(raw_pipes)
	var reachable := NetGraph.bfs_from(adjacency, [head_id])
	var queue: Array = []
	# station direction: suction faces the head (decided by the pre-pump
	# reachability); then flow continues across the branch — extend the BFS
	for id: String in pump_split:
		var from_key: Variant = id
		var to_key: Variant = id + "#dis"
		if reachable.has(to_key) and not reachable.has(from_key):
			from_key = id + "#dis"
			to_key = id
		elif reachable.has(to_key) and reachable.has(from_key):
			warnings.append("booster %s is bypassed by its own main" % id)
		pump_split[id]["from_key"] = from_key
		pump_split[id]["to_key"] = to_key
		for pair: Array in [[id, id + "#dis"], [id + "#dis", id]]:
			if not adjacency.has(pair[0]):
				adjacency[pair[0]] = []
			adjacency[pair[0]].append(pair[1])
		for key: Variant in [from_key, to_key]:
			if reachable.has(key):
				queue.append(key)
	NetGraph.bfs_more(adjacency, reachable, queue)
	for id: String in model.buildings:
		if _relevant(model, id):
			connected[id] = reachable.has(id) or reachable.has(id + "#dis")
	for id: String in source_ids:
		if not reachable.has(id):
			warnings.append(("water source %s sits on a separate pipe network — "
				+ "only the head's network is solved; connect the networks") % id)
			break

	# 4. junction/pipe/consumer/supply docs (reachable subgraph only)
	var node_name := {}
	var junctions: Array[Dictionary] = []
	for key: Variant in reachable:
		var name := _node_name(key)
		node_name[key] = name
		var kind := "node"
		var anchor := _junction_pos(key)
		var base_id := str(key).trim_suffix("#dis")
		if key is String and pump_split.has(base_id):
			# booster nodes sit at their tap tiles (suction/discharge)
			anchor = pump_split[base_id]["b"] if str(key).ends_with("#dis") 				else pump_split[base_id]["a"]
		elif key is String and not str(key).begins_with("j:"):
			anchor = model.buildings[key]["anchor"]
		var elevation := BASE_ELEVATION_M + model.terrain.elevation_m(anchor)
		if key is String and not str(key).begins_with("j:") 				and not pump_split.has(base_id):
			var b_kind: String = model.buildings[key]["kind"]
			if b_kind == "water_station":
				kind = "consumer"
			elif BuildingDefs.WATER_SOURCE_KINDS.has(b_kind):
				kind = "source"
			if b_kind == "water_tower":
				# tank bottom at node elevation (contract §3.1 water notes)
				elevation += float(model.building_params(key).get("tower_height_m", 25.0))
		junctions.append({"name": name, "kind": kind,
			"geo": [48.0 + anchor.y * 0.0004, 8.0 + anchor.x * 0.0004],
			"elevation_m": elevation, "pn_bar": PN_BAR})
	var pipes_out: Array[Dictionary] = []
	for entry: Dictionary in raw_pipes:
		if not (reachable.has(entry["a"]) and reachable.has(entry["b"])):
			continue
		var idx := pipes_out.size()
		pipe_tiles["P%d" % idx] = entry["path"]
		var tiles: int = (entry["path"] as Array).size()
		pipes_out.append({
			"from_node": node_name[entry["a"]], "to_node": node_name[entry["b"]],
			"length_km": tiles * BuildingDefs.TILE_M / 1000.0,
			"inner_diameter_mm": PIPE_DIAMETER_MM, "k_mm": PIPE_K_MM,
		})

	var consumers: Array[Dictionary] = []
	var zones: Array[Dictionary] = []
	for sub_id: String in model.buildings_of_kind("water_station"):
		if not connected.get(sub_id, false):
			continue
		var zone_id := "wz_" + sub_id
		zones.append({"id": zone_id, "consumer": zone_id})
		zones_info[zone_id] = {"sub": sub_id, "houses": 0, "house_tiles": [],
			"center": model.buildings[sub_id]["anchor"]}
		# mdot placeholder (Field gt=0) — the per-step zone_demand rules
		consumers.append({"node": node_name[sub_id], "name": zone_id,
			"mdot_kg_per_s": 0.01, "kind": "residential"})
	_assign_houses(model)
	if consumers.is_empty():
		warnings.append("water network has no connected water stations")
		doc = {}
		return

	var devices: Array[Dictionary] = []
	for id: String in source_ids:     # head FIRST (backend binds the ext_grid)
		if reachable.has(id):
			var def := BuildingDefs.get_def(model.buildings[id]["kind"])
			var params := model.building_params(id)
			# a well near a river taps a richer aquifer: +50 % rated yield
			# (Terrain.is_water — the environment pass's gameplay hook)
			if def["device"] == "well" and model.terrain.near_water(
					model.buildings[id]["anchor"], WELL_WATER_RADIUS):
				params = params.duplicate()
				params["rated_m3_h"] = float(params.get("rated_m3_h", 15.0)) \
					* WELL_RIVER_BONUS
			devices.append({"id": id, "kind": def["device"], "node": node_name[id],
				"params": params})

	var stations_out: Array[Dictionary] = []
	for id: String in pump_split:
		if not (reachable.has(id) or reachable.has(id + "#dis")):
			continue
		var st_params: Dictionary = model.building_params(id).duplicate()
		var st_name := "st_%s" % id
		st_params["station"] = st_name
		var boost := float(st_params.get("boost_bar", 2.0))
		var rated := float(st_params.get("rated_m3_h", 15.0))
		devices.append({"id": id, "kind": "water_pump",
			"node": node_name[pump_split[id]["from_key"]], "params": st_params})
		stations_out.append({
			"from_node": node_name[pump_split[id]["from_key"]],
			"to_node": node_name[pump_split[id]["to_key"]],
			"name": st_name,
			"curve": [[0.0, boost], [rated, boost * 0.6], [rated * 2.0, 0.05]],
			"control": {"mode": "manual", "running": true}})
	var head_is_tower: bool = model.buildings[head_id]["kind"] == "water_tower"
	var temps: Array[float] = []
	for i in 96:
		temps.append(10.0)  # placeholder — the per-step weather override rules
	doc = {
		"contract": "1.0",
		"network_kind": "water",
		"name": "city_water",
		"steps_per_day": 96,
		"native": {
			"network_structure": {"name": "city_water", "junctions": junctions},
			"pipes": {"pipes": pipes_out},
			"consumers": {"consumers": consumers},
			"supply": {"supplies": [{"node": node_name[head_id], "name": "head",
				"kind": "ext_grid", "p_bar": 0.5 if head_is_tower else 4.0}],
				"stations": stations_out},
			"environment": {"resolution_minutes": 15, "steps": 96, "t_air_c": temps},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	NetGraph.assign_houses(model, zones_info, house_zone,
		BuildingDefs.get_def("water_station")["zone_radius"])
	NetGraph.assign_commercial(model, zones_info,
		BuildingDefs.get_def("water_station")["zone_radius"])


static func _junction_pos(key: Variant) -> Vector2i:
	var parts := str(key).trim_prefix("j:").split(",")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO


static func _node_name(key: Variant) -> String:
	return "wn_%s" % key if not str(key).begins_with("j:") \
		else "wj_%s" % str(key).trim_prefix("j:").replace(",", "_")
