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
	KEY_G: CityView.Tool.UCABLE,
	KEY_M: CityView.Tool.REPAIR,
	KEY_K: CityView.Tool.BURIED_PIPE,
	KEY_L: CityView.Tool.BURIED_WATER,
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
			{"tool": CityView.Tool.CABLE, "label": "Overhead line", "mono": "Oh", "key": "3",
				"color": Color(0.45, 0.36, 0.28), "cost": BuildingDefs.COSTS["overhead_line"],
				"desc": "Pole-and-wire feeder (~145 kVA). Cheap and visible; sustained overload trips it."},
			{"tool": CityView.Tool.UCABLE, "label": "Underground cable", "mono": "Ug", "key": "G",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["cable"],
				"desc": "Buried NAYY 4x150 (~187 kVA). Pricier, out of sight — joins overhead runs freely."},
			{"tool": CityView.Tool.SUBSTATION, "label": "Substation", "mono": "Su", "key": "4",
				"kind": "substation",
				"desc": "20/0.4 kV district transformer (250 kVA), supply zone radius 12. Houses inside draw electricity here."},
			{"tool": CityView.Tool.GRID, "label": "Grid connection", "mono": "Gr", "key": "9",
				"kind": "grid_connection",
				"desc": "The 110/20 kV interface to the transmission grid — 10 MVA. Your city's lifeline and wholesale meter."},
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
			{"tool": CityView.Tool.BURIED_PIPE, "label": "Buried heat pipe", "mono": "Bh", "key": "K",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["heat_pipe_buried"],
				"desc": "Same pair, trenched: crosses under roads and shares the street with other buried lines."},
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
			{"tool": CityView.Tool.BURIED_WATER, "label": "Buried water pipe", "mono": "Bw", "key": "L",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["water_pipe_buried"],
				"desc": "Same main, trenched: crosses under roads and shares the street with other buried lines."},
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
		{"cat": "Service", "items": [
			{"tool": CityView.Tool.NONE, "label": "Inspect", "mono": "?", "key": "Esc",
				"color": Color(0.31, 0.76, 0.97), "cost": 0,
				"desc": "No tool: click any building or line/pipe to open its daily graph. Esc always returns here."},
			{"tool": CityView.Tool.REPAIR, "label": "Repair crew", "mono": "Rp", "key": "M",
				"color": Color(1.0, 0.75, 0.2), "cost": City.CREW_COST,
				"desc": "Send a crew to a TRIPPED line or transformer (~2 h work). Overload trips don't fix themselves."},
			{"tool": CityView.Tool.BULLDOZE, "label": "Bulldozer", "mono": "X", "key": "0",
				"color": Color(0.8, 0.25, 0.2), "cost": 0,
				"desc": "Remove anything (buildings refund 25%)."},
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
	_tool_label.text = "Tool: none — TAB build menu · I happiness breakdown · right-drag orbit · Q/E snap 90° · R rotate ghost · SPACE pause · V overlays"
	row.add_child(_tool_label)
	for pair: Array in [["Save", "save"], ["Load", "load"]]:
		var slot_button := Button.new()
		slot_button.text = pair[0]
		slot_button.focus_mode = Control.FOCUS_NONE
		var mode: String = pair[1]
		slot_button.pressed.connect(func() -> void: show_slot_dialog(mode))
		row.add_child(slot_button)

	var events_panel := PanelContainer.new()
	events_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	events_panel.offset_top = 44.0
	events_panel.offset_left = -420.0
	add_child(events_panel)
	_events_box = VBoxContainer.new()
	events_panel.add_child(_events_box)

	_make_build_menu()
	_render_thumbnails()  # async: icons replace the monograms as they render
	_make_breakdown()
	view.building_clicked.connect(_open_inspector)
	view.tile_infra_clicked.connect(_open_tile_inspector)

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
		if category["cat"] != "Service":
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
	# neutral slate: the 3D thumbnail carries the identity, the item color
	# survives as a slim bottom accent (network color language at a glance)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.16, 0.18, 0.22)
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(3)
	normal.border_color = color
	normal.border_width_bottom = 3
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.24, 0.27, 0.33)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.28, 0.32, 0.4)
	pressed.border_color = Color.WHITE
	pressed.set_border_width_all(2)
	pressed.border_width_bottom = 3
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.pressed.connect(func() -> void: _select_tool(item["tool"]))
	_tool_buttons[item["tool"]] = button
	return button


