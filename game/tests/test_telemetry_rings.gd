extends GdUnitTestSuite
## TelemetryRings (Phase-2 extraction): day rollover, NAN gaps, and the
## backwards-restore rule — "yesterday" must never show another day's (or
## the future's) samples. City-level forwarding stays covered by
## test_telemetry.gd.


func test_unfilled_slots_are_nan_gaps() -> void:
	var rings := TelemetryRings.new()
	rings.put("k", 10, 5.0)
	var today: Array = rings.rings["k"]["today"]
	assert_float(float(today[10])).is_equal(5.0)
	assert_bool(is_nan(float(today[9]))).is_true()
	assert_bool(is_nan(float(today[11]))).is_true()
	for slot in 96:
		assert_bool(is_nan(float(rings.rings["k"]["yesterday"][slot]))).is_true()


func test_adjacent_midnight_rollover_keeps_yesterday() -> void:
	var rings := TelemetryRings.new()
	for t in 96:
		rings.put("k", t, float(t))
	rings.put("k", 96, 123.0)  # first slot of day 1
	assert_int(int(rings.rings["k"]["day"])).is_equal(1)
	assert_float(float(rings.rings["k"]["yesterday"][95])).is_equal(95.0)
	assert_float(float(rings.rings["k"]["today"][0])).is_equal(123.0)


func test_forward_day_jump_blanks_yesterday() -> void:
	var rings := TelemetryRings.new()
	rings.put("k", 5 * 96 + 3, 7.0)
	rings.put("k", 9 * 96 + 3, 8.0)  # seek: day 5 -> day 9, not adjacent
	assert_bool(is_nan(float(rings.rings["k"]["yesterday"][3]))).is_true()
	assert_float(float(rings.rings["k"]["today"][3])).is_equal(8.0)


func test_backwards_restore_blanks_yesterday_not_future() -> void:
	# regression rule (refactor plan): restoring the clock to an EARLIER day
	# must not present the abandoned future day as "yesterday"
	var rings := TelemetryRings.new()
	rings.put("k", 5 * 96 + 3, 7.0)   # day 5
	rings.put("k", 3 * 96 + 3, 6.0)   # backwards restore to day 3
	assert_int(int(rings.rings["k"]["day"])).is_equal(3)
	assert_bool(is_nan(float(rings.rings["k"]["yesterday"][3]))).is_true()
	assert_float(float(rings.rings["k"]["today"][3])).is_equal(6.0)


func test_clear_drops_all_keys() -> void:
	var rings := TelemetryRings.new()
	rings.put("a", 0, 1.0)
	rings.put("b", 0, 2.0)
	rings.clear()
	assert_bool(rings.rings.is_empty()).is_true()
