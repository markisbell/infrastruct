class_name TerrainMeshBuilder
extends RefCounted
## Terrain geometry (Phase-5 refactor plan, extracted from city_view.gd):
## smoothed-corner ground quads with true face normals, stitch quads for
## cliffs/mixed-corner seams/river banks, and the dipped water surface.
## Pure static build() over a Terrain — returns Packed arrays, so the
## twice-regressed corner rules (Minecraft pass, plateau cap) are
## headless-testable; the renderer owns meshes, materials and the
## vertex_color_is_srgb flag.

## Grass ramp by height level (0 = valley, MAX = rocky top); skirts earthen.
## Realism pass: warmer, more saturated meadow greens (SynerGame reference)
## plus per-tile jitter toward hay.
const TERRAIN_COLORS: Array[Color] = [
	Color(0.36, 0.56, 0.24), Color(0.40, 0.59, 0.25), Color(0.46, 0.61, 0.26),
	Color(0.52, 0.60, 0.28), Color(0.57, 0.56, 0.34), Color(0.60, 0.57, 0.45)]
const MEADOW_JITTER := Color(0.58, 0.60, 0.26)  # dry-grass tint to lerp toward
## bright warm earth: skirts face away from the sun, so the bluish ambient
## dominates them — a dark brown reads as water there, this stays soil
const TERRAIN_SKIRT_COLOR := Color(0.72, 0.58, 0.4)
## rivers: dipped below their valley plateau, saturated blue (vertex color)
const WATER_COLOR := Color(0.2, 0.42, 0.65)
const WATER_DIP := 0.45  # fraction of VISUAL_STEP below the tile's plateau


## Smoothed corner height (the anti-Minecraft pass, user request
## 2026-08-02): mean visual y of the up-to-4 tiles meeting at corner
## (x, z), counting only tiles within ONE level of the asking tile —
## gentle steps become real slopes, >=2-level cliffs keep their edges
## (the stitch quads cover the remaining faces).
static func corner_y(terrain: Terrain, x: int, z: int, ref_level: int) -> float:
	var total := 0.0
	var n := 0
	for tile: Vector2i in [Vector2i(x - 1, z - 1), Vector2i(x, z - 1),
			Vector2i(x - 1, z), Vector2i(x, z)]:
		var lvl := terrain.height(tile)
		if absi(lvl - ref_level) <= 1:
			total += lvl * Terrain.VISUAL_STEP
			n += 1
	if n == 0:
		return ref_level * Terrain.VISUAL_STEP
	# CAP at the tile's own plateau: slopes descend from the UPPER terrace
	# only (rounded tops, crisp lips) — the surface never exceeds a tile's
	# level, so roads/buildings/props at level height always sit clean
	return minf(total / n, ref_level * Terrain.VISUAL_STEP)


static func face_normal(q: Array) -> Vector3:
	var n: Vector3 = (q[2] - q[0]).cross(q[3] - q[1]).normalized()
	return -n if n.y < 0.0 else n


## Rendered surface height of a tile: its plateau, dipped for water — the
## dip is what draws the river bed and banks (skirt rule sees it as lower).
static func tile_y(terrain: Terrain, pos: Vector2i) -> float:
	var y := terrain.height(pos) * Terrain.VISUAL_STEP
	return y - WATER_DIP * Terrain.VISUAL_STEP if terrain.is_water(pos) else y


static func emit_quad(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		corners: Array, normal: Vector3, color: Color) -> void:
	var base := verts.size()
	for corner: Vector3 in corners:
		verts.append(corner)
		normals.append(normal)
		colors.append(color)
	for i: int in [0, 1, 2, 0, 2, 3]:
		indices.append(base + i)


