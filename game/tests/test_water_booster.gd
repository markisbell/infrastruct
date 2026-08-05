extends GdUnitTestSuite
## Water head/booster rules (Phase-7 refactor plan): head preference by
## kind then id, suction-faces-the-head direction, the bypassed-loop
## warning, and the two-tap allowance staying scoped to the water layer.


static func _base(head_kind: String, head_pos: Vector2i) -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building(head_kind, head_pos)
	return model


func test_head_preference_tower_over_well_over_pump() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	# all three source kinds on one main; tower must take the head even
	# though the well was placed first
	model.place_building("well", Vector2i(1, 1))
	for x in range(2, 12):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_tower", Vector2i(5, 0))
	model.place_building("water_station", Vector2i(12, 1))
	var topo := WaterTopology.build(model, {})
	var supply: Dictionary = topo.doc["native"]["supply"]["supplies"][0]
	var tower_id: String = model.buildings_of_kind("water_tower")[0]
	assert_str(supply["node"]).is_equal("wn_" + tower_id)
	assert_float(float(supply["p_bar"])).is_equal(0.5)  # elevation carries it
	# head device ordered FIRST (backend binds the ext_grid)
	assert_str(topo.doc["devices"][0]["id"]).is_equal(tower_id)


func test_headless_pump_is_pressurized_feed() -> void:
	var model := _base("pumping_station", Vector2i(0, 0))
	for x in range(2, 8):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_station", Vector2i(8, 1))
	var topo := WaterTopology.build(model, {})
	# a single-tap pump keeps its source-with-head duty: ext_grid at 4 bar
	assert_float(float(topo.doc["native"]["supply"]["supplies"][0]["p_bar"])) \
		.is_equal(4.0)
	assert_array(topo.doc["native"]["supply"]["stations"]).is_empty()


func test_booster_suction_faces_the_head() -> void:
	var model := _base("water_tower", Vector2i(1, 1))
	for x in range(2, 7):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("pumping_station", Vector2i(7, 0))  # bridges at (7,1)/(8,1)
	for x in range(9, 15):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_station", Vector2i(15, 1))
	var topo := WaterTopology.build(model, {})
	var pump_id: String = model.buildings_of_kind("pumping_station")[0]
	var station: Dictionary = topo.doc["native"]["supply"]["stations"][0]
	# suction node = the head-side tap; discharge = the far side (#dis)
	assert_str(station["from_node"]).is_equal("wn_" + pump_id)
	assert_str(station["to_node"]).is_equal("wn_" + pump_id + "#dis")
	assert_bool(topo.warnings.is_empty()).is_true()
	# the far station is reachable THROUGH the booster branch
	var st_id: String = model.buildings_of_kind("water_station")[0]
	assert_bool(topo.connected.get(st_id, false)).is_true()


func test_bypassed_booster_warns() -> void:
	# a ring main around the pump: both taps reachable without the branch
	var model := _base("water_tower", Vector2i(1, 1))
	for x in range(2, 7):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("pumping_station", Vector2i(7, 0))  # taps (6,1)+(9,1)
	for x in range(9, 14):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	# the bypass loop under the pump: down at x6, across y3, up at x9 —
	# joins both mains without touching the pump footprint (y0-1)
	for pos: Vector2i in [Vector2i(6, 2), Vector2i(6, 3), Vector2i(7, 3),
			Vector2i(8, 3), Vector2i(9, 3), Vector2i(9, 2)]:
		model.set_water_pipe(pos, BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_station", Vector2i(14, 1))
	var topo := WaterTopology.build(model, {})
	var pump_id: String = model.buildings_of_kind("pumping_station")[0]
	if topo.doc.is_empty():
		fail("bypass fixture no longer builds a solvable network")
		return
	var bypassed := false
	for warning: String in topo.warnings:
		if warning.contains("bypassed by its own main"):
			bypassed = true
	assert_bool(bypassed) \
		.override_failure_message("expected bypass warning for " + pump_id
			+ ", got " + str(topo.warnings)).is_true()


func test_pump_two_tap_allowance_is_water_layer_only() -> void:
	# the same pump taps its CABLE exactly once (pair_kind scoping)
	var model := _base("water_tower", Vector2i(1, 1))
	model.place_building("pumping_station", Vector2i(7, 0))
	for x in range(2, 12):
		model.set_cable(Vector2i(x, 2), BuildingDefs.LINE_OVERHEAD)
	var pump_id: String = model.buildings_of_kind("pumping_station")[0]
	var cable_taps := PowerTopology.connection_tiles(model, pump_id,
		model.cables)
	assert_int(cable_taps.size()).is_equal(1)
	var water_taps := PowerTopology.connection_tiles(model, pump_id,
		model.water_pipes, "pumping_station")
	assert_int(water_taps.size()).is_equal(0)  # no pipes here at all
