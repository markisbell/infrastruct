extends Node2D
## Spike A: isometric drag-build prototype (ROADMAP Phase 0).
## - 256×256 isometric terrain TileMapLayer
## - drag-build cable tool: left-drag paints, right-drag erases
## - logical model (WorldModel) is the source of truth; the network
##   TileMapLayer is rebuilt/updated as a view of it
## - F5 saves the model to user://world.json, F6 loads it back
## - `--bench --out=<path>` runs an automated drag benchmark, writes a JSON
##   report (frame times, save/load round-trip check) and quits.

const MAP_SIZE := 256
const TILE_W := 64
const TILE_H := 32

const TILE_GRASS := Vector2i(0, 0)
const TILE_CABLE := Vector2i(1, 0)
const CABLE_KIND_DEFAULT := 1

var model := WorldModel.new()
var terrain_layer: TileMapLayer
var network_layer: TileMapLayer
var cam: Camera2D

var _painting := false
var _erasing := false

# bench state
var _bench := false
var _bench_out := ""
var _bench_warmup_frames := 30
var _bench_paint_frames := 300
var _bench_tiles_per_frame := 5
var _bench_cursor := Vector2i(64, 64)
var _bench_dir := Vector2i(1, 0)
var _frame_times: Array[float] = []


func _ready() -> void:
	var tile_set := _make_tileset()
	terrain_layer = TileMapLayer.new()
	terrain_layer.tile_set = tile_set
	add_child(terrain_layer)
	network_layer = TileMapLayer.new()
	network_layer.tile_set = tile_set
	add_child(network_layer)

	for x in MAP_SIZE:
		for y in MAP_SIZE:
			terrain_layer.set_cell(Vector2i(x, y), 0, TILE_GRASS)

	cam = Camera2D.new()
	add_child(cam)
	cam.position = terrain_layer.map_to_local(Vector2i(MAP_SIZE / 2, MAP_SIZE / 2))
	cam.make_current()

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
	if _bench:
		cam.position = terrain_layer.map_to_local(_bench_cursor)
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
		_:
			# normal game run: supervise the backends + debug panel
			if SidecarManager.load_config():
				SidecarManager.start_all()
				SidecarManager.state_changed.connect(_on_sidecar_state)
				_add_debug_panel()


func _make_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = Vector2i(TILE_W, TILE_H)
	var src := TileSetAtlasSource.new()
	src.texture = _make_texture()
	src.texture_region_size = Vector2i(TILE_W, TILE_H)
	src.create_tile(TILE_GRASS)
	src.create_tile(TILE_CABLE)
	ts.add_source(src, 0)
	return ts


## Procedurally drawn diamond tiles — no binary assets needed for the spike.
## Atlas: [0]=grass green, [1]=cable yellow.
func _make_texture() -> ImageTexture:
	var colors := [Color(0.33, 0.55, 0.28), Color(0.95, 0.78, 0.15)]
	var img := Image.create(TILE_W * colors.size(), TILE_H, false, Image.FORMAT_RGBA8)
	for t in colors.size():
		var col: Color = colors[t]
		var edge := col.darkened(0.35)
		var half_h := TILE_H / 2.0
		for y in TILE_H:
			var frac := 1.0 - absf(y - half_h + 0.5) / half_h
			var half_w := int(frac * TILE_W / 2.0)
			for x in range(TILE_W / 2 - half_w, TILE_W / 2 + half_w):
				var border := x <= TILE_W / 2 - half_w + 1 or x >= TILE_W / 2 + half_w - 2
				img.set_pixel(t * TILE_W + x, y, edge if border else col)
	return ImageTexture.create_from_image(img)


# ─── model <-> view ───

func _paint_cable(pos: Vector2i) -> void:
	if pos.x < 0 or pos.y < 0 or pos.x >= MAP_SIZE or pos.y >= MAP_SIZE:
		return
	model.set_cable(pos, CABLE_KIND_DEFAULT)
	network_layer.set_cell(pos, 0, TILE_CABLE)


func _erase_cable(pos: Vector2i) -> void:
	model.remove_cable(pos)
	network_layer.erase_cell(pos)


func _rebuild_network_view() -> void:
	network_layer.clear()
	for pos: Vector2i in model.cables:
		network_layer.set_cell(pos, 0, TILE_CABLE)


