class_name FixtureProvider
extends RefCounted
## BoundaryProvider (see Orchestrator) backed by the shared contract fixtures —
## the same files the contract test suite runs, so game e2e and backend tests
## exercise identical topologies and boundary series (single source of truth).
## Superseded for gameplay by the real demand/weather modules (Phase 3);
## kept as the fixture-backed provider for the cosim/cosim-kill smokes.

var fixtures := {}  # network id -> parsed fixture file


static func load_default(repo_root: String) -> FixtureProvider:
	var provider := FixtureProvider.new()
	var dir := repo_root.path_join("tests/contract/fixtures")
	for entry: Array in [["power", "power_fixture.json"], ["heat", "heat_fixture.json"]]:
		var path: String = dir.path_join(entry[1])
		if FileAccess.file_exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				provider.fixtures[entry[0]] = parsed
	return provider


func topology(network: String) -> Dictionary:
	return fixtures.get(network, {}).get("topology", {})


func steps(network: String) -> int:
	return int(fixtures.get(network, {}).get("script", {}).get("steps", 96))


func golden(network: String) -> Dictionary:
	# in the game loop cross-network coupling is live (heat CHP feeds the
	# power net), so physics differ from the standalone contract-suite run —
	# fixtures may carry a dedicated "golden_coupled" section for this case
	var fixture: Dictionary = fixtures.get(network, {})
	return fixture.get("golden_coupled", fixture.get("golden", {}))


func allowed_statuses(network: String) -> Array:
	return fixtures.get(network, {}).get("allowed_statuses", ["converged"])


func get_zone_demand(network: String, t: int) -> Dictionary:
	var out := {}
	var series: Dictionary = fixtures.get(network, {}).get("script", {}) \
		.get("zone_demand_kw", {})
	for zone: String in series:
		out[zone] = {"value": _at(series[zone], t, steps(network))}
	return out


func get_device_setpoints(network: String, t: int) -> Dictionary:
	var out := {}
	var setpoints: Dictionary = fixtures.get(network, {}).get("script", {}) \
		.get("device_setpoints", {})
	for device: String in setpoints:
		var fields: Dictionary = setpoints[device]
		var resolved := {}
		for field: String in fields:
			resolved[field] = _at(fields[field], t, steps(network))
		out[device] = resolved
	return out


func get_weather(t: int) -> Dictionary:
	var out := {"wind_ms": 5.0, "ghi_wm2": 0.0, "temp_c": 10.0}
	for network: String in fixtures:
		var weather: Dictionary = fixtures[network].get("script", {}).get("weather", {})
		for field: String in weather:
			out[field] = _at(weather[field], t, steps(network))
	return out


func _at(series: Variant, t: int, n: int) -> float:
	if series is Dictionary:
		return float(series.get("const", 0.0))
	if series is Array and not (series as Array).is_empty():
		return float(series[t % mini(n, series.size())])
	return 0.0
