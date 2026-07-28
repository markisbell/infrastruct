extends GdUnitTestSuite
## GameClock time math + persistence (autoload state is reset around each test).

var _saved_minutes: float
var _saved_speed: float


func before_test() -> void:
	_saved_minutes = GameClock.total_minutes
	_saved_speed = GameClock.speed


func after_test() -> void:
	GameClock.restore({"total_minutes": _saved_minutes, "speed": _saved_speed})


func test_day_and_time_of_day() -> void:
	GameClock.restore({"total_minutes": 3 * 1440.0 + 125.0, "speed": 1.0})
	assert_int(GameClock.day()).is_equal(3)
	assert_str(GameClock.time_of_day_string()).is_equal("02:05")


func test_seasons_cycle_through_the_year() -> void:
	for expectation: Array in [
		[0, "spring"], [89, "spring"], [90, "summer"],
		[180, "autumn"], [270, "winter"], [360, "spring"],
	]:
		GameClock.restore({"total_minutes": expectation[0] * 1440.0, "speed": 1.0})
		assert_str(GameClock.season_name()) \
			.override_failure_message("day %d" % expectation[0]) \
			.is_equal(expectation[1])


func test_serialize_restore_roundtrip() -> void:
	GameClock.restore({"total_minutes": 12345.6, "speed": 10.0})
	var data := GameClock.serialize()
	GameClock.restore({"total_minutes": 0.0, "speed": 1.0})
	GameClock.restore(data)
	assert_float(GameClock.total_minutes).is_equal_approx(12345.6, 0.001)
	assert_float(GameClock.speed).is_equal_approx(10.0, 0.001)


func test_save_envelope_roundtrip() -> void:
	var model := WorldModel.new()
	model.set_cable(Vector2i(1, 2), 1)
	GameClock.restore({"total_minutes": 999.0, "speed": 3.0})
	var path := "user://gdunit_save_test.json"
	assert_int(SaveGame.save_to(path, model)).is_equal(OK)

	GameClock.restore({"total_minutes": 0.0, "speed": 1.0})
	var loaded: Dictionary = SaveGame.load_from(path)
	assert_bool(loaded["ok"]).is_true()
	var restored: WorldModel = loaded["model"]
	assert_bool(restored.equals(model)).is_true()
	assert_float(GameClock.total_minutes).is_equal_approx(999.0, 0.001)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_load_rejects_unsupported_version() -> void:
	var path := "user://gdunit_bad_save.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 999, "model": {}, "clock": {}}))
	f.close()
	assert_bool(SaveGame.load_from(path)["ok"]).is_false()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
