extends Node
## 乒乓球音效播放器 —— 击球反馈声 + 现场呐喊声
##
## 挂载位置：pingpong.tscn 的 Audio (Node)
##
## ★ 击球 / 台面弹跳：**2026-10-07 用户要求改回程序合成的版本**
##   （`audio/hit.wav` / `audio/bounce.wav`）。
##   2026-10-03 曾一度换成真实乒乓球录音（hit1~4 / bounce1~4，BigSoundBank CC0），
##   现按用户要求回退。那 8 个文件已从工程移除，但**仍在 git 历史里**——
##   想再换回去：`git checkout <那次提交> -- audio/`。
##   合成版瞬态更长（≈12.8 ms vs 真实录音 2.4 ms）、频谱重心更低
##   （3834 vs 3984 Hz），听感更「闷、钝」，就是 2026-10-02「击球音重做」定稿那版。
## 呐喊 / 欢呼是**真实观众录音**（audio/cheer1~2.wav）。
##
## ★ 得分与失分是**两种完全不同的声音**（2026-10-03 用户定）：
##     · 玩家得分 → `play_score_cheer()` → 真实观众**呐喊**（cheer1/cheer2 轮转）；
##     · 玩家失分 → `play_concede()`     → **奶龙大笑**（nailong_laugh.mp3）。
##   这条分工是用户指定的：「失分用奶龙笑，得分呐喊」。
##   于是奶龙不再是「呐喊的一种」，而是**挖苦音**——对面拿分时它笑你。
##
## ★ HIT / BOUNCE / HIT_SOFT / HIT_SPIN / NET / WHOOSH / CROWD 现在**全是程序合成**的
##   16-bit PCM WAV（22050 Hz）。
##
## ★★ HIT / BOUNCE 是怎么找回来的（值得记住）：这两个文件 2026-10-03 被真实录音
##   替换时，旧版被移到了 `%TEMP%/cs1_tools/attic_audio_synth/`，而那个目录
##   后来被清掉了 —— 回收站里也没有。**唯一**的存档是工作区根目录的
##   `sfx_preview.html`：当时为了让用户 A/B 试听，把「旧·合成」两条以 base64
##   内联进了那个单文件页面。
##   ★ 取回时的自证方式：同一页里的 4 条「新」素材解码后与工程内
##     hit1~4 / bounce1~4 **逐字节相同** → 证明解码链路无损，取回的「旧」也可信。
##
## ★ 推子按「合成素材」重新标定：合成版峰值 hit **-3.5** / bounce **-2.5** dBFS
##   （真实录音是 -2.0），所以 `hit_db` 回到 **-4.0**、`bounce_db` 回到 **-9.0**
##   —— 与 2026-10-03 换素材**之前**的标定一致。
## ★ HIT_SOFT / HIT_SPIN 峰值 -0.9 / -0.7 dBFS，配 hit_db±1.0 得 -6.4 / -4.2 dBFS。
##   换回合成版本后它们与 HIT 同属一个合成家族，音色梯度
##   （普通球干脆 / 搓球闷而长 / 拉球带摩擦）反而更连贯。
##
## 素材出处与生成参数见 audio/CREDITS.txt。
##
## 设计要点：
##   1. **播放器池**：击球/弹跳会在几十毫秒内连着触发好几次，
##      单个 AudioStreamPlayer 会被后一次 play() 掐断前一次，所以用池轮转。
##   2. **音高随机化**：每次 ±6% 的 pitch 抖动，连打十几拍也不会听出是同一段采样。
##   3. **呐喊是循环轨**：crowd.wav 做了首尾交叉淡化（loop 点跳变 = 0），
##      可以无缝一直放；浏览器有 autoplay 限制，所以由主控在
##      **第一次用户输入**时调 start_ambience() 启动，而不是 _ready 里硬启动。
##   4. **爆冲/暴拧**不是换个音效，而是在普通击球声上再叠一层低八度的闷响，
##      听起来才像「发力了」而不是「换了个球拍」。

