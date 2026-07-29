extends GdUnitTestSuite
## Buried lines: under roads yes, under buildings never, shared street
## cross-sections, road paving over buried-only tiles, and network
## continuity across a road crossing.

const B := BuildingDefs.LINE_UNDERGROUND
const S := BuildingDefs.LINE_OVERHEAD


func test_buried_under_road_surface_not() -> void:
	var model := WorldModel.new()
	model.set_road(Vector2i(5, 5))
	assert_bool(model.set_cable(Vector2i(5, 5), S)).is_false()
	assert_bool(model.set_heat_pipe(Vector2i(5, 5), S)).is_false()
	assert_bool(model.set_water_pipe(Vector2i(5, 5), S)).is_false()
	assert_bool(model.set_water_pipe(Vector2i(5, 5), B)).is_true()
	assert_bool(model.set_heat_pipe(Vector2i(5, 5), B)).is_true()
	assert_bool(model.set_cable(Vector2i(5, 5), B)).is_true()


func test_nothing_under_houses_or_buildings() -> void:
	var model := WorldModel.new()
	model.set_road(Vector2i(1, 0))
	model.set_zone(Vector2i(1, 1))
	model.spawn_house(Vector2i(1, 1))
	model.place_building("substation", Vector2i(4, 4))
	for pos: Vector2i in [Vector2i(1, 1), Vector2i(4, 4)]:
		assert_bool(model.set_cable(pos, B)).is_false()
		assert_bool(model.set_heat_pipe(pos, B)).is_false()
		assert_bool(model.set_water_pipe(pos, B)).is_false()


func test_shared_street_cross_section() -> void:
	var model := WorldModel.new()
	# three buried networks share one open-ground tile
	assert_bool(model.set_cable(Vector2i(7, 7), B)).is_true()
	assert_bool(model.set_heat_pipe(Vector2i(7, 7), B)).is_true()
	assert_bool(model.set_water_pipe(Vector2i(7, 7), B)).is_true()
	# but a surface line refuses a tile with any other network on it
	assert_bool(model.set_cable(Vector2i(8, 7), S)).is_true()
	assert_bool(model.set_heat_pipe(Vector2i(8, 7), B)).is_false()
	assert_bool(model.set_heat_pipe(Vector2i(9, 7), S)).is_true()
	assert_bool(model.set_water_pipe(Vector2i(9, 7), B)).is_false()


func test_road_paves_over_buried_only() -> void:
	var model := WorldModel.new()
	model.set_water_pipe(Vector2i(3, 3), B)
	assert_bool(model.set_road(Vector2i(3, 3))).is_true()
	model.set_heat_pipe(Vector2i(4, 3), S)
	assert_bool(model.set_road(Vector2i(4, 3))).is_false()


func test_no_zoning_or_houses_over_lines() -> void:
	var model := WorldModel.new()
	model.set_water_pipe(Vector2i(2, 2), B)
	assert_bool(model.set_zone(Vector2i(2, 2))).is_false()
	model.set_heat_pipe(Vector2i(3, 2), S)
	assert_bool(model.set_zone(Vector2i(3, 2))).is_false()


func test_water_network_continuous_under_road() -> void:
	var model := WorldModel.new()
	model.place_building("water_tower", Vector2i(0, 5))
	model.set_water_pipe(Vector2i(1, 5), S)
	model.set_water_pipe(Vector2i(2, 5), B)   # dives under the street
	model.set_road(Vector2i(2, 5))
	model.set_water_pipe(Vector2i(3, 5), S)
	model.place_building("water_station", Vector2i(4, 5))
	var topo := WaterTopology.build(model, {})
	assert_bool(topo.doc.is_empty()).is_false()
	assert_bool(bool(topo.connected["water_station_2"])).is_true()


func test_power_continuous_under_road_with_kind_split() -> void:
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 4))
	model.set_cable(Vector2i(2, 5), S)
	model.set_cable(Vector2i(3, 5), B)
	model.set_road(Vector2i(3, 5))
	model.set_cable(Vector2i(4, 5), S)
	model.place_building("substation", Vector2i(5, 5))
	var topo := PowerTopology.build(model, {})
	assert_bool(bool(topo.connected["substation_2"])).is_true()