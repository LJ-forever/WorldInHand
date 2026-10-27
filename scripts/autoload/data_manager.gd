extends Node
## 数据层：加载 res://data/ 下的 JSON，提供按 ID 查询，并在启动时做引用完整性自检。
## 不包含任何玩法逻辑。字段定义见 docs/数据Schema.md。

const DATA_FILES := {
	"characters": "res://data/characters.json",
	"items": "res://data/items.json",
	"statuses": "res://data/statuses.json",
	"flags": "res://data/flags.json",
	"terrains": "res://data/terrains.json",
	"hidden_tasks": "res://data/hidden_tasks.json",
	"events": "res://data/events/events.json",
	"landmarks": "res://data/landmarks.json",
}

const ATTRIBUTES := ["speed", "stamina", "perception", "luck", "combat", "negotiation"]
const EVENT_TRIGGERS := ["poi", "enter_region", "wander", "goal", "facility"]
const EVENT_RESOLUTIONS := ["check", "trade", "steal", "item_sacrifice", "heal_choice", "inn"]
const EVENT_EFFECT_TYPES := [
	"hp", "hp_relief", "ap", "gold", "item_gain", "item_lose",
	"status_add", "status_remove", "flag_add", "flag_remove", "reveal",
	"ai_favor", "move", "enter_goal", "goal_guard_suppress", "special",
]
const OUTCOME_LEVELS := ["great_success", "success", "fail", "great_fail"]

var _tables: Dictionary = {}
var load_errors: Array[String] = []


func _ready() -> void:
	reload()


func reload() -> void:
	_tables.clear()
	load_errors.clear()
	for table_name in DATA_FILES.keys():
		_load_table(String(table_name), String(DATA_FILES[table_name]))
	_validate_references()
	if load_errors.is_empty():
		print("[DataManager] 自检通过：", summary())
	else:
		for message in load_errors:
			push_warning("[DataManager] " + message)


func _load_table(table_name: String, path: String) -> void:
	if not FileAccess.file_exists(path):
		load_errors.append("%s：文件不存在" % path)
		return
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		load_errors.append("%s：读取失败或为空" % path)
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		load_errors.append("%s：JSON 解析失败" % path)
		return
	if not parsed.has(table_name):
		load_errors.append("%s：缺少顶层字段 \"%s\"" % [path, table_name])
		return
	var rows = parsed[table_name]
	if typeof(rows) != TYPE_ARRAY:
		load_errors.append("%s：字段 \"%s\" 应为数组" % [path, table_name])
		return
	var table_data: Dictionary = {}
	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			load_errors.append("%s：存在非对象记录" % path)
			continue
		var record_id := String(row.get("id", ""))
		if record_id.is_empty():
			load_errors.append("%s：记录缺少 id" % path)
			continue
		if table_data.has(record_id):
			load_errors.append("%s：重复 id \"%s\"" % [path, record_id])
			continue
		table_data[record_id] = row
	_tables[table_name] = table_data


func summary() -> String:
	var parts := PackedStringArray()
	for table_name in _tables.keys():
		var rows: Dictionary = _tables[table_name]
		parts.append("%s=%d" % [table_name, rows.size()])
	return ", ".join(parts)


func table(table_name: String) -> Dictionary:
	var value = _tables.get(table_name, null)
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return value


func get_record(table_name: String, record_id: String) -> Dictionary:
	var rows := table(table_name)
	var value = rows.get(record_id, null)
	if typeof(value) != TYPE_DICTIONARY:
		return {}
	return value


func has_record(table_name: String, record_id: String) -> bool:
	return table(table_name).has(record_id)


func all_records(table_name: String) -> Array:
	return table(table_name).values()