## ★ 击球采样：改回合成版后只剩**一条**。
##   2026-10-02 那版原本有 3 条（hit.wav / hit2 / hit3），但只有 hit.wav 被
##   A/B 试听页留存下来，另两条随归档目录一起没了 —— 这里不重新合成、
##   不编造素材，就放这一条真取回来的。
##   ★ 会不会像复读机？不会明显：`play_hit()` 每次施加 ±6% 的 pitch 抖动
##     （`randf_range(0.94, 1.06)`），相邻两拍音高最多差 12%；对一段 60 ms 的
##     敲击声来说，这个幅度已经足够听不出重复。
const HIT_VARIANTS := [
	preload("res://audio/hit.wav"),
]
## 下旋/搓球：高频砍掉的闷「噗」，和上面那 4 个是两个音色，不是调个 pitch 凑的
const HIT_SOFT := preload("res://audio/hit_soft.wav")
## 上旋/拉球：多一层 4~9 kHz 的摩擦「沙」，听得出是在「蹭」球
const HIT_SPIN := preload("res://audio/hit_spin.wav")
## ★ 台面弹跳：同样只剩一条（理由见上）。
##   合成版的弹跳能量明显偏中低频（低/中/高 = 0.07 / 0.59 / 0.34，击球是
##   0.20 / 0.25 / 0.55），所以「球拍脆、台面闷」的对比仍然成立。
##   ★ `play_bounce()` 的 pitch 抖动比击球更大（`randf_range(0.92, 1.10)`，±9%），
##     重复感更不成问题。
const BOUNCE_VARIANTS := [
	preload("res://audio/bounce.wav"),
]
const NET := preload("res://audio/net.wav")
const WHOOSH := preload("res://audio/whoosh.wav")
const CROWD := preload("res://audio/crowd.wav")
## 奶龙大笑 —— ★ 现在它是**失分挖苦音**，不再是得分欢呼。
## 来源：从 https://talking-milk-dragon.app.workbuddy.host/ 的单文件里
## 抽出的内嵌 data:audio/mpeg（页面把全部资源 base64 内联，90.8 MB 单 HTML），
## 取出 48 KB 的 MP3 原样存进来，没有再编码。
const NAILONG_LAUGH := preload("res://audio/nailong_laugh.mp3")

## ★ 呐喊 / 欢呼的**变体池** —— 只用于「玩家得分」和「连拍里程碑」这些**好事**。
##
## ★ 2026-10-03 把奶龙从这个池子里摘了出去：用户要求「失分用奶龙笑，得分呐喊」，
##   两者语义必须互斥。奶龙留在池子里的话，涨分时可能听到「被嘲笑」的声音、
##   丢分时又可能听到欢呼 —— 玩家没法从声音判断刚才发生了什么。
##   现在池里只剩两条真实观众呐喊（原本就是池里最像「欢呼」的两条）。
##
## 为什么还是要池而不是一条：得分欢呼单局要响十几次，只放一条素材
## 第三次就听得出是复读。
##
## 素材实测（功率谱能量占比，用来确认它是人声而不是噪声）：
##   cheer1  0.3~1k 68.8% / 1~3k 24.6% / 重心 1310 Hz
##   cheer2  0.3~1k 36.0% / 1~3k 48.5% / 重心 1808 Hz
##   对照：旧的合成 crowd.wav 重心 3852 Hz、>6k 占 19.2% —— 那是噪声不是人声。
const CHEER_VARIANTS := [
	preload("res://audio/cheer1.wav"),
	preload("res://audio/cheer2.wav"),
]

@export_group("音量")
@export var master_db: float = 0.0
## 击球声比原来抬了 1 dB。原来 -5 配上 -16 的破风声，「啪」那一下容易被
## 挥拍的风声糊掉 —— 而击球反馈是这套音效里最要紧的一条：
## 玩家判断「我到底打没打到」几乎全靠它。
##
## ★ 2026-10-07 改回合成素材后**回退到 -4.0**：合成版峰值 -3.5 dBFS
##   （真实录音是 -2.0），那 -4.5 是为「更响的素材」补的 1.5 dB，
##   现在素材变回原来那条，推子也跟着变回去 —— 这正是 2026-10-03 之前的标定。
@export var hit_db: float = -4.0
## 同上：合成弹跳峰值 -2.5（真实录音 -2.0）→ 回到 -9.0。
## 于是「击球比弹跳高 5 dB」这个原有音量关系原样恢复。
@export var bounce_db: float = -9.0
@export var net_db: float = -8.0
## 破风声压到 -18，给击球声让路（它本来就是「没打到」的补偿音）
@export var whoosh_db: float = -18.0
@export var cheer_db: float = -4.0
## 失分挖苦音（奶龙大笑）的音量。比欢呼略高一点（-3.0 vs -4.0）——
## 它要在「刚丢一分、比分提示音也在响」的时候还能听清；
## 而且奶龙那条是 MP3、动态比观众录音窄，同响度下会显得偏轻。
@export var concede_db: float = -3.0
@export var crowd_db: float = -23.0

