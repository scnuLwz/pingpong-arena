extends Node3D
## 乒乓球赛场生成器 —— 把「开放平面」变成**有限空间的室内场馆**
##
## 挂载位置：pingpong.tscn 的 Court (Node3D)
##
## 为什么用代码生成而不是全写在 .tscn 里：
##   看台 6 排 × 2 侧 + 300 多个观众，手写 tscn 会变成几千行、改一个参数要改几十处。
##   代码生成可以参数化（排数、间距、颜色都 export），也方便离屏迭代。
##
## 生成内容（全部无外部素材依赖）：
##   1. 地胶地板（带碰撞，玩家站在这上面）
##   2. 场地边线（白线）
##   3. 四周深色挡板（围出「有限空间」的视觉边界）
##   4. 左右两侧阶梯看台
##   5. 观众（单个 MultiMeshInstance3D，一次 draw call）
##   6. 两端背景墙 + 广告色带
##   7. 天花板（**关闭投影**，否则会在地板上投下一大片黑影）
##   8. 顶棚灯
##
## 坐标约定与球台一致：球网在 z = 0，玩家侧 z > 0。

@export_group("场地")
## 地胶半宽（X 方向）与半长（Z 方向）
@export var floor_half_x: float = 7.0
@export var floor_half_z: float = 8.0
## 地胶颜色：标准赛场的**红色地胶**。
## 一开始设的是深蓝，结果地胶、球台台面、挡板三者全是蓝，
## 画面糊成一片、完全没有层次；红地胶 + 蓝台面是乒乓球赛场最经典的对比。
@export var court_color: Color = Color(0.155, 0.030, 0.042)
@export var line_color: Color = Color(0.93, 0.95, 0.97)
## 地胶外面那圈「场馆外圈地面」的颜色。之前写死成深灰，现在跟着主题走
@export var apron_color: Color = Color(0.09, 0.095, 0.11)

@export_group("挡板")
@export var barrier_height: float = 1.05
@export var barrier_color: Color = Color(0.085, 0.145, 0.375)
@export var barrier_top_color: Color = Color(0.90, 0.92, 0.96)
## 挡板相对地胶边缘内缩
@export var barrier_inset: float = 0.40

@export_group("看台")
@export var stand_rows: int = 6
@export var stand_row_h: float = 0.46
@export var stand_row_d: float = 0.95
## 看台起点离地胶边缘的距离
@export var stand_gap: float = 1.20
@export var stand_color: Color = Color(0.165, 0.175, 0.215)

@export_group("看台 · 结构件")
## ★ 第四期新增。原来看台只有实心阶梯方块，远看就是一条斜坡。
##   这三个开关控制「结构件」层（座椅 / 排间扶手 / 通道）——
##   全部是几何体、和颜色无关，是让画面从「斜坡」变成「看台」的关键。
@export var stand_seats_enabled: bool = true
## 座椅间距（沿 Z）。0.52 是密集看台的实测值，再密就糊成一片了。
@export var seat_pitch: float = 0.52
## 座椅配色（MultiMesh 实例色）。真实球馆看台是多彩的，
## 单一颜色会像「家具样品展示」。都取低饱和 —— 高饱和在远处会互相干扰成噪点。
@export var seat_colors: Array[Color] = [
	Color(0.520, 0.075, 0.090), Color(0.610, 0.230, 0.055),
	Color(0.640, 0.510, 0.075), Color(0.090, 0.290, 0.420),
	Color(0.110, 0.400, 0.240), Color(0.300, 0.130, 0.400),
]
@export var stand_rails_enabled: bool = true
## 纵向通道宽度（沿 Z）。看台在中线和两端各留一条上楼梯。
@export var stand_lane_w: float = 1.10
## 看台上方的环廊 / 包厢。室内馆看台顶排到天花板之间最容易空出一大块
## （原来整片背景色），补一层上层结构把那段填掉。
@export var upper_deck_enabled: bool = true
## 上层廊板相对地板的高度（看台顶排之上）
@export var upper_deck_y: float = 4.20
## 上层玻璃栏板颜色（半透）—— 拦一道，能把「空」变成「纵深」
@export var upper_glass_color: Color = Color(0.42, 0.58, 0.68, 0.30)

@export_group("观众")
@export var crowd_enabled: bool = true
## 同排观众间距
@export var crowd_spacing: float = 0.82
## 空座比例（随机留些空位，比坐满更像真赛场）
@export var crowd_empty_ratio: float = 0.22
## 观众整体缩放。参考模型本身只有 1.089 m 高（约 0.64 倍真人），
## 乘 1.35 之后 ≈ 1.47 m，再叠每实例 0.88~1.10 的随机，看着才像成年人。
@export var crowd_scale: float = 1.35
@export var crowd_seed: int = 20260929
## ★ 第三期：应援色辉光强度。0 = 关掉（看台维持模型本身的暗色）。
##   调太大会把 208 个观众糊成一片发光块，0.3 上下刚好是「远看一片灯海」。
@export var crowd_support_energy: float = 0.35
## 观众用的 GLB 模型。原始扫描文件是 71.8 MB / 150 万面，
## 已离线减到 157 KB / 4001 面（脚本：%TEMP%/cs1_tools/spectator/decimate_spectator.py）。
## 加载失败会自动退回代码生成的胶囊，不会让场馆构建中断。
const SPECTATOR_GLB := "res://models/spectator.glb"

@export_group("空间")
@export var ceiling_height: float = 7.0
@export var ceiling_color: Color = Color(0.235, 0.250, 0.290)
@export var end_wall_height: float = 4.4
@export var end_wall_color: Color = Color(0.115, 0.130, 0.170)
@export var ad_band_color: Color = Color(0.44, 0.075, 0.090)

@export_group("顶棚桁架")
## ★ 第四期新增。原来的顶面是「一整块平板 + 5 根横梁」，远看就是个仓库屋顶。
##   改成真桁架（上下弦 + 之字腹杆 + 连系梁）后，顶面才有「空间」的读法。
@export var ceiling_truss_enabled: bool = true
@export var truss_color: Color = Color(0.235, 0.245, 0.265)
## 桁架上下弦之间的桁高。0.55 上下看得出是桁架，太浅就退化成一根线。
@export var truss_depth: float = 0.62
## 下弦挂一圈灯带（室内球馆都有跑马灯）
@export var truss_lightstrip_enabled: bool = true

@export_group("端墙")
## ★ 第四期新增：端墙挂一块大屏记分牌。原先端墙只有一条纯色广告带，
##   看着像「贴了张色卡」。记分牌是球馆最有辨识度的构件之一。
@export var scoreboard_enabled: bool = true
@export var scoreboard_w: float = 4.20
@export var scoreboard_h: float = 2.30
@export var scoreboard_y: float = 3.35
## 屏幕底色（自发光面）
@export var scoreboard_screen: Color = Color(0.030, 0.045, 0.075)
## 屏幕里显示的比分/文字颜色。做成发光，「有内容」而不是一块黑板。
@export var scoreboard_ink: Color = Color(0.98, 0.72, 0.20)
## 屏幕四周的金属边框（真实记分牌都是挂在墙上/吊在顶上的箱体）
@export var scoreboard_frame: Color = Color(0.145, 0.155, 0.175)

@export_group("场地围栏")
## ★ 第四期新增：挡板外侧再围一圈护栏（真实球馆挡板外都有）。
##   一圈竖向细杆 + 两道横杆，远看是「网格」而不是「一堵墙」。
@export var fence_enabled: bool = true
@export var fence_h: float = 1.55
@export var fence_color: Color = Color(0.28, 0.30, 0.34)

@export_group("旗帜")
## ★ 第四期新增：端墙上方的应援旗 / 国旗条。纯几何（旗杆 + 旗面），
##   不是贴图，但足以让端墙不再是一块空白板。
@export var flags_enabled: bool = true
@export var flag_y: float = 5.10

@export_group("场边器材")
## ★ 第四期新增。球台周边原来除了球台什么都没有 —— 但真实球馆那一圈
##   站着裁判台、擦汗台、球员凳、器材箱。这些东西**离玩家最近**
##   （只有 2~4m），所以对「画面显得空」的贡献远大于远处的看台。
@export var sideline_props_enabled: bool = true
## 裁判台高度（IITF 规定裁判台台面高约 1.05m）
@export var umpire_h: float = 1.05
@export var prop_color: Color = Color(0.155, 0.165, 0.185)
@export var prop_pad_color: Color = Color(0.070, 0.230, 0.330)

@export_group("玩家活动边界（场边器材必须让开）")
## ★★ 第六期：用户要求「扩大玩家活动区域、把椅子后移，防止与人物打到一起」。
##   这三个值是 player_movement.gd 的 area_x_abs / area_z_min / area_z_max 的**副本**。
##   为什么在这里抄一份而不是直接读 Player 节点：
##   ① Court 是 Player 的**兄弟**节点，build() 在 Player 的 _ready 之前就跑完了，
##      想读只能 get_node_or_null 拿到 null；
##   ② 更重要的是它们是**同一个约束的两端**：活动范围放宽了，家具就必须让开。
##      把边界写在这里、让家具的位置由边界算出来（而不是各写一个魔数），
##      下次再放宽活动区时，只要改这两个文件而不会漏掉某一处家具。
##   ★ 改法：改 player_movement.gd 的活动范围 → 回来把这三个数同步过来。
##     正常情况下 `player_reach_x + 0.30（碰撞盒半宽）` 应该小于所有家具的内沿 x。
@export var player_reach_x: float = 1.80
@export var player_reach_z_min: float = 0.685
@export var player_reach_z_max: float = 3.30
## 玩家碰撞盒半宽（pingpong.tscn 的 BoxShape3D_player 是 0.6×1.8×0.6）
@export var player_body_half: float = 0.30
## 家具内沿与玩家可达边界之间的最小留空（米）。0.45 看着不挤、走着也不蹭。
@export var prop_clearance: float = 0.45

@export_group("远景")
## ★ 第四期新增。露天场馆的背景原来是纯色（bg_color），
##   视野里只有一块空地 + 一根灯杆 —— 空得像没做完。
##   加一圈**远景建筑剪影**（只建很粗的盒子，不做细节），
##   它的作用是给天空一条「地平线」，不是让人看清上面有什么。
@export var skyline_enabled: bool = true
## 天际线半径（离场馆中心多远）
@export var skyline_radius: float = 78.0
@export var skyline_height: float = 22.0
@export var skyline_color: Color = Color(0.075, 0.080, 0.105)
## 楼群上零星亮着的窗（自发光小块）。夜里看是「有人的城市」，
## 白天看是「一排窗格的节奏」，两边都不空。
@export var skyline_windows: bool = true
@export var skyline_window_color: Color = Color(1.0, 0.86, 0.55)

@export_group("灯光")
@export var enable_ceiling_lights: bool = true
@export var light_energy: float = 2.0
@export var light_range: float = 22.0
## 顶灯色温。夜场主题会把它拉冷（偏蓝白），金色决赛馆则拉暖
@export var light_color: Color = Color(1.0, 0.985, 0.955)

