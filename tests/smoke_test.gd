extends Node
## P0 冒烟测试：Voronoi 地图、可复现、自由画笔路径、连续距离 AP、格内移动、事件与 UI 场景加载。
## 运行：Godot_v4.7.2-stable_win64_console.exe --headless --path . res://tests/smoke_test.tscn

var failures: Array[String] = []


func _ready() -> void:
	print("=== P0 smoke test（Voronoi / 自由画线） ===")
	# 测试中不等待战斗面板输入；需要 UI 的分支单独断言状态机。
	GameManager.combat_interactive = false
	_test_map_generation()
	_test_segment_cost_cap()
	_test_drawing_and_animated_move()
	_test_continuous_distance_ap()
	_test_ap_exhaustion()
	_test_turn_actions()
	_test_event_system()
	await _test_game_scene()
	await _test_menu_scenes()
	await _test_map_content_manifest()
	_test_random_map_runs()
	_test_fog_and_scouting()
	_test_hidden_tasks()
	_test_companion_and_events()
	_test_formula_sources()
	_test_combat_and_victory_tiers()
	_test_p0_exclusive_tasks()
	_test_inventory_overflow_and_recovery()
	_test_save_load()
	_test_victory()
	print("=== %s ===" % ("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size()))
	for failure in failures:
		print("  - " + failure)
	get_tree().quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok: " + message)
	else:
		failures.append(message)
		print("  FAIL: " + message)


func _test_map_generation() -> void:
	print("-- map configs / Voronoi generation --")
	var configs := MapConfigLoader.list_configs()
	_check(configs.size() == 1, "exactly one built-in map JSON config")
	if not configs.is_empty():
		_check(bool(configs[0].get("randomize_seed", false)), "sole built-in map randomizes each run")
	var config: Dictionary = configs[0] if not configs.is_empty() else MapGenerator.DEFAULT_CONFIG
	var map := MapGenerator.generate(config)
	var player_started := Time.get_ticks_msec()
	print("  map=%s seed=%d generated=%d cells=%d terrains=%s pois=%d" % [
		map.map_name, map.seed_value, map.generated_seed, map.cells.size(), str(map.terrain_counts), map.poi_ids.size(),
	])
	print("  boundary_vertices=%d start=%d goal=%d centers=(%s, %s)" % [
		map.boundary.size(), map.start_id, map.goal_id,
		str(map.cell_center(map.start_id)), str(map.cell_center(map.goal_id)),
	])
	var areas: Array[float] = []
	var area_sum := 0.0
	for cell in map.cells:
		areas.append(cell.area)
		area_sum += cell.area
	areas.sort()
	var average_area := area_sum / maxf(float(areas.size()), 1.0)
	var p10 := areas[clampi(int(areas.size() * 0.10), 0, areas.size() - 1)]
	var p90 := areas[clampi(int(areas.size() * 0.90), 0, areas.size() - 1)]
	print("  cell area min=%.0f p10=%.0f avg=%.0f p90=%.0f max=%.0f (px²), p90/p10=%.2f, max/avg=%.2f, min/avg=%.2f" % [
		areas[0], p10, average_area, p90, areas[areas.size() - 1],
		p90 / maxf(p10, 1.0), areas[areas.size() - 1] / maxf(average_area, 1.0), areas[0] / maxf(average_area, 1.0),
	])
	_check(map.validation_ok, "map passes validation: %s" % "; ".join(map.validation_notes))
	_check(map.cells.size() >= 150 and map.cells.size() <= 800, "Voronoi cell count in 150..800")
	_check(p90 / maxf(p10, 1.0) >= 1.8, "cell areas vary visibly")
	_check(areas[0] >= average_area * 0.22, "no tiny sliver cells")
	_check(areas[areas.size() - 1] <= average_area * 2.8, "no oversized cells")
	_check(map.boundary.size() >= 10, "irregular boundary has at least 10 vertices")
	_check(map.terrain_counts.size() >= 3, "at least 3 terrain types")
	_check(map.poi_ids.size() == int(config.get("poi_count", 8)), "POI count matches config")
	_check(map.start_id != map.goal_id, "start and goal are different cells")
	var hops := map.graph_distance(map.start_id, map.goal_id)
	var depth: Dictionary = {map.start_id: 0}
	var frontier := PackedInt32Array([map.start_id])
	var max_depth := 0
	while not frontier.is_empty():
		var next := PackedInt32Array()
		for current in frontier:
			for neighbor in map.neighbors_of(current):
				if depth.has(neighbor):
					continue
				depth[neighbor] = int(depth[current]) + 1
				max_depth = maxi(max_depth, int(depth[neighbor]))
				next.append(neighbor)
		frontier = next
	var min_hops := int(config.get("start_goal_min_hops", 10))
	var max_hops := int(config.get("start_goal_max_hops", 20))
	print("  BFS hops start->goal = %d (allowed %d..%d), max hops from start = %d" % [hops, min_hops, max_hops, max_depth])
	_check(hops >= min_hops and hops <= max_hops, "start->goal BFS distance in configured range")
	var reachable := map.reachable_cells(map.start_id, 1200, null)
	var goal_cost := int(reachable.get(map.goal_id, -1))
	print("  shortest AP to goal = %.1f, reachable=%d/%d, generation=%dms" % [
		goal_cost / 10.0, reachable.size(), map.cells.size(), Time.get_ticks_msec() - player_started,
	])
	_check(goal_cost > 0 and goal_cost <= 1200, "goal reachable within 120 AP")
	# AP 成本按实际像素距离与地形连续计算，不再按地块面积一次性计价。
	var start_cell := map.get_cell(map.start_id)
	var probe_a := start_cell.center
	var probe_b := start_cell.center + Vector2(12.0, 0.0)
	var short_cost := map.segment_move_cost_deci(probe_a, probe_b, map.start_id, map.start_id, null)
	var medium_cost := map.segment_move_cost_deci(probe_a, probe_a + Vector2(24.0, 0.0), map.start_id, map.start_id, null)
	var long_cost := map.segment_move_cost_deci(probe_a, probe_a + Vector2(48.0, 0.0), map.start_id, map.start_id, null)
	print("  distance costs: 12px=%.1f 24px=%.1f 48px=%.1f rate=%.2f deci/px" % [
		short_cost, medium_cost, long_cost, map.movement_rate_deci_per_pixel(map.start_id, null),
	])
	_check(map.movement_rate_deci_per_pixel(map.start_id, null) > 0.0, "terrain provides a positive movement rate")
	_check(medium_cost > short_cost * 1.5, "AP cost grows with actual path distance")
	_check(long_cost <= MapData.MAX_SEGMENT_COST_DECI + 0.01, "long path samples stay within the single-segment cap")
	_check(is_equal_approx(map.segment_move_cost_deci(probe_a, probe_a, map.start_id, map.start_id, null), 0.0), "zero-length movement is free")
	var uphill_pair: Array[int] = [-1, -1]
	for cell in map.cells:
		for neighbor in cell.neighbors:
			if map.elevation_of(cell.id) < map.elevation_of(neighbor):
				uphill_pair = [int(cell.id), int(neighbor)]
				break
		if uphill_pair[0] >= 0:
			break
	_check(uphill_pair[0] >= 0, "map contains a reachable elevation change for uphill costs")
	if uphill_pair[0] >= 0:
		var low_center := map.cell_center(uphill_pair[0])
		var high_center := map.cell_center(uphill_pair[1])
		var climb := map.elevation_at(uphill_pair[1], high_center) - map.elevation_at(uphill_pair[0], low_center)
		var flat_cost := low_center.distance_to(high_center) * map.movement_rate_deci_per_pixel(uphill_pair[1], null)
		var climb_cost := map.segment_move_cost_deci(low_center, high_center, uphill_pair[0], uphill_pair[1], null)
		_check(climb > 0.0, "chosen segment actually climbs in elevation")
		_check(climb_cost > flat_cost + 0.5, "climbing adds AP on top of the distance cost")
		var roped := MapData.ROPE_UPHILL_MULTIPLIER
		_check(roped > 0.0 and roped < 1.0, "rope reduces the uphill penalty without removing it")
	var total_sides := 0
	var bad_polygons := 0
	for cell in map.cells:
		var sides := cell.polygon.size()
		total_sides += sides
		if sides < 3:
			bad_polygons += 1
		var center_cell := map.cell_at_point(cell.center)
		if center_cell != cell.id:
			bad_polygons += 1
		for neighbor in cell.neighbors:
			if not map.are_adjacent(neighbor, cell.id):
				bad_polygons += 1
	var average_sides := float(total_sides) / float(map.cells.size())
	print("  average polygon sides = %.2f" % average_sides)
	_check(bad_polygons == 0, "polygons and adjacency consistent; point lookup hits own cell")
	_check(average_sides >= 5.0 and average_sides <= 8.0, "average polygon sides in 5..8")
	_check(map.are_adjacent(map.start_id, map.neighbors_of(map.start_id)[0]), "adjacency is symmetric")

	# 凹地块：合并相邻 Voronoi 块，避免整张图都是凸多边形。
	var concave_cells := 0
	var broken_polygons := 0
	var broken_relief := 0
	for cell in map.cells:
		if cell.concave:
			concave_cells += 1
		if Geometry2D.triangulate_polygon(cell.polygon).is_empty():
			broken_polygons += 1
		if cell.relief_polygon.size() >= 3 and Geometry2D.triangulate_polygon(cell.relief_polygon).is_empty():
			broken_relief += 1
	var concave_ratio := float(concave_cells) / float(maxi(map.cells.size(), 1))
	print("  concave cells=%d (%.1f%%), broken polygons=%d, broken relief=%d" % [
		concave_cells, concave_ratio * 100.0, broken_polygons, broken_relief,
	])
	_check(concave_cells >= 20 and concave_ratio >= 0.08, "map contains a visible share of concave cells")
	_check(broken_polygons == 0, "all cell polygons triangulate for rendering")
	_check(broken_relief == 0, "all relief polygons triangulate for rendering")

	# 同一形状、不同生态种子应得到不同地形分布，且大致保持西沙东海。
	var biome_a := MapGenerator.generate(config, 20260101)
	var biome_b := MapGenerator.generate(config, 20260202)
	var terrain_changed := 0
	if biome_a.cells.size() == biome_b.cells.size():
		for i in range(biome_a.cells.size()):
			if biome_a.cells[i].terrain != biome_b.cells[i].terrain:
				terrain_changed += 1
	var changed_ratio := float(terrain_changed) / float(maxi(biome_a.cells.size(), 1))
	var gradient_score := _west_east_gradient_score(biome_a)
	print("  biome seed A=%d B=%d terrains A=%s B=%s changed=%.1f%% gradient=%.2f" % [
		biome_a.terrain_seed, biome_b.terrain_seed,
		str(biome_a.terrain_counts), str(biome_b.terrain_counts),
		changed_ratio * 100.0, gradient_score,
	])
	_check(biome_a.terrain_seed != biome_b.terrain_seed, "each run owns a separate terrain seed")
	_check(changed_ratio >= 0.15, "same map shape reshuffles its biome layout per run")
	_check(gradient_score >= 0.20, "directional gradient keeps west desert / east forest")
	_check(biome_a.terrain_counts.size() >= 3 and biome_b.terrain_counts.size() >= 3, "both biome rolls keep all terrain types")

	# 正式开局路径也必须每局重掷生态种子，而不只是生成器接口支持。
	_start_game("qing_heng", config)
	var first_run_seed := GameManager.map.terrain_seed
	_start_game("qing_heng", config)
	var second_run_seed := GameManager.map.terrain_seed
	print("  per-run terrain seeds via GameManager: %d / %d" % [first_run_seed, second_run_seed])
	_check(first_run_seed != second_run_seed, "starting the same map again rolls a new biome")

	var map_again := MapGenerator.generate(config)
	_check(map_again.generated_seed == map.generated_seed, "same config reproduces same generated seed")
	_check(_checksum(map_again) == _checksum(map), "same config reproduces same Voronoi map")
	for map_config in configs:
		var generated := MapGenerator.generate(map_config)
		_check(generated.validation_ok, "built-in map %s passes validation" % String(map_config.get("map_id", "?")))
		var generated_concave := 0
		for cell in generated.cells:
			if cell.concave:
				generated_concave += 1
		_check(generated_concave >= int(generated.cells.size() * 0.08), "built-in map %s has concave cells" % String(map_config.get("map_id", "?")))

	var weak_gradient_rolls := 0
	for roll_index in range(4):
		var roll := MapGenerator.generate(config, 30000017 + roll_index * 7919)
		if _west_east_gradient_score(roll) < 0.20:
			weak_gradient_rolls += 1
	_check(weak_gradient_rolls == 0, "directional gradient holds across several biome rolls")


## 复核回归：AI 用相邻地块中心点的直线近似成本，陡坡长边可能超过
## 低 AP 角色整回合的 AP，导致 AI 每回合都判定“走不起”而永久停在原地。
## 单段成本必须封顶，保证任意一条相邻边都能在下一回合迈出。
func _test_segment_cost_cap() -> void:
	print("-- steep segment cost cap --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "segment cap test config exists")
		return
	var map := MapGenerator.generate_exact(configs[0], 1038328, 3457048)
	_check(map != null and not map.cells.is_empty(), "reported deadlock seed regenerates")
	if map == null:
		return
	var worst_capped := 0.0
	var worst_capped_info := ""
	var worst_raw := 0.0
	var worst_raw_info := ""
	var edges := 0
	for cell in map.cells:
		for neighbor_id in cell.neighbors:
			if neighbor_id <= cell.id:
				continue
			var other := map.get_cell(neighbor_id)
			if other == null:
				continue
			edges += 1
			var capped := map.move_cost_deci(cell.id, neighbor_id, null)
			if capped > worst_capped:
				worst_capped = capped
				worst_capped_info = "cell %d->%d %.2f AP" % [cell.id, neighbor_id, capped / 10.0]
			# 复算封顶前的中心点近似成本，确认这个种子确实包含超预算边。
			var raw := cell.center.distance_to(other.center) \
				* map.movement_rate_deci_per_pixel(neighbor_id, null)
			var climb := map.elevation_at(neighbor_id, other.center) \
				- map.elevation_at(cell.id, cell.center)
			if climb > 0.0:
				raw += climb * MapData.UPHILL_AP_DECI_PER_ELEVATION
			if raw > worst_raw:
				worst_raw = raw
				worst_raw_info = "cell %d->%d %.2f AP" % [cell.id, neighbor_id, raw / 10.0]
	print("  adjacent edges=%d raw worst=%.2f AP (%s), capped worst=%.2f AP (%s), cap=%.1f AP" % [
		edges, worst_raw / 10.0, worst_raw_info,
		worst_capped / 10.0, worst_capped_info, MapData.MAX_SEGMENT_COST_DECI / 10.0,
	])
	_check(edges > 0, "the reported seed has adjacent edges to scan")
	_check(worst_raw > MapData.MAX_SEGMENT_COST_DECI, "reported seed contains an edge above the cap before clamping")
	_check(worst_capped <= MapData.MAX_SEGMENT_COST_DECI + 0.01, "every adjacent-cell edge is clamped to the cap")
	var lowest_ap := 99
	for record in DataManager.all_records("characters"):
		var character: Dictionary = record
		var actor := ActorState.from_character(character)
		lowest_ap = mini(lowest_ap, 1 + actor.speed())
	print("  slowest character minimum AP = %d" % lowest_ap)
	_check(MapData.MAX_SEGMENT_COST_DECI <= float(lowest_ap * 10), "the cap is affordable by the slowest character")


func _test_drawing_and_animated_move() -> void:
	print("-- freehand drawing / animated move --")
	var configs := MapConfigLoader.list_configs()
	_check(_start_game("lin_xiao", configs[0]), "start_new_game with selected map config")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	_check(player.cell_id == map.start_id, "player starts on start cell")
	_check(player.ap_deci >= 10 and player.ap_deci <= 120, "initial AP in 1.0..12.0")

	var neighbor_id: int = map.neighbors_of(player.cell_id)[0]
	var stroke := PackedVector2Array([map.cell_center(player.cell_id), map.cell_center(neighbor_id)])
	var ok := GameManager.set_drawn_path(stroke)
	_check(ok, "freehand stroke accepted")
	_check(GameManager.path_cells.size() >= 2, "stroke becomes a contiguous cell sequence")
	_check(GameManager.path_cells[0] == player.cell_id, "path starts at player cell")
	_check(GameManager.drawn_stroke.size() >= 2, "raw stroke is retained for rendering")
	var hidden_cost := GameManager.path_cost_deci()
	print("  path cells=%s hidden_cost=%.1f AP" % [str(GameManager.path_cells), hidden_cost / 10.0])
	_check(hidden_cost > 0, "path has a hidden cost")

	var arrivals: Array[int] = []
	GameManager.cell_entered.connect(func(cell_id: int, _from_id: int) -> void: arrivals.append(cell_id))
	var captured_cells: Array[int] = GameManager.path_cells.duplicate()
	var expected_cell: int = captured_cells[captured_cells.size() - 1]
	player.ap_deci = 300
	player.ap_max_deci = 300
	var ap_before := player.ap_deci
	var start_pos := GameManager.get_visual_position()
	_check(GameManager.execute_move(), "execute_move starts animation")
	_check(GameManager.is_moving, "movement is active immediately after execute")
	_check(GameManager.get_visual_position().distance_to(start_pos) < 0.01, "token does not teleport at start")
	GameManager.advance_movement(0.01)
	_check(GameManager.is_moving, "movement still active after a small time step")
	GameManager.advance_movement(5.0)
	_check(not GameManager.is_moving, "movement finishes after enough time")
	_check(player.cell_id == expected_cell, "player ends on last drawn cell")
	_check(player.ap_deci == ap_before - hidden_cost, "AP deducted exactly by actual path distance")
	_check(arrivals.size() == captured_cells.size() - 1, "cell_entered fires once per entered cell")
	_check(GameManager.path_cells.is_empty(), "path clears after movement finishes")
	_check(GameManager.last_move_message.is_empty(), "no failure message on successful move")


func _test_continuous_distance_ap() -> void:
	print("-- continuous distance AP / intra-cell movement --")
	var configs := MapConfigLoader.list_configs()
	_start_game("lin_xiao", configs[0])
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var start_id := player.cell_id
	var center := map.cell_center(start_id)

	# 1. 整条路径都在当前地块内也必须可以执行。
	var target := _point_inside_cell(map, start_id, center, Vector2.RIGHT, 10.0)
	_check(target.distance_to(center) > 1.0, "test finds a point inside the current cell")
	var intra_ok := GameManager.set_drawn_path(PackedVector2Array([center, target]))
	_check(intra_ok, "a path fully inside the current cell is accepted")
	_check(GameManager.path_cells.size() == 1, "intra-cell path keeps a single-cell sequence")
	_check(GameManager.has_drawn_path(), "intra-cell path is executable")
	var intra_cost := GameManager.path_cost_deci()
	_check(intra_cost > 0, "intra-cell travel still costs AP")
	player.ap_deci = 40
	player.ap_max_deci = 40
	var ap_before := player.ap_deci
	_check(GameManager.execute_move(), "intra-cell movement can start")
	GameManager.advance_movement(0.02)
	_check(GameManager.is_moving, "intra-cell movement is still in progress")
	_check(player.cell_id == start_id, "AP drains before the player leaves the starting cell")
	_check(player.ap_deci < ap_before, "AP decreases continuously while still inside the same cell")
	GameManager.advance_movement(5.0)
	_check(not GameManager.is_moving, "intra-cell movement finishes")
	_check(player.cell_id == start_id, "moving inside one cell never changes the cell")
	_check(player.ap_deci == ap_before - intra_cost, "intra-cell AP equals the actual drawn distance cost")

	# 2. 同一地块内可以反复画线移动，每次都扣 AP。
	player.ap_deci = 90
	player.ap_max_deci = 90
	var repeat_ok := true
	var last_ap := player.ap_deci
	for repeat in range(3):
		var from := GameManager.get_visual_position()
		var next := _point_inside_cell(map, start_id, center, Vector2.RIGHT.rotated(repeat * 1.7), 9.0)
		# 经过格心，保证每一段新线都有足够长度，同时仍完全在同一地块内。
		var repeated_path := PackedVector2Array([from, center, next])
		if not GameManager.set_drawn_path(repeated_path):
			repeat_ok = false
			break
		if not GameManager.execute_move():
			repeat_ok = false
			break
		GameManager.advance_movement(5.0)
		if player.cell_id != start_id or player.ap_deci >= last_ap:
			repeat_ok = false
			break
		last_ap = player.ap_deci
	_check(repeat_ok, "the player can move repeatedly inside one cell and pay AP each time")
	_check(last_ap < 90, "repeated intra-cell moves actually consume AP")

	# 3. AP 可以在同一地块内耗尽，并停在画线上的真实位置。
	_start_game("lin_xiao", configs[0])
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	start_id = player.cell_id
	center = map.cell_center(start_id)
	var zigzag := PackedVector2Array([center])
	for angle in [0.0, PI, PI * 0.5, -PI * 0.5, 0.0]:
		var point := _point_inside_cell(map, start_id, center, Vector2.RIGHT.rotated(angle), 6.0)
		if point.distance_to(zigzag[zigzag.size() - 1]) > 1.0:
			zigzag.append(point)
	_check(zigzag.size() >= 3 and GameManager.set_drawn_path(zigzag), "multi-segment intra-cell zigzag is accepted")
	player.ap_deci = 3
	player.ap_max_deci = 3
	var drawn_length := GameManager.path_length
	_check(GameManager.execute_move(), "movement starts with a tiny AP budget")
	GameManager.advance_movement(5.0)
	_check(not GameManager.is_moving, "movement stops when AP runs out inside the cell")
	_check(player.ap_deci == 0, "all remaining AP is spent before stopping")
	_check(player.cell_id == start_id, "AP exhaustion inside a cell leaves the player in that cell")
	_check(GameManager.last_move_message.contains("停在路径上的实际位置"), "intra-cell exhaustion explains the exact stop point")
	var stopped_at := GameManager.get_visual_position()
	_check(stopped_at.distance_to(center) > 0.5, "token stops along the drawn line, not at the cell center")
	_check(stopped_at.distance_to(center) < drawn_length - 0.5, "token stops before the drawn endpoint when AP runs out")

	# 4. 进入相邻格的成本取决于从当前格的哪个位置出发。
	_start_game("lin_xiao", configs[0])
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	start_id = player.cell_id
	center = map.cell_center(start_id)
	var proximity_ok := false
	for neighbor in map.neighbors_of(start_id):
		var neighbor_center := map.cell_center(neighbor)
		var direction := (neighbor_center - center).normalized()
		var near_start := _last_inside_point(map, start_id, center, direction)
		var far_start := _last_inside_point(map, start_id, center, -direction)
		if near_start.distance_to(neighbor_center) + 4.0 >= far_start.distance_to(neighbor_center):
			continue
		var near_cost := map.segment_move_cost_deci(near_start, neighbor_center, start_id, neighbor, player)
		var far_cost := map.segment_move_cost_deci(far_start, neighbor_center, start_id, neighbor, player)
		if near_cost < far_cost:
			proximity_ok = true
			print("  entry proximity: near=%.1f AP far=%.1f AP (cell %d -> %d)" % [
				near_cost / 10.0, far_cost / 10.0, start_id, neighbor,
			])
			break
	_check(proximity_ok, "starting near the shared border costs less AP than starting far from it")

	# 5. 近边界起笔的实际路径总成本也更低，而不仅是单段公式。
	var near_route_cost := 0
	var far_route_cost := 0
	for neighbor in map.neighbors_of(start_id):
		var neighbor_center := map.cell_center(neighbor)
		var direction := (neighbor_center - center).normalized()
		var near_start := _last_inside_point(map, start_id, center, direction)
		var far_start := _last_inside_point(map, start_id, center, -direction)
		if near_start.distance_to(center) < 1.0 or far_start.distance_to(center) < 1.0:
			continue
		GameManager.visual_position = near_start
		if GameManager.set_drawn_path(PackedVector2Array([near_start, neighbor_center])):
			near_route_cost = GameManager.path_cost_deci()
		GameManager.visual_position = center
		if GameManager.set_drawn_path(PackedVector2Array([center, far_start, neighbor_center])):
			far_route_cost = GameManager.path_cost_deci()
		if near_route_cost > 0 and far_route_cost > near_route_cost:
			break
	GameManager.clear_drawn_path()
	_check(near_route_cost > 0 and far_route_cost > near_route_cost, "a longer approach route inside the same cell costs more AP")


func _point_inside_cell(map: MapData, cell_id: int, origin: Vector2, direction: Vector2, distance: float) -> Vector2:
	for scale in [1.0, 0.75, 0.5, 0.35]:
		var candidate: Vector2 = origin + direction.normalized() * distance * float(scale)
		if map.cell_at_point(candidate) == cell_id:
			return candidate
	return origin


func _last_inside_point(map: MapData, cell_id: int, origin: Vector2, direction: Vector2) -> Vector2:
	var last := origin
	for step in range(1, 121):
		var candidate := origin + direction.normalized() * float(step)
		if map.cell_at_point(candidate) != cell_id:
			break
		last = candidate
	return last


## 找到一条真正与相邻地块共享的边，并返回边界内外各 1/2px 的点。
## 从格心朝邻格射线可能先撞上第三块地（Voronoi 顶点），在多边形边上取样更稳。
func _find_shared_boundary_click(map: MapData, cell_id: int) -> Dictionary:
	var cell := map.get_cell(cell_id)
	if cell == null or cell.polygon.size() < 3:
		return {}
	for i in range(cell.polygon.size()):
		var a := cell.polygon[i]
		var b := cell.polygon[(i + 1) % cell.polygon.size()]
		if a.distance_to(b) < 4.0:
			continue
		var midpoint := (a + b) * 0.5
		var normal := (b - a).orthogonal().normalized()
		var point_a := midpoint + normal
		var point_b := midpoint - normal
		var cell_a := map.cell_at_point(point_a)
		var cell_b := map.cell_at_point(point_b)
		var inside_point := point_a
		var outside_point := point_b
		var other := cell_b
		if cell_a != cell_id:
			inside_point = point_b
			outside_point = point_a
			other = cell_a
		if other < 0 or other == cell_id or not map.are_adjacent(cell_id, other):
			continue
		return {
			"inside": inside_point,
			"outside": outside_point,
			"neighbor": other,
		}
	return {}


func _test_ap_exhaustion() -> void:
	print("-- AP exhaustion --")
	var configs := MapConfigLoader.list_configs()
	_start_game("sha_kai", configs[0])
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var neighbor_id: int = map.neighbors_of(player.cell_id)[0]
	var stroke := PackedVector2Array([map.cell_center(player.cell_id), map.cell_center(neighbor_id)])
	_check(GameManager.set_drawn_path(stroke), "draw path before 0 AP test")
	var origin_cell := player.cell_id
	player.ap_deci = 0
	player.ap_max_deci = 0
	_check(GameManager.execute_move(), "execute_move with 0 AP starts (then stops at first cell)")
	GameManager.advance_movement(5.0)
	_check(not GameManager.is_moving, "movement stops when AP is insufficient")
	_check(player.cell_id == origin_cell, "player remains in the current cell")
	_check(GameManager.last_move_message.contains("AP 不足"), "AP exhaustion message is shown after movement")
	_check(GameManager.path_cells.is_empty(), "unreachable path is cleared")

	# 半路 AP 耗尽：角色应停在路径上的实际落点，而不是被吸回上一格中心。
	_start_game("sha_kai", configs[0])
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	var start_id := player.cell_id
	var first_hop := -1
	var second_hop := -1
	for candidate in map.neighbors_of(start_id):
		var options: Array[int] = []
		for neighbor in map.neighbors_of(candidate):
			if neighbor != start_id:
				options.append(int(neighbor))
		if not options.is_empty():
			first_hop = candidate
			second_hop = options[0]
			break
	_check(first_hop >= 0 and second_hop >= 0, "map provides a three-cell route for the mid-path stop test")
	if first_hop >= 0 and second_hop >= 0:
		var stroke3 := PackedVector2Array([
			map.cell_center(start_id),
			map.cell_center(first_hop),
			map.cell_center(second_hop),
		])
		var path_ok := GameManager.set_drawn_path(stroke3)
		_check(path_ok and GameManager.path_cells.size() >= 3, "three-cell path is accepted")
		if path_ok and GameManager.path_cells.size() >= 3:
			var entered_cell := int(GameManager.path_cells[1])
			var first_cost := GameManager.path_entry_cost_deci(1)
			_check(first_cost > 0, "first entered cell has a real AP cost")
			player.ap_deci = first_cost
			player.ap_max_deci = maxi(player.ap_max_deci, first_cost)
			_check(GameManager.execute_move(), "movement can start with exactly enough AP for one cell")
			GameManager.advance_movement(10.0)
			_check(not GameManager.is_moving, "movement stops when the next cell is unaffordable")
			_check(player.cell_id == entered_cell, "player keeps the last cell they actually paid for")
			_check(GameManager.last_move_message.contains("停在路径上"), "the stop reason says the token stays on the path")
			var stop_center := map.cell_center(player.cell_id)
			_check(
				GameManager.get_visual_position().distance_to(stop_center) > 1.0,
				"token remains at the path point instead of snapping back to the cell center"
			)
			# 停在格边后，从标记处起笔的点击可能落在下一格；仍应能继续画线。
			# 用实际共享边两侧 1/2px 的构造点，避免随机地块形状和顶点处误判。
			var boundary := _find_shared_boundary_click(map, player.cell_id)
			_check(not boundary.is_empty(), "map exposes a shared boundary for the boundary click")
			if not boundary.is_empty():
				var boundary_neighbor := int(boundary.get("neighbor", -1))
				var boundary_inside: Vector2 = boundary.get("inside", stop_center)
				var click_point: Vector2 = boundary.get("outside", stop_center)
				_check(map.cell_at_point(click_point) == boundary_neighbor, "constructed boundary click lands in the next cell")
				_check(click_point.distance_to(boundary_inside) <= GameManager.TOKEN_GRAB_RADIUS, "boundary click stays within token grab radius")
				GameManager.visual_position = boundary_inside
				var resumed_stroke := PackedVector2Array([click_point, map.cell_center(boundary_neighbor)])
				_check(
					GameManager.set_drawn_path(resumed_stroke),
					"a new path can start from the token resting on the cell boundary"
				)
				GameManager.clear_drawn_path()


func _test_turn_actions() -> void:
	print("-- turn actions --")
	var configs := MapConfigLoader.list_configs()
	_start_game("ying", configs[0])
	var player := GameManager.player
	player.hp = player.hp_max - 2
	var hp_before := player.hp
	GameManager.rest()
	_check(player.hp == hp_before + 1, "rest heals 1 HP")
	_check(player.rest_used, "rest marks used")
	GameManager.rest()
	_check(player.hp == hp_before + 1, "rest cannot be used twice per turn")

	# 消耗品可以直接从背包使用：补给二选一，药水解除一个负面状态。
	player.add_item("supply", 2)
	player.hp = player.hp_max - 1
	var supply_options := GameManager.consumable_options("supply")
	_check(supply_options.size() == 2, "supply offers HP and AP choices")
	var supply_used := GameManager.use_item("supply", "hp")
	_check(bool(supply_used.get("ok", false)) and player.hp == player.hp_max, "supply restores the chosen HP")
	_check(player.item_count("supply") == 1, "using a supply consumes exactly one")
	player.hp = player.hp_max
	var supplies_before_denied := player.item_count("supply")
	var denied_supply := GameManager.use_item("supply", "hp")
	_check(not bool(denied_supply.get("ok", true)) and player.item_count("supply") == supplies_before_denied, "a rejected supply use does not consume the item")
	player.add_status("bleeding", 2, GameManager.round_index)
	player.add_item("potion", 1)
	var potion_options := GameManager.consumable_options("potion")
	_check(potion_options.size() >= 1 and String(potion_options[0].get("id", "")) == "bleeding", "potion lists the removable negative status")
	var potion_used := GameManager.use_item("potion", "bleeding")
	_check(bool(potion_used.get("ok", false)) and not player.has_status("bleeding"), "potion removes the chosen negative status")
	_check(not player.has_item("potion"), "using a potion consumes it")
	player.statuses.clear()
	player.hp = player.hp_max

	var round_before := GameManager.round_index
	GameManager.end_turn()
	_check(GameManager.round_index == round_before + 1, "end_turn advances round")
	_check(not player.rest_used, "new turn resets rest")
	_check(player.ap_deci >= 10 and player.ap_deci <= 120, "new turn rolls AP")


func _test_event_system() -> void:
	print("-- event system --")
	var events: Array = DataManager.all_records("events")
	var expected_ids := [
		"caravan", "bandit_ambush", "herb_patch", "goal_guard",
		"wildfire", "sandstorm", "old_well", "lost",
		"abandoned_camp", "wanderer", "cliff", "ancient_stele",
		"fallen_tree", "mirage", "pilgrim",
	]
	var loaded_ids: Array[String] = []
	var invalid_events := 0
	for record in events:
		var event: Dictionary = record
		var event_id := String(event.get("id", ""))
		loaded_ids.append(event_id)
		if String(event.get("name", "")).is_empty() or String(event.get("text", "")).is_empty():
			invalid_events += 1
		if not EventManager.PRIORITY.has(String(event.get("trigger", ""))):
			invalid_events += 1
		if (event.get("choices", []) as Array).is_empty():
			invalid_events += 1
		if int(event.get("cooldown", 0)) < 0:
			invalid_events += 1
	for expected in expected_ids:
		if not loaded_ids.has(expected):
			invalid_events += 1
	_check(events.size() == expected_ids.size(), "all 15 events are loaded")
	_check(invalid_events == 0, "every event has name, text, trigger, cooldown and choices")
	var wander_coverage := {"forest": 0, "desert": 0, "plain": 0}
	for record in events:
		var event: Dictionary = record
		if String(event.get("trigger", "")) != "wander":
			continue
		var terrains: Array = event.get("terrains", [])
		for terrain_id in wander_coverage.keys():
			if terrains.has("any") or terrains.has(terrain_id):
				wander_coverage[terrain_id] += 1
	for terrain_id in wander_coverage.keys():
		_check(int(wander_coverage[terrain_id]) >= 3, "%s has at least three wander candidates" % terrain_id)

	var configs := MapConfigLoader.list_configs()
	_start_game("lin_xiao", configs[0])
	var player := GameManager.player
	EventManager.random_events_enabled = false
	EventManager.begin_run(GameManager.map, player)

	# 选择前不能泄露结果：只保留选项文本与风险档位，具体收益/诅咒在选择后才出现。
	var stele_event: Dictionary = DataManager.get_record("events", "ancient_stele")
	var decipher_choice: Dictionary = {}
	var destroy_choice: Dictionary = {}
	for raw_choice in stele_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "decipher":
			decipher_choice = choice
		elif String(choice.get("id", "")) == "destroy":
			destroy_choice = choice
	var decipher_info := EventManager._describe_choice(decipher_choice)
	_check(decipher_info.get("risk", "") == "高", "stele decipher is labeled high risk because of the permanent curse")
	_check(not decipher_info.has("preview") and not decipher_info.has("hint") and not decipher_info.has("warning"), "pre-choice data exposes no outcome preview fields")
	var pre_choice_text := String(decipher_info.get("text", ""))
	_check(not pre_choice_text.contains("隐士祝福") and not pre_choice_text.contains("被诅咒"), "stele choice text does not spoil blessings or curses")
	var destroy_info := EventManager._describe_choice(destroy_choice)
	_check(not destroy_info.has("preview") and not destroy_info.has("hint") and not destroy_info.has("warning"), "second stele choice also hides its outcomes")
	var destroy_text := String(destroy_info.get("text", ""))
	_check(not destroy_text.contains("古币") and not destroy_text.contains("被诅咒"), "destroy option does not reveal coins or curse before choosing")

	# 马匪战斗：成功结算后才揭示获得「马匪弯刀」。
	_start_game("lin_xiao", configs[0])
	player = GameManager.player
	EventManager.random_events_enabled = false
	var bandit_event: Dictionary = DataManager.get_record("events", "bandit_ambush")
	var fight_choice: Dictionary = {}
	for raw_choice in bandit_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "fight":
			fight_choice = choice
	var fight_info := EventManager._describe_choice(fight_choice)
	var fight_text := String(fight_info.get("text", ""))
	_check(String(fight_info.get("risk", "")) == "中", "bandit fight is marked medium risk")
	_check(not fight_info.has("preview") and not fight_info.has("hint") and not fight_info.has("warning"), "bandit choice has no pre-choice outcome fields")
	_check(not fight_text.contains("马匪弯刀") and not fight_text.contains("获得"), "bandit choice does not reveal the blade before the check")
	var blade_before := player.item_count("bandit_blade")
	var bandit_result := EventManager._resolve_outcome(fight_choice, "success", {})
	var bandit_messages: Array = bandit_result.get("effect_messages", [])
	var bandit_text := " ".join(bandit_messages)
	print("  bandit success result: %s" % bandit_text)
	_check(bandit_text.contains("马匪弯刀"), "successful bandit fight result reveals the bandit blade")
	_check(player.item_count("bandit_blade") == blade_before + 1, "successful bandit fight actually grants the blade")
	var bandit_rewards: Array = bandit_result.get("reward_entries", [])
	var bandit_reward_found := false
	for entry in bandit_rewards:
		if String(entry.get("text", "")).contains("马匪弯刀") and String(entry.get("kind", "")) == "item":
			bandit_reward_found = String(entry.get("hint", "")).contains("背包") or String(entry.get("hint", "")).contains("装备")
	_check(bandit_reward_found, "outcome ledger lists the blade with a usable hint")
	_check((bandit_result.get("cost_entries", []) as Array).is_empty(), "a clean success has no cost entries")
	player.remove_item("bandit_blade", 1)

	player.statuses.clear()
	var curse_apply := EventManager._apply_effects([{"type": "status_add", "status_id": "cursed"}])
	var curse_messages := " ".join(curse_apply.get("messages", []))
	_check(curse_messages.contains("被诅咒") and curse_messages.contains("幸运 -2"), "event result text spells out the curse effect")
	var curse_costs: Array = curse_apply.get("costs", [])
	var curse_cost_found := false
	for entry in curse_costs:
		if String(entry.get("text", "")).contains("被诅咒"):
			curse_cost_found = String(entry.get("kind", "")) == "status"
	_check(curse_cost_found, "outcome ledger lists the curse as a cost")
	_check(curse_messages.contains("药水无法解除"), "event result text says the curse cannot be cured with a potion")
	_check(curse_messages.contains("「被诅咒」") and not curse_messages.contains("。。"), "curse result reads as one clean sentence with a quoted status name")
	_check(player.status_detail_text().contains("被诅咒") and player.status_detail_text().contains("幸运 -2"), "player status detail exposes the active curse")
	_check(player.status_summary_text().contains("被诅咒") and player.status_summary_text().contains("幸运 -2"), "HUD status summary exposes the active curse")
	player.statuses.clear()
	EventManager.random_events_enabled = false

	# 队列按优先级替换最低项，同回合只结算一个事件。
	EventManager._enqueue_event("wildfire", "wander", 0, true)
	EventManager._enqueue_event("bandit_ambush", "enter_region", 0, true)
	_check(EventManager.get_pending_ids().size() == 2, "event queue holds at most two entries")
	EventManager._enqueue_event("caravan", "poi", 0, true)
	var queued := EventManager.get_pending_ids()
	_check(queued.has("caravan") and queued.has("bandit_ambush") and not queued.has("wildfire"), "POI trigger replaces the lowest-priority wander event")
	EventManager._enqueue_event("goal_guard", "goal", 0, true)
	queued = EventManager.get_pending_ids()
	_check(queued.has("goal_guard") and queued.has("caravan") and not queued.has("bandit_ambush"), "goal trigger outranks region events in the queue")
	EventManager._enqueue_event("herb_patch", "poi", 0, true)
	_check(EventManager.get_pending_ids().size() == 2 and not EventManager.get_pending_ids().has("herb_patch"), "a full queue drops an equal-priority newcomer")
	EventManager.pending_events.clear()

	# 冷却每回合递减，归零后重新可抽取。
	EventManager._cooldowns["caravan"] = 2
	_check(EventManager.is_on_cooldown("caravan"), "event cooldown starts active")
	EventManager.tick_cooldowns()
	_check(EventManager.is_on_cooldown("caravan"), "cooldown ticks from 2 to 1")
	EventManager.tick_cooldowns()
	_check(not EventManager.is_on_cooldown("caravan"), "cooldown expires after two rounds")

	# 2d6 检定等级：大成功/成功/大失败与固定边界。
	var probe := {"id": "probe", "text": "检定", "check": {"attr": "combat", "dc": 10}}
	var unequal_seed := _find_event_seed(false)
	RNGManager.set_seed(unequal_seed)
	var baseline := EventManager._roll_check(probe)
	var baseline_total := int(baseline.get("total", 0))
	probe["check"]["dc"] = baseline_total - 5
	RNGManager.set_seed(unequal_seed)
	var great_success := EventManager._roll_check(probe)
	probe["check"]["dc"] = baseline_total + 5
	RNGManager.set_seed(unequal_seed)
	var great_fail := EventManager._roll_check(probe)
	probe["check"]["dc"] = baseline_total
	RNGManager.set_seed(unequal_seed)
	var plain_success := EventManager._roll_check(probe)
	_check((baseline.get("dice", []) as Array).size() == 2, "check reports both d6 values")
	_check(String(great_success.get("level", "")) == "great_success", "total >= DC+5 is a great success")
	_check(String(plain_success.get("level", "")) == "success", "total >= DC is a success")
	_check(String(great_fail.get("level", "")) == "great_fail", "total <= DC-5 is a great failure")
	var double_six_seed := _find_event_seed(true)
	probe["check"]["dc"] = 99
	RNGManager.set_seed(double_six_seed)
	_check(String(EventManager._roll_check(probe).get("level", "")) == "great_success", "double 6 is always a great success")
	probe["check"]["dc"] = 1
	RNGManager.set_seed(double_six_seed)
	_check(String(EventManager._roll_check(probe).get("level", "")) == "great_success", "natural 12 beats a low DC")
	var double_one_seed := _find_event_seed(false, true)
	probe["check"]["dc"] = 1
	RNGManager.set_seed(double_one_seed)
	_check(String(EventManager._roll_check(probe).get("level", "")) == "great_fail", "double 1 is always a great failure")

	# AP 不足转 HP。
	player.statuses.clear()
	player.hp = player.hp_max
	player.ap_deci = 5
	var ap_result := EventManager._apply_effects([{"type": "ap", "value": -1}])
	_check(player.ap_deci == 0 and player.hp == player.hp_max - 1, "missing AP converts to HP")
	_check(String(ap_result.get("messages", [""])[0]).find("转 1 HP") >= 0, "AP overflow is shown in the result text")
	EventManager.take_pending_outcome()

	# 状态持续、流血结算、迷路的次回合 AP 惩罚。
	player.statuses.clear()
	player.hp = player.hp_max
	player.add_status("bleeding", 3, 10)
	var immediate := player.apply_round_status_effects(10)
	var bled_out := false
	for round_no in range(11, 14):
		player.apply_round_status_effects(round_no)
		bled_out = player.tick_status_durations(round_no).has("bleeding") or bled_out
	_check(int(immediate.get("hp_lost", 0)) == 0, "new status does not tick on the round it was gained")
	_check(player.hp == player.hp_max - 3, "bleeding deals 1 HP for each of 3 rounds")
	_check(bled_out and not player.has_status("bleeding"), "status duration expires and removes itself")

	player.hp = player.hp_max
	player.ap_deci = 5
	player.add_status("lost_severe", 1, 1)
	var penalty := player.apply_ap_penalties()
	_check(int(penalty.get("ap_lost_deci", -1)) == 5, "lost_severe penalty consumes remaining AP")
	_check(int(penalty.get("hp_lost", 0)) == 4, "lost_severe AP shortage converts to HP")
	player.statuses.clear()
	player.hp = player.hp_max

	player.add_status("trapped", 1, GameManager.round_index)
	_check(player.status_blocks_movement() and player.status_blocks_goal(), "trapped blocks movement and the goal")
	_check(not GameManager.can_draw_path(), "trapped player cannot draw a path")
	player.remove_status("trapped")
	_check(GameManager.can_draw_path(), "movement is available again after trapped is removed")

	# 商队交易：购买、放弃、以物易物、通缉拒绝。
	var caravan: Dictionary = DataManager.get_record("events", "caravan")
	var trade_choice: Dictionary = {}
	var steal_choice: Dictionary = {}
	for raw_choice in caravan.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "trade":
			trade_choice = choice
		elif String(choice.get("id", "")) == "steal":
			steal_choice = choice
	player.inventory.clear()
	player.gold = 100
	EventManager._pending.clear()
	EventManager.debug_start_event("caravan")
	var trade_menu := EventManager._begin_trade(trade_choice, "success", {})
	_check((trade_menu.get("offers", []) as Array).size() == 3, "caravan offers buy, buy and barter options")
	EventManager.resolve_trade_offer(0)
	_check(player.gold == 90 and player.has_item("pelt"), "buying an offer deducts gold and grants the item")
	var gold_before_decline := player.gold
	EventManager._begin_trade(trade_choice, "success", {})
	EventManager.resolve_trade_offer(-1)
	_check(player.gold == gold_before_decline, "declining a trade changes nothing")
	player.add_item("pelt", 2)
	EventManager._begin_trade(trade_choice, "success", {})
	EventManager.resolve_trade_offer(2)
	_check(player.item_count("pelt") == 1 and player.has_item("rare_charm"), "barter consumes the offered goods and grants the received item")
	player.add_flag("wanted")
	var wanted_description := EventManager._describe_choice(trade_choice)
	_check(bool(wanted_description.get("disabled", false)), "wanted player cannot trade with the caravan")
	player.remove_flag("wanted")

	# 偷窃成功选择物品。
	var charms_before := player.item_count("rare_charm")
	EventManager._pending.clear()
	var steal_menu := EventManager._begin_steal(steal_choice, "success", {})
	_check((steal_menu.get("items", []) as Array).has("rare_charm"), "steal success opens the item choice menu")
	EventManager.resolve_steal_item("rare_charm")
	_check(player.item_count("rare_charm") == charms_before + 1, "stealing adds the selected item")
	_check(player.gold > gold_before_decline, "stealing also grants the configured gold")
	EventManager.finish_event()

	# 终点守卫：献祭直接通过；另有无需检定的「退开」出口，避免无物品时只能反复掉血。
	var goal_choice: Dictionary = {}
	var withdraw_choice: Dictionary = {}
	var goal_event: Dictionary = DataManager.get_record("events", "goal_guard")
	for raw_choice in goal_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "sacrifice_item":
			goal_choice = choice
		elif String(choice.get("id", "")) == "withdraw":
			withdraw_choice = choice
	_check(not withdraw_choice.is_empty(), "goal guard offers a withdrawal choice")
	_check(withdraw_choice.get("check", null) == null, "withdrawal requires no check")
	_check(not bool(withdraw_choice.get("ai_allowed", true)), "AI does not pick the withdrawal shortcut")
	player.goal_passed = false
	player.inventory.clear()
	player.add_item("supply", 1)
	player.add_item("herb", 1)
	EventManager._pending.clear()
	EventManager.debug_start_event("goal_guard")
	var sacrifice_menu := EventManager._begin_sacrifice(goal_choice, {})
	_check((sacrifice_menu.get("items", []) as Array).has("supply"), "sacrifice menu lists non-quest inventory")
	EventManager.resolve_sacrifice("supply")
	var sacrifice_outcome := EventManager.take_pending_outcome()
	_check(player.item_count("supply") == 0, "sacrificed item leaves inventory or equipment")
	_check(bool(sacrifice_outcome.get("goal", false)), "sacrifice passes the goal guard")
	player.goal_passed = false
	EventManager.finish_event()

	# 退开：自动成功、不扣 HP、退回 1 格，且不通过终点。
	var guard_map := GameManager.map
	var guard_cell := int(guard_map.neighbors_of(guard_map.goal_id)[0])
	var restore_cell := player.cell_id
	var restore_position := GameManager.visual_position
	player.cell_id = guard_cell
	GameManager.visual_position = guard_map.cell_center(guard_cell)
	var guard_hp := player.hp
	EventManager.debug_start_event("goal_guard")
	var withdraw_result := EventManager.choose_choice("withdraw")
	_check(not bool(withdraw_result.get("check", true)), "withdrawal resolves without a dice check")
	_check(String(withdraw_result.get("level_name", "")) == "自动成功", "withdrawal is reported as an automatic success")
	_check(player.hp == guard_hp, "withdrawal costs no HP")
	_check(player.cell_id != guard_cell and player.cell_id != guard_map.goal_id, "withdrawal retreats one cell away from the goal")
	_check(not bool(withdraw_result.get("enter_goal", true)), "withdrawal does not enter the goal")
	EventManager.finish_event()
	player.cell_id = restore_cell
	GameManager.visual_position = restore_position

	# 效果顺序：死亡检查早于物品/状态/标记。
	player.inventory.clear()
	player.statuses.clear()
	player.hp = 1
	var death_effects := EventManager._apply_effects([
		{"type": "hp", "value": -1},
		{"type": "item_gain", "item_id": "herb"},
		{"type": "status_add", "status_id": "bleeding"},
	])
	_check(bool(death_effects.get("death", false)) and player.hp == 0, "lethal HP effect triggers death")
	_check(not player.has_item("herb") and not player.has_status("bleeding"), "effects after a death check are skipped")
	var death_outcome := EventManager.take_pending_outcome()
	_check(bool(death_outcome.get("death", false)), "death outcome is available to GameManager")
	player.hp = player.hp_max

	# 事件开始/选项/关闭。
	EventManager.start_new_round()
	EventManager._events_this_round = 0
	_check(EventManager.debug_start_event("caravan"), "debug hook starts a specific event")
	_check(String(EventManager.get_active_event().get("id", "")) == "caravan", "active event is exposed to the UI")
	_check(EventManager.get_choices().size() == 3, "event exposes its three choices with descriptions")
	EventManager.finish_event()
	_check(not EventManager.is_event_active(), "finish_event closes the overlay event")
	_check(EventManager.is_on_cooldown("caravan"), "finishing an event starts its cooldown")

	# 单次移动的事件预算：最多 2 个、间隔 3 AP、同触发源 1 个、每回合随机事件上限 3 个。
	EventManager.begin_run(GameManager.map, player)
	EventManager.random_events_enabled = false

	# POI 首次踏足：保底发现奖励只发一次，探索进度同步可见。
	EventManager.begin_run(GameManager.map, player)
	var poi_cell_id := -1
	for raw_poi_id in GameManager.map.poi_ids:
		var candidate_poi := int(raw_poi_id)
		if candidate_poi != GameManager.map.goal_id:
			poi_cell_id = candidate_poi
			break
	_check(poi_cell_id >= 0, "map has a non-goal POI for discovery rewards")
	if poi_cell_id >= 0:
		var supply_before_poi := player.item_count("supply")
		var potion_before_poi := player.item_count("potion")
		var gold_before_poi := player.gold
		var visited_before_poi := EventManager.get_visited_poi_count()
		EventManager.random_events_enabled = true
		EventManager.on_cell_entered(poi_cell_id)
		EventManager.finish_event()
		EventManager.pending_events.clear()
		var poi_gains := 0
		if player.item_count("supply") > supply_before_poi:
			poi_gains += 1
		if player.item_count("potion") > potion_before_poi:
			poi_gains += 1
		if player.gold > gold_before_poi:
			poi_gains += 1
		_check(poi_gains == 1, "first POI entry grants exactly one discovery reward")
		_check(EventManager.get_visited_poi_count() == visited_before_poi + 1, "first POI entry advances exploration")
		_check(
			EventManager.get_exploration_text() == "探索 %d/%d" % [
				EventManager.get_visited_poi_count(), EventManager.get_total_poi_count(),
			],
			"exploration text reports the visited POI count"
		)
		var gold_after_poi := player.gold
		var inventory_after_poi := player.inventory.size()
		EventManager.on_cell_entered(poi_cell_id)
		EventManager.finish_event()
		EventManager.pending_events.clear()
		_check(
			player.gold == gold_after_poi and player.inventory.size() == inventory_after_poi,
			"re-entering a visited POI pays no second discovery reward"
		)
	EventManager.random_events_enabled = false
	EventManager.begin_run(GameManager.map, player)
	EventManager._cooldowns.clear()
	EventManager._recent_event_ids.clear()
	var wander_entry := {"event_id": "wildfire", "trigger": "wander", "priority": 1, "counted": true}
	var region_entry := {"event_id": "bandit_ambush", "trigger": "enter_region", "priority": 2, "counted": true}
	var poi_entry := {"event_id": "caravan", "trigger": "poi", "priority": 3, "counted": true}
	var goal_entry := {"event_id": "goal_guard", "trigger": "goal", "priority": 4, "counted": true}
	EventManager.begin_action()
	EventManager._action_ap_deci = 10
	_check(EventManager._start_event(wander_entry), "first event of an action starts")
	_check(not EventManager._can_start_entry(region_entry), "events inside one action keep 3 AP spacing")
	EventManager.finish_event()
	EventManager._action_ap_deci = 39
	_check(not EventManager._can_start_entry(region_entry), "2.9 AP after the first event is still too close")
	EventManager._action_ap_deci = 40
	_check(EventManager._can_start_entry(region_entry), "3 AP spacing opens the next event slot")
	_check(EventManager._start_event(region_entry), "second event of the action starts")
	EventManager.finish_event()
	EventManager._action_ap_deci = 200
	_check(not EventManager._can_start_entry(poi_entry), "a single action caps at two events")
	EventManager.end_action()

	EventManager.begin_action()
	EventManager._action_ap_deci = 10
	_check(EventManager._start_event(wander_entry), "new action resets the event budget")
	EventManager.finish_event()
	EventManager._action_ap_deci = 200
	_check(not EventManager._can_start_entry({"event_id": "mirage", "trigger": "wander", "priority": 1, "counted": true}), "wander fires at most once per action")
	EventManager._random_events_this_round = 0
	_check(EventManager._can_start_entry(region_entry), "another trigger type can still fire in the same action")
	EventManager._random_events_this_round = 3
	_check(not EventManager._can_start_entry(region_entry), "random events cap at three per round")
	_check(EventManager._can_start_entry(goal_entry), "goal guard ignores the random-event cap")
	EventManager.end_action()
	EventManager.finish_event()

	# 单局随机事件上限：达到上限后忽略新的随机触发，但终点守卫仍可入队。
	EventManager.pending_events.clear()
	EventManager._random_events_this_run = EventManager.MAX_RANDOM_EVENTS_PER_RUN
	EventManager._enqueue_event("mirage", "wander", player.cell_id, true)
	_check(EventManager.pending_events.is_empty(), "per-run random event cap rejects new triggers")
	EventManager._enqueue_event("goal_guard", "goal", player.cell_id, true)
	_check(EventManager.pending_events.size() == 1, "goal guard ignores the per-run random event cap")
	EventManager.pending_events.clear()
	EventManager._random_events_this_run = 0

	# 防重复池：最近出现过的事件在有替代项时不再被抽中。
	EventManager._cooldowns.clear()
	EventManager._recent_event_ids.clear()
	EventManager._remember_recent_event("lost")
	var repeated_recent := false
	for _roll in range(40):
		var picked := EventManager._pick_weighted_event("wander", "forest")
		if String(picked.get("id", "")) == "lost":
			repeated_recent = true
			break
	_check(not repeated_recent, "recent event is filtered while alternatives exist")
	EventManager._recent_event_ids.clear()


func _find_event_seed(double_six: bool, double_one: bool = false) -> int:
	for seed_value in range(1, 20000):
		RNGManager.set_seed(seed_value)
		var dice := RNGManager.roll_2d6("event")
		if double_six and dice[0] == 6 and dice[1] == 6:
			return seed_value
		if double_one and dice[0] == 1 and dice[1] == 1:
			return seed_value
		if not double_six and not double_one and dice[0] != dice[1] and dice[0] + dice[1] != 12:
			return seed_value
	return 1


func _test_game_scene() -> void:
	print("-- game scene --")
	var configs := MapConfigLoader.list_configs()
	GameManager.start_new_game("qing_heng", configs[0])
	var total_cells := 0
	var relief_cells := 0
	var varied_cells := 0
	var sampled_cells := 0
	var elevation_varies_inside := false
	for cell in GameManager.map.cells:
		total_cells += 1
		if cell.relief_polygon.size() >= 6 and cell.relief_heights.size() == cell.relief_polygon.size():
			relief_cells += 1
			if cell.elevation_samples.size() == cell.relief_heights.size():
				sampled_cells += 1
			if cell.relief_max - cell.relief_min > 0.15:
				varied_cells += 1
				if not elevation_varies_inside:
					var center_height := GameManager.map.elevation_at(cell.id, cell.center)
					var vertex_height := GameManager.map.elevation_at(cell.id, cell.relief_polygon[0])
					elevation_varies_inside = absf(center_height - vertex_height) > 0.02
	_check(relief_cells >= int(total_cells * 0.95), "cells carry continuous relief geometry")
	_check(sampled_cells >= int(total_cells * 0.95), "cells carry multiple elevation samples")
	_check(varied_cells >= int(relief_cells * 0.90), "relief varies inside a cell instead of staying flat")
	_check(elevation_varies_inside, "elevation query returns different values inside one cell")
	var packed: PackedScene = load("res://scenes/game/game.tscn")
	var scene: Node = packed.instantiate()
	add_child(scene)
	await get_tree().process_frame
	var map_view: Node = scene.get_node_or_null("MapView")
	_check(map_view != null, "game scene has MapView")
	var hud: Node = scene.get_node_or_null("UI")
	_check(hud != null, "game scene has UI")
	if hud != null:
		var intro_overlay: Control = hud.get_node_or_null("IntroOverlay")
		_check(intro_overlay != null and intro_overlay.visible, "intro overlay opens before the player may act")
		_check(GameManager.intro_open, "intro state blocks gameplay input until dismissed")
		if intro_overlay != null:
			var intro_body: Label = intro_overlay.get_node_or_null("Center/Panel/Margin/VBox/Scroll/Body")
			var intro_relation: Label = intro_overlay.get_node_or_null("Center/Panel/Margin/VBox/Relation")
			var enter_button: Button = intro_overlay.get_node_or_null("Center/Panel/Margin/VBox/EnterButton")
			_check(intro_body != null and GameManager.player.display_name in intro_body.text, "intro names the player character")
			_check(intro_body != null and GameManager.companion_name() in intro_body.text, "intro names the companion")
			_check(intro_body != null and "回合" in intro_body.text and "烽火台" in intro_body.text, "intro states the goal and round limit")
			_check(intro_relation != null and "关系：" in intro_relation.text, "intro states the initial relationship directly")
			_check(enter_button != null and "踏入荒原" in enter_button.text, "intro has an explicit enter-game button")
			if enter_button != null:
				enter_button.pressed.emit()
				await get_tree().process_frame
			_check(not intro_overlay.visible and not GameManager.intro_open, "enter button closes the intro and unlocks play")
		var dice_overlay: Control = hud.get_node_or_null("DiceOverlay")
		_check(dice_overlay != null and dice_overlay.visible, "opening AP roll animates the dice overlay")
		if dice_overlay != null:
			var dice_title: Label = dice_overlay.get_node_or_null("Banner/Center/Panel/Margin/VBox/Header/TitleLabel")
			var dice_box: HBoxContainer = dice_overlay.get_node_or_null("Banner/Center/Panel/Margin/VBox/DiceRow/DiceBox")
			_check(dice_title != null and "AP" in dice_title.text, "dice overlay announces the AP roll")
			_check(dice_box != null and dice_box.get_child_count() == 1, "AP roll shows one six-sided die")
			_check(dice_overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "dice overlay never blocks map input")
			dice_overlay.show_roll({
				"title": "测试检定", "dice": [2, 5], "sides": 6, "modifier": 3,
				"total": 10, "dc": 9, "level_name": "成功",
				"kind_label": "事件选项", "detail": "2d6 + 3 vs DC 9",
			})
			await get_tree().create_timer(0.65).timeout
			var dice_summary: Label = dice_overlay.get_node_or_null("Banner/Center/Panel/Margin/VBox/DiceRow/SummaryLabel")
			_check(dice_box != null and dice_box.get_child_count() == 2, "2d6 checks show two dice")
			_check(dice_summary != null and "DC 9" in dice_summary.text and "成功" in dice_summary.text, "dice overlay explains modifier, total and DC")
			dice_overlay.clear()
			_check(not dice_overlay.visible, "dice overlay can be cleared explicitly")
			dice_overlay.show_roll({
				"title": "上一条检定", "dice": [3, 4], "sides": 6,
				"total": 7, "dc": 10, "level_name": "失败",
			})
			hud._on_event_started_clear_dice({})
			_check(not dice_overlay.visible, "starting a new event clears the previous event's dice")
			dice_overlay.show_roll({
				"title": "上一条检定", "dice": [3, 4], "sides": 6,
				"total": 7, "dc": 10, "level_name": "失败",
			})
			hud._on_event_progress_clear_dice({"check": false})
			_check(not dice_overlay.visible, "a no-check event result clears the old dice")
			dice_overlay.show_roll({
				"title": "真实检定", "dice": [5, 6], "sides": 6,
				"total": 11, "dc": 10, "level_name": "成功",
			})
			hud._on_event_progress_clear_dice({"check": true})
			_check(dice_overlay.visible, "a real dice check stays visible while its result is shown")
			dice_overlay.clear()
		var name_label: Label = hud.get_node_or_null("TopBar/Margin/HBox/NameLabel")
		_check(name_label != null and GameManager.player.display_name in name_label.text, "HUD shows character name")
		var seed_label: Label = hud.get_node_or_null("TopBar/Margin/HBox/SeedLabel")
		_check(seed_label != null and GameManager.map.map_name in seed_label.text, "HUD shows map file name and seed")
		_check(seed_label != null and "生态种子" in seed_label.tooltip_text, "HUD exposes the per-run biome seed")
		var help_overlay: Control = hud.get_node_or_null("HelpOverlay")
		_check(help_overlay != null, "game scene has a help overlay")
		if help_overlay != null:
			help_overlay.open()
			var help_body: Label = help_overlay.get_node_or_null("Center/Panel/Margin/VBox/Scroll/PageBody")
			_check(help_body != null and "左键" in help_body.text and "路径" in help_body.text, "HUD drawing hint lives in the paginated help panel")
			_check(help_body != null and "状态条" in help_body.text and "旅途纪事" in help_body.text, "help explains the status chip and chronicle controls")
			var help_title: Label = help_overlay.get_node_or_null("Center/Panel/Margin/VBox/PageTitle")
			_check(help_title != null and help_title.text == "操作", "help panel opens on the controls page")
			help_overlay.show_page(1)
			_check(help_title != null and help_title.text == "移动与 AP" and "1d6" in help_body.text, "help panel explains AP rolls on a dedicated page")
			_check("不会跳回地块中心" in help_body.text, "help explains that exhausted AP keeps the token at its actual path position")
			help_overlay.show_page(3)
			_check(help_title != null and help_title.text == "袭击与战斗" and "相邻" in help_body.text, "help panel explains when attack is available")
			var help_page: Label = help_overlay.get_node_or_null("Center/Panel/Margin/VBox/Footer/PageLabel")
			_check(help_page != null and "/ 6" in help_page.text, "help panel paginates all topics")
			help_overlay.close()
		var scout_button: Button = hud.get_node_or_null("BottomBar/Margin/VBox/HBox/ScoutButton")
		_check(scout_button != null and "侦察" in scout_button.text, "HUD has a scouting action")
		_check(scout_button != null and "DC" in scout_button.tooltip_text, "scout tooltip explains the DC and risk")
		var ai_label: Label = hud.get_node_or_null("TopBar/Margin/HBox/AiLabel")
		_check(ai_label != null and "同伴" in ai_label.text and GameManager.companion_name() in ai_label.text, "HUD shows the companion and relation")
		_check(ai_label != null and "情报" in ai_label.tooltip_text, "HUD tooltip shows AI intel level")
		var companion_speech: Label = hud.get_node_or_null("BottomBar/Margin/VBox/CompanionStrip/CompanionSpeech")
		var companion_activity: Label = hud.get_node_or_null("BottomBar/Margin/VBox/CompanionStrip/CompanionActivity")
		_check(companion_speech != null and not companion_speech.text.strip_edges().is_empty(), "companion strip shows a spoken line")
		_check(companion_activity != null and not companion_activity.text.strip_edges().is_empty(), "companion strip doubles as the turn-end activity readout")
		var action_row: Control = hud.get_node_or_null("BottomBar/Margin/VBox/HBox")
		_check(
			companion_activity != null and action_row != null
				and companion_activity.global_position.y > action_row.global_position.y,
			"companion speech and status sit below the end-turn controls"
		)
		var pause_task_name: Label = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/PauseTaskName")
		var pause_task_detail: Label = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/PauseTaskDetail")
		_check(pause_task_name != null and "MVP 未启用" in pause_task_name.text, "pause menu labels the player task as inactive")
		_check(pause_task_detail != null and "只记录" in pause_task_detail.text, "pause menu explains why player tasks are not judged")
		var chronicle_panel: Control = hud.get_node_or_null("ChroniclePanel")
		var chronicle_scroll: ScrollContainer = hud.get_node_or_null("ChroniclePanel/Margin/VBox/Scroll")
		var chronicle_toggle: Button = hud.get_node_or_null("ChroniclePanel/Margin/VBox/Header/ChronicleToggle")
		var chronicle_label: Label = hud.get_node_or_null("ChroniclePanel/Margin/VBox/Scroll/ChronicleLabel")
		_check(chronicle_label != null and "走散" in chronicle_label.text, "HUD world chronicle records the companion journey start")
		_check(
			chronicle_panel != null and chronicle_scroll != null and chronicle_toggle != null,
			"chronicle has a scroll area and a collapse button"
		)
		if chronicle_scroll != null:
			_check(chronicle_toggle != null and chronicle_toggle.text == "收起", "chronicle starts expanded")
			for i in range(14):
				GameManager.add_world_log("滚轮记录 %d" % i)
			await get_tree().process_frame
			hud.refresh()
			await get_tree().process_frame
			_check(chronicle_label != null and "滚轮记录 13" in chronicle_label.text, "chronicle keeps the full recent history")
			var chronicle_bar := chronicle_scroll.get_v_scroll_bar()
			_check(chronicle_bar.max_value > chronicle_bar.page, "long chronicle overflows into a scrollable area")
			chronicle_scroll.scroll_vertical = 0
			var wheel := InputEventMouseButton.new()
			wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
			wheel.pressed = true
			var wheel_pos := chronicle_scroll.global_position + chronicle_scroll.size * 0.5
			wheel.position = wheel_pos
			wheel.global_position = wheel_pos
			get_viewport().push_input(wheel, true)
			await get_tree().process_frame
			_check(chronicle_scroll.scroll_vertical > 0, "mouse wheel scrolls the journey chronicle")
			hud._toggle_chronicle()
			await get_tree().process_frame
			_check(not chronicle_scroll.visible and chronicle_toggle != null and chronicle_toggle.text == "展开", "chronicle collapses to its header")
			_check(chronicle_panel != null and chronicle_panel.size.y < 70.0, "collapsed chronicle no longer covers the map")
			hud._toggle_chronicle()
			await get_tree().process_frame
			_check(chronicle_scroll.visible and chronicle_toggle != null and chronicle_toggle.text == "收起", "chronicle expands again")
		var status_chip: Control = hud.get_node_or_null("StatusChip")
		var status_label: Label = hud.get_node_or_null("StatusChip/Margin/StatusLabel")
		_check(status_chip != null and status_label != null, "HUD has a persistent player status chip")
		if status_label != null:
			GameManager.player.statuses.clear()
			GameManager.player.add_status("cursed", -1, GameManager.round_index)
			hud.refresh()
			await get_tree().process_frame
			_check("被诅咒" in status_label.text and "幸运 -2" in status_label.text, "status chip shows the curse and its luck penalty")
			_check("药水无效" in status_label.text, "status chip spells out potion immunity at a glance")
			_check("药水无法解除" in status_label.tooltip_text, "status chip tooltip explains how the curse can be removed")
			var status_font := status_label.get_theme_font("font")
			var status_needed := status_font.get_string_size(
				status_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12
			).x
			_check(status_needed <= status_chip.size.x - 20.0, "status chip summary fits without being clipped")
			GameManager.player.statuses.clear()
			hud.refresh()
		var pause_companion: Label = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/PauseCompanionLabel")
		var pause_chronicle: Label = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/PauseChronicleLabel")
		_check(pause_companion != null and "个人目标" in pause_companion.text and "情报" in pause_companion.text, "pause menu shows companion relation and intel")
		_check(pause_chronicle != null and "滚轮记录 13" in pause_chronicle.text, "pause menu mirrors the newest journey chronicle entries")
		var backpack_overlay: Control = hud.get_node_or_null("BackpackOverlay")
		_check(backpack_overlay != null, "game scene has a backpack overlay")
		if backpack_overlay != null:
			backpack_overlay.open()
			await get_tree().process_frame
			var equip_title: Label = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Left/EquipTitle")
			var bag_title: Label = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/BagTitle")
			var equip_slots: VBoxContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Left/EquipSlots")
			_check(equip_title != null and "装备栏" in equip_title.text, "backpack page separates equipment from inventory")
			_check(bag_title != null and "背包" in bag_title.text, "backpack page separates equipment from inventory")
			var bag_has_potion := false
			var grid_before: GridContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/Scroll/Grid")
			if grid_before != null:
				for child in grid_before.get_children():
					if child is Button and "药水" in String(child.text):
						bag_has_potion = true
			_check(bag_has_potion, "backpack page lists starting inventory")
			var held_equipment := GameManager.player.equipment.duplicate()
			var held_inventory := GameManager.player.inventory.duplicate()
			GameManager.player.inventory.append("rope")
			backpack_overlay.refresh()
			await get_tree().process_frame
			var equippable_slot: Node = null
			for child in equip_slots.get_children():
				if String(child.get("item_id")) == "rope":
					equippable_slot = child
			var grid: GridContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/Scroll/Grid")
			var rope_slot: Node = null
			if grid != null:
				for child in grid.get_children():
					if String(child.get("item_id")) == "rope":
						rope_slot = child
			_check(equippable_slot == null and rope_slot != null, "newly acquired equipment appears in the backpack, not the equipment bar")
			if rope_slot != null:
				_check(bool(rope_slot.get("drag_allowed")), "equippable backpack items can be dragged to an equipment slot")
				var preview = rope_slot.call("_get_drag_data", Vector2.ZERO)
				_check(typeof(preview) == TYPE_DICTIONARY and String(preview.get("item_id", "")) == "rope", "drag payload carries the item id")
			var equip_result := GameManager.player.equip_item("rope")
			_check(bool(equip_result.get("ok", false)) and GameManager.player.equipment.has("rope"), "equipment can be worn from the backpack")
			backpack_overlay.refresh()
			await get_tree().process_frame
			var detail_label: Label = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/DetailLabel")
			_check(detail_label != null, "backpack page has an item detail pane")
			var use_actions: HBoxContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/UseActions")
			_check(use_actions != null, "backpack page has a consumable action row")
			var unequip_result := GameManager.player.unequip_item("rope")
			_check(bool(unequip_result.get("ok", false)) and GameManager.player.inventory.has("rope"), "equipment can be taken off again")
			GameManager.player.equipment = held_equipment
			GameManager.player.inventory = held_inventory
			backpack_overlay.close()
			await get_tree().process_frame
			# A3 UI：满格奖励会让 HUD 在安全边界自动打开背包取舍页。
			var ui_held_inventory := GameManager.player.inventory.duplicate()
			var ui_held_equipment := GameManager.player.equipment.duplicate()
			var ui_held_companion := GameManager.companion
			var ui_held_perception := int(GameManager.player.attributes.get("perception", 0))
			GameManager.player.inventory.clear()
			for ui_item in ["supply", "potion", "herb", "mount", "pelt", "ancient_coin", "rare_charm", "telescope"]:
				GameManager.player.add_item(ui_item, 1)
			_check(GameManager.player.inventory_slot_count() == 8, "UI overflow test fills 8 backpack slots")
			_check(not backpack_overlay.visible and not get_tree().paused, "backpack starts closed before the queued reward")
			GameManager.grant_item("bandit_blade", 1, "UI 测试")
			await get_tree().process_frame
			await get_tree().process_frame
			_check(backpack_overlay.visible and get_tree().paused, "HUD auto-opens the backpack for a queued reward")
			var ui_bag_title: Label = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/BagTitle")
			var ui_use_actions: HBoxContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/UseActions")
			var ui_recovery_row: HBoxContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/RecoveryRow")
			_check(ui_bag_title != null and "需取舍" in ui_bag_title.text, "overflow backpack page explains that a choice is required")
			_check(ui_use_actions != null and ui_use_actions.get_child_count() >= 2, "overflow page offers discard guidance and an abandon button")
			_check(ui_recovery_row != null and not ui_recovery_row.visible, "recovery row stays hidden when no item was stolen")
			backpack_overlay._on_inventory_pressed("pelt")
			await get_tree().process_frame
			_check(not GameManager.has_pending_item_overflow(), "discarding from the UI resolves the overflow")
			_check(GameManager.player.has_item("bandit_blade") and not GameManager.player.has_item("pelt"), "UI discard swaps in the queued reward")
			_check(not backpack_overlay.visible and not get_tree().paused, "backpack closes and unpauses after the overflow is resolved")
			# D-25 UI：失物存在时背包页出现追查入口，检定后按钮切换为“本回合已追查”。
			var ui_thief := CompanionAI.new()
			_check(ui_thief.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", int(GameManager.map.neighbors_of(GameManager.player.cell_id)[0]), RNGManager.get_stream("ai")), "UI recovery thief setup succeeds")
			GameManager.companion = ui_thief
			ui_thief.actor.inventory.clear()
			ui_thief.actor.add_item("rare_charm", 1)
			ui_thief._stolen_item_id = "rare_charm"
			GameManager.player.attributes["perception"] = -100
			backpack_overlay.open()
			await get_tree().process_frame
			var ui_recovery_button: Button = ui_recovery_row.get_node_or_null("RecoveryButton") if ui_recovery_row != null else null
			var ui_recovery_label: Label = ui_recovery_row.get_node_or_null("RecoveryLabel") if ui_recovery_row != null else null
			_check(ui_recovery_row != null and ui_recovery_row.visible, "stolen item exposes the recovery row in the backpack")
			_check(ui_recovery_label != null and "失物" in ui_recovery_label.text, "recovery row names the stolen item")
			_check(ui_recovery_button != null and not ui_recovery_button.disabled and "免费" in ui_recovery_button.text, "recovery button is available and free")
			if ui_recovery_button != null:
				ui_recovery_button.pressed.emit()
				await get_tree().process_frame
				var ui_detail: Label = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/DetailLabel")
				_check(ui_detail != null and "没能找回" in ui_detail.text, "failed recovery is explained in the backpack detail pane")
				_check(ui_recovery_button.disabled and ui_recovery_button.text.contains("本回合"), "recovery button locks after the free attempt")
			backpack_overlay.close()
			await get_tree().process_frame
			GameManager.companion = ui_held_companion
			GameManager.player.attributes["perception"] = ui_held_perception
			GameManager.player.equipment = ui_held_equipment
			GameManager.player.inventory = ui_held_inventory
		var hover_label: Label = hud.get_node_or_null("HoverChip/Margin/HoverLabel")
		_check(hover_label != null, "HUD shows terrain state while hovering")
		if hover_label != null and map_view != null and GameManager.player != null:
			var hover_id := GameManager.player.cell_id
			map_view._update_hover(GameManager.map.cell_center(hover_id))
			_check(hover_label.text.find("海拔") >= 0 and hover_label.text.find("格内") >= 0, "HUD shows local elevation and within-cell range")
			var hover_cell := GameManager.map.get_cell(hover_id)
			var low_index := 0
			var high_index := 0
			for i in range(hover_cell.elevation_samples.size()):
				if hover_cell.elevation_samples[i] < hover_cell.elevation_samples[low_index]:
					low_index = i
				if hover_cell.elevation_samples[i] > hover_cell.elevation_samples[high_index]:
					high_index = i
			map_view._update_hover(hover_cell.center.lerp(hover_cell.relief_polygon[low_index], 0.75))
			var low_text: String = hover_label.text
			map_view._update_hover(hover_cell.center.lerp(hover_cell.relief_polygon[high_index], 0.75))
			_check(low_text != hover_label.text, "HUD local elevation updates while moving inside one cell")
			var unknown_id := -1
			for cell in GameManager.map.cells:
				if not GameManager.map.cell_intersects_vision(cell.id) \
						and GameManager.map.fog_state(cell.id) == MapData.FogState.UNKNOWN:
					unknown_id = cell.id
					break
			if unknown_id >= 0:
				map_view._update_hover(GameManager.map.cell_center(unknown_id))
				_check("未知" in hover_label.text, "HUD hides terrain under unknown fog")
				_check(hover_label.text.find("海拔") < 0 or hover_label.text.find("—") >= 0, "HUD hides elevation under unknown fog")
		var hover_chip: Control = hud.get_node_or_null("HoverChip")
		_check(hover_chip != null, "hover readout lives in its own top-left chip")
		if hover_chip != null:
			_check(hover_chip.mouse_filter == Control.MOUSE_FILTER_IGNORE, "hover chip lets clicks pass through to the map")
			var blocking_children := 0
			for child in hover_chip.find_children("*", "Control", true, false):
				if (child as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
					blocking_children += 1
			_check(blocking_children == 0, "all hover chip children are click-through")
			var viewport_size: Vector2 = hud.get_viewport().get_visible_rect().size
			_check(hover_chip.global_position.x < viewport_size.x * 0.5 and hover_chip.global_position.y < viewport_size.y * 0.3, "hover chip is anchored to the top-left")
			var bottom_bar: Control = hud.get_node_or_null("BottomBar")
			_check(bottom_bar != null and bottom_bar.global_position.y + bottom_bar.size.y <= viewport_size.y + 1.0, "bottom action bar stays inside the viewport")
			var help_button: Button = hud.get_node_or_null("HelpButton")
			_check(help_button != null and help_button.global_position.x + help_button.size.x <= viewport_size.x + 1.0 and help_button.global_position.y >= 0.0, "help button stays inside the top-right corner")
			_check(hud.get_node_or_null("InfoPanel") == null, "old overflowing bottom-right hint panel was removed")
			_check(hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/PauseEquipmentLabel") == null, "pause menu no longer duplicates the backpack contents")
		var pause_overlay: Control = hud.get_node_or_null("PauseOverlay")
		_check(pause_overlay != null and not pause_overlay.visible, "pause overlay starts hidden")
		if pause_overlay != null:
			var resume_button: Button = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/ResumeButton")
			var pause_menu_button: Button = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/MainMenuButton")
			var pause_quit_button: Button = hud.get_node_or_null("PauseOverlay/Center/Panel/Margin/VBox/QuitButton")
			_check(resume_button != null and resume_button.pressed.is_connected(Callable(hud, "_resume_game")), "pause resume button is wired")
			_check(pause_menu_button != null and pause_menu_button.pressed.is_connected(Callable(hud, "_on_return_to_main_menu")), "pause main-menu button is wired")
			_check(pause_quit_button != null and pause_quit_button.pressed.is_connected(Callable(hud, "_on_quit_game")), "pause quit button is wired")
			var esc := InputEventAction.new()
			esc.action = "ui_cancel"
			esc.pressed = true
			hud._unhandled_input(esc)
			await get_tree().process_frame
			_check(pause_overlay.visible and get_tree().paused, "Esc opens the pause menu")
			if resume_button != null:
				# 真实鼠标点击：验证暂停层没有拦截输入，而不只是信号已连接。
				var click_pos := resume_button.global_position + resume_button.size * 0.5
				var press := InputEventMouseButton.new()
				press.button_index = MOUSE_BUTTON_LEFT
				press.pressed = true
				press.position = click_pos
				press.global_position = click_pos
				var motion := InputEventMouseMotion.new()
				motion.position = click_pos
				motion.global_position = click_pos
				get_viewport().push_input(motion, true)
				get_viewport().push_input(press, true)
				var release := InputEventMouseButton.new()
				release.button_index = MOUSE_BUTTON_LEFT
				release.pressed = false
				release.position = click_pos
				release.global_position = click_pos
				get_viewport().push_input(release, true)
				await get_tree().process_frame
			else:
				hud._resume_game()
			_check(not pause_overlay.visible and not get_tree().paused, "clicking resume closes the menu and unpauses")
		var result_restart: Button = hud.get_node_or_null("ResultOverlay/Center/Panel/Margin/VBox/Buttons/RestartButton")
		var result_menu: Button = hud.get_node_or_null("ResultOverlay/Center/Panel/Margin/VBox/Buttons/MenuButton")
		_check(result_restart != null and result_restart.pressed.is_connected(Callable(hud, "_on_restart_pressed")), "result restart button is wired")
		_check(result_menu != null and result_menu.pressed.is_connected(Callable(hud, "_on_return_to_main_menu")), "result main-menu button is wired")
		var event_overlay: Control = hud.get_node_or_null("EventOverlay")
		_check(event_overlay != null and not event_overlay.visible, "event overlay starts hidden")
		if event_overlay != null:
			_check(EventManager.debug_start_event("caravan"), "event can start from gameplay")
			await get_tree().process_frame
			_check(event_overlay.visible, "event overlay opens when an event starts")
			var choice_buttons: VBoxContainer = event_overlay.get_node_or_null("Center/Panel/Margin/VBox/Choices")
			_check(choice_buttons != null and choice_buttons.get_child_count() == 3, "event overlay lists every choice button")
			var choice_text := ""
			var choice_labels := 0
			if choice_buttons != null:
				for button in choice_buttons.find_children("*", "Button", true, false):
					choice_text += (button as Button).text + " | " + (button as Button).tooltip_text + "\n"
				choice_labels = choice_buttons.find_children("*", "Label", true, false).size()
			_check(choice_labels == 0, "no outcome preview labels are rendered before choosing")
			_check(not choice_text.contains("成功：") and not choice_text.contains("失败："), "choice buttons do not spoil success/failure text")
			var event_title: Label = event_overlay.get_node_or_null("Center/Panel/Margin/VBox/TitleLabel")
			_check(event_title != null and event_title.text == "商队", "event overlay shows the event title")
			EventManager.finish_event()
			await get_tree().process_frame
			_check(not event_overlay.visible, "event overlay closes after the player continues")
			# 神秘石碑在选择前也不能把祝福或诅咒写在选项旁边。
			_check(EventManager.debug_start_event("ancient_stele"), "stele event can start from gameplay")
			await get_tree().process_frame
			var stele_text := ""
			if choice_buttons != null:
				for button in choice_buttons.find_children("*", "Button", true, false):
					stele_text += (button as Button).text + " | " + (button as Button).tooltip_text + "\n"
			_check(not stele_text.contains("隐士祝福") and not stele_text.contains("被诅咒"), "stele choices do not reveal the blessing or curse before choosing")
			_check(not stele_text.contains("幸运 -2") and not stele_text.contains("药水无法解除"), "stele choices hide curse values and cure rules")
			EventManager.finish_event()
			await get_tree().process_frame
		var attack_button: Button = hud.get_node_or_null("BottomBar/Margin/VBox/HBox/AttackButton")
		var attack_reason := GameManager.attack_block_reason()
		_check(attack_button != null and "袭击" in attack_button.text, "HUD has a proactive attack action")
		_check(attack_button != null and "1 AP" in attack_button.tooltip_text, "attack tooltip explains the AP cost and counterattack")
		_check(attack_button != null and attack_button.disabled == not attack_reason.is_empty(), "attack button state matches its availability")
		if attack_button != null and not attack_reason.is_empty():
			_check(attack_reason in attack_button.tooltip_text, "attack tooltip explains why it is unavailable")
		var pause_button: Button = hud.get_node_or_null("BottomBar/Margin/VBox/HBox/PauseButton")
		_check(pause_button != null and not pause_button.disabled, "pause is available during normal play")
		var combat_overlay: Control = hud.get_node_or_null("CombatOverlay")
		_check(combat_overlay != null and not combat_overlay.visible, "combat overlay starts hidden")
		if combat_overlay != null:
			GameManager.combat_interactive = true
			GameManager._handle_companion_combat({"lines": ["测试袭击"], "source": "companion"}, false)
			await get_tree().process_frame
			_check(combat_overlay.visible, "combat overlay opens when an enemy attacks")
			_check(pause_button != null and pause_button.disabled, "pause is locked while combat is unresolved")
			var esc_during_combat := InputEventAction.new()
			esc_during_combat.action = "ui_cancel"
			esc_during_combat.pressed = true
			hud._unhandled_input(esc_during_combat)
			_check(pause_overlay != null and not pause_overlay.visible, "Esc cannot open pause over combat")
			var counter_button: Button = combat_overlay.get_node_or_null("Center/Panel/Margin/VBox/Buttons/CounterButton")
			var endure_button: Button = combat_overlay.get_node_or_null("Center/Panel/Margin/VBox/Buttons/EndureButton")
			var combat_detail: Label = combat_overlay.get_node_or_null("Center/Panel/Margin/VBox/DetailLabel")
			_check(counter_button != null and counter_button.visible and "反击" in counter_button.text, "combat overlay offers a counterattack")
			_check(endure_button != null and endure_button.visible, "combat overlay offers enduring the hit")
			_check(combat_detail != null and combat_detail.text == "测试袭击", "combat overlay renders attack lines")
			GameManager.resolve_combat_choice("endure")
			await get_tree().process_frame
			var continue_button: Button = combat_overlay.get_node_or_null("Center/Panel/Margin/VBox/ContinueButton")
			_check(counter_button != null and not counter_button.visible and continue_button != null and continue_button.visible, "combat overlay switches to a result after the choice")
			GameManager.close_combat()
			await get_tree().process_frame
			_check(not combat_overlay.visible and GameManager.state == GameManager.State.PLAYING, "combat overlay closes back into PLAYING")
			GameManager.combat_interactive = false
		if GameManager.player != null and GameManager.map != null:
			var neighbor_id: int = GameManager.map.neighbors_of(GameManager.player.cell_id)[0]
			var stroke := PackedVector2Array([
				GameManager.map.cell_center(GameManager.player.cell_id),
				GameManager.map.cell_center(neighbor_id),
			])
			GameManager.set_drawn_path(stroke)
			await get_tree().process_frame
			if hover_label != null:
				_check(hover_label.text.find("AP") < 0 and hover_label.text.find("截断") < 0, "HUD hides AP / truncation after drawing")
			GameManager.clear_drawn_path()
	if map_view != null and GameManager.player != null and GameManager.map != null:
		map_view._reset_view()
		var zoom_before: float = map_view.get_zoom()
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		wheel.position = Vector2(640.0, 360.0)
		map_view._unhandled_input(wheel)
		_check(map_view.get_zoom() > zoom_before, "mouse wheel zooms the map")
		var pan_before: Vector2 = map_view._pan
		var middle_press := InputEventMouseButton.new()
		middle_press.button_index = MOUSE_BUTTON_MIDDLE
		middle_press.pressed = true
		middle_press.position = Vector2(640.0, 360.0)
		map_view._unhandled_input(middle_press)
		var middle_motion := InputEventMouseMotion.new()
		middle_motion.position = Vector2(700.0, 410.0)
		map_view._unhandled_input(middle_motion)
		var middle_release := InputEventMouseButton.new()
		middle_release.button_index = MOUSE_BUTTON_MIDDLE
		middle_release.pressed = false
		middle_release.position = Vector2(700.0, 410.0)
		map_view._unhandled_input(middle_release)
		_check(map_view._pan != pan_before, "middle drag pans the map")
		map_view._reset_view()

		var start_center: Vector2 = GameManager.map.cell_center(GameManager.player.cell_id)
		var neighbor_id: int = GameManager.map.neighbors_of(GameManager.player.cell_id)[0]
		var neighbor_center: Vector2 = GameManager.map.cell_center(neighbor_id)
		var ap_before := GameManager.player.ap_deci
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = map_view._world_to_screen(start_center)
		map_view._unhandled_input(press)
		for step in range(1, 6):
			var motion := InputEventMouseMotion.new()
			motion.position = map_view._world_to_screen(start_center.lerp(neighbor_center, float(step) / 5.0))
			map_view._unhandled_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = map_view._world_to_screen(neighbor_center)
		map_view._unhandled_input(release)
		_check(GameManager.path_cells.size() >= 2, "mouse drag creates a drawn path")
		_check(GameManager.player.ap_deci == ap_before, "drawing does not deduct AP")
		GameManager.clear_drawn_path()

	# 结算页接管后，底栏（含「失物可追查」）与残留骰子都不应继续可见。
	if hud != null:
		var result_dice_overlay: Control = hud.get_node_or_null("DiceOverlay")
		var result_overlay: Control = hud.get_node_or_null("ResultOverlay")
		if result_dice_overlay != null:
			result_dice_overlay.show_roll({
				"title": "残留检定", "dice": [2, 2], "sides": 6,
				"total": 4, "dc": 9, "level_name": "失败",
			})
		hud._on_game_over(false, "测试结算")
		await get_tree().process_frame
		var bottom_bar_after: Control = hud.get_node_or_null("BottomBar")
		_check(bottom_bar_after != null and not bottom_bar_after.visible, "result screen hides the bottom action bar and its stale prompts")
		_check(result_dice_overlay != null and not result_dice_overlay.visible, "result screen clears any leftover dice overlay")
		if result_overlay != null:
			result_overlay.visible = false
		if bottom_bar_after != null:
			bottom_bar_after.visible = true
	scene.queue_free()
	await get_tree().process_frame


func _test_menu_scenes() -> void:
	print("-- menu scenes --")
	var main_scene: PackedScene = load("res://scenes/menu/main_menu.tscn")
	var main_node: Node = main_scene.instantiate()
	add_child(main_node)
	await get_tree().process_frame
	_check(main_node.get_node_or_null("Center/VBox/StartButton") != null, "main interface has start button")
	var continue_button: Button = main_node.get_node_or_null("Center/VBox/ContinueButton")
	_check(continue_button != null, "main interface has continue button")
	_check(continue_button != null and continue_button.visible == SaveManager.has_save(SaveManager.DEFAULT_SLOT), "continue button visibility follows the autosave slot")
	main_node.queue_free()
	await get_tree().process_frame

	var map_scene: PackedScene = load("res://scenes/menu/map_select.tscn")
	var map_node: Node = map_scene.instantiate()
	add_child(map_node)
	await get_tree().process_frame
	var grid: GridContainer = map_node.get_node_or_null("Margin/VBox/Scroll/Center/MapGrid")
	_check(grid != null and grid.get_child_count() == 1, "map select lists the single random map")
	map_node.queue_free()
	await get_tree().process_frame

	var character_scene: PackedScene = load("res://scenes/menu/character_select.tscn")
	var character_node: Node = character_scene.instantiate()
	add_child(character_node)
	await get_tree().process_frame
	var char_grid: GridContainer = character_node.get_node_or_null("Margin/VBox/Center/CharacterGrid")
	_check(char_grid != null and char_grid.get_child_count() == 5, "character select shows 5 characters")
	character_node.queue_free()
	await get_tree().process_frame


func _test_map_content_manifest() -> void:
	print("-- map content manifest --")
	var configs := MapConfigLoader.list_configs()
	var all_characters := DataManager.all_records("characters").size()
	var all_events := DataManager.all_records("events").size()
	_check(configs.size() == 1, "single built-in map config available for manifest checks")
	for config in configs:
		var map_name := String(config.get("name", config.get("map_id", "?")))
		_check(MapConfigLoader.validate_config(config).is_empty(), "%s content manifest validates" % map_name)
		_check(GameManager.available_character_ids(config).size() == all_characters, "%s exposes all characters" % map_name)
		_check(GameManager.available_event_ids(config).size() == all_events, "%s exposes all events" % map_name)

	var subset: Dictionary = configs[0].duplicate(true)
	subset["map_id"] = "subset_probe"
	subset["name"] = "清单子集探针"
	subset["character_ids"] = ["lin_xiao", "qing_heng"]
	subset["event_ids"] = ["caravan"]
	_check(MapConfigLoader.validate_config(subset).is_empty(), "subset manifest passes validation")
	_check(GameManager.available_character_ids(subset).size() == 2, "subset exposes exactly two characters")
	_check(GameManager.available_event_ids(subset).size() == 1, "subset exposes exactly one event")
	_check(not GameManager.is_character_available("sha_kai", subset), "character outside manifest is unavailable")
	_check(GameManager.is_event_available("caravan", subset), "declared event is available")
	_check(not GameManager.is_event_available("bandit_ambush", subset), "undeclared event is unavailable")
	_check(not _start_game("sha_kai", subset), "start_new_game rejects character outside map roster")
	_check(_start_game("lin_xiao", subset), "start_new_game accepts roster character")
	_check(GameManager.ai_character_id == "qing_heng", "AI opponent is picked from map roster only")

	var invalid_event := 0
	var allowed := GameManager.available_event_ids(GameManager.map.config)
	for i in range(60):
		EventManager._cooldowns.clear()
		var picked := EventManager._pick_weighted_event("poi", "plain")
		if not picked.is_empty():
			var picked_id := String(picked.get("id", ""))
			if not allowed.has(picked_id):
				invalid_event += 1
	_check(invalid_event == 0, "event picker filters by map event list")

	var legacy: Dictionary = configs[0].duplicate(true)
	legacy.erase("character_ids")
	legacy.erase("event_ids")
	_check(MapConfigLoader.validate_config(legacy).is_empty(), "map without content lists still validates")
	_check(GameManager.available_character_ids(legacy).size() == all_characters, "omitted character list falls back to all")
	_check(GameManager.available_event_ids(legacy).size() == all_events, "omitted event list falls back to all")

	var broken_character: Dictionary = configs[0].duplicate(true)
	broken_character["character_ids"] = ["missing_character"]
	_check(not MapConfigLoader.validate_config(broken_character).is_empty(), "unknown character ID fails validation")
	var broken_event: Dictionary = configs[0].duplicate(true)
	broken_event["event_ids"] = ["missing_event"]
	_check(not MapConfigLoader.validate_config(broken_event).is_empty(), "unknown event ID fails validation")
	var broken_random: Dictionary = configs[0].duplicate(true)
	broken_random["randomize_seed"] = "yes"
	_check(not MapConfigLoader.validate_config(broken_random).is_empty(), "non-boolean randomize_seed fails validation")

	GameManager.select_map(subset)
	var character_scene: PackedScene = load("res://scenes/menu/character_select.tscn")
	var character_node: Node = character_scene.instantiate()
	add_child(character_node)
	await get_tree().process_frame
	var char_grid: GridContainer = character_node.get_node_or_null("Margin/VBox/Center/CharacterGrid")
	_check(char_grid != null and char_grid.get_child_count() == 2, "character select follows map roster")
	character_node.queue_free()
	await get_tree().process_frame


func _test_random_map_runs() -> void:
	print("-- random map runs --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "random map config exists")
		return
	var config: Dictionary = configs[0]
	var base_seed := int(config.get("seed", 0))
	var seeds: Dictionary = {}
	var signatures: Dictionary = {}
	for run_index in range(2):
		_check(_start_game("lin_xiao", config), "random map run %d starts" % (run_index + 1))
		var generated := GameManager.map
		seeds[generated.seed_value] = true
		var area_sum := 0.0
		for cell in generated.cells:
			area_sum += cell.area
		signatures["%d|%d|%.1f|%s" % [
			generated.cells.size(),
			generated.start_id,
			area_sum,
			str(generated.cell_center(generated.goal_id)),
		]] = true
	_check(seeds.size() == 2, "each random map run gets a new shape seed")
	_check(not seeds.has(base_seed), "random map run does not reuse the JSON file seed")
	_check(signatures.size() == 2, "random map runs produce different map content")
	_check(int(config.get("seed", 0)) == base_seed, "randomization does not mutate the loaded map config")

	var seed_before_restart := GameManager.map.seed_value
	_check(GameManager.restart_same_seed(), "restart same seed starts")
	if GameManager.intro_open:
		GameManager.dismiss_intro()
	_check(GameManager.map.seed_value == seed_before_restart, "restart same seed keeps the current shape seed")


func _test_fog_and_scouting() -> void:
	print("-- fog / scouting --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "scouting test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "scouting test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var start_id := player.cell_id

	_check(map.fog_state(start_id) == MapData.FogState.VISIBLE, "start cell is visible")
	_check(map.is_in_current_vision(start_id), "start cell is in current vision")
	_check(map.vision_radius_world > 0.0, "base vision uses a world-space circle")
	var unknown := 0
	var visible := 0
	var remembered := 0
	for cell in map.cells:
		match map.fog_state(cell.id):
			MapData.FogState.UNKNOWN:
				unknown += 1
			MapData.FogState.VISIBLE:
				visible += 1
			MapData.FogState.REMEMBERED:
				remembered += 1
	_check(unknown > map.cells.size() / 2, "fog covers most of the map at game start")
	_check(visible > 1, "passive sight reveals the start cell and nearby cells")
	_check(remembered == 0, "no memory cells before moving away")
	_check(map.fog_state(map.goal_id) != MapData.FogState.VISIBLE, "goal starts outside current vision")
	_check(map.is_point_in_current_vision(map.vision_center), "vision center is visible")

	# 圆形视野不会吸附到整格：把圆心放到某个地块外侧，仍可切进该地块。
	var probe_cell := map.cells[map.cells.size() / 2]
	var probe_span := 0.0
	var probe_far := probe_cell.center
	for point in probe_cell.polygon:
		var distance := point.distance_to(probe_cell.center)
		if distance > probe_span:
			probe_span = distance
			probe_far = point
	var saved_center := map.vision_center
	var saved_radius := map.vision_radius_world
	var probe_direction := (probe_far - probe_cell.center).normalized()
	map.vision_center = probe_cell.center + probe_direction * probe_span * 1.2
	map.vision_radius_world = probe_span
	_check(not map.is_point_in_current_vision(probe_cell.center), "vision circle does not include a cell center just beyond its edge")
	_check(map.cell_intersects_vision(probe_cell.id), "vision circle cuts through a cell without covering its center")
	map.vision_center = saved_center
	map.vision_radius_world = saved_radius

	# DC：地形修正 + 高低处修正；恐高角色在高处不吃 -2 加成。
	var high_id := -1
	var low_id := -1
	var plain_id := -1
	var forest_id := -1
	for cell in map.cells:
		if cell.elevation >= GameManager.HIGH_ELEVATION and high_id < 0:
			high_id = cell.id
		if cell.elevation <= GameManager.LOW_ELEVATION and low_id < 0:
			low_id = cell.id
		if cell.terrain == "plain" and plain_id < 0:
			plain_id = cell.id
		if cell.terrain == "forest" and forest_id < 0:
			forest_id = cell.id
	_check(high_id >= 0 and low_id >= 0, "map has both high and low cells for scouting DC")
	if high_id >= 0:
		var high_info := GameManager.scout_dc_info(high_id, player)
		_check(int(high_info["height_mod"]) == -2, "high ground lowers scouting DC by 2")
		var wei := ActorState.from_character(DataManager.get_record("characters", "wei_la"))
		var wei_high := GameManager.scout_dc_info(high_id, wei)
		_check(wei.has_trait("acrophobia") and int(wei_high["height_mod"]) == 0, "acrophobia cancels the high-ground bonus")
	if low_id >= 0:
		var low_info := GameManager.scout_dc_info(low_id, player)
		_check(int(low_info["height_mod"]) == 2, "low ground raises scouting DC by 2")
	if plain_id >= 0 and forest_id >= 0:
		var plain_dc := GameManager.scout_dc_info(plain_id, player)
		var forest_dc := GameManager.scout_dc_info(forest_id, player)
		_check(int(plain_dc["terrain_mod"]) == 0 and int(forest_dc["terrain_mod"]) == 2, "terrain scout modifiers come from terrains.json")
		_check(int(plain_dc["dc"]) == 10 + int(plain_dc["terrain_mod"]) + int(plain_dc["height_mod"]), "scout DC is 10 + terrain + height")

	# poisoned 的 -1 应作用于侦察检定，但不缩小“感知 // 2 + 1”的揭示半径。
	player.add_status("poisoned", 1, 0)
	var poison_check := player.check_breakdown("perception")
	_check(int(poison_check["status"]) == -1, "poisoned applies -1 to scouting checks")
	_check(player.effective_perception() == player.perception(), "scout radius ignores check-only penalties")
	player.remove_status("poisoned")

	var qing := ActorState.from_character(DataManager.get_record("characters", "qing_heng"))
	var sha := ActorState.from_character(DataManager.get_record("characters", "sha_kai"))
	_check(qing.scout_reveal_radius() == 3 and sha.scout_reveal_radius() == 2, "scout radius follows perception // 2 + 1")

	# 成功：高感知保证总值足够，固定骰子避免蛇眼触发大失败。
	player.attributes["perception"] = 20
	var base_scout_radius := player.scout_reveal_radius()
	player.ap_deci = 100
	player.ap_max_deci = 100
	_check(_seed_scout_natural(7), "seed a deterministic non-critical scouting roll")
	var ap_before := player.ap_deci
	var scouted_before := 0
	for cell in map.cells:
		if cell.scouted:
			scouted_before += 1
	var report := GameManager.scout()
	_check(bool(report.get("ok", false)), "scouting action succeeds")
	_check(ap_before - player.ap_deci == GameManager.SCOUT_AP_COST_DECI, "scouting costs exactly 2 AP")
	_check(String(report.get("level", "")) == "great_success", "high total produces a great success")
	_check(int(report.get("radius", 0)) == base_scout_radius + 1, "great success adds one cell to the reduced reveal radius")
	_check(int(report.get("cells_revealed", 0)) > 0, "scouting reveals multiple cells")
	var scout_formula := String(report.get("formula", ""))
	print("  scout formula: " + scout_formula)
	_check(
		scout_formula.contains("2d6（") and scout_formula.contains("（感知）")
			and scout_formula.contains("（望远镜）"),
		"scout formula names the die, attribute and telescope"
	)
	_check(String(report.get("dc_text", "")).contains("基础"), "scout DC explains its base value")
	_check(EventManager.get_reveal_level() == 1, "scouting success raises AI reveal level to 1")
	var scouted_after := 0
	for cell in map.cells:
		if cell.scouted:
			scouted_after += 1
	_check(scouted_after > scouted_before, "scouted cells are recorded on the map")
	_check(map.is_poi_known(int(report["poi_cell"])) or int(report.get("poi_cell", -1)) < 0, "great success marks the revealed POI as known")
	var expected_vision := GameManager._base_vision_radius_world() + float(report["radius"]) * map.average_site_spacing
	_check(is_equal_approx(GameManager.vision_boost_cells, float(report["radius"])), "scouting sets a circular vision boost")
	_check(is_equal_approx(GameManager.vision_radius_world(), expected_vision), "scout vision radius is the base circle plus the boost")
	_check(int(report.get("vision_hold_rounds", 0)) == GameManager.SCOUT_VISION_HOLD_ROUNDS, "scout vision starts with a hold timer")
	var boosted := GameManager.vision_boost_cells
	GameManager._tick_vision_boost()
	GameManager._tick_vision_boost()
	_check(is_equal_approx(GameManager.vision_boost_cells, boosted), "scout vision holds for 2 rounds")
	GameManager._tick_vision_boost()
	_check(is_equal_approx(GameManager.vision_boost_cells, boosted - GameManager.VISION_BOOST_DECAY_PER_ROUND), "scout vision shrinks by 0.5 cells per round after the hold")
	for i in range(80):
		GameManager._tick_vision_boost()
	_check(not GameManager.vision_boost_active(), "scout vision eventually returns to base")
	_check(is_equal_approx(GameManager.vision_radius_world(), GameManager._base_vision_radius_world()), "boosted circle fully collapses back to base vision")
	_check(EventManager.grant_ai_reveal(9) == GameManager.MAX_AI_REVEAL_LEVEL, "AI reveal level caps at 3")

	# 大失败：位置暴露 1 回合；骰子固定为 7，极低感知保证总值 ≤ DC-5。
	player.attributes["perception"] = -100
	player.ap_deci = 100
	_check(_seed_scout_natural(7), "seed a deterministic great-failure roll")
	var fail_report := GameManager.scout()
	_check(bool(fail_report.get("ok", false)), "low-perception scouting still resolves")
	_check(String(fail_report.get("level", "")) == "great_fail", "very low total produces a great failure")
	_check(GameManager.is_position_exposed(), "great failure exposes the player to AI for one round")
	_check(int(fail_report.get("cells_revealed", 0)) == 0, "failed scouting reveals no cells")

	# AP 不足时拒绝侦察且不扣 AP。
	player.ap_deci = GameManager.SCOUT_AP_COST_DECI - 1
	var rejected := GameManager.scout()
	_check(not bool(rejected.get("ok", true)), "scouting is rejected when AP is below 2")
	_check(player.ap_deci == GameManager.SCOUT_AP_COST_DECI - 1, "rejected scouting does not consume AP")

	# 记忆：离开圆形视野后，见过但当前不可见的格子变成 REMEMBERED。
	_check(_start_game("lin_xiao", configs[0]), "fog memory test run starts")
	map = GameManager.map
	player = GameManager.player
	var old_start := player.cell_id
	var old_seen: Array[int] = []
	for cell in map.cells:
		if cell.seen and not cell.entered and not cell.scouted:
			old_seen.append(cell.id)
	_check(not old_seen.is_empty(), "passive sight marks nearby cells as seen")
	var far_id := -1
	var old_center := map.cell_center(old_start)
	for cell in map.cells:
		if cell.center.distance_to(old_center) > map.vision_radius_world:
			far_id = cell.id
			break
	_check(far_id >= 0, "map has a cell outside the starting vision circle")
	if far_id >= 0:
		player.cell_id = far_id
		map.mark_cell_entered(far_id)
		GameManager.refresh_vision()
		var memory_count := 0
		for cell_id in old_seen:
			if map.fog_state(cell_id) == MapData.FogState.REMEMBERED:
				memory_count += 1
		_check(memory_count > 0, "cells seen earlier fade into memory outside the current circle")
		_check(not map.is_in_current_vision(old_start), "leaving the area removes old cells from current vision")
		_check(map.fog_state(old_start) == MapData.FogState.REMEMBERED, "entered cells become remembered after leaving the circle")
		_check(map.fog_state(far_id) == MapData.FogState.VISIBLE, "the destination cell is visible inside the new circle")
		var unknown_visible_mismatch := 0
		for cell in map.cells:
			if map.fog_state(cell.id) == MapData.FogState.VISIBLE and not map.is_in_current_vision(cell.id):
				unknown_visible_mismatch += 1
		_check(unknown_visible_mismatch == 0, "VISIBLE is reserved for cells inside the current circle")

	# 事件/侦察揭示 POI 时同步到迷雾，HUD 可据此显示标记。
	if not map.poi_ids.is_empty():
		var poi_cell: int = map.poi_ids[0]
		GameManager.reveal_poi(poi_cell)
		_check(map.is_poi_known(poi_cell), "revealed POI is marked known on the fog map")


func _test_hidden_tasks() -> void:
	print("-- hidden tasks --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "hidden task test config exists")
		return
	_check(_start_game("qing_heng", configs[0]), "hidden task test run starts")
	var player_candidates := GameManager.get_player_hidden_task_candidates()
	var ai_task := GameManager.get_ai_hidden_task()
	var qing_candidates := GameManager.mvp_hidden_task_ids("qing_heng")
	_check(qing_candidates.size() == 2, "character exposes exactly two MVP hidden task candidates")
	_check(player_candidates == qing_candidates, "player side only records the chosen character's candidates")
	_check(player_candidates.size() == 2, "player candidates are recorded but not narrowed to one AI task")
	_check(not ai_task.is_empty(), "AI receives a hidden task at game start")
	_check(String(ai_task.get("character_id", "")) == GameManager.ai_character_id, "AI hidden task belongs to the AI character")
	_check(bool(ai_task.get("mvp_available", false)), "AI hidden task is MVP-enabled")
	_check(GameManager.ai_hidden_task_id == String(ai_task.get("id", "")), "AI hidden task ID is stored on the game state")

	# 背包装备摘要：同类物品合并计数；装备直接显示名称。
	var sha := ActorState.from_character(DataManager.get_record("characters", "sha_kai"))
	_check(sha.equipment_text() == "马匪弯刀", "equipment summary shows equipped item names")
	sha.add_item("herb", 2)
	sha.add_item("pelt")
	_check(sha.inventory_text() == "草药 ×2、兽皮", "inventory summary merges duplicate items in insertion order")
	var qing := ActorState.from_character(DataManager.get_record("characters", "qing_heng"))
	_check(qing.inventory_text() == "药水" and qing.equipment_text() == "无", "empty equipment and starting potion are shown correctly")

	var invalid_character_tasks := 0
	for character in DataManager.all_records("characters"):
		var character_id := String(character.get("id", ""))
		var candidates := GameManager.mvp_hidden_task_ids(character_id)
		if candidates.size() != 2:
			invalid_character_tasks += 1
		for task_id in candidates:
			var task := DataManager.get_record("hidden_tasks", task_id)
			if String(task.get("character_id", "")) != character_id or not bool(task.get("mvp_available", false)):
				invalid_character_tasks += 1
	_check(invalid_character_tasks == 0, "every character has two valid MVP hidden task candidates")


## 固定侦察骰子：让下一次 roll_2d6("scout") 得到指定点数和。
func _seed_scout_natural(target: int) -> bool:
	var rng := RNGManager.get_stream("scout")
	for candidate in range(1, 512):
		rng.seed = candidate
		var a := rng.randi_range(1, 6)
		var b := rng.randi_range(1, 6)
		if a + b == target:
			rng.seed = candidate
			return true
	return false


func _west_east_gradient_score(map: MapData) -> float:
	# 西侧三分之一 vs 东侧三分之一：沙漠占比差 + 森林占比差，0 表示完全无梯度。
	var west_desert := 0
	var west_total := 0
	var east_forest := 0
	var east_total := 0
	for cell in map.cells:
		var nx := (cell.center.x - map.bounds.position.x) / maxf(map.bounds.size.x, 1.0)
		if nx < 0.34:
			west_total += 1
			if cell.terrain == "desert":
				west_desert += 1
		elif nx > 0.66:
			east_total += 1
			if cell.terrain == "forest":
				east_forest += 1
	var west_share := float(west_desert) / float(maxi(west_total, 1))
	var east_share := float(east_forest) / float(maxi(east_total, 1))
	return west_share + east_share


## 同伴 AI 与 4X 事件：任务驱动、相邻互动、情报分级、情境权重与结果提示。
func _test_companion_and_events() -> void:
	print("-- companion AI / 4X events --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "companion test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "companion test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	_check(companion != null, "start_new_game creates a companion")
	if companion == null:
		return
	var start_distance := map.graph_distance(map.start_id, companion.actor.cell_id)
	_check(companion.actor != null and companion.actor.cell_id != map.start_id and start_distance >= 3 and start_distance <= 6, "companion starts 3..6 cells away on another path")
	_check(not companion.task.is_empty(), "companion receives a hidden task at game start")
	_check(companion.faction == String(companion.task.get("initial_faction", "neutral")), "companion faction is driven by her hidden task")
	var favor_band: Array = companion.task.get("initial_favor", [0, 0])
	if favor_band.size() >= 2:
		var low := mini(int(favor_band[0]), int(favor_band[1]))
		var high := maxi(int(favor_band[0]), int(favor_band[1]))
		_check(companion.favor >= low and companion.favor <= high, "companion initial favor stays inside the configured band")
	var opening_log := GameManager.get_world_log()
	_check(not opening_log.is_empty() and "走散" in opening_log[0], "world chronicle records the journey start")
	_check(EventManager.get_reveal_level() == 0, "companion intel starts hidden from the player")

	var adjacency := map.neighbors_of(player.cell_id)
	_check(not adjacency.is_empty(), "player start has a neighboring cell for AI interaction")
	if adjacency.is_empty():
		return
	var beside := int(adjacency[0])

	# 友方任务：相邻时主动分享草药，既改变玩家背包也完成她自己的目标。
	var friend := CompanionAI.new()
	_check(friend.setup(DataManager.get_record("characters", "qing_heng"), "qing_share_herb", beside, RNGManager.get_stream("ai")), "friendly companion setup succeeds")
	friend.actor.add_item("herb", 1)
	var herbs_before := player.item_count("herb")
	var friendly_report := friend.take_turn(map, player, GameManager.round_index, true)
	_check(player.item_count("herb") == herbs_before + 1, "friendly companion shares a herb with an adjacent player")
	_check(not friend.actor.has_item("herb"), "shared herb leaves the companion inventory")
	_check(bool(friendly_report.get("task_completed", false)), "sharing the herb completes her personal task")
	_check(not (friendly_report.get("messages", []) as Array).is_empty(), "visible AI actions produce chronicle text")

	# 支援意图不等于“永远跟在玩家身后”，但离得远（>3 格）时必须先靠近：
	# 玩家要能看见她在移动，也要能在听觉范围内听到她说话。
	var support_friend := CompanionAI.new()
	var support_cell := -1
	for cell in map.cells:
		if cell.id == player.cell_id or cell.id == map.goal_id:
			continue
		var support_distance := map.graph_distance(player.cell_id, cell.id)
		if support_distance >= 4:
			support_cell = cell.id
			break
	if support_cell >= 0:
		_check(support_friend.setup(DataManager.get_record("characters", "sha_kai"), "sha_keep_player_alive", support_cell, RNGManager.get_stream("ai")), "support companion setup succeeds away from the player")
		support_friend.actor.hp = support_friend.actor.hp_max
		# 固定高速度，让测试不依赖本回合 1d6 的随机值；只验证“会靠近”和移动上限。
		support_friend.actor.attributes["speed"] = 12
		support_friend.turns_taken = 2
		var support_before := map.graph_distance(support_friend.actor.cell_id, player.cell_id)
		var support_report := support_friend.take_turn(map, player, GameManager.round_index, true)
		var support_after := map.graph_distance(support_friend.actor.cell_id, player.cell_id)
		_check(String(support_report.get("intent", "")) == "support", "support-intent companion keeps her support intent")
		_check(support_friend.activity.contains("向你靠拢"), "distant support companion moves to close the gap")
		_check(support_after < support_before, "distant support companion actually reduces the distance")
		_check(CompanionAI.MAX_MOVES_PER_TURN >= 4, "companion may cross several cells in one turn")
		_check(not String(support_report.get("speech", "")).strip_edges().is_empty(), "companion turn produces a spoken line")
		_check(not (support_report.get("messages", []) as Array).is_empty(), "proactive companion action is visible in the chronicle")

		# 友好地图任务直接朝终点前的最短路区段侦察，而不是站在玩家身边空转。
		var map_mate := CompanionAI.new()
		_check(map_mate.setup(DataManager.get_record("characters", "lin_xiao"), "lin_map_before_goal", support_cell, RNGManager.get_stream("ai")), "friendly map-task companion setup succeeds")
		map_mate.actor.hp = map_mate.actor.hp_max
		_check(map_mate._choose_intent(map, player) == "scout", "friendly map-task companion scouts the goal-front route")
		map_mate.actor.cell_id = beside
		_check(map_mate._choose_intent(map, player) == "scout", "friendly map-task companion keeps scouting until the route is mapped")

	# 敌方任务：相邻时偷窃，物品与任务进度都转给 AI。
	var enemy := CompanionAI.new()
	_check(enemy.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "enemy companion setup succeeds")
	player.inventory.clear()
	player.equipment.clear()
	player.add_item("rare_charm", 1)
	player.attributes["perception"] = -100
	var theft_report := enemy.take_turn(map, player, GameManager.round_index, true)
	_check(not player.has_item("rare_charm"), "enemy companion steals an adjacent player's item")
	_check(enemy.actor.has_item("rare_charm"), "stolen item moves into the companion inventory")
	_check(bool(theft_report.get("task_completed", false)), "successful theft completes her personal task")
	# D-25：每回合一次免费感知检定 DC 12；成功归还物品、好感 -3，任务完成不回溯。
	var theft_round := GameManager.round_index
	player.attributes["perception"] = -100
	var failed_recovery := enemy.attempt_recover_stolen_item(player, theft_round)
	_check(not bool(failed_recovery.get("success", true)), "a low-perception recovery check fails")
	_check(enemy.has_stolen_item(), "a failed recovery leaves the item with the thief")
	var repeat_recovery := enemy.attempt_recover_stolen_item(player, theft_round)
	_check(not bool(repeat_recovery.get("ok", true)) and String(repeat_recovery.get("message", "")).contains("本回合"), "only one recovery check is allowed per round")
	# 偷窃本身已把好感压到下限 -5；抬回中间值，单独验证追回的 -3 修正。
	enemy.favor = 0
	GameManager.round_index = theft_round + 1
	player.attributes["perception"] = 20
	var recovery_report := enemy.attempt_recover_stolen_item(player, GameManager.round_index)
	_check(bool(recovery_report.get("success", false)), "a high-perception player recovers the stolen item next round")
	_check(not enemy.actor.has_item("rare_charm"), "recovered item leaves the thief's inventory")
	_check(enemy.favor == -3, "recovering the item costs 3 companion favor")
	_check(enemy._task_completed, "recovery does not undo the completed theft task")
	_check(not enemy.has_stolen_item(), "theft tracking clears after a successful recovery")
	GameManager.round_index = theft_round
	player.attributes["perception"] = 4

	# 关系：ai_favor 立即改变好感；情报不足时只给模糊描述。
	GameManager.companion = friend
	EventManager.reset_state()
	friend.favor = 2
	friend.faction = "friendly"
	var favor_before := friend.favor
	var favor_result := EventManager._apply_effects([{"type": "ai_favor", "value": 1}])
	_check(friend.favor == favor_before + 1, "ai_favor effects change companion favor")
	var favor_messages: Array = favor_result.get("messages", [])
	_check(not favor_messages.is_empty() and not String(favor_messages[-1]).contains("+1"), "intel 0 hides the exact companion favor")
	EventManager.grant_ai_reveal(1)
	var detailed_result := EventManager._apply_effects([{"type": "ai_favor", "value": 1}])
	var detailed_messages: Array = detailed_result.get("messages", [])
	var detailed_favor_text := " ".join(detailed_messages)
	_check(detailed_favor_text.contains("好感 +1"), "intel 1 reveals the companion favor change")
	_check(friend.favor == 4 and friend.bond_label() == "信赖", "favor 4 exposes the trust bond label")
	_check(bool(friend.favor_milestones.get("trust_supply", false)), "reaching trust grants the companion milestone")
	_check(detailed_favor_text.contains("补给"), "trust milestone message explains the supply gift")
	var supplies_after_milestone := player.item_count("supply")
	var duplicate_milestone := friend.check_favor_milestone()
	_check(duplicate_milestone.is_empty() and player.item_count("supply") == supplies_after_milestone, "companion trust milestone pays only once")
	var relation_text := GameManager.companion_relation_text()
	_check(relation_text.contains("信赖"), "companion relation line shows the bond label without exact favor")
	_check(not relation_text.contains("好感"), "qualitative bond label does not require high intel")

	# 事件直接波及同伴：仅在相邻时生效。
	friend.actor.cell_id = beside
	var friend_hp := friend.actor.hp
	var ai_messages := EventManager._apply_ai_effects([{"type": "hp", "value": -1}])
	_check(friend.actor.hp == friend_hp - 1, "event ai_effects damage an adjacent companion")
	_check(not ai_messages.is_empty(), "event result reports companion damage")

	# 4X 情境权重与局势说明。
	player.hp = 1
	EventManager.reset_state()
	var beneficial: Dictionary = DataManager.get_record("events", "old_well")
	var dangerous: Dictionary = DataManager.get_record("events", "bandit_ambush")
	_check(EventManager._context_weight(beneficial) > 1.0, "low HP raises the weight of beneficial events")
	_check(EventManager._context_weight(dangerous) < 1.0, "low HP lowers the weight of dangerous events")
	var context_note := EventManager.get_context_note()
	_check(context_note.contains("负伤") and context_note.contains(GameManager.companion_name()), "event context note explains wounds and companion presence")
	GameManager.round_index = GameManager.MAX_ROUNDS - 5
	context_note = EventManager.get_context_note()
	_check(context_note.contains("日落"), "event context note warns about remaining rounds")
	GameManager.round_index = 1
	player.hp = player.hp_max

	# 选择提示只保留风险等级；成功/失败细节与致命警告不得提前出现。
	EventManager.reset_state()
	var bandit_event: Dictionary = DataManager.get_record("events", "bandit_ambush")
	var fight_choice: Dictionary = {}
	for raw_choice in bandit_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "fight":
			fight_choice = choice
	player.hp = 1
	var fight_info := EventManager._describe_choice(fight_choice)
	_check(String(fight_info.get("risk", "")) == "中", "bandit fight is marked medium risk")
	_check(not fight_info.has("hint") and not fight_info.has("preview") and not fight_info.has("warning"), "low HP no longer leaks success/failure or lethality before choosing")
	player.hp = player.hp_max
	var wanderer_event: Dictionary = DataManager.get_record("events", "wanderer")
	var talk_choice: Dictionary = {}
	for raw_choice in wanderer_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "talk":
			talk_choice = choice
	var talk_info := EventManager._describe_choice(talk_choice)
	_check(String(talk_info.get("risk", "")) == "低", "a low-DC social check without severe failure is marked low risk")

	# AI 侧效应只在结算时报告，不在选择前提示。
	var caravan: Dictionary = DataManager.get_record("events", "caravan")
	var steal_choice: Dictionary = {}
	for raw_choice in caravan.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "steal":
			steal_choice = choice
	GameManager.companion = friend
	friend.actor.cell_id = beside
	friend.alive = true
	var steal_info := EventManager._describe_choice(steal_choice)
	_check(not steal_info.has("warning") and not steal_info.has("preview"), "companion side effects are not previewed before choosing")
	var hp_before_outcome := friend.actor.hp
	var outcome := EventManager._resolve_outcome(steal_choice, "fail", {})
	var outcome_messages: Array = outcome.get("effect_messages", [])
	var outcome_text := ""
	for message in outcome_messages:
		outcome_text += String(message) + " "
	_check(friend.actor.hp == hp_before_outcome - 1, "caravan failure also hurts an adjacent companion")
	_check(outcome_text.contains(GameManager.companion_name()), "event result text reports the companion injury")
	player.remove_flag("wanted")

	# GameManager 回合接线：同伴行动写入纪事并刷新最后已知位置。
	_check(_start_game("lin_xiao", configs[0]), "companion turn run starts")
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	var turn_ai := CompanionAI.new()
	var turn_cell := int(map.neighbors_of(player.cell_id)[0])
	_check(turn_ai.setup(DataManager.get_record("characters", "qing_heng"), "qing_share_herb", turn_cell, RNGManager.get_stream("ai")), "turn companion setup succeeds")
	turn_ai.actor.add_item("herb", 1)
	turn_ai.last_known_cell = turn_cell
	turn_ai.last_known_round = GameManager.round_index
	GameManager.companion = turn_ai
	var log_before := GameManager.get_world_log().size()
	GameManager._run_companion_turn()
	_check(GameManager.get_world_log().size() > log_before, "GameManager runs the companion each round and logs her action")
	_check(turn_ai.last_known_cell == turn_ai.actor.cell_id and turn_ai.last_known_round == GameManager.round_index, "a visible companion refreshes her last known position")

	# 多回合推演：AI 不依赖玩家指令，持续朝自己的目标行动。
	var runner := CompanionAI.new()
	var runner_start := int(map.neighbors_of(player.cell_id)[0])
	_check(runner.setup(DataManager.get_record("characters", "ying"), "ying_reach_goal_first", runner_start, RNGManager.get_stream("ai")), "runner companion setup succeeds")
	var runner_origin := runner.actor.cell_id
	for round_no in range(1, 7):
		runner.take_turn(map, player, round_no, true)
	_check(runner.turns_taken == 6, "companion acts once per simulated round")
	_check(runner.actor.cell_id != runner_origin or runner.reached_goal, "companion keeps advancing toward her own goal")

	# 离开视野且超过记忆回合后，HUD 只保留模糊的踪迹。
	var player_center := map.cell_center(player.cell_id)
	var far_cell := -1
	for cell in map.cells:
		if map.graph_distance(player.cell_id, cell.id) > 4 and cell.center.distance_to(player_center) > GameManager.vision_radius_world() * 1.5:
			far_cell = cell.id
			break
	_check(far_cell >= 0, "map has a cell far outside the companion memory radius")
	if far_cell >= 0:
		# 听觉范围：4 格外不能隔空听见台词，地图也只能显示最后已知位置。
		turn_ai.last_speech = "测试暗号"
		turn_ai.actor.cell_id = far_cell
		_check(not GameManager.companion_is_heard(), "a far companion is outside hearing range")
		var far_speech := GameManager.companion_speech_text()
		_check(far_speech.contains("听不见") and not far_speech.contains("测试暗号"), "far companion speech is not audible")
		_check(GameManager.companion_marker_state() == "last_known", "far companion marker falls back to the last known cell")
		# 3 格内但看不见：能听见她，标记跟随她的真实位置而不是旧点位。
		var near_cell := -1
		for cell in map.cells:
			var near_distance := map.graph_distance(player.cell_id, cell.id)
			if near_distance >= 2 and near_distance <= GameManager.COMPANION_HEARING_RANGE:
				near_cell = cell.id
				break
		if near_cell >= 0:
			var saved_radius := map.vision_radius_world
			map.vision_radius_world = 0.0
			turn_ai.actor.cell_id = near_cell
			_check(not GameManager.companion_is_visible(), "a nearby companion can still be outside the circle")
			_check(GameManager.companion_is_heard(), "a companion within 3 cells is audible")
			var near_speech := GameManager.companion_speech_text()
			_check(near_speech.contains("测试暗号") and near_speech.contains("雾里传来"), "nearby but unseen companion is heard, not seen")
			_check(GameManager.companion_marker_state() == "heard", "nearby unheard-of companion is drawn as a heard marker")
			_check(GameManager.companion_marker_cell() == near_cell, "heard marker follows her actual moving position")
			map.vision_radius_world = saved_radius
		turn_ai.actor.cell_id = far_cell
		GameManager.round_index = turn_ai.last_known_round + GameManager.COMPANION_MEMORY_ROUNDS + 1
		_check(not GameManager.companion_is_visible(), "a companion outside the circle is not shown live")
		_check(GameManager.companion_status_text() == "踪迹已经模糊", "an old sighting fades into a vague trail")
		_check(GameManager.companion_last_known_text() == "情报不足", "low intel hides the last-known direction")
		GameManager.round_index = 1

	# 纪事有上限，避免长局把 UI 撑爆。
	for i in range(GameManager.WORLD_LOG_LIMIT + 5):
		GameManager.add_world_log("封测记录 %d" % i)
	var capped_log := GameManager.get_world_log()
	_check(capped_log.size() == GameManager.WORLD_LOG_LIMIT, "world chronicle keeps only the latest entries")
	_check(capped_log[capped_log.size() - 1].ends_with("封测记录 %d" % (GameManager.WORLD_LOG_LIMIT + 4)), "world chronicle keeps the newest entry")


## AP / 事件 / 侦察 / 战斗公式必须逐项标出来源（骰子、属性、装备名、状态名、天赋）。
func _test_formula_sources() -> void:
	print("-- formula source labels --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "formula test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "formula test run starts")
	EventManager.random_events_enabled = false
	var player := GameManager.player
	var breakdown := player.check_breakdown("perception")
	var equipment_parts: Array = breakdown.get("equipment_parts", [])
	var telescope_part: Dictionary = {}
	for part in equipment_parts:
		if String(part.get("name", "")) == "望远镜":
			telescope_part = part
	_check(
		not telescope_part.is_empty() and int(telescope_part.get("value", 0)) == 1,
		"check breakdown names the telescope as +1 perception"
	)
	var formula := player.check_formula_text("perception", 7, "感知")
	print("  check formula: " + formula)
	_check(formula.contains("2d6（7）"), "check formula shows the actual 2d6 result")
	_check(formula.contains("4（感知）"), "check formula names the base attribute")
	_check(formula.contains("1（望远镜）"), "check formula names the equipment source")

	player.add_status("poisoned", 3, GameManager.round_index)
	var poisoned_formula := player.check_formula_text("perception", 7, "感知")
	print("  poisoned formula: " + poisoned_formula)
	_check(poisoned_formula.contains("- 1（中毒）"), "check formula names the status source")
	var poison_parts: Array = player.check_breakdown("perception").get("status_parts", [])
	_check(poison_parts.size() == 1 and String(poison_parts[0].get("name", "")) == "中毒", "status parts expose the poisoned source")

	var ap_roll := player.roll_ap("grassland")
	var ap_text := ActorState.ap_formula_text(ap_roll)
	print("  AP formula: " + ap_text)
	_check(ap_text.contains("1d6（") and ap_text.contains("（速度）"), "AP formula names the die and speed")
	player.equipment.append("mount")
	var mount_roll := player.roll_ap("grassland")
	var mount_text := ActorState.ap_formula_text(mount_roll)
	print("  AP formula with mount: " + mount_text)
	_check(mount_text.contains("1（坐骑）"), "AP formula names each equipment bonus")
	var ap_payload := GameManager._ap_dice_payload(mount_roll, "AP 公式测试")
	_check(String(ap_payload.get("detail", "")).contains("（坐骑）"), "AP dice overlay receives the named formula")
	player.equipment.erase("mount")

	var herb_event: Dictionary = DataManager.get_record("events", "herb_patch")
	var gather_choice: Dictionary = {}
	for raw_choice in herb_event.get("choices", []):
		var choice: Dictionary = raw_choice
		if String(choice.get("id", "")) == "gather":
			gather_choice = choice
	var event_payload := EventManager._roll_check(gather_choice)
	var event_formula := String(event_payload.get("formula", ""))
	print("  event formula: " + event_formula)
	_check(
		event_formula.contains("2d6（") and event_formula.contains("（感知）")
			and event_formula.contains("（望远镜）") and event_formula.contains("- 1（中毒）"),
		"event formula labels dice, attribute, gear and status"
	)
	player.remove_status("poisoned")

	var fighter := ActorState.from_character(DataManager.get_record("characters", "sha_kai"))
	fighter.ap_deci = CombatRules.AP_COST_DECI
	var combat_parts := fighter.equipment_check_parts("combat")
	_check(
		combat_parts.size() == 1 and String(combat_parts[0].get("name", "")) == "马匪弯刀",
		"combat breakdown names the weapon"
	)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261025
	var attack := CombatRules.resolve_attack(fighter, player, rng)
	var attack_text := CombatRules.attack_formula_text(attack)
	print("  combat formula: " + attack_text)
	_check(attack_text.contains("（战斗）") and attack_text.contains("（马匪弯刀）"), "combat formula names the weapon bonus")
	_check(String(attack.get("dc_text", "")).contains("（体力）"), "combat formula explains the defense DC")


## 战斗检定、AI/玩家袭击、战斗面板状态机，以及先到奖励/完美胜利的分层判定。
func _test_combat_and_victory_tiers() -> void:
	print("-- combat / first arrival / victory tiers --")
	var attacker := ActorState.from_character(DataManager.get_record("characters", "sha_kai"))
	var defender := ActorState.from_character(DataManager.get_record("characters", "lin_xiao"))
	attacker.ap_deci = CombatRules.AP_COST_DECI
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261025
	var attack := CombatRules.resolve_attack(attacker, defender, rng)
	print("  combat roll=%s natural=%d total=%d dc=%d damage=%d" % [
		str(attack.get("dice", [])), int(attack.get("natural", 0)),
		int(attack.get("total", 0)), int(attack.get("dc", 0)), int(attack.get("damage", 0)),
	])
	_check(bool(attack.get("ok", false)), "combat attack resolves with enough AP")
	_check(attacker.ap_deci == 0, "attacking spends exactly 1 AP before consequences")
	_check(attacker.equipment_defense_bonus() == 1, "equipment defense bonus counts combat equipment")
	_check(CombatRules.defense_dc(attacker) == 14, "defense DC = 8 + stamina + equipment bonus")
	_check(CombatRules.defense_dc(defender) == 10, "non-combat equipment does not inflate defense DC")
	_check((attack.get("dice", []) as Array).size() == 2, "attack exposes both d6 for the panel")
	attacker.ap_deci = 5
	var no_ap := CombatRules.resolve_attack(attacker, defender, rng)
	_check(not bool(no_ap.get("ok", false)) and attacker.ap_deci == 5, "attack without 1 AP is rejected without mutation")

	var configs := MapConfigLoader.list_configs()
	_check(_start_game("lin_xiao", configs[0]), "combat test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	player.hp_max = 30
	player.hp = 30
	player.ap_deci = 100
	var beside: int = map.neighbors_of(player.cell_id)[0]
	var enemy := CompanionAI.new()
	_check(enemy.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "enemy attacker setup succeeds")
	enemy._task_completed = true
	enemy.faction = "enemy"
	enemy.actor.hp = enemy.actor.hp_max
	GameManager.companion = enemy
	GameManager._run_companion_turn()
	var enemy_combat := enemy.last_combat
	_check(not enemy_combat.is_empty() and bool(enemy_combat.get("ok", false)), "enemy companion attacks an adjacent player")
	_check(not (enemy_combat.get("lines", []) as Array).is_empty(), "enemy attack exposes readable combat lines")
	_check(GameManager.state == GameManager.State.PLAYING, "auto-resolved combat returns to PLAYING")

	_check(_start_game("lin_xiao", configs[0]), "player attack test run starts")
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	player.hp_max = 30
	player.hp = 30
	player.ap_deci = 100
	var beside2: int = map.neighbors_of(player.cell_id)[0]
	var target := CompanionAI.new()
	_check(target.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside2, RNGManager.get_stream("ai")), "player attack target setup succeeds")
	target._task_completed = true
	target.faction = "enemy"
	target.actor.hp = target.actor.hp_max
	target.actor.ap_deci = 100
	GameManager.companion = target
	_check(GameManager.can_attack_companion(), "adjacent hostile companion can be attacked")
	var target_hp := target.actor.hp
	var target_ap := target.actor.ap_deci
	var player_ap_before := player.ap_deci
	var player_attack := GameManager.player_attack_companion()
	_check(bool(player_attack.get("ok", false)), "player attack resolves")
	_check(player.ap_deci <= player_ap_before - CombatRules.AP_COST_DECI, "player attack deducts at least 1 AP")
	_check(target.actor.hp < target_hp or not target.alive or target.actor.ap_deci < target_ap, "target loses HP or AP in the exchange")
	_check(GameManager.state == GameManager.State.PLAYING, "auto-resolved player attack returns to PLAYING")

	# 交互式状态机：面板等待选择，选择后显示结果，关闭后恢复行动。
	_check(_start_game("lin_xiao", configs[0]), "interactive combat test run starts")
	GameManager.combat_interactive = true
	GameManager._handle_companion_combat({"lines": ["测试袭击"], "source": "companion"}, false)
	_check(GameManager.state == GameManager.State.COMBAT, "combat prompt enters COMBAT state")
	_check(bool(GameManager.combat_payload.get("show_choice", false)), "combat prompt offers counter/endure")
	GameManager.resolve_combat_choice("endure")
	_check(String(GameManager.combat_payload.get("stage", "")) == "resolved", "endure resolves the prompt")
	GameManager.close_combat()
	_check(GameManager.state == GameManager.State.PLAYING and GameManager.combat_payload.is_empty(), "closing combat restores PLAYING")
	GameManager.combat_interactive = false

	# 先到奖励：第一个到达者 +20；同回合并列均获得。
	_check(_start_game("lin_xiao", configs[0]), "perfect victory test run starts")
	GameManager.companion.reached_goal = true
	GameManager.companion.goal_round = GameManager.round_index - 1
	GameManager.companion.faction_at_goal = "friendly"
	GameManager.finish_victory("你抵达终点。")
	_check(GameManager.player_victory_tier == "perfect", "no enemy at the goal means perfect victory")
	_check(GameManager.player.gold == 40 and GameManager.first_goal_round == GameManager.round_index, "first arrival grants +20 gold")

	_check(_start_game("lin_xiao", configs[0]), "basic victory test run starts")
	GameManager.companion.reached_goal = true
	GameManager.companion.goal_round = 1
	GameManager.companion.faction_at_goal = "enemy"
	GameManager._record_goal_arrival("companion", GameManager.companion.actor, "影", "enemy")
	GameManager.round_index = 2
	GameManager.player.gold = 20
	var basic_result := {"reason": ""}
	GameManager.game_over.connect(func(_win: bool, reason: String) -> void: basic_result["reason"] = reason, CONNECT_ONE_SHOT)
	GameManager.finish_victory("你抵达终点。")
	_check(GameManager.player_victory_tier == "basic", "enemy already at the goal downgrades to basic victory")
	_check(GameManager.player.gold == 20, "late arrival does not receive the first-arrival reward")
	_check(String(basic_result["reason"]).contains("基础胜利") and String(basic_result["reason"]).contains("敌方同伴"), "basic victory explains the enemy preemption")

	_check(_start_game("lin_xiao", configs[0]), "same-round tie test run starts")
	GameManager.companion.reached_goal = true
	GameManager.companion.goal_round = GameManager.round_index
	GameManager.companion.faction_at_goal = "friendly"
	GameManager._record_goal_arrival("companion", GameManager.companion.actor, "青蘅", "friendly")
	GameManager.player.gold = 20
	GameManager.finish_victory("你抵达终点。")
	_check(GameManager.player.gold == 40, "same-round arrival still grants the first-arrival reward")
	_check(GameManager.goal_arrivals.size() == 2, "same-round arrivals are both recorded")
	_check(GameManager.player_victory_tier == "perfect", "friendly same-round arrival keeps perfect victory")

	_check(_start_game("lin_xiao", configs[0]), "enemy tie test run starts")
	GameManager.companion.reached_goal = true
	GameManager.companion.goal_round = GameManager.round_index
	GameManager.companion.faction_at_goal = "enemy"
	GameManager._record_goal_arrival("companion", GameManager.companion.actor, "影", "enemy")
	GameManager.finish_victory("你抵达终点。")
	_check(GameManager.player_victory_tier == "basic", "enemy same-round arrival invalidates perfect victory")


func _test_p0_exclusive_tasks() -> void:
	print("-- P0 exclusive tasks / hidden-task fidelity --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "exclusive-task test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "exclusive-task test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var beside := int(map.neighbors_of(player.cell_id)[0])

	# 影的偷窃任务初始为中立：她会主动寻找偷窃机会，但首次得手不立即判负，
	# 让 D-25 的失物追回在正常开局中真正可达。
	var theft_task := DataManager.get_record("hidden_tasks", "ying_steal_gear")
	_check(String(theft_task.get("initial_faction", "")) == "neutral", "Ying's theft task data starts neutral")
	var default_thief := CompanionAI.new()
	_check(default_thief.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "default thief setup succeeds")
	_check(default_thief.faction == "neutral", "default thief starts neutral")
	_check(default_thief._choose_intent(map, player) == "hunt", "neutral thief still hunts for a theft opportunity")

	# 设计 §11.3 的阵营阈值：−2～+2 中立，±3 才切换。
	var threshold_probe := CompanionAI.new()
	threshold_probe.favor = 2
	_check(threshold_probe._faction_from_favor() == "neutral", "favor +2 is still neutral")
	threshold_probe.favor = 3
	_check(threshold_probe._faction_from_favor() == "friendly", "favor +3 turns friendly")
	threshold_probe.favor = -2
	_check(threshold_probe._faction_from_favor() == "neutral", "favor −2 is still neutral")
	threshold_probe.favor = -3
	_check(threshold_probe._faction_from_favor() == "enemy", "favor −3 turns enemy")

	# 一次偷窃失败只到 −2，不应提前敌对；否则下一次得手会立即判负，
	# D-25 的追回窗口在正常开局里几乎不会出现。
	var neutral_fail := CompanionAI.new()
	_check(neutral_fail.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "neutral failing thief setup succeeds")
	neutral_fail.faction = "neutral"
	neutral_fail.favor = 0
	player.attributes["perception"] = 100
	player.equipment.clear()
	player.inventory.clear()
	player.equipment.append("bandit_blade")
	neutral_fail._try_steal(player)
	_check(neutral_fail.favor == -2 and neutral_fail.faction == "neutral", "one failed theft leaves the thief neutral")
	_check(not neutral_fail._task_completed and player.has_item("bandit_blade"), "the first failure keeps the theft task open for D-25")
	neutral_fail._try_steal(player)
	_check(neutral_fail.favor == -2 and neutral_fail.faction == "neutral", "repeated failures cannot skip the D-25 recovery window")
	player.attributes["perception"] = -100
	neutral_fail._try_steal(player)
	_check(neutral_fail._task_completed and neutral_fail.faction == "enemy", "the first success after repeated failures still completes the task")
	_check(not neutral_fail._player_defeated and String(neutral_fail._stolen_item_id) == "bandit_blade", "that success opens recovery instead of ending the run")
	player.attributes["perception"] = 0
	player.equipment.clear()
	player.inventory.clear()
	player.equipment.append("bandit_blade")

	# 影：武器/饰品优先，成功即完成；敌方时立即判负。
	var thief := CompanionAI.new()
	_check(thief.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "thief setup succeeds")
	thief.faction = "enemy"
	thief.favor = -5
	player.equipment.clear()
	player.inventory.clear()
	player.equipment.append("bandit_blade")
	player.add_item("potion", 1)
	player.add_item("pelt", 1)
	player.attributes["perception"] = -100
	var theft_report := thief.take_turn(map, player, 1, true)
	_check(not player.has_item("bandit_blade") and thief.actor.has_item("bandit_blade"), "thief prioritizes non-consumable equipment")
	_check(player.has_item("potion") and player.has_item("pelt"), "thief leaves consumables and materials when equipment is available")
	_check(bool(theft_report.get("task_completed", false)), "successful equipment theft completes the hidden task")
	_check(bool(theft_report.get("player_defeated", false)), "enemy thief defeating the player is reported immediately")
	_check(String(theft_report.get("defeat_reason", "")).contains("偷走"), "theft defeat explains what was taken")

	# 影：失败好感 −2；中立/友方成功只转敌，不立即判负。
	var thief_fail := CompanionAI.new()
	_check(thief_fail.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "failing thief setup succeeds")
	thief_fail.faction = "enemy"
	thief_fail.favor = -2
	player.attributes["perception"] = 100
	player.equipment.clear()
	player.inventory.clear()
	player.equipment.append("bandit_blade")
	thief_fail._try_steal(player)
	_check(thief_fail.favor == -4, "failed theft lowers favor by 2")
	_check(not thief_fail._task_completed and player.has_item("bandit_blade"), "failed theft keeps the task and the item")

	var thief_neutral := CompanionAI.new()
	_check(thief_neutral.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "neutral thief setup succeeds")
	thief_neutral.faction = "neutral"
	thief_neutral.favor = 0
	player.attributes["perception"] = -100
	thief_neutral._try_steal(player)
	_check(thief_neutral._task_completed, "neutral thief still completes her objective on success")
	_check(thief_neutral.faction == "enemy" and thief_neutral.favor == -5, "neutral thief turns enemy at favor −5")
	_check(not thief_neutral._player_defeated, "non-enemy thief does not immediately defeat the player")

	var thief_empty := CompanionAI.new()
	_check(thief_empty.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", beside, RNGManager.get_stream("ai")), "empty-pocket thief setup succeeds")
	thief_empty.faction = "enemy"
	thief_empty.favor = -5
	player.equipment.clear()
	player.inventory.clear()
	player.add_item("pelt", 1)
	var gold_before := player.gold
	thief_empty._try_steal(player)
	_check(not thief_empty._task_completed, "materials-only victims leave the theft task incomplete")
	_check(player.gold == gold_before and player.has_item("pelt"), "thief never takes gold or materials")

	# 薇拉：失败好感 −2；成功只施加 trapped，完成窗口延后。
	var wei := CompanionAI.new()
	_check(wei.setup(DataManager.get_record("characters", "wei_la"), "wei_trap_player", beside, RNGManager.get_stream("ai")), "trap companion setup succeeds")
	wei.faction = "enemy"
	wei.favor = -5
	player.statuses.clear()
	player.attributes["perception"] = -100
	wei.actor.ap_deci = 100
	wei._try_trap(player, 1)
	_check(player.has_status("trapped"), "successful trap applies trapped")
	_check(not wei._task_completed, "trap success does not complete the task at application")
	_check(not wei._player_defeated, "trap success alone does not immediately defeat the player")
	var trap_window := wei.accept_run_end(player, false)
	_check(bool(trap_window.get("completed", false)), "trap task completes when the run ends while the player is trapped")
	_check(bool(trap_window.get("player_defeated", false)), "enemy trap completion reports player defeat at the window")

	var wei_fail := CompanionAI.new()
	_check(wei_fail.setup(DataManager.get_record("characters", "wei_la"), "wei_trap_player", beside, RNGManager.get_stream("ai")), "failing trap companion setup succeeds")
	wei_fail.faction = "enemy"
	wei_fail.favor = -2
	player.statuses.clear()
	player.attributes["perception"] = 100
	wei_fail.actor.ap_deci = 100
	wei_fail._try_trap(player, 1)
	_check(not player.has_status("trapped"), "failed trap does not apply trapped")
	_check(wei_fail.favor == -4, "failed trap lowers favor by 2")
	_check(not wei_fail._task_completed, "failed trap leaves the task open")

	var wei_friendly := CompanionAI.new()
	_check(wei_friendly.setup(DataManager.get_record("characters", "wei_la"), "wei_trap_player", beside, RNGManager.get_stream("ai")), "friendly trap companion setup succeeds")
	wei_friendly.faction = "friendly"
	wei_friendly.favor = 3
	player.statuses.clear()
	player.attributes["perception"] = -100
	wei_friendly.actor.ap_deci = 100
	wei_friendly._try_trap(player, 1)
	_check(wei_friendly.favor == 3 and wei_friendly.faction == "friendly", "trap application does not change faction before the window")
	var friendly_window := wei_friendly.accept_run_end(player, false)
	_check(bool(friendly_window.get("completed", false)), "friendly trap still completes at the window")
	_check(wei_friendly.faction == "enemy" and wei_friendly.favor == -2, "friendly trap completion applies favor −5 and turns enemy")
	_check(not bool(friendly_window.get("player_defeated", false)), "friendly/neutral trap completion does not immediately defeat the player")
	player.statuses.clear()
	player.attributes["perception"] = 4

	# 青蘅：玩家背包满时保留草药、不完成、不扣分享次数。
	var qing := CompanionAI.new()
	_check(qing.setup(DataManager.get_record("characters", "qing_heng"), "qing_share_herb", beside, RNGManager.get_stream("ai")), "herb companion setup succeeds")
	qing.actor.add_item("herb", 1)
	player.equipment.clear()
	player.inventory.clear()
	for item_id in ["supply", "potion", "mount", "bandit_blade", "pelt", "ancient_coin", "rare_charm", "telescope"]:
		player.add_item(item_id, 1)
	_check(player.inventory_slot_count() == ActorState.INVENTORY_SLOT_LIMIT, "player backpack reaches 8 slots")
	_check(qing._interact_support(player, 1), "full-backpack share is still a handled interaction")
	_check(qing.actor.has_item("herb") and not qing._task_completed, "full backpack keeps the herb and leaves the task incomplete")
	_check(player.item_count("herb") == 0, "full backpack receives no herb")
	player.remove_item("telescope", 1)
	_check(qing._interact_support(player, 1), "share succeeds once a slot opens")
	_check(not qing.actor.has_item("herb") and qing._task_completed, "successful share transfers the herb and completes the task")
	_check(player.item_count("herb") == 1, "player receives the shared herb")

	# 林鸮：终点前 3 格 = 起点→终点最短路的最后 3 格（不含终点）。
	var lin := CompanionAI.new()
	_check(lin.setup(DataManager.get_record("characters", "lin_xiao"), "lin_map_before_goal", beside, RNGManager.get_stream("ai")), "map companion setup succeeds")
	lin._ensure_map_tasks(map)
	var goal_path := map.shortest_cell_path(map.start_id, map.goal_id)
	_check(goal_path.size() >= 4, "goal path has enough cells for the last-three rule")
	var expected_targets: Array[int] = []
	for i in range(goal_path.size() - 4, goal_path.size() - 1):
		expected_targets.append(goal_path[i])
	_check(lin._target_path_cells == expected_targets, "map task targets the last three cells before the goal")
	_check(not lin._target_path_cells.has(map.goal_id), "map task excludes the goal cell itself")
	lin._scouted_cells.clear()
	lin._scouted_cells[expected_targets[0]] = true
	lin._scouted_cells[expected_targets[1]] = true
	lin._refresh_map_task_progress()
	_check(not lin._check_map_task_completion(map, player), "two revealed target cells do not complete the map task")
	lin._scouted_cells[expected_targets[2]] = true
	lin._refresh_map_task_progress()
	_check(lin._check_map_task_completion(map, player), "all three target cells complete the map task")

	var goal_lin := CompanionAI.new()
	_check(goal_lin.setup(DataManager.get_record("characters", "lin_xiao"), "lin_reveal_goal_first", beside, RNGManager.get_stream("ai")), "goal-reveal companion setup succeeds")
	map.get_cell(map.goal_id).seen = false
	player.cell_id = beside
	goal_lin._scouted_cells[map.goal_id] = true
	goal_lin._update_scout_task(map, player)
	_check(goal_lin._goal_revealed_by_ai and goal_lin._task_completed, "revealing the goal before the player completes the information task")

	var late_lin := CompanionAI.new()
	_check(late_lin.setup(DataManager.get_record("characters", "lin_xiao"), "lin_reveal_goal_first", beside, RNGManager.get_stream("ai")), "late goal-reveal companion setup succeeds")
	map.get_cell(map.goal_id).seen = true
	late_lin._scouted_cells[map.goal_id] = true
	late_lin._update_scout_task(map, player)
	_check(late_lin._task_failed and not late_lin._task_completed, "goal already known to the player fails the reveal-first task")

	# 沙铠：只认非初始可交易物；任务物品不会被自动丢弃。
	var sha := CompanionAI.new()
	_check(sha.setup(DataManager.get_record("characters", "sha_kai"), "sha_carry_tradable", beside, RNGManager.get_stream("ai")), "carry companion setup succeeds")
	sha.actor.equipment.clear()
	sha.actor.inventory.clear()
	sha.actor.equipment.append("bandit_blade")
	_check(not sha._has_tradable(), "initial blade does not count as a tradable quest item")
	sha.actor.add_item("pelt", 1)
	_check(sha._has_tradable(), "pelt satisfies the carry task")
	sha.actor.inventory.clear()
	sha.actor.inventory.append("pelt")
	sha.actor.inventory.append("ancient_coin")
	sha.actor.inventory.append("herb")
	_check(not sha._add_item("rare_charm"), "full AI bag cannot accept an extra protected item")
	_check(sha.actor.has_item("pelt") and sha.actor.has_item("ancient_coin"), "protected task items are never auto-dropped")
	sha.actor.inventory[2] = "telescope"
	_check(sha._add_item("rare_charm"), "a non-task item is dropped to make room")
	_check(sha.actor.has_item("pelt") and sha.actor.has_item("ancient_coin") and sha.actor.has_item("rare_charm"), "task items survive the bag cleanup")
	sha.actor.cell_id = map.goal_id
	sha.actor.attributes["combat"] = 100
	sha._goal_cooldown = 0
	sha._attempt_goal(map, player, 1)
	_check(sha.reached_goal and sha._task_completed, "carrying a tradable to the goal completes the task")

	var carry_intent := CompanionAI.new()
	_check(carry_intent.setup(DataManager.get_record("characters", "sha_kai"), "sha_carry_tradable", beside, RNGManager.get_stream("ai")), "carry-intent companion setup succeeds")
	carry_intent.faction = "friendly"
	carry_intent.actor.hp = carry_intent.actor.hp_max
	_check(carry_intent._choose_intent(map, player) == "explore", "carry companion searches before heading to the goal empty-handed")
	carry_intent.actor.add_item("herb", 1)
	_check(carry_intent._choose_intent(map, player) == "goal", "carry companion heads to the goal once a tradable is held")

	# GameManager 接线：敌方偷窃成功立即结束本局；薇拉在终点窗口可把胜利改判为失败。
	_check(_start_game("lin_xiao", configs[0]), "theft-defeat run starts")
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	player.equipment.clear()
	player.inventory.clear()
	player.equipment.append("bandit_blade")
	player.attributes["perception"] = -100
	var run_thief := CompanionAI.new()
	var thief_cell := int(map.neighbors_of(player.cell_id)[0])
	_check(run_thief.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", thief_cell, RNGManager.get_stream("ai")), "run thief setup succeeds")
	run_thief.faction = "enemy"
	run_thief.favor = -5
	GameManager.companion = run_thief
	var defeat_result := {"win": true, "reason": ""}
	var on_defeat := func(win: bool, reason: String) -> void:
		defeat_result["win"] = win
		defeat_result["reason"] = reason
	GameManager.game_over.connect(on_defeat, CONNECT_ONE_SHOT)
	GameManager._run_companion_turn()
	_check(not bool(defeat_result["win"]), "enemy theft immediately ends the run in defeat")
	_check(GameManager.state == GameManager.State.GAME_OVER, "theft defeat enters GAME_OVER")
	_check(String(defeat_result["reason"]).contains("偷走"), "theft defeat reason names the stolen item")
	_check(not SaveManager.has_save(SaveManager.DEFAULT_SLOT), "defeat clears the autosave slot")

	_check(_start_game("lin_xiao", configs[0]), "trap-window victory run starts")
	EventManager.random_events_enabled = false
	map = GameManager.map
	player = GameManager.player
	var last_wei := CompanionAI.new()
	_check(last_wei.setup(DataManager.get_record("characters", "wei_la"), "wei_trap_player", int(map.neighbors_of(player.cell_id)[0]), RNGManager.get_stream("ai")), "final trap companion setup succeeds")
	last_wei.faction = "enemy"
	last_wei.favor = -5
	GameManager.companion = last_wei
	player.cell_id = map.goal_id
	player.add_status("trapped", 2, GameManager.round_index)
	var trap_result := {"win": true, "reason": ""}
	var on_trap_result := func(win: bool, reason: String) -> void:
		trap_result["win"] = win
		trap_result["reason"] = reason
	GameManager.game_over.connect(on_trap_result, CONNECT_ONE_SHOT)
	GameManager.finish_victory("你抵达终点。")
	_check(not bool(trap_result["win"]), "enemy trap at the goal window overrides the victory")
	_check(String(trap_result["reason"]).contains("绳套"), "trap-window defeat explains the trap")


func _test_inventory_overflow_and_recovery() -> void:
	print("-- A3 inventory overflow / D-25 recovery integration --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "overflow test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "overflow test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	player.equipment.clear()
	player.inventory.clear()
	GameManager.pending_item_overflows.clear()

	# 未知物品 ID 必须在入口被拒绝，不能进入背包或溢出队列。
	var inventory_before_invalid := player.inventory.duplicate()
	var invalid_item := GameManager.grant_item("not_a_real_item", 1, "测试")
	_check(not bool(invalid_item.get("ok", true)) and not bool(invalid_item.get("queued", true)), "unknown item IDs are rejected")
	_check(player.inventory == inventory_before_invalid and not GameManager.has_pending_item_overflow(), "rejected items change neither inventory nor overflow queue")

	# A3：8 格满后，第九件不同物品先排队；同种物品仍可叠加。
	for item_id in ["supply", "potion", "herb", "mount", "pelt", "ancient_coin", "rare_charm", "telescope"]:
		player.add_item(item_id, 1)
	_check(player.inventory_slot_count() == ActorState.INVENTORY_SLOT_LIMIT, "A3 test fills all 8 backpack slots")
	var invalid_when_full := GameManager.grant_item("not_a_real_item", 1, "测试")
	_check(not bool(invalid_when_full.get("ok", true)) and not bool(invalid_when_full.get("queued", true)), "unknown item IDs are rejected even when the backpack is full")
	_check(not GameManager.has_pending_item_overflow(), "rejected unknown items never enter the overflow queue")
	var stacked := GameManager.grant_item("potion", 2, "测试")
	_check(bool(stacked.get("ok", false)) and not bool(stacked.get("queued", true)), "a stacked consumable is accepted at 8 slots")
	_check(player.item_count("potion") == 3 and player.inventory_slot_count() == 8, "stacking does not consume another slot")
	var queued := GameManager.grant_item("bandit_blade", 1, "POI")
	_check(bool(queued.get("ok", false)) and bool(queued.get("queued", false)), "a ninth item type is queued when the backpack is full")
	_check(not player.has_item("bandit_blade") and GameManager.has_pending_item_overflow(), "queued reward is not added before the player decides")
	var pending := GameManager.current_item_overflow()
	_check(String(pending.get("item_id", "")) == "bandit_blade" and String(pending.get("source", "")) == "POI", "pending overflow records the item and source")
	var bad_discard := GameManager.resolve_item_overflow("relic")
	_check(not bool(bad_discard.get("ok", true)) and GameManager.has_pending_item_overflow(), "discarding an item not in the backpack is rejected")
	var accepted := GameManager.resolve_item_overflow("pelt")
	_check(bool(accepted.get("ok", false)), "discarding a backpack item resolves the overflow")
	_check(player.has_item("bandit_blade") and not player.has_item("pelt"), "the discarded item is replaced by the queued reward")
	_check(not GameManager.has_pending_item_overflow(), "resolved overflow leaves the queue empty")
	var queued_again := GameManager.grant_item("relic", 1, "事件")
	_check(bool(queued_again.get("queued", false)), "a later reward can queue again after the backpack refills")
	var abandoned := GameManager.resolve_item_overflow("")
	_check(bool(abandoned.get("ok", false)), "refusing the queued item resolves the overflow")
	_check(not player.has_item("relic"), "refusing the overflow permanently loses the reward")
	_check(not GameManager.has_pending_item_overflow(), "abandoning leaves no pending overflow")
	_check(not bool(GameManager.resolve_item_overflow("").get("ok", true)), "resolving with an empty queue is rejected")

	# D-25：中立的影偷走装备后不立即判负；每回合一次免费感知检定，成功归还且好感 −3。
	player.inventory.clear()
	player.equipment.clear()
	player.equipment.append("bandit_blade")
	player.attributes["perception"] = -100
	var thief := CompanionAI.new()
	_check(thief.setup(DataManager.get_record("characters", "ying"), "ying_steal_gear", int(map.neighbors_of(player.cell_id)[0]), RNGManager.get_stream("ai")), "integration thief setup succeeds")
	_check(thief.faction == "neutral", "theft task starts neutral so its first success is recoverable")
	GameManager.companion = thief
	thief._try_steal(player)
	_check(thief.has_stolen_item() and not player.has_item("bandit_blade"), "neutral theft transfers the equipment to the thief")
	_check(String(GameManager.stolen_item_recovery_info().get("item_id", "")) == "bandit_blade", "GameManager exposes the stolen item recovery entry")
	var ap_before := player.ap_deci
	var failed := GameManager.recover_stolen_item()
	_check(bool(failed.get("ok", false)) and not bool(failed.get("success", true)), "a failed recovery check is reported as a check result")
	_check(player.ap_deci == ap_before, "the free recovery check costs no AP")
	_check(thief.has_stolen_item(), "a failed recovery leaves the item with the thief")
	var second_same_round := GameManager.recover_stolen_item()
	_check(not bool(second_same_round.get("ok", true)) and String(second_same_round.get("message", "")).contains("本回合"), "GameManager enforces one recovery check per round")
	GameManager.round_index += 1
	player.attributes["perception"] = 20
	# 偷窃已把好感压到 -5；抬回 -1，验证 D-25 的 -3 修正没有被下限掩盖。
	thief.favor = -1
	var favor_before_recovery := thief.favor
	var recovered := GameManager.recover_stolen_item()
	_check(bool(recovered.get("success", false)), "a high-perception recovery succeeds on the next round")
	_check(player.has_item("bandit_blade") and not thief.has_stolen_item(), "the recovered item returns to the player")
	_check(thief.favor == favor_before_recovery - 3, "GameManager applies the D-25 favor penalty")
	_check(thief._task_completed, "recovery leaves the thief's completed task untouched")
	_check(not bool(GameManager.stolen_item_recovery_info().get("available", true)), "the recovery entry disappears once the item is returned")
	_check(GameManager.last_move_message.contains("夺回"), "successful recovery is reported in the move log")
	_check(player.ap_deci == ap_before, "successful recovery also costs no AP")
	player.attributes["perception"] = 4


func _test_save_load() -> void:
	print("-- save / load --")
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		_check(false, "save/load test config exists")
		return
	_check(_start_game("lin_xiao", configs[0]), "save/load test run starts")
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	_check(companion != null, "save/load test has a companion")

	var neighbor_id := map.neighbors_of(player.cell_id)[0]
	player.cell_id = neighbor_id
	GameManager.visual_position = map.cell_center(neighbor_id) + Vector2(2.0, -1.0)
	GameManager.refresh_vision()
	player.hp = maxi(1, player.hp_max - 2)
	player.ap_deci = 37
	player.ap_max_deci = maxi(37, player.ap_max_deci)
	player.gold = 43
	player.add_item("bandit_blade")
	player.add_status("poisoned", 2, 7)
	player.flags["wanted"] = true
	player.pending_ap_penalty_deci = 8
	var expected_hp := player.hp
	GameManager.round_index = 7
	GameManager.add_world_log("存档测试标记。")
	GameManager.goal_arrivals.clear()
	GameManager.goal_arrivals.append({
		"actor": "player", "name": "你", "round": 6,
		"faction_at_arrival": "player", "rewarded": true,
	})
	GameManager.first_goal_round = 6
	GameManager.player_goal_round = 6
	GameManager.last_move_message = "存档测试消息"
	GameManager.last_scout_report = {"ok": true, "level": "success", "message": "测试侦察"}
	GameManager.last_scout_message = "测试侦察"
	GameManager.position_exposed_until_round = 9
	GameManager.vision_boost_cells = 1.5
	GameManager.vision_boost_hold_rounds = 2
	GameManager.refresh_vision()
	EventManager._cooldowns["caravan"] = 3
	EventManager._wander_ap_accum = 17
	EventManager._random_events_this_run = 17
	EventManager._reveal_level = 2
	EventManager._visited_pois["probe_poi"] = true
	EventManager._visited_regions[2] = true
	EventManager._revealed_pois[3] = true
	EventManager._recent_event_ids.clear()
	EventManager._recent_event_ids.append("caravan")
	companion.faction = "enemy"
	companion.favor = -3
	companion.actor.hp = maxi(1, companion.actor.hp_max - 1)
	companion.last_speech = "存档前的台词"
	companion.activity = "测试行动"
	companion.turns_taken = 4
	companion._scout_count = 2
	companion._support_cooldown = 1
	companion._task_completed = true
	companion._scouted_cells[map.start_id] = true
	companion._map_task_revealed_count = 2
	companion._goal_revealed_by_ai = true
	companion._goal_info_shared = true
	companion._task_failed = true
	companion.favor_milestones["trust_supply"] = true
	companion.visited_pois[map.start_id] = true
	companion.actor.add_item("rare_charm", 1)
	companion._stolen_item_id = "rare_charm"
	companion._recovery_attempt_round = 7
	GameManager.pending_item_overflows.clear()
	GameManager.pending_item_overflows.append({"item_id": "herb", "count": 1, "source": "存档测试"})
	var probe_index := (neighbor_id + 7) % map.cells.size()
	if probe_index == neighbor_id:
		probe_index = (probe_index + 1) % map.cells.size()
	var fog_cell := map.get_cell(probe_index)
	fog_cell.scouted = true
	fog_cell.entered = true
	fog_cell.poi_known = true
	var expected_checksum := _checksum(map)
	var expected_seen := 0
	for cell in map.cells:
		if cell.seen:
			expected_seen += 1
	var expected_goal := map.goal_id
	var expected_start := map.start_id
	var expected_generated_seed := map.generated_seed
	var expected_terrain_seed := map.terrain_seed

	_check(SaveManager.save_game("test_auto"), "safe boundary writes a save: %s" % SaveManager.last_error)
	_check(SaveManager.has_save("test_auto"), "slot reports an existing save")
	var peek := SaveManager.peek_save("test_auto")
	_check(not peek.is_empty(), "peek reads save metadata without loading")
	var peek_meta: Dictionary = peek.get("meta", {})
	_check(int(peek_meta.get("round", 0)) == 7, "save metadata records the current round")
	_check(String(peek.get("game_version", "")) == SaveManager.GAME_VERSION, "save metadata records the game version")

	# 存档后消耗随机数，再读档：下一条随机结果必须与存档点之后一致。
	var expected_event_roll := RNGManager.get_stream("event").randi()
	var expected_ai_roll := RNGManager.get_stream("ai").randi()
	GameManager.round_index = 1
	player.gold = -1
	player.hp = 1
	companion.faction = "friendly"
	RNGManager.get_stream("event").randi()

	var result := SaveManager.load_game("test_auto")
	_check(bool(result.get("ok", false)), "save loads successfully: %s" % String(result.get("error", "")))
	_check(GameManager.state == GameManager.State.PLAYING, "load returns to PLAYING")
	_check(not GameManager.intro_open, "load does not replay the intro")
	var loaded_map := GameManager.map
	var loaded_player := GameManager.player
	var loaded_companion := GameManager.companion
	_check(loaded_map != null and loaded_map != map, "load rebuilds a fresh map object")
	_check(_checksum(loaded_map) == expected_checksum, "map geometry, terrain, elevation and POIs match exactly")
	_check(loaded_map.generated_seed == expected_generated_seed, "map generated seed restored")
	_check(loaded_map.terrain_seed == expected_terrain_seed, "map terrain seed restored")
	_check(loaded_map.start_id == expected_start and loaded_map.goal_id == expected_goal, "start and goal restored")
	var loaded_seen := 0
	for cell in loaded_map.cells:
		if cell.seen:
			loaded_seen += 1
	_check(loaded_seen == expected_seen, "seen fog count restored (%d -> %d)" % [expected_seen, loaded_seen])
	var loaded_fog_cell := loaded_map.get_cell(fog_cell.id)
	_check(loaded_fog_cell.scouted and loaded_fog_cell.entered and loaded_fog_cell.poi_known, "scouted/entered/POI fog restored")
	_check(loaded_player != null and loaded_player != player, "load rebuilds a fresh player object")
	_check(loaded_player.cell_id == neighbor_id, "player cell restored")
	_check(loaded_player.gold == 43, "gold restored")
	_check(loaded_player.hp == expected_hp, "HP restored")
	_check(loaded_player.ap_deci == 37, "current AP restored")
	_check(loaded_player.ap_max_deci == player.ap_max_deci, "max AP restored")
	_check(loaded_player.has_item("bandit_blade"), "inventory restored")
	_check(loaded_player.has_status("poisoned"), "statuses restored")
	_check(int(loaded_player.statuses.get("poisoned", {}).get("remaining", 0)) == 2, "status duration restored")
	_check(bool(loaded_player.flags.get("wanted", false)), "story flags restored")
	_check(loaded_player.pending_ap_penalty_deci == 8, "pending AP penalty restored")
	_check(GameManager.round_index == 7, "round restored")
	_check(GameManager.get_world_log().has("第 7 回合 · 存档测试标记。"), "world chronicle restored")
	_check(GameManager.last_move_message == "存档测试消息", "last move message restored")
	_check(String(GameManager.last_scout_report.get("level", "")) == "success", "last scout report restored")
	_check(GameManager.is_position_exposed(), "position exposure restored")
	_check(is_equal_approx(GameManager.vision_boost_cells, 1.5), "vision boost restored")
	_check(GameManager.vision_boost_hold_rounds == 2, "vision boost hold restored")
	_check(loaded_player.cell_id == neighbor_id and GameManager.visual_position.distance_to(map.cell_center(neighbor_id) + Vector2(2.0, -1.0)) < 0.01, "sub-cell visual position restored")
	_check(loaded_companion != null, "companion restored")
	if loaded_companion != null:
		_check(loaded_companion.faction == "enemy", "companion faction restored")
		_check(loaded_companion.favor == -3, "companion favor restored")
		_check(loaded_companion.last_speech == "存档前的台词", "companion speech restored")
		_check(loaded_companion.turns_taken == 4, "companion turn count restored")
		_check(loaded_companion._scout_count == 2, "companion private counters restored")
		_check(loaded_companion._support_cooldown == 1, "companion cooldown restored")
		_check(loaded_companion._task_completed, "companion task completion restored")
		_check(loaded_companion._scouted_cells.has(map.start_id), "companion scouted cells restored")
		_check(loaded_companion._map_task_revealed_count == 2, "companion map-task progress restored")
		_check(loaded_companion._goal_revealed_by_ai and loaded_companion._goal_info_shared and loaded_companion._task_failed, "companion information-task flags restored")
		_check(bool(loaded_companion.favor_milestones.get("trust_supply", false)), "companion favor milestones restored")
		_check(loaded_companion.visited_pois.has(map.start_id), "companion visited POIs restored")
		_check(loaded_companion.has_stolen_item() and loaded_companion.stolen_item_id() == "rare_charm", "stolen item tracking restored")
		_check(loaded_companion._recovery_attempt_round == 7, "recovery attempt round restored")
	_check(GameManager.has_pending_item_overflow(), "pending backpack overflow restored")
	var loaded_overflow := GameManager.current_item_overflow()
	_check(String(loaded_overflow.get("item_id", "")) == "herb" and String(loaded_overflow.get("source", "")) == "存档测试", "pending overflow item and source restored")
	_check(int(EventManager._cooldowns.get("caravan", 0)) == 3, "event cooldowns restored")
	_check(int(EventManager._wander_ap_accum) == 17, "wander AP accumulator restored")
	_check(int(EventManager._random_events_this_run) == 17, "per-run random event count restored")
	_check(EventManager.get_reveal_level() == 2, "AI reveal level restored")
	_check(EventManager._visited_pois.has("probe_poi"), "visited POIs restored")
	_check(EventManager._visited_regions.has(2), "visited regions restored")
	_check(EventManager._revealed_pois.has(3), "revealed POIs restored")
	_check(RNGManager.get_stream("event").randi() == expected_event_roll, "event RNG stream continues from the save point")
	_check(RNGManager.get_stream("ai").randi() == expected_ai_roll, "AI RNG stream continues from the save point")
	_check(GameManager.autosave(), "restored state is a valid autosave boundary")
	_check(SaveManager.has_save(SaveManager.DEFAULT_SLOT), "autosave slot is available for continue")

	var bad_version := _clone_save_data("test_auto")
	if not bad_version.is_empty():
		bad_version["save_version"] = SaveManager.SAVE_VERSION + 99
		_write_slot_json("test_bad_version", bad_version)
		_check(not SaveManager.has_save("test_bad_version"), "incompatible save version is rejected")
		var bad_result := SaveManager.load_game("test_bad_version")
		_check(not bool(bad_result.get("ok", true)), "incompatible save cannot be loaded")
	_write_slot_text("test_corrupt", "{ 这不是 JSON")
	_check(not SaveManager.has_save("test_corrupt"), "corrupted save is rejected")
	var corrupt_result := SaveManager.load_game("test_corrupt")
	_check(not bool(corrupt_result.get("ok", true)), "corrupted save cannot be loaded")
	_check(not SaveManager.has_save("test_missing"), "missing save reports no save")

	SaveManager.clear_save("test_auto")
	SaveManager.clear_save("test_bad_version")
	SaveManager.clear_save("test_corrupt")
	_check(not SaveManager.has_save("test_auto"), "cleared save disappears")


func _clone_save_data(slot: String) -> Dictionary:
	var path := SaveManager.save_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write_slot_json(slot: String, data: Dictionary) -> void:
	_write_slot_text(slot, JSON.stringify(data, "\t"))


func _write_slot_text(slot: String, text: String) -> void:
	var path := SaveManager.save_path(slot)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _test_victory() -> void:
	print("-- victory --")
	var configs := MapConfigLoader.list_configs()
	_start_game("lin_xiao", configs[0])
	EventManager.random_events_enabled = false
	var map := GameManager.map
	var player := GameManager.player
	var goal_neighbor: int = map.neighbors_of(map.goal_id)[0]
	player.cell_id = goal_neighbor
	GameManager.visual_position = map.cell_center(goal_neighbor)
	player.ap_deci = 120
	player.ap_max_deci = 120
	var stroke := PackedVector2Array([map.cell_center(goal_neighbor), map.cell_center(map.goal_id)])
	_check(GameManager.set_drawn_path(stroke), "draw path onto goal")
	var result: Dictionary = {"win": false, "reason": ""}
	var handler := func(win: bool, reason: String) -> void:
		result["win"] = win
		result["reason"] = reason
	GameManager.game_over.connect(handler, CONNECT_ONE_SHOT)
	_check(GameManager.execute_move(), "move onto goal starts")
	GameManager.advance_movement(5.0)
	if EventManager.is_event_active():
		_auto_resolve_active_event()
	_check(player.cell_id == map.goal_id, "player enters goal cell")
	_check(bool(result["win"]), "game_over emits win=true on goal")
	_check(GameManager.state == GameManager.State.GAME_OVER, "game state becomes GAME_OVER")
	_check(GameManager.get_goal_distance() == 0, "goal distance is 0")
	var victory_summary := GameManager.build_run_summary_text(true)
	_check(victory_summary.contains("本局回顾") and victory_summary.contains("探索"), "run summary reports exploration and rounds")
	_check(victory_summary.contains("抵达终点"), "victory run summary states the final result")
	var ongoing_summary := GameManager.build_run_summary_text(false)
	_check(ongoing_summary.contains("本局回顾") and ongoing_summary.contains("距终点"), "ongoing run summary includes the remaining distance")


func _auto_resolve_active_event() -> void:
	var guard := 0
	while EventManager.is_event_active() and guard < 16:
		guard += 1
		var event := EventManager.get_active_event()
		var event_id := String(event.get("id", ""))
		var choices := EventManager.get_choices()
		var chosen := ""
		if event_id == "goal_guard":
			for choice in choices:
				if String(choice.get("id", "")) == "sacrifice_item" and not bool(choice.get("disabled", false)):
					chosen = "sacrifice_item"
		if chosen.is_empty():
			for choice in choices:
				if not bool(choice.get("disabled", false)):
					chosen = String(choice.get("id", ""))
					break
		if chosen.is_empty() and not choices.is_empty():
			chosen = String(choices[0].get("id", ""))
		if chosen.is_empty():
			EventManager.finish_event()
			return
		var result := EventManager.choose_choice(chosen)
		var inner := 0
		while EventManager.is_event_active() and inner < 8:
			inner += 1
			var kind := String(result.get("kind", ""))
			match kind:
				"trade_menu":
					var offers: Array = result.get("offers", [])
					var picked := -1
					for i in range(offers.size()):
						if not bool(offers[i].get("disabled", false)):
							picked = i
							break
					result = EventManager.resolve_trade_offer(picked)
				"steal_menu":
					var items: Array = result.get("items", [])
					if items.is_empty():
						EventManager.finish_event()
						break
					result = EventManager.resolve_steal_item(String(items[0]))
				"sacrifice_menu":
					var sacrifice_items: Array = result.get("items", [])
					if sacrifice_items.is_empty():
						EventManager.finish_event()
						break
					result = EventManager.resolve_sacrifice(String(sacrifice_items[0]))
				"heal_menu":
					result = EventManager.resolve_heal("hp")
				_:
					EventManager.finish_event()
					break


func _advance_until_settled() -> void:
	for _step in range(200):
		if EventManager.is_event_active():
			_auto_resolve_active_event()
		if not GameManager.is_moving and not GameManager.movement_paused:
			return
		GameManager.advance_movement(0.5)


## 测试里的开局默认等同于玩家按过「踏入荒原」。
## 需要验证序章本身时，再直接调用 GameManager.start_new_game。
func _start_game(character_id: String, config: Dictionary = {}) -> bool:
	var ok := GameManager.start_new_game(character_id, config)
	if ok and GameManager.intro_open:
		GameManager.dismiss_intro()
	return ok


func _checksum(map: MapData) -> String:
	var parts := PackedStringArray()
	for cell in map.cells:
		var polygon_text := PackedStringArray()
		for point in cell.polygon:
			polygon_text.append("%.2f,%.2f" % [point.x, point.y])
		parts.append("%d:%s:%d:%s:%s" % [
			cell.id, cell.terrain, cell.elevation, cell.poi_id, ";".join(polygon_text),
		])
	return "|".join(parts)
