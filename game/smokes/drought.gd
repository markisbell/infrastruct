extends SmokeBase
## --smoke=drought (extracted from main.gd, Phase-3 refactor plan).


## Summer drought: the well's yield collapses (aquifer state via
## yield_factor) while heat drives demand up — the tower drains, then the
## taps weaken. Wagner PDD makes it gradual: weak taps before dry taps.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_DROUGHT", "health timeout")
		return
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 30.0)   # heat wave: +40% demand
	City.weather.force_drought(0, 100_000, 1.0)  # healthy aquifer first
	# tower head + well feed: well rated small via override so the balance
	# tips when the drought hits (demand ~0.5 m³/h at 24 houses)
	City.place_building("water_tower", Vector2i(8, 8), 0, {"volume_m3": 0.5})
	for x in range(9, 21):
		City.build_water_pipe(Vector2i(x, 8))
	City.place_building("well", Vector2i(12, 6), 0, {"rated_m3_h": 1.5})
	City.build_water_pipe(Vector2i(12, 7))  # well spur onto the main
	City.place_building("water_station", Vector2i(21, 8))
	for x in range(14, 31):
		City.build_road(Vector2i(x, 11))
	for x in range(14, 31):
		City.build_zone(Vector2i(x, 12))
	City.spawn_houses_bulk(City.model.buildings_of_kind("water_station")[0], 24)
	City._topo_dirty = true
	if not await _wait_water_registered(180.0):
		_fail("SMOKE_DROUGHT", "register timeout")
		return
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	var tower_id: String = City.model.buildings_of_kind("water_tower")[0]
	var well_id: String = City.model.buildings_of_kind("well")[0]
	GameClock.restore({"total_minutes": 10.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(8, 240.0)
	var soc_wet := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_wet := _water_supplied(zone_id)
	var well_q_wet := float(City.last_water_result.get("devices", {})
		.get(well_id, {}).get("detail", {}).get("q_m3h", -1.0))
	City.weather.force_drought(0, 100_000, 0.1)  # aquifer collapses
	await _run_steps(36, 360.0)                  # 9 h of net drain (sampled
		# household mixes vary — the window must empty the tower for ANY draw)
	var soc_dry := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_dry := _water_supplied(zone_id)
	var well_q_dry := float(City.last_water_result.get("devices", {})
		.get(well_id, {}).get("detail", {}).get("q_m3h", -1.0))
	var report := {
		# well_q_* stay diagnostic: full-tank throttling is backend machinery
		# the DRY PHASE is the assertion (sustained outage minutes) — the
		# final-instant supplied flag flickers under sampled demand once
		# the near-empty tower trickle momentarily covers a low quarter
		"ok": supplied_wet >= 0.99 and soc_wet > 0.3
			and soc_dry < soc_wet - 0.1
			and City.total_water_outage_minutes() >= 30,
		"soc_wet": snappedf(soc_wet, 0.01), "soc_dry": snappedf(soc_dry, 0.01),
		"supplied_wet": snappedf(supplied_wet, 0.01),
		"supplied_dry": snappedf(supplied_dry, 0.01),
		"well_q_wet": snappedf(well_q_wet, 0.01), "well_q_dry": snappedf(well_q_dry, 0.01),
		"dry_minutes": City.total_water_outage_minutes(),
		"water_status": City.last_water_result.get("status", "?"),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_DROUGHT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