## ★ 玩家是否想听背景人群底噪。读 Game.crowd_on —— 拿不到单例时（探针里）
##   退回「开着」，免得测试环境里整段底噪静默消失。
func crowd_wanted() -> bool:
	if not enable_ambience:
		return false
	var g := get_node_or_null("/root/Game")
	if g == null:
		return true
	return bool(g.get("crowd_on"))


## 底噪当前的基准音量（不含 dip/swell 的临时偏移）。
## 分项增益在这里叠进去，所以拖「背景人群声」滑杆时循环音量立刻跟着变。
func _crowd_base_db() -> float:
	var g := _crowd_gain()
	return crowd_db + master_db + (0.0 if g <= -79.0 else g)

@export_group("功能")
@export var enable_sfx: bool = true
## ★ 「让玩家能自己开背景人群底噪」的**总闸**（默认 true = 允许）。
##   以前这里是 `false` 且不可改，于是设置面板的「现场氛围」滑杆和试听按钮
##   全是摆设：拖了没反应、点了没声音，但 UI 又不告诉你它坏了。
##   现在真正决定放不放的是 Game.crowd_on（分项开关，默认关），
##   这个导出只当「允许不允许存在底噪这条通道」的保险丝。
@export var enable_ambience: bool = true
## 背景噪音（现场人群底噪）默认关闭 —— 用户要求取消背景噪音，
## 只保留击球/弹跳/得分等明确的玩法反馈音。
## 两次击球音的最小间隔（秒），防止同一次挥拍联判两次出双响
@export var hit_cooldown: float = 0.045
## 两次「失分挖苦音」的最小间隔（秒）。见 play_concede()。
@export var concede_cooldown: float = 0.9

## 这两条子总线由 Game 单例（game_state.gd）在启动时建好，
## 设置面板的三个滑杆就是直接写它们的音量。
const BUS_SFX := "SFX"
const BUS_AMBIENCE := "Ambience"

var _pool: Array[AudioStreamPlayer] = []
var _pool_idx: int = 0
const POOL_SIZE := 6

var _crowd_player: AudioStreamPlayer
## 人群音量的当前补间。得分时会连着重设好几次，不 kill 掉旧的会互相打架
## （两个 tween 同时写 volume_db，表现是音量抖一下然后卡在中间值）。
var _crowd_tween: Tween = null
## 「音频已解锁」。浏览器在用户手势之前 AudioContext 是 suspended 状态，
## 这段期间 play() 不但没声音，还会每秒往控制台刷一条
## "The AudioContext was not allowed to start."，而且所有排队的音效会在
## 玩家第一次点击的瞬间一起爆出来。所以解锁之前一律不发声。
var _unlocked: bool = false
var _last_hit_time: float = -99.0
## 上一次播放失分挖苦音的时刻。point_pause(1.3 s) 比奶龙那段笑声(3.06 s) 短，
## 不节流的话连丢两分会把两段笑声叠在一起糊成一片。见 play_concede()。
var _last_concede_time: float = -99.0
var _time: float = 0.0
## 击球 / 弹跳 / 呐喊采样的轮转游标。见 _hit_take() / _bounce_take() / _cheer_take()。
var _hit_idx: int = 0
var _bounce_idx: int = 0
var _cheer_idx: int = 0


