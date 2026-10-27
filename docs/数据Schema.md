# 数据 Schema（v1.9）

所有内容数据位于 `res://data/`，UTF-8 JSON。改数据不需要改代码；改字段结构才需要同步本文件。v1.9 无新增/改名内容 JSON 字段，但新增效果类型 `goal_guard_suppress`（退开守卫），运行时与存档新增 `goal_guard_suppressed_round` / `goal_fail_streak` / `goal_withdraw_count` / `theft_warning_given`，`game_version` 升到 `1.9`、`save_version` 仍为 1；青蘅 `negotiation` 3 → 4；`goal_guard` 的 `sacrifice_item` 由自动通过改为消耗物品 + 交涉 DC 13（稀有度 +1/+2/+3），`withdraw` 增加每局 2 次上限与本回合压制。v1.8 无新增/改名 JSON 字段；修正阵营阈值口径为 `favor ≤ −3` 敌方、`favor ≥ +3` 友方（§11.3），影的偷窃任务改为初始中立并在任务完成前限制失败好感下限，另新增单段移动成本 3 AP 上限与终点守卫「退开」选项（`goal_guard` 的 `withdraw`，字段仍沿用既有 `choices` 结构）。v1.7 完成 P0 收口：存档新增 `companion.stolen_item_id` / `companion.recovery_attempt_round`（D-25 被偷物品与最近追查回合）和 `game.pending_item_overflows`（A3 背包满时待取舍的奖励队列），三者都必须原样跨读档保留；内容 JSON 字段不变。v1.6 补充正反馈闭环：事件结算新增运行时 `reward_entries` / `cost_entries` / `insight_entries` 三类摘要，`supply` / `potion` 的 `effects.use` 接入背包直接使用，POI 首次踏足额外发放保底发现奖励并显示探索进度，同伴 `favor_milestones` 随存档持久化；内容 JSON 字段不变。v1.5 补充平衡统计口径：POI 首次进入必定触发、区域首次进入 60%、wander 每 3 AP 13% 加每回合 24% 环境判定、单局随机事件上限 29；地图配置新增仅测试用的 `fixed_terrain_seed`，并明确 AI 袭击后的玩家反击不会触发二次反击。v1.3 新增单槽自动存档 `user://saves/auto.json` 的格式说明（§9.3，`save_version = 1`），并在存档中保存地图配置/实际种子、角色与同伴运行时状态、事件编排、迷雾标记与 RNG 流；内容 JSON 字段不变。v1.2 未新增 JSON 字段，但移动 AP 改为按实际路径距离连续计算：`MapData.segment_move_cost_deci()` 使用世界像素距离、目标格地形系数与 `elevation_at` 起止高差，不再读取地块面积；事件选项在选择前只返回 `risk` / `disabled` / `reason`，不再生成 `hint` / `warning`，实际收益与损失只通过选择后的 `effect_messages` 揭示。v1.1 调整 UI 与地图生成口径：迷雾改为地形底色 + 未知/记忆覆盖层的分层渲染，起终点从内陆候选点生成，单局约 279 块，新增开场白、右上帮助、背包/装备页与骰子动画；v0.9 接入 AI 同伴完整回合与 4X 式事件编排：`hidden_tasks.json` 的 `initial_faction` / `initial_favor` / `completion` 驱动 AI 意图，事件结果中的 `ai_effects` / `ai_favor` 接入结算，并补充事件情境权重与同伴情报口径；v0.8 补齐分层迷雾三态、侦察检定与 AI 揭示等级的运行时口径（不新增 JSON 字段），并接入隐藏任务的运行时分配：玩家侧只记录候选、AI 侧抽取任务，修正了把 AI 任务误当玩家目标展示的问题；v0.7 只保留一张内置地图，并新增 `randomize_seed`：每次开局重掷形状种子，整张地图内容重新生成；v0.6 让地图 JSON 通过 `character_ids` / `event_ids` 声明本图内容清单；v0.5 将地块放大到约 1.65 倍，补充移动 AP 与单次移动 2 事件/3 AP 间隔口径，并新增 3 个 wander 事件；v0.4 补全事件触发、`hp_relief` 与 `lost_severe`；v0.3 补充地图配置、运行时派生地块字段与 `cell_id` 约定。

## 0. 通用约定

| 约定 | 说明 |
|---|---|
| 顶层结构 | `{"<表名>": [ ... ]}`，表名与文件名一致 |
| ID | `snake_case`，同一文件内唯一，跨表引用用 ID |
| 数值单位 | AP/金币/HP 均写人类单位（`-1` = 减 1）；代码内部 AP ×10 |
| 价格 | 整数金币；`null` = 设计未给价（不可交易） |
| 持续时间 | 回合数；`-1` = 永久/本局 |
| 友好度 | −5 ～ +5 |
| 伤害 | 负数表示损失 |
| 坐标 | 无全局坐标；地块用 `cell_id` 标识，Voronoi 多边形与中心由「配置 + 种子」重建 |
| 文本 | 中文直接写，无需转义 |

---

## 1. 文件清单

| 文件 | 顶层键 | 当前数量 | Schema 版本 |
|---|---|---|---|
| `characters.json` | `characters` | 5 | v0.1 |
| `items.json` | `items` | 12 | v0.1 |
| `statuses.json` | `statuses` | 11 | v0.5 |
| `flags.json` | `flags` | 5 | v0.1 |
| `terrains.json` | `terrains` | 11 | v0.1 |
| `hidden_tasks.json` | `hidden_tasks` | 15（MVP 10） | v0.1 |
| `events/events.json` | `events` | 15 | v0.5 |
| `maps/*.json` | 无（单对象） | 1 内置 | v0.7 |

> `events.json` 现有 15 个事件：5 个 `enter_region`、4 个 `poi`、5 个 `wander`、1 个 `goal`。其中 12 个来自设计文档，`fallen_tree` / `mirage` / `pilgrim` 是为大地图后“一次移动可遇多个事件”补充的 wander 事件，保证森林/沙漠/平原都有足够的非重复候选。事件池的 20～30 指单局触发次数，不是唯一事件数。触发权重与条件见 §8.6。

---

## 2. characters.json

```json
{
  "id": "lin_xiao",
  "name": "林鸮",
  "role": "侦察兵",
  "attributes": { "speed": 4, "stamina": 2, "perception": 4, "luck": 2, "combat": 2, "negotiation": 2 },
  "traits": ["forest_hunter", "night_walker"],
  "starting_equipment": ["telescope"],
  "starting_items": [],
  "starting_gold": 20,
  "hidden_task_ids": ["lin_map_before_goal"],
  "note": ""
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `attributes` | 对象 | 六属性各 1～5 |
| `traits` | 字符串数组 | 词条 ID，见 §10 |
| `starting_equipment` | 字符串数组 | 必须存在于 `items.json`，各占 1 装备槽 |
| `starting_items` | 字符串数组 | 背包物品（如青蘅的药水） |
| `starting_gold` | 整数 | MVP 固定 20 |
| `hidden_task_ids` | 字符串数组 | 3 个候选：2 个 `mvp_available` + 1 个 P1 |

派生值不入库：`HP = 体力 × 3`、`重投 = 幸运 // 2`、`侦察半径 = 感知 // 2 + 1`（至少 1 格；状态里的真实感知修正计入；望远镜等 `scout_check_bonus` 只加检定，不加半径）。

