extends Node
## 开发用截图工具：按流程截取主界面、地图选择、角色选择、游戏内自由笔迹。
## 运行：Godot_v4.7.2-stable_win64_console.exe --path . res://tests/capture_screens.tscn

const OUTPUT_DIR := "user://captures"


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	await get_tree().process_frame
	var absolute_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(absolute_dir)

	await _capture_scene("res://scenes/menu/main_menu.tscn", "01_main_menu.png")
	await _capture_scene("res://scenes/menu/map_select.tscn", "02_map_select.png")
	await _capture_scene("res://scenes/menu/character_select.tscn", "03_character_select.png")

	var configs := MapConfigLoader.list_configs()
	if not configs.is_empty() and GameManager.start_new_game("lin_xiao", configs[0]):
		var game_scene: Node = load("res://scenes/game/game.tscn").instantiate()
		add_child(game_scene)
		await _wait_frames(3)
		await _save_capture("03a_intro_story.png")
		var game_hud: Node = game_scene.get_node_or_null("UI")
		GameManager.dismiss_intro()
		await get_tree().create_timer(0.62).timeout
		await _save_capture("03b_opening_ap_dice.png")
		await get_tree().create_timer(2.0).timeout
		if game_hud != null:
			game_hud._on_help_pressed()
			await _wait_frames(2)
			await _save_capture("03c_help_panel.png")
			game_hud.help_overlay.close()
			await _wait_frames(2)
		if game_hud != null:
			game_hud._on_backpack_pressed()
			await _wait_frames(2)
			var backpack_overlay: Node = game_hud.backpack_overlay
			var first_equipment := String(GameManager.player.equipment[0]) if not GameManager.player.equipment.is_empty() else ""
			if first_equipment.is_empty():
				var grid: GridContainer = backpack_overlay.get_node_or_null("Center/Panel/Margin/VBox/Body/Right/Scroll/Grid")
				if grid != null:
					for child in grid.get_children():
						var item_id := String(child.get("item_id"))
						if not item_id.is_empty():
							first_equipment = item_id
							break
			if not first_equipment.is_empty():
				backpack_overlay._on_item_hovered(first_equipment)
			await _wait_frames(2)
			await _save_capture("03e_backpack_equipment.png")
			backpack_overlay.close()
			await _wait_frames(2)
		await _capture_intra_cell_movement(game_scene)
		_draw_preview_path()
		_hover_preview_cell(game_scene)
		await _wait_frames(3)
		await _save_capture("04_game_path.png")
		var map_view: Node = game_scene.get_node_or_null("MapView")
		if map_view != null and GameManager.player != null:
			var focus: Vector2 = map_view._world_to_screen(GameManager.map.cell_center(GameManager.player.cell_id))
			map_view._zoom_at(focus, 1.55)
			await _wait_frames(2)
			await _save_capture("04c_zoomed_map.png")
			map_view._reset_view()
		var hud: Node = game_scene.get_node_or_null("UI")
		if hud != null:
			hud._toggle_pause()
			await _wait_frames(2)
			await _save_capture("04b_pause_menu.png")
			hud._resume_game()
		GameManager.player.hp = 2
		GameManager.player_moved.emit()
		if EventManager.debug_start_event("caravan"):
			await _wait_frames(2)
			await _save_capture("04d_event_choice.png")
			# 风险提示截完后再回满血，避免偷窃失败直接把演示流程打死。
			GameManager.player.hp = GameManager.player.hp_max
			GameManager.player_moved.emit()
			EventManager.choose_choice("steal")
			await _wait_frames(2)
			await _save_capture("04e_event_result.png")
			EventManager.finish_event()
			GameManager.player.hp = GameManager.player.hp_max
			GameManager.player_moved.emit()
			await _wait_frames(2)
		# 等上一场事件的骰子动画完全退场，再截马匪的选择页。
		await get_tree().create_timer(3.2).timeout
		await _capture_bandit_event()
		await get_tree().create_timer(3.0).timeout
		await _capture_stele_event()
		await _capture_status_and_chronicle(game_scene)
		await _capture_companion_last_known(map_view)
		await _capture_companion_heard(map_view)
		await _capture_combat_flow()
		GameManager.player.ap_deci = 120
		GameManager.player.ap_max_deci = 120
		GameManager.execute_move()
		await get_tree().create_timer(0.18).timeout
		await _save_capture("05_game_moving.png")
		await get_tree().create_timer(0.35).timeout
		await _save_capture("06_game_after_move.png")
		await _capture_fog_states()
		await _capture_perfect_victory()
		game_scene.queue_free()
		await get_tree().process_frame
		await _capture_save_continue()

	print("captures saved to: ", absolute_dir)
	get_tree().quit()