func _ready() -> void:
	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.name = "Sfx%d" % i
		p.bus = _bus(BUS_SFX)
		p.volume_db = master_db
		add_child(p)
		_pool.append(p)

	_crowd_player = AudioStreamPlayer.new()
	_crowd_player.name = "CrowdLoop"
	_crowd_player.bus = _bus(BUS_AMBIENCE)
	_crowd_player.volume_db = _crowd_base_db()
	_crowd_player.stream = _looped(CROWD)
	add_child(_crowd_player)

	# ★ start_ambience 里已经接了玩家开关（crowd_wanted），
	#   这里不再额外判 enable_ambience —— 那个条件在 crowd_wanted 里。
	start_ambience()

	# 设置面板改了「背景人群声」的开关 / 音量 → 立刻生效。
	# ★ 自己连自己的信号，而不是让 pingpong_game 记得来调 apply_settings()：
	#   谁拥有这个节点谁负责响应，调用方漏调一次就静默失效（连了信号就漏不掉）。
	# ★ 拖滑杆时 settings_changed 是连续发的，_sync_crowd 在「已经是目标状态」
	#   时不做任何事，所以不会每帧重启播放器。
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_signal("settings_changed"):
		if not g.is_connected("settings_changed", _on_settings_changed):
			g.connect("settings_changed", _on_settings_changed)


func _on_settings_changed() -> void:
	apply_settings()


## 总线不存在时退到 Master，不让整条音频链因为找不到名字就报错/静音。
## 正常流程里 Game 单例已经建好这两条总线，这里是兜底。
func _bus(want: String) -> String:
	return want if AudioServer.get_bus_index(want) >= 0 else "Master"


func _process(delta: float) -> void:
	_time += delta


## 把 WAV 设成前向循环。loop_end 必须显式给帧数：
## 给 0 的话循环区间长度为 0，会直接静音（踩过）。
func _looped(src: AudioStreamWAV) -> AudioStreamWAV:
	var s: AudioStreamWAV = src.duplicate()
	var bytes_per_frame := 2 * (2 if s.stereo else 1)   # FORMAT_16_BITS
	var frames := int(s.data.size() / bytes_per_frame)
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = maxi(frames, 1)
	return s


# ───────────── 播放器池 ─────────────
func _take() -> AudioStreamPlayer:
	var p := _pool[_pool_idx]
	_pool_idx = (_pool_idx + 1) % _pool.size()
	return p


func _play(stream: AudioStream, db: float, pitch: float = 1.0,
		max_len: float = 0.0) -> AudioStreamPlayer:
	if not _unlocked:
		return null
	var p := _take()
	p.stream = stream
	p.volume_db = db + master_db
	p.pitch_scale = pitch
	p.max_polyphony = 1
	p.play()
	if max_len > 0.0:
		pass
	return p


## 轮转取一套击球采样。**用轮转而不是随机**：一板来回里击球音连着响，
## 随机会出现「连着两次同一段」（4 选 1 时有 25% 概率），轮转保证不重复。
func _hit_take() -> AudioStream:
	var s: AudioStream = HIT_VARIANTS[_hit_idx]
	_hit_idx = (_hit_idx + 1) % HIT_VARIANTS.size()
	return s


## 同上，台面弹跳的 4 个变体。
func _bounce_take() -> AudioStream:
	var s: AudioStream = BOUNCE_VARIANTS[_bounce_idx]
	_bounce_idx = (_bounce_idx + 1) % BOUNCE_VARIANTS.size()
	return s


## 同上，呐喊的 2 个变体。
## ★ 这里轮转比随机更重要：2 选 1 随机会有一半概率连着两次同一条，
##   而得分欢呼是「隔一会儿响一次」，重复出现最容易被耳朵记住。
func _cheer_take() -> AudioStream:
	var s: AudioStream = CHEER_VARIANTS[_cheer_idx]
	_cheer_idx = (_cheer_idx + 1) % CHEER_VARIANTS.size()
	return s


## ★ 第三期：呐喊换肤。返回 [音频, 音调倍数]。
## 皮肤里存的是「源文件 + pitch_scale」—— 压到 0.78 是满场观众的闷响，
## 抬到 1.24 是短促的起哄，不必为每种音色再录一条素材。
## autoload 不在（探针场景）或皮肤查不到时退回轮转池，行为和以前完全一致。
func _cheer_skin() -> Array:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return [_cheer_take(), 1.0]
	var c: Dictionary = g.call("cheer_skin")
	if c.is_empty():
		return [_cheer_take(), 1.0]
	var s: AudioStream = CHEER_VARIANTS[0]
	if str(c.get("src", "")) == "cheer2":
		s = CHEER_VARIANTS[1]
	return [s, float(c.get("pitch", 1.0))]


# ───────────── 对外接口 ─────────────

