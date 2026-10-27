extends Control
## 即时反馈层：命中特效、程序化音效、震屏、伤害数字、连击提示与按钮回弹。
##
## 这一层只读 GameManager 已经结算完成的事实（combat_hit / scout_finished），
## 不参与任何判定，也不阻塞输入。所有音效在运行时合成，不依赖外部音频资源。

const MAX_EFFECTS := 48
const MAX_SFX_PLAYERS := 8
const COMBO_WINDOW_STYLE := "连击 ×%d"
const COMBO_HOT_STYLE := "连击 ×%d · 势不可挡"

var _map_view: Node2D = null
var _map_base_position: Vector2 = Vector2.ZERO
var _effects: Array[Dictionary] = []
var _flash_alpha: float = 0.0
var _flash_color: Color = Color(1.0, 0.82, 0.42)
var _shake_time: float = 0.0
var _shake_duration: float = 0.0
var _shake_strength: float = 0.0
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_cache: Dictionary = {}
var _sfx_cursor: int = 0
var _rng := RandomNumberGenerator.new()
var _combo_label: Label = null
var _combo_tween: Tween = null
var _combo_token: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	_rng.randomize()
	_map_view = get_node_or_null("../../MapView") as Node2D
	if _map_view != null:
		_map_base_position = _map_view.position
	_build_sfx_players()
	_build_combo_label()
	GameManager.combat_hit.connect(_on_combat_hit)
	GameManager.scout_finished.connect(_on_scout_finished)
	# 事件选项、背包物品等按钮是运行时生成的，监听新节点才能统一接上回弹与点击音。
	get_tree().node_added.connect(_on_node_added)
	call_deferred("_bind_existing_buttons")


func _exit_tree() -> void:
	if _map_view != null and is_instance_valid(_map_view):
		_map_view.position = _map_base_position


func _process(delta: float) -> void:
	for i in range(_effects.size() - 1, -1, -1):
		var effect: Dictionary = _effects[i]
		effect["age"] = float(effect.get("age", 0.0)) + delta
		if float(effect["age"]) >= float(effect.get("life", 0.3)):
			_effects.remove_at(i)
	if _flash_alpha > 0.0:
		_flash_alpha = maxf(0.0, _flash_alpha - delta * 1.9)
	_update_shake(delta)
	queue_redraw()


func _draw() -> void:
	if _flash_alpha > 0.001:
		var flash := _flash_color
		flash.a = _flash_alpha
		draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), flash)
	for effect in _effects:
		_draw_effect(effect)


func _draw_effect(effect: Dictionary) -> void:
	var life := maxf(0.001, float(effect.get("life", 0.3)))
	var t := clampf(float(effect.get("age", 0.0)) / life, 0.0, 1.0)
	var color: Color = effect.get("color", Color.WHITE)
	var pos: Vector2 = effect.get("pos", Vector2.ZERO)
	match String(effect.get("kind", "")):
		"burst":
			var core := maxf(0.0, (1.0 - t) * 11.0)
			draw_circle(pos, core, Color(color.r, color.g, color.b, 0.28 * (1.0 - t)), true, -1.0, true)
			for ray in effect.get("rays", []):
				var direction: Vector2 = ray.get("dir", Vector2.RIGHT)
				var speed := float(ray.get("speed", 40.0))
				var distance := lerpf(2.0, speed, ease(t, 0.22))
				var start := pos + direction * distance * 0.34
				var end := pos + direction * distance
				draw_line(
					start, end,
					Color(color.r, color.g, color.b, (1.0 - t) * 0.92),
					maxf(0.6, 3.2 * (1.0 - t)), true
				)
		"ring":
			var radius := lerpf(float(effect.get("radius", 6.0)), float(effect.get("max_radius", 44.0)), ease(t, 0.32))
			var width := maxf(0.5, 3.4 * (1.0 - t))
			draw_arc(pos, radius, 0.0, TAU, 36, Color(color.r, color.g, color.b, (1.0 - t) * 0.85), width, true)
		"slash":
			var direction := Vector2.RIGHT.rotated(float(effect.get("angle", 0.0)))
			var length := lerpf(8.0, float(effect.get("length", 54.0)), ease(t, 0.18))
			draw_line(
				pos - direction * length * 0.5, pos + direction * length * 0.5,
				Color(color.r, color.g, color.b, 1.0 - t),
				maxf(0.7, 4.6 * (1.0 - t)), true
			)


