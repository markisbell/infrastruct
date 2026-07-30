class_name CityView
extends Node3D
## Renders City.model in real 3D (ADR-005): locked isometric orthographic
## camera, Kenney CC0 GLB models + procedural fills, incremental instance
## diffing per layer. Same public API as the 2D version: Tool, tool,
## overlays_visible, redraw(), mouse_tile().
## One tile = 1.0 world unit; tile (x, y) occupies [x, x+1)×[y, y+1) on the
## ground plane, model centers at (x+0.5, 0, y+0.5).

enum Tool { NONE, ROAD, ZONE, CABLE, SUBSTATION, GAS, WIND, SOLAR, BATTERY, GRID,
	BULLDOZE, PIPE, HEAT_SUB, BOILER, CHP, HEATPUMP, HEATSTORE,
	WATER_PIPE, WATER_SUB, WELL, PUMP, WATER_TOWER, UCABLE, REPAIR,
	BURIED_PIPE, BURIED_WATER }

const TOOL_BUILDING := {
	Tool.SUBSTATION: "substation", Tool.GAS: "gas_plant", Tool.WIND: "wind_farm",
	Tool.SOLAR: "solar_park", Tool.BATTERY: "battery", Tool.GRID: "grid_connection",
	Tool.HEAT_SUB: "heat_exchanger", Tool.BOILER: "boiler_plant",
	Tool.CHP: "chp_plant", Tool.HEATPUMP: "heat_pump_plant",
	Tool.HEATSTORE: "heat_storage",
	Tool.WATER_SUB: "water_station", Tool.WELL: "well",
	Tool.PUMP: "pumping_station", Tool.WATER_TOWER: "water_tower",
}

const KENNEY := "res://assets/kenney/"

## Left click with NO tool active selects infrastructure (HUD inspector).
signal building_clicked(id: String)
## Same for line/pipe tiles: category is "cable" | "heat_pipe" | "water_pipe".
signal tile_infra_clicked(category: String, pos: Vector2i)

## Network color language (user direction): heat = red/blue double pipe
## (forward/return — physically honest, the backend models both sides);
## water (Phase 5) = green.
const PIPE_SUPPLY_COLOR := Color(0.85, 0.22, 0.15)
const PIPE_RETURN_COLOR := Color(0.2, 0.38, 0.85)
const WATER_PIPE_COLOR := Color(0.2, 0.7, 0.35)
const PIPE_HEIGHT := 0.16
const HOUSE_VARIANTS := ["a", "b", "c", "d", "e", "f", "g", "h", "l", "m", "n", "q"]

var tool: Tool = Tool.NONE:
	set(value):
		tool = value
		_cancel_drag()  # a half-drawn ghost path dies with its tool
var overlays_visible := true:
	set(value):
		overlays_visible = value
		_apply_overlay_visibility()

var camera: Camera3D
var _zoom := 18.0
var _cam_focus := Vector3(128.5, 0, 128.5)
var _cam_yaw := 0.0          # current, degrees
var _cam_yaw_target := 0.0   # Q/E rotate in 90° steps, smoothed in _process

# ghost placement preview (adapted from Kenney's Starter-Kit-City-Builder, MIT)
var _ghost: Node3D
var _ghost_kind := ""
var _ghost_rot := 0
var _ghost_flip := false
var _ghost_disc: MeshInstance3D

## drag-and-draw ghost path (lines/pipes/roads/zones): hold LMB to sketch,
## release to build — red from the first blockage on (user-specified UX)
const PATH_TOOL_BUILD := {
	Tool.ROAD: "road", Tool.ZONE: "zone",
	Tool.CABLE: "cable_overhead", Tool.UCABLE: "cable_buried",
	Tool.PIPE: "heat", Tool.BURIED_PIPE: "heat_buried",
	Tool.WATER_PIPE: "water", Tool.BURIED_WATER: "water_buried",
}
## ghost tint per path tool (the element's own color language, faded)
const PATH_TOOL_COLOR := {
	Tool.ROAD: Color(0.45, 0.45, 0.5), Tool.ZONE: Color(0.45, 0.8, 0.4),
	Tool.CABLE: Color(0.45, 0.36, 0.28), Tool.UCABLE: Color(0.36, 0.33, 0.29),
	Tool.PIPE: PIPE_SUPPLY_COLOR, Tool.BURIED_PIPE: Color(0.36, 0.33, 0.29),
	Tool.WATER_PIPE: WATER_PIPE_COLOR, Tool.BURIED_WATER: Color(0.36, 0.33, 0.29),
}
const PATH_BLOCKED_COLOR := Color(0.95, 0.22, 0.18)
var _drag_path: Array[Vector2i] = []
var _drag_active := false
var _path_ghost: Node3D
var _path_quads: Array[MeshInstance3D] = []

# build feedback (user direction): coverage diamonds while placing zone
# stations, disconnection markers on network buildings, orphan markers on
# houses outside every service area
var _range_discs := {}       # building id -> MeshInstance3D
var _status_markers := {}    # building id -> Label3D
var _orphan_markers := {}    # house pos -> Label3D

# pos/id -> Node3D, one dict per layer (incremental diff in redraw)
var _roads := {}
var _cables := {}
var _pipes := {}
var _water_pipes := {}
var _zones := {}
var _houses := {}
var _buildings := {}
var _rings := {}          # zone/slack overlay rings
var _cursor: MeshInstance3D
var _painting := false
## Right mouse: drag orbits the camera freely around the focus (any angle);
## a click without movement keeps the quick-bulldoze convenience.
var _orbiting := false
var _orbit_travel := 0.0

var _dark_material := StandardMaterial3D.new()
var _cold_material := StandardMaterial3D.new()
var _house_scene_cache := {}

var _terrain_mesh: MeshInstance3D
var _water_mesh: MeshInstance3D
var _terrain_fingerprint := ""

## Animated river surface: albedo shimmer + low roughness for sun glints.
const WATER_SHADER := "
shader_type spatial;
uniform vec3 shallow : source_color = vec3(0.17, 0.43, 0.60);
uniform vec3 deep : source_color = vec3(0.07, 0.23, 0.40);
void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float wave = sin(world.x * 1.9 + TIME * 0.9) * sin(world.z * 1.4 + TIME * 0.7)
		+ 0.5 * sin((world.x + world.z) * 3.1 - TIME * 1.3);
	ALBEDO = mix(deep, shallow, 0.5 + 0.28 * wave);
	ROUGHNESS = 0.12;
	SPECULAR = 0.7;
}
"

## Grass ramp by height level (0 = valley, MAX = rocky top); skirts earthen.
## Realism pass: warmer, more saturated meadow greens (SynerGame reference)
## plus per-tile jitter toward hay — see MEADOW_JITTER in _rebuild_terrain.
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
const WORLD_TILES := 256


func _ready() -> void:
	_build_environment()
	_dark_material.albedo_color = Color(0.16, 0.17, 0.22)
	_cold_material.albedo_color = Color(0.55, 0.68, 0.88)  # cold homes: icy blue
	_cursor = MeshInstance3D.new()
	var cursor_mesh := PlaneMesh.new()
	cursor_mesh.size = Vector2(1.0, 1.0)
	_cursor.mesh = cursor_mesh
	_cursor.material_override = _flat(Color(1, 1, 1, 0.35), true)
	_cursor.position.y = 0.02
	add_child(_cursor)
	City.world_changed.connect(redraw)
	City.power_result.connect(func(_t: int, _r: Dictionary) -> void:
		_update_overlays()
		_update_house_power())
	City.heat_result.connect(func(_t: int, _r: Dictionary) -> void:
		_update_overlays()
		_update_house_power())
	City.water_result.connect(func(_t: int, _r: Dictionary) -> void:
		_update_overlays())
	redraw()


var _sun: DirectionalLight3D
var _sky_material: ProceduralSkyMaterial
var _env: Environment
## daytime sky anchors — the day/night cycle lerps these toward night navy
const SKY_TOP_DAY := Color(0.33, 0.52, 0.78)
const SKY_HORIZON_DAY := Color(0.74, 0.82, 0.88)
const SKY_TOP_NIGHT := Color(0.045, 0.06, 0.13)
const SKY_HORIZON_NIGHT := Color(0.10, 0.12, 0.2)


func _build_environment() -> void:
	# realism pass (SynerGame reference): warm soft daylight + sky ambient +
	# SSAO + filmic tonemap + gentle glow/fog — Forward+ features
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -32, 0)
	sun.shadow_enabled = true
	sun.light_color = Color(1.0, 0.965, 0.89)  # late-morning warmth
	sun.light_energy = 1.5
	sun.shadow_blur = 1.2
	sun.directional_shadow_max_distance = 220.0
	sun.directional_shadow_split_1 = 0.08
	add_child(sun)
	_sun = sun
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = SKY_TOP_DAY
	sky_material.sky_horizon_color = SKY_HORIZON_DAY
	sky_material.ground_bottom_color = Color(0.32, 0.38, 0.3)
	sky_material.ground_horizon_color = Color(0.72, 0.79, 0.83)
	_sky_material = sky_material
	env.sky = Sky.new()
	env.sky.sky_material = sky_material
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# sky ambient at reduced energy: full blue fill made shadow-side faces
	# (esp. terrain skirts) read as water — the old vertex-color gotcha —
	# and too much of it flattens the sun shadows the look depends on
	env.ambient_light_sky_contribution = 0.55
	env.ambient_light_energy = 0.65
	# ACES over FILMIC: filmic bleached the greens pastel; ACES keeps the
	# SynerGame-style saturated meadow under the same sun
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_intensity = 2.0
	env.ssao_power = 1.5
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = true
	env.fog_light_color = Color(0.78, 0.84, 0.9)
	# the camera orbits ~90 units out — exponential fog stronger than this
	# washes the WHOLE frame pastel (first attempt: 0.0035 = 27% fog on
	# everything); this keeps it a distant-hill hint only
	env.fog_density = 0.0006
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.28
	env.adjustment_contrast = 1.06
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	_env = env
	_spawn_clouds()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	add_child(camera)
	_place_camera()
	camera.make_current()


# ─── day/night cycle + drifting clouds (user request) ───

var _clouds: Array[Node3D] = []
const CLOUD_COUNT := 26


