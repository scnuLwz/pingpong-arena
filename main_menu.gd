extends Control
## 游戏初始界面 —— 开始游戏 / 声音设置 / 存档 / 任务奖励 / 商店（更换场馆）
##
## 面板按需重建：每次打开都从 Game 单例现读数据重新生成，
## 而不是建好一套再手动同步。条目只有个位数，重建的开销可以忽略，
## 换来的是「商店里买完立刻看到按钮变『使用中』」这类一致性。
##
## 布局按 1920×1080 设计（project.godot 里 stretch/mode=canvas_items，
## 窗口实际是 1280×720，控件坐标仍然走 1920×1080 的逻辑分辨率）。

const GAME_SCENE := "res://pingpong.tscn"

## 开发者署名。**收在「关于」面板里**（首页那个按钮打开）——
## 用户 2026-10-03 要求「创作者的信息放在一个按键里面」。
const DEV_EMAIL := "202636383396@m.scnu.edu.cn"
const DEV_POWER := "Powered by WorkBuddy & Codex"

var _panel_host: Control
var _btn_column: VBoxContainer
## 面板**底部固定栏**的内容（钉在滚动区之外）。
## 由 _panel_start() 设置、_shell() 消费后清空 —— 只在本次开面板时有效。
## 见 _shell 里那段注释：主行动按钮必须永远可见，不能被滚动区裁掉。
var _shell_footer: Control = null
var _coins_label: Label
var _stat_label: Label
var _arena_label: Label
var _arena_swatch: HBoxContainer
var _quest_btn: Button
var _tour_btn: Button
var _rank_btn: Button
var _rank_label: Label
var _title_label: Label
## 联赛面板当前页签：sched / rank / data。放在成员上是为了「切页签只重建面板」
## 也能记住选中项（点击页签 = 设好这个值再 _open("tournament")）。
var _tour_tab: String = "sched"
## 任务面板当前页签：daily / weekly / life。默认落在每日任务 ——
## 面板被打开的理由通常就是「今天的任务做完没」，多一次点击就少一批人看到。
var _quest_tab: String = "daily"
var _skin_btn: Button
## 上一次抽卡的结果。抽完要留在面板上给玩家看，而不是只弹一下 ——
## 「抽出什么了」这件事本身值得占三行版面。
var _last_draw: Dictionary = {}
## 刚发生的赛季结算（非空 = 有新闻要给玩家看）。_refresh 里填、_panel_rank 里消费掉。
var _season_news: Dictionary = {}
## 本次回主菜单新解锁的称号 id。_refresh 里填、状态卡上展示。
var _new_titles: Array[String] = []
## 当前面板里的五个难度按钮。微调滑杆拖动时用它更新高亮（只改样式，不重建）。
var _diff_buttons: Array[Button] = []


func _ready() -> void:
	# 从游戏里返回菜单时鼠标可能还是锁定状态
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()
	Game.coins_changed.connect(_on_coins_changed)
	Game.profile_changed.connect(_refresh)
	Game.arena_changed.connect(_on_arena_changed)
	Game.tournament_changed.connect(_refresh)
	_refresh()


# ───────────── 骨架 ─────────────
func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UiKit.BG_DARK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_build_backdrop()

	var margin := UiKit.margin(110, 96, 110, 76)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var hb := UiKit.hbox(64)
	margin.add_child(hb)

	# ── 左：标题 + 菜单 ──
	var left := UiKit.vbox(0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(left)

	var title := UiKit.label("乒乓竞技场", 62, UiKit.TEXT)
	left.add_child(title)

	var sub := UiKit.label("TABLE  TENNIS  ARENA", 17, UiKit.ACCENT)
	left.add_child(sub)

	var underline: Control = UiKit.hline()
	underline.custom_minimum_size = Vector2(300, 3)
	underline.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.add_child(UiKit.spacer(22))
	left.add_child(underline)

	left.add_child(UiKit.spacer(52))

	_btn_column = UiKit.vbox(14)
	_btn_column.custom_minimum_size = Vector2(392, 0)
	_btn_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.add_child(_btn_column)

	_add_menu_button("开始比赛", true, func() -> void: _open("start"))
	_tour_btn = _add_menu_button("联赛 · 比赛模式", false, func() -> void:
		_tour_tab = "sched"
		_open("tournament")
	)
	# 排位（方案 B）紧挨着联赛放：两者都是「长期目标」，一个有终点（32 人夺冠）、
	# 一个没有（段位天梯），玩家一眼就能看出这是两种互补的玩法。
	_rank_btn = _add_menu_button("排位赛 · 段位天梯", false, func() -> void: _open("rank"))
	_add_menu_button("设置（声音 / 操作）", false, func() -> void: _open("settings"))
	_add_menu_button("存档", false, func() -> void: _open("save"))
	_quest_btn = _add_menu_button("任务 · 每日 / 每周 / 生涯", false, func() -> void:
		_quest_tab = "daily"
		_open("quests")
	)
	_add_menu_button("商店 · 更换场馆", false, func() -> void: _open("shop"))
	_skin_btn = _add_menu_button("球拍工坊 · 外观", false, func() -> void: _open("skins"))
	_add_menu_button("个性化 · 称号 / 应援 / 呐喊", false, func() -> void:
		_open("persona"))

	# ── 关于（开发者信息）──
	# ★ 2026-10-03 用户要求「创作者的信息放在一个按键里面」。
	#   原来那块邮箱 + 署名常驻在首页左下，把操作提示挤到只剩两行，
	#   而邮箱有 20 多个字符、常驻在那里玩家也不会去手抄。
	#   放进菜单列（而不是挂在提示文字下面），它才是菜单里的一项，
	#   位置和「退出游戏」这类次要入口归为一组。
	_add_menu_button("关于 · 开发者信息", false, func() -> void: _open("about"))

	# ── 退出游戏 ──
	# ★ 只在桌面端给：Web 版跑在浏览器标签页里，没有「退出程序」这回事，
	#   留一个点了没反应的按钮比不给更糟。用 feature tag 判断而不是 DisplayServer
	#   —— Web 导出里 OS.has_feature("web") 恒为真，其余平台为假。
	# ★ spacer 也放进同一个 if：否则 Web 端按钮列末尾会多出一段空隙，
	#   而 Web 上这一段后面什么都没有。
	if not OS.has_feature("web"):
		_btn_column.add_child(UiKit.spacer(22))
		_add_menu_button("退出游戏", false, _quit_game)

	left.add_child(UiKit.spacer())
	var tip := UiKit.para("按住空格蓄力，再按左键/右键打出反手暴拧 / 正手爆冲。"
		+ "WASD 移动，Ctrl 蹲下，V 跳跃，Esc 暂停。", 14, UiKit.TEXT_MUTE, 400)
	left.add_child(tip)

	# ── 右：状态卡 ──
	var right := UiKit.vbox(0)
	right.custom_minimum_size = Vector2(430, 0)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(right)

	var card := UiKit.panel()
	right.add_child(card)
	var cm := UiKit.margin(26, 24, 26, 24)
	card.add_child(cm)
	var cv := UiKit.vbox(14)
	cm.add_child(cv)

	var cap := UiKit.label("当前状态", 15, UiKit.TEXT_MUTE)
	cv.add_child(cap)
	cv.add_child(UiKit.hline())

	var coin_row := UiKit.hbox(10)
	coin_row.add_child(UiKit.label("金币", 17, UiKit.TEXT_DIM))
	coin_row.add_child(UiKit.spacer())
	_coins_label = UiKit.label("0", 30, UiKit.GOLD)
	coin_row.add_child(_coins_label)
	cv.add_child(coin_row)

	var arena_cap := UiKit.label("使用中的场馆", 15, UiKit.TEXT_MUTE)
	cv.add_child(arena_cap)
	_arena_label = UiKit.label("—", 20, UiKit.TEXT)
	cv.add_child(_arena_label)
	_arena_swatch = UiKit.hbox(6)
	cv.add_child(_arena_swatch)

	# 排位段位：放在状态卡里而不是藏进面板 —— 「我现在什么段位」应当
	# 一打开菜单就看得见，否则段位就没有「一直在那儿盯着你」的压力。
	cv.add_child(UiKit.hline())
	var rank_row := UiKit.hbox(10)
	rank_row.add_child(UiKit.label("排位段位", 15, UiKit.TEXT_MUTE))
	rank_row.add_child(UiKit.spacer())
	_rank_label = UiKit.label("—", 18, UiKit.GOLD)
	rank_row.add_child(_rank_label)
	cv.add_child(rank_row)

	# 称号：同样放在状态卡里。称号是「身份」，藏进面板里就等于没有 ——
	# 玩家得在每次打开菜单时都看见自己挂着什么，才会有动力去解锁下一个。
	cv.add_child(UiKit.hline())
	var title_row := UiKit.hbox(10)
	title_row.add_child(UiKit.label("当前称号", 15, UiKit.TEXT_MUTE))
	title_row.add_child(UiKit.spacer())
	_title_label = UiKit.label("—", 18, UiKit.ACCENT_2)
	title_row.add_child(_title_label)
	cv.add_child(title_row)

	cv.add_child(UiKit.hline())
	_stat_label = UiKit.label("", 15, UiKit.TEXT_DIM)
	cv.add_child(_stat_label)

	# 面板容器：盖在最上层
	_panel_host = Control.new()
	_panel_host.name = "PanelHost"
	_panel_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel_host)


## 背景：几块大面积色斑 + 一条球台轮廓线。纯装饰，不参与交互。
## 「关于 · 开发者信息」面板（首页那个按钮打开的）。
##
## ★ 2026-10-03：从首页常驻块改成面板 —— 常驻在左下角把操作提示挤没了，
##   而邮箱这种「要联系时才需要」的字符串本来就不该抢首屏。
##   面板里给足信息：邮箱（可一键复制）、署名、以及素材授权出处。
##
## 邮箱做成可复制：这串字符有 20 多个，手抄一遍几乎必错，而它存在的意义
## 就是「能被联系上」。复制完把按钮文字改成「已复制」给个明确回执。
func _panel_about() -> Control:
	var v := UiKit.vbox(14)
	v.add_child(UiKit.para("乒乓竞技场 · 一个用 Godot 4.7 做的第一人称乒乓球原型。",
		15, UiKit.TEXT_DIM, 620))
	v.add_child(UiKit.hline())

	v.add_child(UiKit.label("开发者", 18, UiKit.TEXT))
	var row := UiKit.hbox(10)
	row.add_child(UiKit.label("邮箱", 15, UiKit.TEXT_MUTE))
	var mail := UiKit.label(DEV_EMAIL, 17, UiKit.ACCENT)
	mail.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(mail)

	var cp := UiKit.button("复制", 13, Vector2(84, 34))
	cp.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(DEV_EMAIL)
		cp.text = "已复制"
		# 3 秒后把文字改回去，一直挂着「已复制」会像是坏了。
		# ★ await 之后按钮可能已经随面板一起销毁了，必须判一次有效性。
		await get_tree().create_timer(3.0).timeout
		if is_instance_valid(cp):
			cp.text = "复制"
	)
	row.add_child(cp)
	v.add_child(row)

	v.add_child(UiKit.label(DEV_POWER, 15, UiKit.TEXT_DIM))

	v.add_child(UiKit.hline())
	v.add_child(UiKit.label("素材与授权", 18, UiKit.TEXT))
	v.add_child(UiKit.para(
		"音效来自 BigSoundBank 与 Joseph SARDIN，授权 CC0 1.0 公共领域"
		+ "（可商用、免署名）。观众模型与击球素材见工程内 audio/CREDITS.txt。",
		14, UiKit.TEXT_MUTE, 620))
	return v


func _build_backdrop() -> void:
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layer)

	var glow := ColorRect.new()
	glow.color = Color(0.155, 0.030, 0.042, 0.55)
	glow.position = Vector2(-260, -220)
	glow.size = Vector2(1100, 760)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.rotation = deg_to_rad(-14.0)
	layer.add_child(glow)

	var glow2 := ColorRect.new()
	glow2.color = Color(0.085, 0.145, 0.375, 0.42)
	glow2.position = Vector2(980, 320)
	glow2.size = Vector2(1200, 900)
	glow2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow2.rotation = deg_to_rad(18.0)
	layer.add_child(glow2)

	# 一条横贯的「球网」白线，给画面一个水平基准
	var net := ColorRect.new()
	net.color = Color(1, 1, 1, 0.10)
	net.position = Vector2(0, 862)
	net.size = Vector2(1920, 2)
	net.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(net)

	var ball := Panel.new()
	ball.add_theme_stylebox_override("panel", _ball_style())
	ball.position = Vector2(1618, 150)
	ball.size = Vector2(74, 74)
	ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ball)


func _ball_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 0.97, 0.92)
	sb.set_corner_radius_all(37)
	sb.shadow_color = Color(1, 1, 1, 0.30)
	sb.shadow_size = 22
	return sb