---

## 3. items.json

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` / `name` | 字符串 | 唯一 ID / 显示名 |
| `type` | 枚举 | `consumable` / `material` / `equipment` / `quest` |
| `rarity` | 枚举 | `common` / `uncommon` / `rare` |
| `price` | 整数或 null | 仅商队交易与 P2 价值限制使用 |
| `stackable` / `max_stack` | 布尔 / 整数 | 材料可堆叠 |
| `tradable` | 布尔 | 是否属于可交易材料（影响沙铠任务） |
| `quest_item` | 布尔 | 任务物品：守卫献祭不可消耗、AI 不自动丢弃 |
| `mvp_available` | 布尔 | false = 仅 P1/P2 |
| `effects` | 对象 | 见下表 |
| `description` | 字符串 | 规则说明 |

`effects` 常用键：

| 键 | 说明 |
|---|---|
| `use` | `choose_hp_or_ap_1`（补给，玩家选择恢复 1 HP 或 1 AP）/ `remove_one_negative_status`（药水，解除一个可移除状态） |
| `removable_status_ids` | 药水可移除的状态 ID 列表；空数组表示所有 `removable_by_potion = true` 的状态 |
| `ap_bonus` | 装备 AP 加值（坐骑 +1） |
| `ap_bonus_disabled_terrains` | 该地形中 AP 加值失效（坐骑→密林） |
| `combat` / `negotiation` / `perception` / `luck` / `stamina` | **属性加值**，计入「装备加值总和」 |
| `luck_event` | 仅影响事件数值随机，不影响重投 |
| `scout_check_bonus` / `negotiation_check_bonus` | **专项检定加值**，不计入「装备加值总和」 |
| `uphill_penalty_modifier` | 上坡惩罚修正（绳索 −0.5/层） |
| `max_equipped` | 每人最多装备数（`rare_charm` = 1） |

---

## 4. statuses.json

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` / `name` | 字符串 | 唯一 ID / 显示名 |
| `category` | 枚举 | `debuff` / `buff` / `special` |
| `duration` | 整数 | 默认持续回合；−1 永久 |
| `max_duration` | 整数或 null | 上限（`trapped` = 2） |
| `effects` | 对象 | 见下表 |
| `removable_by_potion` | 布尔 | 药水是否可移除 |
| `player_only` | 布尔 | `suspected` 仅玩家可获得 |
| `description` | 字符串 | 完整效果说明，用于结算与 HUD tooltip |
| `short` | 字符串 | 状态条短效果，如「幸运 -2，药水无效」 |

`effects` 常用键：`hp_per_round`、`scout_check_bonus`、`ap_next_round`、`ap_penalty_overflow_to_hp`、`blocks_movement`、`blocks_goal`、`end_of_round_check{attr,dc}`、`luck`、`negotiation`、`combat`、`perception`、`immune_terrain_negative`。

`lost` 与 `lost_severe` 是事件「迷路」的两种 AP 惩罚：下回合掷 AP 后分别扣 2 AP / 4 AP，不足按 D-10 转 HP；`added_round` 保证获得状态的当回合不结算，`ap_applied` 保证只扣一次。`duration=1` 的状态在下一回合结束时移除。HUD 状态条优先读取 `short`；缺失时回退到 `description`，保证旧状态定义仍可用。

---

## 5. flags.json

| 字段 | 说明 |
|---|---|
| `category` | `ai` / `quest` / `world` / `player` |
| `effects` | 机器可读效果（如 `goal_visible`、`merchants_refuse_trade`、`path_ap_multiplier`） |
| `ai_can_gain` | AI 是否可能获得（`wanted` = false） |
| `mvp_effect_note` | MVP 中的实际作用，防止「有 flag 没逻辑」 |

---

## 6. terrains.json

| 字段 | 说明 |
|---|---|
| `movement_coefficient` | 移动系数；`null` = P2 未定义 |
| `mvp_enabled` | MVP 是否参与生成与结算 |
| `scout_dc_mod` | 侦察 DC 修正 |
| `event_affinity` | 倾向事件 ID 列表 |
| `color` | 地图基色（十六进制） |

MVP 启用：`plain` 1.2、`forest` 2.0、`desert` 2.5。其余为正式版预留。

---

## 7. hidden_tasks.json

| 字段 | 说明 |
|---|---|
| `character_id` | 归属角色 |
| `relation` | `compatible` / `protect` / `competitive` / `independent` / `sabotage` / `assassination` |
| `initial_faction` | `friendly` / `neutral` / `enemy`（由关系推导，不独立随机） |
| `initial_favor` | `[min, max]`，按种子在区间内取值 |
| `exclusive` | 是否互斥（达成时按当前阵营处理） |
| `mvp_available` | MVP 是否可用 |
| `completion` | 完成条件，见下表 |
| `behavior` | AI 行为倾向（叙事/调试提示） |

`completion.type` 取值：

| type | 参数 | 含义 |
|---|---|---|
| `reveal_regions_before_goal` | `count` | 揭示终点前 N 格（仅自己揭示） |
| `reveal_goal_first` | `share_allowed` | 先于玩家揭示终点且未分享 |
| `reveal_water_sources` | `count` | 标记 N 处水源（P1） |
| `player_alive_at_goal` | — | 玩家 HP>0 到达终点 |
| `hold_tradable_quest_item_at_goal` | — | 携带至少 1 件非初始可交易物品到达 |
| `raid_cargo` | — | 截获货物（P1） |
| `favor_at_goal` | `min` | 到达终点时与玩家友好度 ≥ min |
| `player_trapped_at_window` | — | 判定窗口内玩家仍被困 |
| `collect_intel` | `count` | 收集情报（P1） |
| `reach_goal_first` | — | 先于玩家与其他 AI 到达 |
| `steal_equipment` | — | 偷走玩家一件装备/物品 |
| `unseen_actions` | — | 关键行动未被目击（P1） |
| `player_poisoned_and_survived` | — | 玩家至少中毒一次且未死亡并到达 |
| `share_herb_to_player` | — | 把草药分享给玩家 |
| `collect_two_samples` | — | 采集两种样本（P1） |

### 7.1 运行时分配（不写入 JSON）

