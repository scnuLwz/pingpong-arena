extends Node3D
## 第一人称相机 / 视角控制器 (Godot 4.x, GDScript)
##
## 挂载位置：Player(CharacterBody3D) 下的 Head(Node3D) 节点
## 场景结构：
##   Player (CharacterBody3D)  <- 角色移动脚本
##   ├── CollisionShape3D
##   └── Head (Node3D)         <- 本脚本挂这里
##       └── Camera3D
##
## 说明：
## - 水平转头(yaw)作用在父节点 Player 上，保证角色朝向与视线一致
## - 垂直俯仰(pitch)只作用在本节点(Head)，避免身体倾斜
## - 不包含角色移动，只处理视角，可与任意移动脚本共存

@export_group("视角灵敏度")
## 鼠标灵敏度（弧度/像素），数值越大转得越快。
##
## ★ 实际生效值 = 本值 × Game.look_speed_mult()（设置面板的「球拍灵敏度」）。
##   基准值在 _ready 里抓一次存进 _base_mouse_sens，之后只改倍率，
##   所以反复改设置不会累积漂移。
@export var mouse_sensitivity: float = 0.0025
## 是否反转 Y 轴（true = 向上推鼠标视角向下）
@export var invert_y: bool = false

@export_group("俯仰限制")
## 初始俯仰角（度），负值 = 向下看。用于让开场就看到想看的东西（比如球台）
@export var initial_pitch_degrees: float = 0.0
## 向上看的角度上限（度）
@export var pitch_max: float = 89.0
## 向下看的角度下限（度）
@export var pitch_min: float = -89.0

@export_group("键盘转向")
## 用 ←/→ 左右转头的角速度（弧度/秒），0 = 关闭。
##
## 为什么需要一条不依赖鼠标的通道：转头原本只有鼠标，而且**必须先锁上指针**
## （见 _unhandled_input 里 `Input.mouse_mode == MOUSE_MODE_CAPTURED` 那个判断）。
## 浏览器里指针锁可能被直接拒绝 —— 被 iframe 包着、用户拒绝授权、无头/自动化
## 环境都会抛 WrongDocumentError，这时鼠标怎么推都转不了头，玩家只会以为游戏坏了。
## ←/→ 不受任何锁影响，是必须留的兜底。（真实浏览器里正常点击后锁是能成功的，
## 所以这条平时用不到，属于「坏了也能玩」的保险。）
##
## 只做左右、不做上下：↓ 已经被「切难度」占用了（project.godot 的 difficulty 动作
## 绑的就是 KEY_DOWN），再拿 ui_up/ui_down 做俯仰会和它同时触发。
## 俯仰继续只走鼠标 —— 看左右两侧的看台只需要左右转。
@export var key_turn_speed: float = 2.0

@export_group("平滑")
## 视角平滑速度，0 = 关闭平滑（直接跟手，推荐 FPS 用 0）
@export var smooth_speed: float = 0.0

@export_group("球台内俯角保护")
## 走进球台范围（人站到台面正上方）之后，**越贴近台面就越不许往下看** ——
## 用户要的「台内视角不能俯得太低，防止穿模」。
##
## ★ 为什么要做成**动态**的，而不是把 pitch_min 直接改小：
##   站在台边时头在台面上方 0.7~0.8 m，低头 89° 看下去只是正常俯视台面，
##   拦掉它纯属添堵；真正会穿模的是**蹲下**的时候 —— 头降到台面上方
##   0.2 m 上下，再低头镜头就往台面 / 球 / 自己的拍子上怼进去了。
##   所以限制必须跟着「头离台面多高」走。固定值要么平时太紧、要么蹲下拦不住。
@export var table_pitch_guard: bool = true
## 台面顶面高度（m）。要和 pingpong_ball.table_height 对得上
## （跨脚本硬约定，改那边的话这里要一起改）。
@export var table_top_y: float = 0.76
## 球台半长 / 半宽（m），用来判断「人在不在台面正上方」。
## 同样要和 pingpong_ball.table_half_length / table_half_width 对齐。
@export var table_half_length: float = 1.37
@export var table_half_width: float = 0.7625
## 判定范围外扩（m）：站在台边外一点点也算「台内」，提前收窄，不至于
## 一跨过台边俯角突然被砍一刀。
@export var table_guard_pad: float = 0.35
## 头离台面高于这个高度就不干预（m）。站立时 h≈0.74 > 0.62 → 完全不限；
## 蹲下 h≈0.19 → 生效。
@export var table_guard_band: float = 0.62
## 允许镜头贴到离台面多近（m）——限制的「安全距离」。
## 高度 h 时俯角下限 = -acos(margin / h)：h 越小，能低头的角度越小。
@export var table_guard_margin: float = 0.34

