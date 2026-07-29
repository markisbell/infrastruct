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
signal heat_result(t: int, result: Dictionary)
signal water_result(t: int, result: Dictionary)

const START_MONEY := 500_000
const GROWTH_HAPPINESS_MIN := 60.0

# ─── economy (Phase 7 task 1; rationale in tools/balancing/economy.md) ───
const TARIFF_ELEC_KWH := 0.35     # income per kWh actually delivered
const TARIFF_HEAT_KWH := 0.16
const TARIFF_WATER_M3 := 3.0
const BASE_FEE_HOUSE_DAY := 0.4   # Grundgebühr per connected household
const FUEL_PRICE_KWH := 0.09      # gas, per kWh fuel
const GRID_IMPORT_KWH := 0.22     # wholesale purchase at the slack
const GRID_FEEDIN_KWH := 0.06     # feed-in revenue for exports
const GAS_PLANT_ETA := 0.40
const CHP_ETA_TOTAL := 0.88
const LOAN_RATE_DAY := 0.0005     # ~18 % p.a., charged daily on the balance
const STEP_H := 0.25              # 15-min step in hours
const TRIP_STREAK := 3            # consecutive critical overloads before a line trips
const GRID_TRIP_STREAK := 2       # consecutive capacity busts before the slack trips
const REPAIR_STEPS := 8           # 2 in-game hours
# Idle-based: the countdown RESTARTS on every build action, so a building
# spree costs ONE reset at the end, not one per click (reset storms froze
# the world in the first playtest).
const TOPO_DEBOUNCE_S := 2.5

var model := WorldModel.new()
var weather := WeatherSystem.new(42)
var money := START_MONEY
var happiness := 100.0
## Happiness v2 (Phase 6): per-network satisfaction 0..100 with MEMORY —
## outages hit fast, trust recovers slowly (~weeks of clean supply for a
## bad blackout). happiness = weighted blend; water weighs heaviest, heat
## by season (a January heat outage is a catastrophe, a July one a shrug).
var satisfaction := {"power": 100.0, "heat": 100.0, "water": 100.0}
var outage_minutes := {}          # zone_id -> minutes
var events: Array[Dictionary] = []

var topo: PowerTopology = PowerTopology.new()
var heat_topo: HeatTopology = HeatTopology.new()
var water_topo: WaterTopology = WaterTopology.new()
var tripped_tiles := {}           # Vector2i -> repair_at (sim-step)
var grid_trip_until := -1
var zone_supplied := {}           # power zone_id -> bool (latest step)
var heat_zone_supplied := {}      # heat zone_id -> bool (latest step)
var heat_outage_minutes := {}     # heat zone_id -> minutes cold
var water_zone_supplied := {}     # water zone_id -> bool (latest step)
var water_outage_minutes := {}    # water zone_id -> minutes dry
var last_result := {}
var last_heat_result := {}
var last_water_result := {}
var current_t := 0
var heat_registered := false
var water_registered := false
var _last_heat_doc_json := ""
var _last_water_doc_json := ""

## Scenario hook: overrides the grid connection's capacity_kw when > 0.
var grid_capacity_override := -1.0
## Scenario hook: freezes growth/abandonment (constant-demand recordings).
var growth_enabled := true

# ─── Phase 7 game layer ───
var event_system := EventSystem.new(42)
## Random events roll only when enabled (sandbox + scenarios; acceptance
## smokes stay deterministic and script events explicitly).
var events_enabled := false
var loans := 0.0
## Daily cash-flow breakdown (today accumulates, yesterday is the closed
## day the budget panel shows).
var econ_today := {}
var econ_yesterday := {}
var econ_total := {}              # cumulative since scenario start (balancing)
var _cash_frac := 0.0
var _econ_day := -1
## Difficulty knobs (Phase 7 task 4), set by the scenario picker.
var difficulty := {"growth_scale": 1.0, "event_scale": 1.0, "money_scale": 1.0}

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
	# surface orchestrator failures in the event feed — a silent reset
	# failure cost a debugging session once
	Orchestrator.supply_event.connect(
		func(network: String, kind: String, severity: String, data: Dictionary) -> void:
			if severity != "info" and kind != "violation":
				log_event(kind, severity, "%s (%s): %s" % [kind, network,
					str(data.get("detail", data.get("error", "")))]))
	GameClock.sim_step.connect(func(t: int) -> void:
		current_t = t
		_econ_tick(t))


