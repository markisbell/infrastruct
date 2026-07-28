extends GdUnitTestSuite
## Weather: determinism, calm hook, availability curves, day/night.


func test_same_seed_is_deterministic() -> void:
	var a := WeatherSystem.new(1234)
	var b := WeatherSystem.new(1234)
	for t in range(0, 2000, 13):
		assert_that(a.sample(t)).is_equal(b.sample(t))


func test_different_seeds_differ() -> void:
	var a := WeatherSystem.new(1)
	var b := WeatherSystem.new(2)
	var diverged := false
	for t in range(0, 500, 7):
		if a.wind_ms(t) != b.wind_ms(t):
			diverged = true
			break
	assert_bool(diverged).is_true()


func test_force_calm_zeroes_wind_availability() -> void:
	var weather := WeatherSystem.new(7)
	weather.force_calm(96, 192)
	for t in [96, 120, 191]:
		assert_float(weather.wind_ms(t)).is_less(1.0)
		assert_float(WeatherSystem.wind_availability(weather.wind_ms(t))).is_equal(0.0)
	weather.clear_calm()
	# outside the window the series is untouched
	assert_float(weather.wind_ms(300)).is_equal(WeatherSystem.new(7).wind_ms(300))


func test_wind_availability_curve() -> void:
	assert_float(WeatherSystem.wind_availability(2.9)).is_equal(0.0)
	assert_float(WeatherSystem.wind_availability(12.0)).is_equal(1.0)
	assert_float(WeatherSystem.wind_availability(25.0)).is_equal(0.0)  # cut-out
	var half := WeatherSystem.wind_availability(7.5)
	assert_bool(half > 0.0 and half < 1.0).is_true()


func test_solar_day_night() -> void:
	var weather := WeatherSystem.new(42)
	# summer midday (day 180 of the 360-day year), step 48 = 12:00
	var midday := 180 * 96 + 48
	assert_float(weather.ghi_wm2(midday)).is_greater(300.0)
	assert_float(weather.ghi_wm2(180 * 96)).is_equal(0.0)  # midnight
	# winter midday is dimmer than summer midday
	assert_float(weather.ghi_wm2(48)).is_less(weather.ghi_wm2(midday))
