extends SmokeBase
## --smoke=windless-week (extracted from main.gd, Phase-3 refactor plan).


## Wind-only town behind a tiny grid connection: outages must occur exactly
## during the forced calm window; a battery bridges it (ROADMAP Phase 3).
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_WINDLESS", "power health timeout")
		return
	var phases := {}
	for with_battery: bool in [false, true]:
		var result := await _run_windless_phase(42, with_battery)
		phases["battery" if with_battery else "plain"] = result
	var plain: Dictionary = phases["plain"]
	var battery: Dictionary = phases["battery"]
	var ok: bool = (
		plain["outage_min"] > 0 and plain["all_in_window"]
		and plain["outage_before_calm"] == 0
		and battery["outage_min"] == 0
		# import buckets were collected but never asserted (gate hardening
		# 2026-08-04): the plain town must actually EXCEED the 14-kW cap in
		# the calm window (that is what trips it) and the battery town must
		# hold its calm peak at the cap — outage==0 alone would also pass
		# if the cap silently stopped being enforced
		and float(plain["import_calm"][1]) > 14.0
		and float(battery["import_calm"][1]) <= 14.5
	)
	print("SMOKE_WINDLESS ", JSON.stringify({"ok": ok,
		"plain": plain, "battery": battery}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)

func _run_windless_phase(weather_seed: int, with_battery: bool) -> Dictionary:
	City.reset_for_scenario(weather_seed)
	City.growth_enabled = false  # fixed 6 houses — the EMA needs a stable target
	# between the battery-shaved evening import (~EMA, <10 kW) and the raw
	# EV-peak import (~22 kW): the plain town trips, the battery town holds
	City.grid_capacity_override = 14.0
	City.place_building("grid_connection", Vector2i(10, 10))
	for x in range(12, 31):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(31, 10))
	City.place_building("wind_farm", Vector2i(24, 9))  # each single turbine
	City.place_building("wind_farm", Vector2i(25, 9))  # adjacent to the
	City.place_building("wind_farm", Vector2i(26, 9))  # y=10 cable run
	for x in range(26, 38):
		City.build_road(Vector2i(x, 12))
	for x in range(26, 38):
		City.build_zone(Vector2i(x, 13))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 6)
	if with_battery:
		City.place_building("battery", Vector2i(27, 9))  # adjacent to cable (27,10)
	City._topo_dirty = true
	if not await _wait_registered(120.0):
		return {"error": "register timeout"}

	# clock: start at the next full day boundary; calm 12:00-24:00 on day 1 —
	# the window must cover the EV evening peak, where the import spike lives
	var t0 := (int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES / 96) + 1) * 96
	GameClock.restore({"total_minutes": t0 * float(GameClock.SIM_STEP_MINUTES), "speed": 0.0})
	var calm_start := t0 + 48
	var calm_end := t0 + 96
	# scripted series: solid wind across the whole run, dead calm inside the
	# window — "outages fire exactly when the weather series says calm";
	# 7 m/s keeps the 9-MW farm at a modest few-hundred-kW output
	City.weather.force_wind(t0 - 96, t0 + 192, 7.0)
	City.weather.force_calm(calm_start, calm_end)
	var unsupplied_steps: Array[int] = []
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var import_calm := [0.0, -999.0]   # min, max during calm
	var import_windy := [0.0, -999.0]
	var statuses := {}
	var handler := func(t: int, result: Dictionary) -> void:
		for zone_id: String in City.zone_supplied:
			if not City.zone_supplied[zone_id]:
				unsupplied_steps.append(t)
				break
		var status: String = result.get("status", "?")
		statuses[status] = statuses.get(status, 0) + 1
		var import_kw := float(result.get("devices", {}).get(slack_id, {}).get("output_kw", 0.0))
		var bucket: Array = import_calm if (t >= calm_start and t < calm_end) else import_windy
		bucket[0] = minf(bucket[0], import_kw)
		bucket[1] = maxf(bucket[1], import_kw)
	City.power_result.connect(handler)
	Orchestrator.start()
	GameClock.speed = 60.0
	var end_t := t0 + 96  # one full day covering the calm window
	var deadline := Time.get_ticks_msec() + 300_000
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(1.5).timeout
	City.power_result.disconnect(handler)
	City.weather.clear_calm()

	var all_in_window := true
	var before_calm := 0
	for t: int in unsupplied_steps:
		if t < calm_start:
			before_calm += 1
		if t < calm_start or t > calm_end + City.REPAIR_STEPS + 2:
			all_in_window = false
	return {"outage_min": City.total_outage_minutes(),
		"unsupplied_steps": unsupplied_steps.size(),
		"all_in_window": all_in_window, "outage_before_calm": before_calm,
		"calm": [calm_start, calm_end], "statuses": statuses,
		"import_calm": import_calm, "import_windy": import_windy,
		"events": City.events.size()}