func _add_menu_button(text: String, primary: bool, cb: Callable) -> Button:
	var b: Button
	if primary:
		b = UiKit.button_primary(text, 22, UiKit.ACCENT, Vector2(392, 62))
	else:
		b = UiKit.button(text, 19, Vector2(392, 52))
	b.pressed.connect(cb)
	_btn_column.add_child(b)
	return b


## 退出游戏（桌面端，见 _build 里 Web 端不建这个按钮）。
##
## ★ 为什么退出前补一次存档：金币 / 战绩 / 任务进度平时靠 profile 自动落盘，
##   但玩家点「退出」的时机是任意的，完全可能刚好在一次得分之后、写盘之前。
##   一次小文件写入的成本，换「这一局没白打」——值。
func _quit_game() -> void:
	Game.save_profile()
	get_tree().quit()


# ───────────── 刷新 ─────────────
func _on_coins_changed(_c: int) -> void:
	_refresh()


func _on_arena_changed(_id: String) -> void:
	_refresh()


func _refresh() -> void:
	if _coins_label == null:
		return
	_coins_label.text = str(Game.coins)

	# ── 第三期：称号自动解锁 ──
	# ★ 放在刷新入口：称号的达成条件全是 stats 里的累计值，
	#   而 stats 是打完一局才更新的 —— 回主菜单时扫一遍最自然。
	#   幂等（已解锁的不会重复进 titles），所以每帧调也没问题。
	_new_titles = Game.title_refresh()

	# ── 排位（方案 B）──
	# ★ 跨赛季结算放在刷新入口：单机没有「登录」这个事件，玩家可能隔一周
	#   才开一次游戏，唯一可靠的触发点就是「要用到赛季数据时」。
	#   幂等（见 Game.rank_ensure_season），所以每帧调也没问题。
	# ★ 结算结果先存起来、等玩家打开排位面板再展示 —— 直接在这里弹面板
	#   会在主菜单刚起来的一瞬间糊脸。
	var sn := Game.rank_ensure_season()
	if bool(sn.get("changed", false)):
		_season_news = sn
	_rank_label.text = "%s　%d 分" % [Game.rank_name(), Game.rank_points]
	# ── 称号（第三期）──
	if _title_label != null:
		var tn := Game.title_name()
		if not _new_titles.is_empty():
			_title_label.text = "%s　新解锁 %d 个" % [tn, _new_titles.size()]
			_title_label.add_theme_color_override("font_color", UiKit.GOLD)
		else:
			_title_label.text = tn if not tn.is_empty() else "—"
			_title_label.add_theme_color_override("font_color",
				UiKit.ACCENT_2 if not tn.is_empty() else UiKit.TEXT_MUTE)
	if _rank_btn != null:
		_rank_btn.text = "排位赛 · %s（%d 分）" % [Game.rank_name(), Game.rank_points]

	var a := Game.get_arena(Game.current_arena)
	_arena_label.text = str(a["name"])

	for c in _arena_swatch.get_children():
		_arena_swatch.remove_child(c)
		c.queue_free()
	var theme: Dictionary = a.get("theme", {})
	for key: String in ["court_color", "barrier_color", "ad_band_color", "apron_color"]:
		if not theme.has(key):
			continue
		var sw := Panel.new()
		sw.custom_minimum_size = Vector2(46, 14)
		var sb := StyleBoxFlat.new()
		sb.bg_color = theme[key]
		sb.set_corner_radius_all(4)
		sw.add_theme_stylebox_override("panel", sb)
		_arena_swatch.add_child(sw)

	var s: Dictionary = Game.stats
	_stat_label.text = "累计得分 %d　·　最长对拉 %d 拍\n赢下 %d 局　·　出战 %d 局" % [
		int(s["points"]), int(s["max_rally"]),
		int(s["matches_won"]), int(s["matches_played"]),
	]

	var n := Game.claimable_count()
	# ── 每日任务（经济重做第一期）──
	# ★★ daily_ensure() 的两个触发点之一（另一个是 pingpong_game._end_match）。
	#    单机没有「上线」这个事件，玩家可能隔三天才开一次游戏 ——
	#    唯一可靠的时机就是「要用到每日数据时」，所以菜单刷新必须调。
	#    幂等，重复调没有代价。
	Game.daily_ensure()
	Game.weekly_ensure()
	var ds: Dictionary = Game.daily_summary()
	var nd := Game.daily_claimable_count()
	var nw := Game.weekly_claimable_count()
	# ★ 角标写成「今日 1/3」这种**可见进度**，而不是「● 有可领取的」。
	#   「有几个能领」是完成度的结果，「1/3」是还差多少 —— 后者才推得动人。
	_quest_btn.text = "任务 · 今日 %d/%d" % [int(ds["done"]), int(ds["total"])]
	if int(ds["streak"]) > 0:
		_quest_btn.text += "　连续 %d 天" % int(ds["streak"])
	if n + nd + nw > 0:
		_quest_btn.text += "　● %d 个可领取" % (n + nd + nw)
	_quest_btn.add_theme_color_override("font_color",
		UiKit.GOLD if (n + nd + nw) > 0 else UiKit.TEXT)

	# ── 球拍工坊（经济二期）──
	# ★ 券的进度直接写在按钮上。「球拍券 5/7」本身就是一句催促：
	#   玩家看到「差 2 张」会想起今天的全清还没领。
	if _skin_btn != null:
		var tp := Game.tickets_paddle
		_skin_btn.text = "球拍工坊 · 外观"
		if tp > 0 or Game.tickets_arena > 0:
			_skin_btn.text += "　券 %d/%d" % [tp, Game.DRAW_COST_PADDLE]
		var ready := tp >= Game.DRAW_COST_PADDLE
		if ready:
			_skin_btn.text += "　● 可抽取"
		_skin_btn.add_theme_color_override("font_color",
			UiKit.GOLD if ready else UiKit.TEXT)

	# 联赛按钮兼作「赛事进度灯」：没报名 / 打到第几轮 / 已结束拿了第几名，
	# 不进面板就能看出来。
	if _tour_btn != null:
		var t: Dictionary = Game.tournament
		if t.is_empty():
			_tour_btn.text = "联赛 · 比赛模式"
			_tour_btn.add_theme_color_override("font_color", UiKit.TEXT)
		elif str(t.get("stage", "")) == "done":
			var pl := int(t.get("place", 0))
			_tour_btn.text = "联赛 · 本届第 %d 名" % pl
			_tour_btn.add_theme_color_override("font_color", UiKit.GOLD)
		else:
			# ★ 措辞带上「去这里打」：现在联赛赛程**只能**从这个按钮进去
			#   （2026-10-03 起赛事不再劫持「开始比赛」），按钮得自己说明这一点，
			#   否则玩家会以为打完一场自由对战赛程也会自己往前推。
			_tour_btn.text = "联赛 · 待你开打　%s" % Tournament.stage_name(str(t.get("stage", "")))
			_tour_btn.add_theme_color_override("font_color", UiKit.ACCENT_2)


# ───────────── 面板骨架 ─────────────
func _open(key: String) -> void:
	for c in _panel_host.get_children():
		_panel_host.remove_child(c)
		c.queue_free()
	# ★ 每次开面板先清footer。_panel_start() 会在构造时把主按钮写进来，
	#   但换开别的面板时它不会被覆写 —— 上一面板的按钮会留在底部。
	#   之所以之前没炸：_shell 消费后就清了；这里再清一次是为了覆盖
	#   「面板被 Esc 关掉、_shell 早已跑完」这条路径。
	_shell_footer = null
	# ★ 同理清难度按钮表：_panel_start() 重建时会往里塞新按钮，
	#   不清的话每开一次面板就多一批上一轮已释放的节点
	#   （_sync_diff_buttons 遍历到它们会报 invalid access）。
	_diff_buttons.clear()
	var body: Control = null
	var title := ""
	var width := 640.0
	var scroll_h := 372.0
	match key:
		"start":
			title = "开始比赛"; body = _panel_start(); width = 560.0
		"settings":
			title = "设置"; body = _panel_settings(); width = 700.0
		"about":
			title = "关于 · 开发者信息"; body = _panel_about(); width = 680.0
		"save":
			title = "存档"; body = _panel_save(); width = 780.0
		"quests":
			# 每日 3 条 + 全清行 + 每周 3 条，给高一点免得滚
			title = "任务 · 每日 / 每周 / 生涯"
			body = _panel_quests(); width = 880.0; scroll_h = 552.0
		"shop":
			title = "商店 · 更换场馆"; body = _panel_shop(); width = 860.0
		"skins":
			# 三个槽共 13 条 + 抽卡区，要滚
			title = "球拍工坊"; body = _panel_skins(); width = 880.0; scroll_h = 552.0
		"persona":
			title = "个性化 · 称号 / 应援 / 呐喊"
			body = _panel_persona(); width = 880.0; scroll_h = 552.0
		"rank":
			# 排位面板要装段位卡 + 战绩 + 赛季 + 7 行段位表，给高一点。
			title = "排位赛 · 段位天梯"; body = _panel_rank()
			width = 780.0; scroll_h = 552.0
		"tournament":
			# 联赛面板要装 32 行的名次表和 8 组的小组榜，默认 372 只露三行，
			# 滚起来很难受 —— 这里单独给高一点。
			title = "联赛 · 比赛模式"; body = _panel_tournament()
			width = 920.0; scroll_h = 596.0
	if body == null:
		return
	# ★★ 把滚动区高度**夹到视口内**（2026-10-03 修）。
	#
	#   原来 scroll_h 是每面板写死的常数（372 / 552 / 596）。在 1080p 高的
	#   窗口上没问题，但窗口一矮（笔记本 768、或浏览器地址栏占一截），
	#   面板就超出屏幕 —— 而「开始比赛」的主按钮恰好在内容最底部，
	#   于是**玩家在矮窗口里根本点不到「开始比赛」，游戏进不去**。
	#   表现是「点了没反应」，UI 又不提示为什么。
	#
	#   这里按实际视口留出标题栏 + 上下边距 + 一点余量，
	#   保证任何窗口高度下主按钮都在屏幕内。
	var vh := get_viewport_rect().size.y
	var max_scroll := vh - 210.0# 210 = 标题栏(~60) + 边距(48) + 余量(100)
	scroll_h = clampf(scroll_h, 180.0, maxf(180.0, max_scroll))
	_panel_host.add_child(_shell(title, body, width, scroll_h))


func _close() -> void:
	for c in _panel_host.get_children():
		_panel_host.remove_child(c)
		c.queue_free()
	# ★ 必须一起清：_shell 只在**消费时**清 footer。
	#   面板被 Esc 关掉时 _shell 早就跑完了，footer 还挂着 ——
	#   下次开「存档」这种没设 footer 的面板，就会多出一个「开始比赛」按钮。
	_shell_footer = null


## 面板外壳。scroll_h 是内容滚动区的高度（逻辑像素）——
## 默认 372 够装五六个条目，联赛那种「32 行表格」要单独要更高的。
func _shell(title: String, body: Control, width: float, scroll_h: float = 372.0) -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var scrim := ColorRect.new()
	scrim.color = Color(0.0, 0.0, 0.0, 0.62)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close()
	)
	root.add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var pc := UiKit.panel(Vector2(width, 0))
	pc.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(pc)

	var m := UiKit.margin(30, 24, 30, 24)
	pc.add_child(m)
	var v := UiKit.vbox(16)
	m.add_child(v)

	var head := UiKit.hbox(12)
	var t := UiKit.label(title, 28)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var close := UiKit.button("关闭", 16, Vector2(92, 38))
	close.pressed.connect(_close)
	head.add_child(close)
	v.add_child(head)
	v.add_child(UiKit.hline())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, scroll_h)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)

	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	# ★★ 底部固定栏（2026-10-03 新增）。
	#
	#  「开始比赛」这类面板的**主行动按钮在内容最底部**，而内容常常
	#  高于滚动区 → 按钮被裁在滚动区外，矮窗口下玩家永远点不到。
	#  把footer 从 body 里挪到这里、钉在滚动区**下方**，
	#  它就永远可见 —— 内容再长也只滚动正文，主按钮不动。
	#
	#  传 null 表示没有固定栏（绝大多数面板）。
	if _shell_footer != null:
		var foot_wrap := UiKit.vbox(10)
		foot_wrap.add_child(UiKit.hline())
		foot_wrap.add_child(_shell_footer)
		v.add_child(foot_wrap)
		_shell_footer = null
	return root


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _panel_host.get_child_count() > 0:
		_close()
		get_viewport().set_input_as_handled()


