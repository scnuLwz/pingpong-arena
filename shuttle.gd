class_name Shuttle
extends Node3D
## 羽毛球 (shuttlecock) —— 带大阻力的弹道 (Godot 4.x, GDScript)
##
## 真实羽毛球的关键特性：
##   - 质量极轻（约 5g），但迎风面积大 → **空气阻力 dominant**
##   - 终速只有约 6.7 m/s（对比：网球约 30 m/s）
##   - 结果是标志性的**不对称轨迹**：飞出去时比较平缓，
##     末段几乎垂直下坠（"杀球"看起来像砸下来）
##
## 物理模型（每帧手动积分，不用 RigidBody）：
##   a = -g·ŷ  -  k·v·|v|
##   其中 k 由终速反推：mg = k·v_t²  →  k = g / v_t²
##   取 v_t = 6.7 → k ≈ 0.218
##
## 落点求解：给定发射点与目标落点，用迭代修正求出初速度。

signal landed(pos: Vector3, in_bounds: bool)

## 重力加速度
@export var gravity: float = 9.8
## 阻力系数 k（越大阻力越强，球越"飘"）。终速 = sqrt(g/k)
@export var drag_k: float = 0.218
## 是否启用阻力（关掉就是普通抛物线，用来对比）
@export var enable_drag: bool = true

## 球的飞行状态
var velocity: Vector3 = Vector3.ZERO
var _flying: bool = false
var _mesh: Node3D
var _floor_y: float = 0.0


func _ready() -> void:
	_mesh = _build_shuttle()
	add_child(_mesh)


# ───────────── 外观：球头 + 羽毛裙 ─────────────
func _build_shuttle() -> Node3D:
	var root := Node3D.new()
	root.name = "ShuttleMesh"

	# 球头（软木，半球状，用压扁的球）
	var cork := MeshInstance3D.new()
	cork.name = "Cork"
	var cm := SphereMesh.new()
	cm.radius = 0.0135
	cm.height = 0.026
	cm.radial_segments = 16
	cm.rings = 10
	cork.mesh = cm
	var cork_mat := StandardMaterial3D.new()
	cork_mat.albedo_color = Color(0.93, 0.93, 0.90, 1)
	cork_mat.roughness = 0.75
	cork.set_surface_override_material(0, cork_mat)
	root.add_child(cork)

	# 羽毛裙（圆锥台，白色）
	var skirt := MeshInstance3D.new()
	skirt.name = "Skirt"
	var sm := CylinderMesh.new()
	sm.top_radius = 0.031
	sm.bottom_radius = 0.0135
	sm.height = 0.052
	sm.radial_segments = 16
	skirt.mesh = sm
	skirt.position = Vector3(0, 0.039, 0)
	var sk_mat := StandardMaterial3D.new()
	sk_mat.albedo_color = Color(1.0, 1.0, 0.99, 1)
	sk_mat.roughness = 0.85
	skirt.set_surface_override_material(0, sk_mat)
	root.add_child(skirt)

	return root


# ───────────── 飞行 ─────────────
func launch(from: Vector3, vel: Vector3, floor_y: float = 0.0) -> void:
	global_position = from
	velocity = vel
	_floor_y = floor_y
	_flying = true
	visible = true


func stop() -> void:
	_flying = false
	velocity = Vector3.ZERO


func is_flying() -> bool:
	return _flying


func _physics_process(delta: float) -> void:
	if not _flying:
		return

	var acc := Vector3(0, -gravity, 0)
	if enable_drag:
		var sp := velocity.length()
		if sp > 0.0001:
			acc -= velocity.normalized() * drag_k * sp * sp

	velocity += acc * delta
	global_position += velocity * delta

	# 球头始终朝向运动方向（羽毛球飞行的经典姿态）
	if velocity.length() > 0.05:
		var look := global_position + velocity.normalized()
		if global_position.distance_to(look) > 0.0001:
			look_at(look, Vector3.UP)
		rotate_object_local(Vector3(1, 0, 0), deg_to_rad(-90))

	# 落地
	if global_position.y <= _floor_y:
		global_position.y = _floor_y
		_flying = false
		emit_signal("landed", global_position, true)


# ───────────── 弹道求解 ─────────────
## 模拟一次飞行，返回落点（不改变本球状态）
func simulate_landing(from: Vector3, vel: Vector3, floor_y: float = 0.0,
					 max_time: float = 8.0, dt: float = 1.0 / 60.0) -> Vector3:
	var p := from
	var v := vel
	var t := 0.0
	while t < max_time:
		var acc := Vector3(0, -gravity, 0)
		if enable_drag:
			var sp := v.length()
			if sp > 0.0001:
				acc -= v.normalized() * drag_k * sp * sp
		v += acc * dt
		p += v * dt
		t += dt
		if p.y <= floor_y:
			p.y = floor_y
			return p
	return p


## 模拟飞行，返回穿过 z = net_z 竖直平面时球的高度。
## 如果球没穿过该平面（比如提前落地）就返回 -1.0。
## 用途：回球时先算一遍，确保这一拍能过网。
func simulate_net_height(from: Vector3, vel: Vector3, net_z: float,
						floor_y: float = 0.0, max_time: float = 8.0,
						dt: float = 1.0 / 120.0) -> float:
	var p := from
	var v := vel
	var t := 0.0
	var prev_z := p.z
	while t < max_time:
		var acc := Vector3(0, -gravity, 0)
		if enable_drag:
			var sp := v.length()
			if sp > 0.0001:
				acc -= v.normalized() * drag_k * sp * sp
		v += acc * dt
		var np := p + v * dt
		t += dt

		# 符号变化 = 这一跨步穿过了 net_z 平面
		if (prev_z - net_z) * (np.z - net_z) <= 0.0 and absf(np.z - prev_z) > 1e-9:
			var f := (net_z - prev_z) / (np.z - prev_z)
			return lerpf(p.y, np.y, clampf(f, 0.0, 1.0))

		p = np
		prev_z = p.z
		if p.y <= floor_y:
			return -1.0
	return -1.0


## 求初速度：让球从 from 出发、经过 flight_time 秒后正好落在 target。
## 阻力让解析解变复杂，所以用「粗估 + 迭代修正」：
##   先按无阻力给个估计，模拟看落点偏差，把偏差补偿回初速度，迭代若干次。
func solve_velocity(from: Vector3, target: Vector3, flight_time: float,
				   floor_y: float = 0.0, iterations: int = 6) -> Vector3:
	# 初始猜测：位移/时间，再加一半重力补偿（阻力会让它衰减得快，后面迭代修正）
	var v := (target - from) / flight_time
	v.y += 0.5 * gravity * flight_time

	for _i in range(iterations):
		var land := simulate_landing(from, v, floor_y)
		var err := target - land
		err.y = 0.0
		if err.length() < 0.02:
			break
		v += err / flight_time

	return v
