extends SmokeBase
## --smoke=boosterblackout: an INLINE booster (StationSpec pump bridging
## two pipe-run ends) loses its electric feed — sim.station_modes must
## cut the branch, drying the downstream zone while the head-side zone
## rides on the tower; power back -> the far zone recovers. Pins the
## params.station device target end-to-end against the real solver.


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_BOOSTERBLACKOUT", "health timeout")
		return
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 15.0)
	# water: tower head -> main A -> booster bridge -> main B -> far station
	City.place_building("water_tower", Vector2i(1, 1))
	for x in range(2, 7):
		City.build_water_pipe(Vector2i(x, 1))
	City.place_building("pumping_station", Vector2i(7, 0))  # taps (6,1)+(9,1)
	for x in range(9, 15):
		City.build_water_pipe(Vector2i(x, 1))
	City.place_building("water_station", Vector2i(15, 1))
	# power: grid feeds the booster through a cable column at x=7
	City.place_building("grid_connection", Vector2i(2, 5))
	for x in range(4, 8):
		City.build_cable(Vector2i(x, 6))
	for y in [2, 3, 4, 5]:
		City.build_cable(Vector2i(7, y))
	# houses on the FAR side so the booster genuinely carries the town
	for x in range(11, 17):
		City.build_road(Vector2i(x, 3))
	for x in range(11, 17):
		City.build_zone(Vector2i(x, 4))
		City.model.spawn_house(Vector2i(x, 4))
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_water_registered(120.0):
		_fail("SMOKE_BOOSTERBLACKOUT", "register timeout")
		return
	var pump_id: String = City.model.buildings_of_kind("pumping_station")[0]
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	check("booster_split", not (City.water_topo.doc["native"]["supply"]
		["stations"] as Array).is_empty())

	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(8, 240.0)
	check("far_zone_supplied_before", _water_supplied(zone_id) >= 0.99)
	check("station_enabled_before",
		bool(City._water_setpoints(City.current_t).get(pump_id, {})
			.get("enabled", false)))

	City.grid_trip_until = 1_000_000  # scripted city-wide blackout
	var dark := {"statuses": {}, "min_supplied": 2.0}
	var dark_watch := func(_t: int, r: Dictionary) -> void:
		var status: String = r.get("status", "?")
		dark["statuses"][status] = int(dark["statuses"].get(status, 0)) + 1
		var z: Dictionary = r.get("zones", {}).get(zone_id, {})
		if not z.is_empty() and (z.get("supplied") is float or z.get("supplied") is int):
			dark["min_supplied"] = minf(dark["min_supplied"], float(z["supplied"]))
	City.water_result.connect(dark_watch)
	await _run_steps(10, 300.0)
	City.water_result.disconnect(dark_watch)
	check("station_cut_dark",
		not bool(City._water_setpoints(City.current_t).get(pump_id, {})
			.get("enabled", true)))
	# downstream of a stopped booster the hydraulics DESTABILIZE: the
	# retry ladder degrades every frame and never converges (NOTE: degraded
	# frames carry optimistic supplied values — the consequence layer takes
	# them at face value, so no outage books; a known gap, candidate for a
	# stricter degraded policy)
	check("dark_never_converged",
		int(dark["statuses"].get("converged", 0)) == 0
		and not (dark["statuses"] as Dictionary).is_empty())

	City.grid_trip_until = -1  # power restored
	await _run_steps(16, 400.0)
	check("station_back",
		bool(City._water_setpoints(City.current_t).get(pump_id, {})
			.get("enabled", false)))
	check("far_zone_recovered", _water_supplied(zone_id) >= 0.99)
	check("recovered_converged",
		City.last_water_result.get("status", "failed") == "converged")

	var report := {"ok": verdict(), "failed": failed_checks(),
		"dark_frames": dark,
		"houses": City.model.houses.size(),
		"zone_houses": City.water_topo.zones_info.get(zone_id, {}).get("houses", -1),
		"supplied_final": snappedf(_water_supplied(zone_id), 0.01)}
	print("SMOKE_BOOSTERBLACKOUT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