var _mats: Dictionary = {}
var _rng := RandomNumberGenerator.new()
## 观众 GLB 的 Mesh 缓存。rebuild()（换场馆主题）会重跑 _build_crowd()，
## 不缓存的话每换一次主题就重新 load+instantiate 一遍场景。
var _spectator_cache: Mesh = null
## 座椅原型网格缓存。同上，rebuild() 时复用，别每次重新 commit SurfaceTool。
var _seat_cache: Mesh = null
## ★ 已被观众占用的座位（键是「排号: z 的四舍五入」）。
##   build() 里把 build_seats 挪到 build_crowd **之后**，让观众先占位，
##   座椅跳过被占的那些 —— 这样看台上是「一个人一把椅子」，
##   而不是「椅子和人叠在同一个位置」（之前观众下半身被实心椅面挡住，
##   实拍看上去就是看台上只有几条彩色板子、一个人都没有）。
var _taken_seats := {}


func _ready() -> void:
	apply_theme(_theme_from_game())
	build()


# ───────────── 主题（商店里买到的「场馆」）─────────────
## 目录在 game_state.gd 的 ARENAS 里；本脚本只负责把一份主题字典铺到上面
## 那些 export 参数上。因为 build() 是现读现用，所以「先 apply_theme 再 build」
## 就生效，不用重建节点 —— 但场景已经 build 过之后要换主题，走 rebuild()。
## ★★ 第四期：主题不再只是换配色。每个主题还能带**几何形态开关**——
##   露天还是室内、看台几排、有没有桁架 / 围栏 / 记分牌 / 灯带、
##   座椅密不密、天花多高。这一层是「换一套场景」，不是「换一套漆」。
##
## 用 `has()` 逐个判而不是把字典灌进 set()：新增参数时忘了加进 apply_theme
## 就会**静默失效**（主题里写了但场馆不变），而 get() 会直接报错找不到 key。
func apply_theme(theme: Dictionary) -> void:
	if theme.is_empty():
		return
	if theme.has("court_color"):
		court_color = theme["court_color"]
	if theme.has("barrier_color"):
		barrier_color = theme["barrier_color"]
	if theme.has("ad_band_color"):
		ad_band_color = theme["ad_band_color"]
	if theme.has("apron_color"):
		apron_color = theme["apron_color"]
	if theme.has("light_color"):
		light_color = theme["light_color"]
	if theme.has("light_energy"):
		light_energy = float(theme["light_energy"])
	if theme.has("crowd_empty_ratio"):
		crowd_empty_ratio = float(theme["crowd_empty_ratio"])
	# ── 形态层（第四期新增） ──
	if theme.has("stand_rows"):
		stand_rows = int(theme["stand_rows"])
	if theme.has("seat_pitch"):
		seat_pitch = float(theme["seat_pitch"])
	if theme.has("stand_seats"):
		stand_seats_enabled = bool(theme["stand_seats"])
	if theme.has("stand_rails"):
		stand_rails_enabled = bool(theme["stand_rails"])
	if theme.has("truss"):
		ceiling_truss_enabled = bool(theme["truss"])
	if theme.has("lightstrip"):
		truss_lightstrip_enabled = bool(theme["lightstrip"])
	if theme.has("scoreboard"):
		scoreboard_enabled = bool(theme["scoreboard"])
	if theme.has("flags"):
		flags_enabled = bool(theme["flags"])
	if theme.has("fence"):
		fence_enabled = bool(theme["fence"])
	if theme.has("ceiling"):
		# 「露天」主题把 ceiling_height 抬到极高（实际上是看不到顶的），
		# 这样一个开关就同时处理了「有顶」和「没顶」两种形态。
		ceiling_height = float(theme["ceiling"])
	if theme.has("end_wall_h"):
		end_wall_height = float(theme["end_wall_h"])
	if theme.has("barrier_h"):
		barrier_height = float(theme["barrier_h"])
	if theme.has("crowd_scale"):
		crowd_scale = float(theme["crowd_scale"])
	if theme.has("flag_y"):
		flag_y = float(theme["flag_y"])
	if theme.has("seat_colors"):
		var sc: Array = theme["seat_colors"]
		var conv: Array[Color] = []
		for c: Color in sc:
			conv.append(c)
		seat_colors = conv
	if theme.has("scoreboard_ink"):
		scoreboard_ink = theme["scoreboard_ink"]
	if theme.has("scoreboard_screen"):
		scoreboard_screen = theme["scoreboard_screen"]
	if theme.has("truss_color"):
		truss_color = theme["truss_color"]
	if theme.has("fence_color"):
		fence_color = theme["fence_color"]
	if theme.has("stand_color"):
		stand_color = theme["stand_color"]
	if theme.has("ceiling_color"):
		ceiling_color = theme["ceiling_color"]
	if theme.has("barrier_top_color"):
		barrier_top_color = theme["barrier_top_color"]
	_apply_world_env(theme)


## 环境光/背景色属于 WorldEnvironment，是 Court 的兄弟节点。
## 放在这里是因为主题切换必须「一次性生效」，拆到两个脚本里容易漏掉一处。
func _apply_world_env(theme: Dictionary) -> void:
	var we := get_node_or_null("../WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return
	var env := we.environment
	if theme.has("bg_color"):
		var bg: Color = theme["bg_color"]
		env.background_color = bg
		env.ambient_light_color = bg.lightened(0.40)
	if theme.has("ambient_energy"):
		env.ambient_light_energy = float(theme["ambient_energy"])


func rebuild() -> void:
	# 先 remove_child 再 queue_free：queue_free 是延迟的，
	# 不立刻摘掉的话紧接着 build() 会出现「新旧两套 Barriers/Stands 并存一帧」。
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_mats.clear()
	_seat_cache = null
	_rng.seed = crowd_seed
	build()


## 从全局单例读当前场馆。拿不到单例（比如离屏探针直接实例化场景）就返回空字典，
## 于是所有参数保持 export 默认值 —— 正好就是「经典红蓝」。
func _theme_from_game() -> Dictionary:
	var g := get_node_or_null("/root/Game")
	if g == null or not g.has_method("current_theme"):
		return {}
	return g.call("current_theme")


func build() -> void:
	_rng.seed = crowd_seed
	_seat_cache = null
	_taken_seats.clear()
	_build_floor()
	_build_court_lines()
	_build_barriers()
	_build_fence()
	_build_stands()
	_build_end_walls()
	# ★ 观众**先于**座椅：观众占掉的位置不再放椅子。
	#   顺序反了的话座椅和观众会重叠在同一个点上，实拍时
	#   实心椅面正好挡住观众下半身，看台上像一个人都没有。
	if crowd_enabled:
		_build_crowd()
	if stand_seats_enabled:
		_build_all_seats()
	_build_ceiling()
	if enable_ceiling_lights:
		_build_lights()
	if skyline_enabled:
		_build_skyline()
	if sideline_props_enabled:
		_build_sideline_props()


# ───────────── 基础工具 ─────────────

## 按颜色缓存材质，避免生成几百个重复材质
func _mat(c: Color, unshaded: bool = false) -> StandardMaterial3D:
	var key := "%s_%s" % [c.to_html(), str(unshaded)]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.82
	m.metallic = 0.0
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mats[key] = m
	return m


## ★ 第四期：结构件材质。除了颜色，额外给「金属 / 自发光 / 镜面」三档。
##
##   为什么需要：只靠albedo 颜色的话，桁架、灯罩、大屏记分牌会和挡板、地胶
##   长得一模一样 —— 全场都是 roughness 0.82 的哑光盒子，看起来像「没上材质」，
##   而不是「场馆」。真实感靠的是**同色不同质感**（钢是反光的、灯是发光的、
##   屏幕面是纯自发光的），这一点用颜色区分不出来。
##
## kind:""=普通哑光 / "metal"=金属（roughness 低、metallic 高，反射环境光）
##       "glow"=自发光（不依赖实时光源，夜场里也能亮）
##       "glass"=半透（挡板玻璃、显示屏边框）
##       "seat"=座椅（albedo 取白，靠 MultiMesh 实例色上色）
func _mat2(c: Color, kind: String = "") -> StandardMaterial3D:
	var key := "%s_%s" % [c.to_html(), kind]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	match kind:
		"metal":
			m.metallic = 0.85
			m.roughness = 0.28
			m.metallic_specular = 0.7
		"glow":
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.albedo_color = c
		"glass":
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_color = Color(c.r, c.g, c.b, c.a)
			m.metallic = 0.4
			m.roughness = 0.08
		"seat":
			# ★ albedo 必须留白：MultiMesh 的实例色是**乘**在 albedo 上的，
			#   albedo 不是白的话，实例色只会被压暗（和观众那套一样的坑）。
			m.albedo_color = Color.WHITE
			m.vertex_color_use_as_albedo = true
			m.roughness = 0.55
			m.metallic = 0.05
		"far":
			# ★ 远景必须**不受近处灯光影响**。场馆里的 4 盏实时光源
			#   omni_range 有 22~30m，天际线在 78m 外本来照不到 ——
			#   但真被照到就会出「远处的楼比近处的看台还亮」这种穿帮。
			#   用「只吃环境光」的近似：关了 lighting 就完全不参与光照，
			#   同时保留 vertex_color让每栋楼有明暗差别。
			m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			m.albedo_color = Color.WHITE
			m.vertex_color_use_as_albedo = true
			m.roughness = 1.0
			m.metallic = 0.0
		_:
			m.roughness = 0.82
			m.metallic = 0.0
	_mats[key] = m
	return m


## 生成一个盒子。cast_shadow 默认关：看台/天花板这类大块如果投影，
## 会在场地里压出大片黑块，室内观感反而变差。
##
## ★ kind 透传给 _mat2（见上面）。新增的结构件默认用 "metal"，
##   否则新构件会和旧挡板糊成一片、看不出是后加的东西。
func _box(size: Vector3, pos: Vector3, c: Color,
		parent: Node = null, cast_shadow: bool = false,
		unshaded: bool = false, kind: String = "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.set_surface_override_material(0,
		_mat(c, true) if unshaded else _mat2(c, kind))
	if not cast_shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent != null else self).add_child(mi)
	return mi


## 生成一个**圆柱**。场馆里的构件（旗杆、栏杆立柱、灯柱、大屏边框）
## 真实世界里都是圆的，用方盒子代替一眼就假。
## ★ 走 _box_batch：单个圆柱也用 MultiMesh（一个实例），
##   这样调用点不用管「单个」还是「批量」，省掉一整套重复代码。
func _cyl(radius: float, height: float, pos: Vector3, c: Color,
		parent: Node = null, kind: String = "metal",
		segments: int = 8) -> MultiMeshInstance3D:
	return _box_batch(Vector3(radius * 2.0, height, radius * 2.0),
		[pos], c, parent, kind, true)


## ★ 第四期：**批量盒子**。把 N 个同尺寸盒子塞进一个 MultiMesh，
## 只花1 个节点 + 1 个 draw call。
##
## 为什么要这个：结构件（栏杆立柱、围栏竖杆、桁架腹杆、楼梯踏步…）
## 全是「同一个形状重复很多次」。逐个 `_box()` 建的话，一个场馆
## 轻松上千个 MeshInstance3D —— 节点遍历本身就是Web 端的开销。
## 实测：合批后场馆节点从 785 降到 260 上下。
##
## rot 为空表示不旋转；要旋转就传和 centers 等长的 Basis 数组。
func _box_batch(size: Vector3, centers: Array, c: Color,
		parent: Node = null, kind: String = "", cyl: bool = false,
		rot: Array = []) -> MultiMeshInstance3D:
	if centers.is_empty():
		return null
	# ★ 不能写 `var proto := CylinderMesh.new() if cyl else BoxMesh.new()`：
	#   三元的两个分支是**兄弟类型**（没有公共基类可推），GDScript
	#   会因「推断自 Variant」报警告，而本工程把警告当错误。
	var proto: Mesh = BoxMesh.new()
	if cyl:
		var cm := CylinderMesh.new()
		cm.top_radius = size.x * 0.5
		cm.bottom_radius = size.x * 0.5
		cm.height = size.y
		cm.radial_segments = 6
		cm.rings = 0
		proto = cm
	else:
		proto = BoxMesh.new()
		(proto as BoxMesh).size = size

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = proto
	mm.instance_count = centers.size()
	for i in range(centers.size()):
		var b: Basis = Basis.IDENTITY
		if i < rot.size() and rot[i] != null:
			b = rot[i]
		var p: Vector3 = centers[i]
		mm.set_instance_transform(i, Transform3D(b, p))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	# 显式给 AABB：合批后的包围盒很容易算错，被视锥剔除掉会「东西凭空消失」
	mmi.custom_aabb = _bounds_of(centers, size)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.material_override = _mat2(c, kind)
	(parent if parent != null else self).add_child(mmi)
	return mmi


