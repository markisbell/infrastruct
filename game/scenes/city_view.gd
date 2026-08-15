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
	BURIED_PIPE, BURIED_WATER, ZONE_COMMERCIAL, CHARGING, SUBSTATION_XL }

const TOOL_BUILDING := {
	Tool.SUBSTATION: "substation", Tool.GAS: "gas_plant", Tool.WIND: "wind_farm",
	Tool.SOLAR: "solar_park", Tool.BATTERY: "battery", Tool.GRID: "grid_connection",
	Tool.HEAT_SUB: "heat_exchanger", Tool.BOILER: "boiler_plant",
	Tool.CHP: "chp_plant", Tool.HEATPUMP: "heat_pump_plant",
	Tool.HEATSTORE: "heat_storage",
	Tool.WATER_SUB: "water_station", Tool.WELL: "well",
	Tool.PUMP: "pumping_station", Tool.WATER_TOWER: "water_tower",
	Tool.CHARGING: "charging_park",
	Tool.SUBSTATION_XL: "substation_xl",
}

const KENNEY := "res://assets/kenney/"

## Left click with NO tool active selects infrastructure (HUD inspector).
signal building_clicked(id: String)
## Same for line/pipe tiles: category is "cable" | "heat_pipe" | "water_pipe".
signal tile_infra_clicked(category: String, pos: Vector2i)
## No-tool click on a tile with nothing inspectable — click-away dismiss.
signal empty_clicked
## Middle-click that did NOT pan: "give me the tool that built this tile".
signal pipette_requested(pos: Vector2i)

