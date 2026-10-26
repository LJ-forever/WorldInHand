extends Node
## P0 平衡基线统计（headless）。
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path . res://tests/balance_report.tscn -- --runs=10
##
## 工具做三件事：
## 1. 自动探索若干局，统计每局事件数、触发来源（POI / 区域 / 游荡 / 终点）与事件 ID；
## 2. 在每个回合结束后读取同伴的 last_intent，统计 AI 意图分布，并记录自然发生的袭击；
## 3. 用 CombatRules 做单次攻击、反击对比与决斗的蒙特卡洛统计。
##
## 模拟期间关闭 SaveManager 写入，避免覆盖玩家真实的自动存档；结束时恢复。
## 每局固定形状种子与生态种子（fixed_terrain_seed），同一批 --runs 可逐局复现。

const RUNS_DEFAULT := 10
const MAX_ROUNDS_PER_RUN := 40
const ACTIONS_PER_ROUND := 6
const EVENT_TARGET_MIN := 20
const EVENT_TARGET_MAX := 30
const COMBAT_TRIALS_PER_PAIR := 500
const DUEL_TRIALS_PER_PAIR := 120
const PLAYER_IDS := ["lin_xiao", "sha_kai", "wei_la", "ying", "qing_heng"]
const TRIGGER_TARGET_RANGES := {
	# 校准后的诊断区间：POI 数量固定为 10，单局实际只会进入 4～8 个，
	# 因此 POI 份额天然低于区域/游荡；wander 含每回合环境判定。
	"poi": [0.15, 0.25],
	"enter_region": [0.20, 0.32],
	"wander": [0.50, 0.65],
	"goal": [0.0, 0.05],
}
## 总体意图分布只做宽带诊断；真正应达标的是按阵营拆分的任务驱动分布。
## MVP 的两个敌对隐藏任务（偷装备、困住玩家）都是“完成前持续接近玩家”，
## 所以 enemy 的 hunt 基线会到七成左右，不能用普通遭遇战的直觉去卡 50%。
const INTENT_TARGET_RANGES := {
	"support": [0.40, 0.60],
	"hunt": [0.05, 0.15],
	"attack": [0.01, 0.05],
	"explore": [0.0, 0.05],
	"scout": [0.0, 0.05],
	"rest": [0.15, 0.25],
	"goal": [0.10, 0.22],
	"none": [0.0, 0.10],
	"trapped": [0.0, 0.05],
	"dead": [0.0, 0.0],
}
## 隐藏任务决定意图，所以按阵营分别检查：友好偏支援、中立偏休息/争胜、敌对偏追击。
const FACTION_INTENT_TARGET_RANGES := {
	"friendly": {
		"support": [0.50, 0.75],
		"goal": [0.05, 0.20],
		"rest": [0.10, 0.25],
		"explore": [0.0, 0.05],
		"scout": [0.0, 0.05],
		"hunt": [0.0, 0.02],
		"attack": [0.0, 0.02],
	},
	"neutral": {
		"rest": [0.30, 0.60],
		"goal": [0.25, 0.45],
		"explore": [0.05, 0.20],
		"scout": [0.0, 0.05],
		"support": [0.0, 0.05],
		"hunt": [0.0, 0.02],
		"attack": [0.0, 0.02],
	},
	"enemy": {
		"hunt": [0.45, 0.75],
		"goal": [0.10, 0.25],
		"attack": [0.05, 0.15],
		"rest": [0.0, 0.15],
		"support": [0.0, 0.02],
		"explore": [0.0, 0.05],
		"scout": [0.0, 0.05],
	},
}

var _runs: Array[Dictionary] = []
var _current: Dictionary = {}
var _track_events := false
var _game_over_win := false
var _game_over_reason := ""
var _combat_rng := RandomNumberGenerator.new()
var _entered_pois: Dictionary = {}


func _ready() -> void:
	_run_all()


func _run_all() -> void:
	await get_tree().process_frame
	var run_count := _read_int_arg("--runs", RUNS_DEFAULT)
	if run_count < 1:
		run_count = 1
	var save_write_was_enabled := SaveManager.write_enabled
	var combat_interactive_was_enabled := GameManager.combat_interactive
	SaveManager.write_enabled = false
	GameManager.combat_interactive = false
	_combat_rng.seed = 20261026
	if not EventManager.event_started.is_connected(_on_event_started):
		EventManager.event_started.connect(_on_event_started)
	if not GameManager.game_over.is_connected(_on_game_over):
		GameManager.game_over.connect(_on_game_over)
	if not GameManager.cell_entered.is_connected(_on_cell_entered):
		GameManager.cell_entered.connect(_on_cell_entered)
	if not EventManager.event_queued.is_connected(_on_event_queued):
		EventManager.event_queued.connect(_on_event_queued)

	print("=== 平衡基线报告 ===")
	print("自动探索 %d 局，每局最多 %d 回合；模拟期间已关闭存档写入。" % [run_count, MAX_ROUNDS_PER_RUN])
	for i in range(run_count):
		_simulate_run(i, run_count)
	_track_events = false
	var combat := _run_combat_trials()
	var report := _build_report(run_count, combat)

	SaveManager.write_enabled = save_write_was_enabled
	GameManager.combat_interactive = combat_interactive_was_enabled
	_print_report(report)
	_write_report_json(report)
	get_tree().quit()


# ---------------- 自动跑局 ----------------

