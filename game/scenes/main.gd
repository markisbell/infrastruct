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
		elif arg.begins_with("--seed="):
			_playtest_seed = int(arg.trim_prefix("--seed="))
		elif arg.begins_with("--screenshot="):
			_screenshot_path = arg.trim_prefix("--screenshot=")
		elif arg.begins_with("--roadtest="):
			_roadtest_path = arg.trim_prefix("--roadtest=")
		elif arg.begins_with("--gallery="):
			_gallery_path = arg.trim_prefix("--gallery=")

	view = CityView.new()
	add_child(view)

	if _bench:
		_run_bench()
		return
	if _screenshot_path != "":
		_take_screenshot()
		return
	if _roadtest_path != "":
		_take_roadtest()
		return
	if _gallery_path != "":
		_take_gallery()
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
		"stress":
			_smoke_stress()
		"coldsnap":
			_smoke_coldsnap()
		"heatstorage":
			_smoke_heatstorage()
		"pumpblackout":
			_smoke_pumpblackout()
		"drought":
			_smoke_drought()
		"towerheight":
			_smoke_towerheight()
		"hilltower":
			_smoke_hilltower()
		"yearcurves":
			_smoke_yearcurves()
		"citylife":
			_smoke_citylife()
		"economy":
			_smoke_economy()
		"events":
			_smoke_events()
		"scenarios":
			_smoke_scenarios()
		"maintenance":
			_smoke_maintenance()
		"playtest":
			_smoke_playtest()
		_:
			_boot_game()


var _hud: Hud
var _tutorial_steps: Array[Dictionary] = []
var _tutorial_idx := 0


func _boot_game() -> void:
	_hud = Hud.new()
	_hud.view = view
	add_child(_hud)
	if SidecarManager.load_config():
		SidecarManager.start_all()
		SidecarManager.state_changed.connect(_on_sidecar_state)
		_add_debug_panel()
	GameClock.speed = 0.0  # paused until a scenario is picked (or loaded)
	GameClock.sim_step.connect(_on_scenario_step)  # runner works for loads too
	_hud.show_scenario_picker(_start_scenario)


func _start_scenario(id: String, difficulty_key: String) -> void:
	City.scenario_state = Scenarios.start(id, difficulty_key)
	view.redraw()
	if id == "tutorial":
		_tutorial_steps = Scenarios.tutorial_steps()
		_tutorial_idx = 0
		_hud.show_objective(_tutorial_steps[0]["text"])
		City.world_changed.connect(_check_tutorial)
	else:
		for scenario: Dictionary in Scenarios.catalog():
			if scenario["id"] == id and id not in ["sandbox"]:
				_hud.show_objective("GOAL: " + scenario["desc"])
	# lively default: one sim step every ~2 s of play (SPACE pauses, +/- adjust)
	GameClock.speed = 8.0


func _check_tutorial() -> void:
	if _tutorial_steps.is_empty() or _tutorial_idx >= _tutorial_steps.size() - 1:
		return
	if (_tutorial_steps[_tutorial_idx]["done"] as Callable).call():
		_tutorial_idx += 1
		_hud.show_objective(_tutorial_steps[_tutorial_idx]["text"])


func _on_scenario_step(t: int) -> void:
	_check_tutorial()  # house-count steps advance on sim time, not builds
	if City.scenario_state.get("done", true) \
			or City.scenario_state.get("id", "") in ["sandbox", "tutorial"]:
		return
	if t % 96 != 0:  # verdicts fall at midnight
		return
	var verdict := Scenarios.evaluate(City.scenario_state, t / 96)
	if verdict == "":
		return
	City.scenario_state["done"] = true
	if verdict == "win":
		_hud.show_banner("SCENARIO COMPLETE", Color(0.4, 0.95, 0.5))
		City.log_event("scenario_won", "info", "Scenario objective reached!")
	else:
		_hud.show_banner("SCENARIO FAILED", Color(0.95, 0.3, 0.25))
		City.log_event("scenario_lost", "critical", "Scenario failed.")
	GameClock.pause()


func _on_sidecar_state(id: String, state: SidecarManager.State) -> void:
	if state == SidecarManager.State.HEALTHY and not CosimBridge.info.has(id):
		if await CosimBridge.handshake(id) and id == "power":
			City.warmup_backend()  # absorb the numba JIT before the first build


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
			KEY_F5:  # quicksave/-load (the Save/Load buttons offer slots)
				if _hud:
					_hud._save_slot(SaveGame.DEFAULT_PATH)
				else:
					SaveGame.save_to(SaveGame.DEFAULT_PATH)
			KEY_F6:
				if _hud:
					_hud._load_slot(SaveGame.DEFAULT_PATH)
				elif SaveGame.load_from(SaveGame.DEFAULT_PATH)["ok"]:
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
				if City.weather._wind_overrides.is_empty():
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
	view.focus_tile(_bench_state["cursor"])
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
	var hud := Hud.new()  # status bar + build menu belong in the pre-alpha look
	hud.view = view
	add_child(hud)
	City.money = 100_000_000
	# environment demo: seed-19 wilderness (hills, rivers, mini-forest props)
	# around a forced flat DRY pad the fixed town layout builds on (height
	# overrides are never water); a river bend hugs the west and south edges
	City.model.terrain.set_seed(19)
	City.model.terrain.force_height(Vector2i(113, 114), Vector2i(146, 138), 0)
	City.model.terrain.force_water(Vector2i(96, 139), Vector2i(146, 141))
	City.model.terrain.force_water(Vector2i(96, 112), Vector2i(98, 141))
	# terrain demo: the water tower stands on a forced plateau (elevation is
	# real pressure now), plus a decorative stepped hill west of town
	City.model.terrain.force_height(Vector2i(117, 130), Vector2i(123, 136), 2)
	City.model.terrain.force_height(Vector2i(100, 116), Vector2i(112, 138), 1)
	City.model.terrain.force_height(Vector2i(103, 121), Vector2i(109, 133), 3)
	City.place_building("grid_connection", Vector2i(118, 120))
	for x in range(120, 141):  # buried out of the station, overhead onward
		City.build_cable(Vector2i(x, 121), BuildingDefs.LINE_UNDERGROUND
			if x < 128 else BuildingDefs.LINE_OVERHEAD)
	City.place_building("substation", Vector2i(134, 122))
	City.place_building("wind_farm", Vector2i(124, 116))
	for y in range(117, 121):  # reaches (126,117), adjacent to the farm —
		City.build_cable(Vector2i(126, y))  # the new "!" marker caught this gap
	City.place_building("solar_park", Vector2i(139, 117))
	for y in range(119, 121):
		City.build_cable(Vector2i(140, y))
	for x in range(128, 143):
		City.build_road(Vector2i(x, 124))
	for y in range(125, 130):
		City.build_road(Vector2i(142, y))  # bend + vertical leg: corner check
	for x in range(128, 143):
		for y in [125, 126]:
			if not (x == 142):
				City.build_zone(Vector2i(x, y))
	# district heating: boiler -> trunk under the houses -> heat exchanger
	City.place_building("boiler_plant", Vector2i(120, 128))
	for x in range(122, 141):
		City.build_heat_pipe(Vector2i(x, 129))
	City.place_building("heat_exchanger", Vector2i(136, 130))
	City.place_building("heat_storage", Vector2i(126, 130))
	# water: tower-headed green main under the heat trunk, well feed + station
	City.place_building("water_tower", Vector2i(120, 132))
	for x in range(121, 136):
		City.build_water_pipe(Vector2i(x, 132))
	City.place_building("water_station", Vector2i(136, 132))
	City.place_building("well", Vector2i(128, 134))
	City.build_water_pipe(Vector2i(128, 133))
	City.place_building("pumping_station", Vector2i(146, 131))
	var subs := City.model.buildings_of_kind("substation")
	City.spawn_houses_bulk(subs[0], 22)
	# demo the build feedback: a disconnected plant (red !), orphan houses
	# beyond any coverage (yellow !), and coverage diamonds (substation tool)
	City.place_building("wind_farm", Vector2i(149, 118))
	for x in range(147, 153):
		City.build_road(Vector2i(x, 126))
	for x in range(147, 153):
		City.build_zone(Vector2i(x, 127))
	City.model.spawn_house(Vector2i(148, 127))
	City.model.spawn_house(Vector2i(151, 127))
	City._refresh_topo_assignment()
	# inspector demo: synthetic two-day LINE-loading telemetry (yesterday
	# full + today up to "now"), then open the clicked line's graph panel
	var line_pos := Vector2i(130, 121)
	var line_edge := City.topo.line_id_at(line_pos)
	if line_edge != "":
		var line_demo := City.topo.line_key(line_edge)
		for t in 96:
			City._telemetry_put(line_demo, t,
				maxf(38.0 + 42.0 * sin(TAU * (t / 96.0 - 0.31)) + 6.0 * sin(TAU * t / 16.0), 4.0))
		for t in range(96, 96 + 62):
			City._telemetry_put(line_demo, t,
				maxf(42.0 + 47.0 * sin(TAU * ((t - 96) / 96.0 - 0.31)) + 5.0 * sin(TAU * t / 12.0), 4.0))
		City.current_t = 96 + 61
		hud._open_tile_inspector("cable", line_pos)
	view.tool = CityView.Tool.SUBSTATION
	view.redraw()
	view.focus_tile(Vector2i(133, 125), 24.0)
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(_screenshot_path)
	print("SCREENSHOT saved to ", _screenshot_path)
	get_tree().quit(0)


