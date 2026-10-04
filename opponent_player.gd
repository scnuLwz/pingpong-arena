extends Node3D
## 球台对侧的对手：**一把悬空的球拍**（人形可开关，当前默认关闭）。
##
## ── 为什么需要它 ──
## 加入本脚本之前，对手**完全没有 3D 实体**：pingpong_game._do_serve() 直接
## 从 (x, 1.02, -1.30) 凭空发射一个球，玩家抬头看过去是对面空无一人、
## 却一直有球飞过来 —— 而且对面连球拍都没有。
##
## ── 设计取舍 ──
## 1. **球拍用真实模型**（models/paddle_lite.glb）+ 与第一人称同一套
##    paddle_rubber.gdshader，两边外观一致；不再另调一套材质。
## 2. **默认不渲染人形**（show_figure = false）。理由：
##    · 玩家离对手 2.5 m，人形在屏幕上只占一小块 —— 建模成本全花在看不见的
##      细节上（头发那条黑带、躯干胶囊吞脖子，都是这么踩出来的）；
##    · 这条手臂是**刚性**的（没有骨骼），接球时靠整个身体挪位去找球，
##      步子稍跟不上，「手和拍脱节」比一把悬空拍更刺眼；
##    · 只留拍子时，玩家的注意力自然落在「拍面朝向 + 触球点」上，画面更干净。
##    人形的建模代码完整保留（`_build()` 里 show_figure 的分支 + `_limb/_hair`），
##    把开关打开就能回来。
## 3. **不做骨骼动画**：上骨架是过度设计。肢体用「点对点生成胶囊」+
##    旋转肩关节实现。
## 4. **站姿朝向**：根节点放在 z=-1.78（球台远边 -1.37 之外 0.41 m），
##    面朝 +Z（玩家）。球拍在发球时的拍面中心落在 z≈-1.30、
##    与 _do_serve() 的发射点重合 —— 球看起来是从拍面离开的。
## 5. **「不画人」≠「不要 ArmR 节点」**：球拍挂在 ArmR 下面、挥拍靠旋转
##    ArmR，所以这个枢轴必须在。Node3D 枢轴不可见、不占渲染开销 ——
##    不渲染的只是它的网格，不是它的变换。

# ───────────── 球拍模型（与 paddle_viewmodel 用同一份，保证两边一致）─────────────
const PADDLE_MODEL := preload("res://models/paddle_lite.glb")
const PADDLE_SHADER := preload("res://paddle_rubber.gdshader")
## 模型拍面直径 0.7043（模型单位）→ 真实 0.150 m
const MODEL_SCALE: float = 0.15 / 0.7043
## 模型空间里拍面中心（长轴 -Z 方向，离柄尾 0.770 模型单位）
const BLADE_CENTER_MODEL := Vector3(0.0, 0.0, -0.770)
## 柄尾 → 拍面中心的真实距离（米），用来把拍面摆到发球点上。
## 只能写成 var：GDScript 的常量表达式不允许 Vector3.length()，
## 写成 const 会在解析期直接报 "Assigned value for constant ... isn't a
## constant expression"，整个脚本挂不上场景（踩过一次）。
var _blade_offset: float = BLADE_CENTER_MODEL.length() * MODEL_SCALE

@export_group("开关")
@export var show_paddle: bool = true
## 是否渲染人形（躯干 / 头 / 头发 / 双臂 / 腿）。**默认关闭** —— 只留一把悬空球拍。
##
## 关掉时球拍的姿态、挥拍、迈步、击球音效**全部照常**，只是不画身体：
## 关节枢轴（ArmR）依旧存在，球拍照旧挂在它下面被转动。
## 打开可以拿回完整的「真人对手」（建模代码完整保留，见文件头说明）。
@export var show_figure: bool = false

@export_group("站位")
## 站在球台远边之后多少米。球台远边 z=-1.37
@export var stand_z: float = -1.78
@export var stand_x: float = 0.06

@export_group("体型")
@export var body_height_scale: float = 1.0

