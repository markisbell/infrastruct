class_name NetGraph
extends RefCounted
## Shared tile-graph machinery for the three network topology builders
## (Phase-7 refactor plan): live-layer masking, building tap maps, the
## bus-to-bus run walk with service edges, BFS reachability, and
## nearest-center house assignment. BYTE-STABILITY CONTRACT: these
## helpers preserve the exact iteration/insertion orders of the original
## inline code — the golden topology documents (test_topology_goldens)
## pin the builders' full output against any drift.

const NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## The live layer minus tripped tiles. Power keeps the line KIND as the
## value (std_type per segment); heat/water only need membership.
static func live_layer(layer: Dictionary, tripped: Dictionary,
		keep_kind: bool) -> Dictionary:
	var live := {}
	for pos: Vector2i in layer:
		if not tripped.has(pos):
			live[pos] = int(layer[pos]) if keep_kind else true
	return live


## tile -> Array[building ids] tapping it. A tile adjacent to SEVERAL
## buildings serves them ALL (service edges join the extras) — first-wins
## used to silently orphan every later neighbor of a shared tile.
## network "" = every building (power); else filtered by def network.
static func tap_map(model: WorldModel, layer: Dictionary,
		network: String, pair_kind := "") -> Dictionary:
	var taps := {}
	for id: String in model.buildings:
		if network != "" and BuildingDefs.get_def(
				model.buildings[id]["kind"]).get("network", "") != network:
			continue
		for n: Vector2i in PowerTopology.connection_tiles(model, id, layer,
				pair_kind):
			if not taps.has(n):
				taps[n] = []
			if not (taps[n] as Array).has(id):
				taps[n].append(id)
	return taps


static func degree(layer: Dictionary, pos: Vector2i) -> int:
	var count := 0
	for offset: Vector2i in NEIGHBORS:
		var n := pos + offset
		if layer.has(n) and PowerTopology.cable_linked(layer, pos, n):
			count += 1
	return count


## Bus-to-bus runs: walk from every bus tile along linked tiles until the
## next bus tile (stubs to nowhere are ignored; directed-segment dedupe),
## then the one-tile service edges joining EXTRA buildings on shared tap
## tiles. Returns [{a: key, b: key, path: Array[Vector2i]}] in walk order
## then service order — the edge indices downstream depend on it.
static func run_edges(layer: Dictionary, bus_tiles: Dictionary,
		taps: Dictionary) -> Array[Dictionary]:
	var edges: Array[Dictionary] = []
	var walked := {}
	for pos: Vector2i in bus_tiles:
		for offset: Vector2i in NEIGHBORS:
			var step: Vector2i = pos + offset
			if not layer.has(step) \
					or not PowerTopology.cable_linked(layer, pos, step) \
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
					if cand != prev and layer.has(cand) \
							and PowerTopology.cable_linked(layer, cur, cand):
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
				edges.append({"a": bus_tiles[pos], "b": bus_tiles[cur],
					"path": path})
	var linked := {}
	for pos: Vector2i in taps:
		var ids: Array = taps[pos]
		for i in range(1, ids.size()):
			var pair := "%s|%s" % [ids[0], ids[i]]
			if linked.has(pair):
				continue
			linked[pair] = true
			var stub: Array[Vector2i] = [pos]
			edges.append({"a": ids[0], "b": ids[i], "path": stub})
	return edges


static func adjacency(edge_list: Array[Dictionary]) -> Dictionary:
	var adjacency_map := {}
	for entry: Dictionary in edge_list:
		for pair: Array in [[entry["a"], entry["b"]], [entry["b"], entry["a"]]]:
			if not adjacency_map.has(pair[0]):
				adjacency_map[pair[0]] = []
			adjacency_map[pair[0]].append(pair[1])
	return adjacency_map


static func bfs_from(adjacency_map: Dictionary, seeds: Array) -> Dictionary:
	var reachable := {}
	var queue: Array = []
	for seed: Variant in seeds:
		reachable[seed] = true
		queue.append(seed)
	bfs_more(adjacency_map, reachable, queue)
	return reachable


## Continue a traversal after the caller extended the adjacency (the water
## booster branch) — mutates `reachable` in place.
static func bfs_more(adjacency_map: Dictionary, reachable: Dictionary,
		queue: Array) -> void:
	while not queue.is_empty():
		var key: Variant = queue.pop_back()
		for neighbor: Variant in adjacency_map.get(key, []):
			if not reachable.has(neighbor):
				reachable[neighbor] = true
				queue.append(neighbor)


## Houses join the NEAREST zone center within radius (manhattan; ties by
## zones_info iteration order). Mutates zones_info counts/house_tiles and
## house_zone in place — all three builders share the rule.
static func assign_houses(model: WorldModel, zones_info: Dictionary,
		house_zone: Dictionary, radius: int) -> void:
	for pos: Vector2i in model.houses:
		var best_zone := ""
		var best_dist := 999
		for zone_id: String in zones_info:
			var info: Dictionary = zones_info[zone_id]
			var dist: int = absi(pos.x - info["center"].x) \
				+ absi(pos.y - info["center"].y)
			if dist <= radius and dist < best_dist:
				best_dist = dist
				best_zone = zone_id
		if best_zone != "":
			house_zone[pos] = best_zone
			zones_info[best_zone]["houses"] += 1
			zones_info[best_zone]["house_tiles"].append(pos)