var _assign_dirty := false


func _process(delta: float) -> void:
	if _assign_dirty and not _topo_dirty:
		# cheap local re-extraction (house→zone assignment), max once per frame
		_assign_dirty = false
		_refresh_topo_assignment()
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


func build_heat_pipe(pos: Vector2i) -> bool:
	return _paid(BuildingDefs.COSTS["heat_pipe"]) and model.set_heat_pipe(pos, 1) \
		and _after_build(true)


func build_water_pipe(pos: Vector2i) -> bool:
	return _paid(BuildingDefs.COSTS["water_pipe"]) and model.set_water_pipe(pos, 1) \
		and _after_build(true)


func place_building(kind: String, anchor: Vector2i, rot: int = 0,
		params_override: Dictionary = {}) -> bool:
	var def := BuildingDefs.get_def(kind)
	if def.is_empty() or not model.can_place_building(kind, anchor):
		return false
	if not _paid(def["cost"]):
		return false
	model.place_building(kind, anchor, rot, params_override)
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
	if model.heat_pipes.has(pos):
		model.remove_heat_pipe(pos)
		return _after_build(true)
	if model.water_pipes.has(pos):
		model.remove_water_pipe(pos)
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
		_assign_dirty = true  # zone/house reassignment is deferred to _process
	_topo_timer = 0.0  # restart the idle countdown — see TOPO_DEBOUNCE_S
	world_changed.emit()
	state_changed.emit()
	return true


# ─── topology sync (model -> solver; reset only on real change) ───

func _refresh_topo_assignment() -> void:
	# houses/zones changed but the network docs did not: re-extract locally
	# for zone assignment + house counts, skip the backend resets
	topo = PowerTopology.build(model, tripped_tiles)
	heat_topo = HeatTopology.build(model, tripped_tiles)
	water_topo = WaterTopology.build(model, tripped_tiles)


func _sync_topology() -> void:
	_topo_dirty = false
	topo = PowerTopology.build(model, tripped_tiles)
	heat_topo = HeatTopology.build(model, tripped_tiles)
	water_topo = WaterTopology.build(model, tripped_tiles)
	_syncing = true
	_register_async()


func _register_async() -> void:
	# power
	if not topo.has_slack or topo.doc.is_empty():
		registered = false
		_last_doc_json = ""
	else:
		var doc_json := JSON.stringify(topo.doc)
		if doc_json != _last_doc_json or not registered:
			if await _register_network("power", topo.doc):
				registered = true
				_last_doc_json = doc_json
			else:
				registered = false
	# heat (independent of power failures)
	if not heat_topo.has_plant or heat_topo.doc.is_empty():
		heat_registered = false
		_last_heat_doc_json = ""
	else:
		var heat_json := JSON.stringify(heat_topo.doc)
		if heat_json != _last_heat_doc_json or not heat_registered:
			if await _register_network("heat", heat_topo.doc):
				heat_registered = true
				_last_heat_doc_json = heat_json
			else:
				heat_registered = false
	# water (independent of both)
	if not water_topo.has_source or water_topo.doc.is_empty():
		water_registered = false
		_last_water_doc_json = ""
	else:
		var water_json := JSON.stringify(water_topo.doc)
		if water_json != _last_water_doc_json or not water_registered:
			if await _register_network("water", water_topo.doc):
				water_registered = true
				_last_water_doc_json = water_json
			else:
				water_registered = false
	if registered or heat_registered or water_registered:
		Orchestrator.start()
	_syncing = false


func _register_network(id: String, doc: Dictionary) -> bool:
	if SidecarManager.state_of(id) != SidecarManager.State.HEALTHY:
		_topo_dirty = true  # retry once the backend is back
		return false
	if not CosimBridge.info.has(id):
		if not await CosimBridge.handshake(id):
			_topo_dirty = true
			return false
	var ok: bool = await Orchestrator.register(id, doc)
	if ok:
		# instant feedback: solve once right now instead of waiting for the
		# next clock-driven sim step
		Orchestrator._dispatch(id, current_t)
	return ok


