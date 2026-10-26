class_name MapData
extends RefCounted
## 一局游戏的地图数据：Voronoi 不规则地块、邻接关系与移动消耗规则。
## 地块坐标一律使用世界坐标（像素），渲染层不再自行换算六边形。

## 迷雾状态：未知 / 曾获得信息（走过或侦察过，但当前不在视野）/ 当前可见。
## 渲染时当前视野是一条圆形边界，只有圆内区域最亮；边缘地块会被圆切开。
enum FogState { UNKNOWN, REMEMBERED, VISIBLE }

class Cell:
	var id: int = -1
	var center: Vector2 = Vector2.ZERO
	var polygon: PackedVector2Array = PackedVector2Array()
	## 多边形包围盒；用于快速筛掉不可能包含光标的地块。
	var bounds: Rect2 = Rect2()
	## 地块面积（像素²），由生成器填充；用于检查大小分布。
	var area: float = 0.0
	## 是否为凹多边形（由相邻 Voronoi 地块合并而成）。
	var concave: bool = false
	var terrain: String = "plain"
	var elevation: int = 0
	var poi_id: String = ""
	var neighbors: Array[int] = []
	## 迷雾：曾经进入玩家当前视野（被动视野或侦察）。
	var seen: bool = false
	## 迷雾：被主动侦察揭示过；离开视野后仍算“曾获得信息”。
	var scouted: bool = false
	## 迷雾：玩家实际踏足过；离开视野后仍保留记忆。
	var entered: bool = false
	## 是否已知该格 POI 的位置（进入或被事件/侦察揭示）。
	var poi_known: bool = false
	## 渲染用：多边形顶点 + 每条边的中点，配合 relief_heights 形成格内连续起伏。
	var relief_polygon: PackedVector2Array = PackedVector2Array()
	var relief_heights: PackedFloat32Array = PackedFloat32Array()
	## 格内高程采样点（与 relief_polygon 对齐）；规则结算仍使用整数 elevation。
	var elevation_samples: PackedFloat32Array = PackedFloat32Array()
	var elevation_mean: float = 0.0
	## 渲染海拔范围；规则结算仍使用整数 elevation。
	var relief_min: float = 0.0
	var relief_max: float = 0.0

var map_id: String = ""
var map_name: String = ""
var description: String = ""
var config: Dictionary = {}
var bounds: Rect2 = Rect2()
var boundary: PackedVector2Array = PackedVector2Array()
## 玩家输入的种子（对外展示；决定地块形状）。
var seed_value: int = 0
## 实际用于生成地图形状的种子（校验失败时会递增，可能不同于 seed_value）。
var generated_seed: int = 0
## 本局生态/地形分布的种子；同形状地图每次开局可不同。
var terrain_seed: int = 0
var cells: Array[Cell] = []
var start_id: int = -1
var goal_id: int = -1
var poi_ids: Array[int] = []
## 当前视野中心与半径（世界像素）。渲染层可按显示半径做平滑收缩；规则层用目标半径重建 current_vision。
var vision_center: Vector2 = Vector2.ZERO
var vision_radius_world: float = 0.0
## 当前视野内的地块中心（每次玩家移动/侦察/回合收缩后重建）。
var current_vision: Dictionary = {}
## 地块中心的平均最近邻距离；用于把“侦察 +N 格”换算成世界半径。
var average_site_spacing: float = 24.0
## 与地块数量等效的平均格径 sqrt(面积 / 格数)；用于基础视野半径。
var average_cell_size: float = 40.0
var terrain_counts: Dictionary = {}
var validation_ok: bool = false
var validation_notes: Array[String] = []
## 每个地块的中心点（保证落在该地块内部），供标记、起点与调试使用。
var sites: PackedVector2Array = PackedVector2Array()
## 地块中心的空间哈希，供需要“最近中心”的逻辑使用。
var _site_buckets: Dictionary = {}
var _bucket_size: float = 64.0


