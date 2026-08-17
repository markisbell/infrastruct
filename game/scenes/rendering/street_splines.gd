class_name StreetSplines
extends Node3D
## Spline street renderer (2026-08-17, user-directed rebuild on the vendored
## road-generator addon). Organic streets — the OSM-shaped polylines stored
## in `WorldModel.street_ways` — draw as smooth ribbons that follow their
## REAL geometry instead of a staircase of tile pieces; player-drawn
## orthogonal roads keep the Kenney art, which renders them perfectly.
##
## PURELY VISUAL, like the diagonal bands this supersedes where it applies:
## roads stay 4-connected tiles and every gameplay rule reads the raster.
## The bridge between the two worlds is the CLIP: a way's ribbon exists
## exactly where its rasterized tiles are still roads, so paving, the
## thinning passes and the player's bulldozer all reshape the ribbons
## without ever touching the stored geometry. Tiles a ribbon covers are
## reported in `covered` and the tile renderer skips their pieces.

const LANE_WIDTH := 0.21          # our tile = 1.0 unit = 25 m; two lanes + …
const SHOULDER_WIDTH := 0.1       # …sidewalk-ish shoulders ≈ a Kenney road
const GUTTER := Vector2(0.04, -0.015)
const DENSITY := 1.5              # mesh loop spacing [units]
const DECK_LIFT := 0.04           # ribbon rides just above the ground/pieces
const SUBDIVIDE_TILES := 2.0      # max segment span before a ground resample
const TEXTURE := "res://assets/road_texture_flat.png"

var covered := {}                 # Vector2i -> true (tiles ribbons draw)
var _manager: RoadManager
var _material: StandardMaterial3D
var _built := {}                  # way index -> {"node": RoadContainer, "key": int}
var _last_roads_hash := 0
var _last_ways_size := -1


## Rebuild whatever changed. Cheap when nothing did: the road raster's hash
## gates the whole pass, and per-way clip keys gate each container.
## Returns true when the COVERED set changed — the caller must then run a
## full piece re-orientation, because a clipped ribbon uncovers tiles far
## outside any dirty ring (the same contract the diagonal bands use).
func sync(model: WorldModel, ground: Callable) -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var roads_hash := model.roads.hash()
	if roads_hash == _last_roads_hash and model.street_ways.size() == _last_ways_size:
		return false
	_last_roads_hash = roads_hash
	_last_ways_size = model.street_ways.size()
	_ensure_scaffold()
	var covered_before := covered.hash()
	covered.clear()
	for idx in model.street_ways.size():
		var runs := clip_way(model.street_ways[idx], model.roads)
		var key := _runs_key(runs)
		for run: Array in runs:
			for i in run.size() - 1:
				for tile: Vector2i in raster_line(run[i], run[i + 1]):
					covered[tile] = true
		var entry: Dictionary = _built.get(idx, {})
		if not entry.is_empty() and int(entry["key"]) == key:
			continue
		if not entry.is_empty():
			(entry["node"] as Node).queue_free()
			_built.erase(idx)
		if runs.is_empty():
			continue
		var holder := Node3D.new()
		_manager.add_child(holder)
		for run: Array in runs:
			_build_ribbon(holder, run, ground)
		_built[idx] = {"node": holder, "key": key}
	# ways can vanish wholesale (scenario reset to a smaller city)
	for idx: int in _built.keys():
		if idx >= model.street_ways.size():
			(_built[idx]["node"] as Node).queue_free()
			_built.erase(idx)
	return covered.hash() != covered_before


func reset() -> void:
	for idx: int in _built:
		(_built[idx]["node"] as Node).queue_free()
	_built.clear()
	covered.clear()
	_last_roads_hash = 0
	_last_ways_size = -1


## The live sub-polylines of one way: maximal vertex runs whose EVERY raster
## tile is still a road. Paving gaps, the thinning passes and the bulldozer
## all clip here — the stored way is never mutated.
static func clip_way(pts: Array, roads: Dictionary) -> Array:
	var runs: Array = []
	var current: Array[Vector2i] = []
	for i in pts.size() - 1:
		var a := Vector2i(pts[i])
		var b := Vector2i(pts[i + 1])
		var live := true
		for tile: Vector2i in raster_line(a, b):
			if not roads.has(tile):
				live = false
				break
		if live:
			if current.is_empty():
				current.append(a)
			current.append(b)
		else:
			if current.size() >= 2:
				runs.append(current)
			current = []
	if current.size() >= 2:
		runs.append(current)
	# a fragment shorter than a couple of tiles renders as a pointed shard
	# poking out of the tile art that covers the rest of its street — the
	# pieces draw those stretches better than a stub ribbon does
	var kept: Array = []
	for run: Array in runs:
		var length := 0.0
		for i in run.size() - 1:
			length += Vector2(run[i]).distance_to(Vector2(run[i + 1]))
		if length >= 2.5:
			kept.append(run)
	return kept


