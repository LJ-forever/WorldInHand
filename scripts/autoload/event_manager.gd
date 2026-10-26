extends Node
## 事件系统：触发检测、优先级队列、冷却、2d6 检定与效果结算。
## 规则来自设计文档 §7 / §8，并按地块放大后的节奏调整：
## - goal(4) > poi(3) > enter_region(2) > wander(1)；
## - 每次移动行动最多结算 2 个事件，事件之间至少间隔 3 AP；
## - 同一行动内每种触发源最多 1 次，每回合最多 3 个随机事件；
## - 队列最多 2 个，溢出时丢弃最低优先级；每个事件冷却 2 回合；
## - POI 首次进入必触发；区域首次进入 60%；wander 13%/3 AP + 每回合 24% 环境判定；
## - 单局随机事件上限 29（终点守卫预留 1 个名额），达到后忽略新的随机触发；
## - 最近出现过的事件在还有替代项时降低优先级（防重复池）；
## - 效果按 D-17 分阶段结算，AP 不足转 HP，死亡后终止后续结算。
##
## 事件以玩家为主；同伴仅在相邻时承受 `ai_effects`，`ai_favor` 全局生效。

signal event_queued(event_id: String)
signal event_started(event_data: Dictionary)
signal event_progress(result: Dictionary)
signal event_finished(event_id: String)
signal dice_rolled(payload: Dictionary)
signal log_added(text: String)

const PRIORITY := {"goal": 4, "poi": 3, "enter_region": 2, "wander": 1}
const MAX_QUEUE := 2
const MAX_EVENTS_PER_ACTION := 2
const MIN_EVENT_AP_SPACING_DECI := 30
const MAX_RANDOM_EVENTS_PER_ROUND := 3
## 单局随机事件上限。20～30 是设计目标；高速角色在 40 回合内可覆盖整张图，
## 不设上限时会刷到 35～46 个。预留 1 个名额给终点守卫，含终点事件时仍不超过 30。
const MAX_RANDOM_EVENTS_PER_RUN := 29
const RECENT_EVENT_MEMORY := 3
const POI_TRIGGER_CHANCE := 1.0
## 首次进入地形连通区域时的触发概率。设计目标是单局 20～30 个事件；
## 若区域全量触发，40 回合的自动探索会在区域事件上单独堆到 19 个，
## 把 POI/wander 的份额挤掉。60% 让区域事件保持存在感，又不独占预算。
const REGION_TRIGGER_CHANCE := 0.60
const WANDER_AP_STEP_DECI := 30
## 每 3 AP 的游荡判定概率。原 20% 在“从标记位置直接画线”的实际移动下
## 约每 7 AP 就产生一个事件，单局可达 40+；13% 把总事件密度压回 20～30。
const WANDER_CHANCE := 0.13
## 每回合开始时的环境事件判定（归入 wander）。低速角色掷出的 AP 少，
## 若只按 AP 判定，速度 2 的角色单局只有 13 个事件，速度 5 的却有 23 个；
## 24% 的回合判定把时间流逝本身也算作遭遇来源，让 20～30 的目标覆盖全角色。
const AMBIENT_CHANCE := 0.24
## POI 首次踏足的保底发现奖励：补给 45% / 金币 35% / 药水 20%。
## 用独立的 exploration 随机流，避免改变事件触发与检定序列。
const POI_REWARD_SUPPLY_CHANCE := 0.45
const POI_REWARD_GOLD_CHANCE := 0.80
const POI_REWARD_GOLD_MIN := 5
const POI_REWARD_GOLD_MAX := 9
const ATTR_NAMES := {
	"speed": "速度",
	"stamina": "体力",
	"perception": "感知",
	"luck": "幸运",
	"combat": "战斗",
	"negotiation": "交涉",
}
## 4X 式情境权重：同样的地形，在负伤、通缉、临近日落或同伴在侧时应有不同的事件倾向。
const BENEFICIAL_EVENTS := ["old_well", "abandoned_camp", "herb_patch", "wanderer", "caravan", "pilgrim"]
const DANGEROUS_EVENTS := ["bandit_ambush", "wildfire", "sandstorm", "cliff", "fallen_tree", "mirage"]
const SOCIAL_EVENTS := ["wanderer", "pilgrim", "caravan"]
const INFO_EVENTS := ["lost", "ancient_stele", "cliff"]

var pending_events: Array[Dictionary] = []
var active_event_id: String = ""
var active_event: Dictionary = {}
## 当前事件的触发来源（goal/poi/enter_region/wander）；供 UI 调试与平衡统计读取。
var active_trigger: String = ""

var _cooldowns: Dictionary = {}
var _events_this_round: int = 0
var _random_events_this_round: int = 0
var _random_events_this_run: int = 0
var _events_this_action: int = 0
var _action_ap_deci: int = 0
var _last_event_action_deci: int = -1000000
var _action_trigger_types: Dictionary = {}
var _action_active: bool = false
var _recent_event_ids: Array[String] = []
var _wander_ap_accum: int = 0
var _visited_pois: Dictionary = {}
var _visited_regions: Dictionary = {}
var _revealed_pois: Dictionary = {}
var _previous_terrain: String = ""
var _region_ids: PackedInt32Array = PackedInt32Array()
var _region_count: int = 0
var _choice_used: Dictionary = {}
var _pending: Dictionary = {}
var _reveal_level: int = 0
var _goal_attempts: int = 0
var _goal_counted: bool = false
var _pending_goal_victory: bool = false
var _pending_death: bool = false
var _pending_death_reason: String = ""
var _event_log: Array[String] = []
## 调试/测试开关：关闭后只保留终点守卫，便于单独验证移动与 AP。
var random_events_enabled: bool = true


## 新开一局时调用；清空所有本局状态并建立区域划分。
func begin_run(map: MapData, player: ActorState) -> void:
	reset_state()
	if map == null or player == null:
		return
	_build_regions(map)
	_previous_terrain = map.terrain_of(player.cell_id)
	var region := _region_of(player.cell_id)
	if region >= 0:
		_visited_regions[region] = true


func reset_state() -> void:
	pending_events.clear()
	active_event_id = ""
	active_event = {}
	active_trigger = ""
	_cooldowns.clear()
	_events_this_round = 0
	_random_events_this_round = 0
	_random_events_this_run = 0
	_events_this_action = 0
	_action_ap_deci = 0
	_last_event_action_deci = -1000000
	_action_trigger_types.clear()
	_action_active = false
	_recent_event_ids.clear()
	_wander_ap_accum = 0
	_visited_pois.clear()
	_visited_regions.clear()
	_revealed_pois.clear()
	_previous_terrain = ""
	_region_ids = PackedInt32Array()
	_region_count = 0
	_choice_used.clear()
	_pending.clear()
	_reveal_level = 0
	_goal_attempts = 0
	_goal_counted = false
	_pending_goal_victory = false
	_pending_death = false
	_pending_death_reason = ""
	_event_log.clear()
	random_events_enabled = true


## 存档用：只保存跨回合仍会影响事件池的运行时状态。
## 事件界面不会在存档点打开，因此 active_event / 交易菜单等瞬时状态不写入。
func to_save_data() -> Dictionary:
	var pending: Array[Dictionary] = []
	for entry in pending_events:
		pending.append(entry.duplicate(true))
	var visited_regions := {}
	for region in _visited_regions.keys():
		visited_regions[str(int(region))] = true
	var revealed_pois := {}
	for cell_id in _revealed_pois.keys():
		revealed_pois[str(int(cell_id))] = true
	return {
		"pending_events": pending,
		"cooldowns": _cooldowns.duplicate(true),
		"events_this_round": _events_this_round,
		"random_events_this_round": _random_events_this_round,
		"random_events_this_run": _random_events_this_run,
		"events_this_action": _events_this_action,
		"action_ap_deci": _action_ap_deci,
		"last_event_action_deci": _last_event_action_deci,
		"action_trigger_types": _action_trigger_types.duplicate(true),
		"action_active": _action_active,
		"recent_event_ids": _recent_event_ids.duplicate(),
		"wander_ap_accum": _wander_ap_accum,
		"visited_pois": _visited_pois.duplicate(true),
		"visited_regions": visited_regions,
		"revealed_pois": revealed_pois,
		"previous_terrain": _previous_terrain,
		"reveal_level": _reveal_level,
		"goal_attempts": _goal_attempts,
		"goal_counted": _goal_counted,
		"event_log": _event_log.duplicate(),
		"random_events_enabled": random_events_enabled,
	}


