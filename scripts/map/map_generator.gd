class_name MapGenerator
extends RefCounted
## Voronoi 不规则地块地图生成器。
## 输入一份 JSON 地图配置（见 data/maps/*.json），输出确定性的 MapData。
## 校验失败会递增种子重试；仍失败则使用内置兜底配置。

const DEFAULT_CONFIG := {
	"map_id": "random",
	"name": "无名荒原",
	"description": "临时生成的地图。",
	"seed": 20261023,
	"cell_count": 400,
	"poi_count": 10,
	"bounds": {"x": 190.0, "y": 0.0, "w": 900.0, "h": 720.0},
	"boundary_points": 72,
	"boundary_roughness": 0.12,
	"terrain_weights": {"plain": 1.0, "forest": 1.0, "desert": 1.0},
	"gradient": {"axis": "x", "low": "desert", "high": "forest", "strength": 2.2},
	"elevation": {"frequency": 0.011, "octaves": 3, "max": 4},
	"poi_min_hops": 4,
	"start_goal_margin": 0.22,
	"start_goal_samples": 28,
	"start_goal_min_hops": 14,
	"start_goal_max_hops": 30,
}

const MAX_ATTEMPTS := 12
const FALLBACK_SEED := 20261023
const MAX_PATH_AP_DECI := 1200
const MAX_DEAD_ZONE_RATIO := 0.15
const MIN_TERRAINS := 3
const MIN_CELLS := 150
const MAX_CELLS := 800
const VERTEX_MATCH_EPSILON := 0.8
## 候选站点步长 = 平均间距 × 该系数；配合按密度保留，形成大小不一的地块。
const SITE_STEP_FACTOR := 0.74
const SITE_KEEP_MIN := 0.25
const SITE_KEEP_MAX := 0.80
const SITE_REFINE_PASSES := 2
## 细化时低于/高于平均面积多少倍就移除/拆分。
const CELL_REFINE_MIN_FACTOR := 0.46
const CELL_REFINE_MAX_FACTOR := 2.40
## 最终校验允许的极端面积；超出比例过高则换种子重试。
const CELL_LIMIT_MIN_FACTOR := 0.22
const CELL_LIMIT_MAX_FACTOR := 2.80
const MAX_CELL_AREA_OUTLIER_RATIO := 0.04
## 把相邻 Voronoi 地块合并成凹多边形的概率，以及合并后允许的最大面积。
const CONCAVE_MERGE_CHANCE := 0.36
## 已经合并了两块时，继续吞并第三块的概率（形成更明显的 L/U 形）。
const CONCAVE_THIRD_CELL_CHANCE := 0.28
const CONCAVE_MERGE_MAX_AREA_FACTOR := 2.30
## 地形生长的尝试次数：每次用不同生态种子从中心重新生长，直到出现全部地形。
const TERRAIN_ATTEMPTS := 8
## 地形权重：方向梯度做乘法（保证东西差异压过局部噪声）；
## 相邻同类按“已定型邻格中的占比”放大，形成成片群系而不是椒盐噪点。
const TERRAIN_SAME_NEIGHBOR_BONUS := 0.55
const TERRAIN_DESERT_TO_PLAIN_BONUS := 0.50
const TERRAIN_DESERT_TO_FOREST_PENALTY := 0.35
const TERRAIN_FOREST_TO_PLAIN_BONUS := 0.20
const TERRAIN_PLAIN_TO_DESERT_PENALTY := 0.15


## 生成地图。run_seed 只影响生态/地形分布，不改变地块形状；
## 不传时使用配置种子，保证测试与同配置可复现。
static func generate(config: Dictionary, run_seed: int = 0) -> MapData:
	var cfg := normalize_config(config)
	var requested_seed := int(cfg.get("seed", FALLBACK_SEED))
	var terrain_seed := run_seed if run_seed != 0 else requested_seed
	var last_map: MapData = null
	for attempt in range(MAX_ATTEMPTS):
		var generated_seed := requested_seed + attempt * 7919
		var candidate := _generate_once(cfg, generated_seed, terrain_seed + attempt * 104729)
		candidate.seed_value = requested_seed
		candidate.generated_seed = generated_seed
		last_map = candidate
		if candidate.validation_ok:
			return candidate
	# 兜底：使用内置参数，并继承本次地图请求的角色/事件清单。
	var fallback_cfg := _fallback_config(cfg)
	for attempt in range(MAX_ATTEMPTS):
		var generated_seed := FALLBACK_SEED + attempt * 104729
		var candidate := _generate_once(fallback_cfg, generated_seed, terrain_seed + attempt * 7919)
		candidate.seed_value = requested_seed
		candidate.generated_seed = generated_seed
		last_map = candidate
		if candidate.validation_ok:
			candidate.validation_notes.append("已使用兜底地图配置")
			return candidate
	if last_map != null:
		last_map.validation_notes.append("地图校验未通过，返回最后一次生成结果")
		push_warning("[MapGenerator] 地图校验未通过：%s" % ", ".join(last_map.validation_notes))
	return last_map


static func generate_from_seed(seed_value: int) -> MapData:
	var cfg := DEFAULT_CONFIG.duplicate(true)
	cfg["seed"] = seed_value
	return generate(cfg)


## 读档用：不再重试或回退，直接用存档记录的实际形状种子与生态种子重建同一张地图。
## 存档中的 config 已可能是兜底配置，因此这里必须原样生成，不能再次 generate()。
static func generate_exact(config: Dictionary, generated_seed: int, terrain_seed: int) -> MapData:
	if config.is_empty() or generated_seed == 0 or terrain_seed == 0:
		return null
	var cfg := normalize_config(config)
	var map := _generate_once(cfg, generated_seed, terrain_seed)
	if map != null:
		map.seed_value = int(config.get("seed", map.seed_value))
	return map


static func _fallback_config(source: Dictionary) -> Dictionary:
	var cfg := normalize_config(DEFAULT_CONFIG)
	for key in ["character_ids", "event_ids", "landmark_counts"]:
		if source.has(key):
			cfg[key] = source[key]
	return cfg


