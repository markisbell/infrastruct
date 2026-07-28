extends GdUnitTestSuite
## World model v4: water pipe layer occupancy, params overrides, v4 roundtrip,
## and the WaterTopology extraction (head choice, elevation folding, zones).


func test_water_pipe_occupancy() -> void:
	var model := WorldModel.new()
	assert_bool(model.set_water_pipe(Vector2i(0, 0), 1)).is_true()
	assert_bool(model.set_cable(Vector2i(0, 0), 1)).is_false()      # water blocks cable
	assert_bool(model.set_heat_pipe(Vector2i(0, 0), 1)).is_false()  # and heat pipe
	assert_bool(model.set_road(Vector2i(0, 0))).is_false()          # and road
	model.set_road(Vector2i(1, 0))
	assert_bool(model.set_water_pipe(Vector2i(1, 0), 1)).is_false() # road blocks water
	model.set_cable(Vector2i(2, 0), 1)
	assert_bool(model.set_water_pipe(Vector2i(2, 0), 1)).is_false() # cable blocks water
	model.remove_water_pipe(Vector2i(0, 0))
	assert_bool(model.is_tile_free(Vector2i(0, 0))).is_true()


func test_v4_roundtrip_with_params_override() -> void:
	var model := WorldModel.new()
	model.set_water_pipe(Vector2i(3, 3), 1)
	var tall := model.place_building("water_tower", Vector2i(5, 5), 0,
		{"tower_height_m": 40.0})
	model.place_building("well", Vector2i(7, 7))
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(restored.equals(model)).is_true()
	assert_bool(restored.water_pipes.has(Vector2i(3, 3))).is_true()
	assert_float(float(restored.building_params(tall)["tower_height_m"])).is_equal(40.0)
	# catalog params still fill the gaps around the override
	assert_float(float(restored.building_params(tall)["volume_m3"])).is_equal(200.0)


func test_v3_save_loads_without_water() -> void:
	var v3 := JSON.stringify({"version": 3, "cables": {"1,1": 1},
		"heat_pipes": {"2,2": 1}, "roads": {}, "zoning": {}, "houses": {},
		"buildings": {}, "next_building_id": 1})
	var model := WorldModel.from_json(v3)
	assert_int(model.water_pipes.size()).is_equal(0)
	assert_bool(model.heat_pipes.has(Vector2i(2, 2))).is_true()


# ─── WaterTopology extraction ───

## Straight main: tower — pipe — station, two houses in range.
func _tiny_water_city() -> WorldModel:
	var model := WorldModel.new()
	model.place_building("water_tower", Vector2i(0, 5))       # 1x1 at (0,5)
	for x in range(1, 6):
		model.set_water_pipe(Vector2i(x, 5), 1)
	model.place_building("water_station", Vector2i(6, 5))     # 1x1 at (6,5)
	model.set_road(Vector2i(6, 7))
	model.set_zone(Vector2i(5, 7))
	model.set_zone(Vector2i(7, 7))
	model.spawn_house(Vector2i(5, 7))
	model.spawn_house(Vector2i(7, 7))
	return model


func test_water_topology_doc_shape() -> void:
	var topo := WaterTopology.build(_tiny_water_city(), {})
	assert_bool(topo.has_source).is_true()
	assert_str(str(topo.doc["network_kind"])).is_equal("water")
	# the tower is the head: first device, ext_grid supply at its junction
	var devices: Array = topo.doc["devices"]
	assert_str(str(devices[0]["kind"])).is_equal("water_tower")
	var supplies: Array = topo.doc["native"]["supply"]["supplies"]
	assert_int(supplies.size()).is_equal(1)
	assert_str(str(supplies[0]["node"])).is_equal(str(devices[0]["node"]))
	assert_float(float(supplies[0]["p_bar"])).is_equal(0.5)
	# one zone with both houses
	assert_int(topo.zones_info.size()).is_equal(1)
	var zone_id: String = topo.zones_info.keys()[0]
	assert_int(int(topo.zones_info[zone_id]["houses"])).is_equal(2)
	# zones map by consumer NAME (heat convention)
	assert_str(str(topo.doc["zones"][0]["consumer"])).is_equal(zone_id)


func test_water_tower_elevation_folding() -> void:
	var model := _tiny_water_city()
	var topo := WaterTopology.build(model, {})
	var junctions: Array = topo.doc["native"]["network_structure"]["junctions"]
	var tower_node: String = topo.doc["devices"][0]["node"]
	for junction: Dictionary in junctions:
		if str(junction["name"]) == tower_node:
			# base 300 + default tower height 25
			assert_float(float(junction["elevation_m"])).is_equal(325.0)
		else:
			assert_float(float(junction["elevation_m"])).is_equal(300.0)


func test_pump_head_when_towerless() -> void:
	var model := WorldModel.new()
	model.place_building("pumping_station", Vector2i(0, 5))   # 2x2
	for x in range(2, 6):
		model.set_water_pipe(Vector2i(x, 5), 1)
	model.place_building("water_station", Vector2i(6, 5))
	var topo := WaterTopology.build(model, {})
	assert_str(str(topo.doc["devices"][0]["kind"])).is_equal("water_pump")
	var supplies: Array = topo.doc["native"]["supply"]["supplies"]
	assert_float(float(supplies[0]["p_bar"])).is_equal(4.0)


func test_disconnected_station_excluded() -> void:
	var model := _tiny_water_city()
	model.place_building("water_station", Vector2i(20, 20))   # no pipe to it
	var topo := WaterTopology.build(model, {})
	assert_int(topo.zones_info.size()).is_equal(1)
	assert_bool(bool(topo.connected["water_station_3"])).is_false()
