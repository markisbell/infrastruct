extends GdUnitTestSuite
## Hotbar slot rules + persistence. The invariant under test throughout is
## that a slot's POSITION is sacred: nothing the game does — an unknown id,
## a short file, a corrupt one — may shift a tool the player learned into a
## different slot.

const TEST_PATH := "user://test_hotbar_slots.cfg"


func _known() -> Dictionary:
	var known := {}
	for id: String in Hotbar.DEFAULT_IDS:
		known[id] = true
	known["water_pipe"] = true
	known["repair"] = true
	return known


func after_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func test_defaults_fill_every_slot_with_a_known_tool() -> void:
	var slots := Hotbar.default_slots()
	assert_int(slots.size()).is_equal(Hotbar.SLOT_COUNT)
	assert_int(Hotbar.SLOT_LABELS.size()).is_equal(Hotbar.SLOT_COUNT)
	for id: String in slots:
		assert_str(id).is_not_empty()


func test_digits_are_matched_physically_across_layouts() -> void:
	# the number row is not digits on every layout — physical position is
	# the only binding that survives AZERTY
	assert_int(Hotbar.slot_for_physical(KEY_1)).is_equal(0)
	assert_int(Hotbar.slot_for_physical(KEY_9)).is_equal(8)
	assert_int(Hotbar.slot_for_physical(KEY_0)).is_equal(9)  # 0 is the LAST slot
	assert_int(Hotbar.slot_for_physical(KEY_KP_5)).is_equal(4)
	assert_int(Hotbar.slot_for_physical(KEY_KP_0)).is_equal(9)
	assert_int(Hotbar.slot_for_physical(KEY_A)).is_equal(-1)
	assert_int(Hotbar.slot_for_physical(0)).is_equal(-1)


func test_sanitize_never_shifts_a_surviving_slot() -> void:
	var known := _known()
	# an unknown id in the middle empties ITS slot and leaves the rest put
	var raw: Array = ["road", "gone_tool", "cable_overhead"]
	var slots := Hotbar.sanitize(raw, known)
	assert_int(slots.size()).is_equal(Hotbar.SLOT_COUNT)
	assert_str(slots[0]).is_equal("road")
	assert_str(slots[1]).is_equal("")           # dropped, not closed up
	assert_str(slots[2]).is_equal("cable_overhead")
	for i in range(3, Hotbar.SLOT_COUNT):
		assert_str(slots[i]).is_equal("")       # short array pads with empties
	# an over-long array is truncated, not wrapped
	var long_raw: Array = []
	for i in Hotbar.SLOT_COUNT + 5:
		long_raw.append("road")
	assert_int(Hotbar.sanitize(long_raw, known).size()).is_equal(Hotbar.SLOT_COUNT)


func test_assign_touches_exactly_one_slot_and_ignores_bad_indices() -> void:
	var slots := Hotbar.sanitize(Hotbar.default_slots(), _known())
	var pinned := Hotbar.assign(slots, 3, "water_pipe")
	assert_str(pinned[3]).is_equal("water_pipe")
	assert_str(pinned[2]).is_equal(slots[2])
	assert_str(pinned[4]).is_equal(slots[4])
	# clearing is assigning nothing
	assert_str(Hotbar.assign(pinned, 3, "")[3]).is_equal("")
	# out of range is a no-op, never a crash or a resize
	assert_that(Hotbar.assign(slots, -1, "repair")).is_equal(slots)
	assert_that(Hotbar.assign(slots, 99, "repair")).is_equal(slots)


func test_slots_survive_a_save_load_round_trip() -> void:
	var known := _known()
	var slots := Hotbar.assign(
		Hotbar.assign(Hotbar.sanitize([], known), 0, "repair"),
		7, "water_pipe")
	assert_int(Hotbar.save_slots(slots, TEST_PATH)).is_equal(OK)
	var loaded := Hotbar.load_slots(known, TEST_PATH)
	assert_that(loaded).is_equal(slots)


func test_missing_or_unreadable_settings_fall_back_to_defaults() -> void:
	var known := _known()
	assert_that(Hotbar.load_slots(known, "user://no_such_hotbar.cfg")) \
		.is_equal(Hotbar.sanitize(Hotbar.default_slots(), known))
	# a file whose slots key is the wrong type must not poison the loadout
	var config := ConfigFile.new()
	config.set_value(Hotbar.SECTION, "slots", "not-an-array")
	config.save(TEST_PATH)
	assert_that(Hotbar.load_slots(known, TEST_PATH)) \
		.is_equal(Hotbar.sanitize(Hotbar.default_slots(), known))


func test_saving_preserves_other_settings_in_the_file() -> void:
	# the hotbar shares user://settings.cfg with whatever lands there next
	var config := ConfigFile.new()
	config.set_value("display", "some_pref", 42)
	config.save(TEST_PATH)
	Hotbar.save_slots(Hotbar.default_slots(), TEST_PATH)
	var reread := ConfigFile.new()
	assert_int(reread.load(TEST_PATH)).is_equal(OK)
	assert_int(int(reread.get_value("display", "some_pref", 0))).is_equal(42)
