extends SmokeBase
## --smoke=hilltower (extracted from main.gd, Phase-3 refactor plan).


## Terrain hydraulics: the SAME tower on a 4-level (20 m) hill vs in the
## valley — junction elevations come from per-tile heights now, so the
## hilltop tower must deliver ~1.96 bar more at the taps (ROADMAP Phase 5
## task 3 / elevation acceptance).
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_HILLTOWER", "health timeout")
		return
	var p_bars := {}
	for hill_level: int in [0, 4]:
		City.reset_for_scenario(42)
		City.weather.force_temp(0, 100_000, 15.0)
		if hill_level > 0:
			City.model.terrain.force_height(Vector2i(6, 6), Vector2i(10, 10), hill_level)
		City.place_building("water_tower", Vector2i(8, 8))
		for x in range(9, 21):
			City.build_water_pipe(Vector2i(x, 8))
		City.place_building("water_station", Vector2i(21, 8))
		for x in range(14, 31):
			City.build_road(Vector2i(x, 11))
		for x in range(14, 31):
			City.build_zone(Vector2i(x, 12))
		City.spawn_houses_bulk(City.model.buildings_of_kind("water_station")[0], 12)
		City._topo_dirty = true
		if not await _wait_water_registered(180.0):
			_fail("SMOKE_HILLTOWER", "register timeout (hill %d)" % hill_level)
			return
		var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
		GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(6, 240.0)
		p_bars[hill_level] = _water_p_bar(zone_id)
	var p_valley: float = p_bars[0]
	var p_hill: float = p_bars[4]
	var report := {
		"ok": p_valley > 0.0 and p_hill > p_valley + 1.5 and p_hill < p_valley + 2.5,
		"p_bar_valley": snappedf(p_valley, 0.01), "p_bar_hill": snappedf(p_hill, 0.01),
		"delta_bar": snappedf(p_hill - p_valley, 0.01),
		"expected_delta_bar": 1.96,  # 4 levels x 5 m = 20 m of water column
		"water_status": City.last_water_result.get("status", "?"),
	}
	print("SMOKE_HILLTOWER ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
