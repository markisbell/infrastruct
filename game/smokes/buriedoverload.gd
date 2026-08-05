extends SmokeBase
## --smoke=buriedoverload: the overload scenario on a BURIED heavy feeder
## — the NA2XS2Y cable's ~8.7 MVA rating must be what the solver applies
## (18 MW lands near ~207 % loading; the overhead 48-AL1 rating would
## read ~246 % — the loading band is the honest fingerprint), the
## sustained overload still trips, and only the zones behind the cut go
## dark. Buried runs join overhead ones freely; here the whole heavy
## feeder is trenched.


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_BURIEDOVERLOAD", "power health timeout")
		return
	City.model = WorldModel.new()
	City.money = 100_000_000
	City.weather = WeatherSystem.new(42)
	City.outage_minutes = {}
	City.place_building("grid_connection", Vector2i(10, 10))
	# feeder A (east) -> sub1, light, stays overhead
	for x in range(12, 18):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(18, 10))
	for x in range(14, 26):
		City.build_road(Vector2i(x, 8))
	for x in range(14, 26):
		City.build_zone(Vector2i(x, 7))
	# feeder B: BURIED all the way to the wind park
	for y in range(12, 16):
		City.build_cable(Vector2i(10, y), BuildingDefs.LINE_UNDERGROUND)
	for x in range(11, 35):
		City.build_cable(Vector2i(x, 15), BuildingDefs.LINE_UNDERGROUND)
	City.place_building("substation", Vector2i(20, 16))
	City.place_building("substation", Vector2i(30, 16))
	City.place_building("wind_farm", Vector2i(31, 14))
	City.place_building("wind_farm", Vector2i(32, 14))
	City.place_building("wind_farm", Vector2i(33, 14))
	City.place_building("wind_farm", Vector2i(32, 16))
	City.place_building("wind_farm", Vector2i(33, 16))
	City.place_building("wind_farm", Vector2i(34, 16))
	for x in range(12, 34):
		City.build_road(Vector2i(x, 19))
		City.build_road(Vector2i(x, 22))
	for x in range(12, 34):
		for y in [20, 21, 23]:
			City.build_zone(Vector2i(x, y))
	var subs := City.model.buildings_of_kind("substation")
	var spawned := [City.spawn_houses_bulk(subs[1], 60),
		City.spawn_houses_bulk(subs[2], 60), City.spawn_houses_bulk(subs[0], 20)]
	City.weather.force_wind(0, 100_000, 14.0)
	City._topo_dirty = true
	if not await _wait_registered(120.0):
		_fail("SMOKE_BURIEDOVERLOAD", "register timeout")
		return

	var counters := {"trips": 0, "max_loading": 0.0}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "line_trip":
			counters["trips"] += 1)
	City.power_result.connect(func(_t: int, result: Dictionary) -> void:
		for edge_id: String in result.get("edges", {}):
			counters["max_loading"] = maxf(counters["max_loading"],
				float(result["edges"][edge_id].get("loading_percent", 0.0))))

	GameClock.restore({"total_minutes": 17.5 * 60.0, "speed": 0.0})
	Orchestrator.start()
	GameClock.speed = 30.0
	var end_t := int(21.0 * 60.0 / GameClock.SIM_STEP_MINUTES)
	var deadline := Time.get_ticks_msec() + 300_000
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(1.5).timeout

	check("tripped", counters["trips"] >= 1)
	# the loading FINGERPRINT: ~18 MW on the 8.7-MVA NA2XS2Y sits far
	# below where the 7.3-MVA overhead rating would put it
	check("buried_rating_band",
		counters["max_loading"] > 150.0 and counters["max_loading"] < 232.0)
	var heavy_outage: int = City.outage_minutes.get("z_" + subs[1], 0) \
		+ City.outage_minutes.get("z_" + subs[2], 0)
	check("heavy_dark", heavy_outage > 0)
	check("light_untouched", City.outage_minutes.get("z_" + subs[0], 0) == 0)

	var report := {"ok": verdict(), "failed": failed_checks(),
		"max_loading": snappedf(counters["max_loading"], 0.1),
		"trip_events": counters["trips"],
		"heavy_outage_min": heavy_outage, "houses_spawned": spawned}
	print("SMOKE_BURIEDOVERLOAD ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