func _simulate_run(index: int, total: int) -> void:
	_game_over_win = false
	_game_over_reason = ""
	_current = {
		"index": index,
		"player_id": "",
		"rounds": 0,
		"events": 0,
		"trigger_counts": {},
		"queued_trigger_counts": {},
		"event_counts": {},
		"cells_entered": 0,
		"poi_entries": 0,
		"ap_rolled_deci": 0,
		"ap_spent_deci": 0,
		"ai_turns": 0,
		"intents": {},
		"intents_by_faction": {},
		"ai_attacks": 0,
		"ai_attack_hits": 0,
		"ai_attack_damage": 0,
		"ai_attack_hp_cost": 0,
		"ended": "stalled",
		"end_reason": "",
		"start_hp": 0,
		"end_hp": 0,
		"last_event_id": "",
		"last_choice_id": "",
		"last_event_hp_before": 0,
		"last_event_hp_after": 0,
	}
	var player_id := String(PLAYER_IDS[index % PLAYER_IDS.size()])
	_current["player_id"] = player_id

	var config := MapGenerator.DEFAULT_CONFIG.duplicate(true)
	config["name"] = "平衡模拟荒原"
	config["randomize_seed"] = false
	config["seed"] = 20261023 + index * 7919
	## 生态分布默认每局重掷；平衡统计固定它，保证同一批种子可反复对比。
	config["fixed_terrain_seed"] = 20261026 + index * 104729
	config["cell_count"] = 400
	config["poi_count"] = 10
	config["character_ids"] = PLAYER_IDS.duplicate()
	config["event_ids"] = []
	if not GameManager.start_new_game(player_id, config):
		_current["ended"] = "start_failed"
		_runs.append(_current.duplicate(true))
		print("  [%d/%d] %s 无法开局" % [index + 1, total, player_id])
		return
	GameManager.dismiss_intro()
	_current["start_hp"] = GameManager.player.hp
	_current["ap_rolled_deci"] = GameManager.player.ap_max_deci
	_entered_pois.clear()
	_track_events = true

	var guard := 0
	while GameManager.state != GameManager.State.GAME_OVER and guard < MAX_ROUNDS_PER_RUN + 8:
		guard += 1
		if EventManager.is_event_active():
			_auto_resolve_active_event()
		if GameManager.state == GameManager.State.GAME_OVER:
			break
		if GameManager.state == GameManager.State.COMBAT:
			GameManager.close_combat()
		if GameManager.state != GameManager.State.PLAYING:
			break

		if GameManager.player.hp <= int(ceil(GameManager.player.hp_max * 0.5)) \
				and not GameManager.player.rest_used:
			GameManager.rest()
		_maybe_scout()
		_spend_round_ap()
		if EventManager.is_event_active():
			_auto_resolve_active_event()
		if GameManager.state == GameManager.State.GAME_OVER:
			break
		if GameManager.state == GameManager.State.COMBAT:
			GameManager.close_combat()
		if GameManager.state != GameManager.State.PLAYING:
			break

		var round_before := GameManager.round_index
		GameManager.end_turn()
		if GameManager.state != GameManager.State.GAME_OVER:
			_current["ap_rolled_deci"] = int(_current["ap_rolled_deci"]) + GameManager.player.ap_max_deci
		_record_ai_turn()
		if GameManager.state == GameManager.State.COMBAT:
			GameManager.close_combat()
		if GameManager.state == GameManager.State.GAME_OVER:
			break
		if GameManager.round_index <= round_before:
			# 回合没有推进说明状态机被意外卡住，保留样本并结束本局。
			_current["ended"] = "stalled"
			_current["end_reason"] = "回合未推进"
			break

	_current["rounds"] = mini(GameManager.round_index, MAX_ROUNDS_PER_RUN)
	_current["end_hp"] = GameManager.player.hp if GameManager.player != null else 0
	_current["end_reason"] = _game_over_reason
	_current["cap_reached"] = EventManager._random_events_this_run >= EventManager.MAX_RANDOM_EVENTS_PER_RUN
	if _game_over_win:
		_current["ended"] = "win"
	elif GameManager.player != null and GameManager.player.hp <= 0:
		_current["ended"] = "death"
	elif _game_over_reason.contains("回合"):
		_current["ended"] = "timeout"
	elif String(_current["ended"]) == "stalled" and _game_over_reason.is_empty():
		_current["ended"] = "stalled"
	_current["events"] = int(_current["events"])
	_track_events = false
	_runs.append(_current.duplicate(true))
	print("  [%d/%d] %s · %d 回合 · %d 事件 · %d 格 / %d POI · AP %d/%d · %s" % [
		index + 1,
		total,
		player_id,
		int(_current["rounds"]),
		int(_current["events"]),
		int(_current["cells_entered"]),
		int(_current["poi_entries"]),
		int(_current["ap_spent_deci"]) / 10,
		int(_current["ap_rolled_deci"]) / 10,
		_end_kind_text(String(_current["ended"])),
	])
	if String(_current["ended"]) == "death":
		print("      死因：%s" % String(_current["end_reason"]))
		print("      最近事件：%s / 选项 %s · HP %d→%d" % [
			String(_current["last_event_id"]),
			String(_current["last_choice_id"]),
			int(_current["last_event_hp_before"]),
			int(_current["last_event_hp_after"]),
		])


func _on_game_over(win: bool, reason: String) -> void:
	_game_over_win = win
	_game_over_reason = reason
	if _current.is_empty():
		return
	if win:
		_current["ended"] = "win"
	elif GameManager.player != null and GameManager.player.hp <= 0:
		_current["ended"] = "death"
	elif reason.contains("回合"):
		_current["ended"] = "timeout"
	else:
		_current["ended"] = "other"


func _on_cell_entered(cell_id: int, _from_id: int) -> void:
	if not _track_events or _current.is_empty():
		return
	_current["cells_entered"] = int(_current["cells_entered"]) + 1
	var map := GameManager.map
	if map == null:
		return
	var cell := map.get_cell(cell_id)
	if cell == null or cell.poi_id.is_empty() or _entered_pois.has(cell.poi_id):
		return
	_entered_pois[cell.poi_id] = true
	_current["poi_entries"] = int(_current["poi_entries"]) + 1


func _on_event_queued(event_id: String) -> void:
	if not _track_events or _current.is_empty():
		return
	var record := DataManager.get_record("events", event_id)
	var trigger := String(record.get("trigger", ""))
	var queued: Dictionary = _current["queued_trigger_counts"]
	queued[trigger] = int(queued.get(trigger, 0)) + 1


func _on_event_started(event_data: Dictionary) -> void:
	if not _track_events or _current.is_empty():
		return
	var trigger := EventManager.active_trigger
	var event_id := String(event_data.get("id", ""))
	_current["events"] = int(_current["events"]) + 1
	var triggers: Dictionary = _current["trigger_counts"]
	triggers[trigger] = int(triggers.get(trigger, 0)) + 1
	var events: Dictionary = _current["event_counts"]
	events[event_id] = int(events.get(event_id, 0)) + 1


