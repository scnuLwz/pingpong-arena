extends Node
## 一次性探针：量「旋球 → 对手触球高度 → 扣杀概率」以及「各击球方式的真实球速」。
##
## ★ **不进** run_regression.sh（同 tests/_perf_probe.tscn）。
## 跑法：
##   <godot_console> --headless --path . tests/_spin_probe.tscn --fixed-fps 60
##
## ── 为什么要有它 ──
## 用户提出：「旋球可以减少对方的扣球概率，但是球速更慢。」
##
## 但扣杀概率的判定函数 `opp_smash_chance_at(h)` **只看触球高度**、不读旋球，
## 所以这条因果若存在，只能是**间接**的：上旋吃马格努斯下沉（acc.y -= spin * …）
## → 球在对手拍面平面处更低 → 触球高度更低 → 扣杀概率更低。
##
## 到底有多强、够不够被玩家感知，**只能量，不能推**。
## 量出来才决定：是要「显式加一层旋转折扣」，还是这条因果本来就够用。
##
## ── 用的必须是真实物理 + 真实判定 ──
## · 飞行：把**真的 PingPongBall 挂进树**，由引擎按 --fixed-fps 60 逐帧积分
##   （重力 + 阻力 + 马格努斯 + 台面弹跳 + 撞网都用 _physics_process 那一套）。
##   ★ 不要在这里复制一份积分公式 —— 那就不是「量真实物理」了。
## · 概率：`opp_smash_chance_at` 是**从 pingpong_game.gd 实例上真调的**，
##   所以旋转折扣一改，这张表就跟着变，不需要同步改探针。

## 与 pingpong_game.gd / pingpong_ball.gd 一致的几何常量
const NET_NEED := 0.76 + 0.1525 + 0.015       # _solve_return 里用的过网判据
const OPP_PLANE_Z := -1.30                     # = pingpong_game.gd 的 OPP_PADDLE_Z

## 一次飞行的上限帧数（60 fps 下 240 帧 = 4 s，正常一拍远小于此）
const MAX_FRAMES := 240

var _ball: PingPongBall
var _game: Node          # 只为读参数 / 调 opp_smash_chance_at，**不入树**
var _bounced_opp := false


func _ready() -> void:
	var ball_script := load("res://pingpong_ball.gd") as GDScript
	var game_script := load("res://pingpong_game.gd") as GDScript
	if ball_script == null or game_script == null:
		push_error("找不到脚本")
		get_tree().quit(1)
		return
	# ★ `script.new()` 的类型是 Variant，不能用 `:=` 接 —— 本工程把那条警告当错误。
	#   （同一族坑：三元两分支也会推断出 Variant。见项目记忆。）
	var b: Node = ball_script.new()
	b.name = "ProbeBall"
	add_child(b)
	_ball = b as PingPongBall
	# 游戏实例**不入树**：只要它的导出量和纯函数，_ready / _process 都不该跑。
	_game = game_script.new()
	if _ball == null or _game == null:
		push_error("实例化失败")
		get_tree().quit(1)
		return
	_ball.bounced_table.connect(_on_bounced_table)
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("")
	print("参数：单次折扣 spin_smash_discount=%.2f  spin_smash_full=%.2f  "
		% [float(_game.get("spin_smash_discount")), float(_game.get("spin_smash_full"))]
		+ "触球高度门槛 h_low=%.2f / h_full=%.2f"
		% [float(_game.get("opp_smash_h_low")), float(_game.get("opp_smash_h_full"))])

	await _run()

	print("")
	print("══════ 表 C：球速标定（用于定「快球」阈值）══════")
	_speed_table()

	print("")
	print("══════ 表 D：对手扣杀的**真实出手球速**（按难度 × 落点深度）══════")
	_opp_smash_table()

	print("")
	print("══════ 小结用的原始数（供换算）══════")
	print("  · 玩家回球速度**上限** return_speed_max = 24 m/s（实测出手只有 5~10，故从不触发）")
	print("  · 对手扣杀速度**上限** opp_smash_speed_max = 32 m/s（同上）")
	_game.free()
	print("")


func _on_bounced_table(_pos: Vector3, side: int) -> void:
	if side < 0:
		_bounced_opp = true