func _capture_scene(path: String, file_name: String) -> void:
	var packed: PackedScene = load(path)
	if packed == null:
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	await _wait_frames(3)
	await _save_capture(file_name)
	scene.queue_free()
	await get_tree().process_frame


func _draw_preview_path() -> void:
	var map := GameManager.map
	var player := GameManager.player
	if map == null or player == null or map.poi_ids.is_empty():
		return
	var route := map.shortest_cell_path(player.cell_id, map.poi_ids[0])
	if route.is_empty():
		return
	var stroke := PackedVector2Array([map.cell_center(player.cell_id)])
	var limit := mini(route.size(), 11)
	for i in range(limit):
		var center := map.cell_center(route[i])
		var previous := map.cell_center(player.cell_id) if i == 0 else map.cell_center(route[i - 1])
		var direction := (center - previous).normalized()
		var perpendicular := Vector2(-direction.y, direction.x)
		stroke.append(center + perpendicular * sin(float(i) * 1.35) * 5.0)
	GameManager.set_drawn_path(stroke)


func _hover_preview_cell(game_scene: Node) -> void:
	var map := GameManager.map
	var player := GameManager.player
	var map_view: Node = game_scene.get_node_or_null("MapView")
	if map == null or player == null or map_view == null:
		return
	var center := map.cell_center(player.cell_id)
	map_view._update_hover(center + Vector2(7.0, -3.0))


func _capture_fog_states() -> void:
	if EventManager.is_event_active():
		EventManager.finish_event()
	await get_tree().create_timer(0.2).timeout
	var map := GameManager.map
	var player := GameManager.player
	if map == null or player == null:
		return
	GameManager.is_moving = false
	GameManager.movement_paused = false
	var far_id := map.goal_id
	if far_id == player.cell_id:
		far_id = map.start_id
	player.cell_id = far_id
	map.mark_cell_entered(far_id)
	GameManager.visual_position = map.cell_center(far_id)
	GameManager.refresh_vision()
	await get_tree().create_timer(1.4).timeout
	await _save_capture("07_fog_memory.png")
	GameManager.vision_boost_cells = 6.0
	GameManager.vision_boost_hold_rounds = GameManager.SCOUT_VISION_HOLD_ROUNDS
	GameManager.refresh_vision()
	await get_tree().create_timer(1.8).timeout
	await _save_capture("08_fog_scout_expanded.png")


## 演示一次敌方同伴袭击：先截反击/承受面板，再截结算文本。
func _capture_combat_flow() -> void:
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	if map == null or player == null or companion == null or companion.actor == null:
		return
	var neighbors := map.neighbors_of(player.cell_id)
	if neighbors.is_empty():
		return
	var original_cell := companion.actor.cell_id
	var original_faction := companion.faction
	var original_hp := player.hp
	var original_ap := player.ap_deci
	companion.actor.cell_id = int(neighbors[0])
	companion.faction = "enemy"
	companion.actor.hp = companion.actor.hp_max
	companion.actor.ap_deci = 100
	player.hp = player.hp_max
	player.ap_deci = 100
	var attack := CombatRules.resolve_attack(companion.actor, player, RNGManager.get_stream("ai"))
	var lines := CombatRules.describe_attack(attack, GameManager.companion_name(), player.display_name)
	GameManager.combat_interactive = true
	GameManager._handle_companion_combat({"lines": lines, "source": "companion"}, false)
	await _wait_frames(3)
	await _save_capture("04g_combat_choice.png")
	GameManager.resolve_combat_choice("endure")
	await _wait_frames(2)
	await _save_capture("04h_combat_result.png")
	GameManager.close_combat()
	companion.actor.cell_id = original_cell
	companion.faction = original_faction
	player.hp = original_hp
	player.ap_deci = original_ap
	await _wait_frames(2)


## 演示先到奖励后的完美胜利结算面板。
func _capture_perfect_victory() -> void:
	if GameManager.player == null:
		return
	if EventManager.is_event_active():
		EventManager.finish_event()
		await get_tree().process_frame
	var companion := GameManager.companion
	# 先记录玩家为第一个到达者，再把同伴设为同回合到达的友方，
	# 这样截图能同时展示先到奖励与完美胜利，而不是伪造一个更早到达的敌手。
	GameManager._record_goal_arrival("player", GameManager.player, "你", "player")
	if companion != null:
		companion.faction = "friendly"
		companion.reached_goal = true
		companion.goal_round = GameManager.round_index
		companion.faction_at_goal = "friendly"
		GameManager.companion_changed.emit()
	GameManager.finish_victory("你先于所有敌对同伴抵达终点。")
	await _wait_frames(3)
	await _save_capture("09_perfect_victory.png")