func _on_combat_hit(info: Dictionary) -> void:
	var defender_side := String(info.get("defender_side", ""))
	var attacker_side := String(info.get("attacker_side", ""))
	var damage := int(info.get("damage", 0))
	var critical := bool(info.get("critical", false))
	var by_player := attacker_side == "player"
	var combo := int(info.get("combo", 0))
	var pos := _combatant_screen_position(defender_side)
	var color := Color(0.98, 0.78, 0.34) if by_player else Color(0.96, 0.40, 0.34)
	_spawn_hit(pos, color, critical, damage)
	if damage > 0:
		var text := ("暴击 −%d" if critical else "−%d") % damage
		_spawn_floating_text(pos, text, color, 40 if critical else 31)
		_flash(color, 0.12 if critical else 0.075)
		if by_player:
			_play_sfx("crit" if critical else ("combo" if combo >= 2 else "hit"))
			_shake(12.0 if critical else 6.0, 0.24)
			if combo >= 2:
				_show_combo(combo)
		else:
			_play_sfx("hurt")
			_shake(13.0, 0.3)
	else:
		var miss_text := "未破防" if by_player else "闪避"
		_spawn_floating_text(pos, miss_text, Color(0.72, 0.70, 0.64), 23)
		_play_sfx("miss")
		_shake(3.0, 0.14)


func _on_scout_finished(report: Dictionary) -> void:
	if not bool(report.get("ok", false)):
		return
	var level := String(report.get("level", ""))
	var pos := _player_screen_position()
	if level == "great_success":
		_spawn_ring(pos, Color(0.58, 0.92, 0.72), 86.0)
		_spawn_hit(pos, Color(0.58, 0.92, 0.72), true, 0)
		_spawn_floating_text(pos, "洞察！", Color(0.62, 0.96, 0.76), 34)
		_flash(Color(0.58, 0.92, 0.72), 0.10)
		_play_sfx("scout_great")
	elif level == "success":
		_spawn_ring(pos, Color(0.82, 0.88, 0.56), 66.0)
		_spawn_floating_text(pos, "先机！", Color(0.88, 0.92, 0.62), 30)
		_flash(Color(0.82, 0.88, 0.56), 0.07)
		_play_sfx("scout_success")
	elif level == "great_fail" or level == "fail":
		_play_sfx("scout_fail")
		if level == "great_fail":
			_shake(5.0, 0.2)


func _combatant_screen_position(side: String) -> Vector2:
	if _map_view == null or GameManager.map == null:
		return get_viewport_rect().size * 0.5
	if side == "companion":
		if GameManager.companion == null or GameManager.companion.actor == null:
			return get_viewport_rect().size * 0.5
		return _map_view.world_to_screen(GameManager.map.cell_center(GameManager.companion.actor.cell_id))
	return _player_screen_position()


func _player_screen_position() -> Vector2:
	if _map_view == null:
		return get_viewport_rect().size * 0.5
	return _map_view.world_to_screen(GameManager.get_visual_position())


func _spawn_hit(pos: Vector2, color: Color, critical: bool, _damage: int) -> void:
	var count := 22 if critical else 12
	var rays: Array[Dictionary] = []
	for i in range(count):
		var angle := TAU * float(i) / float(count) + _rng.randf_range(-0.22, 0.22)
		rays.append({
			"dir": Vector2.RIGHT.rotated(angle),
			"speed": _rng.randf_range(54.0, 86.0) if critical else _rng.randf_range(30.0, 56.0),
		})
	_effects.append({
		"kind": "burst", "pos": pos, "age": 0.0,
		"life": 0.48 if critical else 0.32,
		"color": color, "rays": rays,
	})
	_spawn_ring(pos, color, 72.0 if critical else 42.0)
	if critical:
		_effects.append({
			"kind": "slash", "pos": pos, "age": 0.0, "life": 0.26,
			"angle": -0.72, "length": 74.0, "color": color,
		})
		_effects.append({
			"kind": "slash", "pos": pos, "age": 0.0, "life": 0.26,
			"angle": 0.72, "length": 74.0, "color": color,
		})
	_trim_effects()


func _spawn_ring(pos: Vector2, color: Color, max_radius: float) -> void:
	_effects.append({
		"kind": "ring", "pos": pos, "age": 0.0, "life": 0.34,
		"radius": 7.0, "max_radius": max_radius, "color": color,
	})
	_trim_effects()


func _trim_effects() -> void:
	while _effects.size() > MAX_EFFECTS:
		_effects.pop_front()


func _spawn_floating_text(pos: Vector2, text: String, color: Color, font_size: int) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", 7)
	label.add_theme_color_override("font_outline_color", Color(0.045, 0.035, 0.025, 0.96))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = Vector2(260, 56)
	label.position = pos - Vector2(130, 34) + Vector2(_rng.randf_range(-9.0, 9.0), 0.0)
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(0.68, 0.68)
	add_child(label)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 62.0, 0.9) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.32).set_delay(0.56)
	tween.chain().tween_callback(label.queue_free)


