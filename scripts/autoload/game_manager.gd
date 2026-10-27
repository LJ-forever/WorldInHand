extends Node
## 一局游戏的总控：地图、玩家、回合、自由画笔路径与逐格移动动画。
## 关键规则：
## - 画路径时只记录线条，不计算/显示 AP 消耗与可达性；
## - 移动时沿玩家画出的线前进，AP 按实际路径距离连续消耗；
## - 可以在当前地块内移动，AP 耗尽时停在路径上的实际位置；
## - 进入新地块时触发到达事件；事件暂停后保留剩余路径。

signal state_changed(new_state: int)
signal turn_started
signal player_moved
signal path_changed
signal movement_started
signal movement_finished(reason: String)
## 移动中 AP 连续下降时发出；HUD 只刷新 AP 文本，不重建整页信息。
signal ap_changed(ap_deci: int)
signal cell_entered(cell_id: int, from_id: int)
signal fog_changed
signal scout_finished(report: Dictionary)
signal companion_changed
signal inventory_changed
## 背包已满、有物品等待玩家丢弃取舍时发出；HUD 据此打开背包页。
signal inventory_overflow_changed
signal dice_rolled(payload: Dictionary)
signal intro_dismissed
signal world_log_changed
## 不需要玩家确认的即时好消息/发现提示，HUD 以 toast 展示。
signal world_notice(text: String)
signal combat_started(payload: Dictionary)
signal combat_updated(payload: Dictionary)
signal combat_finished(payload: Dictionary)
signal game_over(win: bool, reason: String)

enum State { BOOT, TITLE, MAP_SELECT, CHARACTER_SELECT, PLAYING, EVENT, COMBAT, GAME_OVER }

const MAX_ROUNDS := 40
const FIRST_ARRIVAL_REWARD_GOLD := 20
const MOVE_SPEED := 260.0
## 一次有效画线的最短长度（世界像素）；允许整条线都在当前地块内。
const MIN_PATH_LENGTH := 6.0
## 角色停在格边时，允许从标记附近起笔；否则边界点可能被判定成下一格，反而画不了线。
const TOKEN_GRAB_RADIUS := 24.0
## 基础视野半径：等效格径的 2 倍，开局约覆盖 10～15 个地块中心。
## 侦察成功后视野额外扩张 感知/2+1 个平均格距，保持 2 回合后缓慢收束。
const BASE_SIGHT_RADIUS := 2.0
const SCOUT_AP_COST_DECI := 20
const SCOUT_VISION_HOLD_ROUNDS := 2
const VISION_BOOST_DECAY_PER_ROUND := 0.5
const MAX_AI_REVEAL_LEVEL := 3
const WORLD_LOG_LIMIT := 30
const COMPANION_MEMORY_ROUNDS := 4
## 能听见同伴说话/察觉她脚步的最大 BFS 距离。超过这个距离，玩家不应听到她的台词。
const COMPANION_HEARING_RANGE := 3
## 高处/低处判定：0～4 层高程中的两端。
const HIGH_ELEVATION := 3
const LOW_ELEVATION := 1

var state: int = State.BOOT
var round_index: int = 1
var player_character_id: String = ""
var ai_character_id: String = ""
## 玩家角色在本局只记录隐藏任务候选，不分配、不判定；正式版接入个人胜利后再启用。
var player_hidden_task_candidate_ids: Array[String] = []
## AI 同伴本局抽中的隐藏任务，供后续 AI 行动/阵营判定使用，不对玩家公开。
var ai_hidden_task_id: String = ""
## 本局 AI 同伴的完整运行时状态：位置、意图、阵营、好感与自己的目标。
var companion: CompanionAI = null
## 本局同伴的出发地块。与玩家刻意隔开一段距离，开场白会解释走散原因。
var companion_start_cell_id: int = -1
## 开场白是否尚未关闭；只影响 HUD/输入，不阻断自动化逻辑。
var intro_open: bool = false
## 由本局角色、同伴、关系与走散距离生成的序章文本。
var intro_story: Dictionary = {}
## 开场白关闭后再播放的开局 AP 骰子，避免动画被序章盖住。
var pending_intro_dice: Dictionary = {}
## 玩家可见的旅途纪事，用于 4X 式世界反馈与不可见行动的氛围线索。
var world_log: Array[String] = []
## 交互式战斗提示；自动化测试可关闭，关闭后默认“承受”。
var combat_interactive: bool = true
## 当前战斗面板数据。
var combat_payload: Dictionary = {}
## 先到奖励与抢先判定：所有到达记录按 actor 去重。
var goal_arrivals: Array[Dictionary] = []
var first_goal_round: int = 0
var player_goal_round: int = 0
## "perfect" / "basic"；只在玩家胜利后写入。
var player_victory_tier: String = ""
var map: MapData = null
var player: ActorState = null
var selected_map_config: Dictionary = {}
## A3：背包 8 格已满时，新获得的物品在这里排队。
## 玩家在背包页丢弃一件或选择放弃后，队列才会继续处理。
var pending_item_overflows: Array[Dictionary] = []

## 玩家当前正在画 / 已画完的原始笔迹（世界坐标）。
var drawn_stroke: PackedVector2Array = PackedVector2Array()
## 最近一次画线失败的具体原因，直接展示给玩家。
var last_path_error: String = ""
## 笔迹经过的地块序列，[0] 永远是玩家当前所在地块。
var path_cells: Array[int] = []
## 每个地块入口在 move_points 中的下标。
var entry_move_indices: Array[int] = []
## 每个地块入口沿路径的累计距离。
var entry_distances: PackedFloat32Array = PackedFloat32Array()
## 移动动画使用的折线（笔迹的密集采样 + 少量补齐点）。
var move_points: PackedVector2Array = PackedVector2Array()
var path_length: float = 0.0
## 每个 move_point 的累计距离，长度与 move_points 一致。
var move_point_distances: PackedFloat32Array = PackedFloat32Array()
## 每个 move_point 的累计移动消耗（浮点 deci-AP），长度与 move_points 一致。
var move_cost_samples: PackedFloat32Array = PackedFloat32Array()

var is_moving: bool = false
var movement_paused: bool = false
var move_distance: float = 0.0
var visual_position: Vector2 = Vector2.ZERO
var last_move_message: String = ""
## 本次移动已经实际扣除的 AP（deci），用于按累计成本精确扣费。
var _movement_charged_deci: int = 0

## 最近一次侦察的完整检定结果；HUD 用它显示骰子、DC 与揭示范围。
var last_scout_report: Dictionary = {}
var last_scout_message: String = ""
## 侦察大失败后位置暴露到的回合；到该回合结束前 AI 都能知道玩家坐标。
var position_exposed_until_round: int = 0
## 侦察带来的额外视野（单位：平均格距）。保持若干回合后每回合减少 0.5。
var vision_boost_cells: float = 0.0
var vision_boost_hold_rounds: int = 0
## 渲染用平滑视野：半径会缓动到目标值，圆心跟随角色移动。
var vision_center_display: Vector2 = Vector2.ZERO
var vision_radius_display: float = 0.0

var _next_entry_index: int = 1
var _seed_sequence: int = 0
var _combat_stage: String = ""
var _combat_context: Dictionary = {}
var _pending_end_turn_after_combat: bool = false
var _goal_victory_resolved: bool = false


func _ready() -> void:
	state = State.BOOT
	EventManager.event_finished.connect(_on_event_finished)


func _process(delta: float) -> void:
	advance_movement(delta)
	_update_vision_display(delta)


## 圆心跟随角色，半径缓动到目标值。侦察扩张会先保持，再逐回合收束。
func _update_vision_display(delta: float) -> void:
	if map == null or player == null:
		return
	var target_center := visual_position
	var target_radius := vision_radius_world()
	var center_weight := 1.0 - exp(-delta * 12.0)
	var radius_weight := 1.0 - exp(-delta * 2.6)
	vision_center_display = vision_center_display.lerp(target_center, center_weight)
	vision_radius_display = lerpf(vision_radius_display, target_radius, radius_weight)
	if absf(vision_radius_display - target_radius) < 0.05:
		vision_radius_display = target_radius
	map.vision_center = vision_center_display
	map.vision_radius_world = vision_radius_display


func select_map(config: Dictionary) -> void:
	selected_map_config = config.duplicate(true)


func start_new_game(player_id: String, map_config: Dictionary = {}) -> bool:
	var chosen_config := map_config
	if chosen_config.is_empty():
		chosen_config = selected_map_config
	if chosen_config.is_empty():
		chosen_config = MapGenerator.DEFAULT_CONFIG
	if bool(chosen_config.get("randomize_seed", false)):
		chosen_config = chosen_config.duplicate(true)
		chosen_config["seed"] = _roll_map_seed()
	if not is_character_available(player_id, chosen_config):
		push_warning("角色 %s 不在当前地图的角色清单中" % player_id)
		return false
	if available_character_ids(chosen_config).is_empty():
		push_error("当前地图没有可用角色")
		return false
	player_character_id = player_id
	selected_map_config = chosen_config.duplicate(true)
	intro_open = false
	intro_story = {}
	# 地块形状由地图配置种子决定；生态分布每局重新生长，因此同一张地图每次开局不同。
	# 平衡模拟/回归可通过 fixed_terrain_seed 固定生态分布，让同一批种子可复现。
	var terrain_seed := _roll_terrain_seed()
	if not bool(chosen_config.get("randomize_seed", false)) and chosen_config.has("fixed_terrain_seed"):
		terrain_seed = int(chosen_config.get("fixed_terrain_seed", terrain_seed))
	map = MapGenerator.generate(chosen_config, terrain_seed)
	if map == null or map.cells.is_empty():
		push_error("地图生成失败")
		return false
	RNGManager.set_seed(map.terrain_seed if map.terrain_seed != 0 else map.generated_seed)

	var record := DataManager.get_record("characters", player_id)
	player = ActorState.from_character(record)
	if map.start_id < 0 or map.start_id >= map.cells.size():
		push_error("地图起点无效")
		return false
	player.cell_id = map.start_id
	ai_character_id = _pick_ai_id(player_id, available_character_ids(chosen_config))
	player_hidden_task_candidate_ids = mvp_hidden_task_ids(player_id)
	ai_hidden_task_id = _pick_hidden_task_id(ai_character_id, "hidden_task_ai")
	round_index = 1
	world_log.clear()
	combat_payload.clear()
	goal_arrivals.clear()
	first_goal_round = 0
	player_goal_round = 0
	player_victory_tier = ""
	_combat_stage = ""
	_combat_context.clear()
	_pending_end_turn_after_combat = false
	_goal_victory_resolved = false
	pending_item_overflows.clear()
	companion = CompanionAI.new()
	companion_start_cell_id = _pick_companion_start(map, map.start_id)
	if not companion.setup(DataManager.get_record("characters", ai_character_id), ai_hidden_task_id, companion_start_cell_id, RNGManager.get_stream("ai")):
		companion = null
		companion_start_cell_id = -1
		push_warning("AI 同伴初始化失败")
	else:
		companion.last_known_cell = companion_start_cell_id
		companion.last_known_round = round_index
		companion.ever_seen = true
		_add_world_log("你们在进入荒原时走散了：%s在约 %d 格外的另一条路上。" % [
			companion.actor.display_name,
			map.graph_distance(map.start_id, companion_start_cell_id),
		])
	intro_story = _build_intro_story()
	intro_open = true
	player.rest_used = false
	visual_position = map.cell_center(player.cell_id)
	vision_boost_cells = 0.0
	vision_boost_hold_rounds = 0
	vision_center_display = visual_position
	vision_radius_display = _base_vision_radius_world()
	last_move_message = ""
	last_scout_report = {}
	last_scout_message = ""
	position_exposed_until_round = 0
	_clear_path_data()
	is_moving = false
	movement_paused = false
	EventManager.begin_run(map, player)
	map.mark_cell_entered(player.cell_id)
	refresh_vision()
	var opening_ap := player.roll_ap(map.terrain_of(player.cell_id))
	player.apply_ap_penalties()
	pending_intro_dice = _ap_dice_payload(opening_ap, "开局 AP · 第 1 回合")

	_set_state(State.PLAYING)
	turn_started.emit()
	companion_changed.emit()
	world_log_changed.emit()
	player_moved.emit()
	path_changed.emit()
	# 新开局会使旧存档失效；第一次可存档点在序章关闭之后。
	SaveManager.clear_save(SaveManager.DEFAULT_SLOT)
	return true


