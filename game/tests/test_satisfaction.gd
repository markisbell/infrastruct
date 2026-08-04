extends GdUnitTestSuite
## SatisfactionModel (Phase-2 extraction): hurt/recovery memory per network
## and the temperature-weighted happiness blend with empty-network
## exclusion — constants pinned so a balance change is a conscious commit.


func test_full_power_outage_step_hurts_nine_points() -> void:
	var model := SatisfactionModel.new()
	model.apply_step("power", 1.0)
	assert_float(float(model.values["power"])).is_equal_approx(91.0, 0.0001)


func test_clean_step_recovers_slowly() -> void:
	var model := SatisfactionModel.new()
	model.values["power"] = 50.0
	model.apply_step("power", 0.0)
	assert_float(float(model.values["power"])).is_equal_approx(50.06, 0.0001)
	# weeks-scale memory: one day of clean supply is ~6 points
	for _step in 95:
		model.apply_step("power", 0.0)
	assert_float(float(model.values["power"])).is_equal_approx(55.76, 0.001)


func test_water_hurts_hardest_and_recovers_slowest() -> void:
	var model := SatisfactionModel.new()
	model.apply_step("water", 1.0)
	assert_float(float(model.values["water"])).is_equal_approx(88.0, 0.0001)
	model.values["water"] = 50.0
	model.apply_step("water", 0.0)
	assert_float(float(model.values["water"])).is_equal_approx(50.048, 0.0001)


func test_heat_hurt_scales_with_cold_severity() -> void:
	var frosty := SatisfactionModel.new()
	frosty.apply_step("heat", 1.0, 1.25)   # deep-winter cold factor cap
	assert_float(float(frosty.values["heat"])).is_equal_approx(91.25, 0.0001)
	var mild := SatisfactionModel.new()
	mild.apply_step("heat", 1.0, 0.15)     # July outage: a shrug
	assert_float(float(mild.values["heat"])).is_equal_approx(98.95, 0.0001)


func test_values_clamp_to_bounds() -> void:
	var model := SatisfactionModel.new()
	for _step in 20:
		model.apply_step("water", 1.0)
	assert_float(float(model.values["water"])).is_equal(0.0)
	for _step in 3:
		model.apply_step("power", 0.0)
	assert_float(float(model.values["power"])).is_equal(100.0)


func test_happiness_blend_weights_and_exclusion() -> void:
	var model := SatisfactionModel.new()
	model.values = {"power": 100.0, "heat": 100.0, "water": 0.0}
	var all_active := {"power": true, "heat": true, "water": true}
	# at 18 °C: cold_norm = 0.15/1.25 = 0.12, heat weight = 0.3*0.34 = 0.102
	var blended := model.happiness(18.0, all_active)
	assert_float(blended).is_equal_approx(
		100.0 * (0.25 + 0.102) / (0.25 + 0.102 + 0.45), 0.001)
	# a dead water network EXCLUDED from the blend no longer drags it down
	var no_water := model.happiness(18.0,
		{"power": true, "heat": true, "water": false})
	assert_float(no_water).is_equal_approx(100.0, 0.0001)


func test_happiness_cold_raises_heat_weight() -> void:
	var model := SatisfactionModel.new()
	model.values = {"power": 100.0, "heat": 0.0, "water": 100.0}
	var active := {"power": true, "heat": true, "water": true}
	# the same dead heat network hurts MORE at -20 than at +30
	assert_float(model.happiness(-20.0, active)) \
		.is_less(model.happiness(30.0, active))


func test_happiness_nothing_active_returns_sentinel() -> void:
	var model := SatisfactionModel.new()
	assert_float(model.happiness(10.0,
		{"power": false, "heat": false, "water": false})).is_equal(-1.0)
