class_name CompanionAI
extends RefCounted
## AI 队友的单回合决策器。
##
## 设计目标：
## - 队友不是“跟着玩家走的挂件”，而是有自己的隐藏任务、立场和行程；
## - 行为由 hidden_tasks.json 的 completion.type 与 behavior 驱动；
## - 离开玩家视野后仍继续行动，玩家只能通过最后已知位置、传闻与情报等级拼出她的动向；
## - 与玩家同处或相邻时会发生援助、偷窃、下套等真实互动；
## - 所有随机都走 RNGManager 的 "ai" 流，便于同种子复现。

const MAX_MOVES_PER_TURN := 6
const MAX_ITEM_SLOTS := 3
const INTERACT_RANGE := 1
## 支援型同伴愿意独立行动、但仍保持可支援距离的上限（BFS 格数）。
const SUPPORT_NEAR_DISTANCE := 3
const TRAP_STATUS_ID := "trapped"
const HELPFUL_ITEMS := ["herb", "supply", "potion"]
const TRADABLE_ITEMS := ["pelt", "herb", "ancient_coin", "rare_charm"]

var actor: ActorState = null
var task_id: String = ""
var task: Dictionary = {}
var faction: String = "neutral"
var favor: int = 0
var alive: bool = true
var reached_goal: bool = false
var goal_round: int = 0
## 通过终点守卫瞬间的阵营快照；之后转敌对也不追溯计入抢先。
var faction_at_goal: String = ""
var activity: String = "观察四周"
var last_action: String = ""
## 最近一次同伴开口说的话。HUD 的同伴状态栏会直接显示，让她不再沉默。
var last_speech: String = ""
## 最近一次同伴攻击的检定明细；供战斗面板与测试读取。
var last_combat: Dictionary = {}
## 最近一次 AI 回合选择的意图；供平衡统计与调试读取，不写入存档。
var last_intent: String = ""
var last_known_cell: int = -1
var last_known_round: int = 0
var ever_seen: bool = false
var turns_taken: int = 0
## 玩家至少中过一次毒，用于 qing_no_poison_death 的 AI 侧记录。
var player_ever_poisoned: bool = false

var visited_pois: Dictionary = {}
## 一次性好感里程碑，避免读档或反复触发时重复发奖。
var favor_milestones: Dictionary = {}
var _scout_count: int = 0
var _task_completed: bool = false
var _just_completed: bool = false
var _support_cooldown: int = 0
var _hostile_cooldown: int = 0
var _goal_cooldown: int = 0
var _trap_used: bool = false
var _shared_cooldown: int = 0
var _turn_notes: Array[String] = []
var _rng: RandomNumberGenerator = null
var _last_combat: Dictionary = {}
var _just_reached_goal: bool = false
var _faction_at_start: String = "neutral"
var _favor_at_start: int = 0


func setup(character_record: Dictionary, hidden_task_id: String, start_cell: int, rng: RandomNumberGenerator) -> bool:
	if character_record.is_empty():
		return false
	_rng = rng if rng != null else RNGManager.get_stream("ai")
	actor = ActorState.from_character(character_record)
	if actor == null:
		return false
	actor.cell_id = start_cell
	task_id = hidden_task_id
	task = DataManager.get_record("hidden_tasks", hidden_task_id)
	if not task.is_empty():
		faction = String(task.get("initial_faction", "neutral"))
		favor = _roll_initial_favor()
	else:
		faction = "neutral"
		favor = 0
	activity = _initial_activity()
	last_action = "与玩家在同一片荒原上分开出发。"
	match faction:
		"friendly":
			last_speech = "终点见。路上小心。"
		"enemy":
			last_speech = "终点见。别挡我的路。"
		_:
			last_speech = "终点见。别死在半路上。"
	return true


func _roll_initial_favor() -> int:
	var band = task.get("initial_favor", [0, 0])
	if typeof(band) != TYPE_ARRAY or (band as Array).size() < 2:
		return 0
	var values: Array = band
	var low := int(values[0])
	var high := int(values[1])
	if low > high:
		var swap := low
		low = high
		high = swap
	return _rng.randi_range(low, high)


func _initial_activity() -> String:
	match _task_type():
		"steal_equipment":
			return "留意你的行囊"
		"player_trapped_at_window":
			return "寻找落单的时机"
		"share_herb_to_player":
			return "沿途寻找草药"
		"player_alive_at_goal", "player_poisoned_and_survived":
			return "留意你的伤势"
		"favor_at_goal":
			return "寻找交谈的机会"
		"hold_tradable_quest_item_at_goal":
			return "搜寻值钱的货物"
		"reveal_regions_before_goal", "reveal_goal_first":
			return "辨认远处的地形"
		_:
			return "观察四周"


## 同伴的完整运行时快照。隐藏任务本体不重复保存，读档时按 task_id
## 重新读取 hidden_tasks.json，避免旧任务数据覆盖当前平衡版本。
func to_dict() -> Dictionary:
	var pois := {}
	for poi_id in visited_pois.keys():
		pois[str(int(poi_id))] = true
	return {
		"actor": actor.to_dict() if actor != null else {},
		"task_id": task_id,
		"faction": faction,
		"favor": favor,
		"alive": alive,
		"reached_goal": reached_goal,
		"goal_round": goal_round,
		"faction_at_goal": faction_at_goal,
		"activity": activity,
		"last_action": last_action,
		"last_speech": last_speech,
		"last_combat": last_combat.duplicate(true),
		"last_known_cell": last_known_cell,
		"last_known_round": last_known_round,
		"ever_seen": ever_seen,
		"turns_taken": turns_taken,
		"player_ever_poisoned": player_ever_poisoned,
		"visited_pois": pois,
		"favor_milestones": favor_milestones.duplicate(true),
		"scout_count": _scout_count,
		"task_completed": _task_completed,
		"just_completed": _just_completed,
		"support_cooldown": _support_cooldown,
		"hostile_cooldown": _hostile_cooldown,
		"goal_cooldown": _goal_cooldown,
		"trap_used": _trap_used,
		"shared_cooldown": _shared_cooldown,
		"turn_notes": _turn_notes.duplicate(),
		"last_combat_private": _last_combat.duplicate(true),
		"just_reached_goal": _just_reached_goal,
		"faction_at_start": _faction_at_start,
		"favor_at_start": _favor_at_start,
	}


