extends GdUnitTestSuite
## Orchestrator scheduler rules (Phase-4 refactor plan) against
## FakeCosimBridge — no sockets: one-step lag, missed-step counting,
## coupling routing, wire-t resync, down-skip accounting and recovery.
## The Python contract suite remains the wire authority; nothing here
## pins wire shapes.

const TOPO := {"contract": "1.1", "network_kind": "power", "name": "t",
	"steps_per_day": 96, "native": {}, "zones": [{"id": "z0", "node": "b1"}],
	"devices": [{"id": "slack", "kind": "slack", "node": "b0"}]}


class FakeBoundary:
	var zone_calls: Array = []  # [network, t] per get_zone_demand call

	func get_zone_demand(network: String, t: int) -> Dictionary:
		zone_calls.append([network, t])
		return {"z0": {"value": 10.0}}

	func get_device_setpoints(_network: String, _t: int) -> Dictionary:
		return {}

	func get_weather(_t: int) -> Dictionary:
		return {"wind_ms": 5.0}


var _fake: FakeCosimBridge
var _health: FakeSidecarHealth
var _boundary: FakeBoundary
var _saved_boundary: Object
var _events: Array[Dictionary] = []


func before_test() -> void:
	_saved_boundary = Orchestrator.boundary_provider
	Orchestrator.reset_for_test()
	_fake = FakeCosimBridge.new(get_tree())
	_health = FakeSidecarHealth.new()
	_boundary = FakeBoundary.new()
	Orchestrator.bridge_override = _fake
	Orchestrator.health_override = _health
	Orchestrator.boundary_provider = _boundary
	Orchestrator.running = true
	_events = []
	Orchestrator.supply_event.connect(_capture)


func after_test() -> void:
	Orchestrator.supply_event.disconnect(_capture)
	Orchestrator.reset_for_test()
	Orchestrator.boundary_provider = _saved_boundary


func _capture(network: String, kind: String, severity: String,
		data: Dictionary) -> void:
	_events.append({"network": network, "kind": kind,
		"severity": severity, "data": data})


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func test_register_resets_backend_and_first_wire_t_is_game_t() -> void:
	var ok: bool = await Orchestrator.register("power", TOPO)
	assert_bool(ok).is_true()
	assert_int(_fake.resets.size()).is_equal(1)
	Orchestrator._on_sim_step(7)  # mid-run registration: first wire t = game t
	await _settle()
	assert_int(_fake.requests.size()).is_equal(1)
	assert_int(int(_fake.requests[0]["request"]["t"])).is_equal(7)
	assert_int(int(Orchestrator.stats["completed"])).is_equal(1)


func test_one_step_lag_latest_returns_last_completed() -> void:
	await Orchestrator.register("power", TOPO)
	Orchestrator._on_sim_step(1)
	await _settle()
	assert_int(int(Orchestrator.latest("power")["t"])).is_equal(1)
	Orchestrator._on_sim_step(2)
	await _settle()
	assert_int(int(Orchestrator.latest("power")["t"])).is_equal(2)


func test_wire_t_resyncs_as_last_t_plus_one_after_skips() -> void:
	await Orchestrator.register("power", TOPO)
	Orchestrator._on_sim_step(5)
	await _settle()
	# the game skipped ahead to t=9; the WIRE must continue at last_t+1=6
	# while the boundary is evaluated at the GAME step 9 (physics follow
	# the game clock — CLAUDE.md §3)
	Orchestrator._on_sim_step(9)
	await _settle()
	assert_int(int(_fake.requests[1]["request"]["t"])).is_equal(6)
	assert_that(_boundary.zone_calls[1]).is_equal(["power", 9])


func test_missed_steps_counted_while_in_flight() -> void:
	await Orchestrator.register("power", TOPO)
	_fake.hold_frames = 6
	Orchestrator._on_sim_step(1)   # in flight, held by the fake
	Orchestrator._on_sim_step(2)   # overrun: skipped + counted
	Orchestrator._on_sim_step(3)   # again
	assert_int(int(Orchestrator.stats["missed"])).is_equal(2)
	assert_int(int(Orchestrator.networks["power"]["missed"])).is_equal(2)
	assert_int(int(Orchestrator.stats["dispatched"])).is_equal(1)
	for _i in 8:
		await get_tree().process_frame
	assert_int(int(Orchestrator.stats["completed"])).is_equal(1)
	assert_bool(bool(Orchestrator.networks["power"]["in_flight"])).is_false()


