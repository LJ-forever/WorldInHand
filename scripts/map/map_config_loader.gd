class_name MapConfigLoader
extends RefCounted
## 地图配置文件加载器：扫描 data/maps/*.json，供主界面的地图选择使用。
## 每个文件就是一张地图；新增地图只需复制一份 JSON。

const MAP_DIR := "res://data/maps"
const REQUIRED_FIELDS := ["map_id", "name", "seed", "cell_count"]


static func list_configs() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var dir := DirAccess.open(MAP_DIR)
	if dir == null:
		push_warning("[MapConfigLoader] 无法打开地图目录：%s" % MAP_DIR)
		return results
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			var path := MAP_DIR + "/" + file_name
			var config := load_config(path)
			if not config.is_empty() and not bool(config.get("hidden", false)):
				results.append(config)
		file_name = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(_compare_configs)
	return results


static func load_config(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("[MapConfigLoader] 地图文件不存在：%s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_warning("[MapConfigLoader] 地图文件为空：%s" % path)
		return {}
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[MapConfigLoader] JSON 解析失败：%s" % path)
		return {}
	# 本地 JSON 可以只写 name/seed；缺省字段由生成器补齐。
	var config: Dictionary = MapGenerator.normalize_config(parsed)
	var errors := validate_config(config)
	if not errors.is_empty():
		for message in errors:
			push_warning("[MapConfigLoader] %s：%s" % [path, message])
		return {}
	config["source_path"] = path
	return config


static func validate_config(config: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for field in REQUIRED_FIELDS:
		if not config.has(field):
			errors.append("缺少字段 %s" % field)
	if errors.is_empty():
		if String(config.get("map_id", "")).is_empty():
			errors.append("map_id 不能为空")
		if String(config.get("name", "")).is_empty():
			errors.append("name 不能为空")
		if int(config.get("cell_count", 0)) < 150 or int(config.get("cell_count", 0)) > 800:
			errors.append("cell_count 需在 150～800 之间")
		if int(config.get("poi_count", 0)) < 1:
			errors.append("poi_count 至少为 1")
	var weights = config.get("terrain_weights", {})
	if typeof(weights) != TYPE_DICTIONARY or weights.is_empty():
		errors.append("terrain_weights 缺失")
	else:
		for terrain_id in weights.keys():
			if not DataManager.has_record("terrains", String(terrain_id)):
				errors.append("未知地形 %s" % terrain_id)
	var gradient = config.get("gradient", {})
	if typeof(gradient) == TYPE_DICTIONARY:
		for key in ["low", "high"]:
			if gradient.has(key) and not DataManager.has_record("terrains", String(gradient[key])):
				errors.append("梯度地形 %s 不存在" % gradient[key])
	if config.has("randomize_seed") and typeof(config.get("randomize_seed")) != TYPE_BOOL:
		errors.append("randomize_seed 必须是布尔值")
	_validate_content_ids(config, "character_ids", "characters", "角色", errors)
	_validate_content_ids(config, "event_ids", "events", "事件", errors)
	_validate_landmark_counts(config, errors)
	return errors


## 地标数量必须引用地标表中的 ID，且总数不能超过 POI 数；
## 省略该字段表示这张地图不生成固定地标，沿用旧的地图与封印逻辑。
static func _validate_landmark_counts(config: Dictionary, errors: Array[String]) -> void:
	if not config.has("landmark_counts"):
		return
	var counts = config.get("landmark_counts")
	if typeof(counts) != TYPE_DICTIONARY:
		errors.append("landmark_counts 必须是对象")
		return
	var total := 0
	for raw_id in (counts as Dictionary).keys():
		var landmark_id := String(raw_id)
		if not DataManager.has_record("landmarks", landmark_id):
			errors.append("未知地标 %s" % landmark_id)
		var count := int((counts as Dictionary)[raw_id])
		if count < 0:
			errors.append("地标 %s 的数量不能为负" % landmark_id)
		total += maxi(0, count)
	if total > int(config.get("poi_count", 0)):
		errors.append("地标总数 %d 超过 poi_count %d" % [total, int(config.get("poi_count", 0))])


## 地图内容清单：字段可省略（回退到全量内容），但一旦声明就必须是非空、无重复、全部存在的 ID。
static func _validate_content_ids(config: Dictionary, field: String, table: String, label: String, errors: Array[String]) -> void:
	if not config.has(field):
		return
	var values = config.get(field)
	if typeof(values) != TYPE_ARRAY:
		errors.append("%s 必须是数组" % field)
		return
	if (values as Array).is_empty():
		errors.append("%s 不能为空；不需要限制时请省略该字段" % field)
		return
	var seen: Dictionary = {}
	for value in values:
		var record_id := String(value)
		if record_id.is_empty():
			errors.append("%s 含空 ID" % field)
			continue
		if seen.has(record_id):
			errors.append("%s 中 %s 重复" % [field, record_id])
			continue
		seen[record_id] = true
		if not DataManager.has_record(table, record_id):
			errors.append("未知%s %s" % [label, record_id])


static func _compare_configs(a: Dictionary, b: Dictionary) -> bool:
	var order_a := int(a.get("order", 999))
	var order_b := int(b.get("order", 999))
	if order_a == order_b:
		return String(a.get("name", "")) < String(b.get("name", ""))
	return order_a < order_b
