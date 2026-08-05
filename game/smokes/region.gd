extends SmokeBase
## --smoke=region: real-DEM terrain HEADLESS — until now the baked
## regions were only probed visually (REGION_SHOT screenshots). Load
## kraichgau, find a natural plateau, build a two-network town on it and
## prove registration + solves + that the water junctions carry the
## REGION's elevations (not the flat default).


## First WxH rect whose tiles all share one height level. Real DEM
## relief rarely offers big elevated pads — try relief first, fall back
## to the valley floor (the region pin is map-wide relief + elevations).
static func _find_pad(terrain: Terrain, w: int, h: int) -> Vector2i:
	for want_relief in [true, false]:
		for y in range(30, 220):
			for x in range(30, 220):
				var level := terrain.height(Vector2i(x, y))
				if want_relief and level == 0:
					continue
				var flat := true
				for dx in w:
					for dy in h:
						if terrain.height(Vector2i(x + dx, y + dy)) != level \
								or terrain.is_water(Vector2i(x + dx, y + dy)):
							flat = false
							break
					if not flat:
						break
				if flat:
					return Vector2i(x, y)
	return Vector2i(-1, -1)


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_REGION", "health timeout")
		return
	City.reset_for_scenario(42)
	City.model.terrain.load_region("kraichgau")
	var pad := _find_pad(City.model.terrain, 16, 8)
	if pad.x < 0:
		_fail("SMOKE_REGION", "no flat pad found in kraichgau")
		return
	var level := City.model.terrain.height(pad)
	# the REGION is proven by map-wide relief (kraichgau spans ~26 levels
	# after compression), not by where the town happened to fit
	var max_level := 0
	for sy in range(0, 256, 8):
		for sx in range(0, 256, 8):
			max_level = maxi(max_level,
				City.model.terrain.height(Vector2i(sx, sy)))
	check("map_has_relief", max_level >= 10)

	City.place_building("grid_connection", pad + Vector2i(0, 0))
	for x in range(2, 10):
		City.build_cable(pad + Vector2i(x, 1))
	City.place_building("substation", pad + Vector2i(10, 1))
	for x in range(2, 14):
		City.build_road(pad + Vector2i(x, 3))
	for x in range(2, 14):
		City.build_zone(pad + Vector2i(x, 4))
		City.model.spawn_house(pad + Vector2i(x, 4))
	City.place_building("water_tower", pad + Vector2i(0, 6))
	for x in range(1, 10):
		City.build_water_pipe(pad + Vector2i(x, 6))
	City.place_building("water_station", pad + Vector2i(10, 6))
	City._topo_dirty = true
	if not await _wait_registered(180.0) or not await _wait_water_registered(120.0):
		_fail("SMOKE_REGION", "register timeout")
		return

	# the water junctions must carry the REGION's elevation: base 300 m +
	# level * STEP_M (+ tower height on the tank node)
	var junctions: Array = City.water_topo.doc["native"]["network_structure"]["junctions"]
	var expected := 300.0 + level * Terrain.STEP_M
	var station_elev := -1.0
	for junction: Dictionary in junctions:
		if str(junction["name"]).begins_with("wn_water_station"):
			station_elev = float(junction["elevation_m"])
	check("region_elevation_in_doc", absf(station_elev - expected) < 0.001)

	GameClock.restore({"total_minutes": 10.0 * 60.0, "speed": 0.0})
	Orchestrator.start()
	await _run_steps(6, 240.0)
	check("power_converged",
		City.last_result.get("status", "failed") == "converged")
	check("water_converged",
		City.last_water_result.get("status", "failed") == "converged")
	var zone_id: String = "wz_" + City.model.buildings_of_kind("water_station")[0]
	check("zone_supplied", _water_supplied(zone_id) >= 0.99)

	var report := {"ok": verdict(), "failed": failed_checks(),
		"pad": str(pad), "level": level,
		"station_elevation_m": station_elev}
	print("SMOKE_REGION ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
