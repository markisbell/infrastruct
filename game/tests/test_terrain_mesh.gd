extends GdUnitTestSuite
## TerrainMeshBuilder (Phase-5 extraction): the corner-smoothing rules
## that regressed twice (Minecraft pass; plateau-cap fix) and the stitch
## rules — pinned headless over the Packed geometry arrays.

const AREA := 8


static func _skirt_quads(ground: Array) -> int:
	var colors: PackedColorArray = ground[Mesh.ARRAY_COLOR]
	var count := 0
	for i in range(0, colors.size(), 4):
		if colors[i].is_equal_approx(TerrainMeshBuilder.TERRAIN_SKIRT_COLOR):
			count += 1
	return count


## Tallest vertical span among skirt quads — seams are sub-step, cliff
## walls are full multi-step faces.
static func _max_skirt_span(ground: Array) -> float:
	var colors: PackedColorArray = ground[Mesh.ARRAY_COLOR]
	var verts: PackedVector3Array = ground[Mesh.ARRAY_VERTEX]
	var span := 0.0
	for i in range(0, colors.size(), 4):
		if not colors[i].is_equal_approx(TerrainMeshBuilder.TERRAIN_SKIRT_COLOR):
			continue
		var lo := verts[i].y
		var hi := verts[i].y
		for j in range(i, i + 4):
			lo = minf(lo, verts[j].y)
			hi = maxf(hi, verts[j].y)
		span = maxf(span, hi - lo)
	return span


func test_flat_map_is_quads_only_no_skirts() -> void:
	var terrain := Terrain.new(0)
	var geometry := TerrainMeshBuilder.build(terrain, AREA)
	var ground: Array = geometry["ground"]
	assert_int((ground[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) \
		.is_equal(AREA * AREA * 4)  # one quad per tile, nothing else
	assert_int(_skirt_quads(ground)).is_equal(0)
	assert_bool((geometry["water"] as Array).is_empty()).is_true()


func test_one_level_step_becomes_slope_not_cliff() -> void:
	var terrain := Terrain.new(0)
	terrain.force_height(Vector2i(0, 0), Vector2i(3, 7), 1)  # west half up 1
	var geometry := TerrainMeshBuilder.build(terrain, AREA)
	# the plateau-cap rule: the LOWER tile's corner is capped at its OWN
	# plateau (0.0 — crisp base, roads/props sit clean)...
	assert_float(TerrainMeshBuilder.corner_y(terrain, 4, 4, 0)).is_equal(0.0)
	# ...while the UPPER tile's shared corner descends to the smoothed mean
	# — strictly between the plateaus: that IS the slope
	var upper_corner := TerrainMeshBuilder.corner_y(terrain, 4, 4, 1)
	assert_float(upper_corner).is_greater(0.0)
	assert_float(upper_corner).is_less(1.0 * Terrain.VISUAL_STEP)
	# the cap leaves HALF-HEIGHT seams along the step (documented: stitch
	# quads close "cliffs AND mixed-corner seams") — present but shallow,
	# never a full step face
	assert_int(_skirt_quads(geometry["ground"])).is_greater(0)
	assert_float(_max_skirt_span(geometry["ground"])) \
		.is_less(Terrain.VISUAL_STEP)


func test_two_level_cliff_keeps_edges_and_stitches() -> void:
	var terrain := Terrain.new(0)
	terrain.force_height(Vector2i(0, 0), Vector2i(3, 7), 2)  # west half up 2
	# corners ignore tiles >1 level apart: the lower rim stays at 0, the
	# upper rim at 2 — a crisp cliff lip
	assert_float(TerrainMeshBuilder.corner_y(terrain, 4, 4, 0)).is_equal(0.0)
	assert_float(TerrainMeshBuilder.corner_y(terrain, 4, 4, 2)) \
		.is_equal(2.0 * Terrain.VISUAL_STEP)
	# and the cliff face is closed by FULL-height walls (8 rows of them)
	var geometry := TerrainMeshBuilder.build(terrain, AREA)
	assert_int(_skirt_quads(geometry["ground"])).is_greater_equal(AREA)
	assert_float(_max_skirt_span(geometry["ground"])) \
		.is_greater_equal(2.0 * Terrain.VISUAL_STEP - 0.001)


func test_water_dips_below_plateau_and_banks_stitch() -> void:
	var terrain := Terrain.new(0)
	terrain.force_water(Vector2i(3, 0), Vector2i(4, 7))
	var geometry := TerrainMeshBuilder.build(terrain, AREA)
	var water: Array = geometry["water"]
	assert_bool(water.is_empty()).is_false()
	var water_verts: PackedVector3Array = water[Mesh.ARRAY_VERTEX]
	assert_int(water_verts.size()).is_equal(2 * 8 * 4)
	for vert: Vector3 in water_verts:
		assert_float(vert.y).is_equal_approx(
			-TerrainMeshBuilder.WATER_DIP * Terrain.VISUAL_STEP, 0.0001)
	# the land next to the river emits bank skirts down to the dipped bed
	assert_int(_skirt_quads(geometry["ground"])).is_greater_equal(2 * AREA)


func test_face_normals_are_unit_and_upward() -> void:
	var terrain := Terrain.new(19)
	var geometry := TerrainMeshBuilder.build(terrain, AREA)
	var normals: PackedVector3Array = geometry["ground"][Mesh.ARRAY_NORMAL]
	for i in range(0, normals.size(), 7):  # sample
		assert_float(normals[i].length()).is_equal_approx(1.0, 0.001)
	# ground-quad normals (skirts excluded) must never point down
	var colors: PackedColorArray = geometry["ground"][Mesh.ARRAY_COLOR]
	for i in range(0, normals.size(), 4):
		if not colors[i].is_equal_approx(TerrainMeshBuilder.TERRAIN_SKIRT_COLOR):
			assert_float(normals[i].y).is_greater(0.0)


func test_build_is_deterministic() -> void:
	var a := TerrainMeshBuilder.build(Terrain.new(19), AREA)
	var b := TerrainMeshBuilder.build(Terrain.new(19), AREA)
	assert_that(a["ground"][Mesh.ARRAY_VERTEX]) \
		.is_equal(b["ground"][Mesh.ARRAY_VERTEX])
	assert_that(a["ground"][Mesh.ARRAY_COLOR]) \
		.is_equal(b["ground"][Mesh.ARRAY_COLOR])
