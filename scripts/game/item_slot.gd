class_name ItemSlot
extends Button
## 背包/装备栏里的一个物品格。
## 背包格支持拖拽；装备格接受背包格拖入，并可用点击卸下。
## 所有规则判定集中在 ActorState / BackpackOverlay，这里只处理交互与视觉。

signal item_hovered(item_id: String)
signal item_unhovered(item_id: String)
signal inventory_item_dropped(item_id: String)

var item_id: String = ""
var source: String = "inventory"
var drag_allowed: bool = true


func _ready() -> void:
	mouse_entered.connect(func() -> void: item_hovered.emit(item_id))
	mouse_exited.connect(func() -> void: item_unhovered.emit(item_id))


func _get_drag_data(_at_position: Vector2):
	if item_id.is_empty() or not drag_allowed:
		return null
	var record := DataManager.get_record("items", item_id)
	var preview := PanelContainer.new()
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	var label := Label.new()
	label.text = String(record.get("name", item_id))
	label.add_theme_font_size_override("font_size", 15)
	margin.add_child(label)
	preview.add_child(margin)
	if get_viewport().gui_is_dragging():
		set_drag_preview(preview)
	return {"item_id": item_id, "source": source}


func _can_drop_data(_at_position: Vector2, data) -> bool:
	if source != "equipment":
		return false
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var payload: Dictionary = data
	return String(payload.get("source", "")) == "inventory" and not String(payload.get("item_id", "")).is_empty()


func _drop_data(_at_position: Vector2, data) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	inventory_item_dropped.emit(String((data as Dictionary).get("item_id", "")))