func test_coupling_routes_other_network_outputs() -> void:
	await Orchestrator.register("power", TOPO)
	var heat_topo := TOPO.duplicate(true)
	heat_topo["network_kind"] = "heat"
	await Orchestrator.register("heat", heat_topo)
	# heat solves first and reports electric draws in coupling_out
	_fake.step_handlers["heat"] = func(request: Dictionary) -> Dictionary:
		return FakeCosimBridge.converged(int(request["t"]),
			{"coupling_out": {"hp1": {"p_el_kw": 30.0},
				"chp1": {"p_el_kw": -12.5}}})
	Orchestrator._on_sim_step(1)
	await _settle()
	Orchestrator._on_sim_step(2)
	await _settle()
	# power's t=2 request carries heat's t=1 outputs summed onto cpl_heat
	var power_requests: Array = _fake.requests.filter(
		func(entry: Dictionary) -> bool: return entry["id"] == "power")
	var coupling: Dictionary = power_requests[1]["request"]["coupling_in"]
	assert_float(float(coupling["cpl_heat"]["p_kw"])).is_equal_approx(17.5, 0.0001)
	# and heat never receives its own outputs back as cpl_heat
	var heat_requests: Array = _fake.requests.filter(
		func(entry: Dictionary) -> bool: return entry["id"] == "heat")
	assert_bool((heat_requests[1]["request"]["coupling_in"] as Dictionary)
		.has("cpl_heat")).is_false()


func test_down_backend_skips_counted_and_single_down_event() -> void:
	await Orchestrator.register("power", TOPO)
	_health.states["power"] = SidecarManager.State.DOWN
	Orchestrator._on_sim_step(1)
	Orchestrator._on_sim_step(2)
	assert_int(int(Orchestrator.stats["skipped_down"])).is_equal(2)
	assert_int(_fake.requests.size()).is_equal(0)
	var down_events := _events.filter(
		func(event: Dictionary) -> bool: return event["kind"] == "backend_down")
	assert_int(down_events.size()).is_equal(1)  # latched, not repeated
	assert_int(int(Orchestrator.networks["power"]["down_since_t"])).is_equal(1)


func test_recovery_rehandshakes_resets_and_resumes() -> void:
	await Orchestrator.register("power", TOPO)
	Orchestrator._on_sim_step(1)
	await _settle()
	# backend dies: subsequent steps are skipped, drop + needs_reset latch
	_health.states["power"] = SidecarManager.State.DOWN
	Orchestrator._on_sidecar_state("power", SidecarManager.State.DOWN)
	Orchestrator._on_sim_step(2)
	assert_bool(bool(Orchestrator.networks["power"]["needs_reset"])).is_true()
	assert_that(_fake.dropped).contains(["power"])
	_health.states["power"] = SidecarManager.State.HEALTHY
	Orchestrator._on_sidecar_state("power", SidecarManager.State.HEALTHY)
	await _settle()
	assert_that(_fake.handshakes).contains(["power"])
	assert_int(_fake.resets.size()).is_equal(2)  # register + recovery
	assert_bool(bool(Orchestrator.networks["power"]["needs_reset"])).is_false()
	var recovered := _events.filter(
		func(event: Dictionary) -> bool: return event["kind"] == "backend_recovered")
	assert_int(recovered.size()).is_equal(1)
	# and the wire resumes at last_t+1 on the next dispatch
	Orchestrator._on_sim_step(40)
	await _settle()
	assert_int(int(_fake.requests[-1]["request"]["t"])).is_equal(2)


func test_error_frame_is_not_stored() -> void:
	await Orchestrator.register("power", TOPO)
	Orchestrator._on_sim_step(1)
	await _settle()
	_fake.step_handlers["power"] = func(_request: Dictionary) -> Dictionary:
		return {"_status": 200, "status": "error", "error": "out_of_order"}
	Orchestrator._on_sim_step(2)
	await _settle()
	# rejected frame: last_result/last_t unchanged, rejection event emitted
	assert_int(int(Orchestrator.latest("power")["t"])).is_equal(1)
	assert_int(int(Orchestrator.networks["power"]["last_t"])).is_equal(1)
	var rejected := _events.filter(
		func(event: Dictionary) -> bool: return event["kind"] == "step_rejected")
	assert_int(rejected.size()).is_equal(1)


func test_failed_escalates_to_critical_on_third_consecutive() -> void:
	await Orchestrator.register("power", TOPO)
	_fake.step_handlers["power"] = func(request: Dictionary) -> Dictionary:
		return FakeCosimBridge.converged(int(request["t"]), {"status": "failed"})
	var severities: Array[String] = []
	for t in [1, 2, 3]:
		Orchestrator._on_sim_step(t)
		await _settle()
	for event: Dictionary in _events:
		if event["kind"] == "supply_failure":
			severities.append(event["severity"])
	assert_that(severities).is_equal(["warning", "warning", "critical"])