## 格内移动：整条笔迹都在当前地块内，AP 仍会连续下降；截图对照起笔与落点。
func _capture_intra_cell_movement(game_scene: Node) -> void:
	var map := GameManager.map
	var player := GameManager.player
	var map_view: Node = game_scene.get_node_or_null("MapView")
	if map == null or player == null or map_view == null:
		return
	if EventManager.is_event_active():
		EventManager.finish_event()
		await get_tree().process_frame
	GameManager.is_moving = false
	GameManager.movement_paused = false
	GameManager.clear_drawn_path()
	var cell := map.get_cell(player.cell_id)
	if cell == null:
		return
	var cell_id := player.cell_id
	var center := map.cell_center(cell_id)
	var segment := _longest_inside_segment(cell, center)
	if segment.size() < 2:
		push_warning("格内截图跳过：当前地块找不到足够长的内部线段")
		return
	var original_ap := player.ap_deci
	var original_ap_max := player.ap_max_deci
	var original_visual := GameManager.visual_position
	var events_were_enabled := EventManager.random_events_enabled
	EventManager.random_events_enabled = false
	GameManager.visual_position = center
	player.ap_deci = clampi(original_ap_max, 50, 120)
	player.ap_max_deci = maxi(original_ap_max, player.ap_deci)
	GameManager.player_moved.emit()
	var focus: Vector2 = map_view._world_to_screen(center)
	map_view._pan += Vector2(640.0, 360.0) - focus
	map_view._clamp_pan()
	focus = map_view._world_to_screen(center)
	map_view._zoom_at(focus, 2.4)
	if not GameManager.set_drawn_path(segment):
		push_error("格内截图失败：无法建立格内路径（%s）" % GameManager.last_path_error)
		EventManager.random_events_enabled = events_were_enabled
		return
	await _wait_frames(3)
	await _save_capture("10a_intra_cell_path.png")
	var ap_before := player.ap_deci
	var start_position := GameManager.visual_position
	GameManager.execute_move()
	await get_tree().create_timer(1.0).timeout
	await _wait_frames(2)
	await _save_capture("10b_intra_cell_after.png")
	var ap_spent := ap_before - player.ap_deci
	var travel := GameManager.visual_position.distance_to(start_position)
	if player.cell_id != cell_id:
		push_error("格内截图失败：角色跨出了原地块")
	if ap_spent <= 0:
		push_error("格内截图失败：格内移动没有消耗 AP")
	if travel < 1.0:
		push_error("格内截图失败：角色没有移动")
	print("intra-cell move: cell=%d travel=%.1fpx ap %.1f -> %.1f" % [
		cell_id, travel, ap_before / 10.0, player.ap_deci / 10.0,
	])
	player.ap_deci = original_ap
	player.ap_max_deci = original_ap_max
	GameManager.visual_position = original_visual
	GameManager.clear_drawn_path()
	GameManager.player_moved.emit()
	map_view._reset_view()
	EventManager.random_events_enabled = events_were_enabled
	await _wait_frames(2)


## 在当前地块中心向外找一条最长且不越界的内部线段，用于演示格内移动。
func _longest_inside_segment(cell: MapData.Cell, center: Vector2) -> PackedVector2Array:
	var best_end := center
	var best_length := 0.0
	for i in range(32):
		var angle := TAU * float(i) / 32.0
		var direction := Vector2(cos(angle), sin(angle))
		var last_inside := center
		for step in range(4, 241, 2):
			var candidate := center + direction * float(step)
			if not Geometry2D.is_point_in_polygon(candidate, cell.polygon):
				break
			last_inside = candidate
		var length := center.distance_to(last_inside)
		if length > best_length:
			best_length = length
			best_end = last_inside
	if best_length < 8.0:
		return PackedVector2Array()
	var end := center + (best_end - center) * 0.80
	if center.distance_to(end) < 6.0:
		return PackedVector2Array()
	return PackedVector2Array([center, end])