## 读档用：区域编号由地图重新推导，其余计数、冷却与已访问记录逐项恢复。
func load_save_data(map: MapData, data: Dictionary) -> bool:
	if map == null or data.is_empty():
		return false
	reset_state()
	_build_regions(map)
	pending_events.clear()
	for entry in data.get("pending_events", []):
		if not (entry is Dictionary):
			continue
		var raw: Dictionary = entry
		var event_id := String(raw.get("event_id", ""))
		if event_id.is_empty():
			continue
		var trigger := String(raw.get("trigger", "wander"))
		pending_events.append({
			"event_id": event_id,
			"trigger": trigger,
			"cell_id": int(raw.get("cell_id", -1)),
			"priority": int(raw.get("priority", PRIORITY.get(trigger, 0))),
			"counted": bool(raw.get("counted", true)),
			"note": String(raw.get("note", "")),
		})
	_cooldowns.clear()
	var cooldowns = data.get("cooldowns", {})
	if cooldowns is Dictionary:
		for event_id in cooldowns.keys():
			var remaining := int(cooldowns[event_id])
			if remaining > 0:
				_cooldowns[String(event_id)] = remaining
	_events_this_round = maxi(0, int(data.get("events_this_round", 0)))
	_random_events_this_round = maxi(0, int(data.get("random_events_this_round", 0)))
	_random_events_this_run = maxi(0, int(data.get("random_events_this_run", 0)))
	_events_this_action = maxi(0, int(data.get("events_this_action", 0)))
	_action_ap_deci = maxi(0, int(data.get("action_ap_deci", 0)))
	_last_event_action_deci = int(data.get("last_event_action_deci", -1000000))
	_action_trigger_types.clear()
	var trigger_types = data.get("action_trigger_types", {})
	if trigger_types is Dictionary:
		for trigger in trigger_types.keys():
			_action_trigger_types[String(trigger)] = bool(trigger_types[trigger])
	_action_active = bool(data.get("action_active", false))
	_recent_event_ids.clear()
	for event_id in data.get("recent_event_ids", []):
		_recent_event_ids.append(String(event_id))
	_wander_ap_accum = maxi(0, int(data.get("wander_ap_accum", 0)))
	_visited_pois.clear()
	var visited_pois = data.get("visited_pois", {})
	if visited_pois is Dictionary:
		for poi_id in visited_pois.keys():
			_visited_pois[String(poi_id)] = true
	_visited_regions.clear()
	var visited_regions = data.get("visited_regions", {})
	if visited_regions is Dictionary:
		for region in visited_regions.keys():
			_visited_regions[int(region)] = true
	_revealed_pois.clear()
	var revealed_pois = data.get("revealed_pois", {})
	if revealed_pois is Dictionary:
		for cell_id in revealed_pois.keys():
			_revealed_pois[int(cell_id)] = true
	_previous_terrain = String(data.get("previous_terrain", ""))
	_reveal_level = clampi(int(data.get("reveal_level", 0)), 0, GameManager.MAX_AI_REVEAL_LEVEL)
	_goal_attempts = maxi(0, int(data.get("goal_attempts", 0)))
	_goal_counted = bool(data.get("goal_counted", false))
	_event_log.clear()
	for line in data.get("event_log", []):
		_event_log.append(String(line))
	random_events_enabled = bool(data.get("random_events_enabled", true))
	# 存档点一定在事件外：清掉交易/选项等瞬时状态，避免读档后残留旧菜单。
	active_event_id = ""
	active_event = {}
	_choice_used.clear()
	_pending.clear()
	_pending_goal_victory = false
	_pending_death = false
	_pending_death_reason = ""
	return true


func start_new_round() -> void:
	_events_this_round = 0
	_random_events_this_round = 0
	_wander_ap_accum = 0
	# 上一回合已入队但没等到触发时机的队列事件保留到下一回合；
	# 队列仍受 MAX_QUEUE 限制，不会无限堆积，也不会平白吞掉玩家走过的地点。
	if random_events_enabled and GameManager.player != null and GameManager.map != null:
		if RNGManager.roll_chance(AMBIENT_CHANCE, "event_trigger"):
			var terrain := GameManager.map.terrain_of(GameManager.player.cell_id)
			var ambient_event := _pick_weighted_event("wander", terrain)
			if not ambient_event.is_empty():
				_enqueue_event(String(ambient_event.get("id", "")), "wander", GameManager.player.cell_id, true)


## 一次“移动行动”开始（从按下执行到动画结束/事件暂停后继续）。
func begin_action() -> void:
	_action_active = true
	_events_this_action = 0
	_action_ap_deci = 0
	_last_event_action_deci = -1000000
	_action_trigger_types.clear()


func end_action() -> void:
	_action_active = false
	_events_this_action = 0
	_last_event_action_deci = -1000000
	_action_trigger_types.clear()


func tick_cooldowns() -> void:
	for event_id in _cooldowns.keys():
		var value := int(_cooldowns[event_id]) - 1
		if value <= 0:
			_cooldowns.erase(event_id)
		else:
			_cooldowns[event_id] = value


func is_on_cooldown(event_id: String) -> bool:
	return int(_cooldowns.get(event_id, 0)) > 0


func is_event_active() -> bool:
	return not active_event.is_empty()


func get_active_event() -> Dictionary:
	return active_event


func get_pending_ids() -> Array[String]:
	var result: Array[String] = []
	for entry in pending_events:
		result.append(String(entry.get("event_id", "")))
	return result


func get_reveal_level() -> int:
	return _reveal_level


func get_visited_poi_count() -> int:
	return _visited_pois.size()


func get_total_poi_count() -> int:
	return GameManager.map.poi_ids.size() if GameManager.map != null else 0


func get_exploration_text() -> String:
	var total := get_total_poi_count()
	if total <= 0:
		return "探索 0/0"
	return "探索 %d/%d" % [mini(_visited_pois.size(), total), total]


func get_events_this_run() -> int:
	return _random_events_this_run + (1 if _goal_counted else 0)


## 侦察/事件提升 AI 揭示等级；MVP 上限 3。
func grant_ai_reveal(value: int) -> int:
	_reveal_level = clampi(_reveal_level + maxi(0, value), 0, GameManager.MAX_AI_REVEAL_LEVEL)
	return _reveal_level


func is_poi_revealed(cell_id: int) -> bool:
	return _revealed_pois.has(cell_id) or GameManager.is_poi_known(cell_id)


## 侦察大成功专用：揭示最近的未探索 POI，并同步到地图迷雾。
func reveal_nearest_poi_for_scout() -> int:
	var target := _nearest_unexplored_poi()
	if target >= 0:
		_revealed_pois[target] = true
		GameManager.reveal_poi(target)
	return target


func get_event_log() -> Array[String]:
	return _event_log.duplicate()


## 调试/测试用：立即开始指定事件（不经过触发池与队列）。
func debug_start_event(event_id: String) -> bool:
	if not active_event.is_empty():
		return false
	var record := DataManager.get_record("events", event_id)
	if record.is_empty():
		return false
	var trigger := String(record.get("trigger", "poi"))
	return _start_event({
		"event_id": event_id,
		"trigger": trigger,
		"cell_id": GameManager.player.cell_id if GameManager.player != null else -1,
		"priority": int(PRIORITY.get(trigger, 0)),
		"counted": true,
	})


## 玩家实际进入地块后调用。返回 true 表示事件界面接管，移动应暂停。
func on_cell_entered(cell_id: int) -> bool:
	var map := GameManager.map
	var player := GameManager.player
	if map == null or player == null:
		return false
	var cell := map.get_cell(cell_id)
	if cell == null:
		return false

	var is_goal := cell_id == map.goal_id
	var entered_region := false
	var region := _region_of(cell_id)
	if region >= 0 and not _visited_regions.has(region):
		_visited_regions[region] = true
		entered_region = true

	if is_goal and not player.goal_passed:
		var counted := not _goal_counted
		if counted:
			_goal_counted = true
		_enqueue_event("goal_guard", "goal", cell_id, counted)
	elif not is_goal:
		if random_events_enabled and not cell.poi_id.is_empty() and not _visited_pois.has(cell.poi_id):
			var discovery_note := _grant_poi_discovery(cell_id, cell)
			if RNGManager.roll_chance(POI_TRIGGER_CHANCE, "event_trigger"):
				var poi_event := _pick_weighted_event("poi", cell.terrain)
				if not poi_event.is_empty():
					_enqueue_event(String(poi_event.get("id", "")), "poi", cell_id, true, discovery_note)
		if random_events_enabled and entered_region and not _previous_terrain.is_empty() and _previous_terrain != cell.terrain:
			if RNGManager.roll_chance(REGION_TRIGGER_CHANCE, "event_trigger"):
				var region_event := _pick_weighted_event("enter_region", cell.terrain)
				if not region_event.is_empty():
					_enqueue_event(String(region_event.get("id", "")), "enter_region", cell_id, true)

	_previous_terrain = cell.terrain

	# 终点守卫强制触发，不受行动事件预算限制。
	if is_goal:
		var goal_index := _find_pending_index("goal")
		if goal_index < 0:
			return false
		var goal_entry: Dictionary = pending_events[goal_index]
		pending_events.remove_at(goal_index)
		return _start_event(goal_entry)

	# 一次移动最多 2 个事件；同类型触发源在同一行动内只用一次。
	var next_index := _next_startable_index()
	if next_index < 0:
		return false
	var entry: Dictionary = pending_events[next_index]
	pending_events.remove_at(next_index)
	return _start_event(entry)


## POI 首次踏足：除了可能触发地点事件，还立即给一份保底发现奖励。
## 奖励和“已访问”在同一步写入，读档后不会重复领取。
func _grant_poi_discovery(cell_id: int, cell: MapData.Cell) -> String:
	var player := GameManager.player
	var map := GameManager.map
	if player == null or map == null or cell == null:
		return ""
	_visited_pois[cell.poi_id] = true
	var rng := RNGManager.get_stream("exploration")
	var roll := rng.randf()
	var terrain_name := map.terrain_display_name(cell.terrain)
	var note := ""
	if roll < POI_REWARD_SUPPLY_CHANCE:
		var supply_grant := GameManager.grant_item("supply", 1, "POI 发现")
		note = "首次踏足%s（地块 %d）：在避风处找到补给 ×1。" % [terrain_name, cell_id + 1]
		if bool(supply_grant.get("queued", false)):
			note += " 背包已满，请在背包页取舍。"
	elif roll < POI_REWARD_GOLD_CHANCE:
		var gold := rng.randi_range(POI_REWARD_GOLD_MIN, POI_REWARD_GOLD_MAX)
		player.gold += gold
		note = "首次踏足%s（地块 %d）：搜到 %d 金币。" % [terrain_name, cell_id + 1, gold]
	else:
		var potion_grant := GameManager.grant_item("potion", 1, "POI 发现")
		note = "首次踏足%s（地块 %d）：找到药水 ×1。" % [terrain_name, cell_id + 1]
		if bool(potion_grant.get("queued", false)):
			note += " 背包已满，请在背包页取舍。"
	GameManager.add_world_log(note)
	GameManager.inventory_changed.emit()
	GameManager.world_notice.emit(note)
	return note