func is_syncing() -> bool:
	return _syncing or _topo_dirty


## Absorb the one-time numba JIT (~3-8 s backend-side) at BOOT with a
## throwaway 2-bus network, so the player's first real build doesn't stall.
func warmup_backend() -> void:
	if registered or _syncing or not CosimBridge.info.has("power"):
		return
	var warmup_doc := {
		"contract": "1.0", "network_kind": "power", "name": "jit_warmup",
		"steps_per_day": 96,
		"native": {
			"grid_structure": {"name": "warmup", "f_hz": 50,
				"buses": [{"name": "w0", "vn_kv": 0.4}, {"name": "w1", "vn_kv": 0.4}]},
			"lines": {"lines": [{"name": "wl", "from_bus": 0, "to_bus": 1,
				"length_km": 0.1, "std_type": "NAYY 4x50 SE"}], "transformers": []},
			"load": {"resolution_minutes": 15, "steps": 96, "loads": []},
			"generation": {"resolution_minutes": 15, "steps": 96, "generation": []},
			"substation": {"resolution_minutes": 15, "steps": 96, "substations": []},
		},
		"zones": [],
		"devices": [{"id": "wslack", "kind": "slack", "node": "w0",
			"params": {"vm_pu": 1.0}}],
	}
	await CosimBridge.net_reset("power", warmup_doc)
	log_event("ready", "info", "Power solver warmed up — build away")


# ─── BoundaryProvider (duck-typed, see Orchestrator) ───

func get_zone_demand(network: String, t: int) -> Dictionary:
	var out := {}
	if network == "heat":
		var temp := float(weather.sample(t)["temp_c"])
		for zone_id: String in heat_topo.zones_info:
			out[zone_id] = {"value": snappedf(DemandModel.heat_zone_demand_kw(
				heat_topo.zones_info[zone_id]["houses"], t, temp), 0.1)}
		return out
	if network == "water":
		var temp_w := float(weather.sample(t)["temp_c"])
		for zone_id: String in water_topo.zones_info:
			# household demand + any hydrant/leak draw (fire, burst events):
			# the network solves the sag, PDD weakens the neighbors
			out[zone_id] = {"value": snappedf(DemandModel.water_zone_demand_m3h(
				water_topo.zones_info[zone_id]["houses"], t, temp_w)
				+ event_system.extra_water_demand_m3h(zone_id, t), 0.001)}
		return out
	for zone_id: String in topo.zones_info:
		out[zone_id] = {"value": DemandModel.zone_demand_kw(
			topo.zones_info[zone_id]["houses"], t)}
	return out


