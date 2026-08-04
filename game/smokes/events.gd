extends SmokeBase
## --smoke=events (extracted from main.gd, Phase-3 refactor plan).


## Failure events: every kind exercised scripted, consequences physically
## solved — storm cut-out, equipment failure + repair, planned maintenance,
## hydrant fire flow (pressure sag), pipe burst (topology loss + recovery).
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_EVENTS", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	_build_reference_city(24)
	City.place_building("wind_farm", Vector2i(27, 4))  # storm test subjects:
	City.place_building("wind_farm", Vector2i(28, 4))  # three 3-MW turbines
	City.place_building("wind_farm", Vector2i(29, 4))  # on the y=5 cable row
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_EVENTS", "register timeout")
		return
	var wind_id: String = City.model.buildings_of_kind("wind_farm")[0]
	var gas_id: String = City.model.buildings_of_kind("gas_plant")[0]
	var pump_id: String = City.model.buildings_of_kind("pumping_station")[0]
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	var wind_out := func() -> float:
		return float(City.last_result.get("devices", {})
			.get(wind_id, {}).get("output_kw", -1.0))
	var gas_out := func() -> float:
		return float(City.last_result.get("devices", {})
			.get(gas_id, {}).get("output_kw", -1.0))
	var pump_q := func() -> float:
		return float(City.last_water_result.get("devices", {})
			.get(pump_id, {}).get("detail", {}).get("q_m3h", -1.0))

	# steady breeze so the turbines have something to lose — 7 m/s ≈ 26 kW;
	# 10 m/s was 141 kW and TRIPPED the feeder, islanding half the city
	City.weather.force_wind(0, 1_000_000, 7.0)
	GameClock.restore({"total_minutes": 301.0 * 1440.0 + 17.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(6, 240.0)
	var wind_pre: float = wind_out.call()
	var p_bar_pre := _water_p_bar(zone_id)
	var pump_pre: float = pump_q.call()

	# 1. STORM: forced above the 25 m/s cut-out — output must drop to zero
	City._apply_event(City.event_system.force_storm(City.weather, City.current_t), City.current_t)
	await _run_steps(4, 240.0)
	var wind_storm: float = wind_out.call()
	var gas_storm: float = gas_out.call()  # dark + windless: gas carries the town

	# 2. EQUIPMENT FAILURE on the gas plant (repair crew: 24 steps)
	City._apply_event(City.event_system.force_equipment_failure(gas_id, City.current_t), City.current_t)
	await _run_steps(4, 240.0)
	var gas_down: float = gas_out.call()
	await _run_steps(24, 300.0)
	var gas_back: float = gas_out.call()

	# 3. PLANNED MAINTENANCE on the pumping station
	City._apply_event(City.event_system.schedule_maintenance(pump_id, City.current_t, 8), City.current_t)
	await _run_steps(4, 240.0)
	var pump_maint: float = pump_q.call()

	# 4. FIRE: hydrant flow sags the zone pressure, physically solved
	await _run_steps(8, 240.0)  # let the pump come back first
	var p_bar_before_fire := _water_p_bar(zone_id)
	City._apply_event(City.event_system.force_fire(zone_id, City.current_t), City.current_t)
	await _run_steps(4, 240.0)
	var p_bar_fire := _water_p_bar(zone_id)
	# gate hardening 2026-08-04: the baseline is rock-steady (p_bar_pre ==
	# p_bar_before_fire to the hundredth), so the solved ~0.09-bar sag is
	# clean signal — pinned at 0.07 (was 0.05). The 48 m³/h itself is served
	# from the TOWER buffer, not extra pump flow (the pump holds its rated
	# ~20 m³/h hysteresis duty) — so the pump term only pins "still running".
	var pump_fire: float = pump_q.call()

	# 5. PIPE BURST on the trunk: the only head is cut off — network down,
	# repair + resync bring it back
	await _run_steps(8, 240.0)
	City._apply_event(City.event_system.make_burst(Vector2i(10, 17),
		["%s" % zone_id], City.current_t), City.current_t)
	await _run_steps(10, 300.0)
	# down = deregistered/emptied topology OR a solved dry frame (gate
	# hardening 2026-08-04 — the registration proxy alone said nothing
	# about supply; pre-burst solvedness is pinned by the fire p_bar pair)
	var water_down_during_burst := not City.water_registered \
		or City.water_topo.zones_info.is_empty() \
		or _water_supplied(zone_id) < 0.5
	await _run_steps(24, 400.0)
	var supplied_after := _water_supplied(zone_id)
	# storm expiry: its force-wind window is until_t = storm start + 96 —
	# by here we are past it, the 7 m/s base series resumes, rotors spin
	await _run_steps(12, 300.0)
	var wind_recovered: float = wind_out.call()

	var report := {
		"ok": wind_pre > 10.0 and wind_storm == 0.0 and gas_storm > 5.0
			and gas_down == 0.0 and gas_back > 5.0
			and pump_pre > 0.0 and pump_maint == 0.0
			and p_bar_fire < p_bar_before_fire - 0.07 and pump_fire > 15.0
			and water_down_during_burst and supplied_after >= 0.99
			and wind_recovered > 10.0,
		"wind_pre": snappedf(wind_pre, 0.1), "wind_storm": wind_storm,
		"gas_storm": snappedf(gas_storm, 0.1), "gas_down": gas_down,
		"gas_back": snappedf(gas_back, 0.1),
		"pump_pre": snappedf(pump_pre, 0.1), "pump_maint": pump_maint,
		"p_bar_pre": snappedf(p_bar_pre, 0.01),
		"p_bar_before_fire": snappedf(p_bar_before_fire, 0.01),
		"p_bar_fire": snappedf(p_bar_fire, 0.01),
		"pump_fire": snappedf(pump_fire, 0.1),
		"water_down_during_burst": water_down_during_burst,
		"supplied_after_burst": snappedf(supplied_after, 0.01),
		"wind_recovered": snappedf(wind_recovered, 0.1),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_EVENTS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
