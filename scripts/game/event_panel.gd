extends Control
## 事件面板：展示事件文本、选项、2d6 检定明细与结算结果。
## 所有规则判定都在 EventManager；本脚本只负责把结果渲染成可操作界面。

@onready var title_label: Label = $Center/Panel/Margin/VBox/TitleLabel
@onready var meta_label: Label = $Center/Panel/Margin/VBox/MetaLabel
@onready var context_label: Label = $Center/Panel/Margin/VBox/ContextLabel
@onready var event_text: Label = $Center/Panel/Margin/VBox/EventText
@onready var dice_panel: PanelContainer = $Center/Panel/Margin/VBox/DicePanel
@onready var dice_label: Label = $Center/Panel/Margin/VBox/DicePanel/Margin/DiceLabel
@onready var result_title: Label = $Center/Panel/Margin/VBox/ResultTitle
@onready var outcome_summary: RichTextLabel = $Center/Panel/Margin/VBox/OutcomeSummary
@onready var effects_label: Label = $Center/Panel/Margin/VBox/EffectsLabel
@onready var choices_box: VBoxContainer = $Center/Panel/Margin/VBox/Choices
@onready var continue_button: Button = $Center/Panel/Margin/VBox/ContinueButton

const LEVEL_COLORS := {
	"great_success": Color(0.96, 0.84, 0.48),
	"success": Color(0.66, 0.88, 0.62),
	"fail": Color(0.94, 0.66, 0.48),
	"great_fail": Color(0.94, 0.45, 0.40),
	"immune": Color(0.60, 0.86, 0.92),
}

var _choices_locked: bool = false


func _ready() -> void:
	visible = false
	EventManager.event_started.connect(_on_event_started)
	EventManager.event_progress.connect(_on_event_progress)
	EventManager.event_finished.connect(_on_event_finished)
	continue_button.pressed.connect(_on_continue_pressed)
	dice_panel.visible = false
	result_title.visible = false
	outcome_summary.visible = false
	effects_label.visible = false
	continue_button.visible = false


func _on_event_started(event_data: Dictionary) -> void:
	visible = true
	_choices_locked = false
	var trigger := String(event_data.get("trigger", ""))
	var trigger_names := {"goal": "终点", "poi": "地点", "facility": "设施", "enter_region": "区域", "wander": "游荡"}
	title_label.text = String(event_data.get("name", "事件"))
	meta_label.text = "触发：%s · 地形：%s" % [
		String(trigger_names.get(trigger, trigger)),
		_terrain_name(GameManager.map.terrain_of(GameManager.player.cell_id)) if GameManager.map != null else "—",
	]
	event_text.text = String(event_data.get("text", ""))
	var context_parts: Array[String] = []
	var discovery_note := String(event_data.get("discovery_note", "")).strip_edges()
	if not discovery_note.is_empty():
		context_parts.append(discovery_note)
	var context := EventManager.get_context_note().strip_edges()
	if not context.is_empty():
		context_parts.append(context)
	context_label.text = "  ".join(context_parts)
	context_label.visible = not context_parts.is_empty()
	dice_panel.visible = false
	dice_label.text = ""
	result_title.visible = false
	result_title.text = ""
	outcome_summary.visible = false
	outcome_summary.text = ""
	effects_label.visible = false
	effects_label.text = ""
	continue_button.visible = false
	_clear_choices()
	var choices := EventManager.get_choices()
	for choice in choices:
		var option := VBoxContainer.new()
		option.add_theme_constant_override("separation", 2)
		option.mouse_filter = Control.MOUSE_FILTER_PASS
		var button := _make_button(_choice_label(choice))
		button.disabled = bool(choice.get("disabled", false))
		if button.disabled:
			button.tooltip_text = String(choice.get("reason", ""))
		else:
			var risk := String(choice.get("risk", ""))
			if not risk.is_empty():
				button.add_theme_color_override("font_color", _risk_color(risk))
		var choice_id := String(choice.get("id", ""))
		button.pressed.connect(_on_choice_pressed.bind(choice_id))
		option.add_child(button)
		choices_box.add_child(option)
	var focus_button := _first_choice_button()
	if focus_button != null:
		focus_button.grab_focus()


func _on_choice_pressed(choice_id: String) -> void:
	if _choices_locked:
		return
	_choices_locked = true
	for button in choices_box.find_children("*", "Button", true, false):
		(button as Button).disabled = true
	EventManager.choose_choice(choice_id)


func _first_choice_button() -> Button:
	for child in choices_box.find_children("*", "Button", true, false):
		if not (child as Button).disabled:
			return child as Button
	return null


