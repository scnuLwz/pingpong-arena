extends Node3D
## 羽毛球小游戏主控 (Godot 4.x, GDScript)
##
## 玩法：
##   1. 站在己方半场，手持球拍
##   2. 对方（发球机）随机把球发到你的场地内
##   3. 按鼠标左键挥拍，在拍子够得到的范围内击球
##   4. 击回去的球落在对方半场内 → 得分；没接到 / 出界 → 失分
##
## 难度影响：球速（飞行时间）、落点刁钻程度、击球判定窗口大小、反应时间。
##
## 场地坐标约定（与 node_3d.tscn 一致）：
##   - 球场沿 Z 轴铺开，球网在 z = 0
##   - 玩家半场：z > 0（防守/接球侧）
##   - 对方半场：z < 0（球发来的方向 / 得分落点区）
##   - 场地半长 half_len，半宽 half_wid

signal score_changed(player: int, opponent: int)
signal state_changed(new_state: String)
signal message_changed(text: String)

enum State { IDLE, SERVE_DELAY, INCOMING, RALLY, POINT }

# ───────────── 场地尺寸（真实单打场地 13.4 x 5.18）─────────────
@export_group("场地")
@export var court_half_length: float = 6.7    # 半场长（全场 13.4m）
@export var court_half_width: float = 2.59    # 半场宽（全场 5.18m）
@export var net_height: float = 1.55

# ───────────── 难度 ─────────────
@export_group("难度")
@export_enum("简单", "普通", "困难") var difficulty: int = 1
## 三档难度参数：
##   flight_time  球飞到你场地所需时间（越小越快）
##   spread       落点随机范围（占场地比例，越大越刁钻）
##   hit_radius   击球判定半径（越大越好打）
##   hit_window   挥拍有效时间窗（秒）
@export var easy_flight_time: float = 1.85
@export var easy_spread: float = 0.45
@export var easy_hit_radius: float = 1.15
@export var easy_hit_window: float = 0.34

@export var normal_flight_time: float = 1.45
@export var normal_spread: float = 0.70
@export var normal_hit_radius: float = 0.90
@export var normal_hit_window: float = 0.26

@export var hard_flight_time: float = 1.05
@export var hard_spread: float = 0.95
@export var hard_hit_radius: float = 0.68
@export var hard_hit_window: float = 0.18

# ───────────── 击球 ─────────────
@export_group("击球")
## 挥拍后多久内可以击球（秒）。这段时间内每一帧都会判定，
## 所以「早一点按」也能打到，不用卡在精确那一帧。
@export var swing_valid_duration: float = 0.34
## 回球飞行时间（秒）。越小回球越平快
@export var return_flight_time: float = 1.25
## 击球时机不完美时，落点的最大偏移（米）。打准了就是 0。
@export var hit_error_max: float = 2.2
## 是否显示落点预测圈（新手很需要）
@export var show_landing_marker: bool = true

# ───────────── 流程 ─────────────
@export_group("流程")
@export var serve_delay: float = 1.4
@export var point_pause: float = 1.2
@export var auto_serve: bool = true

# 引用（在 _ready 里解析，也支持外部赋值）
@export var shuttle_path: NodePath
@export var racket_path: NodePath
@export var player_path: NodePath

# 说明：不用 `var _shuttle: Shuttle` 是因为 class_name 依赖全局类缓存，
# 用 --check-only / 部分加载路径下会解析失败。改成 Node3D + 调用处 `as Shuttle` 强转，
# 这样在任何加载路径下都能编译通过。
var _shuttle: Node3D
var _racket_view: Node3D
var _player: CharacterBody3D

var _state: State = State.IDLE
var _timer: float = 0.0
var _swing_timer: float = -1.0   # >0 表示挥拍有效窗口内
var _hit_cooldown: float = 0.0   # 防止一次挥拍连击同一颗球
var _prev_shuttle_z: float = 0.0 # 过网检测用

var _player_score: int = 0
var _opponent_score: int = 0

var _hud: CanvasLayer
var _label: Label
var _score_label: Label
var _landing_marker: Node3D


