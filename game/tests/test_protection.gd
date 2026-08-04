extends GdUnitTestSuite
## ProtectionSystem (Phase-2 extraction): streak semantics for line, trafo
## and grid trips — strictly >120 %, consecutive-step maturity, clean-step
## reset, already-tripped exclusion.

const KNOWN := {"L1": true, "L2": true}


static func _edge(loading: float) -> Dictionary:
	return {"loading_percent": loading}


func test_line_trips_after_three_consecutive_criticals() -> void:
	var protection := ProtectionSystem.new()
	assert_array(protection.line_trips({"L1": _edge(130.0)}, KNOWN)).is_empty()
	assert_array(protection.line_trips({"L1": _edge(125.0)}, KNOWN)).is_empty()
	var trips := protection.line_trips({"L1": _edge(140.0)}, KNOWN)
	assert_int(trips.size()).is_equal(1)
	assert_str(trips[0]["edge_id"]).is_equal("L1")
	assert_float(float(trips[0]["loading"])).is_equal(140.0)
	assert_bool(protection.line_streak.has("L1")).is_false()  # streak consumed


func test_line_threshold_is_strict_and_clean_step_resets() -> void:
	var protection := ProtectionSystem.new()
	# exactly 120.0 is NOT critical
	protection.line_trips({"L1": _edge(120.0)}, KNOWN)
	assert_bool(protection.line_streak.has("L1")).is_false()
	# a clean step between criticals resets the count
	protection.line_trips({"L1": _edge(130.0)}, KNOWN)
	protection.line_trips({"L1": _edge(130.0)}, KNOWN)
	protection.line_trips({"L1": _edge(90.0)}, KNOWN)
	protection.line_trips({"L1": _edge(130.0)}, KNOWN)
	assert_array(protection.line_trips({"L1": _edge(130.0)}, KNOWN)).is_empty()


func test_line_unknown_edge_keeps_counting_never_trips_blind() -> void:
	var protection := ProtectionSystem.new()
	for _i in 5:
		assert_array(protection.line_trips({"LX": _edge(150.0)}, KNOWN)).is_empty()
	assert_int(int(protection.line_streak["LX"])).is_equal(5)


func test_trafo_trips_after_four_and_skips_already_tripped() -> void:
	var protection := ProtectionSystem.new()
	var subs := {"T0": "sub_1"}
	for _i in 3:
		assert_array(protection.trafo_trips(
			{"T0": _edge(130.0)}, subs, {})).is_empty()
	var trips := protection.trafo_trips({"T0": _edge(130.0)}, subs, {})
	assert_int(trips.size()).is_equal(1)
	assert_str(trips[0]["sub_id"]).is_equal("sub_1")
	# already tripped: excluded entirely, no streak bookkeeping either
	for _i in 6:
		assert_array(protection.trafo_trips(
			{"T0": _edge(130.0)}, subs, {"sub_1": -1})).is_empty()
	assert_bool(protection.trafo_streak.has("sub_1")).is_false()


func test_grid_trip_streak_and_reset() -> void:
	var protection := ProtectionSystem.new()
	assert_bool(protection.grid_trip(30.0, 20.0, true)).is_false()  # streak 1
	assert_bool(protection.grid_trip(30.0, 20.0, true)).is_true()   # streak 2
	assert_int(protection.slack_streak).is_equal(0)
	# import within capacity resets the streak
	protection.grid_trip(30.0, 20.0, true)
	protection.grid_trip(10.0, 20.0, true)
	assert_bool(protection.grid_trip(30.0, 20.0, true)).is_false()


func test_grid_trip_holds_streak_while_trip_active() -> void:
	var protection := ProtectionSystem.new()
	protection.grid_trip(30.0, 20.0, true)
	# a matured streak with an ACTIVE trip (can_trip false) keeps standing…
	assert_bool(protection.grid_trip(30.0, 20.0, false)).is_false()
	assert_int(protection.slack_streak).is_equal(2)
	# …so the first eligible step re-trips immediately
	assert_bool(protection.grid_trip(30.0, 20.0, true)).is_true()


func test_reset_clears_all_streaks() -> void:
	var protection := ProtectionSystem.new()
	protection.line_trips({"L1": _edge(130.0)}, KNOWN)
	protection.trafo_trips({"T0": _edge(130.0)}, {"T0": "s"}, {})
	protection.grid_trip(30.0, 20.0, true)
	protection.reset()
	assert_bool(protection.line_streak.is_empty()).is_true()
	assert_bool(protection.trafo_streak.is_empty()).is_true()
	assert_int(protection.slack_streak).is_equal(0)
