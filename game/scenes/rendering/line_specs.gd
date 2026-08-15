class_name LineSpecs
extends RefCounted
## Line-tile DECISIONS (Phase-5 refactor plan, extracted from
## city_view.gd): which neighbors a road/cable/buried run joins, where a
## building taps, where the Kabelendmast dresses a pole, and the cache
## keys the dirty-tile fast path compares. This is the code most past
## regressions lived in (staircase/parallel rule, neighbor-kind cache
## key, the twice-flipped road table) — pure statics over WorldModel,
## sharing PowerTopology's layer-agnostic linkage predicates. The
## renderer builds meshes FROM these specs and adds nothing of its own.

const DIRECTIONS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(0, 1), Vector2i(-1, 0)]  # N E S W (indices ride cache keys)


# ─── building predicates (shared by cable, buried and pipe rendering) ───

## Is the neighbor tile part of a building of the given network? (pipe
## connection stubs — heat plants/exchangers, water sources/stations)
static func network_building_at(model: WorldModel, pos: Vector2i,
		network: String) -> bool:
	var id: String = model.building_tiles.get(pos, "")
	if id == "":
		return false
	return BuildingDefs.get_def(
		model.buildings[id]["kind"]).get("network", "") == network


## Power buildings, or any coupled plant (heat pumps, water pumps...).
static func electrical_building_at(model: WorldModel, pos: Vector2i) -> bool:
	var id: String = model.building_tiles.get(pos, "")
	if id == "":
		return false
	var def := BuildingDefs.get_def(model.buildings[id]["kind"])
	return def.get("network", "") == "power" or def.get("device", "") != ""


## Does the building on `building_pos` take its (single) service
## connection from the cable at `cable_pos`? Grid connections tap
## everywhere; every other building only at its sorted-first tile
## (mirrors PowerTopology).
static func building_taps_here(model: WorldModel, building_pos: Vector2i,
		cable_pos: Vector2i) -> bool:
	if not electrical_building_at(model, building_pos):
		return false
	var id: String = model.building_tiles.get(building_pos, "")
	return PowerTopology.connection_tiles(model, id, model.cables) \
		.has(cable_pos)


## Single-tap check for heat/water service stubs — pipes tap a building
## at ONE tile too (PowerTopology.connection_tiles is layer-agnostic).
static func network_taps_here(model: WorldModel, building_pos: Vector2i,
		network: String, pipe_pos: Vector2i) -> bool:
	if not network_building_at(model, building_pos, network):
		return false
	var id: String = model.building_tiles.get(building_pos, "")
	var layer: Dictionary = model.heat_pipes if network == "heat" \
		else model.water_pipes
	return PowerTopology.connection_tiles(model, id, layer,
		"pumping_station" if network == "water" else "").has(pipe_pos)


static func buried_building_target(model: WorldModel, pos: Vector2i,
		network: String) -> bool:
	if network == "power":
		return electrical_building_at(model, pos)
	return network_building_at(model, pos, network)


# ─── roads ───

## N/E/S/W join mask — roads only join on the same plateau (a step is a
## wall, not a ramp).
static func road_mask(model: WorldModel, pos: Vector2i) -> int:
	var mask := 0
	var height := model.terrain.height(pos)
	for i in 4:
		var n: Vector2i = pos + DIRECTIONS[i]
		if model.roads.has(n) and model.terrain.height(n) == height:
			mask |= 1 << i
	return mask


## mask bits: 1=N 2=E 4=S 8=W. Native orientations read off the raw GLBs
## with N/E marker posts (--roadtest ..._native.png): straight runs E-W,
## end opens W, bend connects N+E, intersection is the E-W bar with the
## stem S. Godot +yaw is CCW from above: E→N→W→S→E per 90°.
## (This table was fixed twice — 7b5b03a, a78c026 — hence the pin.)
static func road_piece(mask: int) -> Array:
	match mask:
		0: return ["road-end-round", 90]
		1: return ["road-end", 270]
		2: return ["road-end", 180]
		4: return ["road-end", 90]
		8: return ["road-end", 0]
		5: return ["road-straight", 90]
		10: return ["road-straight", 0]
		3: return ["road-bend", 180]
		9: return ["road-bend", 270]
		12: return ["road-bend", 0]
		6: return ["road-bend", 90]
		14: return ["road-intersection", 0]
		7: return ["road-intersection", 90]
		11: return ["road-intersection", 180]
		13: return ["road-intersection", 270]
		_: return ["road-crossroad", 0]


# ─── cables ───

