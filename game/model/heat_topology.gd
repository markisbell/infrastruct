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
## Design load of ONE heat zone [kW] — matches the `q_design_w` each
## consumer carries into the bundle, and is what pipe sizing counts.
const ZONE_DESIGN_KW := 160.0

## The ISOPLUS DN ladder and what each size carries at a sane 1.2 m/s with
## this network's 30 K spread (85/55). Every pipe in every city used to be
## ISOPLUS_DRE50_STD — one constant — and DN50 carries ~335 kW. Heidelberg's
## 17 zones want 2720 kW, so its trunk was about ten times too small and the
## far Altstadt arrived at 10-20 °C however much plant stood behind it. Real
## networks size each pipe for the load DOWNSTREAM of it, which is exactly
## what rtheatflow's own convert_schutterwald does to the same catalog.
const PIPE_LADDER: Array = [
	["ISOPLUS_DRE32_STD", 149.0], ["ISOPLUS_DRE40_STD", 202.0],
	["ISOPLUS_DRE50_STD", 335.0], ["ISOPLUS_DRE65_STD", 560.0],
	["ISOPLUS_DRE80_STD", 784.0], ["ISOPLUS_DRE100_STD", 1321.0],
	["ISOPLUS_DRE125_STD", 2022.0], ["ISOPLUS_DRE150_STD", 2959.0],
	["ISOPLUS_DRE200_STD", 5084.0], ["ISOPLUS_DRE250_STD", 7966.0],
	["ISOPLUS_DRE300_STD", 11262.0], ["ISOPLUS_DRE400_STD", 17861.0],
	["ISOPLUS_DRE500_STD", 27136.0],
]


const T_SUPPLY_MIN_C := 60.0
const TRETURN_K := 328.15  # 55 °C

var doc := {}                    # contract topology document ({} if no plant)
var pipe_tiles := {}             # "P<idx>" -> Array[Vector2i]
var zones_info := {}             # zone_id -> {sub: building_id, houses: int, center: Vector2i}
var house_zone := {}             # Vector2i -> zone_id
var connected := {}              # building_id -> bool (plant-reachable)
var has_plant := false
var warnings: Array[String] = []


## Pump lift for the pressure slack [bar]. A fixed 2 bar suits a village and
## leaves a 6 km city's far end at NEGATIVE differential pressure (measured
## on Heidelberg: -0.86 bar at the worst point, a critical `dp_low`) — the
## drop a run has to overcome grows with its length. A real network
## regulates this on the worst point (Schlechtpunktregelung); with no such
## controller in the loop, sizing it from the network's own extent is the
## honest stand-in.
const PLIFT_PER_KM := 0.35
const PLIFT_MIN_BAR := 2.0
const PLIFT_MAX_BAR := 8.0


static func plift_bar(trench_km: float) -> float:
	return clampf(1.5 + PLIFT_PER_KM * trench_km, PLIFT_MIN_BAR, PLIFT_MAX_BAR)


## Smallest catalog pipe that carries *load_kw* at a sane velocity.
static func pipe_std_type(load_kw: float) -> String:
	for entry: Array in PIPE_LADDER:
		if load_kw <= float(entry[1]):
			return str(entry[0])
	return str(PIPE_LADDER[PIPE_LADDER.size() - 1][0])


## Design load BEHIND every node, seen from the plant: root the reachable
## network at the slack and sum each subtree's consumers. A pipe then takes
## the load of whatever hangs off its far end, which is how a network is
## dimensioned in practice — thick at the plant, thin at the last house.
static func load_tree(raw_pipes: Array, reachable: Dictionary,
		roots: Array, node_kw: Dictionary) -> Dictionary:
	var adj := {}
	for entry: Dictionary in raw_pipes:
		if not (reachable.has(entry["a"]) and reachable.has(entry["b"])):
			continue
		for pair: Array in [[entry["a"], entry["b"]], [entry["b"], entry["a"]]]:
			if not adj.has(pair[0]):
				adj[pair[0]] = []
			adj[pair[0]].append(pair[1])
	var parent := {}
	# one root PER independent system: each component is dimensioned from
	# its own plant outwards, and a node belongs to exactly one of them
	var order: Array = []
	var seen := {}
	for root: Variant in roots:
		if not seen.has(root):
			seen[root] = true
			order.append(root)
	var i := 0
	while i < order.size():
		var node: Variant = order[i]
		i += 1
		for nb: Variant in adj.get(node, []):
			if not seen.has(nb):
				seen[nb] = true
				parent[nb] = node
				order.append(nb)
	var load := {}
	for node: Variant in order:
		load[node] = float(node_kw.get(node, 0.0))
	for j in range(order.size() - 1, -1, -1):   # leaves first, up to the roots
		var node: Variant = order[j]
		if parent.has(node):                    # a root has none
			load[parent[node]] = float(load[parent[node]]) + float(load[node])
	return {"parent": parent, "load": load, "node_kw": node_kw}