# ───────────── ① 开始比赛 ─────────────
## 难度微调行：一条 0.00~4.00 的滑杆 + 实时读数 + 「归到整档」按钮。
##
## 每次开面板都重建 —— 不能复用同一个节点：`_open()` 会把上一个面板的
## 子树整个 free 掉，复用成员变量就会往已释放的节点上 add_child。
func _build_fine_tune() -> Control:
	var box := UiKit.vbox(6)

	# ★ 这里**不**因为「有未完成联赛」就隐藏微调。
	#   我第一版写了 `if Game.tournament_active(): return` —— 实拍才看清是错的：
	#   面板顶上已经写明「下面的难度用于**自由对战**」，也就是说这一栏照常生效
	#   （有联赛时被劫持的是**赛事场次**，不是这个面板）。既然难度能选，
	#   微调就该能拖 —— 凭空少一个功能比多一行字更糟。
	#   真正锁难度的是排位和赛事场次，而这两个都不从这个面板进场。
	#   有区别的是**去哪打**：赛事那一场的难度跟对手走，要去联赛面板点「开始本场」。

	# ★ 布局压成**两行**（标题+读数 / 滑杆+按钮），别做成三行。
	#   实拍过：三行会把下面的「模式」那栏顶出可视区，而面板一旦超高，
	#   滚轮滚的是**外层**（不是面板内的 ScrollContainer）——
	#   表现是「滚一下整个面板消失」，玩家以为面板坏了。
	#   省下一行的收益远大于把说明写全。
	var head := UiKit.hbox(10)
	head.add_child(UiKit.label("微调", 14, UiKit.TEXT_DIM))
	# 读数要能说清「现在算哪一档」：t=1.35 落在普通(1) 与困难(2) 之间，
	# 只显示「1.35」玩家不知道偏哪边，所以带上偏向。
	var val := UiKit.label("", 14, UiKit.ACCENT)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(val)
	var rst := UiKit.button("回整档", 13, Vector2(74, 26))
	# 「回整档」三个字看不出是干什么的，而面板里没有第二行可以写说明。
	rst.tooltip_text = "回到最近的那个整数档（简单/普通/困难/专家/大师）"
	head.add_child(rst)
	box.add_child(head)

	var s := UiKit.slider(1.0)
	s.min_value = 0.0
	s.max_value = 4.0
	# 0.05 一格：比它更细玩家分辨不出，再细只是让存档里多几个无意义的小数。
	s.step = 0.05
	s.value = Game.difficulty_t
	s.custom_minimum_size = Vector2(0, 22)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.tooltip_text = "在两档之间连续微调。停在整数就等于那一档的手感。"
	box.add_child(s)

	var refresh := func() -> void:
		var t: float = Game.difficulty_t
		var near := int(round(t))
		if absf(t - float(near)) < 0.001:
			val.text = "%.2f（%s）" % [t, _diff_name(near)]
		elif t < float(near):
			val.text = "%.2f（偏%s）" % [t, _diff_name(near - 1)]
		else:
			val.text = "%.2f（偏%s）" % [t, _diff_name(near)]
	refresh.call()

	s.value_changed.connect(func(x: float) -> void:
		Game.set_difficulty_t(x)
		refresh.call()
		# ★ 不重建整个面板：那会把手焦点丢在滑杆上（拖到一半面板重建 → 拖不动）。
		#   只更新受影响的两个控件：读数和五档按钮的高亮。
		_sync_diff_buttons()
	)
	rst.pressed.connect(func() -> void:
		Game.set_difficulty_t(float(Game.difficulty))
		refresh.call()
		_sync_diff_buttons()
	)
	return box


func _diff_name(i: int) -> String:
	var names := ["简单", "普通", "困难", "专家", "大师"]
	return names[clampi(i, 0, 4)]


## 把五档按钮的高亮同步到当前难度。微调滑杆拖动时调它。
## ★ 只能改样式不能重建按钮 —— 重建会毁掉按下状态，表现为「点不中」；
##   而且重建会把焦点从滑杆抢走，拖到一半面板重建 = 拖不动。
## ★ 提升/降级都必须四个状态一起设，只设 normal 会出现半吊子高亮
##   （底色变了、字体还是 primary 的深色）。这套配色只在 UiKit 里有一份，
##   所以调用 promote/demote 而不是在这里复刻。
func _sync_diff_buttons() -> void:
	_diff_buttons.clear()
	_collect_diff_buttons(self)
	var cur: int = Game.difficulty
	for b: Button in _diff_buttons:
		var idx: int = int(b.get_meta("diff_index", -1))
		if idx < 0:
			continue
		if idx == cur:
			UiKit.button_promote(b, UiKit.ACCENT)
		else:
			UiKit.button_demote(b)


## _diff_buttons 的成员声明在文件顶部（见 var _diff_buttons: Array[Button] = []）。
func _collect_diff_buttons(n: Node) -> void:
	for c in n.get_children():
		if c is Button and c.has_meta("diff_index"):
			_diff_buttons.append(c as Button)
		_collect_diff_buttons(c)


func _panel_start() -> Control:
	var v := UiKit.vbox(16)

	# ★ 有未完成联赛时在这里点破一句：面板里的难度确实生效，
	#   赛事赛程要从「联赛」面板进去打。以前不写这句话，是因为那时
	#   「有联赛」会把任何入口都劫持成赛事场次 —— 难度选了等于没选
	#   （用户 2026-10-03 报的「开始游戏那里选难度无用」）。
	#   现在两件事解耦了，但玩家不知道，所以主动讲清楚。
	if Game.tournament_active():
		v.add_child(UiKit.para("下面的难度用于**自由对战**。你那届联赛还剩 %s 没打，"
			% Tournament.stage_name(str(Game.tournament.get("stage", "group")))
			+ "要从「联赛 · 比赛模式」面板点「开始本场」才进那一场。",
			14, UiKit.TEXT_DIM, 480))

	v.add_child(UiKit.label("难度", 18, UiKit.TEXT))
	# ★ 三档改五档之后，一行放不下 5 个 170 px 的按钮（面板正文只有 ~480 px 宽）。
	#   用 HFlowContainer 让它自己换行，而不是手算两行 —— 换字体 / 改文案时不会突然溢出。
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 8)
	var names := ["简单", "普通", "困难", "专家", "大师"]
	var descs := [
		"球速慢、落点散，适合熟悉手感",
		"标准球速与判定",
		"球又快又刁，挥拍容错更小",
		"发球贴边带转，还会发短球逼你上前",
		"发球又快又贴边、对手几乎不失误 —— 大师档很难战胜",
	]
	for i in range(5):
		var d := i
		var b: Button
		if Game.difficulty == d:
			b = UiKit.button_primary(names[d], 16, UiKit.ACCENT, Vector2(104, 50))
		else:
			b = UiKit.button(names[d], 16, Vector2(104, 50))
		# ★ 记下这是第几档：微调滑杆拖动时要靠它更新高亮，
		#   而那时不能重建按钮（重建会毁掉按下状态，表现为「点不中」）。
		b.set_meta("diff_index", d)
		b.pressed.connect(func() -> void:
			Game.set_difficulty(d)
			_open("start")
		)
		row.add_child(b)
	v.add_child(row)
	v.add_child(UiKit.label(descs[Game.difficulty], 14, UiKit.TEXT_DIM))

	# ── 精细微调（2026-10-04）──
	# ★ 为什么在五档按钮下面还要一个滑杆：底层早就支持连续难度
	#   （`_tier5()` 线性插值，排位 21 个段位一直在用），但面板只能选 5 个点。
	#   于是「比普通难一点、没到困难」——也就是大多数玩家的实际需求 ——
	#   无处表达。这一行不新增任何机制，只是把已有的浮点档位暴露出来。
	#
	#   零行为变化：滑杆停在整数时 `_diff_t` 与原来逐位相等
	#   （回归探针 A 组守着这条）。所以「不拖它」= 行为与改动前完全一样。
	v.add_child(_build_fine_tune())
	v.add_child(UiKit.spacer(8))

	# ── 单打 / 双打（自动切换）/ 双打（队友 AI）──	# 三选一。存进 Game 的是「doubles 开关 + partner_ai 开关」两个 bool：
	# 赛事那条链路（tournament.gd）全按 1v1 写的，用 bool 隔开最不容易串。
	v.add_child(UiKit.label("模式", 18, UiKit.TEXT))
	var mrow := UiKit.hbox(8)
	# 0 = 单打 / 1 = 双打·自动切换 / 2 = 双打·队友 AI
	var mnames := ["单打", "双打·轮换", "双打·AI队友"]
	for i in range(3):
		var want_mode := i
		var mb: Button
		var sel := (0 if not Game.doubles else (2 if Game.partner_ai else 1))
		if sel == want_mode:
			mb = UiKit.button_primary(mnames[i], 16, UiKit.ACCENT, Vector2(150, 50))
		else:
			mb = UiKit.button(mnames[i], 16, Vector2(150, 50))
		mb.pressed.connect(func() -> void:
			Game.doubles = (want_mode != 0)
			Game.partner_ai = (want_mode == 2)
			Game.save_profile()
			_open("start")
		)
		mrow.add_child(mb)
	v.add_child(mrow)
	if not Game.doubles:
		v.add_child(UiKit.para("1 对 1，不收入场费。", 14, UiKit.TEXT_DIM, 480))
	elif Game.partner_ai:
		v.add_child(UiKit.para("你只守自己这一侧，**另一半边交给 AI 队友** —— 相机不再横移，"
			+ "队友那把拍子会自己跑位、自己挥。仍然**必须轮流击球**。"
			+ "入场费 %d 金币，赢了得 %d。"
			% [Game.DOUBLES_FEE, Game.DOUBLES_PRIZE], 14, UiKit.TEXT_DIM, 480))
	else:
		v.add_child(UiKit.para("两人搭档，各守半边。**必须轮流击球**，"
			+ "同一人连打两次判失分 —— 控制权会在你和队友之间自动切换。"
			+ "入场费 %d 金币，赢了得 %d。"
			% [Game.DOUBLES_FEE, Game.DOUBLES_PRIZE], 14, UiKit.TEXT_DIM, 480))
	v.add_child(UiKit.spacer(10))

	var a := Game.get_arena(Game.current_arena)
	var info := UiKit.hbox(10)
	info.add_child(UiKit.label("场馆", 17, UiKit.TEXT_DIM))
	info.add_child(UiKit.label(str(a["name"]), 17, UiKit.TEXT))
	info.add_child(UiKit.spacer())
	var shop_btn := UiKit.button("去商店换一个", 15, Vector2(0, 36))
	shop_btn.pressed.connect(func() -> void: _open("shop"))
	info.add_child(shop_btn)
	v.add_child(info)
	v.add_child(UiKit.para(str(a["desc"]), 14, UiKit.TEXT_MUTE, 480))
	v.add_child(UiKit.spacer(10))

	# 入场费：不够钱就把按钮禁用，而不是点下去才发现进不去。
	# 费用在**进场景前**扣（见下面），扣了才切场景 ——
	# 反过来先切场景再扣的话，中途退出就等于白嫖一场。
	var go := UiKit.button_primary(
		("开始双打　付 %d 金币入场" % Game.DOUBLES_FEE) if Game.doubles else "开始比赛",
		24, UiKit.ACCENT, Vector2(0, 66))
	if Game.doubles and not Game.can_afford(Game.DOUBLES_FEE):
		go.disabled = true
		v.add_child(UiKit.para("金币不足：入场要 %d，你现在只有 %d。先打几局单打攒攒。"
			% [Game.DOUBLES_FEE, Game.coins], 14, UiKit.TEXT_DIM, 480))
	go.pressed.connect(func() -> void:
		if Game.doubles:
			if not Game.spend_coins(Game.DOUBLES_FEE):
				_open("start")
				return
		# ★ 从「开始比赛」进场一律是自由对战 / 双打，两个模式旗标都要摘掉 ——
		#   它们是持久化在单例上的（要活过「再来一局」的场景重载）。
		#   ranked：不摘的话上一场排位打完再点「开始比赛」会又进排位。
		#   tour_entry：★ 不摘的话「报名过一届联赛」之后，任何一次点「开始比赛」
		#     都会被劫持成赛事场次，上面那五档难度全部作废（用户 2026-10-03 报的）。
		#     联赛进度存在 tournament 里不受影响，只是这一场按菜单难度打。
		Game.ranked = false
		Game.tour_entry = false
		Game.save_profile()
		get_tree().change_scene_to_file(GAME_SCENE)
	)
	# ★ 主按钮放**底部固定栏**，不放正文里。
	#   内容（难度 + 模式 + 场馆说明）在矮窗口下必然超过滚动区高度，
	#   按钮写在正文末尾就永远被裁在可视区之外 —— 玩家点了没反应、
	#   游戏进不去，而且完全看不出原因（这是 2026-10-03 实机踩到的）。
	_shell_footer = go
	return v


