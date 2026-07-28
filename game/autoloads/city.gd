extends Node
## City — the game brain (Phase 3). Owns the world model + city state, is the
## Orchestrator's BoundaryProvider (demand/dispatch/weather), applies step
## results as consequences (outages, happiness, growth, protection trips), and
## keeps the solver topology in sync with the model (reset only when the
## extracted doc actually changed — house growth changes demand, not topology).

signal state_changed          # money/happiness/HUD refresh
signal world_changed          # tiles changed -> views redraw
signal event_logged(event: Dictionary)
signal power_result(t: int, result: Dictionary)

const START_MONEY := 500_000
const GROWTH_HAPPINESS_MIN := 60.0
const TRIP_STREAK := 3            # consecutive critical overloads before a line trips
const GRID_TRIP_STREAK := 2       # consecutive capacity busts before the slack trips
const REPAIR_STEPS := 8           # 2 in-game hours
const TOPO_DEBOUNCE_S := 0.6

var model := WorldModel.new()
var weather := WeatherSystem.new(42)
var money := START_MONEY
var happiness := 100.0
var outage_minutes := {}          # zone_id -> minutes
var events: Array[Dictionary] = []

var topo: PowerTopology = PowerTopology.new()
var tripped_tiles := {}           # Vector2i -> repair_at (sim-step)
var grid_trip_until := -1
var zone_supplied := {}           # zone_id -> bool (latest step)
var last_result := {}
var current_t := 0

## Scenario hook: overrides the grid connection's capacity_kw when > 0.
var grid_capacity_override := -1.0

var _line_streak := {}
var _slack_streak := 0
var _topo_dirty := true
var _topo_timer := 0.0
var _last_doc_json := ""
var _syncing := false
var registered := false


func _ready() -> void:
	# City IS the boundary provider for the real game (fixture-driven smokes
	# overwrite this after boot)
	Orchestrator.boundary_provider = self
	Orchestrator.step_completed.connect(_on_step_completed)
	GameClock.sim_step.connect(func(t: int) -> void: current_t = t)


func _process(delta: float) -> void:
	if not _topo_dirty or _syncing:
		return
	_topo_timer += delta
	if _topo_timer >= TOPO_DEBOUNCE_S:
		_topo_timer = 0.0
		_sync_topology()


# ─── build API (UI tools call these; costs + occupancy enforced) ───

func build_road(pos: Vector2i) -> bool:
	return _paid(BuildingDefs.COSTS["road"]) and model.set_road(pos) \
		and _after_build(false)


func build_zone(pos: Vector2i) -> bool:
	return _paid(BuildingDefs.COSTS["zone"]) and model.set_zone(pos) \
		and _after_build(false)


func build_cable(pos: Vector2i) -> bool:
	return _paid(BuildingDefs.COSTS["cable"]) and model.set_cable(pos, 1) \
		and _after_build(true)


func place_building(kind: String, anchor: Vector2i) -> bool:
	var def := BuildingDefs.get_def(kind)
	if def.is_empty() or not model.can_place_building(kind, anchor):
		return false
	if not _paid(def["cost"]):
		return false
	model.place_building(kind, anchor)
	log_event("built", "info", "%s built" % kind)
	return _after_build(true)


func bulldoze(pos: Vector2i) -> bool:
	if model.building_tiles.has(pos):
		var id: String = model.building_tiles[pos]
		var def := BuildingDefs.get_def(model.buildings[id]["kind"])
		model.remove_building(id)
		money += int(def["cost"] * 0.25)
		return _after_build(true)
	if model.cables.has(pos):
		model.remove_cable(pos)
		tripped_tiles.erase(pos)
		return _after_build(true)
	if model.houses.has(pos):
		model.remove_house(pos)
		return _after_build(false)
	if model.roads.has(pos):
		model.remove_road(pos)
		return _after_build(false)
	if model.zoning.has(pos):
		model.remove_zone(pos)
		return _after_build(false)
	return false


func _paid(cost: int) -> bool:
	if money < cost:
		return false
	money -= cost
	return true


func _after_build(topology_relevant: bool) -> bool:
	if topology_relevant:
		_topo_dirty = true
	else:
		_refresh_topo_assignment()
	world_changed.emit()
	state_changed.emit()
	return true


# ─── topology sync (model -> solver; reset only on real change) ───

