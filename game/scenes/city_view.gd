class_name CityView
extends Node3D
## Renders City.model in real 3D (ADR-005): locked isometric orthographic
## camera, Kenney CC0 GLB models + procedural fills, incremental instance
## diffing per layer. Same public API as the 2D version: Tool, tool,
## overlays_visible, redraw(), mouse_tile().
## One tile = 1.0 world unit; tile (x, y) occupies [x, x+1)×[y, y+1) on the
## ground plane, model centers at (x+0.5, 0, y+0.5).

enum Tool { NONE, ROAD, ZONE, CABLE, SUBSTATION, GAS, WIND, SOLAR, BATTERY, GRID,
	BULLDOZE, PIPE, HEAT_SUB, BOILER, CHP, HEATPUMP, HEATSTORE }

const TOOL_BUILDING := {
	Tool.SUBSTATION: "substation", Tool.GAS: "gas_plant", Tool.WIND: "wind_farm",
	Tool.SOLAR: "solar_park", Tool.BATTERY: "battery", Tool.GRID: "grid_connection",
	Tool.HEAT_SUB: "heat_exchanger", Tool.BOILER: "boiler_plant",
	Tool.CHP: "chp_plant", Tool.HEATPUMP: "heat_pump_plant",
	Tool.HEATSTORE: "heat_storage",
}

const KENNEY := "res://assets/kenney/"

## Network color language (user direction): heat = red/blue double pipe
## (forward/return — physically honest, the backend models both sides);
## water (Phase 5) = green.
const PIPE_SUPPLY_COLOR := Color(0.85, 0.22, 0.15)
const PIPE_RETURN_COLOR := Color(0.2, 0.38, 0.85)
const WATER_PIPE_COLOR := Color(0.2, 0.7, 0.35)  # reserved for Phase 5
const PIPE_HEIGHT := 0.16
const HOUSE_VARIANTS := ["a", "b", "c", "d", "e", "f", "g", "h", "l", "m", "n", "q"]

var tool: Tool = Tool.NONE
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

# pos/id -> Node3D, one dict per layer (incremental diff in redraw)
var _roads := {}
var _cables := {}
var _pipes := {}
var _zones := {}
var _houses := {}
var _buildings := {}
var _rings := {}          # zone/slack overlay rings
var _cursor: MeshInstance3D
var _painting := false
var _erasing := false

var _dark_material := StandardMaterial3D.new()
var _cold_material := StandardMaterial3D.new()
var _house_scene_cache := {}


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
	redraw()


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.shadow_enabled = true
	sun.light_energy = 1.25
	sun.directional_shadow_max_distance = 220.0
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.7, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.68, 0.72, 0.82)
	env.ambient_light_energy = 0.42
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(256, 256)
	ground.mesh = plane
	ground.position = Vector3(128, -0.01, 128)
	ground.material_override = _flat(Color(0.36, 0.52, 0.29))
	add_child(ground)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	add_child(camera)
	_place_camera()
	camera.make_current()


func _place_camera() -> void:
	camera.size = _zoom
	var direction := Vector3(-1, 1.15, -1).normalized() \
		.rotated(Vector3.UP, deg_to_rad(_cam_yaw))
	camera.position = _cam_focus + direction * 90.0
	camera.look_at(_cam_focus, Vector3.UP)


func rotate_view(steps: int) -> void:
	_cam_yaw_target += steps * 90.0


func focus_tile(tile: Vector2i, zoom: float = 18.0) -> void:
	_zoom = zoom
	_cam_focus = Vector3(tile.x + 0.5, 0, tile.y + 0.5)
	_place_camera()


# ─── redraw: incremental diff per layer ───

func redraw() -> void:
	var model: WorldModel = City.model
	_diff(_zones, model.zoning, _make_zone)
	_diff(_roads, model.roads, _make_road)
	_diff(_cables, model.cables, _make_cable)
	_diff(_pipes, model.heat_pipes, _make_pipe)
	_diff(_houses, model.houses, _make_house)
	_diff(_buildings, model.buildings, _make_building)
	# neighbor-dependent pieces refresh in place
	for pos: Vector2i in _roads:
		_orient_road(pos, _roads[pos])
	for pos: Vector2i in _cables:
		_orient_cable(pos, _cables[pos])
	for pos: Vector2i in _pipes:
		_orient_pipe(pos, _pipes[pos])
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


