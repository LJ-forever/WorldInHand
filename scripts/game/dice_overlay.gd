extends Control
## 骰子动画条：AP、侦察、事件检定、陷阱挣脱、战斗攻击都会在这里掷一次。
## 动画只负责解释随机结果，不阻塞任何规则结算。

const ROLL_TICKS := 8
const TICK_SECONDS := 0.055
const HOLD_SECONDS := 1.55

@onready var banner: PanelContainer = $Banner/Center/Panel
@onready var title_label: Label = $Banner/Center/Panel/Margin/VBox/Header/TitleLabel
@onready var timer_label: Label = $Banner/Center/Panel/Margin/VBox/Header/TimerLabel
@onready var dice_box: HBoxContainer = $Banner/Center/Panel/Margin/VBox/DiceRow/DiceBox
@onready var summary_label: Label = $Banner/Center/Panel/Margin/VBox/DiceRow/SummaryLabel
@onready var detail_label: Label = $Banner/Center/Panel/Margin/VBox/DetailLabel

var _token: int = 0
var _faces: Array[DiceFace] = []
var _cosmetic_rng := RandomNumberGenerator.new()


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cosmetic_rng.randomize()
	GameManager.dice_rolled.connect(show_roll)
	EventManager.dice_rolled.connect(show_roll)


func show_roll(payload: Dictionary) -> void:
	var dice: Array = payload.get("dice", [])
	if dice.is_empty():
		return
	_token += 1
	var token := _token
	visible = true
	modulate = Color(1, 1, 1, 1)
	title_label.text = String(payload.get("title", "检定"))
	timer_label.text = String(payload.get("kind_label", ""))
	detail_label.text = String(payload.get("detail", ""))
	detail_label.visible = not detail_label.text.is_empty()
	_build_faces(dice.size())
	summary_label.text = "掷骰中…"
	banner.pivot_offset = banner.size * 0.5
	banner.scale = Vector2(0.96, 0.96)
	var tween := create_tween()
	tween.tween_property(banner, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	var sides := int(payload.get("sides", 6))
	for tick in range(ROLL_TICKS):
		await get_tree().create_timer(TICK_SECONDS).timeout
		if token != _token:
			return
		for face_index in range(_faces.size()):
			_faces[face_index].value = _cosmetic_rng.randi_range(1, sides)
			_faces[face_index].highlighted = tick % 2 == 0
	for i in range(_faces.size()):
		_faces[i].highlighted = false
		_faces[i].value = int(dice[i])
	summary_label.text = _summary_text(payload)
	var settle := create_tween()
	settle.tween_property(banner, "scale", Vector2(1.035, 1.035), 0.09)
	settle.tween_property(banner, "scale", Vector2.ONE, 0.12)

	await get_tree().create_timer(HOLD_SECONDS).timeout
	if token != _token:
		return
	var fade := create_tween()
	fade.tween_property(self, "modulate:a", 0.0, 0.28)
	await fade.finished
	if token == _token:
		visible = false


func _build_faces(count: int) -> void:
	for face in _faces:
		face.queue_free()
	_faces.clear()
	for i in range(count):
		var face := DiceFace.new()
		dice_box.add_child(face)
		_faces.append(face)


func _summary_text(payload: Dictionary) -> String:
	var dice: Array = payload.get("dice", [])
	var total := int(payload.get("total", 0))
	var modifier := int(payload.get("modifier", 0))
	var dc := int(payload.get("dc", 0))
	var parts: Array[String] = []
	if dice.size() == 1:
		parts.append("d6 = %d" % int(dice[0]))
	else:
		var values: Array[String] = []
		var natural := 0
		for die in dice:
			values.append(str(int(die)))
			natural += int(die)
		parts.append("%dd6（%s）= %d" % [dice.size(), "+".join(values), natural])
	if modifier != 0:
		parts.append("修正 %+d" % modifier)
	parts.append("总计 %d" % total)
	var summary := " · ".join(parts)
	if dc > 0:
		summary += " · DC %d" % dc
	var level_name := String(payload.get("level_name", ""))
	if not level_name.is_empty():
		summary += " · " + level_name
	return summary