## 同伴从玩家起点 3～6 格外的另一条路出发：既不会同格叠在一起，
## 也不会远到整局碰不到。开场白会解释“在岔路口走散”的原因。
func _pick_companion_start(map: MapData, player_start: int) -> int:
	if map == null or map.get_cell(player_start) == null:
		return player_start
	var depths: Dictionary = {player_start: 0}
	var frontier: Array[int] = [player_start]
	var candidates: Array[int] = []
	var depth := 0
	while not frontier.is_empty() and depth < 6:
		depth += 1
		var next: Array[int] = []
		for current in frontier:
			for neighbor in map.neighbors_of(current):
				if depths.has(neighbor):
					continue
				depths[neighbor] = depth
				next.append(neighbor)
				if depth < 3:
					continue
				if neighbor == map.goal_id or map.poi_ids.has(neighbor):
					continue
				candidates.append(neighbor)
		frontier = next
	if candidates.is_empty():
		var neighbors := map.neighbors_of(player_start)
		return neighbors[0] if not neighbors.is_empty() else player_start
	var rng := RandomNumberGenerator.new()
	rng.seed = int(map.generated_seed) ^ 0xC0FFEE
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## 根据角色、同伴、初始阵营与两人出发位置生成开场白。
## 关系会直接写进文本，玩家不必靠猜；后续仍会随事件/好感改变。
func _build_intro_story() -> Dictionary:
	var player_record := DataManager.get_record("characters", player_character_id)
	var companion_record := DataManager.get_record("characters", ai_character_id)
	var player_name := String(player_record.get("name", "旅人"))
	var player_role := String(player_record.get("role", "旅人"))
	var companion_name := String(companion_record.get("name", companion_name()))
	var companion_role := String(companion_record.get("role", "同行者"))
	var direction := _direction_text(map.cell_center(map.start_id), map.cell_center(companion_start_cell_id))
	var distance := maxi(0, map.graph_distance(map.start_id, companion_start_cell_id))
	var faction := companion.faction if companion != null else "neutral"
	var player_lore := String({
		"lin_xiao": "你靠一双眼睛和一张旧地图吃饭，习惯先看清路再落脚下。",
		"sha_kai": "你的刀在沙匪里很有名，但这一次你护送的不是货物，而是自己的命。",
		"wei_la": "你熟悉筹码与措辞。荒原上的一切都可以谈，只要价码合适。",
		"ying": "你背着旧案，脚步很轻。没人知道你真正想从烽火台带走什么。",
		"qing_heng": "你为草药与样本而来，相信最危险的荒野里长着最珍贵的药。",
	}.get(player_character_id, "你为烽火台下那件东西而来。"))
	var companion_lore := String({
		"lin_xiao": "她靠观察和记路为生，眼睛很少离开地平线。",
		"sha_kai": "他话不多，弯刀却从不离手。",
		"wei_la": "她把每一次相遇都当作谈判，笑容是一层薄薄的鞘。",
		"ying": "她的脚步几乎没有声音，笑意也很少到眼底。",
		"qing_heng": "她的行囊里全是草叶和药瓶，比金子还沉。",
	}.get(ai_character_id, "她有自己的盘算，也有自己的路。"))
	var reason := ""
	var relation := ""
	match faction:
		"friendly":
			reason = "昨夜沙暴撕开了商队。你们从不同的坡地爬出来，在一条干涸河床旁重新碰头。她提出分头走：她去查看侧翼，你沿主路向烽火台推进，到了终点再会合。"
			relation = "关系：互相照应（友好）——她会主动支援你，但荒原上的信任并非不会改变。"
		"enemy":
			reason = "你们在最后一个驿站因一桩旧账同行。她说要先去另一条路找水，你却看见她握刀的手始终没有松开。烽火台的消息只有一个买家，她未必愿意与你平分。"
			relation = "关系：旧怨未清（敌对）——她可能对你出手；当她与你相邻时，你可以先发制人。"
		_:
			reason = "你们在岔路口做了一个简单的约定：同路，不同心。她选了另一条看起来更稳妥的路，说终点见；你也没问她会不会等你。"
			relation = "关系：同路试探（中立）——她暂时不会为你拼命，也未必与你为敌。"
	var body_parts: Array[String] = [
		"你是%s，一名%s。%s" % [player_name, player_role, player_lore],
		"与你同行的，是%s，一名%s。%s你们并非偶然遇见：%s" % [companion_name, companion_role, companion_lore, reason],
		"分开之后，她此刻在约 %d 格外的%s。荒原的视野被风沙与地形切得很碎，你未必能一直看见她。" % [distance, direction],
		"终点是一座废弃的烽火台，传闻先到者能取走埋在台下的消息与赏金。你必须在 %d 回合内赶到，并先踏足 %d 处地点解除终点封印；封印未解时，烽火台的入口不会为你打开。若她先到且仍与你敌对，你的胜利将不再完美；若你们同回合抵达，则算并列。" % [
			MAX_ROUNDS, EventManager.GOAL_SEAL_POI_COUNT,
		],
	]
	return {
		"title": "风沙将起 · %s" % map.map_name,
		"body": "\n\n".join(body_parts),
		"relation": relation,
		"faction": faction,
	}


func _direction_text(from_point: Vector2, to_point: Vector2) -> String:
	var delta := to_point - from_point
	var horizontal := "东" if delta.x >= 0.0 else "西"
	var vertical := "南" if delta.y >= 0.0 else "北"
	if absf(delta.x) < 0.001:
		return vertical
	if absf(delta.y) < 0.001:
		return horizontal
	if absf(delta.x) > absf(delta.y) * 2.0:
		return "偏" + horizontal
	if absf(delta.y) > absf(delta.x) * 2.0:
		return "偏" + vertical
	return vertical + horizontal


func dismiss_intro() -> void:
	if not intro_open:
		return
	intro_open = false
	companion_changed.emit()
	player_moved.emit()
	intro_dismissed.emit()
	if not pending_intro_dice.is_empty():
		var payload := pending_intro_dice.duplicate(true)
		pending_intro_dice.clear()
		dice_rolled.emit(payload)
	autosave()


func _ap_dice_payload(roll: Dictionary, title: String) -> Dictionary:
	var detail := ActorState.ap_formula_text(roll)
	return {
		"title": title,
		"kind": "ap",
		"kind_label": "每回合开始",
		"dice": roll.get("dice", [1]),
		"sides": 6,
		"modifier": int(roll.get("modifier", 0)),
		"total": int(roll.get("total", 0)),
		"detail": detail,
	}


func restart_same_seed() -> bool:
	if map == null or player_character_id.is_empty():
		return false
	var config := map.config.duplicate(true)
	if config.is_empty():
		config = selected_map_config.duplicate(true)
	# “同种子重开”必须保留当前形状种子，不再触发每局随机。
	config["randomize_seed"] = false
	return start_new_game(player_character_id, config)


func current_map_config() -> Dictionary:
	if map != null and not map.config.is_empty():
		return map.config.duplicate(true)
	return selected_map_config.duplicate(true)


## 地图内容清单：地图 JSON 中的 character_ids / event_ids。
## 字段缺省或为空时回退到全量内容，兼容旧地图与本地临时配置。
func available_character_ids(config: Dictionary = {}) -> Array[String]:
	return _content_ids(config, "character_ids", "characters")


func available_event_ids(config: Dictionary = {}) -> Array[String]:
	return _content_ids(config, "event_ids", "events")


func is_character_available(character_id: String, config: Dictionary = {}) -> bool:
	return available_character_ids(config).has(character_id)


func is_event_available(event_id: String, config: Dictionary = {}) -> bool:
	return available_event_ids(config).has(event_id)


## 玩家角色的隐藏任务候选仅作记录。按设计 §10.5，MVP 不从中分配、不判定、不参与胜负。
func get_player_hidden_task_candidates() -> Array[String]:
	return player_hidden_task_candidate_ids


## AI 同伴本局抽中的隐藏任务；对玩家保密，只供 AI 行动模块使用。
func get_ai_hidden_task() -> Dictionary:
	if ai_hidden_task_id.is_empty():
		return {}
	return DataManager.get_record("hidden_tasks", ai_hidden_task_id)


## 只从角色自己的 MVP 可用任务中分配；P1 任务不进入本局。
func mvp_hidden_task_ids(character_id: String) -> Array[String]:
	var result: Array[String] = []
	var character := DataManager.get_record("characters", character_id)
	for task_id_value in character.get("hidden_task_ids", []):
		var task_id := String(task_id_value)
		var task := DataManager.get_record("hidden_tasks", task_id)
		if task.is_empty() or not bool(task.get("mvp_available", false)):
			continue
		if String(task.get("character_id", "")) != character_id:
			continue
		result.append(task_id)
	return result


func _content_ids(config: Dictionary, field: String, table_name: String) -> Array[String]:
	var result: Array[String] = []
	var source_config := config
	if source_config.is_empty():
		source_config = selected_map_config
	var configured = source_config.get(field, null)
	if typeof(configured) == TYPE_ARRAY and not (configured as Array).is_empty():
		for value in configured:
			var record_id := String(value)
			if record_id.is_empty() or result.has(record_id):
				continue
			if DataManager.has_record(table_name, record_id):
				result.append(record_id)
		return result
	for record in DataManager.all_records(table_name):
		var record_id := String(record.get("id", ""))
		if not record_id.is_empty():
			result.append(record_id)
	return result


func end_turn() -> void:
	if state != State.PLAYING or is_moving or movement_paused:
		return
	# 回合结束：持续伤害 → 被困检定 → 持续时间递减。
	var status_report := player.apply_round_status_effects(round_index)
	var status_messages: Array = status_report.get("messages", [])
	if player.hp <= 0:
		_finish(false, "状态伤害耗尽了你的体力。")
		return
	_resolve_trapped_end_of_round(status_messages)
	var expired := player.tick_status_durations(round_index)
	for status_id in expired:
		status_messages.append("状态「%s」结束。" % String(DataManager.get_record("statuses", status_id).get("name", status_id)))
	if not status_messages.is_empty():
		last_move_message = "；".join(status_messages)
	round_index += 1
	if round_index > MAX_ROUNDS:
		_finish(false, "超过 %d 回合仍未到达终点" % MAX_ROUNDS)
		return
	_run_companion_turn()
	# 同伴的袭击需要玩家决定是否反击；战斗面板关闭后再补完回合尾部。
	if state == State.COMBAT or state == State.GAME_OVER:
		return
	_finish_round_after_companion()


## 同伴行动之后的回合收尾。与 end_turn 拆开，便于战斗提示结束后继续。
func _finish_round_after_companion() -> void:
	_tick_vision_boost()
	EventManager.tick_cooldowns()
	EventManager.start_new_round()
	player.rest_used = false
	_clear_path_data()
	var ap_roll := player.roll_ap(map.terrain_of(player.cell_id))
	var ap_report := player.apply_ap_penalties()
	if int(ap_report.get("hp_lost", 0)) > 0:
		last_move_message = "延迟 AP 惩罚不足，转为 %d HP 损失。" % int(ap_report["hp_lost"])
		if player.hp <= 0:
			_finish(false, "延迟的 AP 惩罚耗尽了你的体力。")
			return
	dice_rolled.emit(_ap_dice_payload(ap_roll, "新回合 AP · 第 %d 回合" % round_index))
	turn_started.emit()
	player_moved.emit()
	path_changed.emit()
	autosave()


## ---------------- AI 同伴 ----------------

