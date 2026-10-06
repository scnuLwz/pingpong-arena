class_name PingPongBall
extends Node3D
## 乒乓球（40mm，2.7g）—— 重力 + 空气阻力 + **台面弹跳** + 撞网
##
## 和羽毛球（shuttle.gd）的关键差别，别混用：
##   1. 阻力小得多：k ≈ 0.14（终速 √(g/k) ≈ 8.4 m/s），所以球能飞到 20~30 m/s；
##      羽毛球 k ≈ 0.218、终速只有 6.7 m/s。
##   2. **会在台面弹跳**（羽毛球落地就停）。这是乒乓球玩法的核心：
##      球必须先在己方台面弹一下，再被打过网落到对方台面。
##   3. 尺度差一个量级：台面 2.74 × 1.525 m、网高仅 0.1525 m、球半径 0.02 m。
##
## 台面顶面 y = table_height，球半径 radius，所以实际碰撞面在 y = table_height + radius。
##
## 碰撞用「上一帧位置 → 新位置」的线段与平面求交做连续检测：
## 球速 15 m/s 时一帧要走 0.25 m，逐点判断会直接穿过台面。

signal bounced_table(pos: Vector3, side: int)      # side: +1 玩家侧(z>0)，-1 对方侧
signal bounced_twice(pos: Vector3, side: int)      # 同一侧弹了两次 = 没接到
signal hit_net(pos: Vector3)                       # 撞网
signal landed_floor(pos: Vector3)                  # 落到地面（出界/死球）

# ───────────── 台面 / 球网几何（ITTF 标准）─────────────
@export_group("球台")
@export var table_half_length: float = 1.37     # 台长 2.74 / 2
@export var table_half_width: float = 0.7625    # 台宽 1.525 / 2
@export var table_height: float = 0.76          # 台面离地高度
@export var net_height: float = 0.1525          # 网高
@export var net_half_width: float = 0.915       # 网宽 1.83 / 2

# ───────────── 物理 ─────────────
@export_group("物理")
@export var gravity: float = 9.8
## 阻力系数。0.14 → 终速 ≈ 8.4 m/s（实测乒乓球终速约 9 m/s）
@export var drag_k: float = 0.14
@export var radius: float = 0.02                # 40mm 球
## 台面弹跳恢复系数（乒乓球在台面弹跳约 0.8~0.9）
@export var restitution: float = 0.85
## 弹跳时水平速度的摩擦保留
@export var table_friction: float = 0.88
## 旋转每次弹跳的衰减
@export var spin_decay: float = 0.55
## 上旋让球弹起后往前窜（弧圈球的手感）
@export var spin_bounce_kick: float = 0.35
## 马格努斯系数：上旋(+)下沉快，下旋(-)飘
@export var magnus_coeff: float = 0.012

# ───────────── 状态 ─────────────
var velocity: Vector3 = Vector3.ZERO
var _spin: float = 0.0          # >0 上旋，<0 下旋
var _flying: bool = false
var _mesh: Node3D
var _bounce_count: int = 0
var _last_bounce_side: int = 0


func _ready() -> void:
	_mesh = _build_ball()
	add_child(_mesh)


func _build_ball() -> Node3D:
	var root := Node3D.new()
	root.name = "BallMesh"
	var m := MeshInstance3D.new()
	m.name = "Ball"
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 16
	sm.rings = 12
	m.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.98, 0.98, 0.96, 1)
	mat.roughness = 0.35
	m.set_surface_override_material(0, mat)
	root.add_child(m)
	return root


# ───────────── 发射 / 停止 ─────────────
func launch(from: Vector3, vel: Vector3, spin: float = 0.0) -> void:
	global_position = from
	velocity = vel
	_spin = spin
	_flying = true
	_bounce_count = 0
	_last_bounce_side = 0
	visible = true


func stop() -> void:
	_flying = false
	velocity = Vector3.ZERO


## 「死球」：抽掉水平动力，让球自己坠到地面，而不是继续在台面上连弹几下。
##
## ★ 用户报的现象：「对方球碰到自己的桌子两次之后，球还在弹，不像死球」。
##   判分本身是对的（第二次同侧弹跳就发 bounced_twice → _on_bounced_twice 收分），
##   问题是**没人让球停下** —— 它照旧按自己的物理再弹 2~3 下才落地，
##   玩家看到「分加了、球还在跳」，自然会以为这一分没结束、还能再挥一拍。
##
## ★ 为什么不是直接 stop()：velocity 清零的同时 _flying 变 false，
##   _physics_process 立刻返回 —— 球会**僵在半空**，像卡住了。
##   这里保留垂直速度、只把水平速度打掉，球会原地坠下去，落地才自然结束。
func die() -> void:
	if not _flying:
		return
	velocity = Vector3(velocity.x * 0.12, velocity.y, velocity.z * 0.12)
	_spin = 0.0