func build_spatial_index() -> void:
	sites.clear()
	_site_buckets.clear()
	average_cell_size = sqrt(maxf(bounds.get_area(), 1.0) / maxf(float(cells.size()), 1.0))
	_bucket_size = maxf(24.0, average_cell_size * 1.5)
	for cell in cells:
		sites.append(cell.center)
		var key := _bucket_key(cell.center)
		if not _site_buckets.has(key):
			_site_buckets[key] = PackedInt32Array()
		var bucket: PackedInt32Array = _site_buckets[key]
		bucket.append(cell.id)
		_site_buckets[key] = bucket
	# 最近邻平均距离：O(n²)，开局只算一次，供侦察扩张半径使用。
	var spacing_total := 0.0
	for i in range(cells.size()):
		var nearest := INF
		for j in range(cells.size()):
			if i == j:
				continue
			nearest = minf(nearest, cells[i].center.distance_to(cells[j].center))
		if nearest < INF:
			spacing_total += nearest
	if not cells.is_empty():
		average_site_spacing = maxf(8.0, spacing_total / float(cells.size()))


func _bucket_key(point: Vector2) -> Vector2i:
	return Vector2i(int(floor(point.x / _bucket_size)), int(floor(point.y / _bucket_size)))


func cell_count() -> int:
	return cells.size()


func get_cell(cell_id: int) -> Cell:
	if cell_id < 0 or cell_id >= cells.size():
		return null
	return cells[cell_id]


func cell_center(cell_id: int) -> Vector2:
	var cell := get_cell(cell_id)
	return cell.center if cell != null else Vector2.ZERO


func terrain_of(cell_id: int) -> String:
	var cell := get_cell(cell_id)
	return cell.terrain if cell != null else ""


func elevation_of(cell_id: int) -> int:
	var cell := get_cell(cell_id)
	return cell.elevation if cell != null else 0


func elevation_range_of(cell_id: int) -> Vector2:
	var cell := get_cell(cell_id)
	if cell == null or cell.elevation_samples.is_empty():
		return Vector2.ZERO
	return Vector2(cell.relief_min, cell.relief_max)


## 格内任意一点的高程估计：对格内采样点做反距离加权。
## 移动按实际路径逐段计费，会用这个连续高程计算爬升；展示悬停也使用同一函数。
func elevation_at(cell_id: int, point: Vector2) -> float:
	var cell := get_cell(cell_id)
	if cell == null:
		return 0.0
	var sample_count := mini(cell.elevation_samples.size(), cell.relief_polygon.size())
	if sample_count == 0:
		return float(cell.elevation)
	var total_weight := 0.0
	var weighted_sum := 0.0
	for i in range(sample_count):
		var distance_sq := point.distance_squared_to(cell.relief_polygon[i])
		var weight := 1.0 / (distance_sq + 4.0)
		total_weight += weight
		weighted_sum += cell.elevation_samples[i] * weight
	if total_weight <= 0.0:
		return cell.elevation_mean
	return weighted_sum / total_weight


func poi_of(cell_id: int) -> String:
	var cell := get_cell(cell_id)
	return cell.poi_id if cell != null else ""


## 三态迷雾：
## - 当前视野：最亮；
## - 曾经走过/侦察/看见过，但现在不在视野：记住的地形，亮度居中；
## - 其余：黑色未知。
## 注意：这里以“地块中心是否在圆内”判定当前视野；边缘被圆切开的部分由渲染层处理。
func fog_state(cell_id: int) -> int:
	var cell := get_cell(cell_id)
	if cell == null:
		return FogState.UNKNOWN
	if current_vision.has(cell_id):
		return FogState.VISIBLE
	if cell.seen or cell.scouted or cell.entered:
		return FogState.REMEMBERED
	return FogState.UNKNOWN


func is_cell_known(cell_id: int) -> bool:
	var cell := get_cell(cell_id)
	return cell != null and (cell.seen or cell.scouted or cell.entered)


func is_in_current_vision(cell_id: int) -> bool:
	return current_vision.has(cell_id)


## 供悬停与标记使用：判断任意世界坐标是否落在当前显示视野圆内。
func is_point_in_current_vision(point: Vector2) -> bool:
	return vision_radius_world > 0.0 and point.distance_to(vision_center) <= vision_radius_world