## 马匪伏击：选择前只应出现战斗/交涉/逃跑与风险，成功结算后才出现马匪弯刀。
func _capture_bandit_event() -> void:
	if EventManager.is_event_active():
		EventManager.finish_event()
		await get_tree().process_frame
	if not EventManager.debug_start_event("bandit_ambush"):
		push_warning("马匪截图跳过：无法开始 bandit_ambush")
		return
	await _wait_frames(3)
	var choices := EventManager.get_choices()
	for choice in choices:
		var encoded := JSON.stringify(choice)
		if encoded.contains("马匪弯刀") or encoded.contains("bandit_blade"):
			push_error("选择前泄露了马匪弯刀：%s" % encoded)
	await _save_capture("11a_bandit_choices.png")
	var fight_choice := EventManager._find_choice("fight")
	if fight_choice.is_empty():
		EventManager.finish_event()
		return
	var payload: Dictionary = EventManager._check_payload(fight_choice, "success", true, "演示：固定成功")
	var result: Dictionary = EventManager._resolve_outcome(fight_choice, "success", payload)
	await _wait_frames(3)
	await _save_capture("11b_bandit_result.png")
	var messages: Array = result.get("effect_messages", [])
	var revealed_blade := false
	for message in messages:
		if String(message).contains("马匪弯刀"):
			revealed_blade = true
	if not revealed_blade:
		push_error("马匪成功结算没有展示马匪弯刀：%s" % str(messages))
	if GameManager.player.item_count("bandit_blade") <= 0:
		push_error("马匪成功结算没有把马匪弯刀放入背包")
	print("bandit resolution: %s" % str(messages))
	EventManager.finish_event()
	await get_tree().create_timer(1.0).timeout
	await _wait_frames(2)


## 神秘石碑：选择页只显示选项与风险；结果页才展示诅咒/祝福及状态说明。
func _capture_stele_event() -> void:
	if not EventManager.debug_start_event("ancient_stele"):
		return
	await _wait_frames(3)
	await _save_capture("04j_stele_choices.png")
	EventManager.choose_choice("decipher")
	await _wait_frames(3)
	await _save_capture("04k_stele_result.png")
	EventManager.finish_event()
	# 等事件遮罩和检定骰条都退场，避免状态条/纪事截图叠着一层半透明面板。
	await get_tree().create_timer(3.0).timeout


## 持续状态条与旅途纪事的展开/折叠对照。截图前故意叠一个诅咒与一个祝福。
func _capture_status_and_chronicle(game_scene: Node) -> void:
	if GameManager.player == null:
		return
	GameManager.player.add_status("cursed", -1, GameManager.round_index)
	GameManager.player.add_status("hermit_blessing", -1, GameManager.round_index)
	var notes := [
		"你在断墙下辨认出一行旧刻字，记下了北侧石阶的走向。",
		"风沙暂时停了，远处传来一声短促的鸟鸣。",
		"你检查水囊，还剩半袋，足够撑过下一段路。",
		"路边的枯草被踩倒，像有人不久前从这里经过。",
		"你在一块背风石后歇了片刻，心跳慢了下来。",
		"远处的地平线上浮起一道细长的烟柱。",
		"你把石头摆成箭头，留给后来的人。",
		"夜色压下来，气温骤降，你加快脚步。",
		"你听见身后有碎石滚落，但回头什么也没有。",
		"地图边缘的墨迹被汗水晕开，你重新描了一遍。",
	]
	for line in notes:
		GameManager.add_world_log(line)
	GameManager.player_moved.emit()
	await _wait_frames(4)
	await _save_capture("04l_status_chronicle.png")
	var hud: Node = game_scene.get_node_or_null("UI")
	if hud != null:
		hud._toggle_chronicle()
		await _wait_frames(3)
		await _save_capture("04m_chronicle_collapsed.png")
		hud._toggle_chronicle()
		await _wait_frames(2)


func _capture_companion_last_known(map_view: Node) -> void:
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	if map == null or player == null or companion == null or map_view == null:
		return
	var neighbors := map.neighbors_of(player.cell_id)
	if neighbors.is_empty():
		return
	# 同伴走远后，地图只保留她最后被看到的位置（空心标记）与阵营颜色。
	# 选一个视野内、且不被左下纪事面板遮住的地块，便于看清“最后已知”标记。
	var last_seen := int(neighbors[0])
	var player_center := map.cell_center(player.cell_id)
	# 默认视角下起始点贴在地图左缘，可见圆会被左下纪事面板盖住一半。
	# 截图前把玩家所在区域平移到画面中部，方便看清空心“最后已知”标记。
	var player_screen: Vector2 = map_view._world_to_screen(player_center)
	map_view._pan += Vector2(620.0, 360.0) - player_screen
	map_view._clamp_pan()
	map_view.queue_redraw()
	var min_distance := map.average_site_spacing * 0.75
	var max_distance := GameManager.vision_radius_world() * 0.8
	for cell in map.cells:
		if cell.id == player.cell_id or not map.is_cell_known(cell.id):
			continue
		var distance := cell.center.distance_to(player_center)
		if distance < min_distance or distance > max_distance:
			continue
		var screen: Vector2 = map_view._world_to_screen(cell.center)
		if screen.x < 480.0 or screen.x > 900.0 or screen.y < 120.0 or screen.y > 520.0:
			continue
		last_seen = cell.id
		break
	companion.last_known_cell = last_seen
	companion.last_known_round = GameManager.round_index
	companion.actor.cell_id = map.goal_id
	if companion.actor.cell_id == player.cell_id:
		companion.actor.cell_id = last_seen
	EventManager.grant_ai_reveal(2)
	GameManager.refresh_vision()
	GameManager.companion_changed.emit()
	await _wait_frames(3)
	await _save_capture("04f_companion_last_known.png")
	companion.actor.cell_id = player.cell_id
	companion.last_known_cell = player.cell_id
	GameManager.refresh_vision()
	GameManager.companion_changed.emit()
	map_view._reset_view()
	await _wait_frames(2)


