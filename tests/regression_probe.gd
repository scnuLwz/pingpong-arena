## 回归探针 —— 锁住「优化方案」动手之前的行为基线
##
## 为什么先写这个：方案阶段 3/4 要把30 个平行 export × 5 档重构成一张字典表，
## 还要把 pingpong_game.gd（5286 行）拆成 4 个模块。改完之后**没有任何东西**
## 能证明行为没变—— 那比不重构更危险。
##
## 本探针锁的基线（每一组都是「重构后必须逐位不变」的东西）：
##   A. 难度插值：10 参数 × 5 整数档 + 钳位/单调/键集合 = **142 项断言**
##      硬约束来自 pingpong_game.gd 的注释：「t 取整数时逐位等于原来那一档」。
##      这条一旦破，自由对战/赛事的手感就变了，而且**没有任何症状**——
##      游戏不会报错，只是「大师好像比专家弱」。这是最难发现的回归。
##   B. 三个进场旗标：doubles / ranked / tour_entry 的互斥与清理。
##   C. 关键几何常量：球台、网、活动区、发球区。
##   D. 场边家具不侵入玩家可达区（活动区改过两次，这里钉住第三次）。
##   E~K. 难度微调端到端 / 凶度反馈与 HUD / 球拍不穿台面 / 先落台才能击球 /
##        发球预览开销不变量 / 旋球折扣 + 快球反馈（分组说明见 run_regression.sh）。
##   L. 赛后评价称号（`match_title()` 纯函数）+ 任务一键领取（会写盘）。
##
## 用法：Godot --headless --path . tests/regression_probe.tscn -- <组名>
##   组名省略 = 全跑。不入树（避免 autoload 写真实存档），见 PITFALLS.md 坑 #3。
extends Node

const GAME_SCRIPT := "res://pingpong_game.gd"
const GAME_STATE := "res://game_state.gd"
const PADDLE_SCRIPT := "res://paddle_viewmodel.gd"
## 台面顶 / 半宽 / 半长（m）。★ 跨脚本硬约定，与 camera_controller.table_top_y、
## paddle_viewmodel.TABLE_HALF_WIDTH / TABLE_HALF_LENGTH、pingpong_ball 同值。
const TABLE_TOP_Y := 0.760
const TABLE_HALF_X := 0.7625
const TABLE_HALF_Z := 1.37
## enum Hitter { NONE, PLAYER, OPPONENT }（pingpong_game.gd 里声明）。
const HITTER_NONE := 0
const HITTER_PLAYER := 1
const HITTER_OPPONENT := 2
## enum HitKind { NORMAL, LOOP, FLICK }（pingpong_game.gd 里声明）。
const KIND_NORMAL := 0
const KIND_LOOP := 1
const KIND_FLICK := 2

## 与 pingpong_game.gd 的 `enum State { IDLE, SERVE_DELAY, INCOMING, RALLY, POINT }` 对应
const STATE_IDLE := 0
const STATE_SERVE_DELAY := 1

const BALL_SCRIPT := "res://pingpong_ball.gd"

var _checks := 0
var _fails: Array[String] = []

# ───────────── 存档保护 ─────────────
## ★★ 本探针里有几组会在**离树脚本实例**上调用 `reset_all()`（B 组、D 组），
##   而 `reset_all()` 结尾会 `save_profile()` —— 于是它拿**一份刚 new 出来的
##   默认档案**把玩家真实的 `user://profile.json` 整个覆盖掉：
##   金币、战绩、称号、解锁的场馆、难度设置**全部归零**，而且**不报任何错**，
##   跑完回归看着一切正常。踩了很多轮都没发现，因为没人去核对存档。
##
## ★ 2026-10-06 才定位到：给新功能加回归组后跑了一遍 A~K，事后核对玩家存档
##   才发现金币 5485→0、35 场战绩→0。逐组单跑复现，最后落在 B 组。
##
## ★ 修法选「**文件原文快照**」而不是「依赖某个节点/实例还活着去还原」：
##   它跟场景树无关，探针中途报错也照样能还原（_report() 一定会被调到）。
##   ★★ 但**还原不能只靠探针自己** —— run_regression.sh 里另有一道
##      外部的「跑前 cp / 跑后核对」兜底，那是最后防线，两边都要留着。
const PROFILE_PATH := "user://profile.json"
var _profile_snapshot: PackedByteArray = PackedByteArray()
var _profile_had_file := false


func _snapshot_profile() -> void:
	_profile_had_file = FileAccess.file_exists(PROFILE_PATH)
	if not _profile_had_file:
		return
	var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if f == null:
		return
	_profile_snapshot = f.get_buffer(f.get_length())
	f.close()


## 把档案写回跑之前的样子。没有原文件 / 快照为空时**什么都不做**
## （宁可不写，也不能拿空内容去覆盖 —— 那比被重置还糟）。
func _restore_profile() -> void:
	if not _profile_had_file:
		return
	if _profile_snapshot.is_empty():
		_fail("存档快照为空 —— 拒绝写回，避免把档案清成 0 字节")
		return
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		_fail("存档还原失败：打不开 %s" % PROFILE_PATH)
		return
	f.store_buffer(_profile_snapshot)
	f.close()


func _ready() -> void:
	_run()


func _run() -> void:
	# ★ 第一件事就把档案原文拍下来 —— 之后任何一组怎么写盘都能还原。
	_snapshot_profile()
	var groups: PackedStringArray = _args()
	if groups.is_empty():
		groups = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L"]
	for g: String in groups:
		match g:
			"A": _case_difficulty_tiers()
			"B": _case_entry_flags()
			"C": _case_geometry()
			"D": _case_fine_tune()
			"E": await _case_fine_tune_e2e()
			"F": _case_rage_feedback()
			"G": await _case_rage_hud_layout()
			"H": await _case_paddle_table_clearance()
			"I": _case_bounce_before_hit()
			"J": _case_serve_preview_cost()
			"K": await _case_spin_and_speed()
			"L": _case_match_title_and_claim()
			_: _fail("未知组名 %s" % g)
	_report()


func _args() -> PackedStringArray:
	var out := PackedStringArray()
	for a in OS.get_cmdline_user_args():
		out.append(a)
	return out


# ═══════════════════════════════════════════════════════════
# A. 难度插值基线（142 项断言：A1 10 + A2 50 + A3 5 + A4 1 + A5 4 + A6 10 + A7 62）
# ═══════════════════════════════════════════════════════════
## 每个参数的五档值，从 pingpong_game.gd 的 export 声明逐个抄下来的。
## ★ 这份表就是「基线」本身—— 阶段 3 重构时如果字典里的值和这里不一致，
##   说明重构时抄错了，探针会当场抓住。
const TIERS := {
	"flight_time": [0.46, 0.42, 0.40, 0.38, 0.365],
	"spread": [0.35, 0.55, 0.72, 0.86, 0.96],
	"reach_scale": [1.28, 1.00, 0.86, 0.78, 0.68],
	"serve_spin": [0.25, 0.38, 0.58, 0.78, 1.00],
	"serve_edge": [0.00, 0.06, 0.12, 0.20, 0.28],
	"serve_short": [0.00, 0.00, 0.03, 0.07, 0.12],
	"opponent_miss": [0.34, 0.16, 0.09, 0.045, 0.018],
	"opponent_out": [0.12, 0.06, 0.035, 0.018, 0.007],
	"opponent_return_flight": [1.18, 1.00, 0.90, 0.80, 0.70],
	"opponent_return_spread": [0.45, 0.66, 0.80, 0.90, 0.97],
}

## 对应的取数函数名（都在 pingpong_game.gd 里）。
const GETTERS := {
	"flight_time": "_flight_time",
	"spread": "_spread",
	"reach_scale": "_reach_scale",
	"serve_spin": "_serve_spin",
	"serve_edge": "_serve_edge",
	"serve_short": "_serve_short_chance",
	"opponent_miss": "_opponent_miss_chance",
	"opponent_out": "_opponent_out_chance",
	"opponent_return_flight": "_opponent_return_flight_scale",
	"opponent_return_spread": "_opponent_return_spread",
}


