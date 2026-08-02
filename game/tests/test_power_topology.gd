extends GdUnitTestSuite
## Topology extraction: cable graph → contract doc, islands, junctions, trips.


func _town() -> WorldModel:
	## grid_connection(2x2)@(0,0) — cable (2,0)..(10,0) — substation@(11,0)
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)
	model.place_building("substation", Vector2i(11, 0))
	# a road + zone + houses near the substation
	for x in range(8, 14):
		model.set_road(Vector2i(x, 2))
	for x in range(8, 14):
		model.set_zone(Vector2i(x, 3))
		model.spawn_house(Vector2i(x, 3))
	return model


func test_parallel_runs_do_not_short() -> void:
	# two lines laid side by side must not connect (user correction): the
	# second run stays a separate circuit and its substation stays dark
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)
	for x in range(4, 11):
		model.set_cable(Vector2i(x, 1), 1)  # directly beside the first run
	var sub := model.place_building("substation", Vector2i(11, 1))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected.get(sub, true)).is_false()


func test_t_tap_connects() -> void:
	# ending a run INTO another one is the junction gesture — that bonds
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)
	for y in range(1, 5):
		model.set_cable(Vector2i(6, y), 1)
	var sub := model.place_building("substation", Vector2i(6, 5))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected.get(sub, false)).is_true()


func test_single_tap_does_not_bridge_runs() -> void:
	# a plant touching two separate runs taps only ONE (sorted-first) and
	# must not act as a jumper between them
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)   # energized run
		model.set_cable(Vector2i(x, 2), 1)   # separate run one row below
	var battery := model.place_building("battery", Vector2i(10, 1))
	var sub := model.place_building("substation", Vector2i(2, 3))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected.get(battery, false)).is_true()
	assert_bool(topo.connected.get(sub, true)).is_false()


func test_grid_connection_taps_all_adjacent_runs() -> void:
	# the 110/20 kV station is the ONE building allowed multiple line
	# connections — both runs energize through it
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)
		model.set_cable(Vector2i(x, 1), 1)
	var sub := model.place_building("substation", Vector2i(11, 1))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected.get(sub, false)).is_true()


func test_heat_parallel_runs_do_not_join() -> void:
	# same rule as power (user correction): a parallel heat run beside the
	# trunk stays a separate hydraulic circuit; ending INTO the trunk taps
	var model := WorldModel.new()
	model.place_building("boiler_plant", Vector2i(0, 0))  # 2x2, taps (2,0)-run
	for x in range(2, 11):
		model.set_heat_pipe(Vector2i(x, 0), 1)
	for x in range(4, 11):
		model.set_heat_pipe(Vector2i(x, 1), 1)  # parallel, directly beside
	var ex := model.place_building("heat_exchanger", Vector2i(11, 1))
	var topo := HeatTopology.build(model, {})
	assert_bool(topo.connected.get(ex, true)).is_false()
	# T-tap: a spur ending INTO the trunk connects a second exchanger
	for y in range(1, 4):
		model.set_heat_pipe(Vector2i(6, y), 1)
	var ex2 := model.place_building("heat_exchanger", Vector2i(6, 4))
	var topo2 := HeatTopology.build(model, {})
	assert_bool(topo2.connected.get(ex2, false)).is_true()


func test_water_parallel_runs_do_not_join() -> void:
	var model := WorldModel.new()
	model.place_building("water_tower", Vector2i(0, 0))
	for x in range(1, 11):
		model.set_water_pipe(Vector2i(x, 0), 1)
	for x in range(3, 11):
		model.set_water_pipe(Vector2i(x, 1), 1)  # parallel run
	var station := model.place_building("water_station", Vector2i(11, 1))
	var topo := WaterTopology.build(model, {})
	assert_bool(topo.connected.get(station, true)).is_false()


func test_simple_town_extraction() -> void:
	var topo := PowerTopology.build(_town(), {})
	assert_bool(topo.has_slack).is_true()
	# slack MV + substation MV + the substation's LV bus (realism pass)
	assert_int(topo.doc["native"]["grid_structure"]["buses"].size()).is_equal(3)
	var lines: Array = topo.doc["native"]["lines"]["lines"]
	assert_int(lines.size()).is_equal(1)
	# path: 9 cable tiles + both endpoints are among them -> 9 tiles * 25 m
	assert_float(lines[0]["length_km"]).is_equal_approx(0.225, 0.001)
	assert_int(topo.doc["zones"].size()).is_equal(1)
	var zone_id: String = topo.doc["zones"][0]["id"]
	assert_int(topo.zones_info[zone_id]["houses"]).is_equal(6)
	assert_int(topo.doc["devices"].size()).is_equal(1)  # slack only
	assert_that(topo.doc["devices"][0]["kind"]).is_equal("slack")
	assert_bool(topo.line_tiles.has("L0")).is_true()
	# the substation is a REAL 20/0.4 kV trafo, zone load on its LV side
	var trafos: Array = topo.doc["native"]["lines"]["transformers"]
	assert_int(trafos.size()).is_equal(1)
	assert_str(str(trafos[0]["std_type"])).is_equal("0.63 MVA 20/0.4 kV")
	assert_str(str(topo.doc["zones"][0]["node"])).starts_with("lv_")
	assert_str(str(topo.trafo_subs["T0"])) \
		.is_equal(str(topo.zones_info[zone_id]["sub"]))


func test_junction_splits_lines() -> void:
	var model := _town()
	# branch off tile (6,0) down to a wind farm
	for y in range(1, 5):
		model.set_cable(Vector2i(6, y), 1)
	model.place_building("wind_farm", Vector2i(6, 5))  # 1x1 turbine touches (6,4)
	var topo := PowerTopology.build(model, {})
	# junction at (6,0) -> 3 lines, 5 buses (slack, sub, wind, junction + LV)
	assert_int(topo.doc["native"]["lines"]["lines"].size()).is_equal(3)
	assert_int(topo.doc["native"]["grid_structure"]["buses"].size()).is_equal(5)
	var kinds := []
	for device: Dictionary in topo.doc["devices"]:
		kinds.append(device["kind"])
	assert_array(kinds).contains(["slack", "wind"])


func test_island_excluded_and_flagged() -> void:
	var model := _town()
	model.set_cable(Vector2i(20, 20), 1)
	var island_sub := model.place_building("substation", Vector2i(21, 20))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected[island_sub]).is_false()
	assert_int(topo.doc["zones"].size()).is_equal(1)  # island zone not in doc


func test_trip_disconnects_downstream() -> void:
	var model := _town()
	var tripped := {Vector2i(6, 0): true}
	var topo := PowerTopology.build(model, tripped)
	# the only line crosses the tripped tile -> substation unreachable
	var sub_id: String = model.buildings_of_kind("substation")[0]
	assert_bool(topo.connected[sub_id]).is_false()
	assert_int(topo.doc["zones"].size()).is_equal(0)
	assert_int(topo.doc["native"]["lines"]["lines"].size()).is_equal(0)


func test_no_slack_means_no_doc() -> void:
	var model := WorldModel.new()
	model.set_cable(Vector2i(0, 0), 1)
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.has_slack).is_false()
	assert_bool(topo.doc.is_empty()).is_true()
