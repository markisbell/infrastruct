extends SmokeBase
## --smoke=sidecars (extracted from main.gd, Phase-3 refactor plan).


func run() -> void:
	# dev repo: stress ports (a live play session may own 8010-8012);
	# EXPORTED/staged builds ship exactly one config — this smoke is the
	# installer verification path, so it must use what actually ships
	if OS.has_feature("editor"):
		SidecarManager.load_config("orchestration/sidecars_stress.json")
	else:
		SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		_fail("SMOKE_SIDECARS", "health timeout")
		return
	var ok := true
	var per_sidecar := {}
	# installer verification: the WRONG solver answering the right port must
	# fail (gate hardening 2026-08-04 — handshake booleans alone accepted it)
	var expected_solver := {"power": "pandapower", "heat": "pandapipes",
		"water": "pandapipes"}
	for id: String in SidecarManager.ids():
		var handshake_ok: bool = await CosimBridge.handshake(id)
		var backend_info: Dictionary = CosimBridge.info.get(id, {})
		var solver := str(backend_info.get("solver", "?"))
		var solver_ok := solver.begins_with(str(expected_solver.get(id, "")))
		per_sidecar[id] = {"handshake": handshake_ok, "solver": solver,
			"solver_ok": solver_ok,
			"contract": str(backend_info.get("contract", "?"))}
		ok = ok and handshake_ok and solver_ok
	print("SMOKE_SIDECARS ", JSON.stringify({"ok": ok, "sidecars": per_sidecar}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)
