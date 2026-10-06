extends Node
## 一次性性能量化探针（**不是**回归组，不进 run_regression.sh）。
##
## 跑法：
##   "$GODOT" --headless --path . tests/_perf_probe.tscn
##
## ★ 无头下用的是 dummy 渲染，**渲染耗时不可信**；但这里测的全是
##   纯 CPU 脚本（物理积分 + 线段/平面求交），与渲染无关，数据可用。
##   绝对值和 Web(wasm) 不同（wasm 通常慢数倍），但**热点排序一致**。
##
## 用法边界：全部用**脚本实例**（不入树）跑，所以不会触发 _ready、
## 不会写真实存档、不会开窗口。

const GAME_SCRIPT := "res://pingpong_game.gd"
const BALL_SCRIPT := "res://pingpong_ball.gd"

var _ball: PingPongBall
var _game: Node3D

var _from := Vector3(0.0, 1.05, 1.50)
var _target := Vector3(0.0, 0.78, -0.90)
var _vel := Vector3.ZERO

var _ms_path := 0.0
var _ms_solver := 0.0
var _ms_cached := 0.0


func _ready() -> void:
	_ball = (load(BALL_SCRIPT) as GDScript).new() as PingPongBall
	_game = (load(GAME_SCRIPT) as GDScript).new() as Node3D
	_game.set("_ball", _ball)
	if _game.get("_ball") != _ball:
		print("!! set(_ball) 失败 —— 解算器测量无效")

	print("========================================================")
	print(" 性能量化探针（无头 CPU 计时）")
	print("========================================================")
	print("  当前 serve_solve_iters=%s  serve_search_dt=%.5f"
		% [str(_game.get("serve_solve_iters")), float(_game.get("serve_search_dt"))])

	# ★ 分段开关：CS1_PERF_ONLY=F 只跑 F 段（反复调参数时不用每次等 1 分钟）。
	var only := OS.get_environment("CS1_PERF_ONLY").to_upper()
	var pick := func(tag: String) -> bool:
		return only.is_empty() or only.contains(tag)
	if pick.call("A"):
		_bench_path()
	if pick.call("B"):
		_bench_solver()
	if pick.call("C"):
		_bench_cache()
	if pick.call("D"):
		_bench_quality()
	if pick.call("E"):
		_bench_distribution()
	if pick.call("F"):
		_bench_sweep()
	if pick.call("G"):
		_bench_frame()
	if pick.call("P"):
		_bench_polyline()
	_report()
	get_tree().quit()


