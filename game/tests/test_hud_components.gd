extends GdUnitTestSuite
## Phase-6 hud componentization: the pure pieces — popup placement
## clamping, the InspectorConfig tables, the sampled-house series
## builder, ProfileGraph's y-range rules, money formatting, and a
## palette-table validation sweep.


func test_popup_position_anchors_to_top_right_and_clamps() -> void:
	var anchor := Rect2(100, 400, 50, 40)  # element mid-screen
	var panel := Vector2(400, 250)
	var vp := Vector2(1600, 900)
	# bottom-left of the panel lands at the element's top-right + gap
	assert_that(Hud.popup_position(anchor, panel, vp)) \
		.is_equal(Vector2(160.0, 140.0))
	# clamped: y never above the 48px status bar…
	assert_float(Hud.popup_position(Rect2(100, 10, 50, 40), panel, vp).y) \
		.is_equal(48.0)
	# …and the panel stays fully on screen at the right edge (the y axis
	# opens upward from the anchor, so bottom clamping cannot trigger for
	# an on-screen element)
	var edge := Hud.popup_position(Rect2(1500, 850, 50, 40), panel, vp)
	assert_float(edge.x).is_equal(1600.0 - 400.0 - 8.0)
	assert_float(edge.y).is_equal(850.0 - 250.0 - 10.0)


func test_inspector_config_tables() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	# grid connection: the default 20-MVA station is uncapped in the graph
	# (a 10-MVA line would flatten the curve), an override draws the limit
	var stock := InspectorConfig.config_for("grid_connection", "gc_1", model, -1.0)
	assert_array(stock["limits"]).is_empty()
	var capped := InspectorConfig.config_for("grid_connection", "gc_1", model, 140.0)
	assert_int((capped["limits"] as Array).size()).is_equal(1)
	assert_float(float(capped["limits"][0]["value"])).is_equal(140.0)
	# substation: loading series keyed by trafo:<id> with the rating limit
	var sub_id := model.place_building("substation", Vector2i(5, 5), 0)
	var sub := InspectorConfig.config_for("substation", sub_id, model, -1.0)
	assert_str(sub["series"][0]["key"]).is_equal("trafo:" + sub_id)
	assert_str(sub["unit"]).is_equal("%")
	# storages share the SoC convention
	var battery := InspectorConfig.config_for("battery", "b1", model, -1.0)
	assert_str(battery["series"][0]["key"]).is_equal("soc:b1")
	# unknown kinds carry no panel
	assert_bool(InspectorConfig.config_for("house", "x", model, -1.0).is_empty()) \
		.is_true()


func test_house_config_is_deterministic_and_complete() -> void:
	var weather := WeatherSystem.new(42)
	var a := InspectorConfig.house_config(Vector2i(30, 40), 3, weather, "z_sub_1")
	var b := InspectorConfig.house_config(Vector2i(30, 40), 3, weather, "z_sub_1")
	var config: Dictionary = a["config"]
	assert_int((config["series"] as Array).size()).is_equal(4)
	for entry: Dictionary in config["series"]:
		assert_int((entry["values"] as Array).size()).is_equal(96)
	assert_that(a["config"]["series"][0]["values"]) \
		.is_equal(b["config"]["series"][0]["values"])
	assert_str(str(a["subtitle"])).contains("z_sub_1")
	# secondary axis: water in L/h, never sharing the kW axis
	assert_str(config["secondary"]["unit"]).is_equal("L/h")
	var uncovered := InspectorConfig.house_config(Vector2i(30, 40), 3, weather, "")
	assert_str(str(uncovered["subtitle"])).contains("no substation coverage")


func test_profile_graph_y_range_rules() -> void:
	# base_zero anchors all-positive data at 0 with headroom only
	var anchored := ProfileGraph.y_range([2.0, 5.0] as Array[float], true)
	assert_float(anchored.x).is_equal(0.0)
	assert_float(anchored.y).is_equal_approx(5.4, 0.0001)
	# negatives are never clipped away, padded both ways
	var signed_range := ProfileGraph.y_range([-3.0, 5.0] as Array[float], true)
	assert_float(signed_range.x).is_less(-3.0)
	assert_float(signed_range.y).is_greater(5.0)
	# a flat nonzero line still gets a visible band
	var flat := ProfileGraph.y_range([4.0, 4.0] as Array[float], false)
	assert_float(flat.y - flat.x).is_greater(0.0)
	# empty data: the 0..1 default band
	var empty_range := ProfileGraph.y_range([] as Array[float], true)
	assert_float(empty_range.x).is_equal(0.0)
	assert_float(empty_range.y).is_greater(1.0)


func test_fmt_money_dots_thousands() -> void:
	assert_str(Hud._fmt_money(0)).is_equal("0")
	assert_str(Hud._fmt_money(999)).is_equal("999")
	assert_str(Hud._fmt_money(1234)).is_equal("1.234")
	assert_str(Hud._fmt_money(1234567)).is_equal("1.234.567")


func test_palette_table_is_consistent() -> void:
	var hud := Hud.new()
	var tools_seen := {}
	var keys_seen := {}
	for cat: Dictionary in hud._build_items():
		for item: Dictionary in cat["items"]:
			var label: String = item["label"]
			for field: String in ["tool", "label", "mono", "key", "desc"]:
				assert_bool(item.has(field)) \
					.override_failure_message(label + " missing " + field).is_true()
			# a palette entry names either a building kind or its own color+cost
			if item.has("kind"):
				assert_bool(BuildingDefs.get_def(item["kind"]).is_empty()) \
					.override_failure_message(label + ": unknown kind").is_false()
			else:
				assert_bool(item.has("color") and item.has("cost")) \
					.override_failure_message(label + " needs color+cost").is_true()
			assert_bool(tools_seen.has(item["tool"])) \
				.override_failure_message(label + ": duplicate tool").is_false()
			tools_seen[item["tool"]] = true
			assert_bool(keys_seen.has(item["key"])) \
				.override_failure_message(label + ": duplicate hotkey").is_false()
			keys_seen[item["key"]] = true
	hud.free()