func get_device_setpoints(network: String, t: int) -> Dictionary:
	if network == "heat":
		return _heat_setpoints(t)
	if network == "water":
		return _water_setpoints(t)
	var sample := weather.sample(t)
	var total_demand := 0.0
	for zone_id: String in topo.zones_info:
		total_demand += DemandModel.zone_demand_kw(topo.zones_info[zone_id]["houses"], t)
	var out := {}
	var renewable := 0.0
	for device: Dictionary in topo.doc.get("devices", []):
		var params: Dictionary = device.get("params", {})
		var down := event_system.is_down(device["id"], t)  # equipment/maintenance
		match device["kind"]:
			"wind":
				var p: float = 0.0 if down else params["p_rated_kw"] \
					* WeatherSystem.wind_availability(sample["wind_ms"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				renewable += p
			"pv":
				var p: float = 0.0 if down else params["p_rated_kw"] \
					* WeatherSystem.pv_availability(sample["ghi_wm2"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				renewable += p
	var residual := total_demand - renewable
	for device: Dictionary in topo.doc.get("devices", []):
		var down := event_system.is_down(device["id"], t)
		match device["kind"]:
			"generator":
				var p: float = 0.0 if down \
					else clampf(residual, 0.0, device["params"]["p_max_kw"])
				out[device["id"]] = {"p_kw": snappedf(p, 0.1)}
				residual -= p
			"battery":
				# discharge into deficit, charge on surplus; backend clamps SoC
				var p_max: float = 0.0 if down else device["params"]["p_max_kw"]
				out[device["id"]] = {"p_kw": snappedf(clampf(residual, -p_max, p_max), 0.1)}
				residual -= clampf(residual, -p_max, p_max)
	return out


func get_weather(t: int) -> Dictionary:
	return weather.sample(t)


## Heat network dispatch: secondary plants (feed-ins) run their configured
## constant output; storages charge at night and discharge into the morning
## peak (the Phase 4 storage acceptance behavior).
func _heat_setpoints(t: int) -> Dictionary:
	var out := {}
	var first := true
	# discharging MORE than the net currently consumes is hydraulically
	# infeasible (the pressure slack cannot absorb reverse flow — the solver
	# rightly fails); cap discharge well below live demand
	var temp := float(weather.sample(t)["temp_c"])
	var total_demand := 0.0
	for zone_id: String in heat_topo.zones_info:
		total_demand += DemandModel.heat_zone_demand_kw(
			heat_topo.zones_info[zone_id]["houses"], t, temp)
	for device: Dictionary in heat_topo.doc.get("devices", []):
		var def_kind: String = device["kind"]
		var down := event_system.is_down(device["id"], t)
		if def_kind == "storage_heat":
			var p_max := 0.0 if down else float(device["params"].get("p_max_kw", 100.0))
			var hour := (t * 15 % 1440) / 60
			var setpoint := 0.0
			if hour >= 0 and hour < 5:
				setpoint = -p_max          # charge from the net at night
			elif hour >= 6 and hour < 10:
				setpoint = minf(p_max, 0.6 * total_demand)
			out[device["id"]] = {"q_kw": snappedf(setpoint, 0.1)}
		elif not first and def_kind in ["chp", "boiler", "heat_pump"]:
			# secondary plants are heat-exchanger feed-ins with constant dispatch
			var b_kind: String = model.buildings[device["id"]]["kind"]
			out[device["id"]] = {"q_kw": 0.0 if down else float(
				BuildingDefs.get_def(b_kind).get("dispatch_q_kw", 100.0))}
		if def_kind in ["chp", "boiler", "heat_pump"]:
			first = false
	return out


## Water dispatch: wells follow the aquifer (drought factor), pumps run only
## while their electric feed is alive — cable-connected to a slack-reachable
## grid that is neither tripped nor failed. THE cross-vector consequence:
## a blackout at the pumping station drains the tower, then taps run dry.
func _water_setpoints(t: int) -> Dictionary:
	var out := {}
	var power_ok: bool = registered and grid_trip_until <= t \
		and last_result.get("status", "failed") != "failed"
	for device: Dictionary in water_topo.doc.get("devices", []):
		var down := event_system.is_down(device["id"], t)
		match device["kind"]:
			"well":
				out[device["id"]] = {"yield_factor": 0.0 if down
					else snappedf(weather.drought_factor(t), 0.01)}
			"water_pump":
				var powered: bool = power_ok and not down \
					and topo.connected.get(device["id"], false)
				out[device["id"]] = {"enabled": powered}
	return out


# ─── economy engine (Phase 7 task 1) ───

## Fractional euros accumulate; whole euros land on the int balance.
func _econ_apply(category: String, delta_eur: float) -> void:
	econ_today[category] = econ_today.get(category, 0.0) + delta_eur
	econ_total[category] = econ_total.get(category, 0.0) + delta_eur
	_cash_frac += delta_eur
	var whole := int(_cash_frac)
	money += whole
	_cash_frac -= whole


## Clock-driven costs: upkeep + loan interest accrue every step regardless
## of network state; the day rolls over (and events roll) at midnight.
func _econ_tick(t: int) -> void:
	var day := t / 96
	if day != _econ_day:
		_econ_day = day
		econ_yesterday = econ_today.duplicate()
		econ_today = {}
		if events_enabled:
			_roll_events(t)
	var upkeep := 0.0
	for id: String in model.buildings:
		upkeep += float(BuildingDefs.UPKEEP_DAY.get(model.buildings[id]["kind"], 0.0))
	if upkeep > 0.0:
		_econ_apply("cost_upkeep", -upkeep / 96.0)
	if not model.houses.is_empty():  # standing charges (Grundgebühr)
		_econ_apply("income_base", model.houses.size() * BASE_FEE_HOUSE_DAY / 96.0)
	if loans > 0.0:
		_econ_apply("cost_interest", -loans * LOAN_RATE_DAY / 96.0)


func take_loan(amount: float) -> void:
	loans += amount
	_econ_apply("loan_in", amount)
	log_event("loan", "info", "Loan taken: €%.0f (outstanding €%.0f)" % [amount, loans])


func repay_loan(amount: float) -> void:
	var repay := minf(minf(amount, loans), float(money))
	if repay <= 0.0:
		return
	loans -= repay
	_econ_apply("loan_out", -repay)
	log_event("loan", "info", "Loan repaid: €%.0f (outstanding €%.0f)" % [repay, loans])


## Slack-ish exemptions for MTBF: the pressure/voltage boundary failing is
## an unsolvable network, not an equipment outage.
func _roll_events(t: int) -> void:
	event_system.frequency_scale = float(difficulty["event_scale"])
	var exempt := {}
	for id: String in model.buildings_of_kind("grid_connection"):
		exempt[id] = true
	var plant_ids: Array[String] = []
	for kind: String in BuildingDefs.HEAT_PLANT_KINDS:
		plant_ids.append_array(model.buildings_of_kind(kind))
	plant_ids.sort()
	if not plant_ids.is_empty():
		exempt[plant_ids[0]] = true  # the heat slack
	for event: Dictionary in event_system.roll_daily(t, model, weather, exempt):
		_apply_event(event, t)


func _apply_event(event: Dictionary, _t: int) -> void:
	if event["kind"] == "pipe_burst":
		tripped_tiles[event["tile"]] = event["until_t"]
		_topo_dirty = true
	log_event(event["kind"], event["severity"], event["text"])


# ─── consequences (ROADMAP Phase 3 task 6) ───

func _on_step_completed(network: String, t: int, result: Dictionary) -> void:
	if network == "heat":
		_on_heat_step(t, result)
		return
	if network == "water":
		_on_water_step(t, result)
		return
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

	if total_houses > 0:
		var hurt := float(unsupplied_houses) / total_houses
		satisfaction["power"] = clampf(satisfaction["power"] - 9.0 * hurt
			+ (SATISFACTION_RECOVERY if hurt == 0.0 else 0.0), 0.0, 100.0)
		_update_happiness(t)

	# economy: delivered kWh earn the tariff; the slack settles wholesale;
	# the gas plant burns fuel for what it actually produced
	var income := 0.0
	for zone_id: String in topo.zones_info:
		if zone_supplied.get(zone_id, false):
			income += DemandModel.zone_demand_kw(
				topo.zones_info[zone_id]["houses"], t) * STEP_H * TARIFF_ELEC_KWH
	if income > 0.0:
		_econ_apply("income_elec", income)
	for slack_id: String in model.buildings_of_kind("grid_connection"):
		var import_kw := float(result.get("devices", {})
			.get(slack_id, {}).get("output_kw", 0.0))
		if import_kw > 0.0:
			_econ_apply("cost_grid", -import_kw * STEP_H * GRID_IMPORT_KWH)
		elif import_kw < 0.0:
			_econ_apply("income_feedin", -import_kw * STEP_H * GRID_FEEDIN_KWH)
	for gas_id: String in model.buildings_of_kind("gas_plant"):
		var p_kw := float(result.get("devices", {})
			.get(gas_id, {}).get("output_kw", 0.0))
		if p_kw > 0.0:
			_econ_apply("cost_fuel", -p_kw / GAS_PLANT_ETA * STEP_H * FUEL_PRICE_KWH)

	_check_protection(t, result)
	_grow(t)
	state_changed.emit()
	power_result.emit(t, result)


## Heat consequences (ROADMAP Phase 4 task 4): a zone is warm when supplied
## AND its supply temperature clears the consumer's minimum; cold homes hurt
## happiness scaled by the outdoor temperature — a heat outage in July is a
## shrug, in January a catastrophe.
var _heat_degraded_streak := 0


func _on_heat_step(t: int, result: Dictionary) -> void:
	last_heat_result = result
	var status: String = result.get("status", "failed")
	if status == "degraded":
		_heat_degraded_streak += 1
		if _heat_degraded_streak == 1:
			log_event("heat_degraded", "warning",
				"Heat solver degraded — network near its limits")
	else:
		_heat_degraded_streak = 0
	var failed := status == "failed"
	var temp := float(weather.sample(t)["temp_c"])
	var cold_factor := clampf((18.0 - temp) / 24.0, 0.15, 1.25)
	var cold_houses := 0
	var total := 0
	heat_zone_supplied.clear()
	for zone_id: String in heat_topo.zones_info:
		var houses: int = heat_topo.zones_info[zone_id]["houses"]
		total += houses
		var zone_result: Dictionary = result.get("zones", {}).get(zone_id, {})
		var t_supply := float(zone_result.get("detail", {}).get("t_supply_c", 0.0))
		var warm: bool = (
			not failed and not zone_result.is_empty()
			and float(zone_result.get("supplied", 0.0)) >= 0.99
			and t_supply >= HeatTopology.T_SUPPLY_MIN_C
		)
		heat_zone_supplied[zone_id] = warm
		if not warm and houses > 0:
			heat_outage_minutes[zone_id] = heat_outage_minutes.get(zone_id, 0) \
				+ GameClock.SIM_STEP_MINUTES
			cold_houses += houses
	if total > 0:
		var hurt := float(cold_houses) / total
		satisfaction["heat"] = clampf(satisfaction["heat"]
			- 7.0 * cold_factor * hurt
			+ (SATISFACTION_RECOVERY if hurt == 0.0 else 0.0), 0.0, 100.0)
		_update_happiness(t)
		if cold_houses > 0 and t % 8 == 0:
			log_event("cold_homes", "warning",
				"%d houses without adequate heat (%.0f°C outside)" % [cold_houses, temp])
	# economy: warm zones pay the heat tariff; boiler fuel comes from the
	# solved p_fuel_kw, CHP fuel from heat + coupled electricity over eta
	var income := 0.0
	for zone_id: String in heat_topo.zones_info:
		if heat_zone_supplied.get(zone_id, false):
			income += DemandModel.heat_zone_demand_kw(
				heat_topo.zones_info[zone_id]["houses"], t, temp) \
				* STEP_H * TARIFF_HEAT_KWH
	if income > 0.0:
		_econ_apply("income_heat", income)
	for kind: String in ["boiler_plant", "chp_plant"]:
		for plant_id: String in model.buildings_of_kind(kind):
			var device: Dictionary = result.get("devices", {}).get(plant_id, {})
			if device.is_empty():
				continue
			var q_kw := absf(float(device.get("output_kw", 0.0)))
			var fuel_kw: float
			if kind == "boiler_plant":
				fuel_kw = float(device.get("detail", {})
					.get("p_fuel_kw", q_kw / 0.95))
			else:
				var p_el := absf(float(result.get("coupling_out", {})
					.get(plant_id, {}).get("p_el_kw", q_kw * 0.5)))
				fuel_kw = (q_kw + p_el) / CHP_ETA_TOTAL
			if fuel_kw > 0.0:
				_econ_apply("cost_fuel", -fuel_kw * STEP_H * FUEL_PRICE_KWH)
	state_changed.emit()
	heat_result.emit(t, result)


func total_heat_outage_minutes() -> int:
	var total := 0
	for zone_id: String in heat_outage_minutes:
		total += heat_outage_minutes[zone_id]
	return total


## Water consequences (ROADMAP Phase 5): `supplied` is the Wagner PDD
## fraction — weak taps (fractional) before dry taps. No water is the
## harshest of the three outages: hygiene, cooking, everything stops.
func _on_water_step(t: int, result: Dictionary) -> void:
	last_water_result = result
	var failed: bool = result.get("status", "failed") == "failed"
	var dry_weight := 0.0     # house-weighted shortfall across zones
	var total := 0
	water_zone_supplied.clear()
	for zone_id: String in water_topo.zones_info:
		var houses: int = water_topo.zones_info[zone_id]["houses"]
		total += houses
		var zone_result: Dictionary = result.get("zones", {}).get(zone_id, {})
		var supplied := 0.0 if (failed or zone_result.is_empty()) \
			else clampf(float(zone_result.get("supplied", 0.0)), 0.0, 1.0)
		water_zone_supplied[zone_id] = supplied >= 0.95
		if supplied < 0.95 and houses > 0:
			water_outage_minutes[zone_id] = water_outage_minutes.get(zone_id, 0) \
				+ GameClock.SIM_STEP_MINUTES
			dry_weight += (1.0 - supplied) * houses
	if total > 0:
		var hurt := dry_weight / total
		satisfaction["water"] = clampf(satisfaction["water"] - 12.0 * hurt
			+ (SATISFACTION_RECOVERY * 0.8 if hurt == 0.0 else 0.0), 0.0, 100.0)
		_update_happiness(t)
		if dry_weight > 0.0 and t % 8 == 0:
			log_event("dry_taps", "critical",
				"Water pressure collapsed — %.0f%% of homes short of water"
				% (100.0 * hurt))
	# economy: household m³ actually delivered (PDD fraction) earn the
	# tariff — fire/leak draws are losses, never billed
	var temp_w := float(weather.sample(t)["temp_c"])
	var income := 0.0
	for zone_id: String in water_topo.zones_info:
		var fraction := clampf(float(result.get("zones", {})
			.get(zone_id, {}).get("supplied", 0.0)), 0.0, 1.0)
		if result.get("status", "failed") == "failed":
			fraction = 0.0
		income += DemandModel.water_zone_demand_m3h(
			water_topo.zones_info[zone_id]["houses"], t, temp_w) \
			* fraction * STEP_H * TARIFF_WATER_M3
	if income > 0.0:
		_econ_apply("income_water", income)
	state_changed.emit()
	water_result.emit(t, result)


func total_water_outage_minutes() -> int:
	var total := 0
	for zone_id: String in water_outage_minutes:
		total += water_outage_minutes[zone_id]
	return total


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


const SATISFACTION_RECOVERY := 0.06  # per clean step (~6/day): weeks-scale memory
const ABANDON_HAPPINESS := 35.0


## Weighted blend of the per-network satisfactions. Water always weighs
## heaviest; heat's weight follows the season (cold_factor). Only networks
## the town actually HAS count — a village with no district heating isn't
## shielded by a perfect score for a service that doesn't exist.
func _update_happiness(t: int) -> void:
	var temp := float(weather.sample(t)["temp_c"])
	var cold_norm := clampf((18.0 - temp) / 24.0, 0.15, 1.25) / 1.25  # 0.12..1
	var weights := {"water": 0.45, "power": 0.25,
		"heat": 0.3 * (0.25 + 0.75 * cold_norm)}
	var active := {"power": not topo.zones_info.is_empty(),
		"heat": not heat_topo.zones_info.is_empty(),
		"water": not water_topo.zones_info.is_empty()}
	var acc := 0.0
	var total_weight := 0.0
	for key: String in weights:
		if not active[key]:
			continue
		acc += weights[key] * float(satisfaction[key])
		total_weight += weights[key]
	if total_weight > 0.0:
		happiness = clampf(acc / total_weight, 0.0, 100.0)


## Growth v2 (ROADMAP Phase 6 task 2): the growth rate follows happiness,
## new houses only spawn where the supply has spare margin, and sustained
## misery empties houses back out — a stabilizing feedback loop that also
## reads as failure.
func _grow(t: int) -> void:
	if not growth_enabled:
		return
	if happiness < ABANDON_HAPPINESS:
		_abandon(t)
		return
	var interval := 4 if happiness >= 90.0 \
		else (8 if happiness >= 75.0 else (16 if happiness >= GROWTH_HAPPINESS_MIN else 0))
	if interval > 0:  # difficulty: easy towns grow faster, hard ones slower
		interval = maxi(1, int(interval / float(difficulty["growth_scale"])))
	if interval == 0 or t % interval != 0:
		return
	if not _supply_margin_ok():
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


## Spare-margin gate: nobody moves into a town running at its limits.
## (Power margin — houses hang off power zones; heat/water shortfalls
## already gate growth through happiness.)
func _supply_margin_ok() -> bool:
	if last_result.get("status", "") == "failed":
		return false
	for edge_id: String in last_result.get("edges", {}):
		if float(last_result["edges"][edge_id].get("loading_percent", 0.0)) > 95.0:
			return false
	var slack_ids := model.buildings_of_kind("grid_connection")
	if not slack_ids.is_empty():
		var capacity: float = grid_capacity_override if grid_capacity_override > 0.0 \
			else BuildingDefs.get_def("grid_connection")["capacity_kw"]
		var import_kw := float(last_result.get("devices", {})
			.get(slack_ids[0], {}).get("output_kw", 0.0))
		if import_kw > 0.85 * capacity:
			return false
	return true


## Sustained misery: one household leaves every 4 game-hours, from the zone
## with the worst outage record first.
func _abandon(t: int) -> void:
	if t % 16 != 0 or model.houses.is_empty():
		return
	var houses := model.houses.keys()
	houses.sort()  # deterministic
	var victim: Vector2i = houses[0]
	var worst_zone := ""
	var worst := -1
	for zone_id: String in outage_minutes:
		if outage_minutes[zone_id] > worst:
			worst = outage_minutes[zone_id]
			worst_zone = zone_id
	if worst_zone != "":
		for pos: Vector2i in houses:
			if topo.house_zone.get(pos, "") == worst_zone:
				victim = pos
				break
	model.remove_house(victim)
	_refresh_topo_assignment()
	log_event("abandoned", "warning",
		"A family left town — supply too unreliable")
	world_changed.emit()


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


## Fresh-slate reset for scripted scenarios/tests.
func reset_for_scenario(weather_seed: int) -> void:
	model = WorldModel.new()
	money = 100_000_000
	weather = WeatherSystem.new(weather_seed)
	outage_minutes = {}
	heat_outage_minutes = {}
	water_outage_minutes = {}
	happiness = 100.0
	satisfaction = {"power": 100.0, "heat": 100.0, "water": 100.0}
	tripped_tiles.clear()
	grid_trip_until = -1
	grid_capacity_override = -1.0
	growth_enabled = true
	event_system = EventSystem.new(weather_seed)
	events_enabled = false
	loans = 0.0
	econ_today = {}
	econ_yesterday = {}
	econ_total = {}
	_cash_frac = 0.0
	_econ_day = -1
	difficulty = {"growth_scale": 1.0, "event_scale": 1.0, "money_scale": 1.0}
	registered = false
	heat_registered = false
	water_registered = false
	_last_doc_json = ""
	_last_heat_doc_json = ""
	_last_water_doc_json = ""
	_line_streak.clear()
	_slack_streak = 0
	_heat_degraded_streak = 0
	zone_supplied.clear()
	heat_zone_supplied.clear()
	water_zone_supplied.clear()
	last_result = {}
	last_heat_result = {}
	last_water_result = {}
	_topo_dirty = true
	world_changed.emit()
	state_changed.emit()


# ─── persistence ───

func serialize() -> Dictionary:
	return {
		"money": money, "happiness": happiness,
		"loans": loans,
		"satisfaction": satisfaction.duplicate(),
		"outage_minutes": outage_minutes.duplicate(),
		"heat_outage_minutes": heat_outage_minutes.duplicate(),
		"water_outage_minutes": water_outage_minutes.duplicate(),
		"weather_seed": weather.seed_value,
	}


func restore(data: Dictionary) -> void:
	money = int(data.get("money", START_MONEY))
	happiness = float(data.get("happiness", 100.0))
	loans = float(data.get("loans", 0.0))
	var sat: Dictionary = data.get("satisfaction", {})
	for key: String in satisfaction:
		satisfaction[key] = float(sat.get(key, 100.0))
	outage_minutes = data.get("outage_minutes", {})
	heat_outage_minutes = data.get("heat_outage_minutes", {})
	water_outage_minutes = data.get("water_outage_minutes", {})
	weather = WeatherSystem.new(int(data.get("weather_seed", 42)))
	tripped_tiles.clear()
	grid_trip_until = -1
	_topo_dirty = true
	state_changed.emit()
	world_changed.emit()
