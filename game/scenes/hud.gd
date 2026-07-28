class_name Hud
extends CanvasLayer
## HUD: status bar, build menu (TAB — categorized tile palette with hover
## tooltips), tool hotkeys, event toasts, speed controls.

const TOOL_KEYS := {
	KEY_1: CityView.Tool.ROAD,
	KEY_2: CityView.Tool.ZONE,
	KEY_3: CityView.Tool.CABLE,
	KEY_4: CityView.Tool.SUBSTATION,
	KEY_5: CityView.Tool.GAS,
	KEY_6: CityView.Tool.WIND,
	KEY_7: CityView.Tool.SOLAR,
	KEY_8: CityView.Tool.BATTERY,
	KEY_9: CityView.Tool.GRID,
	KEY_0: CityView.Tool.BULLDOZE,
	KEY_H: CityView.Tool.PIPE,
	KEY_J: CityView.Tool.HEAT_SUB,
	KEY_B: CityView.Tool.BOILER,
	KEY_C: CityView.Tool.CHP,
	KEY_U: CityView.Tool.HEATPUMP,
	KEY_T: CityView.Tool.HEATSTORE,
	KEY_W: CityView.Tool.WATER_PIPE,
	KEY_A: CityView.Tool.WATER_SUB,
	KEY_N: CityView.Tool.WELL,
	KEY_P: CityView.Tool.PUMP,
	KEY_O: CityView.Tool.WATER_TOWER,
}

var view: CityView
var _status: Label
var _tool_label: Label
var _events_box: VBoxContainer
var _build_menu: PanelContainer
var _tool_buttons := {}          # CityView.Tool -> Button
var _button_group := ButtonGroup.new()
var _items_by_tool := {}         # CityView.Tool -> item Dictionary