func load_dict(data: Dictionary) -> bool:
	var actor_data = data.get("actor", {})
	if not (actor_data is Dictionary) or (actor_data as Dictionary).is_empty():
		return false
	actor = ActorState.from_dict(actor_data)
	task_id = String(data.get("task_id", ""))
	task = DataManager.get_record("hidden_tasks", task_id).duplicate(true)
	faction = String(data.get("faction", "neutral"))
	favor = int(data.get("favor", 0))
	alive = bool(data.get("alive", true))
	reached_goal = bool(data.get("reached_goal", false))
	goal_round = int(data.get("goal_round", 0))
	faction_at_goal = String(data.get("faction_at_goal", ""))
	activity = String(data.get("activity", "观察四周"))
	last_action = String(data.get("last_action", ""))
	last_speech = String(data.get("last_speech", ""))
	last_known_cell = int(data.get("last_known_cell", -1))
	last_known_round = int(data.get("last_known_round", 0))
	ever_seen = bool(data.get("ever_seen", false))
	turns_taken = int(data.get("turns_taken", 0))
	player_ever_poisoned = bool(data.get("player_ever_poisoned", false))
	visited_pois.clear()
	var pois = data.get("visited_pois", {})
	if pois is Dictionary:
		for poi_id in pois.keys():
			visited_pois[int(poi_id)] = true
	favor_milestones.clear()
	var milestones = data.get("favor_milestones", {})
	if milestones is Dictionary:
		for milestone_id in milestones.keys():
			favor_milestones[String(milestone_id)] = bool(milestones[milestone_id])
	_scout_count = int(data.get("scout_count", 0))
	_task_completed = bool(data.get("task_completed", false))
	_just_completed = bool(data.get("just_completed", false))
	_support_cooldown = int(data.get("support_cooldown", 0))
	_hostile_cooldown = int(data.get("hostile_cooldown", 0))
	_goal_cooldown = int(data.get("goal_cooldown", 0))
	_trap_used = bool(data.get("trap_used", false))
	_shared_cooldown = int(data.get("shared_cooldown", 0))
	_turn_notes.clear()
	for note in data.get("turn_notes", []):
		_turn_notes.append(String(note))
	var last_combat_data = data.get("last_combat", {})
	last_combat = last_combat_data.duplicate(true) if last_combat_data is Dictionary else {}
	var private_combat_data = data.get("last_combat_private", {})
	_last_combat = private_combat_data.duplicate(true) if private_combat_data is Dictionary else {}
	_just_reached_goal = bool(data.get("just_reached_goal", false))
	_faction_at_start = String(data.get("faction_at_start", "neutral"))
	_favor_at_start = int(data.get("favor_at_start", 0))
	_rng = RNGManager.get_stream("ai")
	return true


## 执行一个 AI 回合。返回给 GameManager 的结构：
## messages 可见行动、rumor 不可见时的环境传闻、shared_reveal 友方共享记忆、
## reached_goal / died / task_completed / favor_changed / faction_changed 等事件。
func take_turn(map: MapData, player: ActorState, current_round: int, player_can_see: bool, goal_race: bool = false) -> Dictionary:
	last_intent = ""
	var report := {
		"messages": [],
		"rumor": "",
		"shared_reveal": {},
		"reached_goal": false,
		"died": false,
		"task_completed": false,
		"favor_changed": false,
		"faction_changed": false,
		"visible_start": player_can_see,
		"visible_end": player_can_see,
		"intent": "",
		"combat": {},
	}
	if not alive or actor == null or map == null or player == null:
		return report
	_turn_notes.clear()
	_last_combat = {}
	_just_completed = false
	_just_reached_goal = false
	_faction_at_start = faction
	_favor_at_start = favor
	_support_cooldown = maxi(0, _support_cooldown - 1)
	_hostile_cooldown = maxi(0, _hostile_cooldown - 1)
	_goal_cooldown = maxi(0, _goal_cooldown - 1)
	_shared_cooldown = maxi(0, _shared_cooldown - 1)
	turns_taken += 1
	if player.has_status("poisoned"):
		player_ever_poisoned = true

	_roll_ap(map)
	var status_report := actor.apply_round_status_effects(current_round)
	var expired: Array[String] = actor.tick_status_durations(current_round)
	if int(status_report.get("hp_lost", 0)) > 0:
		_turn_notes.append("%s的伤势在恶化（-%d HP）。" % [_name(), int(status_report["hp_lost"])])
	if not expired.is_empty() and player_can_see:
		var names: Array[String] = []
		for status_id in expired:
			names.append(String(DataManager.get_record("statuses", status_id).get("name", status_id)))
		_turn_notes.append("%s身上的「%s」消退了。" % [_name(), "、".join(names)])
	if actor.hp <= 0:
		_die(report, "伤重不治")
		return _finish_report(report, map, player_can_see)

	_use_survival_item(current_round)
	if actor.hp <= 0:
		_die(report, "伤重不治")
		return _finish_report(report, map, player_can_see)

	var blocked := _try_escape_trap(map, current_round)
	if not blocked:
		# 玩家抵达终点时给同伴一次“同回合冲刺”机会；此时只赶路，不再袭击玩家。
		var intent := "goal" if goal_race else _choose_intent(map, player)
		report["intent"] = intent
		match intent:
			"support":
				_do_support(map, player, current_round)
			"hunt":
				_do_hunt(map, player, current_round)
			"attack":
				_do_attack(map, player, current_round)
			"explore":
				_do_explore(map, player, current_round)
			"scout":
				_do_scout(map, player)
			"rest":
				_do_rest()
			_:
				_do_goal(map, player, current_round)

	# 友方队友会周期性共享沿途记忆；不扩大玩家圆视野，只留下“曾获得信息”的地块。
	if alive and faction == "friendly" and _shared_cooldown <= 0:
		var radius := float(actor.scout_reveal_radius()) * map.average_site_spacing
		report["shared_reveal"] = {
			"center": actor.cell_id,
			"radius": radius,
			"label": "%s与你分享了沿途观察的地形。" % _name(),
		}
		_shared_cooldown = 2
		activity = "向你示意地形" if activity.is_empty() else "%s · 向你示意地形" % activity

	if alive:
		_update_scout_task(map, player)
		last_speech = _pick_speech(String(report.get("intent", "")), player)
		report["speech"] = last_speech
	return _finish_report(report, map, player_can_see)