# ─── happiness breakdown (Phase 6: see WHAT is wrong, not just that
# something is) — per-network satisfaction bars + outage records ───

var _breakdown: PanelContainer
var _breakdown_bars := {}    # network -> ProgressBar
var _breakdown_notes := {}   # network -> Label

const BREAKDOWN_ROWS := [
	["power", "Electricity", Color(0.95, 0.8, 0.25)],
	["heat", "Heat", Color(0.9, 0.4, 0.25)],
	["water", "Water", Color(0.25, 0.65, 0.9)],
]


func _make_breakdown() -> void:
	_breakdown = PanelContainer.new()
	_breakdown.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_breakdown.offset_top = 44.0
	_breakdown.offset_left = 8.0
	_breakdown.visible = false
	add_child(_breakdown)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	_breakdown.add_child(box)
	var title := Label.new()
	title.text = "Happiness — what's wrong? (I closes)"
	title.add_theme_font_size_override("font_size", 12)
	box.add_child(title)
	for row: Array in BREAKDOWN_ROWS:
		var label := Label.new()
		label.text = row[1]
		label.add_theme_color_override("font_color", row[2])
		box.add_child(label)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 100.0
		bar.show_percentage = true
		var fill := StyleBoxFlat.new()
		fill.bg_color = row[2]
		bar.add_theme_stylebox_override("fill", fill)
		box.add_child(bar)
		_breakdown_bars[row[0]] = bar
		var note := Label.new()
		note.add_theme_font_size_override("font_size", 11)
		note.modulate = Color(1, 1, 1, 0.7)
		box.add_child(note)
		_breakdown_notes[row[0]] = note
	_make_budget_section(box)


var _budget_label: Label


func _refresh_breakdown() -> void:
	if not _breakdown.visible:
		return
	var outages := {
		"power": City.total_outage_minutes(),
		"heat": City.total_heat_outage_minutes(),
		"water": City.total_water_outage_minutes(),
	}
	for network: String in _breakdown_bars:
		(_breakdown_bars[network] as ProgressBar).value = float(City.satisfaction[network])
		(_breakdown_notes[network] as Label).text = "%d outage-min on record" % outages[network]
	var e: Dictionary = City.econ_yesterday
	var income := float(e.get("income_elec", 0.0)) + float(e.get("income_heat", 0.0)) \
		+ float(e.get("income_water", 0.0)) + float(e.get("income_feedin", 0.0))
	var costs := float(e.get("cost_fuel", 0.0)) + float(e.get("cost_upkeep", 0.0)) \
		+ float(e.get("cost_grid", 0.0)) + float(e.get("cost_interest", 0.0))
	_budget_label.text = "— Budget (yesterday) —
Income  €%.0f   (el %.0f · heat %.0f · water %.0f · feed-in %.0f)
Costs   €%.0f   (fuel %.0f · upkeep %.0f · grid %.0f · interest %.0f)
Net     €%.0f       Loans outstanding €%.0f" % [
		income, e.get("income_elec", 0.0), e.get("income_heat", 0.0),
		e.get("income_water", 0.0), e.get("income_feedin", 0.0),
		costs, e.get("cost_fuel", 0.0), e.get("cost_upkeep", 0.0),
		e.get("cost_grid", 0.0), e.get("cost_interest", 0.0),
		income + costs, City.loans]


