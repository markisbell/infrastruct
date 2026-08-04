extends SmokeBase
## --smoke=overload (extracted from main.gd, Phase-3 refactor plan).


## Two feeders from the grid connection; the heavy one carries an 18-MW wind
## park (2 farms) at its far end — at full wind the EXPORT overloads the
## 20-kV overhead run (~7.3 MVA) past 120 %, trips, and blacks out ONLY the
## zones behind the cut. MW-scale generation is what overloads MV lines now;
## household districts alone barely register.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_OVERLOAD", "power health timeout")
		return
	City.model = WorldModel.new()
	City.money = 100_000_000
	City.weather = WeatherSystem.new(42)
	City.outage_minutes = {}
	City.place_building("grid_connection", Vector2i(10, 10))
	# feeder A (east) -> sub1, light
	for x in range(12, 18):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(18, 10))
	for x in range(14, 26):
		City.build_road(Vector2i(x, 8))
	for x in range(14, 26):
		City.build_zone(Vector2i(x, 7))
	# feeder B (south, then east) -> sub2 + sub3 + the wind park at the end
	for y in range(12, 16):
		City.build_cable(Vector2i(10, y))
	for x in range(11, 35):
		City.build_cable(Vector2i(x, 15))
	City.place_building("substation", Vector2i(20, 16))  # touches (20,15)
	City.place_building("substation", Vector2i(30, 16))  # touches (30,15)
	City.place_building("wind_farm", Vector2i(31, 14))   # north trio on y=14,
	City.place_building("wind_farm", Vector2i(32, 14))   # each adjacent to the
	City.place_building("wind_farm", Vector2i(33, 14))   # y=15 cable row
	City.place_building("wind_farm", Vector2i(32, 16))   # south trio on y=16,
	City.place_building("wind_farm", Vector2i(33, 16))   # same cable row from
	City.place_building("wind_farm", Vector2i(34, 16))   # the other side
	for x in range(12, 34):
		City.build_road(Vector2i(x, 19))
		City.build_road(Vector2i(x, 22))
	for x in range(12, 34):
		for y in [20, 21, 23]:  # every zoned row is road-adjacent
			City.build_zone(Vector2i(x, y))
	var subs := City.model.buildings_of_kind("substation")
	# heavy district spawns FIRST so sub1 cannot eat its candidate tiles
	var spawned := [City.spawn_houses_bulk(subs[1], 60),
		City.spawn_houses_bulk(subs[2], 60), City.spawn_houses_bulk(subs[0], 20)]
	# full wind across the whole run: both farms at rated output
	City.weather.force_wind(0, 100_000, 14.0)
	City._topo_dirty = true
	if not await _wait_registered(120.0):
		_fail("SMOKE_OVERLOAD", "register timeout")
		return

	var zone1 := "z_" + subs[0]
	# NOTE: GDScript lambdas capture scalars BY VALUE — mutate a shared
	# Dictionary (reference semantics) or the counters silently stay 0.
	var counters := {"trips": 0, "max_loading": 0.0, "steps": 0}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "line_trip":
			counters["trips"] += 1)
	City.power_result.connect(func(_t: int, result: Dictionary) -> void:
		counters["steps"] += 1
		for edge_id: String in result.get("edges", {}):
			counters["max_loading"] = maxf(counters["max_loading"],
				float(result["edges"][edge_id].get("loading_percent", 0.0))))

	# start at 17:30 — into the evening peak
	GameClock.restore({"total_minutes": 17.5 * 60.0, "speed": 0.0})
	Orchestrator.start()
	GameClock.speed = 30.0
	var end_t := int(21.0 * 60.0 / GameClock.SIM_STEP_MINUTES)  # run to 21:00
	var deadline := Time.get_ticks_msec() + 300_000
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(1.5).timeout

	var heavy_outage: int = City.outage_minutes.get("z_" + subs[1], 0) \
		+ City.outage_minutes.get("z_" + subs[2], 0)
	var light_outage: int = City.outage_minutes.get(zone1, 0)
	var report := {
		"ok": counters["trips"] >= 1 and counters["max_loading"] > 120.0
			and heavy_outage > 0 and light_outage == 0,
		"trip_events": counters["trips"],
		"max_loading": snappedf(counters["max_loading"], 0.1),
		"heavy_feeder_outage_min": heavy_outage, "light_feeder_outage_min": light_outage,
		"steps_seen": counters["steps"], "houses_spawned": spawned,
	}
	print("SMOKE_OVERLOAD ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
