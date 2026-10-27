extends Node
## 单槽自动存档。只保存版本、地图配置/实际种子与运行时状态；
## 地图由种子精确重建，静态角色/事件数据不复制进存档。
##
## 存档格式：
## {
##   "format": "zhenming.save", "save_version": 1, "game_version": "1.12",
##   "saved_at": "...", "meta": {...},
##   "map": {config, generated_seed, terrain_seed, seed_value, fog},
##   "player": {...}, "companion": {...}, "events": {...}, "game": {...}, "rng": {...}
## }

const SAVE_DIR := "user://saves"
const SAVE_FORMAT := "zhenming.save"
## 结构不兼容时递增；读档只接受完全相同的版本。
const SAVE_VERSION := 1
const GAME_VERSION := "1.12"
const DEFAULT_SLOT := "auto"

var last_error: String = ""
var last_saved_at: String = ""
## 自动化统计/压力测试可关闭写入，避免覆盖玩家存档；读档接口仍然可用。
var write_enabled: bool = true


func save_path(slot: String = DEFAULT_SLOT) -> String:
	var clean := slot.strip_edges()
	if clean.is_empty():
		clean = DEFAULT_SLOT
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		clean = clean.replace(bad, "_")
	return "%s/%s.json" % [SAVE_DIR, clean]


## 只在安全边界写入：行动结束、回合结束、侦察/休息/战斗关闭之后。
func save_game(slot: String = DEFAULT_SLOT) -> bool:
	last_error = ""
	if not write_enabled:
		last_error = "存档写入已关闭。"
		return false
	if not GameManager.can_save_game():
		last_error = "当前状态不能存档（移动、事件或战斗尚未结束）。"
		return false
	var data := GameManager.build_save_data()
	if data.is_empty():
		last_error = "游戏状态不完整，无法生成存档。"
		return false
	var now := _timestamp()
	data["format"] = SAVE_FORMAT
	data["save_version"] = SAVE_VERSION
	data["game_version"] = GAME_VERSION
	data["saved_at"] = now
	var meta: Dictionary = data.get("meta", {})
	meta["saved_at"] = now
	meta["game_version"] = GAME_VERSION
	data["meta"] = meta
	if not _write_save(slot, data):
		return false
	last_saved_at = now
	return true


func load_game(slot: String = DEFAULT_SLOT) -> Dictionary:
	last_error = ""
	var data := _read_save(slot)
	if data.is_empty():
		return {"ok": false, "error": last_error}
	var result := GameManager.restore_save_data(data)
	if not bool(result.get("ok", false)):
		last_error = String(result.get("error", "存档内容无法恢复。"))
		result["error"] = last_error
		return result
	return result


func has_save(slot: String = DEFAULT_SLOT) -> bool:
	return not _read_save(slot).is_empty()


## 主菜单使用：只读元信息，不改变当前游戏状态。
func peek_save(slot: String = DEFAULT_SLOT) -> Dictionary:
	var data := _read_save(slot)
	if data.is_empty():
		return {}
	return {
		"ok": true,
		"meta": data.get("meta", {}).duplicate(true),
		"saved_at": String(data.get("saved_at", "")),
		"game_version": String(data.get("game_version", "")),
	}


func clear_save(slot: String = DEFAULT_SLOT) -> bool:
	last_error = ""
	if not write_enabled:
		return true
	var path := save_path(slot)
	if not FileAccess.file_exists(path):
		return true
	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if error != OK:
		last_error = "无法删除存档：%s" % error_string(error)
		return false
	return true


func _write_save(slot: String, data: Dictionary) -> bool:
	var dir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	if dir_error != OK and dir_error != ERR_ALREADY_EXISTS:
		last_error = "无法创建存档目录：%s" % error_string(dir_error)
		return false
	var path := save_path(slot)
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		last_error = "无法写入存档：%s" % error_string(FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	file.close()
	if FileAccess.file_exists(path):
		var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if remove_error != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
			last_error = "无法替换旧存档：%s" % error_string(remove_error)
			return false
	var rename_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(path)
	)
	if rename_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
		last_error = "无法保存存档：%s" % error_string(rename_error)
		return false
	return true


func _read_save(slot: String) -> Dictionary:
	last_error = ""
	var path := save_path(slot)
	if not FileAccess.file_exists(path):
		last_error = "没有找到自动存档。"
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "无法读取存档：%s" % error_string(FileAccess.get_open_error())
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		last_error = "存档已损坏，无法解析（第 %d 行：%s）。" % [
			json.get_error_line(), json.get_error_message(),
		]
		return {}
	if not (json.data is Dictionary):
		last_error = "存档已损坏，顶层内容不是对象。"
		return {}
	var data: Dictionary = json.data
	if String(data.get("format", "")) != SAVE_FORMAT:
		last_error = "存档格式无法识别。"
		return {}
	if int(data.get("save_version", 0)) != SAVE_VERSION:
		last_error = "存档版本不兼容（存档 %d，当前 %d）。" % [
			int(data.get("save_version", 0)), SAVE_VERSION,
		]
		return {}
	return data


func _timestamp() -> String:
	return Time.get_datetime_string_from_system(false, true)