func _validate_references() -> void:
	var characters := table("characters")
	for character_id in characters.keys():
		var character: Dictionary = characters[character_id]
		var starting: Array = character.get("starting_equipment", []) + character.get("starting_items", [])
		for item_id in starting:
			_require("items", item_id, "角色 %s" % character_id)
		for task_id in character.get("hidden_task_ids", []):
			_require("hidden_tasks", task_id, "角色 %s" % character_id)
			if has_record("hidden_tasks", String(task_id)):
				var owner_id := String(get_record("hidden_tasks", String(task_id)).get("character_id", ""))
				if owner_id != String(character_id):
					load_errors.append("隐藏任务 %s 的 character_id=%s 与角色 %s 不一致" % [task_id, owner_id, character_id])

	for task_id in table("hidden_tasks").keys():
		var task := get_record("hidden_tasks", task_id)
		_require("characters", task.get("character_id", ""), "隐藏任务 %s" % task_id)

	var events := table("events")
	for event_id in events.keys():
		var event: Dictionary = events[event_id]
		var trigger := String(event.get("trigger", ""))
		if not EVENT_TRIGGERS.has(trigger):
			load_errors.append("事件 %s：未知 trigger=%s" % [event_id, trigger])
		for terrain_id in event.get("terrains", []):
			if String(terrain_id) != "any":
				_require("terrains", terrain_id, "事件 %s" % event_id)
		for choice in event.get("choices", []):
			var choice_id := String(choice.get("id", ""))
			var resolution := String(choice.get("resolution", "check"))
			if not EVENT_RESOLUTIONS.has(resolution):
				load_errors.append("事件 %s/%s：未知 resolution=%s" % [event_id, choice_id, resolution])
			var check = choice.get("check", null)
			if typeof(check) == TYPE_DICTIONARY:
				var attribute := String(check.get("attr", ""))
				if not ATTRIBUTES.has(attribute):
					load_errors.append("事件 %s/%s：未知检定属性 %s" % [event_id, choice_id, attribute])
			_scan_effects(choice.get("outcomes", {}), "事件 %s/%s" % [event_id, choice_id])
			_scan_effects(choice.get("params", {}), "事件 %s/%s" % [event_id, choice_id])
			_validate_outcome_effects(choice.get("outcomes", {}), "事件 %s/%s" % [event_id, choice_id])
			if resolution == "trade":
				_validate_trade_offers(choice, "事件 %s/%s" % [event_id, choice_id])
			elif resolution == "inn":
				_validate_inn_params(choice, "事件 %s/%s" % [event_id, choice_id])
	_validate_landmarks()


## 地标表只描述地图上的固定设施；设施事件必须是 facility 触发器，
## 检查点则只负责封印进度，二者不能混在同一条地标记录里。
func _validate_landmarks() -> void:
	var landmarks := table("landmarks")
	for landmark_id in landmarks.keys():
		var landmark: Dictionary = landmarks[landmark_id]
		var color_text := String(landmark.get("color", ""))
		if not color_text.is_empty() and not Color.html_is_valid(color_text):
			load_errors.append("地标 %s：color 不是合法颜色 %s" % [landmark_id, color_text])
		var facility_event_id := String(landmark.get("facility_event_id", ""))
		if not facility_event_id.is_empty():
			if not has_record("events", facility_event_id):
				load_errors.append("地标 %s：引用了不存在的事件 %s" % [landmark_id, facility_event_id])
			elif String(get_record("events", facility_event_id).get("trigger", "")) != "facility":
				load_errors.append("地标 %s：设施事件 %s 的 trigger 必须是 facility" % [landmark_id, facility_event_id])
		if bool(landmark.get("counts_for_seal", false)) and not facility_event_id.is_empty():
			load_errors.append("地标 %s：不能同时计入封印和提供设施事件" % landmark_id)
		if String(landmark.get("short_name", "")).strip_edges().is_empty():
			load_errors.append("地标 %s：缺少 short_name" % landmark_id)


