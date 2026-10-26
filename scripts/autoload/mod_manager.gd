extends Node
## 模组：P3 功能，MVP 只保留扫描入口。

const MOD_DIRS := ["res://mods", "user://mods"]


func scan_mods() -> Array:
	# TODO(P3)：读取 manifest.json、按加载顺序合并、命名空间隔离。
	return []
