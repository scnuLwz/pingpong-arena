class_name FpHand
extends RefCounted
## 第一人称「真手」程序化建模 (Godot 4.x, GDScript)
##
## 全部用**连续放样曲面**（一条中心线 + 变化的椭圆截面），不是拼椭球/圆锥，
## 所以不会出现「一团一团的疙瘩」。手掌/四指/拇指/腕/前臂都是整面。
##
## 坐标约定（与 paddle_viewmodel / racket_viewmodel 一致）：
##   局部 -Z = 拍头方向（远离手）   +Z = 肘方向
##   手柄轴 = Z 轴（x≈0, y≈0），掌在柄的 -X 侧
##   掌面法线 ≈ +Z（朝相机）→ 相机看到的是整块手背，而不是掌的一条侧棱
##   掌宽方向 = +X（屏幕左右）
##
## ★ 握法（关键）：手指必须在**垂直于手柄轴的平面**内绕柄一圈。
##   早先版本手指的弯曲平面里包含了手柄轴（等于让手指顺着柄躺下去），
##   所以看起来不是「握住」，而是一把指头插在柄旁边。现在：
##     四指 → 各自在 z 恒定的 XY 平面内，从掌侧绕过手柄下方（-Y）到对侧（+X）；
##     沿手柄轴 Z 排列（食指最靠拍头，间距≈真人 19mm）；
##     拇指 → 从大鱼际越过手柄上方（+Y），指尖压到食指根部；
##     掌背外侧沿手柄方向排 4 个指关节凸包，跟四指一一对齐。
##
## 用法：
##   var h := FpHand.new()
##   h.handle_half_x = 0.0165  # 乒乓球拍柄半宽
##   h.handle_half_y = 0.0145  # 半厚
##   h.knuckle_z0 = -0.070     # 食指掌指关节 z
##   h.palm_offset_x = -(h.handle_half_x + h.palm_semi.y)
##   var node := h.build()
##   paddle_root.add_child(node)
##
## 换羽毛球拍（柄更细更长）：
##   h.handle_half_x = 0.013; h.handle_half_y = 0.013
##   h.knuckle_z0 = -0.085; h.knuckle_dz = 0.021

## 径向分段。手离相机只有 0.3 m，14 段时掌缘会出现肉眼可见的多边形棱面
## （实测在 1246px 宽的截图里，一段弦长约 22px，折角很清楚），所以提到 24。
const SEG := 24        # 手掌径向分段
const FINGER_SEG := 18 # 手指径向分段（手指更细，18 段已足够）
const SAMPLES := 15    # 沿中心线重采样点数
const CAP_RINGS := 3   # 端部半球盖的环数

const FINGER_NAMES := ["Index", "Middle", "Ring", "Pinky"]
## 各指粗细系数（食指略粗 → 小指渐细）
const FINGER_THICK := [1.00, 1.02, 0.97, 0.88]
## 手指绕柄的起止角（度）。0° = +X，180° = -X（掌侧），270° = -Y（手柄下方）
## 196° → 352°：从掌侧下方绕手柄底、再翻上到远侧。
## 止角从 352° 拉到 362° 让指尖越过 +X 面，从相机这边能看见指腹而不是「四个根疙瘩」。
const WRAP_TH0 := 196.0
const WRAP_TH1 := 362.0

# ── 外观 ──────────────────────────────────────────────────
## 皮肤反照率。真人皮肤漫反射只有 0.5~0.65（蓝通道更低），
## 取 0.85 在本场景光照下会直接过曝成死白。
var skin_color: Color = Color(0.50, 0.38, 0.315, 1.0)
var nail_color: Color = Color(0.86, 0.72, 0.66, 1.0)