## 交易选项支持 buy / barter / sell；出售只接受数据表标记为 tradable 的物品。
func _validate_trade_offers(choice: Dictionary, context: String) -> void:
	var params = choice.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		load_errors.append("%s：trade.params 必须是对象" % context)
		return
	var offers = params.get("offers", [])
	if typeof(offers) != TYPE_ARRAY:
		load_errors.append("%s：trade.params.offers 必须是数组" % context)
		return
	for offer in offers:
		if typeof(offer) != TYPE_DICTIONARY:
			load_errors.append("%s：交易条目必须是对象" % context)
			continue
		var kind := String(offer.get("type", ""))
		match kind:
			"buy":
				_require("items", offer.get("item_id", ""), context)
				if int(offer.get("price", 0)) < 0:
					load_errors.append("%s：购买价格不能为负" % context)
			"sell":
				var item_id := String(offer.get("item_id", ""))
				_require("items", item_id, context)
				if int(offer.get("price", 0)) < 0:
					load_errors.append("%s：出售价格不能为负" % context)
				if has_record("items", item_id) and not bool(get_record("items", item_id).get("tradable", false)):
					load_errors.append("%s：%s 不可交易，不能作为出售项" % [context, item_id])
			"barter":
				var give: Dictionary = offer.get("give", {})
				var receive: Dictionary = offer.get("receive", {})
				_require("items", give.get("item_id", ""), context)
				_require("items", receive.get("item_id", ""), context)
			_:
				load_errors.append("%s：未知交易类型 %s" % [context, kind])


func _validate_inn_params(choice: Dictionary, context: String) -> void:
	var params = choice.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		load_errors.append("%s：inn.params 必须是对象" % context)
		return
	var gold_cost := int(params.get("gold_cost", 0))
	var heal_hp := int(params.get("heal_hp", 0))
	var restore_ap := int(params.get("restore_ap", 0))
	if gold_cost < 0 or heal_hp < 0 or restore_ap < 0:
		load_errors.append("%s：旅店费用与恢复量不能为负" % context)
	if gold_cost == 0 and heal_hp == 0 and restore_ap == 0:
		load_errors.append("%s：旅店没有任何费用或恢复效果" % context)


func _validate_outcome_effects(outcomes: Dictionary, context: String) -> void:
	for level in outcomes.keys():
		if not OUTCOME_LEVELS.has(String(level)):
			load_errors.append("%s：未知结果等级 %s" % [context, level])
			continue
		var outcome: Dictionary = outcomes[level]
		for key in ["effects", "player_effects", "ai_effects"]:
			var effects = outcome.get(key, [])
			if typeof(effects) != TYPE_ARRAY:
				load_errors.append("%s/%s.%s：必须是数组" % [context, level, key])
				continue
			for effect in effects:
				if typeof(effect) != TYPE_DICTIONARY:
					load_errors.append("%s/%s.%s：效果必须是对象" % [context, level, key])
					continue
				var effect_type := String(effect.get("type", ""))
				if not EVENT_EFFECT_TYPES.has(effect_type):
					load_errors.append("%s/%s.%s：未知效果类型 %s" % [context, level, key, effect_type])


func _require(table_name: String, record_id, context: String) -> void:
	var id_text := String(record_id)
	if id_text.is_empty():
		return
	if not has_record(table_name, id_text):
		load_errors.append("%s：引用了不存在的 %s.id=%s" % [context, table_name, id_text])


func _scan_effects(node, context: String) -> void:
	match typeof(node):
		TYPE_DICTIONARY:
			if node.has("item_id"):
				_require("items", node["item_id"], context)
			if node.has("status_id"):
				_require("statuses", node["status_id"], context)
			if node.has("flag_id"):
				_require("flags", node["flag_id"], context)
			if node.has("choose_from"):
				for item_id in node["choose_from"]:
					_require("items", item_id, context)
			for key in node.keys():
				_scan_effects(node[key], context)
		TYPE_ARRAY:
			for entry in node:
				_scan_effects(entry, context)
