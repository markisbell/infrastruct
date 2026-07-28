extends GdUnitTestSuite
## Terrain (v5): determinism, flat default, overrides, placement rules,
## serialization, and the water-junction elevation wiring.


func test_seed_zero_is_flat_everywhere() -> void:
	var terrain := Terrain.new(0)
	for pos: Vector2i in [Vector2i(0, 0), Vector2i(128, 128), Vector2i(255, 255)]:
		assert_int(terrain.height(pos)).is_equal(0)


func test_same_seed_same_heights() -> void:
	var a := Terrain.new(19)
	var b := Terrain.new(19)
	var differs_from_flat := false
	for x in range(0, 256, 16):
		for y in range(0, 256, 16):
			var pos := Vector2i(x, y)
			assert_int(a.height(pos)).is_equal(b.height(pos))
			if a.height(pos) != 0:
				differs_from_flat = true
	assert_bool(differs_from_flat).is_true()


func test_overrides_win_and_serialize() -> void:
	var terrain := Terrain.new(19)
	terrain.force_height(Vector2i(4, 4), Vector2i(6, 6), 5)
	assert_int(terrain.height(Vector2i(5, 5))).is_equal(5)
	var restored := Terrain.deserialize(terrain.serialize())
	assert_bool(restored.equals(terrain)).is_true()
	assert_int(restored.height(Vector2i(5, 5))).is_equal(5)


func test_v5_model_roundtrip_keeps_terrain() -> void:
	var model := WorldModel.new()
	model.terrain.set_seed(19)
	model.terrain.force_height(Vector2i(2, 2), Vector2i(3, 3), 4)
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.equals(model)).is_true()
	assert_int(restored.terrain.height(Vector2i(2, 3))).is_equal(4)


func test_v4_save_loads_flat() -> void:
	var v4 := JSON.stringify({"version": 4, "cables": {}, "heat_pipes": {},
		"water_pipes": {"1,1": 1}, "roads": {}, "zoning": {}, "houses": {},
		"buildings": {}, "next_building_id": 1})
	var model := WorldModel.from_json(v4)
	assert_int(model.terrain.height(Vector2i(128, 128))).is_equal(0)
	assert_bool(model.water_pipes.has(Vector2i(1, 1))).is_true()


func test_buildings_need_level_ground() -> void:
	var model := WorldModel.new()
	model.terrain.force_height(Vector2i(5, 5), Vector2i(5, 9), 2)  # a ridge
	# 2x2 footprint straddles the ridge edge -> refused
	assert_bool(model.can_place_building("gas_plant", Vector2i(4, 4))).is_false()
	# fully on the plateau (needs 2x2 inside the ridge) -> widen it
	model.terrain.force_height(Vector2i(5, 5), Vector2i(8, 9), 2)
	assert_bool(model.can_place_building("gas_plant", Vector2i(5, 5))).is_true()


func test_house_needs_same_height_road() -> void:
	var model := WorldModel.new()
	model.terrain.force_height(Vector2i(3, 3), Vector2i(3, 3), 1)
	model.set_road(Vector2i(3, 3))       # road up on the ledge
	model.set_zone(Vector2i(3, 4))       # lot at the foot of the ledge
	assert_bool(model.spawn_house(Vector2i(3, 4))).is_false()
	model.set_road(Vector2i(2, 4))       # road on the lot's own level
	assert_bool(model.spawn_house(Vector2i(3, 4))).is_true()


func test_water_junction_elevation_from_terrain() -> void:
	var model := WorldModel.new()
	model.terrain.force_height(Vector2i(0, 4), Vector2i(2, 6), 3)  # 15 m hill
	model.place_building("water_tower", Vector2i(0, 5))
	for x in range(1, 6):
		model.set_water_pipe(Vector2i(x, 5), 1)
	model.place_building("water_station", Vector2i(6, 5))
	var topo := WaterTopology.build(model, {})
	var tower_node: String = topo.doc["devices"][0]["node"]
	for junction: Dictionary in topo.doc["native"]["network_structure"]["junctions"]:
		if str(junction["name"]) == tower_node:
			# base 300 + 3 levels x 5 m + default 25 m tower
			assert_float(float(junction["elevation_m"])).is_equal(340.0)
		elif str(junction["kind"]) == "consumer":
			assert_float(float(junction["elevation_m"])).is_equal(300.0)