# ── 尺寸 ──────────────────────────────────────────────────
## 手柄半宽（X）与半厚（Y）。手指中心线的绕行椭圆 = 手柄半轴 + 手指半径。
var handle_half_x: float = 0.018
var handle_half_y: float = 0.014
## 食指掌指关节的 z（越负越靠近拍头）；掌的远端边界也落在这里
var knuckle_z0: float = -0.070
## 相邻两指沿手柄轴（Z）的间距，真人约 19mm
var knuckle_dz: float = 0.019
## 掌半轴（x 厚 / y 宽 / z）。厚度特意给到 0.018（真人约 0.014）：
## 掌面法线 ≈ ±X，而相机大致沿 -Z 看过来，掌面在屏幕上几乎是「侧着」的；
## 厚一点才不会退化成一条暗棱，形状上仍是一块有厚度的掌，不是一根圆木。
var palm_semi: Vector3 = Vector3(0.0180, 0.0340, 0.0500)
## 可见的前臂长度。0.085 时整只手在画面里像一根长原木（掌+前臂 21cm），
## 而球拍本身才 25cm —— 比例上完全被前臂抢戏。压到 0.042 后，
## 掌是掌、腕是腕，前臂很快出画。
var forearm_length: float = 0.042
var show_forearm: bool = true
var show_nails: bool = true
## 掌的横向偏移：掌轴离手柄轴的距离。厚度轴是 RIGHT，
## 所以 |palm_offset_x| = 手柄半宽 + 掌半厚（0.0165 + 0.0180 = 0.0345），
## 掌的 +X 面才正好贴住柄的 -X 面。
var palm_offset_x: float = -0.0345

var _skin: StandardMaterial3D
var _nail: StandardMaterial3D
var _root: Node3D

# 掌的骨架（由上面的参数推出）
var _wrist: Vector3 = Vector3(-0.0345, 0.004, 0.024)
var _palm_axis: Vector3 = Vector3(0.0, -0.165, -1.0).normalized()   # 腕 → 掌指关节
var _palm_normal: Vector3 = Vector3.RIGHT                            # 厚度方向（掌背朝 -X）
var _palm_width_dir: Vector3 = Vector3.ZERO                          # 掌宽方向（≈ +Y）
var _palm_len: float = 0.097
var _knee: Vector3 = Vector3.ZERO                                   # 掌指关节线中点


## 生成整只手，返回根节点（直接 add_child 到拍子节点即可）
func build() -> Node3D:
	_skin = _make_skin()
	_nail = _make_nail()
	_compute_frame()

	_root = Node3D.new()
	_root.name = "Hand"

	_build_palm(_root)
	_build_knuckles(_root)
	_build_fingers(_root)
	_build_thumb(_root)
	# 前臂没有独立节点：它已经作为掌放样的前几段一起生成了（见 _build_palm 的 show_forearm 分支），
	# 这样腕 → 掌 → 前臂是一条连续曲面，不会出现接缝。
	return _root


## 先算出掌的骨架：腕点、掌轴、掌宽方向、掌长
func _compute_frame() -> void:
	# 腕点：掌轴离手柄轴 palm_offset_x（掌贴在柄的 -X 侧）
	_wrist = Vector3(palm_offset_x, 0.004, 0.024)
	_palm_axis = Vector3(0.0, -0.165, -1.0).normalized()
	# 掌宽方向：垂直于掌轴、且尽量朝 +Y
	_palm_width_dir = (Vector3.UP - _palm_axis * Vector3.UP.dot(_palm_axis)).normalized()
	_palm_normal = Vector3.RIGHT
	# 掌的远端边界刚好落在食指掌指关节上 → 反推掌长，四指从掌的远端横排长出
	_palm_len = clampf((_wrist.z - knuckle_z0) / -_palm_axis.z, 0.055, 0.15)
	_knee = _wrist + _palm_axis * _palm_len


## 掌（含前臂）的截面表：[沿掌轴距离 s, 厚度半轴 rx, 宽度半轴 ry]。
## 抽出来给放样和「掌背指关节」共用，免得两处各写一套比例、对不上。
func _palm_profile() -> Array:
	var rx: float = palm_semi.x
	var ry: float = palm_semi.y
	var out: Array = []
	if show_forearm:
		# 前臂必须是「扁」的：厚度(rx) 明显小于宽度(ry)。
		# 早期版本给的是 rx*1.62 / ry*0.74 —— 厚度 58mm、宽度 50mm，
		# 比宽还厚，在第一人称里就变成一根正圆柱「软管」。
		# 真人前臂靠腕处约 37×53mm、靠肘约 47×63mm，这里照这个比例来。
		out.append([-forearm_length, rx * 1.30, ry * 0.92])          # 肘侧（最近相机）
		out.append([-forearm_length * 0.62, rx * 1.18, ry * 0.86])
		out.append([-forearm_length * 0.30, rx * 1.02, ry * 0.78])
	out.append([-0.019, rx * 0.92, ry * 0.70])            # 腕（收窄，做出腕褶）
	out.append([0.000, rx * 1.06, ry * 0.76])
	out.append([_palm_len * 0.24, rx * 1.02, ry * 0.84])
	out.append([_palm_len * 0.52, rx * 0.99, ry * 0.93])
	out.append([_palm_len * 0.78, rx * 0.97, ry * 0.99])
	out.append([_palm_len * 1.02, rx * 0.95, ry * 1.00])   # 掌指关节线
	return out