## 地块是否被当前视野圆切到（哪怕中心在圆外）。用于测试与边缘渲染判断。
func cell_intersects_vision(cell_id: int) -> bool:
	var cell := get_cell(cell_id)
	if cell == null or vision_radius_world <= 0.0:
		return false
	if cell.center.distance_to(vision_center) <= vision_radius_world:
		return true
	if Geometry2D.is_point_in_polygon(vision_center, cell.polygon):
		return true
	var count := cell.polygon.size()
	for i in range(count):
		var a := cell.polygon[i]
		var b := cell.polygon[(i + 1) % count]
		var closest := Geometry2D.get_closest_point_to_segment(vision_center, a, b)
		if closest.distance_to(vision_center) <= vision_radius_world:
			return true
	return false


func is_poi_known(cell_id: int) -> bool:
	var cell := get_cell(cell_id)
	return cell != null and cell.poi_known


func mark_cell_entered(cell_id: int) -> void:
	var cell := get_cell(cell_id)
	if cell == null:
		return
	cell.seen = true
	cell.entered = true
	if not cell.poi_id.is_empty():
		cell.poi_known = true


func mark_poi_known(cell_id: int) -> void:
	var cell := get_cell(cell_id)
	if cell != null:
		cell.poi_known = true


func is_inside_boundary(point: Vector2) -> bool:
	return boundary.size() >= 3 and Geometry2D.is_point_in_polygon(point, boundary)


## 找到包含该点的地块。合并后的地块可能是凹多边形，
## 因此不能再用“离中心最近”判断，必须做点在多边形内测试。
func cell_at_point(point: Vector2) -> int:
	if not is_inside_boundary(point):
		return -1
	for cell in cells:
		if cell.bounds.size.x > 0.0 and not cell.bounds.has_point(point):
			continue
		if Geometry2D.is_point_in_polygon(point, cell.polygon):
			return cell.id
	# 边界/浮点误差兜底：正常情况下不会走到这里。
	var best_id: int = -1
	var best_distance: float = INF
	for cell in cells:
		var distance := point.distance_squared_to(cell.center)
		if distance < best_distance:
			best_distance = distance
			best_id = cell.id
	return best_id


func neighbors_of(cell_id: int) -> Array[int]:
	var result: Array[int] = []
	var cell := get_cell(cell_id)
	if cell == null:
		return result
	for neighbor_id in _neighbor_table().get(cell_id, PackedInt32Array()):
		result.append(int(neighbor_id))
	return result


func are_adjacent(a: int, b: int) -> bool:
	var bucket: PackedInt32Array = _neighbor_table().get(a, PackedInt32Array())
	return bucket.has(b)


func graph_distance(from_id: int, to_id: int) -> int:
	if from_id == to_id:
		return 0
	var table := _neighbor_table()
	var visited: Dictionary = {from_id: true}
	var frontier := PackedInt32Array([from_id])
	var depth := 0
	while not frontier.is_empty():
		depth += 1
		var next := PackedInt32Array()
		for current in frontier:
			var neighbors: PackedInt32Array = table.get(current, PackedInt32Array())
			for neighbor in neighbors:
				if visited.has(neighbor):
					continue
				if neighbor == to_id:
					return depth
				visited[neighbor] = true
				next.append(neighbor)
		frontier = next
	return -1


## 返回从 from 到 to 的 BFS 最短格子序列（不含 from，含 to）。无路时返回空数组。
func shortest_cell_path(from_id: int, to_id: int) -> Array[int]:
	var result: Array[int] = []
	if from_id == to_id or get_cell(from_id) == null or get_cell(to_id) == null:
		return result
	var table := _neighbor_table()
	var previous: Dictionary = {from_id: -1}
	var frontier := PackedInt32Array([from_id])
	var found := false
	while not frontier.is_empty() and not found:
		var next := PackedInt32Array()
		for current in frontier:
			var neighbors: PackedInt32Array = table.get(current, PackedInt32Array())
			for neighbor in neighbors:
				if previous.has(neighbor):
					continue
				previous[neighbor] = current
				if neighbor == to_id:
					found = true
					break
				next.append(neighbor)
			if found:
				break
		frontier = next
	if not found:
		return result
	var node := to_id
	while node != from_id and node >= 0:
		result.push_front(node)
		node = int(previous[node])
	return result


