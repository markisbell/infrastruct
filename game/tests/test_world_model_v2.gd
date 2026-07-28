extends GdUnitTestSuite
## World model v2: occupancy rules, footprints, v2 roundtrip, v1 migration.


func test_occupancy_rules() -> void:
	var model := WorldModel.new()
	assert_bool(model.set_road(Vector2i(0, 0))).is_true()
	assert_bool(model.set_cable(Vector2i(0, 0), 1)).is_false()  # road blocks cable
	assert_bool(model.set_zone(Vector2i(1, 0))).is_true()
	assert_bool(model.spawn_house(Vector2i(1, 0))).is_true()    # zoned + road-adjacent
	assert_bool(model.spawn_house(Vector2i(5, 5))).is_false()   # not zoned
	model.set_zone(Vector2i(9, 9))
	assert_bool(model.spawn_house(Vector2i(9, 9))).is_false()   # zoned but no road


func test_building_footprint_placement() -> void:
	var model := WorldModel.new()
	var id := model.place_building("gas_plant", Vector2i(4, 4))  # 2x2
	assert_str(id).is_not_empty()
	assert_bool(model.is_tile_free(Vector2i(5, 5))).is_false()
	assert_bool(model.can_place_building("battery", Vector2i(5, 5))).is_false()
	assert_str(model.place_building("battery", Vector2i(4, 5))).is_empty()  # overlap
	model.remove_building(id)
	assert_bool(model.is_tile_free(Vector2i(5, 5))).is_true()


func test_v2_roundtrip() -> void:
	var model := WorldModel.new()
	model.set_road(Vector2i(0, 0))
	model.set_zone(Vector2i(1, 0))
	model.spawn_house(Vector2i(1, 0))
	model.set_cable(Vector2i(3, 3), 1)
	model.place_building("substation", Vector2i(4, 3))
	var rotated_id := model.place_building("gas_plant", Vector2i(8, 8), 3)
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.equals(model)).is_true()
	assert_int(restored.buildings[rotated_id]["rot"]).is_equal(3)
	# derived index rebuilt on load
	assert_bool(restored.building_tiles.has(Vector2i(4, 3))).is_true()
	# building ids keep counting after a roundtrip (no id reuse)
	restored.place_building("battery", Vector2i(10, 10))
	assert_int(restored.next_building_id).is_equal(model.next_building_id + 1)


func test_v1_save_migration() -> void:
	var v1_json := JSON.stringify({"version": 1, "cables": {"2,3": 1}})
	var model := WorldModel.from_json(v1_json)
	assert_bool(model.has_cable(Vector2i(2, 3))).is_true()
	assert_int(model.houses.size()).is_equal(0)


func test_spawn_candidates_deterministic_order() -> void:
	var model := WorldModel.new()
	model.set_road(Vector2i(0, 0))
	model.set_road(Vector2i(1, 0))
	model.set_zone(Vector2i(0, 1))
	model.set_zone(Vector2i(1, 1))
	var a := model.spawn_candidates(Vector2i(0, 0), 10)
	var b := model.spawn_candidates(Vector2i(0, 0), 10)
	assert_array(a).is_equal(b)
	assert_int(a.size()).is_equal(2)