# ───────────── ② 声音设置 ─────────────
func _panel_settings() -> Control:
	var v := UiKit.vbox(16)
	v.add_child(UiKit.para("三条总线分别是总闸、击球音效、现场氛围。"
		+ "下面还能调球拍灵敏度（鼠标推一下球拍走多远）。"
		+ "所有改动都立刻生效并自动保存。", 15, UiKit.TEXT_DIM, 600))
	v.add_child(UiKit.volume_controls())

	# ── 得分呐喊 / 失分奶龙笑 ──
	# 这两条是**同一条 SFX 总线上的分项**，各自带独立开关：
	# 有人就是不想听奶龙笑，但仍想保留得分时的欢呼 —— 一刀切的总闸做不到。
	v.add_child(UiKit.hline())
	v.add_child(UiKit.label("得分 / 失分的声音", 18, UiKit.TEXT))
	v.add_child(UiKit.para(
		"得分放观众呐喊，失分放奶龙大笑。两条可以单独关掉，音量也单独调 —— "
		+ "关掉不会动音量条，再打开还是原来的响度。", 14, UiKit.TEXT_DIM, 620))
	v.add_child(_voice_row("cheer", "得分呐喊",
		"得分、以及 10 / 20 拍里程碑时的观众欢呼"))
	v.add_child(_voice_row("concede", "失分奶龙笑",
		"丢一分时那声大笑（有 0.9 秒冷却，连丢分不会糊成一片）"))
	v.add_child(_voice_row("crowd", "背景人群声",
		"一直开着的现场底噪。默认关；打开后得分时它会先压低、让呐喊露出来，"
		+ "再一起爆发。"))

	# ── 球拍 / 视角灵敏度 ──
	# 用户要的「拍移动灵敏度下降 + 提供灵敏度设置」。
	# 球拍挂在相机下，鼠标一推拍子就跟着走，所以这条直接决定瞄准手感。
	v.add_child(UiKit.hline())
	v.add_child(UiKit.label("操作", 18, UiKit.TEXT))
	v.add_child(UiKit.look_controls())

	# ── 全屏 ──
	# 桌面端也可以直接按 F11 / Alt+Enter，但按钮是**唯一对 Web 也有效**的入口：
	# 浏览器只认真实用户手势，脚本自发请求全屏一律被拒。
	v.add_child(UiKit.hline())
	var fs_row := UiKit.hbox(12)
	fs_row.add_child(UiKit.label("显示", 18, UiKit.TEXT))
	var fs_btn := UiKit.button("切换全屏", 18, Vector2(240, 48))
	fs_btn.pressed.connect(func() -> void:
		Game.toggle_fullscreen()
		# deferred：不能在自己的 pressed 信号里同步重建面板 ——
		# 那一刻按钮还在信号发射栈上，直接 _refresh() 会把它释放掉。
		_refresh.call_deferred()
	)
	fs_row.add_child(fs_btn)
	v.add_child(fs_row)
	v.add_child(UiKit.para(
		("当前：全屏。按 F11 或 Alt+Enter 退出。" if Game.is_fullscreen()
			else "当前：窗口（已最大化到 1080p）。按 F11 / Alt+Enter 进入全屏。"),
		14, UiKit.TEXT_DIM, 620))
	return v


## 一条「可开关 + 可调音量」的音效行：名称 / 开关 / 音量滑杆 / 试听。
##
## ★ 开关按钮点完要**重建面板**而不是只改自己的文字：开关状态存在 Game 里，
##   设置面板之外（比如别处读 sfx_gain_db 的地方）也依赖它，重建是最不容易
##   漏掉的一招。★ 但必须 call_deferred —— 按钮此刻还在自己的 pressed 信号
##   发射栈上，同步重建会把它释放掉（全屏切换那个按钮踩过同一件事）。
##
## ★ 三条分项（cheer / concede / crowd）走同一个函数，靠 `_voice_on` /
##   `_voice_set_on` 两个查表函数分派。
##   原来这里是 `if key == "cheer" else ...` 的二元三元式 —— 那样写加第三条
##   时**不会报错**，crowd 会被当成 concede：开关打开的是奶龙笑而不是底噪。
##   查表 + 缺键直接 assert，坑掉的时候立刻炸。
func _voice_row(key: String, nm: String, desc: String) -> Control:
	var v := UiKit.vbox(5)

	var h := UiKit.hbox(12)
	var name_l := UiKit.label(nm, 17, UiKit.TEXT)
	name_l.custom_minimum_size = Vector2(108, 0)
	h.add_child(name_l)

	var on := _voice_on(key)
	var tb := UiKit.button("开" if on else "关", 16, Vector2(74, 40))
	tb.add_theme_color_override("font_color",
		UiKit.ACCENT_2 if on else UiKit.TEXT_MUTE)
	tb.pressed.connect(func() -> void:
		_voice_set_on(key, not _voice_on(key))
		_open.call_deferred("settings")
	)
	h.add_child(tb)

	var s := UiKit.slider(Game.get_volume(key))
	s.custom_minimum_size = Vector2(0, 28)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vl := UiKit.label("%d%%" % int(round(Game.get_volume(key) * 100.0)),
		16, UiKit.TEXT_DIM)
	vl.custom_minimum_size = Vector2(58, 0)
	vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.value_changed.connect(func(x: float) -> void:
		Game.set_volume(key, x)
		vl.text = "%d%%" % int(round(x * 100.0))
	)
	h.add_child(s)
	h.add_child(vl)

	# 试听走的是**当前这条**（含开关与增益），所以关掉时点了没声是预期行为，
	# 不是按钮坏了 —— 关掉状态下这个按钮也一并禁用，免得被当成 bug。
	var t := UiKit.button("试听", 15, Vector2(92, 40))
	t.disabled = not on
	t.tooltip_text = "这一条已关闭，先打开再试听" if not on else ""
	t.pressed.connect(func() -> void: UiKit._preview(key))
	h.add_child(t)
	v.add_child(h)

	v.add_child(UiKit.para(desc, 13, UiKit.TEXT_MUTE, 640))
	return v


## 读某条分项的开关状态。
## ★ 必须用查表而不是 `if key == "cheer" else concede_on` ——
##   那种二元写法加第三条分项时不会报错，只是默默把新 key 当成 concede。
func _voice_on(key: String) -> bool:
	match key:
		"cheer":
			return Game.cheer_on
		"concede":
			return Game.concede_on
		"crowd":
			return Game.crowd_on
	push_error("未知的音效分项：" + key)
	return false


## 写某条分项的开关状态。见 _voice_on 的注释（缺键必须炸，不能默默兜底）。
func _voice_set_on(key: String, v: bool) -> void:
	match key:
		"cheer":
			Game.set_cheer_enabled(v)
		"concede":
			Game.set_concede_enabled(v)
		"crowd":
			Game.set_crowd_enabled(v)
		_:
			push_error("未知的音效分项：" + key)


# ───────────── ③ 存档 ─────────────
func _panel_save() -> Control:
	var v := UiKit.vbox(14)
	v.add_child(UiKit.para("存档保存的是完整进度：金币、已解锁场馆、任务领取情况、"
		+ "累计战绩。读取会**覆盖**当前进度。", 15, UiKit.TEXT_DIM, 680))

	for i in range(Game.SLOT_COUNT):
		var idx := i
		var info := Game.slot_info(i)
		var row := UiKit.row()
		var m := UiKit.margin(18, 14, 18, 14)
		row.add_child(m)
		var h := UiKit.hbox(16)
		m.add_child(h)

		var col := UiKit.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(UiKit.label("存档 %d" % (i + 1), 19, UiKit.TEXT))
		if bool(info["empty"]):
			col.add_child(UiKit.label("空", 14, UiKit.TEXT_MUTE))
		else:
			col.add_child(UiKit.label("%s　·　%d 金币　·　%d 分　·　赢 %d 局　·　%s　·　%s" % [
				str(info["time"]), int(info["coins"]), int(info["points"]),
				int(info["won"]), str(info["arena"]), str(info.get("rank", "—"))],
				14, UiKit.TEXT_DIM))
		h.add_child(col)

		var bs := UiKit.hbox(8)
		var bsave := UiKit.button("保存", 15, Vector2(84, 40))
		bsave.pressed.connect(func() -> void:
			Game.save_slot(idx)
			_open("save")
		)
		bs.add_child(bsave)

		var bload := UiKit.button("读取", 15, Vector2(84, 40))
		bload.disabled = bool(info["empty"])
		bload.pressed.connect(func() -> void:
			if Game.load_slot(idx):
				_open("save")
		)
		bs.add_child(bload)

		var bdel := UiKit.button("删除", 15, Vector2(84, 40))
		bdel.disabled = bool(info["empty"])
		bdel.pressed.connect(func() -> void:
			Game.delete_slot(idx)
			_open("save")
		)
		bs.add_child(bdel)
		h.add_child(bs)
		v.add_child(row)

	v.add_child(UiKit.spacer(6))
	var reset := UiKit.button("清空全部进度（金币 / 场馆 / 战绩 / 任务）", 15, Vector2(0, 44))
	reset.pressed.connect(func() -> void:
		Game.reset_all()
		_open("save")
	)
	v.add_child(reset)
	return v


# ───────────── ④ 任务 · 每日 / 每周 / 生涯 ─────────────
#
# ★ 2026-10-03（经济重做第一期）改动说明：
#   原来这里只有一张「生涯成就」表 —— 36 条全是历史累计、领一次就永远没了，
#   通关之后玩家点开是一面灰墙，**没有任何东西会再长出来**。
#   现在拆成三块，默认落在「每日任务」：那是每天都会重新长出来的部分。
#
# ★ 为什么把每日任务放在第一个页签：面板被打开的理由通常就是「今天的任务做完没」，
#   多一次点击就多一批人看不到。生涯成就反而变成「顺便看看」的第三页。
const QUEST_TABS := [
	["daily", "每日任务"],
	["weekly", "每周任务"],
	["life", "生涯成就"],
]

func _panel_quests() -> Control:
	var v := UiKit.vbox(14)
	# ★ 打开面板也要对齐日期：玩家可能开着菜单跨过零点。
	Game.daily_ensure()
	Game.weekly_ensure()

	var nd := Game.daily_claimable_count()
	var nw := Game.weekly_claimable_count()
	var nl := Game.claimable_count()
	var total := nd + nw + nl

	var head := UiKit.hbox(10)
	head.add_child(UiKit.label("金币 %d" % Game.coins, 18, UiKit.GOLD))
	head.add_child(UiKit.spacer())
	head.add_child(UiKit.label(
		"有 %d 个奖励可领取" % total if total > 0 else "暂时没有可领取的奖励",
		15, UiKit.GOLD if total > 0 else UiKit.TEXT_MUTE))
	v.add_child(head)
	v.add_child(UiKit.hline())

	var tabs := UiKit.hbox(10)
	for spec: Array in QUEST_TABS:
		var key := str(spec[0])
		var tb: Button
		if _quest_tab == key:
			tb = UiKit.button_primary(str(spec[1]), 17, UiKit.ACCENT, Vector2(152, 44))
		else:
			tb = UiKit.button(str(spec[1]), 17, Vector2(152, 44))
		tb.pressed.connect(func() -> void:
			# 和联赛面板一样，靠「整块重建」刷新选中态
			_quest_tab = key
			_open("quests")
		)
		tabs.add_child(tb)
	tabs.add_child(UiKit.spacer())
	v.add_child(tabs)

	var body := UiKit.vbox(12)
	v.add_child(body)
	match _quest_tab:
		"weekly":
			_quest_fill_weekly(body)
		"life":
			_quest_fill_life(body)
		_:
			_quest_fill_daily(body)
	return v


func _quest_fill_daily(v: Control) -> void:
	var ds: Dictionary = Game.daily_summary()
	var streak := int(ds["streak"])
	var mult := float(ds["mult"])

	# ── 状态卡：完成度 + 连续天数 + 倍率 ──
	# ★ 把「漏一天不清零」直接写在面板上。这条规则玩家猜不到，
	#   不写出来他只会默认「断了 = 归零」，于是一次漏打卡就再也不打开。
	var card := UiKit.row()
	var cm := UiKit.margin(18, 14, 18, 14)
	card.add_child(cm)
	var cv := UiKit.vbox(8)
	cm.add_child(cv)
	cv.add_child(UiKit.label("今日进度　%d / %d" % [int(ds["done"]), int(ds["total"])],
		20, UiKit.TEXT))
	var sub: String = "连续完成 %d 天　·　今日奖励 ×%.1f" % [streak, mult] \
		if streak > 0 else "连续完成能拿到更高倍率：3 天 ×1.3 / 7 天 ×1.6 / 14 天 ×2.0 / 30 天 ×2.5"
	cv.add_child(UiKit.label(sub, 15, UiKit.GOLD if streak > 0 else UiKit.TEXT_DIM))
	cv.add_child(UiKit.para("漏 1 天不会清零，只是停在原天数；连着多天不来才会慢慢掉。",
		13, UiKit.TEXT_MUTE, 700))
	v.add_child(card)

	for idv in Game.daily_ids():
		var q := Game.daily_quest_by_id(str(idv))
		if q.is_empty():
			continue
		# ★ 奖励显示的是**乘过倍率之后**的数，不然玩家领到的比看到的多，
		#   会以为数字算错了。
		v.add_child(_quest_row(q, Game.daily_progress(q), Game.daily_goal(q),
			Game.daily_complete(q), Game.daily_claimed(q),
			int(round(float(int(q["reward"])) * mult)),
			_claim_daily.bind(q)))

	# ── 全清奖励：唯一会把连续天数 +1 的地方 ──
	v.add_child(UiKit.hline())
	v.add_child(_quest_all_row(
		"今日全清奖励", "三条都完成：额外金币 + 连续天数 +1 + 1 张球拍券",
		"+%d 金币　+1 券" % int(round(float(int(ds["all_reward"])) * mult)),
		bool(ds["all"]), bool(ds["all_clear"]), _claim_daily_all))


