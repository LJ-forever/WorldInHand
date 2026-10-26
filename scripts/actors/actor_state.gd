class_name ActorState
extends RefCounted
## 玩家 / AI 的运行时状态。角色静态数据来自 characters.json。

var character_id: String = ""
var display_name: String = ""
var role: String = ""
var attributes: Dictionary = {}
var traits: Array[String] = []
var equipment: Array[String] = []
var inventory: Array[String] = []
## 状态：status_id -> { "remaining": int, "added_round": int, "ap_applied": bool, "failed_checks": int }
## remaining = -1 表示本局永久。
var statuses: Dictionary = {}
## 剧情标记：flag_id -> true。
var flags: Dictionary = {}

var hp: int = 1
var hp_max: int = 1
## 行动点，单位 0.1 AP（10 = 1 AP）。
var ap_deci: int = 0
var ap_max_deci: int = 0
var gold: int = 20
## 当前所在地块 id（Voronoi 地块数组下标）。-1 表示尚未放置。
var cell_id: int = -1
var rest_used: bool = false
## 已通过终点守卫；之后进入终点不再触发守卫。
var goal_passed: bool = false
## 延迟的 AP 惩罚（0.1 AP）。用于「迷路（严重）」等一次性效果。
var pending_ap_penalty_deci: int = 0


static func from_character(record: Dictionary) -> ActorState:
	var actor := ActorState.new()
	actor.character_id = String(record.get("id", ""))
	actor.display_name = String(record.get("name", ""))
	actor.role = String(record.get("role", ""))
	actor.attributes = record.get("attributes", {})
	for trait_id in record.get("traits", []):
		actor.traits.append(String(trait_id))
	for item_id in record.get("starting_equipment", []):
		actor.equipment.append(String(item_id))
	for item_id in record.get("starting_items", []):
		actor.inventory.append(String(item_id))
	actor.gold = int(record.get("starting_gold", 20))
	actor.hp_max = actor.stamina() * 3
	actor.hp = actor.hp_max
	return actor


## 运行时角色状态 → 可 JSON 化的字典。静态角色数据仍以 characters.json 为准，
## 这里保存本局被事件、战斗与装备改变后的全部数值。
func to_dict() -> Dictionary:
	return {
		"character_id": character_id,
		"display_name": display_name,
		"role": role,
		"attributes": attributes.duplicate(true),
		"traits": traits.duplicate(),
		"equipment": equipment.duplicate(),
		"inventory": inventory.duplicate(),
		"statuses": statuses.duplicate(true),
		"flags": flags.duplicate(true),
		"hp": hp,
		"hp_max": hp_max,
		"ap_deci": ap_deci,
		"ap_max_deci": ap_max_deci,
		"gold": gold,
		"cell_id": cell_id,
		"rest_used": rest_used,
		"goal_passed": goal_passed,
		"pending_ap_penalty_deci": pending_ap_penalty_deci,
	}


static func from_dict(data: Dictionary) -> ActorState:
	var actor := ActorState.new()
	actor.character_id = String(data.get("character_id", ""))
	actor.display_name = String(data.get("display_name", ""))
	actor.role = String(data.get("role", ""))
	var attributes_data = data.get("attributes", {})
	if attributes_data is Dictionary:
		actor.attributes = (attributes_data as Dictionary).duplicate(true)
	for trait_id in data.get("traits", []):
		actor.traits.append(String(trait_id))
	for item_id in data.get("equipment", []):
		actor.equipment.append(String(item_id))
	for item_id in data.get("inventory", []):
		actor.inventory.append(String(item_id))
	var status_data = data.get("statuses", {})
	if status_data is Dictionary:
		for status_id in status_data.keys():
			var entry = status_data[status_id]
			if not (entry is Dictionary):
				continue
			actor.statuses[String(status_id)] = {
				"remaining": int((entry as Dictionary).get("remaining", -1)),
				"added_round": int((entry as Dictionary).get("added_round", 0)),
				"ap_applied": bool((entry as Dictionary).get("ap_applied", false)),
				"failed_checks": int((entry as Dictionary).get("failed_checks", 0)),
			}
	var flag_data = data.get("flags", {})
	if flag_data is Dictionary:
		for flag_id in flag_data.keys():
			actor.flags[String(flag_id)] = bool(flag_data[flag_id])
	actor.hp = int(data.get("hp", 1))
	actor.hp_max = maxi(1, int(data.get("hp_max", 1)))
	actor.ap_deci = maxi(0, int(data.get("ap_deci", 0)))
	actor.ap_max_deci = maxi(0, int(data.get("ap_max_deci", actor.ap_deci)))
	actor.gold = int(data.get("gold", 0))
	actor.cell_id = int(data.get("cell_id", -1))
	actor.rest_used = bool(data.get("rest_used", false))
	actor.goal_passed = bool(data.get("goal_passed", false))
	actor.pending_ap_penalty_deci = maxi(0, int(data.get("pending_ap_penalty_deci", 0)))
	return actor