## Network color language (user direction): heat = red/blue double pipe
## (forward/return — physically honest, the backend models both sides);
## water (Phase 5) = green.
const PIPE_SUPPLY_COLOR := BuildingModels.PIPE_SUPPLY_COLOR
const PIPE_RETURN_COLOR := BuildingModels.PIPE_RETURN_COLOR
const WATER_PIPE_COLOR := BuildingModels.WATER_PIPE_COLOR
const PIPE_HEIGHT := BuildingModels.PIPE_HEIGHT
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
	Tool.ZONE_COMMERCIAL: "zone_commercial",
	Tool.CABLE: "cable_overhead", Tool.UCABLE: "cable_buried",
	Tool.PIPE: "heat", Tool.BURIED_PIPE: "heat_buried",
	Tool.WATER_PIPE: "water", Tool.BURIED_WATER: "water_buried",
}
## ghost tint per path tool (the element's own color language, faded)
const PATH_TOOL_COLOR := {
	Tool.ROAD: Color(0.45, 0.45, 0.5), Tool.ZONE: Color(0.45, 0.8, 0.4),
	Tool.ZONE_COMMERCIAL: Color(0.45, 0.55, 0.9),
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
var _commercial := {}
var _buildings := {}
var _rings := {}          # zone/slack overlay rings
var _cursor: MeshInstance3D
var _painting := false
## Right mouse: drag orbits the camera freely around the focus (any angle);
## a click without movement keeps the quick-bulldoze convenience.
var _orbiting := false
var _orbit_travel := 0.0
var _pan_travel := 0.0
## Pixels of middle-button travel that still count as a click, not a pan.
const PIPETTE_MAX_TRAVEL := 6.0

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

# terrain colors/dip live in TerrainMeshBuilder (Phase-5 extraction)
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
	sun.shadow_blur = 0.75
	# high PCF filter quality (project setting) + normal bias against the
	# edge sparkle the moving sun produces on the iGPU ("glimmering",
	# user report 2026-08-02) — sharpness stays, the crawl stops
	sun.shadow_normal_bias = 2.5
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
	_cloud_field = CloudField.new()
	add_child(_cloud_field)
	_cloud_field.build(777)
	_spawn_wind_arrows()
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	add_child(camera)
	_place_camera()
	camera.make_current()


# ─── day/night cycle + drifting clouds (user request) ───

var _cloud_field: CloudField
## Sky-look probe (the REGION_SHOT/PALETTE_TAB pattern): CLOUD_COVER=0..1
## pins the cover a screenshot renders, since the real one comes from a
## seeded noise field you cannot dial from the command line. <0 = off.
var _cloud_cover_probe: float = \
	float(OS.get_environment("CLOUD_COVER")) \
	if OS.get_environment("CLOUD_COVER") != "" else -1.0
var _brightness := 1.0  # daylight brightness from _update_daylight
var _daylight := 1.0    # raw daylight window (compass hides its sun at night)
## The sun rotates in DISCRETE steps: a continuously creeping light
## re-fits the shadow map every frame and every shadow edge texel crawls
## ("flickering", user reports x2 — filter quality alone cannot hide it).
## Snapped to a fixed grid the map is rock-stable between steps; one
## 0.75-degree jump is invisible next to continuous shimmer. Colors and
## energy stay continuous — only the ROTATION shifts texels.
const SUN_QUANT_DEG := 0.75


## Window lights fade in as evening falls; every household keeps its own
## hash-seeded bedtime and wake-up — and a BLACKOUT switches the street
## dark for real (powered = no blackout bubble on the house).
func _update_house_lights() -> void:
	var night := clampf((0.4 - _brightness) / 0.3, 0.0, 1.0)
	var hour := fmod(GameClock.total_minutes, 1440.0) / 60.0
	var since_evening := fmod(hour - 18.0 + 24.0, 24.0)  # 0 at 18:00
	for pos: Vector2i in _houses:
		var light: OmniLight3D = _houses[pos].get_meta("light", null)
		if light == null:
			continue
		var energy := 0.0
		if night > 0.0 and not _blackout_bubbles.has(pos):
			var h := _tile_hash(pos, 5)
			var bedtime := 3.5 + float(h % 40) / 10.0   # 21:30..01:30
			var wake := 11.0 + float(h % 20) / 10.0     # 05:00..06:54
			if since_evening < bedtime or since_evening >= wake:
				energy = night * 0.7 * (0.8 + float(h % 7) * 0.06)
		light.light_energy = energy


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
	_brightness = brightness  # house window lights key on it
	_sun.light_energy = lerpf(0.28, 1.5, brightness)
	var day_color := Color(1.0, 0.965, 0.89).lerp(Color(1.0, 0.62, 0.38), dusk)
	_sun.light_color = Color(0.62, 0.7, 0.95).lerp(day_color, brightness)
	# the sun ARCS: shallow at dawn/dusk, high at noon; azimuth sweeps a
	# REAL half circle — rise EAST (-X), noon SOUTH (+Z), set WEST (+X) —
	# so the compass and solar-park facing can be trusted (the old ±45°
	# quadrant sweep made "sun direction" meaningless). At night it parks
	# as faint moonlight.
	_daylight = daylight
	_sun.rotation_degrees.x = -snappedf(lerpf(10.0, 52.0, daylight),
		SUN_QUANT_DEG)
	if daylight > 0.0:
		_sun.rotation_degrees.y = snappedf(lerpf(-90.0, 90.0,
			clampf((hour - 5.5) / 14.0, 0.0, 1.0)), SUN_QUANT_DEG)
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
## Park a cloud over a world position (screenshot shadow-on-town nicety).
func park_cloud_over(pos: Vector3) -> void:
	if _cloud_field != null:
		_cloud_field.park_over(pos)


const WIND_ARROW_COUNT := 18  # 6x3 jittered pattern across the view box
var _wind_arrows: Array[Node3D] = []
var _wind_arrow_units: Array[Vector2] = []  # base offsets in the unit square
var _wind_drift := Vector2.ZERO             # accumulated wind travel (world m)
var _wind_vis_dir := NAN                    # eased display direction (rad)
var _wind_vis_speed := 0.0                  # eased display speed


## A handful of light-grey arrows between roof and cloud height: they point
## along the wind and drift with it, so direction AND speed read at a
## glance. CAMERA-RELATIVE placement (a world-fixed field misses the ~30-unit
## viewport entirely at map scale): the arrows wrap inside a box around the
## camera focus, so a few are always in sight at any zoom or pan. Shaded
## material on purpose (unshaded overlays glow at night).
func _spawn_wind_arrows() -> void:
	var arng := RandomNumberGenerator.new()
	arng.seed = 778
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.86, 0.88, 0.9, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 1.0
	for i in WIND_ARROW_COUNT:
		var arrow := Node3D.new()
		var shaft := MeshInstance3D.new()
		var shaft_mesh := BoxMesh.new()
		shaft_mesh.size = Vector3(1.1, 0.04, 0.09)
		shaft.mesh = shaft_mesh
		shaft.material_override = material
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		arrow.add_child(shaft)
		var head := MeshInstance3D.new()
		var head_mesh := CylinderMesh.new()  # top_radius 0 = cone tip
		head_mesh.top_radius = 0.0
		head_mesh.bottom_radius = 0.16
		head_mesh.height = 0.4
		head_mesh.radial_segments = 10
		head.mesh = head_mesh
		head.material_override = material
		head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		head.rotation.z = -PI / 2  # cone apex +y -> local +x
		head.position = Vector3(0.65, 0.0, 0.0)
		arrow.add_child(head)
		_wind_arrow_units.append(Vector2(
			float(i % 6) / 6.0 + arng.randf_range(0.01, 0.14),
			float(i / 6) / 3.0 + arng.randf_range(0.03, 0.28)))
		add_child(arrow)
		_wind_arrows.append(arrow)


func _drift_clouds(delta: float) -> void:
	var wind := float(City.weather.sample(City.current_t).get("wind_ms", 5.0))
	# CONTINUOUS clock for the direction (integer sim steps would snap the
	# whole field once per step), plus per-frame easing on top — direction
	# veers, never jumps, even across seeks and scenario restores.
	var target_dir := City.weather.wind_dir_rad(GameClock.total_minutes / 15.0)
	if is_nan(_wind_vis_dir):
		_wind_vis_dir = target_dir
	var ease_w := minf(1.0, delta * 0.4)  # ~2.5 s time constant
	_wind_vis_dir = lerp_angle(_wind_vis_dir, target_dir, ease_w)
	_wind_vis_speed = lerpf(_wind_vis_speed if _wind_vis_speed > 0.0 \
		else 0.35 + wind * 0.05, 0.35 + wind * 0.05, ease_w)
	var dir := _wind_vis_dir
	var vel := Vector3(cos(dir), 0.0, sin(dir)) * _wind_vis_speed
	# cloud COVER follows the weather's clearness field — the same field that
	# attenuates ghi and picks the measured pv day, so an overcast sky and a
	# dim solar dispatch always agree. The field drifts over ~1.5 days, so
	# the sky thickens gradually: CloudField turns cover into visible count,
	# swell and street-vs-sheet organisation (see its header for the
	# morphology it is reproducing).
	if _cloud_field != null:
		var cover := 1.0 - City.weather.clearness(City.current_t)
		if _cloud_cover_probe >= 0.0:
			cover = _cloud_cover_probe
		_cloud_field.update(delta, dir, _wind_vis_speed, cover, _cam_focus)
	_wind_drift += Vector2(vel.x, vel.z) * 2.2 * delta  # brisker than clouds
	var extent := _zoom * 1.9  # covers the ortho view box at any zoom
	var origin := Vector2(_cam_focus.x, _cam_focus.z) - Vector2(extent, extent) * 0.5
	var arrow_scale := clampf(_zoom / 22.0, 0.7, 2.4)  # readable at any zoom
	for i in _wind_arrows.size():
		var arrow: Node3D = _wind_arrows[i]
		# +yaw rotates local +x to (cos a, 0, -sin a); wind dir wants +sin
		arrow.rotation.y = -dir
		arrow.scale = Vector3.ONE * arrow_scale
		var base: Vector2 = _wind_arrow_units[i] * extent
		arrow.position = Vector3(
			origin.x + fposmod(base.x + _wind_drift.x, extent), 9.5,
			origin.y + fposmod(base.y + _wind_drift.y, extent))


## Horizontal world direction the sun sits in (XZ unit vector), ZERO at
## night — the HUD compass paints its sun marker from this.
func sun_dir_world() -> Vector3:
	if _sun == null or _daylight <= 0.0:
		return Vector3.ZERO
	var yaw := deg_to_rad(_sun.rotation_degrees.y)
	return Vector3(sin(yaw), 0.0, cos(yaw))


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
	_diff(_commercial, model.commercial, _make_commercial)
	_diff(_buildings, model.buildings, _make_building)
	# zoned lots that cannot take a house right now (no same-height road,
	# a line across, paved over) glow amber instead of green — cliff-locked
	# zoning used to stall growth with no visible reason (_flat caches the
	# two materials, so this pass only swaps references)
	for pos: Vector2i in _zones:
		var zone_kind: int = int(model.zoning.get(pos, WorldModel.ZONE_RESIDENTIAL))
		var occupied: bool = model.houses.has(pos) or model.commercial.has(pos)
		var dead: bool = not occupied and not model.lot_buildable(pos, zone_kind)
		var live_color := Color(0.45, 0.8, 0.4, 0.10) \
			if zone_kind == WorldModel.ZONE_RESIDENTIAL \
			else Color(0.45, 0.55, 0.9, 0.12)
		(_zones[pos] as MeshInstance3D).material_override = _flat(
			Color(0.95, 0.55, 0.12, 0.22) if dead else live_color, true)
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
			# TWO rings: cable LINKAGE (parallel-run rule) reads neighbors'
			# neighbors, so a one-ring refresh could leave stale cross-wires
			for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
					Vector2i(0, 1), Vector2i(0, -1)]:
				affected[pos + offset] = true
				for offset2: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
						Vector2i(0, 1), Vector2i(0, -1)]:
					affected[pos + offset + offset2] = true
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
	# plain LEVEL height (one noise call): corners are CAPPED at the tile
	# level below, so the terrain never rises above its plateau — models
	# placed here can never be clipped, and construction joins like it
	# always did (the smoothed _ground_y variant cost ~16 noise calls per
	# call in every renderer hot path AND shattered road runs into
	# stepped slabs — user report 2026-08-02)
	return City.model.terrain.visual_y(pos)


