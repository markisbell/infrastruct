extends GdUnitTestSuite
## Commercial consumers (commercial pass 2026-08-06): zone-kind paint and
## lot spawning in WorldModel, the three demand signatures (general/food/
## mall) across electricity/heat/water, the charging park's deterministic
## session series, and the 1000-kVA trafo fields.


static func _t(day: int, hour: float) -> int:
	return day * 96 + int(hour * 4.0)


## Game day 3 is a workday, mid-July heat for summer probes: the LPG
## day-kind machinery classifies from the data — probe a known workday.
const WORKDAY := 3
const SUNDAY := 6  # day 6 of the LPG week layout


func test_zone_kinds_gate_what_grows() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.set_road(Vector2i(5, 5))
	model.set_zone(Vector2i(5, 6), WorldModel.ZONE_RESIDENTIAL)
	model.set_zone(Vector2i(6, 5), WorldModel.ZONE_COMMERCIAL)
	# houses only on residential paint, businesses only on commercial
	assert_bool(model.spawn_house(Vector2i(6, 5))).is_false()
	assert_bool(model.spawn_commercial(Vector2i(5, 6),
		WorldModel.COMMERCIAL_FOOD)).is_false()
	assert_bool(model.spawn_house(Vector2i(5, 6))).is_true()
	assert_bool(model.spawn_commercial(Vector2i(6, 5),
		WorldModel.COMMERCIAL_FOOD)).is_true()
	# an occupied lot takes nothing else
	assert_bool(model.spawn_commercial(Vector2i(6, 5),
		WorldModel.COMMERCIAL_MALL)).is_false()
	assert_array(model.check_invariants()).is_empty()


func test_commercial_serialization_round_trip() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.set_road(Vector2i(5, 5))
	model.set_zone(Vector2i(6, 5), WorldModel.ZONE_COMMERCIAL)
	model.spawn_commercial(Vector2i(6, 5), WorldModel.COMMERCIAL_MALL)
	var copy := WorldModel.from_json(model.to_json())
	assert_int(int(copy.commercial.get(Vector2i(6, 5), -1))) \
		.is_equal(WorldModel.COMMERCIAL_MALL)
	assert_int(int(copy.zoning.get(Vector2i(6, 5), -1))) \
		.is_equal(WorldModel.ZONE_COMMERCIAL)
	# old saves without the key load to an empty dict
	var legacy := WorldModel.from_json(JSON.stringify({"version": 5}))
	assert_bool(legacy.commercial.is_empty()).is_true()


func test_demand_matrix_matches_the_user_spec() -> void:
	var pos := Vector2i(40, 40)
	var noon := _t(WORKDAY, 12.0)
	# general production: HIGH elec, low heat and water vs food production
	assert_float(DemandModel.commercial_kw(1, pos, noon)) \
		.is_greater(DemandModel.commercial_kw(2, pos, noon))
	assert_float(DemandModel.commercial_heat_kw(2, pos, noon, 0.0)) \
		.is_greater(DemandModel.commercial_heat_kw(1, pos, noon, 0.0))
	assert_float(DemandModel.commercial_water_m3h(2, pos, noon)) \
		.is_greater(DemandModel.commercial_water_m3h(1, pos, noon))
	# mall: high elec AND water, heat sits between the two producers
	assert_float(DemandModel.commercial_kw(3, pos, noon)) \
		.is_greater(DemandModel.commercial_kw(2, pos, noon))
	assert_float(DemandModel.commercial_water_m3h(3, pos, noon)) \
		.is_greater(DemandModel.commercial_water_m3h(1, pos, noon))
	var mall_heat := DemandModel.commercial_heat_kw(3, pos, noon, 0.0)
	assert_float(mall_heat) \
		.is_greater(DemandModel.commercial_heat_kw(1, pos, noon, 0.0))
	assert_float(DemandModel.commercial_heat_kw(2, pos, noon, 0.0)) \
		.is_greater(mall_heat)


