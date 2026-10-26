extends Control
## 主界面（首页）：开始游戏 → 地图文件选择 → 角色选择；有自动存档时可继续。

@onready var continue_button: Button = $Center/VBox/ContinueButton
@onready var start_button: Button = $Center/VBox/StartButton
@onready var quit_button: Button = $Center/VBox/QuitButton
@onready var status_label: Label = $Center/VBox/Status
@onready var footer: Label = $Footer


func _ready() -> void:
	continue_button.pressed.connect(_on_continue_pressed)
	start_button.pressed.connect(_on_start_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	var configs := MapConfigLoader.list_configs()
	if DataManager.load_errors.is_empty():
		status_label.text = "数据自检通过 · 可载入地图 %d 张" % configs.size()
		status_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.55))
	else:
		status_label.text = "数据自检失败：%s" % String(DataManager.load_errors[0])
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))
	footer.text = "v%s · 边陲荒原 · 叙事与旅途原型" % SaveManager.GAME_VERSION
	_update_continue_button()
	if continue_button.visible:
		continue_button.grab_focus()
	else:
		start_button.grab_focus()


func _update_continue_button() -> void:
	var save_info := SaveManager.peek_save(SaveManager.DEFAULT_SLOT)
	if save_info.is_empty():
		continue_button.visible = false
		return
	var meta: Dictionary = save_info.get("meta", {})
	var player_name := String(meta.get("player_name", "旅人"))
	var map_name := String(meta.get("map_name", "荒原"))
	var round_index := int(meta.get("round", 1))
	var hp := int(meta.get("hp", 0))
	var hp_max := int(meta.get("hp_max", 0))
	var goal_distance := int(meta.get("goal_distance", 0))
	continue_button.visible = true
	continue_button.text = "继续游戏 · 第 %d 回合" % round_index
	continue_button.tooltip_text = "%s · %s\nHP %d / %d · 距终点约 %d 格\n保存于 %s" % [
		player_name,
		map_name,
		hp,
		hp_max,
		goal_distance,
		String(save_info.get("saved_at", "")),
	]


func _on_continue_pressed() -> void:
	var result := SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	if not bool(result.get("ok", false)):
		status_label.text = "读取存档失败：%s" % String(result.get("error", SaveManager.last_error))
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))
		_update_continue_button()
		return
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu/map_select.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