## 移动实际扣除 AP 后调用。每跨过 3 AP 做一次 13% 的 wander 判定。
func on_ap_spent(cost_deci: int) -> void:
	if cost_deci <= 0:
		return
	_action_ap_deci += cost_deci
	if not random_events_enabled:
		return
	_wander_ap_accum += cost_deci
	while _wander_ap_accum >= WANDER_AP_STEP_DECI:
		_wander_ap_accum -= WANDER_AP_STEP_DECI
		if not RNGManager.roll_chance(WANDER_CHANCE, "event_trigger"):
			continue
		var terrain := ""
		if GameManager.map != null and GameManager.player != null:
			terrain = GameManager.map.terrain_of(GameManager.player.cell_id)
		var wander_event := _pick_weighted_event("wander", terrain)
		if wander_event.is_empty():
			continue
		var cell_id := GameManager.player.cell_id
		_enqueue_event(String(wander_event.get("id", "")), "wander", cell_id, true)


## 击退/传送后同步位置，避免下一次区域判定仍使用旧地形。
func sync_player_cell(cell_id: int) -> void:
	if GameManager.map == null:
		return
	_previous_terrain = GameManager.map.terrain_of(cell_id)
	var region := _region_of(cell_id)
	if region >= 0:
		_visited_regions[region] = true


func get_choices() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if active_event.is_empty() or GameManager.player == null:
		return result
	for choice in active_event.get("choices", []):
		result.append(_describe_choice(choice))
	return result


## 玩家选择一个选项。返回本次结算数据，同时通过 event_progress 通知 UI。
func choose_choice(choice_id: String) -> Dictionary:
	if active_event.is_empty() or GameManager.player == null:
		return _error_result("当前没有进行中的事件。")
	var choice := _find_choice(choice_id)
	if choice.is_empty():
		return _error_result("未知选项：%s" % choice_id)
	var description := _describe_choice(choice)
	if bool(description.get("disabled", false)):
		return _error_result(String(description.get("reason", "当前无法选择该选项。")))

	var resolution := String(choice.get("resolution", "check"))
	if resolution == "trade" and GameManager.player.has_flag("wanted"):
		return _error_result("你已被通缉，商队拒绝交易。")
	if bool(choice.get("once_per_event", false)) and _choice_used.has(choice_id):
		return _error_result("本次事件中已经使用过该选项。")
	_choice_used[choice_id] = true

	var auto_trait := String(choice.get("auto_success_if_trait", ""))
	if not auto_trait.is_empty() and GameManager.player.has_trait(auto_trait):
		var payload := _check_payload(choice, "success", true, "词条「%s」自动成功，跳过检定" % _trait_name(auto_trait))
		if resolution == "item_sacrifice":
			return _begin_sacrifice(choice, payload)
		if resolution == "heal_choice":
			return _begin_heal(choice, payload)
		return _resolve_outcome(choice, "success", payload)

	var immune_trait := String(choice.get("immune_if_trait", ""))
	if not immune_trait.is_empty() and GameManager.player.has_trait(immune_trait):
		var immune_payload := _check_payload(choice, "success", true, "词条「%s」完全免疫，跳过检定" % _trait_name(immune_trait))
		var applied := _apply_effects([])
		var immune_result := _finish_resolution(choice, "success", immune_payload, applied)
		immune_result["level_name"] = "免疫"
		immune_result["outcome_note"] = "你熟悉这片地形，事件没有造成任何影响。"
		event_progress.emit(immune_result)
		return immune_result

	match resolution:
		"item_sacrifice":
			return _begin_sacrifice(choice, _check_payload(choice, "success", true, ""))
		"heal_choice":
			return _begin_heal(choice, _check_payload(choice, "success", true, ""))
		_:
			var payload := _roll_check(choice)
			var level := String(payload.get("level", "success"))
			if resolution == "trade":
				if level == "success" or level == "great_success":
					return _begin_trade(choice, level, payload)
				return _resolve_outcome(choice, level, payload)
			if resolution == "steal" and (level == "success" or level == "great_success"):
				return _begin_steal(choice, level, payload)
			return _resolve_outcome(choice, level, payload)


## 商队交易：index = -1 表示放弃购买。
func resolve_trade_offer(index: int) -> Dictionary:
	if String(_pending.get("type", "")) != "trade":
		return _error_result("当前不在交易选择中。")
	var payload: Dictionary = _pending.get("payload", {})
	var level := String(_pending.get("level", "success"))
	var choice := _find_choice(String(_pending.get("choice_id", "")))
	if index < 0:
		_pending.clear()
		var declined := _base_result(choice, level, payload)
		declined["kind"] = "outcome"
		declined["level_name"] = "放弃交易"
		declined["outcome_note"] = "你放弃了购买，金币没有变化。"
		declined["effect_messages"] = []
		declined["status_text"] = GameManager.player.status_display_text()
		declined["status_details"] = GameManager.player.status_detail_text()
		_emit_progress(declined)
		return declined
	var offers: Array = payload.get("offers", [])
	if index >= offers.size():
		return _error_result("无效的交易选项。")
	var offer: Dictionary = offers[index]
	if bool(offer.get("disabled", false)):
		return _error_result(String(offer.get("reason", "无法完成该交易。")))
	var player := GameManager.player
	var messages: Array[String] = []
	var rewards: Array[Dictionary] = []
	var costs: Array[Dictionary] = []
	if String(offer.get("type", "")) == "buy":
		var price := int(offer.get("price", 0))
		var item_id := String(offer.get("item_id", ""))
		player.gold -= price
		var bought := GameManager.grant_item(item_id, 1, "商队交易")
		var cost_text := "花费 %d 金币。" % price
		var gain_text := String(bought.get("message", "获得 %s ×1。" % _item_name(item_id)))
		messages.append(cost_text)
		messages.append(gain_text)
		_add_cost(costs, cost_text, "gold")
		_add_reward(rewards, gain_text, "item", _item_reward_hint(item_id))
	else:
		var give_id := String(offer.get("give_id", ""))
		var receive_id := String(offer.get("receive_id", ""))
		var give_count := int(offer.get("give_count", 1))
		var receive_count := int(offer.get("receive_count", 1))
		player.remove_item(give_id, give_count)
		var received := GameManager.grant_item(receive_id, receive_count, "商队交易")
		var give_text := "失去 %s ×%d。" % [_item_name(give_id), give_count]
		var receive_text := String(received.get("message", "获得 %s ×%d。" % [_item_name(receive_id), receive_count]))
		messages.append(give_text)
		messages.append(receive_text)
		_add_cost(costs, give_text, "item")
		_add_reward(rewards, receive_text, "item", _item_reward_hint(receive_id))
	_pending.clear()
	var result := _base_result(choice, level, payload)
	result["kind"] = "outcome"
	result["level_name"] = "交易达成"
	result["outcome_note"] = "本次商队事件已交易。"
	result["effect_messages"] = messages
	result["reward_entries"] = rewards
	result["cost_entries"] = costs
	result["insight_entries"] = []
	result["hp"] = player.hp
	result["ap_deci"] = player.ap_deci
	result["gold"] = player.gold
	result["status_text"] = player.status_display_text()
	result["status_details"] = player.status_detail_text()
	_emit_progress(result)
	return result


## 偷窃成功 / 大成功后选择物品。
func resolve_steal_item(item_id: String) -> Dictionary:
	if String(_pending.get("type", "")) != "steal":
		return _error_result("当前不在偷窃选择中。")
	var choice := _find_choice(String(_pending.get("choice_id", "")))
	var level := String(_pending.get("level", "success"))
	var payload: Dictionary = _pending.get("payload", {})
	var allowed: Array = payload.get("items", [])
	if not allowed.has(item_id):
		return _error_result("无法偷取该物品。")
	var outcome := _outcome_for(choice, level)
	var effects: Array = []
	for effect in outcome.get("player_effects", []):
		if String(effect.get("type", "")) == "item_gain" and effect.has("choose_from"):
			continue
		effects.append(effect)
	for effect in outcome.get("effects", []):
		effects.append(effect)
	_pending.clear()
	var applied := _apply_effects(effects)
	var stolen := GameManager.grant_item(item_id, 1, "事件偷窃")
	var stolen_text := String(stolen.get("message", "获得 %s ×1。" % _item_name(item_id)))
	applied["messages"].push_front(stolen_text)
	var rewards: Array[Dictionary] = []
	for entry in applied.get("rewards", []):
		rewards.append(entry)
	rewards.push_front({"text": stolen_text, "kind": "item", "hint": _item_reward_hint(item_id)})
	applied["rewards"] = rewards
	return _finish_resolution(choice, level, payload, applied)


## 献祭物品通过终点守卫。
func resolve_sacrifice(item_id: String) -> Dictionary:
	if String(_pending.get("type", "")) != "sacrifice":
		return _error_result("当前不在献祭选择中。")
	var candidates: Array = _pending.get("items", [])
	if not candidates.has(item_id):
		return _error_result("该物品不能用于献祭。")
	var choice := _find_choice(String(_pending.get("choice_id", "")))
	var payload: Dictionary = _pending.get("payload", {})
	if GameManager.player.remove_item(item_id, 1) <= 0:
		return _error_result("物品已不在背包中。")
	_pending.clear()
	var applied := _apply_effects(choice.get("outcomes", {}).get("success", {}).get("effects", []))
	var sacrifice_text := "献出 %s ×1。" % _item_name(item_id)
	applied["messages"].push_front(sacrifice_text)
	var costs: Array[Dictionary] = []
	for entry in applied.get("costs", []):
		costs.append(entry)
	costs.push_front({"text": sacrifice_text, "kind": "item", "hint": ""})
	applied["costs"] = costs
	var result := _finish_resolution(choice, "success", payload, applied)
	result["level_name"] = "守卫离开"
	result["outcome_note"] = "守卫接过祭品，侧身让开了通往终点的路。"
	return result


