class_name CityView
extends Node2D
## Renders City.model as isometric TileMapLayers (views of the model,
## ADR-002) and handles the build tools. Overlays (line loading, zone
## voltage, dark houses) draw in _draw() on top.

const MAP_SIZE := 256
const TILE_W := 64
const TILE_H := 32

enum Tool { NONE, ROAD, ZONE, CABLE, SUBSTATION, GAS, WIND, SOLAR, BATTERY, GRID, BULLDOZE }

const TOOL_BUILDING := {
	Tool.SUBSTATION: "substation", Tool.GAS: "gas_plant", Tool.WIND: "wind_farm",
	Tool.SOLAR: "solar_park", Tool.BATTERY: "battery", Tool.GRID: "grid_connection",
}

# atlas columns
const T_GRASS := 0
const T_CABLE := 1
const T_ROAD := 2
const T_ZONE := 3
const T_HOUSE_LIT := 4
const T_HOUSE_DARK := 5
const T_TRIPPED := 6
const T_BUILDING_BASE := 7  # + building kind index

const BUILDING_ORDER: Array[String] = [
	"substation", "grid_connection", "gas_plant", "wind_farm", "solar_park", "battery"]

var tool: Tool = Tool.NONE
var overlays_visible := true
var cam: Camera2D

var _terrain: TileMapLayer
var _ground: TileMapLayer     # roads + zoning
var _network: TileMapLayer    # cables
var _structures: TileMapLayer # houses + buildings
var _painting := false
var _erasing := false


func _ready() -> void:
	var tile_set := _make_tileset()
	for layer_ref: Array in [["_terrain", 0], ["_ground", 1], ["_network", 2], ["_structures", 3]]:
		var layer := TileMapLayer.new()
		layer.tile_set = tile_set
		layer.z_index = layer_ref[1]
		add_child(layer)
		set(layer_ref[0], layer)
	for x in MAP_SIZE:
		for y in MAP_SIZE:
			_terrain.set_cell(Vector2i(x, y), 0, Vector2i(T_GRASS, 0))
	cam = Camera2D.new()
	add_child(cam)
	cam.position = _terrain.map_to_local(Vector2i(MAP_SIZE / 2, MAP_SIZE / 2))
	cam.make_current()
	City.world_changed.connect(redraw)
	City.power_result.connect(func(_t: int, _r: Dictionary) -> void: queue_redraw())
	redraw()


func redraw() -> void:
	_ground.clear()
	_network.clear()
	_structures.clear()
	var model: WorldModel = City.model
	for pos: Vector2i in model.zoning:
		_ground.set_cell(pos, 0, Vector2i(T_ZONE, 0))
	for pos: Vector2i in model.roads:
		_ground.set_cell(pos, 0, Vector2i(T_ROAD, 0))
	for pos: Vector2i in model.cables:
		var tripped: bool = City.tripped_tiles.has(pos)
		_network.set_cell(pos, 0, Vector2i(T_TRIPPED if tripped else T_CABLE, 0))
	for pos: Vector2i in model.houses:
		var zone: String = City.topo.house_zone.get(pos, "")
		var lit: bool = zone != "" and City.zone_supplied.get(zone, true)
		_structures.set_cell(pos, 0, Vector2i(T_HOUSE_LIT if lit else T_HOUSE_DARK, 0))
	for id: String in model.buildings:
		var entry: Dictionary = model.buildings[id]
		var atlas_x: int = T_BUILDING_BASE + BUILDING_ORDER.find(entry["kind"])
		for tile: Vector2i in BuildingDefs.footprint(entry["kind"], entry["anchor"]):
			_structures.set_cell(tile, 0, Vector2i(atlas_x, 0))
	queue_redraw()


