extends SmokeBase
## --smoke=commercial: the commercial pass end-to-end. An XL (1000-kVA)
## substation zone takes commercial paint; the headroom gate admits lots
## until the station's rating is spoken for (a 630 zone admits fewer); a
## FOOD plant still draws process heat at 24 °C; the charging park is its
## own MV zone with spiky sessions and bills the charging tariff. All
## sums flow through the real solvers on all three networks.


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_COMMERCIAL", "health timeout")
		return
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 24.0)  # SUMMER: the food-heat probe

	# power: grid feed, one XL zone, one standard-630 zone, charging park
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 31):
		City.build_cable(Vector2i(x, 5))
	var xl_id := City.place_substation_xl(Vector2i(12, 6))
	City.place_building("substation", Vector2i(28, 6))
	City.place_building("charging_park", Vector2i(22, 3))
	# commercial paint: a strip per zone, roads for lot access
	for x in range(9, 17):
		City.build_road(Vector2i(x, 8))
		City.build_zone(Vector2i(x, 7), WorldModel.ZONE_COMMERCIAL)
	for x in range(26, 31):
		City.build_road(Vector2i(x, 8))
		City.build_zone(Vector2i(x, 7), WorldModel.ZONE_COMMERCIAL)
	# heat + water so the lots draw on all three networks
	City.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 15):
		City.build_heat_pipe(Vector2i(x, 14))
	City.place_building("heat_exchanger", Vector2i(15, 14))
	City.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 15):
		City.build_water_pipe(Vector2i(x, 17))
	City.place_building("water_station", Vector2i(15, 17))

	check("xl_placed", xl_id != "")
	check("xl_rating", float(City.model.building_params(xl_id)
		.get("rating_kva", 0.0)) == 1000.0)

	# one FOOD plant pinned where ALL THREE zones cover it (the summer-heat
	# and water probes must not depend on the hash type draw)
	City._refresh_topo_assignment()
	check("food_pinned", City.model.spawn_commercial(Vector2i(14, 7),
		WorldModel.COMMERCIAL_FOOD))
	City._refresh_topo_assignment()

	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_COMMERCIAL", "register timeout")
		return

	# ── the growth gate needs SUPPLIED zones (a solved step) — then it
	# admits lots until the station rating is spoken for
	GameClock.restore({"total_minutes": (3.0 * 24.0 + 10.0) * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(2, 240.0)
	var radius: int = BuildingDefs.get_def("substation")["zone_radius"]
	var guard := 0
	while City._try_spawn_commercial(radius) and guard < 20:
		guard += 1
	City._refresh_topo_assignment()
	var xl_lots := 0
	var std_lots := 0
	for pos: Vector2i in City.model.commercial:
		if pos.x < 20:
			xl_lots += 1
		else:
			std_lots += 1
	check("gate_admitted_lots", guard >= 2)
	check("xl_hosts_more", xl_lots > std_lots)
	var park_id: String = City.model.buildings_of_kind("charging_park")[0]
	var cp_zone := "cp_" + park_id
	check("cp_zone_in_doc", City.topo.zones_info.has(cp_zone))
	var xl_zone := "z_" + xl_id

	# ── a workday noon window: sessions, sums, solves
	var window := {"converged": 0, "cp_max": 0.0, "elec_max": 0.0,
		"heat_max": 0.0, "water_max": 0.0, "trafo_max": 0.0}
	var watch := func(t: int, r: Dictionary) -> void:
		if r.get("status", "") == "converged":
			window["converged"] = int(window["converged"]) + 1
		window["cp_max"] = maxf(float(window["cp_max"]),
			City._zone_power_kw(cp_zone, t))
		window["elec_max"] = maxf(float(window["elec_max"]),
			City._zone_power_kw(xl_zone, t))
		for edge_id: String in City.topo.trafo_subs:
			if City.topo.trafo_subs[edge_id] == xl_id:
				window["trafo_max"] = maxf(float(window["trafo_max"]), float(
					r.get("edges", {}).get(edge_id, {})
					.get("loading_percent", 0.0)))
	City.power_result.connect(watch)
	await _run_steps(10, 300.0)
	City.power_result.disconnect(watch)
	var temp := 24.0
	for zone_id: String in City.heat_topo.zones_info:
		window["heat_max"] = maxf(float(window["heat_max"]),
			DemandModel.commercial_heat_sum_kw(
				City.heat_topo.zones_info[zone_id].get("commercial_tiles", []),
				City.model.commercial, City.current_t, temp))
	for zone_id: String in City.water_topo.zones_info:
		window["water_max"] = maxf(float(window["water_max"]),
			DemandModel.commercial_water_sum_m3h(
				City.water_topo.zones_info[zone_id].get("commercial_tiles", []),
				City.model.commercial, City.current_t))

	check("noon_converged", int(window["converged"]) >= 5)
	check("commercial_load_real", float(window["elec_max"]) > 100.0)
	check("charging_sessions_seen", float(window["cp_max"]) > 150.0)
	check("xl_trafo_carries", float(window["trafo_max"]) > 5.0
		and float(window["trafo_max"]) < 120.0)
	check("summer_process_heat", float(window["heat_max"]) > 50.0)
	check("commercial_water_draw", float(window["water_max"]) > 0.5)
	check("charging_income_booked",
		float(City.econ_today.get("income_charging", 0.0)) > 0.0)
	check("elec_income_booked",
		float(City.econ_today.get("income_elec", 0.0)) > 0.0)

	var report := {"ok": verdict(), "failed": failed_checks(),
		"xl_lots": xl_lots, "std_lots": std_lots,
		"cp_max_kw": snappedf(float(window["cp_max"]), 0.1),
		"elec_max_kw": snappedf(float(window["elec_max"]), 0.1),
		"heat_max_kw": snappedf(float(window["heat_max"]), 0.1),
		"water_max_m3h": snappedf(float(window["water_max"]), 0.01),
		"trafo_max_pct": snappedf(float(window["trafo_max"]), 0.1),
		"charging_eur": snappedf(
			float(City.econ_today.get("income_charging", 0.0)), 0.01)}
	print("SMOKE_COMMERCIAL ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