## 古井饮水：hp / ap。
func resolve_heal(option: String) -> Dictionary:
	if String(_pending.get("type", "")) != "heal":
		return _error_result("当前不在恢复选择中。")
	var choice := _find_choice(String(_pending.get("choice_id", "")))
	var payload: Dictionary = _pending.get("payload", {})
	_pending.clear()
	var messages: Array[String] = []
	var manual_text := "恢复 1 HP。"
	if option == "ap":
		GameManager.player.ap_deci += 10
		manual_text = "恢复 1 AP。"
	else:
		GameManager.player.heal(1)
	messages.append(manual_text)
	var applied := _apply_effects(choice.get("outcomes", {}).get("success", {}).get("effects", []))
	for message in applied.get("messages", []):
		messages.append(String(message))
	var rewards: Array[Dictionary] = []
	for entry in applied.get("rewards", []):
		rewards.append(entry)
	rewards.push_front({"text": manual_text, "kind": "hp" if option != "ap" else "ap", "hint": ""})
	var result := _finish_resolution(choice, "success", payload, {
		"messages": messages,
		"rewards": rewards,
		"costs": applied.get("costs", []),
		"insights": applied.get("insights", []),
		"enter_goal": bool(applied.get("enter_goal", false)),
		"death": bool(applied.get("death", false)),
		"knockback": int(applied.get("knockback", 0)),
	})
	result["level_name"] = "饮水"
	return result


## 关闭当前事件。GameManager 在 event_finished 后决定胜利/死亡/继续移动。
func finish_event() -> void:
	if active_event.is_empty():
		return
	var event_id := active_event_id
	var cooldown := int(active_event.get("cooldown", 2))
	if cooldown > 0:
		_cooldowns[event_id] = maxi(int(_cooldowns.get(event_id, 0)), cooldown)
	active_event_id = ""
	active_event = {}
	active_trigger = ""
	_choice_used.clear()
	_pending.clear()
	event_finished.emit(event_id)


## 取出并清空本事件造成的一次性结局。
func take_pending_outcome() -> Dictionary:
	var outcome := {
		"goal": _pending_goal_victory,
		"death": _pending_death,
		"death_reason": _pending_death_reason,
	}
	_pending_goal_victory = false
	_pending_death = false
	_pending_death_reason = ""
	return outcome


## ---------------- 触发与事件池 ----------------

func _build_regions(map: MapData) -> void:
	_region_ids.resize(map.cells.size())
	_region_ids.fill(-1)
	_region_count = 0
	for start in range(map.cells.size()):
		if _region_ids[start] >= 0:
			continue
		var terrain := map.cells[start].terrain
		var region := _region_count
		_region_count += 1
		var frontier := PackedInt32Array([start])
		_region_ids[start] = region
		while not frontier.is_empty():
			var current := frontier[frontier.size() - 1]
			frontier.remove_at(frontier.size() - 1)
			for neighbor in map.get_cell(current).neighbors:
				if _region_ids[neighbor] >= 0:
					continue
				if map.cells[neighbor].terrain != terrain:
					continue
				_region_ids[neighbor] = region
				frontier.append(neighbor)


func _region_of(cell_id: int) -> int:
	if cell_id < 0 or cell_id >= _region_ids.size():
		return -1
	return int(_region_ids[cell_id])


func _pick_weighted_event(trigger: String, terrain: String) -> Dictionary:
	var allowed_ids := GameManager.available_event_ids(GameManager.current_map_config())
	var candidates: Array[Dictionary] = []
	for record in DataManager.all_records("events"):
		var event: Dictionary = record
		var event_id := String(event.get("id", ""))
		if not allowed_ids.has(event_id):
			continue
		if String(event.get("trigger", "")) != trigger:
			continue
		if is_on_cooldown(event_id):
			continue
		var terrains: Array = event.get("terrains", [])
		var weight := float(event.get("weight", 0))
		if weight <= 0.0:
			continue
		if terrains.has("any"):
			weight *= 1.0
		elif terrains.has(terrain):
			weight *= 1.35
		else:
			continue
		weight *= _context_weight(event)
		candidates.append({"event": event, "weight": weight})
	if candidates.is_empty():
		return {}
	# 防重复池：最近出现过的事件只在没有其他候选时才允许再次出现。
	var fresh: Array[Dictionary] = []
	for entry in candidates:
		var event_id := String((entry["event"] as Dictionary).get("id", ""))
		if not _recent_event_ids.has(event_id):
			fresh.append(entry)
	if not fresh.is_empty():
		candidates = fresh
	var total_weight := 0.0
	for entry in candidates:
		total_weight += float(entry["weight"])
	if total_weight <= 0.0:
		return {}
	var roll := RNGManager.get_stream("event").randf() * total_weight
	for entry in candidates:
		roll -= float(entry["weight"])
		if roll <= 0.0:
			return entry["event"]
	return candidates[candidates.size() - 1]["event"]


## 情境权重只调整“更像会发生什么”，不硬锁事件；仍受地图事件清单与冷却约束。
func _context_weight(event: Dictionary) -> float:
	var weight := 1.0
	var event_id := String(event.get("id", ""))
	var player := GameManager.player
	if player == null:
		return weight
	var hp_ratio := float(player.hp) / maxf(float(player.hp_max), 1.0)
	if hp_ratio <= 0.35:
		if BENEFICIAL_EVENTS.has(event_id):
			weight *= 1.55
		if DANGEROUS_EVENTS.has(event_id):
			weight *= 0.62
	elif hp_ratio <= 0.65:
		if BENEFICIAL_EVENTS.has(event_id):
			weight *= 1.18
		if DANGEROUS_EVENTS.has(event_id):
			weight *= 0.85
	if player.has_flag("wanted"):
		if event_id == "caravan":
			weight *= 0.35
		elif DANGEROUS_EVENTS.has(event_id):
			weight *= 1.2
	var rounds_left := GameManager.MAX_ROUNDS - GameManager.round_index + 1
	if rounds_left <= 10:
		if DANGEROUS_EVENTS.has(event_id) or INFO_EVENTS.has(event_id):
			weight *= 0.78
		elif SOCIAL_EVENTS.has(event_id) or BENEFICIAL_EVENTS.has(event_id):
			weight *= 1.18
	if GameManager.companion_at_player(1):
		match GameManager.companion.faction:
			"enemy":
				if DANGEROUS_EVENTS.has(event_id):
					weight *= 1.25
				if SOCIAL_EVENTS.has(event_id):
					weight *= 0.85
			"friendly":
				if SOCIAL_EVENTS.has(event_id):
					weight *= 1.25
				if BENEFICIAL_EVENTS.has(event_id):
					weight *= 1.1
	return clampf(weight, 0.2, 2.0)


## 事件面板顶部的“局势”提示，让玩家在做选择前理解当前压力来源。
func get_context_note() -> String:
	var player := GameManager.player
	if player == null:
		return ""
	var parts: Array[String] = []
	var hp_ratio := float(player.hp) / maxf(float(player.hp_max), 1.0)
	if hp_ratio <= 0.35:
		parts.append("你已负伤（HP %d/%d），失败可能致命。" % [player.hp, player.hp_max])
	elif hp_ratio < 0.8:
		parts.append("你身上带着伤，别把退路押在一次检定上。")
	if player.has_flag("wanted"):
		parts.append("你正被通缉，商队不会与你交易。")
	var rounds_left := GameManager.MAX_ROUNDS - GameManager.round_index + 1
	if rounds_left <= 10:
		parts.append("距离日落只剩 %d 回合。" % rounds_left)
	if GameManager.companion_at_player(1):
		var ai_name := GameManager.companion_name()
		if GameManager.companion != null and GameManager.companion.faction == "enemy" \
				and EventManager.get_reveal_level() >= 2:
			parts.append("%s就在附近，你能感觉到不善的目光。" % ai_name)
		elif GameManager.companion != null and GameManager.companion.faction == "friendly":
			parts.append("%s在你身侧，随时可以搭把手。" % ai_name)
		else:
			parts.append("%s就在附近。" % ai_name)
	return " ".join(parts)


func _enqueue_event(event_id: String, trigger: String, cell_id: int, counted: bool, note: String = "") -> void:
	if event_id.is_empty():
		return
	if active_event_id == event_id:
		return
	for entry in pending_events:
		if String(entry.get("event_id", "")) == event_id:
			if not note.is_empty() and String(entry.get("note", "")).is_empty():
				entry["note"] = note
			return
	if trigger != "goal" and _random_events_this_run + pending_events.size() >= MAX_RANDOM_EVENTS_PER_RUN:
		_log("单局随机事件已达上限（%d），忽略新的 %s 触发。" % [MAX_RANDOM_EVENTS_PER_RUN, trigger])
		return
	var priority := int(PRIORITY.get(trigger, 0))
	var entry := {
		"event_id": event_id,
		"trigger": trigger,
		"cell_id": cell_id,
		"priority": priority,
		"counted": counted,
		"note": note,
	}
	if pending_events.size() < MAX_QUEUE:
		pending_events.append(entry)
		_log("事件入队：%s（%s）" % [event_id, trigger])
		event_queued.emit(event_id)
		return
	var lowest_index := 0
	for i in range(1, pending_events.size()):
		if int(pending_events[i].get("priority", 0)) < int(pending_events[lowest_index].get("priority", 0)):
			lowest_index = i
	var lowest_priority := int(pending_events[lowest_index].get("priority", 0))
	if priority > lowest_priority:
		var dropped := String(pending_events[lowest_index].get("event_id", ""))
		pending_events[lowest_index] = entry
		_log("事件队列已满：丢弃 %s，保留更高优先级的 %s" % [dropped, event_id])
		event_queued.emit(event_id)
	else:
		_log("事件队列已满：丢弃新触发 %s（优先级 %d）" % [event_id, priority])


