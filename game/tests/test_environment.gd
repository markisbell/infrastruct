extends GdUnitTestSuite
## Environment pass: rivers (derived water tiles), construction blocking,
## and the well-near-water yield bonus.


func test_seed_zero_has_no_water() -> void:
	var terrain := Terrain.new(0)
	for x in range(0, 256, 7):
		for y in range(0, 256, 7):
			assert_bool(terrain.is_water(Vector2i(x, y))) \
				.override_failure_message("water at %d,%d on seed 0" % [x, y]) \
				.is_false()


func test_rivers_exist_and_stay_in_valleys() -> void:
	var terrain := Terrain.new(19)  # the scenario terrain seed
	var water_tiles := 0
	for x in 256:
		for y in 256:
			var pos := Vector2i(x, y)
			if terrain.is_water(pos):
				water_tiles += 1
				assert_int(terrain.height(pos)) \
					.override_failure_message("water off-valley at %s" % pos) \
					.is_equal(0)
	assert_int(water_tiles).is_greater(50)  # seed 19 carries real rivers


func test_water_is_deterministic() -> void:
	var a := Terrain.new(19)
	var b := Terrain.new(19)
	for x in range(0, 256, 11):
		for y in range(0, 256, 11):
			assert_bool(a.is_water(Vector2i(x, y))) \
				.is_equal(b.is_water(Vector2i(x, y)))


func test_water_blocks_construction() -> void:
	var model := WorldModel.new()
	model.terrain.force_water(Vector2i(4, 4), Vector2i(6, 6))
	assert_bool(model.set_road(Vector2i(5, 5))).is_false()
	assert_bool(model.set_cable(Vector2i(5, 5), BuildingDefs.LINE_OVERHEAD)).is_false()
	assert_bool(model.set_cable(Vector2i(5, 5), BuildingDefs.LINE_UNDERGROUND)) \
		.is_false()  # no bridges, no crossings — buried included
	assert_bool(model.set_water_pipe(Vector2i(5, 5), 1)).is_false()
	assert_bool(model.set_zone(Vector2i(5, 5))).is_false()
	assert_str(model.place_building("substation", Vector2i(5, 5))).is_equal("")
	# dry land right next to the river is fine
	assert_bool(model.set_road(Vector2i(5, 7))).is_true()


func test_water_survives_save_roundtrip() -> void:
	var model := WorldModel.new()
	model.terrain.set_seed(19)
	model.terrain.force_water(Vector2i(1, 1), Vector2i(2, 2))
	model.terrain.force_water(Vector2i(9, 9), Vector2i(9, 9), false)
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.terrain.equals(model.terrain)).is_true()
	assert_bool(restored.terrain.is_water(Vector2i(1, 1))).is_true()


func test_well_near_river_yields_more() -> void:
	var model := WorldModel.new()
	# tower head + station + two wells: one at the river, one far away
	model.place_building("water_tower", Vector2i(0, 5))
	for x in range(1, 12):
		model.set_water_pipe(Vector2i(x, 5), 1)
	model.place_building("water_station", Vector2i(12, 5))
	model.place_building("well", Vector2i(3, 6))    # touches pipe via (3,5)
	model.place_building("well", Vector2i(9, 6))
	model.terrain.force_water(Vector2i(3, 9), Vector2i(4, 9))  # 3 tiles from well 1
	var topo := WaterTopology.build(model, {})
	var yields := {}
	for device: Dictionary in topo.doc["devices"]:
		if device["kind"] == "well":
			yields[device["id"]] = float(device["params"]["rated_m3_h"])
	var well_ids := model.buildings_of_kind("well")
	well_ids.sort()
	assert_float(yields[well_ids[0]]).is_equal_approx(22.5, 0.01)  # 15 x 1.5
	assert_float(yields[well_ids[1]]).is_equal_approx(15.0, 0.01)
