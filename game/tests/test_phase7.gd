extends GdUnitTestSuite
## Phase 7 model layer: event system determinism + effects, scenario
## catalog integrity, difficulty table.


func test_event_system_deterministic() -> void:
	var model := WorldModel.new()
	model.place_building("gas_plant", Vector2i(4, 4))
	model.place_building("wind_farm", Vector2i(8, 4))
	var a := EventSystem.new(7)
	var b := EventSystem.new(7)
	var weather_a := WeatherSystem.new(7)
	var weather_b := WeatherSystem.new(7)
	for day in 60:
		var ea := a.roll_daily(day * 96, model, weather_a, {})
		var eb := b.roll_daily(day * 96, model, weather_b, {})
		assert_int(ea.size()).is_equal(eb.size())


func test_equipment_down_window() -> void:
	var events := EventSystem.new(1)
	events.force_equipment_failure("gas_plant_1", 100)
	assert_bool(events.is_down("gas_plant_1", 101)).is_true()
	assert_bool(events.is_down("gas_plant_1", 100 + EventSystem.REPAIR_STEPS_EQUIPMENT)).is_false()
	assert_bool(events.is_down("other", 101)).is_false()


func test_fire_draw_expires() -> void:
	var events := EventSystem.new(1)
	events.force_fire("wz_x", 200)
	assert_float(events.extra_water_demand_m3h("wz_x", 201)).is_equal(EventSystem.FIRE_FLOW_M3H)
	assert_float(events.extra_water_demand_m3h("wz_x", 200 + EventSystem.FIRE_STEPS)).is_equal(0.0)
	assert_float(events.extra_water_demand_m3h("wz_other", 201)).is_equal(0.0)


func test_exempt_buildings_never_fail() -> void:
	var model := WorldModel.new()
	var slack_id := model.place_building("grid_connection", Vector2i(4, 4))
	var events := EventSystem.new(3)
	events.frequency_scale = 50.0  # brutal odds — only the exemption saves it
	var weather := WeatherSystem.new(3)
	for day in 30:
		events.roll_daily(day * 96, model, weather, {slack_id: true})
	assert_bool(events.down_until.has(slack_id)).is_false()


func test_storm_forces_cutout_wind() -> void:
	var events := EventSystem.new(1)
	var weather := WeatherSystem.new(1)
	events.force_storm(weather, 500)
	assert_float(weather.wind_ms(510)).is_equal(27.0)
	assert_float(WeatherSystem.wind_availability(27.0)).is_equal(0.0)


func test_scenario_catalog_and_difficulty() -> void:
	var ids := {}
	for scenario: Dictionary in Scenarios.catalog():
		ids[scenario["id"]] = true
		assert_bool(scenario.has("name") and scenario.has("desc")).is_true()
	for id: String in ["sandbox", "tutorial", "greenfield", "brownfield", "transition"]:
		assert_bool(ids.has(id)).is_true()
	for key: String in ["easy", "normal", "hard"]:
		var diff: Dictionary = Scenarios.DIFFICULTY[key]
		assert_bool(diff.has("growth_scale") and diff.has("event_scale")
			and diff.has("money_scale")).is_true()
	assert_int(Scenarios.tutorial_steps().size()).is_greater(6)


func test_upkeep_and_mtbf_tables_cover_catalog() -> void:
	for kind: String in BuildingDefs.DEFS:
		assert_bool(BuildingDefs.UPKEEP_DAY.has(kind)) \
			.override_failure_message("no upkeep for %s" % kind).is_true()
	for kind: String in BuildingDefs.MTBF_DAYS:
		assert_bool(BuildingDefs.DEFS.has(kind)).is_true()
