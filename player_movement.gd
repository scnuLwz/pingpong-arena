extends CharacterBody3D
## 第一人称角色移动控制器 (Godot 4.x, GDScript)
##
## 挂载位置：Player (CharacterBody3D) —— 场景根节点
## 场景结构：
##   Player (CharacterBody3D)     <- 本脚本
##   ├── CollisionShape3D         <- 长方体碰撞（蹲下时会被压扁）
##   ├── MeshInstance3D           <- 长方体的视觉外观
##   └── Head (Node3D)            <- 相机脚本挂这里（蹲下时整体下沉）
##       └── Camera3D
##
## 与 camera_controller.gd 配合：本脚本只管移动，相机脚本只管视角。
## 方向基于玩家自身朝向，所以鼠标转头后，WASD 会跟着视线走。
##
## ── 本脚本负责的三件事 ──
##  1. 移动 / 冲刺 / 跳跃
##  2. **蹲下与站起**：碰撞盒压扁 + 相机下沉 + 移动变慢，三者同步插值
##  3. **活动范围限制**：玩家被约束在「自己这半边的赛场内」，
##     永远走不到球台对面（球网在 z = 0，玩家侧 z > 0）

@export_group("移动")
## 行走速度
@export var walk_speed: float = 5.0
## 冲刺速度（按住 Shift）
@export var sprint_speed: float = 8.5
## 加速度（越大越跟手，越小越滑）
@export var acceleration: float = 12.0
## 停止时的减速度
@export var friction: float = 16.0

@export_group("跳跃")
## 是否启用跳跃
@export var can_jump: bool = true
## 跳跃初速度
@export var jump_velocity: float = 5.0
## 重力倍率（大于 1 下落更快，手感更干脆）
@export var gravity_multiplier: float = 1.8

@export_group("蹲下")
## 是否启用蹲下（Ctrl 或 C 按住）
@export var can_crouch: bool = true
## 蹲下时移动速度倍率
@export var crouch_speed_scale: float = 0.42
## 蹲下 / 起身的过渡速度（越大越干脆）
@export var crouch_lerp_speed: float = 11.0
## 蹲下时碰撞盒高度相对站立的比例
##   1.8 m → 0.99 m，底边保持贴地不动，所以是「矮下去」而不是「陷下去」
@export var crouch_height_scale: float = 0.55
## 蹲下时相机下沉的距离（米）
@export var crouch_head_drop: float = 0.55

@export_group("活动范围")
## 只允许在自己的半台活动 —— 这是「无法进入球台对面」的硬约束。
## 用位置钳制而不是隐形墙：隐形墙会挡球，而这里球必须能自由穿过 z = 0。
@export var limit_area: bool = true
## X 方向可活动的半宽。
## ★ 用户要的「大幅放宽」（原来是 0.95）：现在能绕到球台**侧身接角球**，
##   也能退到底线后救深球。1.80 的由来是**不是随便取的**，是量出来的：
##   场边最靠内的家具是擦汗台，内沿在 x = 2.75 - 0.20 = 2.55；
##   玩家碰撞盒半宽 0.30，所以 1.80 + 0.30 = 2.10 距家具还剩 0.45 m 余量 ——
##   再放到 2.25 就会蹭到擦汗台（实测间隙只剩 0.10 m，视觉上等于贴身）。
##   台宽半宽仍是 0.7625，所以绕到侧面后离台边约 1.04 m，够挥拍够球。
@export var area_x_abs: float = 1.80
## 可走到的最靠前位置。
## ★ 用户要的「最前只到台面中间」：0.685 = (网 0 + 自己台边 1.37) / 2。
##   原来 0.50 能一路贴到网跟前，人会整个斜插进台面（球台碰撞层已关，
##   玩家不会被台面挡住，是直接穿进台体里），所以往回收半台。
##   ★ **这一项没跟着放宽**：再往前就是球网和对面半场了，是规则红线不是活动范围。
##   代价：近网短球更依赖「按 R 探拍把拍子送出去」够，不能靠人走上去。
@export var area_z_min: float = 0.685
## 身后可退到的最远位置。
## ★ 用户要的「大幅放宽」（原来是 2.60）：3.30 = 端线 1.37 之后 1.93 m，
##   是真实乒乓球运动员能退到极限接深球的位置，再远就够不着球了。
##   ★ 原来的 2.60 正好压在替补席长凳上（长凳 z 范围 2.28~2.56，
##   玩家碰撞盒 z 范围 2.30~2.90 → **完全重叠**，退到底就站进长凳里）。
##   现在长凳改摆到 x = ±3.20 的两侧（见 court_builder._build_sideline_props），
##   3.30 与它不再冲突；同时 serve_zone_max_z 跟到 3.10，
##   免得新放宽的后场变成一大片「不能发球」的死区。
@export var area_z_max: float = 3.30