## Sun elevation/azimuth, light energy/color, ambient and sky colors all
## follow the GAME clock: nights go dim blue (never black — the city must
## stay playable), dawn/dusk glow warm, noon is the bright reference look.
func _update_daylight() -> void:
	if _sun == null:
		return
	var hour := fmod(GameClock.total_minutes, 1440.0) / 60.0
	# light from ~05:30 to ~19:30 (sin window), so evenings really glow
	var daylight := clampf(sin((hour - 5.5) / 14.0 * PI), 0.0, 1.0)
	var dusk := clampf(1.0 - absf(daylight - 0.2) / 0.2, 0.0, 1.0) \
		* (1.0 if daylight > 0.0 else 0.0)
	# gamma-eased: evenings stay usable-bright well past 18:00 before the
	# night floor (0.28 — dim blue, never black) takes over
	var brightness := pow(daylight, 0.65)
	_sun.light_energy = lerpf(0.28, 1.5, brightness)
	var day_color := Color(1.0, 0.965, 0.89).lerp(Color(1.0, 0.62, 0.38), dusk)
	_sun.light_color = Color(0.62, 0.7, 0.95).lerp(day_color, brightness)
	# the sun ARCS: shallow at dawn/dusk, high at noon; azimuth sweeps east
	# to west across the day (at night it parks as faint moonlight)
	_sun.rotation_degrees.x = -lerpf(10.0, 52.0, daylight)
	if daylight > 0.0:
		_sun.rotation_degrees.y = lerpf(-75.0, 15.0,
			clampf((hour - 5.5) / 14.0, 0.0, 1.0))
	_env.ambient_light_energy = lerpf(0.32, 0.75, brightness)
	# fog must darken with the sky — daylight-colored fog washed the night
	# scene in a bright teal haze
	_env.fog_light_color = Color(0.05, 0.07, 0.12).lerp(
		Color(0.78, 0.84, 0.9), daylight)
	_sky_material.sky_top_color = SKY_TOP_NIGHT.lerp(SKY_TOP_DAY, daylight)
	_sky_material.sky_horizon_color = SKY_HORIZON_NIGHT.lerp(
		SKY_HORIZON_DAY, daylight).lerp(Color(0.95, 0.6, 0.4), dusk * 0.6)


## A fleet of soft puff clusters drifting with the weather's wind — they
## cast REAL moving shadows (alpha-hash keeps them in the shadow pass).
func _spawn_clouds() -> void:
	var crng := RandomNumberGenerator.new()
	crng.seed = 777
	# smooth alpha puffs render clean but can't cast shadows — an invisible
	# SHADOWS_ONLY twin per puff throws the moving cloud shadow instead
	# (alpha-hash cast shadows but dithered the puffs into speckle)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.99, 0.99, 1.0, 0.82)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 1.0
	for i in CLOUD_COUNT:
		var cloud := Node3D.new()
		for p in crng.randi_range(3, 5):
			var sphere := SphereMesh.new()
			var radius := crng.randf_range(1.4, 2.8)
			sphere.radius = radius
			sphere.height = radius
			sphere.radial_segments = 16
			sphere.rings = 8
			var spot := Vector3(crng.randf_range(-2.8, 2.8),
				crng.randf_range(-0.2, 0.4), crng.randf_range(-1.6, 1.6))
			var puff := MeshInstance3D.new()
			puff.mesh = sphere
			puff.scale = Vector3(1.7, 0.5, 1.25)
			puff.position = spot
			puff.material_override = material
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cloud.add_child(puff)
			var shadow_twin := MeshInstance3D.new()
			shadow_twin.mesh = sphere
			shadow_twin.scale = puff.scale
			shadow_twin.position = spot
			shadow_twin.cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			cloud.add_child(shadow_twin)
		cloud.position = Vector3(crng.randf_range(0.0, 256.0),
			crng.randf_range(12.0, 17.0), crng.randf_range(0.0, 256.0))
		add_child(cloud)
		_clouds.append(cloud)


func _drift_clouds(delta: float) -> void:
	var wind := float(City.weather.sample(City.current_t).get("wind_ms", 5.0))
	var speed := 0.35 + wind * 0.05
	for cloud: Node3D in _clouds:
		cloud.position.x += speed * delta
		cloud.position.z += speed * 0.22 * delta
		if cloud.position.x > 262.0:
			cloud.position.x = -6.0
		if cloud.position.z > 262.0:
			cloud.position.z = -6.0


func _place_camera() -> void:
	camera.size = _zoom
	var direction := Vector3(-1, 1.15, -1).normalized() \
		.rotated(Vector3.UP, deg_to_rad(_cam_yaw))
	camera.position = _cam_focus + direction * 90.0
	camera.look_at(_cam_focus, Vector3.UP)


## Q/E snap to the NEXT axis-aligned view in that direction — after a free
## right-drag orbit to e.g. 37°, E goes to 90°, Q back to 0°.
func rotate_view(steps: int) -> void:
	if steps > 0:
		_cam_yaw_target = (floorf(_cam_yaw_target / 90.0) + 1.0) * 90.0
	else:
		_cam_yaw_target = (ceilf(_cam_yaw_target / 90.0) - 1.0) * 90.0


func focus_tile(tile: Vector2i, zoom: float = 18.0) -> void:
	_zoom = zoom
	_cam_focus = Vector3(tile.x + 0.5, 0, tile.y + 0.5)
	_place_camera()


# ─── redraw: incremental diff per layer ───

func redraw() -> void:
	var model: WorldModel = City.model
	_rebuild_terrain()
	_rebuild_deco()
	_diff(_zones, model.zoning, _make_zone)
	_diff(_roads, model.roads, _make_road)
	_diff(_cables, model.cables, _make_cable)
	_diff(_pipes, model.heat_pipes, _make_pipe)
	_diff(_water_pipes, model.water_pipes, _make_water_pipe)
	_diff(_houses, model.houses, _make_house)
	_diff(_buildings, model.buildings, _make_building)
	# neighbor-dependent pieces refresh in place. When City hands us the
	# tiles it touched, re-orient only those + neighbors — the full pass is
	# O(city) per placed tile and stalled drags ~36 ms on a modest town.
	var dirty: Dictionary = City.dirty_tiles
	City.dirty_tiles = {}
	if dirty.is_empty():
		for pos: Vector2i in _roads:
			_orient_road(pos, _roads[pos])
		for pos: Vector2i in _cables:
			_orient_cable(pos, _cables[pos])
		for pos: Vector2i in _pipes:
			_orient_pipe(pos, _pipes[pos])
		for pos: Vector2i in _water_pipes:
			_orient_water_pipe(pos, _water_pipes[pos])
	else:
		var affected := {}
		for pos: Vector2i in dirty:
			affected[pos] = true
			for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				affected[pos + offset] = true
		for pos: Vector2i in affected:
			if _roads.has(pos):
				_orient_road(pos, _roads[pos])
			if _cables.has(pos):
				_orient_cable(pos, _cables[pos])
			if _pipes.has(pos):
				_orient_pipe(pos, _pipes[pos])
			if _water_pipes.has(pos):
				_orient_water_pipe(pos, _water_pipes[pos])
	_update_house_power()
	_update_overlays()


func _diff(nodes: Dictionary, source: Dictionary, maker: Callable) -> void:
	for key: Variant in nodes.keys():
		if not source.has(key):
			nodes[key].queue_free()
			nodes.erase(key)
	for key: Variant in source:
		if not nodes.has(key):
			var node: Node3D = maker.call(key)
			add_child(node)
			nodes[key] = node


# ─── terrain (stepped plateaus, one static ArrayMesh, rebuilt on change) ───

func _ground_y(pos: Vector2i) -> float:
	return City.model.terrain.visual_y(pos)


func _rebuild_terrain() -> void:
	var terrain: Terrain = City.model.terrain
	if terrain.fingerprint() == _terrain_fingerprint:
		return
	_terrain_fingerprint = terrain.fingerprint()
	if _terrain_mesh:
		_terrain_mesh.queue_free()
	if _water_mesh:
		_water_mesh.queue_free()
		_water_mesh = null
	# heights moved under everything: flush all layers so _diff recreates
	# them at the new ground levels (matters after loading a save)
	for layer: Dictionary in [_roads, _cables, _pipes, _water_pipes, _zones,
			_houses, _buildings, _rings, _range_discs]:
		for key: Variant in layer:
			if is_instance_valid(layer[key]):
				layer[key].queue_free()
		layer.clear()
	_status_markers.clear()   # children of freed buildings
	_orphan_markers.clear()   # children of freed houses
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var water_verts := PackedVector3Array()
	var water_normals := PackedVector3Array()
	var water_colors := PackedColorArray()
	var water_indices := PackedInt32Array()
	for x in WORLD_TILES:
		for z in WORLD_TILES:
			var pos := Vector2i(x, z)
			var h := terrain.height(pos)
			var y := _tile_y(terrain, pos)
			if terrain.is_water(pos):
				# water lives on its own surface (animated shader below)
				_emit_quad(water_verts, water_normals, water_colors,
					water_indices,
					[Vector3(x, y, z), Vector3(x + 1, y, z),
						Vector3(x + 1, y, z + 1), Vector3(x, y, z + 1)],
					Vector3.UP, WATER_COLOR)
				continue
			# meadow patchiness: hash-jitter each tile toward dry grass —
			# flat single-color plains read as plastic, this reads as land
			var color := TERRAIN_COLORS[clampi(h, 0, TERRAIN_COLORS.size() - 1)]
			var jitter := float(_tile_hash(pos, terrain.seed_value + 17) % 100) / 100.0
			color = color.lerp(MEADOW_JITTER, jitter * 0.18)
			_emit_quad(verts, normals, colors, indices,
				[Vector3(x, y, z), Vector3(x + 1, y, z),
					Vector3(x + 1, y, z + 1), Vector3(x, y, z + 1)],
				Vector3.UP, color)
			# skirts where this plateau stands above a neighbor (each tile
			# emits only its own descending faces — no doubles); river banks
			# come out of the same rule (water tiles dip below their plateau)
			for side: Array in [
				[Vector2i(1, 0), Vector3(x + 1, 0, z), Vector3(x + 1, 0, z + 1), Vector3.RIGHT],
				[Vector2i(-1, 0), Vector3(x, 0, z + 1), Vector3(x, 0, z), Vector3.LEFT],
				[Vector2i(0, 1), Vector3(x + 1, 0, z + 1), Vector3(x, 0, z + 1), Vector3.BACK],
				[Vector2i(0, -1), Vector3(x, 0, z), Vector3(x + 1, 0, z), Vector3.FORWARD],
			]:
				var neighbor_y: float = _tile_y(terrain, pos + side[0])
				if neighbor_y >= y:
					continue
				var a: Vector3 = side[1]
				var b: Vector3 = side[2]
				_emit_quad(verts, normals, colors, indices,
					[Vector3(a.x, y, a.z), Vector3(b.x, y, b.z),
						Vector3(b.x, neighbor_y, b.z), Vector3(a.x, neighbor_y, a.z)],
					side[3], TERRAIN_SKIRT_COLOR)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_terrain_mesh = MeshInstance3D.new()
	_terrain_mesh.mesh = mesh
	_terrain_mesh.position.y = -0.01  # tile decals at ground level stay on top
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	# Forward+ treats vertex colors as LINEAR by default — our palette is
	# authored in sRGB; without this flag every green renders bleached
	material.vertex_color_is_srgb = true
	material.roughness = 0.95  # grass never glints
	# skirt quads are wound per-side; skip the culling bookkeeping entirely —
	# lighting stays correct via the explicit face normals
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_terrain_mesh.material_override = material
	add_child(_terrain_mesh)
	if water_verts.size() > 0:
		var water_arrays := []
		water_arrays.resize(Mesh.ARRAY_MAX)
		water_arrays[Mesh.ARRAY_VERTEX] = water_verts
		water_arrays[Mesh.ARRAY_NORMAL] = water_normals
		water_arrays[Mesh.ARRAY_COLOR] = water_colors
		water_arrays[Mesh.ARRAY_INDEX] = water_indices
		var water_array_mesh := ArrayMesh.new()
		water_array_mesh.add_surface_from_arrays(
			Mesh.PRIMITIVE_TRIANGLES, water_arrays)
		_water_mesh = MeshInstance3D.new()
		_water_mesh.mesh = water_array_mesh
		_water_mesh.position.y = -0.01
		var water_shader := Shader.new()
		water_shader.code = WATER_SHADER
		var water_material := ShaderMaterial.new()
		water_material.shader = water_shader
		_water_mesh.material_override = water_material
		add_child(_water_mesh)