## 某处沿掌轴的厚度半轴 rx（线性插值掌截面表）
func _palm_rx_at(s: float) -> float:
	var prof: Array = _palm_profile()
	if s <= prof[0][0]:
		return prof[0][1]
	for k in prof.size() - 1:
		var a: Array = prof[k]
		var b: Array = prof[k + 1]
		if s <= b[0]:
			var t: float = (s - a[0]) / maxf(b[0] - a[0], 1e-6)
			return lerpf(a[1], b[1], t)
	return prof[prof.size() - 1][1]


# ══════════════════ 手掌 + 腕 + 前臂（一条连续放样）══════════════════
func _build_palm(parent: Node3D) -> void:
	var secs: Array = []
	# s = 沿掌轴距离（负 = 肘侧）
	for row in _palm_profile():
		secs.append(_sec(_wrist, row[0], row[1], row[2]))
	var mi := MeshInstance3D.new()
	mi.name = "Palm"
	mi.mesh = _loft(secs, SEG, 2.0, true, true)
	mi.set_surface_override_material(0, _skin)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## 造一个截面：位置 = 腕点沿掌轴走 s。
## side = ±X（掌的厚度方向，掌背法线），up = 掌宽方向。
## up 必须与掌轴垂直，所以取「垂直于掌轴、且尽量朝 +Y」的方向，不能直接用世界 Z
## —— 掌轴本身就近似 -Z，那样截面会退化成一条线。
func _sec(origin: Vector3, s: float, rx: float, ry: float) -> Dictionary:
	return {
		"pos": origin + _palm_axis * s,
		"side": Vector3.RIGHT,
		"up": _palm_width_dir,
		"rx": rx,
		"ry": ry,
	}


# ══════════════════ 掌背指关节起伏 ══════════════════
## 掌背（-X 侧）沿手柄方向排 4 个低矮凸包。掌背是一块大平面的时候，
## 第一人称视角里它只会读成「一根圆木」；有了这排起伏才有「手背」的读数。
## 凸包位置与四指一一对应（同一 z），这样手掌与手指在视觉上是连着的。
func _build_knuckles(parent: Node3D) -> void:
	for i in FINGER_NAMES.size():
		var z_i: float = knuckle_z0 + float(i) * knuckle_dz
		var s_i: float = (_wrist.z - z_i) / -_palm_axis.z
		var c_i: Vector3 = _wrist + _palm_axis * s_i
		# 凸包中心压在掌面上（半径的一半露在外面），而不是埋进掌里
		var rx_i: float = _palm_rx_at(s_i)
		var mi := MeshInstance3D.new()
		mi.name = "Knuckle" + FINGER_NAMES[i]
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sm.radial_segments = 14
		sm.rings = 8
		mi.mesh = sm
		# 局部轴：x → 手柄轴(Z)，y → +Y，z → 掌背(-X)
		var e1 := Vector3.BACK
		var e3 := Vector3.LEFT
		var e2 := e3.cross(e1)
		mi.transform = Transform3D(Basis(e1, e2, e3), c_i + e3 * (rx_i - 0.0022))
		mi.scale = Vector3(0.0135, 0.0150, 0.0110)
		mi.set_surface_override_material(0, _skin)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)


# ══════════════════ 四指 ══════════════════
func _build_fingers(parent: Node3D) -> void:
	for i in FINGER_NAMES.size():
		_build_finger(parent, FINGER_NAMES[i], i)


