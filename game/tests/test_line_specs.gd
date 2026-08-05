extends GdUnitTestSuite
## LineSpecs (Phase-5 extraction): the line-tile decision layer where
## most historical regressions lived — the twice-flipped road table, the
## staircase/parallel linkage, the Kabelendmast neighbor-KIND cache key,
## and single-tap service drops.

const OH := BuildingDefs.LINE_OVERHEAD
const UG := BuildingDefs.LINE_UNDERGROUND


static func _town() -> WorldModel:
	var model := WorldModel.new()
	model.terrain = Terrain.new(0)
	return model


func test_road_piece_table_pins_all_sixteen_masks() -> void:
	# mask bits 1=N 2=E 4=S 8=W (fixed twice: 7b5b03a, a78c026)
	var expected := {
		0: ["road-end-round", 90], 1: ["road-end", 270], 2: ["road-end", 180],
		4: ["road-end", 90], 8: ["road-end", 0], 5: ["road-straight", 90],
		10: ["road-straight", 0], 3: ["road-bend", 180], 9: ["road-bend", 270],
		12: ["road-bend", 0], 6: ["road-bend", 90], 14: ["road-intersection", 0],
		7: ["road-intersection", 90], 11: ["road-intersection", 180],
		13: ["road-intersection", 270], 15: ["road-crossroad", 0]}
	for mask: int in expected:
		assert_that(LineSpecs.road_piece(mask)).is_equal(expected[mask])


func test_road_mask_ignores_neighbors_on_other_plateaus() -> void:
	var model := _town()
	model.terrain.force_height(Vector2i(6, 5), Vector2i(6, 5), 1)
	for pos: Vector2i in [Vector2i(4, 5), Vector2i(5, 5), Vector2i(6, 5)]:
		model.set_road(pos)
	# (5,5) joins west (4,5) but NOT the raised east (6,5): a step is a wall
	assert_int(LineSpecs.road_mask(model, Vector2i(5, 5))).is_equal(8)


func test_staircase_stays_one_linked_run() -> void:
	# zigzag steps (how diagonal drags interpolate!) continue on OPPOSITE
	# sides — the first strictly-straight rule shattered every diagonal
	# powerline (user report, 167a60f)
	var model := _town()
	for pos: Vector2i in [Vector2i(4, 4), Vector2i(5, 4), Vector2i(5, 5),
			Vector2i(6, 5), Vector2i(6, 6)]:
		model.set_cable(pos, OH)
	var corner := LineSpecs.cable_spec(model, Vector2i(5, 4))
	assert_int((corner["links"] as Array).size()).is_equal(2)  # W + S
	var mid := LineSpecs.cable_spec(model, Vector2i(5, 5))
	assert_int((mid["links"] as Array).size()).is_equal(2)     # N + E


func test_parallel_runs_do_not_cross_link() -> void:
	# two runs laid side by side (both continuing on a COMMON side) stay
	# electrically separate — the map must show what the solver sees
	var model := _town()
	for x in range(4, 9):
		model.set_cable(Vector2i(x, 4), OH)
		model.set_cable(Vector2i(x, 5), OH)
	var spec := LineSpecs.cable_spec(model, Vector2i(6, 4))
	for link: Dictionary in spec["links"]:
		# only the E/W run neighbors — never the lateral (S) contact
		assert_int(int(link["dir"])).is_not_equal(2)


func test_kabelendmast_dir_and_neighbor_kind_rides_cache_key() -> void:
	var model := _town()
	model.set_cable(Vector2i(4, 4), OH)
	model.set_cable(Vector2i(5, 4), OH)
	model.set_cable(Vector2i(6, 4), OH)
	var plain := LineSpecs.cable_spec(model, Vector2i(5, 4))
	assert_int(int(plain["termination"])).is_equal(-1)
	var plain_key := LineSpecs.cable_cache_key(plain, false, "fp")
	# the eastern neighbor turns buried: the pole must dress as Endmast…
	model.cables[Vector2i(6, 4)] = UG
	var dressed := LineSpecs.cable_spec(model, Vector2i(5, 4))
	assert_int(int(dressed["termination"])).is_equal(1)  # E
	# …and the CACHE KEY must change even though the link set is the same
	# (regression 167a60f: a kind flip must refresh the pole)
	assert_str(LineSpecs.cable_cache_key(dressed, false, "fp")) \
		.is_not_equal(plain_key)
	# a buried tile itself never dresses
	assert_int(int(LineSpecs.cable_spec(model, Vector2i(6, 4))["termination"])) \
		.is_equal(-1)


func test_service_tap_only_at_sorted_first_tile() -> void:
	var model := _town()
	for x in range(4, 10):
		model.set_cable(Vector2i(x, 5), OH)
	assert_str(model.place_building("substation", Vector2i(5, 6), 0)) \
		.is_not_empty()
	# the substation footprint touches the cable row on several tiles but
	# taps exactly ONE (sorted-first); every other adjacency stays bare
	var taps := 0
	for x in range(4, 10):
		taps += (LineSpecs.cable_spec(model, Vector2i(x, 5))["taps"] as Array).size()
	assert_int(taps).is_equal(1)


func test_buried_spec_road_plate_links_and_riser() -> void:
	var model := _town()
	for x in range(4, 8):
		model.set_cable(Vector2i(x, 5), UG)
	model.set_road(Vector2i(6, 5))  # roads may pave over buried-only tiles
	assert_bool(bool(LineSpecs.buried_spec(model, Vector2i(6, 5),
		model.cables, "power")["on_road"])).is_true()
	var mid := LineSpecs.buried_spec(model, Vector2i(5, 5),
		model.cables, "power")
	assert_bool(bool(mid["on_road"])).is_false()
	assert_that(mid["links"]).is_equal([1, 3] as Array[int])  # E + W
	assert_that(mid["risers"]).is_equal([] as Array[int])

func test_pipe_spec_links_taps_and_parallel_rule() -> void:
	var model := _town()
	for x in range(4, 9):
		model.set_heat_pipe(Vector2i(x, 5), OH)
		model.set_heat_pipe(Vector2i(x, 6), OH)  # parallel run below
	var spec := LineSpecs.pipe_spec(model, Vector2i(6, 5),
		model.heat_pipes, "heat")
	# E/W joined; the lateral parallel contact (S) is NEITHER link nor tap
	assert_that(spec["links"]).is_equal([1, 3] as Array[int])
	assert_that(spec["taps"]).is_equal([] as Array[int])


func test_pipe_spec_single_building_tap() -> void:
	var model := _town()
	for x in range(4, 10):
		model.set_water_pipe(Vector2i(x, 5), OH)
	assert_str(model.place_building("water_station", Vector2i(5, 6), 0)) \
		.is_not_empty()
	var taps := 0
	for x in range(4, 10):
		taps += (LineSpecs.pipe_spec(model, Vector2i(x, 5),
			model.water_pipes, "water")["taps"] as Array).size()
	assert_int(taps).is_equal(1)