func is_flying() -> bool:
	return _flying


func get_spin() -> float:
	return _spin


func set_spin(s: float) -> void:
	_spin = s


# ───────────── 每帧积分 ─────────────
func _physics_process(delta: float) -> void:
	if not _flying:
		return

	var acc := Vector3(0, -gravity, 0)
	var sp := velocity.length()
	if sp > 0.0001:
		acc -= velocity.normalized() * drag_k * sp * sp
	# 马格努斯：上旋把球往下压，下旋让球飘
	if absf(_spin) > 0.01:
		var hs := Vector2(velocity.x, velocity.z).length()
		acc.y -= _spin * magnus_coeff * hs

	velocity += acc * delta

	var prev := global_position
	var next := prev + velocity * delta

	# 顺序很重要：网 → 台面 → 地面
	if _cross_net(prev, next):
		return
	if _cross_table(prev, next):
		return

	if next.y <= radius:
		next.y = radius
		global_position = next
		_flying = false
		emit_signal("landed_floor", next)
		return

	global_position = next


func _cross_net(prev: Vector3, next: Vector3) -> bool:
	if (prev.z > 0.0) == (next.z > 0.0):
		return false
	var denom := prev.z - next.z
	if absf(denom) < 1e-9:
		return false
	var t := prev.z / denom
	var hit := prev.lerp(next, t)
	var lo := table_height - radius
	var hi := table_height + net_height + radius
	if absf(hit.x) <= net_half_width and hit.y >= lo and hit.y <= hi:
		# 撞网：球被挡下，几乎垂直掉落（后面会再触发 landed_floor）
		global_position = hit
		velocity = Vector3(velocity.x * 0.12, -0.5, velocity.z * 0.08)
		emit_signal("hit_net", hit)
		return true
	return false


func _cross_table(prev: Vector3, next: Vector3) -> bool:
	var top := table_height + radius
	if prev.y <= top or next.y > top:
		return false
	var denom := prev.y - next.y
	if denom < 1e-9:
		return false
	var t := (prev.y - top) / denom
	var hit := prev.lerp(next, t)
	if absf(hit.x) > table_half_width or absf(hit.z) > table_half_length:
		return false

	hit.y = top
	velocity.y = -velocity.y * restitution
	velocity.x *= table_friction
	velocity.z *= table_friction
	# 上旋让球弹起后往前窜
	velocity.z -= _spin * spin_bounce_kick
	_spin *= spin_decay
	global_position = hit

	var side := 1 if hit.z > 0.0 else -1
	if side == _last_bounce_side:
		_bounce_count += 1
	else:
		_bounce_count = 1
		_last_bounce_side = side

	emit_signal("bounced_table", hit, side)
	if _bounce_count >= 2:
		emit_signal("bounced_twice", hit, side)
	return true


# ───────────── 弹道预测（不改变球的状态）─────────────
## 模拟飞行，返回第一次接触（台面 / 网 / 地面）的信息。
## 返回字典：{"pos", "on_table", "net", "side", "time"}
func simulate_first_contact(from: Vector3, vel: Vector3, max_time: float = 5.0,
							dt: float = 1.0 / 120.0) -> Dictionary:
	var p := from
	var v := vel
	var t := 0.0
	var top := table_height + radius
	while t < max_time:
		var acc := Vector3(0, -gravity, 0)
		var sp := v.length()
		if sp > 0.0001:
			acc -= v.normalized() * drag_k * sp * sp
		v += acc * dt
		var np := p + v * dt
		t += dt

		# 台面
		if np.y <= top and absf(np.x) <= table_half_width \
			and absf(np.z) <= table_half_length:
			return {"pos": Vector3(np.x, top, np.z), "on_table": true,
					"net": false, "side": 1 if np.z > 0.0 else -1, "time": t}

		# 网
		if (p.z > 0.0) != (np.z > 0.0):
			var den := p.z - np.z
			if absf(den) > 1e-9:
				var f := p.z / den
				var hit := p.lerp(np, f)
				if absf(hit.x) <= net_half_width \
					and hit.y <= table_height + net_height + radius:
					return {"pos": hit, "on_table": false, "net": true,
							"side": 0, "time": t}

		if np.y <= radius:
			return {"pos": Vector3(np.x, radius, np.z), "on_table": false,
					"net": false, "side": 0, "time": t}
		p = np
	return {"pos": p, "on_table": false, "net": false, "side": 0, "time": t}