func _quest_fill_weekly(v: Control) -> void:
	var wk: String = str(Game.weekly.get("key", ""))
	v.add_child(UiKit.para("当前周次 %s　·　每周一刷新，三条固定不抽签 —— "
		% wk + "周目标应该是可预期的（「这周我要把排位打上黄金」），"
		+ "抽签只适合一天粒度的东西。", 14, UiKit.TEXT_DIM, 760))
	for q: Dictionary in Game.WEEKLY_QUESTS:
		v.add_child(_quest_row(q, Game.weekly_progress(q), Game.weekly_goal(q),
			Game.weekly_complete(q), Game.weekly_claimed(q), int(q["reward"]),
			_claim_weekly.bind(q)))
	v.add_child(UiKit.hline())
	v.add_child(_quest_all_row(
		"本周全清奖励", "三条都完成：额外金币 + 1 张场馆券",
		"+%d 金币　+1 场馆券" % int(Game.WEEKLY_ALL_REWARD),
		bool(Game.weekly.get("all", false)), Game.weekly_all_clear(), _claim_weekly_all))


func _quest_fill_life(v: Control) -> void:
	# 生涯成就：一次性、永不刷新。文案上说明白它是「起步资金」，
	# 免得玩家拿它和每日任务比，觉得「被砍了」。
	v.add_child(UiKit.para("一次性成就 —— 领完就没了，是刚起步时的资金。 "
		+ "日常收入请看「每日任务」。", 14, UiKit.TEXT_DIM, 760))
	# ── 一键领取（用户 2026-10-06 要的）──
	# ★ 每日 / 每周两个页签早就有「全部领取」了，生涯成就这边一直只能一条条点：
	#   二十多条成就里躺着七八个可领的，玩家得点七八次 —— 实际结果就是干脆不领。
	# ★ 只在**真的有可领取**时才放这个按钮：平时摆一个点不动的灰按钮只是噪音，
	#   而「可领取个数」本身也是给玩家看的进度信息。
	var n := Game.claimable_count()
	if n > 0:
		var ball := UiKit.button_primary("一键领取全部成就（%d 个）" % n, 18,
			UiKit.ACCENT_2, Vector2(0, 52))
		ball.pressed.connect(_claim_life_all)
		v.add_child(ball)
	for q: Dictionary in Game.QUESTS:
		v.add_child(_quest_row(q, Game.quest_progress(q), Game.quest_goal(q),
			Game.is_quest_complete(q), Game.is_quest_claimed(q), int(q["reward"]),
			_claim_life.bind(q)))


## 一条任务的行。三个页签共用，只是传进来的进度/领取回调不同。
##
## ★ on_claim 用 `callable.bind(q)` 传进来，而不是在循环里写
##   `func(): Game.claim_quest(q)` —— 闭包捕获循环变量是有名的坑，
##   一旦 Godot 是按引用捕获，所有按钮都会领到最后一条。bind 没有这个歧义。
func _quest_row(q: Dictionary, cur: int, goal: int, done: bool, got: bool,
		reward: int, on_claim: Callable) -> Control:
	var row := UiKit.row()
	var m := UiKit.margin(18, 14, 18, 14)
	row.add_child(m)
	var h := UiKit.hbox(18)
	m.add_child(h)

	var col := UiKit.vbox(6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label(str(q["name"]), 19,
		UiKit.TEXT if not got else UiKit.TEXT_MUTE))
	col.add_child(UiKit.label(str(q["desc"]), 14, UiKit.TEXT_DIM))
	var pbar := UiKit.progress(mini(cur, goal), goal, 0.0,
		UiKit.ACCENT_2 if done else UiKit.ACCENT)
	pbar.size_flags_horizontal = Control.SIZE_FILL
	pbar.custom_minimum_size = Vector2(300, 10)
	col.add_child(pbar)
	h.add_child(col)

	var num := UiKit.vbox(4)
	num.custom_minimum_size = Vector2(96, 0)
	num.alignment = BoxContainer.ALIGNMENT_CENTER
	var pl := UiKit.label("%d / %d" % [mini(cur, goal), goal], 17,
		UiKit.ACCENT_2 if done else UiKit.TEXT_DIM)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.add_child(pl)
	var rl := UiKit.label("+%d 金币" % reward, 14, UiKit.GOLD)
	rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.add_child(rl)
	h.add_child(num)

	var b: Button
	if got:
		b = UiKit.button("已领取", 16, Vector2(118, 46))
		b.disabled = true
	elif done:
		b = UiKit.button_primary("领取", 16, UiKit.ACCENT_2, Vector2(118, 46))
		b.pressed.connect(on_claim)
	else:
		b = UiKit.button("未达成", 16, Vector2(118, 46))
		b.disabled = true
	h.add_child(b)
	return row


## 「全清奖励」那一行。done = 已领，clear = 达标没领。
func _quest_all_row(title: String, desc: String, reward_text: String,
		done: bool, clear: bool, on_claim: Callable) -> Control:
	var row := UiKit.row()
	var m := UiKit.margin(18, 14, 18, 14)
	row.add_child(m)
	var h := UiKit.hbox(18)
	m.add_child(h)

	var col := UiKit.vbox(6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label(title, 19, UiKit.ACCENT_2))
	col.add_child(UiKit.label(desc, 14, UiKit.TEXT_DIM))
	h.add_child(col)

	var num := UiKit.vbox(4)
	num.custom_minimum_size = Vector2(96, 0)
	num.alignment = BoxContainer.ALIGNMENT_CENTER
	var rl := UiKit.label(reward_text, 16, UiKit.GOLD)
	rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.add_child(rl)
	h.add_child(num)

	var b: Button
	if done:
		b = UiKit.button("已领取", 16, Vector2(118, 46))
		b.disabled = true
	elif clear:
		b = UiKit.button_primary("领取", 16, UiKit.ACCENT_2, Vector2(118, 46))
		b.pressed.connect(on_claim)
	else:
		b = UiKit.button("未达成", 16, Vector2(118, 46))
		b.disabled = true
	h.add_child(b)
	return row


# ── 领取回调。领完重建面板刷新状态（3 个页签，重建开销可忽略）──
func _claim_daily(q: Dictionary) -> void:
	Game.daily_claim(q)
	_open("quests")


func _claim_daily_all() -> void:
	Game.daily_claim_all()
	_open("quests")


func _claim_weekly(q: Dictionary) -> void:
	Game.weekly_claim(q)
	_open("quests")


func _claim_weekly_all() -> void:
	Game.weekly_claim_all()
	_open("quests")


func _claim_life(q: Dictionary) -> void:
	Game.claim_quest(q)
	_open("quests")


func _claim_life_all() -> void:
	Game.claim_all()
	_open("quests")


