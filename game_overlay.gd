extends CanvasLayer
## 游戏内浮层：暂停面板 + 一局结算面板。
##
## 为什么单独一个节点、而且 process_mode = ALWAYS：
##   暂停走的是 SceneTree.paused，整棵树停止处理 —— 连 _unhandled_input
##   和按钮点击一起停。所以「暂停期间还得能点的界面」必须挂在一条
##   PROCESS_MODE_ALWAYS 的独立分支上。反过来，如果把游戏逻辑所在的
##   那一支设成 ALWAYS，暂停就等于没生效。
##
## 为什么不复用 main_menu.gd 的 _shell()：
##   那个是给菜单场景用的，生命周期是一整局游戏；这里要反复开关。
##   共用的是 UiKit 那一层（控件工厂 + 配色），不是面板壳子本身。
##
## 职责边界：只画界面、只把动作回抛成信号，不持有任何游戏状态。

signal resume_pressed()
signal restart_pressed()
signal menu_pressed()

const KIND_PAUSE := 0
const KIND_RESULT := 1

var _root: Control
var _body: VBoxContainer
var _kind: int = KIND_PAUSE


func _ready() -> void:
	# 暂停中也要能跑 —— 这是本文件存在的全部理由
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 盖住游戏 HUD（HUD 那层的 layer 是默认的 1）
	layer = 60
	visible = false
	_build()


func _build() -> void:
	_root = Control.new()
	_root.name = "OverlayRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 挡住底下的鼠标事件：面板开着时不该还能挥拍
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, 0.70)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var pc := UiKit.panel(Vector2(760, 0))
	pc.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(pc)

	var m := UiKit.margin(34, 28, 34, 28)
	pc.add_child(m)
	_body = UiKit.vbox(15)
	m.add_child(_body)


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false


# ───────────── 暂停 ─────────────
func open_pause() -> void:
	_kind = KIND_PAUSE
	_clear()

	var head := UiKit.hbox(12)
	var t := UiKit.label("已暂停", 30)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(UiKit.label("Esc 继续", 14, UiKit.TEXT_MUTE))
	_body.add_child(head)
	_body.add_child(UiKit.hline())

	# 暂停界面里直接放音量，是因为「觉得吵」往往就是在这里想调
	_body.add_child(UiKit.label("音量", 16, UiKit.TEXT_DIM))
	_body.add_child(UiKit.volume_controls(true))
	_body.add_child(UiKit.hline())

	# 手感不顺手一般也是打起来才发现 —— 灵敏度同样放进来。
	# 拖动即刻生效：暂停时相机节点虽然暂停了 _process，但信号回调照常执行，
	# 所以松开滑杆回游戏就是新手感。
	_body.add_child(UiKit.label("操作", 16, UiKit.TEXT_DIM))
	_body.add_child(UiKit.look_controls(true))
	_body.add_child(UiKit.hline())

	var row := UiKit.hbox(12)
	var b_resume := UiKit.button_primary("继续游戏", 20, UiKit.ACCENT, Vector2(0, 54))
	b_resume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b_resume.pressed.connect(func() -> void: resume_pressed.emit())
	row.add_child(b_resume)

	var b_menu := UiKit.button("返回主菜单", 18, Vector2(220, 54))
	b_menu.pressed.connect(func() -> void: menu_pressed.emit())
	row.add_child(b_menu)
	_body.add_child(row)

	visible = true