- 每个角色有 3 个候选，其中 `mvp_available = true` 的 2 个进入 MVP 候选池；P1 候选不参与。任务文本按 AI 同伴视角撰写（如「与玩家友好度达到 +3」），不能直接作为玩家目标展示。
- 玩家侧：`GameManager.start_new_game` 只把所选角色的 2 个 MVP 候选记录到 `player_hidden_task_candidate_ids`，不抽具体任务、不判定、不参与胜负（设计文档 §10.5）。`get_player_hidden_task_candidates()` 可读取；HUD 与暂停菜单显示「玩家隐藏任务：MVP 未启用」。
- AI 侧：用独立随机流 `hidden_task_ai` 从 AI 角色候选池抽 1 个，写入 `GameManager.ai_hidden_task_id`，可通过 `get_ai_hidden_task()` 读取；对玩家保持隐藏。`CompanionAI.setup()` 再按其 `initial_faction` 与 `initial_favor` 区间初始化阵营/好感，运行时用它决定意图与任务导向。
- AI 隐藏任务的完成判定随 AI 行动模块接入；玩家隐藏任务候选与 AI 隐藏任务都不是地图 JSON 字段。

### 7.2 AI 同伴运行时口径（不写入 JSON）

| 项目 | 口径 |
|---|---|
| 初始状态 | `initial_faction` 直接作为初始阵营；`initial_favor` 为 `[min, max]`，每局从 `"ai"` 随机流取一个整数 |
| 阵营阈值 | `favor <= -2` 为 `enemy`，`favor >= 2` 为 `friendly`，其余 `neutral`；事件 `ai_favor`、援助、偷窃与下套都会改变好感 |
| 行动频率 | 每个玩家回合结束执行 1 次；独立掷 AP（1d6 + 速度 + 装备，上限 12），不占用玩家 AP |
| 回合顺序 | 掷 AP → 持续伤害/状态持续 → 低血用药/用补给 → 被困挣脱 → 选择意图 → 执行 → 任务进度 → 情报报告 |
| 移动上限 | 每回合最多 6 格；按格心到格心的近似距离、目标地形与高差逐格扣自己的 AP（玩家实际画线使用连续距离成本，D-62）；探索会直接踏入 POI 并拾取物资 |
| 互动范围 | 与玩家同格或相邻（BFS 距离 ≤1）才发生援助/偷窃/下套/袭击；靠拢时停在相邻格，避免与玩家完全重叠 |
| 战斗 | 敌方同伴相邻且攻击冷却结束后消耗 1 AP 袭击玩家；公式与玩家先手共用 `CombatRules`（D-58）。袭击后 `_hostile_cooldown = 2` |
| 到达快照 | `reached_goal` / `goal_round` / `faction_at_goal` 在通过守卫瞬间写入；`faction_at_goal` 之后不随阵营变化追溯（D-59） |
| 可见行动 | 只有玩家当前圆形视野内才把行动文本写入世界纪事；否则改为概率传闻与最后已知位置 |
| 最后已知 | 回合开始/结束任一时刻可见就刷新 `last_known_cell` / `last_known_round`；玩家端保留 4 回合，超过后只显示「踪迹已经模糊」 |
| 情报等级 | 0 完全未知：只给「态度有些变化」；1 倾向线索：显示好感变化；2 阵营线索：显示阵营色、敌对警告、最后已知方向；3：显示任务名、进度与精确好感 |
| 共享视野 | 友方同伴每 2 回合把自身周围 `scout_reveal_radius` 的记忆共享给玩家；只标记「曾获得信息」，不扩大玩家当前圆形视野 |
| 世界纪事 | 开局、可见行动、传闻、任务完成、阵营变化、死亡、终点竞争与玩家事件统一写入，最多保留 30 条 |

意图选择：

| 条件 | 意图 | 行为 |
|---|---|---|
| HP ≤ 1/3 且没有补给/药水 | `rest` | 每回合一次 +1 HP |
| 友方 + `share_herb_to_player` / `player_alive_at_goal` / `player_poisoned_and_survived` / `favor_at_goal` | `support` | 靠拢玩家，分享草药、解毒、包扎、分补给或交谈 |
| 友方 + `reveal_regions_before_goal` | `scout` / `goal` | 独立侦察计数，完成后转向终点 |
| 友方 + `hold_tradable_quest_item_at_goal` | `goal` / `explore` | 已有可交易物则去终点，否则沿途搜集 |
| 敌方 + `steal_equipment` / `player_trapped_at_window` | `hunt` | 跟踪玩家，相邻时偷装备或设绳套；任务完成后转为相邻袭击 |
| 敌方 + 已相邻 + 攻击冷却结束 + AP ≥1 | `attack` | 消耗 1 AP 袭击玩家；玩家可花 1 AP 反击 |
| 敌方 + 好感 ≤−3 + HP 过半 + 玩家在 4 格内 | `hunt` | 主动逼近，进入相邻后按上一条袭击 |
| 中立/竞争 + `reveal_goal_first` | `scout` / `goal` | 距终点 ≤4 格时侦察，否则推进 |
| 中立/竞争 + `reach_goal_first` | `goal` | 直奔终点，尝试通过守卫 |
| 其他（含未实现的 P1 任务） | `explore` / `goal` | 探索最近未访问 POI，搜完或携带目标物后转向终点 |

终点守卫对 AI 同样生效：`2d6 + 战斗 + 装备` 对抗 14；失败 −2 HP 并被击退到相邻格，冷却 2 回合。AI 通过守卫会写入 `goal_arrivals`、获得先到奖励，并作为玩家抵达时「基础/完美胜利」的判定依据；AI 到达本身不立即判玩家失败（见临时裁定 T-03、D-59）。

### 7.3 战斗与胜利运行时（不写入 JSON）

| 项目 | 口径 |
|---|---|
| 攻击成本 | 每次主动攻击/反击消耗 1 AP（10 deci-AP） |
| 攻击检定 | `2d6 + 战斗 + 装备战斗加值 + 状态修正` 对抗 `8 + 体力 + 装备防御加值` |
| 伤害 | 大成功 1d6，成功 1d3；失败攻击者额外 −1 AP（不足转 HP），大失败攻击者再 −1 HP |
| 反击 | AI 袭击后玩家可花 1 AP 反击；该 AI 本回合已经出手，反击后不再顺势攻击。玩家先手后，存活且 AP ≥1 的敌方同伴会立刻反击一次；任一方都不会因反击再次连锁 |
| 战斗状态 | `GameManager.State.COMBAT`；`combat_payload` 含 `lines / show_choice / counter_enabled / stage`，UI 关闭后回到 `PLAYING` |
| 终点封印 | 普通游玩先踏足 3 处不同 POI 才允许进入终点（`EventManager.GOAL_SEAL_POI_COUNT = 3`）；`random_events_enabled = false` 的调试/测试模式不启用。封印未解时移动停在终点格外，标记吸回当前格 |
| 到达记录 | `GameManager.goal_arrivals` 记录 `{actor, name, round, faction_at_arrival, rewarded}`；每角色只记第一次 |
| 先到奖励 | 首次到达回合的所有到达者各 +20 金币；更晚到达者无奖励 |
| 完美胜利 | 玩家结算时任一同伴 `reached_goal` 且 `faction_at_goal == enemy` → 基础胜利；否则完美胜利 |
| 同回合冲刺 | 玩家到达后，存活且未到达的同伴获得一次只赶路/过守卫的最后行动（T-15） |