@export_group("头部晃动")
## 是否启用移动时的头部晃动
@export var enable_head_bob: bool = false
## 晃动幅度
@export var bob_amount: float = 0.06
## 晃动频率
@export var bob_frequency: float = 12.0
## 停止移动后回正的平滑速度
@export var bob_return_speed: float = 8.0

@export_group("FOV 效果")
## 冲刺时是否扩大视野
@export var enable_fov_kick: bool = false
## 基础 FOV
@export var base_fov: float = 75.0
## 冲刺额外增加的 FOV
@export var sprint_fov_bonus: float = 10.0
## FOV 过渡速度
@export var fov_lerp_speed: float = 8.0

@export_group("鼠标锁定")
## 启动时是否锁定鼠标。调试期间可设为 false，避免启动即抢鼠标。
@export var capture_on_start: bool = true
## 窗口失去焦点时自动释放鼠标（强烈建议开启，避免切出后鼠标仍被锁）
@export var release_on_focus_loss: bool = true
## 重新聚焦窗口时自动恢复锁定
@export var recapture_on_focus: bool = true
## Esc 是否只切换鼠标锁定（旧行为）。
##
## 现在默认 false：Esc 交给 pingpong_game.gd 的暂停菜单 —— 按一下就暂停并
## 放出鼠标，再按一下继续并锁回去。两处都抢这个键会出现「暂停开着、
## 鼠标却被重新锁住」的怪状态。
@export var escape_toggles_capture: bool = false

var _pitch: float = 0.0          # 当前俯仰角（弧度）
var _target_pitch: float = 0.0   # 平滑目标
var _target_yaw: float = 0.0
var _bob_time: float = 0.0
var _bob_offset: float = 0.0
var _head_rest_pos: Vector3      # 头部初始位置，用作晃动基准
var _user_released: bool = false # 用户主动按 Esc 释放（此时不自动恢复）
## 灵敏度基准（场景里配的原始值）。设置面板给的是**倍率**，
## 两者相乘才是实际生效值 —— 见 _apply_look_speed()。
var _base_mouse_sens: float = 0.0025
var _base_key_turn: float = 2.0

## UI 模式：暂停面板 / 一局结算面板打开时由游戏逻辑置 true。
##
## 这期间必须让玩家用鼠标点按钮，所以：
##   1) 进入 UI 模式立刻放出鼠标；
##   2) capture_mouse() 一律被拒绝，窗口重新聚焦、点画面补捕获都不会把
##      光标再抢走 —— 否则就是「面板看得见、按钮全点不动」，玩家只能强退。
var ui_mode: bool = false

@onready var _camera: Camera3D = $Camera3D
@onready var _player: Node3D = get_parent()