# ───────────── 一局结算 ─────────────
## d 的键：won / own / opp / max_rally / loop / flick / crouch
##         coins_points / coins_win / coins_blowout / coins_total / claimable
func open_result(d: Dictionary) -> void:
	_kind = KIND_RESULT
	_clear()

	var won := bool(d.get("won", false))
	var own := int(d.get("own", 0))
	var opp := int(d.get("opp", 0))

	var head := UiKit.hbox(14)
	var t := UiKit.label("本局结束", 26, UiKit.TEXT)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(UiKit.label("胜" if won else "负", 36,
		UiKit.ACCENT_2 if won else UiKit.ACCENT))
	_body.add_child(head)

	# ★ 赛后评价称号（用户 2026-10-06）：整块面板里**字号最大**的一行，居中。
	#   贴在「本局结束 / 胜负」正下方 —— 玩家扫一眼就知道这一局打得怎么样，
	#   再往下才是比分、过程数据、金币这些明细。
	#   ★ 称号本身由 pingpong_game.match_title() 这个**纯函数**算好（它能被探针验），
	#     面板只负责把它画大，不参与判定。
	#   ★ 赢给金色、输给灰色：称号是**评价**不是警报，输的时候用乒乓红会像报错。
	var title := String(d.get("title", ""))
	if not title.is_empty():
		var tl := UiKit.label(title, 52, UiKit.GOLD if won else UiKit.TEXT_DIM)
		tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_body.add_child(tl)

	var score := UiKit.hbox(12)
	score.add_child(UiKit.label("比分", 17, UiKit.TEXT_DIM))
	score.add_child(UiKit.label("%d : %d" % [own, opp], 30, UiKit.TEXT))
	score.add_child(UiKit.spacer())
	score.add_child(UiKit.label("先到 %d 分" % own if won else "先到 %d 分" % opp,
		14, UiKit.TEXT_MUTE))
	_body.add_child(score)
	_body.add_child(UiKit.hline())

	# 联赛场次：这一局只是 5 局 3 胜里的一小局，得先把「本场大比分」讲清楚
	var tour: Dictionary = d.get("tour", {})
	var is_tour := not tour.is_empty()
	if is_tour:
		_body.add_child(_tour_block(tour))
		_body.add_child(UiKit.hline())

	# 排位赛（方案 B）：段位变化放在比分下面、过程数据上面。
	# ★ 为什么给它这么高的位置：这一局对玩家最有价值的信息不是比分
	#   （他刚打完，当然知道），而是「我离下一级还差多少」——
	#   而那正是「再来一局」的唯一驱动力。
	var rk: Dictionary = d.get("rank", {})
	if not rk.is_empty():
		_body.add_child(_rank_block(rk))
		_body.add_child(UiKit.hline())

	# 过程数据：一局里打得怎么样，比单看比分更能说明问题
	var grid := UiKit.hbox(24)
	grid.add_child(_stat("最长对拉", "%d 拍" % int(d.get("max_rally", 0))))
	grid.add_child(_stat("正手爆冲制胜", "%d 分" % int(d.get("loop", 0))))
	grid.add_child(_stat("反手暴拧制胜", "%d 分" % int(d.get("flick", 0))))
	grid.add_child(_stat("蹲接", "%d 次" % int(d.get("crouch", 0))))
	_body.add_child(grid)
	_body.add_child(UiKit.hline())

	var coin_v := UiKit.vbox(6)
	coin_v.add_child(_coin_line("本局得分",
		"%d 分" % own, int(d.get("coins_points", 0))))
	# 连拍加成（方案 C）：把「长回合多赚的那部分」单独列一行。
	# 不单列的话玩家只看到总分涨了，不会意识到「刚才那波 20 拍是有回报的」——
	# 而这条因果关系正是这套循环唯一的驱动力。
	if int(d.get("coins_rally", 0)) > 0:
		coin_v.add_child(_coin_line("连拍加成",
			"最长 %d 拍对拉" % int(d.get("max_rally", 0)),
			int(d.get("coins_rally", 0))))
	if int(d.get("coins_win", 0)) > 0:
		coin_v.add_child(_coin_line("赢局奖励", "胜", int(d.get("coins_win", 0))))
	if int(d.get("coins_blowout", 0)) > 0:
		coin_v.add_child(_coin_line("大胜奖励",
			"对手仅得 %d 分" % opp, int(d.get("coins_blowout", 0))))
	# 排位连胜加成：单列一行，因为它是**这一局唯一靠历史连胜挣到的钱**。
	# 混进「赢局奖励」里，玩家永远发现不了连胜有用。
	if int(d.get("coins_streak", 0)) > 0:
		coin_v.add_child(_coin_line("连胜加成",
			"排位 %d 连胜" % int(rk.get("streak", 0)),
			int(d.get("coins_streak", 0))))
	var total := UiKit.hbox(12)
	var tl := UiKit.label("合计", 17, UiKit.TEXT_DIM)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total.add_child(tl)
	total.add_child(UiKit.label("+%d 金币" % int(d.get("coins_total", 0)),
		24, UiKit.GOLD))
	coin_v.add_child(total)
	_body.add_child(coin_v)

	if int(d.get("claimable", 0)) > 0:
		_body.add_child(UiKit.label(
			"有 %d 个任务奖励可以领取，回主菜单 → 任务" % int(d.get("claimable", 0)),
			15, UiKit.GOLD))
	# ★★★ 今日任务的「临近完成」提示 —— 经济重做第一期里**转化率最高的一条**。
	#
	#   玩家刚打完一局：球拍还在手上、手感正热，此刻告诉他「差一点点」
	#   最容易被推一把再来一局。
	#   ★ 只挂在菜单里是没用的 —— 在主菜单里没人会为了 90 金币专门开一局，
	#     但刚打完的人会。位置也刻意放在「再来一局」按钮正上方。
	var hint := Game.daily_hint()
	if not hint.is_empty():
		_body.add_child(UiKit.label(hint, 16, UiKit.ACCENT_2))
	_body.add_child(UiKit.hline())

	var row := UiKit.hbox(12)
	var series_over := bool(tour.get("series_over", false))
	var primary_text := "再来一局"
	if is_tour:
		primary_text = "回到联赛" if series_over else "打下一局"
	var b_again := UiKit.button_primary(primary_text, 20, UiKit.ACCENT, Vector2(0, 56))
	b_again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_tour and series_over:
		# 这一场打完了 —— 「下一局」已经不存在，该去看赛程推进到哪了
		b_again.pressed.connect(func() -> void: menu_pressed.emit())
	else:
		b_again.pressed.connect(func() -> void: restart_pressed.emit())
	row.add_child(b_again)

	var b_menu := UiKit.button("返回主菜单", 18, Vector2(220, 56))
	b_menu.pressed.connect(func() -> void: menu_pressed.emit())
	row.add_child(b_menu)
	_body.add_child(row)

	visible = true