## 半血以下且本回合尚未休息时休息；休息不消耗 AP，是自动玩家最基本的生存策略。
func _maybe_scout() -> void:
	if GameManager.state != GameManager.State.PLAYING or GameManager.is_moving:
		return
	# 侦察是可选的信息投资，会消耗本可用于移动的 AP。
	# 基线玩家只在 AP 充裕时偶尔侦察，避免把低速角色的行动全花在开雾上，
	# 否则测到的不是事件频率，而是“侦察型玩家”的事件频率。
	if GameManager.player.ap_deci < 60:
		return
	if not _known_unentered_poi().is_empty():
		return
	if GameManager.round_index % 5 != 0:
		return
	GameManager.scout()


func _spend_round_ap() -> void:
	var attempts := 0
	while attempts < ACTIONS_PER_ROUND:
		attempts += 1
		if GameManager.state != GameManager.State.PLAYING:
			return
		if GameManager.is_moving or GameManager.movement_paused:
			return
		if GameManager.player == null or GameManager.player.ap_deci <= 0:
			return
		var target := _choose_explore_target()
		if target < 0:
			return
		var stroke := _stroke_to(target)
		if stroke.size() < 2:
			return
		var ap_before := GameManager.player.ap_deci
		if not GameManager.set_drawn_path(stroke):
			return
		if not GameManager.execute_move():
			return
		_settle_movement()
		_current["ap_spent_deci"] = int(_current["ap_spent_deci"]) \
			+ maxi(0, ap_before - GameManager.player.ap_deci)
		if EventManager.is_event_active():
			_auto_resolve_active_event()
		if GameManager.state == GameManager.State.GAME_OVER:
			return
		if GameManager.state != GameManager.State.PLAYING:
			return
		if GameManager.player.ap_deci >= ap_before:
			# 没有消耗 AP 却结束了移动，避免在这里死循环。
			return


## 推进当前路径直到走完、AP 耗尽或被事件打断；事件会立即自动选择并继续。
func _settle_movement() -> void:
	var guard := 0
	while guard < 600:
		guard += 1
		if GameManager.state == GameManager.State.GAME_OVER:
			return
		if EventManager.is_event_active():
			_auto_resolve_active_event()
			if GameManager.state == GameManager.State.GAME_OVER:
				return
			continue
		if not GameManager.is_moving and not GameManager.movement_paused:
			return
		if GameManager.state != GameManager.State.PLAYING:
			return
		var distance_before := GameManager.move_distance
		GameManager.advance_movement(0.25)
		if not GameManager.is_moving and not GameManager.movement_paused:
			return
		if is_equal_approx(distance_before, GameManager.move_distance) \
				and not EventManager.is_event_active() \
				and GameManager.state == GameManager.State.PLAYING:
			return


# ---------------- 自动选择 ----------------

func _auto_resolve_active_event() -> void:
	var guard := 0
	while EventManager.is_event_active() and guard < 16:
		guard += 1
		var choices := EventManager.get_choices()
		var choice_id := _pick_safe_choice(choices)
		if choice_id.is_empty():
			EventManager.finish_event()
			return
		if not _current.is_empty():
			_current["last_event_id"] = EventManager.active_event_id
			_current["last_choice_id"] = choice_id
			_current["last_event_hp_before"] = GameManager.player.hp
		var result := EventManager.choose_choice(choice_id)
		var inner := 0
		while EventManager.is_event_active() and inner < 8:
			inner += 1
			match String(result.get("kind", "")):
				"trade_menu":
					result = EventManager.resolve_trade_offer(-1)
				"steal_menu":
					var steal_items: Array = result.get("items", [])
					if steal_items.is_empty():
						EventManager.finish_event()
						return
					result = EventManager.resolve_steal_item(String(steal_items[0]))
				"sacrifice_menu":
					var sacrifice_items: Array = result.get("items", [])
					if sacrifice_items.is_empty():
						EventManager.finish_event()
						return
					result = EventManager.resolve_sacrifice(String(sacrifice_items[0]))
				"heal_menu":
					result = EventManager.resolve_heal("hp")
				_:
					EventManager.finish_event()
					return
		if not _current.is_empty():
			_current["last_event_hp_after"] = GameManager.player.hp
		if EventManager.is_event_active():
			EventManager.finish_event()
		return


## 生存优先：不选高风险检定；未知风险的非检定选项优先。
## 低血量时额外避开可能当场致死的选项（含 AP 不足转 HP 的部分），
## 但不会因此完全回避所有战斗，避免把自动玩家模拟成无敌的完美决策者。
func _pick_safe_choice(choices: Array) -> String:
	var raw_by_id := {}
	for raw_value in EventManager.active_event.get("choices", []):
		var raw: Dictionary = raw_value
		raw_by_id[String(raw.get("id", ""))] = raw
	var hp := GameManager.player.hp if GameManager.player != null else 1
	var low_hp := GameManager.player != null and hp * 2 <= GameManager.player.hp_max
	var best_id := ""
	var best_rank := 9999
	for value in choices:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var choice: Dictionary = value
		if bool(choice.get("disabled", false)):
			continue
		var risk := String(choice.get("risk", ""))
		var rank := 0
		match risk:
			"低":
				rank = 1
			"中":
				rank = 2
			"高":
				rank = 3
		var raw: Dictionary = raw_by_id.get(String(choice.get("id", "")), {})
		var danger := _choice_worst_damage(raw)
		if danger >= hp:
			# 最坏结果可能直接打死自己：降级为最后手段。
			rank += 100
		elif low_hp:
			# 半血以下优先低伤害选项，让自动玩家更像会看血条的真人。
			rank += danger
		if rank < best_rank:
			best_rank = rank
			best_id = String(choice.get("id", ""))
	return best_id


