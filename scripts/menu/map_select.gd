extends Control
## 地图文件选择：列出 data/maps/*.json；标了 randomize_seed 的地图每次开局重新生成。

@onready var back_button: Button = $Margin/VBox/Header/BackButton
@onready var open_button: Button = $Margin/VBox/Header/OpenButton
@onready var map_grid: GridContainer = $Margin/VBox/Scroll/Center/MapGrid
@onready var status_label: Label = $Margin/VBox/Status
@onready var file_dialog: FileDialog = $FileDialog

var _configs: Array[Dictionary] = []


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	open_button.pressed.connect(_on_open_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	file_dialog.current_dir = ProjectSettings.globalize_path("res://data/maps")
	_configs = MapConfigLoader.list_configs()
	_populate()
	if _configs.is_empty():
		status_label.text = "没有找到内置地图配置，请检查 data/maps/*.json"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))
	else:
		var random_count := 0
		for config in _configs:
			if bool(config.get("randomize_seed", false)):
				random_count += 1
		var random_note := (" · 其中 %d 张每局随机" % random_count) if random_count > 0 else ""
		status_label.text = "内置地图 %d 张%s · 点击卡片选择 · 也可以打开本地 JSON" % [_configs.size(), random_note]
		status_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.55))


func _populate() -> void:
	for child in map_grid.get_children():
		child.queue_free()
	for config in _configs:
		_add_map_card(config)


func _add_map_card(config: Dictionary) -> void:
	var description := String(config.get("description", ""))
	if description.length() > 20:
		description = description.substr(0, 20) + "…"
	var randomize := bool(config.get("randomize_seed", false))
	var button := Button.new()
	button.custom_minimum_size = Vector2(340, 150)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", 14)
	if randomize:
		button.text = "%s\n每局重新生成 · %d 地块 · %d POI\n角色 %d · 事件 %d\n%s" % [
			String(config.get("name", "未命名地图")),
			int(config.get("cell_count", 0)),
			int(config.get("poi_count", 0)),
			GameManager.available_character_ids(config).size(),
			GameManager.available_event_ids(config).size(),
			description,
		]
		button.tooltip_text = "每次进入都会重新生成地块形状、生态分布、海拔与 POI。\n" + description
	else:
		button.text = "%s\n种子 %d · %d 地块 · %d POI\n角色 %d · 事件 %d\n%s" % [
			String(config.get("name", "未命名地图")),
			int(config.get("seed", 0)),
			int(config.get("cell_count", 0)),
			int(config.get("poi_count", 0)),
			GameManager.available_character_ids(config).size(),
			GameManager.available_event_ids(config).size(),
			description,
		]
		button.tooltip_text = description
	button.pressed.connect(_select_config.bind(config))
	map_grid.add_child(button)


func _select_config(config: Dictionary) -> void:
	GameManager.select_map(config)
	get_tree().change_scene_to_file("res://scenes/menu/character_select.tscn")


func _on_open_pressed() -> void:
	file_dialog.popup_centered_ratio(0.72)


func _on_file_selected(path: String) -> void:
	var config := MapConfigLoader.load_config(path)
	if config.is_empty():
		status_label.text = "无法读取地图文件：%s" % path
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))
		return
	_select_config(config)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu/main_menu.tscn")
