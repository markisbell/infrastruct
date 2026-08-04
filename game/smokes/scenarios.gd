extends SmokeBase
## --smoke=scenarios (extracted from main.gd, Phase-3 refactor plan).


## Scenario acceptance: greenfield is winnable (with a loan), the inherited
## grid loses on its own, the energy transition is winnable by retiring the
## fossil plant, and the tutorial chain advances step by step.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_SCENARIOS", "health timeout")
		return

	# ── A: greenfield — loan, build, grow to the win
	var state := Scenarios.start("greenfield", "normal")
	# the fixed reference layout must stay buildable: greenfield's seed-19
	# terrain now carries RIVERS (environment pass) — keep the build area dry
	# (players route around water; the smoke tests scenario mechanics)
	City.model.terrain.force_water(Vector2i(0, 0), Vector2i(45, 25), false)
	City.take_loan(300_000.0)  # the 110/20 kV station alone is 120k
	_build_reference_city(6)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (greenfield)")
		return
	var verdict_green := ""
	for i in 8:
		GameClock.restore({"total_minutes": (10.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_green = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_green != "":
			break
	var green_houses := City.model.houses.size()

	# ── B: inherited grid — do nothing, watch it lose
	state = Scenarios.start("brownfield", "normal")
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (brownfield)")
		return
	var verdict_brown := ""
	for i in 16:
		GameClock.restore({"total_minutes": (301.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_brown = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_brown != "":
			break
	var brown_happiness := City.happiness
	var brown_state := state.duplicate()

	# ── C: energy transition — retire the fossil plant, win
	GameClock.restore({"total_minutes": 100.0 * 1440.0, "speed": 0.0})
	state = Scenarios.start("transition", "normal")
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (transition)")
		return
	var fossil: Vector2i = City.model.buildings[
		City.model.buildings_of_kind("gas_plant")[0]]["anchor"]
	City.bulldoze(fossil)
	City.place_building("solar_park", Vector2i(20, 3))
	City.place_building("battery", Vector2i(25, 4))
	var verdict_transition := ""
	for i in 10:
		GameClock.restore({"total_minutes": (100.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_transition = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_transition != "":
			break

	# ── D: tutorial chain — perform each step, predicates must advance
	Scenarios.start("tutorial", "normal")
	var steps := Scenarios.tutorial_steps()
	var tutorial_ok := true
	City.place_building("grid_connection", Vector2i(6, 4))
	tutorial_ok = tutorial_ok and (steps[0]["done"] as Callable).call()
	for x in range(8, 13):
		City.build_cable(Vector2i(x, 5))
	City.place_building("substation", Vector2i(12, 6))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[1]["done"] as Callable).call()
	for x in range(8, 17):
		City.build_road(Vector2i(x, 8))
	for x in range(8, 17):
		City.build_zone(Vector2i(x, 9))
	tutorial_ok = tutorial_ok and (steps[2]["done"] as Callable).call()
	for x in range(8, 11):
		City.model.spawn_house(Vector2i(x, 9))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[3]["done"] as Callable).call()
	City.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 13):
		City.build_heat_pipe(Vector2i(x, 14))
	tutorial_ok = tutorial_ok and (steps[4]["done"] as Callable).call()
	City.place_building("heat_exchanger", Vector2i(13, 14))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[5]["done"] as Callable).call()
	City.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 13):
		City.build_water_pipe(Vector2i(x, 17))
	tutorial_ok = tutorial_ok and (steps[6]["done"] as Callable).call()
	City.place_building("water_station", Vector2i(13, 17))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[7]["done"] as Callable).call()

	var report := {
		"ok": verdict_green == "win" and green_houses >= 25
			and verdict_brown == "lose" and brown_happiness < 20.0
			and verdict_transition == "win" and tutorial_ok,
		"greenfield": verdict_green, "greenfield_houses": green_houses,
		"brownfield": verdict_brown,
		"brownfield_happiness": snappedf(brown_happiness, 0.1),
		"brownfield_state": brown_state,
		"transition": verdict_transition,
		"tutorial_chain": tutorial_ok,
		"orch": Orchestrator.stats,
	}
	print("SMOKE_SCENARIOS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
