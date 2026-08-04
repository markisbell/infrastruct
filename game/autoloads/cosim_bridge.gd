extends Node
## CosimBridge — the single game↔solver surface (ROADMAP §2.3, contract v1).
## Control plane over HTTP (handshake, net/reset, net/patch); step channel over
## a persistent WebSocket /gb/ws per backend (ADR-003), with the HTTP step as
## automatic fallback while the socket is down.

signal handshake_completed(id: String, ok: bool, info: Dictionary)

## The game NEEDS 1.1 features (solved edges, water device rows, signed
## power demand) — a backend speaking only 1.0 is refused at handshake.
const EXPECTED_CONTRACT := "1.1"
const STEP_TIMEOUT_S := 60.0  # first solve after net load pays the numba JIT
const WS_CONNECT_TIMEOUT_S := 5.0

## id -> /gb/version payload of successfully handshaken backends
var info := {}
## id -> {peer: WebSocketPeer, pending: bool, buffer: String}
var _ws := {}


func _process(_delta: float) -> void:
	for id: String in _ws:
		var ws: Dictionary = _ws[id]
		var peer: WebSocketPeer = ws["peer"]
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				ws["buffer"] = peer.get_packet().get_string_from_utf8()


func base_url(id: String) -> String:
	return "http://127.0.0.1:%d" % SidecarManager.port_of(id)


## Contract §2 version rule: identical MAJOR and game-minor <= backend-minor
## (the previous prefix match accepted a 1.0 backend the game can't use).
static func version_ok(game: String, backend: String) -> bool:
	var g := game.split(".")
	var b := backend.split(".")
	if g.size() < 2 or b.size() < 2:
		return false
	if g[0] != b[0] or not g[1].is_valid_int() or not b[1].is_valid_int():
		return false
	return int(g[1]) <= int(b[1])


## GET /gb/version and verify the contract (game refuses on mismatch, §2).
func handshake(id: String) -> bool:
	var response := await _http(id, HTTPClient.METHOD_GET, "/gb/version", "", 10.0)
	var ok: bool = (
		response.get("_status", 0) == 200
		and version_ok(EXPECTED_CONTRACT, str(response.get("contract", "")))
		and response.get("external_clock", false) == true
	)
	if ok:
		info[id] = response
	handshake_completed.emit(id, ok, response)
	return ok


## POST /gb/net/reset with a topology document (contract §3.1).
func net_reset(id: String, topology: Dictionary) -> Dictionary:
	_ws_close(id)  # a reset invalidates any half-open step channel
	return await _http(id, HTTPClient.METHOD_POST, "/gb/net/reset",
		JSON.stringify(topology), 120.0)  # includes the JIT warmup solve


## POST /gb/net/patch with an op array (contract §3.2).
func net_patch(id: String, ops: Array) -> Dictionary:
	return await _http(id, HTTPClient.METHOD_POST, "/gb/net/patch",
		JSON.stringify(ops), 30.0)


## Step the backend: WS when open (ADR-003), HTTP fallback otherwise.
## Returns the contract step-result; {"_status": 0, ...} on transport failure.
func step(id: String, request: Dictionary) -> Dictionary:
	var body := JSON.stringify(request)
	if await _ws_ensure_open(id):
		var response := await _ws_roundtrip(id, body)
		if not response.is_empty():
			response["_status"] = 200
			response["_transport"] = "ws"
			return response
		_ws_close(id)  # broken socket — fall back to HTTP for this step
	var http_response := await _http(id, HTTPClient.METHOD_POST, "/gb/step",
		body, STEP_TIMEOUT_S)
	http_response["_transport"] = "http"
	return http_response


func drop(id: String) -> void:
	_ws_close(id)
	info.erase(id)


# ─── WebSocket step channel ───

func _ws_ensure_open(id: String) -> bool:
	if _ws.has(id):
		var state: int = _ws[id]["peer"].get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			return true
		_ws_close(id)
	var peer := WebSocketPeer.new()
	var url := "ws://127.0.0.1:%d/gb/ws" % SidecarManager.port_of(id)
	if peer.connect_to_url(url) != OK:
		return false
	_ws[id] = {"peer": peer, "pending": false, "buffer": ""}
	var deadline := Time.get_ticks_msec() + int(WS_CONNECT_TIMEOUT_S * 1000)
	while peer.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		if Time.get_ticks_msec() > deadline:
			_ws_close(id)
			return false
		await get_tree().process_frame  # _process polls the peer
	return peer.get_ready_state() == WebSocketPeer.STATE_OPEN


func _ws_roundtrip(id: String, body: String) -> Dictionary:
	var ws: Dictionary = _ws[id]
	ws["buffer"] = ""
	if ws["peer"].send_text(body) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + int(STEP_TIMEOUT_S * 1000)
	while ws["buffer"] == "":
		if Time.get_ticks_msec() > deadline:
			return {}
		if ws["peer"].get_ready_state() != WebSocketPeer.STATE_OPEN:
			return {}
		await get_tree().process_frame
	var parsed: Variant = JSON.parse_string(ws["buffer"])
	return parsed if parsed is Dictionary else {}


func _ws_close(id: String) -> void:
	if _ws.has(id):
		_ws[id]["peer"].close()
		_ws.erase(id)


# ─── HTTP control plane ───

func _http(id: String, method: int, path: String, body: String,
		timeout_s: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout_s
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/json"]) \
		if body != "" else PackedStringArray()
	var err := http.request(base_url(id) + path, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"_status": 0, "_error": "request() failed: %d" % err}
	var result: Array = await http.request_completed
	http.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		return {"_status": 0, "_error": "transport error: %d" % result[0]}
	var parsed: Variant = JSON.parse_string(
		(result[3] as PackedByteArray).get_string_from_utf8())
	var out: Dictionary = parsed if parsed is Dictionary else {}
	out["_status"] = result[1]
	return out
