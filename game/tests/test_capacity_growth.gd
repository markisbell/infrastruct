extends GdUnitTestSuite
## CapacitySignals threshold table + GrowthModel decision rules (Phase-2
## extractions): the warn/crit boundaries and growth gates, pinned.


func test_line_levels() -> void:
	assert_str(CapacitySignals.line_level(79.9)).is_equal("")
	assert_str(CapacitySignals.line_level(80.0)).is_equal("warn")
	assert_str(CapacitySignals.line_level(94.9)).is_equal("warn")
	assert_str(CapacitySignals.line_level(95.0)).is_equal("crit")


func test_trafo_levels_and_trip_override() -> void:
	assert_str(CapacitySignals.trafo_level(69.9, false)).is_equal("")
	assert_str(CapacitySignals.trafo_level(70.0, false)).is_equal("warn")
	assert_str(CapacitySignals.trafo_level(90.0, false)).is_equal("crit")
	# a tripped substation is critical no matter the (zeroed) loading
	assert_str(CapacitySignals.trafo_level(0.0, true)).is_equal("crit")


func test_grid_levels() -> void:
	assert_str(CapacitySignals.grid_level(79.9)).is_equal("")
	assert_str(CapacitySignals.grid_level(80.0)).is_equal("warn")
	assert_str(CapacitySignals.grid_level(95.0)).is_equal("crit")


func test_heat_levels_margin_and_no_sample() -> void:
	assert_str(CapacitySignals.heat_level(64.0, 60.0)).is_equal("")   # min+4
	assert_str(CapacitySignals.heat_level(63.9, 60.0)).is_equal("warn")
	assert_str(CapacitySignals.heat_level(59.9, 60.0)).is_equal("crit")
	assert_str(CapacitySignals.heat_level(0.0, 60.0)).is_equal("")    # no sample
	assert_str(CapacitySignals.heat_level(-1.0, 60.0)).is_equal("")


func test_water_levels_and_no_sample() -> void:
	assert_str(CapacitySignals.water_level(2.4)).is_equal("")
	assert_str(CapacitySignals.water_level(2.39)).is_equal("warn")
	assert_str(CapacitySignals.water_level(1.99)).is_equal("crit")
	assert_str(CapacitySignals.water_level(-1.0)).is_equal("")        # no sample


func test_growth_interval_tiers_and_difficulty() -> void:
	assert_int(GrowthModel.growth_interval(95.0, 1.0)).is_equal(4)
	assert_int(GrowthModel.growth_interval(80.0, 1.0)).is_equal(8)
	assert_int(GrowthModel.growth_interval(65.0, 1.0)).is_equal(16)
	assert_int(GrowthModel.growth_interval(59.9, 1.0)).is_equal(0)  # stalled
	# difficulty scales but never divides to zero
	assert_int(GrowthModel.growth_interval(95.0, 2.0)).is_equal(2)
	assert_int(GrowthModel.growth_interval(95.0, 8.0)).is_equal(1)
	assert_int(GrowthModel.growth_interval(59.9, 2.0)).is_equal(0)


func test_margin_gate_blocks_failed_hot_lines_and_full_slack() -> void:
	var healthy := {"status": "converged",
		"edges": {"L1": {"loading_percent": 60.0}},
		"devices": {"gc_1": {"output_kw": 10_000.0}}}
	assert_bool(GrowthModel.margin_ok(healthy, 20_000.0, "gc_1")).is_true()
	assert_bool(GrowthModel.margin_ok({"status": "failed"}, 20_000.0, "")) \
		.is_false()
	var hot_line := {"status": "converged",
		"edges": {"L1": {"loading_percent": 95.1}}}
	assert_bool(GrowthModel.margin_ok(hot_line, 20_000.0, "")).is_false()
	var full_slack := {"status": "converged", "edges": {},
		"devices": {"gc_1": {"output_kw": 17_001.0}}}
	assert_bool(GrowthModel.margin_ok(full_slack, 20_000.0, "gc_1")).is_false()
	# no grid connection at all: only lines/status gate
	assert_bool(GrowthModel.margin_ok(full_slack, 20_000.0, "")).is_true()


func test_abandon_victim_prefers_worst_outage_zone() -> void:
	var houses := [Vector2i(1, 1), Vector2i(2, 2), Vector2i(3, 3)]
	var zones := {Vector2i(1, 1): "z_a", Vector2i(2, 2): "z_b",
		Vector2i(3, 3): "z_b"}
	var outages := {"z_a": 30, "z_b": 240}
	# first house of the WORST zone, in sorted order
	assert_that(GrowthModel.abandon_victim(houses, zones, outages)) \
		.is_equal(Vector2i(2, 2))
	# no outage record: deterministic first house
	assert_that(GrowthModel.abandon_victim(houses, zones, {})) \
		.is_equal(Vector2i(1, 1))
	# worst zone has no (remaining) houses: fall back to the first
	assert_that(GrowthModel.abandon_victim(houses, zones, {"z_gone": 999})) \
		.is_equal(Vector2i(1, 1))