## Everything the cable renderer needs to decide for one tile:
## kind, linked neighbor directions WITH their kinds (the neighbor KIND
## must ride the cache key — an overhead pole becomes a Kabelendmast when
## its neighbor turns buried, regression 167a60f), the single service-tap
## directions, and the termination direction (-1 = plain pole).
static func cable_spec(model: WorldModel, pos: Vector2i) -> Dictionary:
	var kind := int(model.cables.get(pos, BuildingDefs.LINE_OVERHEAD))
	var links: Array[Dictionary] = []
	var taps: Array[int] = []
	for i in 4:
		var d := DIRECTIONS[i]
		if model.cables.has(pos + d) \
				and PowerTopology.cable_linked(model.cables, pos, pos + d):
			links.append({"dir": i, "kind": int(model.cables.get(pos + d, 0))})
		elif building_taps_here(model, pos + d, pos):
			# service drop ONLY at the building's single chosen tap tile
			taps.append(i)
	var termination := -1
	if kind == BuildingDefs.LINE_OVERHEAD:
		for link: Dictionary in links:
			if int(link["kind"]) == BuildingDefs.LINE_UNDERGROUND:
				termination = int(link["dir"])
				break
	return {"kind": kind, "links": links, "taps": taps,
		"termination": termination}


## The dirty-tile fast path compares this key — everything that changes
## the tile's look must ride it (kind, links incl. neighbor kinds, taps,
## termination, road paving, terrain heights).
static func cable_cache_key(spec: Dictionary, on_road: bool,
		terrain_fp: String) -> String:
	return "%s|r%s@%s" % [spec, on_road, terrain_fp]


# ─── buried lines (power/heat/water share the renderer) ───

## {on_road, links: [dir indices], risers: [dir indices]} — under a road
## the line compresses to a manhole plate; otherwise trench strips toward
## linked neighbors and a riser box where it enters a tapped building.
static func buried_spec(model: WorldModel, pos: Vector2i,
		layer: Dictionary, network: String) -> Dictionary:
	var links: Array[int] = []
	var risers: Array[int] = []
	for i in 4:
		var d := DIRECTIONS[i]
		if layer.has(pos + d) \
				and PowerTopology.cable_linked(layer, pos, pos + d):
			links.append(i)
		elif buried_building_target(model, pos + d, network) \
				and (building_taps_here(model, pos + d, pos)
					if network == "power"
					else network_taps_here(model, pos + d, network, pos)):
			risers.append(i)
	return {"on_road": model.roads.has(pos), "links": links, "risers": risers}


# ─── surface pipes (heat double-run / water main share the decisions) ───

## Same shape as cable_spec minus termination: linked directions + the
## single-tap building directions for a pipe layer. A neighbor tile that
## HAS a pipe but is not linked (parallel run) is neither — the map must
## show what the solver sees.
static func pipe_spec(model: WorldModel, pos: Vector2i, layer: Dictionary,
		network: String) -> Dictionary:
	var kind := int(layer.get(pos, BuildingDefs.LINE_OVERHEAD))
	var links: Array[int] = []
	var taps: Array[int] = []
	for i in 4:
		var d := DIRECTIONS[i]
		if layer.has(pos + d) \
				and PowerTopology.cable_linked(layer, pos, pos + d):
			links.append(i)
		elif network_taps_here(model, pos + d, network, pos):
			taps.append(i)
	return {"kind": kind, "links": links, "taps": taps}


# ─── diagonal streets ───
#
# A 4-connected raster cannot express a diagonal street: consecutive tiles
# share an EDGE, so the road enters and leaves through edge midpoints and
# must turn 90° inside every tile — which is exactly what `road-bend`
# draws, and why a 45° street renders as a sawtooth. Measured on the real
# Heidelberg import, bend share is set by the street's ANGLE alone and is
# scale-invariant: 45° is 100 % corners at any tile size, so no amount of
# extra resolution fixes it.
#
# The fix is to stop drawing those tiles individually. A maximal run of
# consecutive BEND tiles IS a diagonal street, and the renderer replaces it
# with one straight band of road-straight pieces rotated to the run's angle
# — same art, correct direction. The model is untouched: roads stay
# 4-connected, so topology, lot_buildable and every gameplay rule are
# unaffected. This is purely what the eye sees.

## Fewest consecutive bends worth straightening. A genuine single corner is
## a corner; four in a row is a staircase pretending to be a street.
const DIAGONAL_MIN_TILES := 3


static func road_links(roads: Dictionary, pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
			Vector2i(0, 1), Vector2i(0, -1)]:
		if roads.has(pos + offset):
			out.append(offset)
	return out


## Exactly two road neighbours, perpendicular to each other.
static func is_bend(roads: Dictionary, pos: Vector2i) -> bool:
	var links := road_links(roads, pos)
	return links.size() == 2 and links[0] != -links[1]


