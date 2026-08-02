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


func test_house_profiles_deterministic_and_diverse() -> void:
	var a := DemandModel.house_profile(Vector2i(5, 5))
	var b := DemandModel.house_profile(Vector2i(5, 5))
	assert_str(a["archetype"]).is_equal(b["archetype"])
	assert_float(a["pv_kwp"]).is_equal_approx(b["pv_kwp"], 0.0001)
	assert_bool(a["has_ev"]).is_equal(b["has_ev"])
	# distribution over a block of lots: shares near the fleet constants,
	# PV sizes inside the 5-15 band, several distinct archetypes
	var evs := 0
	var pvs := 0
	var archetypes := {}
	for x in 20:
		for y in 20:
			var p := DemandModel.house_profile(Vector2i(x, y))
			evs += 1 if p["has_ev"] else 0
			pvs += 1 if p["has_pv"] else 0
			archetypes[p["archetype"]] = true
			if p["has_pv"]:
				assert_float(p["pv_kwp"]).is_between(
					DemandModel.PV_KWP_MIN, DemandModel.PV_KWP_MAX)
	assert_float(evs / 400.0).is_between(0.4, 0.6)
	assert_float(pvs / 400.0).is_between(0.3, 0.5)
	assert_int(archetypes.size()).is_greater(4)


func test_house_ev_block_is_full_charger_power() -> void:
	# find an EV house and a non-EV house; the EV one must show a real
	# 22-kW block on top of its base in the evening, the other never
	var ev_pos := Vector2i(-1, -1)
	var plain_pos := Vector2i(-1, -1)
	for x in 40:
		var p := DemandModel.house_profile(Vector2i(x, 0))
		if p["has_ev"] and ev_pos.x < 0:
			ev_pos = Vector2i(x, 0)
		if not p["has_ev"] and plain_pos.x < 0:
			plain_pos = Vector2i(x, 0)
	var ev_profile := DemandModel.house_profile(ev_pos)
	var plain_profile := DemandModel.house_profile(plain_pos)
	var ev_max := 0.0
	var plain_max := 0.0
	for q in 96:
		var t := 301 * 96 + q
		ev_max = maxf(ev_max, DemandModel.house_ev_kw(ev_profile, t))
		plain_max = maxf(plain_max,
			DemandModel.house_ev_kw(plain_profile, t))
	assert_float(ev_max).is_equal_approx(DemandModel.EV_CHARGER_KW, 0.001)
	assert_float(plain_max).is_equal_approx(0.0, 0.001)


func test_zone_sum_matches_expectation_at_scale() -> void:
	# physics tier: many sampled households must average back to the
	# diversified expectation the balancing was designed around
	var tiles: Array = []
	for x in 20:
		for y in 20:
			tiles.append(Vector2i(x + 100, y + 100))
	for hour: float in [3.0, 12.5, 19.0]:
		var t := 301 * 96 + int(hour * 4.0)
		var summed := DemandModel.zone_sum_kw(tiles, t)
		var expected := DemandModel.zone_demand_kw(tiles.size(), t)
		assert_float(summed).is_between(expected - absf(expected) * 0.2 - 8.0,
			expected + absf(expected) * 0.2 + 8.0)


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
