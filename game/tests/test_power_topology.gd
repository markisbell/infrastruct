extends GdUnitTestSuite
## Topology extraction: cable graph → contract doc, islands, junctions, trips.


func _town() -> WorldModel:
	## grid_connection(2x2)@(0,0) — cable (2,0)..(10,0) — substation@(11,0)
	var model := WorldModel.new()
	model.place_building("grid_connection", Vector2i(0, 0))
	for x in range(2, 11):
		model.set_cable(Vector2i(x, 0), 1)
	model.place_building("substation", Vector2i(11, 0))
	# a road + zone + houses near the substation
	for x in range(8, 14):
		model.set_road(Vector2i(x, 2))
	for x in range(8, 14):
		model.set_zone(Vector2i(x, 3))
		model.spawn_house(Vector2i(x, 3))
	return model


func test_simple_town_extraction() -> void:
	var topo := PowerTopology.build(_town(), {})
	assert_bool(topo.has_slack).is_true()
	assert_int(topo.doc["native"]["grid_structure"]["buses"].size()).is_equal(2)
	var lines: Array = topo.doc["native"]["lines"]["lines"]
	assert_int(lines.size()).is_equal(1)
	# path: 9 cable tiles + both endpoints are among them -> 9 tiles * 25 m
	assert_float(lines[0]["length_km"]).is_equal_approx(0.225, 0.001)
	assert_int(topo.doc["zones"].size()).is_equal(1)
	var zone_id: String = topo.doc["zones"][0]["id"]
	assert_int(topo.zones_info[zone_id]["houses"]).is_equal(6)
	assert_int(topo.doc["devices"].size()).is_equal(1)  # slack only
	assert_that(topo.doc["devices"][0]["kind"]).is_equal("slack")
	assert_bool(topo.line_tiles.has("L0")).is_true()


func test_junction_splits_lines() -> void:
	var model := _town()
	# branch off tile (6,0) down to a wind farm
	for y in range(1, 5):
		model.set_cable(Vector2i(6, y), 1)
	model.place_building("wind_farm", Vector2i(5, 5))  # touches (6,4)
	var topo := PowerTopology.build(model, {})
	# junction at (6,0) -> 3 lines, 4 buses (slack, sub, wind, junction)
	assert_int(topo.doc["native"]["lines"]["lines"].size()).is_equal(3)
	assert_int(topo.doc["native"]["grid_structure"]["buses"].size()).is_equal(4)
	var kinds := []
	for device: Dictionary in topo.doc["devices"]:
		kinds.append(device["kind"])
	assert_array(kinds).contains(["slack", "wind"])


func test_island_excluded_and_flagged() -> void:
	var model := _town()
	model.set_cable(Vector2i(20, 20), 1)
	var island_sub := model.place_building("substation", Vector2i(21, 20))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.connected[island_sub]).is_false()
	assert_int(topo.doc["zones"].size()).is_equal(1)  # island zone not in doc


func test_trip_disconnects_downstream() -> void:
	var model := _town()
	var tripped := {Vector2i(6, 0): true}
	var topo := PowerTopology.build(model, tripped)
	# the only line crosses the tripped tile -> substation unreachable
	var sub_id: String = model.buildings_of_kind("substation")[0]
	assert_bool(topo.connected[sub_id]).is_false()
	assert_int(topo.doc["zones"].size()).is_equal(0)
	assert_int(topo.doc["native"]["lines"]["lines"].size()).is_equal(0)


func test_no_slack_means_no_doc() -> void:
	var model := WorldModel.new()
	model.set_cable(Vector2i(0, 0), 1)
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.has_slack).is_false()
	assert_bool(topo.doc.is_empty()).is_true()