func _make_budget_section(box: VBoxContainer) -> void:
	_budget_label = Label.new()
	_budget_label.add_theme_font_size_override("font_size", 11)
	box.add_child(_budget_label)
	var row := HBoxContainer.new()
	box.add_child(row)
	var take := Button.new()
	take.text = "Take €100k loan"
	take.focus_mode = Control.FOCUS_NONE
	take.pressed.connect(func() -> void:
		City.take_loan(100_000.0)
		_refresh_breakdown())
	row.add_child(take)
	var repay := Button.new()
	repay.text = "Repay €100k"
	repay.focus_mode = Control.FOCUS_NONE
	repay.pressed.connect(func() -> void:
		City.repay_loan(100_000.0)
		_refresh_breakdown())
	row.add_child(repay)


# ─── element inspector: click infrastructure with no tool active and its
# daily profile graph appears (rtpowerflow ProfileGraph conventions) ───

var _inspector: PanelContainer
var _inspector_title: Label
var _inspector_graph: ProfileGraph
var _inspector_live: Label


## Per-kind graph configuration: which telemetry series, unit, axis title,
## and dashed limit lines (the rtpowerflow quantities per element type).
func _inspector_config(kind: String, id: String) -> Dictionary:
	var kw_series: Array[Dictionary] = [
		{"key": "dev:" + id, "label": "P", "color": Color(0.95, 0.68, 0.21)}]
	match kind:
		"grid_connection":
			var capacity: float = City.grid_capacity_override \
				if City.grid_capacity_override > 0.0 \
				else BuildingDefs.get_def(kind)["capacity_kw"]
			var limits: Array[Dictionary] = []
			if capacity <= 1_000.0:  # a 10-MVA line would flatten the curve
				limits = [{"value": capacity, "label": "%.0f kW cap" % capacity,
					"color": Color(0.95, 0.3, 0.25)}]
			return {"title": "Grid connection 110/20 kV", "unit": "kW", "dec": 0,
				"base_zero": false, "y": "Import / export [kW]", "limits": limits,
				"series": [{"key": "dev:" + id, "label": "Import",
					"color": Color(0.95, 0.45, 0.3)}]}
		"substation":
			return {"title": "Substation 20/0.4 kV (%.0f kVA)"
					% float(City.model.building_params(id).get("rating_kva", 100.0)),
				"unit": "%", "dec": 0, "base_zero": true, "y": "Trafo loading [%]",
				"limits": [{"value": 100.0, "label": "rating",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": "trafo:" + id, "label": "Loading",
					"color": Color(0.31, 0.76, 0.97)}]}
		"gas_plant", "wind_farm", "solar_park":
			return {"title": kind.capitalize(), "unit": "kW", "dec": 0,
				"base_zero": true, "y": "P [kW]", "limits": [], "series": kw_series}
		"chp_plant", "boiler_plant", "heat_pump_plant":
			return {"title": kind.capitalize(), "unit": "kW", "dec": 0,
				"base_zero": true, "y": "Q [kW]", "limits": [],
				"series": [{"key": "dev:" + id, "label": "Q",
					"color": Color(0.9, 0.35, 0.25)}]}
		"battery", "heat_storage", "water_tower":
			return {"title": kind.capitalize(), "unit": "%", "dec": 0,
				"base_zero": true, "y": "State of charge [%]", "limits": [],
				"series": [{"key": "soc:" + id, "label": "SoC",
					"color": Color(0.62, 0.44, 0.86)}]}
		"heat_exchanger":
			return {"title": "Heat exchanger", "unit": "°C", "dec": 1,
				"base_zero": false, "y": "Supply temperature [°C]",
				"limits": [{"value": 60.0, "label": "min 60 °C",
					"color": Color(0.35, 0.55, 0.95)}],
				"series": [{"key": "t:hz_" + id, "label": "T supply",
					"color": Color(0.95, 0.55, 0.2)}]}
		"water_station":
			return {"title": "Water station", "unit": "bar", "dec": 2,
				"base_zero": false, "y": "Zone pressure [bar]",
				"limits": [{"value": 2.0, "label": "min 2.0 bar",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": "pb:wz_" + id, "label": "p",
					"color": Color(0.25, 0.75, 0.5)}]}
		"well", "pumping_station":
			return {"title": kind.capitalize(), "unit": "m³/h", "dec": 1,
				"base_zero": true, "y": "Flow [m³/h]", "limits": [],
				"series": [{"key": "q:" + id, "label": "Q",
					"color": Color(0.25, 0.75, 0.5)}]}
	return {}


