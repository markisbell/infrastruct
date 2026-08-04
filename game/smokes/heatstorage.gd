extends SmokeBase
## --smoke=heatstorage (extracted from main.gd, Phase-3 refactor plan).


## Buffer storage: charged at night, bridges the morning demand peak
## (assert on the SoC trajectory from the step results).
func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_HEATSTORAGE", "health timeout")
		return
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, -5.0)
	City.place_building("boiler_plant", Vector2i(8, 8))
	for x in range(10, 26):  # pipe reaches (25,9), adjacent to the exchanger
		City.build_heat_pipe(Vector2i(x, 9))
	City.place_building("heat_exchanger", Vector2i(25, 10))
	City.place_building("heat_storage", Vector2i(16, 10))  # adjacent to the trunk
	for x in range(14, 34):
		City.build_road(Vector2i(x, 12))
	for x in range(14, 34):
		City.build_zone(Vector2i(x, 13))
	City.spawn_houses_bulk(City.model.buildings_of_kind("heat_exchanger")[0], 20)
	City._topo_dirty = true
	if not await _wait_heat_registered(180.0):
		_fail("SMOKE_HEATSTORAGE", "register timeout")
		return
	var storage_id: String = City.model.buildings_of_kind("heat_storage")[0]
	var soc_series := {}
	var discharge_kw := {"max": 0.0, "probe": {}, "statuses": {}}
	City.heat_result.connect(func(t: int, result: Dictionary) -> void:
		var status: String = result.get("status", "?")
		discharge_kw["statuses"][status] = discharge_kw["statuses"].get(status, 0) + 1
		var device: Dictionary = result.get("devices", {}).get(storage_id, {})
		if not device.is_empty() and device.get("soc") != null:
			soc_series[t % 96] = float(device["soc"])
			var hour := (t * 15 % 1440) / 60
			if hour >= 6 and hour < 10:
				discharge_kw["max"] = maxf(discharge_kw["max"],
					float(device.get("output_kw", 0.0)))
				if (discharge_kw["probe"] as Dictionary).is_empty():
					discharge_kw["probe"] = {"t": t, "hour": hour, "device": device})
	# start 23:00, run through the night charge + morning discharge to 10:30
	GameClock.restore({"total_minutes": 23.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(46, 360.0)
	var soc_00: float = soc_series.get(1, -1.0)
	var soc_05: float = soc_series.get(21, -1.0)
	var soc_10: float = soc_series.get(41, -1.0)
	# ── Phase 8 SoC replay: a topology rebuild re-registers the backend —
	# the store must come back at its tracked charge, not the default 0
	var soc_before_rebuild := float(City.device_soc.get(storage_id, -1.0))
	City._topo_dirty = false
	City.topo = PowerTopology.build(City.model, City.tripped_tiles)
	City.heat_topo = HeatTopology.build(City.model, City.tripped_tiles)
	City.water_topo = WaterTopology.build(City.model, City.tripped_tiles)
	for doc: Dictionary in [City.topo.doc, City.heat_topo.doc, City.water_topo.doc]:
		City._inject_soc(doc)
	City._last_heat_doc_json = ""  # force the re-registration
	City._syncing = true
	await City._register_async()
	await _run_steps(2, 240.0)
	var soc_after_rebuild := float(City.last_heat_result.get("devices", {})
		.get(storage_id, {}).get("soc", -1.0))
	var replay_ok: bool = soc_before_rebuild >= 0.0 \
		and absf(soc_after_rebuild - soc_before_rebuild) < 0.05
	var report := {
		"ok": soc_00 >= 0.0 and soc_05 > soc_00 + 0.1
			and soc_10 < soc_05 - 0.1 and discharge_kw["max"] > 20.0
			and replay_ok,
		"soc_before_rebuild": snappedf(soc_before_rebuild, 0.01),
		"soc_after_rebuild": snappedf(soc_after_rebuild, 0.01),
		"soc_replay_ok": replay_ok,
		"soc_midnight": snappedf(soc_00, 0.01), "soc_5am": snappedf(soc_05, 0.01),
		"soc_10am": snappedf(soc_10, 0.01),
		"max_morning_discharge_kw": snappedf(discharge_kw["max"], 0.1),
		"samples": soc_series.size(), "storage_id": storage_id,
		"result_status": City.last_heat_result.get("status", "?"),
		"storage_entry": City.last_heat_result.get("devices", {}).get(storage_id, {}),
		"orch": Orchestrator.stats,
		"morning_probe": discharge_kw["probe"],
		"statuses": discharge_kw["statuses"],
	}
	print("SMOKE_HEATSTORAGE ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