# ─── makers ───

func _make_zone(pos: Vector2i) -> Node3D:
	var quad := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(0.92, 0.92)
	quad.mesh = mesh
	quad.material_override = _flat(Color(0.45, 0.8, 0.4, 0.28), true)
	quad.position = _center(pos) + Vector3(0, 0.01, 0)
	return quad


func _make_road(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # child mesh set by _orient_road


func _orient_road(pos: Vector2i, node: Node3D) -> void:
	var mask := 0
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.roads.has(pos + directions[i]):
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
	# mask bits: 1=N 2=E 4=S 8=W. Kenney road GLBs run along X at yaw 0,
	# hence the +90 base against the first-render "ladder" look.
	match mask:
		0: return ["road-end-round", 90]
		1: return ["road-end", 270]
		2: return ["road-end", 180]
		4: return ["road-end", 90]
		8: return ["road-end", 0]
		5: return ["road-straight", 90]
		10: return ["road-straight", 0]
		3: return ["road-bend", 270]
		6: return ["road-bend", 180]
		12: return ["road-bend", 90]
		9: return ["road-bend", 0]
		7: return ["road-intersection", 180]
		14: return ["road-intersection", 90]
		13: return ["road-intersection", 0]
		11: return ["road-intersection", 270]
		_: return ["road-crossroad", 0]


func _make_cable(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
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
	return node  # wire segments added by _orient_cable


func _orient_cable(pos: Vector2i, node: Node3D) -> void:
	var connections := ""
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.cables.has(pos + directions[i]):
			connections += str(i)
	if node.get_meta("wires", "") == connections:
		return
	node.set_meta("wires", connections)
	for child in node.get_children():
		if child.has_meta("wire"):
			child.queue_free()
	for i in 4:
		if not City.model.cables.has(pos + directions[i]):
			continue
		var wire := MeshInstance3D.new()
		wire.set_meta("wire", true)
		var wire_mesh := BoxMesh.new()
		wire_mesh.size = Vector3(0.03, 0.03, 0.5)
		wire.mesh = wire_mesh
		wire.position = Vector3(directions[i].x * 0.25, 0.74, directions[i].y * 0.25)
		if i == 1 or i == 3:
			wire.rotation_degrees.y = 90
		wire.material_override = _flat(Color(0.2, 0.2, 0.22))
		node.add_child(wire)


func _make_pipe(pos: Vector2i) -> Node3D:
	var node := Node3D.new()
	node.position = _center(pos)
	return node  # segments set by _orient_pipe


## District-heating double pipe: forward (red) and return (blue) run in
## parallel on low supports. One segment pair per connected direction from
## the tile center to its edge — handles straights, bends, tees and crosses
## without piece-picking. Side convention is world-axis based (X-runs offset
## in Z, Z-runs offset in X) so straights never zigzag.
func _orient_pipe(pos: Vector2i, node: Node3D) -> void:
	var connections := ""
	var directions: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for i in 4:
		if City.model.heat_pipes.has(pos + directions[i]):
			connections += str(i)
	if node.get_meta("pipes", "") == connections:
		return
	node.set_meta("pipes", connections)
	for child in node.get_children():
		child.queue_free()
	# support foot
	node.add_child(_box(Vector3(0.14, PIPE_HEIGHT - 0.05, 0.14),
		Color(0.45, 0.46, 0.5), Vector3(0, (PIPE_HEIGHT - 0.05) / 2.0, 0)))
	var any_connection := false
	for i in 4:
		var d := directions[i]
		if not City.model.heat_pipes.has(pos + d):
			continue
		any_connection = true
		var horizontal := d.y == 0  # segment runs along world X
		var perp := Vector3(0, 0, 0.13) if horizontal else Vector3(0.13, 0, 0)
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
	# per-color joint flanges bridge the corner gaps
	if any_connection:
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_SUPPLY_COLOR,
			Vector3(0.13, PIPE_HEIGHT, 0.13)))
		node.add_child(_box(Vector3(0.15, 0.15, 0.15), PIPE_RETURN_COLOR,
			Vector3(-0.13, PIPE_HEIGHT, -0.13)))


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
	node.position = Vector3(anchor.x + size.x / 2.0, 0, anchor.y + size.y / 2.0)
	node.rotation_degrees.y = int(entry.get("rot", 0)) * 90.0
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
			return _instance_glb("factory-kit/Models/GLB format/machine-bed.glb", 0.7)
		_:
			return _instance_glb("city-kit-industrial/Models/GLB format/building-a.glb", 1.9)


