extends GdUnitTestSuite
## User bug report: "demolish a line and set it up again — no reconnection
## (test with solar panels or wind power plants)".


func _wind_town() -> void:
	City.reset_for_scenario(42)
	City.place_building("grid_connection", Vector2i(0, 4))  # footprint 0-1,4-5
	for x in range(2, 10):
		City.build_cable(Vector2i(x, 5))
	City.place_building("wind_farm", Vector2i(10, 5))       # touches (9,5)


func test_plain_demolish_and_rebuild_reconnects() -> void:
	_wind_town()
	City._sync_topology()
	var wind: String = City.model.buildings_of_kind("wind_farm")[0]
	assert_bool(bool(City.topo.connected[wind])).is_true()
	City.bulldoze(Vector2i(5, 5))
	City._sync_topology()
	assert_bool(bool(City.topo.connected[wind])).is_false()
	City.build_cable(Vector2i(5, 5))
	City._sync_topology()
	assert_bool(bool(City.topo.connected[wind])) \
		.override_failure_message("rebuilt line did not reconnect").is_true()
	City.reset_for_scenario(42)


func test_tripped_line_demolish_and_rebuild_reconnects() -> void:
	# the live story: the wind farm overloads the line, the WHOLE segment
	# trips (every path tile lands in tripped_tiles); the player demolishes
	# and re-lays ONE tile and expects the branch back
	_wind_town()
	City._sync_topology()
	var wind: String = City.model.buildings_of_kind("wind_farm")[0]
	for x in range(2, 10):
		City.tripped_tiles[Vector2i(x, 5)] = City.AWAITING_CREW
	City._sync_topology()
	assert_bool(bool(City.topo.connected[wind])).is_false()
	# demolish + rebuild one tile of the dead segment
	City.bulldoze(Vector2i(5, 5))
	City.build_cable(Vector2i(5, 5))
	City._sync_topology()
	assert_bool(bool(City.topo.connected[wind])) \
		.override_failure_message(
			"rebuilding over a tripped segment left it dead").is_true()
	City.reset_for_scenario(42)