## Palette data: monogram + hotkey + gameplay description per tool. Costs and
## swatch colors come from BuildingDefs for buildings; line tools carry their
## own. Categories per user direction: city basics, one infrastructure block
## per network, demolish on its own.
func _build_items() -> Array:
	return [
		{"cat": "City", "items": [
			{"tool": CityView.Tool.ROAD, "label": "Road", "mono": "Rd", "key": "1",
				"color": Color(0.45, 0.45, 0.5), "cost": BuildingDefs.COSTS["road"],
				"desc": "Drag to pave. Houses only grow on zoned tiles next to a road."},
			{"tool": CityView.Tool.ZONE, "label": "Residential zone", "mono": "Zn", "key": "2",
				"color": Color(0.45, 0.8, 0.4), "cost": BuildingDefs.COSTS["zone"],
				"desc": "Paint building land. Houses appear when a powered substation covers it and people are happy."},
		]},
		{"cat": "Electricity", "items": [
			{"tool": CityView.Tool.CABLE, "label": "Cable", "mono": "Cb", "key": "3",
				"color": Color(0.25, 0.25, 0.3), "cost": BuildingDefs.COSTS["cable"],
				"desc": "LV feeder (~98 kW). Connects plants and substations; sustained overload trips it."},
			{"tool": CityView.Tool.SUBSTATION, "label": "Substation", "mono": "Su", "key": "4",
				"kind": "substation",
				"desc": "Defines a power supply zone (radius 12). Houses inside draw electricity here."},
			{"tool": CityView.Tool.GRID, "label": "Grid connection", "mono": "Gr", "key": "9",
				"kind": "grid_connection",
				"desc": "External grid feed, 250 kW. The whole city blacks out if you overload it."},
			{"tool": CityView.Tool.GAS, "label": "Gas plant", "mono": "Ga", "key": "5",
				"kind": "gas_plant",
				"desc": "500 kW dispatchable generation — runs when wind and sun don't."},
			{"tool": CityView.Tool.WIND, "label": "Wind farm", "mono": "Wi", "key": "6",
				"kind": "wind_farm",
				"desc": "300 kW rated. Output follows the weather — calm spells produce nothing."},
			{"tool": CityView.Tool.SOLAR, "label": "Solar park", "mono": "So", "key": "7",
				"kind": "solar_park",
				"desc": "200 kW rated. Strong at summer noon, zero at night."},
			{"tool": CityView.Tool.BATTERY, "label": "Battery", "mono": "Ba", "key": "8",
				"kind": "battery",
				"desc": "200 kWh / 100 kW. Charges on surplus, bridges deficits (windless evenings)."},
		]},
		{"cat": "Heat", "items": [
			{"tool": CityView.Tool.PIPE, "label": "Heat pipe", "mono": "Hp", "key": "H",
				"color": CityView.PIPE_SUPPLY_COLOR, "cost": BuildingDefs.COSTS["heat_pipe"],
				"desc": "District-heating pair: red forward, blue return. Long runs lose temperature."},
			{"tool": CityView.Tool.HEAT_SUB, "label": "Heat exchanger", "mono": "Hx", "key": "J",
				"kind": "heat_exchanger",
				"desc": "Defines a heat zone (radius 12). Homes inside get district heat."},
			{"tool": CityView.Tool.BOILER, "label": "Boiler plant", "mono": "Bo", "key": "B",
				"kind": "boiler_plant",
				"desc": "Cheap heat, but low flow temperature (66°C) — far ends go cold in deep winter."},
			{"tool": CityView.Tool.CHP, "label": "CHP plant", "mono": "CH", "key": "C",
				"kind": "chp_plant",
				"desc": "Heat AND electricity (85°C). Cable it up: its power feeds your grid."},
			{"tool": CityView.Tool.HEATPUMP, "label": "Heat pump plant", "mono": "HP", "key": "U",
				"kind": "heat_pump_plant",
				"desc": "Heat from electricity (70°C). Draws serious grid power in cold snaps."},
			{"tool": CityView.Tool.HEATSTORE, "label": "Heat storage", "mono": "St", "key": "T",
				"kind": "heat_storage",
				"desc": "500 kWh buffer tank: charges at night, carries the morning peak."},
		]},
		{"cat": "Water", "items": [
			{"tool": CityView.Tool.WATER_PIPE, "label": "Water pipe", "mono": "Wp", "key": "W",
				"color": CityView.WATER_PIPE_COLOR, "cost": BuildingDefs.COSTS["water_pipe"],
				"desc": "Drinking-water main (green). Pressure falls with distance and elevation."},
			{"tool": CityView.Tool.WATER_SUB, "label": "Water station", "mono": "Ws", "key": "A",
				"kind": "water_station",
				"desc": "Defines a water zone (radius 12). Homes inside tap this network."},
			{"tool": CityView.Tool.WELL, "label": "Well", "mono": "We", "key": "N",
				"kind": "well",
				"desc": "Gravity well field, no power needed — but droughts shrink its yield."},
			{"tool": CityView.Tool.PUMP, "label": "Pumping station", "mono": "Pu", "key": "P",
				"kind": "pumping_station",
				"desc": "High yield and pressure, needs a cable: a blackout here stops the water."},
			{"tool": CityView.Tool.WATER_TOWER, "label": "Water tower", "mono": "Tw", "key": "O",
				"kind": "water_tower",
				"desc": "Pressure head + 200 m³ buffer. Rides through pump outages; taller = more bar."},
		]},
		{"cat": "Demolish", "items": [
			{"tool": CityView.Tool.BULLDOZE, "label": "Bulldozer", "mono": "X", "key": "0",
				"color": Color(0.8, 0.25, 0.2), "cost": 0,
				"desc": "Remove anything (buildings refund 25%). Right-drag bulldozes too."},
		]},
	]


func _ready() -> void:
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	top.add_child(row)
	_status = Label.new()
	row.add_child(_status)
	_tool_label = Label.new()
	_tool_label.text = "Tool: none — TAB build menu · Q/E rotate view · R rotate ghost · SPACE pause · V overlays"
	row.add_child(_tool_label)

	var events_panel := PanelContainer.new()
	events_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	events_panel.offset_top = 44.0
	events_panel.offset_left = -420.0
	add_child(events_panel)
	_events_box = VBoxContainer.new()
	events_panel.add_child(_events_box)

	_make_build_menu()

	City.state_changed.connect(_refresh)
	City.event_logged.connect(_on_event)
	GameClock.speed_changed.connect(func(_s: float) -> void: _refresh())
	var ticker := Timer.new()  # keeps clock + syncing indicator moving
	ticker.wait_time = 0.5
	ticker.autostart = true
	ticker.timeout.connect(_refresh)
	add_child(ticker)
	_refresh()


# ─── build menu (palette) ───

func _make_build_menu() -> void:
	_build_menu = PanelContainer.new()
	_build_menu.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_build_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_build_menu.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_build_menu.offset_bottom = -10.0
	add_child(_build_menu)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	_build_menu.add_child(columns)
	for category: Dictionary in _build_items():
		var col := VBoxContainer.new()
		var header := Label.new()
		header.text = category["cat"]
		header.add_theme_font_size_override("font_size", 11)
		header.modulate = Color(1, 1, 1, 0.65)
		col.add_child(header)
		var tile_row := HBoxContainer.new()
		tile_row.add_theme_constant_override("separation", 4)
		col.add_child(tile_row)
		for item: Dictionary in category["items"]:
			tile_row.add_child(_make_tile(item))
		columns.add_child(col)
		if category["cat"] != "Demolish":
			columns.add_child(VSeparator.new())