## Rendered surface height of a tile: its plateau, dipped for water — the
## dip is what draws the river bed and banks (skirt rule sees it as lower).
static func _tile_y(terrain: Terrain, pos: Vector2i) -> float:
	var y := terrain.height(pos) * Terrain.VISUAL_STEP
	return y - WATER_DIP * Terrain.VISUAL_STEP if terrain.is_water(pos) else y


# ─── environment decoration (Kenney mini-forest, deterministic scatter) ───
#
# Props CLUSTER like real terrain features (user direction: grouped, not
# sprinkled anywhere): a low-frequency noise field carves GROVES (dense
# trees) and STONE FIELDS (dense rocks), rivers grow a riparian tree
# strip, and the land between stays almost bare — the occasional lone
# patch or boulder. Deterministic per (tile, terrain seed), rendered as
# ONE MultiMesh per variant. Anything built on a tile removes its prop
# (occupancy filter runs per redraw); zoned land is kept clean.

const MINI_FOREST := "mini-forest/Models/GLB format/"
## variant -> {file, fit (footprint in world units)}.
## The pack also ships bridge.glb — the hook for river crossings later.
const DECO_KINDS := {
	"tree":        {"file": "tree.glb",        "fit": 0.55},
	"tree_high":   {"file": "tree-high.glb",   "fit": 0.5},
	"plant":       {"file": "plant.glb",       "fit": 0.35},
	"stones":      {"file": "stones.glb",      "fit": 0.35},
	"rocks_low":   {"file": "rocks-low.glb",   "fit": 0.5},
	"rocks_high":  {"file": "rocks-high.glb",  "fit": 0.55},
	"patch_dirt":  {"file": "patch-dirt.glb",  "fit": 0.85},
	"patch_grass": {"file": "patch-grass.glb", "fit": 0.85},
}
## category -> [weighted variant pool, density (fraction of member tiles)]
const DECO_POOLS := {
	"grove":    {"pool": ["tree", "tree", "tree", "tree_high", "tree_high",
		"plant", "patch_grass"], "density": 0.62},
	"rocks":    {"pool": ["stones", "stones", "rocks_low", "rocks_low",
		"rocks_high", "patch_dirt"], "density": 0.25},
	"riparian": {"pool": ["tree", "tree", "plant", "plant", "patch_grass"],
		"density": 0.45},
	"sparse":   {"pool": ["patch_dirt", "patch_grass", "stones", "plant",
		"tree"], "density": 0.012},
}
## cluster field: > this = grove, < negative rock threshold = stone field
## (grove threshold lowered in the graphics pass: bigger forest masses)
const GROVE_LEVEL := 0.22
const ROCKS_LEVEL := -0.42

var _deco_nodes := {}        # variant -> MultiMeshInstance3D
var _deco_lib := {}          # variant -> {mesh, base: Transform3D} | null
var _deco_scatter: Array[Dictionary] = []   # per terrain fingerprint
var _deco_scatter_fp := ""
var _deco_noise := FastNoiseLite.new()


static func _tile_hash(pos: Vector2i, seed_value: int) -> int:
	# cheap 2D integer hash — deterministic prop placement per (tile, seed)
	var h := pos.x * 73856093 ^ pos.y * 19349663 ^ seed_value * 83492791
	return absi(h)


func _rebuild_deco() -> void:
	if DisplayServer.get_name() == "headless":
		return  # smokes never look at props; skip the 65k-tile scatter
	var terrain: Terrain = City.model.terrain
	if terrain.fingerprint() != _deco_scatter_fp:
		_deco_scatter_fp = terrain.fingerprint()
		_deco_scatter.clear()
		_deco_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		_deco_noise.seed = terrain.seed_value + 4021
		_deco_noise.frequency = 0.045  # grove/stone-field features ~20 tiles
		# pass 1: river tiles as a set — the riparian strip needs cheap
		# neighborhood lookups, not 13 noise evaluations per tile
		var water := {}
		for x in WORLD_TILES:
			for z in WORLD_TILES:
				var pos := Vector2i(x, z)
				if terrain.is_water(pos):
					water[pos] = true
		# pass 2: category per tile, then the category's density gate
		for x in WORLD_TILES:
			for z in WORLD_TILES:
				var pos := Vector2i(x, z)
				if water.has(pos):
					continue
				var c := _deco_noise.get_noise_2d(float(x), float(z))
				var category := "sparse"
				if c > GROVE_LEVEL:
					category = "grove"
				elif c < ROCKS_LEVEL:
					category = "rocks"
				else:
					for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
							Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1),
							Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
							Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2),
							Vector2i(0, -2)]:
						if water.has(pos + offset):
							category = "riparian"
							break
				var h := _tile_hash(pos, terrain.seed_value)
				var spec: Dictionary = DECO_POOLS[category]
				if h % 1000 >= int(float(spec["density"]) * 1000.0):
					continue
				var pool: Array = spec["pool"]
				_deco_scatter.append({"pos": pos,
					"variant": pool[(h / 1000) % pool.size()], "h": h})
	# occupancy pass: a prop lives only on truly empty, unzoned land the
	# bulldozer hasn't cleared
	var model: WorldModel = City.model
	var buckets := {}
	for entry: Dictionary in _deco_scatter:
		var pos: Vector2i = entry["pos"]
		if not model.is_tile_free(pos) or model.zoning.has(pos) \
				or model.deco_cleared.has(pos):
			continue
		var variant: String = entry["variant"]
		if not buckets.has(variant):
			buckets[variant] = []
		var h: int = entry["h"]
		var jitter := Vector3((h % 41) / 41.0 - 0.5, 0.0,
			(h % 37) / 37.0 - 0.5) * 0.55
		var spot := Vector3(pos.x + 0.5, _ground_y(pos), pos.y + 0.5) + jitter
		buckets[variant].append(Transform3D(
			Basis(Vector3.UP, TAU * float(h % 97) / 97.0), spot))
	for variant: String in DECO_KINDS:
		var lib: Variant = _deco_lib_entry(variant)
		var transforms: Array = buckets.get(variant, [])
		if lib == null:
			continue
		var entry: Dictionary = lib
		if not _deco_nodes.has(variant):
			var node := MultiMeshInstance3D.new()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = entry["mesh"]
			node.multimesh = mm
			add_child(node)
			_deco_nodes[variant] = node
		var base: Transform3D = entry["base"]
		var multi: MultiMesh = (_deco_nodes[variant] as MultiMeshInstance3D).multimesh
		multi.instance_count = transforms.size()
		for i in transforms.size():
			multi.set_instance_transform(i, (transforms[i] as Transform3D) * base)


## Mesh + grounding transform for a variant (first mesh in the GLB scene,
## scaled so its footprint spans `fit`, bottom at y=0). null = missing model.
func _deco_lib_entry(variant: String) -> Variant:
	if _deco_lib.has(variant):
		return _deco_lib[variant]
	var info: Dictionary = DECO_KINDS[variant]
	var scene: Resource = load(KENNEY + MINI_FOREST + str(info["file"]))
	var entry: Variant = null
	if scene is PackedScene:
		var inst: Node3D = (scene as PackedScene).instantiate()
		var mesh_node := _first_mesh(inst)
		if mesh_node != null:
			var bounds := _aabb_of(inst)
			var extent := maxf(bounds.size.x, bounds.size.z)
			var s := float(info["fit"]) / maxf(extent, 0.001)
			var bottom := bounds.position + Vector3(bounds.size.x / 2.0, 0, bounds.size.z / 2.0)
			entry = {"mesh": mesh_node.mesh, "base":
				Transform3D(Basis.from_scale(Vector3.ONE * s), -bottom * s)}
		inst.free()
	if entry == null:
		push_warning("mini-forest model missing: " + str(info["file"]))
	_deco_lib[variant] = entry
	return entry


static func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child: Node in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null


func _emit_quad(verts: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		corners: Array, normal: Vector3, color: Color) -> void:
	var base := verts.size()
	for corner: Vector3 in corners:
		verts.append(corner)
		normals.append(normal)
		colors.append(color)
	for i: int in [0, 1, 2, 0, 2, 3]:
		indices.append(base + i)


# ─── makers ───

func _make_zone(pos: Vector2i) -> Node3D:
	var quad := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(0.92, 0.92)
	quad.mesh = mesh
	quad.material_override = _flat(Color(0.45, 0.8, 0.4, 0.10), true)
	quad.position = _center(pos) + Vector3(0, 0.01, 0)
	return quad