## Geometry rules live in TerrainMeshBuilder (Phase-5 extraction); this
## keeps the fingerprint gate, layer flush, and mesh/material assembly.
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
			_houses, _commercial, _buildings, _rings, _range_discs]:
		for key: Variant in layer:
			if is_instance_valid(layer[key]):
				layer[key].queue_free()
		layer.clear()
	_status_markers.clear()   # children of freed buildings
	_orphan_markers.clear()   # children of freed houses
	var geometry := TerrainMeshBuilder.build(terrain, WORLD_TILES)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geometry["ground"])
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
	var water_arrays: Array = geometry["water"]
	if not water_arrays.is_empty():
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
var _deco_nodes := {}        # variant -> MultiMeshInstance3D
var _deco_lib := {}          # variant -> {mesh, base: Transform3D} | null
var _deco_scatter: Array[Dictionary] = []   # per terrain fingerprint
var _deco_scatter_fp := ""


## Scatter/placement rules live in DecoScatter (Phase-5 extraction);
## this keeps the fingerprint cache + the MultiMesh assembly.
static func _tile_hash(pos: Vector2i, seed_value: int) -> int:
	return DecoScatter.tile_hash(pos, seed_value)


func _rebuild_deco() -> void:
	if DisplayServer.get_name() == "headless":
		return  # smokes never look at props; skip the 65k-tile scatter
	var terrain: Terrain = City.model.terrain
	if terrain.fingerprint() != _deco_scatter_fp:
		_deco_scatter_fp = terrain.fingerprint()
		_deco_scatter = DecoScatter.compute(terrain, WORLD_TILES)
	var buckets := DecoScatter.placements(_deco_scatter, City.model, _ground_y)
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