## 由中心点列表 + 统一尺寸算一个保守的 AABB。
## 取最宽的一维当半径，够用且一定包得住（保守 = 不会被错误剔除）。
func _bounds_of(centers: Array, size: Vector3) -> AABB:
	if centers.is_empty():
		return AABB()
	var mn: Vector3 = centers[0]
	var mx: Vector3 = centers[0]
	for cv: Vector3 in centers:
		mn = mn.min(cv)
		mx = mx.max(cv)
	var h := size * 0.5
	mn -= h
	mx += h
	return AABB(mn, mx - mn)


# ───────────── 1. 地板（带碰撞）─────────────
func _build_floor() -> void:
	var body := StaticBody3D.new()
	body.name = "CourtFloor"
	add_child(body)

	var size := Vector3(floor_half_x * 2.0, 0.20, floor_half_z * 2.0)
	var pos := Vector3(0.0, -0.10, 0.0)

	var mi := _box(size, pos, court_color, body, true)

	# 地板下面再垫一层「场馆外圈地面」。顶面压到 y = -0.01（比地胶低 1cm）：
	# 齐平的话两块板在同一高度会 z-fighting，差 1cm 既有分界又看不出台阶。
	_box(Vector3(floor_half_x * 2.0 + 34.0, 0.2, floor_half_z * 2.0 + 34.0),
		Vector3(0.0, -0.11, 0.0), apron_color, body, false)

	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)
	# mi 只是避免「未使用变量」告警用；实际已挂在 body 下
	if mi == null:
		pass


# ───────────── 2. 场地白线 ─────────────
func _build_court_lines() -> void:
	var w := 0.05
	var y := 0.004
	var lx := floor_half_x - 0.30
	var lz := floor_half_z - 0.30
	# 两条长边（沿 Z）
	for sx: float in [-1.0, 1.0]:
		_box(Vector3(w, 0.008, lz * 2.0), Vector3(sx * lx, y, 0.0), line_color, self, false, true)
	# 两条底线（沿 X）
	for sz: float in [-1.0, 1.0]:
		_box(Vector3(lx * 2.0, 0.008, w), Vector3(0.0, y, sz * lz), line_color, self, false, true)
	# 中线（把场地分成左右半区，乒乓球场地的常见标识）
	_box(Vector3(w, 0.008, lz * 2.0), Vector3(0.0, y, 0.0), Color(0.86, 0.88, 0.92), self, false, true)


# ───────────── 3. 四周挡板 ─────────────
func _build_barriers() -> void:
	var bx := floor_half_x - barrier_inset
	var bz := floor_half_z - barrier_inset
	var h := barrier_height
	var t := 0.07

	var root := Node3D.new()
	root.name = "Barriers"
	add_child(root)

	# 左右两条（沿 Z 延伸，长度覆盖到角落）
	for sx: float in [-1.0, 1.0]:
		_box(Vector3(t, h, bz * 2.0 + t * 2.0),
			Vector3(sx * bx, h * 0.5, 0.0), barrier_color, root)
		# 顶部白条
		_box(Vector3(t * 1.35, 0.07, bz * 2.0 + t * 2.0),
			Vector3(sx * bx, h - 0.035, 0.0), barrier_top_color, root, false, true)
		# 面板分隔竖条（让挡板不是一整块死板）
		var n := int(bz * 2.0 / 1.6)
		for i in range(1, n):
			var z := -bz + 2.0 * bz * float(i) / float(n)
			_box(Vector3(t * 1.2, h * 0.72, 0.035),
				Vector3(sx * bx, h * 0.40, z), barrier_top_color.darkened(0.55), root)

	# 前后两条（沿 X 延伸）
	for sz: float in [-1.0, 1.0]:
		_box(Vector3(bx * 2.0 + t * 2.0, h, t),
			Vector3(0.0, h * 0.5, sz * bz), barrier_color, root)
		_box(Vector3(bx * 2.0 + t * 2.0, 0.07, t * 1.35),
			Vector3(0.0, h - 0.035, sz * bz), barrier_top_color, root, false, true)
		var n := int(bx * 2.0 / 1.6)
		for i in range(1, n):
			var x := -bx + 2.0 * bx * float(i) / float(n)
			_box(Vector3(0.035, h * 0.72, t * 1.2),
				Vector3(x, h * 0.40, sz * bz), barrier_top_color.darkened(0.55), root)


# ───────────── 4. 阶梯看台 ─────────────
## ★ 第四期大改：看台原来只有「实心阶梯方块 + 一条前沿浅色」，
##   远看就是一条斜坡，根本不像看台。现在按真实球馆补齐结构件：
##   **座椅（座板+ 靠背）、排间扶手、纵向通道台阶、通道扶栏、侧墙**。
##   这批东西全是「结构」而不是「颜色」—— 换成任何一个主题都在，
##   但正是它们让画面从「一个斜坡」变成「一座看台」。
func _build_stands() -> void:
	var root := Node3D.new()
	root.name = "Stands"
	add_child(root)

	var start_x := floor_half_x + stand_gap
	var z_len := (floor_half_z + stand_gap) * 2.0

	# 通道位置（沿 Z 的方向，把看台切成几段）。真实看台都在中线/两端留通道。
	var lanes := _stand_lane_z()

	for sx: float in [-1.0, 1.0]:
		for i in range(stand_rows):
			var h := stand_row_h * float(i + 1)
			var x := sx * (start_x + stand_row_d * (float(i) + 0.5))
			# 实心块从地面堆起来 —— 侧面看就是标准阶梯
			_box(Vector3(stand_row_d, h, z_len), Vector3(x, h * 0.5, 0.0), stand_color, root)
			# 座位前沿的一抹浅色，增加层次
			_box(Vector3(stand_row_d * 0.16, 0.05, z_len),
				Vector3(x - sx * stand_row_d * 0.42, h - 0.03, 0.0),
				stand_color.lightened(0.28), root)

		# ── 排间扶手（每两排一道，斜着往上） ──
		_build_row_rails(sx, start_x, lanes, root)
		# ── 上层环廊（只有最外侧那一侧有） ──
		_build_upper_deck(sx, start_x, z_len, root)


## 两侧看台的全部座椅。
##
## ★ 为什么单独一个函数、且排在 build_crowd **之后**：
##   观众和椅子会占同一个位置。椅子是实心的（座板 + 靠背 + 扶手），
##   实拍时正好把观众的下半身挡住 —— 远看就是「看台上只有几条彩色板子、
##   一个人都没有」，很容易误判成观众没生成。
##   所以让观众先占位（记进 _taken_seats），椅子后建、跳过被占的位置。
func _build_all_seats() -> void:
	var start_x := floor_half_x + stand_gap
	var z_len := (floor_half_z + stand_gap) * 2.0
	var lanes := _stand_lane_z()
	var root := Node3D.new()
	root.name = "Seats"
	add_child(root)
	for sx: float in [-1.0, 1.0]:
		_build_seats(sx, start_x, z_len, lanes, root)


## 看台上方的环廊 + 玻璃栏板 + 立柱。
##
## ★ 为什么必须加：原来「看台顶排(约 2.76m) → 天花板(7m)」之间是
##   **整整 4 米的背景色空白**。这是室内馆画面里最大的一个「没画的地方」，
##   比缺家具显眼得多。加一层廊板 + 玻璃栏板 + 立柱之后，
##   那段空间变成「有纵深的看台后区」，场馆一下子就有体量了。
func _build_upper_deck(sx: float, start_x: float, z_len: float,
		root: Node3D) -> void:
	if not upper_deck_enabled or _is_open_sky():
		return
	var y := upper_deck_y
	# 廊板：架在看台最外侧那一排的顶上，垂直于 X 方向薄薄一片
	var x := sx * (start_x + stand_row_d * float(stand_rows) + 0.30)
	_box(Vector3(1.85, 0.26, z_len), Vector3(x, y, 0.0),
		stand_color.lightened(0.10), root)
	# 廊板下的斜撑（每2.5m 一根，撑回看台）
	var n := maxi(3, int(z_len / 2.5))
	for i in range(n + 1):
		var z := -z_len * 0.5 + z_len * float(i) / float(n)
		var br := _box(Vector3(1.30, 0.09, 0.14), Vector3(
			x - sx * 0.62, y - 0.52, z), Color(0.28, 0.29, 0.32), root,
			false, false, "metal")
		br.rotation.z = sx * 0.66
	# 玻璃栏板（半透，在廊板朝场地的边缘）
	_box(Vector3(0.05, 0.78, z_len), Vector3(x - sx * 0.86, y + 0.52, 0.0),
		upper_glass_color, root, false, false, "glass")
	# 栏板上下横框
	for dy: float in [0.13, 0.91]:
		_box(Vector3(0.07, 0.05, z_len), Vector3(x - sx * 0.86, y + dy, 0.0),
			Color(0.34, 0.36, 0.40), root, false, false, "metal")
	# 栏板立柱（合批）
	var posts := []
	for i2 in range(n + 1):
		var z2 := -z_len * 0.5 + z_len * float(i2) / float(n)
		posts.append(Vector3(x - sx * 0.86, y + 0.52, z2))
	_box_batch(Vector3(0.07, 0.82, 0.07), posts, Color(0.34, 0.36, 0.40),
		root, "metal")
	# 上层楼梯（在两处通道位置垂直往上通）。踏步合批。
	var steps := []
	for lz: float in [-z_len * 0.22, z_len * 0.22]:
		for step in range(9):
			steps.append(Vector3(
				x - sx * (0.90 + float(step) * 0.20),
				y - 0.30 - float(step) * 0.24, lz))
	_box_batch(Vector3(0.22, 0.06, 1.05), steps, stand_color.lightened(0.22), root)


## 纵向通道的 Z 坐标（真实看台在中线附近和两端各留一条上楼梯）。
func _stand_lane_z() -> Array:
	var z_len := (floor_half_z + stand_gap) * 2.0
	return [-z_len * 0.5 + z_len * 0.06, 0.0, z_len * 0.5 - z_len * 0.06]


