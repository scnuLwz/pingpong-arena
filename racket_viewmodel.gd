extends Node3D
## 第一人称「手持羽毛球拍」视觉控制器 (Godot 4.x, GDScript)
##
## 挂载位置：Player/Head/Camera3D/RacketRig
##
## 结构（全部在本脚本里程序化生成，不用在场景里手动摆）：
##   RacketRig (本节点)
##   └── Racket (Node3D)          <- 原点 = 手腕，挥拍绕这里转
##       ├── Grip    (CylinderMesh) 握把，z ∈ [-0.13, 0]
##       ├── Shaft   (CylinderMesh) 拍杆，z ∈ [-0.33, -0.13]
##       ├── Throat  (BoxMesh)      拍喉，z ≈ -0.36
##       ├── Frame   (TorusMesh)    拍框，z = -0.495
##       ├── Strings (CylinderMesh) 拍面（极薄圆柱，Godot 4 没有 CircleMesh）
##       └── Head    (Marker3D)     拍面中心锚点，z = -0.495，击球判定用
##
## 朝向：局部 -Z = 拍头方向（远离手），+Z = 朝手。
##       rotation.x 取正值 → 拍头抬到手腕上方（正确握法）；
##       取负值会把拍头压到下方，看起来就是"上下颠倒"。
##
## 手：由 fp_hand.gd 程序化生成（掌 + 四指各 3 节 + 拇指 + 腕 + 前臂），
## 挂在 Racket 节点下，挥拍时手跟着一起走，并带一点「手腕滞后」。

const HAND := preload("res://fp_hand.gd")

@export_group("挥拍")
## 挥拍最大角度（度）。注意：现在绕「手腕」转，同样角度的视觉幅度比绕中点大得多，
## 所以比旧值（115）小。80° 时拍头会甩到画面下方之外，力度感够又不至于长时间消失。
@export var swing_degrees: float = 80.0
## 挥拍时向内的偏转（度）
@export var swing_yaw_degrees: float = 18.0
## 挥拍时长（秒）
@export var swing_duration: float = 0.32
## 挥拍时拍子向前伸出的距离（米），增加"够到球"的感觉
@export var swing_reach: float = 0.14

@export_group("待机")
## 待机时极缓慢的上下浮动（度）
@export var idle_bob_degrees: float = 1.4
## 浮动频率
@export var idle_bob_frequency: float = 1.15
## 走路时轻微起伏（度）
@export var walk_bob_degrees: float = 2.2
## 走路起伏频率
@export var walk_bob_frequency: float = 4.2

@export_group("惯性")
## 视角转动时拍子的滞后幅度（度）
@export var sway_degrees: float = 2.8
## 滞后回正速度
@export var sway_speed: float = 6.0

@export_group("外观")
## 拍面颜色（拍线）
@export var string_color: Color = Color(0.95, 0.95, 0.92, 0.28)
## 拍框颜色
@export var frame_color: Color = Color(0.86, 0.20, 0.24, 1.0)
## 握把颜色
@export var grip_color: Color = Color(0.16, 0.17, 0.20, 1.0)
## 拍杆颜色（金属）
@export var shaft_color: Color = Color(0.78, 0.80, 0.85, 1.0)
## 是否显示拍子
@export var show_racket: bool = true

@export_group("手")
@export var show_hand: bool = true
@export var skin_color: Color = Color(0.50, 0.38, 0.315, 1.0)
## 挥拍时手腕的滞后比例
@export var wrist_lag_ratio: float = 0.18

@export_group("补光")
@export var enable_fill_light: bool = true
@export var fill_light_color: Color = Color(1.0, 0.97, 0.92, 1.0)
@export var fill_light_energy: float = 0.45
@export var fill_light_range: float = 3.0

# ───────────── 内部 ─────────────
var _racket: Node3D
var _head: Marker3D
var _hand: Node3D
var _player: CharacterBody3D
var _cam: Camera3D

var _rest_rot: Vector3 = Vector3.ZERO
var _rest_pos: Vector3 = Vector3.ZERO

var _swing_time: float = -1.0
var _pending: bool = false

var _idle_phase: float = 0.0
var _walk_phase: float = 0.0

var _sway: Vector2 = Vector2.ZERO
var _last_basis: Basis = Basis.IDENTITY


func _ready() -> void:
	_player = _find_player()
	_cam = get_parent() as Camera3D
	if _cam:
		_last_basis = _cam.global_transform.basis

	_racket = _build_racket()
	add_child(_racket)

	_rest_rot = _racket.rotation
	_rest_pos = _racket.position

	if enable_fill_light:
		_create_fill_light()

	_racket.visible = show_racket