## 击球反馈声。
## kind: 0 = 普通推挡 / 1 = 正手爆冲 / 2 = 反手暴拧 /
##       3 = 上旋拉（Z+左键）/ 4 = 下旋搓（C+左键）
## strength: 0~1 击球时机质量，越准越响越脆
func play_hit(strength: float = 1.0, kind: int = 0) -> void:
	if not enable_sfx:
		return
	if _time - _last_hit_time < hit_cooldown:
		return
	_last_hit_time = _time

	var s := clampf(strength, 0.0, 1.0)
	var jitter := randf_range(0.94, 1.06)

	if kind == 0:
		_play(_hit_take(), lerpf(hit_db - 5.0, hit_db, s), 1.0 * jitter)
		return
	if kind == 4:
		# 下旋搓球：换个音色（闷、短、没有那一层脆响），音量也压一点
		_play(HIT_SOFT, lerpf(hit_db - 6.0, hit_db - 1.0, s), 1.02 * jitter)
		return
	if kind == 3:
		# 上旋拉球：摩擦音 + 一层很轻的低八度，做出「吃住球再甩出去」的感觉
		_play(HIT_SPIN, lerpf(hit_db - 4.0, hit_db + 1.0, s), 0.96 * jitter)
		var ps := _take()
		ps.stream = _hit_take()
		ps.volume_db = lerpf(hit_db - 11.0, hit_db - 7.0, s) + master_db
		ps.pitch_scale = 0.62 * jitter
		ps.play()
		return

	# 爆冲（正手）/ 暴拧（反手）：主体更低沉、更响，再叠一层低频「闷响」当发力感
	# 两层取**同一段**采样，不然叠出来的音色会互相打架（主体和低八度是两段录音的话，
	# 听起来像两个人各打了一下）。
	var base_pitch := 0.84 if kind == 1 else 0.90
	var v := _hit_take()
	_play(v, lerpf(hit_db - 1.5, hit_db + 4.0, s), base_pitch * jitter)
	var p2 := _take()
	p2.stream = v
	p2.volume_db = lerpf(hit_db - 8.0, hit_db - 3.0, s) + master_db
	p2.pitch_scale = base_pitch * 0.52 * jitter
	p2.play()


## 对手击球（发球 / 回球）。
##
## 为什么单独一个函数而不是复用 play_hit：
##   1. **音高不同**。压到 0.80~0.88 倍，听感上比玩家自己的击球「低一档」，
##      闭着眼也能分辨这一下是谁打的 —— 两边音色完全一样的话，
##      对拉时根本分不清是自己打到了还是对面打到了。
##   2. **不吃 hit_cooldown**。那是防「同一次挥拍联判两次」的，
##      对手击球是独立事件，被冷却挡掉就等于丢反馈。
func play_opponent_hit(strength: float = 1.0) -> void:
	if not enable_sfx:
		return
	var s := clampf(strength, 0.0, 1.0)
	_play(_hit_take(), lerpf(hit_db - 6.0, hit_db - 2.0, s), randf_range(0.80, 0.88))


## 球在台面上弹了一下（清脆）
func play_bounce(strength: float = 1.0) -> void:
	if not enable_sfx:
		return
	var s := clampf(strength, 0.0, 1.0)
	_play(_bounce_take(), lerpf(bounce_db - 7.0, bounce_db + 2.0, s),
		randf_range(0.92, 1.10))


## 撞网（闷「沙」）
func play_net() -> void:
	if not enable_sfx:
		return
	_play(NET, net_db, randf_range(0.95, 1.05))


## 挥拍破风声（没打到球时更明显）
func play_whoosh(strength: float = 1.0) -> void:
	if not enable_sfx:
		return
	var s := clampf(strength, 0.0, 1.0)
	_play(WHOOSH, lerpf(whoosh_db - 6.0, whoosh_db + 3.0, s),
		randf_range(0.90, 1.08))


## 一记欢呼（通用入口，不区分场合）—— 从变体池轮转取一条真实呐喊。
func play_cheer() -> void:
	var g := _voice_gain("cheer")
	if g <= -79.0:
		return
	_play(_cheer_take(), cheer_db + g, randf_range(0.97, 1.03))


