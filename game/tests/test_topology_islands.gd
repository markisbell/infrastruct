extends GdUnitTestSuite
## PowerTopology island detection (power islands): a component with no
## grid connection joins the doc when it holds a grid-forming device
## (battery/gas), the former is emitted as that component's slack, pure
## renewable clusters stay dark, and grid-connected cities keep an empty
## islands map (byte-stability — the goldens pin the full docs).


## Off-grid microgrid: battery + wind + solar on one cable run feeding a
## substation zone with houses; a FORMERLESS wind cluster further south.
static func _island_town() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("battery", Vector2i(2, 4))       # taps (2,5)
	for x in range(2, 12):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("wind_farm", Vector2i(5, 4))     # taps (5,5)
	model.place_building("solar_park", Vector2i(8, 3))    # taps (8,5)
	model.place_building("substation", Vector2i(11, 6))   # taps (11,5)
	for x in range(8, 16):
		model.set_road(Vector2i(x, 8))
		model.set_zone(Vector2i(x, 7))
	for x in range(8, 14):
		model.spawn_house(Vector2i(x, 7))
	# formerless cluster: a lone wind turbine + substation, no battery/gas
	model.place_building("wind_farm", Vector2i(2, 14))    # taps (2,15)
	for x in range(2, 8):
		model.set_cable(Vector2i(x, 15), BuildingDefs.LINE_OVERHEAD)
	model.place_building("substation", Vector2i(7, 16))   # taps (7,15)
	return model


func test_battery_forms_island_renewable_cluster_stays_dark() -> void:
	var model := _island_town()
	var topo := PowerTopology.build(model, {})
	var battery_id: String = model.buildings_of_kind("battery")[0]
	var island_id := "isl_%s" % battery_id
	assert_bool(topo.has_slack).is_true()
	assert_array(topo.islands.keys()).contains_exactly([island_id])
	assert_str(str(topo.islands[island_id]["former"])).is_equal(battery_id)
	# the former rides the doc as a slack device with ONLY the vm_pu param
	var former_dev := {}
	for device: Dictionary in topo.doc["devices"]:
		if device["id"] == battery_id:
			former_dev = device
	assert_str(str(former_dev.get("kind"))).is_equal("slack")
	assert_that(former_dev.get("params")).is_equal({"vm_pu": 1.0})
	# members are energized, the island zone is flagged, houses assigned
	var subs := model.buildings_of_kind("substation")
	assert_bool(bool(topo.connected[subs[0]])).is_true()
	var zone_id := "z_" + subs[0]
	assert_str(str(topo.zones_info[zone_id].get("island", ""))) \
		.is_equal(island_id)
	assert_array(topo.islands[island_id]["zones"]).contains_exactly([zone_id])
	assert_int(int(topo.zones_info[zone_id]["houses"])).is_greater(0)
	# renewables recorded as island devices (the EMS dispatch scope)
	var device_kinds: Dictionary = topo.islands[island_id]["devices"]
	assert_array(device_kinds.values()).contains_exactly_in_any_order(
		["wind", "pv"])
	# the formerless southern cluster stays out of the doc, dark
	assert_bool(bool(topo.connected[subs[1]])).is_false()
	assert_bool(bool(topo.zones_info["z_" + subs[1]]["connected"])).is_false()


func test_no_former_no_grid_stays_unsolvable() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("wind_farm", Vector2i(2, 4))
	for x in range(2, 8):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("substation", Vector2i(7, 6))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.has_slack).is_false()
	assert_bool(topo.doc.is_empty()).is_true()
	assert_array(topo.warnings).contains(
		["no grid connection — network unsolvable, everything unpowered"])


func test_battery_preferred_over_gas_as_former() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("gas_plant", Vector2i(2, 3))     # 2x2, taps (2,5)
	for x in range(2, 10):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("battery", Vector2i(6, 4))       # taps (6,5)
	var topo := PowerTopology.build(model, {})
	var battery_id: String = model.buildings_of_kind("battery")[0]
	var gas_id: String = model.buildings_of_kind("gas_plant")[0]
	var island_id := "isl_%s" % battery_id
	assert_array(topo.islands.keys()).contains_exactly([island_id])
	# the gas plant stays an ordinary generator device — the EMS's reserve
	assert_str(str((topo.islands[island_id]["devices"] as Dictionary)
		.get(gas_id, ""))).is_equal("generator")
	for device: Dictionary in topo.doc["devices"]:
		if device["id"] == gas_id:
			assert_str(str(device["kind"])).is_equal("generator")


func test_gas_plant_forms_island_without_battery() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("gas_plant", Vector2i(2, 3))
	for x in range(2, 8):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("substation", Vector2i(7, 6))
	var topo := PowerTopology.build(model, {})
	var gas_id: String = model.buildings_of_kind("gas_plant")[0]
	assert_array(topo.islands.keys()).contains_exactly(["isl_%s" % gas_id])
	assert_str(str(topo.islands["isl_%s" % gas_id]["former_kind"])) \
		.is_equal("gas_plant")


func test_grid_connected_city_has_no_islands() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	model.place_building("grid_connection", Vector2i(1, 3))  # 2x2, taps (1,5)
	for x in range(1, 10):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("battery", Vector2i(6, 4))
	model.place_building("substation", Vector2i(9, 6))
	var topo := PowerTopology.build(model, {})
	assert_bool(topo.islands.is_empty()).is_true()
	assert_bool(topo.island_of.is_empty()).is_true()
	# the battery stays a plain battery device on the main grid
	for device: Dictionary in topo.doc["devices"]:
		if device["id"] == model.buildings_of_kind("battery")[0]:
			assert_str(str(device["kind"])).is_equal("battery")
	for zone_id: String in topo.zones_info:
		assert_str(str(topo.zones_info[zone_id].get("island", ""))).is_equal("")


func test_grid_city_plus_separate_island_coexist() -> void:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	# main grid: connection + substation
	model.place_building("grid_connection", Vector2i(1, 3))
	for x in range(1, 8):
		model.set_cable(Vector2i(x, 5), BuildingDefs.LINE_OVERHEAD)
	model.place_building("substation", Vector2i(7, 6))
	# far-away island: battery + substation on their own run
	model.place_building("battery", Vector2i(1, 14))
	for x in range(1, 8):
		model.set_cable(Vector2i(x, 15), BuildingDefs.LINE_OVERHEAD)
	model.place_building("substation", Vector2i(7, 16))
	var topo := PowerTopology.build(model, {})
	assert_int(topo.islands.size()).is_equal(1)
	var subs := model.buildings_of_kind("substation")
	assert_str(str(topo.zones_info["z_" + subs[0]].get("island", ""))) \
		.is_equal("")
	assert_str(str(topo.zones_info["z_" + subs[1]].get("island", ""))) \
		.is_not_equal("")
	# both zones are in the doc
	var zone_ids: Array = []
	for zone: Dictionary in topo.doc["zones"]:
		zone_ids.append(zone["id"])
	assert_array(zone_ids).contains_exactly_in_any_order(
		["z_" + subs[0], "z_" + subs[1]])