## Piece/orientation decisions live in LineSpecs (Phase-5 extraction).
func _orient_road(pos: Vector2i, node: Node3D) -> void:
	var pick := LineSpecs.road_piece(LineSpecs.road_mask(City.model, pos))
	var wanted: String = "%s|%d" % [pick[0], pick[1]]
	if node.get_meta("piece", "") == wanted:
		return
	node.set_meta("piece", wanted)
	for child in node.get_children():
		child.queue_free()
	var piece := _instance_glb("city-kit-roads/Models/GLB format/%s.glb" % pick[0], 1.0)
	piece.rotation_degrees.y = pick[1]
	node.add_child(piece)


func _make_cable(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # everything kind-dependent is built by _orient_cable


## Decisions live in LineSpecs (Phase-5 extraction); the pipe orienters
## still call these thin delegates until their own extraction pass.
func _network_taps_here(building_pos: Vector2i, network: String,
		pipe_pos: Vector2i) -> bool:
	return LineSpecs.network_taps_here(City.model, building_pos, network,
		pipe_pos)


func _network_building_at(pos: Vector2i, network: String) -> bool:
	return LineSpecs.network_building_at(City.model, pos, network)


func _orient_cable(pos: Vector2i, node: Node3D) -> void:
	var spec := LineSpecs.cable_spec(City.model, pos)
	var wanted := LineSpecs.cable_cache_key(spec,
		City.model.roads.has(pos), _terrain_fingerprint)
	if node.get_meta("wires", "") == wanted:
		return
	node.set_meta("wires", wanted)
	for child in node.get_children():
		child.queue_free()
	if int(spec["kind"]) == BuildingDefs.LINE_UNDERGROUND:
		_orient_buried(pos, node, City.model.cables, "power",
			[Color(0.85, 0.75, 0.35)], true)
		return
	node.add_child(_pole_visual())
	# Kabelendmast (user request 2026-08-02; researched: Endmast carries
	# Endverschluesse + Ueberspannungsableiter + Kabelschutzrohr): where
	# the overhead run hands over to a buried cable, dress the pole
	if int(spec["termination"]) >= 0:
		var toward: Vector2i = LineSpecs.DIRECTIONS[spec["termination"]]
		node.add_child(_termination_hardware(Vector3(toward.x, 0, toward.y)))
	for link: Dictionary in spec["links"]:
		var d: Vector2i = LineSpecs.DIRECTIONS[link["dir"]]
		var dh := _ground_y(pos + d) - _ground_y(pos)
		# half-span to the tile edge; slopes across terrain steps.
		# PARALLEL runs are electrically separate — no cross-wires
		# (the map must show what the solver sees)
		node.add_child(_wire_segment(Vector3(0, 0.74, 0),
			Vector3(d.x * 0.5, 0.74 + dh / 2.0, d.y * 0.5),
			0.03, Color(0.2, 0.2, 0.22)))
	for tap_dir: int in spec["taps"]:
		var d: Vector2i = LineSpecs.DIRECTIONS[tap_dir]
		var dh := _ground_y(pos + d) - _ground_y(pos)
		# service drop ONLY at the building's single chosen tap tile
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
	var spec := LineSpecs.buried_spec(City.model, pos, layer, network)
	var trench := Color(0.36, 0.33, 0.29)
	if spec["on_road"]:
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
	for link_dir: int in spec["links"]:
		var d: Vector2i = LineSpecs.DIRECTIONS[link_dir]
		var strip := _box(Vector3(0.16 if d.y != 0 else 0.5,
			0.025, 0.16 if d.x != 0 else 0.5), trench,
			Vector3(d.x * 0.25, 0.012, d.y * 0.25))
		if tint_loading:
			strip.set_meta("wire", true)  # loading overlay tints the trench
		node.add_child(strip)
	for riser_dir: int in spec["risers"]:
		var d: Vector2i = LineSpecs.DIRECTIONS[riser_dir]
		# riser box where the line comes up into the building
		node.add_child(_box(Vector3(0.4 if d.x != 0 else 0.16, 0.025,
			0.4 if d.y != 0 else 0.16), trench,
			Vector3(d.x * 0.3, 0.012, d.y * 0.3)))
		node.add_child(_box(Vector3(0.12, 0.22, 0.12), Color(0.55, 0.57, 0.6),
			Vector3(d.x * 0.42, 0.11, d.y * 0.42)))


func _make_pipe(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # segments set by _orient_pipe


func _make_water_pipe(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # segments set by _orient_water_pipe


## Shared surface-pipe renderer (Phase-5 merge of the heat/water
## orienters): forward/return double run for heat, single fatter main
## for water — same low supports, per-direction half-segments from the
## tile center, step risers on plateau climbs, a grey box where the run
## enters a tapped building, and per-network joint hardware. Decisions
## come from LineSpecs.pipe_spec; side convention is world-axis based
## (X-runs offset in Z, Z-runs offset in X) so straights never zigzag.
func _orient_pipe(pos: Vector2i, node: Node3D) -> void:
	_orient_surface_pipe(pos, node, City.model.heat_pipes, "heat")


func _orient_water_pipe(pos: Vector2i, node: Node3D) -> void:
	_orient_surface_pipe(pos, node, City.model.water_pipes, "water")


func _pipe_cylinder(radius: float, height: float, color: Color) -> MeshInstance3D:
	var seg := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	seg.mesh = cyl
	seg.material_override = _flat(color)
	return seg


func _orient_surface_pipe(pos: Vector2i, node: Node3D, layer: Dictionary,
		network: String) -> void:
	var heat := network == "heat"
	var spec := LineSpecs.pipe_spec(City.model, pos, layer, network)
	var wanted := LineSpecs.cable_cache_key(spec,
		City.model.roads.has(pos), _terrain_fingerprint)
	if node.get_meta("pipes", "") == wanted:
		return
	node.set_meta("pipes", wanted)
	for child in node.get_children():
		child.queue_free()
	if int(spec["kind"]) == BuildingDefs.LINE_UNDERGROUND:
		_orient_buried(pos, node, layer, network,
			[PIPE_SUPPLY_COLOR, PIPE_RETURN_COLOR] if heat
				else [WATER_PIPE_COLOR], false)
		return
	# support foot
	node.add_child(_box(Vector3(0.14, PIPE_HEIGHT - 0.05, 0.14),
		Color(0.45, 0.46, 0.5), Vector3(0, (PIPE_HEIGHT - 0.05) / 2.0, 0)))
	# heat: supply/return pair offset perpendicular; water: one center run
	var radius := 0.055 if heat else 0.07
	var lines: Array = [[PIPE_SUPPLY_COLOR, 1.0], [PIPE_RETURN_COLOR, -1.0]] 		if heat else [[WATER_PIPE_COLOR, 0.0]]
	var box_size := Vector3(0.1, 0.3, 0.44) if heat else Vector3(0.1, 0.26, 0.24)
	for entry: Array in [[spec["links"], false], [spec["taps"], true]]:
		for dir_index: int in entry[0]:
			var d: Vector2i = LineSpecs.DIRECTIONS[dir_index]
			if entry[1]:
				# valve box / collar where the run enters the building
				node.add_child(_box(box_size if d.y == 0
					else Vector3(box_size.z, box_size.y, box_size.x),
					Color(0.5, 0.52, 0.56),
					Vector3(d.x * 0.48, PIPE_HEIGHT, d.y * 0.48)))
			var horizontal := d.y == 0  # segment runs along world X
			var perp := Vector3(0, 0, 0.13) if horizontal else Vector3(0.13, 0, 0)
			var dh := _ground_y(pos + d) - _ground_y(pos)
			for line: Array in lines:
				var seg := _pipe_cylinder(radius, 0.5, line[0])
				if horizontal:
					seg.rotation_degrees.z = 90.0
				else:
					seg.rotation_degrees.x = 90.0
				seg.position = Vector3(d.x * 0.25, PIPE_HEIGHT, d.y * 0.25) \
					+ perp * float(line[1])
				node.add_child(seg)
				if dh > 0.0:  # climbing a plateau step: riser at the edge
					var riser := _pipe_cylinder(radius, dh, line[0])
					riser.position = Vector3(d.x * 0.5, PIPE_HEIGHT + dh / 2.0,
						d.y * 0.5) + perp * float(line[1])
					node.add_child(riser)
	if (spec["links"] as Array).is_empty() and (spec["taps"] as Array).is_empty():
		return
	# joint hardware bridges the corner gaps: per-color flanges (heat),
	# one center knuckle (water)
	if heat:
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_SUPPLY_COLOR,
			Vector3(0.13, PIPE_HEIGHT, 0.13)))
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_RETURN_COLOR,
			Vector3(-0.13, PIPE_HEIGHT, -0.13)))
	else:
		node.add_child(_box(Vector3(0.17, 0.17, 0.17), WATER_PIPE_COLOR,
			Vector3(0, PIPE_HEIGHT, 0)))