func _flash(color: Color, alpha: float) -> void:
	_flash_color = color
	_flash_alpha = maxf(_flash_alpha, alpha)


func _shake(strength: float, duration: float) -> void:
	if _map_view == null:
		return
	_shake_strength = maxf(_shake_strength, strength)
	_shake_duration = maxf(_shake_duration, duration)
	_shake_time = maxf(_shake_time, duration)


func _update_shake(delta: float) -> void:
	if _map_view == null:
		return
	if _shake_time <= 0.0:
		if _map_view.position != _map_base_position:
			_map_view.position = _map_base_position
		_shake_strength = 0.0
		_shake_duration = 0.0
		return
	_shake_time = maxf(0.0, _shake_time - delta)
	var falloff := _shake_time / maxf(_shake_duration, 0.001)
	var offset := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
	_map_view.position = _map_base_position + offset * _shake_strength * falloff


func _build_combo_label() -> void:
	_combo_label = Label.new()
	_combo_label.visible = false
	_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_label.anchor_left = 0.5
	_combo_label.anchor_right = 0.5
	_combo_label.anchor_top = 0.0
	_combo_label.anchor_bottom = 0.0
	_combo_label.offset_left = -280.0
	_combo_label.offset_right = 280.0
	_combo_label.offset_top = 94.0
	_combo_label.offset_bottom = 154.0
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_combo_label.add_theme_font_size_override("font_size", 34)
	_combo_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.36))
	_combo_label.add_theme_constant_override("outline_size", 9)
	_combo_label.add_theme_color_override("font_outline_color", Color(0.12, 0.06, 0.02, 0.96))
	_combo_label.pivot_offset = Vector2(280, 30)
	add_child(_combo_label)