## 联赛场次的「本场大比分」块。res 是 Game.report_tournament_match() 的回执，
## 只有整场打完了才有内容（没打完是空字典）。
func _tour_block(tour: Dictionary) -> Control:
	var v := UiKit.vbox(8)
	var tw := int(tour.get("won", 0))
	var tl := int(tour.get("lost", 0))

	var top := UiKit.hbox(12)
	top.add_child(UiKit.label("联赛 · %s" % str(tour.get("stage", "")), 17, UiKit.GOLD))
	top.add_child(UiKit.spacer())
	top.add_child(UiKit.label("对手 %s（评分 %d）"
		% [str(tour.get("opp", "?")), int(tour.get("rating", 0))], 15, UiKit.TEXT_DIM))
	v.add_child(top)

	var srow := UiKit.hbox(12)
	srow.add_child(UiKit.label("本场比分", 17, UiKit.TEXT_DIM))
	srow.add_child(UiKit.label("%d : %d" % [tw, tl], 28,
		UiKit.ACCENT_2 if tw > tl else UiKit.ACCENT))
	srow.add_child(UiKit.label("5 局 3 胜", 14, UiKit.TEXT_MUTE))
	srow.add_child(UiKit.spacer())
	v.add_child(srow)

	if not bool(tour.get("series_over", false)):
		v.add_child(UiKit.label("再赢 %d 局拿下这一场；对手再拿 %d 局你就出局"
			% [maxi(Tournament.WIN_TARGET - tw, 0), maxi(Tournament.WIN_TARGET - tl, 0)],
			15, UiKit.TEXT_DIM))
		return v

	var res: Dictionary = tour.get("res", {})
	var won_series := tw > tl
	v.add_child(UiKit.label("本场结束 —— 你以 %d : %d %s"
		% [tw, tl, "胜出" if won_series else "告负"], 18,
		UiKit.ACCENT_2 if won_series else UiKit.ACCENT))

	if res.has("place"):
		var place := int(res["place"])
		v.add_child(UiKit.label("本届最终名次：第 %d 名（%s）　奖励 +%d 金币"
			% [place, str(res.get("prize_label", "")), int(res.get("prize", 0))],
			19, UiKit.GOLD))
		if place == 1:
			v.add_child(UiKit.label("冠军！32 个人里只有一个人能站到最后。", 16, UiKit.GOLD))
	elif bool(res.get("out", false)):
		v.add_child(UiKit.label("止步 %s。" % str(res.get("stage_name", "")), 16, UiKit.ACCENT))
	elif res.has("next_name"):
		# 小组赛的下一场还是小组赛，「晋级小组赛」读起来是错的；
		# 淘汰赛才有「晋级 8 强」这种说法。
		var lead := "小组赛告一段落" if str(res.get("stage", "")) == "group" \
			else "晋级 %s" % str(res.get("next_stage", ""))
		v.add_child(UiKit.label("%s　下一个对手：%s（评分 %d）"
			% [lead, str(res.get("next_name", "?")), int(res.get("next_rating", 0))],
			16, UiKit.TEXT))
	return v