func _run() -> void:
	await _table("表 A：中深落点 tz=-1.00（普通对拉）", -1.00)
	await _table("表 B：短球 tz=-0.45（旋球战术的核心场景）", -0.45)


func _table(title: String, tz: float) -> void:
	print("")
	print("══════ %s ══════" % title)
	print("%-10s %-9s %-9s %-9s %-9s %-9s %-9s" % [
		"旋转", "出手m/s", "触球y(m)", "触球旋量", "折扣倍率", "折扣前%", "折扣后%"])
	var from := Vector3(0.0, 0.95, 1.10)
	var target := Vector3(0.0, 0.78, tz)
	for c in [["上旋 +1.7", 1.7], ["无旋  0.0", 0.0], ["下旋 -1.6", -1.6]]:
		var spin := float(c[1])
		var v := _solve_return(from, target, 0.45)
		var r: Dictionary = await _fly(from, v, spin)
		var y := float(r["contact_y"])
		var cs := float(r["contact_spin"])
		if y <= 0.0:
			print("%-10s %-9.2f %-9s %-9.2f %-9s %-9s %-9s"
				% [c[0], v.length(), "未过面", cs, "—", "—", "—"])
			continue
		var before := _chance(y, 0.0)
		var after := _chance(y, cs)
		print("%-10s %-9.2f %-9.3f %-9.2f %-9.2f %-9.1f %-9.1f" % [
			c[0], v.length(), y, cs,
			float(_game.call("_spin_smash_factor", cs)),
			before * 100.0, after * 100.0,
		])


## 直接调游戏里的真函数：折扣逻辑一改，这张表就跟着变。
func _chance(y: float, spin: float) -> float:
	return float(_game.call("opp_smash_chance_at", y, spin))


## 表 C：把各种击球的飞行时间换算成出手球速
func _speed_table() -> void:
	var from := Vector3(0.0, 0.95, 1.10)
	var target := Vector3(0.0, 0.78, -1.00)
	var rows := [
		["普通回球 0.45", 0.45],
		["爆冲·轻 0.46", 0.46],
		["爆冲·蓄满 0.30", 0.30],
		["暴拧·轻 0.48", 0.48],
		["暴拧·蓄满 0.33", 0.33],
		["偏快 0.35", 0.35],
		["对手普通 0.58×1.18(简单)", 0.684],
		["对手普通 0.58×1.00(普通)", 0.580],
		["对手普通 0.58×0.70(大师)", 0.406],
		# ★ 扣杀还要再乘 opp_smash_flight_scale(0.68) —— 五个难度全列出来。
		#   一开始漏了这层缩放，把阈值定成 7.0，结果普通/困难档一次都弹不出来。
		["对手扣杀 简单 0.58×1.18×0.68", 0.465],
		["对手扣杀 普通 0.58×1.00×0.68", 0.394],
		["对手扣杀 困难 0.58×0.90×0.68", 0.355],
		["对手扣杀 专家 0.58×0.80×0.68", 0.316],
		["对手扣杀 大师 0.58×0.70×0.68", 0.276],
	]
	var thr := float(_game.get("speed_flash_min"))
	var loud := float(_game.get("speed_flash_loud"))
	print("（快球阈值 speed_flash_min=%.1f m/s，特别快 speed_flash_loud=%.1f m/s）" % [thr, loud])
	print("%-26s %-9s %-9s %-9s %s" % ["击球方式", "飞行s", "球速m/s", "球速km/h", "会弹数字?"])
	for row in rows:
		var flight := float(row[1])
		var v := _solve_return(from, target, flight)
		var sp := v.length()
		print("%-26s %-9.3f %-9.2f %-9.1f %s" % [
			row[0], flight, sp, sp * 3.6,
			("是" + ("（大喊）" if sp >= loud else "")) if sp >= thr else "否",
		])


## 复刻 pingpong_game.gd 的 _solve_return：先按 flight 解一次，
## 模拟发现过不了网就把弧线拉高（+0.06 s）重试，最多 8 次。
## ★ 只有这一段是复刻（它是纯求解，不含飞行积分）；飞行本身走真实物理。
func _solve_return(from: Vector3, target: Vector3, flight: float) -> Vector3:
	var t := flight
	for _i in range(8):
		var v := _ball.solve_velocity(from, target, t)
		if _ball.simulate_net_height(from, v) >= NET_NEED:
			return _clamp_speed(v, 24.0)
		t += 0.06
	return _clamp_speed(_ball.solve_velocity(from, target, t), 24.0)