func _capture_companion_heard(map_view: Node) -> void:
	var map := GameManager.map
	var player := GameManager.player
	var companion := GameManager.companion
	if map == null or player == null or companion == null or map_view == null:
		return
	var player_center := map.cell_center(player.cell_id)
	var heard_cell := -1
	for cell in map.cells:
		if cell.id == player.cell_id:
			continue
		var distance := map.graph_distance(player.cell_id, cell.id)
		if distance < 2 or distance > GameManager.COMPANION_HEARING_RANGE:
			continue
		if cell.center.distance_to(player_center) < map.average_site_spacing * 2.2:
			continue
		var screen: Vector2 = map_view._world_to_screen(cell.center)
		if screen.x < 480.0 or screen.x > 900.0 or screen.y < 120.0 or screen.y > 520.0:
			continue
		heard_cell = cell.id
		break
	if heard_cell < 0:
		return
	GameManager.clear_drawn_path()
	companion.actor.cell_id = heard_cell
	companion.last_known_cell = heard_cell
	companion.last_known_round = GameManager.round_index
	EventManager.grant_ai_reveal(2)
	GameManager.refresh_vision()
	# 缩到只包住玩家近身，确保演示格在视野外、但仍落在 3 格听觉范围内。
	map.vision_radius_world = map.average_site_spacing * 1.5
	GameManager.companion_changed.emit()
	await _wait_frames(3)
	await _save_capture("04i_companion_heard.png")
	companion.actor.cell_id = player.cell_id
	companion.last_known_cell = player.cell_id
	GameManager.refresh_vision()
	GameManager.companion_changed.emit()
	map_view._reset_view()
	await _wait_frames(2)


## 自动存档 → 主菜单「继续游戏」→ 读档回到游戏内。用于人工核对存档入口与恢复后的界面。
func _capture_save_continue() -> void:
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		return
	SaveManager.clear_save(SaveManager.DEFAULT_SLOT)
	if not GameManager.start_new_game("lin_xiao", configs[0]):
		return
	GameManager.dismiss_intro()
	GameManager.round_index = 5
	GameManager.add_world_log("自动存档截图标记。")
	GameManager.player.gold = 37
	if not GameManager.autosave():
		push_error("截图前自动存档失败：%s" % SaveManager.last_error)
		return
	await get_tree().process_frame

	var menu_scene: Node = load("res://scenes/menu/main_menu.tscn").instantiate()
	add_child(menu_scene)
	await _wait_frames(3)
	var continue_button: Button = menu_scene.get_node_or_null("Center/VBox/ContinueButton")
	if continue_button == null or not continue_button.visible:
		push_error("主菜单没有显示继续游戏按钮")
		menu_scene.queue_free()
		return
	await _save_capture("12a_continue_game.png")
	menu_scene.queue_free()
	await get_tree().process_frame

	var result := SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	if not bool(result.get("ok", false)):
		push_error("读档失败：%s" % String(result.get("error", "")))
		return
	var loaded_scene: Node = load("res://scenes/game/game.tscn").instantiate()
	add_child(loaded_scene)
	await _wait_frames(4)
	if GameManager.round_index != 5 or GameManager.player.gold != 37:
		push_error("读档后的回合或金币不一致")
	await _save_capture("12b_loaded_game.png")
	loaded_scene.queue_free()
	await get_tree().process_frame
	SaveManager.clear_save(SaveManager.DEFAULT_SLOT)


func _wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _save_capture(file_name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := OUTPUT_DIR + "/" + file_name
	var error := image.save_png(path)
	if error != OK:
		push_error("截图失败：%s (%d)" % [path, error])
	else:
		print("captured ", ProjectSettings.globalize_path(path))