func _ready() -> void:
	# 不 randomize() 的话 Godot 每次运行用同一个默认种子，
	# "随机发球" 会变成每次都发到同一个位置。
	randomize()
	_resolve_refs()
	_build_landing_marker()
	_build_hud()
	set_state(State.IDLE)
	if auto_serve:
		start_serve()


func _resolve_refs() -> void:
	if shuttle_path != NodePath(""):
		_shuttle = get_node_or_null(shuttle_path)
	if _shuttle == null:
		_shuttle = get_node_or_null("Shuttle")
	if _shuttle == null:
		_shuttle = get_tree().get_first_node_in_group("shuttle")
	if _shuttle != null and _shuttle.has_signal("landed"):
		if not _shuttle.is_connected("landed", Callable(self, "on_shuttle_landed")):
			_shuttle.connect("landed", Callable(self, "on_shuttle_landed"))

	if racket_path != NodePath(""):
		_racket_view = get_node_or_null(racket_path)
	if _racket_view == null:
		_racket_view = get_tree().get_first_node_in_group("racket")

	if player_path != NodePath(""):
		_player = get_node_or_null(player_path)
	if _player == null:
		var p := get_tree().get_first_node_in_group("player")
		if p is CharacterBody3D:
			_player = p


# ───────────── 难度参数 ─────────────
func _flight_time() -> float:
	match difficulty:
		0: return easy_flight_time
		2: return hard_flight_time
		_: return normal_flight_time


func _spread() -> float:
	match difficulty:
		0: return easy_spread
		2: return hard_spread
		_: return normal_spread


func _hit_radius() -> float:
	match difficulty:
		0: return easy_hit_radius
		2: return hard_hit_radius
		_: return normal_hit_radius


func difficulty_name() -> String:
	match difficulty:
		0: return "简单"
		2: return "困难"
		_: return "普通"


func set_difficulty(d: int) -> void:
	difficulty = clampi(d, 0, 2)
	_msg("难度：" + difficulty_name())


# ───────────── 状态机 ─────────────
func set_state(s: State) -> void:
	_state = s
	emit_signal("state_changed", State.keys()[s])


func start_serve() -> void:
	_timer = serve_delay
	set_state(State.SERVE_DELAY)
	_msg("准备接球…")


func _do_serve() -> void:
	var sh := _shuttle as Shuttle
	if sh == null:
		return

	# 发射点：对方半场中后部
	var from := Vector3(
		randf_range(-court_half_width * 0.5, court_half_width * 0.5),
		2.1,
		-court_half_length * randf_range(0.55, 0.85)
	)

	# 目标落点：玩家半场内，按难度扩大散布
	var sp := _spread()
	var tx := randf_range(-court_half_width * sp, court_half_width * sp)
	var tz := randf_range(court_half_length * 0.25, court_half_length * lerpf(0.75, 1.0, sp))

	var target := Vector3(tx, 0.02, tz)
	var v: Vector3 = sh.solve_velocity(from, target, _flight_time(), 0.02)

	sh.launch(from, v, 0.02)
	_prev_shuttle_z = from.z
	_hit_cooldown = 0.0
	set_state(State.INCOMING)
	_msg("球来了！")


## 兜底的初速度计算（无阻力近似）
func _manual_velocity(from: Vector3, target: Vector3, t: float) -> Vector3:
	var v := (target - from) / maxf(t, 0.1)
	v.y += 0.5 * 9.8 * t
	return v


func _process(delta: float) -> void:
	match _state:
		State.SERVE_DELAY:
			_timer -= delta
			if _timer <= 0.0:
				_do_serve()
		State.POINT:
			_timer -= delta
			if _timer <= 0.0 and auto_serve:
				start_serve()

	# 挥拍有效窗口倒计时（窗口内每帧都判一次，所以提前按也打得到）
	if _swing_timer > 0.0:
		_swing_timer -= delta
		if _swing_timer <= 0.0:
			_swing_timer = -1.0

	if _hit_cooldown > 0.0:
		_hit_cooldown -= delta

	_update_hud()


func _physics_process(_delta: float) -> void:
	# 挥拍窗口内持续判定 —— 这是「能打到球」的关键
	if _swing_timer > 0.0:
		_check_hit()
	_check_net()
	_update_landing_marker()


