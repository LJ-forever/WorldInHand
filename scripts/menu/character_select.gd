extends Control
## 角色选择：所选地图已在上一屏确定。点击角色卡片进入游戏。

@onready var back_button: Button = $Margin/VBox/Header/BackButton
@onready var map_label: Label = $Margin/VBox/MapLabel
@onready var character_grid: GridContainer = $Margin/VBox/Center/CharacterGrid
@onready var status_label: Label = $Margin/VBox/Status


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	_ensure_selected_map()
	_update_map_label()
	_populate_characters()
	if DataManager.load_errors.is_empty():
		var random_note := " · 进入时重新生成地图" if bool(GameManager.selected_map_config.get("randomize_seed", false)) else ""
		status_label.text = "点击角色开始%s · 数据自检通过" % random_note
		status_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.55))
	else:
		status_label.text = "数据自检失败：%s" % String(DataManager.load_errors[0])
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))


func _ensure_selected_map() -> void:
	if not GameManager.selected_map_config.is_empty():
		return
	var configs := MapConfigLoader.list_configs()
	if not configs.is_empty():
		GameManager.select_map(configs[0])
	else:
		GameManager.select_map(MapGenerator.DEFAULT_CONFIG.duplicate(true))


func _update_map_label() -> void:
	var config := GameManager.selected_map_config
	if config.is_empty():
		map_label.text = "地图：未选择"
		return
	var roster := GameManager.available_character_ids(config)
	var events := GameManager.available_event_ids(config)
	var seed_text := "每局随机" if bool(config.get("randomize_seed", false)) else str(int(config.get("seed", 0)))
	map_label.text = "地图：%s · 种子 %s · %d 地块 · %d POI · 角色 %d · 事件 %d" % [
		String(config.get("name", "未命名地图")),
		seed_text,
		int(config.get("cell_count", 0)),
		int(config.get("poi_count", 0)),
		roster.size(),
		events.size(),
	]


func _populate_characters() -> void:
	for child in character_grid.get_children():
		child.queue_free()
	var roster := GameManager.available_character_ids(GameManager.selected_map_config)
	for id in roster:
		var record := DataManager.get_record("characters", id)
		if record.is_empty():
			continue
		var attributes: Dictionary = record.get("attributes", {})
		var button := Button.new()
		button.custom_minimum_size = Vector2(204, 152)
		button.add_theme_font_size_override("font_size", 14)
		button.text = "%s\n%s\n\n速 %d   体 %d   感 %d\n幸 %d   战 %d   交 %d" % [
			String(record.get("name", id)),
			String(record.get("role", "")),
			int(attributes.get("speed", 0)),
			int(attributes.get("stamina", 0)),
			int(attributes.get("perception", 0)),
			int(attributes.get("luck", 0)),
			int(attributes.get("combat", 0)),
			int(attributes.get("negotiation", 0)),
		]
		button.tooltip_text = _tooltip_for(record)
		button.pressed.connect(_on_character_pressed.bind(id))
		character_grid.add_child(button)


func _tooltip_for(record: Dictionary) -> String:
	var trait_ids := PackedStringArray()
	for trait_id in record.get("traits", []):
		trait_ids.append(String(trait_id))
	var equipment_names := PackedStringArray()
	for item_id in record.get("starting_equipment", []):
		var item := DataManager.get_record("items", String(item_id))
		equipment_names.append(String(item.get("name", item_id)))
	var item_names := PackedStringArray()
	for item_id in record.get("starting_items", []):
		var item := DataManager.get_record("items", String(item_id))
		item_names.append(String(item.get("name", item_id)))
	return "特性：%s\n装备：%s\n物品：%s" % [
		", ".join(trait_ids),
		", ".join(equipment_names) if not equipment_names.is_empty() else "无",
		", ".join(item_names) if not item_names.is_empty() else "无",
	]


func _on_character_pressed(character_id: String) -> void:
	if GameManager.selected_map_config.is_empty():
		_ensure_selected_map()
	if not GameManager.start_new_game(character_id, GameManager.selected_map_config):
		status_label.text = "开局失败：请检查地图与角色数据"
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.40))
		return
	get_tree().change_scene_to_file("res://scenes/game/game.tscn")


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu/map_select.tscn")
