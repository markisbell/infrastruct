class_name Hud
extends CanvasLayer
## HUD: status bar, build menu (TAB — categorized tile palette with hover
## tooltips), tool hotkeys, event toasts, speed controls.

## Mnemonic letter aliases, matched on `keycode` — the LABEL printed on the
## key, which is what a mnemonic means (on QWERTZ the key marked Z reports
## KEY_Z; matching physically would give KEY_Y). The digit row moved to the
## hotbar, which matches PHYSICALLY instead — see Hotbar._PHYSICAL_SLOTS for
## why the two rules differ.
const TOOL_KEYS := {
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
	KEY_X: CityView.Tool.ZONE_COMMERCIAL,
	KEY_D: CityView.Tool.CHARGING,
	KEY_Z: CityView.Tool.SUBSTATION_XL,
}

var view: CityView
var _status: Label
var _tool_label: Label
var _events_box: VBoxContainer
var _build_menu: PanelContainer
var _tool_buttons := {}          # CityView.Tool -> Button
var _button_group := ButtonGroup.new()
var _items_by_tool := {}         # CityView.Tool -> item Dictionary


## Palette data: stable id + monogram + hotkey + gameplay description per
## tool. Costs and swatch colors come from BuildingDefs for buildings; line
## tools carry their own. Categories per user direction: city basics, one
## infrastructure block per network, demolish on its own.
##
## `id` is the PERSISTENCE key (hotbar loadouts in user://settings.cfg) and
## must never be renamed once shipped — a changed id silently empties the
## slot a player learned. `key` is the mnemonic letter alias, "" for tools
## that only ever had a digit (those live on the hotbar now).
func _build_items() -> Array:
	return [
		{"cat": "City", "items": [
			{"tool": CityView.Tool.ROAD, "id": "road", "label": "Road", "mono": "Rd", "key": "",
				"color": Color(0.45, 0.45, 0.5), "cost": BuildingDefs.COSTS["road"],
				"desc": "Drag to pave. Houses only grow on zoned tiles next to a road."},
			{"tool": CityView.Tool.ZONE, "id": "zone", "label": "Residential zone", "mono": "Zn", "key": "",
				"color": Color(0.45, 0.8, 0.4), "cost": BuildingDefs.COSTS["zone"],
				"desc": "Paint building land. Houses appear when a powered substation covers it and people are happy."},
			{"tool": CityView.Tool.ZONE_COMMERCIAL, "id": "zone_commercial", "label": "Commercial zone", "mono": "Cz", "key": "X",
				"color": Color(0.45, 0.55, 0.9), "cost": BuildingDefs.COSTS["zone_commercial"],
				"desc": "Paint industrial land. Factories, food plants and malls move in on their own - but only where the substation has the headroom to carry them."},
			{"tool": CityView.Tool.BRIDGE, "id": "bridge", "label": "Bridge", "mono": "Br", "key": "V",
				"color": Color(0.62, 0.58, 0.52), "cost": BuildingDefs.COSTS["bridge"],
				"desc": "Deck a river tile so a crossing can be built. Drag bank to bank, then run roads, cables and pipes over it like any other ground."},
		]},
		{"cat": "Electricity", "items": [
			{"tool": CityView.Tool.CABLE, "id": "cable_overhead", "label": "Overhead line", "mono": "Oh", "key": "",
				"color": Color(0.45, 0.36, 0.28), "cost": BuildingDefs.COSTS["overhead_line"],
				"desc": "20 kV pole-and-wire line (~7 MVA). Cheap and visible; sustained overload trips it."},
			{"tool": CityView.Tool.UCABLE, "id": "cable_buried", "label": "Underground cable", "mono": "Ug", "key": "G",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["cable"],
				"desc": "Buried 20 kV NA2XS2Y cable (~8.7 MVA). Pricier, out of sight — joins overhead runs freely."},
			{"tool": CityView.Tool.SUBSTATION, "id": "substation", "label": "Substation", "mono": "Su", "key": "",
				"kind": "substation",
				"desc": "20/0.4 kV district transformer (630 kVA), supply zone radius 12. Houses inside draw electricity here."},
			{"tool": CityView.Tool.GRID, "id": "grid_connection", "label": "Grid connection", "mono": "Gr", "key": "",
				"kind": "grid_connection",
				"desc": "The 110/20 kV interface to the transmission grid — 20 MVA. Your city's lifeline and wholesale meter."},
			{"tool": CityView.Tool.GAS, "id": "gas_plant", "label": "Gas plant", "mono": "Ga", "key": "",
				"kind": "gas_plant",
				"desc": "2 MW dispatchable generation — runs when wind and sun don't."},
			{"tool": CityView.Tool.WIND, "id": "wind_farm", "label": "Wind turbine", "mono": "Wi", "key": "",
				"kind": "wind_farm",
				"desc": "9 MW rated (3 × 3 MW turbines). Output follows the weather — calm spells produce nothing."},
			{"tool": CityView.Tool.SOLAR, "id": "solar_park", "label": "Solar park", "mono": "So", "key": "",
				"kind": "solar_park",
				"desc": "1.2 MWp (300 kW per tile), real measured sun profiles. FACING matters: R rotates — south (default) maximizes, east/west spread the day ±1.5 h, north starves. Watch the compass."},
			{"tool": CityView.Tool.BATTERY, "id": "battery", "label": "Battery", "mono": "Ba", "key": "",
				"kind": "battery",
				"desc": "1 MWh / 400 kW. Peak shaving: discharges load spikes, recharges in the valleys."},
			{"tool": CityView.Tool.SUBSTATION_XL, "id": "substation_xl", "label": "Substation 1 MVA", "mono": "S+", "key": "Z",
				"kind": "substation_xl",
				"desc": "The industrial Ortsnetzstation: a 1000-kVA transformer with the headroom commercial customers need. Same coverage as the 630."},
			{"tool": CityView.Tool.CHARGING, "id": "charging_park", "label": "Charging park", "mono": "Cp", "key": "D",
				"kind": "charging_park",
				"desc": "Eight 175-kW DC fast chargers behind one MV connection. Spiky megawatt-class load - and it bills every delivered kWh."},
		]},
		{"cat": "Heat", "items": [
			{"tool": CityView.Tool.PIPE, "id": "heat_pipe", "label": "Heat pipe", "mono": "Hp", "key": "H",
				"color": CityView.PIPE_SUPPLY_COLOR, "cost": BuildingDefs.COSTS["heat_pipe"],
				"desc": "District-heating pair: red forward, blue return. Long runs lose temperature."},
			{"tool": CityView.Tool.BURIED_PIPE, "id": "heat_pipe_buried", "label": "Buried heat pipe", "mono": "Bh", "key": "K",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["heat_pipe_buried"],
				"desc": "Same pair, trenched: crosses under roads and shares the street with other buried lines."},
			{"tool": CityView.Tool.HEAT_SUB, "id": "heat_exchanger", "label": "Heat exchanger", "mono": "Hx", "key": "J",
				"kind": "heat_exchanger",
				"desc": "Defines a heat zone (radius 12). Homes inside get district heat."},
			{"tool": CityView.Tool.BOILER, "id": "boiler_plant", "label": "Boiler plant", "mono": "Bo", "key": "B",
				"kind": "boiler_plant",
				"desc": "Cheap heat, but low flow temperature (66°C) — far ends go cold in deep winter."},
			{"tool": CityView.Tool.CHP, "id": "chp_plant", "label": "CHP plant", "mono": "CH", "key": "C",
				"kind": "chp_plant",
				"desc": "Heat AND electricity (85°C). Cable it up: its power feeds your grid."},
			{"tool": CityView.Tool.HEATPUMP, "id": "heat_pump_plant", "label": "Heat pump plant", "mono": "HP", "key": "U",
				"kind": "heat_pump_plant",
				"desc": "Heat from electricity (70°C). Draws serious grid power in cold snaps."},
			{"tool": CityView.Tool.HEATSTORE, "id": "heat_storage", "label": "Heat storage", "mono": "St", "key": "T",
				"kind": "heat_storage",
				"desc": "500 kWh buffer tank: charges at night, carries the morning peak."},
		]},
		{"cat": "Water", "items": [
			{"tool": CityView.Tool.WATER_PIPE, "id": "water_pipe", "label": "Water pipe", "mono": "Wp", "key": "W",
				"color": CityView.WATER_PIPE_COLOR, "cost": BuildingDefs.COSTS["water_pipe"],
				"desc": "Drinking-water main (green). Pressure falls with distance and elevation."},
			{"tool": CityView.Tool.BURIED_WATER, "id": "water_pipe_buried", "label": "Buried water pipe", "mono": "Bw", "key": "L",
				"color": Color(0.36, 0.33, 0.29), "cost": BuildingDefs.COSTS["water_pipe_buried"],
				"desc": "Same main, trenched: crosses under roads and shares the street with other buried lines."},
			{"tool": CityView.Tool.WATER_SUB, "id": "water_station", "label": "Water station", "mono": "Ws", "key": "A",
				"kind": "water_station",
				"desc": "Defines a water zone (radius 12). Homes inside tap this network."},
			{"tool": CityView.Tool.WELL, "id": "well", "label": "Well", "mono": "We", "key": "N",
				"kind": "well",
				"desc": "Gravity well field, no power needed — droughts shrink its yield. Near a river: +50% yield (richer aquifer)."},
			{"tool": CityView.Tool.PUMP, "id": "pumping_station", "label": "Pumping station", "mono": "Pu", "key": "P",
				"kind": "pumping_station",
				"desc": "High yield and pressure, needs a cable: a blackout here stops the water. Bridge two pipe ends with it to BOOST pressure inline along the run."},
			{"tool": CityView.Tool.WATER_TOWER, "id": "water_tower", "label": "Water tower", "mono": "Tw", "key": "O",
				"kind": "water_tower",
				"desc": "Pressure head + 200 m³ buffer. Rides through pump outages; taller = more bar."},
		]},
		{"cat": "Service", "items": [
			{"tool": CityView.Tool.NONE, "id": "inspect", "label": "Inspect", "mono": "?", "key": "Esc",
				"color": Color(0.31, 0.76, 0.97), "cost": 0,
				"desc": "No tool: click any building or line/pipe to open its daily graph. Esc always returns here."},
			{"tool": CityView.Tool.REPAIR, "id": "repair", "label": "Repair crew", "mono": "Rp", "key": "M",
				"color": Color(1.0, 0.75, 0.2), "cost": City.CREW_COST,
				"desc": "Send a crew to a TRIPPED line or transformer (~2 h work). Overload trips don't fix themselves."},
			{"tool": CityView.Tool.BULLDOZE, "id": "bulldoze", "label": "Bulldozer", "mono": "X", "key": "",
				"color": Color(0.8, 0.25, 0.2), "cost": 0,
				"desc": "Remove anything (buildings refund 25%). On empty land it clears trees, stones and brush."},
		]},
	]


