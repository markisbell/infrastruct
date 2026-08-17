extends GdUnitTestSuite
## The spline street renderer's pure logic: the clip that ties way geometry
## to the road raster, the raster walk that MUST match the paver's, and the
## stored-way serialization. The ribbons themselves are visual (headless
## skips them); everything decidable without a window is pinned here.


func test_raster_walk_matches_the_paver_exactly() -> void:
	# the paver decides which tiles exist; the clip decides which ribbons
	# live. If the two ever rasterize a segment differently, a street can
	# be paved but not drawn — or drawn where nothing was paved.
	var cases: Array = [
		[Vector2i(0, 0), Vector2i(9, 3)],
		[Vector2i(0, 0), Vector2i(3, 9)],
		[Vector2i(5, 5), Vector2i(5, 5)],
		[Vector2i(9, 3), Vector2i(0, 0)],
		[Vector2i(7, 2), Vector2i(-4, 11)],
		[Vector2i(0, 0), Vector2i(12, 12)],
	]
	for case: Array in cases:
		assert_array(StreetSplines.raster_line(case[0], case[1])) \
			.override_failure_message("raster diverged from paved_line on %s" % [case]) \
			.is_equal(Scenarios.paved_line(case[0], case[1]))


func _paved(way: Array) -> Dictionary:
	var roads := {}
	for i in way.size() - 1:
		for tile: Vector2i in Scenarios.paved_line(way[i], way[i + 1]):
			roads[tile] = true
	return roads


func test_a_fully_paved_way_is_one_ribbon() -> void:
	var way: Array[Vector2i] = [Vector2i(0, 0), Vector2i(6, 2), Vector2i(12, 2)]
	var runs := StreetSplines.clip_way(way, _paved(way))
	assert_int(runs.size()).is_equal(1)
	assert_array(runs[0]).is_equal([Vector2i(0, 0), Vector2i(6, 2), Vector2i(12, 2)])


func test_a_bulldozed_tile_splits_the_ribbon() -> void:
	# the player takes one tile out of the street: the ribbon must split at
	# that segment, not vanish and not bridge the gap
	var way: Array[Vector2i] = [Vector2i(0, 0), Vector2i(6, 0), Vector2i(12, 0),
		Vector2i(18, 0)]
	var roads := _paved(way)
	roads.erase(Vector2i(9, 0))    # bulldozer, mid second segment
	var runs := StreetSplines.clip_way(way, roads)
	assert_int(runs.size()).is_equal(2)
	assert_array(runs[0]).is_equal([Vector2i(0, 0), Vector2i(6, 0)])
	assert_array(runs[1]).is_equal([Vector2i(12, 0), Vector2i(18, 0)])


func test_an_unpaved_way_draws_nothing() -> void:
	var way: Array[Vector2i] = [Vector2i(0, 0), Vector2i(9, 3)]
	assert_array(StreetSplines.clip_way(way, {})).is_empty()


func test_short_fragments_are_left_to_the_tile_art() -> void:
	# a surviving stub of less than ~2.5 tiles reads as a pointed shard
	# poking out of the pieced street — the pieces draw it better
	var way: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	var runs := StreetSplines.clip_way(way, _paved(way))
	assert_array(runs).is_empty()


func test_subdivision_bounds_every_span() -> void:
	# long segments must resample the ground often enough to FOLLOW terrain
	# steps instead of bridging them
	var run: Array[Vector2i] = [Vector2i(0, 0), Vector2i(20, 0), Vector2i(20, 8)]
	var pts := StreetSplines.subdivide(run, 2.0)
	assert_that(pts[0]).is_equal(Vector2(0, 0))
	assert_that(pts[pts.size() - 1]).is_equal(Vector2(20, 8))
	for i in pts.size() - 1:
		assert_float((pts[i] as Vector2).distance_to(pts[i + 1])) \
			.is_less_equal(2.001)


func test_street_ways_survive_a_save_and_old_saves_load() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	var way: Array[Vector2i] = [Vector2i(3, 4), Vector2i(9, 6), Vector2i(9, 12)]
	model.street_ways.append(way)
	var restored := WorldModel.from_json(model.to_json())
	assert_int(restored.street_ways.size()).is_equal(1)
	assert_array(restored.street_ways[0]).is_equal(way)
	assert_bool(model.equals(restored)).is_true()
	# additive: a save written before street ways existed still loads
	var old_save: Dictionary = JSON.parse_string(model.to_json())
	old_save.erase("street_ways")
	assert_int(WorldModel.from_json(JSON.stringify(old_save)).street_ways.size()) \
		.is_equal(0)