func _find_player() -> CharacterBody3D:
	var n: Node = self
	while n:
		if n is CharacterBody3D:
			return n as CharacterBody3D
		n = n.get_parent()
	return null


# ───────────── 程序化生成拍子 ─────────────
func _build_racket() -> Node3D:
	var root := Node3D.new()
	root.name = "Racket"

	# ── 重要：模型原点 = 手腕（握把末端），不是拍子中点 ──
	# 这样 Racket 节点的旋转就是「绕手腕转」，挥拍才自然；
	# 原点放在中点会让挥拍看起来像拍子原地翻转。
	# 局部 -Z 指向拍头（远离手的方向），+Z 朝手。
	var grip := MeshInstance3D.new()
	grip.name = "Grip"
	var grip_m := CylinderMesh.new()
	grip_m.top_radius = 0.016
	grip_m.bottom_radius = 0.019
	grip_m.height = 0.13
	grip_m.radial_segments = 16
	grip.mesh = grip_m
	grip.position = Vector3(0, 0, -0.065)      # 覆盖 z ∈ [-0.13, 0]
	grip.rotation_degrees = Vector3(90, 0, 0)   # 圆柱默认沿 Y，转成沿 Z
	grip.set_surface_override_material(0, _mat(grip_color, 0.85))
	root.add_child(grip)

	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	var shaft_m := CylinderMesh.new()
	shaft_m.top_radius = 0.0055
	shaft_m.bottom_radius = 0.0060
	shaft_m.height = 0.20
	shaft_m.radial_segments = 12
	shaft.mesh = shaft_m
	shaft.position = Vector3(0, 0, -0.23)       # 覆盖 z ∈ [-0.33, -0.13]
	shaft.rotation_degrees = Vector3(90, 0, 0)
	shaft.set_surface_override_material(0, _mat(shaft_color, 0.35, 0.75))
	root.add_child(shaft)

	# 拍喉：杆与框之间的过渡
	var throat := MeshInstance3D.new()
	throat.name = "Throat"
	var throat_m := BoxMesh.new()
	throat_m.size = Vector3(0.055, 0.012, 0.055)
	throat.mesh = throat_m
	throat.position = Vector3(0, 0, -0.36)      # 接在拍杆前端 -0.33 之后
	throat.set_surface_override_material(0, _mat(shaft_color, 0.4, 0.7))
	root.add_child(throat)

	# 拍框
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_m := TorusMesh.new()
	frame_m.inner_radius = 0.105
	frame_m.outer_radius = 0.120
	frame_m.rings = 40          # 沿大圆的段数
	frame_m.ring_segments = 16  # 沿管截面的段数
	frame.mesh = frame_m
	frame.position = Vector3(0, 0, -0.495)
	frame.set_surface_override_material(0, _mat(frame_color, 0.45))
	root.add_child(frame)

	# 拍面：Godot 4 没有 CircleMesh，用极薄的圆柱代替（视觉上就是一个圆盘）
	var strings := MeshInstance3D.new()
	strings.name = "Strings"
	var str_m := CylinderMesh.new()
	str_m.top_radius = 0.103
	str_m.bottom_radius = 0.103
	str_m.height = 0.004
	str_m.radial_segments = 24
	strings.mesh = str_m
	strings.position = Vector3(0, 0, -0.495)
	strings.rotation_degrees = Vector3(90, 0, 0)
	var sm := _mat(string_color, 0.6)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	strings.set_surface_override_material(0, sm)
	root.add_child(strings)

	# 拍面中心锚点：击球判定用这里（比用相机位置真实得多）
	var head := Marker3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0, -0.495)      # 拍面中心
	root.add_child(head)
	_head = head

	# ── 握拍的手（程序化生成，挂在拍子下 → 挥拍时手一起动）──
	if show_hand:
		var h := HAND.new()
		h.skin_color = skin_color
		h.handle_half_x = 0.0150    # 羽毛球拍柄半宽
		h.handle_half_y = 0.0175    # 半厚
		h.knuckle_z0 = -0.105       # 食指掌指关节，离拍杆 0.025
		h.knuckle_dz = 0.0225
		_hand = h.build()
		root.add_child(_hand)

	# ── 姿态：拍头朝上举在身前右侧，握把（手）在画面下方之外 ──
	# 原点现在是手腕，所以 position 直接就是手腕在相机空间的位置：
	#   手腕 (0.22, -0.26, -0.30) → 垂直角 40.9° > 半 FOV 35°，手腕在画外（正确）。
	#   rotation.x = +15° 让拍头抬到手腕「上方」（+Y），这是修「上下颠倒」的关键：
	#   之前用 -24° 会把拍头压到手腕下方，看起来像倒着拿拍子。
	# 按 FOV=70 反推验算（半 FOV 垂直 35° / 水平约 51.2°）：
	#   拍头   → 垂直角 10.0° 向下、水平角 27.1° 向右，落在画面右上。
	#   拍杆   → 垂直角 21.5°，清晰可见。
	#   手指关节 → 垂直角 32.8°，刚好在画面底边之内 —— 抬高 0.07m 是为了让握拍的手露出来
	#             （改 pose 务必重算：手持物必须满足 atan2(-y,-z) < FOV/2，否则整只手出画）。
	root.position = Vector3(0.22, -0.26, -0.30)
	root.rotation_degrees = Vector3(15, -20, 0)
	return root