func _ready() -> void:
	var compass := CompassRose.new()
	compass.view = view
	compass.position = Vector2(12.0, 196.0)
	compass.size = Vector2(96.0, 96.0)
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(compass)
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	top.add_child(row)
	_status = Label.new()
	row.add_child(_status)
	_tool_label = Label.new()
	_tool_label.text = "Tool: none — 1-0 hotbar · TAB catalogue · S picks up a tool · I breakdown · Q/E turn · R/F ghost · SPACE pause · V overlays"
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
	_make_hotbar()  # after the menu: slots mirror its tiles' icons
	_render_thumbnails()  # async: icons replace the monograms as they render
	_make_breakdown()
	view.building_clicked.connect(_open_inspector)
	view.tile_infra_clicked.connect(_open_tile_inspector)
	view.empty_clicked.connect(_close_inspector)
	view.pipette_requested.connect(_pipette)

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

## Tabbed palette (user request 2026-08-06 — 28 tiles outgrew the single
## all-categories row): a slim tab row on top, ONE tile row below showing
## the active category. Hotkeys stay global and auto-switch the tab so
## the pressed highlight is never hidden.
var _tab_buttons := {}   # cat name -> Button
var _tab_rows := {}      # cat name -> HBoxContainer
var _tool_category := {} # CityView.Tool -> cat name
var _tab_group := ButtonGroup.new()


