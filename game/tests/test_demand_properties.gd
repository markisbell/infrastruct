extends GdUnitTestSuite
## DemandModel property tests (Phase-7 refactor plan): the pure sampled-
## household core — world-seed independence, rot normalization edges, the
## no-north-roof fleet rule, and physics-tier energy conservation (the
## zone boundary IS the sum of its sampled houses).


func after_test() -> void:
	DemandModel.reset_caches()


func test_house_sampling_is_world_seed_independent() -> void:
	# tile-hash seeded, FIXED draw order: the same lot hosts the same
	# household no matter which weather/world the city runs
	DemandModel.reset_caches()
	DemandModel.weather = WeatherSystem.new(42)
	var a := DemandModel.house_profile(Vector2i(33, 44))
	DemandModel.reset_caches()
	DemandModel.weather = WeatherSystem.new(1337)
	var b := DemandModel.house_profile(Vector2i(33, 44))
	assert_that(a).is_equal(b)


func test_pv_rot_normalizes_negative_and_wrapped() -> void:
	var noon := 180 * 96 + 48  # summer noon
	assert_float(DemandModel.pv_park_availability(noon, -1)) \
		.is_equal(DemandModel.pv_park_availability(noon, 3))
	assert_float(DemandModel.pv_park_availability(noon, 4)) \
		.is_equal(DemandModel.pv_park_availability(noon, 0))
	# north is diffuse-only: half the south yield at most
	assert_float(DemandModel.pv_park_availability(noon, 2)) \
		.is_less_equal(0.5 * DemandModel.pv_park_availability(noon, 0) + 0.0001)


func test_roof_fleet_never_faces_north() -> void:
	for x in range(20, 60, 3):
		for y in range(20, 60, 7):
			var profile := DemandModel.house_profile(Vector2i(x, y))
			if profile["has_pv"]:
				assert_int(int(profile["pv_rot"])).is_not_equal(2)


func test_zone_sum_is_sum_of_sampled_houses() -> void:
	# the transformer sees the SUM of the sampled households (physics
	# tier) — not a smooth mean; conservation must hold exactly
	var tiles: Array = [Vector2i(30, 30), Vector2i(31, 30), Vector2i(32, 30),
		Vector2i(35, 31)]
	var t := 250 * 96 + 74  # a winter evening step
	var manual := 0.0
	for pos: Vector2i in tiles:
		var profile := DemandModel.profile_cached(pos)
		manual += DemandModel.house_base_kw(profile, t) \
			+ DemandModel.house_ev_kw(profile, t) \
			- DemandModel.house_pv_kw(profile, t)
	assert_float(DemandModel.zone_sum_kw(tiles, t)) \
		.is_equal_approx(manual, 0.0001)


func test_dhw_fallback_staircase_survives_pack_removal() -> void:
	DemandModel.set_pack_override({}, -1)  # pack-less fallback branch
	var acc := 0.0
	for q in 96:
		acc += DemandModel.dhw_factor(301 * 96 + q)
	assert_float(acc / 96.0).is_between(0.8, 1.2)  # mean-1.0 staircase
	DemandModel.reset_caches()