---

## 8. 事件 DSL（events.json）

### 8.1 事件对象

| 字段 | 说明 |
|---|---|
| `trigger` | `poi` / `enter_region` / `wander` / `goal` |
| `terrains` | 地形 ID 数组；`["any"]` = 任意 |
| `weight` | 基础权重（再乘地形/词条/装备/天气/阵营/冷却系数） |
| `cooldown` | 冷却回合，MVP 固定 2 |
| `per_character` | 是否每角色独立触发（终点守卫 = true） |
| `text` | 事件描述 |
| `choices` | 选项数组 |

### 8.2 选项对象

| 字段 | 说明 |
|---|---|
| `check` | `{ "attr": "combat", "dc": 12 }` 或 `null`（无检定） |
| `resolution` | 解析器：`check` / `trade` / `steal` / `item_sacrifice` / `heal_choice` |
| `params` | 解析器参数 |
| `auto_success_if_trait` | 拥有该词条时跳过检定，直接取 `success` 结果 |
| `immune_if_trait` | 拥有该词条时完全免疫（如沙漠之子对沙尘暴） |
| `trait_modifiers` | `[{ "trait": "noble", "bonus": 2, "if_terrain": "forest" }]` |
| `ai_allowed` | AI 是否可选（商队交易、守卫献祭 = false） |
| `once_per_event` | 每次事件只能执行一次（交易） |
| `outcomes` | 四种结果，见下 |

### 8.3 结果对象

```json
"outcomes": {
  "great_success": { "effects": [], "player_effects": [], "ai_effects": [], "note": "" },
  "success":       { "effects": [] },
  "fail":          { "effects": [] },
  "great_fail":    { "effects": [] }
}
```

- `effects`：玩家与 AI 共用；`player_effects` / `ai_effects` 覆盖或追加角色专属效果。
- `ai_effects` 只在 AI 同伴与玩家同格/相邻（BFS 距离 ≤1）时结算；同伴不在附近时整组跳过。具体伤势/物品变化只在同伴当前可见时显示给玩家。效果中的 `item_gain.choose_from` 会交给同伴按 `ai_task_aware` 选物。
- `ai_favor` 不受距离限制，直接改变同伴好感与阵营；它不写入 `ai_effects` 也能在 `effects` 中生效。
- 结果判定顺序：`great_success` → `success` → `fail` → `great_fail`。无检定选项走 `success`。
- `player_only: true` 的结果只对玩家生效（如商队交易大失败获得 `suspected`）。

示例：

```json
"fail": {
  "player_effects": [
    { "type": "flag_add", "flag_id": "wanted" },
    { "type": "hp", "value": -1 }
  ],
  "ai_effects": [
    { "type": "hp", "value": -1 }
  ],
  "note": "同伴就在附近时也会被波及；远处则不受影响。"
},
"success": {
  "effects": [
    { "type": "reveal", "kind": "nearest_poi" },
    { "type": "ai_favor", "value": 1 }
  ]
}
```

### 8.4 效果（effect）类型

| `type` | 字段 | 说明 |
|---|---|---|
| `hp` | `value` | 相对 HP |
| `hp_relief` | `value` | 仅当当前地块格内落差 >0.45 时造成 `value` 的 HP 变化（悬崖跌落用） |
| `ap` | `value` | 相对 AP（不足转 HP） |
| `gold` | `value` | 相对金币（下限 0） |
| `item_gain` | `item_id` 或 `choose_from`, `count` | 获得物品；满包按决策记录 A3 处理 |
| `item_lose` | `mode`(`random`/`specific`/`any_non_quest`), `item_id`, `count` | 失去物品；空包按 §7.8 转金币/HP |
| `status_add` | `status_id`, `duration?` | 添加状态 |
| `status_remove` | `status_id` 或 `any_negative` | 移除状态 |
| `flag_add` / `flag_remove` | `flag_id` | 标记 |
| `reveal` | `kind`(`nearest_poi`/`goal_direction`/`region_direction`/`shortcut`/`ai_faction_clue`), `value?` | 揭示/线索 |
| `ai_favor` | `value`, `target` | 同伴好感变化（MVP 目标是玩家）；跨越 ±2 时阵营切换，不受距离限制 |
| `move` | `kind`(`knockback`/`teleport`), `value` | 击退/传送 |
| `enter_goal` | — | 通过守卫进入终点 |
| `goal_guard_suppress` | — | 「退开」守卫：本回合不再触发守卫、终点入口封闭到下一回合，并消耗一次本局退开额度 |
| `special` | `id` | 需代码实现的特殊效果 |

执行顺序按决策记录 **D-17** 的阶段归组，同阶段内按数组顺序。

### 8.5 解析器参数

| resolution | params |
|---|---|
| `trade` | `offers[]`（buy/barter）、`price_multiplier_on_great_success`、`can_decline`、`trade_once_per_event`、`ai_allowed=false` |
| `steal` | `item_choices[]`、`ai_task_aware` |
| `item_sacrifice` | `allow_types[]`、`exclude_quest_items`、`consume_count`、`requires_any_item`、`rarity_bonus{common,uncommon,rare}`；先消耗 1 件物品，再做 `check` 指定的交涉检定，稀有度只提供加值 |
| `heal_choice` | `options: ["hp","ap"]`、`ai_auto: "hp"` |

复杂机制不塞进 JSON 表达式，一律走命名解析器；新增机制时先加解析器、再补数据。

### 8.6 运行时触发与选择

| 触发 | 运行时行为 |
|---|---|
| `poi` | 每个 `poi_id` 每局只在首次进入时触发一次，不再掷概率；从当前地形的事件池抽取。同一次首次踏足还会发放保底发现奖励（§8.9），奖励与“已访问”在同一步写入，读档不会重复领取 |
| `enter_region` | 开局按「同地形 + 邻接」生成连通区域；首次进入未访问区域的边界格时做 60% 判定，命中后触发一次 |
| `wander` | 每累计消耗 30 deci-AP（3 AP）做一次 13% 判定，命中后清零；另外每回合开始时对玩家所在地形做一次 24% 环境判定，归入 `wander` 并重置累计 |
| `goal` | 角色首次进入终点必触发；失败击退后可重复挑战，但只有首次计入单局事件数 |

