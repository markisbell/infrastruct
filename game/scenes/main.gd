extends Node2D
## Entry scene: normal game (CityView + HUD + supervised sidecars) plus the
## headless modes — spike bench, screenshot, and the acceptance smokes
## (Phases 1-3). Smokes print one machine-readable JSON line and quit 0/1.

var view: CityView
var _screenshot_path := ""
var _bench := false
var _bench_out := ""


func _ready() -> void:
	var smoke := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--bench":
			_bench = true
		elif arg.begins_with("--out="):
			_bench_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--smoke="):
			smoke = arg.trim_prefix("--smoke=")
		elif arg.begins_with("--screenshot="):
			_screenshot_path = arg.trim_prefix("--screenshot=")

	view = CityView.new()
	add_child(view)

	if _bench:
		_run_bench()
		return
	if _screenshot_path != "":
		_take_screenshot()
		return
	match smoke:
		"sidecars":
			_smoke_sidecars()
		"resilience":
			_smoke_resilience()
		"saveload":
			_smoke_saveload()
		"cosim":
			_smoke_cosim(false)
		"cosim-kill":
			_smoke_cosim(true)
		"windless-week":
			_smoke_windless_week()
		"overload":
			_smoke_overload()
		_:
			_boot_game()


func _boot_game() -> void:
	var hud := Hud.new()
	hud.view = view
	add_child(hud)
	if SidecarManager.load_config():
		SidecarManager.start_all()
		SidecarManager.state_changed.connect(_on_sidecar_state)
		_add_debug_panel()
	GameClock.speed = 1.0


func _on_sidecar_state(id: String, state: SidecarManager.State) -> void:
	if state == SidecarManager.State.HEALTHY and not CosimBridge.info.has(id):
		CosimBridge.handshake(id)


var _debug_panel: PanelContainer


func _add_debug_panel() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	_debug_panel = preload("res://scenes/debug_panel.gd").new()
	_debug_panel.position = Vector2(8, 48)
	layer.add_child(_debug_panel)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		match key.keycode:
			KEY_F5:
				SaveGame.save_to(SaveGame.DEFAULT_PATH)
			KEY_F6:
				if SaveGame.load_from(SaveGame.DEFAULT_PATH)["ok"]:
					view.redraw()
			KEY_F1:
				if _debug_panel:
					_debug_panel.visible = not _debug_panel.visible
			KEY_F2:
				var dump := {}
				for id: String in Orchestrator.networks:
					dump[id] = Orchestrator.latest(id)
				var f := FileAccess.open("user://debug_dump.json", FileAccess.WRITE)
				f.store_string(JSON.stringify(dump, "  "))
				f.close()
				print("debug: results dumped to user://debug_dump.json")
			KEY_F3:
				GameClock.total_minutes += GameClock.SIM_STEP_MINUTES
				Orchestrator._on_sim_step(int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES))
				print("debug: forced sim-step")
			KEY_F4:
				if City.weather._calm_from < 0:
					City.weather.force_calm(City.current_t, City.current_t + 96)
					print("debug: cold calm forced for 24 h")
				else:
					City.weather.clear_calm()
					print("debug: weather override cleared")


# ─── bench (Phase 0 spike A, now through the City/model path) ───

var _bench_state := {"warmup": 30, "frames": [], "cursor": Vector2i(64, 64), "dir": 1}


func _run_bench() -> void:
	City.money = 100_000_000
	set_process(true)


func _process(delta: float) -> void:
	if not _bench:
		return
	if _bench_state["warmup"] > 0:
		_bench_state["warmup"] -= 1
		return
	var frames: Array = _bench_state["frames"]
	if frames.size() >= 300:
		set_process(false)
		_bench_finish()
		return
	for i in 5:
		var cursor: Vector2i = _bench_state["cursor"]
		City.model.set_cable(cursor, 1)
		cursor.x += _bench_state["dir"]
		if cursor.x >= 192 or cursor.x <= 64:
			_bench_state["dir"] = -_bench_state["dir"]
			cursor.y += 1
		_bench_state["cursor"] = cursor
	view.redraw()
	view.cam.position = view._terrain.map_to_local(_bench_state["cursor"])
	frames.append(delta)


