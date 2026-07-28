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
	if _bench:
		cam.position = terrain_layer.map_to_local(_bench_cursor)
		return

	match smoke:
		"sidecars":
			_smoke_sidecars()
		"resilience":
			_smoke_resilience()
		"saveload":
			_smoke_saveload()
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
		var handshake_ok: bool = await CosimBridge.handshake(id)
		var frame := await CosimBridge.step(id)  # first step pays the numba JIT
		var stepped: bool = frame.get("_status", 0) == 200 and frame.get("converged", false)
		per_sidecar[id] = {
			"handshake": handshake_ok,
			"step_converged": stepped,
			"solver": CosimBridge.info.get(id, {}).get("solver", "?"),
		}
		ok = ok and handshake_ok and stepped
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