func stamina() -> int:
	return int(attributes.get("stamina", 1))


func speed() -> int:
	return int(attributes.get("speed", 1))


func perception() -> int:
	return int(attributes.get("perception", 1))


func luck() -> int:
	return int(attributes.get("luck", 1))


func combat() -> int:
	return int(attributes.get("combat", 1))


func negotiation() -> int:
	return int(attributes.get("negotiation", 1))


func has_trait(trait_id: String) -> bool:
	return traits.has(trait_id)


func has_equipment(item_id: String) -> bool:
	return equipment.has(item_id)


## 装备提供的 AP 加值；坐骑在禁用地形上不生效。
## AP 装备加值明细：每件生效装备一项，供公式逐项标注来源。
func equipment_ap_parts(terrain_id: String) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	for item_id in equipment:
		var record := DataManager.get_record("items", item_id)
		var effects: Dictionary = record.get("effects", {})
		if not effects.has("ap_bonus"):
			continue
		var disabled: Array = effects.get("ap_bonus_disabled_terrains", [])
		if disabled.has(terrain_id):
			continue
		var value := int(effects["ap_bonus"])
		if value == 0:
			continue
		parts.append({
			"id": item_id,
			"name": String(record.get("name", item_id)),
			"value": value,
		})
	return parts


func equipment_ap_bonus(terrain_id: String) -> int:
	var bonus := 0
	for part in equipment_ap_parts(terrain_id):
		bonus += int(part.get("value", 0))
	return bonus


## 回合开始掷 AP：1d6 + 速度 + 装备加值，上限 12 AP。
## 延迟的 AP 惩罚不在这里扣除，由 apply_ap_penalties() 在掷骰后结算。
## 返回掷骰明细（含每件装备名称），供 HUD 的骰子动画解释 AP 来源。
func roll_ap(terrain_id: String) -> Dictionary:
	var die := RNGManager.roll_1d6("ap")
	var speed_bonus := speed()
	var equipment_parts := equipment_ap_parts(terrain_id)
	var equipment_bonus := 0
	for part in equipment_parts:
		equipment_bonus += int(part.get("value", 0))
	var raw_total := die + speed_bonus + equipment_bonus
	var total := int(min(raw_total, 12))
	ap_deci = total * 10
	ap_max_deci = ap_deci
	return {
		"dice": [die],
		"sides": 6,
		"speed": speed_bonus,
		"equipment": equipment_bonus,
		"equipment_parts": equipment_parts,
		"modifier": speed_bonus + equipment_bonus,
		"raw_total": raw_total,
		"total": total,
		"capped": raw_total > 12,
	}


func heal(amount: int) -> void:
	hp = int(min(hp_max, hp + amount))


func take_damage(amount: int) -> void:
	hp = int(max(0, hp - amount))


func add_item(item_id: String, count: int = 1) -> void:
	if item_id.is_empty():
		return
	for _i in range(maxi(1, count)):
		inventory.append(item_id)


const EQUIP_SLOT_LIMIT := 4


func is_equippable(item_id: String) -> bool:
	var record := DataManager.get_record("items", item_id)
	return not record.is_empty() and String(record.get("type", "")) == "equipment"