func _make_build_menu() -> void:
	_build_menu = PanelContainer.new()
	_build_menu.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_build_menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_build_menu.grow_vertical = Control.GROW_DIRECTION_BEGIN
	# clears the hotbar AND the flash line that sits between the two
	_build_menu.offset_bottom = -96.0
	add_child(_build_menu)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	_build_menu.add_child(stack)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 2)
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(tab_row)
	for category: Dictionary in _build_items():
		var cat: String = category["cat"]
		# rows live directly in the VBox: hidden children are excluded
		# from container layout, so the panel auto-sizes to tabs + the
		# ACTIVE row (an overlapping plain Control collapsed the panel —
		# anchored children carry no minimum size)
		var tile_row := HBoxContainer.new()
		tile_row.add_theme_constant_override("separation", 4)
		tile_row.alignment = BoxContainer.ALIGNMENT_CENTER
		tile_row.visible = false
		for item: Dictionary in category["items"]:
			tile_row.add_child(_make_tile(item))
			_tool_category[item["tool"]] = cat
		stack.add_child(tile_row)
		_tab_rows[cat] = tile_row
		var tab := Button.new()
		tab.text = cat
		tab.toggle_mode = true
		tab.button_group = _tab_group
		tab.focus_mode = Control.FOCUS_NONE
		tab.add_theme_font_size_override("font_size", 12)
		tab.pressed.connect(func() -> void: _show_category(cat))
		tab_row.add_child(tab)
		_tab_buttons[cat] = tab
	# the binding gesture is only discoverable where it applies — a hint in
	# the status bar would be read once and never again
	var hint := Label.new()
	hint.text = "hover a tool + press 1-0 to pin it to that hotbar slot · middle-click a slot to clear"
	hint.add_theme_font_size_override("font_size", 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.6)
	stack.add_child(hint)
	# screenshot-mode probe (the REGION_SHOT pattern): PALETTE_TAB=<cat>
	# opens that tab so its tiles can be verified visually
	var probe := OS.get_environment("PALETTE_TAB")
	_show_category(probe if _tab_rows.has(probe)
		else str((_build_items()[0] as Dictionary)["cat"]))
	# the catalogue STAYS on screen by default: every tool the hotbar does
	# not hold has to remain visible, or the ones that moved off the digit
	# row read as deleted. TAB still folds it away when the map matters
	# more than the menu.