func _make_road(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # child mesh set by _orient_road


func _orient_road(pos: Vector2i, node: Node3D) -> void:
	var mask := 0
	var height := City.model.terrain.height(pos)
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		# roads only join on the same plateau — a step is a wall, not a ramp
		var n: Vector2i = pos + directions[i]
		if City.model.roads.has(n) and City.model.terrain.height(n) == height:
			mask |= 1 << i
	var pick := _road_piece(mask)  # [model, yaw_deg]
	var wanted: String = "%s|%d" % [pick[0], pick[1]]
	if node.get_meta("piece", "") == wanted:
		return
	node.set_meta("piece", wanted)
	for child in node.get_children():
		child.queue_free()
	var piece := _instance_glb("city-kit-roads/Models/GLB format/%s.glb" % pick[0], 1.0)
	piece.rotation_degrees.y = pick[1]
	node.add_child(piece)


func _road_piece(mask: int) -> Array:
	# mask bits: 1=N 2=E 4=S 8=W. Native orientations read off the raw GLBs
	# with N/E marker posts (--roadtest ..._native.png): straight runs E-W,
	# end opens W, bend connects N+E, intersection is the E-W bar with the
	# stem S. Godot +yaw is CCW from above: E→N→W→S→E per 90°.
	match mask:
		0: return ["road-end-round", 90]
		1: return ["road-end", 270]
		2: return ["road-end", 180]
		4: return ["road-end", 90]
		8: return ["road-end", 0]
		5: return ["road-straight", 90]
		10: return ["road-straight", 0]
		3: return ["road-bend", 180]
		9: return ["road-bend", 270]
		12: return ["road-bend", 0]
		6: return ["road-bend", 90]
		14: return ["road-intersection", 0]
		7: return ["road-intersection", 90]
		11: return ["road-intersection", 180]
		13: return ["road-intersection", 270]
		_: return ["road-crossroad", 0]


func _make_cable(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # everything kind-dependent is built by _orient_cable


## The wooden distribution pole + crossarm (also the palette thumbnail).
func _pole_visual() -> Node3D:
	var node := Node3D.new()
	var pole := MeshInstance3D.new()
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.035
	pole_mesh.bottom_radius = 0.05
	pole_mesh.height = 0.85
	pole.mesh = pole_mesh
	pole.position.y = 0.42
	pole.material_override = _flat(Color(0.45, 0.36, 0.28))
	node.add_child(pole)
	var arm := MeshInstance3D.new()
	arm.mesh = BoxMesh.new()
	(arm.mesh as BoxMesh).size = Vector3(0.3, 0.04, 0.06)
	arm.position.y = 0.78
	arm.material_override = pole.material_override
	node.add_child(arm)
	return node


func _wire_segment(from: Vector3, to: Vector3, thickness: float,
		color: Color) -> MeshInstance3D:
	var wire := MeshInstance3D.new()
	wire.set_meta("wire", true)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thickness, thickness, from.distance_to(to))
	wire.mesh = mesh
	wire.transform = Transform3D(
		Basis.looking_at((to - from).normalized(), Vector3.UP),
		(from + to) / 2.0)
	wire.material_override = _flat(color)
	return wire


## Is the neighbor tile part of a building that belongs on the grid —
## power buildings, or any coupled plant (heat pumps, water pumps...)?
func _electrical_building_at(pos: Vector2i) -> bool:
	var id: String = City.model.building_tiles.get(pos, "")
	if id == "":
		return false
	var def := BuildingDefs.get_def(City.model.buildings[id]["kind"])
	return def.get("network", "") == "power" or def.get("device", "") != ""


## Is the neighbor tile part of a building of the given network? (pipe
## connection stubs — heat plants/exchangers, water sources/stations)
func _network_building_at(pos: Vector2i, network: String) -> bool:
	var id: String = City.model.building_tiles.get(pos, "")
	if id == "":
		return false
	return BuildingDefs.get_def(
		City.model.buildings[id]["kind"]).get("network", "") == network


## Line tile visuals by kind. Overhead: pole, crossarm, wire half-spans,
## and a sloped SERVICE DROP to any adjacent electrical building (the
## visible connection). Underground: a trench strip with a marker post
## (Kabelmerkstein) and a grey riser box where it enters a building.
func _orient_cable(pos: Vector2i, node: Node3D) -> void:
	var kind := int(City.model.cables.get(pos, BuildingDefs.LINE_OVERHEAD))
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var connections := "%d|" % kind
	for i in 4:
		if City.model.cables.has(pos + directions[i]):
			connections += str(i)
		if _electrical_building_at(pos + directions[i]):
			connections += "b%d" % i
	var wanted := "%s|r%s@%s" % [connections,
		City.model.roads.has(pos), _terrain_fingerprint]
	if node.get_meta("wires", "") == wanted:
		return
	node.set_meta("wires", wanted)
	for child in node.get_children():
		child.queue_free()
	if kind == BuildingDefs.LINE_UNDERGROUND:
		_orient_buried(pos, node, City.model.cables, "power",
			[Color(0.85, 0.75, 0.35)], true)
		return
	node.add_child(_pole_visual())
	for i in 4:
		var d := directions[i]
		var dh := _ground_y(pos + d) - _ground_y(pos)
		if City.model.cables.has(pos + d):
			# half-span to the tile edge; slopes across terrain steps
			node.add_child(_wire_segment(Vector3(0, 0.74, 0),
				Vector3(d.x * 0.5, 0.74 + dh / 2.0, d.y * 0.5),
				0.03, Color(0.2, 0.2, 0.22)))
		elif _electrical_building_at(pos + d):
			# service drop: from the crossarm down to the building's edge
			node.add_child(_wire_segment(Vector3(0, 0.74, 0),
				Vector3(d.x * 0.5, 0.32 + dh, d.y * 0.5),
				0.025, Color(0.16, 0.16, 0.18)))


## Shared buried-line renderer (power/heat/water). Open ground: a trench
## strip toward each connected neighbor, network-colored marker posts
## (Merksteine), riser boxes into adjacent buildings. Under a ROAD the
## line compresses to a manhole plate on the pavement — buried lines may
## cross streets, and each network's plate sits at its own offset so
## shared street cross-sections stay readable.
func _orient_buried(pos: Vector2i, node: Node3D, layer: Dictionary,
		network: String, markers: Array, tint_loading: bool) -> void:
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var trench := Color(0.36, 0.33, 0.29)
	if City.model.roads.has(pos):
		var plate_offset := {"power": Vector3.ZERO,
			"heat": Vector3(0.24, 0, 0.24),
			"water": Vector3(-0.24, 0, -0.24)}[network] as Vector3
		var plate := _box(Vector3(0.2, 0.015, 0.2), Color(0.3, 0.3, 0.33),
			plate_offset + Vector3(0, 0.035, 0))
		if tint_loading:
			plate.set_meta("wire", true)
		node.add_child(plate)
		return
	node.add_child(_box(Vector3(0.18, 0.025, 0.18), trench, Vector3(0, 0.012, 0)))
	for i in markers.size():  # marker posts so buried runs stay findable
		node.add_child(_box(Vector3(0.05, 0.2, 0.05), markers[i],
			Vector3(0.2, 0.1, 0.2 - 0.14 * i)))
	for i in 4:
		var d := directions[i]
		if layer.has(pos + d):
			var strip := _box(Vector3(0.16 if d.y != 0 else 0.5,
				0.025, 0.16 if d.x != 0 else 0.5), trench,
				Vector3(d.x * 0.25, 0.012, d.y * 0.25))
			if tint_loading:
				strip.set_meta("wire", true)  # loading overlay tints the trench
			node.add_child(strip)
		elif _buried_building_target(pos + d, network):
			# riser box where the line comes up into the building
			node.add_child(_box(Vector3(0.4 if d.x != 0 else 0.16, 0.025,
				0.4 if d.y != 0 else 0.16), trench,
				Vector3(d.x * 0.3, 0.012, d.y * 0.3)))
			node.add_child(_box(Vector3(0.12, 0.22, 0.12), Color(0.55, 0.57, 0.6),
				Vector3(d.x * 0.42, 0.11, d.y * 0.42)))


func _buried_building_target(pos: Vector2i, network: String) -> bool:
	if network == "power":
		return _electrical_building_at(pos)
	return _network_building_at(pos, network)


func _make_pipe(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # segments set by _orient_pipe


## District-heating double pipe: forward (red) and return (blue) run in
## parallel on low supports. One segment pair per connected direction from
## the tile center to its edge — handles straights, bends, tees and crosses
## without piece-picking. Side convention is world-axis based (X-runs offset
## in Z, Z-runs offset in X) so straights never zigzag.
## Double heat pipe toward every connected NEIGHBOR — pipe tiles and heat
## buildings alike: a plant or exchanger next to the pipe gets visible
## supply/return stubs plus a valve box at the joint (same idea as the
## electrical service drops).
func _orient_pipe(pos: Vector2i, node: Node3D) -> void:
	var kind := int(City.model.heat_pipes.get(pos, BuildingDefs.LINE_OVERHEAD))
	var connections := "%d|" % kind
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.heat_pipes.has(pos + directions[i]):
			connections += str(i)
		elif _network_building_at(pos + directions[i], "heat"):
			connections += "b%d" % i
	var wanted := "%s|r%s@%s" % [connections,
		City.model.roads.has(pos), _terrain_fingerprint]
	if node.get_meta("pipes", "") == wanted:
		return
	node.set_meta("pipes", wanted)
	for child in node.get_children():
		child.queue_free()
	if kind == BuildingDefs.LINE_UNDERGROUND:
		_orient_buried(pos, node, City.model.heat_pipes, "heat",
			[PIPE_SUPPLY_COLOR, PIPE_RETURN_COLOR], false)
		return
	# support foot
	node.add_child(_box(Vector3(0.14, PIPE_HEIGHT - 0.05, 0.14),
		Color(0.45, 0.46, 0.5), Vector3(0, (PIPE_HEIGHT - 0.05) / 2.0, 0)))
	var any_connection := false
	for i in 4:
		var d := directions[i]
		var to_building: bool = not City.model.heat_pipes.has(pos + d) \
			and _network_building_at(pos + d, "heat")
		if not City.model.heat_pipes.has(pos + d) and not to_building:
			continue
		any_connection = true
		if to_building:
			# valve box where the pair enters the building
			node.add_child(_box(
				Vector3(0.1, 0.3, 0.44) if d.y == 0 else Vector3(0.44, 0.3, 0.1),
				Color(0.5, 0.52, 0.56),
				Vector3(d.x * 0.48, PIPE_HEIGHT, d.y * 0.48)))
		var horizontal := d.y == 0  # segment runs along world X
		var perp := Vector3(0, 0, 0.13) if horizontal else Vector3(0.13, 0, 0)
		var dh := _ground_y(pos + d) - _ground_y(pos)
		for pair: Array in [[PIPE_SUPPLY_COLOR, 1.0], [PIPE_RETURN_COLOR, -1.0]]:
			var seg := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.055
			cyl.bottom_radius = 0.055
			cyl.height = 0.5
			seg.mesh = cyl
			if horizontal:
				seg.rotation_degrees.z = 90.0
			else:
				seg.rotation_degrees.x = 90.0
			seg.position = Vector3(d.x * 0.25, PIPE_HEIGHT, d.y * 0.25) \
				+ perp * pair[1]
			seg.material_override = _flat(pair[0])
			node.add_child(seg)
			if dh > 0.0:  # climbing a plateau step: riser at the shared edge
				var riser := MeshInstance3D.new()
				var riser_mesh := CylinderMesh.new()
				riser_mesh.top_radius = 0.055
				riser_mesh.bottom_radius = 0.055
				riser_mesh.height = dh
				riser.mesh = riser_mesh
				riser.position = Vector3(d.x * 0.5, PIPE_HEIGHT + dh / 2.0, d.y * 0.5) \
					+ perp * pair[1]
				riser.material_override = _flat(pair[0])
				node.add_child(riser)
	# per-color joint flanges bridge the corner gaps
	if any_connection:
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_SUPPLY_COLOR,
			Vector3(0.13, PIPE_HEIGHT, 0.13)))
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_RETURN_COLOR,
			Vector3(-0.13, PIPE_HEIGHT, -0.13)))


