extends SmokeBase
## --smoke=resilience (extracted from main.gd, Phase-3 refactor plan).


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		_fail("SMOKE_RESILIENCE", "initial health timeout")
		return
	print("SMOKE_READY ", JSON.stringify({"ports": SidecarManager.ids().map(
		func(id: String) -> int: return SidecarManager.port_of(id))}))
	var saw_down := false
	var deadline := Time.get_ticks_msec() + 120_000
	while Time.get_ticks_msec() < deadline and not saw_down:
		for id: String in SidecarManager.ids():
			var state: SidecarManager.State = SidecarManager.state_of(id)
			if state == SidecarManager.State.DOWN or state == SidecarManager.State.RESTARTING:
				saw_down = true
		await get_tree().create_timer(0.5).timeout
	var recovered := saw_down and await _wait_all_healthy(180.0)
	print("SMOKE_RESILIENCE ", JSON.stringify({"ok": recovered, "saw_down": saw_down}))
	SidecarManager.stop_all()
	get_tree().quit(0 if recovered else 1)