## 得分瞬间的**整套观众反应**：一记呐喊 + 人群「先让路、再爆发」。
##
## ★ 这里只出真实观众呐喊（CHEER_VARIANTS），**不含奶龙** ——
##   奶龙已经改派给 `play_concede()`，见那个函数的注释。
## ★ 为什么要先压低人群：现场氛围是一层连续的中频噪声，而人声同样落在
##   人声频段。不先让路，呐喊会被底噪糊掉 —— 玩家听到的只是「现场吵了一点」，
##   而不是「有人在为我欢呼」。
## 取某一类音效的**分项增益**（dB），关掉 / 音量为 0 时返回 null 表示「不要发声」。
##
## ★ 「不要发声」用 -999 表示：调用点一句 `if g <= -79.0: return` 同时吃掉
##   「总闸关了」「这一类关了」「音量拖到 0」三种情况，不会漏判任何一种。
## ★ 拿不到 Game 单例时（探针里、或还没加进树）一律当作「开着、原音量」，
##   免得在测试环境里整段音效静默消失。
func _voice_gain(key: String) -> float:
	if not enable_sfx:
		return -999.0
	var g := get_node_or_null("/root/Game")
	if g == null or not g.has_method("sfx_gain_db"):
		return 0.0
	return float(g.call("sfx_gain_db", key))


## 底噪的分项增益。**故意不过 enable_sfx**：
## 底噪挂在 Ambience 总线上（见 _ready 的 _crowd_player.bus），
## 管它的是「现场氛围」那条总线 —— 用「击球音效」开关去关底噪属于串线。
## 所以这里绕开 _voice_gain 直接问 Game。
func _crowd_gain() -> float:
	var g := get_node_or_null("/root/Game")
	if g == null or not g.has_method("sfx_gain_db"):
		return 0.0
	return float(g.call("sfx_gain_db", "crowd"))



## big = 一局拿下（比拿到 1 分更隆重）。
func play_score_cheer(big: bool = false) -> void:
	var g := _voice_gain("cheer")
	if g <= -79.0:
		# ★ 关掉呐喊时**连人群爆发一起跳过**：只留人群、没有人声，
		#   听感是「现场忽然吵了一下」，比完全没反应更奇怪。
		return
	var cs: Array = _cheer_skin()
	_play(cs[0] as AudioStream, cheer_db + g + (1.5 if big else 0.0),
		randf_range(0.98, 1.03) * float(cs[1]))
	_crowd_dip_then_swell(9.0 if big else 8.0,
		0.40,
		6.0 if big else 4.5,
		2.4 if big else 1.8)


## 失分瞬间的挖苦音：**奶龙大笑**。
##
## ★ 用户指定「失分用奶龙笑，得分呐喊」—— 所以这条和 play_score_cheer 是
##   一对互斥的声音，玩家光靠听就能判断刚才是谁拿的分。
## ★ 为什么不做「人群倒抽气 / 叹气」：手头没有合适的素材，而且这一段
##   正在被『人群先让路再爆发』的补间占着，塞第三条会互相抢音量。
##   只放一记短促的笑，反而干净。
##
## 节流：point_pause 是 1.3 s 而这段笑声有 3.06 s，连丢两分时后一条会盖住
## 前一条的尾巴。0.9 s 的冷却保证「每次丢分都听得到一声」，又不会糊成一团。
func play_concede() -> void:
	var g := _voice_gain("concede")
	if g <= -79.0:
		return
	if _time - _last_concede_time < concede_cooldown:
		return
	_last_concede_time = _time
	_play(NAILONG_LAUGH, concede_db + g, randf_range(0.97, 1.03))


## 连拍里程碑的呐喊（方案 C「连拍爽感循环」）。
## tier: 1 = 5 拍（不出声，只有文字）/ 2 = 10 拍「精彩对拉」/ 3 = 20 拍「神球」。
##
## ★ 20 拍不再固定用奶龙：奶龙改派给失分之后，「全场最夸张的一记反馈」再放
##   笑声会被读成「刚才是对手得分吗」。改成**呐喊 + 更大的音量与人群爆发**，
##   一样能听出「这一档比上一档隆重」，而且语义不会串。
func play_rally_cheer(tier: int) -> void:
	if tier < 2:
		return
	var g := _voice_gain("cheer")
	if g <= -79.0:
		# 同上：连拍里程碑的呐喊被关掉时，人群爆发也一起跳过
		return
	var big := tier >= 3
	var cs: Array = _cheer_skin()
	_play(cs[0] as AudioStream, cheer_db + g + (2.0 if big else 0.5),
		randf_range(0.98, 1.03) * float(cs[1]))
	_crowd_dip_then_swell(10.0 if big else 7.0,
		0.35,
		7.0 if big else 4.5,
		2.6 if big else 1.8)