func _finish_report(report: Dictionary, map: MapData, was_visible: bool) -> Dictionary:
	last_intent = String(report.get("intent", ""))
	if last_intent.is_empty():
		if not alive:
			last_intent = "dead"
		elif actor != null and actor.has_status("trapped"):
			last_intent = "trapped"
		else:
			last_intent = "none"
	var end_visible := alive and _point_visible(map, actor.cell_id)
	report["visible_end"] = end_visible
	var visible := was_visible or end_visible
	var messages: Array[String] = []
	if visible:
		messages.append_array(_turn_notes)
		if not last_action.is_empty():
			messages.append(last_action)
	report["messages"] = messages
	if not visible:
		report["rumor"] = _offscreen_rumor()
	if not alive:
		report["died"] = true
	report["task_completed"] = _just_completed
	report["reached_goal"] = _just_reached_goal
	report["combat"] = _last_combat.duplicate(true)
	last_combat = _last_combat.duplicate(true)
	report["speech"] = last_speech
	report["favor_changed"] = favor != _favor_at_start
	report["faction_changed"] = faction != _faction_at_start
	report["faction_before"] = _faction_at_start
	report["faction"] = faction
	report["favor"] = favor
	return report


## 同伴每回合至少说一句话，按意图、阵营和当前处境选择短句。
## 内容只用于氛围与关系反馈，不携带隐藏数值。
func _pick_speech(intent: String, player: ActorState = null) -> String:
	var options: Array[String] = []
	if player != null and player.has_status("trapped"):
		match faction:
			"friendly":
				options = ["别硬挣，越挣越紧。", "稳住，我看看绳结。", "先别动，我来想办法。"]
			"enemy":
				options = ["你就在那儿待着吧。", "省点力气，路还长。", "这绳结打得不错。"]
			_:
				options = ["别乱动，绳结会咬人。", "这地方不适合挣扎。"]
	elif player != null and player.hp * 3 <= player.hp_max:
		match faction:
			"friendly":
				options = ["你脸色不对，先停下。", "伤口又裂了？我看看。", "别逞强，命比终点重要。"]
			"enemy":
				options = ["你撑不到终点的。", "血的味道会引来别的东西。", "现在求我还来得及。"]
			_:
				options = ["你走得太急了。", "先处理伤口，别把命丢在这儿。"]
	elif player != null and player.has_status("poisoned") and faction == "friendly":
		options = ["毒性还没退，别再碰生水。", "我这儿还有药，撑住。"]
	else:
		match faction:
			"enemy":
				match intent:
					"attack":
						options = ["别怪我。", "把东西留下，你可以活着走。", "现在收手还来得及。"]
					"hunt":
						options = ["你走你的，我走我的。", "别回头。", "我们最好别离得太近。"]
					"goal":
						options = ["烽火台不会等人。", "我先走一步。", "希望你别死在半路。"]
					_:
						options = ["风向不对。", "这地方埋着东西。", "别指望我替你挡刀。"]
			"friendly":
				match intent:
					"support":
						options = ["我替你看着这边。", "别走太快，前面有动静。", "你专心看路，背后交给我。"]
					"scout":
						options = ["我去高处看一眼。", "这片地形我记下了。", "前面像是有水。"]
					"explore":
						options = ["我去附近翻翻，很快回来。", "这边有东西，等我一下。", "别跟丢我。"]
					"goal":
						options = ["烽火台就在前面。", "再快一点，天黑前赶到。", "我先去前面探路。"]
					"rest":
						options = ["先喘口气。", "歇一会儿，我守着。", "伤口处理好了再走。"]
					_:
						options = ["我还在。", "脚步放轻些。", "别担心我。"]
			_:
				match intent:
					"scout":
						options = ["前面雾很重，我看看再说。", "风向变了，可能有水。", "别急着走。"]
					"explore":
						options = ["我去那边看看。", "这地方不太对劲，别跟丢。", "各走各的，终点见。"]
					"goal":
						options = ["烽火台不会等人。", "我先走一步。", "终点见。"]
					"support":
						options = ["不必谢我。", "只是顺路。", "别误会，我也有自己的事。"]
					_:
						options = ["荒原比人诚实。", "留神脚下。", "我们只是同路。"]
	if options.is_empty():
		options = ["留神。"]
	var pick := options[_rng.randi_range(0, options.size() - 1)]
	# 避免连续两回合说同一句。
	if options.size() > 1 and pick == last_speech:
		var index := options.find(pick)
		pick = options[(index + 1) % options.size()]
	return pick