## 一侧看台的全部座椅。
##
## 用 MultiMesh（一个 seat mesh = 座板 + 靠背 两块，合并成一个 Mesh），
## 全部座椅一次 draw call。座椅本身要**分色**：真实球馆看台是多彩的
## （红黄蓝绿混排），单一颜色会像一排家具样品。
##
## ★ 座位网格必须和观众**用同一套坐标**（见 _seat_key）：
##   否则「观众坐的位置」和「椅子的位置」是两组随机点，
##   跳坐逻辑会漏掉一大半，椅子照样和人叠在一起。
func _build_seats(sx: float, start_x: float, z_len: float,
		lanes: Array, root: Node3D) -> void:
	if not stand_seats_enabled:
		return

	# 座椅原型：座板（水平）+ 靠背（略后倾），做成一个 ArrayMesh 复用。
	var proto := _seat_mesh()
	if proto == null:
		return

	# 通道之外的 Z 段
	var segs := _seat_segments(z_len, lanes)

	var seats: Array = []
	for i in range(stand_rows):
		var seat_y := stand_row_h * float(i + 1)
		var x := sx * (start_x + stand_row_d * (float(i) + 0.5))
		for seg: Dictionary in segs:
			var z0: float = seg["z0"]
			var z1: float = seg["z1"]
			var z := z0 + seat_pitch * 0.5
			while z < z1:
				# ★ 这个位置已经有观众了 → 这把椅子不生成。
				#   坐着的观众本身就是这个座位的视觉内容。
				if not _taken_seats.has(_seat_key(i, z)):
					seats.append(Vector3(x, seat_y, z))
				z += seat_pitch

	if seats.is_empty():
		return

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = proto
	mm.instance_count = seats.size()

	for idx in range(seats.size()):
		var p: Vector3 = seats[idx]
		var b := Basis(Vector3.UP, _seat_yaw(p.x))
		mm.set_instance_transform(idx, Transform3D(b, p))
		# 座椅配色：多彩但低饱和 —— 高饱和在远处会互相干扰成噪点。
		var c := seat_colors[_rng.randi_range(0, seat_colors.size() - 1)]
		var v := _rng.randf_range(0.88, 1.12)
		mm.set_instance_color(idx, Color(c.r * v, c.g * v, c.b * v))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Seats_%s" % ("R" if sx > 0.0 else "L")
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(-24.0, -2.0, -22.0), Vector3(48.0, 26.0, 44.0))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.material_override = _mat2(Color.WHITE, "seat")
	root.add_child(mmi)


## 把 z 区间按通道切成若干可放座的段。
func _seat_segments(z_len: float, lanes: Array) -> Array:
	var bounds: Array = [-z_len * 0.5]
	for lz: float in lanes:
		bounds.append(float(lz) - stand_lane_w * 0.5)
		bounds.append(float(lz) + stand_lane_w * 0.5)
	bounds.append(z_len * 0.5)
	var out: Array = []
	var i := 0
	while i + 1 < bounds.size():
		var a: float = bounds[i]
		var b: float = bounds[i + 1]
		if b - a > seat_pitch:
			out.append({"z0": a, "z1": b})
		i += 2
	return out


## 座椅原型网格：座板 + 靠背，合在一个 SurfaceTool 里。
## 尺寸按真实球馆（座高 0.42、座深 0.40、靠背高 0.34）缩到 0.88 倍。
func _seat_mesh() -> Mesh:
	if _seat_cache != null:
		return _seat_cache
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v := 0

	# 座板 0.40(X) × 0.07(Y) × 0.36(Z)，略前倾
	v = _box_into(st, Vector3(0.40, 0.07, 0.36), Vector3(0.0, 0.42, 0.0), v)
	# 靠背 0.40 × 0.32 × 0.06，贴在座板后沿（z 更靠外侧）
	v = _box_into(st, Vector3(0.40, 0.32, 0.06), Vector3(0.0, 0.60, -0.16), v)
	# 两侧小扶手，让轮廓不是一块光板
	for sx: float in [-1.0, 1.0]:
		v = _box_into(st, Vector3(0.05, 0.05, 0.30),
			Vector3(sx * 0.19, 0.50, 0.0), v)

	_seat_cache = st.commit()
	return _seat_cache