func _find_pending_index(trigger: String) -> int:
	for i in range(pending_events.size()):
		if String(pending_events[i].get("trigger", "")) == trigger:
			return i
	return -1


func _highest_priority_index() -> int:
	var best := -1
	for i in range(pending_events.size()):
		if best < 0 or int(pending_events[i].get("priority", 0)) > int(pending_events[best].get("priority", 0)):
			best = i
	return best


## 在当前行动预算内选取优先级最高、且可以立即开始的事件。
func _next_startable_index() -> int:
	var best := -1
	for i in range(pending_events.size()):
		if not _can_start_entry(pending_events[i]):
			continue
		if best < 0 or int(pending_events[i].get("priority", 0)) > int(pending_events[best].get("priority", 0)):
			best = i
	return best


func _can_start_entry(entry: Dictionary) -> bool:
	var trigger := String(entry.get("trigger", ""))
	if trigger == "goal":
		return true
	if _events_this_action >= MAX_EVENTS_PER_ACTION:
		return false
	if _action_trigger_types.has(trigger):
		return false
	if _random_events_this_round >= MAX_RANDOM_EVENTS_PER_ROUND:
		return false
	if _events_this_action > 0 and _action_ap_deci - _last_event_action_deci < MIN_EVENT_AP_SPACING_DECI:
		return false
	return true


func _remember_recent_event(event_id: String) -> void:
	if event_id.is_empty():
		return
	_recent_event_ids.erase(event_id)
	_recent_event_ids.append(event_id)
	while _recent_event_ids.size() > RECENT_EVENT_MEMORY:
		_recent_event_ids.pop_front()


func _start_event(entry: Dictionary) -> bool:
	var event_id := String(entry.get("event_id", ""))
	var record := DataManager.get_record("events", event_id)
	if record.is_empty():
		_log("事件数据缺失：%s" % event_id)
		return false
	var trigger := String(entry.get("trigger", ""))
	var counted := bool(entry.get("counted", true))
	active_event_id = event_id
	active_event = record.duplicate(true)
	var discovery_note := String(entry.get("note", "")).strip_edges()
	if not discovery_note.is_empty():
		active_event["discovery_note"] = discovery_note
	active_trigger = trigger
	_choice_used.clear()
	_pending.clear()
	if counted:
		_events_this_round += 1
		if trigger != "goal":
			_random_events_this_round += 1
			_random_events_this_run += 1
	if _action_active:
		_events_this_action += 1
		_action_trigger_types[trigger] = true
		_last_event_action_deci = _action_ap_deci
	_remember_recent_event(event_id)
	if trigger == "goal":
		_goal_attempts += 1
	_log("事件开始：%s" % String(record.get("name", event_id)))
	GameManager.add_world_log("遭遇「%s」。" % String(record.get("name", event_id)))
	event_started.emit(active_event)
	return true


## ---------------- 选项与检定 ----------------

func _find_choice(choice_id: String) -> Dictionary:
	for choice in active_event.get("choices", []):
		if String(choice.get("id", "")) == choice_id:
			return choice
	return {}


func _describe_choice(choice: Dictionary) -> Dictionary:
	var choice_id := String(choice.get("id", ""))
	var info := {
		"id": choice_id,
		"text": String(choice.get("text", choice_id)),
		"check_text": _check_text(choice.get("check", null)),
		"disabled": false,
		"reason": "",
		"resolution": String(choice.get("resolution", "check")),
		"risk": "",
	}
	if typeof(choice.get("check")) == TYPE_DICTIONARY:
		info["risk"] = _risk_label(choice)
	if bool(choice.get("once_per_event", false)) and _choice_used.has(choice_id):
		info["disabled"] = true
		info["reason"] = "本次事件中已经使用过。"
		return info
	if String(choice.get("resolution", "")) == "trade" and GameManager.player.has_flag("wanted"):
		info["disabled"] = true
		info["reason"] = "你已被通缉，商队拒绝交易。"
		return info
	if String(choice.get("resolution", "")) == "item_sacrifice":
		var params: Dictionary = choice.get("params", {})
		var allowed: Array = params.get("allow_types", [])
		var candidates := GameManager.player.sacrifice_candidates(allowed, bool(params.get("exclude_quest_items", true)))
		if candidates.is_empty():
			info["disabled"] = true
			info["reason"] = "没有可用于献祭的非任务物品。"
	return info


## 选择前只给出选项文本与风险档位，不展示任何结果预告。
## 实际获得/失去什么，只在选择并完成检定后由结算消息揭示。
func _risk_label(choice: Dictionary) -> String:
	var check: Dictionary = choice.get("check", {})
	var dc := int(check.get("dc", 10))
	# 风险主要看常见失败；只有大失败中的永久诅咒才额外抬高等级，
	# 否则普通高伤害大失败会把所有战斗选项都标成“高”。
	var severity := _outcome_severity(_outcome_for(choice, "fail"))
	var great_fail := _outcome_for(choice, "great_fail")
	if _outcome_has_status(great_fail, "cursed"):
		severity = maxi(severity, 3)
	elif _outcome_has_status(great_fail, "cursed_minor"):
		severity = maxi(severity, 2)
	if severity >= 3 or dc >= 14:
		return "高"
	if severity >= 1 or dc >= 11:
		return "中"
	return "低"


## 失败与大失败中更严重的代价，用来算风险标签。
func _outcome_severity(outcome: Dictionary) -> int:
	var severity := _hp_loss_of(outcome)
	for pool_name in ["effects", "player_effects"]:
		for effect_value in outcome.get(pool_name, []):
			var effect: Dictionary = effect_value
			match String(effect.get("type", "")):
				"status_add":
					match String(effect.get("status_id", "")):
						"cursed":
							severity += 3
						"trapped", "bleeding", "poisoned", "burned":
							severity += 2
						"cursed_minor", "suspected", "lost", "lost_severe":
							severity += 1
				"flag_add":
					if String(effect.get("flag_id", "")) == "wanted":
						severity += 1
	return severity


func _hp_loss_of(outcome: Dictionary) -> int:
	var loss := 0
	for pool_name in ["effects", "player_effects", "ai_effects"]:
		for effect_value in outcome.get(pool_name, []):
			var effect: Dictionary = effect_value
			if String(effect.get("type", "")) == "hp":
				var value := int(effect.get("value", 0))
				if value < 0:
					loss += -value
	return loss


func _outcome_has_status(outcome: Dictionary, status_id: String) -> bool:
	for pool_name in ["effects", "player_effects"]:
		for effect_value in outcome.get(pool_name, []):
			var effect: Dictionary = effect_value
			if String(effect.get("type", "")) == "status_add" and String(effect.get("status_id", "")) == status_id:
				return true
	return false


func _outcome_has_flag(outcome: Dictionary, flag_id: String) -> bool:
	for pool_name in ["effects", "player_effects"]:
		for effect_value in outcome.get(pool_name, []):
			var effect: Dictionary = effect_value
			if String(effect.get("type", "")) == "flag_add" and String(effect.get("flag_id", "")) == flag_id:
				return true
	return false


## 状态预览直接带上数值、持续时间和解除方式；诅咒不能只显示一个名字。
func _status_detail(status_id: String) -> String:
	var record := DataManager.get_record("statuses", status_id)
	var name := String(record.get("name", status_id))
	var description := String(record.get("description", "")).strip_edges()
	if description.is_empty():
		description = "效果见状态说明。"
	var removable := bool(record.get("removable_by_potion", false))
	var category := String(record.get("category", ""))
	if removable and not description.contains("药水"):
		description += "；可被药水解除。"
	elif not removable and category == "debuff" and not description.contains("药水"):
		description += "；药水无法解除。"
	return "「%s」：%s" % [name, description]


func _check_text(check) -> String:
	if typeof(check) != TYPE_DICTIONARY:
		return "无需检定"
	var attr := String(check.get("attr", ""))
	return "%s DC %d" % [String(ATTR_NAMES.get(attr, attr)), int(check.get("dc", 10))]


func _roll_check(choice: Dictionary) -> Dictionary:
	var check = choice.get("check", null)
	if typeof(check) != TYPE_DICTIONARY:
		return _check_payload(choice, "success", true, "")
	var dice := RNGManager.roll_2d6("event")
	var natural := int(dice[0]) + int(dice[1])
	var attr := String(check.get("attr", ""))
	var dc := int(check.get("dc", 10))
	var breakdown := GameManager.player.check_breakdown(attr)
	var equipment_parts: Array = breakdown.get("equipment_parts", [])
	var status_parts: Array = breakdown.get("status_parts", [])
	var trait_bonus := 0
	var trait_notes: Array[String] = []
	var trait_parts: Array[Dictionary] = []
	var terrain := ""
	if GameManager.map != null:
		terrain = GameManager.map.terrain_of(GameManager.player.cell_id)
	for modifier in choice.get("trait_modifiers", []):
		var trait_id := String(modifier.get("trait", ""))
		if not GameManager.player.has_trait(trait_id):
			continue
		if modifier.has("if_terrain") and String(modifier["if_terrain"]) != terrain:
			continue
		var bonus := int(modifier.get("bonus", 0))
		trait_bonus += bonus
		var trait_name := _trait_name(trait_id)
		trait_notes.append("%s %+d" % [trait_name, bonus])
		trait_parts.append({"id": trait_id, "name": trait_name, "value": bonus})
	var total := natural + int(breakdown["base"]) + int(breakdown["equipment"]) + int(breakdown["status"]) + trait_bonus
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
	var attribute_name := String(ATTR_NAMES.get(attr, attr))
	var formula := GameManager.player.check_formula_text(attr, natural, attribute_name)
	for part in trait_parts:
		formula = ActorState.append_bonus_term(formula, int(part.get("value", 0)), String(part.get("name", "")))
	var detail := "%s = %d vs DC %d · %s" % [formula, total, dc, level_name]
	var payload := {
		"check": true,
		"auto": false,
		"dice": [int(dice[0]), int(dice[1])],
		"natural": natural,
		"attribute": attr,
		"attribute_name": attribute_name,
		"base": int(breakdown["base"]),
		"equipment": int(breakdown["equipment"]),
		"status": int(breakdown["status"]),
		"equipment_parts": equipment_parts,
		"status_parts": status_parts,
		"trait": trait_bonus,
		"trait_notes": trait_notes,
		"trait_parts": trait_parts,
		"formula": formula,
		"total": total,
		"dc": dc,
		"level": level,
		"level_name": level_name,
		"note": "",
	}
	dice_rolled.emit({
		"title": "事件检定 · %s" % attribute_name,
		"kind": "event",
		"kind_label": "事件选项",
		"dice": [int(dice[0]), int(dice[1])],
		"sides": 6,
		"modifier": int(breakdown["base"]) + int(breakdown["equipment"]) + int(breakdown["status"]) + trait_bonus,
		"total": total,
		"dc": dc,
		"level_name": level_name,
		"detail": detail,
	})
	return payload