func _roll_ap(map: MapData) -> void:
	var total := _rng.randi_range(1, 6) + actor.speed() \
		+ actor.equipment_ap_bonus(map.terrain_of(actor.cell_id))
	actor.ap_deci = mini(total, 12) * 10
	actor.ap_max_deci = actor.ap_deci
	var penalty := actor.apply_ap_penalties()
	if int(penalty.get("hp_lost", 0)) > 0:
		_turn_notes.append("%s因体力透支损失了 %d HP。" % [_name(), int(penalty["hp_lost"])])


func _use_survival_item(current_round: int) -> void:
	if actor.has_status("poisoned") and actor.has_item("potion"):
		actor.remove_item("potion", 1)
		actor.remove_status("poisoned")
		_turn_notes.append("%s喝下药水，压住了毒性。" % _name())
		return
	if actor.hp * 2 <= actor.hp_max and actor.has_item("supply"):
		actor.remove_item("supply", 1)
		actor.heal(2)
		_turn_notes.append("%s用补给处理了伤口（+2 HP）。" % _name())


## 被困时先尝试挣脱；成功返回 false 继续行动，失败返回 true 跳过主动作。
func _try_escape_trap(map: MapData, current_round: int) -> bool:
	if not actor.status_blocks_movement():
		return false
	if actor.has_status(TRAP_STATUS_ID):
		var roll := _roll_2d6() + actor.attribute_base("stamina") + actor.status_check_modifier("stamina")
		if roll >= 10:
			actor.remove_status(TRAP_STATUS_ID)
			_turn_notes.append("%s割断绳套，挣脱了束缚。" % _name())
			return false
		activity = "被困在原地"
		last_action = "%s试着挣脱绳套，但没有成功。" % _name()
		return true
	activity = "受状态所困"
	last_action = "%s暂时无法行动。" % _name()
	return true


func _choose_intent(map: MapData, player: ActorState) -> String:
	if actor.hp * 3 <= actor.hp_max and not actor.has_item("supply") and not actor.has_item("potion"):
		return "rest"
	var task_type := _task_type()
	match faction:
		"friendly":
			match task_type:
				"share_herb_to_player", "player_alive_at_goal", "player_poisoned_and_survived", "favor_at_goal":
					return "support"
				"reveal_regions_before_goal":
					# 友好同伴的地图任务也先回到可交流距离，再在玩家附近侦察；
					# 否则她会从开局位置一直站着，玩家既看不到她移动，也听不见台词。
					if not _task_completed and map.graph_distance(actor.cell_id, player.cell_id) > SUPPORT_NEAR_DISTANCE:
						return "support"
					return "scout" if not _task_completed else "goal"
				"hold_tradable_quest_item_at_goal":
					return "goal" if _has_tradable() else "explore"
				_:
					return "goal"
		"enemy":
			# 敌方优先完成互斥任务；任务了结或目标不在手边时，靠近并袭击玩家。
			if (task_type == "steal_equipment" or task_type == "player_trapped_at_window") \
					and not _task_completed:
				return "hunt"
			var distance := map.graph_distance(actor.cell_id, player.cell_id)
			if distance >= 0 and distance <= INTERACT_RANGE and _can_attack():
				return "attack"
			if favor <= -3 and actor.hp * 2 > actor.hp_max and distance >= 0 and distance <= 4:
				return "hunt"
			return "goal"
		_:
			match task_type:
				"reveal_goal_first":
					if not _task_completed and map.graph_distance(actor.cell_id, map.goal_id) <= 4:
						return "scout"
					return "goal"
				"reach_goal_first":
					return "goal"
				_:
					return "explore"


func _do_support(map: MapData, player: ActorState, current_round: int) -> void:
	var distance := map.graph_distance(actor.cell_id, player.cell_id)
	if distance < 0:
		_do_goal(map, player, current_round)
		return
	if distance <= INTERACT_RANGE:
		if _interact_support(player, current_round):
			return
		_support_fallback(map, player, current_round)
		return

	# 支援不是“永远跟着玩家”，但离得太远时必须先缩短距离；
	# 否则玩家既看不见她的移动，也不可能听见她说话。
	var task_type := _task_type()
	if task_type == "share_herb_to_player" and not actor.has_item("herb"):
		_do_explore(map, player, current_round)
		activity = "寻找草药"
		last_action = "%s在路边的草丛间停下，翻找可用的草药。" % _name()
		return
	if task_type == "player_poisoned_and_survived":
		if player.has_status("poisoned") and actor.has_item("potion"):
			_approach_to_support(map, player, current_round, "赶来替你解毒")
			return
		if not actor.has_item("potion"):
			_do_explore(map, player, current_round)
			activity = "寻找解药"
			last_action = "%s在废墟间翻找药草与药瓶。" % _name()
			return
	if task_type == "favor_at_goal":
		_approach_to_support(map, player, current_round, "想和你聊聊")
		return

	var urgent := player.has_status("poisoned") or player.hp * 2 <= player.hp_max
	# 远处（>3 格）先靠近；进入可支援范围后才独立侦察/搜集，避免“原地不动”。
	if urgent or distance > SUPPORT_NEAR_DISTANCE:
		_approach_to_support(map, player, current_round, "向你靠拢")
		return
	_support_fallback(map, player, current_round)