func _on_event_progress(result: Dictionary) -> void:
	var kind := String(result.get("kind", "outcome"))
	outcome_summary.visible = false
	_render_dice(result)
	match kind:
		"trade_menu":
			result_title.visible = true
			result_title.text = String(result.get("title", "交易"))
			result_title.add_theme_color_override("font_color", Color(0.94, 0.82, 0.52))
			effects_label.visible = true
			effects_label.text = String(result.get("note", "选择一项交易，或放弃。"))
			_show_trade_menu(result)
		"steal_menu":
			result_title.visible = true
			result_title.text = String(result.get("title", "选择物品"))
			result_title.add_theme_color_override("font_color", Color(0.94, 0.82, 0.52))
			effects_label.visible = false
			_show_item_menu(result, "steal")
		"sacrifice_menu":
			result_title.visible = true
			result_title.text = String(result.get("title", "选择献祭物品"))
			result_title.add_theme_color_override("font_color", Color(0.94, 0.82, 0.52))
			effects_label.visible = false
			_show_item_menu(result, "sacrifice")
		"heal_menu":
			result_title.visible = true
			result_title.text = String(result.get("title", "恢复"))
			result_title.add_theme_color_override("font_color", Color(0.94, 0.82, 0.52))
			effects_label.visible = false
			_show_heal_menu()
		"error":
			_choices_locked = false
			result_title.visible = true
			result_title.text = "无法选择"
			result_title.add_theme_color_override("font_color", Color(0.94, 0.52, 0.45))
			effects_label.visible = true
			effects_label.text = String(result.get("message", ""))
			continue_button.visible = true
			continue_button.grab_focus()
		_:
			_show_outcome(result)


func _render_dice(result: Dictionary) -> void:
	var check := bool(result.get("check", false))
	var auto := bool(result.get("auto", false))
	if not check:
		dice_panel.visible = false
		dice_label.text = ""
		return
	dice_panel.visible = true
	var dice: Array = result.get("dice", [])
	var natural := int(result.get("natural", 0))
	var formula := String(result.get("formula", ""))
	var line := ""
	if not formula.is_empty():
		line = formula + " → 合计 %d vs DC %d" % [int(result.get("total", 0)), int(result.get("dc", 0))]
	else:
		var parts: Array[String] = []
		parts.append("2d6：%d + %d = %d" % [int(dice[0]), int(dice[1]), natural])
		parts.append("%s %+d" % [String(result.get("attribute_name", "")), int(result.get("base", 0))])
		for part in result.get("equipment_parts", []):
			parts.append("%s %+d" % [String(part.get("name", "装备")), int(part.get("value", 0))])
		for part in result.get("status_parts", []):
			parts.append("%s %+d" % [String(part.get("name", "状态")), int(part.get("value", 0))])
		for part in result.get("trait_parts", []):
			parts.append("%s %+d" % [String(part.get("name", "词条")), int(part.get("value", 0))])
		line = " ｜ ".join(parts)
		line += " → 合计 %d vs DC %d" % [int(result.get("total", 0)), int(result.get("dc", 0))]
	var note := String(result.get("note", ""))
	if not note.is_empty():
		line += "\n" + note
	dice_label.text = line
	var level := String(result.get("level", "success"))
	var color_key := "immune" if String(result.get("level_name", "")) == "免疫" else level
	dice_label.add_theme_color_override("font_color", LEVEL_COLORS.get(color_key, Color(0.82, 0.82, 0.76)))


func _show_outcome(result: Dictionary) -> void:
	result_title.visible = true
	var level := String(result.get("level", "success"))
	var level_name := String(result.get("level_name", ""))
	if level_name.is_empty():
		level_name = String(result.get("choice_text", ""))
	result_title.text = "%s：%s" % [String(result.get("choice_text", "结果")), level_name]
	var color_key := "immune" if level_name == "免疫" else level
	result_title.add_theme_color_override("font_color", LEVEL_COLORS.get(color_key, Color(0.82, 0.82, 0.76)))
	var summary_text := _build_outcome_summary(result)
	outcome_summary.visible = not summary_text.is_empty()
	outcome_summary.text = summary_text
	var summarized: Dictionary = {}
	for key in ["reward_entries", "cost_entries", "insight_entries"]:
		for entry in result.get(key, []):
			summarized[String(entry.get("text", ""))] = true
	var lines: Array[String] = []
	var note := String(result.get("outcome_note", ""))
	if not note.is_empty():
		lines.append(note)
	var messages: Array = result.get("effect_messages", [])
	for message in messages:
		var text := String(message)
		if not summarized.has(text):
			lines.append(text)
	if bool(result.get("enter_goal", false)) and not summarized.has("你通过了终点守卫。"):
		lines.append("你通过了终点守卫。")
	if bool(result.get("death", false)) and not summarized.has("你倒下了。"):
		lines.append("你倒下了。")
	if lines.is_empty() and summary_text.is_empty():
		lines.append("这个选择没有造成额外收益或损失。")
	effects_label.visible = not lines.is_empty()
	effects_label.text = "\n".join(lines)
	_clear_choices()
	continue_button.visible = true
	continue_button.grab_focus()


