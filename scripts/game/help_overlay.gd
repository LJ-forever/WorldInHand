extends Control
## 旅途手册：用分页收纳操作、移动/AP、侦察/迷雾、袭击/战斗、背包/装备、同伴/目标。
## 顶部问号打开，避免把长提示塞进底栏造成溢出。

signal closed

@onready var close_button: Button = $Center/Panel/Margin/VBox/Header/CloseButton
@onready var page_title: Label = $Center/Panel/Margin/VBox/PageTitle
@onready var page_body: Label = $Center/Panel/Margin/VBox/Scroll/PageBody
@onready var prev_button: Button = $Center/Panel/Margin/VBox/Footer/PrevButton
@onready var next_button: Button = $Center/Panel/Margin/VBox/Footer/NextButton
@onready var page_label: Label = $Center/Panel/Margin/VBox/Footer/PageLabel

var _page_index: int = 0
var _pages: Array[Dictionary] = [
	{
		"title": "操作",
		"body": "· 左键：从角色所在格按住拖动，松开后生成路径。可以只画当前地块内的一小段。\n· 右键：清除已画路径。空格或「沿路径移动」：出发。\n· 滚轮：缩放地图；中键拖动：平移；Home：复位视角。\n· 底部「背包」：打开行囊与装备页。\n· 右上「？」：随时打开这本手册；Esc：暂停。\n\n画线时只记录路线，不会提前告诉你 AP 消耗或能否走到。AP 在移动动画中按实际走过的距离连续扣除；进入新地块时才触发到达事件。\n\n界面提示：\n· 左上状态条持续显示诅咒、祝福、流血等效果；红色是负面，绿色是祝福。悬停可看完整数值、持续回合与药水能否解除。\n· 左下旅途纪事记录事件与同伴动向。点标题栏「收起/展开」可折叠；鼠标悬停后用滚轮浏览全部记录。\n· 事件选择前只显示选项与风险档位；选择并完成检定后，结算页才列出实际获得的物品、状态、数值与指引，不会提前剧透结果。",
	},
	{
		"title": "移动与 AP",
		"body": "· 每回合开始掷 1d6，加上速度与装备加值，就是本回合 AP（上限 12）。\n· AP 按实际走过的路径距离连续消耗：距离 × 基础系数 × 目标地形系数，再叠加爬升高差。同一地块内反复移动也会扣 AP。\n· 进入相邻格需要多少 AP，取决于你从当前格的哪个位置出发：靠近共享边界更省，远离边界更贵。\n· 路径可以完全在当前地块内；AP 耗尽时角色停在画线上的真实位置，不会跳回地块中心。下次从标记附近起笔即可继续。\n· 被困：无法画线，也无法进入终点。回合结束做一次体力检定 DC 10；成功解除，失败再持续 1 回合，最多 2 回合。\n· 事件、战斗或移动动画期间不能画线；此时点击地图会直接显示原因。\n\n提示：每回合的 AP 掷骰会以骰子动画出现在屏幕上方。",
	},
	{
		"title": "侦察与视野",
		"body": "· 侦察消耗 2 AP：2d6 + 感知 + 装备/状态，对抗地形 DC。\n· 成功：圆形视野向外扩张「感知 ÷ 2 + 1」格，保持 2 回合，之后每回合收缩 0.5 格。\n· 大成功：额外 +1 格，并定位最近的未探索 POI。\n· 大失败：你的位置暴露给所有 AI，持续 1 回合。\n\n迷雾是独立覆盖层：\n· 每个地块的地形底色始终先绘制，不会被迷雾替换。\n· 从未探索：地形上盖一层近黑的未知迷雾。\n· 曾经探索、现在不在视野内：盖一层低亮度记忆迷雾，仍能辨认地形颜色。\n· 当前圆形视野内：覆盖层被圆弧裁掉，显示完整亮度。",
	},
	{
		"title": "袭击与战斗",
		"body": "· 只有同伴与你相邻（1 格）且关系为「敌对」时，「袭击」按钮才可用。\n· 袭击消耗 1 AP：2d6 + 战斗 + 装备/状态，对抗 8 + 体力 + 防御装备。\n· 命中造成 1d3 伤害；大成功 1d6；失败可能额外损失 AP/HP。\n· 袭击能击倒或削弱敌方同伴，阻止她抢先抵达终点，或让她无法继续偷袭你。\n· 她若存活、仍有 1 AP 且保持敌对，会立刻反击。\n\n按钮不可用时，把鼠标停在按钮上会说明原因：不在相邻格、关系不敌对、AP 不足或当前不能行动。开场白会直接告诉你最初的关系；关系会随事件与好感变化。",
	},
	{
		"title": "背包与装备",
		"body": "· 点击底部「背包」，打开左侧装备栏、右侧背包。\n· 鼠标悬停物品：显示名称、类型、稀有度、效果与描述。\n· 把右侧可装备物品拖到左侧槽位即可穿戴；也可以点击物品直接装备。\n· 点击左侧已装备物品可以卸下，放回背包。\n· 每个角色有 4 个装备槽。装备立即改变 AP、战斗、侦察、交涉、事件幸运或上坡消耗。\n· 消耗品、材料与任务物品不能装备。\n\n背包按物品「种类」计 8 格，同种物品叠加仍只占 1 格。\n· 满格时新获得的物品会先排队：在背包页点击一件物品丢弃即可收下新物品，或点「放弃」让它永久丢失。\n· 未完成取舍前，背包页不能关闭。\n· 若影偷走了你的物品，背包页顶部会出现「追查失物（免费）」：每回合一次感知检定 DC 12，不耗 AP；成功归还物品、她的好感 −3，但不会撤销她已完成的任务。击败影则会直接取回失物。\n\n初始装备已经穿在身上；背包里可能只有药水或材料，所以之前看不到装备效果是正常的。",
	},
	{
		"title": "同伴与目标",
		"body": "· 开场白会交代：你是谁、她是谁、你们为什么同行、为什么在岔路口分开出发。\n· 开场白会直接写明你们最初的关系：互相照应、同路试探或旧怨未清。\n· 同伴独立行动：侦察、探索、搜集物资、支援、偷窃、下套或袭击。她不会一直跟着你。\n· 情报等级随侦察成功和事件线索提升；等级越高，越能看清她的动机、阵营与好感。\n· 目标：在 40 回合内抵达终点，并主动激活地图上的检查点（青色标记）解除终点封印；三处仪式的选择会在封印闭合时形成不同的最终共鸣，并在结算回顾中显示。没有检查点的旧地图改为先踏足 3 处地点。封印未解时无法进入终点格。先到者获得 +20 金币；若敌对同伴先到，完美胜利降为基础胜利；同回合到达仍算并列。\n· 地图上的商店（金色）、旅店（蓝色）和检查点（青色）始终可见；鼠标悬停只显示名称、距离和是否已激活。进入商店会打开交易页，进入旅店会打开休息页，检查点则触发封印仪式并让你选择一种誓约。普通 POI 只有探索或侦察后才会显示。\n· 守卫退开后本回合不会再出现，但终点入口会封闭到下一回合；每局最多成功退开 2 次；连续两次检定失败后，守卫的 DC 会降低 2 点。\n· 敌对同伴完成自己的互斥目标会改变你的结局：影第一次动手前会先警告一轮；首次得手时若她仍为友方/中立，则转为敌对并留下失物，不立即判负；若她已与你敌对，则直接判负。薇拉成功施困后，你若带着「被困」抵达终点或超时未到，也会失败。\n\n友方同伴会分享沿途地形、替你处理伤势；敌对同伴会在相邻时出手。你的行为也会改变她的好感与立场。",
	},
]


func _ready() -> void:
	visible = false
	close_button.pressed.connect(close)
	prev_button.pressed.connect(_previous_page)
	next_button.pressed.connect(_next_page)
	_render_page()


func open() -> void:
	visible = true
	_render_page()
	close_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _previous_page() -> void:
	_page_index = maxi(0, _page_index - 1)
	_render_page()


func _next_page() -> void:
	_page_index = mini(_pages.size() - 1, _page_index + 1)
	_render_page()


func show_page(index: int) -> void:
	_page_index = clampi(index, 0, _pages.size() - 1)
	_render_page()


func _render_page() -> void:
	var page: Dictionary = _pages[_page_index]
	page_title.text = String(page.get("title", ""))
	page_body.text = String(page.get("body", ""))
	page_label.text = "%d / %d" % [_page_index + 1, _pages.size()]
	prev_button.disabled = _page_index <= 0
	next_button.disabled = _page_index >= _pages.size() - 1