func _show_category(cat: String) -> void:
	for name: String in _tab_rows:
		(_tab_rows[name] as HBoxContainer).visible = name == cat
	if _tab_buttons.has(cat):
		(_tab_buttons[cat] as Button).set_pressed_no_signal(true)
	# NO manual size fiddling: Control.size keeps the TOP-LEFT fixed and
	# extends DOWNWARD (clipped the tile row off-screen once) — the
	# bottom-center anchor preset + grow directions re-fit the panel
	# around the active row on their own


func _make_tile(item: Dictionary) -> Button:
	var color: Color = item.get("color", Color.GRAY)
	var cost: int = item.get("cost", 0)
	if item.has("kind"):
		var def := BuildingDefs.get_def(item["kind"])
		color = def["color"]
		cost = def["cost"]
	_items_by_tool[item["tool"]] = item
	_items_by_id[item["id"]] = item
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
	# hovering a tile with the catalogue open makes the digit keys PIN
	# instead of select — Minecraft's creative-inventory binding gesture,
	# the cheapest possible way to build a loadout
	button.mouse_entered.connect(func() -> void: _hovered_id = str(item["id"]))
	button.mouse_exited.connect(func() -> void:
		if _hovered_id == str(item["id"]):
			_hovered_id = "")
	_tool_buttons[item["tool"]] = button
	return button


# ─── hotbar: ten stable slots on 1-0, the always-visible bottom row ───
#
# The tabbed catalogue above it still holds everything; what changed is
# that the tools you actually use sit in ONE place that never re-arranges
# itself. Rules live in Hotbar (pure + persisted); this is the row.

var _hotbar: PanelContainer
var _hotbar_slots: Array[String] = []
var _hotbar_buttons: Array[Button] = []
var _slot_group := ButtonGroup.new()
var _items_by_id := {}    # stable id -> item Dictionary
var _hovered_id := ""     # catalogue tile under the mouse, "" when none
var _flash: Label         # armed-tool confirmation, fades on its own
var _flash_fade: Tween


