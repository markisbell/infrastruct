extends GdUnitTestSuite
## `WorldModel.street_ways` — the OSM-shaped centrelines the Heidelberg
## paver rasterized. No renderer consumes them today (the spline-ribbon
## experiment that did was retired after failing in play); they stay
## because they are REAL geometry the save already carries, and the natural
## host for future street features (names, way-following markings).


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
