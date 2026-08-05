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
## The buildable grid is the 20 kV MEDIUM-VOLTAGE network (realism pass:
## MW-scale generation makes 0.4 kV feeders physically impossible). Two
## builds share one graph, kind transitions become junction buses:
## overhead 48-AL1 (~7.3 MVA) vs buried NA2XS2Y 1x95 (~8.7 MVA). A 9 MW
## wind farm at full output overloads a single overhead line — route
## strong generation on cable or split the export path.
const MV_KV := 20.0
const STD_TYPES := {
	BuildingDefs.LINE_OVERHEAD: "48-AL1/8-ST1A 20.0",
	BuildingDefs.LINE_UNDERGROUND: "NA2XS2Y 1x95 RM/25 12/20 kV",
}


## Substation trafo element fields from its kVA rating: pandapower catalog
## std types down to 0.25 MVA; BELOW that, explicit physical parameters
## (typical distribution-trafo values) — the scenario/smoke hook for
## deliberately undersized village stations.
static func trafo_fields(rating_kva: float) -> Dictionary:
	if rating_kva < 250.0:
		return {"sn_mva": rating_kva / 1000.0, "vn_hv_kv": MV_KV, "vn_lv_kv": 0.4,
			"vk_percent": 4.0, "vkr_percent": 1.5, "pfe_kw": 0.2, "i0_percent": 0.4}
	if rating_kva <= 250.0:
		return {"std_type": "0.25 MVA 20/0.4 kV"}
	if rating_kva <= 400.0:
		return {"std_type": "0.4 MVA 20/0.4 kV"}
	return {"std_type": "0.63 MVA 20/0.4 kV"}

var doc := {}                    # contract topology document ({} if no slack)
var line_tiles := {}             # "L<idx>" -> Array[Vector2i] (path incl. endpoints)
var zones_info := {}             # zone_id -> {sub: building_id, houses: int, bus: String, center: Vector2i}
var house_zone := {}             # Vector2i -> zone_id
var connected := {}              # building_id -> bool (slack-reachable)
var trafo_subs := {}             # "T<idx>" (solved edge id) -> substation building id
var has_slack := false
var warnings: Array[String] = []


## Two adjacent cable tiles carry current unless they are PARALLEL RUNS
## touching sideways (user correction 2026-08-02: two lines laid side by
## side must not short together). PARALLEL means: both runs continue on a
## COMMON side of the contact. Zigzag/staircase steps (diagonal drags!)
## continue on OPPOSITE sides and stay one run (the first formulation cut
## them apart — user bug report), and anything continuing THROUGH the
## contact axis (T-approaches, crossings) always bonds. A T-tap is built
## by ending the new run INTO the old one.
static func cable_linked(cable: Dictionary, a: Vector2i, b: Vector2i) -> bool:
	var d := b - a
	var p := Vector2i(d.y, d.x)
	if cable.has(a - d) or cable.has(b + d):
		return true  # a run continues through the contact — junction gesture
	return not ((cable.has(a - p) and cable.has(b - p))
		or (cable.has(a + p) and cable.has(b + p)))


## The cable tiles a building actually taps: ALL adjacent runs for the
## grid connection (the 110/20 kV station bonds everything it touches),
## exactly ONE (sorted-first) for every other plant, battery or consumer
## (user correction 2026-08-02: single service connection per building).
static func connection_tiles(model: WorldModel, id: String,
		cable: Dictionary, pair_kind := "") -> Array[Vector2i]:
	var entry: Dictionary = model.buildings[id]
	var adjacent := {}
	for tile: Vector2i in BuildingDefs.footprint(entry["kind"], entry["anchor"]):
		for offset: Vector2i in NEIGHBORS:
			var n: Vector2i = tile + offset
			if cable.has(n):
				adjacent[n] = true
	var out: Array[Vector2i] = []
	out.assign(adjacent.keys())
	out.sort()
	if entry["kind"] == "grid_connection":
		return out
	# only the layer that ASKS for it may pair-tap (WaterTopology passes
	# pair_kind="pumping_station" for inline boosters — on the POWER layer
	# the same pump still taps its cable exactly once)
	var cap := 2 if (pair_kind != "" and entry["kind"] == pair_kind) else 1
	if out.size() > cap:
		out.resize(cap)
	return out


static func build(model: WorldModel, tripped: Dictionary) -> PowerTopology:
	var topo := PowerTopology.new()
	topo._build(model, tripped)
	return topo