func _approach_to_support(map: MapData, player: ActorState, current_round: int, reason: String) -> void:
	_approach(map, player.cell_id)
	activity = reason
	last_action = "%s加快脚步，向你这边靠拢。" % _name()
	if map.graph_distance(actor.cell_id, player.cell_id) <= INTERACT_RANGE:
		if not _interact_support(player, current_round):
			activity = reason


## 支援型任务没有具体事情可做时，不要傻站着。
## 去侦察、找物资或望风，让玩家在状态栏里看到她真的在行动。
func _support_fallback(map: MapData, player: ActorState, current_round: int) -> void:
	var task_type := _task_type()
	if not _task_completed and (task_type == "reveal_regions_before_goal" or task_type == "reveal_goal_first"):
		_do_scout(map, player)
		return
	if not _task_completed and task_type == "hold_tradable_quest_item_at_goal" and not _has_tradable():
		_do_explore(map, player, current_round)
		return
	match turns_taken % 3:
		0:
			_do_scout(map, player)
		1:
			_do_explore(map, player, current_round)
		_:
			if actor.ap_deci >= 10:
				actor.ap_deci -= 10
			activity = "替你望风"
			last_action = "%s退开半步，替你盯着来路。" % _name()


func _do_hunt(map: MapData, player: ActorState, current_round: int) -> void:
	var distance := map.graph_distance(actor.cell_id, player.cell_id)
	if distance < 0:
		_do_goal(map, player, current_round)
		return
	if distance <= INTERACT_RANGE:
		_interact_hostile(map, player, current_round)
		return
	_approach(map, player.cell_id)
	activity = "远远跟着你"
	last_action = "%s沿着你的方向移动，若即若离。" % _name()
	if map.graph_distance(actor.cell_id, player.cell_id) <= INTERACT_RANGE:
		_interact_hostile(map, player, current_round)


func _do_attack(map: MapData, player: ActorState, current_round: int) -> void:
	var distance := map.graph_distance(actor.cell_id, player.cell_id)
	if distance < 0:
		_do_goal(map, player, current_round)
		return
	if distance <= INTERACT_RANGE:
		_attack_player(player, current_round)
		return
	_approach(map, player.cell_id)
	activity = "逼近你"
	last_action = "%s压低身形，朝你逼近。" % _name()
	if map.graph_distance(actor.cell_id, player.cell_id) <= INTERACT_RANGE:
		_attack_player(player, current_round)


func _can_attack() -> bool:
	return faction == "enemy" and alive and actor != null and actor.ap_deci >= CombatRules.AP_COST_DECI \
		and _hostile_cooldown <= 0


func _attack_player(player: ActorState, _current_round: int) -> void:
	if not _can_attack():
		activity = "寻找破绽"
		last_action = "%s在你身侧游走，却没有立刻出手。" % _name()
		return
	var result := CombatRules.resolve_attack(actor, player, _rng)
	_hostile_cooldown = 2
	_last_combat = result.duplicate(true)
	_last_combat["source"] = "companion"
	_last_combat["target"] = "player"
	_last_combat["attacker_name"] = _name()
	_last_combat["defender_name"] = player.display_name
	_last_combat["lines"] = CombatRules.describe_attack(result, _name(), player.display_name)
	if not bool(result.get("ok", false)):
		activity = "迟疑了一瞬"
		last_action = "%s握紧了武器，却没有出手。" % _name()
		return
	if int(result.get("damage", 0)) > 0:
		activity = "对你出手"
		last_action = "%s突然挥动武器袭来，你受了 %d 点伤。" % [_name(), int(result.get("damage", 0))]
	else:
		activity = "试探你的防线"
		last_action = "%s挥出一击，被你侧身避开。" % _name()


func _do_explore(map: MapData, player: ActorState, current_round: int) -> void:
	var target := _nearest_unvisited_poi(map)
	if target < 0 or (_task_type() == "hold_tradable_quest_item_at_goal" and _has_tradable()):
		_do_goal(map, player, current_round)
		return
	_approach(map, target, false)
	activity = "搜寻沿途物资"
	last_action = "%s离开大路，去查看附近的地点。" % _name()


func _do_scout(map: MapData, player: ActorState) -> void:
	# 侦察消耗 1 AP，不移动；为任务累计一次“独立侦察”。
	if actor.ap_deci >= 10:
		actor.ap_deci -= 10
	_scout_count += 1
	activity = "辨认地形"
	last_action = "%s停下脚步，仔细辨认周围的地形。" % _name()
	if _task_type() == "reveal_regions_before_goal":
		var target_count := int(task.get("completion", {}).get("count", 3))
		if _scout_count >= target_count:
			_complete_task()
			last_action = "%s收起地图，像是记全了终点前的路。" % _name()
	elif _task_type() == "reveal_goal_first":
		var goal_distance := map.graph_distance(actor.cell_id, map.goal_id)
		if goal_distance >= 0 and goal_distance <= 4:
			_complete_task()
			last_action = "%s远远望见了终点，却没有对你说什么。" % _name()


func _do_rest() -> void:
	if actor.rest_used:
		activity = "在背风处歇脚"
		last_action = "%s靠着石块闭目养神。" % _name()
		return
	actor.rest_used = true
	actor.heal(1)
	activity = "休整"
	last_action = "%s在背风处歇了一会儿（+1 HP）。" % _name()