func _make_hotbar() -> void:
	_hotbar_slots = Hotbar.load_slots(_items_by_id)
	_hotbar = PanelContainer.new()
	_hotbar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hotbar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hotbar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hotbar.offset_bottom = -6.0  # hug the screen edge: Fitts pays there
	add_child(_hotbar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_hotbar.add_child(row)
	for i in Hotbar.SLOT_COUNT:
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(52, 52)
		slot.toggle_mode = true
		slot.button_group = _slot_group
		slot.focus_mode = Control.FOCUS_NONE
		slot.expand_icon = true
		slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot.add_theme_color_override("font_color", Color.WHITE)
		slot.add_theme_color_override("font_pressed_color", Color.WHITE)
		slot.add_theme_color_override("font_hover_color", Color.WHITE)
		var index := i
		slot.pressed.connect(func() -> void: _select_slot(index))
		# middle-click clears a slot — the near-universal gesture for this
		# (Factorio, and every mod that adds slots to a game lacking them)
		slot.gui_input.connect(func(event: InputEvent) -> void:
			var mb := event as InputEventMouseButton
			if mb != null and mb.pressed \
					and mb.button_index == MOUSE_BUTTON_MIDDLE:
				_pin_to_slot(index, ""))
		var digit := Label.new()
		digit.text = Hotbar.SLOT_LABELS[i]
		digit.add_theme_font_size_override("font_size", 10)
		digit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		digit.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		digit.grow_vertical = Control.GROW_DIRECTION_BEGIN
		digit.offset_right = -4.0
		digit.offset_bottom = -2.0
		digit.modulate = Color(1, 1, 1, 0.75)
		digit.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(digit)
		row.add_child(slot)
		_hotbar_buttons.append(slot)
	_refresh_hotbar()


## Slot styling carries three states: assigned, empty, and unaffordable.
## Unaffordable stays SELECTABLE and keeps its place — a tool that vanishes
## when money dips would move every neighbour, which is the one thing a
## hotbar must never do. It dims and says why in the tooltip instead.
func _refresh_hotbar() -> void:
	for i in _hotbar_buttons.size():
		var slot: Button = _hotbar_buttons[i]
		var id: String = _hotbar_slots[i] if i < _hotbar_slots.size() else ""
		var item: Dictionary = _items_by_id.get(id, {})
		if item.is_empty():
			slot.icon = null
			slot.text = ""
			slot.tooltip_text = "Empty slot %s — hover a tool in the build menu (TAB) and press %s" % [
				Hotbar.SLOT_LABELS[i], Hotbar.SLOT_LABELS[i]]
			slot.add_theme_stylebox_override("normal", _slot_style(
				Color(0.11, 0.12, 0.15), Color(0.25, 0.27, 0.32)))
			continue
		var source: Button = _tool_buttons.get(item["tool"], null)
		if source != null:  # icon or monogram, whichever the palette has
			slot.icon = source.icon
			slot.text = "" if source.icon != null else str(item["mono"])
		var cost := _item_cost(item)
		var affordable := City.infinite_money or City.money >= cost
		slot.tooltip_text = "%s — %s%s\nmiddle-click to clear" % [
			item["label"], ("€%s" % _fmt_money(cost)) if cost > 0 else "free",
			"" if affordable else "  (not affordable)"]
		slot.modulate = Color.WHITE if affordable else Color(1, 0.72, 0.66, 0.55)
		slot.add_theme_stylebox_override("normal", _slot_style(
			Color(0.16, 0.18, 0.22), _item_color(item)))


func _slot_style(bg: Color, accent: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(6)
	style.set_content_margin_all(3)
	style.border_color = accent
	style.border_width_bottom = 3
	return style


static func _item_cost(item: Dictionary) -> int:
	if item.has("kind"):
		var def := BuildingDefs.get_def(item["kind"])
		return int(def.get("cost", 0))
	return int(item.get("cost", 0))


static func _item_color(item: Dictionary) -> Color:
	if item.has("kind"):
		var def := BuildingDefs.get_def(item["kind"])
		var kind_color: Color = def.get("color", Color.GRAY)
		return kind_color
	var own_color: Color = item.get("color", Color.GRAY)
	return own_color


func _select_slot(index: int) -> void:
	var id: String = _hotbar_slots[index] if index < _hotbar_slots.size() else ""
	if id == "":
		_show_flash("Slot %s is empty — TAB, hover a tool, press %s" % [
			Hotbar.SLOT_LABELS[index], Hotbar.SLOT_LABELS[index]])
		_sync_slot_pressed(view.tool)
		return
	_select_tool(_items_by_id[id]["tool"])


## Pin (or with an empty id, clear). Saves immediately: a loadout the
## player has to remember to save is a loadout they lose.
func _pin_to_slot(index: int, id: String) -> void:
	_hotbar_slots = Hotbar.assign(_hotbar_slots, index, id)
	Hotbar.save_slots(_hotbar_slots)
	_refresh_hotbar()
	_sync_slot_pressed(view.tool)
	_show_flash("Slot %s cleared" % Hotbar.SLOT_LABELS[index] if id == ""
		else "%s → slot %s" % [_items_by_id[id]["label"],
			Hotbar.SLOT_LABELS[index]])


## Press the slot(s) holding the armed tool; leave none pressed otherwise.
func _sync_slot_pressed(tool: CityView.Tool) -> void:
	for i in _hotbar_buttons.size():
		var id: String = _hotbar_slots[i] if i < _hotbar_slots.size() else ""
		var item: Dictionary = _items_by_id.get(id, {})
		(_hotbar_buttons[i] as Button).set_pressed_no_signal(
			not item.is_empty() and item["tool"] == tool)


## Transient confirmation above the hotbar (Minecraft names the item you
## just selected the same way): visible where the eyes already are, gone
## before it becomes clutter.
func _show_flash(text: String) -> void:
	if _flash == null:
		_flash = Label.new()
		_flash.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_flash.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_flash.grow_vertical = Control.GROW_DIRECTION_BEGIN
		_flash.offset_bottom = -70.0
		_flash.add_theme_font_size_override("font_size", 14)
		_flash.add_theme_constant_override("outline_size", 4)
		_flash.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_flash)
	_flash.text = text
	_flash.modulate = Color.WHITE
	# kill the previous fade first: switching tools quickly otherwise leaves
	# several tweens racing over the same alpha, and the newest message
	# inherits the oldest one's countdown
	if _flash_fade != null and _flash_fade.is_valid():
		_flash_fade.kill()
	_flash_fade = create_tween()
	_flash_fade.tween_interval(1.4)
	_flash_fade.tween_property(_flash, "modulate:a", 0.0, 0.6)


# ─── pipette: point at it, get the tool that built it ───

## The shortest path to a tool there is — no menu, no category, no recall
## of which of two near-identical tools laid that run. Carries the variant
## and the placement transform (ToolPipette owns the mapping).
func _pipette(pos: Vector2i) -> void:
	var picked := ToolPipette.sample(City.model, pos)
	if picked.is_empty():
		_show_flash("Nothing to pick up here")
		return
	var tool: CityView.Tool = picked["tool"]
	_select_tool(tool)
	view.set_ghost_transform(int(picked["rot"]), bool(picked["flip"]))
	var item: Dictionary = _items_by_tool.get(tool, {})
	_show_flash("Picked up: %s" % item.get("label", "tool"))


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
var _inspector_graph2: ProfileGraph  # optional second axis (per-house water)
var _inspector_live: Label
var _inspector_key := ""  # what's open — re-clicking the same element toggles


## The panel is a popup at the element now, so it dismisses like one:
## ✕, Esc, click-away on empty ground, or re-click of the same element
## (user report 2026-08-04: with every town tile inspectable, a panel
## that only the small ✕ could close felt impossible to get rid of).
func _close_inspector() -> void:
	if _inspector != null:
		_inspector.visible = false


## True (and closes) when this element's panel is already open — the
## callers early-return so the click acts as a toggle.
func _inspector_toggled_off(key: String) -> bool:
	if _inspector != null and _inspector.visible and _inspector_key == key:
		_inspector.visible = false
		return true
	_inspector_key = key
	return false


## Config tables live in InspectorConfig (Phase-6 extraction).
func _inspector_config(kind: String, id: String) -> Dictionary:
	var island_id: String = City.topo.island_of.get(id, "")
	return InspectorConfig.config_for(kind, id, City.model,
		City.grid_capacity_override,
		island_id != "" and str(City.topo.islands.get(island_id, {})
			.get("former", "")) == id)


## Line/pipe clicks: power lines carry real per-segment loading (contract
## 1.1 edges); heat/water pipes have no per-pipe wire data, so they open
## the network-total graph — honest about what the solver reports.
func _open_tile_inspector(category: String, pos: Vector2i) -> void:
	if _inspector_toggled_off("%s %s" % [category, pos]):
		return
	var anchor := view.tiles_screen_rect([pos])
	match category:
		"commercial":
			var built := InspectorConfig.commercial_config(pos,
				int(City.model.commercial.get(pos, 1)), City.current_t / 96,
				City.weather)
			_show_config(built["config"], built["subtitle"], anchor)
			return
		"house":
			var built := InspectorConfig.house_config(pos, City.current_t / 96,
				City.weather, City.topo.house_zone.get(pos, ""))
			_show_config(built["config"], built["subtitle"], anchor)
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
					"color": Color(0.31, 0.76, 0.97)}]}, edge, anchor)
		"heat_pipe":
			_show_config({"title": "District heating network", "unit": "kW",
				"dec": 0, "base_zero": true, "y": "Total heat load [kW]",
				"limits": [],
				"series": [{"key": "net:heat", "label": "Heat load",
					"color": Color(0.9, 0.35, 0.25)}]}, "all zones", anchor)
		"water_pipe":
			_show_config({"title": "Water network", "unit": "m³/h", "dec": 2,
				"base_zero": true, "y": "Total demand [m³/h]", "limits": [],
				"series": [{"key": "net:water", "label": "Demand",
					"color": Color(0.25, 0.75, 0.5)}]}, "all zones", anchor)


