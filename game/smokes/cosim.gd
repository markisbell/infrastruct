extends SmokeBase
## --smoke=cosim (extracted from main.gd, Phase-3 refactor plan).


var kill_mode := false  # cosim-kill sets this via the registry


func run() -> void:
	var provider := FixtureProvider.load_default(SidecarManager.repo_root)
	if provider.fixtures.size() < 2:
		_fail("SMOKE_COSIM", "fixtures missing (need power+heat)")
		return
	# stress ports (8014/15) like every other smoke — the default 8010/11
	# may belong to a LIVE play session whose sidecars must not be reused
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		_fail("SMOKE_COSIM", "health timeout")
		return

	Orchestrator.boundary_provider = provider
	var events: Array[Dictionary] = []
	Orchestrator.supply_event.connect(
		func(network: String, kind: String, severity: String, data: Dictionary) -> void:
			events.append({"network": network, "kind": kind, "severity": severity,
				"t": data.get("t", -1)}))
	var n_steps := provider.steps("power")
	var seen := {"power": [], "heat": []}
	var statuses := {"power": {}, "heat": {}}
	var final_results := {}
	Orchestrator.step_completed.connect(
		func(network: String, t: int, result: Dictionary) -> void:
			seen[network].append(t)
			if t == n_steps - 1:
				final_results[network] = result
			var status: String = result.get("status", "?")
			statuses[network][status] = statuses[network].get(status, 0) + 1)

	var registered := true
	for id: String in ["power", "heat"]:
		var handshake_ok := await CosimBridge.handshake(id)
		registered = registered and handshake_ok \
			and await Orchestrator.register(id, provider.topology(id))
	if not registered:
		_fail("SMOKE_COSIM", "register failed")
		return

	GameClock.restore({"total_minutes": 0.0, "speed": 0.0})
	Orchestrator.start()
	if kill_mode:
		print("SMOKE_READY ", JSON.stringify({"ports": [8014, 8015]}))
	GameClock.speed = 15.0 if kill_mode else 60.0

	var deadline := Time.get_ticks_msec() + (420_000 if kill_mode else 240_000)
	while Time.get_ticks_msec() < deadline:
		var power_done: bool = (seen["power"] as Array).size() >= n_steps
		var heat_done: bool = (seen["heat"] as Array).size() >= n_steps \
			or (kill_mode and GameClock.total_minutes >= n_steps * GameClock.SIM_STEP_MINUTES)
		if power_done and heat_done:
			break
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(2.0).timeout

	var report := {"ok": true, "steps_target": n_steps, "events": events.size()}
	for id: String in ["power", "heat"]:
		var ts: Array = seen[id]
		var monotonic := true
		for i in range(1, ts.size()):
			monotonic = monotonic and ts[i] > ts[i - 1]
		var bad_status := 0
		for status: String in statuses[id]:
			if status not in provider.allowed_statuses(id):
				bad_status += statuses[id][status]
		var golden_fails := _golden_check(provider.golden(id),
			final_results.get(id, Orchestrator.latest(id)))
		report[id] = {"completed": ts.size(),
			"missed": Orchestrator.networks[id]["missed"], "monotonic": monotonic,
			"statuses": statuses[id], "bad_status_steps": bad_status,
			"golden_fails": golden_fails}
		if kill_mode and id == "heat":
			var down := events.any(func(e: Dictionary) -> bool:
				return e.kind == "backend_down" and e.network == "heat")
			var recovered := events.any(func(e: Dictionary) -> bool:
				return e.kind == "backend_recovered" and e.network == "heat")
			var resumed: bool = not ts.is_empty() and ts.back() > (ts[0] + ts.size())
			report["heat"]["down_event"] = down
			report["heat"]["recovered_event"] = recovered
			report["heat"]["resumed_after_gap"] = resumed
			report["ok"] = report["ok"] and down and recovered and resumed and monotonic
		else:
			report["ok"] = report["ok"] and ts.size() >= n_steps \
				and Orchestrator.networks[id]["missed"] == 0 and monotonic \
				and bad_status == 0 and golden_fails.is_empty()
	if kill_mode:
		report["ok"] = report["ok"] and report["power"]["completed"] >= n_steps - 2 \
			and report["power"]["bad_status_steps"] == 0
	print("SMOKE_COSIM_KILL " if kill_mode else "SMOKE_COSIM ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)

func _golden_check(golden: Dictionary, result: Dictionary) -> Array:
	var fails := []
	for path: String in golden:
		var bounds: Array = golden[path]
		var value: Variant = result
		for key: String in path.split("."):
			if value is Dictionary and (value as Dictionary).has(key):
				value = value[key]
			else:
				value = null
				break
		if value == null or not (value is float or value is int):
			fails.append({"path": path, "error": "missing"})
		elif float(value) < float(bounds[0]) or float(value) > float(bounds[1]):
			fails.append({"path": path, "value": value, "bounds": bounds})
	return fails