func _do_goal(map: MapData, player: ActorState, current_round: int) -> void:
	if actor.cell_id == map.goal_id:
		_attempt_goal(map, player, current_round)
		return
	var path := map.shortest_cell_path(actor.cell_id, map.goal_id)
	if path.is_empty():
		activity = "寻找通往终点的路"
		last_action = "%s在原地辨认通往终点的方向。" % _name()
		return
	var moved := _follow_path(map, path, MAX_MOVES_PER_TURN)
	activity = "向终点推进"
	if moved > 0:
		last_action = "%s朝终点方向移动了 %d 格。" % [_name(), moved]
	else:
		last_action = "%s停下观察前方的路。" % _name()
	if actor.cell_id == map.goal_id:
		_attempt_goal(map, player, current_round)


func _attempt_goal(map: MapData, player: ActorState, current_round: int) -> void:
	if _goal_cooldown > 0:
		activity = "在终点外围观望"
		last_action = "%s停在终点外围，没有贸然靠近。" % _name()
		return
	if actor.status_blocks_goal():
		activity = "被挡在终点外"
		last_action = "某种力量把%s挡在终点之外。" % _name()
		return
	var roll := _roll_2d6() + actor.combat() + actor.equipment_check_bonus("combat")
	if roll >= 14:
		reached_goal = true
		goal_round = current_round
		faction_at_goal = faction
		_just_reached_goal = true
		activity = "已抵达终点"
		last_action = "%s通过了终点守卫，先你一步抵达。" % _name()
		_goal_cooldown = 99
		match _task_type():
			"reach_goal_first":
				_complete_task()
			"hold_tradable_quest_item_at_goal":
				if _has_tradable():
					_complete_task()
			_:
				pass
		return
	actor.take_damage(2)
	_goal_cooldown = 2
	var neighbors := map.neighbors_of(map.goal_id)
	if not neighbors.is_empty():
		actor.cell_id = neighbors[_rng.randi_range(0, neighbors.size() - 1)]
	activity = "被守卫击退"
	last_action = "%s尝试通过终点，被守卫击退了（-2 HP）。" % _name()
	if actor.hp <= 0:
		alive = false
		activity = "倒在终点前"


func _approach(map: MapData, target_cell: int, stop_adjacent: bool = true) -> int:
	var path := map.shortest_cell_path(actor.cell_id, target_cell)
	if path.is_empty():
		return 0
	# 援助/敌对互动停在相邻格，避免与玩家完全重叠；探索则直接踏入地点。
	if stop_adjacent and path.size() >= 2:
		path = path.slice(0, path.size() - 1)
	return _follow_path(map, path, MAX_MOVES_PER_TURN)


func _follow_path(map: MapData, path: Array[int], max_steps: int) -> int:
	var moved := 0
	for cell_id_value in path:
		if moved >= max_steps:
			break
		var next_id := int(cell_id_value)
		var cost := map.move_cost_deci(actor.cell_id, next_id, actor)
		if actor.ap_deci < cost:
			break
		actor.ap_deci -= cost
		actor.cell_id = next_id
		moved += 1
		_collect_poi(map, next_id)
	return moved


func _collect_poi(map: MapData, cell_id: int) -> void:
	if not map.poi_ids.has(cell_id) or visited_pois.has(cell_id):
		return
	visited_pois[cell_id] = true
	var item_id := _loot_for_cell(map.get_cell(cell_id))
	if item_id.is_empty():
		return
	if not _add_item(item_id):
		return
	_turn_notes.append("%s在%s找到了%s。" % [
		_name(),
		map.terrain_display_name(map.terrain_of(cell_id)),
		_str_item_name(item_id),
	])


func _loot_for_cell(cell: MapData.Cell) -> String:
	if cell == null:
		return ""
	if _task_type() == "share_herb_to_player" and not actor.has_item("herb"):
		return "herb"
	if _task_type() == "hold_tradable_quest_item_at_goal":
		for item_id in TRADABLE_ITEMS:
			if not actor.has_item(item_id):
				return item_id
	match cell.terrain:
		"forest", "swamp", "grassland":
			return "herb"
		"desert", "gobi":
			return "ancient_coin"
		"mountain", "hills", "tundra":
			return "pelt"
		_:
			return "pelt" if _rng.randf() < 0.7 else "herb"


func _interact_support(player: ActorState, current_round: int) -> bool:
	var task_type := _task_type()
	if task_type == "share_herb_to_player" and actor.has_item("herb"):
		actor.remove_item("herb", 1)
		player.add_item("herb", 1)
		_change_favor(1)
		_complete_task()
		activity = "把草药递给你"
		last_action = "%s把一株还带着露水的草药塞进你手里。" % _name()
		return true
	if task_type == "player_poisoned_and_survived" and player.has_status("poisoned") \
			and actor.has_item("potion") and _support_cooldown <= 0:
		actor.remove_item("potion", 1)
		player.remove_status("poisoned")
		_change_favor(1)
		_support_cooldown = 2
		activity = "替你解毒"
		last_action = "%s掰开药水瓶塞，替你压下了毒性。" % _name()
		return true
	if task_type == "player_alive_at_goal" and player.hp < player.hp_max \
			and actor.has_item("supply") and _support_cooldown <= 0:
		actor.remove_item("supply", 1)
		player.heal(2)
		_change_favor(1)
		_support_cooldown = 2
		activity = "替你包扎"
		last_action = "%s替你处理了伤口（+2 HP）。" % _name()
		return true
	if task_type == "favor_at_goal" and _support_cooldown <= 0:
		_change_favor(1)
		_support_cooldown = 3
		activity = "与你交谈"
		last_action = "%s和你并肩走了一段，聊起各自的来路。" % _name()
		return true
	if player.hp < player.hp_max and actor.has_item("supply") and _support_cooldown <= 0:
		actor.remove_item("supply", 1)
		player.heal(1)
		_change_favor(1)
		_support_cooldown = 2
		activity = "分你一份补给"
		last_action = "%s把半份补给推到你面前（+1 HP）。" % _name()
		return true
	return false