func _ready() -> void:
	_head_rest_pos = position
	_target_yaw = _player.rotation.y
	# 初始俯仰角：让开场视角对准该看的地方（乒乓球场景设了 -21.3° 看球台）
	_pitch = deg_to_rad(initial_pitch_degrees)
	_target_pitch = _pitch
	rotation.x = _pitch
	# 保留场景里相机初始的 FOV 作为基准
	if _camera:
		base_fov = _camera.fov
		_camera.top_level = false

	# ★ 灵敏度：抓住场景里配的原始值当基准，再乘上设置面板里的倍率。
	#   顺序很关键 —— 必须在任何外部改 mouse_sensitivity 之前抓基准，
	#   否则「基准」会变成已经被缩放过一次的值，改两下就飘走了。
	_base_mouse_sens = mouse_sensitivity
	_base_key_turn = key_turn_speed
	_apply_look_speed()
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_signal("settings_changed"):
		g.connect("settings_changed", _on_settings_changed)

	# 仅在允许且窗口已聚焦时才锁定鼠标，避免启动瞬间抢走鼠标。
	# Web 平台例外：浏览器要求用户手势才能申请指针锁定，启动时请求必然被拒，
	# 只会在控制台留下一条未捕获的 Promise 异常。网页版让玩家点一下画面再锁定。
	if capture_on_start and not OS.has_feature("web") and get_window().has_focus():
		capture_mouse()

	# 监听窗口焦点变化，失焦自动释放
	if release_on_focus_loss:
		get_window().focus_exited.connect(_on_window_focus_exited)
	if recapture_on_focus:
		get_window().focus_entered.connect(_on_window_focus_entered)


## 把设置面板的灵敏度倍率乘回基准值上。
##
## ★ 一定从 _base_* 重新算，不要在现值上再乘 —— 那样每次拖滑杆都会
##   在已缩放的值上再缩一次，拖两下滑杆就飞了。
## 无头 / 独立测试环境里没有 Game 单例，退化成 ×1.0（用场景原值）。
func _apply_look_speed() -> void:
	var mult := 1.0
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_method("look_speed_mult"):
		mult = float(g.call("look_speed_mult"))
	mouse_sensitivity = _base_mouse_sens * mult
	key_turn_speed = _base_key_turn * mult


func _on_settings_changed() -> void:
	_apply_look_speed()


## 锁定鼠标到窗口（对外公开，便于外部调用）
##
## UI 模式下直接拒绝（见 ui_mode 的说明）—— 这是唯一的锁定入口，
## 守在这里，任何调用方都抢不走面板上的光标。
func capture_mouse() -> void:
	if ui_mode:
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_user_released = false


## 释放鼠标（对外公开）
func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_user_released = true


## 进出 UI 模式（对外公开）。进入时顺手把鼠标放出来；
## 退出时不自动锁回去 —— 由调用方决定什么时候恢复第一人称操作。
func set_ui_mode(on: bool) -> void:
	ui_mode = on
	if on:
		release_mouse()


func _on_window_focus_exited() -> void:
	# 切到别的窗口时自动释放，避免鼠标被困在游戏里
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_window_focus_entered() -> void:
	# 回到游戏窗口时恢复锁定，但用户主动按 Esc 释放过就不恢复
	if capture_on_start and not _user_released:
		capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	# Esc 切换鼠标锁定 —— 只在没接暂停菜单时才这么做（见 escape_toggles_capture）
	if escape_toggles_capture and event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			release_mouse()
		else:
			capture_mouse()
		return

	# 浏览器/Web 平台要求「用户手势」内才能申请指针锁定（pointer lock），
	# 启动时直接 CAPTURED 会被静默拒绝。这里补一条：点一下画面就重新捕获。
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if not ui_mode and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
					and not _user_released:
				capture_mouse()

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		# 水平转头 -> 作用在 Player 上
		_target_yaw -= motion.relative.x * mouse_sensitivity
		_player.rotation.y = _target_yaw
		# 垂直俯仰 -> 作用在 Head 上
		var y_dir := 1.0 if invert_y else -1.0
		_target_pitch += motion.relative.y * mouse_sensitivity * y_dir
		_target_pitch = clampf(
			_target_pitch,
			deg_to_rad(_pitch_floor_deg()),
			deg_to_rad(pitch_max)
		)


func _process(delta: float) -> void:
	_update_key_look(delta)
	_update_look(delta)
	_update_head_bob(delta)
	_update_fov(delta)


