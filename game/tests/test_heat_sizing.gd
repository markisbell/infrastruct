extends GdUnitTestSuite
## Heat pipe sizing: every pipe carries the load BEHIND it.
##
## Every pipe in every city used to be ISOPLUS_DRE50_STD — one constant.
## DN50 carries ~335 kW, and Heidelberg's zones want 2720 kW, so the trunk
## was about ten times too small and the far Altstadt arrived at 10-20 °C
## however much plant stood behind it.


func test_the_ladder_picks_the_smallest_pipe_that_carries_the_load() -> void:
	assert_str(HeatTopology.pipe_std_type(100.0)).is_equal("ISOPLUS_DRE32_STD")
	assert_str(HeatTopology.pipe_std_type(160.0)).is_equal("ISOPLUS_DRE40_STD")
	# a city trunk: one zone fits in DN40, seventeen need DN150
	assert_str(HeatTopology.pipe_std_type(17.0 * HeatTopology.ZONE_DESIGN_KW)) \
		.is_equal("ISOPLUS_DRE150_STD")


func test_the_ladder_is_monotone_and_saturates() -> void:
	var previous := ""
	var seen: Array[String] = []
	for kw in [10.0, 200.0, 500.0, 1000.0, 2500.0, 6000.0, 20000.0]:
		var pick := HeatTopology.pipe_std_type(kw)
		if pick != previous:
			seen.append(pick)
			previous = pick
	assert_int(seen.size()) \
		.override_failure_message("the ladder never widened: %s" % [seen]) \
		.is_greater(4)
	# past the biggest catalog entry it saturates rather than failing
	assert_str(HeatTopology.pipe_std_type(1.0e9)) \
		.is_equal("ISOPLUS_DRE500_STD")


func test_pump_lift_grows_with_the_network_and_stays_bounded() -> void:
	# a village keeps the old 2 bar; a 6 km city needs more, or its worst
	# point sits at NEGATIVE differential pressure (measured: -0.86 bar)
	assert_float(HeatTopology.plift_bar(0.5)).is_equal(HeatTopology.PLIFT_MIN_BAR)
	assert_float(HeatTopology.plift_bar(6.25)).is_greater(3.0)
	assert_float(HeatTopology.plift_bar(500.0)).is_equal(HeatTopology.PLIFT_MAX_BAR)


func test_load_tree_sums_what_hangs_behind_each_node() -> void:
	# plant --- j --- zone A
	#            \--- zone B
	var edges: Array[Dictionary] = [
		{"a": "plant", "b": "j:1,1", "path": []},
		{"a": "j:1,1", "b": "a", "path": []},
		{"a": "j:1,1", "b": "b", "path": []},
	]
	var reachable := {"plant": true, "j:1,1": true, "a": true, "b": true}
	var tree := HeatTopology.load_tree(edges, reachable, "plant",
		{"a": 160.0, "b": 160.0})
	var load: Dictionary = tree["load"]
	assert_float(float(load["a"])).is_equal(160.0)
	assert_float(float(load["j:1,1"])) \
		.override_failure_message("the junction must carry BOTH zones behind it") \
		.is_equal(320.0)
	assert_float(float(load["plant"])).is_equal(320.0)


func test_a_real_network_sizes_its_trunk_above_its_spurs() -> void:
	# the property that matters: the pipe nearest the plant is the widest,
	# because everything the city draws passes through it
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("chp_plant", Vector2i(2, 2))
	for x in range(2, 40):
		model.set_heat_pipe(Vector2i(x, 4), BuildingDefs.LINE_OVERHEAD)
	model.set_heat_pipe(Vector2i(2, 3), BuildingDefs.LINE_OVERHEAD)
	for x in [8, 16, 24, 32]:      # four zones hanging off one trunk
		model.place_building("heat_exchanger", Vector2i(x, 5))
	var topo := HeatTopology.build(model, {})
	assert_int(topo.zones_info.size()).is_equal(4)
	var widths := {}
	for pipe: Dictionary in topo.doc["native"]["pipes"]["pipes"]:
		widths[pipe["std_type"]] = true
	assert_int(widths.size()) \
		.override_failure_message("every pipe got the same size: %s" % [widths.keys()]) \
		.is_greater(1)
	# and no pipe is undersized for its own zone's design load
	for pipe: Dictionary in topo.doc["native"]["pipes"]["pipes"]:
		assert_str(pipe["std_type"]).is_not_equal("ISOPLUS_DRE20_STD")