# ───────────── 击球 ─────────────
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
		and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_try_hit()
	if event.is_action_pressed("hit") or event.is_action_pressed("attack"):
		_try_hit()
	if event.is_action_pressed("difficulty"):
		set_difficulty((difficulty + 1) % 3)


## 玩家挥拍 → 开一个判定窗口（不是只判按下的那一帧）
func _try_hit() -> void:
	if _racket_view != null and _racket_view.has_method("trigger_swing"):
		_racket_view.call("trigger_swing")
	_swing_timer = swing_valid_duration
	# 按下瞬间先判一次，手感更跟手
	_check_hit()


## 拍面中心的世界坐标（优先用球拍自己的锚点）
func _racket_point() -> Vector3:
	if _racket_view != null and _racket_view.has_method("head_position"):
		return _racket_view.call("head_position") as Vector3
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return global_position
	var fwd := -cam.global_transform.basis.z
	return cam.global_position + fwd * 0.45


## 时机质量 0~1：挥到最有劲儿那一刻（进度约 0.4）最好
func _timing_quality() -> float:
	if _racket_view != null and _racket_view.has_method("swing_progress"):
		var p := float(_racket_view.call("swing_progress"))
		if p >= 0.0:
			return clampf(1.0 - absf(p - 0.40) / 0.40, 0.0, 1.0)
	return 1.0


## 检查这一拍是否够得到球。够到就击球，返回 true。
func _check_hit() -> bool:
	var sh := _shuttle as Shuttle
	if sh == null or not sh.is_flying():
		return false
	if _hit_cooldown > 0.0:
		return false

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false

	# 用拍面中心做判定，比用相机真实得多。
	# 判定体是个「椭球」而不是球：水平方向是臂展，垂直方向是挥拍幅度，
	# 上下抡拍本来就比左右够得开，所以垂直给得更宽容。
	var rp := _racket_point()
	var d: Vector3 = sh.global_position - rp
	var r := _hit_radius()
	var h := Vector2(d.x, d.z).length() / maxf(r * 1.20, 0.01)
	var v := d.y / maxf(r * 1.55, 0.01)
	if h * h + v * v > 1.0:
		return false

	# 球必须在身前（不能在背后乱打）
	var fwd := -cam.global_transform.basis.z
	var to_ball := (sh.global_position - cam.global_position).normalized()
	if to_ball.dot(fwd) < 0.10:
		return false

	_do_hit(fwd)
	return true


func _do_hit(fwd: Vector3) -> void:
	var sh := _shuttle as Shuttle
	if sh == null:
		return

	var from := sh.global_position
	# 时机越准，落点越贴近目标
	var quality := _timing_quality()
	var err := (1.0 - quality) * hit_error_max

	var tx := randf_range(-court_half_width * 0.80, court_half_width * 0.80) \
			 + randf_range(-err, err)
	var tz := -randf_range(court_half_length * 0.30, court_half_length * 0.90) \
			 + randf_range(-err, err)
	var target := Vector3(tx, 0.02, tz)

	var v := _solve_return(from, target)
	sh.launch(from, v, 0.02)

	_swing_timer = -1.0
	_hit_cooldown = 0.35
	set_state(State.RALLY)
	_msg("击球！" + ("好球" if quality > 0.6 else ""))


## 求一拍能过网、且尽量落在 target 的初速度。
## 先按 return_flight_time 解一次，模拟发现过不了网就把弧线拉高再来。
func _solve_return(from: Vector3, target: Vector3) -> Vector3:
	var sh := _shuttle as Shuttle
	if sh == null:
		return Vector3(0, 0, -1)

	var t := return_flight_time
	for _i in range(8):
		var v := sh.solve_velocity(from, target, t, 0.02)
		var h := sh.simulate_net_height(from, v, 0.0, 0.02)
		if h >= net_height + 0.12:
			return v
		t += 0.10
	return sh.solve_velocity(from, target, t, 0.02)


