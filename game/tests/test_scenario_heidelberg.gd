extends GdUnitTestSuite
## The Heidelberg reference build. These are the assertions that keep the
## city recognisable: the Neckar where the bridges are, districts on their
## real ground, and — because the river cuts the map and there are no
## bridges — two independent networks rather than one broken one.


func before_test() -> void:
	Scenarios.start("heidelberg", "normal")


func test_terrain_is_the_real_region() -> void:
	var terrain := City.model.terrain
	assert_str(terrain.region).is_equal("heidelberg")
	# the Königstuhl really is ~460 m above the valley floor, and the game
	# keeps that as levels: the hill must tower over the Altstadt
	var koenigstuhl := terrain.height(Vector2i(205, 161))
	var altstadt := terrain.height(Vector2i(146, 124))
	assert_int(koenigstuhl).is_greater(altstadt + 20)
	assert_int(altstadt).is_less(4)  # Altstadt sits on the valley floor


func test_neckar_runs_where_the_bridges_are() -> void:
	var terrain := City.model.terrain
	# the three real crossings must be water — they anchor the channel
	for crossing: Vector2i in [Vector2i(91, 105), Vector2i(114, 109),
			Vector2i(159, 115)]:
		assert_bool(terrain.is_water(crossing)) \
			.override_failure_message("no Neckar at %s" % crossing).is_true()
	# and the banks must be dry, or the river has eaten the city
	assert_bool(terrain.is_water(Vector2i(146, 124))).is_false()  # Altstadt
	assert_bool(terrain.is_water(Vector2i(116, 96))).is_false()   # Neuenheim


func test_city_stands_on_both_banks() -> void:
	var model := City.model
	# houses actually grew — the terrain-aware zoning has to leave enough
	# flat, road-served lots for a real town
	assert_int(model.houses.size()).is_greater(60)
	var north := 0
	var south := 0
	for pos: Vector2i in model.houses:
		if pos.y < 105:
			north += 1
		else:
			south += 1
	assert_int(south).is_greater(40)
	assert_int(north).is_greater(10)


func test_two_independent_networks_because_there_are_no_bridges() -> void:
	# the honest consequence of the missing river crossing: each bank needs
	# its own 110/20 kV infeed. If bridges ever land, this is the assertion
	# that should change.
	assert_int(City.model.buildings_of_kind("grid_connection").size()) \
		.is_equal(2)


func test_all_three_networks_are_supplied() -> void:
	var model := City.model
	assert_int(model.buildings_of_kind("substation").size()).is_greater(4)
	assert_int(model.buildings_of_kind("heat_exchanger").size()).is_greater(2)
	assert_int(model.buildings_of_kind("water_station").size()).is_greater(4)
	# ONE heat producer, and it must be the CENTRAL one: the contract
	# carries a single slack, and with it at the west map edge the far
	# exchangers fell to 10 °C and the solve failed outright.
	assert_int(model.buildings_of_kind("chp_plant").size()).is_equal(1)
	assert_int(model.buildings_of_kind("heat_storage").size()).is_equal(1)
	# two wells, both south: the north bank has no water system at all,
	# because WaterTopology solves only the single head's network and the
	# head (the Königstuhl tower) is on this side of the river
	assert_int(model.buildings_of_kind("well").size()).is_equal(2)
	# every line layer got built, and buried: a surface line cannot cross a
	# road, so an overhead trunk would never have entered a district
	assert_int(model.cables.size()).is_greater(100)
	assert_int(model.heat_pipes.size()).is_greater(80)
	assert_int(model.water_pipes.size()).is_greater(100)
	for layer: Dictionary in [model.cables, model.heat_pipes, model.water_pipes]:
		for kind: int in layer.values():
			assert_int(kind).is_equal(BuildingDefs.LINE_UNDERGROUND)


func test_every_network_is_actually_connected() -> void:
	# THE test this city needed. Heat "converged" 9 frames out of 9 while
	# only 2 of its 20 exchangers were in the solved network: the slack
	# plant's tie-in ran through the grid connection's 2x2 footprint and was
	# severed, so HeatTopology fell back to a 2-exchanger island and dropped
	# the 273-tile trunk. A tiny network solves perfectly — CONVERGENCE
	# NEVER IMPLIED COVERAGE, and a tile count did not show it either.
	# The builders' own warnings and zone counts are the honest signal:
	# every builder BFSes from its single source and silently discards
	# whatever it cannot reach.
	var power := PowerTopology.build(City.model, {})
	var heat := HeatTopology.build(City.model, {})
	var water := WaterTopology.build(City.model, {})
	assert_array(power.warnings) \
		.override_failure_message("power topology complained: %s" % [power.warnings]) \
		.is_empty()
	assert_array(heat.warnings) \
		.override_failure_message("heat topology complained: %s" % [heat.warnings]) \
		.is_empty()
	assert_array(water.warnings) \
		.override_failure_message("water topology complained: %s" % [water.warnings]) \
		.is_empty()
	# every station placed must actually BECOME a zone — the gap between
	# "built" and "reachable" is exactly where this bug lived
	var model := City.model
	assert_int(heat.zones_info.size()) \
		.override_failure_message("heat exchangers stranded off the network") \
		.is_equal(model.buildings_of_kind("heat_exchanger").size())
	assert_int(water.zones_info.size()) \
		.override_failure_message("water stations stranded off the network") \
		.is_equal(model.buildings_of_kind("water_station").size())
	assert_int(power.zones_info.size()) \
		.is_equal(model.buildings_of_kind("substation").size()
			+ model.buildings_of_kind("substation_xl").size())


