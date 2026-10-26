extends Control
## 开场白：介绍玩家身份、同伴身份、同行原因、走散原因、目标与最初关系。
## 按「踏入荒原」后才会把操作交还给 HUD。

@onready var title_label: Label = $Center/Panel/Margin/VBox/Title
@onready var body_label: Label = $Center/Panel/Margin/VBox/Scroll/Body
@onready var relation_label: Label = $Center/Panel/Margin/VBox/Relation
@onready var enter_button: Button = $Center/Panel/Margin/VBox/EnterButton


func _ready() -> void:
	visible = false
	enter_button.pressed.connect(_on_enter_pressed)
	GameManager.intro_dismissed.connect(_on_intro_dismissed)
	if GameManager.intro_open:
		_show_story()


func _show_story() -> void:
	var story: Dictionary = GameManager.intro_story
	if story.is_empty():
		story = {
			"title": "风沙将起",
			"body": "你是旅人。边陲荒原在你们面前展开。",
			"relation": "关系：未知",
		}
	title_label.text = String(story.get("title", "风沙将起"))
	body_label.text = String(story.get("body", ""))
	relation_label.text = String(story.get("relation", ""))
	visible = true
	enter_button.grab_focus()


func _on_enter_pressed() -> void:
	visible = false
	GameManager.dismiss_intro()


func _on_intro_dismissed() -> void:
	visible = false