func _interact_hostile(map: MapData, player: ActorState, current_round: int) -> void:
	if _hostile_cooldown > 0 or actor.ap_deci < 10:
		activity = "观察你的破绽"
		last_action = "%s不远不近地跟着，目光落在你的行囊上。" % _name()
		return
	if _task_type() == "steal_equipment" and not _task_completed:
		_try_steal(player)
		return
	if _task_type() == "player_trapped_at_window" and not _task_completed:
		_try_trap(player, current_round)
		return
	if faction == "enemy":
		_attack_player(player, current_round)
		return
	activity = "保持距离"
	last_action = "%s在几步外停下，没有靠近。" % _name()


func _try_steal(player: ActorState) -> void:
	actor.ap_deci = maxi(0, actor.ap_deci - 10)
	_hostile_cooldown = 3
	var roll := _roll_2d6() + actor.luck() + actor.equipment_check_bonus("luck")
	var dc := 10 + player.perception() + player.status_check_modifier("perception")
	if roll < dc:
		_change_favor(-1)
		activity = "若无其事地走开"
		last_action = "你察觉到%s的手伸向行囊，及时避开了。" % _name()
		return
	var candidates: Array[String] = []
	for item_id in player.equipment:
		var record := DataManager.get_record("items", item_id)
		if not record.is_empty() and not bool(record.get("quest_item", false)):
			candidates.append(item_id)
	if candidates.is_empty():
		for item_id in player.inventory:
			var record := DataManager.get_record("items", item_id)
			if not record.is_empty() and not bool(record.get("quest_item", false)):
				candidates.append(item_id)
	if candidates.is_empty():
		_change_favor(-1)
		activity = "无功而返"
		last_action = "%s摸了半天，只摸到你空荡荡的行囊。" % _name()
		return
	var stolen := candidates[_rng.randi_range(0, candidates.size() - 1)]
	player.remove_item(stolen, 1)
	_add_item(stolen)
	_change_favor(-5)
	_complete_task()
	activity = "揣走了你的东西"
	last_action = "%s借着擦肩而过的机会，拿走了你的「%s」。" % [_name(), _str_item_name(stolen)]


func _try_trap(player: ActorState, current_round: int) -> void:
	if _trap_used:
		activity = "等待下一个时机"
		last_action = "%s看了你一眼，把手里的一段绳子收了起来。" % _name()
		return
	actor.ap_deci = maxi(0, actor.ap_deci - 10)
	_hostile_cooldown = 4
	var roll := _roll_2d6() + maxi(actor.combat(), actor.negotiation())
	var dc := 8 + player.perception() + player.status_check_modifier("perception")
	if roll < dc:
		_change_favor(-1)
		activity = "收起绳套"
		last_action = "你听见脚边有细绳绷紧的声音，%s若无其事地移开了视线。" % _name()
		return
	_trap_used = true
	player.add_status(TRAP_STATUS_ID, 2, current_round)
	_change_favor(-5)
	_complete_task()
	activity = "退到一旁"
	last_action = "%s在你前头布下的绳套骤然收紧，你被困住了。" % _name()


func _add_item(item_id: String) -> bool:
	if item_id.is_empty():
		return false
	while actor.inventory.size() >= MAX_ITEM_SLOTS:
		var dropped := false
		for i in range(actor.inventory.size()):
			var inventory_id := actor.inventory[i]
			var record := DataManager.get_record("items", inventory_id)
			if not bool(record.get("quest_item", false)) and not HELPFUL_ITEMS.has(inventory_id):
				actor.inventory.remove_at(i)
				dropped = true
				break
		if not dropped:
			return false
	actor.add_item(item_id, 1)
	return true


## EventManager 用：按 AI 任务偏好从 choose_from 中挑选物品。
func choose_event_item(choices: Array, task_aware: bool) -> String:
	var pool: Array[String] = []
	for value in choices:
		pool.append(String(value))
	if pool.is_empty():
		return ""
	if task_aware and _task_type() == "hold_tradable_quest_item_at_goal":
		var item_ids: Array = task.get("completion", {}).get("item_ids", TRADABLE_ITEMS)
		for item_id_value in item_ids:
			var item_id := String(item_id_value)
			if pool.has(item_id) and not actor.has_item(item_id):
				return item_id
	return pool[_rng.randi_range(0, pool.size() - 1)]


func add_event_item(item_id: String) -> bool:
	return _add_item(item_id)


func remove_random_item() -> String:
	var candidates: Array[String] = []
	for item_id in actor.inventory:
		var record := DataManager.get_record("items", item_id)
		if not bool(record.get("quest_item", false)):
			candidates.append(item_id)
	if candidates.is_empty():
		return ""
	var item_id := candidates[_rng.randi_range(0, candidates.size() - 1)]
	actor.remove_item(item_id, 1)
	return item_id


func change_favor(delta: int) -> Dictionary:
	return _change_favor(delta)


func _change_favor(delta: int) -> Dictionary:
	var before_faction := faction
	var before_favor := favor
	favor = clampi(favor + delta, -5, 5)
	faction = _faction_from_favor()
	return {
		"delta": delta,
		"favor": favor,
		"favor_changed": favor != before_favor,
		"faction": faction,
		"faction_changed": faction != before_faction,
	}