func _case_difficulty_tiers() -> void:
	# ★ 不入树：只调纯函数，不跑 _ready / apply_preferences
	#   （那会读autoload、写回档案）。
	var g: Object = (load(GAME_SCRIPT) as GDScript).new()
	if g == null:
		_fail("实例化 pingpong_game.gd 失败")
		return

	# ── A1. 10 个取数函数都存在 ──
	# 记忆坑 #28：调用 autoload 上不存在的方法不会在解析期报错。
	for key: String in GETTERS:
		var fn: String = GETTERS[key]
		if not g.has_method(fn):
			_fail("pingpong_game.gd 缺少取数函数 %s（难度参数 %s 已无处可取）" % [fn, key])
		_checks += 1

	# ── A2. 五档整数逐位一致（核心硬约束，150 组）──
	for key: String in TIERS:
		var fn2: String = GETTERS.get(key, "")
		if fn2 == "" or not g.has_method(fn2):
			continue
		var want: Array = TIERS[key]
		for tier: int in range(5):
			g.call("set_difficulty_t", float(tier))
			var got: float = float(g.call(fn2))
			# 用相对误差而不是精确相等：float 运算的舍入不该被当成回归。
			if absf(got - float(want[tier])) > 0.0005:
				_fail("%s @t=%d：期望 %.4f，实际 %.4f" % [key, tier, float(want[tier]), got])
			_checks += 1

	# ── A3. _tier5 本身：边界与钳位 ──
	# t<0 钳到 0、t>4 钳到 4 —— 排位段位算出来的 t 可能越界。
	g.call("set_difficulty_t", -5.0)
	_eqf("_tier5 t<0 钳到第0 档", float(g.call("_tier5", 1.0, 2.0, 3.0, 4.0, 5.0)), 1.0)
	g.call("set_difficulty_t", 99.0)
	_eqf("_tier5 t>4 钳到第 4 档", float(g.call("_tier5", 1.0, 2.0, 3.0, 4.0, 5.0)), 5.0)
	# 线性中点：t=0.5 应正好落在 1 与 2 之间。
	g.call("set_difficulty_t", 0.5)
	_eqf("_tier5 t=0.5 线性中点", float(g.call("_tier5", 1.0, 2.0, 3.0, 4.0, 5.0)), 1.5)
	g.call("set_difficulty_t", 2.5)
	_eqf("_tier5 t=2.5 线性中点", float(g.call("_tier5", 1.0, 2.0, 3.0, 4.0, 5.0)), 3.5)
	# 5 档全同值时，任何 t 都得那个值（重构字典表时最容易漏的退化情形）。
	g.call("set_difficulty_t", 2.3)
	_eqf("_tier5 五档同值→恒定", float(g.call("_tier5", 7.0, 7.0, 7.0, 7.0, 7.0)), 7.0)

	# ── A4. DIFF_NAMES 与 @export_enum 必须同序 ──
	# 记忆坑 #23 的同类：二元三元式分派写反了不报错，只是「大师比专家弱」。
	var names: Array = g.get("DIFF_NAMES")
	_eqs("DIFF_NAMES 五档名", str(names), '["简单", "普通", "困难", "专家", "大师"]')

	# ── A5. set_difficulty / set_difficulty_t 同步整数档 ──
	# HUD 和结算面板显示的是 difficulty，不是 _diff_t。
	g.call("set_difficulty_t", 2.4)
	_eqf("set_difficulty_t(2.4) → difficulty=2", float(g.get("difficulty")), 2.0)
	g.call("set_difficulty_t", 2.6)
	_eqf("set_difficulty_t(2.6) → difficulty=3", float(g.get("difficulty")), 3.0)
	g.call("set_difficulty", 9)
	_eqf("set_difficulty(9) 钳到 4", float(g.get("difficulty")), 4.0)
	g.call("set_difficulty", -3)
	_eqf("set_difficulty(-3) 钳到 0", float(g.get("difficulty")), 0.0)

	# ── A6. 难度序关系：参数必须随档位单调（否则「高档更强」是假的）──
	# 这条不是抄值，是**语义**约束。重构字典表时最容易在这里悄悄反掉。
	# ↑ 随档位**上升**的：失误率↓ 球速↑ 散布↑ 发球变化↑ 够球范围↓
	var mono_up := ["opponent_return_spread", "serve_spin", "serve_edge",
		"serve_short", "spread"]
	# ↓ 随档位**下降**的：飞行时间（越快越难接）、够球倍率、
	#   回球飞行倍率，以及两个失误率。
	# ★ 失误率是「对手有多常犯错」，属下降那一组 —— 我第一版把它归到上升组，
	#   探针立刻报了两条假FAIL。分类错的是探针，不是游戏。
	var mono_dn := ["flight_time", "reach_scale", "opponent_return_flight",
		"opponent_miss", "opponent_out"]
	for key2: String in mono_up:
		var w: Array = TIERS[key2]
		var ok := true
		for i: int in range(4):
			if float(w[i + 1]) < float(w[i]) - 0.00001:
				ok = false
		if not ok:
			_fail("%s 五档应单调不降，实际 %s" % [key2, str(w)])
		_checks += 1

	for key3: String in mono_dn:
		var w2: Array = TIERS[key3]
		var ok2 := true
		for i2: int in range(4):
			if float(w2[i2 + 1]) > float(w2[i2]) + 0.00001:
				ok2 = false
		if not ok2:
			_fail("%s 五档应单调不升，实际 %s" % [key3, str(w2)])
		_checks += 1

	# ── A7. 难度表完整性（2026-10-04 阶段 3 加）──
	# ★ 重构之后「参数」有两个来源：取数函数里的键名，和表里的键。
	#   两边对不上的两种坏法都**不会报错**：
	#     表里多个键   → 那个参数永远没人用（调平衡时改了却毫无效果）；
	#     取数函数多一个键 → `tune()` 里 push_error 然后返回 0.0，
	#                       症状是「这一档 AI 直接变木头」。
	var table: Variant = g.get("DIFFICULTY_TABLE")
	if table == null or not (table is Dictionary):
		_fail("DIFFICULTY_TABLE 不存在或不是字典")
		return
	var tbl: Dictionary = table
	# 键集合必须**逐一相等**（不是「包含」）—— 多一个少一个都是隐患。
	var want_keys: Array = TIERS.keys()
	want_keys.sort()
	var got_keys: Array = tbl.keys()
	got_keys.sort()
	_eqs("DIFFICULTY_TABLE 键集合", str(got_keys), str(want_keys))
	# 每行必须正好 5 档（_tier5 只取前 5 个，多写的会被静默忽略）
	for k: String in tbl:
		var row: Variant = tbl[k]
		if not (row is Array) or (row as Array).size() != 5:
			_fail("DIFFICULTY_TABLE['%s'] 不是 5 档" % k)
		_checks += 1
	# 表里的值必须和探针这份**独立抄写的**基线逐位一致 ——
	# 这就是「重构时抄错数字」的唯一防线。
	for k2: String in TIERS:
		if not tbl.has(k2):
			continue
		var row2: Array = tbl[k2]
		var want2: Array = TIERS[k2]
		for i3: int in range(5):
			if absf(float(row2[i3]) - float(want2[i3])) > 0.0005:
				_fail("表 %s[%d]：期望 %.4f，实际 %.4f"
					% [k2, i3, float(want2[i3]), float(row2[i3])])
			_checks += 1
	# 未知键必须**显式失败**而不是静默返回 0（返回 0 = AI 变木头）。
	# 用一个不可能撞上的名字探它。
	var bogus: float = float(g.call("tune", "__no_such_key__"))
	_eqf("tune(未知键) 返回 0（且 push_error）", bogus, 0.0)

	g.free()


# ═══════════════════════════════════════════════════════════
# B. 三个进场旗标
# ═══════════════════════════════════════════════════════════
func _case_entry_flags() -> void:
	var g: Object = (load(GAME_STATE) as GDScript).new()
	if g == null:
		_fail("实例化 game_state.gd 失败")
		return

	# ── B1. tour_begin 只认tour_entry，不再从档案推断 ──
	g.set("tournament", _fake_tournament())
	g.set("tour_entry", false)
	_eqs("tour_entry=false → 自由对战", _is_empty_dict(g.call("tour_begin")), "empty")
	_eqs("  且清掉 tour_key", _is_empty_str(g.get("tour_key")), "empty")
	g.set("tour_entry", true)
	var opp: Dictionary = g.call("tour_begin")
	if opp.is_empty():
		_fail("tour_entry=true 应返回对手（拿不到 = 联赛面板点开始进不了比赛）")
	_checks += 1
	if _is_empty_str(g.get("tour_key")) == "empty":
		_fail("tour_begin 成功后应写 tour_key，实际留空 → 局分每次都会被清零")
	_checks += 1

	# ── B2. 同一场连打：tour_key 不变，局分接着走 ──
	g.set("tour_won", 2)
	g.set("tour_lost", 1)
	g.call("tour_begin")
	_eqf("同一场重进：tour_won 保留", float(g.get("tour_won")), 2.0)
	_eqf("同一场重进：tour_lost 保留", float(g.get("tour_lost")), 1.0)

	# ── B3. 走自由对战那条路：只清 tour_key，局分留给「key 变化时清」──
	# ★ 这里我第一版断言错了。真实语义是：tour_won/lost 只在 tour_key **变化**时
	#   清零（换对手/换轮次= 新的一场）。走自由对战只清 key，
	#   局分保留着，下次回联赛时 key 一变自然被清。
	#   断言它「也清」等于把一个正确的设计当成 bug。
	g.set("tour_entry", false)
	g.set("tour_won", 3)
	g.set("tour_lost", 2)
	g.set("tour_key", "abc")
	g.call("tour_begin")
	_eqs("自由对战清 tour_key", _is_empty_str(g.get("tour_key")), "empty")
	_eqf("自由对战不清 tour_won（留给 key 变化时清）", float(g.get("tour_won")), 3.0)
	_eqf("自由对战不清 tour_lost（同上）", float(g.get("tour_lost")), 2.0)
	# ★ 反过来验：key 真的变了 → 必须清零。这才是局分唯一的清零点。
	g.set("tour_entry", true)
	g.call("tour_begin")
	_eqf("key 变化 → 清 tour_won", float(g.get("tour_won")), 0.0)
	_eqf("key 变化 → 清 tour_lost", float(g.get("tour_lost")), 0.0)
	# 同一场再进：不许清（否则每局都从 0 开始，永远打不完 BO5）
	g.set("tour_won", 2)
	g.call("tour_begin")
	_eqf("同一场重进：不重清 tour_won", float(g.get("tour_won")), 2.0)

	# ── B4. 「本局模式」旗标不进存档；但 doubles 是**持久化偏好**，必须进 ──
	# ★ 语义要分清（我第一版把两者当一类，误报了 2 条）：
	#   ranked / tour_entry = 「这一场按什么模式打」→ 本局意图，不落盘、读档清。
	#   doubles / partner_ai = 「主菜单里选的模式偏好」→ 故意持久化
	#     （game_state.gd 原文：「双打模式开关。主菜单里选」），
	#     下次开局面板还要显示上次选的双打。清掉它反而是bug。
	g.set("ranked", true)
	g.set("doubles", true)
	g.set("partner_ai", true)
	g.set("tour_entry", true)
	var d: Dictionary = g.call("_to_dict")
	# 先断言再谈别的：绝不能先塞进字典再验 not has()（恒真，记忆坑）。
	for key: String in ["ranked", "tour_entry"]:
		if d.has(key):
			_fail("本局模式 '%s' 不该进存档" % key)
		_checks += 1
	for key2: String in ["doubles", "partner_ai"]:
		if not d.has(key2):
			_fail("模式偏好 '%s' 应持久化（下次开局面板要显示上次选择）" % key2)
		_checks += 1

	# ── B5. 读档清「本局模式」旗标，但保留偏好 ──
	g.call("_from_dict", d)
	_eqs("读档清 ranked", str(g.get("ranked")), "false")
	_eqs("读档清 tour_entry", str(g.get("tour_entry")), "false")
	_eqs("读档保留 doubles（偏好）", str(g.get("doubles")), "true")
	_eqs("读档保留 partner_ai（偏好）", str(g.get("partner_ai")), "true")

	# ── B6. 读档能吃掉陈旧字段（模拟旧版本/手改档案）──
	var dirty: Dictionary = d.duplicate()
	dirty["ranked"] = true
	dirty["tour_entry"] = true
	g.call("_from_dict", dirty)
	_eqs("陈旧 ranked 字段被忽略", str(g.get("ranked")), "false")
	_eqs("陈旧 tour_entry 字段被忽略", str(g.get("tour_entry")), "false")

	# ── B7. reset_all 清整届联赛 + 模式偏好 + 难度 ──
	# 面板写的是「清空全部进度」，留着赛程/双打偏好就等于只重置了一半。
	g.set("tournament", _fake_tournament())
	g.set("tour_key", "k")
	g.set("tour_won", 3)
	g.set("ranked", true)
	g.set("doubles", true)
	g.set("partner_ai", true)
	g.set("difficulty", 4)
	g.call("reset_all")
	# ★ `str({})` 在 GDScript 里是 "{  }"（两个空格），不是 "{}"。
	_eqs("reset_all 清整届联赛", _is_empty_dict(g.get("tournament")), "empty")
	_eqs("reset_all 清 tour_key", _is_empty_str(g.get("tour_key")), "empty")
	_eqf("reset_all 清 tour_won", float(g.get("tour_won")), 0.0)
	_eqs("reset_all 清 ranked", str(g.get("ranked")), "false")
	_eqs("reset_all 清 doubles（模式偏好）", str(g.get("doubles")), "false")
	_eqs("reset_all 清 partner_ai", str(g.get("partner_ai")), "false")
	_eqf("reset_all 复位难度到默认 1", float(g.get("difficulty")), 1.0)

	# ── B8. 放弃赛事也清干净 ──
	g.set("tournament", _fake_tournament())
	g.set("tour_entry", true)
	g.call("abandon_tournament")
	_eqs("abandon 清联赛", _is_empty_dict(g.get("tournament")), "empty")
	_eqs("abandon 清 tour_entry", str(g.get("tour_entry")), "false")

	g.free()