## 模拟飞行，返回穿过 z=0 时的高度；没穿过或提前落地返回 -1
func simulate_net_height(from: Vector3, vel: Vector3, max_time: float = 5.0,
						 dt: float = 1.0 / 120.0) -> float:
	var p := from
	var v := vel
	var t := 0.0
	var prev_z := p.z
	while t < max_time:
		var acc := Vector3(0, -gravity, 0)
		var sp := v.length()
		if sp > 0.0001:
			acc -= v.normalized() * drag_k * sp * sp
		v += acc * dt
		var np := p + v * dt
		t += dt
		if (prev_z) * (np.z) <= 0.0 and absf(np.z - prev_z) > 1e-9:
			var f := (0.0 - prev_z) / (np.z - prev_z)
			return lerpf(p.y, np.y, clampf(f, 0.0, 1.0))
		p = np
		prev_z = p.z
		if p.y <= radius:
			return -1.0
	return -1.0


## 模拟飞行，返回整条弧线的最高点（y）。
## 用来给发球「封顶」：只要水平速度太慢，解出来的抛物线就会一路飞向天花板，
## 而玩家眼高才 1.52 m —— 球出了画面上边就完全没法接。
func simulate_apex(from: Vector3, vel: Vector3, max_time: float = 5.0,
				   dt: float = 1.0 / 120.0) -> float:
	var p := from
	var v := vel
	var t := 0.0
	var top := from.y
	while t < max_time:
		var acc := Vector3(0, -gravity, 0)
		var sp := v.length()
		if sp > 0.0001:
			acc -= v.normalized() * drag_k * sp * sp
		v += acc * dt
		p += v * dt
		t += dt
		top = maxf(top, p.y)
		if p.y <= radius:
			break
	return top