func _refresh_topo_assignment() -> void:
	# houses/zones changed but the electrical doc did not: re-extract locally
	# for zone assignment + house counts, skip the backend reset
	topo = PowerTopology.build(model, tripped_tiles)


func _sync_topology() -> void:
	_topo_dirty = false
	topo = PowerTopology.build(model, tripped_tiles)
	if not topo.has_slack or topo.doc.is_empty():
		registered = false
		_last_doc_json = ""
		return
	var doc_json := JSON.stringify(topo.doc)
	if doc_json == _last_doc_json and registered:
		return
	if SidecarManager.state_of("power") != SidecarManager.State.HEALTHY:
		_topo_dirty = true  # retry once the backend is back
		return
	_syncing = true
	_register_async(doc_json)


func _register_async(doc_json: String) -> void:
	if not CosimBridge.info.has("power"):
		if not await CosimBridge.handshake("power"):
			_syncing = false
			_topo_dirty = true
			return
	var ok: bool = await Orchestrator.register("power", topo.doc)
	registered = ok
	if ok:
		_last_doc_json = doc_json
		Orchestrator.start()
	_syncing = false


# ─── BoundaryProvider (duck-typed, see Orchestrator) ───

func get_zone_demand(_network: String, t: int) -> Dictionary:
	var out := {}
	for zone_id: String in topo.zones_info:
		out[zone_id] = {"value": DemandModel.zone_demand_kw(
			topo.zones_info[zone_id]["houses"], t)}
	return out