## What one pipe has to carry [kW].
static func _edge_load_kw(tree: Dictionary, a: Variant, b: Variant) -> float:
	var parent: Dictionary = tree["parent"]
	var load: Dictionary = tree["load"]
	var kw := 0.0
	if parent.get(b) == a:
		kw = float(load.get(b, 0.0))
	elif parent.get(a) == b:
		kw = float(load.get(a, 0.0))
	else:
		# a loop closer, in neither direction of the tree: it carries a share
		# of the ring rather than everything behind either end, so the
		# smaller side is the honest design figure
		kw = minf(float(load.get(a, 0.0)), float(load.get(b, 0.0)))
	# a pipe touching a plant or a zone must at least carry that node's OWN
	# duty: a secondary boiler sits at a leaf, so its subtree load is zero
	# and its service pipe would otherwise be sized DN32 for 100 kW of
	# output. On a trunk the subtree already dominates, so this is a no-op.
	var node_kw: Dictionary = tree["node_kw"]
	return maxf(kw, maxf(float(node_kw.get(a, 0.0)), float(node_kw.get(b, 0.0))))


static func build(model: WorldModel, tripped: Dictionary) -> HeatTopology:
	var topo := HeatTopology.new()
	topo._build(model, tripped)
	return topo


func _relevant(model: WorldModel, id: String) -> bool:
	var kind: String = model.buildings[id]["kind"]
	return BuildingDefs.get_def(kind).get("network", "") == "heat"


