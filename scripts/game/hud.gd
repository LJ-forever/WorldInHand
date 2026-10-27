extends CanvasLayer
## 游戏内 HUD。画路径时不显示 AP 消耗、可达性与截断点；
## 移动动画中 AP 按实际路径距离连续下降，只刷新顶部 AP 文本。
##
## 界面分区：
## - 顶部：角色/回合/种子 + 右上「？」旅途手册；
## - 底部：动作按钮 + 同伴状态与台词条 + 「背包」页；
## - 左上：光标地块的地形与迷雾状态；
## - 左下：旅途纪事。长提示不再堆在底栏，统一收进分页手册。

const ATTACK_HELP := "袭击的用途：只有同伴与你相邻且关系为「敌对」时才能出手。\n消耗 1 AP 先手攻击：2d6 + 战斗 + 装备/状态 对抗 8 + 体力 + 防御装备。\n命中造成 1d3（大成功 1d6）。她若存活且还有 1 AP，会立刻反击。\n击倒或削弱她能阻止她抢先抵达终点、偷你的装备或给你下套。"
const CHRONICLE_TOP_EXPANDED := -410.0
const CHRONICLE_TOP_COLLAPSED := -238.0

@onready var name_label: Label = $TopBar/Margin/HBox/NameLabel
@onready var hp_label: Label = $TopBar/Margin/HBox/HpLabel
@onready var ap_label: Label = $TopBar/Margin/HBox/ApLabel
@onready var gold_label: Label = $TopBar/Margin/HBox/GoldLabel
@onready var round_label: Label = $TopBar/Margin/HBox/RoundLabel
@onready var seed_label: Label = $TopBar/Margin/HBox/SeedLabel
@onready var ai_label: Label = $TopBar/Margin/HBox/AiLabel
@onready var hover_label: Label = $HoverChip/Margin/HoverLabel
@onready var status_chip: PanelContainer = $StatusChip
@onready var status_label: Label = $StatusChip/Margin/StatusLabel
@onready var chronicle_panel: PanelContainer = $ChroniclePanel
@onready var chronicle_title: Label = $ChroniclePanel/Margin/VBox/Header/ChronicleTitle
@onready var chronicle_toggle: Button = $ChroniclePanel/Margin/VBox/Header/ChronicleToggle
@onready var chronicle_scroll: ScrollContainer = $ChroniclePanel/Margin/VBox/Scroll
@onready var chronicle_label: Label = $ChroniclePanel/Margin/VBox/Scroll/ChronicleLabel
@onready var companion_who: Label = $BottomBar/Margin/VBox/CompanionStrip/CompanionWho
@onready var companion_speech: Label = $BottomBar/Margin/VBox/CompanionStrip/CompanionSpeech
@onready var companion_activity: Label = $BottomBar/Margin/VBox/CompanionStrip/CompanionActivity
@onready var toast_panel: PanelContainer = $ToastPanel
@onready var toast_label: Label = $ToastPanel/Margin/ToastLabel
@onready var help_button: Button = $HelpButton

@onready var scout_button: Button = $BottomBar/Margin/VBox/HBox/ScoutButton
@onready var rest_button: Button = $BottomBar/Margin/VBox/HBox/RestButton
@onready var clear_button: Button = $BottomBar/Margin/VBox/HBox/ClearButton
@onready var move_button: Button = $BottomBar/Margin/VBox/HBox/MoveButton
@onready var attack_button: Button = $BottomBar/Margin/VBox/HBox/AttackButton
@onready var backpack_button: Button = $BottomBar/Margin/VBox/HBox/BackpackButton
@onready var end_turn_button: Button = $BottomBar/Margin/VBox/HBox/EndTurnButton
@onready var pause_button: Button = $BottomBar/Margin/VBox/HBox/PauseButton

@onready var pause_overlay: Control = $PauseOverlay
@onready var pause_task_name: Label = $PauseOverlay/Center/Panel/Margin/VBox/PauseTaskName
@onready var pause_task_detail: Label = $PauseOverlay/Center/Panel/Margin/VBox/PauseTaskDetail
@onready var pause_companion_label: Label = $PauseOverlay/Center/Panel/Margin/VBox/PauseCompanionLabel
@onready var pause_chronicle_label: Label = $PauseOverlay/Center/Panel/Margin/VBox/PauseChronicleLabel
@onready var resume_button: Button = $PauseOverlay/Center/Panel/Margin/VBox/ResumeButton
@onready var pause_main_menu_button: Button = $PauseOverlay/Center/Panel/Margin/VBox/MainMenuButton
@onready var pause_quit_button: Button = $PauseOverlay/Center/Panel/Margin/VBox/QuitButton