## 复刻 _clamp_return_speed
func _clamp_speed(v: Vector3, cap: float) -> Vector3:
	var sp := v.length()
	if sp <= cap or sp < 0.01:
		return v
	return v * (cap / sp)


## 表 D：对手扣杀的出手球速。
##
## ★ 为什么非要单独量：扣杀的飞行时间 = `opponent_return_flight(0.58)`
##   × **难度倍率** × `opp_smash_flight_scale(0.68)` —— 简单档 1.18、大师档 0.70，
##   差 1.7 倍。所以「扣杀有多快」是跟着难度走的，拿一个绝对阈值去卡
##   很容易在低难度整档失效（踩过：阈值 7.0 时普通/困难档一次都弹不出来）。
func _opp_smash_table() -> void:
	var diffs := [["简单", 1.18], ["普通", 1.00], ["困难", 0.90], ["专家", 0.80], ["大师", 0.70]]
	var from := Vector3(0.0, 0.95, OPP_PLANE_Z)
	var base := float(_game.get("opponent_return_flight"))
	var scale := float(_game.get("opp_smash_flight_scale"))
	var lo := float(_game.get("opp_smash_deep_lo"))
	var hi := float(_game.get("opp_smash_deep_hi"))
	var half := 1.37
	var thr := float(_game.get("speed_flash_min"))
	print("（飞行 = %.2f × 难度倍率 × %.2f；落点深度取 opp_smash_deep %.2f~%.2f）" % [base, scale, lo, hi])
	print("%-8s %-8s %-12s %-12s %-12s %s" % ["难度", "飞行s", "浅落点m/s", "中落点m/s", "深落点m/s", "够阈值?"])
	for d in diffs:
		var flight := base * float(d[1]) * scale
		var sp_lo := 0.0
		var sp_mid := 0.0
		var sp_hi := 0.0
		var ks := [lo, (lo + hi) * 0.5, hi]
		var sps: Array[float] = []
		for k in ks:
			var v := _solve_return(from, Vector3(0.0, 0.78, half * float(k)), flight)
			sps.append(v.length())
		sp_lo = sps[0]
		sp_mid = sps[1]
		sp_hi = sps[2]
		print("%-8s %-8.3f %-12.2f %-12.2f %-12.2f %s" % [
			d[0], flight, sp_lo, sp_mid, sp_hi,
			"是" if minf(sp_lo, minf(sp_mid, sp_hi)) >= thr else "★否（阈值过高）",
		])


## 真的把球打出去，逐物理帧步进，返回穿过对手拍面平面时的状态。
func _fly(from: Vector3, v: Vector3, spin: float) -> Dictionary:
	_bounced_opp = false
	_ball.launch(from, v, spin)
	var prev := from
	var out := {
		"contact_y": -1.0,
		"contact_speed": 0.0,
		"contact_spin": 0.0,
		"bounced_opp": false,
		"frames": 0,
	}
	for i in range(MAX_FRAMES):
		await get_tree().physics_frame
		out["frames"] = i + 1
		if not _ball.is_flying():
			break
		var cur := _ball.global_position
		# 连续检测：这一帧有没有从 z > 平面 跨到 z <= 平面（球的 z 速度恒为负）
		if prev.z > OPP_PLANE_Z and cur.z <= OPP_PLANE_Z:
			var dz := prev.z - cur.z
			var t := 1.0 if absf(dz) < 1e-9 else (prev.z - OPP_PLANE_Z) / dz
			var hit := prev.lerp(cur, t)
			out["contact_y"] = hit.y
			out["contact_speed"] = _ball.velocity.length()
			# ★ 旋量取**触球那一刻**的值：它每弹一次台乘 spin_decay，
			#   而球到对手拍面前必弹一次 —— 折扣吃的就是这个衰减后的值。
			out["contact_spin"] = _ball.get_spin()
			return out
		if cur.y < 0.02:
			break
		prev = cur
	out["bounced_opp"] = _bounced_opp
	return out
