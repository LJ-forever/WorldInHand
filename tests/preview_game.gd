extends Node
## 开发用预览入口：跳过菜单，直接用第一张地图进入游戏并预置一条自由笔迹。
## 运行：Godot ... --path . res://tests/preview_game.tscn

func _ready() -> void:
	var configs := MapConfigLoader.list_configs()
	if configs.is_empty():
		push_error("预览失败：没有地图配置")
		get_tree().quit(1)
		return
	if not GameManager.start_new_game("lin_xiao", configs[0]):
		push_error("预览开局失败")
		get_tree().quit(1)
		return
	var map := GameManager.map
	var player := GameManager.player
	if not map.poi_ids.is_empty():
		var route := map.shortest_cell_path(player.cell_id, map.poi_ids[0])
		var stroke := PackedVector2Array([map.cell_center(player.cell_id)])
		for cell_id in route:
			stroke.append(map.cell_center(cell_id))
		GameManager.set_drawn_path(stroke)
	get_tree().call_deferred("change_scene_to_file", "res://scenes/game/game.tscn")