@export_group("持拍姿态")
## 拍面中心希望落在哪 —— **根节点坐标系**（不是肩关节坐标系）。
## z=0.48 是硬约定：站位 -1.78 + 0.48 = -1.30，正是 pingpong_game 的
## OPP_PADDLE_Z（发球发射点 + 对手回球的触球平面）。改这里要两边一起改。
##
## y 从 1.05 降到 1.00：这是回球能不能「看起来被拍子打到」的关键。
## 对手是接**弹起后的球**，实测球飞到 z=-1.30 时高度只有 ~1.0 m；
## 拍子静止位高 5 cm 就足以让 2.5 m 外的玩家看出「球没碰到拍子」。
## 顺带把肩到手拉长到 0.587 m —— 比 0.57 略长，仍在成年人手臂范围内。
@export var blade_target: Vector3 = Vector3(0.0, 1.00, 0.48)
## 拍头指向（局部）：朝下。
##
## 两个约束把这一项夹死了，不是随便挑的：
##   1. **法线要垂直于它**（见 blade_normal_dir）。两向量接近平行时，
##      _blade_basis() 的正交化会把法线投影成一条又短又随机的向量，
##      拍面就歪到看不见 —— 踩过：写成 (0.10, 0.40, 0.91)（斜前上）时，
##      正交化后法线变成 (−0.22, −0.88, 0.41)，几乎朝下，只能看到一条拍边。
##   2. **握把点要落在真人臂长上**。拍面中心被发球点钉在 y≈1.0，
##      若拍头朝上，柄尾就得低到 y=0.84，肩到手 0.70 m —— 太长了。
##      朝下时柄尾在 y=1.16，臂长 0.587 m，是成年人的前臂+上臂。
##      而且「手在柄尾、拍面垂在手下方」本来就是真人握拍的姿势。
@export var blade_tip_dir: Vector3 = Vector3(0.12, -0.99, 0.0)
## 拍面法线希望的朝向（局部）。
##
## 用根节点坐标写「希望拍面朝哪边」，_blade_basis() 会把它对 blade_tip_dir
## 做正交化。**必须是 (0,0,1)**：玩家站在 +Z 方向，拍面朝 +Z 才看得见拍面。
## 早先写成 (0,1,0)（朝上）时，拍面正好与玩家视线平行 ——
## 实测从玩家视角只能看到一条暗红色薄边，等于没渲染。
@export var blade_normal_dir: Vector3 = Vector3(0.0, 0.0, 1.0)

@export_group("挥拍")
## 绕肩关节 X 轴的**抬臂**幅度（度）。
##
## 从 36 降到 14 是被回球逼出来的：抬臂会把拍面沿一段圆弧甩上去，
## 36° 时拍面中心从 y=1.00 一路升到 y=1.37 —— 而球只有 y≈1.0，
## 于是「拍子在空中划过、球在下面 40 cm 处自己掉头」。
## 现在抬臂只占一小部分，横向扫（swing_yaw_degrees）才是主体，
## 拍面整段轨迹都贴在击球高度附近，看起来才像真把球抽回去。
@export var swing_degrees: float = 14.0
## 绕肩关节 Y 轴的**横向扫**幅度（度）。正手抽球的真实动作是横向为主。
@export var swing_yaw_degrees: float = 34.0
@export var swing_duration: float = 0.30
## 反手挥拍的横向幅度倍率。
##
## ★ 用户要「对手也有正反手切换」。真人的反手挥幅比正手小 ——
##   正手是从身体外侧抡过去，反手是被身体挡着、只能顶出去。
##   0.68 是看着调出来的：再小就像没挥，再大就看不出和反手的区别。
@export var backhand_swing_scale: float = 0.68
## 反手时手臂额外往内收的角度（度）。正手拍面朝外、反手拍面朝内，
##   差的就是这一下滚转 —— 没有它，正反手只是「往左扫 / 往右扫」，
##   远处看还是同一个动作。
@export var backhand_roll_degrees: float = 16.0