## 回合结束时让同伴行动一次。她可能离开视野、在别处搜集物资、完成自己的目标，
## 也可能在相邻格援助、偷窃、下套或袭击。玩家只看到视野内的行动，
## 其余以传闻和最后已知位置呈现。goal_race 用于玩家抵达同回合的终点冲刺。
func _run_companion_turn(goal_race: bool = false, defer_end_turn: bool = true) -> void:
	if companion == null or companion.actor == null or map == null or player == null:
		return
	if not companion.alive:
		return
	var start_cell := companion.actor.cell_id
	var was_visible := companion_is_visible()
	var start_perceived := companion_is_perceived()
	var ai_name := companion_name()
	var report := companion.take_turn(map, player, round_index, was_visible, goal_race)
	var end_perceived := companion_is_perceived()
	if start_perceived:
		companion.ever_seen = true
		companion.last_known_cell = start_cell
		companion.last_known_round = round_index
	if end_perceived:
		companion.ever_seen = true
		companion.last_known_cell = companion.actor.cell_id
		companion.last_known_round = round_index

	var shared: Dictionary = report.get("shared_reveal", {})
	if companion.alive and not shared.is_empty():
		var shared_cells := reveal_area(int(shared.get("center", companion.actor.cell_id)), float(shared.get("radius", 0.0)), true)
		if not shared_cells.is_empty():
			refresh_vision()
			var label := String(shared.get("label", "%s与你分享了沿途地形。" % ai_name))
			_add_world_log(label)
			_append_last_move(label)

	var messages: Array = report.get("messages", [])
	var visible_lines: Array[String] = []
	for message in messages:
		visible_lines.append(String(message))
	if not visible_lines.is_empty():
		var joined := " ".join(visible_lines)
		_add_world_log(joined)
		_append_last_move(joined)
	if bool(report.get("died", false)):
		_add_world_log("%s倒下了。" % ai_name)
	elif bool(report.get("reached_goal", false)):
		_record_goal_arrival("companion", companion.actor, ai_name, companion.faction_at_goal)
		if player_goal_round == round_index:
			_add_world_log("%s在同一回合冲过了终点守卫，与你并列抵达。" % ai_name)
		else:
			_add_world_log("%s先你一步通过了终点守卫。" % ai_name)
	if bool(report.get("theft_warning", false)):
		var warning := "%s盯上了你的行囊：下一回合她可能下手。保持距离，或先发制人。" % ai_name
		_add_world_log(warning)
		_append_last_move(warning)
		world_notice.emit(warning)
	if String(report.get("stolen_item_id", "")) != "":
		var stolen_name := String(report.get("stolen_item_name", "物品"))
		var theft_notice := "%s偷走了你的「%s」。打开背包页可每回合免费追查一次；击败她也能直接取回。" % [
			ai_name, stolen_name,
		]
		_add_world_log(theft_notice)
		_append_last_move(theft_notice)
		world_notice.emit(theft_notice)
		inventory_changed.emit()
	if bool(report.get("task_completed", false)):
		var task := companion.task
		if EventManager.get_reveal_level() >= 3 and not task.is_empty():
			_add_world_log("%s完成了她的计划：%s。" % [ai_name, String(task.get("name", ""))])
		else:
			_add_world_log("%s像是了结了一桩心事。" % ai_name)
	if bool(report.get("died", false)):
		_return_stolen_item(String(report.get("released_stolen_item_id", "")))
	if bool(report.get("faction_changed", false)):
		match String(report.get("faction", "")):
			"enemy":
				_add_world_log("%s看你的眼神冷了下来。" % ai_name)
			"friendly":
				_add_world_log("%s开始主动护着你的侧翼。" % ai_name)
			_:
				_add_world_log("%s重新与你保持了距离。" % ai_name)
	var rumor := String(report.get("rumor", ""))
	if not rumor.is_empty():
		_add_world_log("传闻：" + rumor)
	if companion.alive and player != null:
		var milestone := companion.check_favor_milestone()
		if bool(milestone.get("triggered", false)):
			var gift_item := String(milestone.get("gift_item", "supply"))
			var gift := grant_item(gift_item, 1, "同伴信赖")
			var milestone_message := String(milestone.get("message", ""))
			if bool(gift.get("queued", false)):
				milestone_message += " 背包已满，请在背包页取舍。"
			_add_world_log(milestone_message)
			_append_last_move(milestone_message)
			world_notice.emit(milestone_message)
			inventory_changed.emit()
	companion_changed.emit()

	if bool(report.get("player_defeated", false)):
		var defeat_reason := String(report.get("defeat_reason", "同伴完成了她的互斥目标。"))
		_add_world_log(defeat_reason)
		_finish(false, defeat_reason)
		return

	var combat: Dictionary = report.get("combat", {})
	if companion.alive and not combat.is_empty():
		_handle_companion_combat(combat, defer_end_turn)


## 同伴的攻击先结算，再由玩家决定是否花 1 AP 反击。
func _handle_companion_combat(combat: Dictionary, defer_end_turn: bool) -> void:
	if player == null:
		return
	var lines: Array = combat.get("lines", [])
	if player.hp <= 0:
		_finish(false, "%s的袭击击倒了你。" % companion_name())
		return
	_emit_combat_dice("%s的袭击" % companion_name(), companion_name(), player.display_name, combat)
	_combat_context = {
		"ai_attack": combat.duplicate(true),
		# AI 的袭击已经用掉了它本回合的出手；玩家反击时它不能再顺势多打一次。
		"ai_initiated": true,
	}
	_combat_stage = "choice"
	combat_payload = {
		"title": "遭遇袭击",
		"meta": "%s抢先出手" % companion_name(),
		"lines": lines.duplicate(),
		"stage": "choice",
		"show_choice": true,
		"counter_enabled": player.ap_deci >= CombatRules.AP_COST_DECI,
		"counter_reason": "" if player.ap_deci >= CombatRules.AP_COST_DECI else "AP 不足 1 点，无法反击。",
		"death": false,
	}
	_set_state(State.COMBAT)
	if combat_interactive:
		if defer_end_turn:
			_pending_end_turn_after_combat = true
		combat_started.emit(combat_payload)
		return
	# 无 UI 的自动化流程默认不反击，避免测试因等待输入而挂起。
	_resolve_combat_choice_internal("endure")


## ---------------- 战斗 ----------------

func can_attack_companion() -> bool:
	return attack_block_reason().is_empty()


## 「袭击」按钮为什么可用/不可用。空字符串表示可以出手。
## HUD 直接显示这段文字，避免玩家面对灰按钮猜规则。
func attack_block_reason() -> String:
	if intro_open:
		return "先读完开场白，才能行动"
	if state == State.COMBAT:
		return "战斗结算中"
	if state != State.PLAYING:
		return "当前不是行动阶段"
	if is_moving or movement_paused:
		return "移动或事件尚未结束"
	if player == null or companion == null or companion.actor == null or map == null:
		return "当前没有可袭击的目标"
	if not companion.alive:
		return "同伴已经倒下"
	if companion.faction == "friendly":
		return "关系为「友好」：袭击盟友会立刻转为敌对，且无法带来胜利优势"
	if companion.faction != "enemy":
		return "关系为「中立」：她尚未与你为敌；先观察，或通过事件让立场改变"
	if player.ap_deci < CombatRules.AP_COST_DECI:
		return "AP 不足 1 点（当前 %.1f）" % (player.ap_deci / 10.0)
	var distance := map.graph_distance(player.cell_id, companion.actor.cell_id)
	if distance < 0:
		return "找不到通往她的相邻路线"
	if distance > 1:
		return "需要与她相邻（当前相距 %d 格）" % distance
	return ""


## 玩家主动袭击敌方同伴：先手 1 AP，随后同伴若存活且为敌方会消耗 1 AP 反击。
func player_attack_companion() -> Dictionary:
	if not can_attack_companion():
		return {"ok": false, "error": "当前无法袭击同伴。"}
	var attack := CombatRules.resolve_attack(player, companion.actor, RNGManager.get_stream("event"))
	_emit_combat_dice("你的袭击", player.display_name, companion_name(), attack)
	var lines := CombatRules.describe_attack(attack, player.display_name, companion_name())
	var counter: Dictionary = {}
	if companion.actor.hp <= 0:
		mark_companion_dead("被你击倒")
	elif companion.faction == "enemy" and companion.actor.ap_deci >= CombatRules.AP_COST_DECI:
		counter = CombatRules.resolve_attack(companion.actor, player, RNGManager.get_stream("ai"))
		lines.append("")
		lines.append_array(CombatRules.describe_attack(counter, companion_name(), player.display_name))
	var death := player.hp <= 0
	_combat_context = {"player_attack": attack}
	_combat_stage = "resolved"
	combat_payload = {
		"title": "主动袭击",
		"meta": "你向%s出手" % companion_name(),
		"lines": lines,
		"stage": "resolved",
		"show_choice": false,
		"counter_enabled": false,
		"death": death,
	}
	_set_state(State.COMBAT)
	combat_started.emit(combat_payload)
	if death:
		_add_world_log("%s在反击中击倒了你。" % companion_name())
	else:
		_add_world_log("你与%s交了一次手。" % companion_name())
	if not combat_interactive:
		close_combat()
	return {
		"ok": true,
		"attack": attack,
		"counter": counter,
		"death": death,
		"payload": combat_payload.duplicate(true),
	}


