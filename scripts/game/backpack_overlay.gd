extends Control
## 背包与装备页：左装备栏、右背包。
## 悬停显示物品详情；把右侧可装备物品拖到左侧槽位即可穿戴，点击已装备物品可卸下。

const TYPE_NAMES := {
	"equipment": "装备",
	"consumable": "消耗品",
	"material": "材料",
	"quest": "任务物品",
}
const RARITY_NAMES := {
	"common": "普通",
	"uncommon": "精良",
	"rare": "稀有",
}
const DETAIL_DEFAULT := "把鼠标移到物品上查看详情。装备会立即改变属性。"

signal closed

@onready var close_button: Button = $Center/Panel/Margin/VBox/Header/CloseButton
@onready var equip_title: Label = $Center/Panel/Margin/VBox/Body/Left/EquipTitle
@onready var equip_slots: VBoxContainer = $Center/Panel/Margin/VBox/Body/Left/EquipSlots
@onready var bag_title: Label = $Center/Panel/Margin/VBox/Body/Right/BagTitle
@onready var grid: GridContainer = $Center/Panel/Margin/VBox/Body/Right/Scroll/Grid
@onready var detail_label: Label = $Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/DetailLabel
@onready var use_actions: HBoxContainer = $Center/Panel/Margin/VBox/DetailPanel/DetailMargin/DetailVBox/UseActions

var _detail_override: String = ""
var _selected_consumable: String = ""


func _ready() -> void:
	visible = false
	close_button.pressed.connect(close)
	GameManager.player_moved.connect(_on_player_changed)


func open() -> void:
	_detail_override = ""
	_selected_consumable = ""
	_clear_use_actions()
	refresh()
	visible = true
	close_button.grab_focus()


func close() -> void:
	if not visible:
		return
	_selected_consumable = ""
	_clear_use_actions()
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func refresh() -> void:
	if GameManager.player == null:
		return
	_build_equipment()
	_build_inventory()
	if _detail_override.is_empty():
		detail_label.text = DETAIL_DEFAULT
	else:
		detail_label.text = _detail_override


func _on_player_changed() -> void:
	if visible:
		refresh()


func _build_equipment() -> void:
	var player := GameManager.player
	equip_title.text = "装备栏 %d / %d" % [player.equipment.size(), ActorState.EQUIP_SLOT_LIMIT]
	_clear_container(equip_slots)
	for i in range(ActorState.EQUIP_SLOT_LIMIT):
		var slot := ItemSlot.new()
		slot.source = "equipment"
		slot.drag_allowed = false
		slot.custom_minimum_size = Vector2(276, 78)
		slot.add_theme_font_size_override("font_size", 14)
		slot.item_hovered.connect(_on_item_hovered)
		slot.item_unhovered.connect(_on_item_unhovered)
		slot.inventory_item_dropped.connect(_on_equip_dropped)
		if i < player.equipment.size():
			var item_id := String(player.equipment[i])
			slot.item_id = item_id
			slot.text = _slot_text(item_id, 1, true)
			slot.tooltip_text = _item_detail(item_id, true)
			slot.pressed.connect(_on_equipment_pressed.bind(item_id))
		else:
			slot.text = "空槽位 %d\n把右侧装备拖到这里" % (i + 1)
			slot.disabled = false
		equip_slots.add_child(slot)


