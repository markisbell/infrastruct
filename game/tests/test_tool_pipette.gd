extends GdUnitTestSuite
## The pipette's world→tool mapping. Every case here is a promise to the
## player that pointing at a thing gives back the tool that made it —
## including the VARIANT, which is the half that is easy to get wrong and
## impossible to notice (a buried run picked up as a surface run builds
## the wrong thing at a different price).


func _model() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)  # flat, no water
	return model


func test_empty_tile_picks_up_nothing() -> void:
	assert_bool(ToolPipette.sample(_model(), Vector2i(4, 4)).is_empty()).is_true()


func test_line_kinds_round_trip_to_their_own_tools() -> void:
	var model := _model()
	model.set_cable(Vector2i(1, 0), BuildingDefs.LINE_OVERHEAD)
	model.set_cable(Vector2i(2, 0), BuildingDefs.LINE_UNDERGROUND)
	model.set_heat_pipe(Vector2i(3, 0), BuildingDefs.LINE_OVERHEAD)
	model.set_heat_pipe(Vector2i(4, 0), BuildingDefs.LINE_UNDERGROUND)
	model.set_water_pipe(Vector2i(5, 0), BuildingDefs.LINE_OVERHEAD)
	model.set_water_pipe(Vector2i(6, 0), BuildingDefs.LINE_UNDERGROUND)
	var expected := {
		1: CityView.Tool.CABLE, 2: CityView.Tool.UCABLE,
		3: CityView.Tool.PIPE, 4: CityView.Tool.BURIED_PIPE,
		5: CityView.Tool.WATER_PIPE, 6: CityView.Tool.BURIED_WATER,
	}
	for x: int in expected:
		assert_int(int(ToolPipette.sample(model, Vector2i(x, 0))["tool"])) \
			.override_failure_message("wrong tool at x=%d" % x) \
			.is_equal(expected[x])


func test_building_carries_its_rotation_and_flip() -> void:
	var model := _model()
	model.place_building("solar_park", Vector2i(20, 20), 2, {}, true)
	# every tile of the 2x2 footprint answers identically
	for tile: Vector2i in [Vector2i(20, 20), Vector2i(21, 20),
			Vector2i(20, 21), Vector2i(21, 21)]:
		var picked := ToolPipette.sample(model, tile)
		assert_int(int(picked["tool"])).is_equal(CityView.Tool.SOLAR)
		assert_int(int(picked["rot"])).is_equal(2)
		assert_bool(bool(picked["flip"])).is_true()


func test_substation_sizes_do_not_collapse_into_each_other() -> void:
	# the two substations differ only in rating — exactly the pair a player
	# cannot tell apart on the map, so the pipette must not guess
	var model := _model()
	model.place_building("substation", Vector2i(2, 2), 0)
	model.place_building("substation_xl", Vector2i(8, 8), 0)
	assert_int(int(ToolPipette.sample(model, Vector2i(2, 2))["tool"])) \
		.is_equal(CityView.Tool.SUBSTATION)
	assert_int(int(ToolPipette.sample(model, Vector2i(8, 8))["tool"])) \
		.is_equal(CityView.Tool.SUBSTATION_XL)


func test_zoning_houses_and_commercial_answer_with_their_zone_tool() -> void:
	var model := _model()
	model.set_road(Vector2i(10, 9))
	model.set_zone(Vector2i(10, 10), WorldModel.ZONE_RESIDENTIAL)
	model.set_zone(Vector2i(11, 9), WorldModel.ZONE_COMMERCIAL)
	assert_int(int(ToolPipette.sample(model, Vector2i(10, 10))["tool"])) \
		.is_equal(CityView.Tool.ZONE)
	assert_int(int(ToolPipette.sample(model, Vector2i(11, 9))["tool"])) \
		.is_equal(CityView.Tool.ZONE_COMMERCIAL)
	# a grown house/lot answers with the paint that made its lot — "more of
	# this district" is what the player is pointing at
	assert_bool(model.spawn_house(Vector2i(10, 10))).is_true()
	assert_int(int(ToolPipette.sample(model, Vector2i(10, 10))["tool"])) \
		.is_equal(CityView.Tool.ZONE)
	assert_bool(model.spawn_commercial(Vector2i(11, 9),
		WorldModel.COMMERCIAL_MALL)).is_true()
	assert_int(int(ToolPipette.sample(model, Vector2i(11, 9))["tool"])) \
		.is_equal(CityView.Tool.ZONE_COMMERCIAL)


func test_road_answers_only_where_no_line_shares_the_tile() -> void:
	var model := _model()
	model.set_road(Vector2i(30, 30))
	assert_int(int(ToolPipette.sample(model, Vector2i(30, 30))["tool"])) \
		.is_equal(CityView.Tool.ROAD)
	# buried runs cross UNDER roads: the run is the thing you cannot see
	# and cannot re-pick any other way, so it outranks the asphalt
	model.set_cable(Vector2i(30, 30), BuildingDefs.LINE_UNDERGROUND)
	assert_int(int(ToolPipette.sample(model, Vector2i(30, 30))["tool"])) \
		.is_equal(CityView.Tool.UCABLE)


func test_building_outranks_everything_under_it() -> void:
	var model := _model()
	model.set_zone(Vector2i(40, 40), WorldModel.ZONE_RESIDENTIAL)
	model.place_building("battery", Vector2i(40, 40), 0)
	assert_int(int(ToolPipette.sample(model, Vector2i(40, 40))["tool"])) \
		.is_equal(CityView.Tool.BATTERY)
