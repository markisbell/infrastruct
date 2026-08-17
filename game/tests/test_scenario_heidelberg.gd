extends GdUnitTestSuite
## The Heidelberg reference build. These are the assertions that keep the
## city recognisable: the Neckar where the bridges are, districts on their
## real ground, and the three crossings that make it ONE city — power and
## water run over the Theodor-Heuss-Brücke, and only heat stays south, on
## capacity grounds rather than structural ones.


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


func test_each_bank_keeps_its_own_infeed() -> void:
	# This used to be forced: with no way over the river, each bank NEEDED
	# its own 110/20 kV infeed. The banks are bridged now and the cable
	# crosses, so the second one is redundancy rather than necessity — which
	# is also how the real city is fed. Kept at two deliberately: it gives
	# the north bank somewhere to island onto when the crossing trips.
	assert_int(City.model.buildings_of_kind("grid_connection").size()) \
		.is_equal(2)


func test_all_three_networks_are_supplied() -> void:
	var model := City.model
	assert_int(model.buildings_of_kind("substation").size()).is_greater(4)
	assert_int(model.buildings_of_kind("heat_exchanger").size()).is_greater(2)
	assert_int(model.buildings_of_kind("water_station").size()).is_greater(4)
	# TWO CHPs: Heizwerk Mitte on the south bank and the real Heizkraftwerk
	# Heidelberg on the north, each the pressure reference of its OWN
	# district heating system. Heat carried a single reference until
	# 2026-08-17, so the north bank had none at all and the HKW — a gas CHP
	# in life — had to be modelled as a plain power plant.
	assert_int(model.buildings_of_kind("chp_plant").size()).is_equal(2)
	assert_int(model.buildings_of_kind("heat_storage").size()).is_equal(1)
	# two wells, both south — but the north bank drinks from them now. Its
	# mains used to be discarded by WaterTopology, which BFSes from the one
	# head (the Königstuhl tower, on this side); the bridged crossing puts
	# them in the same pressure zone, and water zones went 20 -> 34.
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
	# Components stay >1 legitimately: outlying stubs at the map edge, and
	# whatever the OSM extract left dangling. The banks themselves are no
	# longer among the reasons — the three crossings are decked, and a deck
	# is ordinary ground to the street layer.
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
	# SHAPE, the half that topology cannot see (user: "the streets just do
	# not look right"). The grid has no diagonal road piece, so any street
	# off the axes renders as a staircase of corners; at 51 % corner tiles
	# it read as a sawtooth ribbon rather than a road. Axis-snapping the
	# import brings it to ~20 %. This ceiling is the visual gate.
	assert_int(health["bend_pct"]) \
		.override_failure_message("streets are mostly corners — a sawtooth, not a road") \
		.is_less_equal(30)
	assert_int(health["blobs"]) \
		.override_failure_message("too much solid 2x2 asphalt — blobs, not streets") \
		.is_less(60)
	# dead ends render as capped stubs — the "loose ends". OSM's driveways
	# and service spurs make dozens of them; _hd_prune_stubs trims the short
	# ones, and a road that simply ends at a building is legitimate.
	assert_int(health["stubs"]) \
		.override_failure_message("too many capped dead ends") \
		.is_less(80)


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
	# edge: the gas Heizkraftwerk on the north bank, Heizwerk Mitte in the
	# middle of town, peak-load boilers along the line, and the Neckar
	# river-water heat pump. Each must actually reach a heat main, or it is
	# scenery — and the two CHPs are the pressure reference of one system
	# each, north and south.
	var model := City.model
	assert_int(model.buildings_of_kind("chp_plant").size()).is_equal(2)
	assert_int(model.buildings_of_kind("heat_pump_plant").size()).is_equal(1)
	# THREE SPITZENLASTKESSEL along the line, which is how a real district
	# heating network is fed. This used to pin ZERO boilers, and the reason
	# is worth keeping because both halves of it were real bugs:
	#   1. the slack was `plant_ids.sort()[0]`, so "boiler_plant" outranked
	#      "chp_plant" by STRING and one boiler dropped the whole city from
	#      85 °C to 66 °C — the slack sets the network's supply temperature;
	#   2. secondary plants were `heat_exchanger` feed-ins, which fix HEAT on
	#      a branch whose flow the network decides, so the second one landed
	#      at near-zero flow and its temperature rise exploded.
	# The slack is the hottest plant now and secondaries are pumps, so these
	# can stand. Every one of them must REACH a heat main (below). The
	# fourth is the GKM tie-in at the west energy park (2026-08-17 rebuild):
	# Heidelberg's heat is largely Mannheim waste heat arriving from the
	# west, and a feed-in plant is exactly what that is.
	assert_int(model.buildings_of_kind("boiler_plant").size()).is_equal(4)
	# one gas plant: the small south-bank generator. The Heizkraftwerk that
	# used to be the second is a CHP now (above), which is what it is.
	assert_int(model.buildings_of_kind("gas_plant").size()).is_equal(1)
	# BOTH BANKS ARE HEATED, by two SEPARATE systems. This assertion has
	# been through every stage of the model's understanding: it used to
	# demand zero north-bank heat because HeatTopology bound one slack and
	# silently discarded every pipe it could not reach, so building heat up
	# there cost the south its solve. Heat holds one pressure reference PER
	# CONNECTED COMPONENT now. The two systems stay deliberately unjoined —
	# no heat crosses the bridge — because that is both what the real city
	# has and what keeps Neuenheim's load off the Altstadt's trunk.
	var north_heat := 0
	for pos: Vector2i in model.heat_pipes:
		if pos.y < 100:
			north_heat += 1
	assert_int(north_heat) \
		.override_failure_message("the north bank lost its district heating") \
		.is_greater(40)
	assert_int(model.heat_pipes.size()).is_greater(150)


