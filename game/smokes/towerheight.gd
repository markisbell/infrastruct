extends SmokeBase
## --smoke=towerheight (extracted from main.gd, Phase-3 refactor plan).


## Hydraulics check the player can feel: the same town fed by a 25 m vs a
## 45 m tower — the taller tower holds ~2 bar more at the taps (Δh≈20 m).
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_TOWERHEIGHT", "health timeout")
		return
	var p_bars := {}
	for height: float in [25.0, 45.0]:
		City.reset_for_scenario(42)
		City.weather.force_temp(0, 100_000, 15.0)
		City.place_building("water_tower", Vector2i(8, 8), 0,
			{"tower_height_m": height})
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
			_fail("SMOKE_TOWERHEIGHT", "register timeout (%.0f m)" % height)
			return
		var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
		GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(6, 240.0)
		p_bars[height] = _water_p_bar(zone_id)
	var p_25: float = p_bars[25.0]
	var p_45: float = p_bars[45.0]
	var report := {
		"ok": p_25 > 0.0 and p_45 > p_25 + 1.5 and p_45 < p_25 + 2.5,
		"p_bar_25m": snappedf(p_25, 0.01), "p_bar_45m": snappedf(p_45, 0.01),
		"delta_bar": snappedf(p_45 - p_25, 0.01),
		"expected_delta_bar": 1.96,
		"water_status": City.last_water_result.get("status", "?"),
	}
	print("SMOKE_TOWERHEIGHT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
