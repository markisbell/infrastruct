extends GdUnitTestSuite
## Envelope v4 (Phase 8 completeness): trips, econ books, event-system
## state and device SoC survive the save/load roundtrip — a load can no
## longer cheese away failures or recharge the storages.


func test_v4_roundtrip_restores_the_whole_game_state() -> void:
	City.reset_for_scenario(42)
	City.tripped_tiles[Vector2i(7, 7)] = City.AWAITING_CREW
	City.tripped_tiles[Vector2i(8, 7)] = 120
	City.tripped_substations["substation_9"] = City.AWAITING_CREW
	City.grid_trip_until = 555
	City.econ_total = {"income_elec": 123.5, "cost_fuel": -44.0}
	City.econ_today = {"income_elec": 3.25}
	City.event_system.down_until["wind_farm_4"] = 999
	City.event_system.water_draws["wz_x"] = {"until_t": 400, "m3h": 48.0}
	City.device_soc = {"battery_5": 0.37, "heat_storage_2": 0.81}
	var path := "user://gdunit_v4_save.json"
	assert_int(SaveGame.save_to(path)).is_equal(OK)

	City.reset_for_scenario(7)  # wipe everything
	assert_bool(City.tripped_tiles.is_empty()).is_true()

	var loaded: Dictionary = SaveGame.load_from(path)
	assert_bool(loaded["ok"]).is_true()
	assert_int(int(City.tripped_tiles[Vector2i(7, 7)])).is_equal(City.AWAITING_CREW)
	assert_int(int(City.tripped_tiles[Vector2i(8, 7)])).is_equal(120)
	assert_int(int(City.tripped_substations["substation_9"])) \
		.is_equal(City.AWAITING_CREW)
	assert_int(City.grid_trip_until).is_equal(555)
	assert_float(float(City.econ_total["income_elec"])).is_equal_approx(123.5, 0.001)
	assert_float(float(City.econ_today["income_elec"])).is_equal_approx(3.25, 0.001)
	assert_bool(City.event_system.is_down("wind_farm_4", 500)).is_true()
	assert_bool(City.event_system.is_down("wind_farm_4", 1500)).is_false()
	assert_float(float(City.event_system.water_draws["wz_x"]["m3h"])) \
		.is_equal_approx(48.0, 0.001)
	assert_float(float(City.device_soc["battery_5"])).is_equal_approx(0.37, 0.0001)
	City.reset_for_scenario(42)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_soc_is_injected_into_registration_docs() -> void:
	City.reset_for_scenario(42)
	City.model.place_building("grid_connection", Vector2i(0, 4))
	for x in range(2, 6):
		City.model.set_cable(Vector2i(x, 5), 1)
	var battery := City.model.place_building("battery", Vector2i(6, 5))
	City.device_soc[battery] = 0.42
	City._sync_topology()
	var found := 0.0
	for device: Dictionary in City.topo.doc["devices"]:
		if device["id"] == battery:
			found = float(device["params"].get("soc", -1.0))
	assert_float(found).is_equal_approx(0.42, 0.0001)
	City.reset_for_scenario(42)


func test_event_rng_state_survives_the_roundtrip() -> void:
	# the RNG position rides as a string (int64 vs JSON float64) — after a
	# load the SAME event stream continues instead of rerolling
	var system := EventSystem.new(1234)
	for i in 5:
		system.rng.randf()
	var expected := system.rng.randf()
	system = EventSystem.new(1234)
	for i in 5:
		system.rng.randf()
	var parsed: Variant = JSON.parse_string(JSON.stringify(system.serialize()))
	var restored := EventSystem.deserialize(parsed, 42)
	assert_float(restored.rng.randf()).is_equal_approx(expected, 0.0000001)