# ─── road-piece visual regression: every mask variant on one screen ───

var _roadtest_path := ""


## Builds all road-orientation cases: a closed loop (all four bends), a
## crossroad with four ends, and all four T-junctions. The red pillar
## marks NORTH (y-), the blue pillar EAST (x+) — read the picture against
## the world axes, not the camera.
func _take_roadtest() -> void:
	City.money = 100_000_000
	for x in range(120, 126):  # loop: top + bottom edges
		City.build_road(Vector2i(x, 120))
		City.build_road(Vector2i(x, 123))
	for y in range(121, 123):  # loop: left + right edges
		City.build_road(Vector2i(120, y))
		City.build_road(Vector2i(125, y))
	for y in range(119, 124):  # crossroad: vertical arm
		City.build_road(Vector2i(132, y))
	for x in range(130, 135):  # crossroad: horizontal arm
		City.build_road(Vector2i(x, 121))
	for x in range(137, 140):  # T with stem SOUTH (mask W|E|S)
		City.build_road(Vector2i(x, 120))
	City.build_road(Vector2i(138, 121))
	for x in range(137, 140):  # T with stem NORTH (mask W|E|N)
		City.build_road(Vector2i(x, 124))
	City.build_road(Vector2i(138, 123))
	for y in range(119, 122):  # T with stem EAST (mask N|S|E)
		City.build_road(Vector2i(142, y))
	City.build_road(Vector2i(143, 120))
	for y in range(119, 122):  # T with stem WEST (mask N|S|W)
		City.build_road(Vector2i(146, y))
	City.build_road(Vector2i(145, 120))
	# crossing demo: all three buried networks dive under a street
	for y in range(127, 132):
		City.build_road(Vector2i(122, y))
	for x in range(119, 126):
		City.build_water_pipe(Vector2i(x, 128), BuildingDefs.LINE_UNDERGROUND)
		City.build_heat_pipe(Vector2i(x, 129), BuildingDefs.LINE_UNDERGROUND)
		City.build_cable(Vector2i(x, 130), BuildingDefs.LINE_UNDERGROUND)
	var north := view._box(Vector3(0.5, 1.6, 0.5), Color(0.9, 0.15, 0.1),
		Vector3(133.5, 0.8, 116.5))
	view.add_child(north)
	var east := view._box(Vector3(0.5, 1.6, 0.5), Color(0.15, 0.3, 0.9),
		Vector3(150.5, 0.8, 121.5))
	view.add_child(east)
	view.redraw()
	view.focus_tile(Vector2i(133, 121), 24.0)
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(_roadtest_path)
	view.focus_tile(Vector2i(122, 121), 9.0)  # loop close-up: the four bends
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_loop.png"))
	view.focus_tile(Vector2i(141, 121), 14.0)  # the four T-junctions
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_tees.png"))
	view.focus_tile(Vector2i(138, 121), 6.0)  # single T, close enough to read
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_tee1.png"))
	# ground truth: the raw GLBs at yaw 0, red post = N edge, blue = E edge
	var x := 126
	for piece: String in ["road-bend", "road-intersection", "road-end"]:
		var raw := view._instance_glb(
			"city-kit-roads/Models/GLB format/%s.glb" % piece, 1.0)
		raw.position = Vector3(x + 0.5, 0, 130.5)
		view.add_child(raw)
		view.add_child(view._box(Vector3(0.15, 0.7, 0.15), Color(0.9, 0.15, 0.1),
			Vector3(x + 0.5, 0.35, 130.0 - 0.35)))  # north edge
		view.add_child(view._box(Vector3(0.15, 0.7, 0.15), Color(0.15, 0.3, 0.9),
			Vector3(x + 0.5 + 0.85, 0.35, 130.5)))  # east edge
		x += 3
	view.focus_tile(Vector2i(129, 130), 7.0)
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_native.png"))
	view.focus_tile(Vector2i(122, 129), 8.0)  # buried lines crossing the street
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_crossing.png"))
	# four 3-tile L-turns, one per bend orientation — at this zoom a flipped
	# corner cannot hide: the band either flows through the curve or breaks
	for l_shape: Array in [
		[Vector2i(150, 128), Vector2i(151, 128), Vector2i(151, 129)],  # corner W+S
		[Vector2i(155, 128), Vector2i(156, 128), Vector2i(155, 129)],  # corner E+S
		[Vector2i(150, 133), Vector2i(151, 133), Vector2i(150, 132)],  # corner E+N
		[Vector2i(155, 133), Vector2i(156, 133), Vector2i(156, 132)],  # corner W+N
	]:
		for tile: Vector2i in l_shape:
			City.build_road(tile)
	view.redraw()
	view.focus_tile(Vector2i(153, 130), 10.0)
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_bends.png"))
	view.focus_tile(Vector2i(138, 122), 7.0)  # T stem-S + stem-N, close
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_tee_ns.png"))
	view.focus_tile(Vector2i(144, 120), 7.0)  # T stem-E + stem-W, close
	await get_tree().create_timer(0.4).timeout
	get_viewport().get_texture().get_image().save_png(
		_roadtest_path.replace(".png", "_tee_ew.png"))
	print("ROADTEST saved to ", _roadtest_path)
	get_tree().quit(0)


# ─── model gallery (art-direction picker, e.g. heat exchanger candidates) ───

var _gallery_path := ""


func _take_gallery() -> void:
	var factory := "factory-kit/Models/GLB format/"
	var candidates: Array = [
		["1 machine-bed (current)", factory + "machine-bed.glb", 0.7],
		["2 machine-connection-pipe", factory + "machine-connection-pipe.glb", 0.8],
		["3 pipe-large-valve", factory + "pipe-large-valve.glb", 0.8],
		["4 hopper-round", factory + "hopper-round.glb", 0.7],
		["5 piston-round", factory + "piston-round.glb", 0.7],
		["6 structure-yellow-short", factory + "structure-yellow-short.glb", 0.8],
	]
	var x := 118
	# short lead-in double pipe so candidates are seen in context
	for lead_x in range(x - 3, x + candidates.size() * 3 + 2):
		City.model.set_heat_pipe(Vector2i(lead_x, 121), 1)
	for entry: Array in candidates:
		var node: Node3D = view._instance_glb(entry[1], entry[2])
		node.position = Vector3(x + 0.5, 0, 120.5)
		view.add_child(node)
		_gallery_label(entry[0], Vector3(x + 0.5, 1.3, 120.5))
		x += 3
	# 7: the transfer station (now the shipped heat exchanger visual)
	var station: Node3D = view._make_transfer_station()
	station.position = Vector3(x + 0.5, 0, 120.5)
	view.add_child(station)
	_gallery_label("7 procedural transfer station", Vector3(x + 0.5, 1.3, 120.5))
	view.redraw()
	view.focus_tile(Vector2i(118 + candidates.size() * 3 / 2, 122), 13.0)
	await get_tree().create_timer(1.0).timeout
	get_viewport().get_texture().get_image().save_png(_gallery_path)
	print("GALLERY saved to ", _gallery_path)
	get_tree().quit(0)