## 过网检测：球从己方半场穿到 z<=0，且高度低于网、横向在网宽内 → 下网
func _check_net() -> void:
	var sh := _shuttle as Shuttle
	if sh == null or not sh.is_flying():
		return
	var z := sh.global_position.z
	if _prev_shuttle_z > 0.0 and z <= 0.0:
		var y := sh.global_position.y
		if y < net_height and absf(sh.global_position.x) <= court_half_width + 0.6:
			sh.stop()
			sh.global_position.y = maxf(y, 0.02)
			_opponent_score += 1
			emit_signal("score_changed", _player_score, _opponent_score)
			_msg("下网了… %d" % _opponent_score)
			_timer = point_pause
			set_state(State.POINT)
	_prev_shuttle_z = z


# ───────────── 计分 ─────────────
## 由 shuttle 的 landed 信号调用
## 注意：信号声明为 landed(pos, in_bounds)，这里的参数个数必须完全一致，
## 否则 Godot 4 会在 emit 时报错，回调根本不会被调用（比分就不会变）。
func on_shuttle_landed(pos: Vector3, _in_bounds: bool = true) -> void:
	# 判断落在哪一侧、是否在界内
	var in_x := absf(pos.x) <= court_half_width
	var in_z := absf(pos.z) <= court_half_length
	var in_bounds := in_x and in_z

	if pos.z < 0.0:
		# 落在对方半场 → 玩家得分
		if in_bounds:
			_player_score += 1
			_msg("得分！+%d" % _player_score)
		else:
			_msg("出界了…")
	else:
		# 落在自己半场 → 没接到
		_opponent_score += 1
		_msg("没接到… %d" % _opponent_score)

	emit_signal("score_changed", _player_score, _opponent_score)
	_timer = point_pause
	set_state(State.POINT)


func _msg(t: String) -> void:
	emit_signal("message_changed", t)
	if _label:
		_label.text = t


# ───────────── 落点预测圈 ─────────────
func _build_landing_marker() -> void:
	_landing_marker = Node3D.new()
	_landing_marker.name = "LandingMarker"
	add_child(_landing_marker)

	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var rm := TorusMesh.new()
	rm.inner_radius = 0.30
	rm.outer_radius = 0.38
	rm.rings = 32
	rm.ring_segments = 8
	ring.mesh = rm
	ring.rotation_degrees = Vector3(90, 0, 0)   # 平躺在地上
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.20, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, m)
	_landing_marker.add_child(ring)
	_landing_marker.visible = false


func _update_landing_marker() -> void:
	if _landing_marker == null:
		return
	var sh := _shuttle as Shuttle
	if sh == null or not sh.is_flying() or not show_landing_marker:
		_landing_marker.visible = false
		return

	var land: Vector3 = sh.simulate_landing(sh.global_position, sh.velocity, 0.02)
	_landing_marker.visible = true
	_landing_marker.global_position = Vector3(land.x, 0.03, land.z)


# ───────────── HUD ─────────────
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "GameHUD"
	add_child(_hud)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	_hud.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_label = Label.new()
	_label.text = "羽毛球"
	_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_label)

	_score_label = Label.new()
	_score_label.text = "0 : 0"
	_score_label.add_theme_font_size_override("font_size", 26)
	vbox.add_child(_score_label)

	var hint := Label.new()
	hint.text = "鼠标左键/F=挥拍　WASD=移动　Shift=冲刺　空格=跳\nTab=切换难度　Esc=释放鼠标"
	hint.add_theme_font_size_override("font_size", 14)
	vbox.add_child(hint)


func _update_hud() -> void:
	if _score_label != null:
		_score_label.text = "%d : %d　[%s]" % [
			_player_score, _opponent_score, difficulty_name()
		]


func get_score() -> Vector2i:
	return Vector2i(_player_score, _opponent_score)


# ───────────── 对外接口（调试 / 自动化测试用）─────────────
func get_state() -> int:
	return _state


func get_state_name() -> String:
	return State.keys()[_state]


func get_hit_radius() -> float:
	return _hit_radius()


func get_flight_time() -> float:
	return _flight_time()


func get_racket_point() -> Vector3:
	return _racket_point()


## 玩家挥拍（等价于按鼠标左键 / F）
func swing() -> void:
	_try_hit()