func _show_combo(count: int) -> void:
	if _combo_label == null:
		return
	_combo_token += 1
	var token := _combo_token
	if _combo_tween != null and _combo_tween.is_valid():
		_combo_tween.kill()
	_combo_label.visible = true
	_combo_label.text = COMBO_HOT_STYLE % count if count >= 3 else COMBO_WINDOW_STYLE % count
	_combo_label.modulate = Color(1, 1, 1, 1)
	_combo_label.scale = Vector2(0.55, 0.55)
	_combo_tween = _combo_label.create_tween()
	_combo_tween.tween_property(_combo_label, "scale", Vector2(1.16, 1.16), 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_combo_tween.tween_property(_combo_label, "scale", Vector2.ONE, 0.14)
	_combo_tween.tween_interval(0.62)
	_combo_tween.tween_property(_combo_label, "modulate:a", 0.0, 0.28)
	_combo_tween.tween_callback(func() -> void:
		if token == _combo_token and _combo_label != null:
			_combo_label.visible = false
	)


func _build_sfx_players() -> void:
	for i in range(MAX_SFX_PLAYERS):
		var player := AudioStreamPlayer.new()
		player.volume_db = -7.0
		add_child(player)
		_sfx_players.append(player)


func _play_sfx(id: String) -> void:
	if DisplayServer.get_name() == "headless" or _sfx_players.is_empty():
		return
	var stream: AudioStreamWAV = _sfx_cache.get(id)
	if stream == null:
		stream = _build_sfx(id)
		if stream == null:
			return
		_sfx_cache[id] = stream
	var player := _sfx_players[_sfx_cursor % _sfx_players.size()]
	_sfx_cursor += 1
	player.stream = stream
	player.play()


## 运行时合成短音效：每个音符是 [开始秒, 长度秒, 起始频率, 结束频率, 振幅]。
func _build_sfx(id: String) -> AudioStreamWAV:
	var notes: Array = []
	var duration := 0.2
	var noise := 0.0
	match id:
		"hit":
			notes = [[0.0, 0.16, 240.0, 92.0, 0.62]]
			duration = 0.19
			noise = 0.26
		"crit":
			notes = [[0.0, 0.28, 560.0, 150.0, 0.55], [0.0, 0.18, 1320.0, 880.0, 0.24]]
			duration = 0.32
			noise = 0.30
		"dust":
			notes = [[0.0, 0.12, 160.0, 100.0, 0.24]]
			duration = 0.14
			noise = 0.40
		"miss":
			notes = [[0.0, 0.12, 185.0, 120.0, 0.22]]
			duration = 0.14
			noise = 0.48
		"hurt":
			notes = [[0.0, 0.24, 128.0, 58.0, 0.68]]
			duration = 0.27
			noise = 0.22
		"scout_success":
			notes = [
				[0.0, 0.18, 523.25, 523.25, 0.26],
				[0.07, 0.18, 659.25, 659.25, 0.26],
				[0.14, 0.30, 783.99, 783.99, 0.30],
			]
			duration = 0.52
		"scout_great":
			notes = [
				[0.0, 0.16, 523.25, 523.25, 0.24],
				[0.06, 0.16, 659.25, 659.25, 0.25],
				[0.12, 0.18, 783.99, 783.99, 0.27],
				[0.18, 0.34, 1046.50, 1046.50, 0.32],
			]
			duration = 0.60
		"scout_fail":
			notes = [[0.0, 0.24, 330.0, 220.0, 0.24], [0.12, 0.26, 247.0, 165.0, 0.22]]
			duration = 0.42
		"combo":
			notes = [[0.0, 0.16, 880.0, 1174.66, 0.34], [0.07, 0.22, 1318.51, 1760.0, 0.28]]
			duration = 0.33
		"click":
			notes = [[0.0, 0.035, 1500.0, 1150.0, 0.22]]
			duration = 0.045
		_:
			return null
	return _synth_wav(notes, duration, noise)


func _synth_wav(notes: Array, duration: float, noise: float) -> AudioStreamWAV:
	var rate := 22050
	var frames := maxi(1, int(rate * duration))
	var samples := PackedFloat32Array()
	samples.resize(frames)
	var phases: Array[float] = []
	phases.resize(notes.size())
	var peak := 0.001
	for i in range(frames):
		var t := float(i) / float(rate)
		var sample := 0.0
		for n in range(notes.size()):
			var note: Array = notes[n]
			var start := float(note[0])
			var note_length := float(note[1])
			if t < start or t >= start + note_length:
				continue
			var local := (t - start) / note_length
			var freq := lerpf(float(note[2]), float(note[3]), local)
			phases[n] += TAU * freq / float(rate)
			var envelope := minf(local / 0.035, 1.0) * pow(1.0 - local, 1.8)
			sample += sin(phases[n]) * envelope * float(note[4])
		if noise > 0.0:
			var noise_envelope := pow(maxf(0.0, 1.0 - t / duration), 2.0)
			sample += _rng.randf_range(-1.0, 1.0) * noise * noise_envelope
		samples[i] = sample
		peak = maxf(peak, absf(sample))
	var normalize := 0.86 / peak
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in range(frames):
		var value := int(clampf(samples[i] * normalize, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, value)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	return stream


## ---------------- 按钮回弹 ----------------

func _bind_existing_buttons() -> void:
	var root := get_parent()
	if root == null:
		return
	for node in root.find_children("*", "Button", true, false):
		_bind_button(node as Button)


func _on_node_added(node: Node) -> void:
	if node is Button and _is_under_ui(node):
		call_deferred("_bind_button", node)


func _is_under_ui(node: Node) -> bool:
	var ui := get_parent()
	var current := node
	while current != null:
		if current == ui:
			return true
		current = current.get_parent()
	return false


func _bind_button(button: Button) -> void:
	if button == null or not is_instance_valid(button):
		return
	if button.has_meta("feedback_bound"):
		return
	button.set_meta("feedback_bound", true)
	button.button_down.connect(_on_button_down.bind(button))
	button.button_up.connect(_on_button_up.bind(button))
	button.pressed.connect(_play_sfx.bind("click"))


func _on_button_down(button: Button) -> void:
	if button.disabled or not is_instance_valid(button):
		return
	var token := int(button.get_meta("feedback_press_token", 0)) + 1
	button.set_meta("feedback_press_token", token)
	button.pivot_offset = button.size * 0.5
	var tween := button.create_tween()
	tween.tween_property(button, "scale", Vector2(0.94, 0.94), 0.055) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_reset_button_after_press(button, token)


## 按钮可能在按下后被禁用，收不到 button_up；超时后主动弹回，避免卡在缩小状态。
func _reset_button_after_press(button: Button, token: int) -> void:
	await get_tree().create_timer(0.22).timeout
	if not is_instance_valid(button):
		return
	if int(button.get_meta("feedback_press_token", -1)) != token:
		return
	_rebound_button(button)


func _on_button_up(button: Button) -> void:
	if not is_instance_valid(button):
		return
	button.set_meta("feedback_press_token", int(button.get_meta("feedback_press_token", 0)) + 1)
	_rebound_button(button)


func _rebound_button(button: Button) -> void:
	if not is_instance_valid(button):
		return
	button.pivot_offset = button.size * 0.5
	var tween := button.create_tween()
	tween.tween_property(button, "scale", Vector2(1.045, 1.045), 0.075) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(button, "scale", Vector2.ONE, 0.11) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)