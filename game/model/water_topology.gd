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
	var pipe := {}
	for pos: Vector2i in model.water_pipes:
		if not tripped.has(pos):
			pipe[pos] = true

	# 1. bus tiles: water-building connection points + junctions. A pipe
	# tile adjacent to SEVERAL water buildings serves them ALL (service
	# edges below) — first-wins orphaned e.g. a second station teeing off
	# the same tile as the well (user report)
	var tile_buildings := {}
	for id: String in model.buildings:
		if not _relevant(model, id):
			continue
		var entry: Dictionary = model.buildings[id]
		# single service connection per building (user correction
		# 2026-08-02) — same rule as power, no multi-tap exception here
		for n: Vector2i in PowerTopology.connection_tiles(model, id, pipe):
			if not tile_buildings.has(n):
				tile_buildings[n] = []
			if not (tile_buildings[n] as Array).has(id):
				tile_buildings[n].append(id)
	var bus_tiles := {}
	for pos: Vector2i in pipe:
		if tile_buildings.has(pos):
			bus_tiles[pos] = tile_buildings[pos][0]
		elif _degree(pipe, pos) >= 3:
			bus_tiles[pos] = "j:%d,%d" % [pos.x, pos.y]

	# 2. walk pipe runs between bus tiles
	var raw_pipes: Array[Dictionary] = []
	var walked := {}
	for pos: Vector2i in bus_tiles:
		for offset: Vector2i in NEIGHBORS:
			var step: Vector2i = pos + offset
			if not pipe.has(step) or not PowerTopology.cable_linked(pipe, pos, step) \
					or walked.has("%s>%s" % [pos, step]):
				continue
			var path: Array[Vector2i] = [pos]
			var prev := pos
			var cur := step
			var dead_end := false
			while not bus_tiles.has(cur):
				path.append(cur)
				var nxt := Vector2i(99999, 99999)
				for o2: Vector2i in NEIGHBORS:
					var cand: Vector2i = cur + o2
					if cand != prev and pipe.has(cand) \
							and PowerTopology.cable_linked(pipe, cur, cand):
						nxt = cand
						break
				if nxt.x == 99999:
					dead_end = true
					break
				prev = cur
				cur = nxt
			if dead_end:
				continue
			path.append(cur)
			walked["%s>%s" % [pos, step]] = true
			walked["%s>%s" % [cur, prev]] = true
			if bus_tiles[pos] != bus_tiles[cur]:
				raw_pipes.append({"a": bus_tiles[pos], "b": bus_tiles[cur], "path": path})
	# service edges: every EXTRA building on a shared connection tile joins
	# the first one over that tile (one-tile stub main)
	var linked := {}
	for pos: Vector2i in tile_buildings:
		var ids: Array = tile_buildings[pos]
		for i in range(1, ids.size()):
			var pair := "%s|%s" % [ids[0], ids[i]]
			if linked.has(pair):
				continue
			linked[pair] = true
			var stub: Array[Vector2i] = [pos]
			raw_pipes.append({"a": ids[0], "b": ids[i], "path": stub})

	# 3. head choice + reachability from the head
	var source_ids: Array[String] = []
	for kind: String in SOURCE_PRIORITY:
		source_ids.append_array(model.buildings_of_kind(kind))
	has_source = not source_ids.is_empty()
	if not has_source:
		return
	var head_id: String = source_ids[0]
	var adjacency := {}
	for entry: Dictionary in raw_pipes:
		for pair: Array in [[entry["a"], entry["b"]], [entry["b"], entry["a"]]]:
			if not adjacency.has(pair[0]):
				adjacency[pair[0]] = []
			adjacency[pair[0]].append(pair[1])
	var reachable := {head_id: true}
	var queue: Array = [head_id]
	while not queue.is_empty():
		var key: Variant = queue.pop_back()
		for neighbor: Variant in adjacency.get(key, []):
			if not reachable.has(neighbor):
				reachable[neighbor] = true
				queue.append(neighbor)
	for id: String in model.buildings:
		if _relevant(model, id):
			connected[id] = reachable.has(id)
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
		if key is String and not str(key).begins_with("j:"):
			anchor = model.buildings[key]["anchor"]
		var elevation := BASE_ELEVATION_M + model.terrain.elevation_m(anchor)
		if key is String and not str(key).begins_with("j:"):
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
				"kind": "ext_grid", "p_bar": 0.5 if head_is_tower else 4.0}]},
			"environment": {"resolution_minutes": 15, "steps": 96, "t_air_c": temps},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	var radius: int = BuildingDefs.get_def("water_station")["zone_radius"]
	for pos: Vector2i in model.houses:
		var best_zone := ""
		var best_dist := 999
		for zone_id: String in zones_info:
			var info: Dictionary = zones_info[zone_id]
			var dist: int = absi(pos.x - info["center"].x) + absi(pos.y - info["center"].y)
			if dist <= radius and dist < best_dist:
				best_dist = dist
				best_zone = zone_id
		if best_zone != "":
			house_zone[pos] = best_zone
			zones_info[best_zone]["houses"] += 1
			zones_info[best_zone]["house_tiles"].append(pos)


static func _degree(pipe: Dictionary, pos: Vector2i) -> int:
	var degree := 0
	for offset: Vector2i in NEIGHBORS:
		var n := pos + offset
		if pipe.has(n) and PowerTopology.cable_linked(pipe, pos, n):
			degree += 1
	return degree


static func _junction_pos(key: Variant) -> Vector2i:
	var parts := str(key).trim_prefix("j:").split(",")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO


static func _node_name(key: Variant) -> String:
	return "wn_%s" % key if not str(key).begins_with("j:") \
		else "wj_%s" % str(key).trim_prefix("j:").replace(",", "_")
