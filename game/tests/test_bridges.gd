extends GdUnitTestSuite
## River bridges: a deck makes ONE water tile crossable by roads and every
## utility line, and by nothing else. Before these, water split a city into
## networks that could not be joined at all — Heidelberg needed two grid
## connections and simply had no heat or water on the north bank.


## A model with a river running along y = 4 (force_water is the test hook).
func _riverside() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)  # seed 0 = no derived water
	model.terrain.force_water(Vector2i(0, 4), Vector2i(20, 4))
	return model


func test_water_blocks_a_road_until_a_bridge_decks_it() -> void:
	var model := _riverside()
	var wet := Vector2i(6, 4)
	assert_bool(model.can_set_road(wet)).is_false()
	assert_bool(model.set_bridge(wet)).is_true()
	assert_bool(model.can_set_road(wet)) \
		.override_failure_message("a decked river tile still refused a road") \
		.is_true()
	assert_bool(model.set_road(wet)).is_true()


func test_every_utility_crosses_a_bridge_surface_and_buried() -> void:
	# the whole point: one deck carries the street cross-section, so power,
	# heat and water reach the far bank the way the road does
	var model := _riverside()
	var wet := Vector2i(7, 4)
	for kind: int in [BuildingDefs.LINE_OVERHEAD, BuildingDefs.LINE_UNDERGROUND]:
		assert_bool(model.can_set_cable(wet, kind)).is_false()
		assert_bool(model.can_set_heat_pipe(wet, kind)).is_false()
		assert_bool(model.can_set_water_pipe(wet, kind)).is_false()
	model.set_bridge(wet)
	assert_bool(model.can_set_cable(wet, BuildingDefs.LINE_OVERHEAD)).is_true()
	assert_bool(model.can_set_heat_pipe(wet, BuildingDefs.LINE_UNDERGROUND)).is_true()
	assert_bool(model.set_water_pipe(wet, BuildingDefs.LINE_UNDERGROUND)).is_true()


func test_a_deck_carries_infrastructure_never_land_uses() -> void:
	# a bridge is a street cross-section, not a plot: no zoning, no houses,
	# no building footprints, however decked the tile is
	var model := _riverside()
	var wet := Vector2i(8, 4)
	model.set_bridge(wet)
	assert_bool(model.can_set_zone(wet)) \
		.override_failure_message("zoning was painted onto a bridge").is_false()
	assert_bool(model.can_place_building("substation", wet)) \
		.override_failure_message("a building was placed on a bridge").is_false()
	assert_bool(model.spawn_house(wet)).is_false()


func test_a_bridge_only_goes_on_water_and_only_once() -> void:
	var model := _riverside()
	assert_bool(model.can_set_bridge(Vector2i(6, 9))) \
		.override_failure_message("a bridge was allowed on dry land").is_false()
	assert_bool(model.set_bridge(Vector2i(6, 4))).is_true()
	assert_bool(model.set_bridge(Vector2i(6, 4))) \
		.override_failure_message("a tile took a second deck").is_false()


func test_a_loaded_deck_cannot_be_pulled_out_from_under_its_traffic() -> void:
	var model := _riverside()
	var wet := Vector2i(9, 4)
	model.set_bridge(wet)
	model.set_road(wet)
	assert_bool(model.remove_bridge(wet)) \
		.override_failure_message("the deck went while the road stood on it") \
		.is_false()
	model.remove_road(wet)
	assert_bool(model.remove_bridge(wet)).is_true()
	assert_bool(model.can_set_road(wet)) \
		.override_failure_message("the river stayed crossable without a deck") \
		.is_false()


func test_bridges_survive_a_save_and_old_saves_still_load() -> void:
	var model := _riverside()
	model.set_bridge(Vector2i(5, 4))
	model.set_bridge(Vector2i(6, 4))
	model.set_road(Vector2i(6, 4))
	var restored := WorldModel.from_json(model.to_json())
	assert_int(restored.bridges.size()).is_equal(2)
	assert_bool(restored.bridges.has(Vector2i(5, 4))).is_true()
	assert_bool(model.equals(restored)).is_true()
	# additive key: a save written before bridges existed still loads
	var old_save: Dictionary = JSON.parse_string(model.to_json())
	old_save.erase("bridges")
	assert_int(WorldModel.from_json(JSON.stringify(old_save)).bridges.size()) \
		.is_equal(0)


func test_invariants_accept_a_bridged_crossing_and_catch_a_stranded_deck() -> void:
	var model := _riverside()
	var wet := Vector2i(10, 4)
	model.set_bridge(wet)
	model.set_road(wet)
	model.set_cable(wet, BuildingDefs.LINE_UNDERGROUND)
	assert_array(model.check_invariants()) \
		.override_failure_message("a legitimate crossing was reported broken") \
		.is_empty()
	# a deck that is not over water is a bookkeeping error
	model.bridges[Vector2i(10, 9)] = true
	assert_int(model.check_invariants().size()).is_greater(0)