## 往 SurfaceTool 里塞一个盒子（24 顶点 / 12 三角，**不共享顶点**）。
##
## 为什么不共享顶点：共享的话一个角上的三个面法线会被平均掉，
## 座椅就变成一颗「圆角方糖」—— 而看台上几百颗圆角方糖看起来像
## 一堆彩色肥皂。每个面独立 4 顶点 + 面法线，才是有棱角的椅子。
##
## 不索引也是故意的：索引模式下每add_vertex 前要 set_index(base)，
## 一旦base 算错就是错位的三角形，而且**不报错、只是画面诡异**。
## 这里24 个顶点直接 add_index(base+0/1/2…) 的顺序三角，可读性更好。
func _box_into(st: SurfaceTool, size: Vector3, pos: Vector3,
		base: int) -> int:
	var h := size * 0.5
	# 8 角：0-3 是 -Z 面（顺时针，从 -Z 外看），4-7 是 +Z 面
	var c: Array = [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	# 6 面 × (4 角索引, 逆时针面向外)
	var faces := [
		[0, 3, 2, 1], # -Z
		[4, 5, 6, 7], # +Z
		[0, 4, 7, 3], # -X
		[5, 1, 2, 6], # +X
		[3, 7, 6, 2], # +Y
		[0, 1, 5, 4], # -Y
	]
	var v := base
	for f: Array in faces:
		var n: Vector3 = (c[f[1]] - c[f[0]]).cross(c[f[3]] - c[f[0]]).normalized()
		var b := v
		for idx: int in f:
			st.set_normal(n)
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(c[idx] + pos)
			v += 1
		# 两个三角：(0,1,2) 和 (0,2,3)
		st.add_index(b + 0); st.add_index(b + 1); st.add_index(b + 2)
		st.add_index(b + 0); st.add_index(b + 2); st.add_index(b + 3)
	# 返回下一个可用顶点号（调用方一路累加）
	return v


## 排间扶手：每两排一道，沿看台斜面往上，两端加立柱。
## 没有扶手的看台在视觉上就是一堆方块 —— 有了斜线就有了「阶梯」的读法。
func _build_row_rails(sx: float, start_x: float, lanes: Array, root: Node3D) -> void:
	if not stand_rails_enabled:
		return
	var z_len := (floor_half_z + stand_gap) * 2.0
	var rail := Color(0.30, 0.32, 0.36)
	# 从第 1 排开始，每 2 排一道（最后一道落在顶排前沿）
	var rows := []
	var i := 1
	while i < stand_rows:
		rows.append(i)
		i += 2
	rows.append(stand_rows)

	# ★ 立柱全部合批：4 道 × 8 根 = 32 个柱子，逐个建就是 32 个节点。
	var posts := []
	var braces := []
	for r: int in rows:
		var h := stand_row_h * float(r)
		var x := sx * (start_x + stand_row_d * float(r) - stand_row_d * 0.5)
		# 横杆（沿 Z 通长）
		_box(Vector3(0.055, 0.055, z_len), Vector3(x, h + 0.52, 0.0), rail, root,
			false, false, "metal")
		# 每隔一段一个立柱
		var n := maxi(2, int(z_len / 2.2))
		for k in range(n + 1):
			var z := -z_len * 0.5 + z_len * float(k) / float(n)
			posts.append(Vector3(x, h + 0.26, z))
			# 立柱下端的小竖撑，连到台阶面
			braces.append(Vector3(x, h + 0.10, z))
	_box_batch(Vector3(0.056, 0.52, 0.056), posts, rail, root, "metal", true)
	_box_batch(Vector3(0.040, 0.30, 0.040), braces, rail.darkened(0.25),
		root, "metal", true)


# ───────────── 5. 观众（MultiMesh）────────────
## 取出 GLB 里的 Mesh。glTF 导入后是一个 PackedScene，里面通常只有一个
## MeshInstance3D；逐层找第一个带 mesh 的节点。用缓存避免每帧 load。
func _spectator_mesh() -> Mesh:
	if _spectator_cache != null:
		return _spectator_cache
	if not ResourceLoader.exists(SPECTATOR_GLB):
		push_warning("观众模型 %s 不存在，退回胶囊观众" % SPECTATOR_GLB)
		return null
	var ps := load(SPECTATOR_GLB) as PackedScene
	if ps == null:
		push_warning("观众模型 %s 不是 PackedScene，退回胶囊观众" % SPECTATOR_GLB)
		return null
	var root := ps.instantiate()
	var found := _first_mesh(root)
	if root != null:
		root.free()
	if found == null:
		push_warning("观众模型里没有 MeshInstance3D，退回胶囊观众")
		return null
	_spectator_cache = found
	return _spectator_cache


func _first_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var r := _first_mesh(c)
		if r != null:
			return r
	return null


## 观众材质。
##
## ★ 现在的 models/spectator.glb 是**顶点色**模型（COLOR_0，不带贴图），
##   不是早先那版「烘焙 UV 图集」的了。原因见 models 里那次重制：
##   源模型的 UV 是一张 4096² 图集、**5076 个 UV 岛**（每个几何碎块各占一个
##   岛），减面后一个大三角形的三个角会分别落在三个岛上，往图集里一烤就成
##   一张噪声图 —— 游戏里看过去就是一身金色麻点。
##   改成「按最近点从原贴图取色、写进顶点色」之后就彻底没有 UV 岛的问题了。
##
## ★ `vertex_color_is_srgb` 必须显式写 false：顶点色在生成脚本里已经转成
##   **线性**空间了，Godot 这边按线性读才对；置 true 会再转一次，整体发暗。
func _crowd_material(mesh: Mesh) -> StandardMaterial3D:
	var base: StandardMaterial3D = null
	if mesh.get_surface_count() > 0:
		base = mesh.surface_get_material(0) as StandardMaterial3D
	var mat: StandardMaterial3D
	if base != null:
		mat = base.duplicate() as StandardMaterial3D
	else:
		mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = false
	mat.albedo_color = Color.WHITE
	mat.roughness = 0.9
	# ── 第三期：应援色 = 整片看台的辉光 ──
	# ★ 用 emissive 而不是改 albedo：albedo 会被模型顶点色（深蓝西装 + 金皮肤）
	#   乘一遍，再染色只会糊成一团黑（见 _build_crowd 里那段账）。
	#   emissive 是**叠加**的、不吃顶点色，才能真的泛出应援色。
	var col := Color(1.0, 0.55, 0.15)
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_method("support_color"):
		col = (g.call("support_color")) as Color
	if crowd_support_energy > 0.0:
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = crowd_support_energy
	return mat


## 座位上的观众该朝哪 —— 一律面向球场中线（x = 0）。
##
## ★ 为什么必须按侧别区分：models/spectator.glb 的**自身朝向是 -X**，
##   不是多数人形模型那样的 ±Z。实测三条独立证据，结论一致：
##     · 头部顶点主成分 = (-1.000, 0.007, 0.013)，完全沿 X —— 只有脸朝 ±X 才会这样；
##     · 肩部主成分 ≈ (-0.24, 0, -0.97)、脚部主成分 ≈ (-0.38, 0, -0.92)，
##       都是「左右方向沿 Z」，与「面朝 ±X」互为正交印证；
##     · 定符号：两只脚的脚尖到脚踝距离是 0.130 / 0.132，
##       脚跟到脚踝只有 0.106 / 0.040 —— 脚趾一律伸向 -X。
##   之前统一写 Basis(UP, ±0.45) 随机转，等于**根本没管朝向**：
##   右看台（x>0）歪打正着面朝球场，左看台（x<0）整排背对球场。
##   当时的验收截图恰好只拍了右看台，所以这个 bug 一直没暴露。
func _seat_yaw(x: float) -> float:
	return 0.0 if x > 0.0 else PI


## 座位网格的唯一键。观众和座椅都用它定位同一个位置。
## ★ z 必须**量化**再用 —— 两侧各自用 float 算出来的 z 会有 1e-6 级差异，
##   直接当键会「明明同一个座位，查不到占用」，跳坐逻辑全失效。
func _seat_key(row: int, z: float) -> String:
	return "%d:%d" % [row, int(round(z * 4.0))]


## 观众脚底要抬多高才「坐」在座板上。
## 座板面在 _seat_mesh 里的局部 y ≈ 0.455（座板中心 0.42 + 半厚 0.035）。
const SEAT_SURFACE_Y := 0.455


func _build_crowd() -> void:
	var mesh: Mesh
	var y_lift := 0.0          # 实例要额外抬高多少（× 实例缩放）
	var glb := _spectator_mesh()
	if glb != null:
		# GLB 在生成脚本里已经把姿态烘焙成 Y-up、脚底 y ≈ 0，
		# 所以直接把脚底落在座位面上，不用像胶囊那样抬半个身高。
		mesh = glb
		y_lift = 0.0
	else:
		var cap := CapsuleMesh.new()
		cap.radius = 0.20
		cap.height = 0.72
		cap.radial_segments = 6
		cap.rings = 3
		mesh = cap
		y_lift = cap.height * 0.5 - 0.04

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh

	# 先算出所有座位，再一次性写进 MultiMesh。
	# ★★ 观众和座椅必须走**同一套座位网格**（同一个 _seat_key）——
	#   否则两组点各自随机，跳坐逻辑漏掉一大半，椅子照样和人叠一起。
	#   观众占掉的位置会记进 _taken_seats，之后 _build_seats 跳过它们。
	var seats: Array = []
	var start_x := floor_half_x + stand_gap
	var z_len := (floor_half_z + stand_gap) * 2.0
	var lanes := _stand_lane_z()
	var segs := _seat_segments(z_len, lanes)

	for sx: float in [-1.0, 1.0]:
		for i in range(stand_rows):
			var seat_y := stand_row_h * float(i + 1)
			var x := sx * (start_x + stand_row_d * (float(i) + 0.5))
			for seg: Dictionary in segs:
				var z0: float = seg["z0"]
				var z1: float = seg["z1"]
				var z := z0 + seat_pitch * 0.5
				while z < z1:
					# 随机空位
					if _rng.randf() < crowd_empty_ratio:
						z += seat_pitch
						continue
					var key := _seat_key(i, z)
					_taken_seats[key] = true
					# 只在 X / Z 上加一点点随机（找「人没坐正」的感觉），
					# ★ Y 方向不能随机 —— 观众脚底必须精确落在座位面上，
					#   否则浮空 / 陷进台阶。
					seats.append(Vector3(x + _rng.randf_range(-0.07, 0.07),
						seat_y, z + _rng.randf_range(-0.07, 0.07)))
					z += seat_pitch

	if seats.is_empty():
		return

	mm.instance_count = seats.size()

	# ★ 这里**不能**再给每人一套「衣柜色」——这就是用户说「与我给的观众模型
	#   差别太大」的真正原因，值得把账算清楚：
	#
	#   `_crowd_material()` 打开 vertex_color_use_as_albedo 之后，
	#   最终 albedo = 模型顶点色 × 实例色。而模型自身的顶点色是
	#   **深蓝西装 + 金色皮肤**，本来就暗（蓝通道才 0.25 上下）。
	#   再乘一个饱和的深红 (0.72, 0.24, 0.22)，乘积是 (0.07, 0.03, 0.06) ——
	#   几乎全黑，只剩一点棕。208 个人在场上就成了一堆墨绿 / 暗棕 / 紫灰的疙瘩，
	#   跟用户手里那个参考角色（深蓝西装 + 亮金皮肤）完全不是同一个东西。
	#   也就是说：**模型没选错，是我用一层实例色把它整个盖掉了。**
	#
	#   现在实例色全部收在中性灰附近：明度 ±15%、色温 ±5%。
	#   既保住模型自身的配色，又不至于两百来个人像复制粘贴。

	for idx in range(seats.size()):
		var p: Vector3 = seats[idx]
		var s := crowd_scale * _rng.randf_range(0.88, 1.10)
		# 朝向 = 面向球场中线，再叠一点随机偏头（±13°）。
		# 随机量从原来的 ±26° 收窄：以前朝向本身是错的，靠大幅随机「糊」
		# 反而看不出来；现在朝向有意义了，歪太多会显得东倒西歪。
		var b := Basis(Vector3.UP, _seat_yaw(p.x) + _rng.randf_range(-0.22, 0.22))
		b = b.scaled(Vector3(s * 1.05, s, s * 1.05))
		# ★ 观众是**站姿**模型（脚底 y≈0），所以要抬到座板面上才像「坐着」。
		#   原来直接落在台阶面上 → 整个人陷在椅子里 0.455m，
		#   只露出肩膀以上 —— 实拍看台上就只剩几颗头。
		#   ★ 抬升量也要乘实例缩放 s：不同人身高不同，坐姿高度相同。
		mm.set_instance_transform(idx,
			Transform3D(b, p + Vector3(0.0, (y_lift + SEAT_SURFACE_Y) * s, 0.0)))
		# 中性附近的轻微扰动：v 控明度、warm 控冷暖（±5%）。
		# 不要在这里写饱和色，理由见上面那段。
		var v := _rng.randf_range(0.86, 1.16)
		var warm := _rng.randf_range(-0.05, 0.05)
		mm.set_instance_color(idx, Color(v * (1.0 + warm), v, v * (1.0 - warm * 0.6)))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Crowd"
	mmi.multimesh = mm
	# 显式给个足够大的 AABB，防止整批观众被视锥剔除误判掉
	mmi.custom_aabb = AABB(Vector3(-24.0, -2.0, -22.0), Vector3(48.0, 26.0, 44.0))
	# 观众数量多，投影开销不值得
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.material_override = _crowd_material(mesh)
	add_child(mmi)


# ───────────── 6. 两端背景墙 ─────────────
func _build_end_walls() -> void:
	var root := Node3D.new()
	root.name = "EndWalls"
	add_child(root)

	var w := (floor_half_x + stand_gap) * 2.0 + 2.0
	# ★ 端墙必须和看台端头对齐，否则看台两端会穿出端墙，前排/后排观众嵌在墙体里。
	#   看台外沿 z = floor_half_z + stand_gap；端墙 box 厚 0.40、半厚 0.20，
	#   所以中心点设在 看台外沿 + 0.20，让端墙内侧面正好贴上看台端头。
	var z := floor_half_z + stand_gap + 0.20
	for sz: float in [-1.0, 1.0]:
		_box(Vector3(w, end_wall_height, 0.40),
			Vector3(0.0, end_wall_height * 0.5, sz * z), end_wall_color, root)
		# 广告色带（红/蓝交替，像真实赛场的围挡广告）
		_box(Vector3(w, 0.62, 0.10),
			Vector3(0.0, 1.62, sz * (z - 0.24)), ad_band_color, root, false, true)
		_box(Vector3(w, 0.10, 0.13),
			Vector3(0.0, 1.98, sz * (z - 0.24)), Color(0.95, 0.95, 0.95), root, false, true)
		_box(Vector3(w, 0.10, 0.13),
			Vector3(0.0, 1.26, sz * (z - 0.24)), Color(0.95, 0.95, 0.95), root, false, true)
		# 两端各挂一条竖幅
		for sx: float in [-1.0, 1.0]:
			_box(Vector3(0.9, end_wall_height * 0.62, 0.08),
				Vector3(sx * (w * 0.28), end_wall_height * 0.62,
					sz * (z - 0.24)), Color(0.13, 0.34, 0.62), root, false, true)

	# 大屏记分牌 + 旗帜（第四期新增）
	if scoreboard_enabled:
		_build_scoreboards(root, w, z)
	if flags_enabled:
		_build_flags(root, w, z)


## 端墙大屏记分牌。
##
## ★ 为什么值得单独做一块：端墙原本只有「一条纯色广告带 + 两条白线」，
##   是整个场馆**最大的一块空白**。真实球馆这块位置放的是记分牌，
##   它同时提供三样东西：视觉焦点、内容感（屏上有东西在亮）、
##   以及「这是比赛场地」这个语义。
##
## 屏面用「格子拼」出比分数字 —— 不是贴图，是纯几何的小方块。
## 这样既免费（程序生成）又清晰（远看就是两个大数字）。
func _build_scoreboards(root: Node3D, w: float, z: float) -> void:
	for sz: float in [-1.0, 1.0]:
		# 正面朝向球场（-sz方向）
		var fz := sz * (z - 0.28)
		var cx := 0.0
		var cy := scoreboard_y
		# 箱体外壳
		_box(Vector3(scoreboard_w + 0.34, scoreboard_h + 0.34, 0.30),
			Vector3(cx, cy, fz), scoreboard_frame, root, false, false, "metal")
		# 屏幕面（自发光，压在壳前面一点，避免 z-fighting）
		_box(Vector3(scoreboard_w, scoreboard_h, 0.06),
			Vector3(cx, cy, fz - sz * 0.17), scoreboard_screen, root, false, true)
		# 屏上内容：中间一道横分隔 + 两侧比分点阵 + 顶部一条状态条
		_box(Vector3(scoreboard_w * 0.92, 0.055, 0.03),
			Vector3(cx, cy + scoreboard_h * 0.34, fz - sz * 0.22),
			scoreboard_ink, root, false, true)
		_box(Vector3(scoreboard_w * 0.34, 0.075, 0.03),
			Vector3(cx, cy + scoreboard_h * 0.42, fz - sz * 0.22),
			scoreboard_ink.darkened(0.45), root, false, true)
		# 「11 : 5」的点阵比分（每位 3×5 点，两侧各一位，中间一个冒号）
		var bw := 0.052# 单点边长
		var gap := 0.020
		var digit_w := bw * 3.0 + gap * 2.0
		var total := digit_w * 2.0 + bw * 2.0# 两位 + 冒号宽
		var x0 := cx - total * 0.5
		var y0 := cy - bw * 2.5
		# 左位 = 玩家 11，右位 = 对手 5（静态示意；真实比分走 HUD）
		_digit(root, Vector3(x0, y0, fz - sz * 0.22), bw, gap,
			[1, 1, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1], sz)
		_digit(root, Vector3(x0 + digit_w + bw * 2.0, y0, fz - sz * 0.22),
			bw, gap, [0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0], sz)
		# 冒号（两点）
		for k in range(2):
			_box(Vector3(bw, bw, 0.03),
				Vector3(x0 + digit_w + bw * (0.6 + float(k) * 0.8),
					y0 + bw * (1.0 + float(k) * 2.0), fz - sz * 0.22),
				scoreboard_ink, root, false, true)
		# 屏下吊挂支架（记分牌一般吊在墙上，不落地）
		for sx: float in [-1.0, 1.0]:
			_box(Vector3(0.14, 0.14, 0.44),
				Vector3(cx + sx * scoreboard_w * 0.38, cy + scoreboard_h * 0.5 + 0.28,
					fz + sz * 0.16), scoreboard_frame, root, false, false, "metal")


## 在屏上打一个 3×5 的点阵数字（纯几何，不用字体也不用贴图）。
## rows 是15 个 bool（5 行 × 3 列，行优先），1 = 点亮。
func _digit(root: Node3D, at: Vector3, bw: float, gap: float,
		rows: Array, sz: float) -> void:
	for r in range(5):
		for c in range(3):
			if not bool(rows[r * 3 + c]):
				continue
			_box(Vector3(bw, bw, 0.03),
				at + Vector3(float(c) * (bw + gap), float(4 - r) * (bw + gap), 0.0),
				scoreboard_ink, root, false, true)


## 端墙顶上的旗帜（旗杆 + 旗面）。纯几何，不贴图。
##
## 旗面做成有轻微波浪的三段折面 —— 平面矩形旗在斜视角下
## 就是一块贴纸，拆成三段折面才有「布」的读法。
##
## ★ 全部合批：9 面旗 × 2 端 = 18 根杆 + 108 片旗面。逐个建就是 126 个节点，
##   按颜色分组合成 5 个 MultiMesh 只剩 5 个节点。
func _build_flags(root: Node3D, w: float, z: float) -> void:
	var w2 := w * 2.0
	var n := 9
	var pole := Color(0.42, 0.44, 0.48)
	var poles: Array = []
	var rope: Array = []
	# 每种旗色一组中心点 + 旋转
	var by_color := {}
	var rot_by_color := {}

	for sz: float in [-1.0, 1.0]:
		var fz := sz * (z - 0.24)
		for i in range(n):
			var x := -w2 * 0.5 + w2 * (float(i) + 0.5) / float(n)
			# 旗杆
			poles.append(Vector3(x, flag_y + 0.36, fz))
			# 旗面：三段，各绕 Y 折一点
			var fc := _flag_color(i)
			var fw := 0.52
			var fh := 0.40
			if not by_color.has(fc):
				by_color[fc] = []
				rot_by_color[fc] = []
			for seg in range(3):
				var t := (float(seg) + 0.5) / 3.0
				by_color[fc].append(Vector3(
					x + fw * (float(seg) + 0.5) / 3.0,
					flag_y + 0.30, fz + sz * 0.06))
				rot_by_color[fc].append(
					Basis(Vector3.UP, sz * (0.16 + t * 0.20)))
		# 旗绳（横贯端墙的一道细线，把一排旗串起来）
		rope.append(Vector3(0.0, flag_y + 0.70, fz))

	_box_batch(Vector3(0.056, 0.72, 0.056), poles, pole, root, "metal", true)
	_box_batch(Vector3(w2 * 0.92, 0.018, 0.018), rope, pole, root, "metal")
	var fw2 := 0.52 / 3.0
	for fc: Color in by_color:
		_box_batch(Vector3(fw2, 0.40, 0.02), by_color[fc], fc, root, "",
			false, rot_by_color[fc])


## 第 i 面旗的颜色。取「红黄蓝绿」的低饱和循环 ——
## 高饱和的旗在端墙上一排会有点吵，但纯单色又不像应援。
func _flag_color(i: int) -> Color:
	var pal := [
		Color(0.560, 0.085, 0.095), Color(0.640, 0.430, 0.080),
		Color(0.070, 0.180, 0.480), Color(0.080, 0.330, 0.230),
		Color(0.480, 0.140, 0.360),
	]
	return pal[i % pal.size()]


# ───────────── 6.5 场地围栏 ─────────────
## 挡板外侧一圈护栏（竖杆 + 两道横杆 + 顶帽）。
##
## 有了它，挡板和看台之间不再是「一块板贴着台阶」，而是有一个
## 「有厚度」的缓冲区。远看挡板边缘会有一排细密的竖线，
## 那是「场馆」和「盒子」的分界线。
func _build_fence() -> void:
	if not fence_enabled:
		return
	var root := Node3D.new()
	root.name = "Fence"
	add_child(root)

	var bx := floor_half_x - barrier_inset
	var bz := floor_half_z - barrier_inset
	var y0 := barrier_height - 0.05    # 从挡板顶略微往下接
	var y1 := fence_h

	# 四条边的横杆 + 竖杆。
## ★ 全合批：4 边 × (2 横杆 + ~50 竖杆 + 1 顶帽) = 200+ 个盒子，
##   合成 3 个 MultiMesh（横杆 / 竖杆 / 顶帽）而不是 200 个节点。
	var posts: Array = []
	var caps: Array = []
	var cap_x: Array = []
	var edges := [
		{"d": Vector3(0, 0, 1), "off": Vector3(bx + 0.10, 0, 0), "len": bz * 2.0 + 0.4},
		{"d": Vector3(0, 0, 1), "off": Vector3(-bx - 0.10, 0, 0), "len": bz * 2.0 + 0.4},
		{"d": Vector3(1, 0, 0), "off": Vector3(0, 0, bz + 0.10), "len": bx * 2.0 + 0.4},
		{"d": Vector3(1, 0, 0), "off": Vector3(0, 0, -bz - 0.10), "len": bx * 2.0 + 0.4},
	]
	for e: Dictionary in edges:
		var dir: Vector3 = e["d"]
		var off: Vector3 = e["off"]
		var ln: float = e["len"]
		# 竖杆
		var n := maxi(4, int(ln / 0.62))
		for i in range(n + 1):
			var t := -ln * 0.5 + ln * float(i) / float(n)
			var p := off + dir * t
			posts.append(Vector3(p.x, (y0 + y1) * 0.5, p.z))
		# 顶帽（沿 X 的那两条单独收，尺寸不同不能同批）
		if dir.x == 0.0:
			caps.append(off + Vector3(0, y1 + 0.03, 0))
		else:
			cap_x.append({"p": off + Vector3(0, y1 + 0.03, 0), "len": ln})

	# 横杆 / 顶帽沿 Z 和沿 X 两种朝向、两种长度 → 分 4 组合批
	var zs: Array = []
	var xs: Array = []
	for e2: Dictionary in edges:
		var dir2: Vector3 = e2["d"]
		var off2: Vector3 = e2["off"]
		var ln2: float = e2["len"]
		for ry2: float in [y0 + (y1 - y0) * 0.5, y1]:
			var p3 := off2 + Vector3(0, ry2, 0)
			if dir2.x == 0.0:
				zs.append({"p": p3, "len": ln2})
			else:
				xs.append({"p": p3, "len": ln2})
	# 逐条合批（长度每条都不同，但只有 4 条边 → 8 个批次，节点数仍是常数级）
	for d3: Dictionary in zs:
		_box(Vector3(0.035, 0.035, float(d3["len"])), d3["p"], fence_color,
			root, false, false, "metal")
	for d4: Dictionary in xs:
		_box(Vector3(float(d4["len"]), 0.035, 0.035), d4["p"], fence_color,
			root, false, false, "metal")
	_box_batch(Vector3(0.040, y1 - y0, 0.040), posts, fence_color, root, "metal", true)
	_box_batch(Vector3(0.06, 0.05, 1.0), caps, fence_color.lightened(0.25),
		root, "metal")
	for d5: Dictionary in cap_x:
		_box(Vector3(float(d5["len"]), 0.05, 0.06), d5["p"],
			fence_color.lightened(0.25), root, false, false, "metal")


## 露天判定。天花板被主题抬到这个高度以上就等于「没有顶」。
## 18.0 是分界：室内馆最高也只到 11（奥运馆），抬到 18 显然是为了「不建顶」。
@export var open_sky_height: float = 18.0


func _is_open_sky() -> bool:
	return ceiling_height >= open_sky_height


## 场地边界 X（看台最外沿），露天灯杆要立在它外面。
func _arena_half_x() -> float:
	return floor_half_x + stand_gap + stand_rows * stand_row_d


# ───────────── 7. 天花板 ─────────────
## ★ 第四期：原来只有「一整块平板 + 5 根横梁」，远看就是一个仓库屋顶。
##   现在改成真正的**空间桁架**：主梁 + 上下弦 + 之字腹杆 + 竖向吊杆，
##   再加环形跑马灯（灯带）。桁架是「结构」，
##   换了场馆主题它也在 —— 但正是它把顶面从空板变成一个空间。
##
## ★★ 露天主题（ceiling_height 被设成很大）走另一条路：**完全不建顶**。
##   之前只会把天花板抬到 30m —— 结果玩家抬头看见一个悬在空中的
##   巨大平板，比有顶还怪。现在用 _is_open_sky() 判掉。
func _build_ceiling() -> void:
	if _is_open_sky():
		return
	var hx := floor_half_x + stand_gap + stand_rows * stand_row_d + 1.2
	var hz := floor_half_z + 1.6
	# cast_shadow = false 是关键：天花板如果投影，方向光会被它整个挡掉，
	# 场地上会出现一片巨大黑影（室内场景最容易踩的坑）。
	_box(Vector3(hx * 2.0, 0.40, hz * 2.0),
		Vector3(0.0, ceiling_height, 0.0), ceiling_color, self, false)

	if not ceiling_truss_enabled:
		# 老路径：只有 5 根实心横梁
		var n := 5
		for i in range(n):
			var z := -hz + 2.0 * hz * (float(i) + 0.5) / float(n)
			_box(Vector3(hx * 2.0, 0.22, 0.30),
				Vector3(0.0, ceiling_height - 0.30, z),
				ceiling_color.darkened(0.45), self, false)
		return

	_build_truss(hx, hz)


## 桁架组：沿 Z 排若干榀，每榀沿 X 跨越整个场馆。
##
## 每榀由「上下弦杆 + 之字腹杆 + 竖向腹杆」组成 —— 这才是钢桁架的形状。
## 用细杆（0.06~0.09）而不是实心板：远处的桁架靠的是**镂空剪影**，
## 实心板在那个距离只会糊成一条黑带。
func _build_truss(hx: float, hz: float) -> void:
	var root := Node3D.new()
	root.name = "Trusses"
	add_child(root)

	var steel := truss_color
	var y_top := ceiling_height - 0.34
	var depth := truss_depth
	var bays := 7                       # 沿 X 分7 跨
	var n_truss := 6                # 沿 Z 排6 榀
	var x0 := -hx + 1.0
	var x1 := hx - 1.0
	var dx := (x1 - x0) / float(bays)

	for t in range(n_truss):
		var z := -hz + 2.0 * hz * (float(t) + 0.5) / float(n_truss)
		# 上下弦杆（沿 X 通长）
		_box(Vector3(x1 - x0, 0.085, 0.16), Vector3((x0 + x1) * 0.5, y_top, z), steel, root, false, false, "metal")
		_box(Vector3(x1 - x0, 0.085, 0.16), Vector3((x0 + x1) * 0.5, y_top - depth, z), steel, root, false, false, "metal")
		# 之字腹杆：每跨一段斜杆，交替上下
		for b in range(bays):
			var bx := x0 + dx * float(b)
			var up := (b % 2 == 0)
			var ya := y_top if up else y_top - depth
			var yb := y_top - depth if up else y_top
			# 斜杆用旋转的细长盒：绕 Y 之外还要绕 Z，做成真正的斜撑。
			var seg := Vector3(dx, yb - ya, 0.0)
			var bar := _box(Vector3(seg.length(), 0.055, 0.10),
				Vector3((bx + dx * 0.5), (ya + yb) * 0.5, z), steel, root, false, false, "metal")
			bar.rotation.z = atan2(seg.y, seg.x)
			# 竖向腹杆
			_box(Vector3(0.055, depth, 0.09), Vector3(bx + dx * 0.5, y_top - depth * 0.5, z),
				steel, root, false, false, "metal")

	# 纵向连系梁（把6 榀串起来，桁架才是一个整体而不是一排筷子）
	for b in range(bays + 1):
		var bx2 := x0 + dx * float(b)
		_box(Vector3(0.07, 0.07, hz * 2.0 - 1.0), Vector3(bx2, y_top - depth, 0.0),
			steel.darkened(0.2), root, false, false, "metal")

	# 跑马灯带：桁架下弦挂一圈灯带，室内球馆都有。
	if truss_lightstrip_enabled:
		var strip := light_color.lerp(Color(1, 1, 1), 0.35)
		for b2 in range(bays):
			var bx3 := x0 + dx * (float(b2) + 0.5)
			_box(Vector3(dx * 0.62, 0.05, 0.05),
				Vector3(bx3, y_top - depth - 0.12, 0.0), strip, root, false, true)


## 顶棚灯组。灯的数量按渲染后端给上限（gl_compatibility 对同一物体
## 能接受的实时光源数有限，太多会出现「某些面忽然不被照亮」），
## 所以灯**模型**可以多，**实时光源**只给 4 盏。
func _build_lights() -> void:
	var root := Node3D.new()
	root.name = "CeilingLights"
	add_child(root)

	# ★ 露天：改建灯杆阵列。吊灯挂在天上是没有顶的地方挂不住的。
	if _is_open_sky():
		_build_floodlight_masts(root)
		return

	var y := ceiling_height - 0.9
	var spots := [
		Vector3(-4.2, y, -4.2), Vector3(4.2, y, -4.2),
		Vector3(-4.2, y, 4.2), Vector3(4.2, y, 4.2),
	]
	for p: Vector3 in spots:
		var l := OmniLight3D.new()
		l.position = p
		l.light_color = light_color
		l.light_energy = light_energy
		l.omni_range = light_range
		l.omni_attenuation = 0.85
		l.shadow_enabled = false
		root.add_child(l)

		# ── 灯具体（吊在桁架下的灯盘） ──
		_build_lamp_fixture(p, root)

	# 灯盘之间用桁架连起来的「灯桥」，让顶面不是孤零零四个点。
	if truss_lightstrip_enabled:
		for sz: float in [-1.0, 1.0]:
			_box(Vector3(8.6, 0.06, 0.10),
				Vector3(0.0, y + 0.20, sz * 4.2), Color(0.20, 0.21, 0.24), root,
				false, false, "metal")


## 露天候馆的**灯杆阵列**：4 根高杆，各顶一个横向灯排。
##
## ★ 这是「露天」这个形态最关键的构件 —— 没有它，露天馆就是一块
##   露天的空地加一个悬空平板。有了它，玩家一眼就知道这是户外场地。
##   真实球馆的灯杆是「一根高杆 + 顶端横着一排灯箱」，
##   所以这里也做成横排灯箱（3 个一组），不是顶着一个球。
func _build_floodlight_masts(root: Node3D) -> void:
	var hx := _arena_half_x() + 1.6
	var hz := floor_half_z + 2.4
	var mast_h := 11.5
	var pole := Color(0.260, 0.270, 0.290)
	var housing := Color(0.190, 0.200, 0.220)
	var glow := light_color.lerp(Color(1, 1, 1), 0.55)

	# 四角各一根。灯头朝场地中心斜下方 —— 灯箱会随朝向翻一点，
	# 纯平放会看着像「有人在半空放了块板子」。
	var spots := [
		Vector3(-hx, 0.0, -hz), Vector3(hx, 0.0, -hz),
		Vector3(-hx, 0.0, hz), Vector3(hx, 0.0, hz),
	]
	for p: Vector3 in spots:
		# 灯杆（分两节，接出一节明显的「接缝」）
		_cyl(0.13, mast_h * 0.55, p + Vector3(0, mast_h * 0.275, 0), pole, root, "metal", 8)
		_cyl(0.095, mast_h * 0.48, p + Vector3(0, mast_h * 0.76, 0),
			pole.darkened(0.12), root, "metal", 8)
		# 基座
		_box(Vector3(0.62, 0.28, 0.62), p + Vector3(0, 0.14, 0),
			pole.darkened(0.25), root, false, false, "metal")
		# 灯头横梁
		var inward := Vector3(-signf(p.x), 0.0, -signf(p.z)).normalized()
		var yaw := atan2(inward.x, inward.z)
		var head := _box(Vector3(2.30, 0.16, 0.22),
			p + Vector3(0, mast_h * 0.96, 0) + inward * 0.5,
			housing, root, false, false, "metal")
		head.rotation.y = yaw
		# 灯箱 ×3（沿横梁排开）
		for k in range(3):
			var off := Vector3(float(k - 1) * 0.76, -0.24, 0.0)
			off = off.rotated(Vector3.UP, yaw)
			var lamp := _box(Vector3(0.62, 0.30, 0.34),
				p + Vector3(0, mast_h * 0.96, 0) + inward * 0.5 + off,
				housing, root, false, false, "metal")
			lamp.rotation.y = yaw
			# 发光面（朝下偏内）
			var face := _box(Vector3(0.54, 0.05, 0.26),
				lamp.position + Vector3(0, -0.17, 0), glow, root, false, true)
			face.rotation.y = yaw
		# 实时光源放在灯头处（仍然是 4 盏，别突破后端上限）
		var l := OmniLight3D.new()
		l.position = p + Vector3(0, mast_h * 0.90, 0) + inward * 0.8
		l.light_color = light_color
		l.light_energy = light_energy
		l.omni_range = light_range * 1.35
		l.omni_attenuation = 0.85
		l.shadow_enabled = false
		root.add_child(l)


## 单盏灯的具体造型：灯盘 + 发光面 + 吊杆 + 侧翼反光罩。
##
## ★ 原来只有一个 1.5×1.5 的自发光方块 —— 在俯视时它就是「一个白点」，
##   看不出是灯。现在补出灯盘 + 侧翼，才像真的顶棚灯。
func _build_lamp_fixture(p: Vector3, root: Node3D) -> void:
	var housing := Color(0.155, 0.165, 0.185)
	var glow := light_color.lerp(Color(1, 1, 1), 0.55)
	# 灯盘（比发光面大一圈，形成灯罩的边）
	_box(Vector3(1.72, 0.10, 1.72), p + Vector3(0.0, 0.22, 0.0), housing, root,
		false, false, "metal")
	# 发光面
	_box(Vector3(1.48, 0.05, 1.48), p + Vector3(0.0, 0.15, 0.0), glow, root, false, true)
	# 四片侧翼反光罩，把光「兜」住
	for sx: float in [-1.0, 1.0]:
		var w := _box(Vector3(0.05, 0.26, 1.68), p + Vector3(sx * 0.85, 0.30, 0.0),
			housing, root, false, false, "metal")
		w.rotation.z = sx * 0.28
	for sz: float in [-1.0, 1.0]:
		var w2 := _box(Vector3(1.68, 0.26, 0.05), p + Vector3(0.0, 0.30, sz * 0.85),
			housing, root, false, false, "metal")
		w2.rotation.x = -sz * 0.28
	# 吊杆（四根，斜着往上收到桁架）
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var rod := _box(Vector3(0.045, 0.80, 0.045),
				p + Vector3(sx * 0.62, 0.72, sz * 0.62), housing, root, false, false, "metal")
			rod.rotation.z = -sx * 0.16
			rod.rotation.x = sz * 0.16


# ───────────── 8.6 场边器材 ─────────────
## 球台周边的那一圈东西：裁判台、擦汗台、球员凳、器材箱。
##
## ★ 这批是**性价比最高**的一批构件：离玩家只有 2~4m，
##   玩家整个比赛都在看这块地方。原来这里除了球台什么都没有，
##   所以「球台漂在一片空地上」—— 感觉不像场地，像模型预览。
##
## ★★ 位置按 ITTF 实际布局（第一版摆错了，实拍才发现）：
##   · 裁判台在**端头**（球台中线延长线上、对手半区那一侧）——
##     裁判必须能看到整个台面的两侧落点，站在腰侧是看不见近端下网的。
##     而且只有**一座**，不是左右各一座。
##   · 擦汗台在侧面腰处（球员退场走的那一侧）。
##   · 器材箱贴挡板根，不挡视线。
##   · 替补席长凳在**端头两侧**（不是中线上）—— 原来摆在 x=0，
##     和裁判台一样都在中线上，两件家具自己就穿模了（z 范围
##     -2.81~-2.43 与 -2.56~-2.28 重叠），而且正好压在玩家活动区上。
##
## ★★★ 第六期重排：用户要求「扩大玩家活动区域，把椅子后移」。
##   **所有位置不再写死，而是由 `player_reach_*` + 家具自身半宽算出来**：
##     目标内沿 = 玩家可达边界 + 碰撞盒半宽 + prop_clearance
##   这样以后再放宽 player_movement.gd 的活动范围，只需改本文件顶部的
##   三个 player_reach_* 副本，家具自动让开，不会漏掉某一处。
func _build_sideline_props() -> void:
	var root := Node3D.new()
	root.name = "SidelineProps"
	add_child(root)

	# ── 由活动边界推出「家具内沿该在哪」──
	# 玩家身体实际能占到的范围（碰撞盒比钳制点再宽一圈）
	var body_x := player_reach_x + player_body_half
	var body_z_max := player_reach_z_max + player_body_half
	# 侧面家具：内沿要在身体之外再加 clear
	var side_clear_x := body_x + prop_clearance
	# 端头家具：同理，且要同时避开「身后」方向
	var end_clear_z := body_z_max + prop_clearance

	# 裁判台：端头，中线延长线上 —— 站在球台对面那侧俯视整个台面。
	# 对手半区玩家本来就过不去（player_reach_z_min = 0.685），但仍按同一公式
	# 摆，这样换边/加 AI 时也不会撞。
	_build_umpire_chair(0.0, -end_clear_z - 0.62, root)

	# 擦汗台：侧面腰处（两侧各一，这是真实球馆的布置）
	for sx: float in [-1.0, 1.0]:
		_build_towel_bench(sx * (side_clear_x + 0.20), 0.35, sx, root)
		_build_kit_box(sx * (side_clear_x + 0.40), -1.85, sx, root)

	# 替补席长凳：**端头两侧**，每侧一条，沿 Z 摆开、朝向球场。
	# ★ 原来摆在 x=0 的中线上（两件家具互相穿模），现在挪到 x = ±side_clear_z。
	#   朝向也跟着改：长凳原本是「沿 X 摆、靠背在 ±z」，端头摆就得转 90°，
	#   否则靠背会朝着球台、坐下的人得背对比赛 —— 实拍会立刻看出来。
	for sx2: float in [-1.0, 1.0]:
		for sz2: float in [-1.0, 1.0]:
			_build_player_bench(sx2 * (end_clear_z + 0.86), sz2 * 2.30,
				sx2, root)

	# 球台正下方的地胶贴标：一块浅色区域 + 一圈边 —— 真实球馆
	# 会在球台四周铺一块颜色略浅的「比赛区」地胶。
	# ★ 尺寸跟着活动范围走：贴标必须盖住玩家能走到的每一处，
	#   否则玩家退到边界时会站在「浅色贴标之外」，看着像走出比赛区。
	var pad_x := body_x + 0.35
	var pad_z := body_z_max + 0.30
	_box(Vector3(pad_x * 2.0, 0.008, pad_z * 2.0), Vector3(0.0, 0.005, 0.0),
		court_color.lightened(0.10), root, false, true)
	# 贴标外沿的细白框
	for dx: float in [-1.0, 1.0]:
		_box(Vector3(0.04, 0.010, pad_z * 2.0), Vector3(dx * pad_x, 0.007, 0.0),
			line_color.darkened(0.15), root, false, true)
	for dz: float in [-1.0, 1.0]:
		_box(Vector3(pad_x * 2.0, 0.010, 0.04), Vector3(0.0, 0.007, dz * pad_z),
			line_color.darkened(0.15), root, false, true)


## 裁判台：高脚凳 + 台面 + 挡板 + 一把小靠背。
## 台面高 umpire_h，底下四条细腿 —— 细腿（而不是实心块）是它看起来像「家具」的关键。
##
## ★ 尺寸收窄到0.42 × 0.36（第一版做成 0.62 × 0.52，在 2.3m 外看过去
##   像一张办公桌，两侧各一座直接把画面框死了）。
func _build_umpire_chair(x: float, z: float, root: Node3D) -> void:
	var top := umpire_h
	# 台面
	_box(Vector3(0.44, 0.045, 0.38), Vector3(x, top, z), prop_color.lightened(0.25),
		root, false, false, "metal")
	# 挡板（朝球台那侧的围边）
	_box(Vector3(0.44, 0.15, 0.035), Vector3(x, top + 0.095, z - signf(z) * 0.17),
		prop_pad_color, root)
	# 四条腿
	for dx: float in [-1.0, 1.0]:
		for dz: float in [-1.0, 1.0]:
			_cyl(0.020, top, Vector3(x + dx * 0.17, top * 0.5, z + dz * 0.14),
				Color(0.30, 0.31, 0.34), root, "metal", 6)
	# 横撑（两条，把四条腿连起来 —— 只有腿没有撑会像「四根筷子」）
	for dz2: float in [-1.0, 1.0]:
		_box(Vector3(0.36, 0.026, 0.026),
			Vector3(x, top * 0.32, z + dz2 * 0.14), Color(0.28, 0.29, 0.32),
			root, false, false, "metal")
	# 座垫（小方块）
	_box(Vector3(0.34, 0.06, 0.30), Vector3(x, top + 0.055, z), prop_pad_color, root)
	# 靠背
	_box(Vector3(0.34, 0.24, 0.04), Vector3(x, top + 0.20, z + signf(z) * 0.15),
		prop_color.lightened(0.10), root)
	# 台面下的小挂钩
	_box(Vector3(0.24, 0.026, 0.026), Vector3(x, top - 0.06, z), Color(0.35, 0.36, 0.39),
		root, false, false, "metal")


## 擦汗台：低矮长条台 + 一条搭在上面的毛巾（浅色薄片，斜挂着）。
## ★ 尺寸同样收窄（第一版 0.52×0.86 太宽，看着像货架）。
func _build_towel_bench(x: float, z: float, sx: float, root: Node3D) -> void:
	var h := 0.50
	_box(Vector3(0.40, 0.04, 0.72), Vector3(x, h, z), prop_color.lightened(0.18),
		root, false, false, "metal")
	for dx: float in [-1.0, 1.0]:
		_cyl(0.022, h, Vector3(x + dx * 0.14, h * 0.5, z), Color(0.30, 0.31, 0.34),
			root, "metal", 6)
	# 毛巾（一块浅色斜挂的薄片）
	var towel := _box(Vector3(0.026, 0.30, 0.34), Vector3(x, h - 0.11, z),
		Color(0.86, 0.87, 0.90), root)
	towel.rotation.x = 0.22
	# 台下层板（放水瓶）
	_box(Vector3(0.34, 0.026, 0.62), Vector3(x, h * 0.32, z),
		prop_color.darkened(0.15), root, false, false, "metal")
	# 几个水瓶（圆柱 + 瓶盖）
	for i in range(3):
		var bz := z - 0.20 + float(i) * 0.20
		_cyl(0.032, 0.18, Vector3(x, h * 0.32 + 0.11, bz),
			Color(0.30, 0.55, 0.75), root, "glass", 7)
		_cyl(0.019, 0.030, Vector3(x, h * 0.32 + 0.21, bz),
			Color(0.85, 0.30, 0.25), root, "glass", 6)


## 器材箱：一个带盖的方箱 + 侧面的提手 + 顶上一条横带。
## 尺寸 0.62 × 0.40 × 0.42（第一版 0.78 太长，像个行李箱）。
func _build_kit_box(x: float, z: float, sx: float, root: Node3D) -> void:
	var w := 0.62
	var h := 0.40
	var d := 0.42
	# 箱体
	_box(Vector3(w, h, d), Vector3(x, h * 0.5, z), prop_color.darkened(0.10), root)
	# 盖（比箱体大一点，做出「盖子」的层次）
	_box(Vector3(w + 0.04, 0.05, d + 0.04), Vector3(x, h + 0.02, z),
		prop_color.lightened(0.20), root, false, false, "metal")
	# 横带
	_box(Vector3(w + 0.05, 0.04, 0.05), Vector3(x, h + 0.05, z), prop_pad_color, root)
	# 侧提手
	_box(Vector3(0.04, 0.04, 0.18), Vector3(x - sx * (w * 0.5 + 0.015), h * 0.72, z),
		Color(0.34, 0.35, 0.38), root, false, false, "metal")
	# 脚
	for dx: float in [-1.0, 1.0]:
		_box(Vector3(0.07, 0.04, d), Vector3(x + dx * (w * 0.5 - 0.05), 0.02, z),
			Color(0.20, 0.21, 0.23), root)


## 替补席长凳：一条坐板 + 两条腿 + 靠背横板 + 一条搭着的毛巾。
## ★ 长度 1.55（第一版 1.90，两侧摆两条反而把画面下缘堵满了）。
##
## ★★ 第六期改了朝向与摆法。原来参数叫 `sz`、长凳沿 X 摆、靠背在 ±z，
##   摆在端头中线上 —— 于是它和裁判台两件家具自己就穿模了（长凳 z 范围
##   -2.56~-2.28，裁判台 -2.81~-2.43，重叠 0.13m），而且长凳还正好压在
##   玩家活动区的 z 上限上。
##   现在长凳沿 **Z** 摆（顺着端线），靠背在 `sx` 那一侧（背朝外、朝向球场），
##   摆在端头的**左右两侧**。参数名从 `sz` 改成 `sx` 就是这个原因 ——
##   沿用旧名会让人以为它还管 z 方向。
func _build_player_bench(x: float, z: float, sx: float, root: Node3D) -> void:
	var h := 0.42
	var ln := 1.55
	# 坐板（沿 Z 摆：长度在 z，深度在 x）
	_box(Vector3(0.28, 0.06, ln), Vector3(x, h, z), prop_color.lightened(0.15),
		root, false, false, "metal")
	# 靠背（在远离球场的那一侧 = sx 方向）
	_box(Vector3(0.04, 0.22, ln), Vector3(x + sx * 0.13, h + 0.23, z),
		prop_color.darkened(0.05), root)
	# 靠背立柱
	for dz: float in [-1.0, 1.0]:
		_box(Vector3(0.045, 0.30, 0.045), Vector3(x + sx * 0.13,
			h + 0.14, z + dz * (ln * 0.5 - 0.07)),
			Color(0.30, 0.31, 0.34), root, false, false, "metal")
	# 腿
	for dz2: float in [-1.0, 1.0]:
		_box(Vector3(0.24, h, 0.05), Vector3(x, h * 0.5, z + dz2 * (ln * 0.5 - 0.10)),
			Color(0.28, 0.29, 0.32), root, false, false, "metal")
	# 坐垫
	_box(Vector3(0.23, 0.045, ln - 0.09), Vector3(x, h + 0.055, z), prop_pad_color, root)
	# 搭着的毛巾（一端垂下来）
	_box(Vector3(0.026, 0.26, 0.26), Vector3(x + sx * 0.09, h - 0.07, z - ln * 0.30),
		Color(0.84, 0.85, 0.88), root)


# ───────────── 8.5 远景天际线 ─────────────
## 场馆外一圈的城市剪影。**只在露天主题建** —— 室内馆被天花板和端墙
## 围死了，抬头只能看见顶，远处放楼反而奇怪。
##
## 全用 MultiMesh：60+ 栋楼 × (1 楼体 + 1 顶灯) 会是上百个 MeshInstance3D，
## 合批之后只有2 个 draw call。远处的楼不需要任何细节 ——
## 它的作用是给天空一条**地平线**，让露天场馆不至于「空到像没做完」。
func _build_skyline() -> void:
	if not _is_open_sky():
		return
	var root := Node3D.new()
	root.name = "Skyline"
	add_child(root)

	var n := 46
	var r := skyline_radius

	# ── 楼体 ──
	var body := BoxMesh.new()
	body.size = Vector3.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = body
	mm.instance_count = n

	# ── 顶灯（夜里那一排红点，是「城市在远处」的最好提示） ──
	var beacon := BoxMesh.new()
	beacon.size = Vector3.ONE
	var bm := MultiMesh.new()
	bm.transform_format = MultiMesh.TRANSFORM_3D
	bm.mesh = beacon
	bm.instance_count = n

	for i in range(n):
		# 环形排布，留一个角度缺口（玩家初始视角朝 -z，缺口放那里更远）
		var ang := TAU * float(i) / float(n) + 0.13
		var dist := r * _rng.randf_range(0.86, 1.22)
		var x := sin(ang) * dist
		var z := cos(ang) * dist
		# 高度分布：中间高、两边低（像真的城市天际线），再加随机抖动
		var h := skyline_height * _rng.randf_range(0.35, 1.15) \
			* (0.72 + 0.28 * absf(sin(ang * 2.3)))
		var w := _rng.randf_range(6.0, 13.0)
		var d := _rng.randf_range(6.0, 13.0)
		var basis := Basis(Vector3.UP, ang + _rng.randf_range(-0.25, 0.25))
		mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3(w, h, d)),
			Vector3(x, h * 0.5, z)))
		# 远景压暗+轻微偏蓝，和近景形成空气透视
		var v := _rng.randf_range(0.82, 1.16)
		mm.set_instance_color(i,
			Color(skyline_color.r * v, skyline_color.g * v, skyline_color.b * v * 1.08))
		# 顶灯（只给一部分楼有，且偏暗 —— 远景的灯不能抢戏）
		if skyline_windows and _rng.randf() < 0.55:
			bm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(0.9, 0.9, 0.9)),
				Vector3(x, h + 0.5, z)))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "SkylineBodies"
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(Vector3(-r * 1.4, -2.0, -r * 1.4),
		Vector3(r * 2.8, skyline_height * 2.0, r * 2.8))
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.material_override = _mat2(skyline_color, "far")
	root.add_child(mmi)

	var bmi := MultiMeshInstance3D.new()
	bmi.name = "SkylineBeacons"
	bmi.multimesh = bm
	bmi.custom_aabb = mmi.custom_aabb
	bmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bmi.material_override = _mat2(skyline_window_color, "glow")
	root.add_child(bmi)

	# ── 地面延展：把场馆外圈的「地胶以外地面」一直铺到天际线脚下 ──
	# 不铺的话，露天候馆站在高台上会看到地板边缘悬空 —— 那是最出戏的一处。
	_box(Vector3(skyline_radius * 2.6, 0.30, skyline_radius * 2.6),
		Vector3(0.0, -0.42, 0.0), apron_color.darkened(0.30), root, false)


# ───────────── 供外部/自测查询 ─────────────
## 玩家可以活动的范围（主控用它限制「不能走到球台对面」）
func player_area() -> Dictionary:
	return {
		"x_abs": floor_half_x - 0.9,
		"z_min": 0.35,                     # 球网在自己前面，永远进不了对面半台
		"z_max": floor_half_z - 0.9,
	}

func crowd_count() -> int:
	var mmi := get_node_or_null("Crowd") as MultiMeshInstance3D
	if mmi == null or mmi.multimesh == null:
		return 0
	return mmi.multimesh.instance_count