## 一根手指：在 z 恒定的水平面（垂直于手柄轴）里，从掌侧绕手柄下方到对侧。
func _build_finger(parent: Node3D, fname: String, idx: int) -> void:
	var z0: float = knuckle_z0 + float(idx) * knuckle_dz
	var thick: float = FINGER_THICK[idx]
	# 指根/指尖半径：原来 9.9mm/7.2mm 在画面里只剩「小疙瘩」，
	# 加粗到 11.0/8.0 才有「指头」的存在感（真人近节指约 10~11mm 半径）
	var r0: float = 0.0110 * thick
	var r1: float = 0.0080 * thick
	# 绕行椭圆：手柄半轴 + 手指半径；指尖略收，压向柄面
	var a0: float = handle_half_x + r0
	var b0: float = handle_half_y + r0
	var a1: float = handle_half_x + r1 * 0.70
	var b1: float = handle_half_y + r1 * 0.70
	var th0: float = deg_to_rad(WRAP_TH0)
	var th1: float = deg_to_rad(WRAP_TH1)

	var pts: Array = []
	var radii: Array = []
	for s in SAMPLES:
		var t: float = float(s) / float(SAMPLES - 1)
		var th: float = lerp(th0, th1, t)
		var grow: float = smoothstep(0.0, 1.0, t)
		pts.append(Vector3(
			lerp(a0, a1, grow) * cos(th),
			lerp(b0, b1, grow) * sin(th),
			z0))
		radii.append(lerp(r0, r1, t))

	# up0 取 ±Z：弯曲平面就是 XY，所以截面朝向全程稳定，不会翻面
	var secs: Array = _sections_from_path(pts, radii, 2.0, Vector3.BACK)
	var f := Node3D.new()
	f.name = "Finger" + fname
	parent.add_child(f)

	var mi := MeshInstance3D.new()
	mi.name = fname
	mi.mesh = _loft(secs, FINGER_SEG, 2.0, true, true)
	mi.set_surface_override_material(0, _skin)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	f.add_child(mi)

	if show_nails:
		_build_nail(f, fname, pts, radii)


## 指甲：贴在远节指背（= 背离手柄轴的径向外侧）
func _build_nail(parent: Node3D, fname: String, pts: Array, radii: Array) -> void:
	var n: int = pts.size()
	var a: Vector3 = pts[n - 3]
	var b: Vector3 = pts[n - 1]
	var d: Vector3 = b - a
	if d.length() < 1e-5:
		return
	var axis: Vector3 = d.normalized()
	var dorsal := _radial_out(b, axis)
	var side := axis.cross(dorsal).normalized()

	var mi := MeshInstance3D.new()
	mi.name = fname + "Nail"
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 12
	sm.rings = 7
	mi.mesh = sm
	var base := (a + b) * 0.5
	mi.transform = Transform3D(Basis(side, dorsal, axis), base + dorsal * radii[n - 1] * 0.72)
	mi.scale = Vector3(0.0092, 0.0044, 0.0148)
	mi.set_surface_override_material(0, _nail)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


## 背离手柄轴（局部 Z 轴）的径向方向，再投影到垂直于切线 → 用于定位指甲
func _radial_out(p: Vector3, axis: Vector3) -> Vector3:
	var radial := Vector3(p.x, p.y, 0.0)
	if radial.length_squared() < 1e-8:
		radial = Vector3.RIGHT
	radial = radial.normalized()
	var dorsal := radial - axis * radial.dot(axis)
	if dorsal.length_squared() < 1e-8:
		dorsal = radial
	return dorsal.normalized()