func _build(model: WorldModel, tripped: Dictionary) -> void:
	var pipe := NetGraph.live_layer(model.heat_pipes, tripped, false)

	# 1. bus tiles: heat-building connection points + junctions. A pipe tile
	# adjacent to SEVERAL heat buildings serves them ALL (service edges
	# below) — first-wins orphaned every later neighbor of a shared tile
	# single service connection per building (user correction 2026-08-02)
	var tile_buildings := NetGraph.tap_map(model, pipe, "heat")
	var bus_tiles := {}
	for pos: Vector2i in pipe:
		if tile_buildings.has(pos):
			bus_tiles[pos] = tile_buildings[pos][0]
		elif NetGraph.degree(pipe, pos) >= 3:
			bus_tiles[pos] = "j:%d,%d" % [pos.x, pos.y]

	# 2. walk pipe runs between bus tiles + service edges (NetGraph, Phase 7)
	var raw_pipes := NetGraph.run_edges(pipe, bus_tiles, tile_buildings)

	# 3. reachability from the slack plant
	var plant_ids: Array[String] = []
	for kind: String in BuildingDefs.HEAT_PLANT_KINDS:
		plant_ids.append_array(model.buildings_of_kind(kind))
	plant_ids.sort()  # deterministic tie-break
	has_plant = not plant_ids.is_empty()
	if not has_plant:
		return
	# ONE PRESSURE REFERENCE PER CONNECTED COMPONENT — not one per network.
	# A district heating system that is not physically joined to another is
	# an independent system, and a city split by a river is exactly that.
	# This used to bind a SINGLE slack and BFS from it, silently discarding
	# every pipe it could not reach ("only the slack plant's network is
	# solved"), which is why Heidelberg's north bank could have no heat at
	# all. The backend takes several slacks now, one per component.
	var adjacency := NetGraph.adjacency(raw_pipes)
	var component_of := {}          # node -> component index
	var components: Array = []      # index -> Dictionary(node -> true)
	for entry: Dictionary in raw_pipes:
		for node: Variant in [entry["a"], entry["b"]]:
			if component_of.has(node):
				continue
			var members := NetGraph.bfs_from(adjacency, [node])
			for member: Variant in members:
				component_of[member] = components.size()
			components.append(members)

	# Within a component the slack is the HOTTEST plant, not the
	# alphabetically first: its t_flow_k is the supply temperature that
	# component runs at, and every other plant there feeds in without
	# setting it. Choosing by id let a 66 °C boiler outrank an 85 °C CHP
	# ("boiler_plant" < "chp_plant") and drag a whole city below what its
	# far ends could be served at.
	var slack_of := {}              # component index -> plant id
	var hottest_of := {}
	for id: String in plant_ids:
		if not component_of.has(id):
			continue                # a plant with no pipe of its own
		var cid: int = int(component_of[id])
		var flow_c := float(BuildingDefs.get_def(
			model.buildings[id]["kind"]).get("t_flow_c", 85.0))
		if not slack_of.has(cid) or flow_c > float(hottest_of[cid]):
			slack_of[cid] = id
			hottest_of[cid] = flow_c
	var slack_ids: Array[String] = []
	for cid: Variant in slack_of:
		slack_ids.append(str(slack_of[cid]))
	slack_ids.sort()                # deterministic document order
	var reachable := {}
	for cid: Variant in slack_of:
		for node: Variant in components[int(cid)]:
			reachable[node] = true
	# `connected` is answered for EVERY heat building, including when there
	# is nothing to solve — the HUD and the callers read it either way.
	for id: String in model.buildings:
		if _relevant(model, id):
			connected[id] = reachable.has(id)
	if slack_ids.is_empty():
		return
	# A component with consumers but NO plant stays dark — the heat
	# equivalent of a renewable-only power island with nothing grid-forming
	# in it. Nothing holds its pressure, so there is nothing to solve.
	for sub_id: String in model.buildings_of_kind("heat_exchanger"):
		if component_of.has(sub_id) and not reachable.has(sub_id):
			warnings.append("heat exchangers sit on a pipe network with no "
				+ "plant on it — build a plant there or join the networks")
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
			kind = "plant" if slack_ids.has(key) \
				else ("consumer" if b_kind == "heat_exchanger" else "node")
		var anchor: Vector2i = model.buildings[key]["anchor"] \
			if (key is String and not str(key).begins_with("j:")) else _junction_pos(key)
		junctions.append({"name": name, "kind": kind,
			"geo": [48.0 + anchor.y * 0.0004, 8.0 + anchor.x * 0.0004],
			"pn_bar": 6.0})
	# what every pipe has to carry: zone design loads plus, for the pipes
	# that touch them, what the plants inject
	var node_kw := {}
	for sub_id: String in model.buildings_of_kind("heat_exchanger"):
		if reachable.has(sub_id):
			node_kw[sub_id] = ZONE_DESIGN_KW
	for id: String in plant_ids:
		if reachable.has(id):
			node_kw[id] = float(BuildingDefs.get_def(
				model.buildings[id]["kind"]).get("dispatch_q_kw", 100.0))
	var tree := load_tree(raw_pipes, reachable, slack_ids, node_kw)

	var pipes_out: Array[Dictionary] = []
	var trench_km := {}            # component index -> km, for its pump lift
	for entry: Dictionary in raw_pipes:
		if not (reachable.has(entry["a"]) and reachable.has(entry["b"])):
			continue
		var idx := pipes_out.size()
		pipe_tiles["P%d" % idx] = entry["path"]
		var tiles: int = (entry["path"] as Array).size()
		pipes_out.append({
			"from_node": node_name[entry["a"]], "to_node": node_name[entry["b"]],
			"std_type": pipe_std_type(_edge_load_kw(tree, entry["a"], entry["b"])),
			"length_km": tiles * BuildingDefs.TILE_M / 1000.0,
			"sections": maxi(1, tiles / 4),
		})
		var cid: int = int(component_of[entry["a"]])
		trench_km[cid] = float(trench_km.get(cid, 0.0)) \
			+ tiles * BuildingDefs.TILE_M / 1000.0

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
		zones_info[zone_id] = {"sub": sub_id, "houses": 0, "house_tiles": [],
			"center": model.buildings[sub_id]["anchor"]}
		consumers.append({"node": node_name[sub_id], "name": zone_id,
			"q_sh_w": zeros, "q_dhw_w": zeros, "treturn_k": treturns,
			"q_design_w": ZONE_DESIGN_KW * 1000.0,
			"t_supply_min_c": T_SUPPLY_MIN_C})
	_assign_houses(model)
	if consumers.is_empty():
		warnings.append("heat network has no connected heat exchangers")
		doc = {}
		return

	var devices: Array[Dictionary] = []
	# THE SLACK DEVICE MUST BE FIRST — the backend binds device[0] to the
	# bundle's one slack producer and configures its dispatch model from that
	# plant's kind. This used to fall out of the id sort for free (the slack
	# WAS plant_ids[0]); once the slack became the hottest plant, a boiler
	# sorting ahead of the CHP was handed the slack's role while the bundle's
	# producer still named the CHP's node. The CHP then ran as a secondary
	# and its coupled electricity collapsed (coldsnap caught it: the heat→
	# power coupling came back at -18.8 kW where the CHP owes < -30).
	var ordered: Array[String] = slack_ids.duplicate()
	for id: String in plant_ids:
		if not slack_ids.has(id):
			ordered.append(id)
	for id: String in ordered:
		if reachable.has(id):
			var def := BuildingDefs.get_def(model.buildings[id]["kind"])
			devices.append({"id": id, "kind": def["device"], "node": node_name[id],
				"params": model.building_params(id)})
	for id: String in model.buildings_of_kind("heat_storage"):
		if reachable.has(id):
			devices.append({"id": id, "kind": "storage_heat", "node": node_name[id],
				"params": model.building_params(id)})

	# Secondary plants and storages are BRIDGE-side elements (feed-ins /
	# buffers) — invisible to the backend's native zero-flow validation. On
	# a pipe STUB (degree-1 junction) the whole bundle used to be rejected
	# ("dead-end node without consumer/producer" → HEAT REJECTED, network
	# dark; user report: a second boiler plant wouldn't place). Ship the
	# backend's own remedy automatically: the canonical bypass consumer
	# (SPEC §3.2 mdot+qext pair) — the trickle valve every real plant stub
	# has. The bypass name matches no zone, so its profile stays untouched.
	var degree := {}
	for entry: Dictionary in raw_pipes:
		if reachable.has(entry["a"]) and reachable.has(entry["b"]):
			degree[entry["a"]] = int(degree.get(entry["a"], 0)) + 1
			degree[entry["b"]] = int(degree.get(entry["b"], 0)) + 1
	var standby: Array[float] = []
	for i in 96:
		standby.append(100.0)
	for device: Dictionary in devices:
		var id: String = device["id"]
		if slack_ids.has(id) or int(degree.get(id, 0)) != 1:
			continue
		consumers.append({"node": node_name[id], "name": "bypass_" + id,
			"q_sh_w": zeros, "q_dhw_w": standby,
			"controlled_mdot_kg_per_s": 0.02, "q_design_w": 100.0})

	# ONE producer per pressure reference: its own supply temperature (its
	# plant's kind) and its own pump lift (sized from ITS system's extent).
	var producers_out: Array[Dictionary] = []
	for id: String in slack_ids:
		var cid: int = int(component_of[id])
		producers_out.append({
			"node": node_name[id], "name": "plant_" + id, "kind": "slack",
			"p_flow_bar": 6.0,
			"plift_bar": plift_bar(float(trench_km.get(cid, 0.0))),
			"t_flow_k": 273.15 + float(BuildingDefs.get_def(
				model.buildings[id]["kind"]).get("t_flow_c", 85.0))})

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
			"producers": {"producers": producers_out},
			"weather": {"resolution_minutes": 15, "steps": 96,
				"t_amb_c": temps, "t_ground_c": grounds},
		},
		"zones": zones,
		"devices": devices,
	}


func _assign_houses(model: WorldModel) -> void:
	NetGraph.assign_houses(model, zones_info, house_zone,
		BuildingDefs.get_def("heat_exchanger")["zone_radius"])
	NetGraph.assign_commercial(model, zones_info,
		BuildingDefs.get_def("heat_exchanger")["zone_radius"])


static func _junction_pos(key: Variant) -> Vector2i:
	var parts := str(key).trim_prefix("j:").split(",")
	return Vector2i(int(parts[0]), int(parts[1]))


static func _node_name(key: Variant) -> String:
	return "hn_%s" % key if not str(key).begins_with("j:") \
		else "hj_%s" % str(key).trim_prefix("j:").replace(",", "_")
