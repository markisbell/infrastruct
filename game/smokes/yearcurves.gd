extends SmokeBase
## --smoke=yearcurves (extracted from main.gd, Phase-3 refactor plan).


## Long-run seasonal recording (ROADMAP Phase 6 task 4 + acceptance): four
## 3-day workweek windows across the year, demand recorded per step to CSV;
## the load-duration shape checks are qualitative inequalities (winter heat
## peak, BDEW double peak, summer PV surplus, summer water surge) — robust
## where golden files would rot.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_YEARCURVES", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false  # constant town: curves must come from demand
	_build_reference_city(24)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_YEARCURVES", "register timeout")
		return
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var rows: Array = []
	var statuses := {"bad": 0, "total": 0}
	City.power_result.connect(func(t: int, result: Dictionary) -> void:
		var elec := 0.0
		for zone_id: String in City.topo.zones_info:
			elec += DemandModel.zone_sum_kw(
				City.topo.zones_info[zone_id]["house_tiles"], t)
		var temp := float(City.weather.sample(t)["temp_c"])
		var heat := 0.0
		for zone_id: String in City.heat_topo.zones_info:
			heat += DemandModel.heat_zone_sum_kw(
				City.heat_topo.zones_info[zone_id]["house_tiles"], t, temp)
		var water := 0.0
		for zone_id: String in City.water_topo.zones_info:
			water += DemandModel.water_zone_sum_m3h(
				City.water_topo.zones_info[zone_id]["house_tiles"], t, temp)
		var import_kw := float(result.get("devices", {})
			.get(slack_id, {}).get("output_kw", 0.0))
		rows.append([t, snappedf(elec, 0.01), snappedf(heat, 0.01),
			snappedf(water, 0.0001), snappedf(import_kw, 0.01), temp]))
	for sig: Signal in [City.power_result, City.heat_result, City.water_result]:
		sig.connect(func(_t: int, result: Dictionary) -> void:
			statuses["total"] += 1
			if result.get("status", "failed") == "failed":
				statuses["bad"] += 1)
	# windows start on workdays (day % 7 == 0): winter/transition/summer/autumn
	for start_day: int in [301, 42, 133, 224]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(288, 900.0, 200.0)
	# ── aggregate ──
	var window_of := func(t: int) -> String:
		var day := t / 96
		if day >= 301: return "winter"
		if day >= 224: return "autumn"
		if day >= 133: return "summer"
		return "transition"
	var mean := func(filter: Callable, column: int) -> float:
		var acc := 0.0
		var n := 0
		for row: Array in rows:
			if filter.call(row):
				acc += row[column]
				n += 1
		return acc / maxf(n, 1.0)
	var hour_of := func(t: int) -> int: return (t % 96) / 4
	var heat_winter: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter", 2)
	var heat_summer: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer", 2)
	var elec_w_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 1)
	var elec_w_night: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 2 and hour_of.call(r[0]) < 5, 1)
	var elec_w_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 1)
	var elec_s_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 1)
	var elec_s_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 1)
	var water_winter: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter", 3)
	var water_summer: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer", 3)
	var import_s_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 4)
	var import_s_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 4)
	# ── CSV (the durable record for tools/balancing) ──
	var csv := "t,day,elec_kw,heat_kw,water_m3h,grid_import_kw,temp_c\n"
	for row: Array in rows:
		csv += "%d,%d,%s,%s,%s,%s,%s\n" % [row[0], row[0] / 96, row[1], row[2],
			row[3], row[4], row[5]]
	var csv_path := _repo_file("logs/yearcurves.csv")
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f:
		f.store_string(csv)
		f.close()
	var report := {
		"ok": heat_winter > 3.0 * heat_summer
			and elec_w_evening > 2.0 * elec_w_night
			and elec_w_evening > 1.15 * elec_w_midday
			# summer PV surplus: NET zone load (realism pass: rooftop PV is
			# part of the composition) collapses at midday — often negative —
			# while the EV evening peak stands tall
			and elec_s_midday < 0.5 * elec_s_evening
			and water_summer > 1.15 * water_winter
			and import_s_midday < import_s_evening - 20.0
			and statuses["bad"] == 0
			# drift/leak guard: failed solves and protocol desync are the
			# signal; a few in-flight overrun skips at 200x fast-forward are
			# the designed never-stall behavior, so the bound is generous
			and Orchestrator.stats["missed"] < 0.10 * Orchestrator.stats["dispatched"]
			and Orchestrator.stats["completed"] == Orchestrator.stats["dispatched"],
		"heat_kw_winter": snappedf(heat_winter, 0.1), "heat_kw_summer": snappedf(heat_summer, 0.1),
		"elec_winter_evening": snappedf(elec_w_evening, 0.1),
		"elec_winter_midday": snappedf(elec_w_midday, 0.1),
		"elec_winter_night": snappedf(elec_w_night, 0.1),
		"elec_summer_midday": snappedf(elec_s_midday, 0.1),
		"elec_summer_evening": snappedf(elec_s_evening, 0.1),
		"water_m3h_winter": snappedf(water_winter, 0.001),
		"water_m3h_summer": snappedf(water_summer, 0.001),
		"grid_import_summer_midday": snappedf(import_s_midday, 0.1),
		"grid_import_summer_evening": snappedf(import_s_evening, 0.1),
		"failed_steps": statuses["bad"], "results_seen": statuses["total"],
		"samples": rows.size(), "csv": csv_path,
		"orch": Orchestrator.stats,
	}
	print("SMOKE_YEARCURVES ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
