extends GdUnitTestSuite
## User reports 2026-07-30: multiple grid connections must ALL energize
## (each island with a station lives), and buildings sharing a connection
## tile must ALL join the network (first-wins used to orphan the later
## ones — "cannot connect more than one water station to a well").


func test_two_grid_connections_energize_two_islands() -> void:
	var model := WorldModel.new()
	var grid_a := model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 6):
		model.set_cable(Vector2i(x, 1), 1)
	var sub_a := model.place_building("substation", Vector2i(6, 1))
	var grid_b := model.place_building("grid_connection", Vector2i(20, 20))
	for x in range(22, 26):
		model.set_cable(Vector2i(x, 21), 1)
	var sub_b := model.place_building("substation", Vector2i(26, 21))
	var topo := PowerTopology.build(model, {})
	assert_bool(bool(topo.connected[grid_a])).is_true()
	assert_bool(bool(topo.connected[sub_a])).is_true()
	assert_bool(bool(topo.connected[grid_b])).is_true()   # was: dead island
	assert_bool(bool(topo.connected[sub_b])).is_true()
	assert_int(topo.doc["zones"].size()).is_equal(2)
	assert_int(topo.trafo_subs.size()).is_equal(2)
	var slacks := 0
	for device: Dictionary in topo.doc["devices"]:
		if device["kind"] == "slack":
			slacks += 1
	assert_int(slacks).is_equal(2)  # parallel ext_grids on the backend


func test_shared_cable_tile_serves_every_neighbor() -> void:
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	model.set_cable(Vector2i(2, 1), 1)
	model.set_cable(Vector2i(3, 1), 1)
	var wind := model.place_building("wind_farm", Vector2i(2, 2))  # claims (2,1)+(3,1)
	var battery := model.place_building("battery", Vector2i(3, 0))  # shares (3,1)
	var topo := PowerTopology.build(model, {})
	assert_bool(bool(topo.connected[wind])).is_true()
	assert_bool(bool(topo.connected[battery])).is_true()  # was: orphaned
	var kinds := []
	for device: Dictionary in topo.doc["devices"]:
		kinds.append(device["kind"])
	assert_array(kinds).contains(["slack", "wind", "battery"])


func test_station_one_pipe_tile_from_well_connects() -> void:
	var model := WorldModel.new()
	var well := model.place_building("well", Vector2i(0, 5))
	model.set_water_pipe(Vector2i(1, 5), 1)  # single tile, shared by both
	var station := model.place_building("water_station", Vector2i(2, 5))
	var topo := WaterTopology.build(model, {})
	assert_bool(bool(topo.connected[well])).is_true()
	assert_bool(bool(topo.connected[station])).is_true()  # was: no edge at all
	assert_int(topo.doc["native"]["consumers"]["consumers"].size()).is_equal(1)


func test_two_stations_on_one_well_share_the_end_tile() -> void:
	var model := WorldModel.new()
	model.place_building("well", Vector2i(0, 5))
	for x in range(1, 5):
		model.set_water_pipe(Vector2i(x, 5), 1)
	var station_a := model.place_building("water_station", Vector2i(5, 5))
	var station_b := model.place_building("water_station", Vector2i(4, 6))  # shares (4,5)
	var topo := WaterTopology.build(model, {})
	assert_bool(bool(topo.connected[station_a])).is_true()
	assert_bool(bool(topo.connected[station_b])).is_true()  # was: orphaned
	assert_int(topo.doc["native"]["consumers"]["consumers"].size()).is_equal(2)
	assert_int(topo.doc["zones"].size()).is_equal(2)


func test_second_water_island_warns_and_stays_out() -> void:
	var model := WorldModel.new()
	model.place_building("well", Vector2i(0, 5))
	model.set_water_pipe(Vector2i(1, 5), 1)
	model.place_building("water_station", Vector2i(2, 5))
	model.place_building("well", Vector2i(20, 20))
	model.set_water_pipe(Vector2i(21, 20), 1)
	var island_station := model.place_building("water_station", Vector2i(22, 20))
	var topo := WaterTopology.build(model, {})
	assert_bool(bool(topo.connected[island_station])).is_false()
	assert_int(topo.doc["zones"].size()).is_equal(1)
	assert_bool(topo.warnings.any(func(w: String) -> bool:
		return w.contains("separate pipe network"))).is_true()