@export_group("鼠标")
## 是否需要按 Esc 释放鼠标（调试用）
@export var escape_releases_mouse: bool = true

## 获取引擎的重力值（默认 9.8）
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)

# ── 蹲下相关的缓存 ──
var _crouch: float = 0.0          # 0 = 完全站立，1 = 完全蹲下
var _head: Node3D
var _head_rest_y: float = 0.0
var _shape: CollisionShape3D
var _box: BoxShape3D
var _box_h: float = 1.8           # 站立时的碰撞盒高度
var _box_bottom: float = -0.9     # 碰撞盒底边（相对 Player 原点），蹲下时保持不变


func _ready() -> void:
	_head = get_node_or_null("Head")
	if _head != null:
		_head_rest_y = _head.position.y

	_shape = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _shape != null and _shape.shape is BoxShape3D:
		# duplicate()：场景里的 BoxShape3D 是 sub_resource，
		# 直接改 size 会连带改到别处引用同一个形状的节点。
		_box = (_shape.shape as BoxShape3D).duplicate()
		_shape.shape = _box
		_box_h = _box.size.y
		_box_bottom = _shape.position.y - _box.size.y * 0.5


func _physics_process(delta: float) -> void:
	_update_crouch(delta)
	_apply_gravity(delta)
	_handle_jump()
	_handle_movement(delta)
	move_and_slide()
	_clamp_area()


# ───────────── 蹲下 / 站起 ─────────────
func _update_crouch(delta: float) -> void:
	var want := 0.0
	if can_crouch and _pressed("crouch"):
		want = 1.0
	# 近台保护：放开 area_z_min 后玩家能踩上近台，蹲下时相机(Head)会沉到
	# y≈0.79、直接穿进台面(0.760)看到台体内部。靠近 / 站上台面时禁止蹲下，
	# 只在离台较远(z ≥ area_z_min+0.7)才允许蹲。
	if global_position.z < area_z_min + 0.7:
		want = 0.0
	_crouch = move_toward(_crouch, want, delta * crouch_lerp_speed)

	if _box != null:
		var h := _box_h * lerpf(1.0, crouch_height_scale, _crouch)
		_box.size = Vector3(_box.size.x, h, _box.size.z)
		# 底边固定在地面：中心 = 底边 + 半高
		if _shape != null:
			_shape.position.y = _box_bottom + h * 0.5

	if _head != null:
		_head.position.y = _head_rest_y - crouch_head_drop * _crouch


## InputMap 里没注册的动作直接查会刷 ERROR，统一走这个包装
func _pressed(action: String) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


func is_crouching() -> bool:
	return _crouch > 0.5


func crouch_amount() -> float:
	return _crouch


# ───────────── 活动范围 ─────────────
## 「进不了球台对面」靠这里保证：钳制后把对应方向的速度清零，
## 否则玩家会一直贴着边界「搓」出抖动。
func _clamp_area() -> void:
	if not limit_area:
		return
	var p := global_position
	var nx := clampf(p.x, -area_x_abs, area_x_abs)
	var nz := clampf(p.z, area_z_min, area_z_max)
	if is_equal_approx(nx, p.x) and is_equal_approx(nz, p.z):
		return
	if not is_equal_approx(nx, p.x):
		velocity.x = 0.0
	if not is_equal_approx(nz, p.z):
		velocity.z = 0.0
	global_position = Vector3(nx, p.y, nz)


# ───────────── 重力 / 跳跃 ─────────────
## 重力：不在地面时持续下拉
func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * gravity_multiplier * delta


## 跳跃：地面上按跳跃键
func _handle_jump() -> void:
	if can_jump and _pressed("jump") and Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity


# ───────────── 水平移动 ─────────────
## 水平移动：基于自身朝向
func _handle_movement(delta: float) -> void:
	# 读取输入（move_* 已在项目 InputMap 中绑定 WASD）
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# 把「前后左右」按玩家自身朝向转成世界方向
	# 注意：CharacterBody3D 里 -Z 是前方，所以 forward 对应 -Z
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var target_speed := sprint_speed if _pressed("sprint") else walk_speed
	# 蹲下时明显变慢，跑不动
	target_speed *= lerpf(1.0, crouch_speed_scale, _crouch)
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if direction.length_squared() > 0.01:
		# 有输入：朝目标速度加速
		var target := direction * target_speed
		horizontal = horizontal.move_toward(target, acceleration * delta)
	else:
		# 无输入：摩擦力减速到停
		horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z