func _open_inspector(id: String) -> void:
	if not City.model.buildings.has(id):
		return
	if _inspector_toggled_off(id):
		return
	var kind: String = City.model.buildings[id]["kind"]
	var config := _inspector_config(kind, id)
	if config.is_empty():
		return
	var subtitle := id
	if kind == "solar_park":
		subtitle += " · facing " + DemandModel.PV_ROT_FACING[
			int(City.model.buildings[id].get("rot", 0)) % 4]
	# island badge (power islands M4): members carry their microgrid,
	# the former its EMS role
	var island_id: String = City.topo.island_of.get(id, "")
	if island_id != "":
		subtitle += " · island microgrid" \
			if str(City.topo.islands.get(island_id, {})
				.get("former", "")) != id \
			else " · forms its island"
	var tiles: Array = []  # full footprint, rotation included
	for tile: Vector2i in City.model.building_tiles:
		if City.model.building_tiles[tile] == id:
			tiles.append(tile)
	if tiles.is_empty():
		tiles.append(City.model.buildings[id]["anchor"])
	_show_config(config, subtitle, view.tiles_screen_rect(tiles))


func _show_config(config: Dictionary, subtitle: String, anchor: Rect2) -> void:
	if _inspector == null:
		_inspector = PanelContainer.new()  # positioned per click, see below
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
		_inspector_graph2 = ProfileGraph.new()
		_inspector_graph2.visible = false
		box.add_child(_inspector_graph2)
		_inspector_live = Label.new()
		_inspector_live.add_theme_font_size_override("font_size", 11)
		_inspector_live.modulate = Color(1, 1, 1, 0.7)
		box.add_child(_inspector_live)
		for network_signal: Signal in [City.power_result, City.heat_result,
				City.water_result]:
			network_signal.connect(func(_t: int, _r: Dictionary) -> void:
				if _inspector.visible:
					_inspector_graph.queue_redraw()
					_inspector_graph2.queue_redraw())
	_inspector_title.text = "%s   (%s)" % [config["title"], subtitle]
	_inspector_live.text = "Today opaque · yesterday faded · dashed = limit"
	var series_typed: Array[Dictionary] = []
	series_typed.assign(config["series"])
	var limits_typed: Array[Dictionary] = []
	limits_typed.assign(config["limits"])
	_inspector_graph.setup(series_typed, config["unit"], config["dec"],
		limits_typed, config["base_zero"], config["y"])
	var secondary: Dictionary = config.get("secondary", {})
	_inspector_graph2.visible = not secondary.is_empty()
	if not secondary.is_empty():
		var series2: Array[Dictionary] = []
		series2.assign(secondary["series"])
		var limits2: Array[Dictionary] = []
		limits2.assign(secondary["limits"])
		_inspector_graph2.setup(series2, secondary["unit"], secondary["dec"],
			limits2, secondary["base_zero"], secondary["y"])
	_inspector.visible = true
	_inspector.reset_size()  # shrink back after a taller house panel
	_inspector.position = popup_position(anchor,
		_inspector.get_combined_minimum_size(),
		get_viewport().get_visible_rect().size)