## Full-map geometry: {"ground": Array (Mesh.ARRAY_MAX), "water": Array
## (empty when the map is dry)} ready for add_surface_from_arrays.
static func build(terrain: Terrain, world_tiles: int) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var water_verts := PackedVector3Array()
	var water_normals := PackedVector3Array()
	var water_colors := PackedColorArray()
	var water_indices := PackedInt32Array()
	# color ramp normalized by the MAP's top level: baked DEM regions span
	# ~40 levels, the noise fields 5 — both get the full green->rock ramp
	var top_level := Terrain.MAX_LEVEL
	for x in world_tiles:
		for z in world_tiles:
			top_level = maxi(top_level, terrain.height(Vector2i(x, z)))
	for x in world_tiles:
		for z in world_tiles:
			var pos := Vector2i(x, z)
			var h := terrain.height(pos)
			var y := tile_y(terrain, pos)
			if terrain.is_water(pos):
				# water lives on its own surface (animated shader on top)
				emit_quad(water_verts, water_normals, water_colors,
					water_indices,
					[Vector3(x, y, z), Vector3(x + 1, y, z),
						Vector3(x + 1, y, z + 1), Vector3(x, y, z + 1)],
					Vector3.UP, WATER_COLOR)
				continue
			# meadow patchiness: hash-jitter each tile toward dry grass —
			# flat single-color plains read as plastic, this reads as land
			var color := TERRAIN_COLORS[clampi(int(round(float(h)
				/ float(top_level) * (TERRAIN_COLORS.size() - 1))),
				0, TERRAIN_COLORS.size() - 1)]
			var jitter := float(DecoScatter.tile_hash(pos,
				terrain.seed_value + 17) % 100) / 100.0
			color = color.lerp(MEADOW_JITTER, jitter * 0.18)
			# smoothed corners: 1-level steps become real slopes with true
			# face normals (sun-shaded relief); >=2-level cliffs keep edges
			var c00 := corner_y(terrain, x, z, h)
			var c10 := corner_y(terrain, x + 1, z, h)
			var c11 := corner_y(terrain, x + 1, z + 1, h)
			var c01 := corner_y(terrain, x, z + 1, h)
			var quad: Array = [Vector3(x, c00, z), Vector3(x + 1, c10, z),
				Vector3(x + 1, c11, z + 1), Vector3(x, c01, z + 1)]
			emit_quad(verts, normals, colors, indices, quad,
				face_normal(quad), color)
			# stitch quads close every remaining face: cliff walls AND the
			# small seams mixed-level corners leave (each tile emits only
			# its own DESCENDING faces — no doubles). River banks too.
			for side: Array in [
				[Vector2i(1, 0), Vector2i(x + 1, z), Vector2i(x + 1, z + 1),
					c10, c11, Vector3.RIGHT],
				[Vector2i(-1, 0), Vector2i(x, z + 1), Vector2i(x, z),
					c01, c00, Vector3.LEFT],
				[Vector2i(0, 1), Vector2i(x + 1, z + 1), Vector2i(x, z + 1),
					c11, c01, Vector3.BACK],
				[Vector2i(0, -1), Vector2i(x, z), Vector2i(x + 1, z),
					c00, c10, Vector3.FORWARD],
			]:
				var npos: Vector2i = pos + side[0]
				var na: float
				var nb: float
				if terrain.is_water(npos):
					na = tile_y(terrain, npos)
					nb = na
				else:
					var nh := terrain.height(npos)
					var ca: Vector2i = side[1]
					var cb: Vector2i = side[2]
					na = corner_y(terrain, ca.x, ca.y, nh)
					nb = corner_y(terrain, cb.x, cb.y, nh)
				var ya: float = side[3]
				var yb: float = side[4]
				if ya <= na + 0.001 and yb <= nb + 0.001:
					continue
				var a: Vector2i = side[1]
				var b: Vector2i = side[2]
				emit_quad(verts, normals, colors, indices,
					[Vector3(a.x, ya, a.y), Vector3(b.x, yb, b.y),
						Vector3(b.x, nb, b.y), Vector3(a.x, na, a.y)],
					side[5], TERRAIN_SKIRT_COLOR)
	var ground := []
	ground.resize(Mesh.ARRAY_MAX)
	ground[Mesh.ARRAY_VERTEX] = verts
	ground[Mesh.ARRAY_NORMAL] = normals
	ground[Mesh.ARRAY_COLOR] = colors
	ground[Mesh.ARRAY_INDEX] = indices
	var water := []
	if water_verts.size() > 0:
		water.resize(Mesh.ARRAY_MAX)
		water[Mesh.ARRAY_VERTEX] = water_verts
		water[Mesh.ARRAY_NORMAL] = water_normals
		water[Mesh.ARRAY_COLOR] = water_colors
		water[Mesh.ARRAY_INDEX] = water_indices
	return {"ground": ground, "water": water}
