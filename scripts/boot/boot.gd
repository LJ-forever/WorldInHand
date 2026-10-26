extends Control
## 启动画面：只做数据自检展示，不含玩法入口。

@onready var status_label: Label = $Center/Panel/Status
@onready var detail_label: Label = $Center/Panel/Detail


func _ready() -> void:
	if DataManager.load_errors.is_empty():
		status_label.text = "数据自检通过  ·  " + DataManager.summary()
		status_label.add_theme_color_override("font_color", Color(0.62, 0.82, 0.52))
		detail_label.text = "数据与地图已就绪。当前可玩：主界面 → 选地图 → 选角色 → 自由画线 → 逐格移动 → 事件/侦察 → 主动战斗与胜利结算。\n待接入：双 AI 竞争、存档读档。"
	else:
		status_label.text = "数据自检发现 %d 个问题（详见控制台）" % DataManager.load_errors.size()
		status_label.add_theme_color_override("font_color", Color(0.95, 0.45, 0.4))
		detail_label.text = "\n".join(PackedStringArray(DataManager.load_errors.slice(0, 6)))
	print("[Boot] ", status_label.text)