## Pop up at the clicked element's top-right like a callout (user request
## 2026-08-04 — the fixed right-edge dock sat far from the element),
## clamped fully on screen; min y clears the status bar. Static so the
## clamping geometry is unit-testable.
static func popup_position(anchor: Rect2, panel_size: Vector2,
		viewport_size: Vector2) -> Vector2:
	var panel_pos := Vector2(anchor.end.x + 10.0,
		anchor.position.y - panel_size.y - 10.0)
	panel_pos.x = clampf(panel_pos.x, 8.0,
		maxf(viewport_size.x - panel_size.x - 8.0, 8.0))
	panel_pos.y = clampf(panel_pos.y, 48.0,
		maxf(viewport_size.y - panel_size.y - 8.0, 48.0))
	return panel_pos


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
	_refresh_hotbar()  # slots mirror the tiles: pick the icons up now


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
		CityView.Tool.ZONE_COMMERCIAL:
			var lot := Node3D.new()
			var pad := MeshInstance3D.new()
			var pad_mesh := PlaneMesh.new()
			pad_mesh.size = Vector2(1.1, 1.1)
			pad.mesh = pad_mesh
			pad.material_override = view._flat(Color(0.45, 0.55, 0.9))
			lot.add_child(pad)
			lot.add_child(view._instance_glb(
				"city-kit-industrial/Models/GLB format/building-m.glb", 0.8))
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
	var hint := ""
	if CityView.TOOL_BUILDING.has(tool):
		hint = " — R rotate · F flip"
	elif CityView.PATH_TOOL_BUILD.has(tool):
		hint = " — hold + drag to draw, release to build"
	_tool_label.text = "Tool: %s%s" % [item.get("label", "none"), hint]
	if _tool_buttons.has(tool):
		(_tool_buttons[tool] as Button).set_pressed_no_signal(true)
	_sync_slot_pressed(tool)
	if item.has("label"):
		var cost := _item_cost(item)
		_show_flash("%s%s" % [item["label"],
			("  ·  €%s" % _fmt_money(cost)) if cost > 0 else ""])
	# a hotkey may select a tool on a hidden tab — follow it so the
	# pressed highlight is always visible
	if _tool_category.has(tool):
		_show_category(str(_tool_category[tool]))


