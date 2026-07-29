class_name EventSystem
extends RefCounted
## Failure events beyond physics (ROADMAP Phase 7 task 2). Everything is
## SEEDED and rolled once per game-day, so a given seed replays identically;
## smokes force events directly instead of fishing for probabilities.
##
## Kinds and how they stay physical:
## - equipment (MTBF per building kind) / maintenance (player-scheduled):
##   the device's setpoint is zeroed / pump disabled while down — the
##   network solve carries the consequence
## - storm: wind forced above the 25 m/s cut-out (the turbine curve already
##   models the cut-out — output drops to 0 for real)
## - heatwave / deep frost: temperature overrides (drive heat + water demand
##   through the normal physics paths)
## - drought: aquifer yield collapse via the Phase 5 drought machinery
## - fire: hydrant fire-flow demand injected into a water zone — pressure
##   sags and PDD weakens neighbors, solved by pandapipes
## - pipe burst: the tile trips out of the topology (possible disconnection)
##   plus an uncontrolled leak draw at the nearest zone during repair
## Mid-pipe emitter leaks (rtwaterflow native machinery) need a contract
## 1.2 device kind — noted for Phase 8.

const FIRE_FLOW_M3H := 48.0      # DVGW W 405 small-town fire flow (measurable dp on DN150)
const BURST_LEAK_M3H := 8.0
const REPAIR_STEPS_EQUIPMENT := 24   # 6 h
const REPAIR_STEPS_BURST := 16       # 4 h
const FIRE_STEPS := 8                # 2 h

var rng := RandomNumberGenerator.new()
var frequency_scale := 1.0           # difficulty knob
## building id -> until_t (equipment failures AND maintenance windows)
var down_until := {}
## zone_id -> {until_t, m3h} (fire / burst leak draws)
var water_draws := {}
var log: Array[Dictionary] = []      # what roll_daily decided (for the caller)


func _init(seed_arg: int = 42) -> void:
	rng.seed = seed_arg


## Roll the day's events. Weather overrides are applied to `weather`
## directly; equipment/water effects are stored here for the boundary
## provider. Returns the day's event list for the caller's event feed.
func roll_daily(t: int, model: WorldModel, weather: WeatherSystem,
		exempt: Dictionary) -> Array[Dictionary]:
	var day_events: Array[Dictionary] = []
	# equipment failures (MTBF): p(day) = scale / mtbf
	for id: String in model.buildings:
		if exempt.has(id) or is_down(id, t):
			continue
		var kind: String = model.buildings[id]["kind"]
		if not BuildingDefs.MTBF_DAYS.has(kind):
			continue
		if rng.randf() < frequency_scale / float(BuildingDefs.MTBF_DAYS[kind]):
			day_events.append(force_equipment_failure(id, t))
	# weather events (seasonal windows use the game's 360-day year)
	var doy := (t / 96) % 360
	var summer := doy >= 90 and doy < 180
	var winter := doy >= 270
	if rng.randf() < frequency_scale / 30.0:
		day_events.append(force_storm(weather, t))
	if summer and rng.randf() < frequency_scale / 45.0:
		day_events.append(force_heatwave(weather, t))
	if winter and rng.randf() < frequency_scale / 45.0:
		day_events.append(force_frost(weather, t))
	if summer and rng.randf() < frequency_scale / 60.0:
		day_events.append(force_drought(weather, t))
	# water incidents need a live network
	var zones := _water_zone_ids(model)
	if not zones.is_empty() and rng.randf() < frequency_scale / 40.0:
		day_events.append(force_fire(zones[rng.randi() % zones.size()], t))
	if not model.water_pipes.is_empty() and rng.randf() < frequency_scale / 50.0:
		var tiles := model.water_pipes.keys()
		tiles.sort()
		day_events.append(make_burst(tiles[rng.randi() % tiles.size()], zones, t))
	log.append_array(day_events)
	return day_events


# ─── direct triggers (rolls above + scripted scenarios/smokes) ───

func force_equipment_failure(id: String, t: int) -> Dictionary:
	down_until[id] = t + REPAIR_STEPS_EQUIPMENT
	return {"kind": "equipment_failure", "severity": "warning", "id": id,
		"until_t": down_until[id],
		"text": "%s failed — crew dispatched (~6 h)" % id}


## Player-scheduled maintenance: same down machinery, planned severity.
func schedule_maintenance(id: String, start_t: int, steps: int) -> Dictionary:
	down_until[id] = start_t + steps  # simple v1: window starts now/at start_t
	return {"kind": "maintenance", "severity": "info", "id": id,
		"until_t": down_until[id],
		"text": "%s down for planned maintenance (%d h)" % [id, steps / 4]}


func force_storm(weather: WeatherSystem, t: int) -> Dictionary:
	weather.force_wind(t, t + 96, 27.0)  # above the 25 m/s turbine cut-out
	return {"kind": "storm", "severity": "warning", "until_t": t + 96,
		"text": "Storm front: 27 m/s — wind turbines cutting out"}


func force_heatwave(weather: WeatherSystem, t: int) -> Dictionary:
	weather.force_temp(t, t + 3 * 96, 35.0)
	return {"kind": "heatwave", "severity": "warning", "until_t": t + 3 * 96,
		"text": "Heat wave: 35°C for three days — water demand spikes"}


func force_frost(weather: WeatherSystem, t: int) -> Dictionary:
	weather.force_temp(t, t + 3 * 96, -20.0)
	return {"kind": "deep_frost", "severity": "warning", "until_t": t + 3 * 96,
		"text": "Deep frost: -20°C for three days — heat demand peaks"}


func force_drought(weather: WeatherSystem, t: int) -> Dictionary:
	weather.force_drought(t, t + 10 * 96, 0.15)
	return {"kind": "drought", "severity": "warning", "until_t": t + 10 * 96,
		"text": "Drought: aquifer yields collapse for ten days"}


func force_fire(zone_id: String, t: int) -> Dictionary:
	water_draws[zone_id] = {"until_t": t + FIRE_STEPS, "m3h": FIRE_FLOW_M3H}
	return {"kind": "fire", "severity": "critical", "zone": zone_id,
		"until_t": t + FIRE_STEPS,
		"text": "Fire! Hydrants drawing %.0f m³/h in %s" % [FIRE_FLOW_M3H, zone_id]}


## Burst = the tile leaves the topology (caller adds it to tripped_tiles)
## + an uncontrolled leak billed to the nearest zone while the crew digs.
func make_burst(tile: Vector2i, zones: Array, t: int) -> Dictionary:
	if not zones.is_empty():
		water_draws[zones[0]] = {"until_t": t + REPAIR_STEPS_BURST,
			"m3h": BURST_LEAK_M3H}
	return {"kind": "pipe_burst", "severity": "critical", "tile": tile,
		"until_t": t + REPAIR_STEPS_BURST,
		"text": "Water main burst at (%d,%d) — digging it up (~4 h)" % [tile.x, tile.y]}


# ─── queries (boundary provider) ───

func is_down(id: String, t: int) -> bool:
	return down_until.has(id) and down_until[id] > t


func extra_water_demand_m3h(zone_id: String, t: int) -> float:
	var draw: Dictionary = water_draws.get(zone_id, {})
	return float(draw.get("m3h", 0.0)) if int(draw.get("until_t", -1)) > t else 0.0


func _water_zone_ids(model: WorldModel) -> Array:
	var out := []
	for id: String in model.buildings_of_kind("water_station"):
		out.append("wz_" + id)
	out.sort()
	return out
