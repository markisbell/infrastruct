extends GdUnitTestSuite
## Telemetry rings for the click-inspector graphs: day slots, rollover
## (today becomes yesterday), gap handling, and the step-after readout.


func before_test() -> void:
	City.reset_for_scenario(42)


func after_test() -> void:
	City.reset_for_scenario(42)


func test_today_slots_and_rollover() -> void:
	for t in 96:
		City._telemetry_put("x", t, float(t))
	assert_float(float(City.telemetry["x"]["today"][95])).is_equal(95.0)
	City._telemetry_put("x", 96, 123.0)  # midnight: today -> yesterday
	assert_float(float(City.telemetry["x"]["yesterday"][95])).is_equal(95.0)
	assert_float(float(City.telemetry["x"]["today"][0])).is_equal(123.0)
	assert_bool(is_nan(float(City.telemetry["x"]["today"][1]))).is_true()


func test_day_gap_blanks_yesterday() -> void:
	City._telemetry_put("y", 10, 1.0)
	City._telemetry_put("y", 5 * 96 + 10, 2.0)  # clock jumped several days
	assert_bool(is_nan(float(City.telemetry["y"]["yesterday"][10]))).is_true()
	assert_float(float(City.telemetry["y"]["today"][10])).is_equal(2.0)


func test_step_after_readout() -> void:
	var samples := []
	samples.resize(96)
	samples.fill(NAN)
	samples[0] = 5.0
	samples[40] = 9.0
	# on sample 40's plateau
	assert_float(ProfileGraph._value_at(samples, 40.0 / 95.0)).is_equal(9.0)
	# between samples: walks back to the last filled one
	assert_float(ProfileGraph._value_at(samples, 20.0 / 95.0)).is_equal(5.0)