## Line/pipe clicks: power lines carry real per-segment loading (contract
## 1.1 edges); heat/water pipes have no per-pipe wire data, so they open
## the network-total graph — honest about what the solver reports.
func _open_tile_inspector(category: String, pos: Vector2i) -> void:
	match category:
		"cable":
			var edge := City.topo.line_id_at(pos)
			if edge == "":
				return  # stub or tripped: nothing solved here
			var buried: bool = int(City.model.cables.get(pos, 1)) \
				== BuildingDefs.LINE_UNDERGROUND
			_show_config({
				"title": ("Underground cable" if buried else "Overhead line"),
				"unit": "%", "dec": 0, "base_zero": true, "y": "Loading [%]",
				"limits": [{"value": 100.0, "label": "rating",
					"color": Color(0.95, 0.3, 0.25)}],
				"series": [{"key": City.topo.line_key(edge), "label": "Loading",
					"color": Color(0.31, 0.76, 0.97)}]}, edge)
		"heat_pipe":
			_show_config({"title": "District heating network", "unit": "kW",
				"dec": 0, "base_zero": true, "y": "Total heat load [kW]",
				"limits": [],
				"series": [{"key": "net:heat", "label": "Heat load",
					"color": Color(0.9, 0.35, 0.25)}]}, "all zones")
		"water_pipe":
			_show_config({"title": "Water network", "unit": "m³/h", "dec": 2,
				"base_zero": true, "y": "Total demand [m³/h]", "limits": [],
				"series": [{"key": "net:water", "label": "Demand",
					"color": Color(0.25, 0.75, 0.5)}]}, "all zones")


func _open_inspector(id: String) -> void:
	if not City.model.buildings.has(id):
		return
	var kind: String = City.model.buildings[id]["kind"]
	var config := _inspector_config(kind, id)
	if config.is_empty():
		return
	_show_config(config, id)


func _show_config(config: Dictionary, subtitle: String) -> void:
	if _inspector == null:
		_inspector = PanelContainer.new()
		_inspector.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_inspector.offset_top = 320.0
		_inspector.offset_left = -430.0
		var style := StyleBoxFlat.new()  # opaque: the event feed sits above
		style.bg_color = Color(0.08, 0.1, 0.13, 0.97)
		style.set_corner_radius_all(6)
		style.set_content_margin_all(8)
		_inspector.add_theme_stylebox_override("panel", style)
		add_child(_inspector)
		var box := VBoxContainer.new()
		_inspector.add_child(box)
		var header := HBoxContainer.new()
		box.add_child(header)
		_inspector_title = Label.new()
		_inspector_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(_inspector_title)
		var close := Button.new()
		close.text = "✕"
		close.focus_mode = Control.FOCUS_NONE
		close.pressed.connect(func() -> void: _inspector.visible = false)
		header.add_child(close)
		_inspector_graph = ProfileGraph.new()
		box.add_child(_inspector_graph)
		_inspector_live = Label.new()
		_inspector_live.add_theme_font_size_override("font_size", 11)
		_inspector_live.modulate = Color(1, 1, 1, 0.7)
		box.add_child(_inspector_live)
		for network_signal: Signal in [City.power_result, City.heat_result,
				City.water_result]:
			network_signal.connect(func(_t: int, _r: Dictionary) -> void:
				if _inspector.visible:
					_inspector_graph.queue_redraw())
	_inspector_title.text = "%s   (%s)" % [config["title"], subtitle]
	_inspector_live.text = "Today opaque · yesterday faded · dashed = limit"
	var series_typed: Array[Dictionary] = []
	series_typed.assign(config["series"])
	var limits_typed: Array[Dictionary] = []
	limits_typed.assign(config["limits"])
	_inspector_graph.setup(series_typed, config["unit"], config["dec"],
		limits_typed, config["base_zero"], config["y"])
	_inspector.visible = true


