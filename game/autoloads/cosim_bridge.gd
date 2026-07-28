extends Node
## CosimBridge — the single game↔solver surface (ROADMAP §2.3, ADR-003).
## Phase 1 slice: HTTP control plane (version handshake, /gb/step).
## The persistent WebSocket step channel arrives with contract v1 (Phase 2);
## per ADR-003 the HTTP step path stays as the debugging fallback.

signal handshake_completed(id: String, ok: bool, info: Dictionary)

const EXPECTED_CONTRACT := "0.1"
const STEP_TIMEOUT_S := 60.0  # first solve after net load pays the numba JIT

## id -> /gb/version payload of successfully handshaken backends
var info := {}


func base_url(id: String) -> String:
	return "http://127.0.0.1:%d" % SidecarManager.port_of(id)


## GET /gb/version and verify the contract. The game refuses a backend on
## mismatch (ROADMAP §5 rules).
func handshake(id: String) -> bool:
	var response := await _request(id, HTTPClient.METHOD_GET, "/gb/version", 10.0)
	var ok: bool = (
		response.get("_status", 0) == 200
		and response.get("contract", "") == EXPECTED_CONTRACT
		and response.get("external_clock", false) == true
	)
	if ok:
		info[id] = response
	handshake_completed.emit(id, ok, response)
	return ok


## Advance backend `id` by exactly one step; returns the wire frame
## ({} with "_status" != 200 on failure — the caller maps failures to events).
func step(id: String) -> Dictionary:
	return await _request(id, HTTPClient.METHOD_POST, "/gb/step", STEP_TIMEOUT_S)


## One-shot HTTP request via a transient HTTPRequest node. Sequential-use
## helper — Phase 2's orchestrator owns scheduling so calls never pile up.
func _request(id: String, method: int, path: String, timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	var err := http.request(base_url(id) + path, [], method)
	if err != OK:
		http.queue_free()
		return {"_status": 0, "_error": "request() failed: %d" % err}
	var result: Array = await http.request_completed
	http.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		return {"_status": 0, "_error": "transport error: %d" % result[0]}
	var body: PackedByteArray = result[3]
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var out: Dictionary = parsed if parsed is Dictionary else {}
	out["_status"] = result[1]
	return out