## 估算失败/大失败下玩家可能承受的 HP 代价；AP 不足会按规则转为 HP。
func _choice_worst_damage(choice: Dictionary) -> int:
	var worst := 0
	for level in ["fail", "great_fail"]:
		var outcome: Dictionary = choice.get("outcomes", {}).get(level, {})
		var loss := 0
		for pool_name in ["effects", "player_effects"]:
			for effect_value in outcome.get(pool_name, []):
				var effect: Dictionary = effect_value
				match String(effect.get("type", "")):
					"hp":
						if int(effect.get("value", 0)) < 0:
							loss += -int(effect["value"])
					"ap":
						var value := int(effect.get("value", 0))
						if value < 0 and GameManager.player != null:
							var need := -value * 10
							var missing := maxi(0, need - GameManager.player.ap_deci)
							loss += int(ceil(float(missing) / 10.0))
					"status_add":
						match String(effect.get("status_id", "")):
							"bleeding", "burned", "poisoned", "trapped":
								loss += 2
		worst = maxi(worst, loss)
	return worst


# ---------------- 探索目标与画线 ----------------

func _known_unentered_poi() -> Array[int]:
	var result: Array[int] = []
	var map := GameManager.map
	if map == null:
		return result
	for cell_id in map.poi_ids:
		var cell := map.get_cell(cell_id)
		if cell == null or cell.entered or not cell.poi_known:
			continue
		result.append(cell_id)
	return result


func _choose_explore_target() -> int:
	var map := GameManager.map
	var player := GameManager.player
	if map == null or player == null:
		return -1
	var known_pois := _known_unentered_poi()
	if not known_pois.is_empty():
		return _nearest_by_graph(known_pois)

	var candidates: Array[int] = []
	for cell in map.cells:
		if cell.id == player.cell_id or cell.id == map.goal_id:
			continue
		if cell.entered:
			continue
		if not cell.seen and not cell.scouted:
			continue
		candidates.append(cell.id)
	if candidates.is_empty():
		candidates = _frontier_candidates()
	if candidates.is_empty():
		return -1

	# 向远离起点的方向探索，并轻微偏好跨地形，模拟玩家主动寻找区域分界。
	var current_terrain := map.terrain_of(player.cell_id)
	var best := -1
	var best_score := -INF
	for cell_id in candidates:
		var to_player := map.graph_distance(player.cell_id, cell_id)
		if to_player < 0:
			continue
		var from_start := maxi(0, map.graph_distance(map.start_id, cell_id))
		var score := float(to_player) + float(from_start) * 0.35 + float((cell_id * 37) % 11) * 0.01
		if map.terrain_of(cell_id) != current_terrain:
			score += 6.0
		if score > best_score:
			best_score = score
			best = cell_id
	return best


func _frontier_candidates() -> Array[int]:
	var result: Array[int] = []
	var map := GameManager.map
	if map == null:
		return result
	for cell in map.cells:
		if cell.entered or cell.id == map.goal_id:
			continue
		for neighbor in cell.neighbors:
			var known_cell := map.get_cell(neighbor)
			if known_cell != null and (known_cell.seen or known_cell.scouted or known_cell.entered):
				result.append(cell.id)
				break
	return result


func _nearest_by_graph(cell_ids: Array[int]) -> int:
	var player := GameManager.player
	var map := GameManager.map
	if player == null or map == null:
		return -1
	var best := -1
	var best_distance := 999999
	for cell_id in cell_ids:
		var distance := map.graph_distance(player.cell_id, cell_id)
		if distance >= 0 and distance < best_distance:
			best_distance = distance
			best = cell_id
	return best


func _stroke_to(target_cell: int) -> PackedVector2Array:
	var map := GameManager.map
	var player := GameManager.player
	var result := PackedVector2Array()
	if map == null or player == null or target_cell < 0:
		return result
	var path := map.shortest_cell_path(player.cell_id, target_cell)
	if path.is_empty() and target_cell != player.cell_id:
		return result
	result.append(GameManager.visual_position)
	for cell_id in path:
		if cell_id == player.cell_id:
			continue
		result.append(map.cell_center(cell_id))
	return result


# ---------------- AI 意图与自然袭击 ----------------

func _record_ai_turn() -> void:
	var companion := GameManager.companion
	if companion == null or companion.actor == null:
		return
	var intent := String(companion.last_intent)
	if intent.is_empty():
		intent = "none"
	var intents: Dictionary = _current["intents"]
	intents[intent] = int(intents.get(intent, 0)) + 1
	var faction := String(companion.faction)
	var by_faction: Dictionary = _current["intents_by_faction"]
	if not by_faction.has(faction):
		by_faction[faction] = {}
	var faction_intents: Dictionary = by_faction[faction]
	faction_intents[intent] = int(faction_intents.get(intent, 0)) + 1
	_current["ai_turns"] = int(_current["ai_turns"]) + 1

	var combat := companion.last_combat
	if combat.is_empty() or not bool(combat.get("ok", false)):
		return
	_current["ai_attacks"] = int(_current["ai_attacks"]) + 1
	var level := String(combat.get("level", ""))
	if level == "success" or level == "great_success":
		_current["ai_attack_hits"] = int(_current["ai_attack_hits"]) + 1
	_current["ai_attack_damage"] = int(_current["ai_attack_damage"]) + int(combat.get("damage", 0))
	_current["ai_attack_hp_cost"] = int(_current["ai_attack_hp_cost"]) \
		+ int(combat.get("attacker_hp_loss", 0)) \
		+ int(combat.get("ap_penalty_hp", 0))


# ---------------- 战斗蒙特卡洛 ----------------