@onready var result_overlay: Control = $ResultOverlay
@onready var result_title: Label = $ResultOverlay/Center/Panel/Margin/VBox/ResultTitle
@onready var result_detail: Label = $ResultOverlay/Center/Panel/Margin/VBox/ResultDetail
@onready var restart_button: Button = $ResultOverlay/Center/Panel/Margin/VBox/Buttons/RestartButton
@onready var result_menu_button: Button = $ResultOverlay/Center/Panel/Margin/VBox/Buttons/MenuButton

@onready var help_overlay = $HelpOverlay
@onready var backpack_overlay = $BackpackOverlay
@onready var bottom_bar: PanelContainer = $BottomBar
@onready var dice_overlay = $DiceOverlay

var _hovered: int = -1
var _map_view = null
var _toast_token: int = 0
var _last_seen_move_message: String = ""
var _modal_paused: bool = false
var _chronicle_expanded: bool = true


func _ready() -> void:
	GameManager.path_changed.connect(refresh)
	GameManager.player_moved.connect(refresh)
	GameManager.ap_changed.connect(_on_ap_changed)
	GameManager.turn_started.connect(refresh)
	GameManager.movement_started.connect(refresh)
	GameManager.movement_finished.connect(_on_movement_finished)
	GameManager.state_changed.connect(_on_state_changed)
	GameManager.game_over.connect(_on_game_over)
	GameManager.companion_changed.connect(refresh)
	GameManager.world_log_changed.connect(_update_chronicle)
	GameManager.world_notice.connect(_on_world_notice)
	GameManager.inventory_changed.connect(refresh)
	GameManager.inventory_overflow_changed.connect(_on_inventory_overflow_changed)
	GameManager.combat_finished.connect(_on_combat_finished_for_overflow)
	GameManager.intro_dismissed.connect(_on_intro_dismissed)
	GameManager.scout_finished.connect(_on_scout_finished)
	EventManager.event_started.connect(_on_event_started_clear_dice)
	EventManager.event_progress.connect(_on_event_progress_clear_dice)
	EventManager.event_finished.connect(_on_event_finished_for_overflow)

	_map_view = get_parent().get_node_or_null("MapView")
	if _map_view != null:
		_map_view.hovered_cell_changed.connect(_on_hovered_cell_changed)
		_map_view.hover_position_changed.connect(_on_hover_position_changed)
		_map_view.stroke_rejected.connect(_on_stroke_rejected)

	scout_button.pressed.connect(_on_scout_pressed)
	rest_button.pressed.connect(_on_rest_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	move_button.pressed.connect(_on_move_pressed)
	attack_button.pressed.connect(_on_attack_pressed)
	backpack_button.pressed.connect(_on_backpack_pressed)
	end_turn_button.pressed.connect(_on_end_turn_pressed)
	pause_button.pressed.connect(_toggle_pause)
	help_button.pressed.connect(_on_help_pressed)
	chronicle_toggle.pressed.connect(_toggle_chronicle)
	# 暂停/结算面板的按钮必须显式接线；场景里只放了节点，不会自动调用处理函数。
	resume_button.pressed.connect(_resume_game)
	pause_main_menu_button.pressed.connect(_on_return_to_main_menu)
	pause_quit_button.pressed.connect(_on_quit_game)
	restart_button.pressed.connect(_on_restart_pressed)
	result_menu_button.pressed.connect(_on_return_to_main_menu)
	help_overlay.closed.connect(_on_modal_closed)
	backpack_overlay.closed.connect(_on_modal_closed)

	scout_button.tooltip_text = "消耗 2 AP：2d6 + 感知 + 装备/状态，对抗地形 DC。\n成功扩大圆形视野；大成功额外定位 POI；大失败会暴露你的位置 1 回合。"
	rest_button.tooltip_text = "每回合一次：不消耗 AP，回复 1 HP。"
	move_button.tooltip_text = "沿你画出的路径移动。空格键同效；AP 按实际走过的距离连续消耗，可在当前地块内来回移动。"
	backpack_button.tooltip_text = "打开行囊与装备页：左侧装备、右侧背包，悬停看详情，拖拽装备（B）。"
	end_turn_button.tooltip_text = "结束本回合：结算状态、让同伴独立行动，然后重新掷 1d6 获得下一回合 AP。"
	pause_button.tooltip_text = "暂停并查看任务、同伴与旅途纪事（Esc）。"
	help_button.tooltip_text = "旅途手册：操作、AP、侦察、袭击、背包与同伴。"
	attack_button.tooltip_text = ATTACK_HELP

	pause_overlay.visible = false
	result_overlay.visible = false
	toast_panel.visible = false
	help_overlay.visible = false
	backpack_overlay.visible = false
	# 信息条只用于展示，不能拦截地图上的画线与点击。
	# 纪事面板例外：它需要接收折叠按钮和滚轮事件。
	for path in ["$HoverChip", "$ToastPanel"]:
		var panel: Control = get_node_or_null(path)
		if panel == null:
			continue
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for child in panel.find_children("*", "Control", true, false):
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_chronicle_expanded(true)
	refresh()


func refresh() -> void:
	if GameManager.player == null or GameManager.map == null:
		return
	var player := GameManager.player
	var map := GameManager.map
	name_label.text = "%s · %s" % [player.display_name, player.role]
	hp_label.text = "HP %d / %d" % [player.hp, player.hp_max]
	ap_label.text = "AP %.1f / %.1f" % [player.ap_deci / 10.0, player.ap_max_deci / 10.0]
	gold_label.text = "金币 %d" % player.gold
	round_label.text = "回合 %d / %d · 距终点约 %d 格 · %s" % [
		GameManager.round_index, GameManager.MAX_ROUNDS, GameManager.get_goal_distance(),
		EventManager.get_exploration_text(),
	]
	seed_label.text = "%s · 种子 %d" % [map.map_name, map.seed_value]
	seed_label.tooltip_text = "形状种子 %d · 生成种子 %d · 本局生态种子 %d" % [
		map.seed_value, map.generated_seed, map.terrain_seed,
	]
	var companion_name := GameManager.companion_name()
	ai_label.text = "同伴 %s · %s" % [companion_name, GameManager.companion_relation_text()]
	if GameManager.is_position_exposed():
		ai_label.text += " · 位置暴露"
	ai_label.tooltip_text = _companion_tooltip(companion_name)

	_update_hover_label()
	_update_status_chip(player)
	_update_companion_strip(companion_name)
	_update_chronicle()
	_update_pause_content()
	_update_buttons()
	_update_toast_from_game()
	if backpack_overlay.visible:
		backpack_overlay.refresh()
	_maybe_open_item_overflow()


func _on_ap_changed(_ap_deci: int) -> void:
	# 连续移动时每帧都可能扣费；只更新 AP 文本，避免整页 HUD 重建导致卡顿。
	if GameManager.player == null:
		return
	ap_label.text = "AP %.1f / %.1f" % [
		GameManager.player.ap_deci / 10.0, GameManager.player.ap_max_deci / 10.0,
	]


func _unhandled_input(event: InputEvent) -> void:
	if GameManager.intro_open:
		return
	if help_overlay.visible or backpack_overlay.visible:
		return
	if event.is_action_pressed("ui_cancel") and not result_overlay.visible:
		_toggle_pause()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		if GameManager.state == GameManager.State.PLAYING and not GameManager.is_moving:
			_on_backpack_pressed()
			get_viewport().set_input_as_handled()


func _toggle_pause() -> void:
	if result_overlay.visible or GameManager.state == GameManager.State.COMBAT:
		return
	if GameManager.intro_open:
		return
	if pause_overlay.visible:
		_resume_game()
		return
	refresh()
	pause_overlay.visible = true
	get_tree().paused = true
	resume_button.grab_focus()


func _resume_game() -> void:
	pause_overlay.visible = false
	get_tree().paused = false
	refresh()


func _on_help_pressed() -> void:
	if GameManager.intro_open or result_overlay.visible:
		return
	help_overlay.open()
	_pause_for_modal()


func _on_backpack_pressed() -> void:
	if GameManager.intro_open or result_overlay.visible:
		return
	if GameManager.state != GameManager.State.PLAYING or GameManager.is_moving or GameManager.movement_paused:
		_show_toast(GameManager.move_block_reason(), true)
		return
	dice_overlay.clear()
	backpack_overlay.open()
	_pause_for_modal()


func _pause_for_modal() -> void:
	if not get_tree().paused:
		get_tree().paused = true
		_modal_paused = true


func _on_modal_closed() -> void:
	if _modal_paused:
		get_tree().paused = false
		_modal_paused = false
	refresh()


func _on_inventory_overflow_changed() -> void:
	call_deferred("_maybe_open_item_overflow")


## 新事件开始时，上一场事件的骰子/AP 骰已经失效，先收起。
func _on_event_started_clear_dice(_event: Dictionary) -> void:
	dice_overlay.clear()


## 无检定的选项（例如守卫献祭、退开）不会再发 dice_rolled；
## 只有结果确实来自检定（check=true）时才保留当前骰子动画。
func _on_event_progress_clear_dice(result: Dictionary) -> void:
	if not bool(result.get("check", false)):
		dice_overlay.clear()


func _on_event_finished_for_overflow(_event_id: String) -> void:
	call_deferred("_maybe_open_item_overflow")


func _on_combat_finished_for_overflow(_payload: Dictionary) -> void:
	call_deferred("_maybe_open_item_overflow")


## A3：背包溢出只在没有事件/战斗/移动遮挡时弹出，避免两个面板抢输入。
func _maybe_open_item_overflow() -> void:
	if not GameManager.has_pending_item_overflow():
		return
	if GameManager.intro_open or result_overlay.visible:
		return
	if pause_overlay.visible:
		return
	if GameManager.state != GameManager.State.PLAYING:
		return
	if GameManager.is_moving or GameManager.movement_paused:
		return
	var event_overlay: Control = get_node_or_null("EventOverlay")
	if event_overlay != null and event_overlay.visible:
		return
	var combat_overlay: Control = get_node_or_null("CombatOverlay")
	if combat_overlay != null and combat_overlay.visible:
		return
	if backpack_overlay.visible:
		return
	dice_overlay.clear()
	backpack_overlay.open()
	_pause_for_modal()


func _on_intro_dismissed() -> void:
	refresh()


func _on_return_to_main_menu() -> void:
	# 返回主菜单属于安全边界：保留当前局，主菜单可「继续游戏」。
	GameManager.autosave()
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/menu/main_menu.tscn")


func _on_quit_game() -> void:
	GameManager.autosave()
	get_tree().quit()


func _update_hover_label() -> void:
	var map := GameManager.map
	if map == null or _hovered < 0 or map.get_cell(_hovered) == null:
		hover_label.text = "把光标移到一个地块上"
		hover_label.add_theme_color_override("font_color", Color(0.72, 0.70, 0.61))
		return
	var fog_state := map.fog_state(_hovered)
	var hover_point := map.cell_center(_hovered)
	if _map_view != null:
		hover_point = _map_view.get_hover_position()
	var point_visible := map.is_point_in_current_vision(hover_point)
	if not point_visible and fog_state != MapData.FogState.REMEMBERED:
		hover_label.text = "地块 %d · 未知地形 · 迷雾未散" % (_hovered + 1)
		hover_label.add_theme_color_override("font_color", Color(0.55, 0.54, 0.48))
		return
	var cell := map.get_cell(_hovered)
	var fog_suffix := " · 可见" if point_visible else " · 记忆"
	var elev_range := map.elevation_range_of(_hovered)
	var local_elevation := cell.elevation_mean
	if _map_view != null:
		local_elevation = map.elevation_at(_hovered, _map_view.get_hover_position())
		if elev_range.y - elev_range.x > 0.15:
			local_elevation = clampf(local_elevation, elev_range.x, elev_range.y)
	var relief := "海拔 %.1f" % local_elevation
	if elev_range.y - elev_range.x > 0.15:
		relief += "（格内 %.1f–%.1f）" % [elev_range.x, elev_range.y]
	hover_label.text = "地块 %d · %s · %s%s" % [
		_hovered + 1, map.terrain_display_name(cell.terrain), relief, fog_suffix,
	]
	hover_label.add_theme_color_override("font_color", Color(0.86, 0.82, 0.71))


func _update_companion_strip(companion_name: String) -> void:
	if GameManager.companion == null:
		companion_who.text = "同伴 —"
		companion_speech.text = "本局没有同伴。"
		companion_activity.text = ""
		companion_activity.tooltip_text = ""
		return
	var companion := GameManager.companion
	companion_who.text = "同伴 · %s · %s" % [companion_name, GameManager.companion_relation_text()]
	companion_who.tooltip_text = _companion_tooltip(companion_name)
	companion_speech.text = GameManager.companion_speech_text()
	companion_speech.tooltip_text = "只有视野内或 %d 格内才能听见她说话；更远时只显示最后已知位置。" % GameManager.COMPANION_HEARING_RANGE
	var speech_color := Color(0.93, 0.87, 0.72)
	match companion.faction:
		"friendly":
			speech_color = Color(0.74, 0.90, 0.72)
		"enemy":
			speech_color = Color(0.95, 0.62, 0.53)
		_:
			speech_color = Color(0.88, 0.83, 0.68)
	if not GameManager.companion_is_perceived():
		speech_color = Color(0.62, 0.61, 0.55)
	companion_speech.add_theme_color_override("font_color", speech_color)
	if GameManager.companion_is_visible():
		var distance := GameManager.map.graph_distance(GameManager.player.cell_id, companion.actor.cell_id)
		companion_activity.text = "%s · 距你 %d 格" % [GameManager.companion_status_text(), distance]
	elif GameManager.companion_is_heard():
		companion_activity.text = "%s · 雾里能听见脚步" % GameManager.companion_status_text()
	else:
		companion_activity.text = "%s · %s" % [
			GameManager.companion_status_text(), GameManager.companion_last_known_text(),
		]
	var attack_reason := GameManager.attack_block_reason()
	if attack_reason.is_empty():
		companion_activity.text += " · 可袭击（1 AP）"
		companion_activity.add_theme_color_override("font_color", Color(0.95, 0.66, 0.48))
	else:
		companion_activity.add_theme_color_override("font_color", Color(0.65, 0.69, 0.61))
	var recovery_info := GameManager.stolen_item_recovery_info()
	if GameManager.state == GameManager.State.PLAYING \
			and bool(recovery_info.get("available", false)):
		companion_activity.text += " · 失物可追查"
	companion_activity.tooltip_text = "同伴独立侦察、探索、搜集物资、支援或敌对行动，不会一直跟在你身后。\n%s\n%s" % [
		GameManager.companion_intel_text(), ATTACK_HELP,
	]


func _companion_tooltip(companion_name: String) -> String:
	if GameManager.companion == null:
		return "本局没有同伴。"
	var lines: Array[String] = [
		"同伴：%s · %s" % [companion_name, GameManager.companion_condition_text()],
		"立场：%s" % GameManager.companion_relation_text(),
		"动向：%s" % GameManager.companion_status_text(),
		"最后已知：%s" % GameManager.companion_last_known_text(),
		"个人目标：%s" % GameManager.companion_task_text(),
		GameManager.companion_intel_text(),
		"",
		"好感达到 +4 时，她会主动交给你一份补给（每局一次）。",
		"侦察成功或事件线索可提升情报等级。",
		"位置暴露时，所有 AI 都会知道你的位置。",
	]
	return "\n".join(lines)


func _update_status_chip(player: ActorState) -> void:
	status_label.text = player.status_summary_text()
	if player.statuses.is_empty():
		status_label.add_theme_color_override("font_color", Color(0.63, 0.62, 0.55))
		status_label.tooltip_text = "当前没有状态效果。\n事件造成的诅咒、流血、迷路或祝福，会在这里持续显示。"
	else:
		var has_debuff := false
		for status_id in player.statuses.keys():
			var category := String(DataManager.get_record("statuses", status_id).get("category", ""))
			if category != "buff":
				has_debuff = true
				break
		status_label.add_theme_color_override(
			"font_color",
			Color(0.95, 0.58, 0.49) if has_debuff else Color(0.70, 0.90, 0.68)
		)
		status_label.tooltip_text = "当前状态（完整效果）：\n%s\n\n颜色提示：红色=负面，绿色=祝福。" % player.status_detail_text()
	status_chip.tooltip_text = status_label.tooltip_text


func _update_chronicle() -> void:
	var entries := GameManager.get_world_log()
	chronicle_title.text = "旅途纪事 · %d 条" % entries.size()
	var stay_at_bottom := _chronicle_is_at_bottom()
	if entries.is_empty():
		chronicle_label.text = "尚无记录。"
		pause_chronicle_label.text = "尚无记录。"
		return
	# 面板里保留完整纪事，由 ScrollContainer 负责滚轮浏览；暂停页仍只给最近 8 条。
	chronicle_label.text = "\n".join(entries)
	var pause_start := maxi(0, entries.size() - 8)
	pause_chronicle_label.text = "\n".join(entries.slice(pause_start, entries.size()))
	if _chronicle_expanded and stay_at_bottom:
		_scroll_chronicle_to_bottom()


func _chronicle_is_at_bottom() -> bool:
	if chronicle_scroll == null or not chronicle_scroll.visible:
		return true
	var bar := chronicle_scroll.get_v_scroll_bar()
	var max_scroll := maxf(0.0, bar.max_value - bar.page)
	return float(chronicle_scroll.scroll_vertical) >= max_scroll - 4.0


func _scroll_chronicle_to_bottom() -> void:
	await get_tree().process_frame
	if chronicle_scroll == null or not _chronicle_expanded or not chronicle_scroll.visible:
		return
	var bar := chronicle_scroll.get_v_scroll_bar()
	chronicle_scroll.scroll_vertical = int(maxf(0.0, bar.max_value - bar.page))


func _toggle_chronicle() -> void:
	_set_chronicle_expanded(not _chronicle_expanded)


func _set_chronicle_expanded(expanded: bool) -> void:
	_chronicle_expanded = expanded
	chronicle_scroll.visible = expanded
	chronicle_toggle.text = "收起" if expanded else "展开"
	chronicle_panel.offset_top = CHRONICLE_TOP_EXPANDED if expanded else CHRONICLE_TOP_COLLAPSED
	if expanded:
		_scroll_chronicle_to_bottom()


func _update_pause_content() -> void:
	# hidden_tasks.json 的条目是 AI 同伴视角，不能直接当成玩家的个人目标展示。
	pause_task_name.text = "玩家隐藏任务：MVP 未启用"
	pause_task_detail.text = "按设计 §10.5，玩家角色的隐藏任务在本版\n只记录、不判定。\n同伴的隐藏任务与阵营会随「情报」等级逐步揭示。"
	if GameManager.companion == null:
		pause_companion_label.text = "同伴：本局没有同伴"
		pause_companion_label.tooltip_text = ""
		return
	var lines: Array[String] = [
		"同伴：%s · %s" % [GameManager.companion_name(), GameManager.companion_condition_text()],
		"立场：%s" % GameManager.companion_relation_text(),
		"动向：%s" % GameManager.companion_status_text(),
		"最后已知：%s" % GameManager.companion_last_known_text(),
		"个人目标：%s" % GameManager.companion_task_text(),
		GameManager.companion_intel_text(),
		"台词：%s" % GameManager.companion_speech_text(),
	]
	pause_companion_label.text = "\n".join(lines)
	pause_companion_label.tooltip_text = "同伴会独立行动、侦察、搜集物资并完成自己的隐藏任务。\n侦察成功与事件线索会提升情报等级。"


func _update_buttons() -> void:
	var player := GameManager.player
	var playing := GameManager.state == GameManager.State.PLAYING and not GameManager.intro_open
	var moving := GameManager.is_moving or GameManager.movement_paused
	var has_path := GameManager.has_drawn_path()
	scout_button.disabled = not playing or moving or player.ap_deci < GameManager.SCOUT_AP_COST_DECI
	rest_button.disabled = not playing or player.rest_used or moving
	clear_button.disabled = not playing or not has_path or moving
	move_button.disabled = not playing or not has_path or moving
	attack_button.disabled = not GameManager.can_attack_companion()
	backpack_button.disabled = not playing or moving
	end_turn_button.disabled = not playing or moving
	pause_button.disabled = GameManager.state == GameManager.State.GAME_OVER \
		or GameManager.state == GameManager.State.COMBAT
	help_button.disabled = GameManager.intro_open or GameManager.state == GameManager.State.GAME_OVER
	move_button.text = "移动中…" if GameManager.is_moving else "沿路径移动（空格）"

	var attack_reason := GameManager.attack_block_reason()
	if attack_reason.is_empty():
		attack_button.text = "袭击（1 AP · 可发动）"
	else:
		attack_button.text = "袭击（%s）" % _short_attack_reason(attack_reason)
	attack_button.tooltip_text = ATTACK_HELP + "\n\n当前：" + (
		"她与你相邻且敌对，可以出手。" if attack_reason.is_empty() else attack_reason
	)


func _short_attack_reason(reason: String) -> String:
	if reason.contains("相邻"):
		return "需相邻"
	if reason.contains("AP"):
		return "AP 不足"
	if reason.contains("友好") or reason.contains("中立"):
		return "非敌对"
	if reason.contains("倒下"):
		return "目标已倒"
	return "暂不可用"


func _update_toast_from_game() -> void:
	var message := GameManager.last_move_message.strip_edges()
	if message.is_empty():
		_last_seen_move_message = ""
		return
	if message == _last_seen_move_message:
		return
	_last_seen_move_message = message
	_show_toast(message)


func _on_world_notice(message: String) -> void:
	if not message.strip_edges().is_empty() and not result_overlay.visible:
		_show_toast(message)


func _show_toast(message: String, warning: bool = false) -> void:
	var clean := message.strip_edges()
	if clean.is_empty():
		return
	_toast_token += 1
	var token := _toast_token
	toast_label.text = clean
	toast_label.add_theme_color_override(
		"font_color",
		Color(0.95, 0.66, 0.53) if warning else Color(0.94, 0.85, 0.69)
	)
	toast_panel.visible = true
	toast_panel.modulate = Color(1, 1, 1, 1)
	await get_tree().create_timer(3.4).timeout
	if token != _toast_token:
		return
	var tween := create_tween()
	tween.tween_property(toast_panel, "modulate:a", 0.0, 0.35)
	await tween.finished
	if token == _toast_token:
		toast_panel.visible = false


func _on_hovered_cell_changed(cell_id: int) -> void:
	_hovered = cell_id
	_update_hover_label()


func _on_hover_position_changed(_point: Vector2) -> void:
	if _hovered >= 0:
		_update_hover_label()


func _on_stroke_rejected(message: String) -> void:
	_show_toast(message, true)


func _on_scout_finished(report: Dictionary) -> void:
	var message := String(report.get("message", "")).strip_edges()
	if message.is_empty():
		return
	var level := String(report.get("level", ""))
	_show_toast(message, level == "fail" or level == "great_fail" or not bool(report.get("ok", false)))


func _on_movement_finished(reason: String) -> void:
	if not reason.strip_edges().is_empty():
		_show_toast(reason, true)
	refresh()


func _on_state_changed(_new_state: int) -> void:
	refresh()


func _on_game_over(win: bool, reason: String) -> void:
	toast_panel.visible = false
	help_overlay.visible = false
	backpack_overlay.visible = false
	# 结算页接管输入后，底栏里的动作/失物提示与残留骰子都不应继续可见。
	bottom_bar.visible = false
	dice_overlay.clear()
	if _modal_paused:
		get_tree().paused = false
		_modal_paused = false
	result_overlay.visible = true
	if win:
		result_title.text = "完美胜利" if GameManager.player_victory_tier == "perfect" else "基础胜利"
	else:
		result_title.text = "旅途结束"
	result_title.add_theme_color_override("font_color", Color(0.96, 0.84, 0.48) if win else Color(0.94, 0.52, 0.45))
	var summary := GameManager.build_run_summary_text(win)
	result_detail.text = reason if summary.is_empty() else "%s\n\n%s" % [reason, summary]
	refresh()


func _on_scout_pressed() -> void:
	var result := GameManager.scout()
	if not bool(result.get("ok", false)):
		_show_toast(String(result.get("message", "现在无法侦察。")), true)
	refresh()


func _on_rest_pressed() -> void:
	GameManager.rest()
	refresh()


func _on_clear_pressed() -> void:
	GameManager.clear_drawn_path()
	refresh()


func _on_move_pressed() -> void:
	if not GameManager.execute_move():
		var reason := GameManager.move_block_reason()
		if reason.is_empty():
			reason = "没有可执行的路径：请从角色所在格开始画线"
		_show_toast(reason, true)
	refresh()


func _on_attack_pressed() -> void:
	var result := GameManager.player_attack_companion()
	if not bool(result.get("ok", false)):
		_show_toast(String(result.get("error", "当前无法袭击。")), true)
	refresh()


func _on_end_turn_pressed() -> void:
	GameManager.end_turn()
	refresh()


func _on_restart_pressed() -> void:
	if GameManager.restart_same_seed():
		get_tree().paused = false
		get_tree().reload_current_scene()