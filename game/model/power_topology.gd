class_name PowerTopology
extends RefCounted
## Extracts the electrical network from the tile world (ADR-002: model is the
## source of truth) and builds the contract v1 topology document for the
## power backend, plus everything the game needs to interpret results:
## line-id → cable-tile paths (overlays, trips), house → zone assignment,
## slack-reachability (islands are excluded from the solver doc and rendered
## unpowered — pandapower needs the slack).
##
## Graph rules:
## - a cable tile is a BUS TILE if it touches a building footprint (the
##   building's connection point) or has 3+ cable neighbors (junction)
## - all bus tiles touching the same building collapse into ONE bus
## - lines are the simple cable paths between bus tiles (length = tiles × 25 m)

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
## Two LV feeder builds share one electrical graph (they join freely; a
## kind transition becomes a junction bus so every pandapower line segment
## carries ONE std_type): overhead Freileitung 48-AL1 (~145 kVA) vs the
## buried NAYY 4x150 (~187 kVA, pricier, out of sight). One healthy zone
## (40 houses, ~76 kW peak) loads an overhead feeder to ~52 % — hanging a
## second zone plus a cold-snap coupling load on it still overloads.
const STD_TYPES := {
	BuildingDefs.LINE_OVERHEAD: "48-AL1/8-ST1A 0.4",
	BuildingDefs.LINE_UNDERGROUND: "NAYY 4x150 SE",
}

var doc := {}                    # contract topology document ({} if no slack)
var line_tiles := {}             # "L<idx>" -> Array[Vector2i] (path incl. endpoints)
var zones_info := {}             # zone_id -> {sub: building_id, houses: int, bus: String, center: Vector2i}
var house_zone := {}             # Vector2i -> zone_id
var connected := {}              # building_id -> bool (slack-reachable)
var has_slack := false
var warnings: Array[String] = []


static func build(model: WorldModel, tripped: Dictionary) -> PowerTopology:
	var topo := PowerTopology.new()
	topo._build(model, tripped)
	return topo