static func normalize_config(config: Dictionary) -> Dictionary:
	var cfg := DEFAULT_CONFIG.duplicate(true)
	for key in config.keys():
		cfg[key] = config[key]
	cfg["seed"] = int(cfg.get("seed", FALLBACK_SEED))
	cfg["cell_count"] = clampi(int(cfg.get("cell_count", 288)), MIN_CELLS, MAX_CELLS)
	cfg["poi_count"] = clampi(int(cfg.get("poi_count", 8)), 1, 32)
	cfg["poi_min_hops"] = maxi(1, int(cfg.get("poi_min_hops", 3)))
	cfg["start_goal_min_hops"] = maxi(6, int(cfg.get("start_goal_min_hops", 10)))
	cfg["start_goal_max_hops"] = maxi(int(cfg["start_goal_min_hops"]), int(cfg.get("start_goal_max_hops", 20)))
	if cfg["terrain_weights"] is not Dictionary or cfg["terrain_weights"].is_empty():
		cfg["terrain_weights"] = DEFAULT_CONFIG["terrain_weights"].duplicate(true)
	if cfg["gradient"] is not Dictionary:
		cfg["gradient"] = DEFAULT_CONFIG["gradient"].duplicate(true)
	if cfg["elevation"] is not Dictionary:
		cfg["elevation"] = DEFAULT_CONFIG["elevation"].duplicate(true)
	if cfg["bounds"] is not Dictionary:
		cfg["bounds"] = DEFAULT_CONFIG["bounds"].duplicate(true)
	return cfg


static func _generate_once(cfg: Dictionary, generation_seed: int, terrain_seed: int) -> MapData:
	var map := MapData.new()
	map.map_id = String(cfg.get("map_id", "random"))
	map.map_name = String(cfg.get("name", "无名荒原"))
	map.description = String(cfg.get("description", ""))
	map.config = cfg
	map.bounds = _bounds_from_config(cfg)
	map.seed_value = int(cfg.get("seed", FALLBACK_SEED))
	map.generated_seed = generation_seed
	map.terrain_seed = terrain_seed
	map.poi_ids.clear()
	map.terrain_counts.clear()

	var rng := RandomNumberGenerator.new()
	rng.seed = generation_seed
	map.boundary = _build_boundary(cfg, map.bounds, rng)
	var boundary_area := _polygon_area(map.boundary)
	if boundary_area < 1000.0:
		map.validation_notes.append("地图边界面积过小")
		return map

	var target_count := int(cfg.get("cell_count", 288))
	var spacing := sqrt(boundary_area / float(target_count))
	spacing = clampf(spacing, 15.0, 36.0)
	var sites := _generate_sites(map.boundary, map.bounds, spacing, rng)
	if sites.size() < 120:
		map.validation_notes.append("可放置的站点过少：%d" % sites.size())
		return map

	var base_cells := _build_cells(map.boundary, sites, spacing)
	if base_cells.size() < MIN_CELLS:
		map.validation_notes.append("有效地块过少：%d" % base_cells.size())
		return map
	_build_adjacency(base_cells, spacing)
	var cells := _merge_concave_cells(base_cells, rng)
	if cells.size() < MIN_CELLS:
		map.validation_notes.append("合并后地块过少：%d" % cells.size())
		return map
	map.cells = cells
	map.build_spatial_index()
	_build_adjacency(map.cells, spacing)
	if not _assign_terrain(map, cfg, terrain_seed):
		map.validation_notes.append("地形生长失败：未能生成全部地形")
		return map
	_assign_elevation(map, cfg, rng)
	_build_relief(map, rng)
	_pick_start_goal(map, cfg)
	_place_pois(map, cfg, rng)
	_assign_landmarks(map, cfg)
	_validate(map, cfg)
	return map


static func _bounds_from_config(cfg: Dictionary) -> Rect2:
	var bounds_cfg: Dictionary = cfg.get("bounds", {})
	return Rect2(
		float(bounds_cfg.get("x", 330.0)),
		float(bounds_cfg.get("y", 86.0)),
		float(bounds_cfg.get("w", 620.0)),
		float(bounds_cfg.get("h", 540.0))
	)


## 在矩形内生成一个不规则的凸形海岸线。凸形保证半平面裁剪结果稳定。
static func _build_boundary(cfg: Dictionary, bounds: Rect2, rng: RandomNumberGenerator) -> PackedVector2Array:
	var count := clampi(int(cfg.get("boundary_points", 56)), 18, 120)
	var roughness := clampf(float(cfg.get("boundary_roughness", 0.12)), 0.0, 0.28)
	var center := bounds.get_center()
	var radius_x := bounds.size.x * 0.43
	var radius_y := bounds.size.y * 0.43
	var phase := rng.randf_range(0.0, TAU)
	var raw := PackedVector2Array()
	for i in range(count):
		var angle := TAU * float(i) / float(count)
		var wave := sin(angle * 3.0 + phase) * 0.55
		wave += sin(angle * 5.0 + phase * 1.7) * 0.30
		wave += sin(angle * 7.0 + phase * 2.3) * 0.15
		var factor := 1.0 + roughness * wave
		raw.append(center + Vector2(cos(angle) * radius_x, sin(angle) * radius_y) * factor)
	var hull := Geometry2D.convex_hull(raw)
	var boundary := PackedVector2Array()
	for point in hull:
		if boundary.is_empty() or boundary[boundary.size() - 1].distance_to(point) > 0.01:
			boundary.append(point)
	if boundary.size() >= 2 and boundary[0].distance_to(boundary[boundary.size() - 1]) <= 0.01:
		boundary.remove_at(boundary.size() - 1)
	if boundary.size() < 3:
		boundary = PackedVector2Array([
			bounds.position + Vector2(0, 0),
			bounds.position + Vector2(bounds.size.x, 0),
			bounds.position + Vector2(bounds.size.x, bounds.size.y),
			bounds.position + Vector2(0, bounds.size.y),
		])
	return boundary


