class_name SmokeBase
extends Node
## Shared plumbing for the acceptance smokes (Phase-3 refactor plan):
## health/registration waits, the clocked step-window runner, reference
## towns, and result readers. Each smoke lives in res://smokes/<name>.gd
## as `func run()` over this base; main.gd only dispatches. Smokes print
## one machine-readable JSON line and quit 0/1 — that CLI contract is
## frozen (CI + tests/e2e wrappers grep it).


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

func _wait_heat_registered(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not City.heat_registered:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true

func _wait_water_registered(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not City.water_registered:
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().create_timer(0.5).timeout
	return true

func _wait_three_registered(timeout_s: float) -> bool:
	return await _wait_registered(timeout_s) \
		and await _wait_heat_registered(60.0) \
		and await _wait_water_registered(60.0)

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

func _fail(tag: String, reason: String) -> void:
	print(tag, " ", JSON.stringify({"ok": false, "reason": reason}))
	SidecarManager.stop_all()
	get_tree().quit(1)

func _heat_zone_t(zone_id: String) -> float:
	return float(City.last_heat_result.get("zones", {}).get(zone_id, {})
		.get("detail", {}).get("t_supply_c", 0.0))

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

static func _econ_delta(now: Dictionary, then: Dictionary) -> Dictionary:
	var out := {}
	for key: String in now:
		var d: float = now[key] - float(then.get(key, 0.0))
		if absf(d) > 0.005:
			out[key] = snappedf(d, 0.01)
	return out


## Dev-tree file path for balancing/diagnostic CSV outputs. These smokes
## are dev-only: the res://../ layout only exists in a checkout, never in
## an exported build (Godot has no "standalone" tag — CLAUDE.md §6);
## INFRA_OUT_DIR overrides for CI or sandboxed runs.
static func _repo_file(rel: String) -> String:
	var out_dir := OS.get_environment("INFRA_OUT_DIR")
	if out_dir != "":
		return out_dir.path_join(rel.get_file())
	return ProjectSettings.globalize_path("res://") + "../" + rel


# ─── opt-in per-assertion reporting (Phase-3): named checks instead of
# one anonymous ANDed boolean — failures become attributable from the
# JSON line alone. New/updated smokes should prefer this. ───

var _checks := {}


func check(check_name: String, passed: bool) -> bool:
	_checks[check_name] = passed
	return passed


func failed_checks() -> Array:
	var failed: Array = []
	for check_name: String in _checks:
		if not _checks[check_name]:
			failed.append(check_name)
	return failed


func verdict() -> bool:
	return failed_checks().is_empty()