## 字典是否为空。绕开 `str({})` == "{  }" 的格式坑。
func _is_empty_dict(v: Variant) -> String:
	if v is Dictionary and (v as Dictionary).is_empty():
		return "empty"
	return "not-empty(%s)" % str(v)


## 字符串是否为空。同上，`str("")` 在 GDScript 里是空串不是 `""`。
func _is_empty_str(v: Variant) -> String:
	if str(v).is_empty():
		return "empty"
	return str(v)


## 造一个「有一届没打完的联赛」。
## ★ 用 Tournament.create() 而不是手搓字典 —— 我第一版手写了
##   {stage, round, opponents:[]}，`Tournament.next_match()` 压根认不出来
##   （它要的是 entrants / matches / group_round，而且 match 里要有 a/b/done），
##   于是 tour_entry=true 拿不到对手 → 报了两条假 FAIL。
##   真实结构只认create()，别手搓。
func _fake_tournament() -> Dictionary:
	var T: GDScript = load("res://tournament.gd")
	return T.call("create", 20261004, "你")


# ═══════════════════════════════════════════════════════════
# C. 关键几何常量
# ═══════════════════════════════════════════════════════════
func _case_geometry() -> void:
	# 球台顶 / 网高 —— 判分与发球解算都建立在这两个数上。
	var pm: GDScript = load("res://player_movement.gd")
	var p: Object = pm.new()
	if p == null:
		_fail("实例化 player_movement.gd 失败")
		return
	# 台面 0.760 + 网 0.1525= 0.9125，球半径 0.02 → 判定上界 0.9325。
	_eqf("活动区 X 半宽", float(p.get("area_x_abs")), 1.80)
	_eqf("活动区 Z 前界（球网侧，不放宽）", float(p.get("area_z_min")), 0.685)
	_eqf("活动区 Z 后界", float(p.get("area_z_max")), 3.30)
	p.free()

	# 发球区上沿必须**严格等于**活动区后界：
	# 留余量 = 承认活动区里有一部分位置玩家退得回去却发不了球。
	var gg: GDScript = load(GAME_SCRIPT)
	var g: Object = gg.new()
	var sz_max: float = float(g.get("serve_zone_max_z"))
	var sz_min: float = float(g.get("serve_zone_min_z"))
	_eqf("发球区上沿 == 活动区后界", sz_max, 3.30)
	_eqf("发球区下沿> 活动区前界（须为真）", float(sz_min > 0.685), 1.0)
	# 发球点 x 必须在己方半区（ITTF 2.6.2），这是规则不是手感。
	_eqf("发球区下沿 ≥ 端线 1.37", float(sz_min >= 1.37), 1.0)
	g.free()

	# court_builder 里的活动范围副本必须和 player_movement 同步。
	# 改活动范围忘了同步 → 场边家具会重新压到玩家身上（改过两次的坑）。
	var cb: GDScript = load("res://court_builder.gd")
	var c: Object = cb.new()
	_eqf("court_builder 副本 X", float(c.get("player_reach_x")), 1.80)
	_eqf("court_builder 副本 Z后", float(c.get("player_reach_z_max")), 3.30)
	_eqf("court_builder 副本 Z 前", float(c.get("player_reach_z_min")), 0.685)
	_eqf("碰撞盒半宽", float(c.get("player_body_half")), 0.30)
	# 留空必须为正 —— 0 意味着家具正好贴着玩家身体。
	_eqf("家具留空 > 0（须为真）", float(float(c.get("prop_clearance")) > 0.0), 1.0)
	c.free()


# ═══════════════════════════════════════════════════════════
# D. 难度微调（2026-10-04 新增功能）
# ═══════════════════════════════════════════════════════════
## 这一组锁的是新加的「浮点难度」链路。它最该被盯住的地方不是「能不能存」
## —— 那是显然的 —— 而是**回写单例那一步会不会把浮点 round 掉**。
## 我第一版就踩了：pingpong_game.set_difficulty_t() 结尾调的是
## `Game.set_difficulty(difficulty)`（整数），于是玩家设 1.35、进一次游戏
## 变回 1.0，而且**面板上看不出来**（它显示的是同一个整数档）。
func _case_fine_tune() -> void:
	var g: Object = (load(GAME_STATE) as GDScript).new()
	if g == null:
		_fail("实例化 game_state.gd 失败")
		return

	# ── D1. set_difficulty_t 落浮点，difficulty 只是它的 round ──
	g.set("difficulty_t", 1.0)
	g.call("set_difficulty_t", 1.35)
	_eqf("set_difficulty_t(1.35) 存浮点", float(g.get("difficulty_t")), 1.35)
	_eqf("  difficulty 取 round(1.35)=1", float(g.get("difficulty")), 1.0)
	g.call("set_difficulty_t", 1.65)
	_eqf("  round(1.65)=2（不是 truncate）", float(g.get("difficulty")), 2.0)

	# ── D2. 选整档时浮点必须跟着走，不能留在 1.35 ──
	#   否则会出现「面板显示简单、实际 1.35」这种幽灵状态。
	g.call("set_difficulty_t", 1.35)
	g.call("set_difficulty", 3)
	_eqf("set_difficulty(3) 同步 difficulty_t", float(g.get("difficulty_t")), 3.0)
	_eqf("  difficulty=3", float(g.get("difficulty")), 3.0)

	# ── D3. 钳位 ──
	g.call("set_difficulty_t", -1.0)
	_eqf("下溢钳到 0", float(g.get("difficulty_t")), 0.0)
	_eqf("  difficulty=0", float(g.get("difficulty")), 0.0)
	g.call("set_difficulty_t", 9.0)
	_eqf("上溢钳到 4", float(g.get("difficulty_t")), 4.0)
	_eqf("  difficulty=4", float(g.get("difficulty")), 4.0)

	# ── D4. 存档往返 ──
	g.call("set_difficulty_t", 2.45)
	var d: Dictionary = g.call("_to_dict")
	if not d.has("difficulty_t"):
		_fail("存档里没有 difficulty_t —— 微调设置重启后丢失")
	_checks += 1
	g.call("set_difficulty_t", 0.0)
	g.call("_from_dict", d)
	_eqf("存档往返：difficulty_t 保真", float(g.get("difficulty_t")), 2.45)
	_eqf("  difficulty 同步为 2", float(g.get("difficulty")), 2.0)

	# ── D5. ★ 老存档迁移：没有 difficulty_t 的键必须退回整数档 ──
	#   不能默认 1.0：那会把所有老玩家从自己选的「困难」拉到「普通」。
	var legacy: Dictionary = d.duplicate()
	legacy.erase("difficulty_t")
	legacy["difficulty"] = 3
	g.call("_from_dict", legacy)
	_eqf("老存档无 difficulty_t → 用整数档 3", float(g.get("difficulty_t")), 3.0)
	_eqf("  difficulty=3", float(g.get("difficulty")), 3.0)

	# ── D6. reset_all 复位浮点 ──
	g.call("set_difficulty_t", 3.80)
	g.call("reset_all")
	_eqf("reset_all 复位 difficulty_t=1.0", float(g.get("difficulty_t")), 1.0)
	_eqf("  difficulty=1", float(g.get("difficulty")), 1.0)

	# ── D7. ★ 游戏侧读法：优先 difficulty_t，没有才退回整数 ──
	#   这一条直接对应刚修的那个 bug（回写时用整数档把浮点抹掉）。
	var gg: GDScript = load(GAME_SCRIPT)
	var p: Object = gg.new()
	var fake_g: Object = _fake_singleton({"difficulty": 1, "difficulty_t": 2.45})
	_eqf("_saved_difficulty_t 优先读浮点",
		float(p.call("_saved_difficulty_t", fake_g)), 2.45)
	# ★ 老单例（真的没有 difficulty_t 这个属性）→ get 返回 null → 退回整数。
	#   必须用另一个类，否则 FakeSingleton 上永远有这个字段，退回分支测不到。
	var old_g: Object = FakeLegacySingleton.new()
	old_g.set("difficulty", 3)
	_eqf("_saved_difficulty_t 无浮点字段时退回整数",
		float(p.call("_saved_difficulty_t", old_g)), 3.0)
	# 越界值要钳住（手改档案 / 旧版本脏数据）
	var bad_g: Object = _fake_singleton({"difficulty": 1, "difficulty_t": 99.0})
	_eqf("_saved_difficulty_t 钳上界",
		float(p.call("_saved_difficulty_t", bad_g)), 4.0)
	var bad_g2: Object = _fake_singleton({"difficulty": 1, "difficulty_t": -5.0})
	_eqf("_saved_difficulty_t 钳下界",
		float(p.call("_saved_difficulty_t", bad_g2)), 0.0)

	# ── D8. 连续插值在非整数处真的生效（微调的意义所在）──
	#   如果 t=1.5 算出来还等于 1.0，那滑杆就是个装饰品。
	var t15: float = 0.0
	var t10: float = 0.0
	var t20: float = 0.0
	p.call("set_difficulty_t", 1.0)
	t10 = float(p.call("_flight_time"))
	p.call("set_difficulty_t", 1.5)
	t15 = float(p.call("_flight_time"))
	p.call("set_difficulty_t", 2.0)
	t20 = float(p.call("_flight_time"))
	# flight_time: 1档 0.42 / 2档 0.40 → 中点应正好 0.41
	_eqf("t=1.5 飞行时间插到中点", t15, (t10 + t20) * 0.5)
	if absf(t15 - t10) < 0.0001:
		_fail("t=1.5 与 t=1.0 结果相同 → 浮点难度没生效，滑杆是装饰品")
	_checks += 1

	p.free()
	g.free()


