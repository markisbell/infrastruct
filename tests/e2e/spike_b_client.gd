extends SceneTree
## Spike B client: measures game->backend round-trip latency over
## (a) HTTP keep-alive (HTTPClient) and (b) WebSocket (WebSocketPeer),
## 1000 sequential /gb/step calls each, realistic payload (~100 zones).
##
## Run headless:
##   godot --headless --path game -s res://../tests/e2e/spike_b_client.gd -- --out=<path>
## (stub_backend.py must be running on 127.0.0.1:8123)

const HOST := "127.0.0.1"
const PORT := 8123
const N_CALLS := 1000
const N_ZONES := 100


func _initialize() -> void:
	var out_path := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")

	var http_stats: Dictionary = _bench_http()
	var ws_stats: Dictionary = _bench_ws()
	var report := {"http_keepalive": http_stats, "websocket": ws_stats}
	print("SPIKE_B_REPORT ", JSON.stringify(report))
	if not out_path.is_empty():
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	var ok: bool = http_stats.get("ok", false) and ws_stats.get("ok", false)
	quit(0 if ok else 1)


func _step_payload(t: int) -> String:
	var zone_demand := {}
	for i in N_ZONES:
		zone_demand["z%d" % i] = {"p_kw": 120.0 + i}
	return JSON.stringify({
		"t": t,
		"dt_s": 900,
		"weather": {"wind_ms": 6.2, "ghi_wm2": 410.0, "temp_c": 12.5},
		"zone_demand": zone_demand,
		"coupling_in": {"hp1": 80.0},
		"device_setpoints": {},
	})


func _stats(times_usec: Array[float], ok: bool) -> Dictionary:
	if times_usec.is_empty():
		return {"ok": false, "error": "no samples"}
	var sorted := times_usec.duplicate()
	sorted.sort()
	var total := 0.0
	for v: float in times_usec:
		total += v
	return {
		"ok": ok,
		"calls": times_usec.size(),
		"avg_ms": total / times_usec.size() / 1000.0,
		"p50_ms": sorted[int(sorted.size() * 0.50)] / 1000.0,
		"p99_ms": sorted[mini(int(sorted.size() * 0.99), sorted.size() - 1)] / 1000.0,
		"worst_ms": sorted[-1] / 1000.0,
	}


func _bench_http() -> Dictionary:
	var http := HTTPClient.new()
	http.connect_to_host(HOST, PORT)
	while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		http.poll()
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "error": "connect failed, status %d" % http.get_status()}

	var times: Array[float] = []
	var ok := true
	var headers := ["Content-Type: application/json"]
	for i in N_CALLS:
		var body := _step_payload(i)
		var t0 := Time.get_ticks_usec()
		http.request(HTTPClient.METHOD_POST, "/gb/step", headers, body)
		while http.get_status() == HTTPClient.STATUS_REQUESTING:
			http.poll()
		if not http.has_response():
			ok = false
			break
		var response := PackedByteArray()
		while http.get_status() == HTTPClient.STATUS_BODY:
			http.poll()
			response.append_array(http.read_response_body_chunk())
		times.append(float(Time.get_ticks_usec() - t0))
		if i == 0:
			var parsed: Variant = JSON.parse_string(response.get_string_from_utf8())
			ok = parsed != null and parsed.get("status", "") == "converged"
	http.close()
	return _stats(times, ok)


func _bench_ws() -> Dictionary:
	var ws := WebSocketPeer.new()
	ws.connect_to_url("ws://%s:%d/ws" % [HOST, PORT])
	var deadline := Time.get_ticks_msec() + 5000
	while ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		ws.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "error": "ws connect timeout"}
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return {"ok": false, "error": "ws not open"}

	var times: Array[float] = []
	var ok := true
	for i in N_CALLS:
		var body := _step_payload(i)
		var t0 := Time.get_ticks_usec()
		ws.send_text(body)
		var got := false
		var call_deadline := Time.get_ticks_msec() + 5000
		while not got:
			ws.poll()
			if ws.get_available_packet_count() > 0:
				var resp := ws.get_packet().get_string_from_utf8()
				times.append(float(Time.get_ticks_usec() - t0))
				if i == 0:
					var parsed: Variant = JSON.parse_string(resp)
					ok = parsed != null and parsed.get("status", "") == "converged"
				got = true
			elif Time.get_ticks_msec() > call_deadline:
				ok = false
				break
		if not ok and times.size() < i + 1:
			break
	ws.close()
	return _stats(times, ok)