# ─── input ───

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_painting = mb.pressed
				if mb.pressed:
					_paint_cable(_mouse_tile())
			MOUSE_BUTTON_RIGHT:
				_erasing = mb.pressed
				if mb.pressed:
					_erase_cable(_mouse_tile())
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					cam.zoom = (cam.zoom * 1.1).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					cam.zoom = (cam.zoom / 1.1).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _painting:
			_paint_cable(_mouse_tile())
		elif _erasing:
			_erase_cable(_mouse_tile())
		elif mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			cam.position -= mm.relative / cam.zoom
	elif event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		match key.keycode:
			KEY_F5:
				_save_to(_save_path())
			KEY_F6:
				_load_from(_save_path())
			KEY_F1:
				if _debug_panel:
					_debug_panel.visible = not _debug_panel.visible
			KEY_F2:
				# debug console: dump the latest contract results per network
				var dump := {}
				for id: String in Orchestrator.networks:
					dump[id] = Orchestrator.latest(id)
				var f := FileAccess.open("user://debug_dump.json", FileAccess.WRITE)
				f.store_string(JSON.stringify(dump, "  "))
				f.close()
				print("debug: results dumped to user://debug_dump.json")
			KEY_F3:
				# debug console: force one sim-step while paused
				GameClock.total_minutes += GameClock.SIM_STEP_MINUTES
				var forced := int(GameClock.total_minutes / GameClock.SIM_STEP_MINUTES)
				Orchestrator._on_sim_step(forced)
				print("debug: forced sim-step ", forced)
			KEY_F4:
				# debug console: toggle a cold-snap weather override
				if Orchestrator.boundary_provider is FixtureProvider:
					var provider: FixtureProvider = Orchestrator.boundary_provider
					if provider.weather_override.is_empty():
						provider.weather_override = {"temp_c": -12.0, "wind_ms": 1.0}
					else:
						provider.weather_override = {}
					print("debug: weather override = ", provider.weather_override)


func _mouse_tile() -> Vector2i:
	return network_layer.local_to_map(network_layer.get_local_mouse_position())


func _process(delta: float) -> void:
	var pan := Vector2(
		Input.get_axis(&"ui_left", &"ui_right"), Input.get_axis(&"ui_up", &"ui_down")
	)
	cam.position += pan * 600.0 * delta / cam.zoom.x
	if _bench:
		_bench_tick(delta)


# ─── save/load (SaveGame autoload: model + clock, versioned envelope) ───

func _save_path() -> String:
	return SaveGame.DEFAULT_PATH


func _save_to(path: String) -> void:
	SaveGame.save_to(path, model)


func _load_from(path: String) -> void:
	var loaded: Dictionary = SaveGame.load_from(path)
	if loaded["ok"]:
		model = loaded["model"]
		_rebuild_network_view()


# ─── screenshot mode (pre-alpha look, no sidecars) ───

var _screenshot_path := ""


func _take_screenshot() -> void:
	# paint a small demo network so the shot shows content
	for i in 42:
		_paint_cable(Vector2i(118 + i, 128))
	for i in 26:
		_paint_cable(Vector2i(138, 110 + i))
	for i in 18:
		_paint_cable(Vector2i(150 + i, 118))
	cam.position = terrain_layer.map_to_local(Vector2i(140, 124))
	cam.zoom = Vector2(1.4, 1.4)
	await get_tree().create_timer(1.0).timeout  # let a few frames render
	var img := get_viewport().get_texture().get_image()
	img.save_png(_screenshot_path)
	print("SCREENSHOT saved to ", _screenshot_path)
	get_tree().quit(0)


# ─── sidecar supervision UI ───

var _debug_panel: PanelContainer


func _add_debug_panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_debug_panel = preload("res://scenes/debug_panel.gd").new()
	_debug_panel.position = Vector2(8, 8)
	layer.add_child(_debug_panel)


func _on_sidecar_state(id: String, state: SidecarManager.State) -> void:
	if state == SidecarManager.State.HEALTHY and not CosimBridge.info.has(id):
		CosimBridge.handshake(id)


# ─── Phase 1 acceptance smoke modes (headless, print one JSON line, quit) ───

