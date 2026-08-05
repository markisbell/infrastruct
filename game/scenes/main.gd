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
		elif arg.begins_with("--hour="):
			_screenshot_hour = float(arg.trim_prefix("--hour="))
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
	if SMOKES.has(smoke):
		_run_smoke(smoke)
	else:
		_boot_game()  # incl. smoke == "" — any unknown name boots the game


# ─── acceptance smokes: one file per smoke over SmokeBase (Phase-3
# refactor plan); the CLI (--smoke=<name>, one JSON line, exit 0/1) is
# frozen — CI and the tests/e2e wrappers depend on it ───

const SMOKES := {
	"sidecars": "res://smokes/sidecars.gd",
	"resilience": "res://smokes/resilience.gd",
	"saveload": "res://smokes/saveload.gd",
	"cosim": "res://smokes/cosim.gd",
	"cosim-kill": "res://smokes/cosim.gd",
	"windless-week": "res://smokes/windless_week.gd",
	"overload": "res://smokes/overload.gd",
	"stress": "res://smokes/stress.gd",
	"coldsnap": "res://smokes/coldsnap.gd",
	"heatstorage": "res://smokes/heatstorage.gd",
	"pumpblackout": "res://smokes/pumpblackout.gd",
	"drought": "res://smokes/drought.gd",
	"towerheight": "res://smokes/towerheight.gd",
	"hilltower": "res://smokes/hilltower.gd",
	"yearcurves": "res://smokes/yearcurves.gd",
	"citylife": "res://smokes/citylife.gd",
	"economy": "res://smokes/economy.gd",
	"events": "res://smokes/events.gd",
	"scenarios": "res://smokes/scenarios.gd",
	"maintenance": "res://smokes/maintenance.gd",
	"playtest": "res://smokes/playtest.gd",
	"boosterblackout": "res://smokes/boosterblackout.gd",
	"savemidevent": "res://smokes/savemidevent.gd",
	"region": "res://smokes/region.gd",
	"buriedoverload": "res://smokes/buriedoverload.gd",
	"island": "res://smokes/island.gd",
}


func _run_smoke(name: String) -> void:
	var runner: SmokeBase = (load(SMOKES[name]) as GDScript).new()
	# set() is a silent no-op for smokes that don't declare the property
	runner.set("kill_mode", name == "cosim-kill")
	runner.set("playtest_seed", _playtest_seed)
	add_child(runner)
	runner.run()


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
	# default 13:00 — the day/night cycle would render Day 0 00:00 as night;
	# --hour=N picks another time (dusk/night verification shots)
	GameClock.restore({"total_minutes": _screenshot_hour * 60.0, "speed": 0.0})
	City.money = 100_000_000
	if OS.get_environment("REGION_SHOT") != "":  # terrain-look probe (kept)
		City.model.terrain.set_seed(19)
		City.model.terrain.load_region(OS.get_environment("REGION_SHOT"))
		view.redraw()
		view.focus_tile(Vector2i(128, 128), 90.0)
		await get_tree().create_timer(1.5).timeout
		get_viewport().get_texture().get_image().save_png(_screenshot_path)
		print("SCREENSHOT saved to ", _screenshot_path)
		get_tree().quit(0)
		return
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
	# three single turbines lined along the cable column (each 1x1 turbine
	# needs its OWN adjacency since the 2x2 farm split)
	City.place_building("wind_farm", Vector2i(125, 117))
	City.place_building("wind_farm", Vector2i(125, 118))
	City.place_building("wind_farm", Vector2i(125, 119))
	for y in range(117, 121):  # reaches (126,117), adjacent to the turbines —
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
	City.place_building("wind_farm", Vector2i(149, 118))  # one lone turbine, disconnected on purpose
	for x in range(147, 153):
		City.build_road(Vector2i(x, 126))
	for x in range(147, 153):
		City.build_zone(Vector2i(x, 127))
	City.model.spawn_house(Vector2i(148, 127))
	City.model.spawn_house(Vector2i(151, 127))
	City._refresh_topo_assignment()
	# camera BEFORE the inspector demo: the panel anchors to the clicked
	# element through the live camera at click time
	view.focus_tile(Vector2i(133, 125), 24.0)
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
	if not view._clouds.is_empty():  # drift one cloud over town for the shot
		view._clouds[0].position = Vector3(126.0, 13.0, 128.0)
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


var _playtest_seed := 20260730  # override with --seed=N for fuzz sweeps
var _screenshot_hour := 13.0    # override with --hour=N (day/night shots)