# ───────────── ⑤ 排位赛 · 段位天梯（方案 B）─────────────
func _panel_rank() -> Control:
	var v := UiKit.vbox(16)

	# 赛季刚翻页 → 把结算摆在最上面。这是「赛季」唯一会被玩家感知到的时刻，
	# 不在这里说他永远不知道自己的分数为什么变少了。
	if not _season_news.is_empty():
		v.add_child(_season_block(_season_news))
		_season_news = {}

	var rank_nm: String = Game.rank_name()
	var into: int = Game.rank_into_div()
	var span: int = Game.rank_div_span()
	var at_max: bool = Game.rank_is_max()

	# ── 段位大字 ──
	var head := UiKit.hbox(16)
	var col := UiKit.vbox(2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label("当前段位", 14, UiKit.TEXT_MUTE))
	col.add_child(UiKit.label(rank_nm, 46, UiKit.GOLD))
	head.add_child(col)

	var num := UiKit.vbox(4)
	num.alignment = BoxContainer.ALIGNMENT_CENTER
	var pl := UiKit.label("%d 分" % Game.rank_points, 28, UiKit.TEXT)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	num.add_child(pl)
	var nl := UiKit.label("已到顶" if at_max
		else "距 %s 还差 %d 分" % [Game.rank_next_name(), maxi(span - into, 0)],
		14, UiKit.TEXT_DIM)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	num.add_child(nl)
	head.add_child(num)
	v.add_child(head)

	var bar := UiKit.progress(into, span, 0.0, UiKit.GOLD)
	bar.custom_minimum_size = Vector2(0, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(bar)
	v.add_child(UiKit.label("本小级 %d / %d 分　·　共 %d 个小级（7 段 × 3 级）"
		% [into, span, Game.RANK_MAX_DIV + 1], 13, UiKit.TEXT_MUTE))

	# ── 战绩 ──
	v.add_child(UiKit.hline())
	var grid := UiKit.hbox(22)
	var rm := int(Game.stats["rank_matches"])
	var rw := int(Game.stats["rank_wins"])
	grid.add_child(_kv("排位场次", "%d 场" % rm))
	grid.add_child(_kv("排位胜场", "%d 场" % rw))
	grid.add_child(_kv("胜率", "—" if rm <= 0 else "%.0f%%" % (100.0 * float(rw) / float(rm))))
	grid.add_child(_kv("历史最高", Game.rank_div_label(int(Game.stats["rank_best_tier"]))))
	v.add_child(grid)

	# ── 连胜 / 连败 / 赛季 ──
	var info := UiKit.vbox(5)
	if Game.rank_streak >= 1:
		info.add_child(UiKit.label("当前 %d 连胜　金币 ×%.1f"
			% [Game.rank_streak, Game.rank_coins_mult()], 16, UiKit.GOLD))
	else:
		info.add_child(UiKit.label("当前没有连胜　（3 连胜起金币 ×1.2 / 1.4 / 1.6）",
			14, UiKit.TEXT_DIM))
	var ls := Game.rank_lose_streak
	if ls > 0:
		var left := maxi(Game.RANK_LOSS_SHIELD - ls, 0)
		if left > 0:
			info.add_child(UiKit.label("连败 %d 场　保底还剩 %d 次不掉级" % [ls, left],
				14, UiKit.TEXT_DIM))
		else:
			info.add_child(UiKit.label("连败 %d 场　保底已失效，再输就会掉级" % ls,
				14, UiKit.ACCENT))
	info.add_child(UiKit.label("赛季 %s　本赛季最高 %s" % [Game.rank_season,
		Game.rank_div_label(Game.rank_div_of(Game.rank_season_peak))], 15, UiKit.TEXT_DIM))
	v.add_child(info)
	v.add_child(UiKit.para("赛季每周翻页：上个赛季的段位分回落到 60%，"
		+ "并按本赛季达到过的最高段位发一笔金币奖励。想保住段位就得回来打。",
		13, UiKit.TEXT_MUTE, 660))

	# ── 对手强度 ──
	v.add_child(UiKit.hline())
	v.add_child(UiKit.label("对手强度", 17, UiKit.TEXT))
	var t := Game.rank_difficulty_t()
	var dnames := ["简单", "普通", "困难", "专家", "大师"]
	v.add_child(UiKit.para("本段位对应「%s」档（%.2f / 4）。段位越高，对手回球越快、"
		% [dnames[clampi(int(round(t)), 0, 4)], t]
		+ "落点越贴边、自己失误越少 —— 而且是**逐级平滑上升**，不会突然跳档。",
		14, UiKit.TEXT_DIM, 660))

	# ── 段位表 ──
	v.add_child(UiKit.label("段位表", 17, UiKit.TEXT))
	var tl := UiKit.vbox(3)
	var cur := Game.rank_tier()
	var my_div := Game.rank_div()
	for i in range(Game.RANK_TIERS.size()):
		var row := UiKit.hbox(12)
		var is_cur := i == cur
		var c := UiKit.GOLD if is_cur else UiKit.TEXT_DIM
		row.add_child(UiKit.label(str(Game.RANK_TIERS[i]), 16, c))
		if is_cur:
			row.add_child(UiKit.label(Game.RANK_DIVS[my_div - i * Game.RANK_DIVS_PER_TIER],
				15, UiKit.GOLD))
		row.add_child(UiKit.spacer())
		row.add_child(UiKit.label("%d ~ %d 分"
			% [i * 300, (i + 1) * 300 - 1], 13, UiKit.TEXT_MUTE))
		if is_cur:
			row.add_child(UiKit.label("◀ 当前", 13, UiKit.GOLD))
		tl.add_child(row)
	v.add_child(tl)

	# ── 开打 ──
	v.add_child(UiKit.spacer(8))
	var go := UiKit.button_primary("进入排位赛", 24, UiKit.ACCENT, Vector2(0, 66))
	go.pressed.connect(func() -> void:
		Game.ranked = true
		# ★ 双打必须一起关掉：它在 apply_preferences() 里的优先级最高，
		#   不清的话「进入排位赛」会被静默降级成一场双打。
		Game.doubles = false
		Game.partner_ai = false
		# ★ 赛事旗标同理。排位的优先级本来就压过赛事（apply_preferences 里
		#   ranked 先判），所以这一行不是修bug、是为了让「旗标各自独立」
		#   这条不变量在三个入口都成立 —— 少一处就等于埋一个下次加功能会踩的坑。
		Game.tour_entry = false
		Game.save_profile()
		get_tree().change_scene_to_file(GAME_SCENE)
	)
	v.add_child(go)
	v.add_child(UiKit.para("排位赛按当前段位决定 AI 强度，局内不能手动改难度。"
		+ "段位分与连胜自动保存，中途退出不丢。", 13, UiKit.TEXT_MUTE, 660))
	return v


## 跨赛季结算提示块。只在赛季刚翻页的那一次出现。
func _season_block(s: Dictionary) -> Control:
	var box := UiKit.panel()
	var m := UiKit.margin(18, 14, 18, 14)
	box.add_child(m)
	var v := UiKit.vbox(6)
	m.add_child(v)

	v.add_child(UiKit.label("新赛季开始　%s" % str(s.get("season", "")), 19, UiKit.GOLD))
	v.add_child(UiKit.label("上个赛季最高打到 %s　·　段位分 %d → %d（回落到 60%%）"
		% [str(s.get("peak_name", "")), int(s.get("points_before", 0)),
			int(s.get("points_after", 0))], 15, UiKit.TEXT))
	var rw := int(s.get("reward", 0))
	if rw > 0:
		v.add_child(UiKit.label("赛季奖励 +%d 金币（按最高段位 %s 结算）"
			% [rw, str(s.get("peak_name", ""))], 16, UiKit.GOLD))
	else:
		v.add_child(UiKit.label("本赛季没爬上白银，没有赛季奖励。", 14, UiKit.TEXT_MUTE))
	return box


## 「小标题 + 值」的一格。好几个面板都要用，抽出来免得各写一份。
func _kv(name: String, value: String) -> Control:
	var v := UiKit.vbox(3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UiKit.label(name, 13, UiKit.TEXT_MUTE))
	v.add_child(UiKit.label(value, 19, UiKit.TEXT))
	return v


# ───────────── ⑥ 商店 · 更换场馆 ─────────────
func _panel_shop() -> Control:
	var v := UiKit.vbox(14)
	var head := UiKit.hbox(10)
	head.add_child(UiKit.label("金币 %d" % Game.coins, 18, UiKit.GOLD))
	head.add_child(UiKit.spacer())
	head.add_child(UiKit.label("打比赛和完成任务都能赚金币", 15, UiKit.TEXT_MUTE))
	v.add_child(head)
	v.add_child(UiKit.hline())

	# ── 今日限购（第三期）──
	# ★ 放在最上面：玩家进商店第一眼该看到的是「今天有便宜可捡」，
	#   而不是一屏买不起的东西。每天换一件、限购 1 件。
	var dl := Game.deal_ensure()
	if not dl.is_empty() and dl.has("id"):
		var dbox := UiKit.row()
		var dm := UiKit.margin(18, 14, 18, 14)
		dbox.add_child(dm)
		var dh := UiKit.hbox(16)
		dm.add_child(dh)
		var dcol := UiKit.vbox(5)
		dcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dcol.add_child(UiKit.label("今日限购", 20, UiKit.GOLD))
		dcol.add_child(UiKit.label("%s　%d → %d 金币" % [
			str(dl["name"]), int(dl["orig"]), int(dl["price"])],
			16, UiKit.TEXT))
		dcol.add_child(UiKit.label("每天换一件，限购 1 件，跨天刷新", 14, UiKit.TEXT_DIM))
		dh.add_child(dcol)
		var db: Button
		if bool(dl.get("bought", false)):
			db = UiKit.button("今日已购", 16, Vector2(130, 46))
			db.disabled = true
		elif Game.can_afford(int(dl["price"])):
			db = UiKit.button_primary("买下", 16, UiKit.GOLD, Vector2(130, 46))
			db.pressed.connect(func() -> void:
				Game.deal_buy()
				_open("shop")
			)
		else:
			db = UiKit.button("金币不够", 16, Vector2(130, 46))
			db.disabled = true
		dh.add_child(db)
		v.add_child(dbox)
		v.add_child(UiKit.hline())

	# ── 场馆券（经济二期）──
	# ★ 券只能抵 ≤ ARENA_TICKET_MAX_PRICE 的场馆。这句话必须写在面板上，
	#   否则玩家攒了券发现「最想要的那个用不了」会直接认为是 bug。
	if Game.tickets_arena > 0:
		var tb := UiKit.hbox(10)
		tb.add_child(UiKit.label("场馆券 ×%d" % Game.tickets_arena, 17, UiKit.ACCENT_2))
		tb.add_child(UiKit.para(
			"每周任务全清给 1 张，可直接兑换标价 %d 以下的场馆"
			% Game.ARENA_TICKET_MAX_PRICE, 14, UiKit.TEXT_DIM, 520))
		tb.add_child(UiKit.spacer())
		v.add_child(tb)
		v.add_child(UiKit.hline())

	for a: Dictionary in Game.ARENAS:
		var aid := str(a["id"])
		var owned := Game.is_unlocked(aid)
		var using := Game.current_arena == aid
		var price := int(a["price"])
		var theme: Dictionary = a.get("theme", {})

		var row := UiKit.row()
		var m := UiKit.margin(18, 16, 18, 16)
		row.add_child(m)
		var h := UiKit.hbox(18)
		m.add_child(h)

		# 配色预览：直接把这个主题的四种颜色摆出来，选之前就能看出差别
		var sw := UiKit.vbox(4)
		sw.custom_minimum_size = Vector2(30, 0)
		for key: String in ["court_color", "barrier_color", "ad_band_color", "apron_color"]:
			if not theme.has(key):
				continue
			var p := Panel.new()
			p.custom_minimum_size = Vector2(30, 22)
			var sb := StyleBoxFlat.new()
			sb.bg_color = theme[key]
			sb.set_corner_radius_all(4)
			p.add_theme_stylebox_override("panel", sb)
			sw.add_child(p)
		h.add_child(sw)

		var col := UiKit.vbox(6)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_row := UiKit.hbox(10)
		name_row.add_child(UiKit.label(str(a["name"]), 20, UiKit.TEXT))
		if using:
			name_row.add_child(UiKit.label("使用中", 14, UiKit.ACCENT_2))
		name_row.add_child(UiKit.spacer())
		col.add_child(name_row)
		col.add_child(UiKit.para(str(a["desc"]), 14, UiKit.TEXT_DIM, 460))
		h.add_child(col)

		var b: Button
		if using:
			b = UiKit.button("使用中", 16, Vector2(140, 48))
			b.disabled = true
		elif owned:
			b = UiKit.button_primary("使用", 16, UiKit.ACCENT_2, Vector2(140, 48))
			b.pressed.connect(func() -> void:
				Game.set_arena(aid)
				_open("shop")
			)
		elif Game.tickets_arena > 0 and price <= Game.ARENA_TICKET_MAX_PRICE:
			# 有券就优先用券 —— 券没有别的用途，攒着只会让玩家纠结
			b = UiKit.button_primary("用券兑换", 16, UiKit.ACCENT_2, Vector2(140, 48))
			b.pressed.connect(func() -> void:
				Game.use_arena_ticket(aid)
				_open("shop")
			)
		elif Game.can_afford(price):
			b = UiKit.button_primary("%d 金币" % price, 16, UiKit.GOLD, Vector2(140, 48))
			b.pressed.connect(func() -> void:
				Game.buy_arena(aid)
				_open("shop")
			)
		else:
			b = UiKit.button("%d 金币" % price, 16, Vector2(140, 48))
			b.disabled = true
			b.tooltip_text = "金币不足"
		h.add_child(b)
		v.add_child(row)
	return v


# ───────────── ⑧ 球拍工坊（经济二期）─────────────
## ★ 这是「让金币有地方花」的三个出口里最先做的那个，原因是**成本最低**：
##   paddle_rubber.gdshader 本来就按模型局部坐标分区上色，换色只改两个
##   uniform，不动贴图、不动模型。另外两个出口（场馆已扩到 10 个、三期做称号
##   和呐喊换肤）都要新建资产。
##
## ★ 面板的排版顺序是「先抽卡、后目录」——玩家进来第一眼该看到的是
##   「我攒的券能不能抽了」，而不是一屏买不起的东西。
const SKIN_SLOTS := [
	["rubber", "胶皮配色", "普通 70%　抽到重复返还 150"],
	["wood", "拍柄材质", "稀有 25%　抽到重复返还 400"],
	["epic", "特效拍面", "史诗 5%　抽到重复返还 1200"],
]

## 稀有度 → 显示色。让玩家在目录里一眼看出「哪个更难得」。
const RARITY_COLOR := {
	"common": UiKit.TEXT_DIM,
	"rare": UiKit.ACCENT_2,
	"epic": UiKit.GOLD,
}


func _panel_skins() -> Control:
	var v := UiKit.vbox(14)

	# ── 头部：金币 + 两种券 ──
	var head := UiKit.hbox(18)
	head.add_child(UiKit.label("金币 %d" % Game.coins, 18, UiKit.GOLD))
	head.add_child(UiKit.label("球拍券 %d" % Game.tickets_paddle, 17, UiKit.ACCENT))
	if Game.tickets_arena > 0:
		head.add_child(UiKit.label("场馆券 %d" % Game.tickets_arena, 17, UiKit.ACCENT_2))
	head.add_child(UiKit.spacer())
	head.add_child(UiKit.label("外观不影响任何数值", 14, UiKit.TEXT_MUTE))
	v.add_child(head)
	v.add_child(UiKit.hline())

	v.add_child(_skin_draw_block())
	v.add_child(UiKit.hline())

	for slot_row: Array in SKIN_SLOTS:
		var slot := str(slot_row[0])
		v.add_child(UiKit.label(str(slot_row[1]), 21, UiKit.TEXT))
		v.add_child(UiKit.label(str(slot_row[2]), 14, UiKit.TEXT_MUTE))
		for s: Dictionary in Game.PADDLE_SKINS:
			if str(s.get("slot", "")) != slot:
				continue
			v.add_child(_skin_row(s))
		v.add_child(UiKit.spacer(10))
	return v


## 抽卡区：进度条 + 按钮 + 上次结果。
## ★ 抽卡结果必须**留在面板上**而不是弹一下就消失 —— 玩家抽完要能对着
##   「新外观，已自动装备」这句话确认一遍，否则会怀疑是不是白扔了 7 张券。
func _skin_draw_block() -> Control:
	var outer := UiKit.vbox(12)

	var box := UiKit.row()
	var m := UiKit.margin(18, 16, 18, 16)
	box.add_child(m)
	var h := UiKit.hbox(18)
	m.add_child(h)

	var col := UiKit.vbox(6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var need := Game.DRAW_COST_PADDLE
	var have := Game.tickets_paddle
	col.add_child(UiKit.label("球拍券 %d / %d" % [have, need], 20, UiKit.TEXT))
	var pbar := UiKit.progress(float(have), float(need), 0.0,
		UiKit.GOLD if have >= need else UiKit.ACCENT)
	pbar.size_flags_horizontal = Control.SIZE_FILL
	pbar.custom_minimum_size = Vector2(0, 12)
	col.add_child(pbar)
	col.add_child(UiKit.para(
		"每日任务 3/3 给 1 张　·　每周任务全清给 1 张场馆券（在商店里兑）",
		14, UiKit.TEXT_DIM, 520))
	# ★ 保底要明说。玩家知道「最多 10 次必出」才敢一直攒券，
	#   不知道的话 5% 看起来就是「永远抽不到」。
	if Game.draw_pity > 0:
		col.add_child(UiKit.label(
			"已连续 %d 次未出史诗，再 %d 次必出" % [
				Game.draw_pity, Game.DRAW_PITY_EPIC - Game.draw_pity],
			14, UiKit.ACCENT))
	h.add_child(col)

	var b := UiKit.button_primary("抽一次", 20, UiKit.GOLD, Vector2(150, 62))
	b.disabled = have < need
	b.tooltip_text = "球拍券不足" if b.disabled else ""
	b.pressed.connect(func() -> void:
		var r: Dictionary = Game.draw_paddle_skin()
		if not r.is_empty():
			_last_draw = r
		_open("skins")
	)
	h.add_child(b)
	outer.add_child(box)

	if not _last_draw.is_empty():
		var d: Dictionary = _last_draw
		var wrap := UiKit.vbox(4)
		wrap.add_child(UiKit.label("抽到了　%s" % str(d["name"]), 18,
			RARITY_COLOR.get(str(d["rarity"]), UiKit.TEXT)))
		wrap.add_child(UiKit.label(
			("已有 → 返还 %d 金币" % int(d["coins"])) if bool(d["dup"])
			else "新外观，已自动装备",
			15, UiKit.GOLD if bool(d["dup"]) else UiKit.ACCENT_2))
		if bool(d["pity"]):
			wrap.add_child(UiKit.label("（保底触发）", 14, UiKit.ACCENT))
		var mm := UiKit.margin(18, 0, 18, 0)
		mm.add_child(wrap)
		outer.add_child(mm)
	return outer


## 目录里的一行。
func _skin_row(s: Dictionary) -> Control:
	var sid := str(s["id"])
	var owned := Game.has_skin(sid)
	var slot := str(s.get("slot", ""))
	# epic 装备时 rubber 槽的当前款其实被盖住了，但「装备状态」仍然成立
	var using := (slot == "rubber" and Game.skin_rubber == sid) \
		or (slot == "wood" and Game.skin_wood == sid) \
		or (slot == "epic" and Game.skin_epic == sid)
	var covered := slot == "rubber" and using and not Game.skin_epic.is_empty()

	var row := UiKit.row()
	var m := UiKit.margin(18, 14, 18, 14)
	row.add_child(m)
	var h := UiKit.hbox(18)
	m.add_child(h)

	# 色块预览：胶皮 / 木柄各一个方块，特效款再补一个流光色
	var sw := UiKit.vbox(4)
	sw.custom_minimum_size = Vector2(30, 0)
	for key: String in ["rubber", "wood", "glow"]:
		if not s.has(key):
			continue
		var p := Panel.new()
		p.custom_minimum_size = Vector2(30, 24)
		var sb := StyleBoxFlat.new()
		sb.bg_color = s[key]
		sb.set_corner_radius_all(4)
		p.add_theme_stylebox_override("panel", sb)
		sw.add_child(p)
	h.add_child(sw)

	var col := UiKit.vbox(5)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nr := UiKit.hbox(10)
	nr.add_child(UiKit.label(str(s["name"]), 19, UiKit.TEXT))
	nr.add_child(UiKit.label(_rarity_name(str(s.get("rarity", ""))), 13,
		RARITY_COLOR.get(str(s.get("rarity", "")), UiKit.TEXT_MUTE)))
	if using:
		var tl := "使用中" if not covered else "使用中（被特效覆盖）"
		nr.add_child(UiKit.label(tl, 14,
			UiKit.ACCENT_2 if not covered else UiKit.TEXT_MUTE))
	nr.add_child(UiKit.spacer())
	col.add_child(nr)
	col.add_child(UiKit.para(str(s["desc"]), 14, UiKit.TEXT_DIM, 460))
	h.add_child(col)

	var b: Button
	if using and slot != "epic":
		b = UiKit.button("使用中", 16, Vector2(132, 46))
		b.disabled = true
	elif using:
		# 特效拍面再点一次 = 摘掉
		b = UiKit.button_primary("卸下", 16, UiKit.TEXT_DIM, Vector2(132, 46))
		b.pressed.connect(func() -> void:
			Game.equip_skin(sid)
			_open("skins")
		)
	elif owned:
		b = UiKit.button_primary("装备", 16, UiKit.ACCENT_2, Vector2(132, 46))
		b.pressed.connect(func() -> void:
			Game.equip_skin(sid)
			_open("skins")
		)
	elif Game.can_afford(int(s["price"])):
		b = UiKit.button_primary("%d 金币" % int(s["price"]), 16, UiKit.GOLD,
			Vector2(132, 46))
		b.pressed.connect(func() -> void:
			Game.buy_skin(sid)
			_open("skins")
		)
	else:
		b = UiKit.button("%d 金币" % int(s["price"]), 16, Vector2(132, 46))
		b.disabled = true
		b.tooltip_text = "金币不足"
	h.add_child(b)
	return row


func _rarity_name(r: String) -> String:
	match r:
		"rare":
			return "稀有"
		"epic":
			return "史诗"
		_:
			return "普通"


# ───────────── ⑩ 个性化 · 称号 / 应援 / 呐喊（第三期）─────────────
func _panel_persona() -> Control:
	var v := UiKit.vbox(14)
	var head := UiKit.hbox(10)
	head.add_child(UiKit.label("金币 %d" % Game.coins, 18, UiKit.GOLD))
	head.add_child(UiKit.spacer())
	var tn := Game.title_name()
	head.add_child(UiKit.label(
		("当前称号　%s" % tn) if not tn.is_empty() else "还没挂称号",
		15, UiKit.GOLD if not tn.is_empty() else UiKit.TEXT_MUTE))
	v.add_child(head)
	v.add_child(UiKit.hline())

	# ── 称号 ──
	v.add_child(UiKit.label("称号", 22, UiKit.TEXT))
	v.add_child(UiKit.para(
		"达成条件自动解锁，点一下挂上、再点一下卸下。纯展示，不带任何数值加成。",
		14, UiKit.TEXT_DIM, 560))
	var owned := 0
	for t: Dictionary in Game.TITLES:
		var tid := str(t["id"])
		var got := Game.titles.has(tid)
		if got:
			owned += 1
		var row := UiKit.row()
		var m := UiKit.margin(16, 12, 16, 12)
		row.add_child(m)
		var h := UiKit.hbox(14)
		m.add_child(h)
		var col := UiKit.vbox(4)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(UiKit.label(str(t["name"]), 18,
			UiKit.TEXT if got else UiKit.TEXT_MUTE))
		col.add_child(UiKit.label(str(t["desc"]), 14, UiKit.TEXT_DIM))
		if not got:
			col.add_child(UiKit.label("进度 %d / %d"
				% [Game.title_progress(t), int(t["goal"])], 14, UiKit.ACCENT))
		h.add_child(col)
		var b: Button
		if not got:
			b = UiKit.button("未解锁", 15, Vector2(110, 42))
			b.disabled = true
		elif Game.title_current == tid:
			b = UiKit.button_primary("已挂上", 15, UiKit.ACCENT_2, Vector2(110, 42))
			b.pressed.connect(func() -> void:
				Game.title_equip(tid)
				_open("persona")
			)
		else:
			b = UiKit.button("挂上", 15, Vector2(110, 42))
			b.pressed.connect(func() -> void:
				Game.title_equip(tid)
				_open("persona")
			)
		h.add_child(b)
		v.add_child(row)
	v.add_child(UiKit.label("已解锁 %d / %d" % [owned, Game.TITLES.size()],
		15, UiKit.TEXT_MUTE))
	v.add_child(UiKit.hline())

	# ── 应援色 ──
	v.add_child(UiKit.label("应援色", 22, UiKit.TEXT))
	v.add_child(UiKit.para(
		"整片看台泛出的辉光色 —— 远看就是一片灯海。深色场馆里差别最明显。",
		14, UiKit.TEXT_DIM, 560))
	for s: Dictionary in Game.SUPPORT_COLORS:
		var sid := str(s["id"])
		# ★ lambda 先存成变量再传：写在多行调用的最后一个实参位置时，
		#   GDScript 的缩进解析会把收尾的 `))` 当成 lambda 体的一部分
		#   （报 "Unindent doesn't match the previous indentation level"）。
		var scb := func() -> void:
			if Game.supports.has(sid):
				Game.support_equip(sid)
			else:
				Game.support_buy(sid)
			_open("persona")
		v.add_child(_persona_row(str(s["name"]), str(s["desc"]), int(s["price"]),
			Game.supports.has(sid), Game.support_current == sid,
			s["color"] as Color, scb))
	v.add_child(UiKit.hline())

	# ── 呐喊 ──
	v.add_child(UiKit.label("得分呐喊", 22, UiKit.TEXT))
	v.add_child(UiKit.para(
		"得分和连拍里程碑时放的那声欢呼。同一份录音变调，不改内容。",
		14, UiKit.TEXT_DIM, 560))
	for c: Dictionary in Game.CHEER_SKINS:
		var cid := str(c["id"])
		var pitch := float(c["pitch"])
		var note := "原声" if absf(pitch - 1.0) < 0.01 else "音调 ×%.2f" % pitch
		var ccb := func() -> void:
			if Game.cheers.has(cid):
				Game.cheer_equip(cid)
			else:
				Game.cheer_buy(cid)
			_open("persona")
		v.add_child(_persona_row(str(c["name"]),
			"%s　%s" % [str(c["desc"]), note], int(c["price"]),
			Game.cheers.has(cid), Game.cheer_current == cid,
			Color(0.0, 0.0, 0.0, 0.0), ccb))
	return v


## 个性化面板的一行：名字 / 说明 / 右侧价格或状态按钮。
## ★ swatch 用 alpha = 0 表示「不画色块」—— Color 不能传 null，
##   硬传 null 会让整个面板在打开那一刻报错。
func _persona_row(nm: String, desc: String, price: int,
		owned: bool, equipped: bool, swatch: Color, cb: Callable) -> Control:
	var row := UiKit.row()
	var m := UiKit.margin(16, 12, 16, 12)
	row.add_child(m)
	var h := UiKit.hbox(14)
	m.add_child(h)
	if swatch.a > 0.01:
		var sw := ColorRect.new()
		sw.color = swatch
		sw.custom_minimum_size = Vector2(26, 26)
		h.add_child(sw)
	var col := UiKit.vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(UiKit.label(nm, 18, UiKit.TEXT if owned else UiKit.TEXT_MUTE))
	col.add_child(UiKit.label(desc, 14, UiKit.TEXT_DIM))
	h.add_child(col)
	var b: Button
	if equipped:
		b = UiKit.button_primary("使用中", 15, UiKit.ACCENT_2, Vector2(120, 42))
	elif owned:
		b = UiKit.button("换上", 15, Vector2(120, 42))
	elif Game.can_afford(price):
		b = UiKit.button_primary("%d 金币" % price, 15, UiKit.GOLD, Vector2(120, 42))
	else:
		b = UiKit.button("%d 金币" % price, 15, Vector2(120, 42))
		b.disabled = true
	if not equipped and (owned or Game.can_afford(price)):
		b.pressed.connect(cb)
	h.add_child(b)
	return row


# ───────────── ⑨ 联赛 · 比赛模式 ─────────────
## 32 人赛事：8 个小组（4 人单循环，前 2 出线）→ 16 强 → 8 强 → 4 强 → 决赛，
## 每场 5 局 3 胜。赛程推进全在 tournament.gd（纯数据），这里只负责画。
##
## 为什么分三个页签而不是一长条：
##   一屏塞不下「32 人名次表 + 48 场小组赛 + 淘汰赛签表 + 战报」，
##   而玩家每次打开只想知道三件事之一 —— 接下来打谁、我排第几、我打了什么。
##   分页比让人滚 200 行好用。

const TOUR_TABS := [["sched", "赛程"], ["rank", "排名"], ["data", "数据"]]


func _panel_tournament() -> Control:
	var v := UiKit.vbox(14)
	var t: Dictionary = Game.tournament
	var done := (not t.is_empty()) and str(t.get("stage", "")) == "done"

	# ── 状态条：当前处境 + 三个动作 ──
	var head := UiKit.hbox(16)
	var st_col := UiKit.vbox(5)
	st_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if t.is_empty():
		st_col.add_child(UiKit.label("尚未报名", 23, UiKit.TEXT))
		st_col.add_child(UiKit.label(
			"32 名选手 · 8 个小组单循环取前 2 · 16 强起单败 · 每场 5 局 3 胜",
			15, UiKit.TEXT_DIM))
	elif done:
		var pl := int(t.get("place", 0))
		st_col.add_child(UiKit.label("本届已结束　你排第 %d 名（%s）"
			% [pl, Tournament.prize_label(pl)], 23, UiKit.GOLD))
		st_col.add_child(UiKit.label("名次奖励 %d 金币已到账，战绩与最好名次也记下了"
			% Tournament.prize_for_place(pl), 15, UiKit.TEXT_DIM))
	else:
		var stg := str(t.get("stage", "group"))
		var extra := ""
		if stg == "group":
			extra = "　第 %d / 3 轮" % (int(t.get("group_round", 0)) + 1)
		st_col.add_child(UiKit.label("进行中　%s%s"
			% [Tournament.stage_name(stg), extra], 23, UiKit.ACCENT_2))
		var nm := Game.tournament_next_match()
		if not nm.is_empty():
			var pid := Tournament.player_id(t)
			var opp := int(nm["b"]) if int(nm["a"]) == pid else int(nm["a"])
			st_col.add_child(UiKit.label("下一个对手　%s（评分 %d）　5 局 3 胜"
				% [Tournament.name_of(t, opp), int(Tournament.rating_of(t, opp))],
				15, UiKit.TEXT_DIM))
	head.add_child(st_col)

	var acts := UiKit.vbox(8)
	if t.is_empty():
		var b0 := UiKit.button_primary("报名参赛", 18, UiKit.ACCENT, Vector2(190, 50))
		b0.pressed.connect(func() -> void:
			Game.new_tournament()
			_open("tournament")
		)
		acts.add_child(b0)
	elif done:
		var b1 := UiKit.button_primary("再打一届", 18, UiKit.GOLD, Vector2(190, 50))
		b1.pressed.connect(func() -> void:
			Game.new_tournament()
			_open("tournament")
		)
		acts.add_child(b1)
	else:
		# ★ 措辞改成「开始本场」：玩家点联赛按钮进来是为了**选这一场**，
		#   「继续参赛」读起来像「恢复一届赛事」，容易以为点了只是回到赛事视图。
		var b2 := UiKit.button_primary("开始本场", 18, UiKit.ACCENT, Vector2(190, 50))
		b2.pressed.connect(func() -> void:
			# 从联赛进场必须摘掉排位旗标，否则这一场会被排位劫走
			#（ranked 在 apply_preferences 里压过赛事判定）。
			Game.ranked = false
			# ★ 双打同理：优先级比赛事更高，不清的话「开始本场」打的是双打。
			Game.doubles = false
			Game.partner_ai = false
			# ★★ 这里是**唯一**置位赛事进场意图的地方（对应 game_state.tour_entry）。
			#   原来这个意图是「档案里有赛事就推断有」，跟从哪进来无关 ——
			#   于是「开始比赛」也被劫持成赛事场次、菜单难度作废。
			#   现在改成：只有在这里点了按钮，下一局才是赛事场次。
			Game.tour_entry = true
			Game.save_profile()
			get_tree().change_scene_to_file(GAME_SCENE)
		)
		acts.add_child(b2)
		# ★ 主动回答「为什么联赛面板里没有难度选」：这一场的难度跟着对手评分走，
		#   在面板上改它没有意义。写出来才不会让人以为功能漏了。
		#   （用户报「开始游戏那里选难度无用」时真正想问的其实是这个。）
		acts.add_child(UiKit.label("难度跟对手走", 13, UiKit.TEXT_MUTE))
	var b3 := UiKit.button("放弃本届赛事", 15, Vector2(190, 38))
	b3.disabled = t.is_empty()
	b3.pressed.connect(func() -> void:
		Game.abandon_tournament()
		_open("tournament")
	)
	acts.add_child(b3)
	head.add_child(acts)
	v.add_child(head)
	v.add_child(UiKit.hline())

	# ── 页签 ──
	var tabs := UiKit.hbox(10)
	for spec: Array in TOUR_TABS:
		var key := str(spec[0])
		var tb: Button
		if _tour_tab == key:
			tb = UiKit.button_primary(str(spec[1]), 17, UiKit.ACCENT, Vector2(152, 44))
		else:
			tb = UiKit.button(str(spec[1]), 17, Vector2(152, 44))
		tb.pressed.connect(func() -> void:
			# 页签的选中态靠「整块面板重建」刷新；3 个页签，重建开销可忽略。
			_tour_tab = key
			_open("tournament")
		)
		tabs.add_child(tb)
	tabs.add_child(UiKit.spacer())
	v.add_child(tabs)

	var body := UiKit.vbox(12)
	v.add_child(body)
	if t.is_empty():
		body.add_child(UiKit.para("还没有赛程。点「报名参赛」抽签开赛 —— "
			+ "你（评分 1020）会作为第 12 号种子被塞进 32 人名单，蛇形分档保证 8 个小组实力均衡，"
			+ "不会出现「死亡之组」。\n\n"
			+ "小组赛每人打 3 场，按胜场数排前 2 名出线；进入 16 强后每轮都是单败淘汰，"
			+ "输一场就回家。每场比赛 5 局 3 胜，局内先到 11 分。\n\n"
			+ "名次奖励：冠军 2000 / 亚军 1200 / 四强 800 / 八强 500 / 十六强 300 / 小组赛 150 金币。",
			16, UiKit.TEXT_DIM, 850))
		return v
	match _tour_tab:
		"rank":
			_tour_fill_rank(body, t)
		"data":
			_tour_fill_data(body, t)
		_:
			_tour_fill_sched(body, t)
	return v


## 赛程页：我的小组 + 我的比赛时间线 + 淘汰赛签表
func _tour_fill_sched(body: VBoxContainer, t: Dictionary) -> void:
	var pid := Tournament.player_id(t)

	# ★ 这里用 int(id) == pid 而不是 groups[g].has(pid)：
	#   Game._from_dict 已经把 id 规整成 int 了，但 has() 比较依赖 Variant 的
	#   类型哈希 —— 只要哪天有别的路径（存档槽 / 手改 json）漏过规整，
	#   has() 会**静默**返回 false，症状是「我的小组」整块不渲染、没有任何报错。
	#   数值比较不会。这种「错了还不吭声」的写法不值得省。
	var gid := -1
	for g in (t["groups"] as Array).size():
		for id in ((t["groups"] as Array)[g] as Array):
			if int(id) == pid:
				gid = g
				break
		if gid >= 0:
			break
	if gid >= 0:
		body.add_child(UiKit.label("我的小组　第 %d 组" % (gid + 1), 18, UiKit.TEXT))
		var tab := Tournament.group_table(t, gid)
		for i in tab.size():
			var r: Dictionary = tab[i]
			var id := int(r["id"])
			var me := id == pid
			body.add_child(_tour_row([
				["%d" % (i + 1), 34, UiKit.GOLD if me else UiKit.TEXT_MUTE],
				[Tournament.name_of(t, id), 0, UiKit.ACCENT_2 if me else UiKit.TEXT],
				["评分 %d" % int(Tournament.rating_of(t, id)), 0, UiKit.TEXT_MUTE],
				["%d 胜 %d 负" % [int(r["w"]), int(r["l"])], 0,
					UiKit.ACCENT_2 if int(r["w"]) > int(r["l"]) else UiKit.TEXT_DIM],
				["净胜 %+d" % int(r["diff"]), 0, UiKit.TEXT_MUTE],
			]))
		body.add_child(UiKit.label("小组前 2 名进入 16 强", 13, UiKit.TEXT_MUTE))

	body.add_child(UiKit.spacer(10))
	body.add_child(UiKit.label("我的比赛", 18, UiKit.TEXT))
	var mine := 0
	for m: Dictionary in t["matches"]:
		if int(m["a"]) != pid and int(m["b"]) != pid:
			continue
		mine += 1
		var a_is_me := int(m["a"]) == pid
		var opp := int(m["b"]) if a_is_me else int(m["a"])
		var my := int(m["sa"]) if a_is_me else int(m["sb"])
		var th := int(m["sb"]) if a_is_me else int(m["sa"])
		var stg := str(m["stage"])
		var tag := Tournament.stage_name(stg)
		if stg == "group":
			tag += " 第 %d 轮" % (int(m.get("round", 0)) + 1)
		var third := "待打"
		var third_col := UiKit.TEXT_MUTE
		if bool(m["done"]):
			third = "%d : %d　%s" % [my, th, "胜" if my > th else "负"]
			third_col = UiKit.ACCENT_2 if my > th else UiKit.ACCENT
		body.add_child(_tour_row([
			[tag, 150, UiKit.TEXT_DIM],
			[Tournament.name_of(t, opp), 0, UiKit.TEXT],
			["评分 %d" % int(Tournament.rating_of(t, opp)), 0, UiKit.TEXT_MUTE],
			[third, 150, third_col],
		]))
	if mine == 0:
		body.add_child(UiKit.label("还没有交手记录", 14, UiKit.TEXT_MUTE))

	var has_ko := false
	for m: Dictionary in t["matches"]:
		if str(m["stage"]) != "group":
			has_ko = true
			break
	if not has_ko:
		return
	body.add_child(UiKit.spacer(10))
	body.add_child(UiKit.label("淘汰赛签表", 18, UiKit.TEXT))
	for stg: String in ["r16", "qf", "sf", "f"]:
		var ms := Tournament.ko_round(t, stg)
		if ms.is_empty():
			continue
		body.add_child(UiKit.label(Tournament.stage_name(stg), 15, UiKit.TEXT_DIM))
		for m: Dictionary in ms:
			var a := int(m["a"])
			var b := int(m["b"])
			var res := "待打"
			var res_col := UiKit.TEXT_MUTE
			if bool(m["done"]):
				res = "%d : %d" % [int(m["sa"]), int(m["sb"])]
				res_col = UiKit.TEXT
				if a == pid:
					res += "　你" + ("胜" if int(m["sa"]) > int(m["sb"]) else "负")
				elif b == pid:
					res += "　你" + ("胜" if int(m["sb"]) > int(m["sa"]) else "负")
			body.add_child(_tour_row([
				[Tournament.name_of(t, a), 0, UiKit.ACCENT_2 if a == pid else UiKit.TEXT],
				["vs", 40, UiKit.TEXT_MUTE],
				[Tournament.name_of(t, b), 0, UiKit.ACCENT_2 if b == pid else UiKit.TEXT],
				[res, 170, res_col],
			]))


## 排名页：没打完给 8 个小组的即时榜；打完了给 1..32 的最终名次表
func _tour_fill_rank(body: VBoxContainer, t: Dictionary) -> void:
	var pid := Tournament.player_id(t)
	var rows := Tournament.standings(t)
	if rows.is_empty():
		body.add_child(UiKit.para("最终名次要等决赛打完才结算。"
			+ "下面是 8 个小组的即时排名 —— 每组前 2 名可以出线。", 15, UiKit.TEXT_DIM, 850))
		for g in (t["groups"] as Array).size():
			body.add_child(UiKit.spacer(8))
			body.add_child(UiKit.label("第 %d 组" % (g + 1), 16, UiKit.TEXT))
			var tab := Tournament.group_table(t, g)
			for i in tab.size():
				var r: Dictionary = tab[i]
				var id := int(r["id"])
				var me := id == pid
				body.add_child(_tour_row([
					["%d" % (i + 1), 34, UiKit.GOLD if me else UiKit.TEXT_MUTE],
					[Tournament.name_of(t, id), 0, UiKit.ACCENT_2 if me else UiKit.TEXT],
					["%d 胜 %d 负" % [int(r["w"]), int(r["l"])], 0, UiKit.TEXT_DIM],
					["出线" if i < 2 else "—", 90, UiKit.ACCENT_2 if i < 2 else UiKit.TEXT_MUTE],
				]))
		return

	body.add_child(UiKit.para("32 人名次已定：淘汰赛出局轮次定档，同档内按小组赛胜场排。"
		+ "奖励已发放。", 15, UiKit.TEXT_DIM, 850))
	body.add_child(UiKit.spacer(6))
	for r: Dictionary in rows:
		var id := int(r["id"])
		var me := id == pid
		var place := int(r["place"])
		var tone := UiKit.TEXT_MUTE
		if place == 1:
			tone = UiKit.GOLD
		elif place <= 4:
			tone = UiKit.ACCENT
		elif place <= 16:
			tone = UiKit.TEXT_DIM
		body.add_child(_tour_row([
			["%d" % place, 46, UiKit.GOLD if me else tone],
			[Tournament.name_of(t, id), 0, UiKit.ACCENT_2 if me else UiKit.TEXT],
			[Tournament.prize_label(place), 110, tone],
			["+%d 金币" % Tournament.prize_for_place(place) if me else "", 130, UiKit.GOLD],
		]))


## 数据页：累计战绩 + 本届战报
func _tour_fill_data(body: VBoxContainer, t: Dictionary) -> void:
	var s: Dictionary = Game.stats
	var grid := UiKit.hbox(26)
	grid.add_child(_tour_stat("参赛届数", "%d 届" % int(s["tournaments_played"])))
	grid.add_child(_tour_stat("冠军", "%d 次" % int(s["tournaments_won"])))
	var bp := int(s["best_place"])
	grid.add_child(_tour_stat("历史最好名次", ("第 %d 名" % bp) if bp > 0 else "—"))
	grid.add_child(_tour_stat("本届进度",
		Tournament.stage_name(str(t.get("stage", "group")))))
	body.add_child(grid)
	body.add_child(UiKit.hline())

	var cap := UiKit.hbox(10)
	cap.add_child(UiKit.label("本届战报", 18, UiKit.TEXT))
	cap.add_child(UiKit.spacer())
	cap.add_child(UiKit.label("从抽签开始，逐条记", 13, UiKit.TEXT_MUTE))
	body.add_child(cap)
	for i in (t["history"] as Array).size():
		var line := str((t["history"] as Array)[i])
		body.add_child(UiKit.label("%d.　%s" % [i + 1, line], 15, UiKit.TEXT_DIM))


## 一行「表格」：cols = [[文本, 固定宽(0 = 自适应), 颜色], ...]
## 固定宽的列会 clip_text —— 名字长短不一，不裁的话整行宽度会跳。
func _tour_row(cols: Array) -> Control:
	var row := UiKit.row()
	var m := UiKit.margin(14, 9, 14, 9)
	row.add_child(m)
	var h := UiKit.hbox(14)
	m.add_child(h)
	for i in cols.size():
		var c: Array = cols[i]
		var l := UiKit.label(str(c[0]), 16, c[2])
		var w := float(c[1])
		if w > 0.0:
			l.custom_minimum_size = Vector2(w, 0)
			l.clip_text = true
		else:
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if i == cols.size() - 1:
				l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(l)
	return row


func _tour_stat(name: String, value: String) -> Control:
	var v := UiKit.vbox(3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UiKit.label(name, 13, UiKit.TEXT_MUTE))
	v.add_child(UiKit.label(value, 20, UiKit.TEXT))
	return v