func _build_inventory() -> void:
	var player := GameManager.player
	var counts: Dictionary = {}
	var order: Array[String] = []
	for raw_id in player.inventory:
		var item_id := String(raw_id)
		if not counts.has(item_id):
			counts[item_id] = 0
			order.append(item_id)
		counts[item_id] = int(counts[item_id]) + 1
	bag_title.text = "背包 · %d 件" % player.inventory.size()
	_clear_container(grid)
	grid.columns = 3
	if order.is_empty():
		grid.columns = 1
		var empty := Label.new()
		empty.text = "背包是空的。沿途的 POI、事件和同伴都可能带来物资。"
		empty.custom_minimum_size = Vector2(520, 54)
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", Color(0.60, 0.58, 0.50))
		empty.add_theme_font_size_override("font_size", 14)
		grid.add_child(empty)
		return
	for item_id in order:
		if item_id.is_empty():
			continue
		var count := int(counts[item_id])
		var equippable := player.is_equippable(item_id)
		var slot := ItemSlot.new()
		slot.source = "inventory"
		slot.drag_allowed = equippable
		slot.item_id = item_id
		slot.custom_minimum_size = Vector2(168, 82)
		slot.add_theme_font_size_override("font_size", 13)
		slot.text = _slot_text(item_id, count, false)
		slot.tooltip_text = _item_detail(item_id)
		slot.item_hovered.connect(_on_item_hovered)
		slot.item_unhovered.connect(_on_item_unhovered)
		slot.pressed.connect(_on_inventory_pressed.bind(item_id))
		grid.add_child(slot)


func _slot_text(item_id: String, count: int, equipped: bool) -> String:
	var record := DataManager.get_record("items", item_id)
	var item_name := String(record.get("name", item_id))
	var type_id := String(record.get("type", ""))
	var heading := item_name if count <= 1 else "%s ×%d" % [item_name, count]
	if equipped:
		return "%s\n已装备 · 点击卸下" % heading
	if type_id == "equipment":
		return "%s\n可装备 · 拖到左侧" % heading
	if type_id == "consumable":
		return "%s\n可使用 · 点击选择" % heading
	return "%s\n%s" % [heading, String(TYPE_NAMES.get(type_id, type_id))]


func _item_detail(item_id: String, equipped: bool = false) -> String:
	if item_id.is_empty():
		return DETAIL_DEFAULT
	var record := DataManager.get_record("items", item_id)
	if record.is_empty():
		return "未知物品：%s" % item_id
	var type_id := String(record.get("type", ""))
	var type_name := String(TYPE_NAMES.get(type_id, type_id))
	var rarity := String(RARITY_NAMES.get(String(record.get("rarity", "")), record.get("rarity", "")))
	var lines: Array[String] = [
		"「%s」 · %s%s" % [
			String(record.get("name", item_id)),
			type_name,
			"" if rarity.is_empty() else " · %s" % rarity,
		],
	]
	if type_id == "equipment":
		lines.append("效果：%s" % _effects_text(record))
	elif type_id == "consumable":
		lines.append("效果：%s" % _consumable_effect_text(record))
	lines.append(String(record.get("description", "没有更多记载。")))
	if type_id == "equipment":
		if equipped:
			lines.append("操作：已装备，点击此处卸下并放回背包。")
		else:
			lines.append("操作：把右侧背包中的这件物品拖到左侧装备栏，或点击此处直接装备。")
	elif type_id == "consumable":
		lines.append("操作：点击此物品，在下方选择立即使用。使用会消耗 1 件。")
	else:
		lines.append("操作：这件物品不能直接使用，留给交易、任务或终点献祭。")
	return "\n".join(lines)


func _consumable_effect_text(record: Dictionary) -> String:
	var effects: Dictionary = record.get("effects", {})
	match String(effects.get("use", "")):
		"choose_hp_or_ap_1":
			return "恢复 1 HP 或 1 AP"
		"remove_one_negative_status":
			return "解除 1 个可解除的负面状态"
		_:
			return "没有可直接使用的效果"


