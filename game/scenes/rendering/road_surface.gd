class_name RoadSurface
extends Node3D
## ONE continuous road surface built from the tile raster (2026-08-17,
## user-chosen direction after the ribbon hybrid failed in play: a road
## layer must be all or nothing).
##
## Every road tile contributes a patch that meets its neighbours edge to
## edge, so a street network renders as a single rounded band of asphalt
## with a sidewalk apron — junctions, curves and dead ends all fall out of
## the same rule instead of being special pieces. Two tones from the Kenney
## colormap keep it in the kit's language. Purely visual: the raster stays
## the source of truth for every gameplay rule.

const SIDEWALK_MARGIN := 0.0      # apron runs to the tile edge
const SIDEWALK_RADIUS := 0.34     # outer corner rounding [tiles]
const ASPHALT_MARGIN := 0.14      # asphalt inset inside the apron
const ASPHALT_RADIUS := 0.24
const ARC_STEPS := 4              # segments per rounded corner
# Lifted like a Kenney piece's own thickness: the terrain renders smoothed
# CORNERS, so on a gentle slope the uphill corner rises ~0.15 above the
# tile-centre height a flat patch sits at — at 0.012 the whole west bank's
# streets were buried and only flat-valley tiles showed.
const APRON_LIFT := 0.045          # above terrain, below the asphalt
const ASPHALT_LIFT := 0.058
const SIDEWALK_COLOR := Color(142.0 / 255.0, 149.0 / 255.0, 179.0 / 255.0)
const ASPHALT_COLOR := Color(91.0 / 255.0, 96.0 / 255.0, 115.0 / 255.0)

var _mesh: MeshInstance3D
var _last_roads_hash := 0


## One tile's patch outline in tile-local [0,1]² space. Sides with a
## neighbour run to the tile edge (seamless continuation); open sides pull
## in by *margin*; a corner between two OPEN sides is rounded with *radius*.
static func tile_outline(open_n: bool, open_e: bool, open_s: bool,
		open_w: bool, margin: float, radius: float) -> PackedVector2Array:
	# edges: N = y 0, E = x 1, S = y 1, W = x 0 (tile space, +y south)
	var top := margin if open_n else 0.0
	var right := 1.0 - (margin if open_e else 0.0)
	var bottom := 1.0 - (margin if open_s else 0.0)
	var left := margin if open_w else 0.0
	var out := PackedVector2Array()
	# corners clockwise from NW; each rounded only when BOTH its sides open.
	# dir_in = the direction we ARRIVE along (the arc starts r back along
	# it), dir_out = the direction we LEAVE along — swapping them draws the
	# arc backwards and the outline self-intersects into a bowtie, which
	# triangulates to NOTHING: every corner and stub tile simply vanished
	# from the first build while straight grid streets looked fine.
	# dir_in / dir_out are the clockwise TRAVEL directions at the corner:
	# the arc starts r BEHIND the corner on the incoming edge and ends r
	# PAST it on the outgoing one — both anchors on the outline itself, so
	# the arc can never escape the tile (pinned by test; the first version
	# anchored off the edges and bulged onto the neighbouring grass).
	_corner(out, Vector2(left, top), Vector2(0, -1), Vector2(1, 0),
		radius if (open_n and open_w) else 0.0)
	_corner(out, Vector2(right, top), Vector2(1, 0), Vector2(0, 1),
		radius if (open_n and open_e) else 0.0)
	_corner(out, Vector2(right, bottom), Vector2(0, 1), Vector2(-1, 0),
		radius if (open_s and open_e) else 0.0)
	_corner(out, Vector2(left, bottom), Vector2(-1, 0), Vector2(0, -1),
		radius if (open_s and open_w) else 0.0)
	return out


static func _corner(out: PackedVector2Array, at: Vector2, dir_in: Vector2,
		dir_out: Vector2, radius: float) -> void:
	if radius <= 0.0:
		out.append(at)
		return
	# quarter arc from r BACK along the arrival edge to r FORWARD along the
	# leaving edge, bulging toward the corner point
	var from := at - dir_in * radius
	var to := at + dir_out * radius
	var centre := at - dir_in * radius + dir_out * radius
	var a0 := (from - centre).angle()
	var a1 := (to - centre).angle()
	# walk the short way around
	var diff := wrapf(a1 - a0, -PI, PI)
	for i in ARC_STEPS + 1:
		var a := a0 + diff * float(i) / float(ARC_STEPS)
		out.append(centre + Vector2(cos(a), sin(a)) * radius)


## Rebuild when the raster changed. The whole network is one mesh with two
## surfaces (apron, asphalt) — ~30k triangles for a 3 300-tile city, built
## in one pass and untouched until a road is built or bulldozed.
func sync(roads: Dictionary, ground: Callable) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var roads_hash := roads.hash()
	if roads_hash == _last_roads_hash:
		return
	_last_roads_hash = roads_hash
	if _mesh != null:
		_mesh.queue_free()
	_mesh = MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	for layer: Array in [[SIDEWALK_MARGIN, SIDEWALK_RADIUS, APRON_LIFT,
			SIDEWALK_COLOR], [ASPHALT_MARGIN, ASPHALT_RADIUS, ASPHALT_LIFT,
			ASPHALT_COLOR]]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for pos: Vector2i in roads:
			var outline := tile_outline(
				not roads.has(pos + Vector2i(0, -1)),
				not roads.has(pos + Vector2i(1, 0)),
				not roads.has(pos + Vector2i(0, 1)),
				not roads.has(pos + Vector2i(-1, 0)),
				float(layer[0]), float(layer[1]))
			var h := float(ground.call(pos)) + float(layer[2])
			var ccw := PackedVector2Array(outline)
			ccw.reverse()   # triangulate_polygon wants counter-clockwise
			var indices := Geometry2D.triangulate_polygon(ccw)
			for j in indices:
				var p := ccw[j]
				st.set_normal(Vector3.UP)
				st.add_vertex(Vector3(pos.x + p.x, h, pos.y + p.y))
		st.index()
		var material := StandardMaterial3D.new()
		material.albedo_color = layer[3]
		material.roughness = 1.0
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		st.set_material(material)
		st.commit(mesh)
	_mesh.mesh = mesh
	add_child(_mesh)


func reset() -> void:
	if _mesh != null:
		_mesh.queue_free()
		_mesh = null
	_last_roads_hash = 0