func _run_combat_trials() -> Dictionary:
	var characters := DataManager.all_records("characters")
	var single := {
		"attacks": 0,
		"hit": 0,
		"great": 0,
		"fail": 0,
		"great_fail": 0,
		"damage": 0,
		"attacker_hp_cost": 0,
	}
	var endure := {"trials": 0, "player_hp_loss": 0, "player_deaths": 0}
	var counter := {
		"trials": 0,
		"player_hp_loss": 0,
		"enemy_hp_loss": 0,
		"player_deaths": 0,
	}
	var initiate := {
		"trials": 0,
		"enemy_counters": 0,
		"player_hp_loss": 0,
		"enemy_hp_loss": 0,
		"player_deaths": 0,
	}
	var duel := {
		"duels": 0,
		"player_wins": 0,
		"enemy_wins": 0,
		"draws": 0,
		"player_deaths": 0,
		"attacks": 0,
	}
	var got_pair := false
	for player_record_value in characters:
		var player_record: Dictionary = player_record_value
		for enemy_record_value in characters:
			var enemy_record: Dictionary = enemy_record_value
			if String(player_record.get("id", "")) == String(enemy_record.get("id", "")):
				continue
			got_pair = true
			var player := ActorState.from_character(player_record)
			var enemy := ActorState.from_character(enemy_record)
			_reset_fighter(player)
			_reset_fighter(enemy)
			for _i in range(COMBAT_TRIALS_PER_PAIR):
				_reset_fighter(player)
				_reset_fighter(enemy)
				var result := CombatRules.resolve_attack(enemy, player, _combat_rng)
				if not bool(result.get("ok", false)):
					continue
				single["attacks"] = int(single["attacks"]) + 1
				var level := String(result.get("level", ""))
				if level == "success":
					single["hit"] = int(single["hit"]) + 1
				elif level == "great_success":
					single["hit"] = int(single["hit"]) + 1
					single["great"] = int(single["great"]) + 1
				elif level == "great_fail":
					single["fail"] = int(single["fail"]) + 1
					single["great_fail"] = int(single["great_fail"]) + 1
				else:
					single["fail"] = int(single["fail"]) + 1
				single["damage"] = int(single["damage"]) + int(result.get("damage", 0))
				single["attacker_hp_cost"] = int(single["attacker_hp_cost"]) \
					+ int(result.get("attacker_hp_loss", 0)) \
					+ int(result.get("ap_penalty_hp", 0))

			for _i in range(COMBAT_TRIALS_PER_PAIR):
				_reset_fighter(player)
				_reset_fighter(enemy)
				var hp_before := player.hp
				var ai_attack := CombatRules.resolve_attack(enemy, player, _combat_rng)
				if bool(ai_attack.get("ok", false)):
					endure["trials"] = int(endure["trials"]) + 1
					endure["player_hp_loss"] = int(endure["player_hp_loss"]) + hp_before - maxi(0, player.hp)
					if player.hp <= 0:
						endure["player_deaths"] = int(endure["player_deaths"]) + 1

			for _i in range(COMBAT_TRIALS_PER_PAIR):
				_reset_fighter(player)
				_reset_fighter(enemy)
				var player_hp_before := player.hp
				var enemy_hp_before := enemy.hp
				var ai_attack := CombatRules.resolve_attack(enemy, player, _combat_rng)
				if not bool(ai_attack.get("ok", false)):
					continue
				counter["trials"] = int(counter["trials"]) + 1
				if player.hp > 0 and player.ap_deci >= CombatRules.AP_COST_DECI:
					# AI 的袭击已经用掉它本回合的出手，玩家反击后它不会再顺势打一次。
					CombatRules.resolve_attack(player, enemy, _combat_rng)
				counter["player_hp_loss"] = int(counter["player_hp_loss"]) + player_hp_before - maxi(0, player.hp)
				counter["enemy_hp_loss"] = int(counter["enemy_hp_loss"]) + enemy_hp_before - maxi(0, enemy.hp)
				if player.hp <= 0:
					counter["player_deaths"] = int(counter["player_deaths"]) + 1

			for _i in range(COMBAT_TRIALS_PER_PAIR):
				_reset_fighter(player)
				_reset_fighter(enemy)
				var player_hp_before := player.hp
				var enemy_hp_before := enemy.hp
				var first := CombatRules.resolve_attack(player, enemy, _combat_rng)
				if not bool(first.get("ok", false)):
					continue
				initiate["trials"] = int(initiate["trials"]) + 1
				if enemy.hp > 0 and enemy.ap_deci >= CombatRules.AP_COST_DECI:
					# 玩家先手后，存活且在射程内的敌方同伴会立刻反击。
					initiate["enemy_counters"] = int(initiate["enemy_counters"]) + 1
					CombatRules.resolve_attack(enemy, player, _combat_rng)
				initiate["player_hp_loss"] = int(initiate["player_hp_loss"]) + player_hp_before - maxi(0, player.hp)
				initiate["enemy_hp_loss"] = int(initiate["enemy_hp_loss"]) + enemy_hp_before - maxi(0, enemy.hp)
				if player.hp <= 0:
					initiate["player_deaths"] = int(initiate["player_deaths"]) + 1

			for _i in range(DUEL_TRIALS_PER_PAIR):
				_reset_fighter(player)
				_reset_fighter(enemy)
				var turn_is_player := true
				var attacks := 0
				while player.hp > 0 and enemy.hp > 0 and attacks < 40:
					var attacker := player if turn_is_player else enemy
					var defender := enemy if turn_is_player else player
					if attacker.ap_deci < CombatRules.AP_COST_DECI:
						break
					CombatRules.resolve_attack(attacker, defender, _combat_rng)
					attacks += 1
					turn_is_player = not turn_is_player
				duel["duels"] = int(duel["duels"]) + 1
				duel["attacks"] = int(duel["attacks"]) + attacks
				if player.hp <= 0 and enemy.hp <= 0:
					duel["draws"] = int(duel["draws"]) + 1
				elif player.hp <= 0:
					duel["enemy_wins"] = int(duel["enemy_wins"]) + 1
					duel["player_deaths"] = int(duel["player_deaths"]) + 1
				elif enemy.hp <= 0:
					duel["player_wins"] = int(duel["player_wins"]) + 1
				else:
					duel["draws"] = int(duel["draws"]) + 1
	if not got_pair:
		push_warning("没有可用于战斗模拟的角色对。")
	return {
		"single": single,
		"endure": endure,
		"counter": counter,
		"initiate": initiate,
		"duel": duel,
	}


func _reset_fighter(actor: ActorState) -> void:
	actor.hp = actor.hp_max
	actor.ap_deci = 120
	actor.ap_max_deci = 120
	actor.statuses.clear()
	actor.flags.clear()
	actor.rest_used = false
	actor.goal_passed = false
	actor.pending_ap_penalty_deci = 0


# ---------------- 汇总与输出 ----------------

