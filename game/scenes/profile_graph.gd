class_name ProfileGraph
extends Control
## A daily time-series graph in rtpowerflow's ProfileGraph conventions:
## x = 0..24 h with a tick + gridline every 2 h and a time axis title,
## y = five gridlined ticks with the unit as rotated axis title, curves as
## step-after staircases, dashed limit lines with labels, a "now" marker
## (today's curve opaque up to now, yesterday's full day faded as the
## reference), a legend with live readouts, and a hover cursor that reads
## out each series at the pointed time.

const MARGIN_L := 52.0
const MARGIN_R := 10.0
const MARGIN_T := 12.0
const MARGIN_B := 44.0
const GRID_COLOR := Color(0.16, 0.19, 0.23)
const AXIS_COLOR := Color(0.42, 0.46, 0.5)
const TEXT_COLOR := Color(0.6, 0.65, 0.7)
const FONT_SIZE := 11

## [{key, label, color}] — key indexes City.telemetry
var series: Array[Dictionary] = []
## [{value, label, color}] — dashed horizontal limit lines
var limits: Array[Dictionary] = []
var unit := "kW"
var decimals := 0
var base_zero := true
var y_title := ""

var _hover_frac := -1.0  # 0..1 fraction of the day under the mouse, -1 = none


func setup(series_arg: Array[Dictionary], unit_arg: String, dec_arg: int,
		limits_arg: Array[Dictionary] = [], base_zero_arg: bool = true,
		y_title_arg: String = "") -> void:
	series = series_arg
	unit = unit_arg
	decimals = dec_arg
	limits = limits_arg
	base_zero = base_zero_arg
	y_title = y_title_arg if y_title_arg != "" else unit_arg
	custom_minimum_size = Vector2(380, 200)
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		var plot_w := size.x - MARGIN_L - MARGIN_R
		var frac: float = (mm.position.x - MARGIN_L) / plot_w
		_hover_frac = frac if frac >= 0.0 and frac <= 1.0 else -1.0
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_frac = -1.0
		queue_redraw()


func _today(key: String) -> Array:
	return City.telemetry.get(key, {}).get("today", [])


func _yesterday(key: String) -> Array:
	return City.telemetry.get(key, {}).get("yesterday", [])


static func _last_value(samples: Array) -> float:
	for i in range(samples.size() - 1, -1, -1):
		if not is_nan(float(samples[i])):
			return float(samples[i])
	return NAN


## Evenly spaced y ticks (five, like rtpowerflow's axisTicks).
static func _ticks(y_min: float, y_max: float) -> Array[float]:
	var out: Array[float] = []
	for i in 5:
		out.append(y_min + (y_max - y_min) * i / 4.0)
	return out