## 拍面中心的世界坐标（击球判定的核心点）
func head_position() -> Vector3:
	if _head != null and is_instance_valid(_head):
		return _head.global_position
	return global_position


func _mat(col: Color, rough: float, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


func _create_fill_light() -> void:
	var l := OmniLight3D.new()
	l.name = "RacketFillLight"
	l.light_color = fill_light_color
	l.light_energy = fill_light_energy
	l.omni_range = fill_light_range
	l.omni_attenuation = 0.5
	l.position = Vector3(0.10, -0.05, 0.10)
	l.shadow_enabled = false
	add_child(l)


# ───────────── 挥拍 ─────────────
func trigger_swing() -> void:
	if _swing_time < 0.0:
		_swing_time = 0.0
	else:
		_pending = true


func is_swinging() -> bool:
	return _swing_time >= 0.0


## 挥拍进度 0~1，供击球判定用（挥到最有劲儿的时候约为 0.35）
func swing_progress() -> float:
	if _swing_time < 0.0:
		return -1.0
	return clampf(_swing_time / maxf(swing_duration, 0.001), 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			trigger_swing()
	if event.is_action_pressed("attack") or event.is_action_pressed("swing") \
		or event.is_action_pressed("hit"):
		trigger_swing()


func _process(delta: float) -> void:
	if _racket == null:
		return
	_update_swing(delta)
	_update_idle(delta)
	_update_sway(delta)


func _update_swing(delta: float) -> void:
	var amt := 0.0
	var yaw := 0.0
	var reach := 0.0

	if _swing_time >= 0.0:
		_swing_time += delta
		var p := clampf(_swing_time / maxf(swing_duration, 0.001), 0.0, 1.0)
		# MC 式缓动：f6 = 1-(1-p)^3, f7 = sin(f6 * PI)
		var f6 := 1.0 - p
		f6 = f6 * f6 * f6
		f6 = 1.0 - f6
		var f7 := sin(f6 * PI)

		amt = f7 * deg_to_rad(swing_degrees)
		yaw = f7 * deg_to_rad(swing_yaw_degrees)
		reach = f7 * swing_reach

		if _swing_time >= swing_duration:
			_swing_time = -1.0
			if _pending:
				_pending = false
				trigger_swing()

	var rot := _rest_rot
	rot.x -= amt          # 向前下方抡
	rot.y += yaw          # 向画面中心收
	_racket.rotation = rot

	_racket.position = _rest_pos
	_racket.position.z -= reach   # 挥拍时向前伸

	# 手腕滞后：拍子先走、手慢半拍，收拍时自然回弹
	if _hand != null:
		_hand.rotation.x = -amt * wrist_lag_ratio


func _update_idle(delta: float) -> void:
	_idle_phase += delta * idle_bob_frequency

	var speed := 0.0
	if _player:
		var v := _player.velocity
		speed = Vector2(v.x, v.z).length()
	_walk_phase += delta * walk_bob_frequency * clampf(speed / 5.0, 0.0, 1.8)

	var walking := clampf(speed / 2.0, 0.0, 1.0)
	var bob := sin(_idle_phase) * idle_bob_degrees \
			 + sin(_walk_phase) * walk_bob_degrees * walking

	_racket.rotation.x += deg_to_rad(bob) * 0.35
	_racket.position.y += deg_to_rad(bob) * 0.004


func _update_sway(delta: float) -> void:
	if _cam == null:
		return
	var basis := _cam.global_transform.basis
	var d := basis.inverse() * _last_basis
	_last_basis = basis

	var e := d.get_euler()
	var target := Vector2(
		clampf(-e.y * sway_degrees * 12.0, -sway_degrees, sway_degrees),
		clampf(e.x * sway_degrees * 12.0, -sway_degrees, sway_degrees)
	)
	_sway = _sway.lerp(target, clampf(sway_speed * delta, 0.0, 1.0))
	_racket.rotation.y += deg_to_rad(_sway.x) * 0.3
	_racket.rotation.x += deg_to_rad(_sway.y) * 0.3