func _build_report(run_count: int, combat: Dictionary) -> Dictionary:
	var trigger_totals := {}
	var queued_trigger_totals := {}
	var event_totals := {}
	var intent_totals := {}
	var intents_by_faction := {}
	var ended_counts := {}
	var event_counts_per_run: Array[int] = []
	var total_events := 0
	var total_rounds := 0
	var total_ai_turns := 0
	var total_ai_attacks := 0
	var total_ai_hits := 0
	var total_ai_damage := 0
	var total_ai_hp_cost := 0
	var total_cells := 0
	var total_pois := 0
	var total_ap_rolled := 0
	var total_ap_spent := 0
	var death_count := 0
	var win_count := 0
	var timeout_count := 0
	var target_hits := 0
	var hp_delta_total := 0
	var survivor_events := 0
	var survivor_runs := 0
	var capped_runs := 0
	var per_character := {}

	for run_value in _runs:
		var run: Dictionary = run_value
		var events := int(run.get("events", 0))
		event_counts_per_run.append(events)
		total_events += events
		var player_id := String(run.get("player_id", "?"))
		if not per_character.has(player_id):
			per_character[player_id] = {
				"runs": 0,
				"events": 0,
				"deaths": 0,
				"in_range": 0,
				"min_events": 9999,
				"max_events": 0,
			}
		var char_stats: Dictionary = per_character[player_id]
		char_stats["runs"] = int(char_stats["runs"]) + 1
		char_stats["events"] = int(char_stats["events"]) + events
		char_stats["min_events"] = mini(int(char_stats["min_events"]), events)
		char_stats["max_events"] = maxi(int(char_stats["max_events"]), events)
		var in_range := events >= EVENT_TARGET_MIN and events <= EVENT_TARGET_MAX
		if in_range:
			char_stats["in_range"] = int(char_stats["in_range"]) + 1
		var ended := String(run.get("ended", "stalled"))
		if ended != "death":
			survivor_events += events
			survivor_runs += 1
		else:
			char_stats["deaths"] = int(char_stats["deaths"]) + 1
		total_rounds += int(run.get("rounds", 0))
		total_ai_turns += int(run.get("ai_turns", 0))
		total_ai_attacks += int(run.get("ai_attacks", 0))
		total_ai_hits += int(run.get("ai_attack_hits", 0))
		total_ai_damage += int(run.get("ai_attack_damage", 0))
		total_ai_hp_cost += int(run.get("ai_attack_hp_cost", 0))
		total_cells += int(run.get("cells_entered", 0))
		total_pois += int(run.get("poi_entries", 0))
		total_ap_rolled += int(run.get("ap_rolled_deci", 0))
		total_ap_spent += int(run.get("ap_spent_deci", 0))
		hp_delta_total += int(run.get("end_hp", 0)) - int(run.get("start_hp", 0))
		if events >= EVENT_TARGET_MIN and events <= EVENT_TARGET_MAX:
			target_hits += 1
		if bool(run.get("cap_reached", false)):
			capped_runs += 1
		ended_counts[ended] = int(ended_counts.get(ended, 0)) + 1
		if ended == "death":
			death_count += 1
		elif ended == "win":
			win_count += 1
		elif ended == "timeout":
			timeout_count += 1
		_merge_counts(trigger_totals, run.get("trigger_counts", {}))
		_merge_counts(queued_trigger_totals, run.get("queued_trigger_counts", {}))
		_merge_counts(event_totals, run.get("event_counts", {}))
		_merge_counts(intent_totals, run.get("intents", {}))
		var by_faction: Dictionary = run.get("intents_by_faction", {})
		for faction_key in by_faction.keys():
			var faction := String(faction_key)
			if not intents_by_faction.has(faction):
				intents_by_faction[faction] = {}
			_merge_counts(intents_by_faction[faction], by_faction[faction_key])

	var event_average := float(total_events) / maxf(1.0, float(run_count))
	var sorted_events := event_counts_per_run.duplicate()
	sorted_events.sort()
	var median_events := 0.0
	if not sorted_events.is_empty():
		var middle := sorted_events.size() / 2
		if sorted_events.size() % 2 == 1:
			median_events = float(sorted_events[middle])
		else:
			median_events = (float(sorted_events[middle - 1]) + float(sorted_events[middle])) * 0.5
	var below_target := 0
	var above_target := 0
	for value in event_counts_per_run:
		if value < EVENT_TARGET_MIN:
			below_target += 1
		elif value > EVENT_TARGET_MAX:
			above_target += 1
	return {
		"generated_at": Time.get_datetime_string_from_system(false, true),
		"runs_requested": run_count,
		"runs_completed": _runs.size(),
		"run_details": _runs.duplicate(true),
		"rounds": total_rounds,
		"events": total_events,
		"events_per_run": event_average,
		"cells_entered": total_cells,
		"poi_entries": total_pois,
		"ap_rolled_deci": total_ap_rolled,
		"ap_spent_deci": total_ap_spent,
		"event_counts_per_run": event_counts_per_run,
		"median_events_per_run": median_events,
		"below_target": below_target,
		"above_target": above_target,
		"capped_runs": capped_runs,
		"target_events": [EVENT_TARGET_MIN, EVENT_TARGET_MAX],
		"target_hits": target_hits,
		"survivor_runs": survivor_runs,
		"survivor_events_per_run": float(survivor_events) / maxf(1.0, float(survivor_runs)),
		"per_character": per_character,
		"trigger_totals": trigger_totals,
		"queued_trigger_totals": queued_trigger_totals,
		"event_totals": event_totals,
		"intent_totals": intent_totals,
		"intents_by_faction": intents_by_faction,
		"ai_turns": total_ai_turns,
		"ai_attacks": total_ai_attacks,
		"ai_attack_hits": total_ai_hits,
		"ai_attack_damage": total_ai_damage,
		"ai_attack_hp_cost": total_ai_hp_cost,
		"hp_delta_total": hp_delta_total,
		"ended_counts": ended_counts,
		"deaths": death_count,
		"wins": win_count,
		"timeouts": timeout_count,
		"combat": combat,
	}


func _merge_counts(target: Dictionary, source) -> void:
	if typeof(source) != TYPE_DICTIONARY:
		return
	for key in source.keys():
		var clean := String(key)
		target[clean] = int(target.get(clean, 0)) + int(source[key])


