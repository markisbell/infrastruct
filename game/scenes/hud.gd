class_name Hud
extends CanvasLayer
## HUD: status bar, tool selection (number keys), event toasts, speed controls.

const TOOL_KEYS := {
	KEY_1: [CityView.Tool.ROAD, "Road"],
	KEY_2: [CityView.Tool.ZONE, "Zone (residential)"],
	KEY_3: [CityView.Tool.CABLE, "Cable"],
	KEY_4: [CityView.Tool.SUBSTATION, "Substation"],
	KEY_5: [CityView.Tool.GAS, "Gas plant"],
	KEY_6: [CityView.Tool.WIND, "Wind farm"],
	KEY_7: [CityView.Tool.SOLAR, "Solar park"],
	KEY_8: [CityView.Tool.BATTERY, "Battery"],
	KEY_9: [CityView.Tool.GRID, "Grid connection"],
	KEY_0: [CityView.Tool.BULLDOZE, "Bulldoze"],
}

var view: CityView
var _status: Label
var _tool_label: Label
var _events_box: VBoxContainer


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
	_tool_label.text = "Tool: none — keys 1-9, 0 bulldoze · RMB erase · SPACE pause · +/- speed · V overlays"
	row.add_child(_tool_label)

	var events_panel := PanelContainer.new()
	events_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	events_panel.offset_top = 44.0
	events_panel.offset_left = -420.0
	add_child(events_panel)
	_events_box = VBoxContainer.new()
	events_panel.add_child(_events_box)

	City.state_changed.connect(_refresh)
	City.event_logged.connect(_on_event)
	GameClock.speed_changed.connect(func(_s: float) -> void: _refresh())
	_refresh()


func _refresh() -> void:
	var demand := 0.0
	for zone_id: String in City.topo.zones_info:
		demand += DemandModel.zone_demand_kw(
			City.topo.zones_info[zone_id]["houses"], City.current_t)
	var houses := City.model.houses.size()
	_status.text = "Day %d %s (%s) · %s · €%s · Happiness %.0f%% · %d houses · %.0f kW demand · Outage %d min" % [
		GameClock.day(), GameClock.time_of_day_string(), GameClock.season_name(),
		("PAUSED" if GameClock.speed == 0.0 else "%.0fx" % GameClock.speed),
		_fmt_money(City.money), City.happiness, houses, demand,
		City.total_outage_minutes()]


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
		view.tool = TOOL_KEYS[key.keycode][0]
		_tool_label.text = "Tool: " + TOOL_KEYS[key.keycode][1]
	elif key.keycode == KEY_SPACE:
		GameClock.speed = 1.0 if GameClock.speed == 0.0 else 0.0
	elif key.keycode == KEY_EQUAL or key.keycode == KEY_KP_ADD:
		GameClock.speed = clampf(GameClock.speed * 2.0 if GameClock.speed > 0.0 else 1.0, 0.0, 32.0)
	elif key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
		GameClock.speed = maxf(GameClock.speed / 2.0, 0.25)
	elif key.keycode == KEY_V:
		view.overlays_visible = not view.overlays_visible
		view.queue_redraw()


static func _fmt_money(value: int) -> String:
	var text := str(value)
	var out := ""
	while text.length() > 3:
		out = "." + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return text + out