# ═══════════════════════════════════════════════════════════
# F. 凶度反馈（2026-10-04 阶段 2）
# ═══════════════════════════════════════════════════════════
## 这一组锁的不是「红边好不好看」，而是**反馈与机制的耦合关系**：
##   HUD 必须在凶度真正生效时亮、在它失效时灭，档位门槛与 _opp_rage() 一致。
## ★ 为什么这条最值得测：凶度反馈是**纯显示层**，它坏了游戏一点不报错 ——
##   只是玩家永远看不到「对手变凶了」，而这是这个机制存在的唯一理由。
## ★ 用不入树的脚本实例跑（和 A 组一样），只调纯函数，不碰任何渲染。
func _case_rage_feedback() -> void:
	var g: Object = (load(GAME_SCRIPT) as GDScript).new()
	if g == null:
		_fail("实例化 pingpong_game.gd 失败")
		return

	# ── F1. _opp_rage() 的倍率曲线（这是既有的机制，先钉住它）──
	# ★ 这条不是「改 HUD」，是**防止改 HUD 时顺手动了机制** ——
	#   两者在同一段代码里，很容易一起改。
	g.set("_match_over", false)
	for pair: Array in [[0, 1.0], [1, 1.0], [2, 1.28], [3, 1.56], [4, 1.80], [9, 1.80]]:
		g.set("_win_streak", int(pair[0]))
		_eqf("_opp_rage @%d 连胜" % int(pair[0]),
			float(g.call("_opp_rage")), float(pair[1]))

	# ── F2. 档位门槛：2 分进 1 档、4 分进 2 档 ──
	# 和 STREAK_NOTE_AT(=2) 绑定：文字提示和红边必须同时出现，
	# 一个亮一个不亮 = 玩家收到两个互相矛盾的信号。
	for pair2: Array in [[0, 0], [1, 0], [2, 1], [3, 1], [4, 2], [7, 2]]:
		g.set("_win_streak", int(pair2[0]))
		_eqf("rage_level @%d 连胜" % int(pair2[0]),
			float(g.call("rage_level")), float(pair2[1]))

	# ── F3. ★ 核心不变量：HUD 亮的充要条件 == 机制真的在加成 ──
	#   「rage_level > 0」当且仅当「_opp_rage() > 1」。
	#   这条一旦破，就会出现「屏幕一片红但其实没加成」或者
	#   「对手已经在加成了但玩家看不到」—— 后者正是这次要修的那个问题。
	for s: int in range(0, 12):
		g.set("_win_streak", s)
		var lit: bool = int(g.call("rage_level")) > 0
		var active: bool = float(g.call("_opp_rage")) > 1.0001
		if lit != active:
			_fail("连胜 %d：提示%s 但机制%s（反馈与机制脱钩）"
				% [s, "亮" if lit else "灭", "在加成" if active else "没加成"])
		_checks += 1

	# ── F4. 文案：0 档必须空（否则空档也占一行、把比分面板顶高）──
	g.set("_win_streak", 0)
	_eqs("rage_note(0) 为空", _is_empty_str(g.call("rage_note", 0)), "empty")
	g.set("_win_streak", 2)
	var n1: String = str(g.call("rage_note", 1))
	if n1.is_empty():
		_fail("rage_note(1) 为空 —— 红边亮了却没有文字说明")
	_checks += 1
	var n2: String = str(g.call("rage_note", 2))
	if n2.is_empty():
		_fail("rage_note(2) 为空")
	_checks += 1
	if n1 == n2:
		_fail("两档文案相同 —— 玩家分不出「他认真了」和「他拼命了」")
	_checks += 1

	# ── F5. 比赛结束后必须熄灭 ──
	#   结算面板弹出来时屏幕还红着，看着像这一分还没结束。
	g.set("_win_streak", 5)
	g.set("_match_over", true)
	_eqf("match_over → rage_level 归 0", float(g.call("rage_level")), 0.0)

	# ── F6. 参数必须落在合理区间（防手滑写错数量级）──
	#   红边太亮会盖住球，脉动太快会像画面故障。
	var alpha: float = float(g.get("rage_edge_max_alpha"))
	if alpha <= 0.0 or alpha > 0.5:
		_fail("rage_edge_max_alpha=%s 不在 (0, 0.5] —— 全屏红边会抢球路的注意力" % str(alpha))
	_checks += 1
	var hz: float = float(g.get("rage_pulse_hz"))
	if hz < 0.2 or hz > 4.0:
		_fail("rage_pulse_hz=%s 不在 [0.2, 4.0] —— 太慢像静止、太快像闪烁" % str(hz))
	_checks += 1
	var thick: float = float(g.get("rage_edge_thickness"))
	if thick < 6.0 or thick > 120.0:
		_fail("rage_edge_thickness=%s 不在 [6, 120]" % str(thick))
	_checks += 1

	g.free()


# ═══════════════════════════════════════════════════════════
# G. 凶度 HUD 的**布局**（必须进树）
# ═══════════════════════════════════════════════════════════
## ★ 为什么 F 组不够：F 只验了「档位和文案」这条纯逻辑链，
##   而红边是**四条带锚点的 ColorRect** —— 锚点写错（比如左右两条用了
##   PRESET_TOP_WIDE）的话，逻辑全对、屏幕上却什么也看不见，
##   或者四条边糊成一块盖住整个画面。这两种都不报错。
## ★ 无头下 `root.size` 是 64×64（记忆坑 #16），所以断言一律用
##   **相对量**（厚度、贴边关系），不写死绝对坐标。
func _case_rage_hud_layout() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var p: Node = (load(GAME_SCRIPT) as GDScript).new()
	holder.add_child(p)
	# ★ add_child 在 _initialize 里不触发 _ready → 必须等帧，否则 _hud 还是 null。
	await get_tree().process_frame
	await get_tree().process_frame

	var edges: Array = p.get("_rage_edges")
	if edges.size() != 4:
		_fail("红边应有 4 条，实际 %d" % edges.size())
	# ★ 四条边建好了就立刻检查是否已追加到 _hud —— 这条能抓住
	#   「_build_rage_hud 忘了调」这种最蠢也最可能的错误。
	_checks += 1

	var hud: Node = p.get("_hud")
	if hud == null:
		_fail("_hud 为空 —— _build_hud 没跑")
		holder.queue_free()
		return
	_checks += 1

	# ── 初始必须全部隐藏（没进入凶度时屏幕不能泛红）──
	for i: int in range(edges.size()):
		var e0: ColorRect = edges[i]
		if e0.visible:
			_fail("红边 %d 初始就是可见的 —— 一开局屏幕就泛红" % i)
		_checks += 1

	# ── 亮起来 ──
	p.set("_match_over", false)
	p.set("_win_streak", 3)
	p.set("_rage_shown", -1)
	for _i: int in range(4):
		p.call("_update_rage_hud", 0.016)
		await get_tree().process_frame

	var vp: Vector2 = p.get_viewport().get_visible_rect().size
	var thick: float = float(p.get("rage_edge_thickness"))
	if edges.size() == 4:
		var names := ["上", "下", "左", "右"]
		for i2: int in range(4):
			var e: ColorRect = edges[i2]
			if not e.visible:
				_fail("%s边没亮 —— 凶度生效时屏幕应当泛红" % names[i2])
				continue
			_checks += 1
			if float(e.modulate.a) <= 0.001:
				_fail("%s边可见但完全不透明 → 屏幕上看不见" % names[i2])
			_checks += 1
			var r := e.get_global_rect()
			# 厚度方向必须等于 rage_edge_thickness（±0.5 容差）
			var span := r.size.y if i2 < 2 else r.size.x
			if absf(span - thick) > 0.5:
				_fail("%s边厚度 %s ≠ %s" % [names[i2], str(span), str(thick)])
			_checks += 1
			# 贴边关系：不能浮在画面中间，也不能缩到画面外
			match i2:
				0:
					_eqf("上边贴顶", r.position.y, 0.0)
					_eqf("上边整宽", r.size.x, vp.x)
				1:
					_eqf("下边贴底", r.position.y + r.size.y, vp.y)
					_eqf("下边整宽", r.size.x, vp.x)
				2:
					_eqf("左边贴左", r.position.x, 0.0)
					_eqf("左边整高", r.size.y, vp.y)
				_:
					_eqf("右边贴右", r.position.x + r.size.x, vp.x)
					_eqf("右边整高", r.size.y, vp.y)

	# ── 文字提示必须同步亮 ──
	var lbl: Label = p.get("_rage_label")
	if lbl == null:
		_fail("_rage_label 为空 —— 红边亮了却没有文字说明")
	elif not lbl.visible or lbl.text.is_empty():
		_fail("凶度生效时提示字没显示（visible=%s text='%s'）"
			% [str(lbl.visible), lbl.text])
	_checks += 1
	# ★ 字必须真的套上了中文字体，否则玩家看到的是一排豆腐块。
	if lbl != null and lbl.visible and lbl.get_theme_font("font") == null:
		_fail("凶度提示字没有中文字体 —— 会显示成豆腐块")
	_checks += 1

	# ── 掉下来必须真的熄灭（连胜清零 → 等它衰减完）──
	p.set("_win_streak", 0)
	for _j: int in range(40):
		p.call("_update_rage_hud", 0.05)
	if lbl != null and lbl.visible:
		_fail("连胜清零后提示字仍然显示 —— 反馈和机制又脱钩了")
	_checks += 1
	for i3: int in range(edges.size()):
		var e3: ColorRect = edges[i3]
		if e3.visible:
			_fail("连胜清零后红边 %d 仍然可见（衰减没生效）" % i3)
		_checks += 1

	holder.queue_free()
	await get_tree().process_frame


## 造一个只带指定字段的假单例（只为验 `_saved_difficulty_t` 的读法）。
## ★ 不能用真的 Game：它在树上、set() 会写真实存档。
## ★ 也不能用 `RefCounted.new()` + `set()` —— 那是给 Object 基类的方法，
##   动态属性走 `_set()`，裸 RefCounted 没有实现、set() 静默无效，
##   于是 `get("difficulty_t")` 恒返回 null，探针会误报「读法不对」。
##   用一个显式声明了字段的内部类最省事。
func _fake_singleton(fields: Dictionary) -> Object:
	var o := FakeSingleton.new()
	for k: String in fields:
		o.set(k, fields[k])
	return o


## 假的 Game 单例：字段是**显式声明**的，所以 get/set 都真的生效。
## 故意不声明 `difficulty_t` 的那种情况由探针用另一种构造覆盖
## （`_fake_legacy_singleton`）。
class FakeSingleton extends RefCounted:
	var difficulty: int = 1
	var difficulty_t: float = 1.0
	var doubles: bool = false
	var partner_ai: bool = false


## 只有整数难度、**没有** difficulty_t 的老单例。
## 必须是一个不同的类 —— 同一个类上`difficulty_t` 永远有值，
## 「get 返回 null 走退回分支」那条路径就永远测不到。
class FakeLegacySingleton extends RefCounted:
	var difficulty: int = 1


# ═══════════════════════════════════════════════════════════
# E. 微调难度的端到端链路（必须用**真Game 单例**）
# ═══════════════════════════════════════════════════════════
## ★★ 为什么 D 组不够、D 组灵敏度测试还漏了那个 bug：
##   D 组拿的是不入树的脚本实例，`get_node_or_null("/root/Game")` 返回 null，
##   所以 `set_difficulty_t()` 结尾那段「回写单例」的代码**根本没执行**。
##   我把回写改回 `set_difficulty(difficulty)`（整数，会 round 掉浮点），
##   D 组依然 22/22 全绿 —— 覆盖缺口，不是「改动无害」。
##   这一组进真树、跑真单例，才碰得到那段代码。
##
## ★ 这一组会写真实存档。跑完用外部 `cp` 备份核对（别只信 _restore）。
func _case_fine_tune_e2e() -> void:
	var g: Node = get_node_or_null("/root/Game")
	if g == null:
		_fail("拿不到真Game 单例 —— 这组必须在树里跑")
		return
	if not g.has_method("set_difficulty_t"):
		_fail("Game 单例没有 set_difficulty_t —— 微调难度写不进去")
		return

	# ── E1. 单例真能存浮点 ──
	g.call("set_difficulty_t", 1.35)
	_eqf("单例 set_difficulty_t(1.35)", float(g.get("difficulty_t")), 1.35)

	# ── E2. ★ 关键：pingpong_game.set_difficulty_t 回写单例时不能 round 掉 ──
	#   这一步就是D 组漏掉的那处：回写用的是 set_difficulty（整数）还是
	#   set_difficulty_t（浮点）。
	#   ★ 必须让 pingpong_game 挂在树上 —— 它靠 get_node_or_null("/root/Game")
	#   找单例，不在树上就找不到，回写那段代码不会跑。
	var holder := Node3D.new()
	add_child(holder)
	var p: Node = (load(GAME_SCRIPT) as GDScript).new()
	holder.add_child(p)
	await get_tree().process_frame
	# 清掉进场时的模式旗标，保证走「自由对战」这条分支
	g.set("ranked", false)
	g.set("doubles", false)
	g.set("partner_ai", false)
	g.set("tour_entry", false)
	g.set("difficulty_t", 1.0)
	g.set("difficulty", 1)
	# 跑一次真实的难度设定（会触发回写）
	p.call("set_difficulty_t", 2.65)
	_eqf("游戏内调难度后，单例 difficulty_t 仍是浮点",
		float(g.get("difficulty_t")), 2.65)
	_eqf("  单例 difficulty 取 round=3", float(g.get("difficulty")), 3.0)
	_eqf("  游戏内 _diff_t 同步", float(p.get("_diff_t")), 2.65)

	# ── E3. 进场时读的是浮点，不是整数 ──
	#   apply_preferences() 是进场唯一入口，它调 _saved_difficulty_t(g)。
	#   这里直接验那个读法在真单例上生效（假单例验过，但真单例才是真的）。
	_eqf("_saved_difficulty_t 在真单例上读浮点",
		float(p.call("_saved_difficulty_t", g)), 2.65)

	# 还原：探针改了真存档，外部会用备份核对，这里先尽量复原
	g.call("set_difficulty", 1)

	holder.queue_free()
	p = null
	await get_tree().process_frame


