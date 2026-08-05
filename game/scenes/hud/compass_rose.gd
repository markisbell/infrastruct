## Screen-true compass (user request 2026-08-02): letters are PROJECTED
## through the live camera (ortho, so any anchor point works), so they stay
## honest under Q/E rotation and smoothing; the gold dot is the sun's
## current azimuth — anticipate it when orienting solar parks.
class_name CompassRose
extends Control
var view: CityView

func _process(_dt: float) -> void:
	queue_redraw()

func _screen_dir(camera: Camera3D, world_dir: Vector3) -> Vector2:
	var anchor := Vector3(128.0, 0.0, 128.0)
	return (camera.unproject_position(anchor + world_dir * 8.0)
		- camera.unproject_position(anchor)).normalized()

func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null or view == null:
		return
	var c := size / 2.0
	var r := minf(c.x, c.y) - 12.0
	draw_circle(c, r + 11.0, Color(0.08, 0.1, 0.13, 0.72))
	draw_arc(c, r + 4.0, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.22), 1.0)
	var font := get_theme_default_font()
	for entry: Array in [
			["N", Vector3(0, 0, -1), Color(0.95, 0.45, 0.38)],
			["E", Vector3(-1, 0, 0), Color(1, 1, 1, 0.85)],
			["S", Vector3(0, 0, 1), Color(1, 1, 1, 0.85)],
			["W", Vector3(1, 0, 0), Color(1, 1, 1, 0.85)]]:
		var a := _screen_dir(camera, entry[1])
		var letter: String = entry[0]
		var letter_size := font.get_string_size(letter,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 12)
		draw_string(font, c + a * (r - 3.0)
			- Vector2(letter_size.x / 2.0, -letter_size.y * 0.35),
			letter, HORIZONTAL_ALIGNMENT_CENTER, -1, 12, entry[2])
	var sun := view.sun_dir_world()
	if sun != Vector3.ZERO:
		var a := _screen_dir(camera, sun)
		draw_line(c, c + a * (r - 12.0), Color(1.0, 0.85, 0.3, 0.5), 1.5)
		draw_circle(c + a * (r - 10.0), 4.0, Color(1.0, 0.85, 0.3))