func test_the_two_heat_systems_stay_independent() -> void:
	# The property that makes this legal: one pressure reference per
	# connected component. Two on one component over-determine the
	# hydraulics and the backend refuses the document outright.
	var topo := HeatTopology.build(City.model, {})
	var producers: Array = topo.doc["native"]["producers"]["producers"]
	assert_int(producers.size()) \
		.override_failure_message("expected one reference per bank, got %d"
			% producers.size()) \
		.is_equal(2)
	# and no heat crosses the river: the systems share no pipe
	var crossing := 0
	for pos: Vector2i in City.model.bridges:
		if City.model.heat_pipes.has(pos):
			crossing += 1
	assert_int(crossing) \
		.override_failure_message("heat crossed the bridge and merged the systems") \
		.is_equal(0)
	# every exchanger on both banks is served
	assert_int(topo.zones_info.size()) \
		.is_equal(City.model.buildings_of_kind("heat_exchanger").size())


func test_the_neckar_is_bridged_and_the_north_bank_joins_the_city() -> void:
	# The river used to cut the map in two: the north bank ran on its OWN
	# grid connection and had no water at all, because WaterTopology BFSes
	# from one head and silently discarded 16 stranded stations. Three real
	# crossings (Ernst-Walz, Theodor-Heuss, Alte Brücke) are decked now, and
	# one run over the Theodor-Heuss carries power and water across.
	var model := City.model
	assert_int(model.bridges.size()) 		.override_failure_message("the Neckar has no crossings").is_greater(30)
	for pos: Vector2i in model.bridges:
		assert_bool(model.terrain.is_water(pos)) 			.override_failure_message("a deck at %s stands on dry land" % pos) 			.is_true()
	# the crossing itself: utilities on decked river tiles, north to south
	var crossed := {"cable": 0, "water": 0}
	for pos: Vector2i in model.bridges:
		if model.cables.has(pos):
			crossed["cable"] += 1
		if model.water_pipes.has(pos):
			crossed["water"] += 1
	assert_int(crossed["cable"]) 		.override_failure_message("no power line crosses the river").is_greater(0)
	assert_int(crossed["water"]) 		.override_failure_message("no water main crosses the river").is_greater(0)
	# and the north bank is genuinely served: water mains north of the river
	var north_water := 0
	for pos: Vector2i in model.water_pipes:
		if pos.y < 95:
			north_water += 1
	assert_int(north_water) 		.override_failure_message("the north bank still has no water") 		.is_greater(20)


func test_the_southern_districts_are_living_city_not_dead_infrastructure() -> void:
	# The 2026-08-17 rebuild's finding: zoning existed ONLY where an OSM
	# footprint landed, and the extract covers just the river strip — so
	# every house stood between y=80 and y=139 while Weststadt and Südstadt
	# had streets, ~21 substations, heat and water on land that could never
	# grow. Dense residential districts in reality; buildable land here.
	var model := City.model
	var south_zoned := 0
	var south_houses := 0
	for pos: Vector2i in model.zoning:
		if pos.y >= 140:
			south_zoned += 1
	for pos: Vector2i in model.houses:
		if pos.y >= 140:
			south_houses += 1
	assert_int(south_zoned) \
		.override_failure_message("the southern districts lost their zoning") \
		.is_greater(300)
	assert_int(south_houses) \
		.override_failure_message("nobody lives south of y=140 again") \
		.is_greater(60)
	# and Südstadt is ON district heating — the corridor carries all three
	# networks now that sized pipes + per-component references allow it
	var sued_heat := 0
	for pos: Vector2i in model.heat_pipes:
		if pos.y >= 155:
			sued_heat += 1
	assert_int(sued_heat) \
		.override_failure_message("Südstadt fell off district heating") \
		.is_greater(20)
	# the heat networks serve a real customer base across the whole city
	var topo := HeatTopology.build(model, {})
	assert_int(topo.zones_info.size()).is_greater(15)


func test_pressure_tower_stands_on_the_koenigstuhl_slope() -> void:
	# Heidelberg's Hochbehälter sit on the hillside; the game turns that
	# into real head (elevation_m feeds the water solver's boundary)
	var terrain := City.model.terrain
	var towers := City.model.buildings_of_kind("water_tower")
	assert_int(towers.size()).is_equal(1)
	var anchor: Vector2i = City.model.buildings[towers[0]]["anchor"]
	assert_float(terrain.elevation_m(anchor)) \
		.is_greater(terrain.elevation_m(Vector2i(146, 124)) + 40.0)