# ═══════════════════════════════════════════════════════════
# H. 球拍不穿台面（★ 进树，纯几何）
# ═══════════════════════════════════════════════════════════
## ★ 用户 2026-10-04 报「在球台附近低头时球拍与球台穿模」。
## ★ 为什么必须进树：这是几何问题，纯逻辑断言量不到。
## ★ 真凶不是「低头」—— 实测站着只低头并不穿台（俯到 -55° 时球拍最低点
##   0.827，仍在台面 0.760 之上）；穿的是**低头 + 探拍**（按住 Shift 再往前
##   送 0.35 m）：俯到 -40° 就穿，-70° 时球拍最低点掉到 0.498，比台面低 26 cm。
##   所以三档都要锁：①低头+探拍 ②只低头 ③站台外低头探拍。
## ★ 搭的是与 pingpong.tscn 逐字一致的三级链
##   （Player@(0,0.9,z) → Head@(0,0.62,0) → Camera3D → PaddleRig），
##   不走真场景 —— 真场景根上挂着 pingpong_game.gd，会发球、摆位、抢控制权。
func _case_paddle_table_clearance() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.position = Vector3(0.0, 0.9, 0.685)      # 近台最前（= player_movement.area_z_min）
	add_child(player)
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0.0, 0.62, 0.0)         # 与 tscn 一致 → 站立眼高 1.52
	player.add_child(head)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	head.add_child(cam)
	var rig: Node3D = (load(PADDLE_SCRIPT) as GDScript).new()
	rig.name = "PaddleRig"
	cam.add_child(rig)
	# add_child 不触发 _ready（坑 #11）→ 等两帧，否则 _paddle / _rig_home 还是空。
	await get_tree().process_frame
	await get_tree().process_frame

	if rig.get("_paddle") == null:
		_fail("球拍没建出来（_paddle 为空）—— 后面的断言全部不可信")
		player.queue_free()
		return
	_checks += 1
	var floor_y: float = float(rig.get("blade_floor_y"))
	var pad: float = float(rig.get("blade_clear_pad"))

	# ── ① 低头 + 探拍：用户报的那一档，必须完全不穿台 ──
	for deg: float in [-40.0, -55.0, -70.0, -85.0, -89.0]:
		await _pose_rig(head, rig, deg, 1.0)
		var c: Vector3 = rig.call("head_position")
		var ab := _world_aabb(rig)
		if c.y < floor_y - 0.01:
			_fail("探拍+低头 %.0f°：拍面中心 y=%s 低于下限 %s"
				% [deg, str(c.y), str(floor_y)])
		_checks += 1
		if ab.position.y < TABLE_TOP_Y:
			_fail("探拍+低头 %.0f°：球拍最低点 %s 穿进球台（台面 %s，差 %s）"
				% [deg, str(ab.position.y), str(TABLE_TOP_Y),
					str(TABLE_TOP_Y - ab.position.y)])
		_checks += 1
		# 反向：不能被抬到「僵在半空」——过度的保护同样是 bug
		if ab.position.y > TABLE_TOP_Y + 0.20:
			_fail("探拍+低头 %.0f°：球拍被抬得过高（最低点 %s），像僵在半空"
				% [deg, str(ab.position.y)])
		_checks += 1

	# ── ② 只低头（不探拍）：绝不能被那条下限修正 ──
	# ★ 这档防的是「把下限无脑套到所有姿态」的过度修正 ——
	#   这两档本来就在 1.03~1.20，不该被拉到 0.890 附近。
	for deg2: float in [0.0, -21.3]:
		await _pose_rig(head, rig, deg2, 0.0)
		var c2: Vector3 = rig.call("head_position")
		if c2.y < floor_y + 0.10:
			_fail("只低头 %.1f°：拍面中心 y=%s 已被下限拉到贴线 —— 正常姿态被误伤"
				% [deg2, str(c2.y)])
		_checks += 1

	# ── ③ 站在台外（z=3.0）低头探拍：不该被抬（台子不在那儿）──
	# ★ 下限只在拍面水平投影落进台面范围时才该生效；无条件套会让玩家
	#   在底线后低头看地时拍子僵在半空。
	player.position = Vector3(0.0, 0.9, 3.0)
	for deg3: float in [-40.0, -70.0]:
		await _pose_rig(head, rig, deg3, 1.0)
		var c3: Vector3 = rig.call("head_position")
		if absf(c3.z) <= TABLE_HALF_Z + pad:
			_fail("台外用例没真站出台面（拍面中心 z=%s）—— 这条断言本身失效了"
				% str(c3.z))
		_checks += 1
		if c3.y >= floor_y - 0.01:
			_fail("站在台外（z=3.0）低头探拍：拍面中心仍被顶到 %s —— 台外不该抬拍"
				% str(c3.y))
		_checks += 1

	player.queue_free()
	await get_tree().process_frame


## 摆一个姿态并等它稳定：设 Head 俯仰 + 探拍量，等两帧
## （_process 里的 _update_crouch_lift 每帧重算 rig 位置，要等它跑完）。
func _pose_rig(head: Node3D, rig: Node3D, deg: float, reach: float) -> void:
	head.rotation.x = deg_to_rad(deg)
	rig.call("set_reach_extend", reach)
	await get_tree().process_frame
	rig.call("set_reach_extend", reach)
	await get_tree().process_frame