## 把背包里的装备移到装备栏。返回 {ok, message}，失败原因可直接显示给玩家。
func equip_item(item_id: String) -> Dictionary:
	if item_id.is_empty():
		return {"ok": false, "message": "没有选中物品。"}
	if not inventory.has(item_id):
		return {"ok": false, "message": "背包里没有这件物品。"}
	if not is_equippable(item_id):
		return {"ok": false, "message": "这件物品不是装备，不能装备。"}
	if equipment.has(item_id):
		return {"ok": false, "message": "这件装备已经穿戴在身上。"}
	if equipment.size() >= EQUIP_SLOT_LIMIT:
		return {"ok": false, "message": "装备栏已满（%d/%d），先卸下一件。" % [equipment.size(), EQUIP_SLOT_LIMIT]}
	inventory.erase(item_id)
	equipment.append(item_id)
	var record := DataManager.get_record("items", item_id)
	return {"ok": true, "message": "已装备「%s」。" % String(record.get("name", item_id))}


func unequip_item(item_id: String) -> Dictionary:
	var index := equipment.find(item_id)
	if index < 0:
		return {"ok": false, "message": "这件装备不在装备栏里。"}
	var record := DataManager.get_record("items", item_id)
	equipment.remove_at(index)
	inventory.append(item_id)
	return {"ok": true, "message": "已卸下「%s」，放回背包。" % String(record.get("name", item_id))}


func remove_item(item_id: String, count: int = 1) -> int:
	var removed := 0
	for _i in range(maxi(1, count)):
		var index := inventory.find(item_id)
		if index >= 0:
			inventory.remove_at(index)
			removed += 1
			continue
		var equip_index := equipment.find(item_id)
		if equip_index >= 0:
			equipment.remove_at(equip_index)
			removed += 1
			continue
		break
	return removed


func item_count(item_id: String) -> int:
	var total := 0
	for entry in inventory:
		if entry == item_id:
			total += 1
	for entry in equipment:
		if entry == item_id:
			total += 1
	return total


func has_item(item_id: String) -> bool:
	return item_count(item_id) > 0


func item_display_name(item_id: String) -> String:
	var record := DataManager.get_record("items", item_id)
	if record.is_empty():
		return item_id
	return String(record.get("name", item_id))


## 已装备物品的名称列表，例如「望远镜、马匪弯刀」。
func equipment_text() -> String:
	var parts: Array[String] = []
	for item_id in equipment:
		parts.append(item_display_name(item_id))
	if parts.is_empty():
		return "无"
	return "、".join(parts)


## 背包内容，按首次出现顺序合并同类物品，例如「药水 ×2、草药」。
func inventory_text() -> String:
	if inventory.is_empty():
		return "空"
	var counts: Dictionary = {}
	var order: Array[String] = []
	for item_id in inventory:
		if not counts.has(item_id):
			counts[item_id] = 0
			order.append(item_id)
		counts[item_id] = int(counts[item_id]) + 1
	var parts: Array[String] = []
	for item_id in order:
		var count := int(counts[item_id])
		var item_name := item_display_name(item_id)
		parts.append(item_name if count <= 1 else "%s ×%d" % [item_name, count])
	return "、".join(parts)


## 可作为终点守卫献祭的物品 id（保持背包/装备顺序，可重复）。
func sacrifice_candidates(allow_types: Array, exclude_quest: bool = true) -> Array[String]:
	var result: Array[String] = []
	for item_id in inventory + equipment:
		var record := DataManager.get_record("items", item_id)
		if record.is_empty():
			continue
		if exclude_quest and bool(record.get("quest_item", false)):
			continue
		if not allow_types.is_empty() and not allow_types.has(String(record.get("type", ""))):
			continue
		if not result.has(item_id):
			result.append(item_id)
	return result


func add_status(status_id: String, duration: int = -999, round_index: int = 0) -> void:
	var record := DataManager.get_record("statuses", status_id)
	if record.is_empty():
		push_warning("未知状态：%s" % status_id)
		return
	var base_duration := int(record.get("duration", -1))
	var chosen := base_duration if duration == -999 else duration
	var max_duration_value = record.get("max_duration", null)
	if typeof(max_duration_value) == TYPE_INT or typeof(max_duration_value) == TYPE_FLOAT:
		if chosen > 0:
			chosen = mini(chosen, int(max_duration_value))
	if chosen < 0:
		chosen = -1
	if statuses.has(status_id):
		var entry: Dictionary = statuses[status_id]
		var existing := int(entry.get("remaining", -1))
		if existing < 0 or chosen < 0:
			entry["remaining"] = -1
		else:
			entry["remaining"] = maxi(existing, chosen)
		entry["failed_checks"] = 0
		statuses[status_id] = entry
		return
	statuses[status_id] = {
		"remaining": chosen,
		"added_round": round_index,
		"ap_applied": false,
		"failed_checks": 0,
	}