func _make_tile(item: Dictionary) -> Button:
	var color: Color = item.get("color", Color.GRAY)
	var cost: int = item.get("cost", 0)
	if item.has("kind"):
		var def := BuildingDefs.get_def(item["kind"])
		color = def["color"]
		cost = def["cost"]
	_items_by_tool[item["tool"]] = item
	var button := Button.new()
	button.text = item["mono"]
	button.custom_minimum_size = Vector2(44, 44)
	button.toggle_mode = true
	button.button_group = _button_group
	button.focus_mode = Control.FOCUS_NONE  # keep TAB for the menu toggle
	button.tooltip_text = "%s (%s) — %s\n%s" % [item["label"], item["key"],
		("€%d" % cost) if cost > 0 else "free", item["desc"]]
	var normal := StyleBoxFlat.new()
	normal.bg_color = color.darkened(0.25)
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(4)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = color
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = color.lightened(0.15)
	pressed.border_color = Color.WHITE
	pressed.set_border_width_all(2)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.pressed.connect(func() -> void: _select_tool(item["tool"]))
	_tool_buttons[item["tool"]] = button
	return button


func _select_tool(tool: CityView.Tool) -> void:
	view.tool = tool
	var item: Dictionary = _items_by_tool.get(tool, {})
	_tool_label.text = "Tool: %s" % item.get("label", "none")
	if _tool_buttons.has(tool):
		(_tool_buttons[tool] as Button).set_pressed_no_signal(true)


func _refresh() -> void:
	var demand := 0.0
	for zone_id: String in City.topo.zones_info:
		demand += DemandModel.zone_demand_kw(
			City.topo.zones_info[zone_id]["houses"], City.current_t)
	var houses := City.model.houses.size()
	_status.text = "Day %d %s (%s, %.0f°C) · %s · €%s · Happy %.0f%% · %d houses · %.0f kW el · Outage %d min el / %d min heat / %d min water%s" % [
		GameClock.day(), GameClock.time_of_day_string(), GameClock.season_name(),
		float(City.weather.sample(City.current_t)["temp_c"]),
		("PAUSED" if GameClock.speed == 0.0 else "%.0fx" % GameClock.speed),
		_fmt_money(City.money), City.happiness, houses, demand,
		City.total_outage_minutes(), City.total_heat_outage_minutes(),
		City.total_water_outage_minutes(),
		("  ·  ⟳ rebuilding grid…" if City.is_syncing() else "")]


func _on_event(event: Dictionary) -> void:
	var label := Label.new()
	label.text = "[%s] %s" % [event["severity"], event["text"]]
	match event["severity"]:
		"critical":
			label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
		"warning":
			label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
	_events_box.add_child(label)
	if _events_box.get_child_count() > 6:
		_events_box.get_child(0).queue_free()
	get_tree().create_timer(12.0).timeout.connect(
		func() -> void:
			if is_instance_valid(label):
				label.queue_free())


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed():
		return
	var key: InputEventKey = event
	if TOOL_KEYS.has(key.keycode):
		_select_tool(TOOL_KEYS[key.keycode])
	elif key.keycode == KEY_TAB:
		_build_menu.visible = not _build_menu.visible
	elif key.keycode == KEY_SPACE:
		GameClock.speed = 1.0 if GameClock.speed == 0.0 else 0.0
	elif key.keycode == KEY_EQUAL or key.keycode == KEY_KP_ADD:
		GameClock.speed = clampf(GameClock.speed * 2.0 if GameClock.speed > 0.0 else 1.0, 0.0, 32.0)
	elif key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
		GameClock.speed = maxf(GameClock.speed / 2.0, 0.25)
	elif key.keycode == KEY_V:
		view.overlays_visible = not view.overlays_visible
	elif key.keycode == KEY_Q:
		view.rotate_view(-1)
	elif key.keycode == KEY_E:
		view.rotate_view(1)
	elif key.keycode == KEY_R:
		view.rotate_ghost()


static func _fmt_money(value: int) -> String:
	var text := str(value)
	var out := ""
	while text.length() > 3:
		out = "." + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return text + out