func _print_report(report: Dictionary) -> void:
	print("")
	print("--- 每局事件数 ---")
	var per_run: Array = report.get("event_counts_per_run", [])
	print("  %s" % str(per_run))
	print("  平均 %.1f 事件/局；中位数 %.1f；落在 %d–%d 区间的局数：%d/%d" % [
		float(report.get("events_per_run", 0.0)),
		float(report.get("median_events_per_run", 0.0)),
		EVENT_TARGET_MIN,
		EVENT_TARGET_MAX,
		int(report.get("target_hits", 0)),
		int(report.get("runs_requested", 0)),
	])
	print("  分布：低于 %d 的 %d 局 · 区间内 %d 局 · 高于 %d 的 %d 局 · 触达单局上限 %d 局" % [
		EVENT_TARGET_MIN,
		int(report.get("below_target", 0)),
		int(report.get("target_hits", 0)),
		EVENT_TARGET_MAX,
		int(report.get("above_target", 0)),
		int(report.get("capped_runs", 0)),
	])
	print("  存活局（%d 局）平均 %.1f 事件/局；死亡局按实际回合截断" % [
		int(report.get("survivor_runs", 0)),
		float(report.get("survivor_events_per_run", 0.0)),
	])
	var per_character: Dictionary = report.get("per_character", {})
	for character_id in per_character.keys():
		var stats: Dictionary = per_character[character_id]
		print("    %s：%d 局 · 平均 %.1f 事件 · 范围 %d–%d · 达标 %d/%d · 死亡 %d" % [
			String(character_id),
			int(stats.get("runs", 0)),
			float(stats.get("events", 0)) / maxf(1.0, float(stats.get("runs", 1))),
			int(stats.get("min_events", 0)),
			int(stats.get("max_events", 0)),
			int(stats.get("in_range", 0)),
			int(stats.get("runs", 0)),
			int(stats.get("deaths", 0)),
		])
	print("  移动：%d 格 / %d 个 POI；AP 消耗 %d / 掷出 %d（%.0f%%）" % [
		int(report.get("cells_entered", 0)),
		int(report.get("poi_entries", 0)),
		int(report.get("ap_spent_deci", 0)) / 10,
		int(report.get("ap_rolled_deci", 0)) / 10,
		100.0 * float(report.get("ap_spent_deci", 0)) / maxf(1.0, float(report.get("ap_rolled_deci", 0))),
	])
	print("  事件密度：每 %.2f AP 一次事件；每 %.2f 格一次事件" % [
		float(report.get("ap_spent_deci", 0)) / maxf(1.0, float(report.get("events", 0))) / 10.0,
		float(report.get("cells_entered", 0)) / maxf(1.0, float(report.get("events", 0))),
	])
	var ended: Dictionary = report.get("ended_counts", {})
	print("  结局：死亡 %d · 胜利 %d · 超时 %d · 其他 %d" % [
		int(report.get("deaths", 0)),
		int(report.get("wins", 0)),
		int(report.get("timeouts", 0)),
		int(report.get("runs_completed", 0)) - int(report.get("deaths", 0)) \
			- int(report.get("wins", 0)) - int(report.get("timeouts", 0)),
	])
	if not ended.is_empty():
		var parts: Array[String] = []
		for key in ended.keys():
			parts.append("%s=%d" % [_end_kind_text(String(key)), int(ended[key])])
		print("  结局明细：%s" % "，".join(parts))

	print("")
	print("--- 事件触发来源 ---")
	_print_share_line(report.get("trigger_totals", {}), int(report.get("events", 0)), TRIGGER_TARGET_RANGES)
	var queued: Dictionary = report.get("queued_trigger_totals", {})
	var queued_total := 0
	for key in queued.keys():
		queued_total += int(queued[key])
	print("  入队/开始：%d / %d（%.0f%% 的入队事件最终开始）" % [
		queued_total,
		int(report.get("events", 0)),
		100.0 * float(report.get("events", 0)) / maxf(1.0, float(queued_total)),
	])
	print("--- 事件 ID ---")
	_print_counts(report.get("event_totals", {}))

	print("")
	print("--- AI 意图 ---")
	_print_share_line(report.get("intent_totals", {}), int(report.get("ai_turns", 0)), INTENT_TARGET_RANGES, "intent")
	var by_faction: Dictionary = report.get("intents_by_faction", {})
	for faction_key in ["friendly", "neutral", "enemy"]:
		if not by_faction.has(faction_key):
			continue
		var faction_counts: Dictionary = by_faction[faction_key]
		var faction_total := 0
		for key in faction_counts.keys():
			faction_total += int(faction_counts[key])
		print("  [%s] 总 %d 次（按阵营任务检查）" % [faction_key, faction_total])
		_print_intent_counts(faction_counts, "    ", FACTION_INTENT_TARGET_RANGES.get(faction_key, {}))
	var ai_turns := int(report.get("ai_turns", 0))
	var ai_attacks := int(report.get("ai_attacks", 0))
	var ai_hits := int(report.get("ai_attack_hits", 0))
	print("  自然袭击：%d 次 / %d 回合（%.2f%% 回合），命中 %d 次（%.1f%%），累计伤害 %d，袭击者 HP 代价 %d" % [
		ai_attacks,
		ai_turns,
		100.0 * float(ai_attacks) / maxf(1.0, float(ai_turns)),
		ai_hits,
		100.0 * float(ai_hits) / maxf(1.0, float(ai_attacks)),
		int(report.get("ai_attack_damage", 0)),
		int(report.get("ai_attack_hp_cost", 0)),
	])
	var bandit_events := int(report.get("event_totals", {}).get("bandit_ambush", 0))
	print("  战斗接触：AI 袭击 %.2f 次/局；马匪伏击 %.2f 次/局（事件检定，不走战斗规则）" % [
		float(ai_attacks) / maxf(1.0, float(report.get("runs_requested", 1))),
		float(bandit_events) / maxf(1.0, float(report.get("runs_requested", 1))),
	])

	print("")
	print("--- 战斗蒙特卡洛 ---")
	var combat: Dictionary = report.get("combat", {})
	var single: Dictionary = combat.get("single", {})
	var attacks := int(single.get("attacks", 0))
	if attacks > 0:
		print("  单次攻击：%d 次 · 命中 %.1f%%（大成功 %.1f%%）· 失败 %.1f%%（大失败 %.1f%%）" % [
			attacks,
			100.0 * float(single.get("hit", 0)) / float(attacks),
			100.0 * float(single.get("great", 0)) / float(attacks),
			100.0 * float(single.get("fail", 0)) / float(attacks),
			100.0 * float(single.get("great_fail", 0)) / float(attacks),
		])
		print("  每次攻击平均伤害 %.2f；袭击者平均 HP 代价 %.3f" % [
			float(single.get("damage", 0)) / float(attacks),
			float(single.get("attacker_hp_cost", 0)) / float(attacks),
		])
	var endure: Dictionary = combat.get("endure", {})
	var counter: Dictionary = combat.get("counter", {})
	if int(endure.get("trials", 0)) > 0:
		print("  不反击：样本 %d · 玩家平均损失 %.2f HP · 当场死亡 %.1f%%" % [
			int(endure.get("trials", 0)),
			float(endure.get("player_hp_loss", 0)) / float(endure.get("trials", 1)),
			100.0 * float(endure.get("player_deaths", 0)) / float(endure.get("trials", 1)),
		])
	if int(counter.get("trials", 0)) > 0:
		print("  被袭后反击：样本 %d · 玩家平均净损失 %.2f HP · 对敌平均伤害 %.2f · 当场死亡 %.1f%%" % [
			int(counter.get("trials", 0)),
			float(counter.get("player_hp_loss", 0)) / float(counter.get("trials", 1)),
			float(counter.get("enemy_hp_loss", 0)) / float(counter.get("trials", 1)),
			100.0 * float(counter.get("player_deaths", 0)) / float(counter.get("trials", 1)),
		])
	var initiate: Dictionary = combat.get("initiate", {})
	if int(initiate.get("trials", 0)) > 0:
		print("  玩家先手：样本 %d · 敌方反击率 %.1f%% · 玩家平均净损失 %.2f HP · 对敌平均伤害 %.2f · 当场死亡 %.1f%%" % [
			int(initiate.get("trials", 0)),
			100.0 * float(initiate.get("enemy_counters", 0)) / float(initiate.get("trials", 1)),
			float(initiate.get("player_hp_loss", 0)) / float(initiate.get("trials", 1)),
			float(initiate.get("enemy_hp_loss", 0)) / float(initiate.get("trials", 1)),
			100.0 * float(initiate.get("player_deaths", 0)) / float(initiate.get("trials", 1)),
		])
	var duel: Dictionary = combat.get("duel", {})
	if int(duel.get("duels", 0)) > 0:
		print("  决斗：%d 场 · 玩家胜 %.1f%% · 敌方胜 %.1f%% · 未分胜负 %.1f%% · 平均 %.1f 次出手" % [
			int(duel.get("duels", 0)),
			100.0 * float(duel.get("player_wins", 0)) / float(duel.get("duels", 1)),
			100.0 * float(duel.get("enemy_wins", 0)) / float(duel.get("duels", 1)),
			100.0 * float(duel.get("draws", 0)) / float(duel.get("duels", 1)),
			float(duel.get("attacks", 0)) / float(duel.get("duels", 1)),
		])