static func _generate_sites(boundary: PackedVector2Array, bounds: Rect2, spacing: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var sites := PackedVector2Array()
	var step := spacing * SITE_STEP_FACTOR
	var margin := maxf(4.0, spacing * 0.34)
	var density := FastNoiseLite.new()
	density.seed = int(rng.randi())
	density.frequency = 0.0065
	density.fractal_octaves = 2
	density.fractal_gain = 0.55
	var row := 0
	var y := bounds.position.y + step * 0.5
	while y < bounds.end.y:
		var offset := step * 0.5 if row % 2 == 1 else 0.0
		var x := bounds.position.x + step * 0.5 + offset
		while x < bounds.end.x:
			var point := Vector2(
				x + rng.randf_range(-step * 0.34, step * 0.34),
				y + rng.randf_range(-step * 0.34, step * 0.34)
			)
			if Geometry2D.is_point_in_polygon(point, boundary) and _distance_to_boundary(point, boundary) >= margin:
				# 低频密度噪声决定该区域保留多少站点：
				# 保留得少 → Voronoi 地块变大；保留得多 → 地块变小。
				var raw := density.get_noise_2d(point.x, point.y) * 0.5 + 0.5
				var shaped := raw * raw * (3.0 - 2.0 * raw)
				var keep_chance := lerpf(SITE_KEEP_MIN, SITE_KEEP_MAX, shaped)
				if rng.randf() <= keep_chance:
					sites.append(point)
			x += step
		y += step
		row += 1
	return _refine_site_sizes(boundary, sites, spacing, rng)


## 移除过小的地块站点、拆分过大的地块，最多迭代两轮。
static func _refine_site_sizes(boundary: PackedVector2Array, sites: PackedVector2Array, spacing: float, rng: RandomNumberGenerator) -> PackedVector2Array:
	var current := sites
	for _pass_index in range(SITE_REFINE_PASSES):
		var cells := _build_cells(boundary, current, spacing)
		if cells.is_empty():
			break
		var area_sum := 0.0
		for cell in cells:
			area_sum += cell.area
		var average_area := area_sum / float(cells.size())
		if average_area <= 0.0:
			break
		var min_area := average_area * CELL_REFINE_MIN_FACTOR
		var max_area := average_area * CELL_REFINE_MAX_FACTOR
		var remove_centers: Dictionary = {}
		var additions := PackedVector2Array()
		for cell in cells:
			if cell.area < min_area:
				remove_centers[cell.center] = true
			elif cell.area > max_area and cell.polygon.size() >= 3:
				var centroid := _polygon_centroid(cell.polygon)
				var vertex := cell.polygon[rng.randi_range(0, cell.polygon.size() - 1)]
				var candidate := centroid.lerp(vertex, 0.16)
				if Geometry2D.is_point_in_polygon(candidate, boundary):
					additions.append(candidate)
		if remove_centers.is_empty() and additions.is_empty():
			break
		var refined := PackedVector2Array()
		for site in current:
			if not remove_centers.has(site):
				refined.append(site)
		refined.append_array(additions)
		if refined.size() < 120:
			break
		current = refined
	return current


static func _polygon_centroid(polygon: PackedVector2Array) -> Vector2:
	if polygon.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	for point in polygon:
		total += point
	return total / float(polygon.size())


static func _build_cells(boundary: PackedVector2Array, sites: PackedVector2Array, spacing: float) -> Array[MapData.Cell]:
	var cells: Array[MapData.Cell] = []
	var cutoff := spacing * 4.4
	var cutoff_sq := cutoff * cutoff
	for site_index in range(sites.size()):
		var site := sites[site_index]
		var polygon := boundary.duplicate()
		for other_index in range(sites.size()):
			if other_index == site_index:
				continue
			var other := sites[other_index]
			if site.distance_squared_to(other) > cutoff_sq:
				continue
			var normal := other - site
			var offset := normal.dot((site + other) * 0.5)
			polygon = _clip_halfplane(polygon, normal, offset)
			if polygon.size() < 3:
				break
		polygon = _sanitize_polygon(polygon)
		if polygon.size() < 3 or not _is_polygon_renderable(polygon):
			continue
		var area := _polygon_area(polygon)
		if area < 0.5:
			continue
		var cell := MapData.Cell.new()
		cell.id = cells.size()
		cell.center = site
		cell.polygon = polygon
		cell.bounds = _polygon_bounds(polygon)
		cell.area = area
		cells.append(cell)
	return cells


## 随机把相邻的 Voronoi 地块合并成一块。只接受真正凹的多边形，
## 让地图上同时存在凸/凹地块，而不是全部由 Voronoi 凸块组成。
## 每次可合并 2～3 个相邻块，形成带明显凹角的 L/U 形地块。
static func _merge_concave_cells(cells: Array[MapData.Cell], rng: RandomNumberGenerator) -> Array[MapData.Cell]:
	var area_sum := 0.0
	for cell in cells:
		area_sum += cell.area
	var average_area := area_sum / maxf(float(cells.size()), 1.0)
	var max_combined_area := average_area * CONCAVE_MERGE_MAX_AREA_FACTOR

	var consumed: Dictionary = {}
	var groups: Array[Dictionary] = []
	var order: Array[int] = []
	for i in range(cells.size()):
		order.append(i)
	_shuffle_ints(order, rng)
	for id in order:
		if consumed.has(id):
			continue
		consumed[id] = true
		var cell := cells[id]
		var ids: Array[int] = [id]
		var polygon := cell.polygon
		var total_area := cell.area
		if rng.randf() < CONCAVE_MERGE_CHANCE:
			var neighbor_ids: Array[int] = []
			neighbor_ids.assign(cell.neighbors)
			_shuffle_ints(neighbor_ids, rng)
			for neighbor_id in neighbor_ids:
				if consumed.has(neighbor_id):
					continue
				var other := cells[neighbor_id]
				if total_area + other.area > max_combined_area:
					continue
				var merged := _try_concave_union(polygon, total_area, other)
				if merged.is_empty():
					continue
				polygon = merged
				total_area = _polygon_area(merged)
				ids.append(neighbor_id)
				consumed[neighbor_id] = true
				# 有机会再吞并第三块，形成更深的凹角；否则到此为止。
				if ids.size() >= 3 or total_area > max_combined_area * 0.92:
					break
				if rng.randf() > CONCAVE_THIRD_CELL_CHANCE:
					break
		groups.append({"ids": ids, "polygon": polygon, "area": total_area})

	var result: Array[MapData.Cell] = []
	for group in groups:
		if group.is_empty():
			continue
		var members: Array = group["ids"]
		var main_cell: MapData.Cell = cells[int(members[0])]
		for member_id in members:
			var member: MapData.Cell = cells[int(member_id)]
			if member.area > main_cell.area:
				main_cell = member
		var merged_cell := MapData.Cell.new()
		merged_cell.id = result.size()
		merged_cell.center = main_cell.center
		var polygon: PackedVector2Array = group["polygon"]
		merged_cell.polygon = polygon
		merged_cell.area = _polygon_area(polygon)
		merged_cell.concave = _polygon_is_concave(polygon)
		merged_cell.bounds = _polygon_bounds(polygon)
		result.append(merged_cell)
	return result


## 把一个地块并入现有组：只有合并结果确实为凹、单轮廓、面积未缩水时才接受。
static func _try_concave_union(polygon: PackedVector2Array, current_area: float, other: MapData.Cell) -> PackedVector2Array:
	var union_result := Geometry2D.merge_polygons(polygon, other.polygon)
	if union_result.size() != 1:
		return PackedVector2Array()
	var merged := _sanitize_polygon(union_result[0])
	if merged.size() < 4 or not _is_polygon_renderable(merged):
		return PackedVector2Array()
	if not _polygon_is_concave(merged):
		return PackedVector2Array()
	if _polygon_area(merged) < (current_area + other.area) * 0.96:
		return PackedVector2Array()
	return merged


static func _polygon_bounds(polygon: PackedVector2Array) -> Rect2:
	if polygon.is_empty():
		return Rect2()
	var low := polygon[0]
	var high := polygon[0]
	for point in polygon:
		low.x = minf(low.x, point.x)
		low.y = minf(low.y, point.y)
		high.x = maxf(high.x, point.x)
		high.y = maxf(high.y, point.y)
	return Rect2(low, high - low)


## 判断简单多边形是否有凹角；共线点忽略。
static func _polygon_is_concave(polygon: PackedVector2Array) -> bool:
	var count := polygon.size()
	if count < 4:
		return false
	var orientation := 0
	for i in range(count):
		var a := polygon[i]
		var b := polygon[(i + 1) % count]
		var c := polygon[(i + 2) % count]
		var cross := (b - a).cross(c - b)
		if absf(cross) < 0.001:
			continue
		var current := 1 if cross > 0.0 else -1
		if orientation == 0:
			orientation = current
		elif current != orientation:
			return true
	return false


static func _clip_halfplane(polygon: PackedVector2Array, normal: Vector2, offset: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	var count := polygon.size()
	if count == 0:
		return result
	for i in range(count):
		var a := polygon[i]
		var b := polygon[(i + 1) % count]
		var da := normal.dot(a) - offset
		var db := normal.dot(b) - offset
		var a_inside := da <= 0.0001
		var b_inside := db <= 0.0001
		if a_inside:
			result.append(a)
		if a_inside != b_inside:
			var denominator := da - db
			if absf(denominator) > 0.000001:
				var t := da / denominator
				result.append(a.lerp(b, clampf(t, 0.0, 1.0)))
	return result


static func _clean_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in polygon:
		if result.is_empty() or result[result.size() - 1].distance_to(point) > 0.01:
			result.append(point)
	if result.size() >= 2 and result[0].distance_to(result[result.size() - 1]) <= 0.01:
		result.remove_at(result.size() - 1)
	return result


## 合并后的多边形可能带有几乎重合或几乎共线的点；Godot 的三角化会直接失败。
## 这里反复剔除过短边与近乎共线的顶点，确保后续 draw_polygon 稳定。
static func _sanitize_polygon(polygon: PackedVector2Array) -> PackedVector2Array:
	var result := _clean_polygon(polygon)
	if result.size() < 3:
		return result
	var changed := true
	while changed and result.size() > 3:
		changed = false
		for i in range(result.size()):
			var count := result.size()
			var prev := result[(i - 1 + count) % count]
			var current := result[i]
			var next := result[(i + 1) % count]
			if current.distance_to(prev) < 0.5 or current.distance_to(next) < 0.5:
				result.remove_at(i)
				changed = true
				break
			if _distance_point_to_segment(current, prev, next) < 0.35:
				result.remove_at(i)
				changed = true
				break
	return _clean_polygon(result)


static func _distance_point_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var span := b - a
	var length_sq := span.length_squared()
	if length_sq < 0.000001:
		return point.distance_to(a)
	var t := clampf((point - a).dot(span) / length_sq, 0.0, 1.0)
	return point.distance_to(a + span * t)


## Godot 只会绘制能被三角化的简单多边形；不能三角化的一律视为无效地块。
static func _is_polygon_renderable(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return false
	if _polygon_area(polygon) < 0.5:
		return false
	return not Geometry2D.triangulate_polygon(polygon).is_empty()


static func _build_adjacency(cells: Array[MapData.Cell], spacing: float) -> void:
	var max_distance := spacing * 4.5
	var max_distance_sq := max_distance * max_distance
	var epsilon_sq := VERTEX_MATCH_EPSILON * VERTEX_MATCH_EPSILON
	for i in range(cells.size()):
		cells[i].neighbors.clear()
	for i in range(cells.size()):
		var a := cells[i]
		for j in range(i + 1, cells.size()):
			var b := cells[j]
			if a.center.distance_squared_to(b.center) > max_distance_sq:
				continue
			var shared := 0
			for vertex_a in a.polygon:
				for vertex_b in b.polygon:
					if vertex_a.distance_squared_to(vertex_b) <= epsilon_sq:
						shared += 1
						break
			if shared >= 2:
				a.neighbors.append(b.id)
				b.neighbors.append(a.id)


## 从地图中心开始生长生态：中心格随机定类型，之后按 BFS 逐格选择地形。
## 权重 = 基础权重 + 方向梯度 + 已定型邻格的影响，因此东侧更易森林/平原，
## 西侧更易沙漠，且沙漠边上的森林会被压制成平原过渡带。
## 同一个地块形状可用不同 terrain_seed 反复生长，得到不同的生态分布。
static func _assign_terrain(map: MapData, cfg: Dictionary, terrain_seed: int) -> bool:
	var base_weights: Dictionary = cfg.get("terrain_weights", {})
	var terrain_keys: Array[String] = []
	for key in base_weights.keys():
		var terrain_id := String(key)
		if DataManager.has_record("terrains", terrain_id):
			terrain_keys.append(terrain_id)
	if terrain_keys.is_empty():
		terrain_keys = ["plain", "forest", "desert"]
	terrain_keys.sort()
	var gradient: Dictionary = cfg.get("gradient", {})
	var gradient_axis := String(gradient.get("axis", "x"))
	var gradient_low := String(gradient.get("low", "desert"))
	var gradient_high := String(gradient.get("high", "forest"))
	var gradient_strength := float(gradient.get("strength", 2.2))
	var center_id := _nearest_cell(map.cells, map.bounds.get_center())
	var required_count := maxi(2, int(float(map.cells.size()) * 0.02))

	for attempt in range(TERRAIN_ATTEMPTS):
		var attempt_seed := terrain_seed + attempt * 104729
		var rng := RandomNumberGenerator.new()
		rng.seed = attempt_seed
		for cell in map.cells:
			cell.terrain = ""
		map.terrain_counts.clear()

		var visited: Dictionary = {center_id: true}
		var chosen: Dictionary = {}
		var queue: Array[int] = [center_id]
		var cursor := 0
		while cursor < queue.size():
			var cell_id := queue[cursor]
			cursor += 1
			var cell := map.cells[cell_id]
			cell.terrain = _choose_terrain(
				cell, map, terrain_keys, base_weights, gradient_axis,
				gradient_low, gradient_high, gradient_strength, chosen, rng
			)
			chosen[cell_id] = true
			map.terrain_counts[cell.terrain] = int(map.terrain_counts.get(cell.terrain, 0)) + 1
			for neighbor_id in cell.neighbors:
				if visited.has(neighbor_id):
					continue
				visited[neighbor_id] = true
				queue.append(neighbor_id)

		var varied := true
		for terrain_id in terrain_keys:
			if int(map.terrain_counts.get(terrain_id, 0)) < required_count:
				varied = false
				break
		if varied:
			map.terrain_seed = attempt_seed
			return true

	# 极端情况下强制补全缺失地形，避免整张地图只有一两种生态。
	_force_terrain_variety(map, terrain_keys, gradient_axis, gradient_low, gradient_high)
	map.terrain_seed = terrain_seed
	for terrain_id in terrain_keys:
		if int(map.terrain_counts.get(terrain_id, 0)) < 1:
			return false
	return map.terrain_counts.size() >= 3


static func _choose_terrain(
	cell: MapData.Cell,
	map: MapData,
	terrain_keys: Array[String],
	base_weights: Dictionary,
	gradient_axis: String,
	gradient_low: String,
	gradient_high: String,
	gradient_strength: float,
	chosen: Dictionary,
	rng: RandomNumberGenerator
) -> String:
	var bounds := map.bounds
	var nx := clampf((cell.center.x - bounds.position.x) / maxf(bounds.size.x, 1.0), 0.0, 1.0)
	var ny := clampf((cell.center.y - bounds.position.y) / maxf(bounds.size.y, 1.0), 0.0, 1.0)
	var t := nx if gradient_axis == "x" else ny
	var neighbor_terrains: Array[String] = []
	for neighbor_id in cell.neighbors:
		if not chosen.has(neighbor_id):
			continue
		neighbor_terrains.append(map.cells[neighbor_id].terrain)
	var neighbor_total := float(neighbor_terrains.size())
	var terrain_neighbor_counts: Dictionary = {}
	for neighbor_terrain in neighbor_terrains:
		terrain_neighbor_counts[neighbor_terrain] = int(terrain_neighbor_counts.get(neighbor_terrain, 0)) + 1
	var desert_fraction := float(terrain_neighbor_counts.get("desert", 0)) / maxf(neighbor_total, 1.0)
	var forest_fraction := float(terrain_neighbor_counts.get("forest", 0)) / maxf(neighbor_total, 1.0)
	var plain_fraction := float(terrain_neighbor_counts.get("plain", 0)) / maxf(neighbor_total, 1.0)
	var center_bump := 1.0 - absf(t * 2.0 - 1.0)

	var weights: Array[float] = []
	var total := 0.0
	for terrain_id in terrain_keys:
		var weight := float(base_weights.get(terrain_id, 1.0)) * rng.randf_range(0.90, 1.10)
		# 方向梯度做乘法：越靠西，沙漠倍率越高；越靠东，森林倍率越高。
		# 倍率增长快于邻格同类加成，保证大方向压过局部成团。
		if terrain_id == gradient_low:
			weight *= 1.0 + gradient_strength * 2.4 * pow(1.0 - t, 1.7)
		if terrain_id == gradient_high:
			weight *= 1.0 + gradient_strength * 2.4 * pow(t, 1.7)
		if terrain_id == "plain":
			# 平原在低/高地形之间自然形成过渡带。
			weight *= 1.0 + gradient_strength * 1.8 * pow(center_bump, 1.2)
		# 相邻已定型地块的影响：同类邻格越多越容易成片；
		# 沙漠/森林之间则由草原过渡。
		var same_count := float(terrain_neighbor_counts.get(terrain_id, 0))
		weight *= 1.0 + TERRAIN_SAME_NEIGHBOR_BONUS * same_count
		if terrain_id == "plain":
			weight *= 1.0 + TERRAIN_DESERT_TO_PLAIN_BONUS * desert_fraction
			weight *= 1.0 + TERRAIN_FOREST_TO_PLAIN_BONUS * forest_fraction
		if terrain_id == "forest":
			weight *= maxf(0.2, 1.0 - TERRAIN_DESERT_TO_FOREST_PENALTY * desert_fraction)
		if terrain_id == "desert":
			weight *= maxf(0.2, 1.0 - TERRAIN_PLAIN_TO_DESERT_PENALTY * plain_fraction)
		weight = maxf(weight, 0.01)
		weights.append(weight)
		total += weight

	var roll := rng.randf() * total
	var chosen_terrain := terrain_keys[0]
	for index in range(terrain_keys.size()):
		roll -= weights[index]
		if roll <= 0.0:
			chosen_terrain = terrain_keys[index]
			break
	return chosen_terrain


static func _force_terrain_variety(map: MapData, terrain_keys: Array[String], gradient_axis: String, gradient_low: String, gradient_high: String) -> void:
	map.terrain_counts.clear()
	for cell in map.cells:
		map.terrain_counts[cell.terrain] = int(map.terrain_counts.get(cell.terrain, 0)) + 1
	for terrain_id in terrain_keys:
		if int(map.terrain_counts.get(terrain_id, 0)) > 0:
			continue
		var target_t := 0.5
		if terrain_id == gradient_low:
			target_t = 0.0
		elif terrain_id == gradient_high:
			target_t = 1.0
		var best_cell: MapData.Cell = null
		var best_distance := INF
		for cell in map.cells:
			var nx := clampf((cell.center.x - map.bounds.position.x) / maxf(map.bounds.size.x, 1.0), 0.0, 1.0)
			var ny := clampf((cell.center.y - map.bounds.position.y) / maxf(map.bounds.size.y, 1.0), 0.0, 1.0)
			var t := nx if gradient_axis == "x" else ny
			var distance := absf(t - target_t)
			if distance < best_distance:
				best_distance = distance
				best_cell = cell
		if best_cell != null:
			var previous := best_cell.terrain
			best_cell.terrain = terrain_id
			map.terrain_counts[terrain_id] = int(map.terrain_counts.get(terrain_id, 0)) + 1
			map.terrain_counts[previous] = maxi(0, int(map.terrain_counts.get(previous, 1)) - 1)


static func _assign_elevation(map: MapData, cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var elevation_cfg: Dictionary = cfg.get("elevation", {})
	var noise := FastNoiseLite.new()
	noise.seed = int(rng.randi())
	noise.frequency = float(elevation_cfg.get("frequency", 0.011))
	noise.fractal_octaves = clampi(int(elevation_cfg.get("octaves", 3)), 1, 6)
	var max_elevation := clampi(int(elevation_cfg.get("max", 4)), 1, 6)
	for cell in map.cells:
		var value := noise.get_noise_2d(cell.center.x, cell.center.y)
		var normalized := clampf(value * 0.5 + 0.5, 0.0, 1.0)
		cell.elevation = int(round(normalized * float(max_elevation)))


## 为渲染生成“格内起伏”：顶点高度取本格与共享该顶点的邻格平均海拔，
## 叠加连续细节噪声；每条边再插入一个中点，使多边形内部不是一整块纯色。
## 规则结算仍使用 cell.elevation 与 move_cost_deci，不受渲染海拔影响。
static func _build_relief(map: MapData, rng: RandomNumberGenerator) -> void:
	var detail := FastNoiseLite.new()
	detail.seed = int(rng.randi())
	detail.frequency = 0.030
	detail.fractal_octaves = 2
	detail.fractal_gain = 0.5

	for cell in map.cells:
		var count := cell.polygon.size()
		if count < 3:
			continue
		var vertex_heights := PackedFloat32Array()
		vertex_heights.resize(count)
		for i in range(count):
			vertex_heights[i] = _relief_vertex_height(map, cell, cell.polygon[i], detail)
		var ring := PackedVector2Array()
		var heights := PackedFloat32Array()
		var low := INF
		var high := -INF
		for i in range(count):
			var a := cell.polygon[i]
			var b := cell.polygon[(i + 1) % count]
			var ha := vertex_heights[i]
			var hb := vertex_heights[(i + 1) % count]
			var mid := (a + b) * 0.5
			var hm := (ha + hb) * 0.5 + detail.get_noise_2d(mid.x, mid.y) * 0.35
			ring.append(a)
			heights.append(ha)
			ring.append(mid)
			heights.append(hm)
			low = minf(low, ha)
			low = minf(low, hm)
			high = maxf(high, ha)
			high = maxf(high, hm)
		cell.relief_polygon = ring
		cell.relief_heights = heights
		cell.elevation_samples = heights.duplicate()
		if not _is_polygon_renderable(ring):
			# 极少数退化地块：退回“多边形顶点 + 顶点高度”，仍保持采样与渲染对齐。
			ring = cell.polygon.duplicate()
			heights = vertex_heights.duplicate()
			cell.relief_polygon = ring
			cell.relief_heights = heights
			cell.elevation_samples = heights.duplicate()
			low = INF
			high = -INF
			for value in heights:
				low = minf(low, value)
				high = maxf(high, value)
		cell.relief_min = low
		cell.relief_max = high
		var height_sum := 0.0
		for value in heights:
			height_sum += value
		cell.elevation_mean = height_sum / float(heights.size()) if not heights.is_empty() else float(cell.elevation)


static func _relief_vertex_height(map: MapData, cell: MapData.Cell, vertex: Vector2, detail: FastNoiseLite) -> float:
	var total := float(cell.elevation)
	var count := 1
	for neighbor_id in cell.neighbors:
		var neighbor := map.get_cell(neighbor_id)
		if neighbor == null:
			continue
		for neighbor_vertex in neighbor.polygon:
			if neighbor_vertex.distance_squared_to(vertex) <= 1.0:
				total += float(neighbor.elevation)
				count += 1
				break
	var average := total / float(count)
	return average + detail.get_noise_2d(vertex.x, vertex.y) * 0.55


static func _pick_start_goal(map: MapData, cfg: Dictionary) -> void:
	if cfg.has("start_norm") and cfg.has("goal_norm"):
		var start_point := _norm_to_world(map.bounds, cfg["start_norm"])
		var goal_point := _norm_to_world(map.bounds, cfg["goal_norm"])
		map.start_id = _nearest_cell(map.cells, start_point)
		map.goal_id = _nearest_cell(map.cells, goal_point)
	else:
		# 起终点都从内陆候选里挑，不再固定在边界两角。
		# 先随机取内陆起点，再从 BFS 距离符合配置的格子里挑离起点最远的一个。
		var pair := _pick_interior_pair(map, cfg)
		if pair.size() == 2:
			map.start_id = pair[0]
			map.goal_id = pair[1]
		else:
			map.start_id = _extreme_cell(map.cells, map.bounds, false)
			map.goal_id = _extreme_cell(map.cells, map.bounds, true)
	if map.start_id == map.goal_id:
		map.validation_notes.append("起点与终点重合")


## 在内陆区域采样起点，并选一个 BFS 距离合法的远点作终点。
## 返回 [start_id, goal_id]；采样失败时返回空数组，由调用方兜底。
static func _pick_interior_pair(map: MapData, cfg: Dictionary) -> Array[int]:
	var bounds := map.bounds
	var margin := clampf(float(cfg.get("start_goal_margin", 0.22)), 0.0, 0.36)
	var min_hops := int(cfg.get("start_goal_min_hops", 10))
	var max_hops := int(cfg.get("start_goal_max_hops", 20))
	var attempts := clampi(int(cfg.get("start_goal_samples", 28)), 8, 80)
	var boundary_margin := minf(bounds.size.x, bounds.size.y) * 0.075
	var rng := RandomNumberGenerator.new()
	rng.seed = int(map.generated_seed) ^ 0x5EC7A11
	var best_pair: Array[int] = []
	var best_score := -INF
	for _attempt in range(attempts):
		var point := bounds.position + Vector2(
			rng.randf_range(margin, 1.0 - margin) * bounds.size.x,
			rng.randf_range(margin, 1.0 - margin) * bounds.size.y
		)
		var start_id := _nearest_cell(map.cells, point)
		var start_cell := map.get_cell(start_id)
		if start_cell == null:
			continue
		if _distance_to_boundary(start_cell.center, map.boundary) < boundary_margin:
			continue
		var depths := _bfs_depths(map, start_id)
		for cell in map.cells:
			if cell.id == start_id:
				continue
			var depth := int(depths.get(cell.id, -1))
			if depth < min_hops or depth > max_hops:
				continue
			if _distance_to_boundary(cell.center, map.boundary) < boundary_margin:
				continue
			# 优先挑 BFS 距离长、同时在世界坐标里也拉得开的组合。
			var score := start_cell.center.distance_squared_to(cell.center) + float(depth) * 600.0
			if score > best_score:
				best_score = score
				best_pair = [start_id, cell.id]
	return best_pair


static func _bfs_depths(map: MapData, from_id: int) -> Dictionary:
	var depths: Dictionary = {from_id: 0}
	var frontier := PackedInt32Array([from_id])
	var depth := 0
	while not frontier.is_empty():
		depth += 1
		var next := PackedInt32Array()
		for current in frontier:
			for neighbor in map.neighbors_of(current):
				if depths.has(neighbor):
					continue
				depths[neighbor] = depth
				next.append(neighbor)
		frontier = next
	return depths


static func _norm_to_world(bounds: Rect2, value) -> Vector2:
	if value is Array and value.size() >= 2:
		return bounds.position + Vector2(float(value[0]), float(value[1])) * bounds.size
	if value is Dictionary:
		return bounds.position + Vector2(float(value.get("x", 0.15)), float(value.get("y", 0.85))) * bounds.size
	if value is Vector2:
		return bounds.position + value * bounds.size
	return bounds.get_center()


static func _extreme_cell(cells: Array[MapData.Cell], bounds: Rect2, goal: bool) -> int:
	var best_id := -1
	var best_score := INF
	for cell in cells:
		# 凹地块的中心可能不在极端位置，按实际轮廓的最远顶点评分。
		for point in cell.polygon:
			var nx := (point.x - bounds.position.x) / maxf(bounds.size.x, 1.0)
			var ny := (point.y - bounds.position.y) / maxf(bounds.size.y, 1.0)
			var score := 0.0
			if goal:
				score = (1.0 - nx) + ny * 0.75
			else:
				score = nx + (1.0 - ny) * 0.75
			if score < best_score:
				best_score = score
				best_id = cell.id
	return best_id


static func _nearest_cell(cells: Array[MapData.Cell], point: Vector2) -> int:
	var best_id := -1
	var best_distance := INF
	for cell in cells:
		var distance := point.distance_squared_to(cell.center)
		if distance < best_distance:
			best_distance = distance
			best_id = cell.id
	return best_id


static func _place_pois(map: MapData, cfg: Dictionary, rng: RandomNumberGenerator) -> void:
	var target := int(cfg.get("poi_count", 8))
	var min_hops := int(cfg.get("poi_min_hops", 3))
	var candidates: Array[int] = []
	for cell in map.cells:
		if cell.id == map.start_id or cell.id == map.goal_id:
			continue
		candidates.append(cell.id)
	_shuffle_ints(candidates, rng)
	for candidate_id in candidates:
		if map.poi_ids.size() >= target:
			break
		if map.graph_distance(map.start_id, candidate_id) < min_hops:
			continue
		if map.graph_distance(map.goal_id, candidate_id) < min_hops:
			continue
		var valid := true
		for poi_id in map.poi_ids:
			if map.graph_distance(poi_id, candidate_id) < min_hops:
				valid = false
				break
		if not valid:
			continue
		map.poi_ids.append(candidate_id)
		var cell := map.get_cell(candidate_id)
		if cell != null:
			cell.poi_id = "poi_%02d" % map.poi_ids.size()


static func _shuffle_ints(values: Array[int], rng: RandomNumberGenerator) -> void:
	for i in range(values.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := values[i]
		values[i] = values[j]
		values[j] = tmp


## 在 POI 放置完成后分配检查点/商店/旅店。
## 使用独立随机流，绝不调用写入主 rng 的随机数，避免改变既有地图的 POI 布局。
static func _assign_landmarks(map: MapData, cfg: Dictionary) -> void:
	var counts = cfg.get("landmark_counts", {})
	if typeof(counts) != TYPE_DICTIONARY or (counts as Dictionary).is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("landmark|%s|%d|%d" % [map.map_id, map.generated_seed, map.terrain_seed])
	var pool := map.poi_ids.duplicate()
	_shuffle_ints(pool, rng)
	var type_ids: Array[String] = []
	for raw_id in (counts as Dictionary).keys():
		type_ids.append(String(raw_id))
	type_ids.sort()
	var cursor := 0
	for landmark_id in type_ids:
		var count := maxi(0, int((counts as Dictionary).get(landmark_id, 0)))
		for _i in range(count):
			if cursor >= pool.size():
				return
			var cell := map.get_cell(pool[cursor])
			cursor += 1
			if cell != null:
				cell.landmark_id = landmark_id


static func _validate(map: MapData, cfg: Dictionary) -> void:
	map.validation_notes.clear()
	if map.cells.size() < MIN_CELLS or map.cells.size() > MAX_CELLS:
		map.validation_notes.append("地块数量异常：%d" % map.cells.size())
	if map.start_id < 0 or map.goal_id < 0:
		map.validation_notes.append("缺少起点或终点")
		map.validation_ok = false
		return
	if map.terrain_counts.size() < MIN_TERRAINS:
		map.validation_notes.append("地形种类不足：%d" % map.terrain_counts.size())
	if not map.cells.is_empty():
		var area_sum := 0.0
		for cell in map.cells:
			area_sum += cell.area
		var average_area := area_sum / float(map.cells.size())
		if average_area > 0.0:
			var area_outliers := 0
			for cell in map.cells:
				if cell.area < average_area * CELL_LIMIT_MIN_FACTOR or cell.area > average_area * CELL_LIMIT_MAX_FACTOR:
					area_outliers += 1
			if area_outliers > maxi(1, int(float(map.cells.size()) * MAX_CELL_AREA_OUTLIER_RATIO)):
				map.validation_notes.append("地块面积异常：%d / %d" % [area_outliers, map.cells.size()])
	var isolated := 0
	for cell in map.cells:
		if cell.neighbors.size() < 2:
			isolated += 1
	if isolated > 0:
		map.validation_notes.append("边缘/孤立地块：%d" % isolated)
	var reachable_count := _reachable_count(map, map.start_id)
	if reachable_count < map.cells.size():
		map.validation_notes.append("存在不可达地块：%d / %d" % [reachable_count, map.cells.size()])
	var hops := map.graph_distance(map.start_id, map.goal_id)
	var min_hops := int(cfg.get("start_goal_min_hops", 10))
	var max_hops := int(cfg.get("start_goal_max_hops", 20))
	if hops < min_hops or hops > max_hops:
		map.validation_notes.append("起终点 BFS 距离 %d，不在 %d～%d 格" % [hops, min_hops, max_hops])
	var reachable := map.reachable_cells(map.start_id, MAX_PATH_AP_DECI, null)
	var goal_cost := int(reachable.get(map.goal_id, -1))
	if goal_cost < 0:
		map.validation_notes.append("起终点在 %d AP 内不可达" % (MAX_PATH_AP_DECI / 10))
	var dead_ratio := 1.0 - float(reachable.size()) / maxf(float(map.cells.size()), 1.0)
	if dead_ratio > MAX_DEAD_ZONE_RATIO:
		map.validation_notes.append("AP 死区 %.0f%%，超过 %.0f%%" % [dead_ratio * 100.0, MAX_DEAD_ZONE_RATIO * 100.0])
	var desired_pois := int(cfg.get("poi_count", 8))
	if map.poi_ids.size() != desired_pois:
		map.validation_notes.append("POI 数量 %d / %d" % [map.poi_ids.size(), desired_pois])
	map.validation_ok = map.validation_notes.is_empty()


static func _reachable_count(map: MapData, from_id: int) -> int:
	var visited: Dictionary = {from_id: true}
	var frontier := PackedInt32Array([from_id])
	while not frontier.is_empty():
		var next := PackedInt32Array()
		for current in frontier:
			for neighbor in map.neighbors_of(current):
				if visited.has(neighbor):
					continue
				visited[neighbor] = true
				next.append(neighbor)
		frontier = next
	return visited.size()


static func _distance_to_boundary(point: Vector2, boundary: PackedVector2Array) -> float:
	var result := INF
	var count := boundary.size()
	for i in range(count):
		var a := boundary[i]
		var b := boundary[(i + 1) % count]
		var closest := Geometry2D.get_closest_point_to_segment(point, a, b)
		result = minf(result, point.distance_to(closest))
	return result


static func _polygon_area(polygon: PackedVector2Array) -> float:
	if polygon.size() < 3:
		return 0.0
	var area := 0.0
	for i in range(polygon.size()):
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		area += a.x * b.y - b.x * a.y
	return absf(area) * 0.5