# ══════════════════ 拇指 ══════════════════
## 拇指自大鱼际（掌的 +Y 缘靠腕）出发，越过手柄上方（+Y），
## 指尖顶到食指根部 —— 与四指从下方绕上来正好合成一个闭环。
func _build_thumb(parent: Node3D) -> void:
	var spread: float = clampf((handle_half_x - 0.018) / 0.006, 0.0, 1.0)
	var pts: Array = [
		Vector3(-0.0300, 0.0220, 0.0180),                      # 腕掌关节（大鱼际，掌的桡侧角）
		Vector3(-0.0220, 0.0270, 0.0060),                      # 掌指关节，开始越过手柄
		Vector3(-0.0010, 0.0290, -0.0110),
		Vector3(0.0130, 0.0225, -0.0270),
		Vector3(0.0220 + 0.003 * spread, 0.0115, -0.0420),     # 指尖，压在柄的 +X 面
	]
	var radii: Array = [0.0132, 0.0122, 0.0112, 0.0102, 0.0092]

	var th := Node3D.new()
	th.name = "Thumb"
	parent.add_child(th)

	var secs: Array = _sections_from_path(pts, radii, 2.0, Vector3.BACK)
	var mi := MeshInstance3D.new()
	mi.name = "Thumb"
	mi.mesh = _loft(secs, FINGER_SEG, 2.0, true, true)
	mi.set_surface_override_material(0, _skin)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	th.add_child(mi)

	if show_nails:
		_build_thumb_nail(th, pts, radii)


func _build_thumb_nail(parent: Node3D, pts: Array, radii: Array) -> void:
	var a: Vector3 = pts[3]
	var b: Vector3 = pts[4]
	var axis: Vector3 = (b - a).normalized()
	var dorsal := _radial_out(b, axis)
	var side := axis.cross(dorsal).normalized()

	var mi := MeshInstance3D.new()
	mi.name = "ThumbNail"
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	sm.radial_segments = 12
	sm.rings = 7
	mi.mesh = sm
	mi.transform = Transform3D(Basis(side, dorsal, axis),
			(a + b) * 0.5 + dorsal * radii[4] * 0.72)
	mi.scale = Vector3(0.0105, 0.0046, 0.0150)
	mi.set_surface_override_material(0, _nail)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


# ══════════════════ 中心线 → 截面 ══════════════════
## 把一条中心线（控制点 + 半径）重采样成放样截面，用平行传输算截面朝向，
## 这样手指弯曲时截面不会突然翻面。
func _sections_from_path(pts: Array, radii: Array, shape: float, up0: Vector3) -> Array:
	var curve: Array = _resample(pts, SAMPLES)
	var rs: Array = _resample_f(radii, SAMPLES)
	var out: Array = []
	var up: Vector3 = up0
	for i in curve.size():
		var tan: Vector3
		if i == 0:
			tan = (curve[1] - curve[0]).normalized()
		elif i == curve.size() - 1:
			tan = (curve[i] - curve[i - 1]).normalized()
		else:
			tan = (curve[i + 1] - curve[i - 1]).normalized()
		up = up - tan * up.dot(tan)
		if up.length_squared() < 1e-8:
			var alt: Vector3 = Vector3.RIGHT if absf(tan.dot(Vector3.RIGHT)) < 0.9 else Vector3.UP
			up = alt - tan * alt.dot(tan)
		up = up.normalized()
		out.append({
			"pos": curve[i],
			"side": up.cross(tan).normalized(),
			"up": up,
			"rx": rs[i],
			"ry": rs[i],
			"exp": shape,
		})
	return out


func _resample(pts: Array, n: int) -> Array:
	var p: Array = [pts[0]]
	p.append_array(pts)
	p.append(pts[pts.size() - 1])
	var segs: int = pts.size() - 1
	var out: Array = []
	for k in n:
		var f: float = (float(k) / float(n - 1)) * float(segs)
		var i: int = clampi(int(floor(f)), 0, segs - 1)
		out.append(_catmull(p[i], p[i + 1], p[i + 2], p[i + 3], f - float(i)))
	return out


func _resample_f(vals: Array, n: int) -> Array:
	var segs: int = vals.size() - 1
	var out: Array = []
	for k in n:
		var f: float = (float(k) / float(n - 1)) * float(segs)
		var i: int = clampi(int(floor(f)), 0, segs - 1)
		out.append(lerpf(vals[i], vals[i + 1], f - float(i)))
	return out


