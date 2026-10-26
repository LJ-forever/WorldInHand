class_name DiceFace
extends Control
## 单颗 d6 骰面。用简单绘制而不是贴图，保证任何主题下都清晰。

var value: int = 1:
	set(new_value):
		value = clampi(new_value, 1, 6)
		queue_redraw()

var highlighted: bool = false:
	set(new_value):
		highlighted = new_value
		queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(48, 48)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var side := minf(size.x, size.y)
	var origin := (size - Vector2(side, side)) * 0.5
	var face_rect := Rect2(origin, Vector2(side, side))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.96, 0.91, 0.77) if highlighted else Color(0.89, 0.85, 0.72)
	style.border_color = Color(0.36, 0.31, 0.22, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(9)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	style.shadow_size = 3
	style.shadow_offset = Vector2(1, 2)
	draw_style_box(style, face_rect)

	var pip_color := Color(0.20, 0.18, 0.14)
	var radius := side * 0.075
	var center := face_rect.position + Vector2(side, side) * 0.5
	var offset := side * 0.24
	var points: Array[Vector2] = []
	match value:
		1:
			points = [center]
		2:
			points = [center + Vector2(-offset, -offset), center + Vector2(offset, offset)]
		3:
			points = [
				center + Vector2(-offset, -offset), center,
				center + Vector2(offset, offset),
			]
		4:
			points = [
				center + Vector2(-offset, -offset), center + Vector2(offset, -offset),
				center + Vector2(-offset, offset), center + Vector2(offset, offset),
			]
		5:
			points = [
				center + Vector2(-offset, -offset), center + Vector2(offset, -offset),
				center, center + Vector2(-offset, offset), center + Vector2(offset, offset),
			]
		6:
			points = [
				center + Vector2(-offset, -offset), center + Vector2(offset, -offset),
				center + Vector2(-offset, 0.0), center + Vector2(offset, 0.0),
				center + Vector2(-offset, offset), center + Vector2(offset, offset),
			]
	for point in points:
		draw_circle(point, radius, pip_color)