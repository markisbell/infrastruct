extends SmokeBase
## --smoke=island: POWER ISLANDS end-to-end. An off-grid town (battery +
## wind + solar + substation, NO grid connection) must register and solve
## with the battery as the island's slack; the EMS must then live the
## whole loop against the real solver: noon surplus -> renewable
## CURTAILMENT (a 3 MW turbine cannot charge a tiny battery), calm night
## -> the battery carries the town until its reserve, then the zone is
## SHED (outage books, houses dark), morning wind -> recharge, RESTORE.
## The battery is deliberately small (params_override 6 kWh) so the
## drain fits a smoke window; assertions are WINDOW properties (sampled
## households flicker at instants).


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(240.0):
		_fail("SMOKE_ISLAND", "health timeout")
		return
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, 12.0)
	City.weather.force_wind(0, 84, 10.0)       # windy through noon
	City.weather.force_calm(84, 104)           # dead-calm night (drain)
	City.weather.force_wind(104, 100_000, 10.0)  # morning wind (recover)

	# off-grid microgrid: battery (tiny, fast drain) + 3 MW turbine +
	# solar park on one run, substation zone with a dozen households
	City.place_building("battery", Vector2i(2, 4), 0,
		{"e_kwh": 6.0, "p_max_kw": 100.0})
	for x in range(2, 12):
		City.build_cable(Vector2i(x, 5))
	City.place_building("wind_farm", Vector2i(5, 4))
	City.place_building("solar_park", Vector2i(8, 3))
	City.place_building("substation", Vector2i(11, 6))
	for x in range(8, 16):
		City.build_road(Vector2i(x, 8))
		City.build_zone(Vector2i(x, 7))
	for x in range(8, 16):
		City.model.spawn_house(Vector2i(x, 7))
	City._topo_dirty = true
	if not await _wait_registered(180.0):
		_fail("SMOKE_ISLAND", "register timeout (off-grid island)")
		return

	var battery_id: String = City.model.buildings_of_kind("battery")[0]
	var island_id := "isl_%s" % battery_id
	var zone_id: String = "z_" + City.model.buildings_of_kind("substation")[0]
	check("island_detected", City.topo.islands.has(island_id))
	var former_is_slack := false
	for device: Dictionary in City.topo.doc.get("devices", []):
		if device["id"] == battery_id and device["kind"] == "slack":
			former_is_slack = true
	check("former_is_slack", former_is_slack)
	check("zone_flagged", str(City.topo.zones_info.get(zone_id, {})
		.get("island", "")) == island_id)

	# window watcher: converged frames + the EMS curtail factor per phase
	var window := {"converged": 0, "min_curtail": 2.0}
	var watch := func(_t: int, r: Dictionary) -> void:
		if r.get("status", "") == "converged":
			window["converged"] = int(window["converged"]) + 1
		window["min_curtail"] = minf(float(window["min_curtail"]),
			City.island_ctrl.curtail_of(island_id))

	# ── phase B: windy noon — the island solves, the zone is served, and
	# the EMS curtails the megawatt-class surplus down to the charge path
	GameClock.restore({"total_minutes": 10.0 * 60.0, "speed": 0.0})
	City.power_result.connect(watch)
	await _run_steps(8, 240.0)
	check("noon_converged", int(window["converged"]) >= 4)
	check("noon_zone_supplied", bool(City.zone_supplied.get(zone_id, false)))
	check("noon_curtailed", float(window["min_curtail"]) < 1.0)
	check("noon_soc_charged", float(City.device_soc.get(battery_id, 0.0)) >= 0.6)

	# ── phase C: dead-calm night — the battery carries the town, hits its
	# reserve, and the EMS sheds the zone (outage minutes book, dark town)
	window["converged"] = 0
	var outage_before := int(City.outage_minutes.get(zone_id, 0))
	GameClock.restore({"total_minutes": 21.0 * 60.0, "speed": 0.0})
	await _run_steps(16, 400.0)
	var outage_grew := int(City.outage_minutes.get(zone_id, 0)) > outage_before
	check("night_converged", int(window["converged"]) >= 4)
	check("night_outage_booked", outage_grew)
	check("night_zone_shed", City.island_ctrl.zone_dark(island_id, zone_id))
	var soc_drained: float = float(City.device_soc.get(battery_id, 1.0))
	check("night_soc_drained", soc_drained <= 0.2)

	# ── phase D: morning wind — the battery recharges past the restore
	# hysteresis and the EMS picks the zone back up
	window["converged"] = 0
	GameClock.restore({"total_minutes": 30.0 * 60.0, "speed": 0.0})
	await _run_steps(12, 300.0)
	City.power_result.disconnect(watch)
	check("morning_converged", int(window["converged"]) >= 4)
	check("morning_zone_restored",
		not City.island_ctrl.zone_dark(island_id, zone_id))
	check("morning_zone_supplied", bool(City.zone_supplied.get(zone_id, false)))
	check("morning_soc_recovered",
		float(City.device_soc.get(battery_id, 0.0)) > soc_drained)
	var shed_logged := false
	var restore_logged := false
	for event: Dictionary in City.events:
		if event["kind"] == "island_shed":
			shed_logged = true
		if event["kind"] in ["island_restore", "island_restart"]:
			restore_logged = true
	check("shed_event_logged", shed_logged)
	check("restore_event_logged", restore_logged)

	var report := {"ok": verdict(), "failed": failed_checks(),
		"houses": City.model.houses.size(),
		"islands": City.topo.islands.size(),
		"soc_final": snappedf(float(City.device_soc.get(battery_id, -1.0)), 0.01),
		"outage_min": int(City.outage_minutes.get(zone_id, 0)),
		"min_curtail": snappedf(float(window["min_curtail"]), 0.0001)}
	print("SMOKE_ISLAND ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