# ─── save / load (envelope v3): four slots with day/time/house labels ───

const SLOTS := [
	["Quick", "user://save.json"],
	["Slot 1", "user://save_slot_1.json"],
	["Slot 2", "user://save_slot_2.json"],
	["Slot 3", "user://save_slot_3.json"],
]


## One line describing a slot's content, "" when empty/unreadable.
func _slot_summary(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not (parsed is Dictionary):
		return ""
	var envelope: Dictionary = parsed
	var minutes := float(envelope.get("clock", {}).get("total_minutes", 0.0))
	var houses: int = envelope.get("model", {}).get("houses", {}).size()
	var scenario: String = envelope.get("city", {}) \
		.get("scenario_state", {}).get("id", "sandbox")
	var stamp := Time.get_datetime_dict_from_unix_time(
		int(envelope.get("saved_at_unix", 0)))
	return "%s · Day %d %02d:%02d · %d houses · saved %02d.%02d. %02d:%02d" % [
		scenario, int(minutes / 1440.0), int(minutes / 60.0) % 24,
		int(minutes) % 60, houses,
		stamp["day"], stamp["month"], stamp["hour"], stamp["minute"]]


func _load_slot(path: String) -> void:
	var result := SaveGame.load_from(path)
	if not result["ok"]:
		City.log_event("load_failed", "warning", str(result.get("error", "?")))
		return
	view.redraw()
	_restore_objective()
	City.log_event("loaded", "info", "Game loaded")


func _save_slot(path: String) -> void:
	if SaveGame.save_to(path) == OK:
		City.log_event("saved", "info", "Game saved")


## After a load: put the scenario goal back on screen (tutorial saves
## resume as free play — step progress isn't persisted).
func _restore_objective() -> void:
	var id: String = City.scenario_state.get("id", "")
	if id in ["", "sandbox", "tutorial"] or City.scenario_state.get("done", false):
		show_objective("")
		return
	for scenario: Dictionary in Scenarios.catalog():
		if scenario["id"] == id:
			show_objective("GOAL: " + scenario["desc"])


## The slot dialog, shared by Save and Load.
func show_slot_dialog(mode: String) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.1, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(430, 0)
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Save game" if mode == "save" else "Load game"
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)
	var close_dialog := func() -> void:
		dim.queue_free()
		panel.queue_free()
	for slot: Array in SLOTS:
		var summary := _slot_summary(slot[1])
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_NONE
		button.text = "%s — %s" % [slot[0], summary if summary != "" else "empty"]
		if mode == "load" and summary == "":
			button.disabled = true
		var path: String = slot[1]
		button.pressed.connect(func() -> void:
			if mode == "save":
				_save_slot(path)
			else:
				_load_slot(path)
			close_dialog.call())
		box.add_child(button)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(close_dialog)
	box.add_child(cancel)


# ─── scenario UI (Phase 7): objective line, win/lose banner, picker ───

var _objective: Label
var _banner: Label


func show_objective(text: String) -> void:
	if _objective == null:
		_objective = Label.new()
		_objective.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_objective.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_objective.offset_top = 48.0
		_objective.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
		_objective.add_theme_font_size_override("font_size", 15)
		add_child(_objective)
	_objective.text = text
	_objective.visible = text != ""


func show_banner(text: String, color: Color) -> void:
	if _banner == null:
		_banner = Label.new()
		_banner.set_anchors_preset(Control.PRESET_CENTER)
		_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
		_banner.add_theme_font_size_override("font_size", 42)
		_banner.add_theme_constant_override("outline_size", 8)
		add_child(_banner)
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	_banner.visible = true