func _make_water_pipe(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # segments set by _orient_water_pipe


## Water main: a single green pipe on the same low supports as the heat
## pair — one fatter cylinder per connected direction, center joint knuckle.
## Green main toward every connected neighbor — pipe tiles AND water
## buildings: towers/wells/pumps/stations get a visible stub + collar.
func _orient_water_pipe(pos: Vector2i, node: Node3D) -> void:
	var kind := int(City.model.water_pipes.get(pos, BuildingDefs.LINE_OVERHEAD))
	var connections := "%d|" % kind
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.water_pipes.has(pos + directions[i]):
			connections += str(i)
		elif _network_building_at(pos + directions[i], "water"):
			connections += "b%d" % i
	var wanted := "%s|r%s@%s" % [connections,
		City.model.roads.has(pos), _terrain_fingerprint]
	if node.get_meta("pipes", "") == wanted:
		return
	node.set_meta("pipes", wanted)
	for child in node.get_children():
		child.queue_free()
	if kind == BuildingDefs.LINE_UNDERGROUND:
		_orient_buried(pos, node, City.model.water_pipes, "water",
			[WATER_PIPE_COLOR], false)
		return
	node.add_child(_box(Vector3(0.14, PIPE_HEIGHT - 0.05, 0.14),
		Color(0.45, 0.46, 0.5), Vector3(0, (PIPE_HEIGHT - 0.05) / 2.0, 0)))
	var any_connection := false
	for i in 4:
		var d := directions[i]
		var to_building: bool = not City.model.water_pipes.has(pos + d) \
			and _network_building_at(pos + d, "water")
		if not City.model.water_pipes.has(pos + d) and not to_building:
			continue
		any_connection = true
		if to_building:
			# collar where the main enters the building
			node.add_child(_box(
				Vector3(0.1, 0.26, 0.24) if d.y == 0 else Vector3(0.24, 0.26, 0.1),
				Color(0.5, 0.52, 0.56),
				Vector3(d.x * 0.48, PIPE_HEIGHT, d.y * 0.48)))
		var seg := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.07
		cyl.bottom_radius = 0.07
		cyl.height = 0.5
		seg.mesh = cyl
		if d.y == 0:
			seg.rotation_degrees.z = 90.0
		else:
			seg.rotation_degrees.x = 90.0
		seg.position = Vector3(d.x * 0.25, PIPE_HEIGHT, d.y * 0.25)
		seg.material_override = _flat(WATER_PIPE_COLOR)
		node.add_child(seg)
		var dh := _ground_y(pos + d) - _ground_y(pos)
		if dh > 0.0:  # climbing a plateau step: riser at the shared edge
			var riser := MeshInstance3D.new()
			var riser_mesh := CylinderMesh.new()
			riser_mesh.top_radius = 0.07
			riser_mesh.bottom_radius = 0.07
			riser_mesh.height = dh
			riser.mesh = riser_mesh
			riser.position = Vector3(d.x * 0.5, PIPE_HEIGHT + dh / 2.0, d.y * 0.5)
			riser.material_override = _flat(WATER_PIPE_COLOR)
			node.add_child(riser)
	if any_connection:
		node.add_child(_box(Vector3(0.17, 0.17, 0.17), WATER_PIPE_COLOR,
			Vector3(0, PIPE_HEIGHT, 0)))


func _make_house(pos: Vector2i) -> Node3D:
	var variant: String = HOUSE_VARIANTS[abs(pos.x * 73856093 ^ pos.y * 19349663) % HOUSE_VARIANTS.size()]
	var house := _instance_glb(
		"city-kit-suburban/Models/GLB format/building-type-%s.glb" % variant, 0.85)
	house.position = _center(pos)
	var directions: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.roads.has(pos + directions[i]):
			house.rotation_degrees.y = [0.0, 90.0, 180.0, 270.0][i]
			break
	return house


func _make_building(id: String) -> Node3D:
	var entry: Dictionary = City.model.buildings[id]
	var kind: String = entry["kind"]
	var anchor: Vector2i = entry["anchor"]
	var size: Vector2i = BuildingDefs.DEFS[kind]["size"]
	var node := _build_building_visual(kind)
	node.position = Vector3(anchor.x + size.x / 2.0, _ground_y(anchor),
		anchor.y + size.y / 2.0)
	node.rotation_degrees.y = int(entry.get("rot", 0)) * 90.0
	if bool(entry.get("flip", false)):
		node.scale = Vector3(-1, 1, 1)  # mirror; Godot flips culling itself
	return node


## Shared by real buildings and the placement ghost.
func _build_building_visual(kind: String) -> Node3D:
	match kind:
		"gas_plant":
			var node := _instance_glb("city-kit-industrial/Models/GLB format/building-d.glb", 1.9)
			var chimney := _instance_glb("city-kit-industrial/Models/GLB format/chimney-large.glb", 1.0)
			chimney.position = Vector3(0.55, 0, 0.55)
			node.add_child(chimney)
			return node
		"substation":
			return _make_substation()
		"wind_farm":
			return _make_wind_farm()
		"solar_park":
			return _make_solar_park()
		"battery":
			return _make_battery()
		"grid_connection":
			return _make_grid_connection()
		"boiler_plant":
			var boiler := _instance_glb("factory-kit/Models/GLB format/machine.glb", 1.6)
			var stack := _instance_glb("city-kit-industrial/Models/GLB format/chimney-medium.glb", 0.7)
			stack.position = Vector3(0.6, 0, 0.6)
			boiler.add_child(stack)
			return boiler
		"chp_plant":
			var chp := _instance_glb("factory-kit/Models/GLB format/machine-fortified.glb", 1.7)
			var stack2 := _instance_glb("city-kit-industrial/Models/GLB format/chimney-small.glb", 0.6)
			stack2.position = Vector3(0.55, 0, -0.55)
			chp.add_child(stack2)
			return chp
		"heat_pump_plant":
			return _instance_glb("factory-kit/Models/GLB format/machine-window.glb", 1.7)
		"heat_storage":
			return _instance_glb("city-kit-industrial/Models/GLB format/detail-tank.glb", 0.85)
		"heat_exchanger":
			return _make_transfer_station()
		"water_station":
			return _make_water_station()
		"well":
			return _make_well()
		"pumping_station":
			return _make_pumping_station()
		"water_tower":
			return _make_water_tower()
		_:
			return _instance_glb("city-kit-industrial/Models/GLB format/building-a.glb", 1.9)


# ─── procedural fills (no kit model exists; same flat-shaded style) ───

## Heat transfer station (user pick from the model gallery): grey hut with
## an orange roof band, vent, and red/blue stubs that plug into the double
## pipe — rotate with R so the stubs face your line.
func _make_transfer_station() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(0.55, 0.5, 0.45), Color(0.72, 0.74, 0.78),
		Vector3(0, 0.25, 0)))
	node.add_child(_box(Vector3(0.57, 0.08, 0.47), Color(0.85, 0.45, 0.2),
		Vector3(0, 0.54, 0)))
	node.add_child(_box(Vector3(0.12, 0.2, 0.12), Color(0.5, 0.52, 0.56),
		Vector3(0.15, 0.68, 0.1)))
	for pair: Array in [[PIPE_SUPPLY_COLOR, 0.13], [PIPE_RETURN_COLOR, -0.13]]:
		var stub := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.055
		cyl.bottom_radius = 0.055
		cyl.height = 0.5
		stub.mesh = cyl
		stub.rotation_degrees.x = 90
		stub.position = Vector3(pair[1], PIPE_HEIGHT, 0.4)
		stub.material_override = _flat(pair[0])
		node.add_child(stub)
	return node


## District water station: sibling of the transfer station — grey hut with a
## teal band and one green stub that plugs into the water main.
func _make_water_station() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(0.55, 0.5, 0.45), Color(0.72, 0.74, 0.78),
		Vector3(0, 0.25, 0)))
	node.add_child(_box(Vector3(0.57, 0.08, 0.47), Color(0.2, 0.55, 0.8),
		Vector3(0, 0.54, 0)))
	var stub := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.07
	cyl.bottom_radius = 0.07
	cyl.height = 0.5
	stub.mesh = cyl
	stub.rotation_degrees.x = 90
	stub.position = Vector3(0, PIPE_HEIGHT, 0.4)
	stub.material_override = _flat(WATER_PIPE_COLOR)
	node.add_child(stub)
	return node