func _build_outcome_summary(result: Dictionary) -> String:
	var sections: Array[String] = []
	var hints: Array[String] = []
	_append_summary_section(sections, hints, result, "reward_entries", "◆ 收获", "#a9d68f")
	_append_summary_section(sections, hints, result, "insight_entries", "◇ 线索", "#8fb8dc")
	_append_summary_section(sections, hints, result, "cost_entries", "◆ 代价", "#df9670")
	if not hints.is_empty():
		sections.append("[color=#8d8a79]%s[/color]" % "；".join(hints))
	return "\n".join(sections)


func _append_summary_section(
	sections: Array[String],
	hints: Array[String],
	result: Dictionary,
	key: String,
	title: String,
	color: String
) -> void:
	var entries: Array = result.get(key, [])
	if entries.is_empty():
		return
	var texts: Array[String] = []
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var text := String(entry.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		texts.append(text)
		var hint := String(entry.get("hint", "")).strip_edges()
		if not hint.is_empty() and not hints.has(hint):
			hints.append(hint)
	if texts.is_empty():
		return
	sections.append("[color=%s]%s[/color]  %s" % [color, title, "  ·  ".join(_dedupe(texts))])


func _dedupe(items: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for item in items:
		if not result.has(item):
			result.append(item)
	return result


func _show_trade_menu(result: Dictionary) -> void:
	_clear_choices()
	var offers: Array = result.get("offers", [])
	for i in range(offers.size()):
		var offer: Dictionary = offers[i]
		var button := _make_button(String(offer.get("label", "交易")))
		button.disabled = bool(offer.get("disabled", false))
		if button.disabled:
			button.tooltip_text = String(offer.get("reason", ""))
		button.pressed.connect(_on_trade_pressed.bind(i))
		choices_box.add_child(button)
	if bool(result.get("can_decline", true)):
		var decline := _make_button("放弃交易")
		decline.pressed.connect(_on_trade_pressed.bind(-1))
		choices_box.add_child(decline)
	if choices_box.get_child_count() > 0:
		(choices_box.get_child(0) as Button).grab_focus()


func _show_item_menu(result: Dictionary, mode: String) -> void:
	_clear_choices()
	var items: Array = result.get("items", [])
	var rarity_bonus: Dictionary = result.get("rarity_bonus", {})
	for item_id in items:
		var record := DataManager.get_record("items", String(item_id))
		var label := String(record.get("name", item_id))
		if mode == "sacrifice":
			var bonus := int(rarity_bonus.get(String(record.get("rarity", "common")), 0))
			label = "献出 %s（检定 %+d）" % [label, bonus] if bonus != 0 else "献出 %s" % label
		else:
			label = "偷取 %s" % label
		var button := _make_button(label)
		button.pressed.connect(_on_item_pressed.bind(mode, String(item_id)))
		choices_box.add_child(button)
	if choices_box.get_child_count() > 0:
		(choices_box.get_child(0) as Button).grab_focus()


func _show_heal_menu() -> void:
	_clear_choices()
	var hp_button := _make_button("恢复 1 HP")
	hp_button.pressed.connect(_on_heal_pressed.bind("hp"))
	choices_box.add_child(hp_button)
	var ap_button := _make_button("恢复 1 AP")
	ap_button.pressed.connect(_on_heal_pressed.bind("ap"))
	choices_box.add_child(ap_button)
	hp_button.grab_focus()


func _on_trade_pressed(index: int) -> void:
	EventManager.resolve_trade_offer(index)


func _on_item_pressed(mode: String, item_id: String) -> void:
	if mode == "sacrifice":
		EventManager.resolve_sacrifice(item_id)
	else:
		EventManager.resolve_steal_item(item_id)


func _on_heal_pressed(option: String) -> void:
	EventManager.resolve_heal(option)


func _on_continue_pressed() -> void:
	EventManager.finish_event()


func _on_event_finished(_event_id: String) -> void:
	visible = false
	_clear_choices()
	dice_panel.visible = false
	result_title.visible = false
	outcome_summary.visible = false
	effects_label.visible = false
	continue_button.visible = false


func _choice_label(choice: Dictionary) -> String:
	var check_text := String(choice.get("check_text", ""))
	if check_text.is_empty():
		return String(choice.get("text", ""))
	var risk := String(choice.get("risk", ""))
	if not risk.is_empty():
		check_text += " · 风险%s" % risk
	return "%s（%s）" % [String(choice.get("text", "")), check_text]


func _risk_color(risk: String) -> Color:
	match risk:
		"高":
			return Color(0.94, 0.49, 0.42)
		"中":
			return Color(0.94, 0.75, 0.48)
		_:
			return Color(0.72, 0.84, 0.66)


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 40)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return button


func _clear_choices() -> void:
	for child in choices_box.get_children():
		choices_box.remove_child(child)
		child.queue_free()


func _terrain_name(terrain_id: String) -> String:
	return GameManager.map.terrain_display_name(terrain_id) if GameManager.map != null else terrain_id