func test_food_heat_is_process_heat_summer_holds() -> void:
	var pos := Vector2i(40, 40)
	var noon := _t(WORKDAY, 12.0)
	# 25 °C summer noon: the dairy still steams (>=80 % of its winter
	# draw), the mall's mostly-space heat collapses
	var food_winter := DemandModel.commercial_heat_kw(2, pos, noon, -5.0)
	var food_summer := DemandModel.commercial_heat_kw(2, pos, noon, 25.0)
	assert_float(food_summer).is_greater(0.8 * food_winter)
	var mall_winter := DemandModel.commercial_heat_kw(3, pos, noon, -5.0)
	var mall_summer := DemandModel.commercial_heat_kw(3, pos, noon, 25.0)
	assert_float(mall_summer).is_less(0.4 * mall_winter)


func test_shift_shapes_night_weekend() -> void:
	var pos := Vector2i(40, 40)
	# night standby is a fraction of the working day
	assert_float(DemandModel.commercial_kw(1, pos, _t(WORKDAY, 3.0))) \
		.is_less(0.25 * DemandModel.commercial_kw(1, pos, _t(WORKDAY, 10.0)))
	# German Sunday: the mall is closed, food production keeps running
	var sunday_noon := 0
	for day in range(4, 11):
		if DemandModel.day_kind(_t(day, 12.0)) == "sunday":
			sunday_noon = _t(day, 12.0)
			break
	if sunday_noon > 0:
		assert_float(DemandModel.commercial_kw(3, pos, sunday_noon)) \
			.is_less(0.3 * DemandModel.commercial_kw(3, pos, _t(WORKDAY, 12.0)))
		assert_float(DemandModel.commercial_kw(2, pos, sunday_noon)) \
			.is_greater(0.5 * DemandModel.commercial_kw(2, pos, _t(WORKDAY, 12.0)))


func test_lot_sample_deterministic_and_bounded() -> void:
	var a := DemandModel.commercial_profile(Vector2i(10, 20))
	var b := DemandModel.commercial_profile(Vector2i(10, 20))
	assert_float(float(a["scale"])).is_equal(float(b["scale"]))
	for i in 30:
		var scale := float(DemandModel.commercial_profile(
			Vector2i(i * 7, i * 13))["scale"])
		assert_bool(scale >= 0.75 and scale <= 1.25).is_true()


func test_charging_park_series_deterministic_spiky_bounded() -> void:
	var noon := _t(WORKDAY, 12.0)
	var night := _t(WORKDAY, 3.0)
	assert_float(DemandModel.charging_park_kw("cp_a", noon, 8, 175.0)) \
		.is_equal(DemandModel.charging_park_kw("cp_a", noon, 8, 175.0))
	# bounded by the site's stall capacity, never negative
	var day_sum := 0.0
	for i in 96:
		var kw := DemandModel.charging_park_kw("cp_a", WORKDAY * 96 + i, 8, 175.0)
		assert_bool(kw >= 0.0 and kw <= 8 * 175.0).is_true()
		day_sum += kw
	assert_float(day_sum).is_greater(0.0)
	# the day curve dwarfs the night trickle (window property: means)
	var noon_mean := 0.0
	var night_mean := 0.0
	for i in 8:
		noon_mean += DemandModel.charging_park_kw("cp_a", noon + i, 8, 175.0)
		night_mean += DemandModel.charging_park_kw("cp_a", night + i, 8, 175.0)
	assert_float(noon_mean).is_greater(night_mean)
	# different parks sample different sessions
	var differs := false
	for i in 16:
		if DemandModel.charging_park_kw("cp_a", noon + i, 8, 175.0) \
				!= DemandModel.charging_park_kw("cp_b", noon + i, 8, 175.0):
			differs = true
	assert_bool(differs).is_true()


func test_xl_trafo_fields_and_peak_gate() -> void:
	# 1000 kVA: no 20/0.4 catalog type above 0.63 — explicit params
	var xl := PowerTopology.trafo_fields(1000.0)
	assert_bool(xl.has("std_type")).is_false()
	assert_float(float(xl["sn_mva"])).is_equal(1.0)
	# the 630 default keeps its catalog type byte-for-byte (goldens)
	assert_str(str(PowerTopology.trafo_fields(630.0)["std_type"])) \
		.is_equal("0.63 MVA 20/0.4 kV")
	# the growth gate's peak expectation covers the worst sampled lot
	for ctype in [1, 2, 3]:
		var spec: Dictionary = DemandModel.COMMERCIAL_SPECS[ctype]
		assert_float(DemandModel.commercial_peak_kw(ctype)) \
			.is_greater_equal(float(spec["elec_kw"]) * 1.25 * 1.1 - 0.001)