## 全路径模拟（含弹跳 / 撞网 / 落地），返回 {"events": Array, "bounces": Array}。
##
## 和 _physics_process 用**同一套积分与判据**，只是不真的移动节点 ——
## 所以它是「发球合规性」的唯一可信真值来源：
##   events  形如 ["B1", "B-1"]    = 先弹己方(z>0)、再弹对方(z<0)，合法发球
##                 ["B-1"]         = 直接落在对方台（没先弹己方，不合规）
##                 ["NET", ...]    = 撞网
##                 ["FLOOR"]       = 出界落地
##   B 后面的数字是弹跳所在的半台：+1 = 玩家侧(z>0)、-1 = 对方侧(z<0)。
##   bounces 是每次台面弹跳的世界坐标（用来挑「第二跳最接近目标落点」的解）。
## ★★ `net_clearance`（2026-10-03）：**过网高度余量**（m），默认 0 = 严格照物理判。
##
##   存在的理由：`simulate_path` 是**离散步进**、真正的 `_physics_process` 是另一套步长，
##   两者在网面附近算出的过网高度会差几毫米。只差 3.5 mm 就足以让
##   「解算判定擦过（网顶 0.9325）」在物理里变成「落到 0.9290 撞网」——
##   球被削成垂直下落，**发球直接下网、白送对手一分**。
##
##   ★ 方向：**把网顶抬高**（判撞网的上界 +余量），不是压低。
##     压低 net_hi = 放宽撞网判定 = 擦边球照过 = 余量形同虚设（踩过）。
##     抬高才是「要求球比物理网顶再高一点才认它过关」，
##     解算器就会主动挑那些**真正高过网**的球道，而不是擦边赌一把。
##   ★ 步长对齐（serve_solve_dt = 1/60）才是根治，余量只用来吃掉剩下的
##     几毫米浮点/分支顺序差，1~3 mm 足够 —— 给大了会把「贴网短球」
##     这一整档全部毙掉（实测 22 mm → 18 个落点只接住 6 个）。
##   调用方：_solve_legal_serve（以及 _build_serve_traj，两者必须同值）。
##
## ★★ `stop_after_events`（2026-10-04，修「发球时一卡一卡」的第二刀）：
##   > 0 时，累计到这么多事件就立刻收工。**默认 0 = 跑满 max_time（原行为不变）**。
##
##   `_solve_legal_serve` 只关心「前两个事件是不是 B+1 → B-1」（`is_legal_serve`
##   只看 events[0] / events[1]）以及第二跳的坐标，所以它传 2。
##   不传的话：一发正常发球 `max_time = 2.5 s / dt = 1/60` = **150 步**，
##   而第二跳在第 ~66 步就已经落地了 —— 后面 80 多步纯属白算，
##   一个候选浪费 0.1 ms，180 个候选就是 18 ms。
##   ★ 对 `is_legal_serve` 的判定**完全等价**（它本来也只读前两个事件），
##     不是近似 —— 这正是它比「把 dt 放粗」更安全的地方。
func simulate_path(from: Vector3, vel: Vector3, spin: float = 0.0,
				   max_time: float = 3.0, dt: float = 1.0 / 120.0,
				   net_clearance: float = 0.0,
				   stop_after_events: int = 0) -> Dictionary:
	var p := from
	var v := vel
	var sp := spin
	var t := 0.0
	var top := table_height + radius
	var net_lo := table_height - radius
	var net_hi := table_height + net_height + radius + net_clearance
	var events: Array = []
	var bounces: Array = []
	while t < max_time:
		# ★ 收工判据放在循环头：NET 分支是 `continue`、台面分支也是 `continue`，
		#   放这里三种出口都覆盖得到，且只多跑一次循环头的比较。
		if stop_after_events > 0 and events.size() >= stop_after_events:
			break
		var acc := Vector3(0, -gravity, 0)
		var spd := v.length()
		if spd > 0.0001:
			acc -= v.normalized() * drag_k * spd * spd
		if absf(sp) > 0.01:
			var hs := Vector2(v.x, v.z).length()
			acc.y -= sp * magnus_coeff * hs
		v += acc * dt
		var prev := p
		var next := prev + v * dt

		# 网
		if (prev.z > 0.0) != (next.z > 0.0):
			var denom := prev.z - next.z
			if absf(denom) >= 1e-9:
				var f := prev.z / denom
				var hit := prev.lerp(next, f)
				if absf(hit.x) <= net_half_width and hit.y >= net_lo and hit.y <= net_hi:
					events.append("NET")
					v = Vector3(v.x * 0.12, -0.5, v.z * 0.08)
					p = hit
					t += dt
					continue
		# 台面
		if prev.y > top and next.y <= top:
			var denom2 := prev.y - next.y
			if denom2 >= 1e-9:
				var f2 := (prev.y - top) / denom2
				var hit2 := prev.lerp(next, f2)
				if absf(hit2.x) <= table_half_width and absf(hit2.z) <= table_half_length:
					hit2.y = top
					v.y = -v.y * restitution
					v.x *= table_friction
					v.z *= table_friction
					v.z -= sp * spin_bounce_kick
					sp *= spin_decay
					p = hit2
					events.append("B%d" % (1 if hit2.z > 0.0 else -1))
					bounces.append(hit2)
					t += dt
					continue
		if next.y <= radius:
			events.append("FLOOR")
			return {"events": events, "bounces": bounces}
		p = next
		t += dt
	return {"events": events, "bounces": bounces}


## 从事件序列里判断「是不是一次合规发球」。
## 合规 = 第一跳在己方半台、之后不撞网、第二跳在对方半台。
## server_side：+1 = 玩家发球（己方 z>0），-1 = 对手发球（己方 z<0）。
func is_legal_serve(events: Array, server_side: int) -> bool:
	if events.size() < 2:
		return false
	if not (events[0] as String).begins_with("B"):
		return false
	var own := "B%d" % server_side
	var opp := "B%d" % (-server_side)
	if events[0] != own:
		return false
	return events[1] == opp