func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((p1 * 2.0) + (p2 - p0) * t
			+ (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
			+ (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3)


# ══════════════════ 放样曲面 ══════════════════
## 一串截面 → 一张连续曲面（三角形汤，法线按「截面中心 → 顶点」算，一定是外法线）。
## 截面超出 z 的端部自动补半球盖。
func _loft(secs: Array, seg: int, shape: float, cap_a: bool, cap_b: bool) -> ArrayMesh:
	# 必须先把 exp 写进所有截面：_cap_rings 会读它，而端盖的环要排在正文之前
	for s in secs:
		s["exp"] = shape
	var rings: Array = []
	if cap_a and secs.size() >= 2:
		rings.append_array(_cap_rings(secs[0], (secs[0]["pos"] - secs[1]["pos"]).normalized(), 1.0))
	for s in secs:
		rings.append(s)
	if cap_b and secs.size() >= 2:
		var sn: Dictionary = secs[secs.size() - 1]
		var sp: Dictionary = secs[secs.size() - 2]
		rings.append_array(_cap_rings(sn, (sn["pos"] - sp["pos"]).normalized(), -1.0))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uv_row := 0.0
	for r in rings.size() - 1:
		var a: Dictionary = rings[r]
		var b: Dictionary = rings[r + 1]
		for j in seg:
			var a0: Vector3 = _ring_pt(a, j, seg)
			var a1: Vector3 = _ring_pt(a, j + 1, seg)
			var b0: Vector3 = _ring_pt(b, j, seg)
			var b1: Vector3 = _ring_pt(b, j + 1, seg)
			_tri(st, a0, a1, b1, a["pos"], uv_row, j, seg)
			_tri(st, a0, b1, b0, a["pos"], uv_row, j, seg)
		uv_row += 1.0
	return st.commit()


## 半球盖：沿轴向外侧补 CAP_RINGS 环，半径按 cos 收缩
func _cap_rings(sec: Dictionary, tan: Vector3, dir: float) -> Array:
	var out: Array = []
	var rmax: float = maxf(sec["rx"], sec["ry"])
	for k in range(CAP_RINGS, 0, -1):
		var phi: float = (float(k) / float(CAP_RINGS)) * PI * 0.5
		var sc: float = cos(phi)
		out.append({
			"pos": sec["pos"] + tan * (dir * sin(phi) * rmax),
			"side": sec["side"],
			"up": sec["up"],
			"rx": sec["rx"] * sc,
			"ry": sec["ry"] * sc,
			"exp": sec.get("exp", 2.0),
		})
	if dir < 0.0:
		out.reverse()
	return out


## 截面上的第 j 个点（超椭圆，exp 越大越方）
func _ring_pt(sec: Dictionary, j: int, seg: int) -> Vector3:
	var a: float = TAU * float(j) / float(seg)
	var e: float = maxf(sec["exp"], 2.0)
	var c: float = cos(a)
	var s: float = sin(a)
	var cx: float = signf(c) * pow(absf(c), 2.0 / e)
	var sy: float = signf(s) * pow(absf(s), 2.0 / e)
	return sec["pos"] + sec["side"] * (cx * sec["rx"]) + sec["up"] * (sy * sec["ry"])


func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3,
		center: Vector3, row: float, col: int, seg: int) -> void:
	var u0 := float(col) / float(seg)
	var u1 := float(col + 1) / float(seg)
	var pts := [p0, p1, p2]
	var uvs := [u0, u1, u1]
	for i in 3:
		var n: Vector3 = pts[i] - center
		if n.length_squared() < 1e-10:
			n = Vector3.UP
		st.set_normal(n.normalized())
		st.set_uv(Vector2(uvs[i], row * 0.08))
		st.add_vertex(pts[i])


# ══════════════════ 材质 ══════════════════
func _make_skin() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = skin_color
	m.roughness = 0.62
	m.metallic = 0.0
	# 一点点自发光当作「环境光下限」：只靠补光灯时朝向灯的一面容易过曝、
	# 背光面发黑，同一只手上一半死白一半近黑。给个发光底之后动态范围收窄。
	# 注意：这个值是在**旧场景（室外亮天空）**下定的。改成室内场馆后整体亮度降下来，
	# 0.58 反而会把手顶成发白的「塑料管」，所以回到 0.30。
	m.emission_enabled = true
	m.emission = skin_color
	m.emission_energy_multiplier = 0.30
	# 放样曲面的绕序在端部下收处不好保证，直接关背面剔除，法线我们自己算
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _make_nail() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = nail_color
	m.roughness = 0.28
	m.metallic = 0.0
	m.emission_enabled = true
	m.emission = nail_color
	m.emission_energy_multiplier = 0.24
	return m