func test_paved_line_is_four_connected() -> void:
	# The primitive behind every street. A rounded interpolation is
	# 8-connected: a diagonal step leaves two tiles touching only at a
	# corner, and since the road renderer picks its piece from ORTHOGONAL
	# neighbours, each such step draws two dead-end caps. That is what the
	# city looked like — "unconnected or … circular bumps".
	var cases: Array[Array] = [
		[Vector2i(0, 0), Vector2i(9, 3)],      # shallow diagonal
		[Vector2i(0, 0), Vector2i(3, 9)],      # steep diagonal
		[Vector2i(5, 5), Vector2i(5, 5)],      # degenerate
		[Vector2i(9, 3), Vector2i(0, 0)],      # reversed
		[Vector2i(7, 2), Vector2i(-4, 11)],    # both axes negative-ish
		[Vector2i(0, 0), Vector2i(12, 12)],    # exact 45°, the worst case
	]
	for case: Array in cases:
		var line := Scenarios.paved_line(case[0], case[1])
		assert_that(line[0]).is_equal(case[0])
		assert_that(line[line.size() - 1]).is_equal(case[1])
		for i in line.size() - 1:
			var step: Vector2i = line[i + 1] - line[i]
			assert_int(absi(step.x) + absi(step.y)) \
				.override_failure_message("%s -> %s is not a single orthogonal step in %s"
					% [line[i], line[i + 1], case]) \
				.is_equal(1)


func test_streets_are_continuous_not_dotted() -> void:
	# The whole-city invariant behind the same bug. Two signals: no tile may
	# stand completely alone (it renders as a capped stub in a field), and
	# the network must be a few big pieces, not dust. Before the fix this
	# city had 97 lonely tiles and 803 diagonal dead ends out of 3 600.
	# Components stay >1 legitimately: the Neckar has no bridges, so each
	# bank is its own network, plus a few outlying stubs at the map edge.
	var health := Scenarios.road_health(City.model.roads)
	assert_int(health["tiles"]).is_greater(2000)
	assert_int(health["lonely"]) \
		.override_failure_message("lone road tiles render as capped stubs") \
		.is_equal(0)
	assert_int(health["components"]) \
		.override_failure_message("street network shattered into fragments") \
		.is_less_equal(30)
	assert_float(float(health["largest"]) / float(health["tiles"])) \
		.override_failure_message("no dominant street network") \
		.is_greater(0.6)


func test_road_health_detects_a_dotted_network() -> void:
	# …and the detector itself has to be able to fail: a diagonal chain is
	# exactly the shape that looked fine in a tile count and broke on screen
	var dotted := {}
	for i in 10:
		dotted[Vector2i(i, i)] = true          # touching only at corners
	var bad := Scenarios.road_health(dotted)
	assert_int(bad["lonely"]).is_equal(10)
	assert_int(bad["components"]).is_equal(10)
	var solid := {}
	for i in 10:
		solid[Vector2i(i, 0)] = true
	var good := Scenarios.road_health(solid)
	assert_int(good["lonely"]).is_equal(0)
	assert_int(good["components"]).is_equal(1)
	assert_int(good["largest"]).is_equal(10)


func test_the_city_has_its_real_thermal_plants() -> void:
	# Heidelberg is heated by Stadtwerke plants, not one shed at the map
	# edge: a gas Heizkraftwerk on the north bank, a peak-load Heizwerk in
	# the middle of town, and the Neckar river-water heat pump. Each must
	# actually reach a heat main, or it is scenery.
	var model := City.model
	assert_int(model.buildings_of_kind("chp_plant").size()).is_equal(1)
	assert_int(model.buildings_of_kind("heat_pump_plant").size()).is_equal(1)
	# NO BOILER, and that is load-bearing rather than an omission. The heat
	# doc has ONE producer (the slack), chosen as plant_ids.sort()[0], and
	# the whole network runs at THAT plant's flow temperature.
	# "boiler_plant" sorts before "chp_plant", so one boiler anywhere drops
	# the city from 85 °C to 66 °C and the far ends stop being servable —
	# heat frames went from 9-in-9 converged to 5, with `failed` among them.
	assert_int(model.buildings_of_kind("boiler_plant").size()).is_equal(0)
	# two gas plants: a small generator in the south and the real
	# Heizkraftwerk Heidelberg, which is a gas CHP in life but can only be
	# a power plant here (see below)
	assert_int(model.buildings_of_kind("gas_plant").size()).is_equal(2)
	# DISTRICT HEATING IS SOUTH-BANK ONLY, and that is a model limit worth
	# pinning: HeatTopology binds ONE slack and drops every pipe it cannot
	# reach from it, so the second heat system a river-split city needs
	# cannot exist. Heat on the north bank silently ate the south's solve.
	# If heat ever grows multi-slack the way power grew islands, this is
	# the assertion that should change.
	var north_heat := 0
	for pos: Vector2i in model.heat_pipes:
		if pos.y < 105:
			north_heat += 1
	assert_int(north_heat).is_equal(0)
	assert_int(model.heat_pipes.size()).is_greater(150)


func test_pressure_tower_stands_on_the_koenigstuhl_slope() -> void:
	# Heidelberg's Hochbehälter sit on the hillside; the game turns that
	# into real head (elevation_m feeds the water solver's boundary)
	var terrain := City.model.terrain
	var towers := City.model.buildings_of_kind("water_tower")
	assert_int(towers.size()).is_equal(1)
	var anchor: Vector2i = City.model.buildings[towers[0]]["anchor"]
	assert_float(terrain.elevation_m(anchor)) \
		.is_greater(terrain.elevation_m(Vector2i(146, 124)) + 40.0)