## Well field: gravel pad, wellhead cap, hand-pump style arm — reads as
## "water comes out of the ground here" at map zoom.
func _make_well() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(0.85, 0.05, 0.85), Color(0.62, 0.6, 0.55),
		Vector3(0, 0.025, 0)))
	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.16
	head_mesh.bottom_radius = 0.18
	head_mesh.height = 0.35
	head.mesh = head_mesh
	head.position.y = 0.22
	head.material_override = _flat(Color(0.35, 0.5, 0.45))
	node.add_child(head)
	node.add_child(_box(Vector3(0.08, 0.08, 0.34), WATER_PIPE_COLOR,
		Vector3(0, 0.42, 0.12)))
	node.add_child(_box(Vector3(0.3, 0.3, 0.25), Color(0.72, 0.74, 0.78),
		Vector3(0.25, 0.15, -0.22)))
	return node


## Pumping station: factory hall + intake tank + green discharge stub. The
## building that ties water to power — place it next to a cable AND the main.
func _make_pumping_station() -> Node3D:
	var node := _instance_glb("factory-kit/Models/GLB format/machine.glb", 1.5)
	var tank := _instance_glb("city-kit-industrial/Models/GLB format/detail-tank.glb", 0.6)
	tank.position = Vector3(-0.6, 0, 0.55)
	node.add_child(tank)
	var stub := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.07
	cyl.bottom_radius = 0.07
	cyl.height = 0.7
	stub.mesh = cyl
	stub.rotation_degrees.x = 90
	stub.position = Vector3(0.55, PIPE_HEIGHT, 0.75)
	stub.material_override = _flat(WATER_PIPE_COLOR)
	node.add_child(stub)
	return node


## Classic elevated tank: four legs, cylindrical tank with a conical cap —
## the pressure boundary of the network, unmistakable on the skyline.
func _make_water_tower() -> Node3D:
	var node := Node3D.new()
	for legs: Vector2 in [Vector2(-0.2, -0.2), Vector2(0.2, -0.2),
			Vector2(-0.2, 0.2), Vector2(0.2, 0.2)]:
		node.add_child(_box(Vector3(0.06, 1.1, 0.06), Color(0.55, 0.57, 0.6),
			Vector3(legs.x, 0.55, legs.y)))
	var tank := MeshInstance3D.new()
	var tank_mesh := CylinderMesh.new()
	tank_mesh.top_radius = 0.34
	tank_mesh.bottom_radius = 0.3
	tank_mesh.height = 0.55
	tank.mesh = tank_mesh
	tank.position.y = 1.35
	tank.material_override = _flat(Color(0.55, 0.65, 0.75))
	node.add_child(tank)
	var cap := MeshInstance3D.new()
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.02
	cap_mesh.bottom_radius = 0.36
	cap_mesh.height = 0.22
	cap.mesh = cap_mesh
	cap.position.y = 1.73
	cap.material_override = _flat(Color(0.45, 0.55, 0.65))
	node.add_child(cap)
	# riser pipe down the middle, in network green
	var riser := MeshInstance3D.new()
	var riser_mesh := CylinderMesh.new()
	riser_mesh.top_radius = 0.05
	riser_mesh.bottom_radius = 0.05
	riser_mesh.height = 1.1
	riser.mesh = riser_mesh
	riser.position.y = 0.55
	riser.material_override = _flat(WATER_PIPE_COLOR)
	node.add_child(riser)
	return node


func _make_substation() -> Node3D:
	var node := Node3D.new()
	var pad := _box(Vector3(0.9, 0.06, 0.9), Color(0.6, 0.6, 0.62), Vector3(0, 0.03, 0))
	node.add_child(pad)
	var tank := _instance_glb("city-kit-industrial/Models/GLB format/detail-tank.glb", 0.5)
	tank.position = Vector3(-0.18, 0.06, 0.0)
	node.add_child(tank)
	node.add_child(_box(Vector3(0.3, 0.4, 0.3), Color(0.3, 0.65, 0.75), Vector3(0.22, 0.26, 0.1)))
	for offset: float in [-0.3, 0.3]:
		node.add_child(_box(Vector3(0.04, 0.55, 0.04), Color(0.75, 0.75, 0.78),
			Vector3(offset, 0.33, -0.3)))
	return node


func _make_wind_farm() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(1.9, 0.05, 1.9), Color(0.5, 0.62, 0.42), Vector3(0, 0.02, 0)))
	for spot: Vector3 in [Vector3(-0.55, 0, -0.55), Vector3(0.55, 0, 0.0), Vector3(-0.35, 0, 0.6)]:
		var turbine := Node3D.new()
		turbine.position = spot
		var mast := MeshInstance3D.new()
		var mast_mesh := CylinderMesh.new()
		mast_mesh.top_radius = 0.03
		mast_mesh.bottom_radius = 0.06
		mast_mesh.height = 1.6
		mast.mesh = mast_mesh
		mast.position.y = 0.8
		mast.material_override = _flat(Color(0.92, 0.93, 0.95))
		turbine.add_child(mast)
		var rotor := Node3D.new()
		rotor.position = Vector3(0, 1.58, 0.07)
		rotor.set_meta("rotor", true)
		for blade_i in 3:
			var blade := _box(Vector3(0.05, 0.55, 0.02), Color(0.95, 0.96, 0.97),
				Vector3(0, 0.27, 0))
			var arm := Node3D.new()
			arm.rotation_degrees.z = blade_i * 120.0
			arm.add_child(blade)
			rotor.add_child(arm)
		turbine.add_child(rotor)
		node.add_child(turbine)
	return node


func _make_solar_park() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(1.9, 0.05, 1.9), Color(0.55, 0.55, 0.5), Vector3(0, 0.02, 0)))
	for row in 4:
		for col in 3:
			var panel := _box(Vector3(0.5, 0.02, 0.3), Color(0.15, 0.22, 0.45),
				Vector3(0, 0.16, 0))
			panel.rotation_degrees.x = -30
			var mount := Node3D.new()
			mount.position = Vector3(-0.6 + col * 0.6, 0.05, -0.65 + row * 0.42)
			mount.add_child(panel)
			node.add_child(mount)
	return node


func _make_battery() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(0.8, 0.5, 0.55), Color(0.9, 0.9, 0.92), Vector3(0, 0.25, 0)))
	node.add_child(_box(Vector3(0.82, 0.1, 0.57), Color(0.35, 0.75, 0.4), Vector3(0, 0.42, 0)))
	node.add_child(_box(Vector3(0.2, 0.3, 0.4), Color(0.55, 0.57, 0.6), Vector3(0.42, 0.15, 0)))
	return node


func _make_grid_connection() -> Node3D:
	var node := Node3D.new()
	node.add_child(_box(Vector3(1.9, 0.06, 1.9), Color(0.58, 0.58, 0.6), Vector3(0, 0.03, 0)))
	# simplified lattice pylon: tapered mast + two crossarms
	var mast := MeshInstance3D.new()
	var mast_mesh := CylinderMesh.new()
	mast_mesh.top_radius = 0.05
	mast_mesh.bottom_radius = 0.16
	mast_mesh.height = 2.2
	mast.mesh = mast_mesh
	mast.position.y = 1.1
	mast.material_override = _flat(Color(0.62, 0.64, 0.68))
	node.add_child(mast)
	node.add_child(_box(Vector3(1.3, 0.06, 0.06), Color(0.62, 0.64, 0.68), Vector3(0, 1.95, 0)))
	node.add_child(_box(Vector3(0.9, 0.06, 0.06), Color(0.62, 0.64, 0.68), Vector3(0, 1.6, 0)))
	node.add_child(_box(Vector3(0.5, 0.35, 0.5), Color(0.75, 0.3, 0.28), Vector3(0.55, 0.18, 0.55)))
	return node


# ─── power state + overlays ───

## Coverage diamonds of PLACED zone stations, shown while the matching
## placement tool is active (spacing aid, SimCity-style).
func _update_placed_discs(ghost_kind: String) -> void:
	var wanted := {}
	if ghost_kind in ["substation", "heat_exchanger", "water_station"]:
		var radius := int(BuildingDefs.DEFS[ghost_kind]["zone_radius"])
		var color: Color = BuildingDefs.DEFS[ghost_kind]["color"]
		for id: String in City.model.buildings_of_kind(ghost_kind):
			wanted[id] = true
			if not _range_discs.has(id):
				var disc := _make_range_disc(radius, color)
				var anchor: Vector2i = City.model.buildings[id]["anchor"]
				disc.position = Vector3(anchor.x + 0.5, _ground_y(anchor) + 0.012,
					anchor.y + 0.5)
				add_child(disc)
				_range_discs[id] = disc
	for id: String in _range_discs.keys():
		if not wanted.has(id):
			_range_discs[id].queue_free()
			_range_discs.erase(id)


## Red "!" over network buildings that are not connected to their network's
## source (slack-unreachable per the topology extraction).
func _update_status_markers() -> void:
	var wanted := {}
	for id: String in City.model.buildings:
		var def := BuildingDefs.get_def(City.model.buildings[id]["kind"])
		if def.get("device", "") == "" and def.get("zone_radius", 0) == 0:
			continue
		var connected := false
		match def.get("network", "power"):
			"heat":
				connected = City.heat_topo.connected.get(id, false)
			"water":
				connected = City.water_topo.connected.get(id, false)
			_:
				connected = City.topo.connected.get(id, false)
		if connected or not _buildings.has(id):
			continue
		wanted[id] = true
		if not _status_markers.has(id):
			var marker := _make_marker("!", Color(1.0, 0.25, 0.2))
			marker.position = Vector3(0, 1.6, 0)
			_buildings[id].add_child(marker)
			_status_markers[id] = marker
	for id: String in _status_markers.keys():
		if not wanted.has(id):
			if is_instance_valid(_status_markers[id]):
				_status_markers[id].queue_free()
			_status_markers.erase(id)


func _make_marker(text: String, color: Color, size: int = 220) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.modulate = color
	label.outline_size = 40
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	return label


## Capacity signals (City.capacity_warnings): floating percent/state text
## over anything running near its limit — amber warn, red crit. Always
## visible; unlike the V overlays, these are gameplay-critical.
var _cap_markers := {}