候选事件必须属于当前地图的 `event_ids`（字段省略时视为全量），且 `trigger` 匹配、地形匹配（`["any"]` 或包含当前地形）、`weight > 0` 且不在冷却。地形匹配事件权重 ×1.35。最近开始的 3 个事件会被记入防重复池；只要同池仍有其他候选，它们就不会被抽中。

`goal` 强制触发且不受行动预算限制。其他触发在一次移动行动中最多启动 2 个事件，两次启动之间至少累计消耗 3 AP；同一 `trigger` 在一次行动中最多 1 个，每回合最多 3 个随机事件。队列容量 2，优先级 `goal(4) > poi(3) > enter_region(2) > wander(1)`，新触发只在严格高于最低项时替换，否则丢弃并记日志。事件结束后按 `cooldown`（MVP 为 2）进入全局冷却。

单局随机事件上限为 29 个，终点守卫不计入且预留 1 个名额，因此含终点事件时单局不超过 30。上限按「已开始 + 已入队」的随机事件数计算；达到后新的 POI/区域/wander 触发直接忽略并写调试日志，终点守卫仍可入队。未等到触发时机的队列事件跨回合保留，不会因为换回合而丢掉走过的地点；队列容量仍为 2。该计数写入存档并在读档时恢复。50 局固定种子基线平均 24.5 个事件/局，详见 `docs/实现决策记录.md` D-64。

`EventManager.random_events_enabled = false` 会关闭 POI/区域/wander 触发，但保留终点守卫；仅用于调试和自动化测试，不应写进内容数据。

### 8.7 情境权重（不写入 JSON）

在基础权重、地形匹配、冷却与防重复之后，`_context_weight()` 再按当前局势做软加权，最终 `clamp(weight, 0.2, 2.0)`。它只改变“更像会发生什么”，不硬锁事件，也不绕过地图 `event_ids` 清单：

| 局势 | 事件类型 | 系数 |
|---|---|---|
| HP ≤ 35% | 补给/恢复类 | ×1.55 |
| HP ≤ 35% | 危险类 | ×0.62 |
| HP ≤ 65% | 补给/恢复类 | ×1.18 |
| HP ≤ 65% | 危险类 | ×0.85 |
| 玩家被通缉 | 商队 | ×0.35 |
| 玩家被通缉 | 危险类 | ×1.20 |
| 剩余 ≤10 回合 | 危险/情报类 | ×0.78 |
| 剩余 ≤10 回合 | 社会/补给类 | ×1.18 |
| 敌对同伴在相邻格 | 危险类 / 社会类 | ×1.25 / ×0.85 |
| 友好同伴在相邻格 | 社会类 / 补给类 | ×1.25 / ×1.10 |

事件面板顶部的「局势」由 `get_context_note()` 生成，可能包含负伤、通缉、剩余回合、同伴位置与阵营提示；它只描述玩家已经能感知的信息，不泄露 AI 隐藏任务。

### 8.8 选项可读性（运行时字段）

`get_choices()` 为 UI 额外返回只读字段，不写回 JSON。选择前只展示选项本身与风险档位，不生成任何结果预告：

| 字段 | 来源 | 说明 |
|---|---|---|
| `risk` | `_risk_label()` | `低` / `中` / `高`：DC ≥14 或失败伤害/状态/通缉累计 ≥3 为高；DC ≥11 或任一次要后果为中；否则低 |
| `disabled` / `reason` | `_describe_choice()` | 交易被通缉拒绝、献祭无可用物品、本次事件已使用等 |

`risk` 只看失败代价与 DC，不把成功收益算进去。选择并完成检定后，`_resolve_outcome()` 实际施加效果，`effect_messages` 才列出获得的物品、状态变化、同伴影响等具体结果；事件面板在结算页渲染这些消息。因此事件 JSON 的 `outcomes` 仍可完整定义四档结果，但不会在玩家选择前被查询或展示。

### 8.9 结算摘要、消耗品与 POI 发现（运行时，不写入 JSON）

结算结果在 `effect_messages` 之外还返回三类结构化数组，仅供结算后的 UI 使用，不改变事件 JSON：

| 字段 | 元素结构 | 说明 |
|---|---|---|
| `reward_entries` | `{text, kind, hint}` | 实际获得的 HP/AP/金币、物品、增益状态、揭示、同伴好感、事件链完成等 |
| `cost_entries` | `{text, kind, hint}` | 扣血/AP/金币、失去物品、负面状态、负面标记、好感下降、被击退、死亡 |
| `insight_entries` | `{text, kind, hint}` | 标记/地图揭示等不直接增加数值、但会改变后续选择的线索 |

`kind` 是稳定的英文分类（`hp` / `ap` / `gold` / `item` / `status` / `flag` / `relationship` / `reveal` / `move` / `quest` / `death` 等），`hint` 说明后续用途（装备、背包直接使用、交易材料、已完成本局目标等）。选择前仍不生成这些字段；摘要只在 `_finish_resolution()` 中复制给 `reward_entries` / `cost_entries` / `insight_entries`。

消耗品使用入口位于 `GameManager.consumable_options()` / `use_item()`。补给返回 `hp` / `ap` 两个选项，满值选项带 `disabled` 与 `reason`；药水按 `removable_status_ids` 与状态的 `removable_by_potion` 生成可移除列表。任何校验失败都不会移除物品；成功使用才消耗 1 件并写纪事。该接口只读取 `items.json` 现有字段，不新增数据键。

POI 首次踏足保底奖励由 `EventManager._grant_poi_discovery()` 发放：固定概率 45% 补给、35% 金币（5～9）、20% 药水，使用独立 `exploration` RNG 流。`visited_pois` 与存档共用，重复踏入不再发放；探索进度通过 `get_exploration_text()` 显示为「探索 N/M」。

---

## 9. 地图配置（maps/*.json）

每张地图是**一个 JSON 对象**（不是数组），存生成参数与该图的内容清单，不存逐格数据。运行时由 `MapGenerator.generate(config)` 确定性重建；同配置 + 同形状种子得到同一张 Voronoi 地图。`randomize_seed = true` 时，`GameManager.start_new_game` 会在每次开局前重掷 `seed`，所以同一份 JSON 每次进入都会生成不同的地块轮廓、数量、POI、起终点与高程。**生态/地形分布不在地图文件中固定**：每局由 `GameManager` 生成随机 `terrain_seed` 重新生长（D-47/D-53）。

