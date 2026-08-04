extends SmokeBase
## --smoke=playtest (extracted from main.gd, Phase-3 refactor plan).


## Monkey player (Phase 8 hardening, user request): plays like a human
## through the SAME City APIs the UI calls — seeded random path drags,
## building placements (often deliberately invalid), bulldozing, repairs,
## loans and mid-play save/load roundtrips against the LIVE solvers with
## random events ON — and checks WorldModel invariants + engine health
## after every action. Every reported problem is a bug.
var playtest_seed := 20260730  # main forwards --seed=N


func run() -> void:
	SidecarManager.load_config("orchestration/sidecars_stress.json")
	SidecarManager.start_all()
	if not await _wait_all_healthy(240.0):
		_fail("SMOKE_PLAYTEST", "health timeout")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = playtest_seed
	City.reset_for_scenario(42)
	City.model.terrain.set_seed(19)   # hills + rivers: exercise blocking
	City.model.terrain.force_height(Vector2i(0, 0), Vector2i(45, 25), 0)
	City.money = 500_000
	City.events_enabled = true
	_build_reference_city(8)          # a live town so the solvers have work
	City._topo_dirty = true
	if not await _wait_three_registered(240.0):
		_fail("SMOKE_PLAYTEST", "register timeout")
		return
	var problems: Array[String] = []
	var actions := {"path": 0, "building": 0, "bulldoze": 0, "repair": 0,
		"loan": 0, "saveload": 0, "built_tiles": 0}
	# per-network status counters (gate hardening 2026-08-04: heat/water
	# wedging was undetected — only power was ever counted)
	var statuses := {"power": {}, "heat": {}, "water": {}}
	var count_status := func(net: String, result: Dictionary) -> void:
		var s: String = result.get("status", "?")
		statuses[net][s] = statuses[net].get(s, 0) + 1
	City.power_result.connect(func(_t: int, r: Dictionary) -> void:
		count_status.call("power", r))
	City.heat_result.connect(func(_t: int, r: Dictionary) -> void:
		count_status.call("heat", r))
	City.water_result.connect(func(_t: int, r: Dictionary) -> void:
		count_status.call("water", r))
	var builds: Array[String] = []
	builds.assign(City.PATH_BUILDS.keys())
	var kinds: Array[String] = []
	kinds.assign(BuildingDefs.DEFS.keys())
	var moves: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, 1), Vector2i(0, -1)]

	for burst in 24:
		for action in 8:
			var roll := rng.randf()
			# bias half the actions near the town, half into the wilderness
			var origin := Vector2i(rng.randi_range(4, 40), rng.randi_range(2, 24)) \
				if rng.randf() < 0.5 \
				else Vector2i(rng.randi_range(46, 220), rng.randi_range(26, 220))
			if roll < 0.40:
				var tiles: Array[Vector2i] = [origin]
				var cur := origin
				for i in rng.randi_range(2, 18):
					cur += moves[rng.randi_range(0, 3)]
					tiles.append(cur)
				actions["built_tiles"] += City.build_path(
					builds[rng.randi_range(0, builds.size() - 1)], tiles)
				actions["path"] += 1
			elif roll < 0.60:
				City.place_building(kinds[rng.randi_range(0, kinds.size() - 1)],
					origin, rng.randi_range(0, 3), {}, rng.randf() < 0.5)
				actions["building"] += 1
			elif roll < 0.75:
				City.bulldoze(origin)
				actions["bulldoze"] += 1
			elif roll < 0.85:
				if not City.tripped_tiles.is_empty():
					City.dispatch_repair((City.tripped_tiles.keys())[0])
				elif not City.tripped_substations.is_empty():
					City.dispatch_repair(City.model.buildings[
						(City.tripped_substations.keys())[0]]["anchor"])
				actions["repair"] += 1
			elif roll < 0.95:
				if rng.randf() < 0.5:
					City.take_loan(50_000.0)
				else:
					City.repay_loan(25_000.0)
				actions["loan"] += 1
			else:
				# mid-play save/load: the state must come back UNCHANGED
				# (both sides JSON-normalized — int/float is a wire artifact)
				var path := "user://playtest_save.json"
				SaveGame.save_to(path)
				var norm := func(value: Variant) -> String:
					return JSON.stringify(JSON.parse_string(JSON.stringify(value)))
				var city_a: String = norm.call(City.serialize())
				var model_a: String = City.model.to_json()
				SaveGame.load_from(path)
				if norm.call(City.serialize()) != city_a:
					problems.append("burst %d: save/load changed the city state" % burst)
				if City.model.to_json() != model_a:
					problems.append("burst %d: save/load changed the model" % burst)
				actions["saveload"] += 1
			for violation: String in City.model.check_invariants():
				var line := "burst %d: %s" % [burst, violation]
				if not problems.has(line):  # dedupe repeats per action loop
					problems.append(line)
			if not is_finite(float(City.money)):
				problems.append("burst %d: money is not finite" % burst)
			if problems.size() > 25:
				break
		# let sim time pass; every 4th burst idle past the topo debounce so
		# registration really happens mid-chaos
		GameClock.speed = 60.0
		await get_tree().create_timer(1.0).timeout
		GameClock.pause()
		if burst % 4 == 3:
			await get_tree().create_timer(3.2).timeout
			GameClock.speed = 60.0
			await get_tree().create_timer(2.0).timeout
			GameClock.pause()
		if problems.size() > 25:
			break
	# closing health check: ALL THREE solvers must still be alive and
	# stepping in the FINAL window — a single early power frame used to
	# satisfy a cumulative whole-run count (any status counts as liveness;
	# a monkey-wrecked network may legitimately solve to 'failed')
	var frame_total := func(net: String) -> int:
		var total := 0
		for s: String in statuses[net]:
			total += int(statuses[net][s])
		return total
	await get_tree().create_timer(3.2).timeout
	var closing_base := {"power": frame_total.call("power"),
		"heat": frame_total.call("heat"), "water": frame_total.call("water")}
	GameClock.speed = 60.0
	await get_tree().create_timer(3.0).timeout
	GameClock.pause()
	await get_tree().create_timer(1.0).timeout
	for net: String in closing_base:
		if int(frame_total.call(net)) - int(closing_base[net]) < 1:
			problems.append(net + " solver produced no frames in the closing window")
	var solved := int(statuses["power"].get("converged", 0)) \
		+ int(statuses["power"].get("degraded", 0))
	if solved == 0:
		problems.append("power solver produced no usable frames all run")
	var report := {
		"ok": problems.is_empty(),
		"problems": problems.slice(0, 25),
		"actions": actions, "statuses": statuses,
		"houses": City.model.houses.size(), "money": City.money,
		"tripped_tiles": City.tripped_tiles.size(),
		"orch": Orchestrator.stats,
	}
	print("SMOKE_PLAYTEST ", JSON.stringify(report))
	SidecarManager.stop_all()
	get_tree().quit(0 if report["ok"] else 1)