func _gallery_label(text: String, pos: Vector3) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 110
	label.outline_size = 22
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = pos
	view.add_child(label)


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
	for id: String in SidecarManager.ids():
		var handshake_ok: bool = await CosimBridge.handshake(id)
		per_sidecar[id] = {"handshake": handshake_ok,
			"solver": CosimBridge.info.get(id, {}).get("solver", "?")}
		ok = ok and handshake_ok
	print("SMOKE_SIDECARS ", JSON.stringify({"ok": ok, "sidecars": per_sidecar}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)


func _smoke_resilience() -> void:
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


## Freeze hunt: build like a player (tile drags, then plants) with the clock
## running against the real backend; measure the worst frame stall per phase.
var _stall := {"phase": "", "worst_ms": {}}


func _smoke_stress() -> void:
	# own ports (8014/8015) so a live play session on 8010/8011 is untouched
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_STRESS", "power health timeout")
		return
	City.money = 100_000_000
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 4.0})
	Orchestrator.start()
	_stall["worst_ms"] = {}
	await _stress_phase("gc+substations", func() -> void:
		City.place_building("grid_connection", Vector2i(10, 10))
		City.place_building("substation", Vector2i(30, 10))
		City.place_building("substation", Vector2i(30, 24)))
	await _stress_phase("cable_drag", func() -> void:
		for x in range(12, 30):
			City.build_cable(Vector2i(x, 10))
		for y in range(11, 25):
			City.build_cable(Vector2i(20, y))
		for x in range(21, 30):
			City.build_cable(Vector2i(x, 24)))
	await _stress_phase("road_drag", func() -> void:
		for x in range(24, 44):
			City.build_road(Vector2i(x, 12))
			City.build_road(Vector2i(x, 15))
			City.build_road(Vector2i(x, 26)))
	await _stress_phase("zone_drag", func() -> void:
		for x in range(24, 44):
			for y in [13, 14, 27]:
				City.build_zone(Vector2i(x, y)))
	await _stress_phase("houses", func() -> void:
		for sub_id: String in City.model.buildings_of_kind("substation"):
			City.spawn_houses_bulk(sub_id, 30))
	# plants one by one, waiting between them like a human would
	for plant: Array in [["wind_farm", Vector2i(14, 6)], ["solar_park", Vector2i(24, 6)],
			["gas_plant", Vector2i(34, 6)], ["battery", Vector2i(17, 8)]]:
		await _stress_phase("plant_" + plant[0], func() -> void:
			City.place_building(plant[0], plant[1])
			for y in range(7, 10):
				City.build_cable(Vector2i(plant[1].x + 1, y)))
		await _stress_wait(2.0, "after_" + plant[0])
	await _stress_wait(8.0, "running")
	var report := {"ok": true, "worst_ms": _stall["worst_ms"],
		"registered": City.registered, "houses": City.model.houses.size()}
	for phase: String in _stall["worst_ms"]:
		if float(_stall["worst_ms"][phase]) > 250.0:
			report["ok"] = false
	print("SMOKE_STRESS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


func _stress_phase(name: String, action: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	action.call()
	var blocking_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_stall["worst_ms"][name] = snappedf(blocking_ms, 0.1)
	await get_tree().process_frame


func _stress_wait(seconds: float, name: String) -> void:
	var worst := 0.0
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
	_stall["worst_ms"][name] = snappedf(worst, 0.1)


# ─── Phase 4 acceptance scenarios (district heating) ───

func _wait_heat_registered(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not City.heat_registered:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _run_steps(n: int, timeout_s: float, speed: float = 60.0) -> void:
	# derive the target from the CLOCK: current_t only updates on sim-step
	# emissions and is stale right after a GameClock.restore — resync it too,
	# or a BACKWARDS restore leaves current_t past end_t and the wait loop
	# exits after zero steps (bit the pumpblackout smoke's phase B)
	var start_t := int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES)
	City.current_t = start_t
	var end_t := start_t + n
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	GameClock.speed = speed
	while City.current_t < end_t and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
	GameClock.pause()
	await get_tree().create_timer(1.5).timeout


func _heat_zone_t(zone_id: String) -> float:
	return float(City.last_heat_result.get("zones", {}).get(zone_id, {})
		.get("detail", {}).get("t_supply_c", 0.0))


## January cold snap: undersized network → the FAR zone at the end of a long
## thin spur goes cold first (pandapipes gradient); adding a CHP near the far
## end fixes the heat AND relieves the grid (coupling); a heat-pump town on a
## weak grid connection blacks itself out.
func _smoke_coldsnap() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_COLDSNAP", "health timeout")
		return

	# ── phase A: boiler + near cluster (24 houses) + tiny far zone at the
	# end of a ~850 m trunk — deep cold forced the whole run
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, -18.0)
	City.weather.force_wind(0, 100_000, 7.0)
	City.place_building("boiler_plant", Vector2i(8, 8))
	for x in range(10, 61):  # ~1.25 km trunk — the far end is FAR
		City.build_heat_pipe(Vector2i(x, 9))
	City.place_building("heat_exchanger", Vector2i(14, 10))
	City.place_building("heat_exchanger", Vector2i(60, 10))
	for x in range(10, 27):
		City.build_road(Vector2i(x, 12))
	for x in range(10, 27):
		City.build_zone(Vector2i(x, 13))
	for x in range(56, 65):
		City.build_road(Vector2i(x, 12))
	for x in range(56, 65):
		City.build_zone(Vector2i(x, 13))
	# power net for the near cluster (needed for the coupling checks)
	City.place_building("grid_connection", Vector2i(8, 16))
	for x in range(10, 47):
		City.build_cable(Vector2i(x, 17))
	City.place_building("substation", Vector2i(20, 18))
	var heat_subs := City.model.buildings_of_kind("heat_exchanger")
	City.spawn_houses_bulk(heat_subs[0], 24)  # near
	City.spawn_houses_bulk(heat_subs[1], 2)   # far: tiny flow -> deep temp drop
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_heat_registered(60.0):
		_fail("SMOKE_COLDSNAP", "register timeout (A)")
		return
	var near_zone := "hz_" + heat_subs[0]
	var far_zone := "hz_" + heat_subs[1]
	GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(10, 240.0)
	var near_a := _heat_zone_t(near_zone)
	var far_a := _heat_zone_t(far_zone)
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var import_a := float(City.last_result.get("devices", {})
		.get(slack_id, {}).get("output_kw", 0.0))
	var far_cold_minutes: int = City.heat_outage_minutes.get(far_zone, 0)

	# ── phase B: CHP feed near the far end, cable-connected to the grid
	# the CHP must touch the trunk DIRECTLY: a dead-end stub is rejected by
	# the heat contract (leaf junctions without consumers carry no flow)
	City.place_building("chp_plant", Vector2i(44, 7))  # footprint row (44-45,8) touches the trunk at y=9
	# cable route NORTH of the pipe trunk (cables cannot cross pipes):
	# CHP top (44,7) -> west along y=6 -> south along x=7 -> grid connection
	for x in range(8, 45):
		City.build_cable(Vector2i(x, 6))
	for y in range(7, 17):
		City.build_cable(Vector2i(7, y))
	# explicit awaited re-registration (the debounce path is fire-and-forget)
	City._topo_dirty = false
	City.topo = PowerTopology.build(City.model, City.tripped_tiles)
	City.heat_topo = HeatTopology.build(City.model, City.tripped_tiles)
	City._syncing = true
	await City._register_async()
	Orchestrator.start()
	await _run_steps(12, 240.0)
	var far_b := _heat_zone_t(far_zone)
	var cpl := float(City.last_result.get("devices", {})
		.get("cpl_heat", {}).get("output_kw", 0.0))
	var import_b := float(City.last_result.get("devices", {})
		.get(slack_id, {}).get("output_kw", 0.0))
	var debug_b := {
		"registered": [City.registered, City.heat_registered],
		"heat_devices": City.heat_topo.doc.get("devices", []).map(
			func(d: Dictionary) -> String: return "%s:%s" % [d["id"], d["kind"]]),
		"power_has_cpl": City.topo.doc.get("devices", []).any(
			func(d: Dictionary) -> bool: return d["id"] == "cpl_heat"),
		"heat_result_devices": City.last_heat_result.get("devices", {}).keys(),
		"events_tail": City.events.slice(maxi(0, City.events.size() - 4)).map(
			func(e: Dictionary) -> String: return str(e["kind"])),
	}

	# ── phase C: heat-pump town on a weak grid connection → blackout
	City.reset_for_scenario(42)
	City.weather.force_temp(0, 100_000, -18.0)
	City.weather.force_wind(0, 100_000, 7.0)
	City.grid_capacity_override = 25.0
	City.place_building("heat_pump_plant", Vector2i(8, 8))
	for x in range(10, 21):  # pipe reaches (20,9), adjacent to the exchanger
		City.build_heat_pipe(Vector2i(x, 9))
	City.place_building("heat_exchanger", Vector2i(20, 10))
	for x in range(12, 29):
		City.build_road(Vector2i(x, 12))
	for x in range(12, 29):
		City.build_zone(Vector2i(x, 13))
	City.place_building("grid_connection", Vector2i(8, 16))
	for x in range(10, 24):
		City.build_cable(Vector2i(x, 17))
	for y in range(10, 16):
		# vertical run at x=9: touches the heat pump at (9,9) above and the
		# grid connection footprint at (9,16) below — the coupling path
		City.build_cable(Vector2i(9, y))
	City.place_building("substation", Vector2i(23, 18))  # touches cable (23,17)
	City.spawn_houses_bulk(City.model.buildings_of_kind("heat_exchanger")[0], 24)
	var trip_seen := {"grid": false}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "grid_trip":
			trip_seen["grid"] = true)
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_heat_registered(60.0):
		_fail("SMOKE_COLDSNAP", "register timeout (C)")
		return
	GameClock.restore({"total_minutes": 32.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(14, 240.0)

	var report := {
		"ok": far_a < near_a - 2.0 and far_a < HeatTopology.T_SUPPLY_MIN_C
			and near_a >= HeatTopology.T_SUPPLY_MIN_C and far_cold_minutes > 0
			and far_b >= HeatTopology.T_SUPPLY_MIN_C
			and cpl < -30.0 and import_b < import_a - 20.0
			and trip_seen["grid"] and City.total_outage_minutes() > 0,
		"near_t_A": snappedf(near_a, 0.1), "far_t_A": snappedf(far_a, 0.1),
		"far_cold_min_A": far_cold_minutes,
		"far_t_B": snappedf(far_b, 0.1), "cpl_heat_kw_B": snappedf(cpl, 0.1),
		"grid_import_A": snappedf(import_a, 0.1), "grid_import_B": snappedf(import_b, 0.1),
		"hp_grid_trip_C": trip_seen["grid"],
		"power_outage_min_C": City.total_outage_minutes(),
		"debug_b": debug_b,
	}
	print("SMOKE_COLDSNAP ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Buffer storage: charged at night, bridges the morning demand peak
## (assert on the SoC trajectory from the step results).
func _smoke_heatstorage() -> void:
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


# ─── Phase 5 acceptance scenarios (water) ───

func _wait_water_registered(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not City.water_registered:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _water_supplied(zone_id: String) -> float:
	return float(City.last_water_result.get("zones", {}).get(zone_id, {})
		.get("supplied", -1.0))


func _water_p_bar(zone_id: String) -> float:
	return float(City.last_water_result.get("zones", {}).get(zone_id, {})
		.get("detail", {}).get("p_bar", -1.0))


## Shared layout: pump-fed town, optionally buffered by an elevated tank.
## Pump at (8,8) 2x2, cable column at x=7 down to the grid connection at
## (8,16), water trunk y=9 x=10..20, station (21,9), houses on road y=12.
func _build_pump_town(with_tower: bool, tower_params: Dictionary = {}) -> void:
	City.place_building("pumping_station", Vector2i(8, 8))
	for x in range(10, 21):
		City.build_water_pipe(Vector2i(x, 9))
	City.place_building("water_station", Vector2i(21, 9))
	if with_tower:
		City.place_building("water_tower", Vector2i(14, 5), 0, tower_params)
		for y in range(6, 9):  # spur from the tower down to the trunk
			City.build_water_pipe(Vector2i(14, y))
	City.place_building("grid_connection", Vector2i(8, 16))
	for y in range(8, 17):  # (7,16) touches the grid connection footprint
		City.build_cable(Vector2i(7, y))
	for x in range(14, 31):
		City.build_road(Vector2i(x, 12))
	for x in range(14, 31):
		City.build_zone(Vector2i(x, 13))
	City.spawn_houses_bulk(City.model.buildings_of_kind("water_station")[0], 24)


## THE cross-vector scenario: a blackout at the pumping station. Without a
## tower the head collapses next step — instant dry taps. With a (small)
## tower the town rides through on stored water until the tank runs dry:
## water buys time, elevation is a battery.
func _smoke_pumpblackout() -> void:
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


## Summer drought: the well's yield collapses (aquifer state via
## yield_factor) while heat drives demand up — the tower drains, then the
## taps weaken. Wagner PDD makes it gradual: weak taps before dry taps.
func _smoke_drought() -> void:
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
	City.place_building("water_tower", Vector2i(8, 8), 0, {"volume_m3": 0.8})
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
	await _run_steps(24, 300.0)                  # 6 h of net drain
	var soc_dry := float(City.last_water_result.get("devices", {})
		.get(tower_id, {}).get("soc", -1.0))
	var supplied_dry := _water_supplied(zone_id)
	var well_q_dry := float(City.last_water_result.get("devices", {})
		.get(well_id, {}).get("detail", {}).get("q_m3h", -1.0))
	var report := {
		# well_q_* stay diagnostic: full-tank throttling is backend machinery
		"ok": supplied_wet >= 0.99 and soc_wet > 0.3
			and soc_dry < soc_wet - 0.1 and supplied_dry < 0.99
			and City.total_water_outage_minutes() > 0,
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


## Hydraulics check the player can feel: the same town fed by a 25 m vs a
## 45 m tower — the taller tower holds ~2 bar more at the taps (Δh≈20 m).
func _smoke_towerheight() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_TOWERHEIGHT", "health timeout")
		return
	var p_bars := {}
	for height: float in [25.0, 45.0]:
		City.reset_for_scenario(42)
		City.weather.force_temp(0, 100_000, 15.0)
		City.place_building("water_tower", Vector2i(8, 8), 0,
			{"tower_height_m": height})
		for x in range(9, 21):
			City.build_water_pipe(Vector2i(x, 8))
		City.place_building("water_station", Vector2i(21, 8))
		for x in range(14, 31):
			City.build_road(Vector2i(x, 11))
		for x in range(14, 31):
			City.build_zone(Vector2i(x, 12))
		City.spawn_houses_bulk(City.model.buildings_of_kind("water_station")[0], 12)
		City._topo_dirty = true
		if not await _wait_water_registered(180.0):
			_fail("SMOKE_TOWERHEIGHT", "register timeout (%.0f m)" % height)
			return
		var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
		GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(6, 240.0)
		p_bars[height] = _water_p_bar(zone_id)
	var p_25: float = p_bars[25.0]
	var p_45: float = p_bars[45.0]
	var report := {
		"ok": p_25 > 0.0 and p_45 > p_25 + 1.5 and p_45 < p_25 + 2.5,
		"p_bar_25m": snappedf(p_25, 0.01), "p_bar_45m": snappedf(p_45, 0.01),
		"delta_bar": snappedf(p_45 - p_25, 0.01),
		"expected_delta_bar": 1.96,
		"water_status": City.last_water_result.get("status", "?"),
	}
	print("SMOKE_TOWERHEIGHT ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Terrain hydraulics: the SAME tower on a 4-level (20 m) hill vs in the
## valley — junction elevations come from per-tile heights now, so the
## hilltop tower must deliver ~1.96 bar more at the taps (ROADMAP Phase 5
## task 3 / elevation acceptance).
func _smoke_hilltower() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_HILLTOWER", "health timeout")
		return
	var p_bars := {}
	for hill_level: int in [0, 4]:
		City.reset_for_scenario(42)
		City.weather.force_temp(0, 100_000, 15.0)
		if hill_level > 0:
			City.model.terrain.force_height(Vector2i(6, 6), Vector2i(10, 10), hill_level)
		City.place_building("water_tower", Vector2i(8, 8))
		for x in range(9, 21):
			City.build_water_pipe(Vector2i(x, 8))
		City.place_building("water_station", Vector2i(21, 8))
		for x in range(14, 31):
			City.build_road(Vector2i(x, 11))
		for x in range(14, 31):
			City.build_zone(Vector2i(x, 12))
		City.spawn_houses_bulk(City.model.buildings_of_kind("water_station")[0], 12)
		City._topo_dirty = true
		if not await _wait_water_registered(180.0):
			_fail("SMOKE_HILLTOWER", "register timeout (hill %d)" % hill_level)
			return
		var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
		GameClock.restore({"total_minutes": 8.0 * 60.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(6, 240.0)
		p_bars[hill_level] = _water_p_bar(zone_id)
	var p_valley: float = p_bars[0]
	var p_hill: float = p_bars[4]
	var report := {
		"ok": p_valley > 0.0 and p_hill > p_valley + 1.5 and p_hill < p_valley + 2.5,
		"p_bar_valley": snappedf(p_valley, 0.01), "p_bar_hill": snappedf(p_hill, 0.01),
		"delta_bar": snappedf(p_hill - p_valley, 0.01),
		"expected_delta_bar": 1.96,  # 4 levels x 5 m = 20 m of water column
		"water_status": City.last_water_result.get("status", "?"),
	}
	print("SMOKE_HILLTOWER ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


# ─── Phase 6 acceptance scenarios (living demand) ───

## The three-network reference town both Phase 6 smokes run on — built
## COMPACT originally because the first draft's 0.4-kV feeders sagged under
## 0.90 pu at range (chronic brownouts, satisfaction 12/100). The grid is
## 20 kV MV now (realism pass) so voltage is no longer the constraint, but
## the compact layout stays — it keeps the smokes fast and readable.
func _build_reference_city(seed_houses: int) -> void:
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 32):  # ..31: the east column hangs off (31,5)
		City.build_cable(Vector2i(x, 5))
	City.place_building("gas_plant", Vector2i(16, 3))
	City.place_building("solar_park", Vector2i(20, 3))
	City.place_building("battery", Vector2i(25, 4))
	# the substation sits FIVE tiles from the grid connection: at the full
	# ~28-house evening peak the drop stays ~2-3% (v_pu ≥ 0.95) — the first
	# drafts sagged to 0.889 at range and bled satisfaction every evening
	City.place_building("substation", Vector2i(12, 6))
	for x in range(8, 25):
		City.build_road(Vector2i(x, 8))
	for x in range(8, 25):
		City.build_road(Vector2i(x, 11))
	for x in range(8, 25):
		City.build_zone(Vector2i(x, 9))
	for x in range(8, 25):
		City.build_zone(Vector2i(x, 10))  # served by the y=11 road
	for x in range(8, 19):
		City.build_zone(Vector2i(x, 12))
	City.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 15):
		City.build_heat_pipe(Vector2i(x, 14))
	City.place_building("heat_exchanger", Vector2i(15, 14))
	City.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 15):
		City.build_water_pipe(Vector2i(x, 17))
	City.place_building("water_station", Vector2i(15, 17))
	City.place_building("well", Vector2i(10, 19))
	City.build_water_pipe(Vector2i(10, 18))
	City.place_building("pumping_station", Vector2i(12, 19))
	City.build_water_pipe(Vector2i(12, 18))
	for y in range(6, 20):  # east cable column feeds the pump at (14,19)
		City.build_cable(Vector2i(31, y))
	for x in range(14, 31):
		City.build_cable(Vector2i(x, 19))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], seed_houses)


func _wait_three_registered(timeout_s: float) -> bool:
	return await _wait_registered(timeout_s) \
		and await _wait_heat_registered(60.0) \
		and await _wait_water_registered(60.0)


## Long-run seasonal recording (ROADMAP Phase 6 task 4 + acceptance): four
## 3-day workweek windows across the year, demand recorded per step to CSV;
## the load-duration shape checks are qualitative inequalities (winter heat
## peak, BDEW double peak, summer PV surplus, summer water surge) — robust
## where golden files would rot.
func _smoke_yearcurves() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_YEARCURVES", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false  # constant town: curves must come from demand
	_build_reference_city(24)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_YEARCURVES", "register timeout")
		return
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	var rows: Array = []
	var statuses := {"bad": 0, "total": 0}
	City.power_result.connect(func(t: int, result: Dictionary) -> void:
		var elec := 0.0
		for zone_id: String in City.topo.zones_info:
			elec += DemandModel.zone_demand_kw(
				City.topo.zones_info[zone_id]["houses"], t)
		var temp := float(City.weather.sample(t)["temp_c"])
		var heat := 0.0
		for zone_id: String in City.heat_topo.zones_info:
			heat += DemandModel.heat_zone_demand_kw(
				City.heat_topo.zones_info[zone_id]["houses"], t, temp)
		var water := 0.0
		for zone_id: String in City.water_topo.zones_info:
			water += DemandModel.water_zone_demand_m3h(
				City.water_topo.zones_info[zone_id]["houses"], t, temp)
		var import_kw := float(result.get("devices", {})
			.get(slack_id, {}).get("output_kw", 0.0))
		rows.append([t, snappedf(elec, 0.01), snappedf(heat, 0.01),
			snappedf(water, 0.0001), snappedf(import_kw, 0.01), temp]))
	for sig: Signal in [City.power_result, City.heat_result, City.water_result]:
		sig.connect(func(_t: int, result: Dictionary) -> void:
			statuses["total"] += 1
			if result.get("status", "failed") == "failed":
				statuses["bad"] += 1)
	# windows start on workdays (day % 7 == 0): winter/transition/summer/autumn
	for start_day: int in [301, 42, 133, 224]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(288, 900.0, 200.0)
	# ── aggregate ──
	var window_of := func(t: int) -> String:
		var day := t / 96
		if day >= 301: return "winter"
		if day >= 224: return "autumn"
		if day >= 133: return "summer"
		return "transition"
	var mean := func(filter: Callable, column: int) -> float:
		var acc := 0.0
		var n := 0
		for row: Array in rows:
			if filter.call(row):
				acc += row[column]
				n += 1
		return acc / maxf(n, 1.0)
	var hour_of := func(t: int) -> int: return (t % 96) / 4
	var heat_winter: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter", 2)
	var heat_summer: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer", 2)
	var elec_w_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 1)
	var elec_w_night: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 2 and hour_of.call(r[0]) < 5, 1)
	var elec_w_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 1)
	var elec_s_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 1)
	var elec_s_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 1)
	var water_winter: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "winter", 3)
	var water_summer: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer", 3)
	var import_s_midday: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 11 and hour_of.call(r[0]) < 14, 4)
	var import_s_evening: float = mean.call(func(r: Array) -> bool:
		return window_of.call(r[0]) == "summer" and hour_of.call(r[0]) >= 18 and hour_of.call(r[0]) < 21, 4)
	# ── CSV (the durable record for tools/balancing) ──
	var csv := "t,day,elec_kw,heat_kw,water_m3h,grid_import_kw,temp_c\n"
	for row: Array in rows:
		csv += "%d,%d,%s,%s,%s,%s,%s\n" % [row[0], row[0] / 96, row[1], row[2],
			row[3], row[4], row[5]]
	var csv_path := ProjectSettings.globalize_path("res://") + "../logs/yearcurves.csv"
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f:
		f.store_string(csv)
		f.close()
	var report := {
		"ok": heat_winter > 3.0 * heat_summer
			and elec_w_evening > 2.0 * elec_w_night
			and elec_w_evening > 1.15 * elec_w_midday
			# summer PV surplus: NET zone load (realism pass: rooftop PV is
			# part of the composition) collapses at midday — often negative —
			# while the EV evening peak stands tall
			and elec_s_midday < 0.5 * elec_s_evening
			and water_summer > 1.15 * water_winter
			and import_s_midday < import_s_evening - 20.0
			and statuses["bad"] == 0
			# drift/leak guard: failed solves and protocol desync are the
			# signal; a few in-flight overrun skips at 200x fast-forward are
			# the designed never-stall behavior, so the bound is generous
			and Orchestrator.stats["missed"] < 0.10 * Orchestrator.stats["dispatched"]
			and Orchestrator.stats["completed"] == Orchestrator.stats["dispatched"],
		"heat_kw_winter": snappedf(heat_winter, 0.1), "heat_kw_summer": snappedf(heat_summer, 0.1),
		"elec_winter_evening": snappedf(elec_w_evening, 0.1),
		"elec_winter_midday": snappedf(elec_w_midday, 0.1),
		"elec_winter_night": snappedf(elec_w_night, 0.1),
		"elec_summer_midday": snappedf(elec_s_midday, 0.1),
		"elec_summer_evening": snappedf(elec_s_evening, 0.1),
		"water_m3h_winter": snappedf(water_winter, 0.001),
		"water_m3h_summer": snappedf(water_summer, 0.001),
		"grid_import_summer_midday": snappedf(import_s_midday, 0.1),
		"grid_import_summer_evening": snappedf(import_s_evening, 0.1),
		"failed_steps": statuses["bad"], "results_seen": statuses["total"],
		"samples": rows.size(), "csv": csv_path,
		"orch": Orchestrator.stats,
	}
	print("SMOKE_YEARCURVES ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Growth feedback (ROADMAP Phase 6 acceptance): a well-built city grows
## through a compressed year without intervention; a fragile one (wind-only
## behind an undersized grid connection) stalls and empties out.
func _smoke_citylife() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_CITYLIFE", "health timeout")
		return

	# ── phase A: the reference town, seeded small
	City.reset_for_scenario(42)
	_build_reference_city(6)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_CITYLIFE", "register timeout (A)")
		return
	var houses_start_a := City.model.houses.size()
	var dark_steps: Array = []
	City.power_result.connect(func(t: int, result: Dictionary) -> void:
		for zone_id: String in City.topo.zones_info:
			if not City.zone_supplied.get(zone_id, true) \
					and City.topo.zones_info[zone_id]["houses"] > 0 \
					and dark_steps.size() < 40:
				var zone: Dictionary = result.get("zones", {}).get(zone_id, {})
				dark_steps.append("t%d %s sup=%s vpu=%s status=%s trip=%s" % [t,
					zone_id, str(zone.get("supplied", "?")),
					str(zone.get("detail", {}).get("v_pu", "?")),
					str(result.get("status", "?")),
					str(City.grid_trip_until > t)]))
	for start_day: int in [10, 70, 130, 190, 250, 310]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(192, 600.0, 240.0)
	var houses_end_a := City.model.houses.size()
	var happiness_a := City.happiness
	var satisfaction_a := City.satisfaction.duplicate()

	# ── phase B: fragile — wind-only behind an 18 kW grid connection
	City.reset_for_scenario(42)
	City.grid_capacity_override = 18.0
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 42):
		City.build_cable(Vector2i(x, 5))
	City.place_building("wind_farm", Vector2i(10, 3))
	City.place_building("substation", Vector2i(30, 6))
	for x in range(24, 41):
		City.build_road(Vector2i(x, 8))
	for x in range(24, 41):
		City.build_zone(Vector2i(x, 9))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 12)
	var seen := {"trip": false, "abandoned": false}
	City.event_logged.connect(func(event: Dictionary) -> void:
		if event["kind"] == "grid_trip":
			seen["trip"] = true
		elif event["kind"] == "abandoned":
			seen["abandoned"] = true)
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_CITYLIFE", "register timeout (B)")
		return
	var houses_start_b := City.model.houses.size()
	for start_day: int in [10, 70, 130, 190, 250, 310]:
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(192, 600.0, 240.0)
	var houses_end_b := City.model.houses.size()
	var happiness_b := City.happiness

	var ok: bool = houses_end_a >= houses_start_a + 12 and happiness_a >= 80.0 \
		and houses_end_b <= houses_start_b + 2 and happiness_b < 55.0 \
		and (seen["trip"] or seen["abandoned"])
	var report := {
		"ok": ok,
		"A_houses": [houses_start_a, houses_end_a],
		"A_happiness": snappedf(happiness_a, 0.1),
		"A_satisfaction": satisfaction_a,
		"B_houses": [houses_start_b, houses_end_b],
		"B_happiness": snappedf(happiness_b, 0.1),
		"B_trip_seen": seen["trip"], "B_abandoned_seen": seen["abandoned"],
		"orch": Orchestrator.stats,
	}
	if not ok:  # unsupplied-step trace (t, v_pu, status) — the debugging view
		report["A_dark_steps"] = dark_steps
	print("SMOKE_CITYLIFE ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


# ─── Phase 7 acceptance scenarios (game layer) ───

static func _econ_delta(now: Dictionary, then: Dictionary) -> Dictionary:
	var out := {}
	for key: String in now:
		var d: float = now[key] - float(then.get(key, 0.0))
		if absf(d) > 0.005:
			out[key] = snappedf(d, 0.01)
	return out


static func _econ_net(delta: Dictionary) -> float:
	var net := 0.0
	for key: String in delta:
		if not key.begins_with("loan"):
			net += delta[key]
	return net


## Economy acceptance: tariffs earn on DELIVERED energy/water, fuel tracks
## the solved plant output, seasons move both — and a blackout day visibly
## costs revenue. Window totals land in tools/balancing/economy_windows.csv.
func _smoke_economy() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_ECONOMY", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	_build_reference_city(24)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_ECONOMY", "register timeout")
		return
	var snaps: Array[Dictionary] = []
	for start_day: int in [301, 133]:  # winter, summer — 2 days each
		GameClock.restore({"total_minutes": start_day * 1440.0, "speed": 0.0})
		Orchestrator.start()
		var before := City.econ_total.duplicate()
		await _run_steps(192, 600.0, 200.0)
		snaps.append(_econ_delta(City.econ_total, before))
	# a scripted blackout day: the grid trips, delivered energy collapses
	GameClock.restore({"total_minutes": 303.0 * 1440.0, "speed": 0.0})
	City.grid_trip_until = 1_000_000
	Orchestrator.start()
	var before_dark := City.econ_total.duplicate()
	await _run_steps(96, 400.0, 200.0)
	var dark := _econ_delta(City.econ_total, before_dark)
	var winter: Dictionary = snaps[0]
	var summer: Dictionary = snaps[1]
	# balancing sheet: category totals per window
	var csv := "category,winter_2d,summer_2d,blackout_1d\n"
	var keys := {}
	for window: Dictionary in [winter, summer, dark]:
		for key: String in window:
			keys[key] = true
	var sorted_keys := keys.keys()
	sorted_keys.sort()
	for key: String in sorted_keys:
		csv += "%s,%.2f,%.2f,%.2f\n" % [key, winter.get(key, 0.0),
			summer.get(key, 0.0), dark.get(key, 0.0)]
	var csv_path := ProjectSettings.globalize_path("res://") \
		+ "../tools/balancing/economy_windows.csv"
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f:
		f.store_string(csv)
		f.close()
	var report := {
		"ok": float(winter.get("income_elec", 0.0)) > 0.0
			and float(winter.get("income_heat", 0.0)) > 0.0
			and float(winter.get("income_water", 0.0)) > 0.0
			and float(winter.get("cost_fuel", 0.0)) < 0.0
			and float(winter.get("cost_upkeep", 0.0)) < 0.0
			and float(winter.get("income_heat", 0.0)) > 2.0 * float(summer.get("income_heat", 0.0))
			and absf(float(winter.get("cost_fuel", 0.0))) > absf(float(summer.get("cost_fuel", 0.0)))
			and _econ_net(winter) + _econ_net(summer) > 0.0
			and float(dark.get("income_elec", 0.0)) < 0.2 * float(winter.get("income_elec", 1.0)) / 2.0,
		"winter_2d": winter, "summer_2d": summer, "blackout_1d": dark,
		"net_winter": snappedf(_econ_net(winter), 0.01),
		"net_summer": snappedf(_econ_net(summer), 0.01),
		"csv": csv_path,
	}
	print("SMOKE_ECONOMY ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Failure events: every kind exercised scripted, consequences physically
## solved — storm cut-out, equipment failure + repair, planned maintenance,
## hydrant fire flow (pressure sag), pipe burst (topology loss + recovery).
func _smoke_events() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_EVENTS", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	_build_reference_city(24)
	City.place_building("wind_farm", Vector2i(27, 3))  # storm test subject
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

	# 5. PIPE BURST on the trunk: the only head is cut off — network down,
	# repair + resync bring it back
	await _run_steps(8, 240.0)
	City._apply_event(City.event_system.make_burst(Vector2i(10, 17),
		["%s" % zone_id], City.current_t), City.current_t)
	await _run_steps(10, 300.0)
	var water_down_during_burst := not City.water_registered \
		or City.water_topo.zones_info.is_empty()
	await _run_steps(24, 400.0)
	var supplied_after := _water_supplied(zone_id)

	var report := {
		"ok": wind_pre > 10.0 and wind_storm == 0.0 and gas_storm > 5.0
			and gas_down == 0.0 and gas_back > 5.0
			and pump_pre > 0.0 and pump_maint == 0.0
			and p_bar_fire < p_bar_before_fire - 0.05
			and water_down_during_burst and supplied_after >= 0.99,
		"wind_pre": snappedf(wind_pre, 0.1), "wind_storm": wind_storm,
		"gas_storm": snappedf(gas_storm, 0.1), "gas_down": gas_down,
		"gas_back": snappedf(gas_back, 0.1),
		"pump_pre": snappedf(pump_pre, 0.1), "pump_maint": pump_maint,
		"p_bar_pre": snappedf(p_bar_pre, 0.01),
		"p_bar_before_fire": snappedf(p_bar_before_fire, 0.01),
		"p_bar_fire": snappedf(p_bar_fire, 0.01),
		"water_down_during_burst": water_down_during_burst,
		"supplied_after_burst": snappedf(supplied_after, 0.01),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_EVENTS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Scenario acceptance: greenfield is winnable (with a loan), the inherited
## grid loses on its own, the energy transition is winnable by retiring the
## fossil plant, and the tutorial chain advances step by step.
func _smoke_scenarios() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_SCENARIOS", "health timeout")
		return

	# ── A: greenfield — loan, build, grow to the win
	var state := Scenarios.start("greenfield", "normal")
	# the fixed reference layout must stay buildable: greenfield's seed-19
	# terrain now carries RIVERS (environment pass) — keep the build area dry
	# (players route around water; the smoke tests scenario mechanics)
	City.model.terrain.force_water(Vector2i(0, 0), Vector2i(45, 25), false)
	City.take_loan(300_000.0)  # the 110/20 kV station alone is 120k
	_build_reference_city(6)
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (greenfield)")
		return
	var verdict_green := ""
	for i in 8:
		GameClock.restore({"total_minutes": (10.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_green = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_green != "":
			break
	var green_houses := City.model.houses.size()

	# ── B: inherited grid — do nothing, watch it lose
	state = Scenarios.start("brownfield", "normal")
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (brownfield)")
		return
	var verdict_brown := ""
	for i in 16:
		GameClock.restore({"total_minutes": (301.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_brown = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_brown != "":
			break
	var brown_happiness := City.happiness
	var brown_state := state.duplicate()

	# ── C: energy transition — retire the fossil plant, win
	GameClock.restore({"total_minutes": 100.0 * 1440.0, "speed": 0.0})
	state = Scenarios.start("transition", "normal")
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_SCENARIOS", "register timeout (transition)")
		return
	var fossil: Vector2i = City.model.buildings[
		City.model.buildings_of_kind("gas_plant")[0]]["anchor"]
	City.bulldoze(fossil)
	City.place_building("solar_park", Vector2i(20, 3))
	City.place_building("battery", Vector2i(25, 4))
	var verdict_transition := ""
	for i in 10:
		GameClock.restore({"total_minutes": (100.0 + i) * 1440.0, "speed": 0.0})
		Orchestrator.start()
		await _run_steps(96, 400.0, 240.0)
		verdict_transition = Scenarios.evaluate(state, City.current_t / 96)
		if verdict_transition != "":
			break

	# ── D: tutorial chain — perform each step, predicates must advance
	Scenarios.start("tutorial", "normal")
	var steps := Scenarios.tutorial_steps()
	var tutorial_ok := true
	City.place_building("grid_connection", Vector2i(6, 4))
	tutorial_ok = tutorial_ok and (steps[0]["done"] as Callable).call()
	for x in range(8, 13):
		City.build_cable(Vector2i(x, 5))
	City.place_building("substation", Vector2i(12, 6))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[1]["done"] as Callable).call()
	for x in range(8, 17):
		City.build_road(Vector2i(x, 8))
	for x in range(8, 17):
		City.build_zone(Vector2i(x, 9))
	tutorial_ok = tutorial_ok and (steps[2]["done"] as Callable).call()
	for x in range(8, 11):
		City.model.spawn_house(Vector2i(x, 9))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[3]["done"] as Callable).call()
	City.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 13):
		City.build_heat_pipe(Vector2i(x, 14))
	tutorial_ok = tutorial_ok and (steps[4]["done"] as Callable).call()
	City.place_building("heat_exchanger", Vector2i(13, 14))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[5]["done"] as Callable).call()
	City.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 13):
		City.build_water_pipe(Vector2i(x, 17))
	tutorial_ok = tutorial_ok and (steps[6]["done"] as Callable).call()
	City.place_building("water_station", Vector2i(13, 17))
	City._refresh_topo_assignment()
	tutorial_ok = tutorial_ok and (steps[7]["done"] as Callable).call()

	var report := {
		"ok": verdict_green == "win" and green_houses >= 25
			and verdict_brown == "lose" and brown_happiness < 20.0
			and verdict_transition == "win" and tutorial_ok,
		"greenfield": verdict_green, "greenfield_houses": green_houses,
		"brownfield": verdict_brown,
		"brownfield_happiness": snappedf(brown_happiness, 0.1),
		"brownfield_state": brown_state,
		"transition": verdict_transition,
		"tutorial_chain": tutorial_ok,
		"orch": Orchestrator.stats,
	}
	print("SMOKE_SCENARIOS ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


## Capacity signaling + paid maintenance: an undersized transformer signals,
## trips, and STAYS dark until a crew is paid; a manually tripped trunk
## section blacks out the whole downstream branch until its crew arrives.
func _smoke_maintenance() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(240.0):
		_fail("SMOKE_MAINTENANCE", "health timeout")
		return
	City.reset_for_scenario(42)
	City.growth_enabled = false
	# evening import (30 houses incl. EV charging) crosses 80% of 100 kW well
	# before the trafo trips — the signal precedes the failure, and the
	# 110/20 kV interface itself never trips in this smoke
	City.grid_capacity_override = 100.0
	City.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 33):
		City.build_cable(Vector2i(x, 5))
	# an undersized 50 kVA village trafo (explicit-parameter element): the
	# EV evening peak pushes its SOLVED loading past 120% within the run
	City.place_building("substation", Vector2i(12, 6), 0, {"rating_kva": 50.0})
	# healthy control zone FAR east — its radius must not steal A's houses
	City.place_building("substation", Vector2i(32, 6))
	for y in [8, 11]:
		for x in range(8, 21):
			City.build_road(Vector2i(x, y))
	for y in [9, 10, 12]:
		for x in range(8, 21):
			City.build_zone(Vector2i(x, y))
	City.spawn_houses_bulk(City.model.buildings_of_kind("substation")[0], 30)
	City._topo_dirty = true
	if not await _wait_registered(240.0):
		_fail("SMOKE_MAINTENANCE", "register timeout")
		return
	var sub_a: String = City.model.buildings_of_kind("substation")[0]
	var sub_b: String = City.model.buildings_of_kind("substation")[1]
	var zone_a := "z_" + sub_a
	var zone_b := "z_" + sub_b
	# grid warning is latched DURING the run: once zone A trips, its demand
	# drops off the wire and the end-state import sits well below the signal
	var latch := {"grid_warned": false}
	var slack_id: String = City.model.buildings_of_kind("grid_connection")[0]
	City.power_result.connect(func(_t: int, _result: Dictionary) -> void:
		if City.capacity_warnings.has(slack_id):
			latch["grid_warned"] = true)
	GameClock.restore({"total_minutes": 301.0 * 1440.0 + 17.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(10, 240.0)
	var tripped := City.tripped_substations.has(sub_a)
	var trip_marker: bool = City.capacity_warnings.get(sub_a, {}).get("text", "") == "TRIP"
	var grid_warned: bool = latch["grid_warned"]
	var a_dark_1: bool = not City.zone_supplied.get(zone_a, true)
	var b_alive: bool = City.zone_supplied.get(zone_b, false)
	# no self-healing: well past the old 2 h auto-repair, still dark
	await _run_steps(12, 240.0)
	var a_dark_2: bool = not City.zone_supplied.get(zone_a, true)
	# pay the crew (and right-size the trafo so it doesn't re-trip; the new
	# rating is baked into the solver doc, so force a topology rebuild)
	City.model.buildings[sub_a]["params"]["rating_kva"] = 630.0
	City._topo_dirty = true
	var repaired := City.dispatch_repair(City.model.buildings[sub_a]["anchor"])
	var maintenance_cost := float(City.econ_total.get("cost_maintenance", 0.0))
	await _run_steps(City.REPAIR_STEPS + 2, 240.0)
	var a_back: bool = City.zone_supplied.get(zone_a, false)

	# ── branch disconnection: trip the trunk between the subs; everything
	# downstream (zone B) goes dark until ITS crew arrives
	for x in range(15, 18):
		City.tripped_tiles[Vector2i(x, 5)] = City.AWAITING_CREW
	City._topo_dirty = true
	await _run_steps(8, 240.0)
	# a zone cut from the topology has NO entry at all — absent means dark
	var b_dark: bool = not City.zone_supplied.get(zone_b, false)
	var trip_tile_marker := City.capacity_warnings.has("trip_0")
	var repaired_line := City.dispatch_repair(Vector2i(16, 5))
	await _run_steps(City.REPAIR_STEPS + 6, 300.0)
	var b_back: bool = City.zone_supplied.get(zone_b, false)

	var report := {
		"ok": tripped and trip_marker and grid_warned and a_dark_1 and b_alive
			and a_dark_2 and repaired and maintenance_cost == -float(City.CREW_COST)
			and a_back and b_dark and trip_tile_marker and repaired_line and b_back,
		"trafo_tripped": tripped, "trip_marker": trip_marker,
		"grid_warning": grid_warned,
		"a_dark_after_trip": a_dark_1, "b_alive_meanwhile": b_alive,
		"a_still_dark_no_autoheal": a_dark_2,
		"crew_paid": repaired, "maintenance_cost": maintenance_cost,
		"a_back_after_crew": a_back,
		"branch_dark_after_line_trip": b_dark, "trip_tile_marker": trip_tile_marker,
		"line_crew_paid": repaired_line, "b_back_after_crew": b_back,
		"warnings_seen": City.capacity_warnings.keys(),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_MAINTENANCE ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


var _playtest_seed := 20260730  # override with --seed=N for fuzz sweeps


## Monkey player (Phase 8 hardening, user request): plays like a human
## through the SAME City APIs the UI calls — seeded random path drags,
## building placements (often deliberately invalid), bulldozing, repairs,
## loans and mid-play save/load roundtrips against the LIVE solvers with
## random events ON — and checks WorldModel invariants + engine health
## after every action. Every reported problem is a bug.
func _smoke_playtest() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_PLAYTEST", "health timeout")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = _playtest_seed
	City.reset_for_scenario(42)
	City.model.terrain.set_seed(19)   # hills + rivers: exercise blocking
	City.model.terrain.force_height(Vector2i(0, 0), Vector2i(45, 25), 0)
	City.money = 500_000
	City.events_enabled = true
	_build_reference_city(8)          # a live town so the solvers have work
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_PLAYTEST", "register timeout")
		return
	var problems: Array[String] = []
	var actions := {"path": 0, "building": 0, "bulldoze": 0, "repair": 0,
		"loan": 0, "saveload": 0, "built_tiles": 0}
	var statuses := {}
	City.power_result.connect(func(_t: int, result: Dictionary) -> void:
		var s: String = result.get("status", "?")
		statuses[s] = statuses.get(s, 0) + 1)
	var builds: Array[String] = []
	builds.assign(City.PATH_BUILDS.keys())
	var kinds: Array[String] = []
	kinds.assign(BuildingDefs.DEFS.keys())
	var moves: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, 1), Vector2i(0, -1)]

	for burst in 24:
		for action in 8:
			var roll := rng.randf()
			# bias half the actions near the town, half into the wilderness
			var origin := Vector2i(rng.randi_range(4, 40), rng.randi_range(2, 24)) \
				if rng.randf() < 0.5 \
				else Vector2i(rng.randi_range(46, 220), rng.randi_range(26, 220))
			if roll < 0.40:
				var tiles: Array[Vector2i] = [origin]
				var cur := origin
				for i in rng.randi_range(2, 18):
					cur += moves[rng.randi_range(0, 3)]
					tiles.append(cur)
				actions["built_tiles"] += City.build_path(
					builds[rng.randi_range(0, builds.size() - 1)], tiles)
				actions["path"] += 1
			elif roll < 0.60:
				City.place_building(kinds[rng.randi_range(0, kinds.size() - 1)],
					origin, rng.randi_range(0, 3), {}, rng.randf() < 0.5)
				actions["building"] += 1
			elif roll < 0.75:
				City.bulldoze(origin)
				actions["bulldoze"] += 1
			elif roll < 0.85:
				if not City.tripped_tiles.is_empty():
					City.dispatch_repair((City.tripped_tiles.keys())[0])
				elif not City.tripped_substations.is_empty():
					City.dispatch_repair(City.model.buildings[
						(City.tripped_substations.keys())[0]]["anchor"])
				actions["repair"] += 1
			elif roll < 0.95:
				if rng.randf() < 0.5:
					City.take_loan(50_000.0)
				else:
					City.repay_loan(25_000.0)
				actions["loan"] += 1
			else:
				# mid-play save/load: the state must come back UNCHANGED
				# (both sides JSON-normalized — int/float is a wire artifact)
				var path := "user://playtest_save.json"
				SaveGame.save_to(path)
				var norm := func(value: Variant) -> String:
					return JSON.stringify(JSON.parse_string(JSON.stringify(value)))
				var city_a: String = norm.call(City.serialize())
				var model_a: String = City.model.to_json()
				SaveGame.load_from(path)
				if norm.call(City.serialize()) != city_a:
					problems.append("burst %d: save/load changed the city state" % burst)
				if City.model.to_json() != model_a:
					problems.append("burst %d: save/load changed the model" % burst)
				actions["saveload"] += 1
			for violation: String in City.model.check_invariants():
				var line := "burst %d: %s" % [burst, violation]
				if not problems.has(line):  # dedupe repeats per action loop
					problems.append(line)
			if not is_finite(float(City.money)):
				problems.append("burst %d: money is not finite" % burst)
			if problems.size() > 25:
				break
		# let sim time pass; every 4th burst idle past the topo debounce so
		# registration really happens mid-chaos
		GameClock.speed = 60.0
		await get_tree().create_timer(1.0).timeout
		GameClock.pause()
		if burst % 4 == 3:
			await get_tree().create_timer(3.2).timeout
			GameClock.speed = 60.0
			await get_tree().create_timer(2.0).timeout
			GameClock.pause()
		if problems.size() > 25:
			break
	# closing health check: the engine must still be alive and solving
	await get_tree().create_timer(3.2).timeout
	GameClock.speed = 60.0
	await get_tree().create_timer(3.0).timeout
	GameClock.pause()
	await get_tree().create_timer(1.0).timeout
	var solved := int(statuses.get("converged", 0)) + int(statuses.get("degraded", 0))
	if solved == 0:
		problems.append("power solver produced no usable frames all run")
	var report := {
		"ok": problems.is_empty(),
		"problems": problems.slice(0, 25),
		"actions": actions, "statuses": statuses,
		"houses": City.model.houses.size(), "money": City.money,
		"tripped_tiles": City.tripped_tiles.size(),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_PLAYTEST ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)


# ─── Phase 3 acceptance scenarios ───

## Wind-only town behind a tiny grid connection: outages must occur exactly
## during the forced calm window; a battery bridges it (ROADMAP Phase 3).
func _smoke_windless_week() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
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
	City.reset_for_scenario(weather_seed)
	City.growth_enabled = false  # fixed 6 houses — the EMA needs a stable target
	# between the battery-shaved evening import (~EMA, <10 kW) and the raw
	# EV-peak import (~22 kW): the plain town trips, the battery town holds
	City.grid_capacity_override = 14.0
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

	# clock: start at the next full day boundary; calm 12:00-24:00 on day 1 —
	# the window must cover the EV evening peak, where the import spike lives
	var t0 := (int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES / 96) + 1) * 96
	GameClock.restore({"total_minutes": t0 * float(GameClock.SIM_STEP_MINUTES), "speed": 0.0})
	var calm_start := t0 + 48
	var calm_end := t0 + 96
	# scripted series: solid wind across the whole run, dead calm inside the
	# window — "outages fire exactly when the weather series says calm";
	# 7 m/s keeps the 9-MW farm at a modest few-hundred-kW output
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


## Two feeders from the grid connection; the heavy one carries an 18-MW wind
## park (2 farms) at its far end — at full wind the EXPORT overloads the
## 20-kV overhead run (~7.3 MVA) past 120 %, trips, and blacks out ONLY the
## zones behind the cut. MW-scale generation is what overloads MV lines now;
## household districts alone barely register.
func _smoke_overload() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_power_healthy(180.0):
		_fail("SMOKE_OVERLOAD", "power health timeout")
		return
	City.model = WorldModel.new()
	City.money = 100_000_000
	City.weather = WeatherSystem.new(42)
	City.outage_minutes = {}
	City.place_building("grid_connection", Vector2i(10, 10))
	# feeder A (east) -> sub1, light
	for x in range(12, 18):
		City.build_cable(Vector2i(x, 10))
	City.place_building("substation", Vector2i(18, 10))
	for x in range(14, 26):
		City.build_road(Vector2i(x, 8))
	for x in range(14, 26):
		City.build_zone(Vector2i(x, 7))
	# feeder B (south, then east) -> sub2 + sub3 + the wind park at the end
	for y in range(12, 16):
		City.build_cable(Vector2i(10, y))
	for x in range(11, 35):
		City.build_cable(Vector2i(x, 15))
	City.place_building("substation", Vector2i(20, 16))  # touches (20,15)
	City.place_building("substation", Vector2i(30, 16))  # touches (30,15)
	City.place_building("wind_farm", Vector2i(32, 13))   # touches (32,15)
	City.place_building("wind_farm", Vector2i(33, 16))   # touches (33,15)
	for x in range(12, 34):
		City.build_road(Vector2i(x, 19))
		City.build_road(Vector2i(x, 22))
	for x in range(12, 34):
		for y in [20, 21, 23]:  # every zoned row is road-adjacent
			City.build_zone(Vector2i(x, y))
	var subs := City.model.buildings_of_kind("substation")
	# heavy district spawns FIRST so sub1 cannot eat its candidate tiles
	var spawned := [City.spawn_houses_bulk(subs[1], 60),
		City.spawn_houses_bulk(subs[2], 60), City.spawn_houses_bulk(subs[0], 20)]
	# full wind across the whole run: both farms at rated output
	City.weather.force_wind(0, 100_000, 14.0)
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
