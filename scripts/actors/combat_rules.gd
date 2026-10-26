class_name CombatRules
extends RefCounted
## 攻击事件规则（设计 §12.1）。
##
## MVP 不做独立战斗：攻击仍是一次 2d6 检定。攻击方消耗 1 AP，
## 失败再额外扣 1 AP（不足转 HP）；成功造成 1d3 伤害，大成功 1d6。
## 所有随机由调用方传入，玩家侧走 event 流，AI 侧走 ai 流，便于复现。

const AP_COST_DECI := 10
const EXTRA_FAIL_AP_DECI := 10


static func defense_dc(defender) -> int:
	if defender == null:
		return 8
	return 8 + defender.attribute_base("stamina") + defender.equipment_defense_bonus()


## 防御 DC 的逐项来源：8 + 体力 + 每件防御装备。
static func defense_dc_text(defender) -> String:
	if defender == null:
		return "DC 8（基础）"
	var text := "DC %d（8（基础） + %d（体力）" % [
		defense_dc(defender), defender.attribute_base("stamina"),
	]
	for part in defender.equipment_defense_parts():
		var value := int(part.get("value", 0))
		text = ActorState.append_bonus_term(text, value, String(part.get("name", "装备")))
	return text + "）"


## 攻击公式：2d6（点数） + 战斗 + 装备逐项 + 状态逐项 vs 防御 DC 逐项。
static func attack_formula_text(result: Dictionary) -> String:
	if not bool(result.get("ok", false)):
		return "未能出手：%s" % String(result.get("error", "无法攻击"))
	var dice: Array = result.get("dice", [0, 0])
	var natural := int(result.get("natural", 0))
	var text := "2d6（%d） + %d（战斗）" % [natural, int(result.get("base", 0))]
	for part in result.get("equipment_parts", []):
		text = ActorState.append_bonus_term(text, int(part.get("value", 0)), String(part.get("name", "装备")))
	for part in result.get("status_parts", []):
		text = ActorState.append_bonus_term(text, int(part.get("value", 0)), String(part.get("name", "状态")))
	var dc_text := String(result.get("dc_text", "DC %d" % int(result.get("dc", 0))))
	return "%s = %d vs %s · %s" % [
		text, int(result.get("total", 0)), dc_text, String(result.get("level_name", "")),
	]


## 结算一次攻击；调用前无需手动扣 AP。返回结构同时供 UI 与测试读取。
static func resolve_attack(attacker, defender, rng: RandomNumberGenerator) -> Dictionary:
	var result := {
		"ok": false,
		"attacker": attacker.display_name if attacker != null else "",
		"defender": defender.display_name if defender != null else "",
		"dice": [0, 0],
		"natural": 0,
		"base": 0,
		"equipment": 0,
		"status": 0,
		"equipment_parts": [],
		"status_parts": [],
		"total": 0,
		"dc": 8,
		"dc_text": "DC 8（基础）",
		"level": "",
		"level_name": "",
		"damage": 0,
		"ap_penalty_hp": 0,
		"attacker_hp_loss": 0,
		"attacker_ap_before": 0,
		"attacker_ap_after": 0,
		"defender_hp_before": 0,
		"defender_hp_after": 0,
	}
	if attacker == null or defender == null or rng == null:
		result["error"] = "攻击双方无效。"
		return result
	result["attacker_hp_before"] = attacker.hp
	result["defender_hp_before"] = defender.hp
	result["attacker_ap_before"] = attacker.ap_deci
	result["attacker_ap_after"] = attacker.ap_deci
	if attacker.ap_deci < AP_COST_DECI:
		result["error"] = "AP 不足，无法主动攻击。"
		return result

	attacker.ap_deci -= AP_COST_DECI
	var first := rng.randi_range(1, 6)
	var second := rng.randi_range(1, 6)
	var natural := first + second
	var base: int = attacker.combat()
	var equipment_parts: Array[Dictionary] = attacker.equipment_check_parts("combat")
	var status_parts: Array[Dictionary] = attacker.status_check_parts("combat")
	var equipment: int = attacker.equipment_check_bonus("combat")
	var status: int = attacker.status_check_modifier("combat")
	var total: int = natural + base + equipment + status
	var dc := defense_dc(defender)
	var dc_text := defense_dc_text(defender)
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

	var damage := 0
	if level == "great_success":
		damage = rng.randi_range(1, 6)
	elif level == "success":
		damage = rng.randi_range(1, 3)
	if damage > 0:
		defender.take_damage(damage)

	var ap_penalty_hp := 0
	var attacker_hp_loss := 0
	if level == "fail" or level == "great_fail":
		if attacker.ap_deci >= EXTRA_FAIL_AP_DECI:
			attacker.ap_deci -= EXTRA_FAIL_AP_DECI
		else:
			attacker.take_damage(1)
			ap_penalty_hp = 1
	if level == "great_fail":
		attacker.take_damage(1)
		attacker_hp_loss = 1

	result["ok"] = true
	result["dice"] = [first, second]
	result["natural"] = natural
	result["base"] = base
	result["equipment"] = equipment
	result["status"] = status
	result["equipment_parts"] = equipment_parts
	result["status_parts"] = status_parts
	result["total"] = total
	result["dc"] = dc
	result["dc_text"] = dc_text
	result["level"] = level
	result["level_name"] = level_name
	result["damage"] = damage
	result["ap_penalty_hp"] = ap_penalty_hp
	result["attacker_hp_loss"] = attacker_hp_loss
	result["attacker_ap_after"] = attacker.ap_deci
	result["defender_hp_after"] = defender.hp
	result["attacker_hp_after"] = attacker.hp
	return result


## 把一次攻击结果压成面板可读的中文明细。
static func describe_attack(result: Dictionary, attacker_name: String, defender_name: String) -> Array[String]:
	var lines: Array[String] = []
	if not bool(result.get("ok", false)):
		lines.append("%s未能出手：%s" % [attacker_name, String(result.get("error", "无法攻击"))])
		return lines
	lines.append(attack_formula_text(result))
	var damage := int(result.get("damage", 0))
	if damage > 0:
		lines.append("%s受到 %d 点伤害（HP %d → %d）。" % [
			defender_name, damage, int(result.get("defender_hp_before", 0)), int(result.get("defender_hp_after", 0)),
		])
	else:
		lines.append("这一击没有突破%s的防御。" % defender_name)
	if int(result.get("ap_penalty_hp", 0)) > 0:
		lines.append("%s招式落空，AP 已空，改为损失 1 HP。" % attacker_name)
	elif int(result.get("attacker_ap_after", 0)) < int(result.get("attacker_ap_before", 0)) - AP_COST_DECI:
		lines.append("%s因出手落空额外消耗 1 AP。" % attacker_name)
	if int(result.get("attacker_hp_loss", 0)) > 0:
		lines.append("%s用力过猛，反受 1 点伤害。" % attacker_name)
	return lines