## Overlays: cable tiles colored by loading (contract 1.1 edges), voltage
## rings at substations, capacity ring at the grid connection.
func _draw() -> void:
	if not overlays_visible:
		return
	var edges: Dictionary = City.last_result.get("edges", {})
	for line_id: String in City.topo.line_tiles:
		if not edges.has(line_id):
			continue
		var loading := float(edges[line_id].get("loading_percent", 0.0))
		var color := Color(0.2, 0.9, 0.2, 0.55)
		if loading > 100.0:
			color = Color(1.0, 0.15, 0.1, 0.8)
		elif loading > 60.0:
			color = Color(1.0, 0.7, 0.1, 0.65)
		for tile: Vector2i in City.topo.line_tiles[line_id]:
			_diamond(tile, color)
	for zone_id: String in City.topo.zones_info:
		var zone_result: Dictionary = City.last_result.get("zones", {}).get(zone_id, {})
		var v_pu := float(zone_result.get("detail", {}).get("v_pu", 0.0))
		var color := Color(0.5, 0.5, 0.5)
		if v_pu > 0.0:
			var deviation := clampf(absf(v_pu - 1.0) / 0.1, 0.0, 1.0)
			color = Color(deviation, 1.0 - deviation, 0.1)
		var center: Vector2i = City.topo.zones_info[zone_id]["center"]
		draw_arc(_terrain.map_to_local(center), TILE_H * 0.9, 0, TAU, 24, color, 3.0)


func _diamond(tile: Vector2i, color: Color) -> void:
	var center := _terrain.map_to_local(tile)
	var points := PackedVector2Array([
		center + Vector2(0, -TILE_H / 2.0), center + Vector2(TILE_W / 2.0, 0),
		center + Vector2(0, TILE_H / 2.0), center + Vector2(-TILE_W / 2.0, 0)])
	draw_colored_polygon(points, color)


# ─── input (tools) ───

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
					cam.zoom = (cam.zoom * 1.1).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					cam.zoom = (cam.zoom / 1.1).clamp(Vector2(0.25, 0.25), Vector2(4, 4))
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _painting:
			_apply_tool(mouse_tile())
		elif _erasing:
			City.bulldoze(mouse_tile())
		elif mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			cam.position -= mm.relative / cam.zoom


func _process(delta: float) -> void:
	var pan := Vector2(Input.get_axis(&"ui_left", &"ui_right"),
		Input.get_axis(&"ui_up", &"ui_down"))
	cam.position += pan * 600.0 * delta / cam.zoom.x


func _apply_tool(pos: Vector2i) -> void:
	match tool:
		Tool.ROAD:
			City.build_road(pos)
		Tool.ZONE:
			City.build_zone(pos)
		Tool.CABLE:
			City.build_cable(pos)
		Tool.BULLDOZE:
			City.bulldoze(pos)
		_:
			if TOOL_BUILDING.has(tool):
				City.place_building(TOOL_BUILDING[tool], pos)
				_painting = false  # one building per click


func mouse_tile() -> Vector2i:
	return _terrain.local_to_map(_terrain.get_local_mouse_position())


# ─── procedural tile atlas ───

func _make_tileset() -> TileSet:
	var colors: Array[Color] = [
		Color(0.33, 0.55, 0.28),   # grass
		Color(0.95, 0.78, 0.15),   # cable
		Color(0.35, 0.35, 0.38),   # road
		Color(0.5, 0.75, 0.45, 0.5),  # zone marker
		Color(0.85, 0.75, 0.5),    # house lit (warm)
		Color(0.3, 0.3, 0.38),     # house dark
		Color(0.9, 0.2, 0.15),     # tripped cable
	]
	for kind: String in BUILDING_ORDER:
		colors.append(BuildingDefs.DEFS[kind]["color"])
	var img := Image.create(TILE_W * colors.size(), TILE_H, false, Image.FORMAT_RGBA8)
	for t in colors.size():
		var col := colors[t]
		var edge := col.darkened(0.35)
		var half_h := TILE_H / 2.0
		for y in TILE_H:
			var frac := 1.0 - absf(y - half_h + 0.5) / half_h
			var half_w := int(frac * TILE_W / 2.0)
			for x in range(TILE_W / 2 - half_w, TILE_W / 2 + half_w):
				var border := x <= TILE_W / 2 - half_w + 1 or x >= TILE_W / 2 + half_w - 2
				img.set_pixel(t * TILE_W + x, y, edge if border else col)
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = Vector2i(TILE_W, TILE_H)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE_W, TILE_H)
	for t in colors.size():
		src.create_tile(Vector2i(t, 0))
	ts.add_source(src, 0)
	return ts