func _bench_finish() -> void:
	var frames: Array = _bench_state["frames"]
	frames.sort()
	var total := 0.0
	for f: float in frames:
		total += f
	var restored := WorldModel.from_json(City.model.to_json())
	var report := {
		"frames": frames.size(), "tiles_painted": City.model.cables.size(),
		"avg_ms": total / frames.size() * 1000.0,
		"p99_ms": frames[mini(int(frames.size() * 0.99), frames.size() - 1)] * 1000.0,
		"avg_fps": frames.size() / total,
		"roundtrip_ok": restored.equals(City.model),
	}
	if not _bench_out.is_empty():
		var f := FileAccess.open(_bench_out, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("SPIKE_A_REPORT ", JSON.stringify(report))
	get_tree().quit(0 if report["roundtrip_ok"] else 1)


# ─── screenshot (pre-alpha look; builds a demo town, no sidecars) ───

func _take_screenshot() -> void:
	City.money = 100_000_000
	City.place_building("grid_connection", Vector2i(118, 120))
	for x in range(120, 141):
		City.build_cable(Vector2i(x, 121))
	City.place_building("substation", Vector2i(134, 122))
	City.place_building("wind_farm", Vector2i(124, 116))
	for y in range(118, 121):
		City.build_cable(Vector2i(126, y))
	City.place_building("solar_park", Vector2i(139, 117))
	for y in range(119, 121):
		City.build_cable(Vector2i(140, y))
	for x in range(128, 143):
		City.build_road(Vector2i(x, 124))
	for x in range(128, 143):
		for y in [125, 126]:
			City.build_zone(Vector2i(x, y))
	var subs := City.model.buildings_of_kind("substation")
	City.spawn_houses_bulk(subs[0], 22)
	view.redraw()
	view.cam.position = view._terrain.map_to_local(Vector2i(131, 121))
	view.cam.zoom = Vector2(1.6, 1.6)
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(_screenshot_path)
	print("SCREENSHOT saved to ", _screenshot_path)
	get_tree().quit(0)


# ─── shared smoke helpers ───

func _wait_all_healthy(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _wait_power_healthy(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while SidecarManager.state_of("power") != SidecarManager.State.HEALTHY:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _wait_registered(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not City.registered:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _fail(tag: String, reason: String) -> void:
	print(tag, " ", JSON.stringify({"ok": false, "reason": reason}))
	SidecarManager.stop_all()
	get_tree().quit(1)


# ─── Phase 1 smokes ───

func _smoke_sidecars() -> void:
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		_fail("SMOKE_SIDECARS", "health timeout")
		return
	var ok := true
	var per_sidecar := {}
	for id: String in SidecarManager.ids():
		var handshake_ok: bool = await CosimBridge.handshake(id)
		per_sidecar[id] = {"handshake": handshake_ok,
			"solver": CosimBridge.info.get(id, {}).get("solver", "?")}
		ok = ok and handshake_ok
	print("SMOKE_SIDECARS ", JSON.stringify({"ok": ok, "sidecars": per_sidecar}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)


func _smoke_resilience() -> void:
	SidecarManager.load_config()
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


func _smoke_saveload() -> void:
	City.model.set_cable(Vector2i(10, 20), 1)
	City.model.set_road(Vector2i(0, 0))
	City.money = 123_456
	GameClock.restore({"total_minutes": 3 * 1440.0 + 125.0, "speed": 3.0})
	var path := "user://smoke_save.json"
	var save_err := SaveGame.save_to(path)
	City.model = WorldModel.new()
	City.money = City.START_MONEY
	GameClock.restore({"total_minutes": 0.0, "speed": 1.0})
	var loaded: Dictionary = SaveGame.load_from(path)
	var ok: bool = (
		save_err == OK and loaded["ok"]
		and City.model.has_cable(Vector2i(10, 20)) and City.model.roads.has(Vector2i(0, 0))
		and City.money == 123_456
		and GameClock.day() == 3 and GameClock.time_of_day_string() == "02:05"
	)
	print("SMOKE_SAVELOAD ", JSON.stringify({"ok": ok}))
	get_tree().quit(0 if ok else 1)


# ─── Phase 2 smokes (fixture-driven cosim, both backends) ───

func _smoke_cosim(kill_mode: bool) -> void:
	var provider := FixtureProvider.load_default(SidecarManager.repo_root)
	if provider.fixtures.size() < 2:
		_fail("SMOKE_COSIM", "fixtures missing (need power+heat)")
		return
	SidecarManager.load_config()
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
		print("SMOKE_READY ", JSON.stringify({"ports": [8010, 8011]}))
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


# ─── Phase 3 acceptance scenarios ───

## Wind-only town behind a tiny grid connection: outages must occur exactly
## during the forced calm window; a battery bridges it (ROADMAP Phase 3).
func _smoke_windless_week() -> void:
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_WINDLESS", "power health timeout")
		return
	var phases := {}
	for with_battery: bool in [false, true]:
		var result := await _run_windless_phase(42, with_battery)
		phases["battery" if with_battery else "plain"] = result
	var plain: Dictionary = phases["plain"]
	var battery: Dictionary = phases["battery"]
	var ok: bool = (
		plain["outage_min"] > 0 and plain["all_in_window"]
		and plain["outage_before_calm"] == 0
		and battery["outage_min"] == 0
	)
	print("SMOKE_WINDLESS ", JSON.stringify({"ok": ok,
		"plain": plain, "battery": battery}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)


func _run_windless_phase(weather_seed: int, with_battery: bool) -> Dictionary:
	# fresh city
	City.model = WorldModel.new()
	City.money = 100_000_000
	City.weather = WeatherSystem.new(weather_seed)
	City.outage_minutes = {}
	City.happiness = 100.0
	City.tripped_tiles.clear()
	City.grid_trip_until = -1
	City.grid_capacity_override = 3.0  # kW — below even the night minimum
	City.place_building("grid_connection", Vector2i(10, 10))
	for x in range(12, 31):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(31, 10))
	City.place_building("wind_farm", Vector2i(24, 8))  # touches cable at (24,10)? no: (24,9),(25,9) adjacent
	for x in range(26, 38):
		City.build_road(Vector2i(x, 12))
	for x in range(26, 38):
		City.build_zone(Vector2i(x, 13))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 6)
	if with_battery:
		City.place_building("battery", Vector2i(27, 9))  # adjacent to cable (27,10)
	City._topo_dirty = true
	if not await _wait_registered(120.0):
		return {"error": "register timeout"}

	# clock: start at the next full day boundary; calm 06:00-18:00 on day 1
	var t0 := (int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES / 96) + 1) * 96
	GameClock.restore({"total_minutes": t0 * float(GameClock.SIM_STEP_MINUTES), "speed": 0.0})
	var calm_start := t0 + 24
	var calm_end := t0 + 72
	# scripted series: solid wind across the whole run, dead calm inside the
	# window — "outages fire exactly when the weather series says calm"
	# 7 m/s -> ~26 kW from the 300-kW farm: covers the town without the huge
	# export that would overvolt this small feeder
	City.weather.force_wind(t0 - 96, t0 + 192, 7.0)
	City.weather.force_calm(calm_start, calm_end)
	var unsupplied_steps: Array[int] = []
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var import_calm := [0.0, -999.0]   # min, max during calm
	var import_windy := [0.0, -999.0]
	var statuses := {}
	var handler := func(t: int, result: Dictionary) -> void:
		for zone_id: String in City.zone_supplied:
			if not City.zone_supplied[zone_id]:
				unsupplied_steps.append(t)
				break
		var status: String = result.get("status", "?")
		statuses[status] = statuses.get(status, 0) + 1
		var import_kw := float(result.get("devices", {}).get(slack_id, {}).get("output_kw", 0.0))
		var bucket: Array = import_calm if (t >= calm_start and t < calm_end) else import_windy
		bucket[0] = minf(bucket[0], import_kw)
		bucket[1] = maxf(bucket[1], import_kw)
	City.power_result.connect(handler)
	Orchestrator.start()
	GameClock.speed = 60.0
	var end_t := t0 + 96  # one full day covering the calm window
	var deadline := Time.get_ticks_msec() + 300_000
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(1.5).timeout
	City.power_result.disconnect(handler)
	City.weather.clear_calm()

	var all_in_window := true
	var before_calm := 0
	for t: int in unsupplied_steps:
		if t < calm_start:
			before_calm += 1
		if t < calm_start or t > calm_end + City.REPAIR_STEPS + 2:
			all_in_window = false
	return {"outage_min": City.total_outage_minutes(),
		"unsupplied_steps": unsupplied_steps.size(),
		"all_in_window": all_in_window, "outage_before_calm": before_calm,
		"calm": [calm_start, calm_end], "statuses": statuses,
		"import_calm": import_calm, "import_windy": import_windy,
		"events": City.events.size()}


## Two feeders from the grid connection; the heavy one (140 houses behind two
## substations) overloads past 120 %, trips, and blacks out ONLY its zones.
func _smoke_overload() -> void:
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_OVERLOAD", "power health timeout")
		return
	City.model = WorldModel.new()
	City.money = 100_000_000
	City.weather = WeatherSystem.new(42)
	City.outage_minutes = {}
	City.grid_capacity_override = 2000.0  # capacity is not under test here
	City.place_building("grid_connection", Vector2i(10, 10))
	# feeder A (east) -> sub1, light
	for x in range(12, 18):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(18, 10))
	for x in range(14, 26):
		City.build_road(Vector2i(x, 8))
	for x in range(14, 26):
		City.build_zone(Vector2i(x, 7))
	# feeder B (south, then east) -> sub2 + sub3, heavy
	for y in range(12, 16):
		City.build_cable(Vector2i(10, y))
	for x in range(11, 30):
		City.build_cable(Vector2i(x, 15))
	City.place_building("substation", Vector2i(20, 16))  # touches (20,15)
	City.place_building("substation", Vector2i(30, 15))
	for x in range(12, 34):
		City.build_road(Vector2i(x, 18))
		City.build_road(Vector2i(x, 21))
		City.build_road(Vector2i(x, 24))
	for x in range(12, 34):
		for y in [19, 20, 22, 23]:  # every zoned row is road-adjacent
			City.build_zone(Vector2i(x, y))
	var subs := City.model.buildings_of_kind("substation")
	# heavy district spawns FIRST so sub1 cannot eat its candidate tiles
	var spawned := [City.spawn_houses_bulk(subs[1], 60),
		City.spawn_houses_bulk(subs[2], 60), City.spawn_houses_bulk(subs[0], 20)]
	City._topo_dirty = true
	if not await _wait_registered(120.0):
		_fail("SMOKE_OVERLOAD", "register timeout")
		return

	var zone1 := "z_" + subs[0]
	# NOTE: GDScript lambdas capture scalars BY VALUE — mutate a shared
	# Dictionary (reference semantics) or the counters silently stay 0.
	var counters := {"trips": 0, "max_loading": 0.0, "steps": 0}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "line_trip":
			counters["trips"] += 1)
	City.power_result.connect(func(_t: int, result: Dictionary) -> void:
		counters["steps"] += 1
		for edge_id: String in result.get("edges", {}):
			counters["max_loading"] = maxf(counters["max_loading"],
				float(result["edges"][edge_id].get("loading_percent", 0.0))))

	# start at 17:30 — into the evening peak
	GameClock.restore({"total_minutes": 17.5 * 60.0, "speed": 0.0})
	Orchestrator.start()
	GameClock.speed = 30.0
	var end_t := int(21.0 * 60.0 / GameClock.SIM_STEP_MINUTES)  # run to 21:00
	var deadline := Time.get_ticks_msec() + 300_000
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	Orchestrator.stop()
	await get_tree().create_timer(1.5).timeout

	var heavy_outage: int = City.outage_minutes.get("z_" + subs[1], 0) \
		+ City.outage_minutes.get("z_" + subs[2], 0)
	var light_outage: int = City.outage_minutes.get(zone1, 0)
	var report := {
		"ok": counters["trips"] >= 1 and counters["max_loading"] > 120.0
			and heavy_outage > 0 and light_outage == 0,
		"trip_events": counters["trips"],
		"max_loading": snappedf(counters["max_loading"], 0.1),
		"heavy_feeder_outage_min": heavy_outage, "light_feeder_outage_min": light_outage,
		"steps_seen": counters["steps"], "houses_spawned": spawned,
	}
	print("SMOKE_OVERLOAD ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
