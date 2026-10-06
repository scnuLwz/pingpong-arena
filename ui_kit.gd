class_name UiKit
extends RefCounted
## 主菜单 / 各个面板共用的一套控件工厂与配色。
##
## 全部是 static，直接 `UiKit.button("开始")` 这样调，不需要实例化。
##
## 为什么不用 .tscn 手摆控件：
##   这个菜单里有 5 个面板、几十个按钮和滑杆，而且商店/任务列表的条目是
##   按数据（Game.ARENAS / Game.QUESTS）动态生成的 —— 手写 tscn 会变成
##   上千行、加一个场馆就要改十几处。代码生成可以和数据源保持同步。
##
## 字体：Godot 默认字体没有 CJK 字形，中文会变豆腐块 □。
##   project.godot 里挂了全局 theme/custom_font，但 HUD 那边验证过
##   「全局主题不总是生效」，所以这里再显式 override 一次，双保险。

const FONT: Font = preload("res://fonts/hud_cjk.otf")

# ───────────── 配色 ─────────────
const BG_DARK := Color(0.055, 0.062, 0.082)
const BG_PANEL := Color(0.098, 0.108, 0.140, 0.97)
const BG_ROW := Color(1, 1, 1, 0.045)
const BG_ROW_HOVER := Color(1, 1, 1, 0.09)
const ACCENT := Color(0.945, 0.380, 0.310)      # 乒乓红
const ACCENT_2 := Color(0.380, 0.760, 0.560)    # 通过/已拥有绿
const GOLD := Color(1.0, 0.820, 0.320)
const TEXT := Color(0.920, 0.935, 0.960)
const TEXT_DIM := Color(0.620, 0.660, 0.720)
const TEXT_MUTE := Color(0.430, 0.465, 0.525)
const LINE := Color(1, 1, 1, 0.12)


