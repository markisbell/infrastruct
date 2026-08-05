extends GdUnitTestSuite
## Phase-7 safety net: GOLDEN topology documents. Two fixture cities are
## built model-level and all three network builders run; the full docs +
## derived maps are pinned byte-for-byte against committed goldens under
## res://tests/goldens/. A missing golden is CAPTURED (first run) — a
## mismatch afterwards means the consolidation changed what the solvers
## would receive. Delete a golden deliberately to re-baseline.

const GOLDEN_DIR := "res://tests/goldens/"


## The smoke reference city (proven layout), extended for coverage: a
## buried tail on the main run (kind-transition junction), heat storage +
## CHP secondary on the trunk, a plateau under the water tower (elevation
## in native junctions) and a river next to the well (yield bonus).
static func _reference_town() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.terrain.force_height(Vector2i(5, 16), Vector2i(8, 19), 2)
	model.terrain.force_water(Vector2i(9, 21), Vector2i(14, 21))
	model.place_building("grid_connection", Vector2i(6, 4))
	for x in range(8, 26):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	for x in range(26, 32):  # buried tail: kind-transition junction bus
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_UNDERGROUND)
	model.place_building("gas_plant", Vector2i(16, 3))
	model.place_building("solar_park", Vector2i(20, 3))
	model.place_building("battery", Vector2i(25, 4))
	model.place_building("substation", Vector2i(12, 6))
	for x in range(8, 25):
		model.set_road(Vector2i(x, 8))
		model.set_road(Vector2i(x, 11))
	for x in range(8, 25):
		model.set_zone(Vector2i(x, 9))
		model.set_zone(Vector2i(x, 10))
	for x in range(8, 21):  # deterministic fixed house rows (no bulk RNG)
		model.spawn_house(Vector2i(x, 9))
		model.spawn_house(Vector2i(x, 10))
	model.place_building("boiler_plant", Vector2i(6, 13))
	for x in range(8, 15):
		model.set_heat_pipe(Vector2i(x, 14), BuildingDefs.LINE_OVERHEAD)
	model.place_building("heat_exchanger", Vector2i(15, 14))
	model.place_building("heat_storage", Vector2i(10, 12))
	model.place_building("chp_plant", Vector2i(12, 15))
	model.place_building("water_tower", Vector2i(6, 17))
	for x in range(7, 15):  # (7,17) bridges the 1x1 tower onto the main
		model.set_water_pipe(Vector2i(x, 17), BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_station", Vector2i(15, 17))
	model.place_building("well", Vector2i(10, 19))
	model.set_water_pipe(Vector2i(10, 18), BuildingDefs.LINE_OVERHEAD)
	model.place_building("pumping_station", Vector2i(12, 19))
	model.set_water_pipe(Vector2i(12, 18), BuildingDefs.LINE_OVERHEAD)
	for y in range(6, 20):
		model.set_cable(Vector2i(31, y), BuildingDefs.LINE_OVERHEAD)
	for x in range(14, 31):
		model.set_cable(Vector2i(x, 19), BuildingDefs.LINE_OVERHEAD)
	return model


## Inline booster: a pumping station BRIDGING two pipe-run ends splits
## into suction/discharge nodes joined by a StationSpec pump branch.
static func _booster_town() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("water_tower", Vector2i(1, 1))  # 1x1 head
	for x in range(2, 7):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("pumping_station", Vector2i(7, 0))
	for x in range(9, 15):
		model.set_water_pipe(Vector2i(x, 1), BuildingDefs.LINE_OVERHEAD)
	model.place_building("water_station", Vector2i(15, 1))
	for x in range(10, 15):
		model.set_road(Vector2i(x, 3))
		model.set_zone(Vector2i(x, 4))
	for x in range(10, 15):
		model.spawn_house(Vector2i(x, 4))
	return model


static func _snapshot(model: WorldModel, tripped: Dictionary) -> String:
	var power := PowerTopology.build(model, tripped)
	var heat := HeatTopology.build(model, tripped)
	var water := WaterTopology.build(model, tripped)
	var snap := {
		"power": {"doc": power.doc, "line_tiles": power.line_tiles,
			"zones_info": power.zones_info, "house_zone": power.house_zone,
			"connected": power.connected, "trafo_subs": power.trafo_subs,
			"has_slack": power.has_slack, "warnings": power.warnings},
		"heat": {"doc": heat.doc, "zones_info": heat.zones_info,
			"warnings": heat.warnings},
		"water": {"doc": water.doc, "zones_info": water.zones_info,
			"warnings": water.warnings},
	}
	return JSON.stringify(snap, "\t")


func _check_golden(name: String, actual: String) -> void:
	var path := GOLDEN_DIR + name + ".json"
	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(GOLDEN_DIR))
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(actual)
		f.close()
		push_warning("golden CAPTURED (first run, verify + commit): " + name)
		return
	var expected := FileAccess.get_file_as_string(path)
	if actual == expected:
		assert_bool(true).is_true()
		return
	# byte mismatch: report the FIRST differing line with context, not 40 kB
	var a_lines := actual.split("\n")
	var e_lines := expected.split("\n")
	for i in mini(a_lines.size(), e_lines.size()):
		if a_lines[i] != e_lines[i]:
			assert_str(a_lines[i]) \
				.override_failure_message("%s golden diverges at line %d" % [name, i + 1]) \
				.is_equal(e_lines[i])
			return
	assert_int(a_lines.size()) \
		.override_failure_message(name + " golden length changed") \
		.is_equal(e_lines.size())


func test_reference_town_golden() -> void:
	_check_golden("reference_town", _snapshot(_reference_town(), {}))


func test_reference_town_with_trip_golden() -> void:
	# a mid-run tripped tile: the tail (incl. the buried section, battery,
	# east column, pump feed) must fall out of the doc deterministically
	_check_golden("reference_town_tripped",
		_snapshot(_reference_town(), {Vector2i(18, 5): -1}))


func test_booster_town_golden() -> void:
	_check_golden("booster_town", _snapshot(_booster_town(), {}))
