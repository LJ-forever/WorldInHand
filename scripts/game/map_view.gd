extends Node2D
## Voronoi 地图渲染与自由画笔交互。
## 画线阶段只显示线条：不显示 AP 消耗、不显示可达范围、不显示截断点。
## 地块仍以多边形边界呈现；格内用顶点/边中点高度做出连续起伏。
## 移动阶段读取 GameManager.visual_position，沿玩家画出的折线播放动画。

signal hovered_cell_changed(cell_id: int)
signal hovered_marker_changed(cell_id: int)
signal hover_position_changed(point: Vector2)
signal stroke_rejected(message: String)

const INVALID_CELL := -1
const MIN_ZOOM := 0.6
const MAX_ZOOM := 3.2
const INITIAL_ZOOM := 1.38
const ZOOM_STEP := 1.14
## 平移时至少保留多少像素的地图在屏幕内，避免把整张图拖丢。
const PAN_KEEP_VISIBLE := 96.0

var _hovered: int = INVALID_CELL
var _hovered_marker: int = INVALID_CELL
var _hover_position: Vector2 = Vector2.ZERO
var _drawing: bool = false
var _stroke: PackedVector2Array = PackedVector2Array()
var _cached_map: MapData = null
var _color_cache: Dictionary = {}
var _terrain_color_cache: Dictionary = {}
var _zoom: float = INITIAL_ZOOM
var _pan: Vector2 = Vector2.ZERO
var _view_initialized: bool = false
var _panning: bool = false
var _pan_last_screen: Vector2 = Vector2.ZERO
var _last_vision_center: Vector2 = Vector2.INF
var _last_vision_radius: float = -1.0
## 视野圆边界的近似段数；越高越圆，但每帧对每个地块做裁剪的成本也越高。
const VISION_CIRCLE_SEGMENTS := 72


func _ready() -> void:
	GameManager.path_changed.connect(_on_visual_changed)
	GameManager.player_moved.connect(_on_visual_changed)
	GameManager.turn_started.connect(_on_visual_changed)
	GameManager.movement_started.connect(_on_visual_changed)
	GameManager.movement_finished.connect(_on_movement_finished)
	GameManager.cell_entered.connect(_on_cell_entered)
	GameManager.fog_changed.connect(_on_visual_changed)
	GameManager.companion_changed.connect(_on_visual_changed)
	GameManager.state_changed.connect(_on_state_changed)


func _process(_delta: float) -> void:
	if not _view_initialized and GameManager.map != null:
		_reset_view()
	var map := GameManager.map
	if map != null:
		var vision_changed := map.vision_center.distance_to(_last_vision_center) > 0.05 \
			or absf(map.vision_radius_world - _last_vision_radius) > 0.05
		if vision_changed:
			_last_vision_center = map.vision_center
			_last_vision_radius = map.vision_radius_world
			queue_redraw()
	if GameManager.is_moving:
		queue_redraw()


func _draw() -> void:
	var map := GameManager.map
	if map == null:
		return
	_ensure_color_cache(map)
	draw_set_transform(_pan, 0.0, Vector2(_zoom, _zoom))
	_draw_boundary_shadow(map)
	for cell in map.cells:
		_draw_cell_base(cell)
	_draw_boundary_line(map)
	_draw_fog_overlays(map)
	_draw_hover_overlay(map)
	_draw_landmarks(map)
	_draw_companion()
	_draw_path()
	_draw_player()
	_draw_drawing_cursor(map)


func get_hover_position() -> Vector2:
	return _hover_position


func get_zoom() -> float:
	return _zoom


## 以地图包围盒中心为基准，恢复默认缩放；用于新开一局或按 Home。
func _reset_view() -> void:
	var map := GameManager.map
	if map == null:
		return
	var viewport_size := get_viewport_rect().size
	# 顶部信息条与底部动作栏之间才是可读地图区；右侧不再需要为旧信息框留白。
	var safe_top := 58.0 + 24.0
	var safe_bottom := viewport_size.y - 132.0
	var available := Vector2(
		maxf(viewport_size.x - 64.0, 400.0),
		maxf(safe_bottom - safe_top, 300.0)
	)
	var fit_zoom := minf(available.x / maxf(map.bounds.size.x, 1.0), available.y / maxf(map.bounds.size.y, 1.0))
	_zoom = clampf(fit_zoom, MIN_ZOOM, INITIAL_ZOOM)
	var map_center_screen := Vector2(viewport_size.x * 0.5, (safe_top + safe_bottom) * 0.5)
	_pan = map_center_screen - map.bounds.get_center() * _zoom
	_view_initialized = true
	_hovered = INVALID_CELL
	_hovered_marker = INVALID_CELL
	_clamp_pan()
	queue_redraw()


