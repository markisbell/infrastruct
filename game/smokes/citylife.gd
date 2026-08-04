extends SmokeBase
## --smoke=citylife (extracted from main.gd, Phase-3 refactor plan).


## Growth feedback (ROADMAP Phase 6 acceptance): a well-built city grows
## through a compressed year without intervention; a fragile one (wind-only
## behind an undersized grid connection) stalls and empties out.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_CITYLIFE", "health timeout")
		return

	# ── phase A: the reference town, seeded small
	City.reset_for_scenario(42)
	_build_reference_city(6)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_CITYLIFE", "register timeout (A)")
		return
	var houses_start_a := City.model.houses.size()
	var dark_steps: Array = []
	City.power_result.connect(func(t: int, result: Dictionary) -> void:
		for zone_id: String in City.topo.zones_info:
			if not City.zone_supplied.get(zone_id, true) \
					and City.topo.zones_info[zone_id]["houses"] > 0 \
					and dark_steps.size() < 40:
				var zone: Dictionary = result.get("zones", {}).get(zone_id, {})
				dark_steps.append("t%d %s sup=%s vpu=%s status=%s trip=%s" % [t,
					zone_id, str(zone.get("supplied", "?")),
					str(zone.get("detail", {}).get("v_pu", "?")),
					str(result.get("status", "?")),
					str(City.grid_trip_until > t)]))
	for start_day: int in [10, 70, 130, 190, 250, 310]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(192, 600.0, 240.0)
	var houses_end_a := City.model.houses.size()
	var happiness_a := City.happiness
	var satisfaction_a := City.satisfaction.duplicate()

	# ── phase B: fragile — wind-only behind an 18 kW grid connection
	City.reset_for_scenario(42)
	City.grid_capacity_override = 18.0
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 42):
		City.build_cable(Vector2i(x, 5))
	City.place_building("wind_farm", Vector2i(10, 4))
	City.place_building("wind_farm", Vector2i(11, 4))
	City.place_building("wind_farm", Vector2i(12, 4))
	City.place_building("substation", Vector2i(30, 6))
	for x in range(24, 41):
		City.build_road(Vector2i(x, 8))
	for x in range(24, 41):
		City.build_zone(Vector2i(x, 9))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 12)
	var seen := {"trip": false, "abandoned": false}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "grid_trip":
			seen["trip"] = true
		elif event["kind"] == "abandoned":
			seen["abandoned"] = true)
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_CITYLIFE", "register timeout (B)")
		return
	var houses_start_b := City.model.houses.size()
	for start_day: int in [10, 70, 130, 190, 250, 310]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(192, 600.0, 240.0)
	var houses_end_b := City.model.houses.size()
	var happiness_b := City.happiness

	var ok: bool = houses_end_a >= houses_start_a + 12 and happiness_a >= 80.0 \
		and houses_end_b <= houses_start_b + 2 and happiness_b < 55.0 \
		and (seen["trip"] or seen["abandoned"])
	var report := {
		"ok": ok,
		"A_houses": [houses_start_a, houses_end_a],
		"A_happiness": snappedf(happiness_a, 0.1),
		"A_satisfaction": satisfaction_a,
		"B_houses": [houses_start_b, houses_end_b],
		"B_happiness": snappedf(happiness_b, 0.1),
		"B_trip_seen": seen["trip"], "B_abandoned_seen": seen["abandoned"],
		"orch": Orchestrator.stats,
	}
	if not ok:  # unsupplied-step trace (t, v_pu, status) — the debugging view
		report["A_dark_steps"] = dark_steps
	print("SMOKE_CITYLIFE ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