@export_group("待机")
## 极缓慢的重心起伏 —— 完全不动的对手看起来像一尊雕塑
@export var idle_degrees: float = 2.2
@export var idle_frequency: float = 0.9
## 悬空球拍的上下浮动幅度（米）。**只在 show_figure = false 时生效。**
##
## 一把完全静止的悬空球拍看起来像「卡在空中的贴图」；有身体时这点浮动会显得
## 人在飘，所以那会儿不给。1.2 cm 是试出来的：再大就像在飞，再小看不出在动。
@export var idle_float: float = 0.012

@export_group("接球迈步")
## 左右各能迈出去多少米。再大就会显得像在横着滑冰 ——
## 这个角色没有腿部动画，位移全靠「看起来像是跨了一步」蒙过去。
@export var step_limit_x: float = 0.60
## 前后能迈多少米。**这不是装饰**：球弹起后的弧线里，「高度 ~1.0 m」
## 和「z ≈ -1.30（球拍静止位所在的平面）」两个条件不可能同时满足 ——
##   · 落点靠底线时，球一弹起就已经越过了拍面平面，只能在 y≈0.78 的
##     低点仓促碰到（差 22 cm，一眼假）；
##   · 落点靠网时，球要飞很久才够到拍面，中途还会在台面二次弹跳。
## 所以对手必须自己挪到「球弹起后飞到 ≈1.0 m 高」的那个点上。
##
## ★★ 0.50 → 0.80（2026-10-03，用户报「很多近台球 AI 都接不到」）：
##   方向上 `step_limit_z_back` 其实管的是**朝球网**迈步
##   （dz = world_z − blade_target.z − stand_z，球拍越靠近网 dz 越大）。
##   0.50 时拍面最靠前只到 **z = -1.78 + 0.48 + 0.50 = -0.80**，
##   而贴网球落在 z ≈ -0.30：球要再飘 0.50 m 才够得到拍面，
##   途中还在台面上补 1~2 次弹跳 —— `opponent_return_timeout`(0.85 s)
##   先到，对手就「够不着」了。实测这一条正是短球必失的根因。
##   0.80 → 拍面最靠前 -0.50，落点 -0.30 的球只要飘 0.20 m 就能碰到，
##   一次额外弹跳都不需要。
##   ★ 本角色人形是关的（show_figure = false，场上只有一把悬空球拍），
##     所以「上前 0.8 m」在画面上不会变成「人站到球台里面」。
@export var step_limit_z_fwd: float = 0.26   # 往后退（远离球网）
@export var step_limit_z_back: float = 0.80  # 朝球网前迈（接近网短球）
## 迈步速度（米/秒）。人横向移动大约 2~3 m/s，给一点余量，
## 否则球落点变化快的时候会出现「拍子追不上球」的滞后感。
@export var step_speed: float = 5.0
## 回位速度（米/秒）—— 比迈步慢，收拍回中要显得从容
@export var step_return_speed: float = 1.5

@export_group("配色")
@export var jersey_color: Color = Color(0.085, 0.105, 0.185, 1.0)
## 袖子用浅色：深蓝挡板 + 蓝台面的背景里，深色躯干会糊成一片，
## 浅色袖子 + 肤色前臂能把「手臂在哪」勾出来
@export var sleeve_color: Color = Color(0.885, 0.895, 0.915, 1.0)
@export var skin_color: Color = Color(0.50, 0.365, 0.290, 1.0)
@export var shorts_color: Color = Color(0.10, 0.11, 0.135, 1.0)
@export var hair_color: Color = Color(0.075, 0.065, 0.070, 1.0)

var _arm_r: Node3D
var _arm_l: Node3D
var _torso_pivot: Node3D
var _swing_t: float = -1.0
## 当前握拍：0 = 正手 / 1 = 反手。见 set_grip()。
var _grip: int = 0
var _idle_phase: float = 0.0
## 握把点在肩关节局部空间里的位置（由 blade_target + blade_tip_dir 反推）
var _grip_local: Vector3 = Vector3.ZERO
## 横向 / 纵向迈步：当前偏移量、目标偏移量（都是相对 stand_x / stand_z 的）
var _step_x: float = 0.0
var _step_target_x: float = 0.0
var _step_z: float = 0.0
var _step_target_z: float = 0.0
## 当前是否在「去接球」的状态。回位用更慢的速度，去接球用更快的速度。
var _stepping: bool = false