func _screen_to_world(point: Vector2) -> Vector2:
	return (point - _pan) / _zoom


func _world_to_screen(point: Vector2) -> Vector2:
	return point * _zoom + _pan


func _clamp_pan() -> void:
	var map := GameManager.map
	if map == null:
		return
	var viewport_size := get_viewport_rect().size
	var keep := PAN_KEEP_VISIBLE
	var min_pan_x := keep - map.bounds.end.x * _zoom
	var max_pan_x := viewport_size.x - keep - map.bounds.position.x * _zoom
	var min_pan_y := keep - map.bounds.end.y * _zoom
	var max_pan_y := viewport_size.y - keep - map.bounds.position.y * _zoom
	if min_pan_x <= max_pan_x:
		_pan.x = clampf(_pan.x, min_pan_x, max_pan_x)
	else:
		_pan.x = (min_pan_x + max_pan_x) * 0.5
	if min_pan_y <= max_pan_y:
		_pan.y = clampf(_pan.y, min_pan_y, max_pan_y)
	else:
		_pan.y = (min_pan_y + max_pan_y) * 0.5


func _zoom_at(screen_point: Vector2, factor: float) -> void:
	var world_anchor := _screen_to_world(screen_point)
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	_pan = screen_point - world_anchor * _zoom
	_clamp_pan()
	_view_initialized = true
	_update_hover(_screen_to_world(screen_point))
	queue_redraw()


func _draw_boundary_shadow(map: MapData) -> void:
	var closed := _closed(map.boundary)
	draw_colored_polygon(closed, Color(0.10, 0.09, 0.075, 1.0))
	draw_polyline(closed, Color(0.04, 0.04, 0.035, 0.85), 10.0, true)


func _draw_boundary_line(map: MapData) -> void:
	var closed := _closed(map.boundary)
	draw_polyline(closed, Color(0.06, 0.055, 0.045, 0.95), 4.0, true)
	draw_polyline(closed, Color(0.45, 0.40, 0.31, 0.65), 1.5, true)


func _draw_cell_base(cell: MapData.Cell) -> void:
	var cached_colors: PackedColorArray = _color_cache.get(cell.id, PackedColorArray())
	if cell.relief_polygon.size() >= 3 and cached_colors.size() == cell.relief_polygon.size():
		draw_polygon(cell.relief_polygon, cached_colors)
	else:
		var fallback := _terrain_color(cell.terrain)
		draw_colored_polygon(cell.polygon, _relief_color(fallback, float(cell.elevation)))
	# 内部格线先画；迷雾层会盖住圆外部分，因此未知区域不会提前露出完整地块。
	_draw_polygon_outline(cell.polygon, Color(0.055, 0.05, 0.04, 0.11), 0.7)


