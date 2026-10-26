extends Node
## 随机流管理：同一 master_seed 下按用途分流，保证地图/事件/战斗/AI 可复现。
## 玩法逻辑待 P0 实现，这里只提供基础骰子接口。

var master_seed: int = 0
var _streams: Dictionary = {}


func set_seed(value: int) -> void:
	master_seed = value
	_streams.clear()


func get_stream(stream_name: String = "default") -> RandomNumberGenerator:
	if not _streams.has(stream_name):
		var rng := RandomNumberGenerator.new()
		rng.seed = hash("%d:%s" % [master_seed, stream_name])
		_streams[stream_name] = rng
	return _streams[stream_name]


func roll_1d6(stream_name: String = "default") -> int:
	return get_stream(stream_name).randi_range(1, 6)


func roll_2d6(stream_name: String = "default") -> Array[int]:
	var rng := get_stream(stream_name)
	return [rng.randi_range(1, 6), rng.randi_range(1, 6)]


func roll_chance(probability: float, stream_name: String = "default") -> bool:
	return get_stream(stream_name).randf() < probability


func randf_range(from: float, to: float, stream_name: String = "default") -> float:
	return get_stream(stream_name).randf_range(from, to)


## 存档用：记录主种子与每条已使用随机流的位置。
## state 是 64 位整数，JSON 数字可能丢精度，因此统一转成十进制字符串。
func snapshot_state() -> Dictionary:
	var states := {}
	for stream_name in _streams.keys():
		var rng: RandomNumberGenerator = _streams[stream_name]
		states[String(stream_name)] = str(rng.state)
	return {
		"master_seed": master_seed,
		"streams": states,
	}


## 读档用：主种子恢复后直接还原各流状态；未记录的流下次按主种子惰性创建。
func restore_state(data: Dictionary) -> bool:
	if not (data.has("master_seed") and data.get("streams") is Dictionary):
		return false
	master_seed = int(data.get("master_seed", 0))
	_streams.clear()
	var states: Dictionary = data.get("streams", {})
	for stream_name in states.keys():
		var rng := RandomNumberGenerator.new()
		rng.state = int(String(states[stream_name]))
		_streams[String(stream_name)] = rng
	return true
