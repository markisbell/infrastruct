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

	# ── E: off-grid village (power islands M4) — the prebuild registers
	# WITHOUT any grid connection, the battery forms the island, houses are
	# served, and the verdict machinery runs (no instant win/lose)
	GameClock.restore({"total_minutes": 200.0 * 1440.0, "speed": 0.0})
	state = Scenarios.start("island", "normal")
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (island)")
		return
	var island_offgrid: bool = City.model.buildings_of_kind(
		"grid_connection").is_empty() and City.topo.islands.size() == 1
	Orchestrator.start()
	await _run_steps(8, 240.0)
	var island_zone: String = "z_" + City.model.buildings_of_kind("substation")[0]
	var island_supplied: bool = City.zone_supplied.get(island_zone, false)
	var verdict_island := Scenarios.evaluate(state, City.current_t / 96)

	# ── F: Heidelberg — the reference city, and by far the biggest prebuild
	# we ship: real SRTM terrain, ~14 substations, two independent networks
	# either side of an uncrossable Neckar. The question this phase answers
	# is the one a reference build exists to answer: does a CITY-scale model
	# still register and converge on all three solvers, not just a town?
	GameClock.restore({"total_minutes": 200.0 * 1440.0, "speed": 0.0})
	state = Scenarios.start("heidelberg", "normal")
	City._topo_dirty = true
	if not await _wait_registered(600.0):
		_fail("SMOKE_SCENARIOS", "register timeout (heidelberg)")
		return
	var hd_frames := {"power": 0, "heat": 0, "water": 0}
	var hd_why := {"heat": [], "power": [], "water": []}
	for net: String in ["power", "heat", "water"]:
		var id := net
		City.get(id + "_result").connect(func(_t: int, r: Dictionary) -> void:
			if str(r.get("status", "")) == "converged":
				hd_frames[id] += 1
			elif (hd_why[id] as Array).size() < 3:
				# WHY a frame failed is the whole diagnostic value — a bare
				# converged-count says the city is broken but not where
				(hd_why[id] as Array).append({
					"status": r.get("status", ""),
					"violations": r.get("violations", []),
					"error": r.get("error", "")}))
	Orchestrator.start()
	# SLOWER CLOCK on purpose. At the default 60x this phase reported heat
	# converging 2 frames in 8 — not failures but SKIPS: the orchestrator
	# allows one in-flight step per network, and a 487-pipe / 34-exchanger
	# district-heating model does not solve inside a 60x step. The smoke is
	# asking "does a city-scale network converge", not "how fast", so give
	# it a playable clock. That heat needs one is itself the finding.
	await _run_steps(8, 600.0, 8.0)
	var hd_houses := City.model.houses.size()
	# both banks must be lit: one supplied zone per grid connection is the
	# minimum proof that the river split into two working networks
	var hd_supplied := 0
	for zone_id: String in City.zone_supplied:
		if City.zone_supplied[zone_id]:
			hd_supplied += 1

	var report := {
		"ok": verdict_green == "win" and green_houses >= 25
			and verdict_brown == "lose" and brown_happiness < 20.0
			and verdict_transition == "win" and tutorial_ok
			and island_offgrid and island_supplied and verdict_island == ""
			# MOST frames must converge, not one: a >=1 gate let the heat
			# solve fall from 9 frames to 2 (a second, unreachable district
			# heating system) while the smoke still reported ok
			and hd_houses >= 300 and hd_supplied >= 8
			and hd_frames["power"] >= 6 and hd_frames["heat"] >= 6
			and hd_frames["water"] >= 6,
		"heidelberg_houses": hd_houses,
		"heidelberg_supplied_zones": hd_supplied,
		"heidelberg_converged": hd_frames,
		"heidelberg_why": hd_why,
		"greenfield": verdict_green, "greenfield_houses": green_houses,
		"brownfield": verdict_brown,
		"brownfield_happiness": snappedf(brown_happiness, 0.1),
		"brownfield_state": brown_state,
		"transition": verdict_transition,
		"tutorial_chain": tutorial_ok,
		"island_offgrid": island_offgrid,
		"island_supplied": island_supplied,
		"island_verdict": verdict_island,
		"orch": Orchestrator.stats,
	}
	print("SMOKE_SCENARIOS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
