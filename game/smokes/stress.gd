extends SmokeBase
## --smoke=stress (extracted from main.gd, Phase-3 refactor plan).


## Freeze hunt: build like a player (tile drags, then plants) with the clock
## running against the real backend; measure the worst frame stall per phase.
var _stall := {"phase": "", "worst_ms": {}}

func run() -> void:
	# own ports (8014/8015) so a live play session on 8010/8011 is untouched
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_STRESS", "power health timeout")
		return
	City.money = 100_000_000
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 4.0})
	Orchestrator.start()
	_stall["worst_ms"] = {}
	var power_frames := {"converged": 0}  # Dictionary: lambdas capture by ref
	City.power_result.connect(func(_t: int, r: Dictionary) -> void:
		if str(r.get("status", "")) == "converged":
			power_frames["converged"] += 1)
	await _stress_phase("gc+substations", func() -> void:
		City.place_building("grid_connection", Vector2i(10, 10))
		City.place_building("substation", Vector2i(30, 10))
		City.place_building("substation", Vector2i(30, 24)))
	await _stress_phase("cable_drag", func() -> void:
		for x in range(12, 30):
			City.build_cable(Vector2i(x, 10))
		for y in range(11, 25):
			City.build_cable(Vector2i(20, y))
		for x in range(21, 30):
			City.build_cable(Vector2i(x, 24)))
	await _stress_phase("road_drag", func() -> void:
		for x in range(24, 44):
			City.build_road(Vector2i(x, 12))
			City.build_road(Vector2i(x, 15))
			City.build_road(Vector2i(x, 26)))
	await _stress_phase("zone_drag", func() -> void:
		for x in range(24, 44):
			for y in [13, 14, 27]:
				City.build_zone(Vector2i(x, y)))
	await _stress_phase("houses", func() -> void:
		for sub_id: String in City.model.buildings_of_kind("substation"):
			City.spawn_houses_bulk(sub_id, 30))
	# plants one by one, waiting between them like a human would
	for plant: Array in [["wind_farm", Vector2i(14, 6)], ["wind_farm", Vector2i(15, 6)],
			["wind_farm", Vector2i(14, 7)], ["solar_park", Vector2i(24, 6)],
			["gas_plant", Vector2i(34, 6)], ["battery", Vector2i(17, 8)]]:
		await _stress_phase("plant_" + plant[0], func() -> void:
			City.place_building(plant[0], plant[1])
			for y in range(7, 10):
				City.build_cable(Vector2i(plant[1].x + 1, y)))
		await _stress_wait(2.0, "after_" + plant[0])
	await _stress_wait(8.0, "running")
	var report := {"ok": true, "worst_ms": _stall["worst_ms"],
		"registered": City.registered, "houses": City.model.houses.size(),
		"converged_frames": power_frames["converged"]}
	for phase: String in _stall["worst_ms"]:
		if float(_stall["worst_ms"][phase]) > 250.0:
			report["ok"] = false
	# timing alone is not a pass (gate hardening 2026-08-04): the run must
	# have registered, grown its town AND solved at least one power frame —
	# a silently failed registration used to exit 0 on frame times alone.
	# (This layout deterministically yields 47 houses — lots cap the bulk
	# spawn below the 2x30 request; 40 still pins "town actually built".)
	if not (City.registered and City.model.houses.size() >= 40
			and power_frames["converged"] >= 1):
		report["ok"] = false
	print("SMOKE_STRESS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)

func _stress_phase(name: String, action: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	action.call()
	var blocking_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_stall["worst_ms"][name] = snappedf(blocking_ms, 0.1)
	await get_tree().process_frame

func _stress_wait(seconds: float, name: String) -> void:
	var worst := 0.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
	_stall["worst_ms"][name] = snappedf(worst, 0.1)
