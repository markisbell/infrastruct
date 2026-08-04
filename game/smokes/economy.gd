extends SmokeBase
## --smoke=economy (extracted from main.gd, Phase-3 refactor plan).


## Economy acceptance: tariffs earn on DELIVERED energy/water, fuel tracks
## the solved plant output, seasons move both — and a blackout day visibly
## costs revenue. Window totals land in tools/balancing/economy_windows.csv.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_ECONOMY", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	_build_reference_city(24)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_ECONOMY", "register timeout")
		return
	var snaps: Array[Dictionary] = []
	for start_day: int in [301, 133]:  # winter, summer — 2 days each
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		var before := City.econ_total.duplicate()
		await _run_steps(192, 600.0, 200.0)
		snaps.append(_econ_delta(City.econ_total, before))
	# a scripted blackout day: the grid trips, delivered energy collapses
	GameClock.restore({"total_minutes": 303.0 * 1440.0, "speed": 0.0})
	City.grid_trip_until = 1_000_000
	Orchestrator.start()
	var before_dark := City.econ_total.duplicate()
	await _run_steps(96, 400.0, 200.0)
	var dark := _econ_delta(City.econ_total, before_dark)
	var winter: Dictionary = snaps[0]
	var summer: Dictionary = snaps[1]
	# balancing sheet: category totals per window
	var csv := "category,winter_2d,summer_2d,blackout_1d\n"
	var keys := {}
	for window: Dictionary in [winter, summer, dark]:
		for key: String in window:
			keys[key] = true
	var sorted_keys := keys.keys()
	sorted_keys.sort()
	for key: String in sorted_keys:
		csv += "%s,%.2f,%.2f,%.2f\n" % [key, winter.get(key, 0.0),
			summer.get(key, 0.0), dark.get(key, 0.0)]
	var csv_path := _repo_file("tools/balancing/economy_windows.csv")
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f:
		f.store_string(csv)
		f.close()
	var report := {
		"ok": float(winter.get("income_elec", 0.0)) > 0.0
			and float(winter.get("income_heat", 0.0)) > 0.0
			and float(winter.get("income_water", 0.0)) > 0.0
			and float(winter.get("cost_fuel", 0.0)) < 0.0
			and float(winter.get("cost_upkeep", 0.0)) < 0.0
			and float(winter.get("income_heat", 0.0)) > 2.0 * float(summer.get("income_heat", 0.0))
			and absf(float(winter.get("cost_fuel", 0.0))) > absf(float(summer.get("cost_fuel", 0.0)))
			and _econ_net(winter) + _econ_net(summer) > 0.0
			and float(dark.get("income_elec", 0.0)) < 0.2 * float(winter.get("income_elec", 1.0)) / 2.0,
		"winter_2d": winter, "summer_2d": summer, "blackout_1d": dark,
		"net_winter": snappedf(_econ_net(winter), 0.01),
		"net_summer": snappedf(_econ_net(summer), 0.01),
		"csv": csv_path,
	}
	print("SMOKE_ECONOMY ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


static func _econ_net(delta: Dictionary) -> float:
	var net := 0.0
	for key: String in delta:
		if not key.begins_with("loan"):
			net += delta[key]
	return net