# 肩关节局部坐标（体型的第一性数据，其余都从它推）
var _shoulder_r: Vector3 = Vector3.ZERO
var _shoulder_l: Vector3 = Vector3.ZERO


func _ready() -> void:
	position = Vector3(stand_x, 0.0, stand_z)
	_build()


func _build() -> void:
	var skin := _mat(skin_color, 0.72)
	var jersey := _mat(jersey_color, 0.78)
	var sleeve := _mat(sleeve_color, 0.72)
	var shorts := _mat(shorts_color, 0.80)
	var hair := _mat(hair_color, 0.85)

	# ── 髋以上：躯干 / 颈 / 头 ──
	# 用「局部 Y 轴 = 肢体方向」的胶囊拼，见 _limb()
	var hip := Vector3(0.0, 0.92, 0.0) * body_height_scale
	var neck := Vector3(0.0, 1.44, 0.0) * body_height_scale
	var head_c := Vector3(0.0, 1.60, 0.02) * body_height_scale

	if show_figure:
		_torso_pivot = Node3D.new()
		_torso_pivot.name = "Torso"
		add_child(_torso_pivot)
		# 躯干压扁成椭圆截面。半径给 0.17 而不是 0.185：
		# 胶囊的端部是半球，半径越大越会把脖子和头「吞」进去。
		_limb(_torso_pivot, hip, neck, 0.170 * body_height_scale, jersey, 1.10, 0.78)
		_limb(_torso_pivot, neck, head_c - Vector3(0, 0.06, 0), 0.058, skin)
		_sphere(_torso_pivot, head_c, 0.105 * body_height_scale, skin)
		# 头发：整球，往后上方偏一点，脸从前面露出来
		_hair(_torso_pivot, head_c, 0.115 * body_height_scale, hair)

		# ── 腿：本来会被球台挡住，但低头时能看见，不做会「穿帮」 ──
		for sx: float in [-1.0, 1.0]:
			_limb(_torso_pivot, Vector3(sx * 0.125, 0.94, 0.0) * body_height_scale,
				  Vector3(sx * 0.150, 0.38, 0.03) * body_height_scale, 0.088, shorts)
			_limb(_torso_pivot, Vector3(sx * 0.150, 0.40, 0.03) * body_height_scale,
				  Vector3(sx * 0.155, 0.04, 0.05) * body_height_scale, 0.062, skin)
			# 鞋
			_sphere(_torso_pivot, Vector3(sx * 0.155, 0.045, 0.09) * body_height_scale,
					0.072, _mat(Color(0.92, 0.92, 0.90, 1.0), 0.55))

	_shoulder_l = Vector3(-0.20, 1.40, 0.0) * body_height_scale
	_shoulder_r = Vector3(0.22, 1.40, 0.0) * body_height_scale

	# 握把点由「拍面中心 − 拍头方向 × 柄到拍面中心的距离」反推。
	# 让手去迁就拍子，而不是各自写死 —— 否则一改 blade_tip_dir，
	# 拍子就会飘到手外面（手在肩上、拍在别处）。
	_grip_local = (blade_target - _shoulder_r) - blade_tip_dir.normalized() * _blade_offset

	# ── 左臂（不持拍）：向前下方张开，像发球前托球的那只手 ──
	if show_figure:
		_arm_l = _arm("ArmL", _shoulder_l, Vector3(-0.12, -0.44, 0.24) * body_height_scale, skin, sleeve)

	# ── 右臂（持拍）：末端就是握把点 ──
	# 最后一个参数是「要不要真的画出手臂网格」。不渲染人形时只留空枢轴，
	# 球拍照样挂在它下面 —— 挥拍靠的就是转这个枢轴。
	_arm_r = _arm("ArmR", _shoulder_r, _grip_local, skin, sleeve, show_figure)

	if show_paddle:
		_build_paddle()