## Kenney models per lot type (overhaul 2026-08-06, user request:
## city-kit-industrial for the producers, city-kit-commercial for
## retail — both CC0 like every other kit). Variants are deterministic
## per tile, exactly the house convention.
const COMMERCIAL_VARIANTS := {
	1: ["city-kit-industrial/Models/GLB format/building-b.glb",
		"city-kit-industrial/Models/GLB format/building-e.glb",
		"city-kit-industrial/Models/GLB format/building-m.glb"],
	2: ["city-kit-industrial/Models/GLB format/building-f.glb",
		"city-kit-industrial/Models/GLB format/building-n.glb"],
	3: ["city-kit-commercial/Models/GLB format/building-h.glb",
		"city-kit-commercial/Models/GLB format/building-i.glb",
		"city-kit-commercial/Models/GLB format/building-k.glb"],
}


func _make_commercial(pos: Vector2i) -> Node3D:
	var variants: Array = COMMERCIAL_VARIANTS.get(
		int(City.model.commercial.get(pos, 1)), COMMERCIAL_VARIANTS[1])
	var lot := _instance_glb(
		variants[abs(pos.x * 73856093 ^ pos.y * 19349663) % variants.size()], 0.85)
	lot.position = _center(pos)
	# face the serving road, like houses do
	var directions: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 0),
		Vector2i(0, -1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.roads.has(pos + directions[i]):
			lot.rotation_degrees.y = [0.0, 90.0, 180.0, 270.0][i]
			break
	return lot


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
	# window light: warm shadowless omni, driven per frame by night x power
	# (the whole point: a blackout at night really darkens the street)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.82, 0.5)
	light.omni_range = 1.45
	light.light_energy = 0.0
	light.shadow_enabled = false
	light.position = Vector3(0, 0.4, 0)
	light.set_meta("house_light", true)
	house.add_child(light)
	house.set_meta("light", light)
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


# ─── procedural fills (no kit model exists; same flat-shaded style) ───


## Delegates to the BuildingModels library (Phase-5 extraction); the
## kit-GLB fallback needs the scene cache, so it stays here. hud.gd's
## thumbnails/gallery call this and _pole_visual.
func _build_building_visual(kind: String) -> Node3D:
	var made := BuildingModels.make(kind)
	if made != null:
		return made
	return _instance_glb("city-kit-industrial/Models/GLB format/building-a.glb", 1.9)


func _pole_visual() -> Node3D:
	return BuildingModels.pole_visual()


func _wire_segment(from: Vector3, to: Vector3, thickness: float,
		color: Color) -> MeshInstance3D:
	return BuildingModels.wire_segment(from, to, thickness, color)


func _termination_hardware(toward: Vector3) -> Node3D:
	return BuildingModels.termination_hardware(toward)


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


## Upset-household bubble: a REAL poop emoji (user request — the reaction
## style of online video tools; Noto Emoji PNG, Apache-2.0, see
## assets/emoji/LICENSE.txt) over a small caption naming the cause.
func _make_upset_bubble(caption: String) -> Node3D:
	var bubble := Node3D.new()
	var emoji := Sprite3D.new()
	emoji.texture = load("res://assets/emoji/emoji_u1f4a9.png")
	emoji.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	emoji.pixel_size = 0.0042  # 128 px -> ~0.54 world units
	emoji.position = Vector3(0, 0.36, 0)
	bubble.add_child(emoji)
	var text := _make_marker(caption, Color(0.16, 0.19, 0.28), 90)
	text.outline_size = 34
	text.outline_modulate = Color(1, 1, 1, 0.95)
	bubble.add_child(text)
	bubble.position = Vector3(0, 1.35, 0)
	bubble.set_meta("kind", caption)
	return bubble


func _update_house_power() -> void:
	for pos: Vector2i in _houses:
		var zone: String = City.topo.house_zone.get(pos, "")
		var lit: bool = zone != "" and City.zone_supplied.get(zone, true)
		var heat_zone: String = City.heat_topo.house_zone.get(pos, "")
		var cold: bool = heat_zone != "" \
			and not City.heat_zone_supplied.get(heat_zone, true)
		# cold homes render icy blue; a BLACKOUT keeps the house colors (user:
		# no more houses turning black). Both miseries raise a poop-emoji
		# bubble with the cause as caption — blackout wins when both apply.
		_set_state_material(_houses[pos], "cold" if cold else "")
		var want := "no power" if not lit else ("freezing" if cold else "")
		var have: String = ""
		if _blackout_bubbles.has(pos) and is_instance_valid(_blackout_bubbles[pos]):
			have = _blackout_bubbles[pos].get_meta("kind", "")
		if want != have:
			if _blackout_bubbles.has(pos):
				if is_instance_valid(_blackout_bubbles[pos]):
					_blackout_bubbles[pos].queue_free()
				_blackout_bubbles.erase(pos)
			if want != "":
				var bubble := _make_upset_bubble(want)
				_houses[pos].add_child(bubble)
				_blackout_bubbles[pos] = bubble
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
	_update_house_lights()
	# gentle bob keeps the blackout bubbles alive
	var bob := sin(Time.get_ticks_msec() / 400.0) * 0.06
	for pos: Vector2i in _blackout_bubbles:
		if is_instance_valid(_blackout_bubbles[pos]):
			(_blackout_bubbles[pos] as Node3D).position.y = 1.35 + bob
	# spin the wind rotors — speed follows wind availability (a calm week
	# visibly idles the farm), and each turbine YAWS to face the eased wind
	# direction (same field the clouds and arrows follow)
	var wind_avail := WeatherSystem.wind_availability(
		float(City.weather.sample(City.current_t).get("wind_ms", 5.0)))
	var spin_deg := (12.0 + 150.0 * wind_avail) * delta
	var have_dir := not is_nan(_wind_vis_dir)
	# rotation.y = a maps local +z to (sin a, 0, cos a); the nose must point
	# UPWIND, i.e. against the drift vector (cos dir, 0, sin dir)
	var yaw := atan2(-cos(_wind_vis_dir), -sin(_wind_vis_dir)) if have_dir else 0.0
	for id: String in _buildings:
		if City.model.buildings[id]["kind"] == "wind_farm":
			for part: Node3D in _buildings[id].find_children("*", "Node3D", true, false):
				if part.has_meta("rotor"):
					part.rotation_degrees.z += spin_deg
				elif have_dir and part.has_meta("turbine"):
					part.rotation.y = yaw


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

## Adopt an existing building's placement — the pipette carries rotation
## and flip, because a picked-up solar park whose facing silently reset
## would quietly change its yield.
func set_ghost_transform(rot: int, flip: bool) -> void:
	_ghost_rot = rot % 4
	_ghost_flip = flip


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
			MOUSE_BUTTON_MIDDLE:
				# middle DRAG pans (unchanged); a middle CLICK is the
				# pipette. The travel test is what lets one button carry
				# both — the same click-vs-drag discrimination the orbit
				# button already tracks.
				if mb.pressed:
					_pan_travel = 0.0
				elif _pan_travel < PIPETTE_MAX_TRAVEL:
					pipette_requested.emit(mouse_tile())
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
			_pan_travel += mm.relative.length()
			_pan_ground(Vector2(-mm.relative.x, mm.relative.y) * 0.02 * (_zoom / 18.0))


func _apply_tool(pos: Vector2i) -> void:
	match tool:
		Tool.NONE:
			var id: String = City.model.building_tiles.get(pos, "")
			if id != "":
				building_clicked.emit(id)
			elif City.model.commercial.has(pos):
				tile_infra_clicked.emit("commercial", pos)
			elif City.model.houses.has(pos):
				tile_infra_clicked.emit("house", pos)
			elif City.model.cables.has(pos):
				tile_infra_clicked.emit("cable", pos)
			elif City.model.heat_pipes.has(pos):
				tile_infra_clicked.emit("heat_pipe", pos)
			elif City.model.water_pipes.has(pos):
				tile_infra_clicked.emit("water_pipe", pos)
			else:
				empty_clicked.emit()
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


## Screen-space bounding box of a set of tiles (ground corners through the
## live camera) — the HUD pops the inspector at the clicked element's
## top-right corner (user request 2026-08-04: graphs next to the element,
## not docked at the screen edge).
func tiles_screen_rect(tiles: Array) -> Rect2:
	var rect := Rect2()
	var first := true
	for pos: Vector2i in tiles:
		var y := _ground_y(pos)
		for corner: Vector3 in [Vector3(pos.x, y, pos.y),
				Vector3(pos.x + 1.0, y, pos.y),
				Vector3(pos.x, y, pos.y + 1.0),
				Vector3(pos.x + 1.0, y, pos.y + 1.0)]:
			var point := camera.unproject_position(corner)
			rect = Rect2(point, Vector2.ZERO) if first else rect.expand(point)
			first = false
	return rect


## Material/primitive shims over the BuildingModels statics (Phase-5
## extraction) — the shared material cache lives there now.
func _flat(color: Color, transparent: bool = false, unshaded: bool = false) -> StandardMaterial3D:
	return BuildingModels.flat(color, transparent, unshaded)


func _box(size: Vector3, color: Color, offset: Vector3) -> MeshInstance3D:
	return BuildingModels.box(size, color, offset)


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
