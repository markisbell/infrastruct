extends Node
## SidecarManager — spawns and supervises the Python solver backends
## (ROADMAP Phase 1 task 2). Config: orchestration/sidecars.json.
##
## Windows-first (matches the dev machine): processes launch through a cmd.exe
## wrapper (env vars + log redirect — OS.create_process has no env parameter)
## and are terminated as a tree via taskkill. Health = GET /health every
## POLL_INTERVAL_S; a healthy sidecar that stops answering goes DOWN and is
## restarted with capped backoff. Nothing starts automatically — main.gd calls
## start_all() so bench/test runs stay sidecar-free.

signal state_changed(id: String, state: State)

enum State { STOPPED, STARTING, HEALTHY, DOWN, RESTARTING }

const POLL_INTERVAL_S := 2.0
const STARTING_DEADLINE_S := 90.0   # first health OK must arrive within this (cold imports)
const BACKOFF_STEPS_S: Array[float] = [2.0, 5.0, 10.0, 20.0]

var repo_root := ""
var _sidecars := {}  # id -> {cfg, state, pid, http, in_flight, started_at, backoff_i, restart_at}
var _poll_timer: Timer


func _ready() -> void:
	if OS.has_feature("editor"):
		var game_dir := ProjectSettings.globalize_path("res://")
		repo_root = game_dir.rstrip("/").get_base_dir()
	else:
		# exported build (Godot 4 has no "standalone" tag — check for the
		# ABSENCE of "editor"): everything (orchestration/, backends/)
		# sits next to the executable — the installer lays it out that way
		repo_root = OS.get_executable_path().get_base_dir()
	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_S
	_poll_timer.timeout.connect(_poll)
	add_child(_poll_timer)


func load_config(config_rel_path: String = "orchestration/sidecars.json") -> bool:
	var path := repo_root.path_join(config_rel_path)
	if not FileAccess.file_exists(path):
		push_error("SidecarManager: config not found: " + path)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		push_error("SidecarManager: invalid config JSON")
		return false
	for cfg: Dictionary in parsed.get("sidecars", []):
		var http := HTTPRequest.new()
		http.timeout = POLL_INTERVAL_S - 0.2
		add_child(http)
		_sidecars[cfg["id"]] = {
			"cfg": cfg, "state": State.STOPPED, "pid": -1, "http": http,
			"in_flight": false, "started_at": 0.0, "backoff_i": 0, "restart_at": 0.0,
		}
	return not _sidecars.is_empty()


func ids() -> Array:
	return _sidecars.keys()


func state_of(id: String) -> State:
	return _sidecars[id]["state"] if _sidecars.has(id) else State.STOPPED


func port_of(id: String) -> int:
	return int(_sidecars[id]["cfg"]["port"])


func pids() -> Dictionary:
	var out := {}
	for id: String in _sidecars:
		out[id] = _sidecars[id]["pid"]
	return out


func all_healthy() -> bool:
	if _sidecars.is_empty():
		return false
	for id: String in _sidecars:
		if _sidecars[id]["state"] != State.HEALTHY:
			return false
	return true


func start_all() -> void:
	for id: String in _sidecars:
		_start(id)
	_poll_timer.start()


func stop_all() -> void:
	_poll_timer.stop()
	for id: String in _sidecars:
		_kill(id)
		_set_state(id, State.STOPPED)


func _start(id: String) -> void:
	var s: Dictionary = _sidecars[id]
	var cfg: Dictionary = s["cfg"]
	var log_dir := repo_root.path_join("orchestration/logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	var parts: Array[String] = ['cd /d "%s"' % repo_root.path_join(cfg["cwd"])]
	for key: String in cfg.get("env", {}):
		parts.append('set "%s=%s"' % [key, cfg["env"][key]])
	# dev: venv python -m module; installed build: a PyInstaller-frozen exe
	var run := '"%s"' % repo_root.path_join(cfg["exe"]) if cfg.has("exe") \
		else '"%s" -m %s' % [repo_root.path_join(cfg["python"]), cfg["module"]]
	parts.append('%s >> "%s" 2>&1' % [
		run,
		# port in the name: parallel instances (live game + stress run) must
		# never interleave in one file
		log_dir.path_join("%s_%d.log" % [id, port_of(id)]),
	])
	var pid := OS.create_process("cmd.exe", ["/c", " && ".join(parts)])
	s["pid"] = pid
	s["started_at"] = Time.get_ticks_msec() / 1000.0
	_set_state(id, State.STARTING if pid > 0 else State.DOWN)


func _kill(id: String) -> void:
	var pid: int = _sidecars[id]["pid"]
	if pid > 0:
		# /T takes the whole cmd->python tree down; idempotent if already gone
		OS.execute("taskkill", ["/PID", str(pid), "/T", "/F"])
	_sidecars[id]["pid"] = -1


func _set_state(id: String, state: State) -> void:
	if _sidecars[id]["state"] == state:
		return
	_sidecars[id]["state"] = state
	state_changed.emit(id, state)


func _poll() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for id: String in _sidecars:
		var s: Dictionary = _sidecars[id]
		match s["state"]:
			State.STOPPED:
				continue
			State.RESTARTING:
				if now >= s["restart_at"]:
					_start(id)
				continue
			State.STARTING:
				if now - s["started_at"] > STARTING_DEADLINE_S:
					_schedule_restart(id, now)
					continue
			State.DOWN:
				_schedule_restart(id, now)
				continue
		if not s["in_flight"]:
			_check_health(id)


func _schedule_restart(id: String, now: float) -> void:
	var s: Dictionary = _sidecars[id]
	_kill(id)
	var backoff: float = BACKOFF_STEPS_S[mini(s["backoff_i"], BACKOFF_STEPS_S.size() - 1)]
	s["backoff_i"] += 1
	s["restart_at"] = now + backoff
	_set_state(id, State.RESTARTING)


func _check_health(id: String) -> void:
	var s: Dictionary = _sidecars[id]
	var http: HTTPRequest = s["http"]
	var url := "http://127.0.0.1:%d/health" % port_of(id)
	if http.request(url) != OK:
		return
	s["in_flight"] = true
	var result: Array = await http.request_completed
	s["in_flight"] = false
	var ok: bool = result[0] == HTTPRequest.RESULT_SUCCESS and result[1] == 200
	if ok:
		s["backoff_i"] = 0
		_set_state(id, State.HEALTHY)
	elif s["state"] == State.HEALTHY:
		_set_state(id, State.DOWN)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		stop_all()
