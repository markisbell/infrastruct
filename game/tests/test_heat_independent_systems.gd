extends GdUnitTestSuite
## SEVERAL independent district-heating systems in one city.
##
## HeatTopology used to bind ONE slack and BFS from it, silently discarding
## every pipe it could not reach ("only the slack plant's network is
## solved"). A city split by a river therefore could not heat both banks:
## Heidelberg's north side had no district heating at all, and building it
## anyway cost the south its solve. The rule is ONE PRESSURE REFERENCE PER
## CONNECTED COMPONENT — power grew `grid_forming` islands for exactly this.


## Two heat networks that share no pipe, each with its own plant and zone.
func _split_city() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	# south system: plant at (0,0), trunk along y=1, exchanger at the end
	model.place_building("chp_plant", Vector2i(0, 0))
	for x in range(2, 12):
		model.set_heat_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("heat_exchanger", Vector2i(12, 1))
	# north system: nothing touches the south — a river's width away
	model.place_building("boiler_plant", Vector2i(0, 20))
	for x in range(2, 12):
		model.set_heat_pipe(Vector2i(x, 21), BuildingDefs.LINE_OVERHEAD)
	model.place_building("heat_exchanger", Vector2i(12, 21))
	return model


func test_each_system_gets_its_own_pressure_reference() -> void:
	var topo := HeatTopology.build(_split_city(), {})
	var producers: Array = topo.doc["native"]["producers"]["producers"]
	assert_int(producers.size()) \
		.override_failure_message("a split city needs one reference per side") \
		.is_equal(2)
	for producer: Dictionary in producers:
		assert_str(str(producer["kind"])).is_equal("slack")
	# each runs at ITS OWN plant's supply temperature: a CHP at 85 °C on one
	# side, a boiler at 66 °C on the other — one slack could only ever have
	# imposed a single temperature on both
	var temps: Array = []
	for producer: Dictionary in producers:
		temps.append(round(float(producer["t_flow_k"]) - 273.15))
	temps.sort()
	assert_array(temps).is_equal([66.0, 85.0])


func test_both_sides_are_served_and_no_pipe_is_discarded() -> void:
	var model := _split_city()
	var topo := HeatTopology.build(model, {})
	assert_int(topo.zones_info.size()) \
		.override_failure_message("an exchanger was dropped with its network") \
		.is_equal(2)
	for sub_id: String in model.buildings_of_kind("heat_exchanger"):
		assert_bool(topo.connected.get(sub_id, false)) \
			.override_failure_message("%s stranded off the solve" % sub_id) \
			.is_true()
	assert_array(topo.warnings).is_empty()
	# every pipe of BOTH systems rides the document
	assert_int((topo.doc["native"]["pipes"]["pipes"] as Array).size()) \
		.is_greater(1)


func test_every_plant_still_reaches_the_devices_list() -> void:
	var topo := HeatTopology.build(_split_city(), {})
	var ids: Array = []
	for device: Dictionary in topo.doc["devices"]:
		ids.append(str(device["id"]))
	assert_int(ids.size()).is_equal(2)
	# the references lead the list; the backend binds each by its NODE
	var nodes: Array = []
	for producer: Dictionary in topo.doc["native"]["producers"]["producers"]:
		nodes.append(str(producer["node"]))
	for device: Dictionary in topo.doc["devices"]:
		assert_bool(nodes.has(str(device["node"]))) \
			.override_failure_message("device %s binds no reference" % device["id"]) \
			.is_true()


func test_a_system_with_no_plant_stays_dark_and_says_so() -> void:
	# the heat equivalent of a renewable-only power island: nothing holds
	# its pressure, so there is nothing to solve — but the player is told
	var model := _split_city()
	# a third network with consumers at both ends and NO plant on it
	for x in range(2, 8):
		model.set_heat_pipe(Vector2i(x, 40), BuildingDefs.LINE_OVERHEAD)
	model.place_building("heat_exchanger", Vector2i(1, 40))
	var orphan := model.place_building("heat_exchanger", Vector2i(8, 40))
	var topo := HeatTopology.build(model, {})
	assert_bool(topo.connected.get(orphan, false)) \
		.override_failure_message("an exchanger with no plant was reported served") \
		.is_false()
	assert_int(topo.warnings.size()).is_greater(0)
	assert_int(topo.zones_info.size()).is_equal(2)   # the two real systems