## 一条「上臂 + 前臂 + 手」的手臂，挂在肩关节枢轴上。
## 挥拍动画直接旋转这个枢轴，所以肢体只需在枢轴局部空间里摆一次。
## name 必须区分左右 —— 两只都叫 "Arm" 的话 Godot 会把后者改名成 "Arm2"，
## 之后按路径取节点就会取错手。
##
## with_body = false（不渲染人形）时**只建枢轴、不生成任何网格**。
## 枢轴是 Node3D，不可见也不进渲染队列，但球拍挂在它下面、挥拍靠转它，
## 所以不能省。顺便也不用再算肘点和手掌球。
func _arm(node_name: String, shoulder: Vector3, hand_local: Vector3,
		  skin: Material, sleeve: Material, with_body: bool = true) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = node_name
	pivot.position = shoulder
	add_child(pivot)

	if not with_body:
		return pivot

	# 肘：取肩→手的中点，再往外顶一点，做出自然的屈肘
	var elbow := hand_local * 0.5 + Vector3(0.045, 0.0, 0.0)
	_limb(pivot, Vector3.ZERO, elbow, 0.058, sleeve)
	_limb(pivot, elbow, hand_local, 0.050, skin)
	# 手（简化成一颗球，不做手指 —— 对手离玩家 2.5 m 开外，手指根本看不清）
	_sphere(pivot, hand_local + (hand_local - elbow).normalized() * 0.05, 0.062, skin)
	return pivot


func _build_paddle() -> void:
	var model: Node3D = PADDLE_MODEL.instantiate()
	model.name = "PaddleModel"
	model.scale = Vector3.ONE * MODEL_SCALE

	var holder := Node3D.new()
	holder.name = "Paddle"
	# 位置直接用反推出来的握把点（与右臂末端同一点），朝向用 _blade_basis()。
	# 这样拍面中心必然落在 blade_target 上，且拍子必然在手里。
	holder.transform = Transform3D(_blade_basis(), _grip_local)
	holder.add_child(model)
	_arm_r.add_child(holder)

	# 与第一人称同一套手写着色（模型自带的 AI 噪声贴图不要）
	var mat := ShaderMaterial.new()
	mat.shader = PADDLE_SHADER
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i: int in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, mat)


## 把模型长轴（柄 → 拍头，模型空间是 -Z）摆到 blade_tip_dir，
## 同时让拍面法线（模型空间是 +Y）尽量贴住 blade_normal_dir。
## 用正交化后的向量直接拼 Basis，而不是连着转两次欧拉角 ——
## 后者在法线与长轴接近平行时会退化成随机朝向。
func _blade_basis() -> Basis:
	var l := blade_tip_dir.normalized()
	var n := blade_normal_dir - l * blade_normal_dir.dot(l)
	if n.length_squared() < 1e-6:
		n = Vector3.UP.cross(l).normalized()
	n = n.normalized()
	# 右手系：local -Z = l，local +Y = n
	return Basis(l.cross(n), n, -l)


# ───────────── 肢体生成 ─────────────
## 在 parent 下生成一段胶囊：从 from 指到 to，语义是「这段肢体的走向」。
## 胶囊默认沿 Y，所以把枢轴的局部 -Y 对到方向向量上。
func _limb(parent: Node3D, from: Vector3, to: Vector3, radius: float,
			mat: Material, scale_x: float = 1.0, scale_z: float = 1.0) -> Node3D:
	var d := to - from
	var l := d.length()
	var pivot := Node3D.new()
	pivot.transform = Transform3D(_aim_y(d), from)
	parent.add_child(pivot)

	var mi := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = radius
	# CapsuleMesh.height 含两端半球，所以给 l 就正好从 from 跨到 to。
	# 原来给的是 l + 2r（想「包住」端点），结果每一段都两头各多出一个半球 ——
	# 躯干那段的顶部半球直接把脖子和头一起吞了，看起来像一颗球上贴了个人头。
	cap.height = maxf(l, radius * 2.05)
	cap.radial_segments = 14
	cap.rings = 4
	mi.mesh = cap
	mi.position = Vector3(0.0, -l * 0.5, 0.0)
	# 躯干压扁成椭圆截面（沿肢体自身的横轴缩放，不涉及长度方向）
	mi.scale = Vector3(scale_x, 1.0, scale_z)
	mi.set_surface_override_material(0, mat)
	pivot.add_child(mi)
	return pivot