func _build(model: WorldModel, tripped: Dictionary) -> void:
	# live cable set minus tripped tiles (value = line kind)
	var cable := NetGraph.live_layer(model.cables, tripped, true)

	# 1. bus tiles: building connection points + junctions. A cable tile
	# adjacent to SEVERAL buildings serves them ALL — the first id names the
	# bus, the rest attach through short service edges below (first-wins
	# used to silently orphan every later neighbor of a shared tile)
	var tile_buildings := NetGraph.tap_map(model, cable, "")
	var bus_tiles := {}  # tile -> bus key (building id or "j:x,y")
	for pos: Vector2i in cable:
		if tile_buildings.has(pos):
			bus_tiles[pos] = tile_buildings[pos][0]
		elif NetGraph.degree(cable, pos) >= 3 or _kind_transition(cable, pos):
			bus_tiles[pos] = "j:%d,%d" % [pos.x, pos.y]

	# 2. walk lines between bus tiles + service edges (NetGraph, Phase 7)
	var raw_lines := NetGraph.run_edges(cable, bus_tiles, tile_buildings)

	# 3. reachability from EVERY grid connection: each 110/20 kV station
	# energizes its own island (parallel ext_grids — the backend maps every
	# slack device onto its own substation row). Seeding only the first one
	# left later stations dead (user report: "newer grid connections don't
	# get activated").
	var slack_ids := model.buildings_of_kind("grid_connection")
	has_slack = not slack_ids.is_empty()
	if not has_slack:
		warnings.append("no grid connection — network unsolvable, everything unpowered")
		return
	var adjacency := NetGraph.adjacency(raw_lines)
	var reachable := NetGraph.bfs_from(adjacency, slack_ids)
	for id: String in model.buildings:
		connected[id] = reachable.has(id)

	# 4. buses (reachable only), lines, zones, devices → contract doc
	var bus_index := {}
	var buses: Array[Dictionary] = []
	for key: Variant in reachable:
		bus_index[key] = buses.size()
		buses.append({"name": _bus_name(key), "vn_kv": MV_KV})
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

	# each substation is a REAL 20/0.4 kV transformer: its own LV bus hangs
	# off the MV bus via a trafo element, the zone load sits on the LV side —
	# trafo loading comes solved from the contract "T<idx>" edges.
	# DISCONNECTED substations keep a zones_info entry (connected: false) so
	# their houses still count as dark after a branch trip cuts them off —
	# only connected zones enter the solver doc.
	var transformers: Array[Dictionary] = []
	var zones: Array[Dictionary] = []
	for sub_id: String in model.buildings_of_kind("substation"):
		var zone_id := "z_" + sub_id
		var is_conn: bool = connected.get(sub_id, false)
		zones_info[zone_id] = {"sub": sub_id, "houses": 0, "bus": "",
			"house_tiles": [],
			"connected": is_conn, "center": model.buildings[sub_id]["anchor"]}
		if not is_conn:
			continue
		# per-building params_override wins (scenario/smoke hook), else the def
		var rating: float = float(model.building_params(sub_id).get("rating_kva",
			BuildingDefs.get_def("substation").get("rating_kva", 630.0)))
		var lv_name := "lv_%s" % sub_id
		var edge_id := "T%d" % transformers.size()
		var spec := {"name": edge_id, "hv_bus": bus_index[sub_id],
			"lv_bus": buses.size()}
		spec.merge(trafo_fields(rating))
		transformers.append(spec)
		trafo_subs[edge_id] = sub_id
		buses.append({"name": lv_name, "vn_kv": 0.4})
		zones.append({"id": zone_id, "node": lv_name})
		zones_info[zone_id]["bus"] = lv_name
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
			"lines": {"lines": lines_out, "transformers": transformers},
			"load": {"resolution_minutes": 15, "steps": 96, "loads": []},
			"generation": {"resolution_minutes": 15, "steps": 96, "generation": []},
			"substation": {"resolution_minutes": 15, "steps": 96, "substations": []},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	NetGraph.assign_houses(model, zones_info, house_zone,
		BuildingDefs.get_def("substation")["zone_radius"])


## Overhead-to-underground joints become junction buses so each segment
## keeps one std_type. Only the lower-kind side is marked — one junction
## per joint, not two adjacent ones.
static func _kind_transition(cable: Dictionary, pos: Vector2i) -> bool:
	for offset: Vector2i in NEIGHBORS:
		var n: Vector2i = pos + offset
		if cable.has(n) and cable[n] > cable[pos] \
				and cable_linked(cable, pos, n):
			return true
	return false


## The solved segment covering a cable tile ("L<idx>"), "" if none (stubs,
## tripped tiles).
func line_id_at(pos: Vector2i) -> String:
	for edge_id: String in line_tiles:
		if (line_tiles[edge_id] as Array).has(pos):
			return edge_id
	return ""


## Stable telemetry key for a segment: its middle tile — unlike the
## L-indices, which are renumbered on every topology rebuild, the middle
## tile of a physical run survives most edits.
func line_key(edge_id: String) -> String:
	var path: Array = line_tiles[edge_id]
	var mid: Vector2i = path[path.size() / 2]
	return "line:%d,%d" % [mid.x, mid.y]


static func _bus_name(key: Variant) -> String:
	return "bb_%s" % key if not str(key).begins_with("j:") \
		else "bj_%s" % str(key).trim_prefix("j:").replace(",", "_")