func _update_capacity_markers() -> void:
	var warnings: Dictionary = City.capacity_warnings
	for key: Variant in _cap_markers.keys():
		if not warnings.has(key):
			_cap_markers[key].queue_free()
			_cap_markers.erase(key)
	for key: Variant in warnings:
		var warning: Dictionary = warnings[key]
		if not _cap_markers.has(key):
			var marker := _make_marker("", Color.WHITE, 110)
			add_child(marker)
			_cap_markers[key] = marker
		var label: Label3D = _cap_markers[key]
		label.text = warning["text"]
		label.modulate = Color(0.95, 0.2, 0.15) if warning["level"] == "crit" \
			else Color(1.0, 0.75, 0.2)
		label.position = _center(warning["pos"]) + Vector3(0, 1.15, 0)


## Blackout speech bubbles (user direction): a dark house keeps its normal
## colors — a bobbing sad bubble above it carries the message instead.
var _blackout_bubbles := {}


func _make_blackout_bubble() -> Node3D:
	var bubble := Node3D.new()
	var face := _make_marker(":(", Color(0.16, 0.19, 0.28), 200)
	face.outline_size = 70
	face.outline_modulate = Color(1, 1, 1, 0.95)
	face.position = Vector3(0, 0.28, 0)
	bubble.add_child(face)
	var text := _make_marker("no power", Color(0.16, 0.19, 0.28), 90)
	text.outline_size = 34
	text.outline_modulate = Color(1, 1, 1, 0.95)
	bubble.add_child(text)
	bubble.position = Vector3(0, 1.35, 0)
	return bubble


func _update_house_power() -> void:
	for pos: Vector2i in _houses:
		var zone: String = City.topo.house_zone.get(pos, "")
		var lit: bool = zone != "" and City.zone_supplied.get(zone, true)
		var heat_zone: String = City.heat_topo.house_zone.get(pos, "")
		var cold: bool = heat_zone != "" \
			and not City.heat_zone_supplied.get(heat_zone, true)
		# cold homes render icy blue; a BLACKOUT keeps the house colors and
		# shows a sad bubble instead (user: no more houses turning black)
		_set_state_material(_houses[pos], "cold" if cold else "")
		if not lit and not _blackout_bubbles.has(pos):
			var bubble := _make_blackout_bubble()
			_houses[pos].add_child(bubble)
			_blackout_bubbles[pos] = bubble
		elif lit and _blackout_bubbles.has(pos):
			if is_instance_valid(_blackout_bubbles[pos]):
				_blackout_bubbles[pos].queue_free()
			_blackout_bubbles.erase(pos)
		# yellow "!": no substation covers this house at all
		var orphan := zone == ""
		if orphan and not _orphan_markers.has(pos):
			var marker := _make_marker("!", Color(1.0, 0.85, 0.2))
			marker.position = Vector3(0, 1.0, 0)
			_houses[pos].add_child(marker)
			_orphan_markers[pos] = marker
		elif not orphan and _orphan_markers.has(pos):
			if is_instance_valid(_orphan_markers[pos]):
				_orphan_markers[pos].queue_free()
			_orphan_markers.erase(pos)
	for pos: Vector2i in _orphan_markers.keys():
		if not _houses.has(pos):
			_orphan_markers.erase(pos)  # house gone; marker freed with it
	for pos: Vector2i in _blackout_bubbles.keys():
		if not _houses.has(pos):
			_blackout_bubbles.erase(pos)  # house gone; bubble freed with it
	_update_status_markers()


func _set_state_material(node: Node3D, state: String) -> void:
	if node.get_meta("state", "") == state:
		return
	node.set_meta("state", state)
	var material: StandardMaterial3D = null
	if state == "dark":
		material = _dark_material
	elif state == "cold":
		material = _cold_material
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = material


func _update_overlays() -> void:
	_update_capacity_markers()  # always on — these are gameplay-critical
	if not overlays_visible:
		return
	# cable wires tinted by their line's loading (contract 1.1 edges)
	var loading_of_tile := {}
	var edges: Dictionary = City.last_result.get("edges", {})
	for line_id: String in City.topo.line_tiles:
		if edges.has(line_id):
			for tile: Vector2i in City.topo.line_tiles[line_id]:
				loading_of_tile[tile] = float(edges[line_id].get("loading_percent", 0.0))
	for pos: Vector2i in _cables:
		var color := Color(0.2, 0.2, 0.22)
		if City.tripped_tiles.has(pos):
			color = Color(0.9, 0.15, 0.1)
		elif loading_of_tile.has(pos):
			var loading: float = loading_of_tile[pos]
			color = Color(0.15, 0.75, 0.2) if loading <= 60.0 \
				else (Color(0.95, 0.65, 0.1) if loading <= 100.0 else Color(0.95, 0.12, 0.08))
		for child in _cables[pos].get_children():
			if child.has_meta("wire"):
				(child as MeshInstance3D).material_override = _flat(color)
	# voltage rings at substations, temperature rings at heat exchangers,
	# pressure rings at water stations
	for key: Variant in _rings.keys():
		if not (City.topo.zones_info.has(key) or City.heat_topo.zones_info.has(key)
				or City.water_topo.zones_info.has(key)):
			_rings[key].queue_free()
			_rings.erase(key)
	for zone_id: String in City.topo.zones_info:
		var ring := _ensure_ring(zone_id, City.topo.zones_info[zone_id]["center"])
		var zone_result: Dictionary = City.last_result.get("zones", {}).get(zone_id, {})
		var v_pu := float(zone_result.get("detail", {}).get("v_pu", 0.0))
		var ring_color := Color(0.55, 0.55, 0.55)
		if v_pu > 0.0:
			var deviation := clampf(absf(v_pu - 1.0) / 0.1, 0.0, 1.0)
			ring_color = Color(deviation, 1.0 - deviation, 0.1)
		ring.material_override = _flat(ring_color, false, true)
	for zone_id: String in City.heat_topo.zones_info:
		var ring := _ensure_ring(zone_id, City.heat_topo.zones_info[zone_id]["center"])
		var zone_result: Dictionary = City.last_heat_result.get("zones", {}).get(zone_id, {})
		var t_supply := float(zone_result.get("detail", {}).get("t_supply_c", 0.0))
		var ring_color := Color(0.55, 0.55, 0.55)
		if t_supply > 0.0:
			# cold blue below the minimum, amber at 60-70, warm orange above
			ring_color = Color(0.3, 0.5, 0.95) if t_supply < HeatTopology.T_SUPPLY_MIN_C \
				else (Color(0.95, 0.75, 0.2) if t_supply < 70.0 else Color(1.0, 0.5, 0.1))
		ring.material_override = _flat(ring_color, false, true)
	for zone_id: String in City.water_topo.zones_info:
		var ring := _ensure_ring(zone_id, City.water_topo.zones_info[zone_id]["center"])
		var zone_result: Dictionary = City.last_water_result.get("zones", {}).get(zone_id, {})
		var supplied := float(zone_result.get("supplied", -1.0))
		var ring_color := Color(0.55, 0.55, 0.55)
		if supplied >= 0.0:
			# PDD fraction: green fully supplied, amber weak taps, red dry
			ring_color = Color(0.2, 0.8, 0.4) if supplied >= 0.99 \
				else (Color(0.95, 0.75, 0.2) if supplied >= 0.5 else Color(0.95, 0.15, 0.1))
		ring.material_override = _flat(ring_color, false, true)


func _ensure_ring(zone_id: String, center: Vector2i) -> MeshInstance3D:
	if not _rings.has(zone_id):
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.55
		torus.outer_radius = 0.68
		ring.mesh = torus
		ring.position = _center(center) + Vector3(0, 0.03, 0)
		add_child(ring)
		_rings[zone_id] = ring
	return _rings[zone_id]


func _apply_overlay_visibility() -> void:
	for ring: MeshInstance3D in _rings.values():
		ring.visible = overlays_visible
	_update_overlays()


func _process(delta: float) -> void:
	var pan := Vector2(Input.get_axis(&"ui_left", &"ui_right"),
		Input.get_axis(&"ui_up", &"ui_down"))
	if pan != Vector2.ZERO:
		_pan_ground(pan * 20.0 * delta * (_zoom / 18.0))
	if absf(angle_difference(deg_to_rad(_cam_yaw), deg_to_rad(_cam_yaw_target))) > 0.001:
		_cam_yaw = rad_to_deg(lerp_angle(deg_to_rad(_cam_yaw),
			deg_to_rad(_cam_yaw_target), minf(10.0 * delta, 1.0)))
		_place_camera()
	_cursor.position = _center(mouse_tile()) + Vector3(0, 0.02, 0)
	_update_ghost()
	_update_daylight()
	_drift_clouds(delta)
	# gentle bob keeps the blackout bubbles alive
	var bob := sin(Time.get_ticks_msec() / 400.0) * 0.06
	for pos: Vector2i in _blackout_bubbles:
		if is_instance_valid(_blackout_bubbles[pos]):
			(_blackout_bubbles[pos] as Node3D).position.y = 1.35 + bob
	# spin the wind rotors — the world should feel alive
	for id: String in _buildings:
		if City.model.buildings[id]["kind"] == "wind_farm":
			for rotor: Node3D in _buildings[id].find_children("*", "Node3D", true, false):
				if rotor.has_meta("rotor"):
					rotor.rotation_degrees.z += 90.0 * delta


# ─── drag-and-draw ghost path ───

## Append the tiles from the path's tail to `to` (grid-interpolated so a
## fast mouse flick doesn't leave holes), then recolor the ghost.
func _extend_drag(to: Vector2i) -> void:
	var tail: Vector2i = _drag_path[_drag_path.size() - 1]
	if to == tail:
		return
	var cur := tail
	var guard := 0
	while cur != to and guard < 512:
		guard += 1
		# axis-major step toward the target: L-shaped, never diagonal
		# (diagonal tiles don't connect in the 4-neighbor network graphs)
		if absi(to.x - cur.x) >= absi(to.y - cur.y):
			cur.x += signi(to.x - cur.x)
		else:
			cur.y += signi(to.y - cur.y)
		_drag_path.append(cur)
	_refresh_path_ghost()