func _bench(label: String, n: int, fn: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	var sink := 0.0
	for i in n:
		sink += float(fn.call(i))
	var ms := float(Time.get_ticks_usec() - t0) / float(n) / 1000.0
	print("  %-46s %8.3f ms/次" % [label, ms])
	if sink < -1e9:
		print("   (sink)")
	return ms


# ── A ─────────────────────────────────────────────────────
func _bench_path() -> void:
	print("\n── A. simulate_path 单次成本 ──")
	_vel = _ball.solve_velocity(_from, _target, 0.42)
	print("  基准弹道 from=%s 初速 %.2f m/s" % [str(_from), _vel.length()])
	_ms_path = _bench("A1 解算器档 (2.5s, dt=1/60, clr=0.003)", 300,
		func(_i: int) -> float:
			var r: Dictionary = _ball.simulate_path(
				_from, _vel, 0.20, 2.5, 1.0 / 60.0, 0.003)
			return float((r["events"] as Array).size()))
	_bench("A2 落点提示档 (1.6s, dt=1/60, clr=0)", 300,
		func(_i: int) -> float:
			var r: Dictionary = _ball.simulate_path(
				_from, _vel, 0.20, 1.6, 1.0 / 60.0, 0.0)
			return float((r["bounces"] as Array).size()))


# ── B ─────────────────────────────────────────────────────
func _bench_solver() -> void:
	print("\n── B. _solve_legal_serve 端到端 ──")
	var plan: Dictionary = _game.call("_plan_serve", 1)
	if plan.is_empty():
		print("  !! _plan_serve 返回空，跳过")
		return
	var xs: Array = plan.get("own_x_cands", [])
	var fs: Array = _game.get("serve_legal_flight_scales")
	var cap := int(_game.get("serve_legal_attempts"))
	print("  候选 = own_x %d × n_z 6 × flight %d = %d 次（上限 %d）"
		% [xs.size(), fs.size(), xs.size() * 6 * fs.size(), cap])
	print("  plan 含 from_x = %s" % str(plan.has("from_x")))

	for z: float in [1.5, 2.2, 3.0]:
		var from := Vector3(0.0, 1.05, z)
		var n := 25
		var t0 := Time.get_ticks_usec()
		var hits := 0
		for i in n:
			var r: Dictionary = _game.call("_solve_legal_serve", from, plan)
			if bool(r["ok"]):
				hits += 1
		var ms := float(Time.get_ticks_usec() - t0) / float(n) / 1000.0
		print("  B1 固定瞄准 from z=%.1f   %8.3f ms/次   命中 %d/%d"
			% [z, ms, hits, n])

	var n2 := 25
	var t0b := Time.get_ticks_usec()
	for i in n2:
		plan["opp_x"] = randf_range(-0.72, 0.72)
		plan["opp_z"] = randf_range(-1.20, -0.30)
		_game.call("_solve_legal_serve", Vector3(0.0, 1.05, 1.6), plan)
	_ms_solver = float(Time.get_ticks_usec() - t0b) / float(n2) / 1000.0
	print("  B2 瞄准点每轮变        %8.3f ms/次" % _ms_solver)

	var saved := float(_game.get("serve_legal_accept_dist"))
	_game.set("serve_legal_accept_dist", -1.0)
	var n3 := 8
	var t0c := Time.get_ticks_usec()
	for i in n3:
		plan["opp_x"] = randf_range(-0.72, 0.72)
		plan["opp_z"] = randf_range(-1.20, -0.30)
		_game.call("_solve_legal_serve", Vector3(0.0, 1.05, 1.6), plan)
	var msc := float(Time.get_ticks_usec() - t0c) / float(n3) / 1000.0
	_game.set("serve_legal_accept_dist", saved)
	print("  B3 ★最坏（强制跑满 %d）%8.3f ms/次" % [cap, msc])


# ── B4 缓存 ────────────────────────────────────────────────
func _bench_cache() -> void:
	print("\n── B4. _solve_serve_cached 缓存 ──")
	var plan: Dictionary = _game.call("_plan_serve", 1)
	var from := Vector3(0.0, 1.05, 1.6)
	_game.call("_invalidate_serve_solution")
	var first: Dictionary = _game.call("_solve_serve_cached", from, plan)
	print("  首次（未命中）ok=%s" % str(first.get("ok")))
	_ms_cached = _bench("B4a 缓存命中（同 from/瞄准/自旋）", 300,
		func(_i: int) -> float:
			var r: Dictionary = _game.call("_solve_serve_cached", from, plan)
			return 1.0 if bool(r["ok"]) else 0.0)
	_bench("B4b 未命中（每轮改瞄准点）", 25,
		func(i: int) -> float:
			plan["opp_x"] = randf_range(-0.72, 0.72)
			plan["opp_z"] = randf_range(-1.20, -0.30)
			var r: Dictionary = _game.call("_solve_serve_cached", from, plan)
			return 1.0 if bool(r["ok"]) else 0.0)

	# B5 模拟玩家「连续小步转视角」：瞄准点每轮挪一点点 —— 这正是快路该发威的场景
	_game.call("_invalidate_serve_solution")
	var p5: Dictionary = _game.call("_plan_serve", 1)
	p5["opp_x"] = 0.0
	p5["opp_z"] = -0.80
	var fast := 0
	var n5 := 40
	var t5 := Time.get_ticks_usec()
	for i in n5:
		p5["opp_x"] = clampf(float(p5["opp_x"]) + 0.03, -0.72, 0.72)
		p5["opp_z"] = clampf(float(p5["opp_z"]) - 0.02, -1.20, -0.30)
		var t1 := Time.get_ticks_usec()
		_game.call("_solve_serve_cached", from, p5)
		if float(Time.get_ticks_usec() - t1) / 1000.0 < 1.0:
			fast += 1
	var ms5 := float(Time.get_ticks_usec() - t5) / float(n5) / 1000.0
	print("  B5 连续小步转视角        %8.3f ms/次   快路命中 %d/%d"
		% [ms5, fast, n5])


# ── C ─────────────────────────────────────────────────────
func _bench_polyline() -> void:
	print("\n── C. 轨迹提示线采样 ──")
	_bench("C1 _sim_serve_polyline (2.2s @ 1/90)", 100,
		func(_i: int) -> float:
			var a: Array = _game.call("_sim_serve_polyline", _from, _vel, 0.20)
			return float(a.size()))


# ── D 合法性 / 成功率对比（粗搜索唯一的风险点）────────────
func _bench_quality() -> void:
	print("\n── D. ★粗搜索有没有把「解得出合法发球」的能力弄丢 ──")
	print("     （每个配置扫 60 个随机瞄准点：ok 比例 / 落点误差 / 耗时）")
	print("     ★ 只看 ok 比例会**饱和**（每个配置都是 60/60）—— 因为解算器")
	print("       最后还有一条 `best` 兜底，永远能返回一个合法解。")
	print("       真正的质量指标是**第二跳离瞄准点多远**（越小越准）。")
	var n := 60
	var cfgs: Array = [
		[8, 1.0 / 30.0, -1.0, " 8/1-30  无预算"],
		[8, 1.0 / 30.0, 20.0, " 8/1-30  预算 20ms"],
		[8, 1.0 / 30.0, 16.0, " 8/1-30  预算 16ms"],
		[8, 1.0 / 30.0, 12.0, " 8/1-30  预算 12ms"],
		[8, 1.0 / 30.0, 8.0, " 8/1-30  预算  8ms"],
		[8, 1.0 / 30.0, 6.0, " 8/1-30  预算  6ms"],
	]
	var aims: Array = []
	# 固定同一批瞄准点，几个配置才可比
	for i in n:
		aims.append(Vector2(randf_range(-0.72, 0.72), randf_range(-1.20, -0.30)))
	for cfg: Array in cfgs:
		_game.set("serve_solve_iters", int(cfg[0]))
		_game.set("serve_search_dt", float(cfg[1]))
		if int(_game.get("serve_solve_iters")) != int(cfg[0]):
			print("  !! set(serve_solve_iters) 未生效")
		var plan: Dictionary = _game.call("_plan_serve", 1)
		var ok := 0
		var errs: Array = []
		var t0 := Time.get_ticks_usec()
		for i in n:
			plan["opp_x"] = float((aims[i] as Vector2).x)
			plan["opp_z"] = float((aims[i] as Vector2).y)
			var r: Dictionary = _game.call("_solve_legal_serve",
				Vector3(0.0, 1.05, 1.6), plan, float(cfg[2]))
			if bool(r["ok"]):
				ok += 1
				var s: Vector3 = r["second"]
				errs.append(Vector2(s.x - plan["opp_x"], s.z - plan["opp_z"]).length())
		var ms := float(Time.get_ticks_usec() - t0) / float(n) / 1000.0
		errs.sort()
		var e50 := float(errs[errs.size() / 2])
		var e95 := float(errs[mini(int(errs.size() * 0.95), errs.size() - 1)])
		var eavg := 0.0
		for e: float in errs:
			eavg += e
		eavg /= float(maxi(errs.size(), 1))
		print("  %-24s ok %2d/%d  误差 均 %.3f / p50 %.3f / p95 %.3f m  %7.2f ms/次"
			% [cfg[3], ok, n, eavg, e50, e95, ms])
	# 复位成线上值，免得后面的 E 段量到别的配置
	_game.set("serve_solve_iters", 8)
	_game.set("serve_search_dt", 1.0 / 30.0)


# ── E 单次解算的耗时分布（决定要不要给解算器上「时间预算」）──
##
## ★ 为什么必须量分布而不是平均：玩家转视角时每 serve_preview_interval
##   触发**一次**解算，而帧预算是 16.67 ms。平均值 24 ms 掩盖不了
##   「p90 是 58 ms」—— 那种一次尖峰就是 3 帧掉帧，每秒来 8 次就是
##   用户嘴里的「一卡一卡」。
func _bench_distribution() -> void:
	print("\n── E. 单次 _solve_legal_serve 耗时分布（每档 80 个随机瞄准点）──")
	print("     ★ 看的是 p90/max 而不是均值：玩家转视角时每 0.12 s 触发一次，")
	print("       一次 40 ms 尖峰就是 2~3 帧掉帧，每秒来 8 次 = 肉眼可见的卡顿。")
	var n := 80
	for cfg: Array in [[1.0 / 60.0, -1.0, "1-60 无预算"],
					   [1.0 / 30.0, -1.0, "1-30 无预算"],
					   [1.0 / 30.0, 12.0, "1-30 预算 12ms"],
					   [1.0 / 30.0, 6.0, "1-30 预算  6ms"]]:
		_game.set("serve_solve_iters", 8)
		_game.set("serve_search_dt", float(cfg[0]))
		print("  ── serve_search_dt = %s ──" % cfg[2])
		for z: float in [1.6, 2.4, 3.1]:
			var plan: Dictionary = _game.call("_plan_serve", 1)
			var from := Vector3(0.0, 1.05, z)
			var samples: Array = []
			var okc := 0
			for i in n:
				plan["opp_x"] = randf_range(-0.72, 0.72)
				plan["opp_z"] = randf_range(-1.20, -0.30)
				var t0 := Time.get_ticks_usec()
				var r: Dictionary = _game.call("_solve_legal_serve", from, plan,
					float(cfg[1]))
				samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
				if bool(r["ok"]):
					okc += 1
			samples.sort()
			var p50 := float(samples[int(n * 0.50)])
			var p90 := float(samples[int(n * 0.90)])
			var pmax := float(samples[n - 1])
			var over16 := 0
			for s: float in samples:
				if s > 16.67:
					over16 += 1
			print("    from z=%.1f  ok %2d/%d  p50 %5.1f  p90 %5.1f  max %5.1f ms   超一帧 %2d/%d"
				% [z, okc, n, p50, p90, pmax, over16, n])
	# 复位成线上值
	_game.set("serve_solve_iters", 8)
	_game.set("serve_search_dt", 1.0 / 30.0)


# ── F ─────────────────────────────────────────────────────
## 玩家按住方向键「转视角瞄准」才是真实路径：瞄准点**连续小幅移动**。
## 上面 D/E 每轮都换一个随机瞄准点 —— 那是「视角乱甩」的极端，不是日常。
## ★ 提示候选（_serve_solve_hint）只在这种连续小幅移动下才发挥作用，
##   所以必须有这一段，否则「提示到底有没有用」根本量不出来。
func _bench_sweep() -> void:
	print("\n── F. 连续转视角（瞄准点每次挪一小步）──")
	print("     ★ 这才是实战路径；随机跳瞄准点属于「视角乱甩」的极端。")
	print("     ★ 同一发球只建一次 plan，全程只挪瞄准点 —— 与实战一致。")
	for cfg: Array in [
			[0.03, 8, true, "基线（提示 + 8 次二分）"],
			[0.03, 4, true, "★ 4 次二分"],
			[0.03, 3, true, "★ 3 次二分"],
			[0.03, 4, false, "对照：关掉提示"],
			[0.06, 4, true, "步长翻倍 + 提示"],
			[0.06, 8, false, "步长翻倍、无提示"]]:
		var step := float(cfg[0])
		var use_hint := bool(cfg[2])
		_game.set("serve_solve_iters", int(cfg[1]))
		_game.set("serve_search_dt", 1.0 / 30.0)
		var from := Vector3(0.0, 1.05, 1.9)
		# 从 -0.60 起，每次把瞄准点沿 x 挪 step 米，扫到 +0.60
		var aims: Array = []
		var ax := -0.60
		while ax <= 0.60 + 0.0001:
			aims.append(ax)
			ax += step
		var n := aims.size()
		# ★ 只建**一个** plan，整段扫描过程中只改 opp_x / opp_z ——
		#   这才是实战：plan（含 flight / spin / own_x_cands）在 start_serve
		#   时建一次，之后转视角只调 _apply_serve_aim 改瞄准点。
		#   每步都 _plan_serve（重新掷 flight/spin）会让候选弹道整个变样，
		#   那量的是「每步换一发球」，不是「转视角」。
		var plan: Dictionary = _game.call("_plan_serve", 1)
		var samples: Array = []
		var attempts_sum := 0
		var errs: Array = []
		for i in n:
			plan["opp_x"] = float(aims[i])
			plan["opp_z"] = -0.90 + 0.30 * float(aims[i])
			if not use_hint:
				_game.set("_serve_solve_hint", [])
			var t0 := Time.get_ticks_usec()
			var r: Dictionary = _game.call("_solve_legal_serve", from, plan)
			samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
			attempts_sum += int(_game.get("serve_last_attempts"))
			if bool(r["ok"]):
				var s: Vector3 = r["second"]
				errs.append(Vector2(s.x - float(plan["opp_x"]),
					s.z - float(plan["opp_z"])).length())
			# 每步之间把「缓存解」清掉，强制真的重解（不然量的是缓存）
			_game.set("_serve_sol_res", {})
		samples.sort()
		errs.sort()
		var p50 := float(samples[int(n * 0.5)])
		var p90 := float(samples[int(n * 0.9)])
		var pmax := float(samples[n - 1])
		var over := 0
		for s: float in samples:
			if s > 16.67:
				over += 1
		# 「误差」= 第二跳离瞄准点的距离中位数 —— 它**只能**由精度决定，
		# 与缓存/提示/帧率无关，是判断「提取性能时有没有偷偷降质」的唯一标尺。
		print("  步长 %.2f 迭代 %d  %-22s p50 %6.2f  p90 %6.2f  max %7.2f ms  超一帧 %2d/%d  均候选 %5.1f  误差 %.3f m"
			% [step, int(cfg[1]), str(cfg[3]),
			   p50, p90, pmax, over, n,
			   float(attempts_sum) / float(n),
			   (0.0 if errs.is_empty() else float(errs[errs.size() / 2]))])


# ── G ─────────────────────────────────────────────────────
## ★★ 逐帧摊销的正面证据：直接按**帧**跑真实预览路径（_update_serve_traj），
##    量每一帧花多久 —— 这才是玩家真正感受到的东西。
##
## 对照组 = `serve_step_cands = 0`（不限 = 一次跑完 = 改之前的行为）。
## ★ 为什么必须量**每帧**而不是「一次解算」：摊销的整个意义就是
##   「把 30 ms 摊成 10 帧 × 3 ms」。只看单次解算反而看不出它好在哪。
func _bench_frame() -> void:
	print("\n── G. 逐帧跑真实预览路径（发球态转视角 3 秒）──")
	print("     每帧挪 0.03 m 瞄准点（≈ 按住方向键），量的是每帧开销。")
	_game.set("serve_aim_enabled", false)
	_game.set("_server", 1)
	_game.set("_state", 1)          # State.SERVE_DELAY
	_game.set("_match_over", false)
	_game.set("_par_serve_t", -1.0)
	_game.set("show_serve_trajectory", true)
	_game.call("_build_serve_traj")
	if _game.get("_serve_traj") == null:
		print("  !! 造不出 _serve_traj，跳过")
		return
	for cfg: Array in [[0, "一次跑完（改之前）"], [6, "摊销 6 个/帧（现在）"],
			[4, "摊销 4 个/帧"], [12, "摊销 12 个/帧"]]:
		_game.set("serve_step_cands", int(cfg[0]))
		_game.set("_serve_solve_hint", [])
		_game.set("_serve_job", {})
		_game.set("_serve_sol_res", {})
		var plan: Dictionary = _game.call("_plan_serve", 1)
		_game.set("_serve_plan", plan)
		var n := 180
		var samples: Array = []
		var calls0 := int(_game.get("serve_solve_calls"))
		for i in n:
			var u := float(i) / float(n - 1) * 2.0 - 1.0
			plan["opp_x"] = 0.60 * u
			plan["opp_z"] = -0.90 + 0.30 * u
			var t0 := Time.get_ticks_usec()
			_game.call("_update_serve_traj", 1.0 / 60.0)
			samples.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		samples.sort()
		var over := 0
		for s: float in samples:
			if s > 16.67:
				over += 1
		print("  %-20s 帧 p50 %6.3f  p90 %6.3f  max %7.3f ms  超一帧 %2d/%d  建任务 %d 次"
			% [str(cfg[1]), float(samples[n / 2]), float(samples[int(n * 0.9)]),
			   float(samples[n - 1]), over, n,
			   int(_game.get("serve_solve_calls")) - calls0])


# ── 换算 ──────────────────────────────────────────────────
func _report() -> void:
	print("\n========================================================")
	print(" 结论 / 每帧成本")
	print("========================================================")
	print("  · simulate_path 单次                     %8.3f ms" % _ms_path)
	print("  · _solve_legal_serve 一次（瞄准点变）    %8.3f ms" % _ms_solver)
	print("  · 解算缓存命中                          %8.4f ms" % _ms_cached)
	print("  · 预览重画（命中路径）= polyline + 1×simulate_path ≈ %6.3f ms"
		% (0.079 + _ms_path))
	print("")
	print("  发球态实际开销：")
	print("    · 玩家站着瞄准（缓存命中）→ 每 0.12 s 仅重画线 ≈ %6.3f ms"
		% (0.079 + _ms_path))
	print("    · 转视角（未命中）→ 每 0.12 s 一次 %8.3f ms" % _ms_solver)
	print("    · 出手 → 复用预览的解，≈ 0 ms（原来一次 %8.3f ms）" % 149.058)
	print("  60 fps 一帧预算 = 16.67 ms")
	print("========================================================")
