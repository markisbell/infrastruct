extends SmokeBase
## --smoke=pumpblackout (extracted from main.gd, Phase-3 refactor plan).


## THE cross-vector scenario: a blackout at the pumping station. Without a
## tower the head collapses next step — instant dry taps. With a (small)
## tower the town rides through on stored water until the tank runs dry:
## water buys time, elevation is a battery.
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_PUMPBLACKOUT", "health timeout")
		return

	# ── phase A: pump-only network (the pump IS the pressure head)
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 15.0)
	_build_pump_town(false)
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_water_registered(120.0):
		_fail("SMOKE_PUMPBLACKOUT", "register timeout (A)")
		return
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(8, 240.0)
	var supplied_before := _water_supplied(zone_id)
	City.grid_trip_until = 1_000_000  # scripted city-wide blackout
	await _run_steps(8, 240.0)
	var supplied_dark_a := _water_supplied(zone_id)
	var dry_min_a := City.total_water_outage_minutes()

	# ── phase B: same town + a small elevated tank (params_override shrinks
	# the volume so the drain fits the smoke window)
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 15.0)
	_build_pump_town(true, {"volume_m3": 0.6, "tower_height_m": 25.0})
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_water_registered(120.0):
		_fail("SMOKE_PUMPBLACKOUT", "register timeout (B)")
		return
	zone_id = "wz_" + City.model.buildings_of_kind("water_station")[0]
	var tower_id: String = City.model.buildings_of_kind("water_tower")[0]
	var pump_id: String = City.model.buildings_of_kind("pumping_station")[0]
	var trace: Array = []
	City.water_result.connect(func(t: int, r: Dictionary) -> void:
		trace.append("t%d soc=%.2f sp=%s trip=%s conn=%s pstat=%s" % [t,
			float(r.get("devices", {}).get(tower_id, {}).get("soc", -1.0)),
			str(City._water_setpoints(t).get(pump_id, {})),
			str(City.grid_trip_until > t),
			str(City.topo.connected.get(pump_id, false)),
			str(City.last_result.get("status", "?"))]))
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(8, 240.0)
	var soc_full := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_before_b := _water_supplied(zone_id)
	City.grid_trip_until = 1_000_000
	await _run_steps(4, 240.0)  # 1 h dark: tank draining, taps still wet
	var soc_mid := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_grace := _water_supplied(zone_id)
	await _run_steps(20, 300.0)  # 5 more hours: tank runs dry
	var soc_end := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_dark_b := _water_supplied(zone_id)

	var ok: bool = supplied_before >= 0.99 and supplied_dark_a < 0.5 \
		and dry_min_a > 0 and supplied_before_b >= 0.99 and soc_full > 0.5 \
		and supplied_grace >= 0.99 and soc_mid < soc_full - 0.02 \
		and soc_end < soc_mid and supplied_dark_b < 0.99
	var report := {
		"ok": ok,
		"A_supplied_before": snappedf(supplied_before, 0.01),
		"A_supplied_dark": snappedf(supplied_dark_a, 0.01),
		"A_dry_minutes": dry_min_a,
		"B_supplied_before": snappedf(supplied_before_b, 0.01),
		"B_soc_full": snappedf(soc_full, 0.03), "B_soc_mid": snappedf(soc_mid, 0.03),
		"B_soc_end": snappedf(soc_end, 0.03),
		"B_supplied_grace": snappedf(supplied_grace, 0.01),
		"B_supplied_dark": snappedf(supplied_dark_b, 0.01),
		"water_status": City.last_water_result.get("status", "?"),
		"orch": Orchestrator.stats,
	}
	if not ok:  # per-step soc/setpoint trace — the debugging view
		report["trace"] = trace
	print("SMOKE_PUMPBLACKOUT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