func _build(model: WorldModel, tripped: Dictionary) -> void:
	# live cable set minus tripped tiles (value = line kind)
	var cable := {}
	for pos: Vector2i in model.cables:
		if not tripped.has(pos):
			cable[pos] = int(model.cables[pos])

	# 1. bus tiles: building connection points + junctions
	var tile_building := {}  # cable tile -> building id (first wins)
	for id: String in model.buildings:
		var entry: Dictionary = model.buildings[id]
		for tile: Vector2i in BuildingDefs.footprint(entry["kind"], entry["anchor"]):
			for offset: Vector2i in NEIGHBORS:
				var n: Vector2i = tile + offset
				if cable.has(n) and not tile_building.has(n):
					tile_building[n] = id
	var bus_tiles := {}  # tile -> bus key (building id or "j:x,y")
	for pos: Vector2i in cable:
		if tile_building.has(pos):
			bus_tiles[pos] = tile_building[pos]
		elif _degree(cable, pos) >= 3 or _kind_transition(cable, pos):
			bus_tiles[pos] = "j:%d,%d" % [pos.x, pos.y]

	# 2. walk lines between bus tiles
	var raw_lines: Array[Dictionary] = []  # {a: key, b: key, path: Array[Vector2i]}
	var walked := {}  # "x,y>x,y" directed segment dedupe
	for pos: Vector2i in bus_tiles:
		for offset: Vector2i in NEIGHBORS:
			var step: Vector2i = pos + offset
			if not cable.has(step):
				continue
			var seg_key := "%s>%s" % [pos, step]
			if walked.has(seg_key):
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
					if cand != prev and cable.has(cand):
						nxt = cand
						break
				if nxt.x == 99999:
					dead_end = true
					break
				prev = cur
				cur = nxt
			if dead_end:
				continue  # stub cable to nowhere — ignored
			path.append(cur)
			walked["%s>%s" % [pos, step]] = true
			walked["%s>%s" % [cur, prev]] = true
			if bus_tiles[pos] != bus_tiles[cur]:
				raw_lines.append({"a": bus_tiles[pos], "b": bus_tiles[cur], "path": path})

	# 3. reachability from the slack building over the line graph
	var slack_ids := model.buildings_of_kind("grid_connection")
	has_slack = not slack_ids.is_empty()
	if not has_slack:
		warnings.append("no grid connection — network unsolvable, everything unpowered")
		return
	var slack_id: String = slack_ids[0]
	if slack_ids.size() > 1:
		warnings.append("multiple grid connections; using %s" % slack_id)
	var adjacency := {}
	for line: Dictionary in raw_lines:
		for pair: Array in [[line["a"], line["b"]], [line["b"], line["a"]]]:
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
		connected[id] = reachable.has(id)

	# 4. buses (reachable only), lines, zones, devices → contract doc
	var bus_index := {}
	var buses: Array[Dictionary] = []
	for key: Variant in reachable:
		bus_index[key] = buses.size()
		buses.append({"name": _bus_name(key), "vn_kv": 0.4})
	var lines_out: Array[Dictionary] = []
	for line: Dictionary in raw_lines:
		if not (reachable.has(line["a"]) and reachable.has(line["b"])):
			continue
		var idx := lines_out.size()
		line_tiles["L%d" % idx] = line["path"]
		# kind transitions are junction buses, so the path interior is
		# kind-uniform; the middle tile names the segment's build
		var path: Array = line["path"]
		var mid_kind: int = cable.get(path[path.size() / 2], BuildingDefs.LINE_OVERHEAD)
		lines_out.append({
			"name": "L%d" % idx,
			"from_bus": bus_index[line["a"]], "to_bus": bus_index[line["b"]],
			"length_km": path.size() * BuildingDefs.TILE_M / 1000.0,
			"std_type": STD_TYPES.get(mid_kind, STD_TYPES[BuildingDefs.LINE_OVERHEAD]),
		})

	var zones: Array[Dictionary] = []
	for sub_id: String in model.buildings_of_kind("substation"):
		if not connected.get(sub_id, false):
			continue
		var zone_id := "z_" + sub_id
		zones.append({"id": zone_id, "node": _bus_name(sub_id)})
		zones_info[zone_id] = {"sub": sub_id, "houses": 0, "bus": _bus_name(sub_id),
			"center": model.buildings[sub_id]["anchor"]}
	_assign_houses(model)

	var devices: Array[Dictionary] = []
	var coupling_bus := {}  # other network -> bus (first cable-connected device)
	for id: String in model.buildings:
		if not connected.get(id, false):
			continue
		var def := BuildingDefs.get_def(model.buildings[id]["kind"])
		var device_kind: String = def.get("device", "")
		var network: String = def.get("network", "power")
		if network != "power":
			# a cable-connected heat/water plant: its electric coupling (heat
			# pump draw / CHP feed-in / water pump draw) lands here as the
			# aggregated cpl_<network> load (Orchestrator._coupling_for)
			if device_kind != "" and not coupling_bus.has(network):
				coupling_bus[network] = _bus_name(id)
			continue
		if device_kind == "":
			continue
		devices.append({"id": id, "kind": device_kind, "node": _bus_name(id),
			"params": model.building_params(id)})
	for network: String in coupling_bus:
		devices.append({"id": "cpl_%s" % network, "kind": "coupling_load",
			"node": coupling_bus[network], "params": {}})

	doc = {
		"contract": "1.0",
		"network_kind": "power",
		"name": "city_grid",
		"steps_per_day": 96,
		"native": {
			"grid_structure": {"name": "city", "f_hz": 50, "buses": buses},
			"lines": {"lines": lines_out, "transformers": []},
			"load": {"resolution_minutes": 15, "steps": 96, "loads": []},
			"generation": {"resolution_minutes": 15, "steps": 96, "generation": []},
			"substation": {"resolution_minutes": 15, "steps": 96, "substations": []},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	for pos: Vector2i in model.houses:
		var best_zone := ""
		var best_dist := 999
		for zone_id: String in zones_info:
			var info: Dictionary = zones_info[zone_id]
			var radius: int = BuildingDefs.get_def("substation")["zone_radius"]
			var dist: int = absi(pos.x - info["center"].x) + absi(pos.y - info["center"].y)
			if dist <= radius and dist < best_dist:
				best_dist = dist
				best_zone = zone_id
		if best_zone != "":
			house_zone[pos] = best_zone
			zones_info[best_zone]["houses"] += 1


static func _degree(cable: Dictionary, pos: Vector2i) -> int:
	var degree := 0
	for offset: Vector2i in NEIGHBORS:
		if cable.has(pos + offset):
			degree += 1
	return degree


## Overhead-to-underground joints become junction buses so each segment
## keeps one std_type. Only the lower-kind side is marked — one junction
## per joint, not two adjacent ones.
static func _kind_transition(cable: Dictionary, pos: Vector2i) -> bool:
	for offset: Vector2i in NEIGHBORS:
		var n: Vector2i = pos + offset
		if cable.has(n) and cable[n] > cable[pos]:
			return true
	return false


static func _bus_name(key: Variant) -> String:
	return "bb_%s" % key if not str(key).begins_with("j:") \
		else "bj_%s" % str(key).trim_prefix("j:").replace(",", "_")