## ←/→ 左右转头（key_turn_speed = 0 或 UI 模式下关闭）。
## 方向与鼠标一致：→ = 往右转，所以两套输入可以混着用。
func _update_key_look(delta: float) -> void:
	if key_turn_speed <= 0.0 or ui_mode:
		return
	var lr := Input.get_axis("ui_left", "ui_right")
	if not is_zero_approx(lr):
		_target_yaw -= lr * key_turn_speed * delta
		_player.rotation.y = _target_yaw


## 当前允许的最低俯角（度，负值）。
##
## 返回一个「向下看的角度下限」：不在台面正上方、或者头还够高 → 就是
## 场景里配的 pitch_min（不做任何额外限制）；在台面正上方且头压得低 →
## 按「离台面多高」算出一个更平的下限（见 table_guard_margin 的说明）。
##
## 几何：镜头在台面上方 h 处、向下俯 θ，视轴线到台面的垂直距离是 h·cos(θ)。
## 要求它 ≥ margin，得到 θ ≤ acos(margin / h)。
## h 越小时 margin/h 越大、θ 上限越小 —— 这就是「越贴近台面越不能低头」。
func _pitch_floor_deg() -> float:
	if not table_pitch_guard:
		return pitch_min
	var hp := global_position
	if _camera != null:
		hp.y = _camera.global_position.y
	var h := hp.y - table_top_y
	if h > table_guard_band:
		return pitch_min                    # 够高：正常俯视，不干预
	if absf(hp.x) > table_half_width + table_guard_pad:
		return pitch_min
	if absf(hp.z) > table_half_length + table_guard_pad:
		return pitch_min
	if h <= 0.02:
		return 0.0                          # 已经贴住台面：只能平视以上
	# margin 不能超过 h，否则 acos 无解 —— 贴得极近时按 0.92h 收，仍有约 23° 余量
	var margin := minf(table_guard_margin, maxf(h * 0.92, 0.02))
	var deg := rad_to_deg(acos(clampf(margin / h, 0.0, 1.0)))
	return maxf(pitch_min, -deg)


## 平滑俯仰（smooth_speed 为 0 时直接跟手）
##
## ★ 每帧都要重夹一次：限制会**自己变化**（蹲下 / 走进球台范围都会让它收窄），
##   只在鼠标事件里夹的话，玩家不推鼠标就永远卡在旧的、已经越界的角度上。
func _update_look(delta: float) -> void:
	var lo := deg_to_rad(_pitch_floor_deg())
	var hi := deg_to_rad(pitch_max)
	_target_pitch = clampf(_target_pitch, lo, hi)
	if smooth_speed > 0.0:
		_pitch = lerpf(_pitch, _target_pitch, smooth_speed * delta)
	else:
		_pitch = _target_pitch
	_pitch = clampf(_pitch, lo, hi)
	rotation.x = _pitch


## 头部晃动：按角色水平移动速度驱动
func _update_head_bob(delta: float) -> void:
	if not enable_head_bob:
		return

	var speed := 0.0
	# 兼容 CharacterBody3D：读取其水平速度
	if _player is CharacterBody3D:
		var v: Vector3 = (_player as CharacterBody3D).velocity
		speed = Vector2(v.x, v.z).length()

	var target_offset := 0.0
	if speed > 0.1:
		_bob_time += delta * bob_frequency * clampf(speed / 5.0, 0.5, 1.5)
		target_offset = sin(_bob_time) * bob_amount
	else:
		# 停止移动时平滑回正
		_bob_time = 0.0

	_bob_offset = lerpf(_bob_offset, target_offset, bob_return_speed * delta)
	position.y = _head_rest_pos.y + _bob_offset


## 冲刺时扩大 FOV
func _update_fov(delta: float) -> void:
	if not enable_fov_kick or _camera == null:
		return

	var sprinting := false
	if _player is CharacterBody3D:
		var v: Vector3 = (_player as CharacterBody3D).velocity
		sprinting = Vector2(v.x, v.z).length() > 6.0

	var target := base_fov + (sprint_fov_bonus if sprinting else 0.0)
	_camera.fov = lerpf(_camera.fov, target, fov_lerp_speed * delta)