## Maximal staircase runs, each returned as an ORDERED path of tiles.
## A run qualifies when it is a simple path of bend tiles, at least
## `min_tiles` long, and MONOTONE — every x step the same sign and every y
## step the same sign. Monotonicity is what separates a diagonal street
## from a zigzag that doubles back on itself; a band drawn along the latter
## would cut the corner and miss its own tiles.
static func diagonal_runs(roads: Dictionary,
		min_tiles: int = DIAGONAL_MIN_TILES) -> Array:
	var runs: Array = []
	var seen := {}
	for start: Vector2i in roads:
		if seen.has(start) or not _is_through(roads, start):
			continue
		# The component is every THROUGH tile (degree 2, bend or straight)
		# reachable from here. Restricting it to bends only caught pure 45°
		# staircases and left every medium-angle street — those jog with
		# straights between their corners, which is most of a real city.
		var component := {start: true}
		var stack: Array[Vector2i] = [start]
		seen[start] = true
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			for offset: Vector2i in road_links(roads, cur):
				var q: Vector2i = cur + offset
				if not component.has(q) and _is_through(roads, q):
					component[q] = true
					seen[q] = true
					stack.append(q)
		if component.size() < min_tiles:
			continue
		var path := _bend_path(roads, component)
		if path.size() < min_tiles:
			continue
		# CUT the chain into maximal straight-ish diagonal pieces rather
		# than judging it whole: a through-chain runs from junction to
		# junction and a real street bends along the way, so testing the
		# whole thing for straightness rejected nearly all of them.
		var i := 0
		while i + min_tiles <= path.size():
			var last_good := -1
			var j := i + min_tiles - 1
			while j < path.size():
				var candidate: Array = path.slice(i, j + 1)
				if not (_is_monotone(candidate) and _hugs_line(candidate)):
					break
				last_good = j
				j += 1
			if last_good < 0:
				i += 1
				continue
			var piece: Array = path.slice(i, last_good + 1)
			var corners := 0
			for pos: Vector2i in piece:
				if is_bend(roads, pos):
					corners += 1
			# two corners minimum: one jog is a corner, not a diagonal
			if corners >= 2:
				runs.append(piece)
			i = last_good + 1
	return runs


## Exactly two road neighbours — a tile the street passes THROUGH, whether
## it turns there or not.
static func _is_through(roads: Dictionary, pos: Vector2i) -> bool:
	return road_links(roads, pos).size() == 2


## Does every tile sit within half a tile of the straight line from the
## first to the last? A raster of a straight street always does; a curving
## one does not, and a band drawn across it would cut the corner and leave
## its own tiles uncovered.
static func _hugs_line(path: Array) -> bool:
	var a := Vector2(path[0])
	var b := Vector2(path[path.size() - 1])
	var span := a.distance_to(b)
	if span < 1.0:
		return false
	for pos: Vector2i in path:
		if absf((b - a).cross(Vector2(pos) - a)) / span > 0.75:
			return false
	return true


## Order a component of bend tiles into a path, walking from an end. A
## component that is not a simple path (a junction of staircases, a loop)
## comes back short and is skipped by the caller.
static func _bend_path(roads: Dictionary, component: Dictionary) -> Array:
	var ends: Array[Vector2i] = []
	for pos: Vector2i in component:
		var inside := 0
		for offset: Vector2i in road_links(roads, pos):
			if component.has(pos + offset):
				inside += 1
		if inside == 1:
			ends.append(pos)
		elif inside > 2:
			return []          # a branch: not one street
	if ends.size() != 2:
		return []              # a loop, or an isolated tile
	ends.sort()                # deterministic: lowest tile starts the walk
	var path: Array[Vector2i] = [ends[0]]
	var previous := Vector2i(2147483647, 2147483647)
	var current: Vector2i = ends[0]
	while path.size() <= component.size():
		var stepped := false
		for offset: Vector2i in road_links(roads, current):
			var q: Vector2i = current + offset
			if q != previous and component.has(q):
				previous = current
				current = q
				path.append(current)
				stepped = true
				break
		if not stepped:
			break
	return path if path.size() == component.size() else []


static func _is_monotone(path: Array) -> bool:
	var sx := 0
	var sy := 0
	for i in path.size() - 1:
		var step: Vector2i = path[i + 1] - path[i]
		if step.x != 0:
			if sx != 0 and signi(step.x) != sx:
				return false
			sx = signi(step.x)
		if step.y != 0:
			if sy != 0 and signi(step.y) != sy:
				return false
			sy = signi(step.y)
	return sx != 0 and sy != 0   # a straight line is not a diagonal
