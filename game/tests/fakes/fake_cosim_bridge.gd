class_name FakeCosimBridge
extends RefCounted
## Scripted, request-recording CosimBridge double (Phase-4 refactor plan)
## for Orchestrator suites. IN-PROCESS ONLY: it bypasses the JSON wire
## float coercion, so the Python contract suite remains the wire
## authority — this fake exists to test orchestration logic (one-step
## lag, missed-step counting, coupling routing, wire-t resync, recovery),
## never the wire shape.

var requests: Array[Dictionary] = []   # {id, request} in dispatch order
var resets: Array[Dictionary] = []     # {id, topology}
var dropped: Array[String] = []
var handshakes: Array[String] = []
var handshake_ok := true
var reset_ok := true
## id -> Callable(request: Dictionary) -> Dictionary step-result
var step_handlers := {}
## while > 0, step() awaits that many process frames before answering —
## holds a step IN FLIGHT across sim steps (the missed-step rule needs it)
var hold_frames := 0

var _tree: SceneTree


func _init(tree: SceneTree) -> void:
	_tree = tree


func net_reset(id: String, topology: Dictionary) -> Dictionary:
	resets.append({"id": id, "topology": topology})
	if not reset_ok:
		return {"_status": 400, "ok": false}
	return {"_status": 200, "ok": true,
		"n_zones": topology.get("zones", []).size(),
		"n_devices": topology.get("devices", []).size(),
		"warmup_solve_ms": 0.1}


func step(id: String, request: Dictionary) -> Dictionary:
	requests.append({"id": id, "request": request.duplicate(true)})
	while hold_frames > 0:
		hold_frames -= 1
		await _tree.process_frame
	if step_handlers.has(id):
		return (step_handlers[id] as Callable).call(request)
	return converged(int(request["t"]))


func handshake(id: String) -> bool:
	handshakes.append(id)
	return handshake_ok


func drop(id: String) -> void:
	dropped.append(id)


static func converged(t: int, extra: Dictionary = {}) -> Dictionary:
	var result := {"_status": 200, "t": t, "status": "converged",
		"zones": {}, "devices": {}, "coupling_out": {}, "violations": [],
		"solve_ms": 0.1}
	result.merge(extra, true)
	return result