## 圆形战争迷雾：地形底色始终先完整绘制，迷雾只是叠加在上面的独立深色层。
## 未知 = 近黑覆盖层；曾获得信息 = 低亮度覆盖层；圆内不覆盖。
## 这样同一地块始终保留基础地形颜色，只是被不同透明度的黑层压暗。
func _draw_fog_overlays(map: MapData) -> void:
	var radius := map.vision_radius_world
	if radius <= 0.1:
		for cell in map.cells:
			draw_colored_polygon(cell.polygon, _unknown_fog_color())
		return
	var circle := _circle_polygon(map.vision_center, radius)
	var circle_rect := Rect2(map.vision_center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
	# 记忆层保留地形色相；未知层更黑，但仍透出一点底色，避免看起来像没有地形图层。
	var known_color := Color(0.010, 0.016, 0.013, 0.56)
	var unknown_color := _unknown_fog_color()
	for cell in map.cells:
		# 圆完全在格子外：整格上雾；圆完全包住格子：不用裁剪。
		# 只有被圆弧穿过边界的格子才需要多边形裁剪，避免每帧对所有格子做几何运算。
		if not cell.bounds.intersects(circle_rect):
			draw_colored_polygon(cell.polygon, known_color if map.is_cell_known(cell.id) else unknown_color)
			continue
		if circle_rect.encloses(cell.bounds):
			continue
		var outside := Geometry2D.clip_polygons(cell.polygon, circle)
		if outside.is_empty():
			continue
		var color := known_color if map.is_cell_known(cell.id) else unknown_color
		for piece in outside:
			var clean_piece := _sanitize_polygon(piece)
			if clean_piece.size() < 3:
				continue
			if Geometry2D.triangulate_polygon(clean_piece).is_empty():
				continue
			draw_colored_polygon(clean_piece, color)
	# 很淡的圆弧边界，帮助玩家读出“视野”而不是地块边界。
	draw_arc(map.vision_center, radius, 0.0, TAU, VISION_CIRCLE_SEGMENTS, Color(0.62, 0.66, 0.56, 0.18), 1.2, true)


func _unknown_fog_color() -> Color:
	# 不透明会彻底吃掉基础地形色；保留 8% 的底色透出，形成“黑层覆盖”而不是“换色”。
	return Color(0.006, 0.009, 0.008, 0.92)


func _circle_polygon(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(VISION_CIRCLE_SEGMENTS):
		var angle := TAU * float(i) / float(VISION_CIRCLE_SEGMENTS)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


## 裁剪后可能产生重复点/闭合重复点，直接交给渲染器会三角化失败。
func _sanitize_polygon(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		if result.is_empty() or result[result.size() - 1].distance_squared_to(point) > 0.0001:
			result.append(point)
	if result.size() >= 2 and result[0].distance_squared_to(result[result.size() - 1]) <= 0.0001:
		result.remove_at(result.size() - 1)
	return result


func _draw_hover_overlay(map: MapData) -> void:
	if _hovered == INVALID_CELL:
		return
	var cell := map.get_cell(_hovered)
	if cell == null:
		return
	var radius := map.vision_radius_world
	if radius <= 0.1:
		return
	var circle := _circle_polygon(map.vision_center, radius)
	if map.is_point_in_current_vision(_hover_position):
		# 圆内只高亮被圆切到的那一部分，不显示完整地块。
		var inside := Geometry2D.intersect_polygons(cell.polygon, circle)
		for piece in inside:
			if piece.size() >= 3:
				draw_colored_polygon(piece, Color(1, 1, 1, 0.075))
				_draw_polygon_outline(piece, Color(1, 1, 1, 0.9), 2.0)
	elif map.fog_state(cell.id) == MapData.FogState.REMEMBERED:
		draw_colored_polygon(cell.polygon, Color(1, 1, 1, 0.04))
		_draw_polygon_outline(cell.polygon, Color(0.82, 0.84, 0.76, 0.55), 1.4)


func _ensure_color_cache(map: MapData) -> void:
	if _cached_map == map:
		return
	_cached_map = map
	_color_cache.clear()
	_terrain_color_cache.clear()
	for cell in map.cells:
		var vertex_colors := PackedColorArray()
		vertex_colors.resize(cell.polygon.size())
		for i in range(cell.polygon.size()):
			vertex_colors[i] = _blended_terrain_color(map, cell, cell.polygon[i])
		var colors := PackedColorArray()
		colors.resize(cell.relief_polygon.size())
		var count := cell.polygon.size()
		for i in range(cell.relief_polygon.size()):
			var base: Color
			var vertex_index := i >> 1
			if i % 2 == 0:
				base = vertex_colors[vertex_index]
			else:
				var a := vertex_colors[vertex_index]
				var b := vertex_colors[(vertex_index + 1) % count]
				base = Color(
					(a.r + b.r) * 0.5,
					(a.g + b.g) * 0.5,
					(a.b + b.b) * 0.5,
					(a.a + b.a) * 0.5
				)
			colors[i] = _relief_color(base, cell.relief_heights[i])
		_color_cache[cell.id] = colors


func _blended_terrain_color(map: MapData, cell: MapData.Cell, vertex: Vector2) -> Color:
	var own := _terrain_color(cell.terrain)
	var total := Color(0, 0, 0, 0)
	var count := 0
	for neighbor_id in cell.neighbors:
		var neighbor := map.get_cell(neighbor_id)
		if neighbor == null:
			continue
		for neighbor_vertex in neighbor.polygon:
			if neighbor_vertex.distance_squared_to(vertex) <= 1.0:
				total += _terrain_color(neighbor.terrain)
				count += 1
				break
	if count == 0:
		return own
	var average := Color(total.r / count, total.g / count, total.b / count, total.a / count)
	return own.lerp(average, 0.24)


func _terrain_color(terrain_id: String) -> Color:
	if _terrain_color_cache.has(terrain_id):
		return _terrain_color_cache[terrain_id]
	var record := DataManager.get_record("terrains", terrain_id)
	var color := Color.from_string(String(record.get("color", "#808080")), Color(0.5, 0.5, 0.5))
	_terrain_color_cache[terrain_id] = color
	return color


func _relief_color(base: Color, height: float) -> Color:
	var normalized := clampf(height / 4.0, 0.0, 1.0)
	var illuminated := base.lightened(0.05)
	var shade := (normalized - 0.5) * 0.90
	if shade >= 0.0:
		illuminated = illuminated.lightened(minf(shade, 0.30))
	else:
		illuminated = illuminated.darkened(minf(-shade, 0.30))
	# 高处略偏暖，低处略偏冷，避免只靠明度产生塑料感。
	return illuminated.lerp(Color(0.95, 0.89, 0.70), 0.08 * normalized)


func _draw_polygon_outline(polygon: PackedVector2Array, color: Color, width: float) -> void:
	if polygon.size() < 3:
		return
	var closed := _closed(polygon)
	draw_polyline(closed, color, width, true)


func _draw_landmarks(map: MapData) -> void:
	for poi_id in map.poi_ids:
		var cell := map.get_cell(poi_id)
		if cell == null:
			continue
		if not cell.landmark_id.is_empty():
			if _marker_visible_at(poi_id):
				_draw_facility_marker(map, cell)
			continue
		if not map.is_poi_known(poi_id):
			continue
		var center := map.cell_center(poi_id)
		var poi_state := map.fog_state(poi_id)
		var visible := map.is_point_in_current_vision(center) or poi_state == MapData.FogState.VISIBLE
		if not visible and poi_state != MapData.FogState.REMEMBERED:
			continue
		_draw_poi_dot(center, visible)
	# 起点与终点始终可辨：设计只保证“最终目标点”可见，起点是玩家已知位置。
	_draw_marker(map.cell_center(map.start_id), Color(0.42, 0.82, 0.52), false)
	var goal_center := map.cell_center(map.goal_id)
	_draw_marker(goal_center, Color(0.96, 0.78, 0.30), true)
	draw_arc(goal_center, 15.0, 0.0, TAU, 32, Color(0.96, 0.78, 0.30, 0.35), 2.0, true)
	_draw_marker_hover_ring(map)


func _draw_poi_dot(center: Vector2, visible: bool) -> void:
	var gold := Color(0.94, 0.76, 0.32, 0.95 if visible else 0.45)
	draw_circle(center, 5.0, Color(0.10, 0.08, 0.04, 0.85), true, -1.0, true)
	draw_circle(center, 3.4, gold, true, -1.0, true)
	draw_arc(center, 7.0, 0.0, TAU, 20, Color(0.94, 0.76, 0.32, 0.55 if visible else 0.35), 1.0, true)


## 固定地标标记：always_visible 的地标始终可见；离开视野后只降低亮度。
func _draw_facility_marker(map: MapData, cell: MapData.Cell) -> void:
	var center := map.cell_center(cell.id)
	var state := map.fog_state(cell.id)
	var visible := map.is_point_in_current_vision(center) or state == MapData.FogState.VISIBLE
	var alpha := 1.0 if visible else 0.55
	var color := _landmark_color(cell.landmark_id, alpha)
	draw_circle(center, 7.8, Color(0.05, 0.05, 0.04, 0.82), true, -1.0, true)
	match cell.landmark_id:
		"checkpoint":
			var diamond := PackedVector2Array([
				center + Vector2(0.0, -6.2), center + Vector2(6.2, 0.0),
				center + Vector2(0.0, 6.2), center + Vector2(-6.2, 0.0),
				center + Vector2(0.0, -6.2),
			])
			draw_polyline(diamond, color, 2.0, true)
			draw_circle(center, 2.2, color, true, -1.0, true)
		"shop":
			var shop_rect := Rect2(center - Vector2(4.6, 4.6), Vector2(9.2, 9.2))
			draw_rect(shop_rect, color, true)
			draw_rect(shop_rect, Color(0.05, 0.05, 0.04, 0.70 * alpha), false, 1.0)
		"inn":
			draw_circle(center, 4.9, color, true, -1.0, true)
			draw_line(
				center + Vector2(-3.2, 1.0), center + Vector2(3.2, 1.0),
				Color(0.05, 0.05, 0.04, 0.72 * alpha), 1.2, true
			)
		_:
			draw_circle(center, 3.6, color, true, -1.0, true)
	var halo := color
	halo.a = 0.36 * alpha
	draw_arc(center, 9.0, 0.0, TAU, 20, halo, 1.0, true)


func _draw_marker_hover_ring(map: MapData) -> void:
	if _hovered_marker < 0 or not _marker_visible_at(_hovered_marker):
		return
	var cell := map.get_cell(_hovered_marker)
	var ring_color := Color(0.96, 0.96, 0.90, 0.92)
	if cell != null and not cell.landmark_id.is_empty():
		ring_color = _landmark_color(cell.landmark_id, 0.95)
	elif _hovered_marker == map.goal_id:
		ring_color = Color(0.96, 0.78, 0.30, 0.95)
	elif _hovered_marker == map.start_id:
		ring_color = Color(0.42, 0.82, 0.52, 0.95)
	draw_arc(map.cell_center(_hovered_marker), 12.5, 0.0, TAU, 30, ring_color, 1.6, true)


func _landmark_color(landmark_id: String, alpha: float) -> Color:
	var record := DataManager.get_record("landmarks", landmark_id)
	var color := Color.from_string(String(record.get("color", "#D9A441")), Color(0.85, 0.75, 0.40))
	color.a = alpha
	return color


func _marker_visible_at(cell_id: int) -> bool:
	var map := GameManager.map
	if map == null or map.get_cell(cell_id) == null:
		return false
	if cell_id == map.start_id or cell_id == map.goal_id:
		return true
	var cell := map.get_cell(cell_id)
	if not cell.landmark_id.is_empty():
		var record := DataManager.get_record("landmarks", cell.landmark_id)
		if bool(record.get("always_visible", true)):
			return true
	if not map.is_poi_known(cell_id):
		return false
	var state := map.fog_state(cell_id)
	return state == MapData.FogState.VISIBLE or state == MapData.FogState.REMEMBERED


func _marker_candidates() -> Array[int]:
	var result: Array[int] = []
	var map := GameManager.map
	if map == null:
		return result
	result.append_array(map.poi_ids)
	if map.start_id >= 0:
		result.append(map.start_id)
	if map.goal_id >= 0:
		result.append(map.goal_id)
	return result


## 标记是固定位置的小点，用屏幕半径做命中检测，避免缩放后难以点中。
func _pick_marker_at_screen(screen_point: Vector2) -> int:
	var map := GameManager.map
	if map == null:
		return INVALID_CELL
	var radius := maxf(16.0, 10.0 * _zoom)
	var best := INVALID_CELL
	var best_distance := INF
	for cell_id in _marker_candidates():
		if not _marker_visible_at(cell_id):
			continue
		var distance := _world_to_screen(map.cell_center(cell_id)).distance_to(screen_point)
		if distance <= radius and distance < best_distance:
			best_distance = distance
			best = cell_id
	return best


func _draw_marker(center: Vector2, color: Color, double_ring: bool) -> void:
	draw_circle(center, 9.5, Color(0.06, 0.06, 0.05, 0.85), true, -1.0, true)
	draw_circle(center, 7.0, color, true, -1.0, true)
	draw_circle(center, 2.4, Color(0.10, 0.09, 0.07), true, -1.0, true)
	if double_ring:
		draw_arc(center, 11.0, 0.0, TAU, 24, Color(0.96, 0.78, 0.30, 0.8), 1.5, true)


func _draw_companion() -> void:
	var companion = GameManager.companion
	var map := GameManager.map
	if companion == null or companion.actor == null or map == null:
		return
	var marker_state := GameManager.companion_marker_state()
	if marker_state == "hidden":
		return
	var visible := marker_state == "visible"
	var heard := marker_state == "heard"
	var cell_id := GameManager.companion_marker_cell()
	if cell_id < 0 or cell_id >= map.cells.size():
		return
	var center := map.cell_center(cell_id)
	# 同格时只做格内微调，绝不把标记推出地块边界。
	if visible and GameManager.player != null and companion.actor.cell_id == GameManager.player.cell_id:
		center += Vector2(4.5, 3.5)
	var intel := EventManager.get_reveal_level()
	var color := Color(0.68, 0.68, 0.60, 0.95)
	if intel >= 2:
		match companion.faction:
			"friendly":
				color = Color(0.46, 0.80, 0.64, 0.98)
			"enemy":
				color = Color(0.88, 0.44, 0.38, 0.98)
			_:
				color = Color(0.86, 0.74, 0.46, 0.98)
	if not companion.alive:
		color = Color(0.48, 0.48, 0.44, 0.72)
	if visible:
		draw_circle(center, 7.6, Color(0.04, 0.04, 0.03, 0.86), true, -1.0, true)
		draw_circle(center, 5.8, color, true, -1.0, true)
		draw_circle(center, 2.2, Color(0.12, 0.10, 0.08), true, -1.0, true)
		var halo := color
		halo.a = 0.42
		draw_arc(center, 9.6, -PI * 0.35, PI * 0.95, 22, halo, 1.1, true)
		if companion.faction == "enemy" and intel >= 2:
			var warning := color
			warning.a = 0.7
			draw_line(center + Vector2(0.0, -11.5), center + Vector2(0.0, -15.0), warning, 1.4, true)
	elif heard:
		# 听声辨位：虚化圆心 + 断开的圆环 + 两道声波，表示“她在附近，但还没看见”。
		draw_circle(center, 7.0, Color(0.04, 0.045, 0.035, 0.42), true, -1.0, true)
		var heard_color := color
		heard_color.a = 0.58
		draw_arc(center, 5.6, -PI * 0.5, PI * 0.5, 14, heard_color, 1.5, true)
		draw_arc(center, 5.6, PI * 0.5, PI * 1.5, 14, heard_color, 1.5, true)
		var wave := color
		wave.a = 0.34
		draw_arc(center, 9.4, -0.5, 0.5, 10, wave, 1.2, true)
		draw_arc(center, 11.4, -0.36, 0.36, 10, wave, 1.0, true)
	else:
		# 最后已知位置：空心环 + 暗色底，避免在明亮地块上完全看不见。
		var faded := color
		faded.a = 0.78 if intel >= 2 else 0.55
		draw_circle(center, 7.0, Color(0.04, 0.045, 0.035, 0.52), true, -1.0, true)
		draw_arc(center, 5.6, 0.0, TAU, 20, faded, 1.5, true)
		draw_circle(center, 1.6, faded, true, -1.0, true)
		if not companion.alive:
			var cross := color
			cross.a = 0.85
			draw_line(center + Vector2(-3.6, -3.6), center + Vector2(3.6, 3.6), cross, 1.4, true)
			draw_line(center + Vector2(-3.6, 3.6), center + Vector2(3.6, -3.6), cross, 1.4, true)


func _draw_path() -> void:
	var path_points := GameManager.drawn_stroke
	if not path_points.is_empty():
		draw_polyline(path_points, Color(0.03, 0.035, 0.03, 0.55), 6.0, true)
		draw_polyline(path_points, Color(0.86, 0.90, 0.80, 0.95), 2.6, true)
	if _drawing and _stroke.size() >= 2:
		draw_polyline(_stroke, Color(0.03, 0.035, 0.03, 0.55), 6.0, true)
		draw_polyline(_stroke, Color(0.92, 0.94, 0.84, 0.95), 2.6, true)


func _draw_player() -> void:
	if GameManager.player == null:
		return
	var center := GameManager.get_visual_position()
	# 与队友同格时向内微偏，两个标记都留在地块内。
	var companion = GameManager.companion
	if companion != null and companion.actor != null and companion.actor.cell_id == GameManager.player.cell_id:
		center += Vector2(-4.5, -3.5)
	var pulse := 1.0
	if GameManager.is_moving:
		pulse = 1.0 + 0.10 * sin(Time.get_ticks_msec() * 0.012)
	draw_circle(center, 9.4 * pulse, Color(0.04, 0.04, 0.03, 0.85), true, -1.0, true)
	draw_circle(center, 7.4 * pulse, Color(0.96, 0.87, 0.56), true, -1.0, true)
	draw_circle(center, 2.8, Color(0.20, 0.16, 0.10), true, -1.0, true)
	if GameManager.is_moving:
		draw_arc(center, 11.6, 0.0, TAU, 28, Color(0.96, 0.84, 0.48, 0.5), 1.3, true)


func _draw_drawing_cursor(map: MapData) -> void:
	if not _drawing or _stroke.is_empty():
		return
	var last := _stroke[_stroke.size() - 1]
	var cell_id := map.cell_at_point(last)
	var valid := cell_id >= 0
	draw_circle(last, 5.0, Color(0.98, 0.90, 0.62, 0.95) if valid else Color(0.9, 0.35, 0.3, 0.9), true, -1.0, true)


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var result := points.duplicate()
	if result.size() >= 2 and result[0].distance_to(result[result.size() - 1]) > 0.01:
		result.append(result[0])
	return result


func _on_visual_changed() -> void:
	if _drawing and not GameManager.can_draw_path():
		var reason := GameManager.move_block_reason()
		_cancel_drawing()
		if not reason.is_empty():
			stroke_rejected.emit(reason)
	queue_redraw()


func _on_movement_finished(reason: String) -> void:
	if not reason.is_empty():
		stroke_rejected.emit(reason)
	queue_redraw()


func _on_cell_entered(_cell_id: int, _from_id: int) -> void:
	queue_redraw()


func _on_state_changed(_new_state: int) -> void:
	if _drawing and not GameManager.can_draw_path():
		_cancel_drawing()
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	var map := GameManager.map
	if map == null:
		return
	if event is InputEventMouseMotion:
		if _panning:
			_pan += event.position - _pan_last_screen
			_pan_last_screen = event.position
			_clamp_pan()
			_update_hover(_screen_to_world(event.position))
			queue_redraw()
			return
		var world := _screen_to_world(event.position)
		_update_hover(world)
		if _drawing:
			if not GameManager.can_draw_path():
				_cancel_drawing()
				return
			if _stroke.is_empty() or _stroke[_stroke.size() - 1].distance_to(world) >= 2.0 / _zoom:
				_stroke.append(world)
				queue_redraw()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var factor := ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP
				_zoom_at(event.position, factor)
			return
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
			_pan_last_screen = event.position
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			var world := _screen_to_world(event.position)
			if event.pressed:
				_try_start_drawing(world)
			elif _drawing:
				_finish_drawing()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if not GameManager.is_moving:
				GameManager.clear_drawn_path()
				queue_redraw()
			return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_HOME:
			_reset_view()
			return
		if event.keycode == KEY_ENTER or event.keycode == KEY_SPACE:
			GameManager.execute_move()
			queue_redraw()


func _try_start_drawing(point: Vector2) -> void:
	var map := GameManager.map
	if map == null or GameManager.player == null:
		return
	if not GameManager.can_draw_path():
		stroke_rejected.emit(GameManager.move_block_reason())
		return
	var cell_id := map.cell_at_point(point)
	if cell_id != GameManager.player.cell_id \
			and point.distance_to(GameManager.visual_position) > GameManager.TOKEN_GRAB_RADIUS:
		stroke_rejected.emit("起笔位置不对：请从角色标记所在的地块开始画线")
		return
	_drawing = true
	_stroke = PackedVector2Array([point])
	queue_redraw()


func _finish_drawing() -> void:
	_drawing = false
	var stroke := _stroke
	_stroke = PackedVector2Array()
	if stroke.size() < 2 or _stroke_length(stroke) < 6.0:
		queue_redraw()
		return
	if not GameManager.set_drawn_path(stroke):
		var reason := GameManager.last_path_error
		if reason.is_empty():
			reason = "路径无效：请从角色所在格出发，并画在地图内"
		stroke_rejected.emit(reason)
	queue_redraw()


func _cancel_drawing() -> void:
	_drawing = false
	_stroke = PackedVector2Array()
	queue_redraw()


func _stroke_length(stroke: PackedVector2Array) -> float:
	var length := 0.0
	for i in range(1, stroke.size()):
		length += stroke[i - 1].distance_to(stroke[i])
	return length


func _update_hover(point: Vector2) -> void:
	var map := GameManager.map
	if map == null:
		return
	_hover_position = point
	var marker_id := _pick_marker_at_screen(_world_to_screen(point))
	if marker_id != _hovered_marker:
		_hovered_marker = marker_id
		hovered_marker_changed.emit(marker_id)
		queue_redraw()
	var cell_id := map.cell_at_point(point)
	if cell_id != _hovered:
		_hovered = cell_id
		hovered_cell_changed.emit(cell_id)
		queue_redraw()
	# 同一地块内移动也要刷新 HUD 的“光标处海拔”。
	hover_position_changed.emit(point)
