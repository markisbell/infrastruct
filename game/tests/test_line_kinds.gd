extends GdUnitTestSuite
## Grid rework: overhead vs underground line kinds share one electrical
## graph; kind transitions split pandapower segments; ratings semantics.


func _two_kind_city() -> WorldModel:
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 4))  # 2x2 (0-1, 4-5)
	for x in range(2, 6):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	for x in range(6, 10):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_UNDERGROUND)
	model.place_building("substation", Vector2i(10, 5))
	return model


func test_kind_transition_splits_segments() -> void:
	var topo := PowerTopology.build(_two_kind_city(), {})
	var lines: Array = topo.doc["native"]["lines"]["lines"]
	assert_int(lines.size()).is_equal(2)
	var std_types := {}
	for line: Dictionary in lines:
		std_types[line["std_type"]] = true
	assert_bool(std_types.has("48-AL1/8-ST1A 20.0")).is_true()
	assert_bool(std_types.has("NA2XS2Y 1x95 RM/25 12/20 kV")).is_true()
	# the joint became a junction bus
	var junction_buses := 0
	for bus: Dictionary in topo.doc["native"]["grid_structure"]["buses"]:
		if str(bus["name"]).begins_with("bj_"):
			junction_buses += 1
	assert_int(junction_buses).is_greater_equal(1)
	# both ends still electrically connected
	assert_bool(bool(topo.connected["substation_2"])).is_true()


func test_uniform_run_stays_one_segment() -> void:
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 4))
	for x in range(2, 10):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_UNDERGROUND)
	model.place_building("substation", Vector2i(10, 5))
	var topo := PowerTopology.build(model, {})
	var lines: Array = topo.doc["native"]["lines"]["lines"]
	assert_int(lines.size()).is_equal(1)
	assert_str(str(lines[0]["std_type"])).is_equal("NA2XS2Y 1x95 RM/25 12/20 kV")


func test_grid_connection_is_hv_interface() -> void:
	# user corrections (realism pass): 110/20 kV interface = 20 MVA,
	# district substation = 630 kVA Ortsnetzstation
	assert_float(float(BuildingDefs.get_def("grid_connection")["capacity_kw"])) \
		.is_equal(20_000.0)
	assert_float(float(BuildingDefs.get_def("substation")["rating_kva"])) \
		.is_equal(630.0)


func test_awaiting_crew_never_self_heals() -> void:
	City.reset_for_scenario(42)
	City.tripped_tiles[Vector2i(3, 3)] = City.AWAITING_CREW
	City.tripped_tiles[Vector2i(4, 3)] = 50  # crew finishing at t=50
	City._apply_repairs(100)
	assert_bool(City.tripped_tiles.has(Vector2i(3, 3))).is_true()   # still waiting
	assert_bool(City.tripped_tiles.has(Vector2i(4, 3))).is_false()  # healed
	City.reset_for_scenario(42)


func test_dispatch_repair_charges_and_schedules() -> void:
	City.reset_for_scenario(42)
	City.tripped_tiles[Vector2i(5, 5)] = City.AWAITING_CREW
	var money_before := City.money
	assert_bool(City.dispatch_repair(Vector2i(5, 5))).is_true()
	assert_int(City.money).is_equal(money_before - City.CREW_COST)
	assert_bool(int(City.tripped_tiles[Vector2i(5, 5)]) > 0).is_true()
	assert_float(float(City.econ_total.get("cost_maintenance", 0.0))) \
		.is_equal(-float(City.CREW_COST))
	# no double dispatch on an already-crewed tile
	assert_bool(City.dispatch_repair(Vector2i(5, 5))).is_false()
	City.reset_for_scenario(42)


func test_equipment_failure_shows_a_down_marker() -> void:
	# user report: "a windpark failed without reason" — the MTBF event was
	# only one feed line; the failed building now carries a DOWN marker
	City.reset_for_scenario(42)
	var wind := City.model.place_building("wind_farm", Vector2i(30, 30))
	City._apply_event(City.event_system.force_equipment_failure(wind, 10), 10)
	City._update_capacity_warnings(12, {})
	assert_bool(City.capacity_warnings.has("down_" + wind)).is_true()
	assert_str(str(City.capacity_warnings["down_" + wind]["text"])).is_equal("DOWN")
	# after the auto-crew finishes, the marker clears
	City._update_capacity_warnings(200, {})
	assert_bool(City.capacity_warnings.has("down_" + wind)).is_false()
	City.reset_for_scenario(42)


func test_line_costs_differ() -> void:
	assert_int(int(BuildingDefs.COSTS["cable"])) \
		.is_greater(int(BuildingDefs.COSTS["overhead_line"]))