func remove_status(status_id: String) -> bool:
	return statuses.erase(status_id)


func has_status(status_id: String) -> bool:
	return statuses.has(status_id)


func status_effects(status_id: String) -> Dictionary:
	var record := DataManager.get_record("statuses", status_id)
	return record.get("effects", {})


func has_status_flag(flag_name: String) -> bool:
	for status_id in statuses.keys():
		if bool(status_effects(status_id).get(flag_name, false)):
			return true
	return false


func status_blocks_movement() -> bool:
	return has_status_flag("blocks_movement")


func movement_block_status_name() -> String:
	for status_id in statuses.keys():
		if bool(status_effects(status_id).get("blocks_movement", false)):
			return String(DataManager.get_record("statuses", status_id).get("name", status_id))
	return "受阻"


func movement_block_status_hint() -> String:
	if has_status("trapped"):
		return "回合结束时进行一次体力检定 DC 10，成功或撑满 2 回合后解除"
	return "该状态会阻止你绘制移动路径"


func status_blocks_goal() -> bool:
	return has_status_flag("blocks_goal")


func add_flag(flag_id: String) -> void:
	if not flag_id.is_empty():
		flags[flag_id] = true


func remove_flag(flag_id: String) -> void:
	flags.erase(flag_id)


func has_flag(flag_id: String) -> bool:
	return flags.has(flag_id)


## 不含装备/状态的裸属性值。
func attribute_base(attribute: String) -> int:
	return int(attributes.get(attribute, 0))


## 装备提供的检定加值明细。战斗/交涉等使用物品 effects 中的同名属性；
## 契约书、望远镜、稀有护符使用专用字段。每项带物品名，供公式标注来源。
func equipment_check_parts(attribute: String) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	for item_id in equipment:
		var record := DataManager.get_record("items", item_id)
		var effects: Dictionary = record.get("effects", {})
		var value := int(effects.get(attribute, 0))
		match attribute:
			"negotiation":
				value += int(effects.get("negotiation_check_bonus", 0))
			"perception":
				value += int(effects.get("scout_check_bonus", 0))
			"luck":
				value += int(effects.get("luck_event", 0))
		if value == 0:
			continue
		parts.append({
			"id": item_id,
			"name": String(record.get("name", item_id)),
			"value": value,
		})
	return parts


func equipment_check_bonus(attribute: String) -> int:
	var bonus := 0
	for part in equipment_check_parts(attribute):
		bonus += int(part.get("value", 0))
	return bonus


## 战斗防御 DC 用的「装备属性加值总和」明细。
## 只统计六项基础属性与同名装备字段；侦察/交涉专用加值不计入（设计 §12.1）。
func equipment_defense_parts() -> Array[Dictionary]:
	var attributes := ["speed", "stamina", "perception", "luck", "combat", "negotiation"]
	var parts: Array[Dictionary] = []
	for item_id in equipment:
		var record := DataManager.get_record("items", item_id)
		var effects: Dictionary = record.get("effects", {})
		var value := 0
		for attribute in attributes:
			value += int(effects.get(attribute, 0))
		if value == 0:
			continue
		parts.append({
			"id": item_id,
			"name": String(record.get("name", item_id)),
			"value": value,
		})
	return parts


func equipment_defense_bonus() -> int:
	var bonus := 0
	for part in equipment_defense_parts():
		bonus += int(part.get("value", 0))
	return bonus


## 状态提供的检定加值明细（如 poisoned 侦察 -1、suspected 交涉 -1）。
func status_check_parts(attribute: String) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	for status_id in statuses.keys():
		var effects := status_effects(status_id)
		var value := int(effects.get(attribute, 0))
		if attribute == "perception":
			value += int(effects.get("scout_check_bonus", 0))
		if value == 0:
			continue
		var record := DataManager.get_record("statuses", status_id)
		parts.append({
			"id": status_id,
			"name": String(record.get("name", status_id)),
			"value": value,
		})
	return parts