func _check_payload(choice: Dictionary, level: String, automatic: bool, note: String) -> Dictionary:
	return {
		"check": false,
		"auto": automatic,
		"dice": [],
		"natural": 0,
		"attribute": "",
		"attribute_name": "",
		"base": 0,
		"equipment": 0,
		"status": 0,
		"trait": 0,
		"trait_notes": [],
		"total": 0,
		"dc": 0,
		"level": level,
		"level_name": "自动成功" if automatic else "成功",
		"note": note,
	}


func _resolve_outcome(choice: Dictionary, level: String, payload: Dictionary) -> Dictionary:
	var outcome := _outcome_for(choice, level)
	var effects: Array = []
	for effect in outcome.get("effects", []):
		effects.append(effect)
	for effect in outcome.get("player_effects", []):
		effects.append(effect)
	var applied := _apply_effects(effects)
	# 同伴在场时，同一结果也会作用在她身上；离开视野的同伴不会凭空分走事件。
	if GameManager.player != null and GameManager.player.hp > 0:
		var ai_messages := _apply_ai_effects(outcome.get("ai_effects", []))
		for message in ai_messages:
			applied["messages"].append(String(message))
	var result := _finish_resolution(choice, level, payload, applied)
	result["outcome_note"] = String(outcome.get("note", ""))
	return result


func _finish_resolution(choice: Dictionary, level: String, payload: Dictionary, applied: Dictionary) -> Dictionary:
	var result := _base_result(choice, level, payload)
	result["kind"] = "outcome"
	result["effect_messages"] = applied.get("messages", [])
	result["reward_entries"] = applied.get("rewards", [])
	result["cost_entries"] = applied.get("costs", [])
	result["insight_entries"] = applied.get("insights", [])
	result["enter_goal"] = bool(applied.get("enter_goal", false))
	result["death"] = bool(applied.get("death", false))
	result["knockback"] = int(applied.get("knockback", 0))
	var player := GameManager.player
	result["hp"] = player.hp
	result["ap_deci"] = player.ap_deci
	result["gold"] = player.gold
	result["status_text"] = player.status_display_text()
	result["status_details"] = player.status_detail_text()
	_emit_progress(result)
	return result


func _base_result(choice: Dictionary, level: String, payload: Dictionary) -> Dictionary:
	var result := payload.duplicate(true)
	result["kind"] = "outcome"
	result["choice_id"] = String(choice.get("id", ""))
	result["choice_text"] = String(choice.get("text", ""))
	result["level"] = level
	if not result.has("level_name") or String(result.get("level_name", "")).is_empty():
		result["level_name"] = _level_name(level)
	result["outcome_note"] = ""
	result["event_id"] = active_event_id
	result["reward_entries"] = []
	result["cost_entries"] = []
	result["insight_entries"] = []
	return result


func _outcome_for(choice: Dictionary, level: String) -> Dictionary:
	var outcomes: Dictionary = choice.get("outcomes", {})
	if outcomes.has(level):
		return outcomes[level]
	if (level == "great_success" or level == "success") and outcomes.has("success"):
		return outcomes["success"]
	if (level == "great_fail" or level == "fail") and outcomes.has("fail"):
		return outcomes["fail"]
	return {}


func _level_name(level: String) -> String:
	match level:
		"great_success":
			return "大成功"
		"success":
			return "成功"
		"great_fail":
			return "大失败"
		_:
			return "失败"


## ---------------- 解析器：交易 / 偷窃 / 献祭 / 饮水 ----------------

func _begin_trade(choice: Dictionary, level: String, payload: Dictionary) -> Dictionary:
	var params: Dictionary = choice.get("params", {})
	var multiplier := float(params.get("price_multiplier_on_great_success", 0.5)) if level == "great_success" else 1.0
	var player := GameManager.player
	var offers: Array[Dictionary] = []
	for offer in params.get("offers", []):
		var give: Dictionary = offer.get("give", {})
		var receive: Dictionary = offer.get("receive", {})
		var entry := {
			"type": String(offer.get("type", "")),
			"disabled": false,
			"reason": "",
			"item_id": String(offer.get("item_id", "")),
			"price": 0,
			"give_id": String(give.get("item_id", "")),
			"give_count": int(give.get("count", 1)),
			"receive_id": String(receive.get("item_id", "")),
			"receive_count": int(receive.get("count", 1)),
		}
		if entry["type"] == "buy":
			var price := int(ceil(float(offer.get("price", 0)) * multiplier))
			entry["price"] = price
			if player.gold < price:
				entry["disabled"] = true
				entry["reason"] = "金币不足（需要 %d）。" % price
			entry["label"] = "购买 %s（%d 金币）" % [_item_name(String(entry["item_id"])), price]
		else:
			var give_count := int(entry["give_count"])
			if player.item_count(String(entry["give_id"])) < give_count:
				entry["disabled"] = true
				entry["reason"] = "需要 %s ×%d。" % [_item_name(String(entry["give_id"])), give_count]
			entry["label"] = "以物易物：%s ×%d → %s ×%d" % [
				_item_name(String(entry["give_id"])), give_count,
				_item_name(String(entry["receive_id"])), int(entry["receive_count"]),
			]
		offers.append(entry)
	var trade_payload := payload.duplicate(true)
	trade_payload["offers"] = offers
	trade_payload["can_decline"] = bool(params.get("can_decline", true))
	if level == "great_success":
		trade_payload["note"] = "大成功：本次交易价格减半。"
	_pending = {"type": "trade", "choice_id": String(choice.get("id", "")), "level": level, "payload": trade_payload}
	var result := _base_result(choice, level, trade_payload)
	result["kind"] = "trade_menu"
	result["title"] = "交易"
	result["offers"] = offers
	result["can_decline"] = bool(params.get("can_decline", true))
	_emit_progress(result)
	return result


func _begin_steal(choice: Dictionary, level: String, payload: Dictionary) -> Dictionary:
	var outcome := _outcome_for(choice, level)
	var item_choices: Array[String] = []
	for effect in outcome.get("player_effects", []):
		if String(effect.get("type", "")) == "item_gain" and effect.has("choose_from"):
			for item_id in effect["choose_from"]:
				item_choices.append(String(item_id))
	if item_choices.is_empty():
		for item_id in choice.get("params", {}).get("item_choices", []):
			item_choices.append(String(item_id))
	if item_choices.is_empty():
		return _resolve_outcome(choice, level, payload)
	var steal_payload := payload.duplicate(true)
	steal_payload["items"] = item_choices
	_pending = {"type": "steal", "choice_id": String(choice.get("id", "")), "level": level, "payload": steal_payload}
	var result := _base_result(choice, level, steal_payload)
	result["kind"] = "steal_menu"
	result["title"] = "选择偷取的物品"
	result["items"] = item_choices
	_emit_progress(result)
	return result


func _begin_sacrifice(choice: Dictionary, payload: Dictionary) -> Dictionary:
	var params: Dictionary = choice.get("params", {})
	var allowed: Array = params.get("allow_types", [])
	var candidates := GameManager.player.sacrifice_candidates(allowed, bool(params.get("exclude_quest_items", true)))
	if candidates.is_empty():
		return _error_result("没有可用于献祭的非任务物品。")
	var sacrifice_payload := payload.duplicate(true)
	sacrifice_payload["items"] = candidates
	_pending = {"type": "sacrifice", "choice_id": String(choice.get("id", "")), "level": "success", "payload": sacrifice_payload, "items": candidates}
	var result := _base_result(choice, "success", sacrifice_payload)
	result["kind"] = "sacrifice_menu"
	result["title"] = "选择献祭的物品"
	result["items"] = candidates
	_emit_progress(result)
	return result


func _begin_heal(choice: Dictionary, payload: Dictionary) -> Dictionary:
	_pending = {"type": "heal", "choice_id": String(choice.get("id", "")), "level": "success", "payload": payload}
	var result := _base_result(choice, "success", payload)
	result["kind"] = "heal_menu"
	result["title"] = "饮水"
	result["options"] = ["hp", "ap"]
	_emit_progress(result)
	return result


## ---------------- 效果结算 ----------------

