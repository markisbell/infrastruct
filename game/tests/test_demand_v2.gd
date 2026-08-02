extends GdUnitTestSuite
## DemandModel v2 (Phase 6): the bundled profile pack drives electricity and
## water — seasonal day types, weekend shapes, mean-1.0 normalization; the
## heat formula stays exactly Phase 4.

const STEPS := 96


static func _t(day: int, hour: float) -> int:
	return day * STEPS + int(hour * 4.0)


func test_pack_loads() -> void:
	assert_bool(DemandModel._get_pack().has("elec")).is_true()
	assert_bool(DemandModel._get_pack().has("water")).is_true()


func test_day_kind_and_season() -> void:
	assert_str(DemandModel.day_kind(_t(301, 12))).is_equal("workday")  # 301 % 7 == 0
	assert_str(DemandModel.day_kind(_t(306, 12))).is_equal("saturday")
	assert_str(DemandModel.day_kind(_t(307, 12))).is_equal("sunday")
	assert_str(DemandModel.season_key(_t(301, 0))).is_equal("winter")
	assert_str(DemandModel.season_key(_t(133, 0))).is_equal("summer")
	assert_str(DemandModel.season_key(_t(42, 0))).is_equal("transition")


func test_elec_winter_double_peak() -> void:
	var evening := DemandModel.house_factor(_t(301, 19.0))
	var midday := DemandModel.house_factor(_t(301, 12.5))
	var night := DemandModel.house_factor(_t(301, 3.0))
	assert_float(evening).is_greater(1.4)
	assert_float(night).is_less(0.5)
	assert_float(evening).is_greater(midday * 1.15)


func test_elec_yearly_mean_is_one() -> void:
	# sample a full week per season — composed mean must sit near 1.0
	var acc := 0.0
	var n := 0
	for day: int in [7, 98, 189, 280]:  # one week into each season
		for step in 7 * STEPS:
			acc += DemandModel.house_factor(day * STEPS + step)
			n += 1
	assert_float(acc / n).is_between(0.9, 1.1)


func test_weekend_shape_differs() -> void:
	var diff := 0.0
	for q in STEPS:
		diff += absf(DemandModel.house_factor(_t(301, q / 4.0))
			- DemandModel.house_factor(_t(307, q / 4.0)))
	assert_float(diff).is_greater(3.0)  # sunday is a genuinely different day


func test_pv_park_orientation() -> void:
	# rot 0 = south = EXACTLY the plain availability (pre-existing parks
	# keep their yield); north is starved; east out-produces west in the
	# morning (the curve shifts toward the sun's side of the day)
	var noon := _t(135, 12.5)
	var morning := _t(135, 9.0)
	var south := DemandModel.pv_park_availability(noon, 0)
	assert_float(south).is_equal_approx(DemandModel.pv_availability(noon), 0.0001)
	assert_float(south).is_greater(0.1)
	assert_float(DemandModel.pv_park_availability(noon, 2)).is_less(south * 0.6)
	assert_float(DemandModel.pv_park_availability(morning, 3)) \
		.is_greater(DemandModel.pv_park_availability(morning, 1))


func test_water_summer_exceeds_winter() -> void:
	# same clock hour, seasonal swing + hot-day surcharge
	var summer := DemandModel.water_zone_demand_m3h(10, _t(133, 11.0), 28.0)
	var winter := DemandModel.water_zone_demand_m3h(10, _t(301, 11.0), 0.0)
	assert_float(summer).is_greater(winter * 1.15)


func test_heat_formula_unchanged() -> void:
	# Phase 4 calibration pin on the SPACE-HEATING part: design cold, 12:00
	# (no setback). DHW rides on top via the pack's LPG warm-water shape.
	var expected := 10.0 * (4.0 * 1.0 * 1.0
		+ 0.25 * DemandModel.dhw_factor(_t(301, 12.0)))
	assert_float(DemandModel.heat_zone_demand_kw(10, _t(301, 12.0), -14.0)) \
		.is_equal_approx(expected, 0.001)


func test_dhw_shape_sane() -> void:
	# LPG warm-water shape: composed weekly mean 1.0 (HOUSE_DHW_KW keeps
	# its mean-kW meaning), mornings busier than deep night
	var acc := 0.0
	for day: int in [301, 306, 307]:  # workday, saturday, sunday
		for q in STEPS:
			acc += DemandModel.dhw_factor(day * STEPS + q) \
				* (5.0 if day == 301 else 1.0)
	assert_float(acc / (7.0 * STEPS)).is_between(0.93, 1.07)
	assert_float(DemandModel.dhw_factor(_t(301, 7.5))) \
		.is_greater(DemandModel.dhw_factor(_t(301, 3.0)) * 1.5)