## Scenario + difficulty picker shown at boot; calls back with (id, diff).
func show_scenario_picker(on_pick: Callable) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.06, 0.1, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.text = "infrastruct — choose a scenario"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	var diff_row := HBoxContainer.new()
	box.add_child(diff_row)
	diff_row.add_child(Label.new())
	(diff_row.get_child(0) as Label).text = "Difficulty: "
	var diff_group := ButtonGroup.new()
	var picked := {"diff": "normal"}
	for key: String in ["easy", "normal", "hard"]:
		var toggle := Button.new()
		toggle.text = key
		toggle.toggle_mode = true
		toggle.button_group = diff_group
		toggle.focus_mode = Control.FOCUS_NONE
		toggle.set_pressed_no_signal(key == "normal")
		toggle.pressed.connect(func() -> void: picked["diff"] = key)
		diff_row.add_child(toggle)
	for scenario: Dictionary in Scenarios.catalog():
		var button := Button.new()
		button.text = scenario["name"]
		button.tooltip_text = scenario["desc"]
		button.focus_mode = Control.FOCUS_NONE
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void:
			dim.queue_free()
			panel.queue_free()
			on_pick.call(scenario["id"], picked["diff"]))
		box.add_child(button)
		var desc := Label.new()
		desc.text = scenario["desc"]
		desc.add_theme_font_size_override("font_size", 11)
		desc.modulate = Color(1, 1, 1, 0.65)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(desc)
	# resume a saved game instead
	var any_save := false
	for slot: Array in SLOTS:
		if _slot_summary(slot[1]) != "":
			any_save = true
			break
	if any_save:
		var loads := Label.new()
		loads.text = "— or load a saved game —"
		loads.add_theme_font_size_override("font_size", 11)
		loads.modulate = Color(1, 1, 1, 0.65)
		box.add_child(loads)
		for slot: Array in SLOTS:
			var summary := _slot_summary(slot[1])
			if summary == "":
				continue
			var load_button := Button.new()
			load_button.text = "%s — %s" % [slot[0], summary]
			load_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			load_button.focus_mode = Control.FOCUS_NONE
			var path: String = slot[1]
			load_button.pressed.connect(func() -> void:
				dim.queue_free()
				panel.queue_free()
				_load_slot(path)
				if GameClock.speed == 0.0:
					GameClock.speed = 8.0)
			box.add_child(load_button)


# ─── palette thumbnails: each tool's real 3D visual, rendered once into a
# button icon via an offscreen viewport (stays true to the map look) ───

func _render_thumbnails() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(96, 96)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.2
	vp.add_child(sun)
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.9
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	for tool: CityView.Tool in _tool_buttons:
		var sample := _thumbnail_scene(tool)
		if sample == null:
			continue  # no model — the monogram tile stays
		sample.position = Vector3.ZERO
		vp.add_child(sample)
		var bounds: AABB = view._aabb_of(sample)
		var center := bounds.position + bounds.size / 2.0
		cam.size = maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z)) * 1.2
		cam.position = center + Vector3(-1, 0.85, -1).normalized() * 10.0
		cam.look_at(center, Vector3.UP)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var texture := ImageTexture.create_from_image(vp.get_texture().get_image())
		vp.remove_child(sample)
		sample.queue_free()
		if not is_instance_valid(_tool_buttons[tool]):
			continue
		var button: Button = _tool_buttons[tool]
		button.text = ""
		button.icon = texture
		button.expand_icon = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vp.queue_free()


