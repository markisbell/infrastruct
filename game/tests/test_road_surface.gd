extends GdUnitTestSuite
## The unified road surface's pure geometry. The renderer itself is visual
## (headless skips it); what must never regress is the outline generator —
## its first version emitted every rounded corner as a BOWTIE arc, which
## triangulates to NOTHING, and every corner, stub and isolated tile simply
## vanished from the city while straight grid streets looked fine.


func test_every_neighbour_combination_triangulates() -> void:
	for mask in 16:
		for layer: Array in [[0.0, RoadSurface.SIDEWALK_RADIUS],
				[RoadSurface.ASPHALT_MARGIN, RoadSurface.ASPHALT_RADIUS]]:
			var outline := RoadSurface.tile_outline(
				bool(mask & 1), bool(mask & 2), bool(mask & 4), bool(mask & 8),
				float(layer[0]), float(layer[1]))
			var ccw := PackedVector2Array(outline)
			ccw.reverse()
			assert_int(Geometry2D.triangulate_polygon(ccw).size()) \
				.override_failure_message(
					"mask %d layer %s produced an untriangulatable outline"
					% [mask, layer]) \
				.is_greater(0)


func test_interior_tile_is_the_full_square() -> void:
	var outline := RoadSurface.tile_outline(false, false, false, false,
		0.0, 0.34)
	assert_int(outline.size()).is_equal(4)
	for p: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		assert_bool(p in outline).is_true()


func test_outline_stays_inside_the_tile() -> void:
	# an arc that escapes [0,1]² would overlap the NEIGHBOUR's patch and
	# double-darken the seam
	for mask in 16:
		var outline := RoadSurface.tile_outline(
			bool(mask & 1), bool(mask & 2), bool(mask & 4), bool(mask & 8),
			RoadSurface.ASPHALT_MARGIN, RoadSurface.ASPHALT_RADIUS)
		for p: Vector2 in outline:
			assert_float(p.x).is_between(-0.001, 1.001)
			assert_float(p.y).is_between(-0.001, 1.001)


func test_open_sides_inset_and_neighboured_sides_reach_the_edge() -> void:
	# E/W neighbours, N/S open (a straight street): asphalt insets top and
	# bottom but runs edge-to-edge along the street so patches merge
	var outline := RoadSurface.tile_outline(true, false, true, false,
		0.14, 0.24)
	var min_x := 99.0
	var max_x := -99.0
	var min_y := 99.0
	var max_y := -99.0
	for p: Vector2 in outline:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	# Vector2 components are 32-bit: 0.14 round-trips as 0.14000000059…,
	# so exact equality against a 64-bit literal can never hold
	assert_float(min_x).is_equal_approx(0.0, 0.001)
	assert_float(max_x).is_equal_approx(1.0, 0.001)
	assert_float(min_y).is_equal_approx(0.14, 0.001)
	assert_float(max_y).is_equal_approx(0.86, 0.001)