static func _flat(bg: Color, radius: int = 10,
		border: Color = Color(0, 0, 0, 0), bw: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(bw)
	return sb


# ───────────── 文本 ─────────────
static func label(text: String, size: int = 18, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 会自动换行的说明文字。宽度给死，Label 才会按宽度折行。
static func para(text: String, size: int = 15, color: Color = TEXT_DIM,
		width: float = 420.0) -> Label:
	var l := label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(width, 0.0)
	return l


# ───────────── 按钮 ─────────────
static func button(text: String, font_size: int = 19,
		min_size: Vector2 = Vector2(0, 46)) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", FONT)
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_color_override("font_disabled_color", TEXT_MUTE)
	b.custom_minimum_size = min_size
	b.add_theme_stylebox_override("normal", _flat(Color(1, 1, 1, 0.07), 9, LINE, 1))
	b.add_theme_stylebox_override("hover", _flat(Color(1, 1, 1, 0.14), 9, LINE, 1))
	b.add_theme_stylebox_override("pressed", _flat(Color(1, 1, 1, 0.20), 9))
	b.add_theme_stylebox_override("disabled", _flat(Color(1, 1, 1, 0.03), 9))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


## 主行动按钮（开始比赛、购买…）—— 用强调色，视觉上分主次
static func button_primary(text: String, font_size: int = 20,
		color: Color = ACCENT, min_size: Vector2 = Vector2(0, 52)) -> Button:
	var b := button(text, font_size, min_size)
	b.add_theme_color_override("font_color", Color(0.10, 0.08, 0.09))
	b.add_theme_color_override("font_hover_color", Color(0.06, 0.05, 0.06))
	b.add_theme_color_override("font_pressed_color", Color(0.06, 0.05, 0.06))
	b.add_theme_stylebox_override("normal", _flat(color, 9))
	b.add_theme_stylebox_override("hover", _flat(color.lightened(0.16), 9))
	b.add_theme_stylebox_override("pressed", _flat(color.darkened(0.16), 9))
	b.add_theme_stylebox_override("disabled", _flat(Color(1, 1, 1, 0.05), 9))
	return b


## 把一个**已经存在**的按钮改成 primary 外观。
## 与 `button_demote` 成对，供「选中项会随外部状态变化」的场景用
## （如难度微调滑杆拖动时更新五档按钮的高亮）。
static func button_promote(b: Button, color: Color = ACCENT) -> void:
	if b == null:
		return
	b.add_theme_color_override("font_color", Color(0.10, 0.08, 0.09))
	b.add_theme_color_override("font_hover_color", Color(0.06, 0.05, 0.06))
	b.add_theme_color_override("font_pressed_color", Color(0.06, 0.05, 0.06))
	b.add_theme_stylebox_override("normal", _flat(color, 9))
	b.add_theme_stylebox_override("hover", _flat(color.lightened(0.16), 9))
	b.add_theme_stylebox_override("pressed", _flat(color.darkened(0.16), 9))
	b.add_theme_stylebox_override("disabled", _flat(Color(1, 1, 1, 0.05), 9))


## 把按钮从 primary 样式**改回**普通样式。
##
## 为什么需要它（而不是让调用方自己remove_theme_stylebox_override）：
##   1. `remove_theme_stylebox_override` 会退回主题默认样式，视觉上不是
##      「普通按钮」而是「没上过色的按钮」—— 两者的底色/描边都不一样，
##      挨在一起看就是「有一个按钮缺了层皮」。
##   2. 配色只有这一处知道（`_flat(..., LINE, 1)` 那组常量）。
##      在外面复刻一份，UiKit 改配色时这边会静默留在旧值上。
##   3. 只设`normal` 会出现半吊子高亮：底色变了、字体还是 primary 的深色。
##      必须四个状态一起设。
static func button_demote(b: Button) -> void:
	if b == null:
		return
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_color_override("font_disabled_color", TEXT_MUTE)
	b.add_theme_stylebox_override("normal", _flat(Color(1, 1, 1, 0.07), 9, LINE, 1))
	b.add_theme_stylebox_override("hover", _flat(Color(1, 1, 1, 0.14), 9, LINE, 1))
	b.add_theme_stylebox_override("pressed", _flat(Color(1, 1, 1, 0.11), 9, LINE, 1))
	b.add_theme_stylebox_override("disabled", _flat(Color(1, 1, 1, 0.04), 9, LINE, 1))


# ───────────── 容器 ─────────────
static func panel(min_size: Vector2 = Vector2.ZERO) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _flat(BG_PANEL, 16, Color(1, 1, 1, 0.16), 1))
	p.custom_minimum_size = min_size
	return p


static func vbox(sep: int = 10) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep: int = 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func margin(l: int = 24, t: int = 20, r: int = 24, b: int = 20) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	return m


## 占位控件。两个尺寸都不给（默认 0,0）时它会自动设成「可伸缩」，
## 于是 spacer() 就是 HBox/VBox 里的弹簧；给了尺寸就是一块固定留白。
static func spacer(h: float = 0.0, w: float = 0.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_zero_approx(h) and is_zero_approx(w):
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func hline() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(0, 1)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", _flat(LINE, 0))
	return p


## 给一行列表加「悬停高亮」——纯展示行不做交互，但鼠标划过要有反馈
static func row() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _flat(BG_ROW, 10)
	p.add_theme_stylebox_override("panel", sb)
	return p


# ───────────── 滑杆 ─────────────
static func slider(value: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.01
	s.value = value
	s.custom_minimum_size = Vector2(300, 28)
	s.add_theme_stylebox_override("slider", _flat(Color(1, 1, 1, 0.10), 5))
	s.add_theme_stylebox_override("grabber_area", _flat(ACCENT, 5))
	s.add_theme_stylebox_override("grabber_area_highlight", _flat(ACCENT.lightened(0.2), 5))
	return s


# ───────────── 进度条 ─────────────
static func progress(value: float, maximum: float, width: float = 220.0,
		fill: Color = ACCENT_2) -> ProgressBar:
	var p := ProgressBar.new()
	p.max_value = maxf(maximum, 0.001)
	p.value = clampf(value, 0.0, maximum)
	p.show_percentage = false
	p.custom_minimum_size = Vector2(width, 10)
	p.add_theme_stylebox_override("background", _flat(Color(1, 1, 1, 0.10), 5))
	p.add_theme_stylebox_override("fill", _flat(fill, 5))
	return p


# ───────────── 徽标 / 小圆点 ─────────────
## 金币条上的小圆点（「有奖励可领」提示）
static func dot(color: Color = GOLD, r: float = 5.0) -> Panel:
	var c := Panel.new()
	c.custom_minimum_size = Vector2(r * 2.0, r * 2.0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_theme_stylebox_override("panel", _flat(color, int(r)))
	return c


# ───────────── 音量控件组（主菜单和游戏内暂停面板共用）─────────────
## 返回一个 VBox：三行「标签 + 滑杆 + 百分比」，外加上播试听按钮。
## 直接读写 Game 单例，改一下就立刻落盘并作用到 AudioServer。
## rows: [总线名(小写), 显示名, 试听时是否走这条总线]
const VOLUME_ROWS := [
	["master", "主音量", ""],
	["sfx", "击球音效", "hit"],
	["ambience", "现场氛围", "crowd"],
]


static func volume_controls(compact: bool = false) -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8 if compact else 12)

	# 存下所有滑杆，好在「恢复默认」之后把位置同步回去。
	# 同步时必须用 set_value_no_signal()：普通赋值会再触发一次 value_changed，
	# 于是 set_volume → settings_changed → 刷新滑杆 → set_volume …… 无限循环。
	var sliders: Dictionary = {}
	var val_labels: Dictionary = {}

	for row: Array in VOLUME_ROWS:
		var bus_key: String = row[0]
		var h := hbox(14)
		var name_l := label(row[1], 15 if compact else 17)
		name_l.custom_minimum_size = Vector2(92 if compact else 110, 0)
		h.add_child(name_l)

		var s := slider(Game.get_volume(bus_key))
		s.custom_minimum_size = Vector2(0 if compact else 300, 28)
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(s)

		var v := label("%d%%" % int(round(Game.get_volume(bus_key) * 100.0)),
			14 if compact else 16, TEXT_DIM)
		v.custom_minimum_size = Vector2(58, 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(v)
		sliders[bus_key] = s
		val_labels[bus_key] = v

		s.value_changed.connect(func(x: float) -> void:
			Game.set_volume(bus_key, x)
			(val_labels[bus_key] as Label).text = "%d%%" % int(round(x * 100.0))
		)
		root.add_child(h)

	# 试听：用一条独立播放器走对应总线 —— 拖动滑杆后立刻能听出区别，
	# 不用先开一局。
	var test_row := hbox(10)
	var t := button("试听击球声", 15, Vector2(0, 36))
	t.pressed.connect(func() -> void: _preview("hit"))
	test_row.add_child(t)
	var t2 := button("试听现场氛围", 15, Vector2(0, 36))
	t2.pressed.connect(func() -> void: _preview("crowd"))
	# ★ 底噪现在有独立开关（Game.crowd_on，默认关）。关着的时候这个试听
	#   **必然没声音** —— 不提示的话玩家会以为按钮坏了，而它其实是对的。
	t2.tooltip_text = "" if Game.crowd_on \
		else "「背景人群声」当前是关的，先在下面把它打开再试听"
	test_row.add_child(t2)
	var rst := button("恢复默认", 15, Vector2(0, 36))
	rst.pressed.connect(func() -> void:
		Game.set_volume("master", 1.0)
		Game.set_volume("sfx", 1.0)
		Game.set_volume("ambience", 0.8)
	)
	test_row.add_child(rst)
	root.add_child(test_row)

	# 任何来源改了设置（恢复默认、读档…）都把滑杆位置同步过来
	var sync := func() -> void:
		for k: String in sliders.keys():
			var s := sliders[k] as HSlider
			var val := Game.get_volume(k)
			s.set_value_no_signal(val)
			(val_labels[k] as Label).text = "%d%%" % int(round(val * 100.0))
	Game.settings_changed.connect(sync)
	# 面板被销毁时断开，避免信号连到已释放的对象上
	root.tree_exiting.connect(func() -> void:
		if Game.settings_changed.is_connected(sync):
			Game.settings_changed.disconnect(sync)
	)
	return root


# ───────────── 球拍 / 视角灵敏度 ─────────────
## 用户要的「拍移动灵敏度下降，同时提供灵敏度设置」。
##
## 球拍是挂在相机下的子节点：鼠标一推，相机转、拍子跟着走。
## 所以这条滑杆就是**瞄准手感的总闸**（同时作用于鼠标转头和 ←/→ 转头），
## 主菜单的「声音设置」面板和游戏内暂停面板都接它。
##
## 显示的是「相对原设计手感的百分比」而不是滑杆位置：
## 存的是 0~1 的归一化值，映射成 ×0.20~×1.60 的倍率（见 Game.look_speed_mult），
## 直接显示滑杆的 25% 会让人以为「灵敏度只有四分之一」。
static func look_controls(compact: bool = false) -> Control:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8 if compact else 12)

	var h := hbox(14)
	var name_l := label("球拍灵敏度", 15 if compact else 17)
	name_l.custom_minimum_size = Vector2(92 if compact else 110, 0)
	h.add_child(name_l)

	var s := slider(Game.get_sens())
	s.custom_minimum_size = Vector2(0 if compact else 300, 28)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(s)

	var v := label("", 14 if compact else 16, TEXT_DIM)
	v.custom_minimum_size = Vector2(58, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	root.add_child(h)

	var row := hbox(10)
	var rst := button("灵敏度恢复默认", 15, Vector2(0, 36))
	rst.pressed.connect(func() -> void: Game.set_sens(Game.SENS_DEFAULT))
	row.add_child(rst)
	root.add_child(row)

	var note := para("", 14, TEXT_MUTE, 600)
	root.add_child(note)

	var refresh := func() -> void:
		var pct := int(round(Game.look_speed_mult() * 100.0))
		v.text = "%d%%" % pct
		note.text = "数值越小，推一下鼠标球拍走得越少、越好瞄准（越稳）。现在是原设计手感的 %d%%。" % pct
	refresh.call()

	# 拖动时立刻生效（Game.settings_changed → camera_controller 重新乘一次），
	# 不用等关面板。
	s.value_changed.connect(func(x: float) -> void:
		Game.set_sens(x)
	)

	# 别的入口改了灵敏度（恢复默认 / 读档）也把滑杆同步过来。
	# 必须用 set_value_no_signal()，否则会 set_sens → settings_changed
	# → 同步 → set_value → value_changed → set_sens …… 无限循环。
	var sync := func() -> void:
		s.set_value_no_signal(Game.get_sens())
		refresh.call()
	Game.settings_changed.connect(sync)
	root.tree_exiting.connect(func() -> void:
		if Game.settings_changed.is_connected(sync):
			Game.settings_changed.disconnect(sync)
	)
	return root


## 音量滑杆的试听音。用真正的游戏素材，试听才有意义 ——
## 见 pingpong_audio.gd 的 HIT_VARIANTS。
const PREVIEW_HIT := preload("res://audio/hit1.wav")
const PREVIEW_CROWD := preload("res://audio/crowd.wav")
## 试听呐喊 / 奶龙笑要和**游戏里真正放的那条**是同一份素材，
## 否则「试听觉得行、实战里不是这个声」。
const PREVIEW_CHEER := preload("res://audio/cheer1.wav")
const PREVIEW_CONCEDE := preload("res://audio/nailong_laugh.mp3")
static var _preview_player: AudioStreamPlayer = null


static func _preview(kind: String) -> void:
	if _preview_player == null or not is_instance_valid(_preview_player):
		_preview_player = AudioStreamPlayer.new()
		# 暂停面板里也要能试听：AudioStreamPlayer 在 PROCESS_MODE_PAUSABLE 下
		# 会收到 NOTIFICATION_PAUSED 并把自己静音，所以必须显式声明 ALWAYS。
		_preview_player.process_mode = Node.PROCESS_MODE_ALWAYS
		Engine.get_main_loop().root.add_child(_preview_player)
	_preview_player.stop()
	# ★ 呐喊 / 奶龙笑走的是**分项增益**（不是总线），试听必须把增益也叠上 ——
	#   否则玩家把音量拖到 20%、点了试听还是满音量，会以为滑杆坏了。
	var gain := 0.0
	match kind:
		"hit":
			_preview_player.stream = PREVIEW_HIT
			_preview_player.bus = "SFX"
		"crowd":
			_preview_player.stream = PREVIEW_CROWD
			_preview_player.bus = "Ambience"
			# ★ 底噪是**增益**（Game.crowd_on + settings.crowd），不走总线音量 ——
			#   不叠上的话玩家把滑杆拖到 20%、点试听仍是满音量，会以为滑杆坏了。
			gain = Game.sfx_gain_db("crowd")
		"cheer":
			_preview_player.stream = PREVIEW_CHEER
			_preview_player.bus = "SFX"
			gain = Game.sfx_gain_db("cheer")
		"concede":
			_preview_player.stream = PREVIEW_CONCEDE
			_preview_player.bus = "SFX"
			gain = Game.sfx_gain_db("concede")
		_:
			return
	# 关掉时增益是 -80，这里直接不放 —— 免得「点了没声音」被当成按钮坏了
	if gain <= -79.0:
		return
	_preview_player.volume_db = gain
	_preview_player.play()
