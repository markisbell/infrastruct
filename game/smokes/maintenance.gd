extends SmokeBase
## --smoke=maintenance (extracted from main.gd, Phase-3 refactor plan).


## Capacity signaling + paid maintenance: an undersized transformer signals,
## trips, and STAYS dark until a crew is paid; a manually tripped trunk
## section blacks out the whole downstream branch until its crew arrives.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(240.0):
		_fail("SMOKE_MAINTENANCE", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	# evening import (30 SAMPLED households incl. their concrete 22-kW EV
	# blocks — physics tier) must cross 80% of 140 kW for the warning while
	# staying under 140 so the 110/20 kV interface itself never trips
	# (grid trips at 100% sustained)
	City.grid_capacity_override = 140.0
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 33):
		City.build_cable(Vector2i(x, 5))
	# an undersized 50 kVA village trafo (explicit-parameter element): the
	# EV evening peak pushes its SOLVED loading past 120% within the run
	City.place_building("substation", Vector2i(12, 6), 0, {"rating_kva": 50.0})
	# healthy control zone FAR east — its radius must not steal A's houses
	City.place_building("substation", Vector2i(32, 6))
	for y in [8, 11]:
		for x in range(8, 21):
			City.build_road(Vector2i(x, y))
	for y in [9, 10, 12]:
		for x in range(8, 21):
			City.build_zone(Vector2i(x, y))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 30)
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_MAINTENANCE", "register timeout")
		return
	var sub_a: String = City.model.buildings_of_kind("substation")[0]
	var sub_b: String = City.model.buildings_of_kind("substation")[1]
	var zone_a := "z_" + sub_a
	var zone_b := "z_" + sub_b
	# grid warning is latched DURING the run: once zone A trips, its demand
	# drops off the wire and the end-state import sits well below the signal
	var latch := {"grid_warned": false}
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	City.power_result.connect(func(_t: int, _result: Dictionary) -> void:
		if City.capacity_warnings.has(slack_id):
			latch["grid_warned"] = true)
	GameClock.restore({"total_minutes": 301.0 * 1440.0 + 17.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(10, 240.0)
	var tripped := City.tripped_substations.has(sub_a)
	var trip_marker: bool = City.capacity_warnings.get(sub_a, {}).get("text", "") == "TRIP"
	var grid_warned: bool = latch["grid_warned"]
	var a_dark_1: bool = not City.zone_supplied.get(zone_a, true)
	var b_alive: bool = City.zone_supplied.get(zone_b, false)
	# no self-healing: well past the old 2 h auto-repair, still dark
	await _run_steps(12, 240.0)
	var a_dark_2: bool = not City.zone_supplied.get(zone_a, true)
	# pay the crew (and right-size the trafo so it doesn't re-trip; the new
	# rating is baked into the solver doc, so force a topology rebuild)
	City.model.buildings[sub_a]["params"]["rating_kva"] = 630.0
	City._topo_dirty = true
	var repaired := City.dispatch_repair(City.model.buildings[sub_a]["anchor"])
	var maintenance_cost := float(City.econ_total.get("cost_maintenance", 0.0))
	await _run_steps(City.REPAIR_STEPS + 2, 240.0)
	var a_back: bool = City.zone_supplied.get(zone_a, false)

	# ── branch disconnection: trip the trunk between the subs; everything
	# downstream (zone B) goes dark until ITS crew arrives
	for x in range(15, 18):
		City.tripped_tiles[Vector2i(x, 5)] = City.AWAITING_CREW
	City._topo_dirty = true
	await _run_steps(8, 240.0)
	# a zone cut from the topology has NO entry at all — absent means dark
	var b_dark: bool = not City.zone_supplied.get(zone_b, false)
	var trip_tile_marker := City.capacity_warnings.has("trip_0")
	var repaired_line := City.dispatch_repair(Vector2i(16, 5))
	await _run_steps(City.REPAIR_STEPS + 6, 300.0)
	var b_back: bool = City.zone_supplied.get(zone_b, false)

	var report := {
		"ok": tripped and trip_marker and grid_warned and a_dark_1 and b_alive
			and a_dark_2 and repaired and maintenance_cost == -float(City.CREW_COST)
			and a_back and b_dark and trip_tile_marker and repaired_line and b_back,
		"trafo_tripped": tripped, "trip_marker": trip_marker,
		"grid_warning": grid_warned,
		"a_dark_after_trip": a_dark_1, "b_alive_meanwhile": b_alive,
		"a_still_dark_no_autoheal": a_dark_2,
		"crew_paid": repaired, "maintenance_cost": maintenance_cost,
		"a_back_after_crew": a_back,
		"branch_dark_after_line_trip": b_dark, "trip_tile_marker": trip_tile_marker,
		"line_crew_paid": repaired_line, "b_back_after_crew": b_back,
		"warnings_seen": City.capacity_warnings.keys(),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_MAINTENANCE ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
