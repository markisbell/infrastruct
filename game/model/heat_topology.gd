class_name HeatTopology
extends RefCounted
## Extracts the district-heating network from the tile world and builds the
## contract topology document for the heat backend (rtheatflow native
## five-file bundle: network_structure/pipes/consumers/producers/weather).
## Mirrors PowerTopology's tile-graph walk over model.heat_pipes.
##
## Rules:
## - exactly one heat PLANT (boiler/chp/heat-pump) acts as the slack; it is
##   ordered FIRST in doc.devices (the backend binds the first plant-kind
##   device to the bundle's slack producer); further plants become
##   heat-exchanger feed-ins, storages become buffer storages
## - heat_exchanger buildings define heat zones (one consumer per zone);
##   houses join the nearest slack-reachable heat exchanger within radius

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const STD_TYPE := "ISOPLUS_DRE50_STD"
const T_SUPPLY_MIN_C := 60.0
const TRETURN_K := 328.15  # 55 °C

var doc := {}                    # contract topology document ({} if no plant)
var pipe_tiles := {}             # "P<idx>" -> Array[Vector2i]
var zones_info := {}             # zone_id -> {sub: building_id, houses: int, center: Vector2i}
var house_zone := {}             # Vector2i -> zone_id
var connected := {}              # building_id -> bool (plant-reachable)
var has_plant := false
var warnings: Array[String] = []


static func build(model: WorldModel, tripped: Dictionary) -> HeatTopology:
	var topo := HeatTopology.new()
	topo._build(model, tripped)
	return topo


func _relevant(model: WorldModel, id: String) -> bool:
	var kind: String = model.buildings[id]["kind"]
	return BuildingDefs.get_def(kind).get("network", "") == "heat"