# ─── procedural fills (no kit model exists; same flat-shaded style) ───

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

func _update_house_power() -> void:
	for pos: Vector2i in _houses:
		var zone: String = City.topo.house_zone.get(pos, "")
		var lit: bool = zone != "" and City.zone_supplied.get(zone, true)
		var heat_zone: String = City.heat_topo.house_zone.get(pos, "")
		var cold: bool = heat_zone != "" \
			and not City.heat_zone_supplied.get(heat_zone, true)
		# no power dominates visually; else cold homes render icy blue
		_set_state_material(_houses[pos],
			"dark" if not lit else ("cold" if cold else ""))


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
	# voltage rings at substations, temperature rings at heat exchangers
	for key: Variant in _rings.keys():
		if not (City.topo.zones_info.has(key) or City.heat_topo.zones_info.has(key)):
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
	_cursor.position = Vector3(mouse_tile().x + 0.5, 0.02, mouse_tile().y + 0.5)
	_update_ghost()
	# spin the wind rotors — the world should feel alive
	for id: String in _buildings:
		if City.model.buildings[id]["kind"] == "wind_farm":
			for rotor: Node3D in _buildings[id].find_children("*", "Node3D", true, false):
				if rotor.has_meta("rotor"):
					rotor.rotation_degrees.z += 90.0 * delta


# ─── ghost placement preview ───

func rotate_ghost() -> void:
	_ghost_rot = (_ghost_rot + 1) % 4


func _update_ghost() -> void:
	var kind: String = TOOL_BUILDING.get(tool, "")
	if kind == "":
		if _ghost:
			_ghost.queue_free()
			_ghost = null
			_ghost_kind = ""
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
	_ghost.position = Vector3(anchor.x + size.x / 2.0, 0.01, anchor.y + size.y / 2.0)
	_ghost.rotation_degrees.y = _ghost_rot * 90.0
	var affordable: bool = City.money >= int(BuildingDefs.DEFS[kind]["cost"])
	var valid: bool = City.model.can_place_building(kind, anchor) and affordable
	var tint := _flat(Color(0.3, 0.9, 0.4, 0.5), true) if valid \
		else _flat(Color(0.95, 0.25, 0.2, 0.5), true)
	for mesh: MeshInstance3D in _ghost.find_children("*", "MeshInstance3D", true, false):
		mesh.material_override = tint


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
				_painting = mb.pressed
				if mb.pressed:
					_apply_tool(mouse_tile())
			MOUSE_BUTTON_RIGHT:
				_erasing = mb.pressed
				if mb.pressed:
					City.bulldoze(mouse_tile())
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
		if _painting:
			_apply_tool(mouse_tile())
		elif _erasing:
			City.bulldoze(mouse_tile())
		elif mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan_ground(Vector2(-mm.relative.x, mm.relative.y) * 0.02 * (_zoom / 18.0))


func _apply_tool(pos: Vector2i) -> void:
	match tool:
		Tool.ROAD:
			City.build_road(pos)
		Tool.ZONE:
			City.build_zone(pos)
		Tool.CABLE:
			City.build_cable(pos)
		Tool.PIPE:
			City.build_heat_pipe(pos)
		Tool.BULLDOZE:
			City.bulldoze(pos)
		_:
			if TOOL_BUILDING.has(tool):
				City.place_building(TOOL_BUILDING[tool], pos, _ghost_rot)
				_painting = false


func mouse_tile() -> Vector2i:
	var mouse := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse)
	var direction := camera.project_ray_normal(mouse)
	if absf(direction.y) < 0.0001:
		return Vector2i.ZERO
	var hit := origin - direction * (origin.y / direction.y)
	return Vector2i(int(floor(hit.x)), int(floor(hit.z)))


# ─── helpers ───

func _center(pos: Vector2i) -> Vector3:
	return Vector3(pos.x + 0.5, 0, pos.y + 0.5)


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