func _emit_combat_dice(title: String, attacker_name: String, defender_name: String, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		return
	var dice: Array = result.get("dice", [])
	if dice.size() < 2:
		return
	var modifier := int(result.get("base", 0)) + int(result.get("equipment", 0)) + int(result.get("status", 0))
	var damage := int(result.get("damage", 0))
	var detail := CombatRules.attack_formula_text(result)
	if damage > 0:
		detail += " · %s受到 %d 点伤害" % [defender_name, damage]
	else:
		detail += " · 未破防"
	dice_rolled.emit({
		"title": title,
		"kind": "combat",
		"kind_label": "%s → %s · 1 AP" % [attacker_name, defender_name],
		"dice": [int(dice[0]), int(dice[1])],
		"sides": 6,
		"modifier": modifier,
		"total": int(result.get("total", 0)),
		"dc": int(result.get("dc", 0)),
		"level_name": String(result.get("level_name", "")),
		"detail": detail,
	})


## UI 入口：counter = 花 1 AP 反击，endure = 承受这一击。
func resolve_combat_choice(choice_id: String) -> Dictionary:
	if state != State.COMBAT or _combat_stage != "choice":
		return {"ok": false, "error": "当前没有待处理的战斗选择。"}
	return _resolve_combat_choice_internal(choice_id)


func _resolve_combat_choice_internal(choice_id: String) -> Dictionary:
	var ai_attack: Dictionary = _combat_context.get("ai_attack", {})
	var lines: Array = ai_attack.get("lines", [])
	var counter: Dictionary = {}
	var ai_counter: Dictionary = {}
	if choice_id == "counter" and player.ap_deci >= CombatRules.AP_COST_DECI and companion != null and companion.alive:
		counter = CombatRules.resolve_attack(player, companion.actor, RNGManager.get_stream("event"))
		lines.append("")
		lines.append("你消耗 1 AP 反击。")
		lines.append_array(CombatRules.describe_attack(counter, player.display_name, companion_name()))
		if companion.actor.hp <= 0:
			mark_companion_dead("在反击中倒下")
		elif not bool(_combat_context.get("ai_initiated", false)) \
				and companion.faction == "enemy" \
				and companion.actor.ap_deci >= CombatRules.AP_COST_DECI:
			ai_counter = CombatRules.resolve_attack(companion.actor, player, RNGManager.get_stream("ai"))
			lines.append("")
			lines.append("%s顺势反击。" % companion_name())
			lines.append_array(CombatRules.describe_attack(ai_counter, companion_name(), player.display_name))
	else:
		if choice_id == "counter":
			lines.append("你想反击，但 AP 不足，只能稳住身形。")
		else:
			lines.append("你没有反击，任由这一击落在身上。")
	if not counter.is_empty():
		_emit_combat_dice("你的反击", player.display_name, companion_name(), counter)
	var death := player.hp <= 0
	_combat_stage = "resolved"
	combat_payload = {
		"title": "遭遇袭击",
		"meta": "%s抢先出手" % companion_name(),
		"lines": lines,
		"stage": "resolved",
		"show_choice": false,
		"counter_enabled": false,
		"death": death,
	}
	combat_updated.emit(combat_payload)
	if death:
		_add_world_log("%s的攻击击倒了你。" % companion_name())
	if not combat_interactive:
		close_combat()
	return {
		"ok": true,
		"counter": counter,
		"ai_counter": ai_counter,
		"death": death,
		"payload": combat_payload.duplicate(true),
	}


## 战斗面板点击「继续」：玩家倒下则判负；否则恢复行动或补完本回合。
func close_combat() -> void:
	if state != State.COMBAT:
		return
	var payload := combat_payload.duplicate(true)
	combat_payload = {}
	_combat_stage = ""
	_combat_context.clear()
	combat_finished.emit(payload)
	if player != null and player.hp <= 0:
		_pending_end_turn_after_combat = false
		_finish(false, "你在与%s的交手中倒下。" % companion_name())
		return
	_set_state(State.PLAYING)
	if _pending_end_turn_after_combat:
		_pending_end_turn_after_combat = false
		_finish_round_after_companion()
	else:
		autosave()


## ---------------- 先到奖励与胜利 ----------------

func _record_goal_arrival(actor_key: String, actor: ActorState, actor_label: String, faction_at_arrival: String) -> Dictionary:
	for entry in goal_arrivals:
		if String(entry.get("actor", "")) == actor_key:
			return entry
	var first := goal_arrivals.is_empty() and first_goal_round == 0
	if first_goal_round == 0:
		first_goal_round = round_index
	var rewarded := round_index == first_goal_round
	if rewarded and actor != null:
		actor.gold += FIRST_ARRIVAL_REWARD_GOLD
	if actor_key == "player":
		player_goal_round = round_index
	var entry := {
		"actor": actor_key,
		"name": actor_label,
		"round": round_index,
		"faction_at_arrival": faction_at_arrival,
		"rewarded": rewarded,
	}
	goal_arrivals.append(entry)
	if first:
		_add_world_log("%s第一个通过终点守卫，获得先到奖励 +%d 金币。" % [actor_label, FIRST_ARRIVAL_REWARD_GOLD])
	elif rewarded:
		_add_world_log("%s与先到者同回合抵达，同样获得 +%d 金币。" % [actor_label, FIRST_ARRIVAL_REWARD_GOLD])
	else:
		_add_world_log("%s通过终点守卫，但先到奖励已由更早抵达者取得。" % actor_label)
	return entry


## 玩家胜利结算：记录到达、给同伴同回合冲刺机会，再按到达时阵营判定完美/基础胜利。
func _finalize_victory(base_reason: String) -> String:
	if _goal_victory_resolved:
		return base_reason
	_goal_victory_resolved = true
	var arrival := _record_goal_arrival("player", player, "你", "player")
	if companion != null and companion.alive and not companion.reached_goal:
		_run_companion_turn(true, false)
	var enemy_at_goal := companion != null and companion.reached_goal \
		and companion.faction_at_goal == "enemy"
	player_victory_tier = "basic" if enemy_at_goal else "perfect"
	var parts: Array[String] = [base_reason]
	parts.append("完美胜利。" if player_victory_tier == "perfect" else "基础胜利。")
	if bool(arrival.get("rewarded", false)):
		parts.append("先到奖励 +%d 金币。" % FIRST_ARRIVAL_REWARD_GOLD)
	elif first_goal_round > 0:
		parts.append("先到奖励已由更早抵达者取得。")
	if companion != null:
		if companion.reached_goal:
			if companion.goal_round == round_index:
				parts.append("同伴与你同回合抵达。")
			elif enemy_at_goal:
				parts.append("敌方同伴已先你抵达，完美胜利失效。")
			else:
				parts.append("同伴先于你抵达，但到达时并非敌方，不影响完美胜利。")
		elif companion.alive:
			parts.append("同伴仍在路上。")
		else:
			parts.append("同伴没能走到终点。")
	return " ".join(parts)


func _append_last_move(text: String) -> void:
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	if last_move_message.is_empty():
		last_move_message = clean
	else:
		last_move_message += "；" + clean


func _add_world_log(text: String) -> void:
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	var line := "第 %d 回合 · %s" % [round_index, clean]
	if not world_log.is_empty() and world_log[world_log.size() - 1] == line:
		return
	world_log.append(line)
	while world_log.size() > WORLD_LOG_LIMIT:
		world_log.pop_front()
	world_log_changed.emit()


func get_world_log() -> Array[String]:
	return world_log.duplicate()


func add_world_log(text: String) -> void:
	_add_world_log(text)


func companion_name() -> String:
	return companion.actor.display_name if companion != null and companion.actor != null else "—"


func companion_is_alive() -> bool:
	return companion != null and companion.alive


func companion_is_visible() -> bool:
	if companion == null or not companion.alive or map == null:
		return false
	return map.is_point_in_current_vision(map.cell_center(companion.actor.cell_id))


## 玩家与同伴之间的 BFS 距离；不可达或没有同伴时返回 -1。
func companion_distance_to_player() -> int:
	if companion == null or companion.actor == null or map == null or player == null:
		return -1
	return map.graph_distance(player.cell_id, companion.actor.cell_id)


## 看不见但在听觉范围内：能听到台词与脚步，地图上以半透明「听声」标记跟踪她。
func companion_is_heard() -> bool:
	if companion == null or not companion.alive or companion_is_visible():
		return false
	var distance := companion_distance_to_player()
	return distance >= 0 and distance <= COMPANION_HEARING_RANGE


## 视野内或听觉范围内：玩家此刻能感知到她的实际位置。
func companion_is_perceived() -> bool:
	return companion_is_visible() or companion_is_heard()


## 地图标记状态：visible=亲眼看见；heard=听声辨位；last_known=旧踪迹；hidden=不显示。
## 标记只在这四种状态间切换，避免同伴明明在移动、图标却一直钉在旧位置。
func companion_marker_state() -> String:
	if companion == null or companion.actor == null or map == null:
		return "hidden"
	if companion.alive:
		if companion_is_visible():
			return "visible"
		if companion_is_heard():
			return "heard"
	if companion.last_known_cell < 0 or companion.last_known_cell >= map.cells.size():
		return "hidden"
	if not map.is_cell_known(companion.last_known_cell):
		return "hidden"
	var rounds := maxi(0, round_index - companion.last_known_round)
	if rounds > COMPANION_MEMORY_ROUNDS:
		return "hidden"
	return "last_known"


## 地图标记应该画在哪一格：能看见/听见时用她的真实位置，否则退回最后已知位置。
func companion_marker_cell() -> int:
	match companion_marker_state():
		"visible", "heard":
			return companion.actor.cell_id
		"last_known":
			return companion.last_known_cell
		_:
			return -1


func companion_at_player(max_distance: int = 1) -> bool:
	if companion == null or companion.actor == null or map == null or player == null:
		return false
	var distance := map.graph_distance(player.cell_id, companion.actor.cell_id)
	return distance >= 0 and distance <= max_distance


func companion_intel_text() -> String:
	var level := EventManager.get_reveal_level()
	var names := ["完全未知", "倾向线索", "阵营线索", "友好度与目标"]
	return "情报 %d/3（%s）" % [level, names[clampi(level, 0, names.size() - 1)]]


func companion_relation_text() -> String:
	if companion == null or not companion.alive:
		return "—"
	# 开场白已经直接交代最初关系；这里始终显示当前立场，
	# 好感数值与隐藏任务仍受情报等级限制。
	var text := "%s · %s" % [companion.faction_name(), companion.bond_label()]
	var level := EventManager.get_reveal_level()
	if level >= 3:
		text += "（好感 %+d）" % companion.favor
	return text


func companion_status_text() -> String:
	if companion == null:
		return "—"
	if not companion.alive:
		return "已经倒下"
	if companion_is_visible():
		return "正在%s" % companion.activity
	if companion_is_heard():
		return "能听见她的动静（距你约 %d 格）" % companion_distance_to_player()
	if companion.last_known_cell < 0 or companion.last_known_round <= 0:
		return "行踪不明"
	var rounds := maxi(0, round_index - companion.last_known_round)
	if rounds <= COMPANION_MEMORY_ROUNDS:
		return "%d 回合前最后出现" % rounds
	return "踪迹已经模糊"


func companion_last_known_text() -> String:
	if companion == null:
		return "—"
	if companion_is_visible():
		return "就在你的视野内"
	if companion_is_heard():
		return "就在附近（听声辨位）"
	if companion.last_known_cell < 0:
		return "从未见过"
	if EventManager.get_reveal_level() < 2:
		return "情报不足"
	var from := map.cell_center(player.cell_id)
	var to := map.cell_center(companion.last_known_cell)
	var delta := to - from
	var horizontal := "东" if delta.x >= 0.0 else "西"
	var vertical := "南" if delta.y >= 0.0 else "北"
	var direction := vertical + horizontal
	if absf(delta.x) < absf(delta.y) * 0.4:
		direction = vertical
	elif absf(delta.y) < absf(delta.x) * 0.4:
		direction = horizontal
	var rounds := maxi(0, round_index - companion.last_known_round)
	return "%s方向 · %d 回合前" % [direction, rounds]


func companion_task_text() -> String:
	if companion == null or not companion.alive:
		return "—"
	if EventManager.get_reveal_level() < 3:
		return "意图不明（情报 3 级可读）"
	var task := companion.task
	if task.is_empty():
		return "没有明显的个人目标"
	return "%s · %s" % [String(task.get("name", "自己的计划")), companion.task_progress_text()]


func companion_condition_text() -> String:
	if companion == null or not companion.alive:
		return "—"
	if companion_is_perceived() or EventManager.get_reveal_level() >= 2:
		return companion.condition_text()
	return "看不清"


## 同伴状态栏里的台词。只有看得见她时才像“当面说话”；
## 看不见但离得近时是雾里传来的声音；超出听觉距离则不显示她的新台词。
func companion_speech_text() -> String:
	if companion == null or companion.actor == null or not companion.alive:
		return "……"
	var speech := companion.last_speech.strip_edges()
	if speech.is_empty():
		speech = "终点见。"
	if companion_is_visible():
		return "「%s」" % speech
	if companion_is_heard():
		return "雾里传来她的声音：「%s」" % speech
	return "她在远处，听不见她说话。（听觉范围 %d 格）" % COMPANION_HEARING_RANGE


func apply_companion_favor(delta: int) -> Dictionary:
	if companion == null or not companion.alive or delta == 0:
		return {}
	var result := companion.change_favor(delta)
	if bool(result.get("faction_changed", false)):
		var ai_name := companion_name()
		match String(result.get("faction", "")):
			"enemy":
				_add_world_log("%s对你的态度转为敌对。" % ai_name)
			"friendly":
				_add_world_log("%s对你的态度转为友好。" % ai_name)
			_:
				_add_world_log("%s对你的态度变得难以捉摸。" % ai_name)
	var milestone := companion.check_favor_milestone()
	if bool(milestone.get("triggered", false)) and player != null:
		var gift_item := String(milestone.get("gift_item", "supply"))
		var gift := grant_item(gift_item, 1, "同伴信赖")
		var milestone_message := String(milestone.get("message", ""))
		if bool(gift.get("queued", false)):
			milestone_message += " 背包已满，请在背包页取舍。"
		result["milestone"] = true
		result["milestone_id"] = String(milestone.get("id", ""))
		result["milestone_message"] = milestone_message
		_add_world_log(milestone_message)
		world_notice.emit(milestone_message)
		inventory_changed.emit()
	companion_changed.emit()
	return result


func mark_companion_dead(reason: String) -> void:
	if companion == null or not companion.alive:
		return
	var released := companion.release_stolen_item()
	companion.alive = false
	companion.activity = "倒下"
	_add_world_log("%s倒下了（%s）。" % [companion_name(), reason])
	if not released.is_empty():
		_return_stolen_item(released)
	companion_changed.emit()


## 影倒下/被击败后，把失物直接放回玩家背包；背包已满时按 A3 进入待取舍队列。
func _return_stolen_item(item_id: String) -> void:
	if item_id.is_empty() or player == null:
		return
	var item_name := String(DataManager.get_record("items", item_id).get("name", item_id))
	var granted := grant_item(item_id, 1, "取回失物")
	var message := "你从%s身上取回了「%s」。" % [companion_name(), item_name]
	if bool(granted.get("queued", false)):
		message += " 背包已满，请在背包页取舍。"
	_add_world_log(message)
	_append_last_move(message)
	world_notice.emit(message)
	inventory_changed.emit()


## 被困：回合结束体力检定 DC 10；失败最多再持续 1 回合。
func _resolve_trapped_end_of_round(messages: Array) -> void:
	if not player.has_status("trapped"):
		return
	var dice := RNGManager.roll_2d6("event")
	var modifier := player.attribute_base("stamina") + player.status_check_modifier("stamina")
	var total := int(dice[0]) + int(dice[1]) + modifier
	var entry: Dictionary = player.statuses["trapped"]
	var level_name := "仍被困"
	if total >= 10:
		player.remove_status("trapped")
		messages.append("体力检定 %d ≥ 10，解除被困" % total)
		level_name = "挣脱成功"
	else:
		entry["failed_checks"] = int(entry.get("failed_checks", 0)) + 1
		if int(entry["failed_checks"]) >= 2:
			player.remove_status("trapped")
			messages.append("被困已达 2 回合，自动解除")
			level_name = "自动解除"
		else:
			entry["remaining"] = 1
			# 让持续时间递减跳过本回合，保证下回合仍处于被困。
			entry["added_round"] = round_index + 1
			player.statuses["trapped"] = entry
			messages.append("体力检定 %d < 10，被困再持续 1 回合" % total)
	dice_rolled.emit({
		"title": "挣脱检定",
		"kind": "check",
		"kind_label": "回合结束",
		"dice": [int(dice[0]), int(dice[1])],
		"sides": 6,
		"modifier": modifier,
		"total": total,
		"dc": 10,
		"level_name": level_name,
		"detail": "%s = %d vs DC 10（基础） · %s" % [
			player.check_formula_text("stamina", int(dice[0]) + int(dice[1]), "体力", false),
			total, level_name,
		],
	})


## 休息：不消耗 AP，回复 1 HP，每回合一次。
func rest() -> void:
	if state != State.PLAYING or player == null or player.rest_used or is_moving:
		return
	player.rest_used = true
	player.heal(1)
	player_moved.emit()
	autosave()


## ---------------- 背包容量 / 失物追查 ----------------

## A3：所有玩法内获得物品都走这里。背包 8 格已满时先排队，
## HUD 在安全边界打开背包页，让玩家丢弃一件物品或放弃新物品。
func grant_item(item_id: String, count: int = 1, source: String = "") -> Dictionary:
	if player == null or item_id.is_empty() or count <= 0:
		return {"ok": false, "added": 0, "queued": false, "message": "当前无法获得物品。"}
	if not DataManager.has_record("items", item_id):
		# 未知 ID 一旦进入背包，存档能写回、读档后却无法显示或使用，造成前后不一致。
		push_warning("拒绝授予未知物品：%s" % item_id)
		return {
			"ok": false,
			"added": 0,
			"queued": false,
			"item_id": item_id,
			"message": "未知物品「%s」，没有加入背包。" % item_id,
		}
	var item_name := player.item_display_name(item_id)
	if not player.can_add_item(item_id):
		var queued_count := maxi(1, count)
		pending_item_overflows.append({
			"item_id": item_id,
			"count": queued_count,
			"source": source,
		})
		var queued_message := "发现「%s」×%d，但背包已满：请在背包页丢弃一件，或放弃它。" % [
			item_name, queued_count,
		]
		inventory_overflow_changed.emit()
		return {
			"ok": true,
			"added": 0,
			"queued": true,
			"item_id": item_id,
			"message": queued_message,
		}
	player.add_item(item_id, count)
	inventory_changed.emit()
	return {
		"ok": true,
		"added": count,
		"queued": false,
		"item_id": item_id,
		"message": "获得「%s」×%d。" % [item_name, count],
	}


func has_pending_item_overflow() -> bool:
	return not pending_item_overflows.is_empty()


func current_item_overflow() -> Dictionary:
	if pending_item_overflows.is_empty():
		return {}
	return pending_item_overflows[0].duplicate(true)


## discard_item_id 为空表示拒绝新物品，按 A3 直接丢失；否则从背包丢弃 1 件。
func resolve_item_overflow(discard_item_id: String = "") -> Dictionary:
	if player == null or pending_item_overflows.is_empty():
		return {"ok": false, "message": "当前没有待处理的背包溢出。"}
	var entry: Dictionary = pending_item_overflows[0]
	var item_id := String(entry.get("item_id", ""))
	var count := maxi(1, int(entry.get("count", 1)))
	var item_name := player.item_display_name(item_id)
	var message := ""
	if discard_item_id.is_empty():
		pending_item_overflows.remove_at(0)
		message = "你放弃了「%s」×%d。" % [item_name, count]
	else:
		if not player.inventory.has(discard_item_id):
			return {"ok": false, "message": "背包里没有这件物品，无法丢弃。"}
		var discarded_name := player.item_display_name(discard_item_id)
		player.inventory.erase(discard_item_id)
		player.add_item(item_id, count)
		pending_item_overflows.remove_at(0)
		message = "丢弃「%s」×1，收下「%s」×%d。" % [discarded_name, item_name, count]
	_add_world_log(message)
	inventory_changed.emit()
	inventory_overflow_changed.emit()
	world_notice.emit(message)
	autosave()
	return {
		"ok": true,
		"item_id": item_id,
		"discarded": discard_item_id,
		"message": message,
		"remaining": pending_item_overflows.size(),
	}


## D-25：被影偷走后，每回合可免费进行一次感知检定 DC 12。
func stolen_item_recovery_info() -> Dictionary:
	if companion == null or not companion.has_stolen_item():
		return {"available": false}
	var attempted := companion.has_attempted_recovery(round_index)
	var can_attempt := state == State.PLAYING \
		and not intro_open and not is_moving and not movement_paused and not attempted
	var item_name := companion.stolen_item_name()
	var hint := "每回合可免费进行一次感知检定（DC 12，不消耗 AP）。"
	if attempted:
		hint = "本回合已经追查过，下回合可再免费检定一次。"
	elif not can_attempt:
		hint = "当前状态下不能追查；结束移动或事件后再试。"
	return {
		"available": true,
		"item_id": companion.stolen_item_id(),
		"item_name": item_name,
		"attempted": attempted,
		"can_attempt": can_attempt,
		"hint": hint,
	}


func recover_stolen_item() -> Dictionary:
	if state != State.PLAYING or player == null or companion == null:
		return {"ok": false, "message": "现在无法追查失物。"}
	if intro_open or is_moving or movement_paused:
		return {"ok": false, "message": "移动或事件处理中不能追查失物。"}
	if not companion.has_stolen_item():
		return {"ok": false, "message": "你身上没有需要追回的失物。"}
	var result := companion.attempt_recover_stolen_item(player, round_index)
	if not bool(result.get("ok", false)):
		return result
	var dice: Array = result.get("dice", [])
	var total := int(result.get("total", 0))
	var natural := int(result.get("natural", 0))
	dice_rolled.emit({
		"title": "追查失物",
		"kind": "check",
		"kind_label": "免费 · 感知检定",
		"dice": [int(dice[0]), int(dice[1])],
		"sides": 6,
		"modifier": total - natural,
		"total": total,
		"dc": int(result.get("dc", CompanionAI.RECOVERY_DC)),
		"level_name": String(result.get("level_name", "")),
		"detail": "%s = %d vs DC %d · %s" % [
			String(result.get("formula", "")), total,
			int(result.get("dc", CompanionAI.RECOVERY_DC)),
			String(result.get("level_name", "")),
		],
	})
	var message := String(result.get("message", ""))
	if bool(result.get("success", false)):
		var granted := grant_item(String(result.get("item_id", "")), 1, "追回失物")
		var grant_message := String(granted.get("message", "")).strip_edges()
		if not grant_message.is_empty():
			message += " " + grant_message
		if bool(result.get("faction_changed", false)):
			message += " 她的立场变为%s。" % companion.faction_name()
		_add_world_log(message)
		last_move_message = message
		world_notice.emit(message)
	elif not message.is_empty():
		last_move_message = message
		world_notice.emit(message)
	companion_changed.emit()
	player_moved.emit()
	autosave()
	result["message"] = message
	return result


## 背包里可以立即使用的消耗品选项。空数组表示该物品不能主动使用。
## 每个选项都带 disabled/reason，UI 可以直接渲染成按钮。
func consumable_options(item_id: String) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if player == null or state != State.PLAYING or is_moving or movement_paused:
		return options
	var record := DataManager.get_record("items", item_id)
	if record.is_empty() or String(record.get("type", "")) != "consumable":
		return options
	var effects: Dictionary = record.get("effects", {})
	match String(effects.get("use", "")):
		"choose_hp_or_ap_1":
			options.append({
				"id": "hp",
				"label": "恢复 1 HP（%d / %d）" % [player.hp, player.hp_max],
				"disabled": player.hp >= player.hp_max,
				"reason": "HP 已满。" if player.hp >= player.hp_max else "",
			})
			options.append({
				"id": "ap",
				"label": "恢复 1 AP（%.1f / %.1f）" % [player.ap_deci / 10.0, player.ap_max_deci / 10.0],
				"disabled": player.ap_deci >= player.ap_max_deci,
				"reason": "AP 已满。" if player.ap_deci >= player.ap_max_deci else "",
			})
		"remove_one_negative_status":
			var removable := _removable_status_ids(item_id)
			for status_id in removable:
				options.append({
					"id": status_id,
					"label": "解除「%s」" % _status_display_name(status_id),
					"disabled": false,
					"reason": "",
				})
			if options.is_empty():
				options.append({
					"id": "",
					"label": "没有可解除的负面状态",
					"disabled": true,
					"reason": "当前没有药水能解除的负面状态。",
				})
	return options


## 使用背包中的消耗品。option 对补给是 hp/ap，对药水是状态 id（留空则解除第一个）。
func use_item(item_id: String, option: String = "") -> Dictionary:
	if state != State.PLAYING or player == null:
		return {"ok": false, "message": "现在不能使用物品。"}
	if is_moving or movement_paused:
		return {"ok": false, "message": "移动或事件处理中不能使用物品。"}
	var record := DataManager.get_record("items", item_id)
	if record.is_empty() or String(record.get("type", "")) != "consumable":
		return {"ok": false, "message": "这件物品不能直接使用。"}
	if not player.has_item(item_id):
		return {"ok": false, "message": "背包里没有这件物品。"}
	var effects: Dictionary = record.get("effects", {})
	var use_id := String(effects.get("use", ""))
	var message := ""
	match use_id:
		"choose_hp_or_ap_1":
			if option == "hp":
				if player.hp >= player.hp_max:
					return {"ok": false, "message": "HP 已满，不需要使用%s。" % String(record.get("name", item_id))}
				player.heal(1)
				message = "使用%s，恢复 1 HP。" % String(record.get("name", item_id))
			elif option == "ap":
				if player.ap_deci >= player.ap_max_deci:
					return {"ok": false, "message": "AP 已满，不需要使用%s。" % String(record.get("name", item_id))}
				player.ap_deci += 10
				message = "使用%s，恢复 1 AP。" % String(record.get("name", item_id))
			else:
				return {"ok": false, "message": "请选择恢复 HP 还是 AP。"}
		"remove_one_negative_status":
			var removable := _removable_status_ids(item_id)
			if removable.is_empty():
				return {"ok": false, "message": "当前没有能用药水解除的负面状态。"}
			var target := option
			if target.is_empty():
				target = removable[0]
			if not removable.has(target):
				return {"ok": false, "message": "这个状态无法用该药水解除。"}
			player.remove_status(target)
			message = "使用%s，解除「%s」。" % [
				String(record.get("name", item_id)), _status_display_name(target),
			]
		_:
			return {"ok": false, "message": "这件物品没有可用的效果。"}
	if player.remove_item(item_id, 1) <= 0:
		return {"ok": false, "message": "背包里没有这件物品。"}
	_add_world_log(message)
	inventory_changed.emit()
	player_moved.emit()
	autosave()
	return {"ok": true, "message": message}


func _removable_status_ids(item_id: String) -> Array[String]:
	var result: Array[String] = []
	if player == null:
		return result
	var record := DataManager.get_record("items", item_id)
	var effects: Dictionary = record.get("effects", {})
	var allowed: Array = effects.get("removable_status_ids", [])
	for status_id in player.statuses.keys():
		var status := DataManager.get_record("statuses", String(status_id))
		if not bool(status.get("removable_by_potion", false)):
			continue
		if not allowed.is_empty() and not allowed.has(String(status_id)):
			continue
		result.append(String(status_id))
	return result


func _status_display_name(status_id: String) -> String:
	return String(DataManager.get_record("statuses", status_id).get("name", status_id))


func can_draw_path() -> bool:
	return move_block_reason().is_empty()


## 玩家画线被拒绝时，给出能直接显示给玩家的具体原因。
## 空字符串表示可以画线；非空字符串同时用于地图点击与 HUD 提示。
func move_block_reason() -> String:
	if intro_open:
		return "先读完开场白：按下「踏入荒原」后才能行动"
	if state == State.EVENT:
		return "事件处理中：请先完成当前选择"
	if state == State.COMBAT:
		return "战斗中：请先结束当前战斗"
	if state == State.GAME_OVER:
		return "本局已经结束"
	if state != State.PLAYING:
		return "当前不是移动阶段"
	if player == null or map == null:
		return "地图尚未准备好"
	if is_moving:
		return "正在移动：请等角色走到路径终点"
	if movement_paused:
		return "移动被事件打断：处理完事件后可以继续"
	if player.status_blocks_movement():
		var status_name := player.movement_block_status_name()
		return "无法移动：你正处于「%s」状态（%s）" % [status_name, player.movement_block_status_hint()]
	return ""


## 路径无效（没有从角色所在格起笔、画到地图外，或笔迹太短）时给玩家的原因。
func path_rejection_reason() -> String:
	if not move_block_reason().is_empty():
		return move_block_reason()
	if not has_drawn_path():
		return "路径太短：请从角色标记按住左键，拖出一段可走的线（可在当前地块内）"
	return ""


## 接收玩家松开鼠标时的自由笔迹。只建立地块序列与隐藏成本曲线，不显示 AP。
## 允许整条路径都在当前地块内；AP 会按实际画线长度连续消耗。
func set_drawn_path(stroke: PackedVector2Array) -> bool:
	last_path_error = ""
	var block_reason := move_block_reason()
	if not block_reason.is_empty():
		last_path_error = block_reason
		return false
	if stroke.size() < 2:
		last_path_error = "笔迹太短：按住左键拖出一段线"
		return false
	var dense := _densify_stroke(stroke, 2.5)
	if dense.size() < 2:
		last_path_error = "笔迹太短：按住左键拖出一段线"
		return false
	var start_cell := map.cell_at_point(dense[0])
	if start_cell != player.cell_id:
		# 角色停在格边时，从标记起笔的落点可能被算进下一格。
		# 只要笔尖确实在标记附近，就从角色实际位置开始，而不是拒绝整条线。
		if dense[0].distance_to(visual_position) > TOKEN_GRAB_RADIUS:
			last_path_error = "起笔位置不对：请从角色标记所在的地块开始画线"
			return false
		dense[0] = visual_position
		start_cell = player.cell_id

	var points := PackedVector2Array()
	points.append(visual_position)
	var cells: Array[int] = [player.cell_id]
	var entry_indices: Array[int] = [0]
	var point_cells: Array[int] = [player.cell_id]
	var last_cell := player.cell_id
	var last_point := visual_position
	if dense[0].distance_to(visual_position) >= 1.5:
		points.append(dense[0])
		point_cells.append(start_cell)
		last_point = dense[0]

	for i in range(1, dense.size()):
		var point := dense[i]
		var cell_id := map.cell_at_point(point)
		if cell_id < 0:
			break
		if cell_id == last_cell:
			if point.distance_to(last_point) >= 1.5:
				points.append(point)
				point_cells.append(cell_id)
				last_point = point
			continue
		if map.are_adjacent(last_cell, cell_id):
			points.append(point)
			point_cells.append(cell_id)
			last_point = point
			cells.append(cell_id)
			entry_indices.append(points.size() - 1)
			last_cell = cell_id
			continue
		var fill := map.shortest_cell_path(last_cell, cell_id)
		if fill.is_empty():
			break
		for fill_id in fill:
			if fill_id == cell_id:
				points.append(point)
				point_cells.append(cell_id)
				last_point = point
			else:
				var center := map.cell_center(fill_id)
				points.append(center)
				point_cells.append(fill_id)
				last_point = center
			cells.append(fill_id)
			entry_indices.append(points.size() - 1)
		last_cell = cell_id

	if points.size() < 2:
		last_path_error = "路径太短：按住左键拖出一段可走的线"
		return false

	var distances := PackedFloat32Array()
	distances.resize(points.size())
	distances[0] = 0.0
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
		distances[i] = total
	if total < MIN_PATH_LENGTH:
		last_path_error = "路径太短：按住左键拖出一段可走的线"
		return false

	# 路径成本沿实际折线逐段累加；同一地块内的短距离移动也有成本。
	var costs := PackedFloat32Array()
	costs.resize(points.size())
	costs[0] = 0.0
	for i in range(1, points.size()):
		costs[i] = costs[i - 1] + map.segment_move_cost_deci(
			points[i - 1], points[i], point_cells[i - 1], point_cells[i], player
		)

	var entry_distances_new := PackedFloat32Array()
	entry_distances_new.resize(cells.size())
	for i in range(cells.size()):
		entry_distances_new[i] = distances[entry_indices[i]]

	drawn_stroke = points.duplicate()
	move_points = points
	move_point_distances = distances
	move_cost_samples = costs
	path_cells = cells
	entry_move_indices = entry_indices
	entry_distances = entry_distances_new
	path_length = total
	_movement_charged_deci = 0
	last_move_message = ""
	_next_entry_index = 1
	path_changed.emit()
	return true


func clear_drawn_path() -> void:
	if is_moving:
		return
	_clear_path_data()
	last_move_message = ""
	path_changed.emit()


## 当前是否有一条可执行的画线；允许路径完全在当前地块内。
func has_drawn_path() -> bool:
	return move_points.size() >= 2 and path_length >= MIN_PATH_LENGTH


## 测试/结算可用：路径的隐藏 AP 总消耗（UI 不显示）。
func path_cost_deci() -> int:
	if map == null or player == null or not has_drawn_path() or move_cost_samples.is_empty():
		return 0
	return int(round(move_cost_samples[move_cost_samples.size() - 1]))


## 到第 index 个地块入口（path_cells[index]）的隐藏 AP 消耗。
func path_entry_cost_deci(index: int) -> int:
	if entry_distances.is_empty() or index <= 0:
		return 0
	if index >= entry_distances.size():
		return path_cost_deci()
	return int(round(_cost_at_distance(entry_distances[index])))


func execute_move() -> bool:
	if intro_open or state != State.PLAYING or player == null or is_moving or movement_paused:
		return false
	if not has_drawn_path():
		return false
	EventManager.begin_action()
	is_moving = true
	movement_paused = false
	move_distance = 0.0
	_movement_charged_deci = 0
	_next_entry_index = 1
	visual_position = move_points[0]
	last_move_message = ""
	movement_started.emit()
	return true


func advance_movement(delta: float) -> void:
	if not is_moving or movement_paused or state != State.PLAYING:
		return
	var target_distance := minf(path_length, move_distance + MOVE_SPEED * delta)
	while _next_entry_index < path_cells.size():
		var entry_distance := entry_distances[_next_entry_index]
		if target_distance + 0.0001 < entry_distance:
			break
		var from_id := player.cell_id
		var to_id := path_cells[_next_entry_index]
		# 终点封印/守卫退开：在踏入终点格之前拦截，不能依赖 on_cell_entered 返回 false，
		# 否则下一行会自动判定胜利。这里不能先推进到入口距离，否则 visual_position
		# 会落进终点格，而 cell_id 仍停在上一格；下回合从标记起笔时路径会被判为“太短”。
		if to_id == map.goal_id and player != null and not player.goal_passed:
			var goal_block := EventManager.goal_entry_block_reason()
			if not goal_block.is_empty():
				_advance_to_distance(maxf(move_distance, entry_distance - 0.5))
				_stop_movement(goal_block, true)
				return
		if not _advance_to_distance(entry_distance):
			return
		player.cell_id = to_id
		map.mark_cell_entered(to_id)
		refresh_vision()
		_next_entry_index += 1
		player_moved.emit()
		cell_entered.emit(to_id, from_id)
		# AP 已在移动到该入口的过程中按距离连续扣除。
		# 事件在“动画抵达该格”时判定；返回 true 表示事件界面接管，移动暂停。
		# 终点也要先给事件（终点守卫）机会，再由事件效果或默认逻辑结算胜利。
		if EventManager.on_cell_entered(to_id):
			movement_paused = true
			_set_state(State.EVENT)
			return
		if to_id == map.goal_id:
			_finish(true, "你在第 %d 回合抵达终点。" % round_index)
			return
	if target_distance > move_distance + 0.0001:
		if not _advance_to_distance(target_distance):
			return
	if move_distance >= path_length - 0.01:
		_stop_movement("", false)


## 把角色推进到路径上的指定距离，并按实际累计成本扣 AP。
## 返回 false 表示 AP 已在途中耗尽、移动已停止。
func _advance_to_distance(target_distance: float) -> bool:
	if player == null:
		return false
	target_distance = clampf(target_distance, move_distance, path_length)
	var due := int(round(_cost_at_distance(target_distance))) - _movement_charged_deci
	if due > player.ap_deci:
		# AP 只够走到路径上的某一点；精确求出该点，而不是停在格心或入口。
		var affordable_limit := float(_movement_charged_deci + player.ap_deci)
		var affordable_distance := maxf(_distance_for_cost(affordable_limit), move_distance)
		var affordable_cost := int(round(_cost_at_distance(affordable_distance)))
		var charge := clampi(affordable_cost - _movement_charged_deci, 0, player.ap_deci)
		_charge_movement(charge)
		move_distance = affordable_distance
		visual_position = _point_at_distance(move_distance)
		_stop_movement(
			"AP 不足，停在路径上的实际位置（剩余 %.1f AP）" % (player.ap_deci / 10.0),
			false
		)
		return false
	if due > 0:
		_charge_movement(due)
	move_distance = target_distance
	visual_position = _point_at_distance(move_distance)
	return true


func _charge_movement(amount_deci: int) -> void:
	if amount_deci <= 0 or player == null:
		return
	var charged := mini(amount_deci, player.ap_deci)
	if charged <= 0:
		return
	player.ap_deci -= charged
	_movement_charged_deci += charged
	EventManager.on_ap_spent(charged)
	ap_changed.emit(player.ap_deci)


## 路径上某个累计距离对应的隐藏 AP 成本（deci，浮点）。
func _cost_at_distance(distance: float) -> float:
	if move_points.size() < 2 or move_cost_samples.size() != move_points.size() \
			or move_point_distances.size() != move_points.size():
		return 0.0
	var remaining := clampf(distance, 0.0, path_length)
	for i in range(1, move_points.size()):
		var segment_end := move_point_distances[i]
		if remaining > segment_end and i < move_points.size() - 1:
			continue
		var segment_start := move_point_distances[i - 1]
		var segment_length := segment_end - segment_start
		if segment_length <= 0.0001:
			return move_cost_samples[i]
		var t := clampf((remaining - segment_start) / segment_length, 0.0, 1.0)
		return lerpf(move_cost_samples[i - 1], move_cost_samples[i], t)
	return move_cost_samples[move_cost_samples.size() - 1]


## 反推“花掉 cost_deci 时最远能走到路径的哪里”，用于 AP 耗尽落点。
func _distance_for_cost(cost_deci: float) -> float:
	if move_points.size() < 2 or move_cost_samples.size() != move_points.size() \
			or move_point_distances.size() != move_points.size():
		return 0.0
	if cost_deci <= 0.0:
		return 0.0
	var total_cost := move_cost_samples[move_cost_samples.size() - 1]
	if cost_deci >= total_cost:
		return path_length
	for i in range(1, move_cost_samples.size()):
		if move_cost_samples[i] < cost_deci:
			continue
		var cost_start := move_cost_samples[i - 1]
		var cost_span := move_cost_samples[i] - cost_start
		var distance_start := move_point_distances[i - 1]
		var distance_span := move_point_distances[i] - distance_start
		if cost_span <= 0.0001:
			return move_point_distances[i]
		var t := clampf((cost_deci - cost_start) / cost_span, 0.0, 1.0)
		return distance_start + distance_span * t
	return path_length


func resume_movement() -> void:
	if not movement_paused:
		return
	movement_paused = false
	_set_state(State.PLAYING)


## 事件面板点击「继续」后由 EventManager 发出信号。
func _on_event_finished(_event_id: String) -> void:
	var outcome := EventManager.take_pending_outcome()
	if bool(outcome.get("death", false)):
		var reason := String(outcome.get("death_reason", "你在事件中倒下。"))
		_finish(false, reason)
		return
	if bool(outcome.get("goal", false)):
		_finish(true, "你在第 %d 回合通过终点守卫，抵达终点。" % round_index)
		return
	if player != null and player.status_blocks_movement():
		is_moving = false
		EventManager.end_action()
		_clear_path_data()
		last_move_message = "你被困住了，本回合无法继续移动。"
		player_moved.emit()
		path_changed.emit()
		movement_finished.emit(last_move_message)
	resume_movement()
	autosave()


## 守卫失败/击退：沿远离终点的方向退 steps 格，并清空剩余路径。
func apply_event_knockback(steps: int) -> void:
	if map == null or player == null or steps <= 0:
		return
	var current := player.cell_id
	var previous := -1
	var moved := 0
	for _step in range(steps):
		var best := -1
		var best_distance := -1
		for neighbor in map.get_cell(current).neighbors:
			if neighbor == previous:
				continue
			var distance := map.graph_distance(neighbor, map.goal_id)
			if distance > best_distance:
				best_distance = distance
				best = neighbor
		if best < 0:
			break
		previous = current
		current = best
		moved += 1
	if moved <= 0:
		return
	player.cell_id = current
	map.mark_cell_entered(current)
	refresh_vision()
	visual_position = map.cell_center(current)
	is_moving = false
	_clear_path_data()
	EventManager.sync_player_cell(current)
	player_moved.emit()
	path_changed.emit()
	movement_finished.emit("被击退 %d 格" % moved)


func finish_victory(reason: String) -> void:
	_finish(true, reason)


func finish_death(reason: String) -> void:
	_finish(false, reason)


func get_goal_distance() -> int:
	if map == null or player == null:
		return 0
	return map.graph_distance(player.cell_id, map.goal_id)


## 结算页的本局回顾：把探索、事件、物资与同伴关系汇总成可读的正反馈。
func build_run_summary_text(win: bool = false) -> String:
	if player == null:
		return ""
	var lines: Array[String] = []
	lines.append("本局回顾 · 第 %d 回合" % round_index)
	lines.append("探索 %d/%d 处地点 · 遭遇 %d 次事件" % [
		EventManager.get_visited_poi_count(),
		EventManager.get_total_poi_count(),
		EventManager.get_events_this_run(),
	])
	lines.append("金币 %d · 行囊 %d 件 · 装备：%s" % [
		player.gold, player.inventory.size(), player.equipment_text(),
	])
	if companion != null:
		var relation := companion_relation_text() if companion.alive else "已经倒下"
		lines.append("同伴：%s · %s" % [companion_name(), relation])
		var stolen_name := companion.stolen_item_name() if companion.alive else ""
		if not stolen_name.is_empty():
			lines.append("失物：「%s」仍在%s身上。可在背包页追查，或击败她取回。" % [
				stolen_name, companion_name(),
			])
	if win:
		lines.append("抵达终点：%s" % ("完美胜利" if player_victory_tier == "perfect" else "基础胜利"))
	else:
		lines.append("距终点：约 %d 格" % get_goal_distance())
	return "\n".join(lines)


## ---------------- 迷雾与侦察 ----------------

## 基础视野的世界半径：按地块数量等效格径的 2 倍，保证每次开局覆盖规模接近。
func _base_vision_radius_world() -> float:
	if map == null:
		return 0.0
	return map.average_cell_size * BASE_SIGHT_RADIUS


## 当前目标视野半径（世界像素）。侦察成功后额外扩张，回合结束后逐步收束。
func vision_radius_world() -> float:
	if map == null:
		return 0.0
	return _base_vision_radius_world() + vision_boost_cells * map.average_site_spacing


func vision_boost_active() -> bool:
	return vision_boost_cells > 0.01


## 按玩家当前位置重建圆形视野。只有格心落在圆内的格子进入 current_vision，
## 并永久记为 seen；边缘被圆切到的格子由渲染层局部揭示，不获得整格记忆。
func refresh_vision() -> void:
	if map == null or player == null:
		return
	map.current_vision.clear()
	var start := player.cell_id
	if map.get_cell(start) == null:
		return
	var center := map.cell_center(start)
	var radius := vision_radius_world()
	map.vision_center = center
	map.vision_radius_world = radius
	for cell in map.cells:
		if cell.center.distance_to(center) <= radius:
			map.current_vision[cell.id] = true
			cell.seen = true
			# 地标进入视野即可辨认，玩家才能在附近主动绕行或避开 POI。
			if not cell.poi_id.is_empty():
				cell.poi_known = true
	fog_changed.emit()


## 以 center_id 为中心、按世界半径揭示地块中心。主动侦察会把格子标为 scouted，
## 使扩张视野收束后仍保留“曾获得信息”的暗色地形。
## 回合结束结算侦察视野：先保持 2 回合，再每回合收缩 0.5 格，直到回到基础视野。
func _tick_vision_boost() -> void:
	if vision_boost_cells <= 0.01:
		vision_boost_cells = 0.0
		vision_boost_hold_rounds = 0
		return
	if vision_boost_hold_rounds > 0:
		vision_boost_hold_rounds -= 1
		return
	vision_boost_cells = maxf(0.0, vision_boost_cells - VISION_BOOST_DECAY_PER_ROUND)
	refresh_vision()


func reveal_area(center_id: int, radius_world: float, mark_scouted: bool = true) -> Array[int]:
	var revealed: Array[int] = []
	if map == null or map.get_cell(center_id) == null:
		return revealed
	var center := map.cell_center(center_id)
	for cell in map.cells:
		if cell.center.distance_to(center) > radius_world:
			continue
		cell.seen = true
		if mark_scouted:
			cell.scouted = true
		revealed.append(cell.id)
	return revealed


func reveal_poi(cell_id: int) -> void:
	if map != null:
		map.mark_poi_known(cell_id)


func is_poi_known(cell_id: int) -> bool:
	return map != null and map.is_poi_known(cell_id)


func is_position_exposed() -> bool:
	return position_exposed_until_round > 0 and round_index <= position_exposed_until_round


## 侦察 DC、地形修正与高低处修正。高危/恐高口径见 docs/实现决策记录.md D-54。
func scout_dc_info(cell_id: int = -1, actor = null) -> Dictionary:
	var source = actor if actor != null else player
	if source == null or map == null:
		return {
			"dc": 10, "terrain": "", "terrain_name": "", "terrain_mod": 0,
			"elevation": 0, "height_mod": 0, "height_label": "平地",
		}
	var target_id: int = cell_id if cell_id >= 0 else source.cell_id
	var cell := map.get_cell(target_id)
	if cell == null:
		return {
			"dc": 10, "terrain": "", "terrain_name": "", "terrain_mod": 0,
			"elevation": 0, "height_mod": 0, "height_label": "平地",
		}
	var terrain_record := DataManager.get_record("terrains", cell.terrain)
	var terrain_mod := int(terrain_record.get("scout_dc_mod", 0))
	var height_mod := 0
	var height_label := "平地"
	if cell.elevation >= HIGH_ELEVATION:
		height_mod = -2
		height_label = "高处"
		if source.has_trait("acrophobia"):
			height_mod = 0
			height_label = "高处（恐高无加成）"
	elif cell.elevation <= LOW_ELEVATION:
		height_mod = 2
		height_label = "低处"
	return {
		"dc": 10 + terrain_mod + height_mod,
		"terrain": cell.terrain,
		"terrain_name": String(terrain_record.get("name", cell.terrain)),
		"terrain_mod": terrain_mod,
		"elevation": cell.elevation,
		"height_mod": height_mod,
		"height_label": height_label,
	}


## 侦察 DC 的来源说明：10 + 地形修正 + 高差修正。
func _scout_dc_formula_text(info: Dictionary) -> String:
	var text := "DC %d（10（基础）" % int(info.get("dc", 10))
	var terrain_mod := int(info.get("terrain_mod", 0))
	if terrain_mod != 0:
		text += " %s %d（%s）" % [
			"+" if terrain_mod > 0 else "-", absi(terrain_mod),
			String(info.get("terrain_name", "地形")),
		]
	var height_mod := int(info.get("height_mod", 0))
	if height_mod != 0:
		text += " %s %d（%s）" % [
			"+" if height_mod > 0 else "-", absi(height_mod),
			String(info.get("height_label", "地势")),
		]
	return text + "）"


## 侦察行动：消耗 2 AP，2d6 + 感知 + 装备/状态 vs DC。
## 成功揭示半径 感知/2+1；大成功再 +1 并揭示最近 POI；大失败暴露位置 1 回合。
func scout() -> Dictionary:
	if state != State.PLAYING or player == null or map == null or is_moving or movement_paused:
		return _scout_error("现在无法侦察。")
	if player.ap_deci < SCOUT_AP_COST_DECI:
		return _scout_error("AP 不足，侦察需要 2 AP。")

	var dc_info := scout_dc_info()
	var dc := int(dc_info["dc"])
	var dice := RNGManager.roll_2d6("scout")
	var natural := int(dice[0]) + int(dice[1])
	var breakdown := player.check_breakdown("perception")
	var total := natural + int(breakdown["base"]) + int(breakdown["equipment"]) + int(breakdown["status"])
	var formula := player.check_formula_text("perception", natural, "感知")
	var dc_text := _scout_dc_formula_text(dc_info)
	var level := "fail"
	var level_name := "失败"
	if natural == 12 or total >= dc + 5:
		level = "great_success"
		level_name = "大成功"
	elif natural == 2 or total <= dc - 5:
		level = "great_fail"
		level_name = "大失败"
	elif total >= dc:
		level = "success"
		level_name = "成功"
	var detail := "%s = %d vs %s · %s" % [formula, total, dc_text, level_name]

	player.ap_deci = maxi(0, player.ap_deci - SCOUT_AP_COST_DECI)
	var messages: Array[String] = []
	var revealed: Array[int] = []
	var radius := 0
	var vision_radius := 0.0
	var poi_cell := -1
	var ai_level := EventManager.get_reveal_level()

	if level == "success" or level == "great_success":
		radius = player.scout_reveal_radius()
		if level == "great_success":
			radius += 1
		vision_boost_cells = maxf(vision_boost_cells, float(radius))
		vision_boost_hold_rounds = SCOUT_VISION_HOLD_ROUNDS
		vision_radius = vision_radius_world()
		revealed = reveal_area(player.cell_id, vision_radius, true)
		refresh_vision()
		ai_level = EventManager.grant_ai_reveal(1)
		messages.append("侦察成功：视野向外扩张 %d 格，保持 %d 回合。" % [radius, SCOUT_VISION_HOLD_ROUNDS])
		if level == "great_success":
			poi_cell = EventManager.reveal_nearest_poi_for_scout()
			if poi_cell >= 0:
				messages.append("大成功：额外定位最近 POI（地块 %d）。" % (poi_cell + 1))
			else:
				messages.append("大成功：附近已没有未探索的 POI。")
	elif level == "great_fail":
		position_exposed_until_round = round_index + 1
		messages.append("大失败：你的位置暴露给所有 AI，持续 1 回合。")
	else:
		messages.append("侦察失败：没有揭示新区域。")

	var report := {
		"ok": true,
		"message": "；".join(messages),
		"dice": [int(dice[0]), int(dice[1])],
		"natural": natural,
		"base": int(breakdown["base"]),
		"equipment": int(breakdown["equipment"]),
		"status": int(breakdown["status"]),
		"equipment_parts": breakdown.get("equipment_parts", []),
		"status_parts": breakdown.get("status_parts", []),
		"formula": formula,
		"total": total,
		"dc": dc,
		"dc_detail": dc_info,
		"dc_text": dc_text,
		"level": level,
		"level_name": level_name,
		"radius": radius,
		"vision_radius": vision_radius,
		"vision_boost_cells": vision_boost_cells,
		"vision_hold_rounds": vision_boost_hold_rounds,
		"cells_revealed": revealed.size(),
		"poi_cell": poi_cell,
		"ai_reveal_level": ai_level,
		"exposed": level == "great_fail",
		"ap_deci": player.ap_deci,
	}
	last_scout_report = report
	last_scout_message = String(report["message"])
	dice_rolled.emit({
		"title": "侦察检定",
		"kind": "scout",
		"kind_label": "侦察 · 2 AP",
		"dice": [int(dice[0]), int(dice[1])],
		"sides": 6,
		"modifier": int(breakdown["base"]) + int(breakdown["equipment"]) + int(breakdown["status"]),
		"total": total,
		"dc": dc,
		"level_name": level_name,
		"detail": detail,
	})
	fog_changed.emit()
	scout_finished.emit(report)
	player_moved.emit()
	autosave()
	return report


func _scout_error(message: String) -> Dictionary:
	var report := {
		"ok": false,
		"message": message,
		"level": "",
		"level_name": "",
		"ap_deci": player.ap_deci if player != null else 0,
	}
	last_scout_report = report
	last_scout_message = message
	scout_finished.emit(report)
	if player != null:
		player_moved.emit()
	return report


func get_visual_position() -> Vector2:
	return visual_position


func _stop_movement(reason: String, snap_to_cell_center: bool) -> void:
	is_moving = false
	movement_paused = false
	EventManager.end_action()
	if snap_to_cell_center and player != null:
		visual_position = map.cell_center(player.cell_id)
	last_move_message = reason
	_clear_path_data()
	player_moved.emit()
	path_changed.emit()
	movement_finished.emit(reason)
	autosave()


func _clear_path_data() -> void:
	drawn_stroke = PackedVector2Array()
	path_cells.clear()
	entry_move_indices.clear()
	entry_distances = PackedFloat32Array()
	move_points = PackedVector2Array()
	move_point_distances = PackedFloat32Array()
	move_cost_samples = PackedFloat32Array()
	path_length = 0.0
	move_distance = 0.0
	_movement_charged_deci = 0
	_next_entry_index = 1


func _point_at_distance(distance: float) -> Vector2:
	if move_points.is_empty():
		return visual_position
	if move_points.size() == 1:
		return move_points[0]
	var remaining := maxf(0.0, distance)
	for i in range(1, move_points.size()):
		var segment := move_points[i - 1].distance_to(move_points[i])
		if segment <= 0.0001:
			continue
		if remaining <= segment:
			return move_points[i - 1].lerp(move_points[i], remaining / segment)
		remaining -= segment
	return move_points[move_points.size() - 1]


func _densify_stroke(stroke: PackedVector2Array, step: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if stroke.is_empty():
		return result
	result.append(stroke[0])
	var previous := stroke[0]
	for i in range(1, stroke.size()):
		var current := stroke[i]
		var segment := previous.distance_to(current)
		var steps := maxi(1, int(ceil(segment / step)))
		for s in range(1, steps + 1):
			result.append(previous.lerp(current, float(s) / float(steps)))
		previous = current
	return result


## 每局形状种子：与生态种子分开。randomize_seed 为 true 的地图每次开局重新掷。
func _roll_map_seed() -> int:
	_seed_sequence += 1
	var value := int(Time.get_ticks_usec()) ^ int(Time.get_unix_time_from_system() * 9973.0) ^ (_seed_sequence * 2654435761) ^ randi()
	return absi(value) % 2147483646 + 1


## 每局生态种子：不改变地块形状，只改变地形/生态分布。
func _roll_terrain_seed() -> int:
	var value := int(Time.get_ticks_usec()) ^ randi() ^ int(Time.get_unix_time_from_system() * 1000.0)
	return absi(value) % 2147483647 + 1


func _pick_ai_id(player_id: String, roster: Array[String]) -> String:
	var candidates: Array[String] = []
	for id in roster:
		if id != player_id:
			candidates.append(id)
	if candidates.is_empty():
		return ""
	var rng := RNGManager.get_stream("setup")
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## 只给 AI 角色抽任务；玩家角色在 MVP 不分配隐藏任务。
func _pick_hidden_task_id(character_id: String, stream_name: String) -> String:
	var candidates := mvp_hidden_task_ids(character_id)
	if candidates.is_empty():
		return ""
	var rng := RNGManager.get_stream(stream_name)
	return candidates[rng.randi_range(0, candidates.size() - 1)]


## ---------------- 存档与读档 ----------------

## 只有行动彻底结束后才允许自动存档，避免把半条路径、事件面板或战斗选择写进存档。
func can_save_game() -> bool:
	if state != State.PLAYING or map == null or player == null:
		return false
	if intro_open or is_moving or movement_paused:
		return false
	if EventManager.is_event_active():
		return false
	if not _combat_stage.is_empty() or not combat_payload.is_empty():
		return false
	return true


func autosave() -> bool:
	if not can_save_game():
		return false
	return SaveManager.save_game(SaveManager.DEFAULT_SLOT)


## 生成可 JSON 化的完整本局快照。地图只存配置与实际种子，读档时重建。
func build_save_data() -> Dictionary:
	if not can_save_game():
		return {}
	var fog := {
		"seen": [],
		"scouted": [],
		"entered": [],
		"poi_known": [],
	}
	for cell in map.cells:
		if cell.seen:
			fog["seen"].append(cell.id)
		if cell.scouted:
			fog["scouted"].append(cell.id)
		if cell.entered:
			fog["entered"].append(cell.id)
		if cell.poi_known:
			fog["poi_known"].append(cell.id)
	var meta := {
		"map_id": map.map_id,
		"map_name": map.map_name,
		"seed": map.seed_value,
		"player_character_id": player_character_id,
		"player_name": player.display_name,
		"role": player.role,
		"round": round_index,
		"round_max": MAX_ROUNDS,
		"hp": player.hp,
		"hp_max": player.hp_max,
		"gold": player.gold,
		"goal_distance": get_goal_distance(),
		"companion_name": companion_name(),
	}
	return {
		"meta": meta,
		"map": {
			"config": map.config.duplicate(true),
			"generated_seed": map.generated_seed,
			"terrain_seed": map.terrain_seed,
			"seed_value": map.seed_value,
			"fog": fog,
		},
		"player": player.to_dict(),
		"companion": companion.to_dict() if companion != null else {},
		"events": EventManager.to_save_data(),
		"rng": RNGManager.snapshot_state(),
		"game": {
			"round_index": round_index,
			"player_character_id": player_character_id,
			"ai_character_id": ai_character_id,
			"player_hidden_task_candidate_ids": player_hidden_task_candidate_ids.duplicate(),
			"ai_hidden_task_id": ai_hidden_task_id,
			"companion_start_cell_id": companion_start_cell_id,
			"world_log": world_log.duplicate(),
			"goal_arrivals": goal_arrivals.duplicate(true),
			"first_goal_round": first_goal_round,
			"player_goal_round": player_goal_round,
			"player_victory_tier": player_victory_tier,
			"selected_map_config": selected_map_config.duplicate(true),
			"visual_position": [visual_position.x, visual_position.y],
			"last_move_message": last_move_message,
			"last_scout_report": last_scout_report.duplicate(true),
			"last_scout_message": last_scout_message,
			"position_exposed_until_round": position_exposed_until_round,
			"vision_boost_cells": vision_boost_cells,
			"vision_boost_hold_rounds": vision_boost_hold_rounds,
			"pending_item_overflows": pending_item_overflows.duplicate(true),
		},
	}


## 读档：先用存档中的实际种子重建地图，再恢复角色、事件、迷雾与随机流。
## 任何关键字段缺失都返回错误，不修改当前运行中的游戏。
func restore_save_data(data: Dictionary) -> Dictionary:
	var map_data = data.get("map", {})
	var game_data = data.get("game", {})
	var player_data = data.get("player", {})
	if not (map_data is Dictionary) or not (game_data is Dictionary) or not (player_data is Dictionary):
		return _restore_error("存档缺少地图、游戏或玩家数据。")
	var config = (map_data as Dictionary).get("config", {})
	if not (config is Dictionary) or (config as Dictionary).is_empty():
		return _restore_error("存档缺少地图配置。")
	var generated_seed := int((map_data as Dictionary).get("generated_seed", 0))
	var terrain_seed := int((map_data as Dictionary).get("terrain_seed", 0))
	if generated_seed == 0 or terrain_seed == 0:
		return _restore_error("存档缺少地图生成种子。")
	var loaded_map := MapGenerator.generate_exact(config, generated_seed, terrain_seed)
	if loaded_map == null or loaded_map.cells.is_empty():
		return _restore_error("无法按存档种子重建地图。")
	loaded_map.seed_value = int((map_data as Dictionary).get("seed_value", loaded_map.seed_value))

	var loaded_player := ActorState.from_dict(player_data)
	if loaded_player.character_id.is_empty() or loaded_map.get_cell(loaded_player.cell_id) == null:
		return _restore_error("存档中的玩家位置无效。")

	var companion_data = data.get("companion", {})
	if not (companion_data is Dictionary):
		return _restore_error("存档中的同伴数据无效。")
	var has_companion := not (companion_data as Dictionary).is_empty()
	if has_companion:
		var companion_actor = (companion_data as Dictionary).get("actor", {})
		if not (companion_actor is Dictionary) or (companion_actor as Dictionary).is_empty():
			return _restore_error("存档中的同伴角色数据无效。")

	var rng_data = data.get("rng", {})
	if not (rng_data is Dictionary) or (rng_data as Dictionary).is_empty():
		return _restore_error("存档缺少随机状态。")
	var events_data = data.get("events", {})
	if not (events_data is Dictionary):
		return _restore_error("存档中的事件状态无效。")
	if not EventManager.load_save_data(loaded_map, events_data):
		return _restore_error("事件状态无法恢复。")
	if not RNGManager.restore_state(rng_data):
		return _restore_error("随机状态无法恢复。")

	var loaded_companion: CompanionAI = null
	if has_companion:
		loaded_companion = CompanionAI.new()
		if not loaded_companion.load_dict(companion_data):
			return _restore_error("同伴状态无法恢复。")
		if loaded_map.get_cell(loaded_companion.actor.cell_id) == null:
			return _restore_error("存档中的同伴位置无效。")

	map = loaded_map
	player = loaded_player
	companion = loaded_companion
	selected_map_config = config.duplicate(true)
	round_index = maxi(1, int((game_data as Dictionary).get("round_index", 1)))
	player_character_id = String((game_data as Dictionary).get("player_character_id", player.character_id))
	ai_character_id = String((game_data as Dictionary).get("ai_character_id", ""))
	player_hidden_task_candidate_ids.clear()
	for task_id in (game_data as Dictionary).get("player_hidden_task_candidate_ids", []):
		player_hidden_task_candidate_ids.append(String(task_id))
	ai_hidden_task_id = String((game_data as Dictionary).get("ai_hidden_task_id", ""))
	companion_start_cell_id = int((game_data as Dictionary).get("companion_start_cell_id", -1))
	world_log.clear()
	for line in (game_data as Dictionary).get("world_log", []):
		world_log.append(String(line))
	while world_log.size() > WORLD_LOG_LIMIT:
		world_log.pop_front()
	goal_arrivals.clear()
	for entry in (game_data as Dictionary).get("goal_arrivals", []):
		if not (entry is Dictionary):
			continue
		var raw: Dictionary = entry
		goal_arrivals.append({
			"actor": String(raw.get("actor", "")),
			"name": String(raw.get("name", "")),
			"round": int(raw.get("round", 0)),
			"faction_at_arrival": String(raw.get("faction_at_arrival", "")),
			"rewarded": bool(raw.get("rewarded", false)),
		})
	first_goal_round = int((game_data as Dictionary).get("first_goal_round", 0))
	player_goal_round = int((game_data as Dictionary).get("player_goal_round", 0))
	player_victory_tier = String((game_data as Dictionary).get("player_victory_tier", ""))
	last_move_message = String((game_data as Dictionary).get("last_move_message", ""))
	last_scout_message = String((game_data as Dictionary).get("last_scout_message", ""))
	var scout_report = (game_data as Dictionary).get("last_scout_report", {})
	last_scout_report = scout_report.duplicate(true) if scout_report is Dictionary else {}
	position_exposed_until_round = int((game_data as Dictionary).get("position_exposed_until_round", 0))
	vision_boost_cells = maxf(0.0, float((game_data as Dictionary).get("vision_boost_cells", 0.0)))
	vision_boost_hold_rounds = maxi(0, int((game_data as Dictionary).get("vision_boost_hold_rounds", 0)))
	pending_item_overflows.clear()
	for raw_overflow in (game_data as Dictionary).get("pending_item_overflows", []):
		if not (raw_overflow is Dictionary):
			continue
		var overflow_entry: Dictionary = raw_overflow
		var overflow_item_id := String(overflow_entry.get("item_id", ""))
		if overflow_item_id.is_empty() or not DataManager.has_record("items", overflow_item_id):
			continue
		pending_item_overflows.append({
			"item_id": overflow_item_id,
			"count": maxi(1, int(overflow_entry.get("count", 1))),
			"source": String(overflow_entry.get("source", "")),
		})
	var saved_position = (game_data as Dictionary).get("visual_position", [])
	if saved_position is Array and (saved_position as Array).size() >= 2:
		visual_position = Vector2(float(saved_position[0]), float(saved_position[1]))
	else:
		visual_position = map.cell_center(player.cell_id)

	# 迷雾明细在重建地图上逐格恢复；先按当前位置重建 current_vision，
# 再精确覆盖存档时的 seen/scouted/entered/poi_known，避免视野边界浮点差改变存档。
	_restore_runtime_clean_state()
	intro_open = false
	intro_story = {}
	pending_intro_dice.clear()
	_seed_sequence = 0
	vision_center_display = visual_position
	vision_radius_display = vision_radius_world()
	refresh_vision()
	var fog = (map_data as Dictionary).get("fog", {})
	if fog is Dictionary:
		_restore_fog(fog)
	map.vision_center = vision_center_display
	map.vision_radius_world = vision_radius_display
	fog_changed.emit()
	_set_state(State.PLAYING)
	ap_changed.emit(player.ap_deci)
	turn_started.emit()
	companion_changed.emit()
	world_log_changed.emit()
	player_moved.emit()
	path_changed.emit()
	return {"ok": true, "meta": data.get("meta", {}).duplicate(true)}


func _restore_error(message: String) -> Dictionary:
	return {"ok": false, "error": message}


func _restore_fog(fog: Dictionary) -> void:
	for cell in map.cells:
		cell.seen = false
		cell.scouted = false
		cell.entered = false
		cell.poi_known = false
	for cell_id in fog.get("seen", []):
		var cell := map.get_cell(int(cell_id))
		if cell != null:
			cell.seen = true
	for cell_id in fog.get("scouted", []):
		var cell := map.get_cell(int(cell_id))
		if cell != null:
			cell.scouted = true
	for cell_id in fog.get("entered", []):
		var cell := map.get_cell(int(cell_id))
		if cell != null:
			cell.entered = true
	for cell_id in fog.get("poi_known", []):
		var cell := map.get_cell(int(cell_id))
		if cell != null:
			cell.poi_known = true


func _restore_runtime_clean_state() -> void:
	_clear_path_data()
	is_moving = false
	movement_paused = false
	combat_payload.clear()
	_combat_stage = ""
	_combat_context.clear()
	_pending_end_turn_after_combat = false
	_goal_victory_resolved = false
	last_path_error = ""


func _finish(win: bool, reason: String) -> void:
	if state == State.GAME_OVER:
		return
	is_moving = false
	movement_paused = false
	EventManager.end_action()
	_clear_path_data()
	var final_win := win
	var final_reason := reason
	if companion != null and companion.alive and player != null:
		if win:
			# 到达终点的瞬间先判观察型与互斥型任务；敌方薇拉在窗口内可把胜利改判为失败。
			var goal_result: Dictionary = companion.accept_player_goal(player, player.has_status("trapped"))
			if bool(goal_result.get("completed", false)):
				_log_companion_task_completion()
			if bool(goal_result.get("player_defeated", false)):
				final_win = false
				final_reason = String(goal_result.get("defeat_reason", "%s完成了她的互斥目标。" % companion_name()))
		else:
			var at_goal := map != null and player.cell_id == map.goal_id
			var end_result: Dictionary = companion.accept_run_end(player, at_goal)
			if bool(end_result.get("completed", false)):
				_log_companion_task_completion()
				var summary := String(end_result.get("summary", "")).strip_edges()
				if not summary.is_empty():
					final_reason += " " + summary
	if final_win:
		final_reason = _finalize_victory(final_reason)
	if not final_win and companion != null and companion.reached_goal:
		final_reason += " 同伴已经抵达终点。"
	# 单槽自动存档代表“还能继续的这一局”；死亡或胜利后不再提供继续入口。
	SaveManager.clear_save(SaveManager.DEFAULT_SLOT)
	_set_state(State.GAME_OVER)
	game_over.emit(final_win, final_reason)


func _log_companion_task_completion() -> void:
	if companion == null:
		return
	var task := companion.task
	if EventManager.get_reveal_level() >= 3 and not task.is_empty():
		_add_world_log("%s完成了她的计划：%s。" % [companion_name(), String(task.get("name", ""))])
	else:
		_add_world_log("%s了结了一桩心事。" % companion_name())


func _set_state(new_state: int) -> void:
	state = new_state
	state_changed.emit(state)