## 人群底噪：先压低让呐喊露出来 → 再冲上去 → 慢慢回到日常。
func _crowd_dip_then_swell(dip_db: float, dip_time: float,
		peak_db: float, recover: float) -> void:
	if _crowd_player == null or not _crowd_player.playing:
		return
	if _crowd_tween != null and _crowd_tween.is_valid():
		_crowd_tween.kill()
	var base := _crowd_base_db()
	_crowd_tween = create_tween()
	_crowd_tween.tween_property(_crowd_player, "volume_db", base - dip_db, dip_time) \
		.set_trans(Tween.TRANS_SINE)
	_crowd_tween.tween_property(_crowd_player, "volume_db", base + peak_db, 0.18) \
		.set_trans(Tween.TRANS_SINE)
	_crowd_tween.tween_property(_crowd_player, "volume_db", base, recover)


## 解锁音频（并按玩家设置启动现场底噪）。浏览器需要用户手势，
## 所以在第一次输入时调用。桌面端 _ready 里已经调用过一次，重复调用会被
## _unlocked 挡掉 —— 但**底噪的启停要放在 _unlocked 闸之外**：
## 设置面板改了开关之后（局内暂停也能改）要能立刻生效，不能因为早就解锁了就跳过。
func start_ambience() -> void:
	var first := not _unlocked
	_unlocked = true
	_sync_crowd(first)


## 让底噪的播放状态跟上玩家的开关。start_ambience（解锁）、
## set_state（局内改设置后）都走这里，避免两处各写一份启停逻辑。
func _sync_crowd(allow_start: bool = true) -> void:
	if _crowd_player == null:
		return
	var want := _unlocked and allow_start and crowd_wanted()
	if want and not _crowd_player.playing:
		_crowd_player.volume_db = _crowd_base_db()
		_crowd_player.play()
	elif not want and _crowd_player.playing:
		# 停之前先 kill 补间：留着它会在 play 之后继续往 volume_db 上写，
		# 表现是「重新打开后音量卡在某个中间值」。
		if _crowd_tween != null and _crowd_tween.is_valid():
			_crowd_tween.kill()
		_crowd_player.stop()
	elif want and (_crowd_tween == null or not _crowd_tween.is_valid()):
		# 已经在放、只是滑杆动了 → 把基准音量顶上去。
		# ★ 必须加「没有补间在跑」这个条件（用 is_valid() 而不是 != null：
		#   跑完的 Tween 对象仍然非 null，只是 is_valid() 变 false）：
		#   得分爆发期间正在 tween，这时改基准音量不会立刻生效
		#   （下一帧补间又覆盖回去了）；反过来若无条件写，
		#   就会把「先压低再爆发」那条曲线打断成阶梯。
		_crowd_player.volume_db = _crowd_base_db()


## 设置变更后由 pingpong_game 调一次，让底噪的启停跟上玩家的开关。
## ★ 只管底噪，**不碰 enable_sfx**：底噪在 Ambience 总线上，
##   「击球音效」那条总线本来就管不到它（见 _crowd_gain 的注释）。
func apply_settings() -> void:
	_sync_crowd()


func stop_ambience() -> void:
	if _crowd_player != null:
		_crowd_player.stop()


## 球台对侧进球/得分瞬间把观众音量顶一下，做出「现场被点燃」的效果
func swell_crowd(amount_db: float = 5.0, recover_seconds: float = 1.6) -> void:
	if _crowd_player == null or not _crowd_player.playing:
		return
	if _crowd_tween != null and _crowd_tween.is_valid():
		_crowd_tween.kill()
	var target := _crowd_base_db()
	var peak := target + amount_db
	_crowd_player.volume_db = peak
	_crowd_tween = create_tween()
	_crowd_tween.tween_property(_crowd_player, "volume_db", target, recover_seconds)


func is_ambience_playing() -> bool:
	return _crowd_player != null and _crowd_player.playing


func is_unlocked() -> bool:
	return _unlocked
