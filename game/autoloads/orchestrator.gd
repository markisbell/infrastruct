extends Node
## Orchestrator — schedules solver steps from the game clock (ROADMAP §2.5).
##
## Rules it enforces:
## - one-step lag: at sim-step t the game USES results of t-1; the request for
##   t is dispatched asynchronously and never blocks the frame loop
## - at most one step in flight per network; if the next sim_step arrives while
##   the previous is still solving, the new step is SKIPPED for that network
##   (counted, interpolated by keeping the last result — never a stall)
## - coupling routing: coupling_out of network A at t-1 becomes coupling_in of
##   network B at t (loose Gauss–Seidel; §2.5)
## - solver failure is a gameplay event, not an error (contract §0.2)
## - backend death/recovery: on HEALTHY after DOWN, re-handshake + net/reset
##   (the game model is the source of truth) and resume at the current step;
##   missed steps are skipped, a disturbance event covers the gap (contract §5)

signal supply_event(network: String, kind: String, severity: String, data: Dictionary)
signal step_completed(network: String, t: int, result: Dictionary)

const FAILED_ESCALATION_STEPS := 3

## BoundaryProvider duck-type: get_zone_demand(network, t) -> Dictionary,
## get_device_setpoints(network, t) -> Dictionary, get_weather(t) -> Dictionary
var boundary_provider: Object = null

var networks := {}  # id -> {topology, in_flight, last_result, last_t, missed, consecutive_failed, needs_reset, down_since_t}
var running := false
var stats := {"dispatched": 0, "completed": 0, "missed": 0, "skipped_down": 0}


func _ready() -> void:
	GameClock.sim_step.connect(_on_sim_step)
	SidecarManager.state_changed.connect(_on_sidecar_state)


## Register a network with its topology document; resets the backend.
func register(id: String, topology: Dictionary) -> bool:
	networks[id] = {
		"topology": topology, "in_flight": false, "last_result": {},
		"last_t": -1, "missed": 0, "consecutive_failed": 0,
		"needs_reset": false, "down_since_t": -1, "resetting": true,
	}
	var response := await CosimBridge.net_reset(id, topology)
	var ok: bool = response.get("_status", 0) == 200 and response.get("ok", false)
	networks[id]["resetting"] = false
	if not ok:
		push_warning("net_reset failed for %s: %s" % [id, JSON.stringify(response)])
		supply_event.emit(id, "reset_failed", "critical", response)
	return ok


func start() -> void:
	running = true


func stop() -> void:
	running = false


func latest(id: String) -> Dictionary:
	return networks[id]["last_result"] if networks.has(id) else {}


func _on_sim_step(t: int) -> void:
	if not running:
		return
	for id: String in networks:
		_dispatch(id, t)


func _dispatch(id: String, t: int) -> void:
	var net: Dictionary = networks[id]
	if net.get("resetting", false):
		return  # quiet skip: an ordinary re-register is in flight
	if SidecarManager.state_of(id) != SidecarManager.State.HEALTHY or net["needs_reset"]:
		stats["skipped_down"] += 1
		if net["down_since_t"] < 0:
			net["down_since_t"] = t
			supply_event.emit(id, "backend_down", "critical", {"t": t})
		return
	if net["in_flight"]:
		net["missed"] += 1
		stats["missed"] += 1
		supply_event.emit(id, "step_overrun", "info", {"t": t})
		return
	net["in_flight"] = true
	stats["dispatched"] += 1
	_step_async(id, t)


func _step_async(id: String, t: int) -> void:
	var net: Dictionary = networks[id]
	# Wire t must be last_t+1 for the backend (contract §0.3) even when the
	# game skipped steps (overruns, re-registration) — boundary conditions are
	# still evaluated at the GAME step t, so physics follow the game clock.
	var wire_t: int = net["last_t"] + 1 if net["last_t"] >= 0 else t
	var request := {
		"t": wire_t,
		"dt_s": GameClock.SIM_STEP_MINUTES * 60,
		"weather": boundary_provider.get_weather(t) if boundary_provider else {},
		"zone_demand": boundary_provider.get_zone_demand(id, t) if boundary_provider else {},
		"device_setpoints": boundary_provider.get_device_setpoints(id, t) if boundary_provider else {},
		"coupling_in": _coupling_for(id),
	}
	var result := await CosimBridge.step(id, request)
	net["in_flight"] = false
	if result.get("_status", 0) != 200:
		# transport failure — health polling will flag DOWN; don't corrupt state
		supply_event.emit(id, "step_transport_failed", "warning",
			{"t": t, "error": result.get("_error", "?")})
		return
	if result.get("status", "") == "error":
		# protocol rejection (e.g. out_of_order after a mid-run reset race) —
		# do not store; the wire-t resync self-heals on the next dispatch
		supply_event.emit(id, "step_rejected", "warning",
			{"t": t, "error": result.get("error", "?")})
		return
	net["last_result"] = result
	net["last_t"] = wire_t
	stats["completed"] += 1
	match result.get("status", "failed"):
		"converged":
			net["consecutive_failed"] = 0
		"degraded":
			net["consecutive_failed"] = 0
			supply_event.emit(id, "solver_degraded", "warning", {"t": t})
		"failed":
			net["consecutive_failed"] += 1
			var severity := "critical" \
				if net["consecutive_failed"] >= FAILED_ESCALATION_STEPS else "warning"
			supply_event.emit(id, "supply_failure", severity,
				{"t": t, "consecutive": net["consecutive_failed"]})
	for violation: Dictionary in result.get("violations", []):
		if violation.get("severity", "info") != "info":
			supply_event.emit(id, "violation", violation["severity"], violation)
	step_completed.emit(id, t, result)


## coupling_out of every OTHER network's latest result -> coupling_in here.
## v1 wiring: heat/water electric draws land on the power net's coupling_load
## devices; ids must match across topologies (fixture convention: "cpl_heat").
func _coupling_for(id: String) -> Dictionary:
	var coupling := {}
	for other_id: String in networks:
		if other_id == id:
			continue
		var out: Dictionary = networks[other_id]["last_result"].get("coupling_out", {})
		for device_id: String in out:
			var target := "cpl_%s" % other_id
			var p_kw := float(out[device_id].get("p_el_kw", 0.0))
			if not coupling.has(target):
				coupling[target] = {"p_kw": 0.0}
			coupling[target]["p_kw"] += p_kw
	return coupling


func _on_sidecar_state(id: String, state: SidecarManager.State) -> void:
	if not networks.has(id):
		return
	var net: Dictionary = networks[id]
	if state == SidecarManager.State.DOWN or state == SidecarManager.State.RESTARTING:
		net["needs_reset"] = true
		net["in_flight"] = false
		CosimBridge.drop(id)
	elif state == SidecarManager.State.HEALTHY and net["needs_reset"]:
		_recover(id)


func _recover(id: String) -> void:
	var net: Dictionary = networks[id]
	if not await CosimBridge.handshake(id):
		supply_event.emit(id, "handshake_failed", "critical", {})
		return
	var response := await CosimBridge.net_reset(id, net["topology"])
	if response.get("_status", 0) == 200 and response.get("ok", false):
		net["needs_reset"] = false
		var gap_start: int = net["down_since_t"]
		net["down_since_t"] = -1
		supply_event.emit(id, "backend_recovered", "info",
			{"gap_start": gap_start, "resumed_at": GameClock.total_minutes})
	else:
		supply_event.emit(id, "reset_failed", "critical", response)