func _print_share_line(counts: Dictionary, total: int, targets: Dictionary, label_mode: String = "trigger") -> void:
	if counts.is_empty():
		print("  （无样本）")
		return
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		var count := int(counts[key])
		var share := float(count) / maxf(1.0, float(total))
		var label := _trigger_text(String(key)) if label_mode == "trigger" else _intent_text(String(key))
		print("  %s：%d（%.1f%%）%s" % [label, count, share * 100.0, _target_text(targets, String(key), share)])


func _print_intent_counts(counts: Dictionary, prefix: String, targets: Dictionary) -> void:
	var total := 0
	for key in counts.keys():
		total += int(counts[key])
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		var count := int(counts[key])
		var share := float(count) / maxf(1.0, float(total))
		print("%s%s：%d（%.1f%%）%s" % [
			prefix,
			_intent_text(String(key)),
			count,
			share * 100.0,
			_target_text(targets, String(key), share),
		])


func _target_text(targets: Dictionary, key: String, share: float) -> String:
	if not targets.has(key):
		return ""
	var range_value: Array = targets[key]
	var low := float(range_value[0])
	var high := float(range_value[1])
	if share < low:
		return "  目标 %.0f–%.0f%% · 偏低" % [low * 100.0, high * 100.0]
	if share > high:
		return "  目标 %.0f–%.0f%% · 偏高" % [low * 100.0, high * 100.0]
	return "  目标 %.0f–%.0f%% · 达标" % [low * 100.0, high * 100.0]


func _intent_text(intent: String) -> String:
	match intent:
		"support":
			return "支援"
		"hunt":
			return "追击"
		"attack":
			return "袭击"
		"explore":
			return "探索"
		"scout":
			return "侦察"
		"rest":
			return "休息"
		"goal":
			return "前往终点"
		"none":
			return "无行动"
		"trapped":
			return "被困"
		"dead":
			return "已死亡"
		_:
			return intent


func _print_counts(counts: Dictionary, prefix: String = "  ") -> void:
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		print("%s%s：%d" % [prefix, _event_text(String(key)), int(counts[key])])


func _trigger_text(trigger: String) -> String:
	match trigger:
		"poi":
			return "POI 首次进入"
		"enter_region":
			return "跨区域"
		"wander":
			return "AP 游荡"
		"goal":
			return "终点守卫"
		_:
			return trigger if not trigger.is_empty() else "未知"


func _event_text(event_id: String) -> String:
	var record := DataManager.get_record("events", event_id)
	if record.is_empty():
		return event_id
	return "%s（%s）" % [event_id, String(record.get("name", event_id))]


func _end_kind_text(kind: String) -> String:
	match kind:
		"death":
			return "死亡"
		"win":
			return "胜利"
		"timeout":
			return "超时"
		"stalled":
			return "卡住"
		"start_failed":
			return "开局失败"
		_:
			return "其他"


func _write_report_json(report: Dictionary) -> void:
	var path := "user://balance_report.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("无法写入平衡报告：%s" % path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("")
	print("完整 JSON：%s" % ProjectSettings.globalize_path(path))


func _read_int_arg(name: String, fallback: int) -> int:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	for i in range(args.size()):
		var arg := String(args[i])
		if arg == name and i + 1 < args.size():
			return int(String(args[i + 1]))
		if arg.begins_with(name + "="):
			return int(arg.trim_prefix(name + "="))
	return fallback