```json
{
  "map_id": "borderland",
  "name": "边陲荒原",
  "description": "每次进入都会重新生成地块形状、生态分布、海拔与 POI。",
  "randomize_seed": true,
  "character_ids": ["lin_xiao", "sha_kai", "wei_la", "ying", "qing_heng"],
  "event_ids": ["caravan", "bandit_ambush", "herb_patch", "goal_guard", "wildfire", "sandstorm", "old_well", "lost", "abandoned_camp", "wanderer", "cliff", "ancient_stele", "fallen_tree", "mirage", "pilgrim"],
  "seed": 20261023,
  "cell_count": 400,
  "poi_count": 10,
  "bounds": { "x": 190.0, "y": 0.0, "w": 900.0, "h": 720.0 },
  "boundary_points": 72,
  "boundary_roughness": 0.12,
  "terrain_weights": { "plain": 1.0, "forest": 1.0, "desert": 1.0 },
  "gradient": { "axis": "x", "low": "desert", "high": "forest", "strength": 2.2 },
  "elevation": { "frequency": 0.011, "octaves": 3, "max": 4 },
  "poi_min_hops": 4,
  "start_goal_margin": 0.22,
  "start_goal_samples": 28,
  "start_goal_min_hops": 14,
  "start_goal_max_hops": 30,
  "order": 1
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `map_id` | 字符串 | 地图标识；建议全项目唯一 |
| `name` / `description` | 字符串 | 地图选择界面的标题与说明 |
| `character_ids` | 字符串数组 | 可选；本图可选角色，按数组顺序显示在角色选择界面，AI 对手也只从其中抽取。省略时回退为全量角色 |
| `event_ids` | 字符串数组 | 可选；本图事件池。触发抽取只在这些事件中加权选择；终点守卫仍由代码强制触发。省略时回退为全量事件 |
| `randomize_seed` | 布尔 | 可选，默认 `false`；为 `true` 时每次进入新游戏都会重掷 `seed`，生成不同的地图。`同种子重开` 会保留当前种子 |
| `seed` | 整数 | 主种子；与配置共同决定地图。`randomize_seed` 为 `true` 时只作为文件中的初始值 |
| `fixed_terrain_seed` | 整数 | 可选，仅测试/回归用；`randomize_seed = false` 时用它固定生态分布，省略则每局重掷。平衡报告用该字段保证同批种子可复现 |
| `cell_count` | 整数 | 目标地块数（合并凹地块前）；内置图为 400，最终约 279 块，校验范围 150～800 |
| `poi_count` | 整数 | POI 数量，内置图 10（校验 ≥1） |
| `bounds` | 对象 | 地图世界坐标范围 `x/y/w/h`；视图会自动把整图适配到顶部信息条与底部动作栏之间 |
| `boundary_points` | 整数 | 海岸线采样点数，越多越平滑 |
| `boundary_roughness` | 浮点 | 海岸线噪声强度，0～1 |
| `terrain_weights` | 对象 | 地形基础权重；键必须是 `terrains.json` 中启用的地形 ID |
| `gradient` | 对象 | 方向性梯度：`axis`(`x`/`y`)、`low`/`high` 地形、`strength` |
| `elevation` | 对象 | 高程噪声：`frequency`、`octaves`、`max`（整数层数） |
| `poi_min_hops` | 整数 | POI 与起点/终点/其他 POI 的最小 BFS 距离 |
| `start_goal_margin` | 浮点 | 可选，默认 0.22；起终点采样区域距地图边缘的归一化内缩比例，用于避免贴边出生 |
| `start_goal_samples` | 整数 | 可选，默认 28；内陆起点候选采样次数 |
| `start_goal_min_hops` / `start_goal_max_hops` | 整数 | 起点→终点 BFS 距离区间；内置图 14～30，同时受 120 AP 可达性校验 |
| `order` | 整数 | 地图选择界面的排序，越小越靠前 |
| `hidden` | 布尔 | 可选；`true` 时不在菜单显示，适合本地草稿或内部配置 |

可省略字段会由 `MapGenerator.normalize_config` / `DEFAULT_CONFIG` 补齐，因此本地地图可以只写 `map_id`、`name`、`seed` 等少数键。`MapConfigLoader` 会补齐并校验必填字段、格数、POI 数、`randomize_seed` 类型、地形引用与内容清单；无效配置会返回空并在界面提示。

内容清单的两条规则：

1. **省略 = 全量**：不写 `character_ids` / `event_ids` 的旧地图或本地临时配置，行为与之前一致，显示并抽取所有角色与事件。
2. **写了就必须有效**：字段必须是数组，不能为空、不能重复，所有 ID 必须存在于 `characters.json` / `events.json`。启动新游戏时会再次校验所选角色是否属于该图；事件抽取会跳过清单外事件。

当前只保留一张内置地图 `borderland.json`。它列全 5 名角色和全部 15 个事件，并开启 `randomize_seed`，因此单图即可回归全部内容，同时每次进入都是一张新地图。后续需要固定地图或不同风格地图时，可以复制地图 JSON、调整生成参数与清单，并把 `randomize_seed` 设为 `false`（固定）或保留为 `true`（每局随机）。

起点/终点默认从地图内侧 22% 的采样区域中选一对内陆格：距边界至少 7.5% 短边，BFS 距离 14～30 格，并按空间距离评分。可选字段 `start_norm` / `goal_norm`（`[x, y]`，0～1 归一化）仍可显式指定大致方位；采样失败时才回退到极值格。POI 从可用地块中按种子抽取，数量由 `poi_count` 控制（内置图 10）。

### 9.1 运行时派生字段（不写入 JSON）

`MapGenerator` 生成地图后，会为每格补充面积、凹形标记、格内高程采样与连续起伏数据。它们由配置 + 形状种子 + 本局生态种子生成，不写入地图 JSON，也不进入存档：

| 字段 | 类型 | 说明 |
|---|---|---|
| `area` | 浮点 | 地块多边形面积（像素²）；生成期用于剔除碎块/拆分巨块与校验，不再参与 AP 计算 |
| `bounds` | `Rect2` | 地块多边形包围盒；点选/悬停前先做 AABB 过滤，避免逐格多边形测试 |
| `concave` | 布尔 | 该地块是否由相邻 Voronoi 块合并而成、且含凹角（D-46） |
| `elevation_samples` | `PackedFloat32Array` | 格内高程采样；与 `relief_polygon` 一一对应（顶点/边中点） |
| `elevation_mean` | 浮点 | 该格采样高程的平均值，仅用于展示 |
| `relief_polygon` | `PackedVector2Array` | 渲染环：原多边形顶点与每边中点交替排列 |
| `relief_heights` | `PackedFloat32Array` | 与 `relief_polygon` 一一对应的高度（渲染用） |
| `relief_min` / `relief_max` | 浮点 | 该格高程采样的最小/最大值，HUD 用其显示格内范围 |
| `terrain_seed` | 整数 | **地图级**字段：本局实际使用的生态种子（非逐格）；用于复现同一局的地形分布 |

`MapData.elevation_at(cell_id, point)` 对 `elevation_samples` 做反距离加权，返回格内任意一点的高程估计，供 HUD 悬停显示，也用于移动成本中的实际爬升计算；它不会写回 `cell.elevation`。事件与规则结算仍读整格 `elevation`（整数 0～4）；除 `elevation_at` 参与移动高差外，上述派生字段不参与 AP、事件、邻接或胜负。顶点高度会与共享该顶点的相邻格高程取平均并叠加连续噪声，因此相邻地块的坡面在边界处自然衔接。详见 `docs/实现决策记录.md` D-43B、D-51、D-62。

地块面积也不是统一的：站点先按抖动网格生成，再由低频密度噪声决定保留概率，随后两轮移除碎块、拆分巨块；最终校验要求 0.22×～2.80× 平均面积的异常格不超过 4%。v1.1 内置图 `cell_count = 400`，最终约 279 块。v1.2 起地块面积只影响外观与形态，不再影响 AP；路线成本由实际画线长度、地形与爬升决定。视图默认按顶部信息条与底部动作栏之间的可用区域适配缩放，并支持滚轮缩放、中键平移、`Home` 复位，详见 `docs/实现决策记录.md` D-45、D-48、D-51、D-62。

地块形状也不是全部凸多边形：生成器会随机合并相邻的 2～3 个 Voronoi 块，只保留单轮廓、确实含凹角、面积不超过平均 2.30 倍的结果；`cell.concave` 标记这些地块。合并后重新建立邻接，点选/悬停按合并后的多边形判定。详见 D-46。

地形分布每局重掷：`randomize_seed = true` 时形状种子也每局重掷；`GameManager` 另给随机 `terrain_seed`。生成器从中心 BFS 生长，权重由基础权重、`gradient` 方向梯度和已定型邻格类型共同决定（沙漠旁更易草原，森林旁的草原更多），因此每局的地图轮廓与群系渐变都会变化。详见 D-47/D-53。

### 9.2 运行时迷雾与侦察状态（不写入 JSON）

迷雾不写地图 JSON；它由 `MapData.Cell` 的四个持久标记、地图级当前视野圆与视野扩张状态推导，重开新游戏即全部清空。v1.5 起这些运行时状态会写入存档（§9.3）：四个标记以 `cell_id` 数组保存在 `map.fog`，视野扩张保存在 `game`；读档先重建 `current_vision`，再逐格精确覆盖存档标记。v1.6 的同伴羁绊里程碑保存在 `companion.favor_milestones`，`save_version` 不变（旧存档缺字段时按未领取处理）。v1.7 的失物追查状态保存在 `companion.stolen_item_id` / `companion.recovery_attempt_round`，背包溢出队列保存在 `game.pending_item_overflows`；同样不改变 `save_version`，旧存档缺字段时按“无失物 / 无排队奖励”处理。

| 字段 | 类型 | 说明 |
|---|---|---|
| `cell.seen` | 布尔 | 曾进入过当前视野圆或被侦察揭示；离开圆后保留为「曾获得信息」 |
| `cell.scouted` | 布尔 | 被主动侦察揭示过；离开圆后仍保留在「曾获得信息」 |
| `cell.entered` | 布尔 | 玩家实际踏足过；即使离开视野圆也保留记忆 |
| `cell.poi_known` | 布尔 | 该格 POI 位置已知（进入、侦察大成功或事件揭示） |
| `map.current_vision` | `Dictionary` | 当前视野圆覆盖的格子（以格心是否在圆内判定）；每次移动/侦察/重开后重建 |
| `map.vision_center` | `Vector2` | 当前视野圆的圆心（渲染用平滑圆心；逻辑刷新时取玩家所在格中心） |
| `map.vision_radius_world` | `float` | 当前视野圆的世界半径（像素）；基础半径 + 侦察扩张 |
| `map.average_cell_size` | `float` | 地图平均格径，用于把基础视野换算为世界半径 |
| `map.average_site_spacing` | `float` | 地图平均最近站点间距，用于把「侦察扩张 N 格」换算为世界半径 |
| `GameManager.vision_boost_cells` | `float` | 侦察带来的额外视野（单位：平均格距） |
| `GameManager.vision_boost_hold_rounds` | `int` | 扩张视野的剩余保持回合数 |

`MapData.fog_state(cell_id)` 只返回三态：

| 状态 | 条件 | 显示 |
|---|---|---|
| `VISIBLE` | 格子在 `current_vision` 中（格心在圆内） | 完整地形、海拔与标记，最亮 |
| `REMEMBERED` | `seen` / `scouted` / `entered` 之一，但当前不在圆内 | 保留地形，压暗覆盖；亮度低于可见、高于未知 |
| `UNKNOWN` | 其余 | 近黑覆盖层（保留少量地形底色透出）；悬停只显示「地形：未知」 |

**迷雾是分层绘制**：每个地块先无条件绘制完整地形底色与起伏，再叠加记忆/未知覆盖层。因此 `UNKNOWN` 不是“换掉地形颜色”，同一地块可以同时拥有地形底色和雾层；`REMEMBERED` 也只是低亮度覆盖。覆盖层只作用于视野圆外，圆内不叠雾。

**圆形视野不是整格判定**：渲染时对每个地块做 `cell.polygon − vision_circle` 的多边形裁剪，只给圆外部分上雾。因此圆边缘会切过地块，圆内的局部是亮的、圆外的局部仍是雾色。`current_vision` 只记录格心在圆内的格子；被圆切到但格心在圆外的边缘格不会因“擦边”获得整格记忆。悬停与 POI 标记用光标点/标记点是否在圆内判定。

被动视野半径 = `average_cell_size × 2`。侦察与高低差口径：

- 消耗 **2 AP**；`2d6 + 感知 + 装备加值 + 状态加值` 对抗 `DC = 10 + 地形.scout_dc_mod + 高低差修正`。
- 高低差修正：目标格 `elevation >= 3` 时 DC −2；`elevation <= 1` 时 DC +2；`acrophobia` 在高处把 −2 抵消为 0。
- 大成功：自然 12 或总值 ≥ DC + 5；大失败：自然 2 或总值 ≤ DC − 5。
- 成功扩张 = `max(1, effective_perception() // 2 + 1)` 格（只计状态里的真实感知变化，`poisoned` 的 `scout_check_bonus: -1` 只影响检定）；把该值换算为 `vision_boost_cells` 后扩大圆形视野。大成功再 +1，并把最近一个未探索 POI 标为已知。
- 扩张视野**保持 2 回合**，之后每回合结束收缩 **0.5 格**，直到回到基础圆；收缩过程平滑动画显示。
- 侦察成功使 AI 揭示等级 +1，上限 3；大失败使玩家位置对所有 AI 暴露到下一回合结束。
- 起始格与终点标记始终可见；POI 标记仅在可见或记忆状态绘制。

详见 `docs/实现决策记录.md` D-23/D-24/D-54（修订）。

### 9.3 自动存档 JSON（save_version 1）

`SaveManager` 在安全边界写入单槽 `user://saves/auto.json`。它不是内容表，不参与 `DataManager` 校验；读档只接受 `format = "zhenming.save"` 且 `save_version` 完全相同的文件。结构概览：

```json
{
  "format": "zhenming.save",
  "save_version": 1,
  "game_version": "1.9",
  "saved_at": "2026-10-26T12:34:56",
  "meta": { "map_id": "borderland", "player_name": "林鸮", "round": 5, "...": "..." },
  "map": {
    "config": { "map_id": "borderland", "seed": 123456, "...": "..." },
    "generated_seed": 987654321,
    "terrain_seed": 135792468,
    "seed_value": 123456,
    "fog": {
      "seen": [1, 2, 3],
      "scouted": [2],
      "entered": [1],
      "poi_known": [3]
    }
  },
  "player": { "character_id": "lin_xiao", "cell_id": 42, "hp": 5, "...": "..." },
  "companion": { "actor": { "...": "..." }, "task_id": "scout_route", "...": "..." },
  "events": { "pending_events": [], "cooldowns": {}, "visited_regions": {}, "...": "..." },
  "rng": {
    "master_seed": 123456,
    "streams": { "event": "12345678901234567890", "ai": "9876543210987654321" }
  },
  "game": { "round_index": 5, "world_log": [], "visual_position": [0.0, 0.0], "...": "..." }
}
```

| 键 | 类型 | 说明 |
|---|---|---|
| `format` | 字符串 | 固定 `zhenming.save`；不匹配直接拒绝 |
| `save_version` | 整数 | 当前为 `1`；结构不兼容时递增，读档不接受跨版本 |
| `game_version` | 字符串 | 写入时的游戏版本，当前 `1.9`，仅用于显示与排查 |
| `saved_at` | 字符串 | 本地时间 `YYYY-MM-DDTHH:MM:SS`；`meta.saved_at` 同值 |
| `meta` | 对象 | 主菜单用摘要：地图/角色/回合/HP/金币/终点距离/同伴名，不含完整状态 |
| `map.config` | 对象 | 本局实际生效的完整地图配置（含兜底后的参数），不是只存 `seed` |
| `map.generated_seed` | 整数 | 形状/多边形生成种子；与 `terrain_seed` 一起喂给 `generate_exact()` |
| `map.terrain_seed` | 整数 | 本局生态地形种子 |
| `map.seed_value` | 整数 | HUD 展示的本局种子；读档时一并恢复 |
| `map.fog` | 对象 | `seen` / `scouted` / `entered` / `poi_known` 四个 `cell_id` 整数数组；逐格精确保留，不从其他标记推断 |
| `player` | 对象 | `ActorState.to_dict()`：属性、词条、装备、背包、状态、标记、HP/AP、金币、`cell_id`、休息/任务进度、AP 惩罚 |
| `companion` | 对象 | 空对象表示本局没有同伴；否则含 `actor`（同上）、任务 ID、阵营、好感、`favor_milestones`（已领取的羁绊里程碑，如 `{"trust_supply": true}`）、`stolen_item_id`（D-25 被偷物品 ID，空串表示无失物）、`recovery_attempt_round`（最近一次免费追查的回合，防止同回合重复尝试）、`theft_warning_given`（影是否已给出本局偷窃预警；读档后不会重复预警）、存活/到达终点、当前动向、台词、最后已知位置、互动冷却、访问过的 POI 与战斗摘要 |
| `events` | 对象 | 待处理事件队列、冷却、本回合/本行动计数、单局随机事件累计、wander 累计、已访问 POI/区域、已揭示 POI、上一地形、揭示等级、终点尝试与事件日志；另含守卫状态 `goal_guard_suppressed_round`（本回合「退开」后压制守卫的回合号）、`goal_fail_streak`（连续失败次数，≥2 时守卫交涉/战斗 DC −2）、`goal_withdraw_count`（本局已退开次数，上限 2）；区域 ID 读档时按地图重新推导 |
| `rng.master_seed` | 整数 | 本局主种子 |
| `rng.streams` | 对象 | 命名随机流 → `RandomNumberGenerator.state` 的**十进制字符串**；避免 64 位整数在 JSON 中丢精度 |
| `game` | 对象 | 回合、角色/任务 ID、世界纪事、终点到达记录与胜利层级、选中地图配置、子格视觉位置、最近提示/侦察报告、暴露回合、视野扩张格数与保持回合、`pending_item_overflows`（A3 背包满时排队的奖励，元素含 `item_id` / `count` / `source`；读档后仍要求玩家取舍） |

存档只在 `GameManager.can_save_game()` 为真时写入：序章已关闭、不在移动/暂停、没有活动事件或战斗。已画路径属于瞬时输入，不写入存档。胜利或死亡会删除该槽，避免读档回滚结局。完整行为见 `docs/实现决策记录.md` D-41/D-63。

---

## 10. 词条（traits）ID 与 MVP 生效

| ID | 名称 | MVP 实现 |
|---|---|---|
| `forest_hunter` | 密林猎手 | 密林移动 ×0.8；密林事件检定 +2 |
| `night_walker` | 夜行者 | 不生效（P2） |
| `desert_child` | 沙漠之子 | 沙尘暴跳过检定；沙漠伤害减半（向下取整） |
| `heavy_armor` | 重甲 | 战斗 +2；其余 P2 |
| `noble` | 贵族 | 交涉 +2；被抢劫金币损失 +50% |
| `acrophobia` | 恐高 | 高处侦察 DC 修正 0；高差事件 P2 |
| `thief` | 盗贼 | 偷窃检定 +2；交涉 −1 |
| `herbalist` | 草药师 | 草药丛自动成功；制作药水 P1 |

---

## 11. DataManager 校验规则

启动时自动检查，失败会在启动画面与控制台列出：

1. 文件可读、合法 JSON、顶层键存在且为数组。
2. 每条记录有 `id`，同表内不重复。
3. 角色初始装备/物品、隐藏任务引用存在；隐藏任务的 `character_id` 与归属角色一致。
4. 事件地形引用存在（`any` 除外）；检定的 `attr` 属于六属性。
5. 事件中的 `item_id` / `status_id` / `flag_id` / `choose_from` 引用存在。
6. 事件 `trigger`、`resolution`、`type` 等枚举值在允许集合内（P0 补全）。
7. 地图配置由 `MapConfigLoader` 单独校验：必填字段非空、格数 150～800、`poi_count` ≥1、地形 ID 存在、`randomize_seed` 为布尔值；若声明 `character_ids` / `event_ids`，还要求非空、无重复且引用存在；生成后再由 `MapGenerator` 做连通性/地形/死区/路径 AP/起终点距离校验。

新增或修改数据结构时：先改本文件 → 改 JSON → 跑自检 → 跑 headless 回归。
