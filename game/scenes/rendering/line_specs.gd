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