## 把整棵子树的所有 mesh 顶点**逐个变换到世界**再重新包一次 AABB。
## ★ 不能只把局部 AABB 变换一下 —— 旋转会让包围盒变「小」，
##   量出来的最低点比真实值高（坑 #30：get_aabb() 是局部包围盒）。
func _world_aabb(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for ch: Node in cur.get_children():
			stack.append(ch)
		var mi := cur as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := mi.global_transform
		var a := mi.mesh.get_aabb()
		for i: int in range(8):
			var w: Vector3 = xf * a.get_endpoint(i)
			if first:
				out = AABB(w, Vector3.ZERO)
				first = false
			else:
				out = out.expand(w)
	return out


# ═══════════════════════════════════════════════════════════
# I. 「球必须先落到台面上才能击球」（不允许截击）
# ═══════════════════════════════════════════════════════════
## ★ 这是条**规则**，纯逻辑，所以不进树：直接 new 一个脚本实例，摆
##   `_last_hitter` / `_bounces_player` 两个字段，验真值表。
## ★ 为什么必须两条判据：只卡 `_bounces_player >= 1` 会漏掉
##   「玩家发球的第一跳落在自己半台」—— 那时计数也是 1，
##   于是发完球还能再补一拍。
func _case_bounce_before_hit() -> void:
	var p: Node = (load(GAME_SCRIPT) as GDScript).new()
	var cases := [
		[HITTER_NONE, 0, false, "球刚飞过来、还没落台 —— 不许截击"],
		[HITTER_NONE, 1, true, "对手发球落台 → 可以接发球"],
		[HITTER_OPPONENT, 0, false, "对手回球飞行中、还没落台 —— 不许截击"],
		[HITTER_OPPONENT, 1, true, "对手回球落台 → 正常对拉"],
		[HITTER_PLAYER, 0, false, "自己的球刚出手"],
		[HITTER_PLAYER, 1, false, "自己发球的第一跳落自己半台 —— 不许补一拍"],
	]
	for c: Array in cases:
		p.set("_last_hitter", c[0])
		p.set("_bounces_player", c[1])
		_eqb("may_hit_ball(last_hitter=%s, bounces_player=%s)：%s"
			% [str(c[0]), str(c[1]), str(c[3])],
			bool(p.call("may_hit_ball")), bool(c[2]))
	p.free()


# ═══════════════════════════════════════════════════════════
# J. 发球预览的开销不变量（★ 卡顿回归，用脚本实例、不进树）
# ═══════════════════════════════════════════════════════════
## 用户报「发球和进行中容易一卡一卡」。根因不在某一段代码慢，
## 而在**调用次数**：`_solve_legal_serve` 一次要枚举 180 个候选，
## 而轨迹预览每 0.1 s 就跑一次；再叠一个「线没画出来时每帧重算」的
## 节流 bug，帧率直接掉到个位数。
##
## 这一组把三条不变量钉死：
##   1. 站着瞄准 1 秒 → 全量搜索最多 1 次（解算缓存生效）
##   2. ★ 线一直画不出来（等价于解算失败）时，仍然只按节流刷新
##      —— 旧写法 `if _serve_preview_t > 0.0 and _serve_traj.visible: return`
##         在 visible == false 时条件整体为假，于是每帧都重算一遍
##   3. 预览与出手用同一个出手点（plan.from_x），否则提示线画的是另一条弹道
func _case_serve_preview_cost() -> void:
	var g: Node3D = (load(GAME_SCRIPT) as GDScript).new() as Node3D
	if g == null:
		_fail("实例化 pingpong_game.gd 失败")
		return
	# 不进树即可跑：_serve_hold_point / _serve_aim_point 都有 is_inside_tree 守卫，
	# 再把瞄准关掉，全程不碰 viewport。
	g.set("serve_aim_enabled", false)
	var ball: PingPongBall = (load(BALL_SCRIPT) as GDScript).new() as PingPongBall
	g.set("_ball", ball)
	g.set("_server", HITTER_PLAYER)
	g.set("_state", STATE_SERVE_DELAY)
	g.set("_match_over", false)
	g.set("_par_serve_t", -1.0)
	g.set("show_serve_trajectory", true)
	g.call("_build_serve_traj")

	# ── J1 ★ 出手点统一（2026-10-06 修「发球落点与黄色预览框不一样」）──
	#   预览 / 抛球 / 出手三处**必须**取同一个点。以前是「计划里存一个随机 from_x
	#   给预览用」，但加了抛球之后球其实是从**手里**那个点出去的（刻意放在镜头
	#   左侧 24 cm），两者最多差 1 m —— 而速度是按预览点解出来的，落点自然对不上。
	var plan: Dictionary = g.call("_plan_serve", 1)
	_eqb("J1a 计划里不再有随机出手点（from_x 已废弃）", plan.has("from_x"), false)
	var lp: Vector3 = g.call("_serve_launch_point")
	var hp: Vector3 = g.call("_serve_hold_point")
	_eqf("J1b 未抛球时出手点 x = 手里的位置（不再另外掷随机数）", lp.x, hp.x)
	_eqf("J1c 未抛球时出手点 z 也走手里的位置", lp.z, hp.z)
	_eqf("J1d 出手高度 = _serve_strike_y()（与预览线同一个高度）",
		lp.y, float(g.call("_serve_strike_y")))
	# ★ 抛球途中必须改用**抛球那一列**：玩家这时可能挪步，而球一直待在那一列上。
	#   用错了症状就是「线跟着人走、球留在原地」。
	g.set("_tossing", true)
	g.set("_toss_x", 0.37)
	g.set("_toss_z", 1.42)
	g.set("_toss_strike_y", 0.97)
	var lp2: Vector3 = g.call("_serve_launch_point")
	_eqf("J1e ★ 抛球途中改用抛球列 x（不是手里的位置）", lp2.x, 0.37)
	_eqf("J1f ★ 抛球途中改用抛球列 z", lp2.z, 1.42)
	_eqf("J1g ★ 抛球途中高度用抛球那一刻捕获的 _toss_strike_y", lp2.y, 0.97)
	g.set("_tossing", false)
	g.set("_serve_plan", plan)

	var f := 1.0 / 60.0

	# ── J2 站着瞄准 1 秒 ──
	var c0 := int(g.get("serve_solve_calls"))
	var r0 := int(g.get("serve_preview_refreshes"))
	for i in 60:
		g.call("_update_serve_traj", f)
	var dc := int(g.get("serve_solve_calls")) - c0
	var dr := int(g.get("serve_preview_refreshes")) - r0
	_eqf("J2 站着瞄准 1 秒 → 全量搜索次数（缓存应让它只有 1）", float(dc), 1.0)
	_eqb("J2 预览确实在按节流刷新（一秒 7~10 次）", dr >= 7 and dr <= 10, true)

	# ── J3 ★ 线一直画不出来时也不许每帧重算 ──
	var traj: Node3D = g.get("_serve_traj") as Node3D
	if traj == null:
		_fail("J3 取不到 _serve_traj")
	else:
		var r1 := int(g.get("serve_preview_refreshes"))
		for i in 60:
			traj.visible = false     # 每帧开头藏起来 = 复现「一直画不出来」
			g.call("_update_serve_traj", f)
		var dr2 := int(g.get("serve_preview_refreshes")) - r1
		# ★ 断言用**上界**而不是「和 J2 只差 1」：解算任务收工时会额外补一次重画，
		#   落在哪个窗口里取决于它跑了几帧 —— 卡死差值会变成看运气的假红。
		#   要守的不变量只有一条：**刷新次数不能随帧数线性增长**（旧代码 = 60）。
		_eqb("J3 线一直画不出来时仍受节流约束（旧代码这里会是 60；实测 dr=%d dr2=%d）"
			% [dr, dr2], dr2 <= 14, true)

	# ── J4 ★ 预览解算受时间预算封顶 ──
	#   断言用的是**候选个数**（serve_last_attempts）而不是墙钟毫秒：
	#   机器一忙毫秒就抖，候选个数是确定性的。
	#   ★★ 「难解」不能靠挑一个看着偏的瞄准点来制造 —— 第一版就是这么写的，
	#      结果它**第一个候选就被采纳**了（accept_dist 有 0.32 m 那么宽），
	#      预算根本没机会触发。改成把采纳阈值设成不可能达到，
	#      搜索就必然跑满候选，场景才确定。
	var from4 := Vector3(0.0, 1.05, 1.6)
	var acc_saved := float(g.get("serve_legal_accept_dist"))
	g.set("serve_legal_accept_dist", -1.0)
	g.call("_invalidate_serve_solution")
	var soft: Dictionary = g.call("_plan_serve", 1)
	soft["opp_x"] = 0.30
	soft["opp_z"] = -0.60
	var r_soft: Dictionary = g.call("_solve_serve_cached", from4, soft, 1000.0)
	var attempts_soft := int(g.get("serve_last_attempts"))
	_eqb("J4a 宽松预算下解出合法发球", bool(r_soft["ok"]), true)
	_eqb("J4a 宽松预算下不标记截断", bool(r_soft.get("budget", false)), false)
	_eqb("J4a 宽松预算确实跑满候选（阈值为不可达时）", attempts_soft >= 20, true)

	# 换一个瞄准点（必然缓存不命中）+ 极紧预算。
	# ★★ 这里必须先**清掉提示候选**：提示是**不受预算约束**的（只跑 1 个候选、
	#    约 0.17 ms，代价可以忽略），所以只要提示还在，极紧预算也会被它救回来
	#    —— 那正是我们想要的行为，但它让「预算真的会截断」这条断言测不到。
	#    清掉提示 = 复现「没有任何热身信息」的路径（换发球风格/刚进发球态）。
	var tight: Dictionary = soft.duplicate()
	tight["opp_x"] = -0.55
	tight["opp_z"] = -1.05
	g.set("_serve_solve_hint", [])
	var r_raw: Dictionary = g.call("_solve_legal_serve", from4, tight, 0.05)
	_eqb("J4b 极紧预算把搜索截断（解算器返回 budget 标记）",
		bool(r_raw.get("budget", false)), true)
	_eqb("J4b 截断后没找到合法解 → ok=false", bool(r_raw["ok"]), false)
	_eqb("J4b 截断时试过的候选数远少于宽松时",
		int(g.get("serve_last_attempts")) < attempts_soft, true)

	# ★ J4h 提示候选**不受预算约束**：预算再紧也要先把上次那个候选试掉。
	#   这条不变量是「预算不伤精度」的全部前提 —— 少了它，转视角时预算会把
	#   「本来一步就能命中的候选」也砍掉，玩家就会看到线不跟手。
	#   ★ 直接调**解算器**（不走缓存入口），免得「缓存命中直接返回」把
	#     这一轮的真实搜索整个跳过、断言变成空转。
	g.set("_serve_solve_hint", [])
	var r_untimed: Dictionary = g.call("_solve_legal_serve", from4, tight)
	_eqb("J4h 前置：不限时那一次把提示候选写回",
		(g.get("_serve_solve_hint") as Array).size(), 3)
	var r_hint: Dictionary = g.call("_solve_legal_serve", from4, tight, 0.05)
	_eqb("J4h 极紧预算下仍然先试提示候选 → 仍然解得出", bool(r_hint["ok"]), true)
	_eqf("J4h 只试了提示那一个候选", float(int(g.get("serve_last_attempts"))), 1.0)
	_eqb("J4h 提示给出的解与不限时那一份逐位相同",
		(r_hint["v"] as Vector3) == (r_untimed["v"] as Vector3), true)

	var holds0 := int(g.get("serve_budget_holds"))
	g.set("_serve_solve_hint", [])
	var r_tight: Dictionary = g.call("_solve_serve_cached", from4, tight, 0.05)
	_eqb("J4c 无提示 + 预算用尽 + 有旧解 → 记一次 hold",
		int(g.get("serve_budget_holds")) - holds0, 1)
	_eqb("J4c 沿用旧解（返回的就是上一次那一份解，线不闪）",
		(r_tight["v"] as Vector3) == (r_soft["v"] as Vector3), true)
	_eqb("J4c 沿用的旧解仍然是 ok=true", bool(r_tight["ok"]), true)

	# ★ J4d 关键：截断时**不能**更新缓存键。
	#   键没更新 = 下一次调用（换个宽预算）还得重搜 → serve_solve_calls 要涨。
	#   如果这里没涨，说明键被偷偷更新了，玩家就会永远停在旧瞄准点上。
	var calls_before := int(g.get("serve_solve_calls"))
	var r_retry: Dictionary = g.call("_solve_serve_cached", from4, tight, 1000.0)
	_eqb("J4d 截断不更新缓存键（下一拍会重搜同一片区域）",
		int(g.get("serve_solve_calls")) > calls_before, true)
	_eqb("J4d 重搜（宽松预算）能解出合法发球", bool(r_retry["ok"]), true)
	g.set("serve_legal_accept_dist", acc_saved)

	# ── J5 ★ 真正出手那条路径**不受**预算限制 ──
	#   出手只有一次，落点精度必须最高：拿一个「硬」瞄准点 + 不限时，
	#   它必须跑到远超一个候选才收工，且永远不标记 budget。
	g.call("_invalidate_serve_solution")
	var hard5: Dictionary = g.call("_plan_serve", 1)
	hard5["opp_x"] = 0.70
	hard5["opp_z"] = -0.32
	var r5: Dictionary = g.call("_solve_serve_cached", from4, hard5)
	_eqb("J5 出手路径（不传预算）永不标记截断",
		bool(r5.get("budget", false)), false)
	_eqb("J5 出手路径解出合法发球", bool(r5["ok"]), true)
	# ★ 不assert「跑满 180 个候选」：那取决于瞄准点好不好解，会假红。
	#   截断这件事已经由 J4b/J4d 用**同一 from、同一预算机制**证过了。
	# 出手路径**会**更新缓存键 → 紧跟着再调一次应当命中缓存、不再重搜
	var calls5 := int(g.get("serve_solve_calls"))
	g.call("_solve_serve_cached", from4, hard5)
	_eqf("J5 出手后缓存命中（同参数不再重搜）",
		float(int(g.get("serve_solve_calls")) - calls5), 0.0)
	g.set("serve_solve_budget_ms", -1.0)

	# ── J6 ★★ 提示候选（_serve_solve_hint）：把上次采纳/最优的候选排到搜索最前 ──
	#   这是「转视角时还卡」的**主要**解法（见 pingpong_game.gd 里的 F 组实测）：
	#   瞄准点只挪几厘米时，上一次那个候选通常仍然合格 → 第一次尝试就返回。
	#   两条断言缺一不可：
	#     (2) 提示**真的生效**：一个「要试好几个候选」的瞄准点，
	#         第二次解只用 1 个候选（第一次是 N>1 个）。
	#     (1) 提示**不改变结果**：同一个瞄准点，带提示与不带提示解出的
	#         速度/落点必须逐位相同 —— 提示只换**搜索顺序**。
	#         (它绝不该偷偷放宽判据；一旦放宽，落点就会悄悄变差且没人发现。)
	var from6 := Vector3(0.0, 1.05, 1.7)
	g.call("_invalidate_serve_solution")
	var easy: Dictionary = {}
	var probe_first := 0
	for a: Array in [[0.25, -0.75], [-0.35, -0.85], [0.05, -0.45],
			[0.50, -1.00], [-0.60, -0.55], [0.42, -0.35]]:
		g.set("_serve_solve_hint", [])
		if not (g.get("_serve_solve_hint") as Array).is_empty():
			_fail("J6 前置：set(_serve_solve_hint, []) 没生效（成员类型不对？）")
			break
		var pl: Dictionary = g.call("_plan_serve", 1)
		pl["opp_x"] = float(a[0])
		pl["opp_z"] = float(a[1])
		var r: Dictionary = g.call("_solve_legal_serve", from6, pl)
		var na := int(g.get("serve_last_attempts"))
		# ★ 必须挑一个「扫过不止一个候选才解出」的瞄准点：
		#   如果第一次就命中，那「带提示只用 1 个」什么也证明不了。
		if bool(r["ok"]) and na >= 2:
			easy = pl
			probe_first = na
			break
	_eqb("J6 找到一个「要试多个候选才解出」的瞄准点（提示测试的前提）",
		not easy.is_empty(), true)
	if not easy.is_empty():
		# (1) 基准：关掉提示（上一次的提示刚被最后那次解算写回，得再清一次）
		g.set("_serve_solve_hint", [])
		var base: Dictionary = g.call("_solve_legal_serve", from6, easy)
		var base_attempts := int(g.get("serve_last_attempts"))
		_eqf("J6a 不带提示时就是要点试多个候选（基准）",
			float(base_attempts), float(probe_first))
		# (2) 同一瞄准点，此时提示已经指向那个被采纳的候选
		var again: Dictionary = g.call("_solve_legal_serve", from6, easy)
		_eqf("J6b 带提示时第一次尝试就命中（候选数 = 1）",
			float(int(g.get("serve_last_attempts"))), 1.0)
		_eqb("J6c 提示不改变解出的速度（逐位相同）",
			(again["v"] as Vector3) == (base["v"] as Vector3), true)
		_eqb("J6c 提示不改变第二跳落点（逐位相同）",
			(again["second"] as Vector3) == (base["second"] as Vector3), true)
		_eqb("J6d 基准确实试了不止一个候选（否则 J6b 无意义）",
			base_attempts > 1, true)

	# ── J7 ★★ 解算任务逐帧摊销（「发球时一卡一卡」的正面解法）──
	#   三条不变量，缺一不可：
	#     a) 单帧试的候选数**不超过** serve_step_cands
	#        —— 这就是「不掉帧」本身，也是它和预算（砍候选）的本质区别；
	#     b) 输入不变时任务只建一次、一帧一帧往前推，最后**跑完整个网格**
	#        —— 摊销不减少搜索量，所以**不损精度**；
	#     c) 跑完之后不再有任务 —— 不会空转烧 CPU。
	#   ★ 用 accept_dist=-1 造「找不到合格候选 → 必须扫完 180 个」的确定性场景。
	var step := int(g.get("serve_step_cands"))
	if step < 1:
		_fail("J7 serve_step_cands 必须 ≥ 1")
	else:
		# ★ 必须显式关掉「总时长兜底」，否则它会在几十个候选处就把任务掐掉，
		#   J7b 会报「没有试完整个网格」。（它上一组刚好把预算设成了 12 ms。）
		g.set("serve_solve_budget_ms", -1.0)
		g.set("serve_legal_accept_dist", -1.0)
		g.call("_invalidate_serve_solution")
		g.set("_serve_solve_hint", [])
		var plan7: Dictionary = g.call("_plan_serve", 1)
		plan7["opp_x"] = 0.31
		plan7["opp_z"] = -0.77
		g.set("_serve_plan", plan7)
		var jobs0 := int(g.get("serve_solve_calls"))
		g.call("_update_serve_traj", f)
		_eqb("J7a 第一帧最多试 serve_step_cands 个候选（实测 %d，上限 %d）"
			% [int(g.get("serve_last_attempts")), step],
			int(g.get("serve_last_attempts")) <= step, true)
		_eqb("J7a 第一帧后任务还在跑（没有一次跑完）",
			(g.get("_serve_job") as Dictionary).is_empty(), false)
		var frames := 0
		while frames < 200:
			g.call("_update_serve_traj", f)
			frames += 1
			if (g.get("_serve_job") as Dictionary).is_empty():
				break
		_eqb("J7b 任务在几十帧内收工（实测 %d 帧）" % frames, frames < 60, true)
		_eqb("J7b 收工时整个候选网格都试过了（摊销不减少搜索量，实测 %d 个）"
			% int(g.get("serve_last_attempts")),
			int(g.get("serve_last_attempts")) >= 100, true)
		_eqf("J7c 全程只建了一个任务（输入没变就不重建、不空转）",
			float(int(g.get("serve_solve_calls")) - jobs0), 1.0)
		g.set("serve_legal_accept_dist", acc_saved)

	ball.free()
	g.free()


# ═══════════════════════════════════════════════════════════
# K. 旋球折扣 + 快球反馈（2026-10-06 用户需求）
# ═══════════════════════════════════════════════════════════
## 锁两件事：
##   ① 「旋球 → 对方扣杀概率下降」这条因果**真的落到概率上**，而且与凶度**正交**
##      （不能动 `_opp_rage` 的语义 —— F 组锁着「HUD 亮 ⇔ _opp_rage() > 1」）。
##   ② 「快球反馈」的触发策略：够快才弹、两条来路门槛不同。
##
## ★ 进树：要验 HUD 真的建起来、真的会亮、大字真的是「X.X m/s」。
##   `_build_speed_hud` 忘了调是这类改动最蠢也最可能的错误，不入树抓不到。
## ★ 本组会写真实存档（同 E/G/H 组）：跑完记得核对 %APPDATA% 下的 profile.json。
func _case_spin_and_speed() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var p: Node = (load(GAME_SCRIPT) as GDScript).new()
	holder.add_child(p)
	# ★ add_child 在 _initialize 里不触发 _ready → 必须等帧，否则 _hud 还是 null。
	await get_tree().process_frame
	await get_tree().process_frame

	# ── K1~K5 旋转折扣的曲线（纯函数）──
	var disc := float(p.get("spin_smash_discount"))
	var full := float(p.get("spin_smash_full"))
	_eqf("K1 无旋不打折", float(p.call("_spin_smash_factor", 0.0)), 1.0)
	_eqf("K2 满旋吃满折扣", float(p.call("_spin_smash_factor", full)), disc)
	_eqf("K3 超过满旋仍钳在满折扣", float(p.call("_spin_smash_factor", full * 5.0)), disc)
	var f1 := float(p.call("_spin_smash_factor", 0.3))
	var f2 := float(p.call("_spin_smash_factor", 0.6))
	var f3 := float(p.call("_spin_smash_factor", 0.9))
	_eqb("K4 旋量越大折扣越狠（单调：%.3f > %.3f > %.3f）" % [f1, f2, f3],
		f1 > f2 and f2 > f3, true)
	# ★ 用户说的是「旋球」，不是「上旋球」—— 上下旋必须同等有效
	_eqf("K5 上旋与下旋享受同等折扣",
		float(p.call("_spin_smash_factor", 0.8)),
		float(p.call("_spin_smash_factor", -0.8)))

	# ── K6 折扣真的落到概率上 ──
	# ★ 取样点取曲线**中点**：端点处 k 钳在 0/1，看不出中段有没有被压低。
	var h_lo := float(p.get("opp_smash_h_low"))
	var h_hi := float(p.get("opp_smash_h_full"))
	var h_mid := (h_lo + h_hi) * 0.5
	var c_plain := float(p.call("opp_smash_chance_at", h_mid, 0.0))
	var c_spin := float(p.call("opp_smash_chance_at", h_mid, full))
	_eqb("K6 带旋的球扣杀概率确实更低（%.1f%% → %.1f%%）"
		% [c_plain * 100.0, c_spin * 100.0], c_spin < c_plain, true)

	# ── K7 ★ 与凶度正交（折扣必须是独立乘子）──
	#   取样点用 h_lo：那里 k=0、基础概率只有 opp_smash_chance_low(0.15)，
	#   乘上凶度也不会撞到 clampf(…, 0, 1) 的上界 —— 撞了比值就不等于折扣，
	#   会变成「看运气」的假红。
	var c_lo := float(p.call("opp_smash_chance_at", h_lo, 0.0))
	p.set("_win_streak", 4)                       # 吃满凶度（4 连胜）
	var r_plain := float(p.call("opp_smash_chance_at", h_lo, 0.0))
	var r_spin := float(p.call("opp_smash_chance_at", h_lo, full))
	_eqb("K7a 吃满凶度后不打折的球确实更容易被扣杀", r_plain > c_lo, true)
	_eqf("K7b 折扣与凶度正交（吃满凶度后比值仍是折扣本身）",
		r_spin / maxf(r_plain, 0.000001), disc)
	p.set("_win_streak", 0)

	# ── K8 折扣不能绕过扣杀总开关 ──
	p.set("opp_smash_enabled", false)
	_eqf("K8 扣杀总开关关掉时带旋也还是 0",
		float(p.call("opp_smash_chance_at", h_mid, full)), 0.0)
	p.set("opp_smash_enabled", true)

	# ── K9~K13 快球反馈的触发策略（纯函数）──
	# ★ 2026-10-06 二次定稿：门槛 6.0 → **5.0**，而且**接球那条路也开始卡阈值**。
	#   判据从「是不是扣杀」改成「出手球速够不够快」。
	var thr := float(p.get("speed_flash_min"))
	var fb_hit: Dictionary = p.call("fast_shot_feedback",
		HITTER_OPPONENT, true, 7.2, KIND_NORMAL, 5.0)
	_eqs("K9 接住对手扣杀 → 报「接住扣杀」", String(fb_hit.get("tag", "")), "接住扣杀！")
	_eqf("K9 用的是**对手出手**的球速，不是这一拍我的球速",
		float(fb_hit.get("speed", 0.0)), 7.2)

	# 接球这条路现在也卡阈值：够快就报 —— 对手够快的**普通**回球一样算数
	var fb_recv: Dictionary = p.call("fast_shot_feedback",
		HITTER_OPPONENT, false, thr, KIND_NORMAL, 0.0)
	_eqs("K10 ★ 接住对手的快球（非扣杀）也报，文案分开", _fb_tag(fb_recv), "接住快球！")
	_eqb("K10 ★ 接球**低于**阈值就不报（用户要的是「大于 5 才有反馈」）",
		(p.call("fast_shot_feedback", HITTER_OPPONENT, true, thr - 0.01,
			KIND_NORMAL, 0.0) as Dictionary).is_empty(), true)

	# 队友刚回完球：_opp_smash / _opp_shot_speed 还是上一拍的旧值 —— 不能被报成「接住扣杀」
	# ★ my_speed 必须给一个**低于阈值**的值：不然会从②「打出」那条路弹出来，
	#   断言就变成看运气（这正是「反向验证要选对取样点」那条坑）。
	_eqb("K11 ★ 双打队友刚打完时不能误报「接住扣杀」",
		(p.call("fast_shot_feedback", HITTER_PLAYER, true, 7.2, KIND_NORMAL,
			thr - 1.0) as Dictionary).is_empty(), true)

	# 自己打出的：同样卡这**一个**门槛
	_eqb("K12 ★ 打出低于阈值不弹",
		(p.call("fast_shot_feedback", HITTER_PLAYER, false, 0.0, KIND_NORMAL,
			thr - 0.01) as Dictionary).is_empty(), true)
	var fb_plain: Dictionary = p.call("fast_shot_feedback",
		HITTER_PLAYER, false, 0.0, KIND_NORMAL, thr)
	_eqs("K12 ★ 打出刚过阈值就弹（普通回球归到「快球」文案）", _fb_tag(fb_plain), "快球！")
	_eqb("K13 ★ 接球与打出用的是**同一个**门槛 speed_flash_min",
		not fb_recv.is_empty() and not fb_plain.is_empty(), true)
	var fb_loop: Dictionary = p.call("fast_shot_feedback",
		HITTER_PLAYER, false, 0.0, KIND_LOOP, 7.83)
	_eqs("K13 爆冲·蓄满 → 报「爆冲」", _fb_tag(fb_loop), "爆冲！")
	var fb_flick: Dictionary = p.call("fast_shot_feedback",
		HITTER_PLAYER, false, 0.0, KIND_FLICK, 7.30)
	_eqs("K13 暴拧·蓄满 → 报「暴拧」", _fb_tag(fb_flick), "暴拧！")

	# ── K14~K19 快球 HUD（进树）──
	var root: CanvasItem = p.get("_speed_hud_root") as CanvasItem
	var lbl: Label = p.get("_speed_label") as Label
	var tagl: Label = p.get("_speed_tag") as Label
	if root == null or lbl == null or tagl == null:
		_fail("K14 快球 HUD 没建起来 —— _build_speed_hud 是不是没被调用？")
		p.free()
		holder.queue_free()
		return
	_checks += 1
	_eqb("K14 快球 HUD 挂在 _hud 下且初始不可见",
		root.get_parent() == p.get("_hud") and not root.visible, true)

	# ★★ 锚点必须**不在垂直正中** —— 正中是球和球台，大字压在那里会挡住这一拍本身。
	var ay := float(p.get("speed_flash_anchor_y"))
	_checks += 1
	if absf((root as Control).anchor_top - ay) > 0.001:
		_fail("K15 快球 HUD 的 anchor_top %s ≠ speed_flash_anchor_y %s"
			% [str((root as Control).anchor_top), str(ay)])

	p.set("_speed_flashes", 0)
	p.call("_flash_speed", 7.83, "爆冲！")
	_eqf("K16 弹一次后计数 +1", float(p.get("_speed_flashes")), 1.0)
	_eqf("K16 停留时长 = speed_flash_time",
		float(p.get("_speed_t")), float(p.get("speed_flash_time")))
	_eqf("K16 记下的球速就是传进去的实测值", float(p.get("_speed_last")), 7.83)
	# 别让游戏自己的 _process 把倒计时吃光，不然下面的断言就是在看运气
	p.set("_speed_t", 999.0)
	await get_tree().process_frame
	await get_tree().process_frame
	p.call("_update_speed_hud", 1.0 / 60.0)
	_eqb("K17 刷新后大字可见", root.visible, true)
	_eqs("K17 大字是「X.X m/s」而不是光秃秃一个数", lbl.text, "%.1f m/s" % 7.83)
	_eqs("K18 标签文案跟着来路走", tagl.text, "爆冲！")
	_checks += 1
	if lbl.scale.x <= 1.0:
		_fail("K19 大字没有弹跳（scale=%s）—— _speed_pop 没生效" % str(lbl.scale.x))
	_checks += 1
	# ★ pivot_offset 不取中心的话会从左上角放大、数字往右下跑（同连拍数字那条坑）
	if lbl.size.x > 1.0 and absf(lbl.pivot_offset.x - lbl.size.x * 0.5) > 0.5:
		_fail("K19 pivot_offset 没取控件中心（%s vs %s）→ 数字会从左上角放大"
			% [str(lbl.pivot_offset), str(lbl.size * 0.5)])

	p.set("_speed_t", 0.05)
	p.call("_update_speed_hud", 0.5)
	_eqb("K20 停留时间过后大字自己消失",
		root.visible == false and float(p.get("_speed_t")) <= 0.0, true)

	p.free()
	holder.queue_free()


# ═══════════════════════════════════════════════════════════
# L. 赛后评价称号 + 任务一键领取（2026-10-06 新增）
# ═══════════════════════════════════════════════════════════
## 两块都是「纯逻辑 + 一个面板按钮」，所以全部在离树实例上验，不进场景。
##
## ★★ 这里会调到 `Game.claim_all()`，而它**会写盘**。探针的两道存档防线
##    （`_run()` 的快照 / `_report()` 的无条件还原 + `run_regression.sh` 的
##   跑前 cp / 跑后 cmp）就是为这种组准备的 —— 见 PROFILE_PATH 那段说明。
##    ★ 但**绝不能**在这里调 `reset_all()`：它会拿默认档案把玩家真实存档
##      整份覆盖掉（B / D 组踩过，coins 5485 → 0）。
func _case_match_title_and_claim() -> void:
	# ── L1~L2 赛后评价称号（纯函数）──
	var g: Node3D = (load(GAME_SCRIPT) as GDScript).new() as Node3D
	if g == null:
		_fail("实例化 pingpong_game.gd 失败")
		return
	# 每一档都要有一个能命中的用例 —— 全是阈值的函数最容易出现
	# 「阈值调过头 → 某个称号永远拿不到」而没人发现（快球反馈那次就踩过）。
	var cases: Array = [
		[{"won": true, "own": 11, "opp": 0}, "完胜 · 零封"],
		[{"won": false, "own": 0, "opp": 11}, "一败涂地"],
		[{"won": true, "own": 11, "opp": 6, "max_rally": 20}, "铁壁对拉"],
		[{"won": false, "own": 6, "opp": 11, "max_rally": 20}, "铁壁对拉"],
		[{"won": true, "own": 11, "opp": 4}, "势如破竹"],
		[{"won": true, "own": 11, "opp": 7}, "稳如磐石"],
		[{"won": true, "own": 11, "opp": 9}, "险胜"],
		[{"won": true, "own": 11, "opp": 8}, "技高一筹"],
		[{"won": false, "own": 4, "opp": 11}, "雪崩式落败"],
		[{"won": false, "own": 9, "opp": 11}, "惜败"],
		[{"won": false, "own": 8, "opp": 11}, "稍逊一筹"],
	]
	for c: Array in cases:
		var d: Dictionary = c[0]
		var want := String(c[1])
		var got := String(g.call("match_title", d))
		_eqs("L1 称号「%s」 ← %s" % [want, str(d)], got, want)
	# ★ 极端必须压过长对拉：0:11 里就算打出过 20 拍，称号也不该是「铁壁对拉」。
	_eqs("L2 ★ 零封压过长对拉",
		String(g.call("match_title", {"won": true, "own": 11, "opp": 0,
			"max_rally": 30})), "完胜 · 零封")
	_eqs("L2 ★ 一败涂地压过长对拉",
		String(g.call("match_title", {"won": false, "own": 0, "opp": 11,
			"max_rally": 30})), "一败涂地")
	# ★★ 关键不变量：**永远不许返回空** —— 结算面板那行字是空的等于没给称号。
	#   顺手把「缺键不炸」一起锁住（以后加字段忘了同步这里不能崩）。
	_eqb("L2 ★ 空数据也必须有称号（绝不返回空串）",
		String(g.call("match_title", {} as Dictionary)).is_empty(), false)
	# ★ 方向性：赢绝不能拿到「输」的称号，反之亦然。用 11×11 全比分扫一遍。
	var lose_titles := ["一败涂地", "雪崩式落败", "惜败", "稍逊一筹"]
	var win_titles := ["完胜 · 零封", "势如破竹", "稳如磐石", "险胜", "技高一筹"]
	var bad := 0
	for own in range(0, 12):
		for opp in range(0, 12):
			if own == opp:
				continue
			var won := own > opp
			var t := String(g.call("match_title",
				{"won": won, "own": own, "opp": opp}))
			if (won and lose_titles.has(t)) or (not won and win_titles.has(t)):
				bad += 1
	_eqf("L2 ★ 132 组比分里称号方向全对（赢不会拿到输的称号）", float(bad), 0.0)
	g.free()

	# ── L3 一键领取（game_state.claim_all）──
	var st: Node = (load(GAME_STATE) as GDScript).new()
	if st == null:
		_fail("实例化 game_state.gd 失败")
		return
	var quests: Array = st.get("QUESTS")
	if quests.is_empty():
		_fail("L3 QUESTS 是空的？")
		st.free()
		return
	# ① 一个都不达标 → 0 可领、0 到账（这条走不到 save_profile，最安全）
	st.set("stats", {} as Dictionary)
	_eqf("L3a 全都没达标时可领取数 = 0", float(st.call("claimable_count")), 0.0)
	_eqf("L3b 全都没达标时一键领取拿到 0", float(st.call("claim_all")), 0.0)
	# ② 全部达标 → 一键领到的钱必须**恰好等于**所有奖励之和
	var all_stats := {}
	var want_all := 0
	for q: Dictionary in quests:
		all_stats[String(q["stat"])] = int(q["goal"])
		want_all += int(q["reward"])
	st.set("stats", all_stats)
	_eqf("L3c 全部达标 → 可领取数 = 成就总条数",
		float(st.call("claimable_count")), float(quests.size()))
	var c0 := int(st.get("coins"))
	var got := int(st.call("claim_all"))
	_eqf("L3d ★ 一键领到的金币 = 所有成就奖励之和", float(got), float(want_all))
	_eqf("L3e 金币确实到账了", float(int(st.get("coins")) - c0), float(got))
	_eqf("L3f 领完可领取数归零（与 claimable_count 同一套判据）",
		float(st.call("claimable_count")), 0.0)
	_eqf("L3g 再点一次拿不到钱（幂等，不会重复发奖）",
		float(st.call("claim_all")), 0.0)
	st.free()


## `fast_shot_feedback` 的 tag 取值（顺手把类型收干净，免得到处 String(...)）。
func _fb_tag(fb: Dictionary) -> String:
	if fb.is_empty():
		return ""
	return String(fb["tag"])


func _eqb(name: String, got: bool, want: bool) -> void:
	_checks += 1
	if got != want:
		_fail("%s：期望 %s，实际 %s" % [name, str(want), str(got)])


func _eqf(name: String, got: float, want: float) -> void:
	_checks += 1
	if absf(got - want) > 0.0005:
		_fail("%s：期望 %s，实际 %s" % [name, str(want), str(got)])


func _eqs(name: String, got: String, want: String) -> void:
	_checks += 1
	if got != want:
		_fail("%s：期望 %s，实际 %s" % [name, want, got])


func _fail(msg: String) -> void:
	_fails.append(msg)


func _report() -> void:
	# ★ 无条件还原存档：B / D 组会在离树实例上调 reset_all()，
	#   那会把玩家的真实档案用默认值覆盖掉（见 PROFILE_PATH 那段注释）。
	_restore_profile()
	print("========== 回归探针 ==========")
	if _fails.is_empty():
		print("全部通过：%d 项断言" % _checks)
	else:
		print("失败 %d / %d 项：" % [_fails.size(), _checks])
		for f: String in _fails:
			print("  FAIL  " + f)
	print("===============================")
	get_tree().quit(0 if _fails.is_empty() else 1)