func status_check_modifier(attribute: String) -> int:
	var modifier := 0
	for part in status_check_parts(attribute):
		modifier += int(part.get("value", 0))
	return modifier


## 含状态加成的感知值；用于侦察揭示半径（不给望远镜等检定加值改半径）。
func effective_perception() -> int:
	var total := perception()
	for status_id in statuses.keys():
		total += int(status_effects(status_id).get("perception", 0))
	return maxi(0, total)


## 侦察成功的基础揭示半径：感知每 2 点 +1 格，至少 1 格。
## 大成功在此基础上再 +1，由 GameManager.scout 处理。
func scout_reveal_radius() -> int:
	var half := floori(float(effective_perception()) / 2.0)
	return maxi(1, half + 1)


## 检定面板用：2d6 + 基础属性 + 每件装备 + 每个状态。
func check_breakdown(attribute: String) -> Dictionary:
	return {
		"attribute": attribute,
		"base": attribute_base(attribute),
		"equipment": equipment_check_bonus(attribute),
		"status": status_check_modifier(attribute),
		"equipment_parts": equipment_check_parts(attribute),
		"status_parts": status_check_parts(attribute),
	}


## 把加值项追加成「+ 1（望远镜）/ - 1（中毒）」的可读公式。
static func append_bonus_term(text: String, value: int, source: String) -> String:
	var operator_text := " + " if value >= 0 else " - "
	return text + operator_text + str(absi(value)) + "（" + source + "）"


## 检定公式：2d6（点数） + 基础属性 + 装备逐项 + 状态逐项。
## include_equipment=false 用于只按「基础 + 状态」结算的检定（如挣脱绳套）。
func check_formula_text(
		attribute: String,
		natural: int,
		attribute_name: String,
		include_equipment: bool = true
	) -> String:
	var text := "2d6（%d） + %d（%s）" % [natural, attribute_base(attribute), attribute_name]
	if include_equipment:
		for part in equipment_check_parts(attribute):
			text = append_bonus_term(text, int(part.get("value", 0)), String(part.get("name", "")))
	for part in status_check_parts(attribute):
		text = append_bonus_term(text, int(part.get("value", 0)), String(part.get("name", "")))
	return text


## AP 公式：1d6（点数） + 速度 + 装备逐项，再注明上限。
static func ap_formula_text(roll: Dictionary) -> String:
	var dice: Array = roll.get("dice", [])
	var die_value := int(dice[0]) if not dice.is_empty() else 0
	var text := "1d6（%d） + %d（速度）" % [die_value, int(roll.get("speed", 0))]
	for part in roll.get("equipment_parts", []):
		text = append_bonus_term(text, int(part.get("value", 0)), String(part.get("name", "")))
	var total := int(roll.get("total", 0))
	text += " = %d AP" % total
	if bool(roll.get("capped", false)):
		text += "（原始 %d，达到 12 AP 上限）" % int(roll.get("raw_total", 0))
	else:
		text += "（上限 12 AP）"
	return text


## 掷 AP 之后结算延迟 AP 惩罚；不足部分每缺 1 AP 转 1 HP。
func apply_ap_penalties() -> Dictionary:
	var penalty_deci := maxi(0, pending_ap_penalty_deci)
	pending_ap_penalty_deci = 0
	for status_id in statuses.keys():
		var entry: Dictionary = statuses[status_id]
		var effects := status_effects(status_id)
		if effects.has("ap_next_round") and not bool(entry.get("ap_applied", false)):
			penalty_deci += maxi(0, -int(effects["ap_next_round"]) * 10)
			entry["ap_applied"] = true
			statuses[status_id] = entry
	if penalty_deci <= 0:
		return {"ap_lost_deci": 0, "hp_lost": 0}
	var available := mini(ap_deci, penalty_deci)
	var missing := penalty_deci - available
	ap_deci = maxi(0, ap_deci - available)
	var hp_lost := int(ceil(float(missing) / 10.0))
	if hp_lost > 0:
		take_damage(hp_lost)
	return {"ap_lost_deci": available, "hp_lost": hp_lost}


