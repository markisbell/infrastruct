extends GdUnitTestSuite
## DispatchPolicy (Phase-2 extraction): battery peak-shave EMA, heat
## storage day windows, gas residual coverage, pump/well gates.


static func _t(day: int, hour: float) -> int:
	return day * 96 + int(hour * 4.0)


func test_ema_seeds_with_first_demand_then_tracks_slowly() -> void:
	var policy := DispatchPolicy.new()
	# first call: EMA = demand, shave 0 (nothing above its own average)
	assert_float(policy.battery_shave_kw(0, 100.0, 1)).is_equal(0.0)
	assert_float(policy.peak_ema).is_equal(100.0)
	# a spike discharges: shave = demand - EMA (EMA barely moved at 1/96)
	var shave := policy.battery_shave_kw(1, 196.0, 1)
	assert_float(policy.peak_ema).is_equal_approx(101.0, 0.0001)
	assert_float(shave).is_equal_approx(95.0, 0.0001)
	# below-average demand RECHARGES (negative shave)
	assert_float(policy.battery_shave_kw(2, 50.0, 1)).is_less(0.0)


func test_ema_updates_once_per_step_and_splits_across_batteries() -> void:
	var policy := DispatchPolicy.new()
	policy.battery_shave_kw(0, 100.0, 1)
	# same t asked twice (power register + step): EMA must not double-move
	policy.battery_shave_kw(1, 200.0, 1)
	var ema_after := policy.peak_ema
	policy.battery_shave_kw(1, 200.0, 1)
	assert_float(policy.peak_ema).is_equal(ema_after)
	# two batteries split the shave (evaluate BEFORE reading the moved EMA);
	# zero batteries must not divide by zero
	var split := policy.battery_shave_kw(2, 200.0, 2)
	assert_float(split).is_equal_approx((200.0 - policy.peak_ema) / 2.0, 0.0001)
	policy.battery_shave_kw(3, 200.0, 0)  # no crash, full residual


func test_battery_clamps_to_p_max_both_directions() -> void:
	assert_float(DispatchPolicy.battery_p_kw(900.0, 400.0)).is_equal(400.0)
	assert_float(DispatchPolicy.battery_p_kw(-900.0, 400.0)).is_equal(-400.0)
	assert_float(DispatchPolicy.battery_p_kw(120.0, 400.0)).is_equal(120.0)
	assert_float(DispatchPolicy.battery_p_kw(120.0, 0.0)).is_equal(0.0)  # down


func test_gas_covers_residual_never_negative_never_above_rating() -> void:
	assert_float(DispatchPolicy.gas_p_kw(1_500.0, 2_000.0, false)).is_equal(1_500.0)
	assert_float(DispatchPolicy.gas_p_kw(3_000.0, 2_000.0, false)).is_equal(2_000.0)
	# renewables exceeding demand: gas idles instead of going negative
	assert_float(DispatchPolicy.gas_p_kw(-500.0, 2_000.0, false)).is_equal(0.0)
	assert_float(DispatchPolicy.gas_p_kw(1_500.0, 2_000.0, true)).is_equal(0.0)


func test_heat_storage_windows() -> void:
	# 00-05 h: charge at full power
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 2.0), 100.0, 500.0)) \
		.is_equal(-100.0)
	# 06-10 h: discharge, capped at 0.6x live demand (hydraulic feasibility)
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 7.0), 100.0, 500.0)) \
		.is_equal(100.0)
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 7.0), 100.0, 50.0)) \
		.is_equal(30.0)
	# boundary hours: 05 and 10-23 idle
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 5.0), 100.0, 500.0)) \
		.is_equal(0.0)
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 10.0), 100.0, 500.0)) \
		.is_equal(0.0)
	assert_float(DispatchPolicy.storage_heat_q_kw(_t(1, 18.0), 100.0, 500.0)) \
		.is_equal(0.0)


func test_pump_gate_needs_all_three() -> void:
	assert_bool(DispatchPolicy.pump_enabled(true, false, true)).is_true()
	assert_bool(DispatchPolicy.pump_enabled(false, false, true)).is_false()  # blackout
	assert_bool(DispatchPolicy.pump_enabled(true, true, true)).is_false()   # down
	assert_bool(DispatchPolicy.pump_enabled(true, false, false)).is_false() # no cable


func test_well_yield_follows_drought_and_downtime() -> void:
	assert_float(DispatchPolicy.well_yield(1.0, false)).is_equal(1.0)
	assert_float(DispatchPolicy.well_yield(0.15, false)).is_equal(0.15)
	assert_float(DispatchPolicy.well_yield(1.0, true)).is_equal(0.0)


func test_reset_reseeds_the_ema() -> void:
	var policy := DispatchPolicy.new()
	policy.battery_shave_kw(0, 100.0, 1)
	policy.reset()
	assert_float(policy.battery_shave_kw(50, 400.0, 1)).is_equal(0.0)
	assert_float(policy.peak_ema).is_equal(400.0)