func _faction_from_favor() -> String:
	if favor >= 2:
		return "friendly"
	if favor <= -2:
		return "enemy"
	return "neutral"


## 不暴露精确数值时也能看到的关系层级。情报 3 级仍会额外显示具体好感。
func bond_label() -> String:
	if favor >= 4:
		return "信赖"
	if favor >= 2:
		return "亲近"
	if favor >= 0:
		return "谨慎"
	if favor >= -1:
		return "冷淡"
	return "敌意"


## 好感达到 4 时的一次性回馈：她主动把一份补给交给玩家。
func check_favor_milestone() -> Dictionary:
	if favor < 4 or bool(favor_milestones.get("trust_supply", false)):
		return {}
	favor_milestones["trust_supply"] = true
	return {
		"triggered": true,
		"id": "trust_supply",
		"gift_item": "supply",
		"message": "%s把一份补给塞进你手里：「拿着，别倒在半路。」" % (actor.display_name if actor != null else "同伴"),
	}


func accept_player_goal(player: ActorState, player_trapped: bool) -> bool:
	## 玩家抵达终点时结算 AI 侧的“观察型”任务。返回是否首次完成。
	if not alive:
		return false
	var was_completed := _task_completed
	match _task_type():
		"player_alive_at_goal":
			if player.hp > 0:
				_complete_task()
		"favor_at_goal":
			if favor >= int(task.get("completion", {}).get("min", 3)):
				_complete_task()
		"player_poisoned_and_survived":
			if player_ever_poisoned and player.hp > 0:
				_complete_task()
		"player_trapped_at_window":
			if player_trapped:
				_complete_task()
		_:
			return false
	return _task_completed and not was_completed


func _update_scout_task(map: MapData, player: ActorState) -> void:
	if _task_type() == "reveal_goal_first" and player.cell_id == map.goal_id:
		return
	if _task_type() == "reach_goal_first" and reached_goal:
		_complete_task()


func _complete_task() -> void:
	if _task_completed:
		return
	_task_completed = true
	_just_completed = true


func _die(report: Dictionary, reason: String) -> void:
	alive = false
	activity = "倒下"
	last_action = "%s倒下了。" % _name()
	report["died"] = true
	report["death_reason"] = reason


func _name() -> String:
	if actor != null and not actor.display_name.is_empty():
		return actor.display_name
	return "同伴"


func _task_type() -> String:
	var completion: Dictionary = task.get("completion", {})
	return String(completion.get("type", ""))


func _has_tradable() -> bool:
	var completion: Dictionary = task.get("completion", {})
	var item_ids: Array = completion.get("item_ids", TRADABLE_ITEMS)
	for item_id_value in item_ids:
		if actor != null and actor.has_item(String(item_id_value)):
			return true
	return false


func _nearest_unvisited_poi(map: MapData) -> int:
	var best := -1
	var best_distance := 999999
	for cell_id in map.poi_ids:
		if visited_pois.has(cell_id):
			continue
		var distance := map.graph_distance(actor.cell_id, cell_id)
		if distance >= 0 and distance < best_distance:
			best_distance = distance
			best = cell_id
	return best


func _point_visible(map: MapData, cell_id: int) -> bool:
	if map == null or cell_id < 0 or cell_id >= map.cells.size():
		return false
	return map.is_point_in_current_vision(map.cell_center(cell_id))


func _roll_2d6() -> int:
	return _rng.randi_range(1, 6) + _rng.randi_range(1, 6)


func _str_item_name(item_id: String) -> String:
	return String(DataManager.get_record("items", item_id).get("name", item_id))


func _offscreen_rumor() -> String:
	if _rng.randf() > 0.45:
		return ""
	var options := [
		"远处传来树枝折断的轻响，很快又归于安静。",
		"你看见一群飞鸟从林梢惊起，朝相反的方向散去。",
		"风里夹着一丝若有若无的脚步声，不像是你的。",
		"远处的草丛晃了一下，等你再看时已经恢复原样。",
	]
	return options[_rng.randi_range(0, options.size() - 1)]


func faction_name() -> String:
	match faction:
		"friendly":
			return "友好"
		"enemy":
			return "敌对"
		_:
			return "中立"


func task_progress_text() -> String:
	if task.is_empty():
		return "没有明显的个人目标"
	var completion: Dictionary = task.get("completion", {})
	var task_type := String(completion.get("type", ""))
	if _task_completed:
		return "已经了结了自己的心事"
	match task_type:
		"reveal_regions_before_goal":
			return "正在记录终点前的区域（%d/%d）" % [_scout_count, int(completion.get("count", 3))]
		"reveal_goal_first":
			return "似乎想抢先看清终点"
		"reach_goal_first":
			return "正赶向终点"
		"steal_equipment":
			return "对你的装备格外在意"
		"player_trapped_at_window":
			return "在等待你落单"
		"share_herb_to_player":
			return "正在寻找草药"
		"player_alive_at_goal", "player_poisoned_and_survived":
			return "在留意你的安危"
		"favor_at_goal":
			return "想和你多聊几句"
		"hold_tradable_quest_item_at_goal":
			return "在搜寻能带走的货物"
		_:
			return String(task.get("behavior", "按自己的打算行动"))


func condition_text() -> String:
	if actor == null:
		return "—"
	if not alive or actor.hp <= 0:
		return "已经倒下"
	var ratio := float(actor.hp) / maxf(float(actor.hp_max), 1.0)
	if ratio > 0.7:
		return "状态良好"
	if ratio > 0.4:
		return "带着伤"
	return "步履蹒跚"