## The sample rendered for a tool's thumbnail — building visuals verbatim,
## hand-built minis for the line tools.
func _thumbnail_scene(tool: CityView.Tool) -> Node3D:
	var item: Dictionary = _items_by_tool.get(tool, {})
	if item.has("kind"):
		return view._build_building_visual(item["kind"])
	match tool:
		CityView.Tool.ROAD:
			return view._instance_glb(
				"city-kit-roads/Models/GLB format/road-straight.glb", 1.0)
		CityView.Tool.ZONE:
			var lot := Node3D.new()
			var pad := MeshInstance3D.new()
			var pad_mesh := PlaneMesh.new()
			pad_mesh.size = Vector2(1.1, 1.1)
			pad.mesh = pad_mesh
			pad.material_override = view._flat(Color(0.45, 0.8, 0.4))
			lot.add_child(pad)
			var house := view._instance_glb(
				"city-kit-suburban/Models/GLB format/building-type-a.glb", 0.8)
			lot.add_child(house)
			return lot
		CityView.Tool.CABLE:
			return view._pole_visual()
		CityView.Tool.UCABLE:
			return _trench_sample([Color(0.85, 0.75, 0.35)])
		CityView.Tool.BURIED_PIPE:
			return _trench_sample([CityView.PIPE_SUPPLY_COLOR, CityView.PIPE_RETURN_COLOR])
		CityView.Tool.BURIED_WATER:
			return _trench_sample([CityView.WATER_PIPE_COLOR])
		CityView.Tool.PIPE:
			return _pipe_sample([[CityView.PIPE_SUPPLY_COLOR, 0.13],
				[CityView.PIPE_RETURN_COLOR, -0.13]], 0.055)
		CityView.Tool.WATER_PIPE:
			return _pipe_sample([[CityView.WATER_PIPE_COLOR, 0.0]], 0.07)
		CityView.Tool.BULLDOZE:
			return view._instance_glb(
				"factory-kit/Models/GLB format/crane-magnet.glb", 1.0)
		CityView.Tool.REPAIR:
			return view._instance_glb(
				"factory-kit/Models/GLB format/cone.glb", 0.8)
	return null


## Trench with network-colored marker posts — the buried-line thumbnails.
func _trench_sample(markers: Array) -> Node3D:
	var trench := Node3D.new()
	var strip := MeshInstance3D.new()
	var strip_mesh := BoxMesh.new()
	strip_mesh.size = Vector3(0.9, 0.05, 0.2)
	strip.mesh = strip_mesh
	strip.material_override = view._flat(Color(0.36, 0.33, 0.29))
	trench.add_child(strip)
	for i in markers.size():
		var marker := MeshInstance3D.new()
		var marker_mesh := BoxMesh.new()
		marker_mesh.size = Vector3(0.08, 0.3, 0.08)
		marker.mesh = marker_mesh
		marker.position = Vector3(0.2 - 0.18 * i, 0.15, 0.15)
		marker.material_override = view._flat(markers[i])
		trench.add_child(marker)
	return trench


func _pipe_sample(runs: Array, radius: float) -> Node3D:
	var node := Node3D.new()
	var foot := MeshInstance3D.new()
	var foot_mesh := BoxMesh.new()
	foot_mesh.size = Vector3(0.14, 0.11, 0.14)
	foot.mesh = foot_mesh
	foot.position = Vector3(0, 0.055, 0)
	foot.material_override = view._flat(Color(0.45, 0.46, 0.5))
	node.add_child(foot)
	for run: Array in runs:
		var seg := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = 0.9
		seg.mesh = cyl
		seg.rotation_degrees.z = 90.0
		seg.position = Vector3(0, 0.16, run[1])
		seg.material_override = view._flat(run[0])
		node.add_child(seg)
	return node


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
		("∞" if City.infinite_money else _fmt_money(City.money)),
		City.happiness, houses, demand,
		City.total_outage_minutes(), City.total_heat_outage_minutes(),
		City.total_water_outage_minutes(),
		("  ·  ⟳ rebuilding grid…" if City.is_syncing() else "")]
	_refresh_breakdown()


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
	if key.keycode == KEY_ESCAPE:
		_select_tool(CityView.Tool.NONE)  # back to inspect mode
	elif TOOL_KEYS.has(key.keycode):
		_select_tool(TOOL_KEYS[key.keycode])
	elif key.keycode == KEY_TAB:
		_build_menu.visible = not _build_menu.visible
	elif key.keycode == KEY_I:
		_breakdown.visible = not _breakdown.visible
		_refresh_breakdown()
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