func _apply_effects(effects: Array) -> Dictionary:
	var player := GameManager.player
	var messages: Array[String] = []
	var rewards: Array[Dictionary] = []
	var costs: Array[Dictionary] = []
	var insights: Array[Dictionary] = []
	var enter_goal := false
	var knockback := 0
	var death := false

	# 1. 数值变化：HP / AP / 金币
	for effect in effects:
		var value := int(effect.get("value", 0))
		match String(effect.get("type", "")):
			"hp":
				if value < 0:
					player.take_damage(-value)
					var loss_text := "HP %d。" % value
					messages.append(loss_text)
					_add_cost(costs, loss_text, "hp")
				elif value > 0:
					player.heal(value)
					var heal_text := "HP +%d。" % value
					messages.append(heal_text)
					_add_reward(rewards, heal_text, "hp")
			"ap":
				if value < 0:
					var need := -value * 10
					var paid := mini(player.ap_deci, need)
					var missing := need - paid
					player.ap_deci = maxi(0, player.ap_deci - paid)
					var hp_loss := int(ceil(float(missing) / 10.0))
					var ap_text := "AP %d。" % value
					if hp_loss > 0:
						player.take_damage(hp_loss)
						ap_text = "AP %d（AP 不足，转 %d HP）。" % [value, hp_loss]
					messages.append(ap_text)
					_add_cost(costs, ap_text, "ap")
				elif value > 0:
					player.ap_deci += value * 10
					var ap_gain := "AP +%d。" % value
					messages.append(ap_gain)
					_add_reward(rewards, ap_gain, "ap", "本回合可以走得更远")
			"gold":
				player.gold = maxi(0, player.gold + value)
				var gold_text := "金币 %+d。" % value
				messages.append(gold_text)
				if value > 0:
					_add_reward(rewards, gold_text, "gold", "可在商队交易中购买物资")
				elif value < 0:
					_add_cost(costs, gold_text, "gold")
			"hp_relief":
				var cell := GameManager.map.get_cell(player.cell_id) if GameManager.map != null else null
				var has_relief := cell != null and cell.relief_max - cell.relief_min > 0.45
				if value < 0 and has_relief:
					player.take_damage(-value)
					var relief_text := "地形落差使伤害加深：HP %d。" % value
					messages.append(relief_text)
					_add_cost(costs, relief_text, "hp")

	# 2. 死亡检查：MVP 没有第二条命，死亡后终止后续效果。
	if player.hp <= 0:
		death = true
		_pending_death = true
		_pending_death_reason = "你在事件中倒下。"
		player.hp = 0
		messages.append("你倒下了。")
		_add_cost(costs, "你倒下了。", "death")
		return {
			"messages": messages,
			"rewards": rewards,
			"costs": costs,
			"insights": insights,
			"enter_goal": false,
			"knockback": 0,
			"death": true,
		}

	# 3. 物品
	for effect in effects:
		match String(effect.get("type", "")):
			"item_gain":
				var item_id := String(effect.get("item_id", ""))
				var count := int(effect.get("count", 1))
				if item_id.is_empty() and effect.has("choose_from"):
					var choices: Array = effect["choose_from"]
					if not choices.is_empty():
						item_id = String(choices[0])
				if not item_id.is_empty():
					var item_grant := GameManager.grant_item(item_id, count, "事件奖励")
					var item_text := String(item_grant.get(
						"message", "获得 %s ×%d。" % [_item_name(item_id), count]
					))
					messages.append(item_text)
					_add_reward(rewards, item_text, "item", _item_reward_hint(item_id))
			"item_lose":
				_lose_items(effect, messages, costs)

	# 4. 状态
	for effect in effects:
		match String(effect.get("type", "")):
			"status_add":
				var status_id := String(effect.get("status_id", ""))
				var duration := int(effect.get("duration", -999))
				player.add_status(status_id, duration, GameManager.round_index)
				var status_text := "获得状态%s" % _status_detail(status_id)
				messages.append(status_text)
				if _status_is_negative(status_id):
					_add_cost(costs, status_text, "status")
				else:
					_add_reward(rewards, status_text, "status")
			"status_remove":
				if effect.has("status_id"):
					var removed_id := String(effect["status_id"])
					player.remove_status(removed_id)
					var removed_text := "解除状态「%s」。" % _status_name(removed_id)
					messages.append(removed_text)
					_add_reward(rewards, removed_text, "status")
				elif effect.has("any_negative") or String(effect.get("mode", "")) == "any_negative":
					for status_id in player.statuses.keys():
						if String(DataManager.get_record("statuses", status_id).get("category", "")) == "debuff":
							player.remove_status(String(status_id))
							var cleared_text := "解除状态「%s」。" % _status_name(String(status_id))
							messages.append(cleared_text)
							_add_reward(rewards, cleared_text, "status")
							break

	# 5. 标记
	for effect in effects:
		match String(effect.get("type", "")):
			"flag_add":
				var flag_id := String(effect.get("flag_id", ""))
				player.add_flag(flag_id)
				var flag_text := "获得标记「%s」。" % _flag_name(flag_id)
				messages.append(flag_text)
				if _flag_is_negative(flag_id):
					_add_cost(costs, flag_text, "flag")
				elif _flag_is_reward(flag_id):
					_add_reward(rewards, flag_text, "flag", "旅途纪事会记住这次选择")
				else:
					_add_insight(insights, flag_text, "flag", "旅途纪事会记住这次选择")
			"flag_remove":
				var removed_flag := String(effect.get("flag_id", ""))
				player.remove_flag(removed_flag)
				var removed_flag_text := "移除标记「%s」。" % _flag_name(removed_flag)
				messages.append(removed_flag_text)
				_add_reward(rewards, removed_flag_text, "flag")

	# 6. 地图揭示
	for effect in effects:
		if String(effect.get("type", "")) == "reveal":
			_apply_reveal(String(effect.get("kind", "")), int(effect.get("value", 1)), messages, rewards, insights)

	# 7. AI 友好度：关系是双人共同经历的结果，即使同伴不在身边也会变化。
	for effect in effects:
		if String(effect.get("type", "")) == "ai_favor":
			_apply_ai_favor(int(effect.get("value", 0)), messages, rewards, costs)

	# 8. 位置变化
	for effect in effects:
		if String(effect.get("type", "")) == "move":
			if String(effect.get("kind", "")) == "knockback":
				knockback += int(effect.get("value", 0))
			else:
				messages.append("传送效果（P1）。")

	# 9. 事件链 / 特殊效果
	for effect in effects:
		match String(effect.get("type", "")):
			"special":
				_apply_special(String(effect.get("id", "")), messages, rewards, costs, insights)
			"enter_goal":
				enter_goal = true
				player.goal_passed = true
				_pending_goal_victory = true
				messages.append("你通过了终点守卫。")
				_add_reward(rewards, "你通过了终点守卫。", "quest", "本局目标已经完成")

	if knockback > 0:
		GameManager.apply_event_knockback(knockback)
		var knockback_text := "你被击退 %d 格。" % knockback
		messages.append(knockback_text)
		_add_cost(costs, knockback_text, "move")

	return {
		"messages": messages,
		"rewards": rewards,
		"costs": costs,
		"insights": insights,
		"enter_goal": enter_goal,
		"knockback": knockback,
		"death": death,
	}


func _apply_ai_favor(value: int, messages: Array[String], rewards: Array[Dictionary], costs: Array[Dictionary]) -> void:
	if value == 0 or GameManager.companion == null or not GameManager.companion_is_alive():
		return
	var ai_name := GameManager.companion_name()
	var result := GameManager.apply_companion_favor(value)
	if result.is_empty():
		return
	var relation_text := "%s对你的好感 %+d。" % [ai_name, value]
	if _reveal_level < 1:
		relation_text = "你感觉%s对你的态度有些变化。" % ai_name
	messages.append(relation_text)
	if value > 0:
		_add_reward(rewards, relation_text, "relationship", "好感会在同伴状态栏持续显示")
	else:
		_add_cost(costs, relation_text, "relationship", "敌对同伴会抢先抵达终点")
	if bool(result.get("faction_changed", false)):
		var faction_text := "%s看你的眼神变了。" % ai_name
		if _reveal_level >= 2:
			faction_text = "%s的立场转为%s。" % [ai_name, GameManager.companion.faction_name()]
		messages.append(faction_text)
		if String(result.get("faction", "")) == "enemy":
			_add_cost(costs, faction_text, "relationship")
		else:
			_add_reward(rewards, faction_text, "relationship")
	if bool(result.get("milestone", false)):
		var milestone_text := String(result.get("milestone_message", "")).strip_edges()
		if not milestone_text.is_empty():
			messages.append(milestone_text)
			_add_reward(rewards, milestone_text, "relationship", "获得补给 ×1，可在背包（B）中使用")


## 事件对同伴的直接效果：只有同伴在玩家同格或相邻格时才生效。
func _apply_ai_effects(effects: Array) -> Array[String]:
	var messages: Array[String] = []
	if effects.is_empty() or GameManager.companion == null or not GameManager.companion_is_alive():
		return messages
	if not GameManager.companion_at_player(1):
		return messages
	var companion := GameManager.companion
	var actor := companion.actor
	var visible := GameManager.companion_is_visible()
	var ai_name := GameManager.companion_name()
	for effect_value in effects:
		var effect: Dictionary = effect_value
		var effect_type := String(effect.get("type", ""))
		var value := int(effect.get("value", 0))
		match effect_type:
			"hp":
				if value < 0:
					actor.take_damage(-value)
					if visible:
						messages.append("%s也受到了牵连（HP %d）。" % [ai_name, value])
				elif value > 0:
					actor.heal(value)
					if visible:
						messages.append("%s的伤势有所好转（HP +%d）。" % [ai_name, value])
			"ap":
				actor.ap_deci = maxi(0, actor.ap_deci + value * 10)
				if visible and value != 0:
					messages.append("%s的行动点 %+d。" % [ai_name, value])
			"gold":
				actor.gold = maxi(0, actor.gold + value)
				if visible and value != 0:
					messages.append("%s的金币 %+d。" % [ai_name, value])
			"item_gain":
				var item_id := String(effect.get("item_id", ""))
				if item_id.is_empty() and effect.has("choose_from"):
					var choices: Array = effect["choose_from"]
					item_id = companion.choose_event_item(choices, bool(effect.get("ai_task_aware", false)))
				if not item_id.is_empty() and companion.add_event_item(item_id):
					if visible:
						messages.append("%s获得了「%s」。" % [ai_name, _item_name(item_id)])
			"item_lose":
				var lost := companion.remove_random_item()
				if not lost.is_empty() and visible:
					messages.append("%s失去了「%s」。" % [ai_name, _item_name(lost)])
			"status_add":
				var status_id := String(effect.get("status_id", ""))
				var duration := int(effect.get("duration", -999))
				actor.add_status(status_id, duration, GameManager.round_index)
				if visible:
					messages.append("%s获得状态「%s」。" % [ai_name, _status_name(status_id)])
			"status_remove":
				if effect.has("status_id"):
					actor.remove_status(String(effect["status_id"]))
					if visible:
						messages.append("%s移除了状态「%s」。" % [ai_name, _status_name(String(effect["status_id"]))])
			"flag_add":
				actor.add_flag(String(effect.get("flag_id", "")))
			"flag_remove":
				actor.remove_flag(String(effect.get("flag_id", "")))
			"ai_favor":
				var favor_rewards: Array[Dictionary] = []
				var favor_costs: Array[Dictionary] = []
				_apply_ai_favor(value, messages, favor_rewards, favor_costs)
	if actor.hp <= 0:
		GameManager.mark_companion_dead("事件波及")
		messages.append("%s倒在了你身边。" % ai_name)
	return messages


