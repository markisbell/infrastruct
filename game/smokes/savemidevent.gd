extends SmokeBase
## --smoke=savemidevent: envelope v4 claims trips, event-system state
## (incl. RNG position), weather overrides and SoC survive loads — pin a
## save taken IN THE MIDDLE of an active storm + equipment failure +
## pipe burst, then prove the loaded city still SOLVES.

const SLOT := "user://smoke_midevent.json"


## JSON-normalized comparison: the envelope round-trip turns ints into
## floats (Godot wire rule) — canonicalize both sides before comparing.
static func _canon(value: Variant) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(value)))


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_SAVEMIDEVENT", "health timeout")
		return
	City.reset_for_scenario(42)
	_build_reference_city(8)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_SAVEMIDEVENT", "register timeout")
		return
	GameClock.restore({"total_minutes": 9.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(4, 240.0)

	# mid-run chaos: storm + gas-plant failure + a trunk pipe burst
	var gas_id: String = City.model.buildings_of_kind("gas_plant")[0]
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	City._apply_event(City.event_system.force_storm(City.weather,
		City.current_t), City.current_t)
	City._apply_event(City.event_system.force_equipment_failure(gas_id,
		City.current_t), City.current_t)
	City._apply_event(City.event_system.make_burst(Vector2i(10, 17),
		[zone_id], City.current_t), City.current_t)
	await _run_steps(4, 240.0)

	var pre := {
		"tripped": City.tripped_tiles.duplicate(),
		"down_until": City.event_system.down_until.duplicate(),
		"draws": City.event_system.water_draws.duplicate(),
		"rng_state": City.event_system.rng.state,
		"storm_wind": City.weather.sample(City.current_t + 4)["wind_ms"],
		"money": City.money, "t": City.current_t,
	}
	SaveGame.save_to(SLOT)

	# wreck the live state so the load has to do real work
	City.dispatch_repair(Vector2i(10, 17))
	City.money = 1
	await _run_steps(8, 300.0)

	var load_result: Dictionary = SaveGame.load_from(SLOT)
	check("load_ok", bool(load_result.get("ok", false)))
	# City.current_t stays STALE until the next sim step after a BACKWARDS
	# restore (documented gotcha) — the clock is the source of truth here
	check("t_restored", int(GameClock.total_minutes
		/ GameClock.SIM_STEP_MINUTES) == int(pre["t"]))
	check("money_restored", City.money == int(pre["money"]))
	check("trips_restored",
		_canon(City.tripped_tiles.keys().map(func(k: Vector2i) -> String: return str(k)))
			== _canon(pre["tripped"].keys().map(func(k: Vector2i) -> String: return str(k))))
	check("equipment_failure_restored",
		_canon(City.event_system.down_until) == _canon(pre["down_until"]))
	check("burst_draw_restored",
		_canon(City.event_system.water_draws) == _canon(pre["draws"]))
	check("event_rng_position_restored",
		City.event_system.rng.state == int(pre["rng_state"]))
	# KNOWN GAP (documented, not asserted): the storm's forced-wind
	# override window is NOT in the envelope — only the event bookkeeping
	# survives; after a load the wind returns to the seeded series.
	# Candidate envelope v5 field: WeatherSystem override windows.

	# and the loaded mid-event city must still SOLVE — power and heat
	# re-register; WATER must NOT (the restored burst still severs the
	# main's head: staying down after the load is the honest state)
	if not await _wait_registered(240.0) or not await _wait_heat_registered(120.0):
		_fail("SMOKE_SAVEMIDEVENT", "power/heat re-register after load timeout")
		return
	check("water_still_down_after_load", not City.water_registered)
	Orchestrator.start()
	await _run_steps(4, 240.0)
	check("solves_after_load",
		City.last_result.get("status", "failed") == "converged")

	var report := {"ok": verdict(), "failed": failed_checks(),
		"t": City.current_t}
	print("SMOKE_SAVEMIDEVENT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