func get_device_setpoints(_network: String, t: int) -> Dictionary:
	var sample := weather.sample(t)
	var total_demand := 0.0
	for zone_id: String in topo.zones_info:
		total_demand += DemandModel.zone_demand_kw(topo.zones_info[zone_id]["houses"], t)
	var out := {}
	var renewable := 0.0
	for device: Dictionary in topo.doc.get("devices", []):
		var params: Dictionary = device.get("params", {})
		match device["kind"]:
			"wind":
				var p: float = params["p_rated_kw"] * WeatherSystem.wind_availability(sample["wind_ms"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				renewable += p
			"pv":
				var p: float = params["p_rated_kw"] * WeatherSystem.pv_availability(sample["ghi_wm2"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				renewable += p
	var residual := total_demand - renewable
	for device: Dictionary in topo.doc.get("devices", []):
		match device["kind"]:
			"generator":
				var p: float = clampf(residual, 0.0, device["params"]["p_max_kw"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				residual -= p
			"battery":
				# discharge into deficit, charge on surplus; backend clamps SoC
				var p_max: float = device["params"]["p_max_kw"]
				out[device["id"]] = {"p_kw": snappedf(clampf(residual, -p_max, p_max), 0.1)}
				residual -= clampf(residual, -p_max, p_max)
	return out


func get_weather(t: int) -> Dictionary:
	return weather.sample(t)


# ─── consequences (ROADMAP Phase 3 task 6) ───

func _on_step_completed(network: String, t: int, result: Dictionary) -> void:
	if network != "power":
		return
	last_result = result
	_apply_repairs(t)
	var grid_tripped := grid_trip_until > t
	var failed: bool = result.get("status", "failed") == "failed"

	var unsupplied_houses := 0
	var total_houses := 0
	zone_supplied.clear()
	for zone_id: String in topo.zones_info:
		var houses: int = topo.zones_info[zone_id]["houses"]
		total_houses += houses
		var zone_result: Dictionary = result.get("zones", {}).get(zone_id, {})
		var supplied: bool = (
			not grid_tripped and not failed
			and not zone_result.is_empty()
			and float(zone_result.get("supplied", 0.0)) >= 0.99
			and float(zone_result.get("detail", {}).get("v_pu", 0.0)) >= 0.90
			and float(zone_result.get("detail", {}).get("v_pu", 2.0)) <= 1.10
		)
		zone_supplied[zone_id] = supplied
		if not supplied and houses > 0:
			outage_minutes[zone_id] = outage_minutes.get(zone_id, 0) + GameClock.SIM_STEP_MINUTES
			unsupplied_houses += houses

	# happiness: outages hurt fast, recovery is slow (memory arrives Phase 6)
	if total_houses > 0:
		var hurt := float(unsupplied_houses) / total_houses
		happiness = clampf(happiness - 6.0 * hurt + (0.25 if hurt == 0.0 else 0.0), 0.0, 100.0)

	_check_protection(t, result)
	_grow(t)
	state_changed.emit()
	power_result.emit(t, result)


func _check_protection(t: int, result: Dictionary) -> void:
	# line trips: sustained critical overload (contract 1.1 edges)
	for edge_id: String in result.get("edges", {}):
		var loading := float(result["edges"][edge_id].get("loading_percent", 0.0))
		if loading > 120.0:
			_line_streak[edge_id] = _line_streak.get(edge_id, 0) + 1
			if _line_streak[edge_id] >= TRIP_STREAK and topo.line_tiles.has(edge_id):
				for tile: Vector2i in topo.line_tiles[edge_id]:
					tripped_tiles[tile] = t + REPAIR_STEPS
				_line_streak.erase(edge_id)
				_topo_dirty = true
				log_event("line_trip", "critical",
					"Cable overloaded (%.0f%%) — protection tripped" % loading)
		else:
			_line_streak.erase(edge_id)
	# grid connection capacity (game-side protection on the slack)
	var slack_ids := model.buildings_of_kind("grid_connection")
	if not slack_ids.is_empty():
		var capacity: float = grid_capacity_override if grid_capacity_override > 0.0 \
			else BuildingDefs.get_def("grid_connection")["capacity_kw"]
		var import_kw := float(result.get("devices", {}).get(slack_ids[0], {}).get("output_kw", 0.0))
		if import_kw > capacity:
			_slack_streak += 1
			if _slack_streak >= GRID_TRIP_STREAK and grid_trip_until <= t:
				grid_trip_until = t + REPAIR_STEPS
				_slack_streak = 0
				log_event("grid_trip", "critical",
					"Grid connection overloaded (%.0f kW > %.0f kW) — city-wide outage"
					% [import_kw, capacity])
		else:
			_slack_streak = 0


func _apply_repairs(t: int) -> void:
	var repaired := false
	for tile: Vector2i in tripped_tiles.keys():
		if tripped_tiles[tile] <= t:
			tripped_tiles.erase(tile)
			repaired = true
	if repaired:
		_topo_dirty = true
		log_event("repair", "info", "Cable repaired — line back in service")
		world_changed.emit()


func _grow(t: int) -> void:
	if happiness < GROWTH_HAPPINESS_MIN or t % 4 != 0:
		return
	var capacity: int = BuildingDefs.get_def("substation")["house_capacity"]
	var radius: int = BuildingDefs.get_def("substation")["zone_radius"]
	for zone_id: String in topo.zones_info:
		var info: Dictionary = topo.zones_info[zone_id]
		if not zone_supplied.get(zone_id, false) or info["houses"] >= capacity:
			continue
		var candidates := model.spawn_candidates(info["center"], radius)
		if not candidates.is_empty():
			model.spawn_house(candidates[0])
			_refresh_topo_assignment()
			world_changed.emit()
			return  # one house per growth tick, city-wide


## Bulk helper for scenarios/tests: spawn n houses around a substation.
func spawn_houses_bulk(sub_id: String, n: int) -> int:
	var center: Vector2i = model.buildings[sub_id]["anchor"]
	var radius: int = BuildingDefs.get_def("substation")["zone_radius"]
	var spawned := 0
	while spawned < n:
		var candidates := model.spawn_candidates(center, radius)
		if candidates.is_empty():
			break
		model.spawn_house(candidates[0])
		spawned += 1
	_refresh_topo_assignment()
	return spawned


func log_event(kind: String, severity: String, text: String) -> void:
	var event := {"t": current_t, "kind": kind, "severity": severity, "text": text}
	events.append(event)
	if events.size() > 200:
		events.pop_front()
	event_logged.emit(event)


func total_outage_minutes() -> int:
	var total := 0
	for zone_id: String in outage_minutes:
		total += outage_minutes[zone_id]
	return total


# ─── persistence ───

func serialize() -> Dictionary:
	return {
		"money": money, "happiness": happiness,
		"outage_minutes": outage_minutes.duplicate(),
		"weather_seed": weather.seed_value,
	}


func restore(data: Dictionary) -> void:
	money = int(data.get("money", START_MONEY))
	happiness = float(data.get("happiness", 100.0))
	outage_minutes = data.get("outage_minutes", {})
	weather = WeatherSystem.new(int(data.get("weather_seed", 42)))
	tripped_tiles.clear()
	grid_trip_until = -1
	_topo_dirty = true
	state_changed.emit()
	world_changed.emit()