func _wait_all_healthy(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not SidecarManager.all_healthy():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true


func _smoke_sidecars() -> void:
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		print("SMOKE_SIDECARS ", JSON.stringify({"ok": false, "reason": "health timeout"}))
		SidecarManager.stop_all()
		get_tree().quit(1)
		return
	var ok := true
	var per_sidecar := {}
	for id: String in SidecarManager.ids():
		# spawn + health + handshake only — contract stepping (which requires a
		# /gb/net/reset first) is covered end-to-end by --smoke=cosim
		var handshake_ok: bool = await CosimBridge.handshake(id)
		per_sidecar[id] = {
			"handshake": handshake_ok,
			"solver": CosimBridge.info.get(id, {}).get("solver", "?"),
		}
		ok = ok and handshake_ok
	print("SMOKE_SIDECARS ", JSON.stringify({"ok": ok, "sidecars": per_sidecar}))
	SidecarManager.stop_all()
	get_tree().quit(0 if ok else 1)


func _smoke_resilience() -> void:
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		print("SMOKE_RESILIENCE ", JSON.stringify({"ok": false, "reason": "initial health timeout"}))
		SidecarManager.stop_all()
		get_tree().quit(1)
		return
	# hand the harness what it needs to kill a backend process externally
	print("SMOKE_READY ", JSON.stringify({"ports": SidecarManager.ids().map(
		func(id: String) -> int: return SidecarManager.port_of(id))}))
	# the harness now kills the port owner; we must observe DOWN/RESTARTING…
	var saw_down := false
	var deadline := Time.get_ticks_msec() + 120_000
	while Time.get_ticks_msec() < deadline:
		for id: String in SidecarManager.ids():
			var state: SidecarManager.State = SidecarManager.state_of(id)
			if state == SidecarManager.State.DOWN or state == SidecarManager.State.RESTARTING:
				saw_down = true
		if saw_down:
			break
		await get_tree().create_timer(0.5).timeout
	# …and the automatic recovery back to all-healthy, without crashing
	var recovered := saw_down and await _wait_all_healthy(180.0)
	print("SMOKE_RESILIENCE ", JSON.stringify({"ok": recovered, "saw_down": saw_down}))
	SidecarManager.stop_all()
	get_tree().quit(0 if recovered else 1)


## Phase 2 acceptance e2e (ROADMAP): boot with the fixture town, run a full
## in-game day (96 sim-steps) against BOTH real backends, assert: no missed
## steps (=> one-step lag held), statuses within the fixture's allowance,
## golden ranges on the final results, coupling routed heat->power.
## kill_mode: the harness kills the heat backend mid-run; assert disturbance
## event + reset-recovery + post-recovery stepping, power unaffected.
func _smoke_cosim(kill_mode: bool) -> void:
	var provider := FixtureProvider.load_default(SidecarManager.repo_root)
	if provider.fixtures.size() < 2:
		print("SMOKE_COSIM ", JSON.stringify(
			{"ok": false, "reason": "fixtures missing (need power+heat)"}))
		get_tree().quit(1)
		return
	SidecarManager.load_config()
	SidecarManager.start_all()
	if not await _wait_all_healthy(180.0):
		print("SMOKE_COSIM ", JSON.stringify({"ok": false, "reason": "health timeout"}))
		SidecarManager.stop_all()
		get_tree().quit(1)
		return

	Orchestrator.boundary_provider = provider
	var events: Array[Dictionary] = []
	Orchestrator.supply_event.connect(
		func(network: String, kind: String, severity: String, data: Dictionary) -> void:
			events.append({"network": network, "kind": kind, "severity": severity,
				"t": data.get("t", -1)}))
	var n_steps := provider.steps("power")
	var seen := {"power": [], "heat": []}  # per-network list of completed t (order check)
	var statuses := {"power": {}, "heat": {}}
	var final_results := {}  # network -> result at t == n_steps-1 (golden basis)
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
		if not handshake_ok:
			print("register diag: handshake failed for ", id, ": ",
				JSON.stringify(CosimBridge.info.get(id, {})))
		var reset_ok := handshake_ok and await Orchestrator.register(id, provider.topology(id))
		registered = registered and reset_ok
	if not registered:
		print("SMOKE_COSIM ", JSON.stringify({"ok": false, "reason": "register failed"}))
		SidecarManager.stop_all()
		get_tree().quit(1)
		return

	GameClock.restore({"total_minutes": 0.0, "speed": 0.0})
	Orchestrator.start()
	if kill_mode:
		print("SMOKE_READY ", JSON.stringify({"ports": [8010, 8011]}))
	# kill mode runs slower so the backend can restart inside the window
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
	# drain any in-flight request without dispatching further steps
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
		report[id] = {
			"completed": ts.size(), "missed": Orchestrator.networks[id]["missed"],
			"monotonic": monotonic, "statuses": statuses[id],
			"bad_status_steps": bad_status, "golden_fails": golden_fails,
		}
		if kill_mode and id == "heat":
			var down := events.any(func(e: Dictionary) -> bool:
				return e.kind == "backend_down" and e.network == "heat")
			var recovered := events.any(func(e: Dictionary) -> bool:
				return e.kind == "backend_recovered" and e.network == "heat")
			var resumed: bool = not ts.is_empty() \
				and ts.back() > (ts[0] + ts.size())  # stepped again after a gap
			report["heat"]["down_event"] = down
			report["heat"]["recovered_event"] = recovered
			report["heat"]["resumed_after_gap"] = resumed
			report["ok"] = report["ok"] and down and recovered and resumed and monotonic
		else:
			report["ok"] = report["ok"] and ts.size() >= n_steps \
				and Orchestrator.networks[id]["missed"] == 0 and monotonic \
				and bad_status == 0 and golden_fails.is_empty()
	if kill_mode:
		# power must have sailed through the heat outage untouched
		report["ok"] = report["ok"] and report["power"]["completed"] >= n_steps - 2 \
			and report["power"]["bad_status_steps"] == 0
	var tag := "SMOKE_COSIM_KILL " if kill_mode else "SMOKE_COSIM "
	print(tag, JSON.stringify(report))
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


func _smoke_saveload() -> void:
	model.set_cable(Vector2i(10, 20), 1)
	model.set_cable(Vector2i(-3, 7), 2)
	GameClock.total_minutes = 3 * 1440.0 + 125.0  # day 3, 02:05
	GameClock.speed = 3.0
	var path := "user://smoke_save.json"
	var save_err := SaveGame.save_to(path, model)
	model = WorldModel.new()  # wipe state
	GameClock.restore({"total_minutes": 0.0, "speed": 1.0})
	var loaded: Dictionary = SaveGame.load_from(path)
	var restored: WorldModel = loaded.get("model")
	var ok: bool = (
		save_err == OK and loaded["ok"]
		and restored.cables.size() == 2
		and restored.cables[Vector2i(-3, 7)] == 2
		and GameClock.day() == 3
		and GameClock.time_of_day_string() == "02:05"
		and is_equal_approx(GameClock.speed, 3.0)
	)
	print("SMOKE_SAVELOAD ", JSON.stringify({"ok": ok}))
	get_tree().quit(0 if ok else 1)


# ─── benchmark mode ───

func _bench_tick(delta: float) -> void:
	if _bench_warmup_frames > 0:
		_bench_warmup_frames -= 1
		return
	if _frame_times.size() < _bench_paint_frames:
		# simulate a fast drag: paint N tiles per frame in a snake pattern
		for i in _bench_tiles_per_frame:
			_paint_cable(_bench_cursor)
			_bench_cursor += _bench_dir
			if _bench_cursor.x >= 192:
				_bench_dir = Vector2i(-1, 0)
				_bench_cursor += Vector2i(0, 1)
			elif _bench_cursor.x <= 64:
				_bench_dir = Vector2i(1, 0)
				_bench_cursor += Vector2i(0, 1)
		cam.position = terrain_layer.map_to_local(_bench_cursor)
		_frame_times.append(delta)
		return
	_bench_finish()


func _bench_finish() -> void:
	var sorted := _frame_times.duplicate()
	sorted.sort()
	var total := 0.0
	for t: float in _frame_times:
		total += t
	var avg := total / _frame_times.size()
	var p50: float = sorted[int(sorted.size() * 0.50)]
	var p99: float = sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)]

	# save/load round-trip check on the freshly painted model
	var restored := WorldModel.from_json(model.to_json())
	var report := {
		"frames": _frame_times.size(),
		"tiles_painted": model.cables.size(),
		"avg_ms": avg * 1000.0,
		"p50_ms": p50 * 1000.0,
		"p99_ms": p99 * 1000.0,
		"worst_ms": sorted[-1] * 1000.0,
		"avg_fps": 1.0 / avg,
		"roundtrip_ok": restored.equals(model),
	}
	var out := _bench_out if not _bench_out.is_empty() else "user://spike_a_report.json"
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("SPIKE_A_REPORT ", JSON.stringify(report))
	get_tree().quit(0 if report.roundtrip_ok else 1)