func _refresh_path_ghost() -> void:
	if _path_ghost == null:
		_path_ghost = Node3D.new()
		add_child(_path_ghost)
	while _path_quads.size() < _drag_path.size():
		var quad := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(0.86, 0.86)
		quad.mesh = mesh
		_path_ghost.add_child(quad)
		_path_quads.append(quad)
	var plan := City.plan_path(PATH_TOOL_BUILD[tool], _drag_path)
	var base: Color = PATH_TOOL_COLOR[tool]
	for i in _path_quads.size():
		var quad := _path_quads[i]
		if i >= _drag_path.size():
			quad.visible = false
			continue
		quad.visible = true
		var pos := _drag_path[i]
		quad.position = _center(pos) + Vector3(0, 0.04, 0)
		var tint := PATH_BLOCKED_COLOR if plan[i] == "blocked" else base
		# faded = the promise; blocked tiles glow harder so the cut reads
		quad.material_override = _flat(
			Color(tint.r, tint.g, tint.b, 0.62 if plan[i] == "blocked" else 0.45),
			true, true)


func _cancel_drag() -> void:
	_drag_active = false
	_drag_path.clear()
	_painting = false
	if _path_ghost:
		for quad: MeshInstance3D in _path_quads:
			quad.visible = false


# ─── ghost placement preview ───

func rotate_ghost() -> void:
	_ghost_rot = (_ghost_rot + 1) % 4


func flip_ghost() -> void:
	_ghost_flip = not _ghost_flip


func _update_ghost() -> void:
	var kind: String = TOOL_BUILDING.get(tool, "")
	_update_placed_discs(kind)
	if kind == "":
		if _ghost:
			_ghost.queue_free()
			_ghost = null
			_ghost_kind = ""
		if _ghost_disc:
			_ghost_disc.visible = false
		_cursor.visible = true
		return
	if kind != _ghost_kind:
		if _ghost:
			_ghost.queue_free()
		_ghost = _build_building_visual(kind)
		add_child(_ghost)
		_ghost_kind = kind
	_cursor.visible = false
	var anchor := mouse_tile()
	var size: Vector2i = BuildingDefs.DEFS[kind]["size"]
	_ghost.position = Vector3(anchor.x + size.x / 2.0, _ground_y(anchor) + 0.01,
		anchor.y + size.y / 2.0)
	_ghost.rotation_degrees.y = _ghost_rot * 90.0
	_ghost.scale = Vector3(-1 if _ghost_flip else 1, 1, 1)
	var affordable: bool = City.money >= int(BuildingDefs.DEFS[kind]["cost"])
	var valid: bool = City.model.can_place_building(kind, anchor) and affordable
	# amber: would place, but no line touches the footprint => disconnected
	var linked := _footprint_touches_line(kind, anchor)
	var tint := _flat(Color(0.95, 0.25, 0.2, 0.5), true)
	if valid:
		tint = _flat(Color(0.3, 0.9, 0.4, 0.5), true) if linked \
			else _flat(Color(0.95, 0.75, 0.15, 0.55), true)
	for mesh: MeshInstance3D in _ghost.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = tint
	# coverage preview for zone stations
	var radius := int(BuildingDefs.DEFS[kind].get("zone_radius", 0))
	if radius > 0:
		if _ghost_disc == null:
			_ghost_disc = _make_range_disc(radius,
				BuildingDefs.DEFS[kind]["color"])
			add_child(_ghost_disc)
		_ghost_disc.position = Vector3(anchor.x + 0.5, _ground_y(anchor) + 0.015,
			anchor.y + 0.5)
		_ghost_disc.visible = true
	elif _ghost_disc:
		_ghost_disc.visible = false


## Does any footprint-adjacent tile carry the building's network line?
## (power buildings need a cable, heat buildings a pipe)
func _footprint_touches_line(kind: String, anchor: Vector2i) -> bool:
	var def := BuildingDefs.get_def(kind)
	if def.get("device", "") == "" and def.get("zone_radius", 0) == 0:
		return true  # not a network building
	var lines: Dictionary = City.model.cables
	match def.get("network", "power"):
		"heat":
			lines = City.model.heat_pipes
		"water":
			lines = City.model.water_pipes
	for tile: Vector2i in BuildingDefs.footprint(kind, anchor):
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if lines.has(tile + offset):
				return true
	return false


## Manhattan service area = a diamond (honest to the assignment rule).
func _make_range_disc(radius: int, color: Color) -> MeshInstance3D:
	var disc := MeshInstance3D.new()
	var quad := PlaneMesh.new()
	var side := radius * sqrt(2.0)
	quad.size = Vector2(side, side)
	disc.mesh = quad
	disc.rotation_degrees.y = 45.0
	# SHADED: an unshaded disc ignores the day/night cycle and glows as a
	# solid slab at night (found while verifying the cycle)
	disc.material_override = _flat(Color(color.r, color.g, color.b, 0.14), true)
	return disc


func _pan_ground(screen_delta: Vector2) -> void:
	var right := camera.global_transform.basis.x
	right.y = 0
	var forward := -camera.global_transform.basis.z
	forward.y = 0
	_cam_focus += right.normalized() * screen_delta.x + forward.normalized() * screen_delta.y
	_place_camera()


# ─── input ───

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if PATH_TOOL_BUILD.has(tool):
					# drag-and-draw: sketch a ghost path, build on release
					if mb.pressed:
						_drag_active = true
						_drag_path = [mouse_tile()] as Array[Vector2i]
						_refresh_path_ghost()
					elif _drag_active:
						City.build_path(PATH_TOOL_BUILD[tool], _drag_path)
						_cancel_drag()
				else:
					_painting = mb.pressed
					if mb.pressed:
						_apply_tool(mouse_tile())
			MOUSE_BUTTON_RIGHT:
				# right mouse is CAMERA ONLY (playtest feedback: the old
				# click-bulldoze kept firing accidentally between orbits) —
				# demolition lives exclusively on the bulldozer tool (0)
				_orbiting = mb.pressed
				if mb.pressed:
					_orbit_travel = 0.0
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom = maxf(_zoom / 1.12, 6.0)
					_place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom = minf(_zoom * 1.12, 90.0)
					_place_camera()
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _drag_active:
			_extend_drag(mouse_tile())
		elif _painting:
			_apply_tool(mouse_tile())
		elif _orbiting:
			# free orbit around the current focus; Q/E snap back to 90° views
			_orbit_travel += mm.relative.length()
			_cam_yaw -= mm.relative.x * 0.4
			_cam_yaw_target = _cam_yaw
			_place_camera()
		elif mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan_ground(Vector2(-mm.relative.x, mm.relative.y) * 0.02 * (_zoom / 18.0))


func _apply_tool(pos: Vector2i) -> void:
	match tool:
		Tool.NONE:
			var id: String = City.model.building_tiles.get(pos, "")
			if id != "":
				building_clicked.emit(id)
			elif City.model.cables.has(pos):
				tile_infra_clicked.emit("cable", pos)
			elif City.model.heat_pipes.has(pos):
				tile_infra_clicked.emit("heat_pipe", pos)
			elif City.model.water_pipes.has(pos):
				tile_infra_clicked.emit("water_pipe", pos)
			_painting = false
		Tool.ROAD:
			City.build_road(pos)
		Tool.ZONE:
			City.build_zone(pos)
		Tool.CABLE:
			City.build_cable(pos, BuildingDefs.LINE_OVERHEAD)
		Tool.UCABLE:
			City.build_cable(pos, BuildingDefs.LINE_UNDERGROUND)
		Tool.REPAIR:
			City.dispatch_repair(pos)
			_painting = false
		Tool.PIPE:
			City.build_heat_pipe(pos)
		Tool.BURIED_PIPE:
			City.build_heat_pipe(pos, BuildingDefs.LINE_UNDERGROUND)
		Tool.WATER_PIPE:
			City.build_water_pipe(pos)
		Tool.BURIED_WATER:
			City.build_water_pipe(pos, BuildingDefs.LINE_UNDERGROUND)
		Tool.BULLDOZE:
			City.bulldoze(pos)
		_:
			if TOOL_BUILDING.has(tool):
				City.place_building(TOOL_BUILDING[tool], pos, _ghost_rot, {}, _ghost_flip)
				_painting = false


func mouse_tile() -> Vector2i:
	var mouse := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	if absf(direction.y) < 0.0001:
		return Vector2i.ZERO
	# fixed-point iteration against the tile's own height plane: project on
	# y=0, look the hit tile's height up, re-project — converges in a step
	# or two on plateau terrain
	var tile := Vector2i.ZERO
	for i in 4:
		var plane_y := _ground_y(tile) if i > 0 else 0.0
		var hit := origin - direction * ((origin.y - plane_y) / direction.y)
		var next := Vector2i(int(floor(hit.x)), int(floor(hit.z)))
		if next == tile and i > 0:
			break
		tile = next
	return tile


# ─── helpers ───

func _center(pos: Vector2i) -> Vector3:
	return Vector3(pos.x + 0.5, _ground_y(pos), pos.y + 0.5)


var _material_cache := {}


func _flat(color: Color, transparent: bool = false, unshaded: bool = false) -> StandardMaterial3D:
	var key := "%s|%s|%s" % [color.to_html(), transparent, unshaded]
	if not _material_cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		if transparent:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		if unshaded:
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material_cache[key] = material
	return _material_cache[key]


func _box(size: Vector3, color: Color, offset: Vector3) -> MeshInstance3D:
	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	box.mesh = mesh
	box.position = offset
	box.material_override = _flat(color)
	return box


## Instance a kit GLB scaled so its ground footprint fits `fit` world units.
func _instance_glb(rel_path: String, fit: float) -> Node3D:
	var path := KENNEY + rel_path
	if not _house_scene_cache.has(path):
		_house_scene_cache[path] = load(path)
	var scene: PackedScene = _house_scene_cache[path]
	if scene == null:
		push_warning("missing model: " + path)
		return _box(Vector3(0.5, 0.5, 0.5), Color(0.9, 0.2, 0.9), Vector3(0, 0.25, 0))
	# container wrapper: callers may freely set position/rotation on the
	# returned node without clobbering the grounding offset applied inside
	var container := Node3D.new()
	var inner: Node3D = scene.instantiate()
	container.add_child(inner)
	var bounds := _aabb_of(inner)
	var extent := maxf(bounds.size.x, bounds.size.z)
	if extent > 0.001:
		var scale_factor := fit / extent
		inner.scale = Vector3.ONE * scale_factor
		# ground the model: AABB bottom at y=0, centered on x/z
		var bottom_center := bounds.position + Vector3(bounds.size.x / 2.0, 0, bounds.size.z / 2.0)
		inner.position = -bottom_center * scale_factor
	return container


func _aabb_of(node: Node) -> AABB:
	var total := AABB()
	var first := true
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.transform * mesh.get_aabb()
		total = box if first else total.merge(box)
		first = false
	return total