func _effects_text(record: Dictionary) -> String:
	var effects: Dictionary = record.get("effects", {})
	var parts: Array[String] = []
	if effects.has("ap_bonus"):
		parts.append("AP %+d" % int(effects["ap_bonus"]))
	if effects.has("ap_bonus_disabled_terrains"):
		var terrains: Array = effects["ap_bonus_disabled_terrains"]
		var names: Array[String] = []
		for terrain_id in terrains:
			names.append(String(DataManager.get_record("terrains", String(terrain_id)).get("name", terrain_id)))
		parts.append("（%s无效）" % "、".join(names))
	if effects.has("combat"):
		parts.append("战斗 %+d" % int(effects["combat"]))
	if effects.has("scout_check_bonus"):
		parts.append("侦察 %+d" % int(effects["scout_check_bonus"]))
	if effects.has("negotiation_check_bonus"):
		parts.append("交涉 %+d" % int(effects["negotiation_check_bonus"]))
	if effects.has("luck_event"):
		parts.append("事件幸运 %+d" % int(effects["luck_event"]))
	if effects.has("uphill_penalty_modifier"):
		parts.append("上坡惩罚 %+.1f AP/层" % float(effects["uphill_penalty_modifier"]))
	if effects.has("max_equipped"):
		parts.append("最多装备 %d 件" % int(effects["max_equipped"]))
	if parts.is_empty():
		return "无被动加成"
	return "、".join(parts)


func _on_item_hovered(item_id: String) -> void:
	_detail_override = ""
	var equipped := GameManager.player != null and GameManager.player.equipment.has(item_id)
	detail_label.text = _item_detail(item_id, equipped)


func _on_item_unhovered(_item_id: String) -> void:
	if not _selected_consumable.is_empty():
		detail_label.text = _item_detail(_selected_consumable)
		return
	_detail_override = ""
	detail_label.text = DETAIL_DEFAULT


func _on_inventory_pressed(item_id: String) -> void:
	var record := DataManager.get_record("items", item_id)
	if String(record.get("type", "")) == "consumable":
		_selected_consumable = item_id
		_detail_override = _item_detail(item_id)
		detail_label.text = _detail_override
		_show_use_actions(item_id)
		return
	_selected_consumable = ""
	_clear_use_actions()
	if not GameManager.player.is_equippable(item_id):
		detail_label.text = "「%s」不能装备，也不能直接使用。" % String(record.get("name", item_id))
		return
	_equip(item_id)


func _on_equip_dropped(item_id: String) -> void:
	_selected_consumable = ""
	_clear_use_actions()
	_equip(item_id)


func _equip(item_id: String) -> void:
	var result := GameManager.player.equip_item(item_id)
	_detail_override = String(result.get("message", ""))
	refresh()
	if bool(result.get("ok", false)):
		GameManager.inventory_changed.emit()
		GameManager.player_moved.emit()


func _on_equipment_pressed(item_id: String) -> void:
	var result := GameManager.player.unequip_item(item_id)
	_detail_override = String(result.get("message", ""))
	refresh()
	if bool(result.get("ok", false)):
		GameManager.inventory_changed.emit()
		GameManager.player_moved.emit()


func _show_use_actions(item_id: String) -> void:
	_clear_use_actions()
	var options := GameManager.consumable_options(item_id)
	use_actions.visible = true
	var title := Label.new()
	title.text = "使用："
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(0.70, 0.72, 0.62))
	use_actions.add_child(title)
	for option in options:
		var button := Button.new()
		button.text = String(option.get("label", "使用"))
		button.disabled = bool(option.get("disabled", false))
		button.tooltip_text = String(option.get("reason", ""))
		button.add_theme_font_size_override("font_size", 13)
		button.pressed.connect(_on_use_pressed.bind(item_id, String(option.get("id", ""))))
		use_actions.add_child(button)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.add_theme_font_size_override("font_size", 13)
	cancel.pressed.connect(_clear_selection)
	use_actions.add_child(cancel)


func _on_use_pressed(item_id: String, option: String) -> void:
	var result := GameManager.use_item(item_id, option)
	_detail_override = String(result.get("message", ""))
	_selected_consumable = ""
	_clear_use_actions()
	refresh()


func _clear_selection() -> void:
	_selected_consumable = ""
	_detail_override = ""
	_clear_use_actions()
	detail_label.text = DETAIL_DEFAULT


func _clear_use_actions() -> void:
	use_actions.visible = false
	_clear_container(use_actions)


func _clear_container(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()