## MUST rasterize exactly like Scenarios.paved_line — the paver decides
## which tiles exist and the clip decides which ribbons live, and the two
## must never disagree about a segment's tiles (pinned by test).
static func raster_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [a]
	var steps: int = maxi(absi(b.x - a.x), absi(b.y - a.y))
	var prev := a
	for s in range(1, steps + 1):
		var cur := Vector2i(roundi(lerpf(a.x, b.x, float(s) / steps)),
			roundi(lerpf(a.y, b.y, float(s) / steps)))
		if cur == prev:
			continue
		if cur.x != prev.x and cur.y != prev.y:
			out.append(Vector2i(cur.x, prev.y))
		out.append(cur)
		prev = cur
	return out


## Extra samples along long segments so the ribbon FOLLOWS terrain steps
## instead of bridging them: no span longer than *max_tiles*.
static func subdivide(run: Array, max_tiles: float = SUBDIVIDE_TILES) -> Array:
	var out: Array = [Vector2(run[0])]
	for i in run.size() - 1:
		var a := Vector2(run[i])
		var b := Vector2(run[i + 1])
		var span := a.distance_to(b)
		var cuts := int(ceil(span / max_tiles))
		for s in range(1, cuts + 1):
			out.append(a.lerp(b, float(s) / cuts))
	return out


func _ensure_scaffold() -> void:
	if _manager != null:
		return
	_manager = RoadManager.new()
	add_child(_manager)
	_material = StandardMaterial3D.new()
	_material.albedo_texture = load(TEXTURE)
	_material.roughness = 1.0


func _build_ribbon(parent: Node3D, run: Array, ground: Callable) -> void:
	var pts := subdivide(run)
	var container := RoadContainer.new()
	parent.add_child(container)
	container.material_resource = _material
	container.density = DENSITY
	var rps: Array = []
	for i in pts.size():
		var p: Vector2 = pts[i]
		var rp := RoadPoint.new()
		container.add_child(rp)
		rp.lane_width = LANE_WIDTH
		rp.shoulder_width_l = SHOULDER_WIDTH
		rp.shoulder_width_r = SHOULDER_WIDTH
		rp.gutter_profile = GUTTER
		var tile := Vector2i(roundi(p.x), roundi(p.y))
		rp.position = Vector3(p.x + 0.5,
			float(ground.call(tile)) + DECK_LIFT, p.y + 0.5)
		rps.append(rp)
	for i in rps.size():
		var ahead: Vector3 = (rps[mini(i + 1, rps.size() - 1)] as RoadPoint).position
		var behind: Vector3 = (rps[maxi(i - 1, 0)] as RoadPoint).position
		var dir := ahead - behind
		dir.y = 0.0
		if dir.length() > 0.01:
			(rps[i] as RoadPoint).rotation.y = atan2(dir.x, dir.z)
		var mag := clampf(dir.length() * 0.25, 0.3, 1.2)
		(rps[i] as RoadPoint).prior_mag = mag
		(rps[i] as RoadPoint).next_mag = mag
	for i in rps.size() - 1:
		(rps[i] as RoadPoint).connect_roadpoint(
			RoadPoint.PointInit.NEXT, rps[i + 1], RoadPoint.PointInit.PRIOR)
	container.rebuild_segments(true)


static func _runs_key(runs: Array) -> int:
	var acc := 17
	for run: Array in runs:
		acc = acc * 31 + run.size()
		acc = acc * 31 + int((run[0] as Vector2i).x) * 257 \
			+ int((run[0] as Vector2i).y)
		var last := run[run.size() - 1] as Vector2i
		acc = acc * 31 + last.x * 257 + last.y
		for pos: Vector2i in run:
			acc = ((acc << 5) - acc + pos.x * 4099 + pos.y) & 0x7FFFFFFF
	return acc