func _sphere(parent: Node3D, at: Vector3, r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = r
	sp.height = r * 2.0
	sp.radial_segments = 16
	sp.rings = 10
	mi.mesh = sp
	mi.position = at
	mi.set_surface_override_material(0, mat)
	parent.add_child(mi)
	return mi


## 头发。
##
## 踩过的坑：一开始用 `is_hemisphere`（半球）盖头顶，结果半球那个**平底圆面**
## 的法线朝正下方，顶光打上去接近全黑 —— 从玩家视角看，额头位置横着一条
## 突兀的黑带，像戴了个黑箍。
##
## 改成「略大的整球 + 往后上方偏」：球心后移 0.020、**上移 0.040**、半径 0.115
## （头 0.105）。两个偏移量都不是随手写的 ——
##   · 上移不够（试过 0.010）→ 头发几乎完全躲到头后面，正面看是个光头。
##   · 上移 0.040 时，正面发际线落在头心上方 0.04（＝头高的 69% 处），
##     额头和脸完整露出，而头顶、后脑、上半侧脸都被包住。
##   · 整球没有平面，所以不会再有「黑带」。
func _hair(parent: Node3D, head_c: Vector3, r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = r
	sp.height = r * 2.0
	sp.radial_segments = 18
	sp.rings = 10
	mi.mesh = sp
	mi.position = head_c + Vector3(0.0, 0.040, -0.020)
	mi.set_surface_override_material(0, mat)
	parent.add_child(mi)
	return mi


func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


## 让局部 -Y 指向 dir 的正交基。
## 用叉积现拼而不是算欧拉角：肢体方向是任意的，逐轴算角度又长又容易搞错手性。
## 手性校验：x ⊥ y 且 z = x × y，此时 det = x·(y×z) = 1，是右手系。
static func _aim_y(dir: Vector3, up: Vector3 = Vector3.FORWARD) -> Basis:
	var y := -dir.normalized()
	var x := up.cross(y)
	if x.length_squared() < 1e-8:
		x = Vector3.RIGHT.cross(y)
	if x.length_squared() < 1e-8:
		x = Vector3.UP.cross(y)
	x = x.normalized()
	return Basis(x, y, x.cross(y))


# ───────────── 动作 ─────────────
## 握拍：0 = 正手 / 1 = 反手。和 pingpong_game 的 _grip_mode 同一套取值。
##
## ★ 为什么要有：原来对手只有**一种**挥拍，不管球到它左边还是右边，
##   动作都一模一样，2.5 m 外看过去就是「对面那把拍子在定时抽风」。
##   加了握拍之后，球到持拍手一侧是正手大扫、到身体另一侧是反手小顶，
##   一眼就能看出对手在「处理不同的球」。
##
## 由 pingpong_game._opponent_swing() 在击球前调用（按触球点相对身体判定）。
func set_grip(mode: int) -> void:
	_grip = clampi(mode, 0, 1)


func get_grip() -> int:
	return _grip


func grip_name() -> String:
	return "反手" if _grip == 1 else "正手"


## 发球 / 击球。由 pingpong_game._opponent_swing() 调用（先 set_grip 再挥）。
func trigger_swing() -> void:
	_swing_t = 0.0


func is_swinging() -> bool:
	return _swing_t >= 0.0


func _process(delta: float) -> void:
	if _arm_r == null:
		return

	_update_step(delta)

	_idle_phase += delta * idle_frequency
	var idle := sin(_idle_phase)

	var amt := 0.0
	var yaw := 0.0
	if _swing_t >= 0.0:
		_swing_t += delta
		var p := clampf(_swing_t / maxf(swing_duration, 0.001), 0.0, 1.0)
		# 与第一人称球拍同一套 MC 式缓动，两边挥拍「同一种节奏」
		var f := 1.0 - p
		f = 1.0 - f * f * f
		var e := sin(f * PI)
		amt = e * deg_to_rad(swing_degrees)
		yaw = e * deg_to_rad(swing_yaw_degrees)
		# 正手往外抡（负 yaw，和原来一致）；反手是**被身体挡着顶出去**，
		# 所以方向反过来、幅度按 backhand_swing_scale 收窄。
		if _grip == 1:
			yaw = -yaw * backhand_swing_scale
		if _swing_t >= swing_duration:
			_swing_t = -1.0

	# 绕肩关节的局部 X 轴前扫（-X 旋转 = 手往前上方走，正好从发球点扫过）
	_arm_r.rotation.x = -amt
	_arm_r.rotation.y = -yaw
	# 待机滚转。没有身体时幅度放大一点 ——
	# 有身体时这点抖动会被躯干和双臂吸收掉，只剩「重心在动」的暗示；
	# 只留一把球拍时，它得自己撑住「被一只看不见的手握着」的感觉。
	_arm_r.rotation.z = deg_to_rad(idle * idle_degrees) * (0.35 if not show_figure else 0.12)
	# 反手时手臂整体往内收 —— 正手拍面朝外、反手朝内，差的就是这一下滚转。
	# 乘上挥拍进度 e 是必要的：不乘的话「刚切到反手、还没挥」就已经歪着了，
	# 切握拍会变成一次凭空的抽动。
	if _grip == 1 and _swing_t >= 0.0:
		var p2 := clampf(_swing_t / maxf(swing_duration, 0.001), 0.0, 1.0)
		var f2 := 1.0 - p2
		f2 = 1.0 - f2 * f2 * f2
		_arm_r.rotation.z += deg_to_rad(backhand_roll_degrees) * sin(f2 * PI)

	# 悬空球拍额外加一点上下浮动。**有身体时绝不能加** —— 那会变成「人在飘」。
	# 只改 y：x/z 归迈步逻辑管（见 _update_step），互不干扰。
	if not show_figure:
		_arm_r.position.y = _shoulder_r.y + sin(_idle_phase * 0.62) * idle_float

	if _arm_l != null:
		_arm_l.rotation.x = deg_to_rad(idle * idle_degrees) * 0.55
	if _torso_pivot != null:
		_torso_pivot.position.y = sin(_idle_phase * 0.5) * 0.004


# ───────────── 迈步 ─────────────
## 朝某个世界坐标迈一步去接球。传「希望球拍落在哪」即可 ——
## 球拍在根节点局部空间里的 x 偏移是 0、z 偏移是 blade_target.z，
## 所以从目标反推根节点该挪到哪是一步减法，不需要解 IK。
func step_toward(world_x: float, world_z: float) -> void:
	_step_target_x = clampf(world_x - stand_x, -step_limit_x, step_limit_x)
	var dz := (world_z - blade_target.z) - stand_z
	_step_target_z = clampf(dz, -step_limit_z_fwd, step_limit_z_back)
	_stepping = true


## 回到站位。每一球开始（发球）时调一次，不然上一球的迈步会累积。
func reset_stance() -> void:
	_step_target_x = 0.0
	_step_target_z = 0.0
	_stepping = false


func _update_step(delta: float) -> void:
	var speed := step_speed if _stepping else step_return_speed
	_step_x = move_toward(_step_x, _step_target_x, speed * delta)
	_step_z = move_toward(_step_z, _step_target_z, speed * delta)
	position = Vector3(stand_x + _step_x, position.y, stand_z + _step_z)


## 球拍当前所在的 z 平面（世界坐标）。
## pingpong_game 用它判断「球有没有飞到拍子上」，所以必须是把根节点位移
## 也算进去的实时值，不能写成常量。
func paddle_plane_z() -> float:
	return global_position.z + blade_target.z


## 当前横向 / 纵向偏移（自测用）
func step_offset() -> Vector2:
	return Vector2(_step_x, _step_z)


# ───────────── 对外查询（自测用）─────────────
## 拍面中心的世界坐标（应与 _do_serve() 的发射点大致重合）
func blade_position() -> Vector3:
	var holder := get_node_or_null("ArmR/Paddle") as Node3D
	if holder == null:
		return global_position
	var local_blade := BLADE_CENTER_MODEL * MODEL_SCALE
	return holder.to_global(local_blade)


func arm_swing_degrees() -> float:
	if _arm_r == null:
		return 0.0
	return rad_to_deg(_arm_r.rotation.x)