## 返回从 from 出发、在 AP 预算内能到达的地块集合（Dijkstra）。
func reachable_cells(from_id: int, budget_deci: int, actor = null) -> Dictionary:
	var table := _neighbor_table()
	var best: Dictionary = {from_id: 0}
	var visited: Dictionary = {}
	while true:
		var current: int = -1
		var current_cost: int = budget_deci + 1
		for cell_id in best.keys():
			if visited.has(cell_id):
				continue
			var cost: int = int(best[cell_id])
			if cost < current_cost:
				current_cost = cost
				current = int(cell_id)
		if current < 0:
			break
		visited[current] = current_cost
		if current_cost >= budget_deci:
			continue
		var neighbors: PackedInt32Array = table.get(current, PackedInt32Array())
		for neighbor in neighbors:
			var cost := current_cost + move_cost_deci(current, neighbor, actor)
			if cost > budget_deci:
				continue
			if cost < int(best.get(neighbor, budget_deci + 1)):
				best[neighbor] = cost
	return visited


func terrain_display_name(terrain_id: String) -> String:
	var record := DataManager.get_record("terrains", terrain_id)
	return String(record.get("name", terrain_id))


## 连续移动消耗，单位：0.1 AP（deci-AP）。
## AP 不再按“进入一个地块”一次性扣除，而是沿玩家实际画出的路径逐段消耗：
##   距离 × 基础每像素消耗 × 所经地块地形系数 + 上坡爬升惩罚。
## 因此同一地块内移动也会耗 AP，靠近目标地块边缘起步会比从远处起步更省。
const BASE_MOVE_AP_PER_PIXEL_DECI := 0.35
## 爬升 1 层高程的额外消耗；下坡不返还 AP，避免来回刷高度。
const UPHILL_AP_DECI_PER_ELEVATION := 10.0
const ROPE_UPHILL_MULTIPLIER := 0.5


## 地形移动系数；密林/沙漠等更难走的地形会让每像素消耗更高。
func terrain_movement_coefficient(terrain_id: String, actor = null) -> float:
	var coefficient := 1.2
	var terrain_record := DataManager.get_record("terrains", terrain_id)
	if not terrain_record.is_empty():
		var value = terrain_record.get("movement_coefficient", 1.2)
		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			coefficient = float(value)
	if actor != null and actor.has_trait("forest_hunter") and terrain_id == "forest":
		coefficient *= 0.8
	return maxf(coefficient, 0.1)


func movement_rate_deci_per_pixel(cell_id: int, actor = null) -> float:
	return BASE_MOVE_AP_PER_PIXEL_DECI * terrain_movement_coefficient(terrain_of(cell_id), actor)


## 一段实际路径的消耗（浮点 deci-AP）。from/to 点可以在同一地块内，
## 也可以跨越相邻地块；地形取目标端，高程用连续采样计算这一段爬升。
func segment_move_cost_deci(
	from_point: Vector2,
	to_point: Vector2,
	from_cell_id: int,
	to_cell_id: int,
	actor = null
) -> float:
	var distance := from_point.distance_to(to_point)
	if distance <= 0.0001:
		return 0.0
	var rate := movement_rate_deci_per_pixel(to_cell_id, actor)
	var cost := distance * rate
	var from_height := elevation_at(from_cell_id, from_point)
	var to_height := elevation_at(to_cell_id, to_point)
	var climb := to_height - from_height
	if climb > 0.0:
		var uphill := climb * UPHILL_AP_DECI_PER_ELEVATION
		if actor != null and actor.has_equipment("rope"):
			uphill *= ROPE_UPHILL_MULTIPLIER
		cost += uphill
	return maxf(cost, 0.0)


## AI/可达性使用的近似成本：把相邻地块中心之间的直线当作一次移动。
## 玩家实际移动不使用这个近似，而是按画出的每段路径计算。
func move_cost_deci(from_id: int, to_id: int, actor = null) -> int:
	var from_cell := get_cell(from_id)
	var to_cell := get_cell(to_id)
	if from_cell == null or to_cell == null:
		return 1200
	return int(round(segment_move_cost_deci(from_cell.center, to_cell.center, from_id, to_id, actor)))


func _neighbor_table() -> Dictionary:
	if _neighbor_cache.is_empty() and not cells.is_empty():
		for cell in cells:
			_neighbor_cache[cell.id] = PackedInt32Array(cell.neighbors)
	return _neighbor_cache


var _neighbor_cache: Dictionary = {}