func _lose_items(effect: Dictionary, messages: Array[String], costs: Array[Dictionary]) -> void:
	var player := GameManager.player
	var count := maxi(1, int(effect.get("count", 1)))
	var mode := String(effect.get("mode", "random"))
	var pool: Array[String] = []
	pool.append_array(player.inventory)
	for item_id in player.equipment:
		if not pool.has(item_id):
			pool.append(item_id)
	var candidates: Array[String] = []
	for item_id in pool:
		var record := DataManager.get_record("items", item_id)
		if record.is_empty():
			continue
		if mode == "specific" and item_id != String(effect.get("item_id", "")):
			continue
		if mode == "any_non_quest" and bool(record.get("quest_item", false)):
			continue
		candidates.append(item_id)
	var rng := RNGManager.get_stream("event")
	for _i in range(count):
		if candidates.is_empty():
			var gold := rng.randi_range(1, 6) * 5
			if player.gold > 0:
				var lost := mini(player.gold, gold)
				player.gold -= lost
				var gold_text := "背包已空，改为损失 %d 金币。" % lost
				messages.append(gold_text)
				_add_cost(costs, gold_text, "gold")
			else:
				var hp_loss := rng.randi_range(1, 3)
				player.take_damage(hp_loss)
				var hp_text := "背包与金币皆空，改为损失 %d HP。" % hp_loss
				messages.append(hp_text)
				_add_cost(costs, hp_text, "hp")
			continue
		var index := rng.randi_range(0, candidates.size() - 1)
		var item_id := candidates[index]
		candidates.remove_at(index)
		player.remove_item(item_id, 1)
		var item_text := "失去 %s ×1。" % _item_name(item_id)
		messages.append(item_text)
		_add_cost(costs, item_text, "item")


func _apply_reveal(
	kind: String,
	value: int,
	messages: Array[String],
	rewards: Array[Dictionary],
	insights: Array[Dictionary]
) -> void:
	match kind:
		"nearest_poi":
			var target := _nearest_unexplored_poi()
			if target >= 0:
				_revealed_pois[target] = true
				GameManager.reveal_poi(target)
				_note_insight(messages, insights, "揭示最近的未探索地点（地块 %d）。" % (target + 1), "map")
			else:
				_note_insight(messages, insights, "附近已没有未探索的地点。", "map")
		"goal_direction":
			var direction := _direction_to(GameManager.player.cell_id, GameManager.map.goal_id)
			var distance := GameManager.map.graph_distance(GameManager.player.cell_id, GameManager.map.goal_id)
			_note_insight(messages, insights, "终点在%s方向，约 %d 格。" % [direction, distance], "map")
		"region_direction":
			var region_cell := _nearest_unexplored_region_cell()
			if region_cell >= 0:
				_note_insight(messages, insights, "最近的未探索区域在%s方向。" % _direction_to(GameManager.player.cell_id, region_cell), "map")
			else:
				_note_insight(messages, insights, "周围区域都已被你踏足。", "map")
		"shortcut":
			GameManager.player.add_flag("shortcut_found")
			var shortcut_text := "发现一条捷径（AP 消耗降低 20%，路径揭示在 P1 接入）。"
			messages.append(shortcut_text)
			_add_reward(rewards, shortcut_text, "flag", "旅途纪事会记住这条捷径")
		"ai_faction_clue":
			grant_ai_reveal(maxi(1, value))
			_note_insight(
				messages,
				insights,
				"获得同伴阵营线索 +%d（情报 %d/3，可在同伴栏查看）。" % [maxi(1, value), _reveal_level],
				"intel",
				"同伴状态栏会显示新的情报层级"
			)
		_:
			_note_insight(messages, insights, "获得一条线索。", "intel")


func _apply_special(
	special_id: String,
	messages: Array[String],
	rewards: Array[Dictionary],
	costs: Array[Dictionary],
	insights: Array[Dictionary]
) -> void:
	match special_id:
		"lost_severe":
			GameManager.player.add_status("lost_severe", 1, GameManager.round_index)
			var lost_text := "你彻底迷失了方向。"
			messages.append(lost_text)
			_add_cost(costs, lost_text, "status", "下回合 AP 会减少，可由药水解救")
		"shortcut":
			GameManager.player.add_flag("shortcut_found")
			var shortcut_text := "你记下了一条捷径。"
			messages.append(shortcut_text)
			_add_reward(rewards, shortcut_text, "flag")
		_:
			_note_insight(messages, insights, "特殊效果：%s（P1）。" % special_id, "flag")


func _add_reward(entries: Array[Dictionary], text: String, kind: String, hint: String = "") -> void:
	entries.append({"text": text, "kind": kind, "hint": hint})


func _add_cost(entries: Array[Dictionary], text: String, kind: String, hint: String = "") -> void:
	entries.append({"text": text, "kind": kind, "hint": hint})


func _add_insight(entries: Array[Dictionary], text: String, kind: String, hint: String = "") -> void:
	entries.append({"text": text, "kind": kind, "hint": hint})


func _note_insight(
	messages: Array[String],
	insights: Array[Dictionary],
	text: String,
	kind: String,
	hint: String = "已更新地图或情报标记"
) -> void:
	messages.append(text)
	_add_insight(insights, text, kind, hint)


func _status_is_negative(status_id: String) -> bool:
	var category := String(DataManager.get_record("statuses", status_id).get("category", ""))
	return category == "debuff" or category == "special"


func _flag_is_negative(flag_id: String) -> bool:
	return flag_id == "wanted" or flag_id == "hunted"


func _flag_is_reward(flag_id: String) -> bool:
	return flag_id == "shortcut_found" or flag_id == "goal_revealed" or flag_id == "bandit_ally"


func _item_reward_hint(item_id: String) -> String:
	var record := DataManager.get_record("items", item_id)
	match String(record.get("type", "")):
		"equipment":
			return "可在背包（B）中装备"
		"consumable":
			return "可在背包（B）中直接使用"
		"quest":
			return "任务物品，献祭时不会被消耗"
		_:
			return "可留作交易或任务材料"


func _nearest_unexplored_poi() -> int:
	var map := GameManager.map
	if map == null:
		return -1
	var best := -1
	var best_distance := 999999
	for cell_id in map.poi_ids:
		var cell := map.get_cell(cell_id)
		if cell == null:
			continue
		if _visited_pois.has(cell.poi_id) or _revealed_pois.has(cell_id) or cell.poi_known:
			continue
		var distance := map.graph_distance(GameManager.player.cell_id, cell_id)
		if distance >= 0 and distance < best_distance:
			best_distance = distance
			best = cell_id
	return best


func _nearest_unexplored_region_cell() -> int:
	var map := GameManager.map
	if map == null:
		return -1
	var best := -1
	var best_distance := 999999
	for cell in map.cells:
		var region := _region_of(cell.id)
		if region < 0 or _visited_regions.has(region):
			continue
		var distance := map.graph_distance(GameManager.player.cell_id, cell.id)
		if distance >= 0 and distance < best_distance:
			best_distance = distance
			best = cell.id
	return best


func _direction_to(from_id: int, to_id: int) -> String:
	var map := GameManager.map
	if map == null:
		return ""
	var from := map.cell_center(from_id)
	var to := map.cell_center(to_id)
	var delta := to - from
	var horizontal := "东" if delta.x >= 0.0 else "西"
	var vertical := "南" if delta.y >= 0.0 else "北"
	if absf(delta.x) < absf(delta.y) * 0.4:
		return vertical
	if absf(delta.y) < absf(delta.x) * 0.4:
		return horizontal
	return vertical + horizontal


func _emit_progress(result: Dictionary) -> void:
	event_progress.emit(result)
	GameManager.player_moved.emit()


func _error_result(message: String) -> Dictionary:
	var result := {
		"kind": "error",
		"message": message,
		"effect_messages": [],
		"reward_entries": [],
		"cost_entries": [],
		"insight_entries": [],
	}
	_emit_progress(result)
	return result


func _trait_name(trait_id: String) -> String:
	var record := DataManager.get_record("traits", trait_id)
	return String(record.get("name", trait_id))


func _status_name(status_id: String) -> String:
	return String(DataManager.get_record("statuses", status_id).get("name", status_id))


func _item_name(item_id: String) -> String:
	return String(DataManager.get_record("items", item_id).get("name", item_id))


func _flag_name(flag_id: String) -> String:
	return String(DataManager.get_record("flags", flag_id).get("name", flag_id))


func _log(text: String) -> void:
	_event_log.append(text)
	if _event_log.size() > 80:
		_event_log.remove_at(0)
	log_added.emit(text)