## 求初速度：让球从 from 出发、落到 target 附近（首次接触 = 台面）。
##
## ★ 这里换过一次算法，原因是一个实测出来的**发散 bug**：
##
##   旧实现是「无阻力粗估 + 迭代修正」：v += (target − 首次接触点) / flight_time。
##   飞行时间一短（爆冲满蓄力 = 0.26 s），修正量就被放大 1/0.26 ≈ 3.8 倍，
##   而高速下空气阻力（drag_k·v²，v=40 时高达 220 m/s²）把实际位移压得很死 ——
##   迭代失去收敛性，越算越快。实测 from=(0,0.91,1.62) target=(0,0.78,−0.97)：
##     t=0.45 → 7.63 m/s（正常）
##     t=0.26 → 39.8 m/s（真实需求约 11 m/s）
##   更糟的是：39.8 m/s 的球「恰好」能过网，于是 pingpong_game._solve_return
##   的过网检查直接放行了它 —— 玩家满蓄力爆冲打出来的是一颗 42 m/s 的瞬移球。
##
##   新算法：**先定方向，只对速度大小做二分**。
##   落点（首次接触的 z）对速度大小是单调的（越快飞得越远），
##   所以二分必定收敛，而且天然不会「越算越快」。
##   打网 / 提前落地一律算「还没飞到」，往快的一侧走。
## search_dt：内部「找第一次接触」用的步长。默认 1/120 是留给**回球落点**的精度。
##
## ★ 发球解算器（pingpong_game._solve_legal_serve）可以把 search_dt 放粗到 1/60：
##   它调本函数只是为了给二分提供「落点 z 单调于速度大小」这个比较量，
##   而解出来的速度**随后还要过 simulate_path(dt = serve_solve_dt) 的合规校验** ——
##   合法性不由这里判定。
##   粗一档 = 子模拟步数减半。实测发球解算 150 ms → 35 ms，
##   代价只是首跳落点估计偏几毫米。
func solve_velocity(from: Vector3, target: Vector3, flight_time: float,
					iterations: int = 16, search_dt: float = 1.0 / 120.0) -> Vector3:
	var t := maxf(flight_time, 0.05)
	# 方向：拿无阻力解析解的方向当搜索方向（它已经是「朝 target 且带正确抬升」的）
	var g0 := (target - from) / t
	g0.y += 0.5 * gravity * t
	if g0.length_squared() < 0.25:
		return g0
	var dir := g0.normalized()
	var base := maxf(g0.length(), 1.0)

	# ★ 飞行的 z 方向：+1 = 球朝 z 增大飞（对手击球），-1 = 朝 z 减小飞（玩家击球）。
	#   二分要判「有没有打过头」，而「过头」是相对飞行方向说的：
	#   对手回球落在 z=0.5（比目标 0.9 更靠网）是**没打够**，
	#   玩家回球落在 z=-1.3（比目标 -0.9 更靠底线）才是**打过头**。
	#   旧实现把这条判据写死成「p.z < target.z 即过头」（即假定永远是玩家那个方向），
	#   于是对手的每一板都被二分压成「刚好擦网落台」的最短球 ——
	#   实测对手回球第一落点恒在 z=0.25~0.66，玩家永远接不到。
	var dz := signf(target.z - from.z)

	var best_v := dir * base
	var best_err := 1e9
	# 三轮「二分大小 → 用落点误差校正方向」交替，方向与大小都会收敛
	for _outer in range(3):
		var lo := 0.15
		var hi := 3.50
		for _i in range(iterations):
			var s := 0.5 * (lo + hi)
			var v := dir * (base * s)
			var r := simulate_first_contact(from, v, 3.0, search_dt)
			var p: Vector3 = r["pos"]
			var on_table := bool(r["on_table"])
			var err := Vector3(target.x - p.x, 0.0, target.z - p.z)
			if on_table and err.length() < best_err:
				best_err = err.length()
				best_v = v
			# 「打过头的」= 沿飞行方向越过目标落点。落在台外（飞出底线 / 侧线落地）
			# 也走同一判据：z 越过目标即算过头，往慢的一侧收。
			# ★ 早先只判「落台且 err.z > 0」，把「飞出底线」误当成「太慢」，二分卡死。
			var overshoot := (p.z - target.z) * dz > 0.0
			if overshoot:
				hi = s
			else:
				lo = s
		# 用当前最好解的落点误差，反过来修方向（水平误差 / 飞行时间 ≈ 速度增量）
		var rc: Dictionary = simulate_first_contact(from, best_v, 3.0, search_dt)
		var lp: Vector3 = rc["pos"]
		var corr := Vector3((target.x - lp.x) / t, 0.0, (target.z - lp.z) / t)
		dir = (best_v + corr).normalized()
		base = maxf(best_v.length(), 1.0)
	return best_v