## 排位赛的段位变化块。rk = Game.report_rank_match() 的回执。
##
## ★ 为什么把「距下一级还差多少分」和一根进度条一起放出来：
##   升段是一个**长周期**目标，单看「+26 分」玩家算不出自己到哪了。
##   一根柱子 + 一个具体数字，才是「再来一局」的钩子。
func _rank_block(rk: Dictionary) -> Control:
	var v := UiKit.vbox(8)
	var delta := int(rk.get("delta", 0))
	var promoted := bool(rk.get("promoted", false))
	var demoted := bool(rk.get("demoted", false))
	var name_after := str(rk.get("name_after", ""))

	var top := UiKit.hbox(12)
	top.add_child(UiKit.label("排位赛", 17, UiKit.GOLD))
	top.add_child(UiKit.spacer())
	top.add_child(UiKit.label(str(rk.get("name_before", "")), 16, UiKit.TEXT_DIM))
	top.add_child(UiKit.label("→", 16, UiKit.TEXT_MUTE))
	top.add_child(UiKit.label(name_after, 22,
		UiKit.GOLD if promoted else (UiKit.ACCENT if demoted else UiKit.TEXT)))
	v.add_child(top)

	var row := UiKit.hbox(12)
	row.add_child(UiKit.label("段位分", 16, UiKit.TEXT_DIM))
	row.add_child(UiKit.label("%d → %d" % [
		int(rk.get("points_before", 0)), int(rk.get("points_after", 0))], 20, UiKit.TEXT))
	row.add_child(UiKit.label("+%d" % delta if delta >= 0 else str(delta), 18,
		UiKit.ACCENT_2 if delta >= 0 else UiKit.ACCENT))
	row.add_child(UiKit.spacer())
	if bool(rk.get("is_max", false)):
		row.add_child(UiKit.label("已到顶", 15, UiKit.GOLD))
	else:
		row.add_child(UiKit.label("距 %s 还差 %d 分" % [str(rk.get("next_name", "")),
			maxi(int(rk.get("span", 100)) - int(rk.get("into", 0)), 0)], 15, UiKit.TEXT_MUTE))
	v.add_child(row)

	var span := maxi(int(rk.get("span", 100)), 1)
	var bar := UiKit.progress(into_clamped(rk), span, 0.0, UiKit.GOLD)
	bar.custom_minimum_size = Vector2(0, 12)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(bar)

	if promoted:
		v.add_child(UiKit.label("晋级！%s 达成。" % name_after, 18, UiKit.GOLD))
	elif demoted:
		v.add_child(UiKit.label("掉到 %s 了。再赢两局就能打回来。" % name_after,
			17, UiKit.ACCENT))
	elif bool(rk.get("shielded", false)):
		v.add_child(UiKit.label("连败保底生效：还能再输 %d 场不掉级。"
			% int(rk.get("shield_left", 0)), 16, UiKit.TEXT_DIM))

	var st := int(rk.get("streak", 0))
	var ls := int(rk.get("lose_streak", 0))
	if st >= 2:
		v.add_child(UiKit.label("当前 %d 连胜　金币 ×%.1f"
			% [st, float(rk.get("coins_mult", 1.0))], 16, UiKit.GOLD))
	elif ls >= 2:
		v.add_child(UiKit.label("当前 %d 连败" % ls, 16, UiKit.TEXT_MUTE))
	return v


## 本小级内已走的分数。单独抽出来是为了 clamp 住 —— 回执里的 into 理论上
## 已经夹过了，但面板不该因为上游某天改了个算法就画出一根越界的柱子。
func into_clamped(rk: Dictionary) -> int:
	return clampi(int(rk.get("into", 0)), 0, maxi(int(rk.get("span", 100)), 1))


func _stat(name: String, value: String) -> Control:
	var v := UiKit.vbox(3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UiKit.label(name, 13, UiKit.TEXT_MUTE))
	v.add_child(UiKit.label(value, 19, UiKit.TEXT))
	return v


func _coin_line(name: String, note: String, amount: int) -> Control:
	var h := UiKit.hbox(10)
	var n := UiKit.label(name, 16, UiKit.TEXT_DIM)
	n.custom_minimum_size = Vector2(96, 0)
	h.add_child(n)
	h.add_child(UiKit.label(note, 14, UiKit.TEXT_MUTE))
	h.add_child(UiKit.spacer())
	h.add_child(UiKit.label("+%d" % amount, 18, UiKit.GOLD))
	return h


# ───────────── 输入 ─────────────
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not event.is_action_pressed("ui_cancel"):
		return
	# 不论哪个面板都吃掉这个按键：不然后面 camera_controller 会把它
	# 当成「切换鼠标锁定」，暂停面板还开着鼠标却被锁回去。
	get_viewport().set_input_as_handled()
	# 结算面板不响应 Esc —— 一局的结果要让玩家明确选一次下一步，
	# 顺手按 Esc 再开一局容易让人以为「自动续上了」。
	if _kind == KIND_PAUSE:
		resume_pressed.emit()


func _clear() -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