func _draw() -> void:
	var font := get_theme_default_font()
	var w := size.x
	var h := size.y
	var plot_left := MARGIN_L
	var plot_right := w - MARGIN_R
	var plot_top := MARGIN_T
	var plot_bottom := h - MARGIN_B

	# y range over both day curves + limits (base_zero anchors at 0 for
	# all-positive data, but negatives are never clipped away)
	var values: Array[float] = []
	for entry: Dictionary in series:
		for samples: Array in [_today(entry["key"]), _yesterday(entry["key"])]:
			for v: Variant in samples:
				if not is_nan(float(v)):
					values.append(float(v))
	for limit: Dictionary in limits:
		values.append(float(limit["value"]))
	var data_min: float = 0.0 if values.is_empty() else values.min()
	var y_max: float = 1.0 if values.is_empty() else values.max()
	var y_min: float = minf(0.0, data_min) if base_zero else data_min
	var pad: float = (y_max - y_min) * 0.08
	if pad <= 0.0:
		pad = maxf(absf(y_max) * 0.08, 0.01)
	y_max += pad
	if not base_zero or y_min < 0.0:
		y_min -= pad
	if y_max <= y_min:
		y_max = y_min + 1.0

	var px := func(frac: float) -> float:
		return plot_left + frac * (plot_right - plot_left)
	var py := func(v: float) -> float:
		return plot_bottom - (v - y_min) / (y_max - y_min) * (plot_bottom - plot_top)

	# x grid: tick + label every 2 h
	for hour in range(0, 25, 2):
		var x: float = px.call(hour / 24.0)
		draw_line(Vector2(x, plot_top), Vector2(x, plot_bottom), GRID_COLOR, 1.0)
		draw_string(font, Vector2(x - 7, plot_bottom + FONT_SIZE + 3),
			str(hour), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	# y grid: five ticks
	for tick: float in _ticks(y_min, y_max):
		var y: float = py.call(tick)
		draw_line(Vector2(plot_left, y), Vector2(plot_right, y), GRID_COLOR, 1.0)
		draw_string(font, Vector2(20, y + FONT_SIZE / 2.0 - 1),
			("%." + str(decimals) + "f") % tick,
			HORIZONTAL_ALIGNMENT_RIGHT, int(plot_left) - 26, FONT_SIZE, TEXT_COLOR)
	# axis titles: time along x, unit rotated on y
	draw_string(font, Vector2((plot_left + plot_right) / 2.0 - 30, h - 6),
		"Time of day [h]", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	draw_set_transform(Vector2(12, (plot_top + plot_bottom) / 2.0 + 20), -PI / 2.0)
	draw_string(font, Vector2.ZERO, y_title, HORIZONTAL_ALIGNMENT_LEFT, -1,
		FONT_SIZE, TEXT_COLOR)
	draw_set_transform(Vector2.ZERO, 0.0)
	# baseline + zero reference when the range crosses 0
	draw_line(Vector2(plot_left, plot_bottom), Vector2(plot_right, plot_bottom),
		AXIS_COLOR, 1.2)
	if y_min < 0.0 and y_max > 0.0:
		draw_line(Vector2(plot_left, py.call(0.0)),
			Vector2(plot_right, py.call(0.0)), AXIS_COLOR, 1.0)

	# dashed limit lines with right-aligned labels
	for limit: Dictionary in limits:
		var y: float = py.call(float(limit["value"]))
		var color: Color = limit.get("color", Color(0.95, 0.3, 0.25))
		draw_dashed_line(Vector2(plot_left, y), Vector2(plot_right, y), color, 1.0, 5.0)
		draw_string(font, Vector2(plot_right - 90, y - 3), str(limit["label"]),
			HORIZONTAL_ALIGNMENT_RIGHT, 88, FONT_SIZE - 1, color)

	# no samples anywhere yet: say so instead of showing a bare grid
	if values.size() <= limits.size():
		draw_string(font, Vector2(plot_left + 20, (plot_top + plot_bottom) / 2.0),
			"collecting data — solvers must be running (network connected?)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0.75, 0.7, 0.4))

	# curves: yesterday faded (the full-day reference), today opaque
	var now_frac := float(City.current_t % 96) / 95.0
	for entry: Dictionary in series:
		var color: Color = entry["color"]
		_draw_staircase(_yesterday(entry["key"]), px, py,
			Color(color.r, color.g, color.b, 0.28), 1.0)
		_draw_staircase(_today(entry["key"]), px, py, color, 1.6)
	# "now" marker
	var now_x: float = px.call(now_frac)
	draw_line(Vector2(now_x, plot_top), Vector2(now_x, plot_bottom),
		Color(0.9, 0.9, 0.9, 0.5), 1.0)

	# hover cursor + readout
	if _hover_frac >= 0.0:
		var hx: float = px.call(_hover_frac)
		draw_dashed_line(Vector2(hx, plot_top), Vector2(hx, plot_bottom),
			Color(0.6, 0.64, 0.69), 1.0, 4.0)
		var minute := int(_hover_frac * 1439.0)
		var readout := "%02d:%02d" % [minute / 60, minute % 60]
		for entry: Dictionary in series:
			var v := _value_at(_today(entry["key"]), _hover_frac)
			if is_nan(v):
				v = _value_at(_yesterday(entry["key"]), _hover_frac)
			if not is_nan(v):
				draw_circle(Vector2(hx, py.call(v)), 3.0, entry["color"])
				readout += "  %s %.*f %s" % [entry["label"], decimals, v, unit]
		draw_string(font, Vector2(plot_left + 4, plot_top + FONT_SIZE),
			readout, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, Color(0.85, 0.88, 0.92))

	# legend with the latest value per series
	var legend_x := plot_left
	for entry: Dictionary in series:
		draw_rect(Rect2(legend_x, h - MARGIN_B + 24, 9, 9), entry["color"])
		var latest := _last_value(_today(entry["key"]))
		var label: String = entry["label"] + ("" if is_nan(latest)
			else "  %.*f %s" % [decimals, latest, unit])
		draw_string(font, Vector2(legend_x + 13, h - MARGIN_B + 24 + FONT_SIZE - 2),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
		legend_x += 13 + font.get_string_size(label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 16


func _draw_staircase(samples: Array, px: Callable, py: Callable,
		color: Color, width: float) -> void:
	if samples.is_empty():
		return
	var prev := Vector2.INF
	for i in samples.size():
		var v := float(samples[i])
		if is_nan(v):
			prev = Vector2.INF
			continue
		var pt := Vector2(px.call(i / 95.0), py.call(v))
		if prev != Vector2.INF:
			# step-after: hold the previous value to this x, then step
			draw_line(prev, Vector2(pt.x, prev.y), color, width)
			draw_line(Vector2(pt.x, prev.y), pt, color, width)
		prev = pt


## Step-after readout: the sample whose plateau the fraction sits on.
static func _value_at(samples: Array, frac: float) -> float:
	if samples.is_empty():
		return NAN
	var i := mini(samples.size() - 1, int(frac * (samples.size() - 1)))
	while i > 0 and is_nan(float(samples[i])):
		i -= 1
	return float(samples[i])
