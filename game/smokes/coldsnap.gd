extends SmokeBase
## --smoke=coldsnap (extracted from main.gd, Phase-3 refactor plan).


## January cold snap: undersized network → the FAR zone at the end of a long
## thin spur goes cold first (pandapipes gradient); adding a CHP near the far
## end fixes the heat AND relieves the grid (coupling); a heat-pump town on a
## weak grid connection blacks itself out.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_COLDSNAP", "health timeout")
		return

	# ── phase A: boiler + near cluster (24 houses) + tiny far zone at the
	# end of a ~850 m trunk — deep cold forced the whole run
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, -18.0)
	City.weather.force_wind(0, 100_000, 7.0)
	City.place_building("boiler_plant", Vector2i(8, 8))
	for x in range(10, 61):  # ~1.25 km trunk — the far end is FAR
		City.build_heat_pipe(Vector2i(x, 9))
	City.place_building("heat_exchanger", Vector2i(14, 10))
	City.place_building("heat_exchanger", Vector2i(60, 10))
	for x in range(10, 27):
		City.build_road(Vector2i(x, 12))
	for x in range(10, 27):
		City.build_zone(Vector2i(x, 13))
	for x in range(56, 65):
		City.build_road(Vector2i(x, 12))
	for x in range(56, 65):
		City.build_zone(Vector2i(x, 13))
	# power net for the near cluster (needed for the coupling checks)
	City.place_building("grid_connection", Vector2i(8, 16))
	for x in range(10, 47):
		City.build_cable(Vector2i(x, 17))
	City.place_building("substation", Vector2i(20, 18))
	var heat_subs := City.model.buildings_of_kind("heat_exchanger")
	City.spawn_houses_bulk(heat_subs[0], 24)  # near
	City.spawn_houses_bulk(heat_subs[1], 2)   # far: tiny flow -> deep temp drop
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_heat_registered(60.0):
		_fail("SMOKE_COLDSNAP", "register timeout (A)")
		return
	var near_zone := "hz_" + heat_subs[0]
	var far_zone := "hz_" + heat_subs[1]
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(10, 240.0)
	var near_a := _heat_zone_t(near_zone)
	var far_a := _heat_zone_t(far_zone)
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var import_a := float(City.last_result.get("devices", {})
		.get(slack_id, {}).get("output_kw", 0.0))
	var far_cold_minutes: int = City.heat_outage_minutes.get(far_zone, 0)

	# ── phase B: CHP feed near the far end, cable-connected to the grid
	# the CHP must touch the trunk DIRECTLY: a dead-end stub is rejected by
	# the heat contract (leaf junctions without consumers carry no flow)
	City.place_building("chp_plant", Vector2i(44, 7))  # footprint row (44-45,8) touches the trunk at y=9
	# cable route NORTH of the pipe trunk (cables cannot cross pipes):
	# CHP top (44,7) -> west along y=6 -> south along x=7 -> grid connection
	for x in range(8, 45):
		City.build_cable(Vector2i(x, 6))
	for y in range(7, 17):
		City.build_cable(Vector2i(7, y))
	# explicit awaited re-registration (the debounce path is fire-and-forget)
	City._topo_dirty = false
	City.topo = PowerTopology.build(City.model, City.tripped_tiles)
	City.heat_topo = HeatTopology.build(City.model, City.tripped_tiles)
	City._syncing = true
	await City._register_async()
	Orchestrator.start()
	await _run_steps(12, 240.0)
	var far_b := _heat_zone_t(far_zone)
	var cpl := float(City.last_result.get("devices", {})
		.get("cpl_heat", {}).get("output_kw", 0.0))
	var import_b := float(City.last_result.get("devices", {})
		.get(slack_id, {}).get("output_kw", 0.0))
	var debug_b := {
		"registered": [City.registered, City.heat_registered],
		"heat_devices": City.heat_topo.doc.get("devices", []).map(
			func(d: Dictionary) -> String: return "%s:%s" % [d["id"], d["kind"]]),
		"power_has_cpl": City.topo.doc.get("devices", []).any(
			func(d: Dictionary) -> bool: return d["id"] == "cpl_heat"),
		"heat_result_devices": City.last_heat_result.get("devices", {}).keys(),
		"events_tail": City.events.slice(maxi(0, City.events.size() - 4)).map(
			func(e: Dictionary) -> String: return str(e["kind"])),
	}

	# ── phase C: heat-pump town on a weak grid connection → blackout
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, -18.0)
	City.weather.force_wind(0, 100_000, 7.0)
	City.grid_capacity_override = 25.0
	City.place_building("heat_pump_plant", Vector2i(8, 8))
	for x in range(10, 21):  # pipe reaches (20,9), adjacent to the exchanger
		City.build_heat_pipe(Vector2i(x, 9))
	City.place_building("heat_exchanger", Vector2i(20, 10))
	for x in range(12, 29):
		City.build_road(Vector2i(x, 12))
	for x in range(12, 29):
		City.build_zone(Vector2i(x, 13))
	City.place_building("grid_connection", Vector2i(8, 16))
	for x in range(10, 24):
		City.build_cable(Vector2i(x, 17))
	for y in range(10, 16):
		# vertical run at x=9: touches the heat pump at (9,9) above and the
		# grid connection footprint at (9,16) below — the coupling path
		City.build_cable(Vector2i(9, y))
	City.place_building("substation", Vector2i(23, 18))  # touches cable (23,17)
	City.spawn_houses_bulk(City.model.buildings_of_kind("heat_exchanger")[0], 24)
	var trip_seen := {"grid": false}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "grid_trip":
			trip_seen["grid"] = true)
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_heat_registered(60.0):
		_fail("SMOKE_COLDSNAP", "register timeout (C)")
		return
	GameClock.restore({"total_minutes": 32.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(14, 240.0)

	var report := {
		"ok": far_a < near_a - 2.0 and far_a < HeatTopology.T_SUPPLY_MIN_C
			and near_a >= HeatTopology.T_SUPPLY_MIN_C and far_cold_minutes > 0
			and far_b >= HeatTopology.T_SUPPLY_MIN_C
			and cpl < -30.0 and import_b < import_a - 20.0
			and trip_seen["grid"] and City.total_outage_minutes() > 0,
		"near_t_A": snappedf(near_a, 0.1), "far_t_A": snappedf(far_a, 0.1),
		"far_cold_min_A": far_cold_minutes,
		"far_t_B": snappedf(far_b, 0.1), "cpl_heat_kw_B": snappedf(cpl, 0.1),
		"grid_import_A": snappedf(import_a, 0.1), "grid_import_B": snappedf(import_b, 0.1),
		"hp_grid_trip_C": trip_seen["grid"],
		"power_outage_min_C": City.total_outage_minutes(),
		"debug_b": debug_b,
	}
	print("SMOKE_COLDSNAP ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