func _build(model: WorldModel, tripped: Dictionary) -> void:
	var pipe := {}
	for pos: Vector2i in model.heat_pipes:
		if not tripped.has(pos):
			pipe[pos] = true

	# 1. bus tiles: heat-building connection points + junctions. A pipe tile
	# adjacent to SEVERAL heat buildings serves them ALL (service edges
	# below) — first-wins orphaned every later neighbor of a shared tile
	var tile_buildings := {}
	for id: String in model.buildings:
		if not _relevant(model, id):
			continue
		var entry: Dictionary = model.buildings[id]
		for tile: Vector2i in BuildingDefs.footprint(entry["kind"], entry["anchor"]):
			for offset: Vector2i in NEIGHBORS:
				var n: Vector2i = tile + offset
				if pipe.has(n):
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
			if not pipe.has(step) or walked.has("%s>%s" % [pos, step]):
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
					if cand != prev and pipe.has(cand):
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
	# the first one over that tile (one-tile stub trunk)
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

	# 3. reachability from the slack plant
	var plant_ids: Array[String] = []
	for kind: String in BuildingDefs.HEAT_PLANT_KINDS:
		plant_ids.append_array(model.buildings_of_kind(kind))
	plant_ids.sort()  # deterministic slack choice: first by id
	has_plant = not plant_ids.is_empty()
	if not has_plant:
		return
	var slack_id: String = plant_ids[0]
	var adjacency := {}
	for entry: Dictionary in raw_pipes:
		for pair: Array in [[entry["a"], entry["b"]], [entry["b"], entry["a"]]]:
			if not adjacency.has(pair[0]):
				adjacency[pair[0]] = []
			adjacency[pair[0]].append(pair[1])
	var reachable := {slack_id: true}
	var queue: Array = [slack_id]
	while not queue.is_empty():
		var key: Variant = queue.pop_back()
		for neighbor: Variant in adjacency.get(key, []):
			if not reachable.has(neighbor):
				reachable[neighbor] = true
				queue.append(neighbor)
	for id: String in model.buildings:
		if _relevant(model, id):
			connected[id] = reachable.has(id)
	for id: String in plant_ids:
		if not reachable.has(id):
			warnings.append(("heat plant %s sits on a separate pipe network — "
				+ "only the slack plant's network is solved; connect the networks") % id)
			break

	# 4. junction/pipe/consumer/producer docs (reachable subgraph only)
	var node_name := {}
	var junctions: Array[Dictionary] = []
	for key: Variant in reachable:
		var name := _node_name(key)
		node_name[key] = name
		var kind := "node"
		if key is String and not str(key).begins_with("j:"):
			var b_kind: String = model.buildings[key]["kind"]
			kind = "plant" if key == slack_id \
				else ("consumer" if b_kind == "heat_exchanger" else "node")
		var anchor: Vector2i = model.buildings[key]["anchor"] \
			if (key is String and not str(key).begins_with("j:")) else _junction_pos(key)
		junctions.append({"name": name, "kind": kind,
			"geo": [48.0 + anchor.y * 0.0004, 8.0 + anchor.x * 0.0004],
			"pn_bar": 6.0})
	var pipes_out: Array[Dictionary] = []
	for entry: Dictionary in raw_pipes:
		if not (reachable.has(entry["a"]) and reachable.has(entry["b"])):
			continue
		var idx := pipes_out.size()
		pipe_tiles["P%d" % idx] = entry["path"]
		var tiles: int = (entry["path"] as Array).size()
		pipes_out.append({
			"from_node": node_name[entry["a"]], "to_node": node_name[entry["b"]],
			"std_type": STD_TYPE,
			"length_km": tiles * BuildingDefs.TILE_M / 1000.0,
			"sections": maxi(1, tiles / 4),
		})

	var zeros: Array[float] = []
	var treturns: Array[float] = []
	for i in 96:
		zeros.append(0.0)
		treturns.append(TRETURN_K)
	var consumers: Array[Dictionary] = []
	var zones: Array[Dictionary] = []
	for sub_id: String in model.buildings_of_kind("heat_exchanger"):
		if not connected.get(sub_id, false):
			continue
		var zone_id := "hz_" + sub_id
		zones.append({"id": zone_id, "consumer": zone_id})
		zones_info[zone_id] = {"sub": sub_id, "houses": 0,
			"center": model.buildings[sub_id]["anchor"]}
		consumers.append({"node": node_name[sub_id], "name": zone_id,
			"q_sh_w": zeros, "q_dhw_w": zeros, "treturn_k": treturns,
			"q_design_w": 160_000.0, "t_supply_min_c": T_SUPPLY_MIN_C})
	_assign_houses(model)
	if consumers.is_empty():
		warnings.append("heat network has no connected heat exchangers")
		doc = {}
		return

	var devices: Array[Dictionary] = []
	for id: String in plant_ids:      # slack plant FIRST (backend binds it)
		if reachable.has(id):
			var def := BuildingDefs.get_def(model.buildings[id]["kind"])
			devices.append({"id": id, "kind": def["device"], "node": node_name[id],
				"params": model.building_params(id)})
	for id: String in model.buildings_of_kind("heat_storage"):
		if reachable.has(id):
			devices.append({"id": id, "kind": "storage_heat", "node": node_name[id],
				"params": model.building_params(id)})

	var temps: Array[float] = []
	var grounds: Array[float] = []
	for i in 96:
		temps.append(5.0)   # placeholder — the per-step weather override rules
		grounds.append(10.0)
	doc = {
		"contract": "1.0",
		"network_kind": "heat",
		"name": "city_heat",
		"steps_per_day": 96,
		"native": {
			"network_structure": {"name": "city_heat", "junctions": junctions},
			"pipes": {"pipes": pipes_out},
			"consumers": {"resolution_minutes": 15, "steps": 96, "consumers": consumers},
			"producers": {"producers": [{"node": node_name[slack_id],
				"name": "plant", "kind": "slack", "p_flow_bar": 6.0,
				"plift_bar": 2.0,
				"t_flow_k": 273.15 + float(BuildingDefs.get_def(
					model.buildings[slack_id]["kind"]).get("t_flow_c", 85.0))}]},
			"weather": {"resolution_minutes": 15, "steps": 96,
				"t_amb_c": temps, "t_ground_c": grounds},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	var radius: int = BuildingDefs.get_def("heat_exchanger")["zone_radius"]
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


static func _degree(pipe: Dictionary, pos: Vector2i) -> int:
	var degree := 0
	for offset: Vector2i in NEIGHBORS:
		if pipe.has(pos + offset):
			degree += 1
	return degree


static func _junction_pos(key: Variant) -> Vector2i:
	var parts := str(key).trim_prefix("j:").split(",")
	return Vector2i(int(parts[0]), int(parts[1]))


static func _node_name(key: Variant) -> String:
	return "hn_%s" % key if not str(key).begins_with("j:") \
		else "hj_%s" % str(key).trim_prefix("j:").replace(",", "_")
