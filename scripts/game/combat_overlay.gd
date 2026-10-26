extends Control
## 战斗提示面板：展示一次攻击检定，并让玩家决定是否消耗 1 AP 反击。
## 规则与状态全部在 GameManager / CombatRules，本脚本只负责渲染与转发意图。

@onready var title_label: Label = $Center/Panel/Margin/VBox/TitleLabel
@onready var meta_label: Label = $Center/Panel/Margin/VBox/MetaLabel
@onready var detail_label: Label = $Center/Panel/Margin/VBox/DetailLabel
@onready var counter_button: Button = $Center/Panel/Margin/VBox/Buttons/CounterButton
@onready var endure_button: Button = $Center/Panel/Margin/VBox/Buttons/EndureButton
@onready var continue_button: Button = $Center/Panel/Margin/VBox/ContinueButton


func _ready() -> void:
	visible = false
	GameManager.combat_started.connect(_render)
	GameManager.combat_updated.connect(_render)
	GameManager.combat_finished.connect(_on_finished)
	counter_button.pressed.connect(_on_counter_pressed)
	endure_button.pressed.connect(_on_endure_pressed)
	continue_button.pressed.connect(_on_continue_pressed)


func _render(payload: Dictionary) -> void:
	visible = true
	title_label.text = String(payload.get("title", "遭遇袭击"))
	meta_label.text = String(payload.get("meta", ""))
	var lines: Array = payload.get("lines", [])
	var text_parts: Array[String] = []
	for line in lines:
		text_parts.append(String(line))
	detail_label.text = "\n".join(text_parts)
	var choice := bool(payload.get("show_choice", false))
	counter_button.visible = choice
	endure_button.visible = choice
	continue_button.visible = not choice
	var counter_enabled := bool(payload.get("counter_enabled", false))
	counter_button.disabled = not counter_enabled
	counter_button.text = "消耗 1 AP 反击" if counter_enabled else "AP 不足，无法反击"
	counter_button.tooltip_text = String(payload.get("counter_reason", ""))
	if not counter_enabled:
		counter_button.tooltip_text = "反击需要至少 1 AP。"
	if choice:
		if counter_enabled:
			counter_button.grab_focus()
		else:
			endure_button.grab_focus()
	else:
		continue_button.grab_focus()


func _on_counter_pressed() -> void:
	GameManager.resolve_combat_choice("counter")


func _on_endure_pressed() -> void:
	GameManager.resolve_combat_choice("endure")


func _on_continue_pressed() -> void:
	GameManager.close_combat()


func _on_finished(_payload: Dictionary) -> void:
	visible = false