func test_second_boiler_on_a_stub_gets_an_auto_bypass() -> void:
	# user report: a second boiler plant wouldn't place — its dead-end stub
	# junction made the backend reject the WHOLE bundle (zero-flow guard).
	# The builder now ships the canonical bypass consumer at such nodes.
	var model := WorldModel.new()
	model.place_building("boiler_plant", Vector2i(0, 0))       # slack, 2x2
	for x in range(2, 11):
		model.set_heat_pipe(Vector2i(x, 1), 1)
	model.place_building("heat_exchanger", Vector2i(11, 1))
	var boiler_b := model.place_building("boiler_plant", Vector2i(4, 3))
	model.set_heat_pipe(Vector2i(4, 2), 1)                     # the stub
	var topo := HeatTopology.build(model, {})
	assert_bool(bool(topo.connected[boiler_b])).is_true()
	var device_ids := []
	for device: Dictionary in topo.doc["devices"]:
		device_ids.append(device["id"])
	assert_array(device_ids).contains([boiler_b])              # feed-in shipped
	var bypass := {}
	for consumer: Dictionary in topo.doc["native"]["consumers"]["consumers"]:
		if str(consumer["name"]) == "bypass_" + boiler_b:
			bypass = consumer
	assert_bool(bypass.is_empty()).is_false()
	assert_float(float(bypass["controlled_mdot_kg_per_s"])).is_greater(0.0)
	# a plant ON the through-going trunk needs no bypass
	var boiler_c := model.place_building("boiler_plant", Vector2i(6, 2))
	topo = HeatTopology.build(model, {})
	for consumer: Dictionary in topo.doc["native"]["consumers"]["consumers"]:
		assert_str(str(consumer["name"])).is_not_equal("bypass_" + boiler_c)


func test_heat_exchanger_one_pipe_tile_from_plant_connects() -> void:
	var model := WorldModel.new()
	model.place_building("boiler_plant", Vector2i(0, 0))  # 2x2
	model.set_heat_pipe(Vector2i(2, 1), 1)  # single tile, shared
	var exchanger := model.place_building("heat_exchanger", Vector2i(3, 1))
	var topo := HeatTopology.build(model, {})
	assert_bool(bool(topo.connected[exchanger])).is_true()  # was: no edge
	assert_int(topo.doc["zones"].size()).is_equal(1)


func test_heat_slack_is_the_hottest_plant_not_the_first_by_id() -> void:
	# Only the slack sets the supply temperature the WHOLE network runs at;
	# every other plant feeds in at its own node without touching it. The
	# slack used to be plant_ids.sort()[0], so "boiler_plant" (66 °C) beat
	# "chp_plant" (85 °C) on a string compare and dragged a whole city below
	# what its far ends could be served at.
	var model := WorldModel.new()
	model.place_building("boiler_plant", Vector2i(0, 0))       # 66 °C, 2x2
	for x in range(2, 12):
		model.set_heat_pipe(Vector2i(x, 1), 1)
	model.place_building("chp_plant", Vector2i(4, 2))          # 85 °C
	model.place_building("heat_exchanger", Vector2i(12, 1))
	var topo := HeatTopology.build(model, {})
	var producer: Dictionary = topo.doc["native"]["producers"]["producers"][0]
	assert_float(float(producer["t_flow_k"])) \
		.override_failure_message("the cooler plant became the slack") \
		.is_equal_approx(273.15 + 85.0, 0.01)
	# and the boiler is still shipped — as a feed-in, not as scenery
	var device_ids := []
	for device: Dictionary in topo.doc["devices"]:
		device_ids.append(device["id"])
	assert_int(device_ids.size()).is_greater_equal(2)