## 回合结束时结算持续伤害。added_round 当回合不结算，避免状态刚获得就立刻掉血。
func apply_round_status_effects(current_round: int) -> Dictionary:
	var hp_lost := 0
	var messages: Array[String] = []
	for status_id in statuses.keys():
		var entry: Dictionary = statuses[status_id]
		if int(entry.get("added_round", current_round)) >= current_round:
			continue
		var effects := status_effects(status_id)
		if not effects.has("hp_per_round"):
			continue
		var value := int(effects["hp_per_round"])
		if value < 0:
			var loss := -value
			take_damage(loss)
			hp_lost += loss
			messages.append("%s -%d HP" % [String(DataManager.get_record("statuses", status_id).get("name", status_id)), loss])
		elif value > 0:
			heal(value)
	return {"hp_lost": hp_lost, "messages": messages}


## 回合结束递减持续时间。added_round 当回合不递减，下一回合开始后才计入。
func tick_status_durations(current_round: int) -> Array[String]:
	var expired: Array[String] = []
	for status_id in statuses.keys():
		var entry: Dictionary = statuses[status_id]
		if int(entry.get("added_round", current_round)) >= current_round:
			continue
		var remaining := int(entry.get("remaining", -1))
		if remaining < 0:
			continue
		remaining -= 1
		if remaining <= 0:
			statuses.erase(status_id)
			expired.append(status_id)
		else:
			entry["remaining"] = remaining
			statuses[status_id] = entry
	return expired


func status_display_text() -> String:
	if statuses.is_empty():
		return "状态：无"
	var parts: Array[String] = []
	for status_id in statuses.keys():
		var record := DataManager.get_record("statuses", status_id)
		var name := String(record.get("name", status_id))
		var remaining := int(statuses[status_id].get("remaining", -1))
		parts.append(name if remaining < 0 else "%s(%d)" % [name, remaining])
	return "状态：" + "、".join(parts)


## HUD 状态条：只放短效果，完整说明放在 tooltip / 暂停页，避免横向被裁切。
func status_summary_text() -> String:
	if statuses.is_empty():
		return "状态：无"
	var parts: Array[String] = []
	for status_id in statuses.keys():
		var record := DataManager.get_record("statuses", status_id)
		var short := String(record.get("short", "")).strip_edges()
		if short.is_empty():
			short = _status_description(status_id)
		var remaining := int(statuses[status_id].get("remaining", -1))
		if remaining >= 0:
			short += "，剩 %d 回合" % remaining
		parts.append("%s（%s）" % [String(record.get("name", status_id)), short])
	if parts.size() > 2:
		var hidden := parts.size() - 2
		parts = parts.slice(0, 2)
		parts.append("另有 %d 项，悬停查看" % hidden)
	return "状态：" + "；".join(parts)


## 完整状态说明：名称、数值、持续时间与药水能否解除。
func status_detail_text() -> String:
	if statuses.is_empty():
		return "当前没有状态效果。"
	var lines: Array[String] = []
	for status_id in statuses.keys():
		var record := DataManager.get_record("statuses", status_id)
		var line := "· %s：%s" % [
			String(record.get("name", status_id)),
			_status_description(status_id),
		]
		var remaining := int(statuses[status_id].get("remaining", -1))
		if remaining >= 0:
			line += "（剩余 %d 回合）" % remaining
		lines.append(line)
	return "\n".join(lines)


func _status_description(status_id: String) -> String:
	var record := DataManager.get_record("statuses", status_id)
	var description := String(record.get("description", "")).strip_edges()
	if description.is_empty():
		description = "效果见状态面板。"
	var removable := bool(record.get("removable_by_potion", false))
	var category := String(record.get("category", ""))
	if removable and not description.contains("药水"):
		description += "；可被药水解除。"
	elif not removable and category == "debuff" and not description.contains("药水"):
		description += "；药水无法解除。"
	return description


func status_remaining(status_id: String) -> int:
	if not statuses.has(status_id):
		return 0
	return int(statuses[status_id].get("remaining", -1))