func _refresh() -> void:
	var demand := 0.0
	for zone_id: String in City.topo.zones_info:
		demand += DemandModel.zone_sum_kw(
			City.topo.zones_info[zone_id]["house_tiles"], City.current_t)
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
	_refresh_hotbar()  # affordability tracks the money line


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
	# method callable, NOT a lambda: the feed frees labels early when >6
	# queue up, and a lambda capture on a freed label makes every timer
	# fire log "Lambda capture at index 0 was freed" — a bound method's
	# connection dies with its object instead
	get_tree().create_timer(12.0).timeout.connect(label.queue_free)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed():
		return
	var key: InputEventKey = event
	var slot := Hotbar.slot_for_physical(key.physical_keycode)
	if key.keycode == KEY_ESCAPE:
		_select_tool(CityView.Tool.NONE)  # back to inspect mode
		_close_inspector()
	elif slot >= 0:
		# same digit, two meanings by context: over a catalogue tile it
		# PINS that tool, anywhere else it ARMS the slot
		if _build_menu.visible and _hovered_id != "":
			_pin_to_slot(slot, _hovered_id)
		else:
			_select_slot(slot)
	elif key.keycode == KEY_S:
		_pipette(view.mouse_tile())  # keyboard twin of middle-click
	elif TOOL_KEYS.has(key.keycode):
		_select_tool(TOOL_KEYS[key.keycode])
	elif key.keycode == KEY_TAB:
		_build_menu.visible = not _build_menu.visible
	elif key.keycode == KEY_I:
		_breakdown.visible = not _breakdown.visible
		_refresh_breakdown()
	elif key.keycode == KEY_SPACE:
		GameClock.speed = 1.0 if GameClock.speed == 0.0 else 0.0
	elif speed_key_action(key.keycode, key.unicode) == "faster":
		GameClock.speed = clampf(GameClock.speed * 2.0 if GameClock.speed > 0.0 else 1.0, 0.0, 32.0)
	elif speed_key_action(key.keycode, key.unicode) == "slower":
		GameClock.speed = maxf(GameClock.speed / 2.0, 0.25)
	elif key.keycode == KEY_V:
		view.overlays_visible = not view.overlays_visible
	elif key.keycode == KEY_Q:
		view.rotate_view(-1)
	elif key.keycode == KEY_E:
		view.rotate_view(1)
	elif key.keycode == KEY_R:
		view.rotate_ghost()
	elif key.keycode == KEY_F:
		view.flip_ghost()


## Layout-proof speed-key classification (user report 2026-08-06: on a
## German keyboard the dedicated + key emits KEY_PLUS — the old
## KEY_EQUAL-or-KP_ADD match was the US =/+ convention, so speed-up was
## dead on laptops without a numpad). Match the keycode families AND the
## TYPED character, so any layout's +/- works regardless of which
## physical key produces it.
static func speed_key_action(keycode: int, unicode: int) -> String:
	if keycode in [KEY_EQUAL, KEY_PLUS, KEY_KP_ADD] or unicode == 43:  # "+"
		return "faster"
	if keycode in [KEY_MINUS, KEY_KP_SUBTRACT] or unicode == 45:  # "-"
		return "slower"
	return ""


static func _fmt_money(value: int) -> String:
	var text := str(value)
	var out := ""
	while text.length() > 3:
		out = "." + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return text + out
