extends GdUnitTestSuite
## Drag-and-draw construction (user-specified UX): plan_path colors the
## ghost (ok/dup/blocked, red from the FIRST blockage on — money included),
## build_path commits exactly the green prefix, and building ghosts carry
## rotation (R) + horizontal flip (F) into the model and saves.


func _path(tiles: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.assign(tiles)
	return out


func test_plan_path_all_clear() -> void:
	City.reset_for_scenario(42)
	var plan := City.plan_path("road", _path([Vector2i(10, 10), Vector2i(11, 10),
		Vector2i(12, 10)]))
	assert_array(plan).is_equal(["ok", "ok", "ok"])
	City.reset_for_scenario(42)


func test_plan_path_red_from_the_blockage_on() -> void:
	City.reset_for_scenario(42)
	City.model.terrain.force_water(Vector2i(12, 10), Vector2i(12, 10))
	var plan := City.plan_path("water", _path([Vector2i(10, 10), Vector2i(11, 10),
		Vector2i(12, 10), Vector2i(13, 10), Vector2i(14, 10)]))
	# tile 3+ are buildable in isolation, but the path is cut at tile 2 —
	# everything from the blockage on shows red (user-specified UX)
	assert_array(plan).is_equal(["ok", "ok", "blocked", "blocked", "blocked"])
	City.reset_for_scenario(42)


func test_plan_path_running_out_of_money_blocks() -> void:
	City.reset_for_scenario(42)
	City.money = 2 * int(BuildingDefs.COSTS["road"]) + 10
	var plan := City.plan_path("road", _path([Vector2i(10, 10), Vector2i(11, 10),
		Vector2i(12, 10), Vector2i(13, 10)]))
	assert_array(plan).is_equal(["ok", "ok", "blocked", "blocked"])
	City.infinite_money = true
	plan = City.plan_path("road", _path([Vector2i(10, 10), Vector2i(11, 10),
		Vector2i(12, 10), Vector2i(13, 10)]))
	assert_array(plan).is_equal(["ok", "ok", "ok", "ok"])
	City.reset_for_scenario(42)


func test_plan_path_existing_tiles_are_free_duplicates() -> void:
	City.reset_for_scenario(42)
	City.model.set_road(Vector2i(11, 10))
	var plan := City.plan_path("road", _path([Vector2i(10, 10), Vector2i(11, 10),
		Vector2i(12, 10)]))
	assert_array(plan).is_equal(["ok", "dup", "ok"])
	City.reset_for_scenario(42)


func test_build_path_commits_only_the_green_prefix() -> void:
	City.reset_for_scenario(42)
	City.model.terrain.force_water(Vector2i(12, 10), Vector2i(12, 10))
	var money_before := City.money
	var built := City.build_path("cable_overhead", _path([Vector2i(10, 10),
		Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)]))
	assert_int(built).is_equal(2)
	assert_bool(City.model.cables.has(Vector2i(10, 10))).is_true()
	assert_bool(City.model.cables.has(Vector2i(11, 10))).is_true()
	assert_bool(City.model.cables.has(Vector2i(13, 10))).is_false()  # after the cut
	assert_int(City.money).is_equal(
		money_before - 2 * int(BuildingDefs.COSTS["overhead_line"]))
	City.reset_for_scenario(42)


func test_blocked_single_builds_no_longer_charge() -> void:
	# validate-then-pay: painting over water used to charge and never refund
	City.reset_for_scenario(42)
	City.model.terrain.force_water(Vector2i(10, 10), Vector2i(10, 10))
	var money_before := City.money
	assert_bool(City.build_road(Vector2i(10, 10))).is_false()
	assert_bool(City.build_water_pipe(Vector2i(10, 10))).is_false()
	assert_int(City.money).is_equal(money_before)
	City.reset_for_scenario(42)


func test_houses_never_grow_on_lines_or_roads() -> void:
	# playtest-monkey findings: a cable dragged over a zoned row, and a road
	# paved over zoning paint, both grew houses ON TOP of infrastructure
	var model := WorldModel.new()
	model.set_road(Vector2i(5, 5))
	model.set_zone(Vector2i(5, 6))
	model.set_cable(Vector2i(5, 6), 1)             # line crosses the lot
	assert_bool(model.spawn_house(Vector2i(5, 6))).is_false()
	assert_array(model.spawn_candidates(Vector2i(5, 6), 5)).is_empty()
	model.set_zone(Vector2i(6, 6))
	assert_bool(model.set_road(Vector2i(6, 6))).is_true()   # paving a zone
	assert_bool(model.zoning.has(Vector2i(6, 6))).is_false()  # zone consumed
	assert_bool(model.spawn_house(Vector2i(6, 6))).is_false()
	assert_int(model.check_invariants().size()).is_equal(0)


func test_building_flip_survives_the_save_roundtrip() -> void:
	var model := WorldModel.new()
	var id := model.place_building("substation", Vector2i(5, 5), 3, {}, true)
	assert_bool(bool(model.buildings[id]["flip"])).is_true()
	var restored := WorldModel.from_json(model.to_json())
	assert_bool(bool(restored.buildings[id]["flip"])).is_true()
	assert_int(int(restored.buildings[id]["rot"])).is_equal(3)
	assert_bool(restored.equals(model)).is_true()
