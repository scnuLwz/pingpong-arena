extends Node
## 全局状态单例（autoload 名 `Game`）—— 金币 / 场馆 / 声音设置 / 统计 / 任务 / 存档
##
## 两层持久化，别搞混：
##   · **档案** `user://profile.json` —— 一直活着。金币、已解锁场馆、当前场馆、
##     声音设置、累计统计、已领任务。任何一处变化都会立刻写盘，
##     所以「买了个场馆然后直接关页面」不会丢。
##   · **存档槽** `user://slot_1..3.json` —— 玩家手动存/读的快照。
##     内容就是档案的一份拷贝 + 时间戳 + 比分摘要，用来回滚到某个时间点。
##
## 单位说明：金币是全整数；音量是 0~1 的线性值，写进 AudioServer 前转成分贝。

signal coins_changed(coins: int)
signal profile_changed()
signal settings_changed()
signal arena_changed(id: String)
signal tournament_changed()

const VERSION := 1
const PROFILE_PATH := "user://profile.json"
const SLOT_COUNT := 3

## 音效 / 现场氛围两条总线，名字要和 pingpong_audio.gd 里用的一致
const BUS_MASTER := "Master"
const BUS_SFX := "SFX"
const BUS_AMBIENCE := "Ambience"

# ───────────── 场馆目录（商店的内容）─────────────
## price = 0 表示初始就有。theme 里的键会传给 court_builder.gd。
## 配色都是成对调的：地胶和挡板要有对比，否则整个场馆糊成一片蓝。
##
## ★ 2026-10-03（经济二期）从 4 个扩到 10 个，并把价格整体上调。
##   理由：一期把金币产出砍到 1/6 之后，4 个场馆合起来才 1150 金币，
##   玩家「随便打打就买光了」，之后金币又变成废纸 —— 和一期要解决的问题
##   是同一个。10 个场馆合计 **8200**，最后两个（1500 / 2500）是明确的
##   长期目标：按一期实测一局 95 金币算，皇家紫金要打 26 局，
##   正好是「一周每天 3~4 局」的量，撑得住一个周的回归。
## ★ 老档不受影响：已解锁的 `unlocked` 里该有的还有，涨价不追溯扣款。
const ARENAS := [
	{
		"id": "classic", "name": "经典红蓝", "price": 0,
		"desc": "红地胶 + 深蓝挡板，最常见的比赛场馆配色。",
		"theme": {
			"court_color": Color(0.155, 0.030, 0.042),
			"barrier_color": Color(0.085, 0.145, 0.375),
			"ad_band_color": Color(0.44, 0.075, 0.090),
			"apron_color": Color(0.555, 0.300, 0.240),
			"light_color": Color(1.0, 0.97, 0.92),
			"light_energy": 2.0,
			# ── 形态层：标准室内馆（基准形态） ──
			"stand_rows": 6, "seat_pitch": 0.52,
			"truss": true, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
		},
	},
	{
		"id": "night", "name": "深夜蓝光", "price": 300,
		"desc": "压暗环境光、顶灯转冷白，地胶换成深靛蓝 —— 夜场转播的味道。",
		"theme": {
			"court_color": Color(0.045, 0.058, 0.130),
			"barrier_color": Color(0.055, 0.190, 0.290),
			"ad_band_color": Color(0.070, 0.230, 0.330),
			"apron_color": Color(0.220, 0.330, 0.520),
			"light_color": Color(0.80, 0.90, 1.0),
			"light_energy": 1.7,
			"ambient_energy": 0.22,
			"bg_color": Color(0.028, 0.035, 0.060, 1.0),
			# ── 形态层：夜场转播馆 —— **无顶**（露天转播的典型做法）、
			#   高看台、灯带换成最亮（夜场靠灯带撑氛围）、
			#   记分牌换成冷蓝（和场馆灯光一个色温）。 ──
			"ceiling": 24.0, "stand_rows": 8, "seat_pitch": 0.50,
			"truss": false, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
			"scoreboard_ink": Color(0.30, 0.72, 1.00),
			"scoreboard_screen": Color(0.015, 0.030, 0.060),
			"flag_y": 6.40,
		},
	},
	{
		"id": "campus", "name": "校园体育馆", "price": 400,
		"desc": "米色地胶 + 天蓝挡板，顶灯偏黄 —— 校队训练馆那种不讲究但干净的味道。",
		"theme": {
			"court_color": Color(0.230, 0.195, 0.140),
			"barrier_color": Color(0.240, 0.470, 0.720),
			"ad_band_color": Color(0.180, 0.360, 0.560),
			"apron_color": Color(0.470, 0.420, 0.330),
			"light_color": Color(1.0, 0.960, 0.860),
			"light_energy": 1.9,
			"crowd_empty_ratio": 0.62,
			# ── 形态层：校队训练馆 —— **光秃秃**：没有桁架、没有围栏、没有旗帜、
			#   看台只有 3 排且座椅稀疏（本身就没什么人）。
			#   这档的卖点恰恰是「便宜简陋」，把结构件全关掉才对。 ──
			"stand_rows": 3, "seat_pitch": 0.62,
			"truss": false, "lightstrip": false,
			"scoreboard": false, "flags": false, "fence": false,
			"ceiling": 5.6,
			"end_wall_h": 3.6,
			"stand_color": Color(0.220, 0.215, 0.200),
			"ceiling_color": Color(0.320, 0.330, 0.330),
			"crowd_scale": 1.25,
		},
	},
	{
		"id": "worlds", "name": "世乒赛绿", "price": 500,
		"desc": "墨绿地胶 + 米白挡板，世乒赛主赛场那套干净配色。",
		"theme": {
			"court_color": Color(0.045, 0.115, 0.080),
			"barrier_color": Color(0.700, 0.690, 0.640),
			"ad_band_color": Color(0.115, 0.290, 0.180),
			"apron_color": Color(0.300, 0.480, 0.330),
			"light_color": Color(1.0, 0.99, 0.94),
			"light_energy": 2.1,
			# ── 形态层：世乒赛主赛场 —— **看台最大**（7 排）、座椅最密、
			#   米白挡板配银灰桁架，全场最"正经"的形态。 ──
			"stand_rows": 7, "seat_pitch": 0.48,
			"truss": true, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
			"truss_color": Color(0.430, 0.440, 0.450),
			"fence_color": Color(0.400, 0.410, 0.420),
			"barrier_top_color": Color(0.180, 0.400, 0.260),
			"ceiling": 8.2,
		},
	},
	{
		"id": "mono", "name": "黑白胶片", "price": 600,
		"desc": "全场压成灰阶，只有顶灯留一点冷白 —— 老转播录像的颗粒感。",
		"theme": {
			"court_color": Color(0.130, 0.130, 0.135),
			"barrier_color": Color(0.280, 0.285, 0.295),
			"ad_band_color": Color(0.420, 0.420, 0.425),
			"apron_color": Color(0.350, 0.350, 0.355),
			"light_color": Color(0.93, 0.94, 0.97),
			"light_energy": 1.8,
			"ambient_energy": 0.30,
			"bg_color": Color(0.055, 0.055, 0.060, 1.0),
			# ── 形态层：老录像 —— 低矮看台（4 排）、座椅全是灰（黑白片里
			#   不该有颜色）、**没有灯带**（老场馆没跑马灯）、记分牌是白的。 ──
			"stand_rows": 4, "seat_pitch": 0.58,
			"truss": true, "lightstrip": false,
			"scoreboard": true, "flags": false, "fence": true,
			"seat_colors": [Color(0.42, 0.42, 0.43), Color(0.34, 0.34, 0.35),
				Color(0.50, 0.50, 0.51)],
			"scoreboard_ink": Color(0.92, 0.92, 0.92),
			"scoreboard_screen": Color(0.060, 0.060, 0.062),
			"truss_color": Color(0.280, 0.280, 0.290),
			"ceiling": 6.2,
		},
	},
	{
		"id": "desert", "name": "沙漠黄昏", "price": 800,
		"desc": "暖橙地胶 + 赭石挡板，顶灯压成夕阳色 —— 傍晚的露天赛场。",
		"theme": {
			"court_color": Color(0.200, 0.105, 0.045),
			"barrier_color": Color(0.330, 0.180, 0.075),
			"ad_band_color": Color(0.520, 0.300, 0.105),
			"apron_color": Color(0.560, 0.390, 0.210),
			"light_color": Color(1.0, 0.860, 0.660),
			"light_energy": 2.0,
			"ambient_energy": 0.34,
			"bg_color": Color(0.115, 0.070, 0.045, 1.0),
			# ── 形态层：**纯露天** —— 没有天花板、没有桁架、没有顶灯，
			#   天花抬到 30（等于看不到顶）。端墙压矮到 3.2 当成「场地边的土坡围栏」，
			#   旗帜改挂低一点（露天看台的旗杆本来就矮）。 ──
			"ceiling": 30.0, "end_wall_h": 3.2,
			"stand_rows": 5, "seat_pitch": 0.54,
			"truss": false, "lightstrip": false,
			"scoreboard": true, "flags": true, "fence": true,
			"flag_y": 3.90,
			"seat_colors": [Color(0.640, 0.400, 0.180), Color(0.560, 0.300, 0.130),
				Color(0.700, 0.500, 0.260)],
			"stand_color": Color(0.400, 0.280, 0.170),
			"scoreboard_ink": Color(1.00, 0.80, 0.40),
		},
	},
	{
		"id": "final", "name": "金色决赛馆", "price": 900,
		"desc": "暖金地胶 + 深紫挡板，顶灯全开、看台最满 —— 决赛夜的排场。",
		"theme": {
			"court_color": Color(0.230, 0.130, 0.035),
			"barrier_color": Color(0.150, 0.075, 0.230),
			"ad_band_color": Color(0.470, 0.320, 0.075),
			"apron_color": Color(0.640, 0.470, 0.190),
			"light_color": Color(1.0, 0.93, 0.78),
			"light_energy": 2.4,
			"crowd_empty_ratio": 0.06,
			# ── 形态层：决赛馆 —— **最华丽的形态**。天花板抬到 9.5（挑高）、
			#   看台 7 排、挡板加高到 1.2、金色桁架 + 金色座椅，
			#   记分牌换成大红金。 ──
			"ceiling": 9.5, "barrier_h": 1.20,
			"stand_rows": 7, "seat_pitch": 0.46,
			"truss": true, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
			"truss_color": Color(0.560, 0.440, 0.200),
			"fence_color": Color(0.520, 0.410, 0.190),
			"seat_colors": [Color(0.680, 0.480, 0.110), Color(0.560, 0.140, 0.140),
				Color(0.720, 0.580, 0.220), Color(0.420, 0.120, 0.260)],
			"scoreboard_ink": Color(1.00, 0.86, 0.30),
			"scoreboard_screen": Color(0.045, 0.020, 0.055),
			"flag_y": 5.80,
		},
	},
	{
		"id": "olympic", "name": "奥运蓝", "price": 1200,
		"desc": "亮蓝地胶 + 纯白挡板，冷白顶灯打到发白 —— 奥运会主馆的极简配色。",
		"theme": {
			"court_color": Color(0.040, 0.190, 0.400),
			"barrier_color": Color(0.880, 0.900, 0.930),
			"ad_band_color": Color(0.060, 0.300, 0.620),
			"apron_color": Color(0.330, 0.520, 0.760),
			"light_color": Color(0.95, 0.975, 1.0),
			"light_energy": 2.3,
			"ambient_energy": 0.42,
			# ── 形态层：奥运主馆 —— **最高挑、最空**。天花板 11（挑高到夸张）、
			#   看台 8 排、白座椅白桁架白围栏（全白是奥运馆的标志），
			#   但**不放旗帜**（奥运场馆靠简洁，不挂旗）。 ──
			"ceiling": 11.0, "end_wall_h": 5.6,
			"stand_rows": 8, "seat_pitch": 0.50,
			"truss": true, "lightstrip": false,
			"scoreboard": true, "flags": false, "fence": true,
			"truss_color": Color(0.620, 0.640, 0.660),
			"fence_color": Color(0.600, 0.620, 0.640),
			"seat_colors": [Color(0.850, 0.860, 0.880), Color(0.700, 0.740, 0.800),
				Color(0.080, 0.320, 0.560)],
			"stand_color": Color(0.360, 0.400, 0.450),
			"ceiling_color": Color(0.480, 0.510, 0.545),
			"scoreboard_ink": Color(0.100, 0.420, 0.780),
			"scoreboard_screen": Color(0.030, 0.045, 0.070),
		},
	},
	{
		"id": "neon", "name": "霓虹赛博", "price": 1500,
		"desc": "紫粉地胶 + 青色挡板，环境光压到最低 —— 像在电子游戏里打球。",
		"theme": {
			"court_color": Color(0.140, 0.030, 0.190),
			"barrier_color": Color(0.040, 0.420, 0.470),
			"ad_band_color": Color(0.480, 0.070, 0.560),
			"apron_color": Color(0.290, 0.110, 0.400),
			"light_color": Color(0.720, 0.620, 1.0),
			"light_energy": 1.5,
			"ambient_energy": 0.14,
			"bg_color": Color(0.035, 0.012, 0.055, 1.0),
			# ── 形态层：赛博馆 —— **低矮 + 全是灯**。天花板压到 4.6（压迫感）、
			#   看台 8 排塞满、桁架改成「冷钢蓝」压住暖光，
			#   记分牌换品红（和场馆紫青配色呼应）。 ──
			"ceiling": 4.6, "end_wall_h": 4.0,
			"stand_rows": 8, "seat_pitch": 0.44,
			"truss": true, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
			"truss_color": Color(0.180, 0.560, 0.640),
			"fence_color": Color(0.140, 0.480, 0.540),
			"seat_colors": [Color(0.560, 0.080, 0.640), Color(0.060, 0.520, 0.560),
				Color(0.720, 0.160, 0.520), Color(0.100, 0.240, 0.600)],
			"scoreboard_ink": Color(0.95, 0.25, 0.85),
			"scoreboard_screen": Color(0.040, 0.010, 0.055),
			"ceiling_color": Color(0.150, 0.120, 0.220),
			"flag_y": 4.30,
		},
	},
	{
		"id": "royal", "name": "皇家紫金", "price": 2500,
		"desc": "深紫地胶 + 金色挡板，看台全满、灯全开 —— 这个游戏的顶配场馆。",
		"theme": {
			"court_color": Color(0.105, 0.045, 0.190),
			"barrier_color": Color(0.290, 0.215, 0.060),
			"ad_band_color": Color(0.560, 0.430, 0.120),
			"apron_color": Color(0.420, 0.300, 0.560),
			"light_color": Color(1.0, 0.945, 0.800),
			"light_energy": 2.6,
			"crowd_empty_ratio": 0.02,
			# ── 形态层：顶配 —— 各项都取最大：挑高 10.5、挡板 1.25、
			#   看台 8 排且座椅最密（0.42）、金色桁架/围栏/座椅，
			#   记分牌换成亮金。 ──
			"ceiling": 10.5, "barrier_h": 1.25, "end_wall_h": 5.2,
			"stand_rows": 8, "seat_pitch": 0.42,
			"truss": true, "lightstrip": true,
			"scoreboard": true, "flags": true, "fence": true,
			"truss_color": Color(0.620, 0.500, 0.200),
			"fence_color": Color(0.580, 0.470, 0.180),
			"seat_colors": [Color(0.720, 0.560, 0.140), Color(0.480, 0.160, 0.400),
				Color(0.200, 0.120, 0.340), Color(0.780, 0.660, 0.260)],
			"scoreboard_ink": Color(1.00, 0.82, 0.20),
			"scoreboard_screen": Color(0.040, 0.020, 0.060),
			"flag_y": 6.10,
		},
	},
]

# ───────────── 球拍皮肤目录 ─────────────
## ★ 2026-10-03（经济二期新增）。挂点是现成的 —— paddle_rubber.gdshader
##   已经按模型局部坐标分区上色，换色只需要改 `rubber_color` / `wood_color`
##   两个 uniform，不用碰贴图、不用碰模型。这是整套出口里**成本最低**的一个。
##
## slot 有三种，各自占一个装备槽、互不冲突：
##   rubber —— 胶皮配色（普通档，抽卡 70%）
##   wood   —— 拍柄材质（稀有档，抽卡 25%）
##   epic   —— 特效拍面（史诗档，抽卡 5%）：**覆盖**胶皮色并开启流光，
##             装备 epic 时 rubber 槽的颜色被盖掉，取消后自动恢复。
##
## ★ price = 0 的两条是初始拥有（红黑经典 + 原木柄），但**依然在抽卡池里** ——
##   抽到就走「重复返还」，玩家不会觉得池子被抠掉一块。
## ★ 硬约束：全部是外观。**有排位赛就不能卖任何一层数值**，否则排位变成氪金。
const PADDLE_SKINS := [
	# ── 胶皮配色（普通 70%）──
	{"id": "r_red", "slot": "rubber", "rarity": "common",
	 "name": "红黑经典", "desc": "标准比赛配置，正红反黑那一套。",
	 "price": 0, "rubber": Color(0.600, 0.045, 0.055)},
	{"id": "r_blue", "slot": "rubber", "rarity": "common",
	 "name": "深海蓝", "desc": "冷调蓝胶皮，拍面压得住光。",
	 "price": 150, "rubber": Color(0.055, 0.140, 0.520)},
	{"id": "r_green", "slot": "rubber", "rarity": "common",
	 "name": "墨玉绿", "desc": "深绿胶皮，接近涩性套胶的哑光质感。",
	 "price": 200, "rubber": Color(0.045, 0.290, 0.140)},
	{"id": "r_purple", "slot": "rubber", "rarity": "common",
	 "name": "紫罗兰", "desc": "偏紫的胶皮，灯光下会有一点荧光感。",
	 "price": 260, "rubber": Color(0.330, 0.075, 0.520)},
	{"id": "r_white", "slot": "rubber", "rarity": "common",
	 "name": "素白", "desc": "纯白胶皮，最容易被场馆灯光染色的一档。",
	 "price": 320, "rubber": Color(0.780, 0.790, 0.800)},
	{"id": "r_orange", "slot": "rubber", "rarity": "common",
	 "name": "赤橙", "desc": "高饱和橙，画面里最跳的一块胶皮。",
	 "price": 400, "rubber": Color(0.780, 0.260, 0.030)},

	# ── 拍柄材质（稀有 25%）──
	{"id": "w_wood", "slot": "wood", "rarity": "rare",
	 "name": "原木", "desc": "不上漆的浅木柄，最朴素的那支。",
	 "price": 0, "wood": Color(0.470, 0.290, 0.135)},
	{"id": "w_carbon", "slot": "wood", "rarity": "rare",
	 "name": "碳素黑", "desc": "哑光黑柄，带一点编织纹理的冷淡感。",
	 "price": 300, "wood": Color(0.115, 0.120, 0.135)},
	{"id": "w_sakura", "slot": "wood", "rarity": "rare",
	 "name": "樱花木", "desc": "偏粉的浅木，手感党最爱的一档。",
	 "price": 450, "wood": Color(0.760, 0.520, 0.430)},
	{"id": "w_ivory", "slot": "wood", "rarity": "rare",
	 "name": "象牙白", "desc": "奶白柄，配深色胶皮对比最强烈。",
	 "price": 600, "wood": Color(0.820, 0.790, 0.700)},

	# ── 特效拍面（史诗 5%）──
	{"id": "e_flame", "slot": "epic", "rarity": "epic",
	 "name": "烈焰纹", "desc": "拍面沿长轴流动的火纹，挥拍时最亮。",
	 "price": 600, "rubber": Color(0.620, 0.170, 0.030),
	 "glow": Color(1.0, 0.520, 0.120), "glow_speed": 2.2},
	{"id": "e_aurora", "slot": "epic", "rarity": "epic",
	 "name": "极光", "desc": "青紫色流光缓慢扫过拍面，冷调的一档。",
	 "price": 900, "rubber": Color(0.140, 0.230, 0.420),
	 "glow": Color(0.320, 0.900, 0.780), "glow_speed": 1.1},
	{"id": "e_gold", "slot": "epic", "rarity": "epic",
	 "name": "黄金圣火", "desc": "金色流光 + 最亮的底，决赛夜用的那支。",
	 "price": 1200, "rubber": Color(0.480, 0.320, 0.040),
	 "glow": Color(1.0, 0.860, 0.320), "glow_speed": 3.0},
]

## 抽一次球拍外观要几张券（每日全清给 1 张 → 一周凑一次）。
const DRAW_COST_PADDLE: int = 7

## 档位概率。**先掷档位、再在档内均匀取** —— 这样每条普通款各 70/6 ≈ 11.7%，
## 而不会出现「某一条特别难出」。从大到小排，取第一个满足的。
const DRAW_RARITY := [
	["common", 0.70],
	["rare", 0.25],
	["epic", 0.05],
]

## ★ 抽到已拥有的 → 折成金币返还，不允许「抽了个空气」。
##   「抽到重复什么都没有」是最伤的挫败感，一次就够劝退。
const DRAW_REFUND := {"common": 150, "rare": 400, "epic": 1200}

## ★ 保底：连续这么多次没出史诗，下一次**必出史诗**。
##   没有保底的话，5% 意味着约 13% 的玩家连抽 40 次（= 280 天）也见不到史诗。
##   单机游戏没有客服、没有补偿，这种运气只能靠机制兜住。
const DRAW_PITY_EPIC: int = 10

## 场馆券能直接抵的场馆价格上限。超过这个数的（奥运蓝 1200 / 霓虹 1500 /
## 皇家紫金 2500）必须自己掏钱 —— 券是「给你一个中档场馆」，不是「随便挑」。
const ARENA_TICKET_MAX_PRICE: int = 800

# ───────────── 称号目录（第三期）─────────────
## 称号是**纯展示**的身份标签：达成条件自动解锁，玩家自己挑一个挂着。
## stat / goal 的判定方式和 QUESTS 完全一致（直接读 stats 里的累计值），
## 这样不必为一个展示系统再写一套进度逻辑 —— 也就不存在「漏埋点」的风险。
## ★ 全部称号都不带任何数值加成（有排位赛，一层数值都不能卖）。
const TITLES := [
	{"id": "t_rookie", "name": "新手上路", "desc": "打完第 1 局比赛。",
	 "stat": "matches_played", "goal": 1},
	{"id": "t_regular", "name": "球馆常客", "desc": "累计打满 10 局。",
	 "stat": "matches_played", "goal": 10},
	{"id": "t_veteran", "name": "百战老兵", "desc": "累计打满 50 局。",
	 "stat": "matches_played", "goal": 50},
	{"id": "t_scorer", "name": "得分手", "desc": "累计拿下 100 分。",
	 "stat": "points", "goal": 100},
	{"id": "t_loop", "name": "重炮手", "desc": "用正手爆冲拿下 25 分。",
	 "stat": "winners_loop", "goal": 25},
	{"id": "t_flick", "name": "拧拉行家", "desc": "用反手暴拧拿下 25 分。",
	 "stat": "winners_flick", "goal": 25},
	{"id": "t_wall", "name": "铁闸", "desc": "蹲下接球累计 50 次。",
	 "stat": "crouch_hits", "goal": 50},
	{"id": "t_marathon", "name": "马拉松", "desc": "打出 30 拍的回合。",
	 "stat": "max_rally", "goal": 30},
	{"id": "t_shutout", "name": "零封之王", "desc": "累计零封 5 局。",
	 "stat": "zero_games", "goal": 5},
	{"id": "t_streak", "name": "连击手", "desc": "一局里连续拿下 5 分。",
	 "stat": "best_streak", "goal": 5},
	{"id": "t_champ", "name": "卫冕冠军", "desc": "拿到 1 届赛事冠军。",
	 "stat": "tournaments_won", "goal": 1},
	{"id": "t_silver", "name": "白银选手", "desc": "排位打到白银。",
	 "stat": "rank_best_tier", "goal": 3},
	{"id": "t_gold", "name": "黄金选手", "desc": "排位打到黄金。",
	 "stat": "rank_best_tier", "goal": 6},
	{"id": "t_diamond", "name": "钻石选手", "desc": "排位打到钻石。",
	 "stat": "rank_best_tier", "goal": 12},
	{"id": "t_master", "name": "大师", "desc": "排位打上大师。",
	 "stat": "rank_best_tier", "goal": 15},
]

# ───────────── 应援色目录（第三期）─────────────
## 看台观众的整体辉光色。实现方式是在观众材质上叠一层 emissive
## —— 不是给每个人建模应援棒（208 个实例的 MultiMesh，加几何不现实），
##   而是让整片看台泛出应援色，远看就是一片灯海。
const SUPPORT_COLORS := [
	{"id": "s_warm", "name": "暖橙应援", "price": 0,
	 "desc": "默认的暖橙灯海。", "color": Color(1.00, 0.55, 0.15)},
	{"id": "s_blue", "name": "冰蓝应援", "price": 300,
	 "desc": "冷调蓝白，夜场最好看。", "color": Color(0.30, 0.70, 1.00)},
	{"id": "s_pink", "name": "樱粉应援", "price": 450,
	 "desc": "偏粉的应援色，画面会柔一档。", "color": Color(1.00, 0.45, 0.70)},
	{"id": "s_green", "name": "荧光绿", "price": 600,
	 "desc": "高饱和绿，深色场馆里最跳。", "color": Color(0.45, 1.00, 0.35)},
	{"id": "s_gold", "name": "鎏金应援", "price": 900,
	 "desc": "整片看台泛金，决赛馆的排场。", "color": Color(1.00, 0.85, 0.30)},
	{"id": "s_white", "name": "纯白灯海", "price": 1200,
	 "desc": "接近白光，最亮也最挑场馆。", "color": Color(0.95, 0.97, 1.00)},
]

# ───────────── 呐喊声换肤（第三期）─────────────
## ★ 不新增音频文件：同一份录音用 pitch_scale 变调。
##   压到 0.78 是「满场成年观众的闷响」，抬到 1.24 是「短促高亢的起哄」，
##   和重新录一条相比，差别只在音色而不在内容 —— 对 2 秒的欢呼声足够。
const CHEER_SKINS := [
	{"id": "c_youth", "name": "少年欢呼", "src": "cheer1", "pitch": 1.00,
	 "price": 0, "desc": "清亮的少年人声，最接近真实赛场。"},
	{"id": "c_teen", "name": "青春应援", "src": "cheer2", "pitch": 1.00,
	 "price": 400, "desc": "更密集的一层人声，带一点起哄感。"},
	{"id": "c_deep", "name": "低沉人潮", "src": "cheer1", "pitch": 0.78,
	 "price": 700, "desc": "压低音调，像满场观众的闷响。"},
	{"id": "c_sharp", "name": "高亢应援", "src": "cheer2", "pitch": 1.24,
	 "price": 900, "desc": "提高音调，适合短促的得分瞬间。"},
]

# ───────────── 每日限购（第三期）─────────────
## 每天从「还没拥有、且价格 ≥ DEAL_MIN_PRICE」的商品里挑一件打折，限购 1 件。
## ★ 折扣只对外观生效 —— 和经济系统的硬约束一致（有排位赛就不卖数值）。
const DEAL_DISCOUNTS := [0.60, 0.70, 0.80]
const DEAL_MIN_PRICE: int = 200

# ───────────── 任务目录 ─────────────
## stat 指向 stats 里的键；goal 是达标阈值；reward 是金币。
## progress 一律「单调递增的累计值」，不写「必须在一局内完成」这类条件 ——
## 那种需要对局生命周期管理，收益低但很容易写出边界 bug。
##
## ★ 2026-10-03 从 10 条扩到 36 条（用户要「任务丰富一些」）。扩的方式是
##   **补维度**而不是把同一件事的目标值拆成好几档 —— 后者只是把进度条拉长，
##   玩家做的事一模一样。新增的维度见 stats 里的注释（rally_10plus /
##   serve_returns / zero_games / best_streak / rank_* ），每一条都对应
##   一种「玩法上真的不一样」的行为。
## ★ 顺序即展示顺序：按「入门 → 手感 → 对拉 → 进攻 → 胜场 → 赛事 → 排位」
##   大致推进，玩家从上往下读就是一条成长路线。
## ★ 2026-10-03（经济重标定）：奖励全部 ÷6、取整到 5 的倍数、下限 10。
##   总额 18200 → **3050**，正好约等于「四个场馆 + 一件球拍皮肤」。
##
##   ★ 为什么必须砍：旧版仅这一张表就发 18200 金币，而全游戏能买的东西
##     合计只值 1150 —— 产出/消耗 15.8 倍。金币在这种比例下不是「奖励」，
##     是废纸。砍完这一刀，生涯成就变成「起步资金」，主力收入交给每日任务。
##
## ★ UI 上这张表改叫「**生涯成就**」，和新的「每日任务」分成两个页签。
##   名字分开是故意的：玩家看到「奖励被砍了」会觉得被削，
##   看到「多了一套每日玩法」会觉得是加内容 —— 两件事其实是同一次改动。
const QUESTS := [
	# ── 入门：把每个基础动作都碰一遍 ──
	{"id": "q_first", "name": "初次得分", "desc": "拿下第 1 分",
	 "stat": "points", "goal": 1, "reward": 10},
	{"id": "q_rally5", "name": "多拍相持", "desc": "单回合对拉 5 拍",
	 "stat": "max_rally", "goal": 5, "reward": 10},
	{"id": "q_crouch5", "name": "低姿防守", "desc": "蹲下接球 5 次",
	 "stat": "crouch_hits", "goal": 5, "reward": 10},
	{"id": "q_win1", "name": "旗开得胜", "desc": "赢下一局（先到 11 分）",
	 "stat": "matches_won", "goal": 1, "reward": 35},

	# ── 手感：单局里的动作质量 ──
	{"id": "q_loop3", "name": "爆冲手", "desc": "用正手爆冲拿 3 分",
	 "stat": "winners_loop", "goal": 3, "reward": 15},
	{"id": "q_flick3", "name": "香蕉拧", "desc": "用反手暴拧拿 3 分",
	 "stat": "winners_flick", "goal": 3, "reward": 15},
	{"id": "q_points20", "name": "手感火热", "desc": "累计得分 20 分",
	 "stat": "points", "goal": 20, "reward": 25},
	{"id": "q_points100", "name": "百分俱乐部", "desc": "累计得分 100 分",
	 "stat": "points", "goal": 100, "reward": 100},
	{"id": "q_serve_return20", "name": "接发球好手", "desc": "接住对手的发球 20 次",
	 "stat": "serve_returns", "goal": 20, "reward": 20},
	{"id": "q_crouch30", "name": "铁闸", "desc": "蹲下接球累计 30 次",
	 "stat": "crouch_hits", "goal": 30, "reward": 30},

	# ── 对拉：方案 C 的直接延伸 ──
	{"id": "q_rally10", "name": "拉锯战", "desc": "打出 1 个 10 拍以上的回合",
	 "stat": "rally_10plus", "goal": 1, "reward": 20},
	{"id": "q_rally10x10", "name": "相持成瘾", "desc": "累计打出 10 个 10 拍以上回合",
	 "stat": "rally_10plus", "goal": 10, "reward": 45},
	{"id": "q_rally20", "name": "铁人回合", "desc": "打出 1 个 20 拍以上的回合",
	 "stat": "rally_20plus", "goal": 1, "reward": 50},
	{"id": "q_rally20x5", "name": "二十拍俱乐部", "desc": "累计打出 5 个 20 拍以上回合",
	 "stat": "rally_20plus", "goal": 5, "reward": 115},
	{"id": "q_maxrally30", "name": "三十拍", "desc": "单个回合达到 30 拍",
	 "stat": "max_rally", "goal": 30, "reward": 135},

	# ── 进攻：把两种杀板分开练 ──
	{"id": "q_loop10", "name": "爆冲成性", "desc": "用正手爆冲拿 10 分",
	 "stat": "winners_loop", "goal": 10, "reward": 35},
	{"id": "q_flick10", "name": "拧拉大师", "desc": "用反手暴拧拿 10 分",
	 "stat": "winners_flick", "goal": 10, "reward": 35},
	{"id": "q_loop25", "name": "正手之矛", "desc": "用正手爆冲拿 25 分",
	 "stat": "winners_loop", "goal": 25, "reward": 70},
	{"id": "q_flick25", "name": "反手之刃", "desc": "用反手暴拧拿 25 分",
	 "stat": "winners_flick", "goal": 25, "reward": 70},

	# ── 胜场：从「赢一局」到「碾一局」 ──
	{"id": "q_win5", "name": "连胜节奏", "desc": "累计赢下 5 局",
	 "stat": "matches_won", "goal": 5, "reward": 75},
	{"id": "q_win10", "name": "十战十捷", "desc": "累计赢下 10 局",
	 "stat": "matches_won", "goal": 10, "reward": 115},
	{"id": "q_win25", "name": "常胜将军", "desc": "累计赢下 25 局",
	 "stat": "matches_won", "goal": 25, "reward": 235},
	{"id": "q_zero1", "name": "零封", "desc": "一局不让对手得分（11 : 0）",
	 "stat": "zero_games", "goal": 1, "reward": 85},
	{"id": "q_zero5", "name": "不给机会", "desc": "累计零封 5 局",
	 "stat": "zero_games", "goal": 5, "reward": 200},
	{"id": "q_streak5", "name": "五连击", "desc": "连续拿下 5 分（未中断）",
	 "stat": "best_streak", "goal": 5, "reward": 65},

	# ── 赛事 ──
	{"id": "q_tour1", "name": "站上赛场", "desc": "打完一届 32 人赛事",
	 "stat": "tournaments_played", "goal": 1, "reward": 25},
	{"id": "q_tour3", "name": "三届老兵", "desc": "打完 3 届赛事",
	 "stat": "tournaments_played", "goal": 3, "reward": 65},
	{"id": "q_tour_win", "name": "问鼎冠军", "desc": "拿到一届赛事冠军",
	 "stat": "tournaments_won", "goal": 1, "reward": 100},
	{"id": "q_tour_win3", "name": "卫冕之王", "desc": "拿到 3 届赛事冠军",
	 "stat": "tournaments_won", "goal": 3, "reward": 300},

	# ── 排位（方案 B）──
	{"id": "q_rank_play", "name": "排位初体验", "desc": "打 1 场排位赛",
	 "stat": "rank_matches", "goal": 1, "reward": 15},
	{"id": "q_rank_play10", "name": "排位常客", "desc": "打 10 场排位赛",
	 "stat": "rank_matches", "goal": 10, "reward": 35},
	{"id": "q_rank_win10", "name": "上分之路", "desc": "赢下 10 场排位赛",
	 "stat": "rank_wins", "goal": 10, "reward": 60},
	{"id": "q_rank_silver", "name": "白银段位", "desc": "排位打到白银",
	 "stat": "rank_best_tier", "goal": 3, "reward": 65},
	{"id": "q_rank_gold", "name": "黄金段位", "desc": "排位打到黄金",
	 "stat": "rank_best_tier", "goal": 6, "reward": 115},
	{"id": "q_rank_diamond", "name": "钻石段位", "desc": "排位打到钻石",
	 "stat": "rank_best_tier", "goal": 12, "reward": 250},
	{"id": "q_rank_master", "name": "大师段位", "desc": "排位打上大师",
	 "stat": "rank_best_tier", "goal": 15, "reward": 400},
]

# ───────────── 每日任务（方案 B 第一期）─────────────
##
## ★ 和上面的 QUESTS **是两套并行系统，不要合并**：
##   QUESTS 的维度是「历史累计」（`stats.points`），领一次就永远没了；
##   每日任务的维度一律是「今天」（`daily.stats` 里的 `_today` 键），**跨天归零**。
##   拿累计值去做每日任务，老玩家第一天开面板就是三条已完成的灰任务，毫无意义。
##
## bucket 用来保证「今天抽到的 3 条不撞车」：
##   A 出勤（来了就有） / B 技术（要打某种球） / C 极限（要做到一次漂亮事）
##   三条各从不同桶抽，否则会出现「赢 1 局 / 赢 3 局 / 打完 3 局」这种同质化组合。
##
## ★ id 一律用 **String**：`claimed` 是 `Array[String]`，
##   而 JSON 读回来全是 float —— 用数字 id 会踩 `Array.has(11)` 对 [6.0, 8.0] 返回
##   false 那个坑（Variant 哈希按类型分）。字符串天然避开。
const DAILY_QUESTS := [
	# ── A 出勤 ──
	{"id": "d_play", "name": "日常训练", "desc": "今天打完 3 局",
	 "stat": "played_today", "goal": 3, "reward": 80, "bucket": "A"},
	{"id": "d_win1", "name": "开门红", "desc": "今天赢下 1 局",
	 "stat": "wins_today", "goal": 1, "reward": 60, "bucket": "A"},
	{"id": "d_win3", "name": "三连捷", "desc": "今天赢下 3 局",
	 "stat": "wins_today", "goal": 3, "reward": 150, "bucket": "A"},
	{"id": "d_rank", "name": "排位日常", "desc": "今天打 2 场排位赛",
	 "stat": "rank_today", "goal": 2, "reward": 100, "bucket": "A"},
	{"id": "d_rankwin", "name": "天梯进账", "desc": "今天排位赢 1 场",
	 "stat": "rankwin_today", "goal": 1, "reward": 120, "bucket": "A"},

	# ── B 技术 ──
	{"id": "d_loop", "name": "正手功课", "desc": "今天用正手爆冲拿 5 分",
	 "stat": "loop_today", "goal": 5, "reward": 90, "bucket": "B"},
	{"id": "d_flick", "name": "反手功课", "desc": "今天用反手暴拧拿 5 分",
	 "stat": "flick_today", "goal": 5, "reward": 90, "bucket": "B"},
	{"id": "d_serve", "name": "接发功课", "desc": "今天接住对手 10 次发球",
	 "stat": "serve_today", "goal": 10, "reward": 80, "bucket": "B"},
	{"id": "d_crouch", "name": "低姿防守", "desc": "今天蹲着接 8 个球",
	 "stat": "crouch_today", "goal": 8, "reward": 70, "bucket": "B"},

	# ── C 极限 ──
	{"id": "d_rally10", "name": "手感在线", "desc": "今天打出 2 次 10 拍以上对拉",
	 "stat": "rally10_today", "goal": 2, "reward": 100, "bucket": "C"},
	{"id": "d_rally20", "name": "神拉锯", "desc": "今天打出 1 次 20 拍以上对拉",
	 "stat": "rally20_today", "goal": 1, "reward": 140, "bucket": "C"},
	{"id": "d_zero", "name": "完美一局", "desc": "今天零封 1 局",
	 "stat": "zero_today", "goal": 1, "reward": 180, "bucket": "C"},
	{"id": "d_streak", "name": "连续压制", "desc": "今天打出一次 8 连得分",
	 "stat": "streak_today", "goal": 8, "reward": 110, "bucket": "C"},
]

## 3 条全部完成后的额外奖励。
const DAILY_ALL_REWARD: int = 120

# ───────────── 每周任务 ─────────────
## 固定 3 条，不抽签 —— 每周目标应该是可预期的，玩家才好提前规划
## （「这周我要把排位打上黄金」），抽签只适合一天粒度的东西。
const WEEKLY_QUESTS := [
	{"id": "w_win", "name": "周常胜场", "desc": "本周赢下 10 局",
	 "stat": "wins_week", "goal": 10, "reward": 300},
	{"id": "w_rally", "name": "长回合", "desc": "本周打出 3 次 30 拍以上对拉",
	 "stat": "rally30_week", "goal": 3, "reward": 400},
	{"id": "w_rank", "name": "天梯常客", "desc": "本周打 5 场排位赛",
	 "stat": "rank_week", "goal": 5, "reward": 350},
]
const WEEKLY_ALL_REWARD: int = 800

## 连续完成（每天 3/3）的金币倍率档位。
## ★ 这是「每天回来」的核心钩子 —— 已有的东西不想丢（损失厌恶）。
## 档位用 [天数下限, 倍率] 从大到小排，取第一个满足的。
const DAILY_STREAK_TIERS := [
	[30, 2.5],
	[14, 2.0],
	[7, 1.6],
	[3, 1.3],
]
## 连续天数在下面这些情况下怎么处理：
##   漏 1 天（gap 2） → **冻结**：不增长也不减少
##   漏 n 天（gap n+1） → -(n-1)，最低 0
## ★ 关键：**永远不清零**。严格清零制会让一次意外（出差、考试）
##   直接毁掉 20 天的积累，玩家一旦觉得「反正断了」就再也不会回来。
##   宁可让 streak 通胀，也不能让它清零。
const DAILY_FREEZE_GAP: int = 2

## 新手保护：累计场次不到这个数时，每日任务只从「出勤桶」抽。
## 抽到「今天零封 1 局」对一个还没赢过的新手来说是纯挫败。
const DAILY_GREEN_MATCHES: int = 3

# ───────────── 运行时状态 ─────────────
var coins: int = 0
var unlocked: Array[String] = ["classic"]
var current_arena: String = "classic"
# ── 第三期：称号 / 应援色 / 呐喊 / 每日限购 ──
var titles: Array[String] = []
var title_current: String = ""
var supports: Array[String] = ["s_warm"]
var support_current: String = "s_warm"
var cheers: Array[String] = ["c_youth"]
var cheer_current: String = "c_youth"
## 今日限购。整块存，键：day / kind / id / price / orig / bought
var deal: Dictionary = {}
# ── 券（经济二期）──
## ★ 为什么不直接给金币：金币数额是确定的，玩家算得出来，边际快感递减得很快；
##   券是通往「随机外观」的门票，**不确定奖励的多巴胺远高于确定奖励**。
##   这是让「每日 3/3」值得专门去凑的关键 —— 一期只解决了「回不回来」，
##   券解决的是「回来之后为了什么」。
var tickets_paddle: int = 0     # 每日全清 +1，7 张抽一次球拍外观
var tickets_arena: int = 0      # 每周全清 +1，直接抵一个 ≤800 的场馆
# ── 球拍皮肤（经济二期）──
var skins: Array[String] = ["r_red", "w_wood"]
var skin_rubber: String = "r_red"
var skin_wood: String = "w_wood"
## 空串 = 不装备特效拍面（此时用 skin_rubber 的颜色）。
var skin_epic: String = ""
## 连续多少次没出史诗（保底计数，出了史诗归零）。
var draw_pity: int = 0
## 音量都是 0~1 线性值，1.0 = 原始音量。
## ★ "cheer" / "concede" / "crowd" 不是总线，是**分项增益**
##   （得分呐喊 / 失分奶龙笑 / 背景人群底噪），
##   在 pingpong_audio.gd 里叠到各自的 db 上。放进同一个字典是为了让设置面板
##   的滑杆逻辑复用同一套读写，也自动获得「读档时统一 clamp 到 0~1」的保护。
## ★ "crowd" 和总线 "ambience" 是**两层**：ambience 是「现场氛围」总闸（管所有
##   环境声），crowd 是背景人群底噪这一条的分项。和主音量 / 音效的关系一样。
## "sens" 是**球拍/视角灵敏度**的归一化值（0~1），乘到 camera_controller
## 的基准灵敏度上 —— 见 look_speed_mult()。
var settings: Dictionary = {
	"master": 1.0, "sfx": 1.0, "ambience": 0.8,
	"cheer": 1.0, "concede": 1.0, "crowd": 1.0,
	"sens": 0.25,
}
## 得分呐喊 / 失分奶龙笑 / 背景人群底噪 的**独立开关**（和音量分开）。
##
## ★ 为什么开关不直接用「音量拖到 0」代替：拖到 0 之后玩家看不出
##   「我是关掉了，还是调小了」，下次想开回来还得猜原来在哪一格。
##   开关是布尔、一眼可见，音量值原样保留 —— 关掉再打开，还是原来的响度。
var cheer_on: bool = true
var concede_on: bool = true
## ★ 背景人群底噪默认**关**（用户 2026-10-03 要求取消背景噪音，只要玩法反馈音）。
##   这次同时给它开了独立开关 —— 以前 `enable_ambience` 写死 false，
##   设置面板的「现场氛围」滑杆和试听按钮全是摆设（拖了没反应、点了没声音）。
##   现在玩家可以自己决定要不要现场底噪，且默认值仍然是关。
var crowd_on: bool = false
var stats: Dictionary = {
	"points": 0,            # 累计得分
	"winners_loop": 0,      # 正手爆冲制胜分
	"winners_flick": 0,     # 反手暴拧制胜分
	"max_rally": 0,         # 历史最长对拉
	"rally_today": 0,       # 今日最长对拉（跨天归零，见 note_rally）
	"matches_won": 0,       # 赢下的局数
	"matches_played": 0,
	"crouch_hits": 0,       # 蹲着接到的球
	"tournaments_played": 0,  # 打完的赛事届数
	"tournaments_won": 0,     # 拿过的赛事冠军数
	"best_place": 0,          # 历史最好名次（0 = 还没打）
	# ── 2026-10-03 新增：任务扩充要求的新维度 ──
	"rally_10plus": 0,      # 单回合对拉 ≥10 拍的回合数
	"rally_20plus": 0,      # 单回合对拉 ≥20 拍的回合数
	"serve_returns": 0,     # 接住对手发球的次数（发球阶段把球打回去）
	"zero_games": 0,        # 零封局数（赢下且对手 0 分）
	"best_streak": 0,       # 历史最长连续得分（按分，不是按局）
	"rank_matches": 0,      # 排位赛场次
	"rank_wins": 0,         # 排位赛胜场
	"rank_best_tier": 0,    # 排位历史最高小级序号（0 = 青铜 Ⅲ）
}
## 「今日最长对拉」记在哪一天（YYYY-MM-DD）。和系统日期比对，跨天就把
## rally_today 清零 —— 见 note_rally()。存进档案，重启后当天纪录不会丢。
##
## ★ 为什么不直接用 stats 存日期：_from_dict 里 stats 的每一项都要过 int()，
##   字符串塞进去会被转成 0。日期是 String，必须单独一个字段。
var rally_day: String = ""
var claimed: Array[String] = []
## ── 每日 / 每周任务状态（方案 B 第一期）──
##
## 整块存一个 Dictionary 而不是铺十几个顶层字段：读写/存档/重置都只有一处，
## 加字段时不用改 `_to_dict` / `_from_dict` 两遍。
##
## ★ 结构（★ 存档读回来数字会变 float，靠 `_normalize_daily` 在入口规整）：
##   daily  = {"day": "YYYY-MM-DD", "ids": [...], "stats": {...}, "claimed": [...],
##             "all": false, "streak": 0, "last": "YYYY-MM-DD", "best": 0, "mult": 1.0}
##   weekly = {"key": "2026-S40", "stats": {...}, "claimed": [...], "all": false}
##
## ★ `mult` 是**建块那一刻**就把倍率快照进去的，不是领取时现算。
##   否则玩家先领第 1 条（streak 6 → ×1.3）、再全清（streak 7 → ×1.6），
##   同一天的三条任务拿到三个不同倍率，怎么看都像 bug。
var daily: Dictionary = {}
var weekly: Dictionary = {}
var games_played: int = 0
## 上一次选的难度（0 简单 / 1 普通 / 2 困难 / 3 专家 / 4 大师）。开局面板会改它，游戏读它。
var difficulty: int = 1
## 双打模式开关。主菜单里选，进比赛时 pingpong_game.apply_preferences() 读它。
##
## ★ 为什么是「开关」而不是「模式枚举」：赛事 / 联赛那条链路（tournament.gd）
##   全是按单打写的（1v1 的评分、BO5、分组），把 doubles 塞进去要动的东西太多。
##   双打目前只在自由对战里开放，用一个 bool 隔开最省事，也最不容易串。
var doubles: bool = false
## 双打里「队友也交给 AI 打」的开关。**只在 doubles 为真时有意义。**
##
## 关掉（默认）= 原来的自动切换：轮到谁接球，相机就挪到他身上，两个人都是你。
## 打开 = 你只管自己这一侧，另一半边的球由 AI 队友自己接 ——
##   相机不再横移，队友那把拍子会自己挥。
var partner_ai: bool = false

# ───────────── 双打的入场费 / 奖金 ─────────────
## 进场先付 50 —— 用户定的数。付不出来就进不去（菜单里会拦）。
const DOUBLES_FEE: int = 50
## 赢了给 150（净赚 100）。输了这个不退。
const DOUBLES_PRIZE: int = 150

# ───────────── 比赛模式（赛事）─────────────
## 当前这一届的完整赛程。空字典 = 没在打。形状见 tournament.gd 文件头。
## 整个塞进 profile.json —— 赛程是「长跑」，中途关页面不能丢。
var tournament: Dictionary = {}

## ── 正在打的这一场 BO5 的局分 ──
## 为什么不放在 pingpong_game.gd 里：赛事场次的「打下一局」= 重载场景，
## 场景里的成员变量活不过 reload。放单例上，reload 前后才能接得上。
## tour_key 用来认「还是同一场吗」——换对手/换轮次就自动清零。
var tour_won: int = 0
var tour_lost: int = 0
var tour_key: String = ""

## ★★ **本局是否要打赛事场次** —— 由玩家在联赛面板里点「继续参赛」显式置位。
##
## 为什么必须有这个旗标（2026-10-03 用户报「开始游戏那里选难度无用」）：
##   原来 `tour_begin()` 只看「档案里有没有没打完的赛事」，**跟从哪进来完全无关**。
##   于是只要报名过一届联赛，从「开始比赛」进去也会被劫持成赛事场次，
##   难度跟着对手评分走 —— 菜单里那五档难度就成了摆设，而且**没有任何提示**。
##   排位有 `ranked`、双打有 `doubles`，唯独赛事是「推断」出来的，就漏了这一处。
##
## 语义和 ranked 一致：**一次进场意图**，「打下一局」（reload 场景）后仍然成立，
## 所以放单例而不是放场景里。它不进存档 —— 读档一律清 false（见 `_from_dict`）。
var tour_entry: bool = false


func _ready() -> void:
	# autoload 在启动时就准备好，菜单一打开就能读到正确的金币数
	load_profile()
	# ★ 每日 / 每周任务在这里建：load_profile 之后 stats 已经读完，
	#   _roll_daily 要读 stats.matches_played 判断新手保护，顺序不能反。
	daily_ensure()
	# 总线要在任何播放器建起来之前就位：pingpong_audio 里是按名字挂总线的，
	# 名字不存在时它只能退化到 Master，那样「音效」和「现场氛围」两个滑杆就都失效。
	ensure_audio_buses()
	apply_audio()
	apply_window_startup()


# ───────────── 窗口 / 全屏 ─────────────
## ★ 之前项目里**一行全屏代码都没有** —— 所以 F11、Alt+Enter 按下去全都没反应，
##   用户只能得到一个固定在 720p 的小窗口。这里一次性补齐三个入口：
##   启动最大化、键盘快捷键、设置面板按钮。
##
## ★ Web 端必须由**真实用户手势**触发全屏：浏览器禁止脚本自发请求，
##   所以网页上只有点「全屏」按钮这一条路，键盘快捷键在浏览器里无效。
##   （不是代码偷懒，是浏览器安全模型如此。）
func is_fullscreen() -> bool:
	return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN


func toggle_fullscreen() -> bool:
	if is_fullscreen():
		# 退出全屏回到「最大化」而不是原始 720p 小窗 ——
		# 用户既然嫌窗口小，退出来就不该再把他扔回小窗。
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
		return false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	return true


## 启动时直接全屏（用户要全屏）。保留 F11 / Alt+Enter 随时切回最大化。
## Web 端没有「窗口」概念，跳过。
func apply_window_startup() -> void:
	if OS.has_feature("web"):
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


## 全局快捷键。放在 autoload 上而不是各个场景里，
## 是为了菜单和比赛内都能用同一套键位，不用每个场景复制一遍。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	if not event.pressed or event.is_echo():
		return
	# F11：Windows 上约定俗成的全屏键；Alt+Enter 是第二个习惯键
	if event.keycode == KEY_F11 or (event.keycode == KEY_ENTER and event.alt_pressed):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()


# ───────────── 档案读写 ─────────────
func _to_dict() -> Dictionary:
	return {
		"version": VERSION,
		"coins": coins,
		"unlocked": unlocked,
		"current_arena": current_arena,
		"settings": settings,
		"stats": stats,
		"rally_day": rally_day,
		"claimed": claimed,
		"games_played": games_played,
		"difficulty": difficulty,
		"doubles": doubles,
		"partner_ai": partner_ai,
		"tournament": tournament,
		# ── 排位（方案 B）。日期/字符串字段必须单列，不能塞 stats ——
		#    _from_dict 对 stats 每项无条件 int()，rank_season 会被转成 0。
		"rank_points": rank_points,
		"rank_streak": rank_streak,
		"rank_lose_streak": rank_lose_streak,
		"rank_shield_floor": rank_shield_floor,
		"rank_season": rank_season,
		"rank_season_peak": rank_season_peak,
		# ── 每日 / 每周任务（经济重做第一期）。整块存，不铺十几个键。 ──
		"daily": daily,
		"weekly": weekly,
		# ── 券 + 球拍皮肤（经济重做第二期）──
		"tickets_paddle": tickets_paddle,
		"tickets_arena": tickets_arena,
		"skins": skins,
		"skin_rubber": skin_rubber,
		"skin_wood": skin_wood,
		"skin_epic": skin_epic,
		"draw_pity": draw_pity,
		# ── 第三期：称号 / 应援色 / 呐喊 / 每日限购 ──
		"titles": titles,
		"title_current": title_current,
		"supports": supports,
		"support_current": support_current,
		"cheers": cheers,
		"cheer_current": cheer_current,
		"deal": deal,
		# ── 呐喊 / 奶龙笑 / 人群底噪 的独立开关 ──
		"cheer_on": cheer_on,
		"concede_on": concede_on,
		"crowd_on": crowd_on,
	}


func _from_dict(d: Dictionary) -> void:
	coins = int(d.get("coins", 0))
	# JSON 里没有类型，读回来一律是 Array，要手动过一遍成 Array[String]
	unlocked = _to_str_array(d.get("unlocked", ["classic"]))
	if unlocked.is_empty():
		unlocked = ["classic"]
	current_arena = str(d.get("current_arena", "classic"))
	if not unlocked.has(current_arena):
		current_arena = unlocked[0]
	# ── 券 + 球拍皮肤 ──
	tickets_paddle = maxi(0, int(d.get("tickets_paddle", 0)))
	tickets_arena = maxi(0, int(d.get("tickets_arena", 0)))
	# ★ 无条件把两条初始款补回去：老档没有 skins 键，也不能让玩家因为
	#   版本更新就变成「没拍子」。补齐 + 去重，一步到位。
	skins = _to_str_array(d.get("skins", ["r_red", "w_wood"]))
	for s in ["r_red", "w_wood"]:
		if not skins.has(s):
			skins.append(s)
	skin_rubber = _valid_skin(str(d.get("skin_rubber", "r_red")), "rubber", "r_red")
	skin_wood = _valid_skin(str(d.get("skin_wood", "w_wood")), "wood", "w_wood")
	# 史诗槽可以是空串（= 不用特效拍面），所以 "" 要当成合法值放行
	var ep := str(d.get("skin_epic", ""))
	skin_epic = "" if ep.is_empty() else _valid_skin(ep, "epic", "")
	# ★ 装备了没拥有的皮肤（改档 / 版本回退 / 目录删条目）→ 退回默认款。
	#   不修的话拍子会变成「未定义颜色」，而不是报错，很难查。
	if not skins.has(skin_rubber):
		skin_rubber = "r_red"
	if not skins.has(skin_wood):
		skin_wood = "w_wood"
	if not skin_epic.is_empty() and not skins.has(skin_epic):
		skin_epic = ""
	draw_pity = clampi(int(d.get("draw_pity", 0)), 0, DRAW_PITY_EPIC)
	# ── 第三期：称号 / 应援色 / 呐喊 / 每日限购 ──
	titles = _to_str_array(d.get("titles", []))
	title_current = str(d.get("title_current", ""))
	# ★ 装备了没解锁的称号 → 卸下（和皮肤同样的兜底思路）
	if not title_current.is_empty() and not titles.has(title_current):
		title_current = ""
	supports = _to_str_array(d.get("supports", ["s_warm"]))
	if not supports.has("s_warm"):
		supports.append("s_warm")
	support_current = str(d.get("support_current", "s_warm"))
	if not supports.has(support_current):
		support_current = "s_warm"
	cheers = _to_str_array(d.get("cheers", ["c_youth"]))
	if not cheers.has("c_youth"):
		cheers.append("c_youth")
	cheer_current = str(d.get("cheer_current", "c_youth"))
	if not cheers.has(cheer_current):
		cheer_current = "c_youth"
	var dl = d.get("deal", {})
	deal = dl if dl is Dictionary else {}
	# 开关读档：老档没有这些键 → 取默认值（保持改动前的行为，不会静默静音）
	cheer_on = bool(d.get("cheer_on", true))
	concede_on = bool(d.get("concede_on", true))
	# ★ 人群底噪默认关：老档本来就没有底噪（enable_ambience 写死 false），
	#   所以这里不能用 true，否则升级后会自动开始放背景噪音。
	crowd_on = bool(d.get("crowd_on", false))

	var st: Dictionary = d.get("settings", {})
	for k: String in settings.keys():
		settings[k] = clampf(float(st.get(k, settings[k])), 0.0, 1.0)

	var ss: Dictionary = d.get("stats", {})
	for k: String in stats.keys():
		stats[k] = int(ss.get(k, 0))
	# 日期单独取 —— stats 那一轮的 int() 会把它变成 0，见 rally_day 的声明处
	rally_day = str(d.get("rally_day", ""))

	claimed = _to_str_array(d.get("claimed", []))
	games_played = int(d.get("games_played", 0))
	difficulty = clampi(int(d.get("difficulty", 1)), 0, 4)
	doubles = bool(d.get("doubles", false))
	partner_ai = bool(d.get("partner_ai", false))
	var tt: Variant = d.get("tournament", {})
	tournament = _normalize_tournament(tt) if tt is Dictionary else {}

	# ── 排位。老档案没有这些键 → get 的默认值兜底，等价于「新号」。 ──
	rank_points = maxi(int(d.get("rank_points", 0)), 0)
	rank_streak = maxi(int(d.get("rank_streak", 0)), 0)
	rank_lose_streak = maxi(int(d.get("rank_lose_streak", 0)), 0)
	rank_shield_floor = int(d.get("rank_shield_floor", -1))
	rank_season = str(d.get("rank_season", ""))
	rank_season_peak = maxi(int(d.get("rank_season_peak", rank_points)), 0)
	# ranked 是「本局模式」不是存档字段，读档时一律清掉 ——
	# 不然上次退出时正好在打排位，这次一开局就莫名其妙进了排位。
	ranked = false
	# ★ tour_entry 同理，而且是同一个道理换来的：赛事场次一旦被留下，
	#   读档后从「开始比赛」进去会被劫持，菜单难度作废。
	tour_entry = false

	# ── 每日 / 每周。老档案没有这两个键 → 空字典，下次 daily_ensure() 会建。 ──
	# ★ 不在这里调 daily_ensure()：_ready 里调更合适（那时 stats 已经读完），
	#   而且 _from_dict 里调会触发 save_profile 再写一次盘。
	var dd: Variant = d.get("daily", {})
	daily = _normalize_daily(dd) if dd is Dictionary else {}
	var ww: Variant = d.get("weekly", {})
	weekly = _normalize_weekly(ww) if ww is Dictionary else {}


## ★ JSON 里没有 int —— 读回来的数字**全是 float**。
##
## 这会让「按 id 查」这类操作静默失灵：`[6.0, 8.0, 19.0, 29.0].has(11)` 是 false，
## 因为 Variant 的哈希按类型分，int 11 和 float 11.0 不是同一个键
## （`int(id) == pid` 这种数值比较却成立 —— 所以症状是「有的地方对、有的地方莫名其妙不对」）。
## 实际的坑：联赛面板靠 `groups[g].has(pid)` 定位玩家在第几组，读档之后恒为 -1，
## 「我的小组」整块不渲染。
##
## 赛程是长跑，每届都会经过读档这条路，所以在入口统一把 id / 局数这类字段转回 int，
## 而不是在每个使用点各写一遍 int()。
func _normalize_tournament(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	var out := raw.duplicate(true)
	out["seed"] = int(out.get("seed", 0))
	out["group_round"] = int(out.get("group_round", 0))
	out["place"] = int(out.get("place", 0))
	out["out"] = bool(out.get("out", false))
	out["stage"] = str(out.get("stage", "group"))

	var ents: Array = []
	for e in out.get("entrants", []):
		var ed: Dictionary = e
		ents.append({
			"name": str(ed.get("name", "?")),
			"rating": float(ed.get("rating", 1000.0)),
			"player": bool(ed.get("player", false)),
		})
	out["entrants"] = ents

	var gs: Array = []
	for grp in out.get("groups", []):
		var g: Array = []
		for id in (grp as Array):
			g.append(int(id))
		gs.append(g)
	out["groups"] = gs

	var ms: Array = []
	for m in out.get("matches", []):
		var md: Dictionary = m
		var mm := md.duplicate()
		mm["a"] = int(md.get("a", -1))
		mm["b"] = int(md.get("b", -1))
		mm["sa"] = int(md.get("sa", 0))
		mm["sb"] = int(md.get("sb", 0))
		mm["round"] = int(md.get("round", -1))
		mm["group"] = int(md.get("group", -1))
		mm["done"] = bool(md.get("done", false))
		if md.has("winner"):
			mm["winner"] = int(md["winner"])
		ms.append(mm)
	out["matches"] = ms
	return out


func set_difficulty(d: int) -> void:
	difficulty = clampi(d, 0, 4)
	save_profile()


func difficulty_name() -> String:
	match difficulty:
		0: return "简单"
		2: return "困难"
		3: return "专家"
		4: return "大师"
		_: return "普通"


## 把选手评分折算成 5 档难度（0..4）。
##
## 评分的取值范围是 900~1300（tournament.gd 里 1300 - 400·i/31 铺满 32 人，
## 玩家默认 1020）。阈值按**等分人数**挑的，不是等分分数 ——
## 32 个人大致 5 / 6 / 6 / 7 / 8 分到五档，越往后档人越多，
## 于是「打到决赛才遇到大师档」这件事自然成立。
static func rating_to_difficulty(rating: float) -> int:
	if rating >= 1240.0:
		return 4
	if rating >= 1160.0:
		return 3
	if rating >= 1080.0:
		return 2
	if rating >= 990.0:
		return 1
	return 0


func _to_str_array(v: Variant) -> Array[String]:
	var out: Array[String] = []
	if v is Array:
		for e: Variant in v:
			out.append(str(e))
	return out


func load_profile() -> void:
	if not FileAccess.file_exists(PROFILE_PATH):
		save_profile()
		return
	var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		_from_dict(parsed as Dictionary)


func save_profile() -> void:
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_to_dict(), "  "))
	f.close()
	profile_changed.emit()


func reset_all() -> void:
	coins = 0
	unlocked = ["classic"]
	current_arena = "classic"
	# 券与皮肤一起清。★ 皮肤要清回「只有两条初始款」——留着一堆已解锁的
	# 皮肤等于没重置，而金币已经归零，玩家看着一堆买不起的东西只会难受。
	tickets_paddle = 0
	tickets_arena = 0
	skins = ["r_red", "w_wood"]
	skin_rubber = "r_red"
	skin_wood = "w_wood"
	skin_epic = ""
	draw_pity = 0
	# ── 第三期 ──
	titles = []
	title_current = ""
	supports = ["s_warm"]
	support_current = "s_warm"
	cheers = ["c_youth"]
	cheer_current = "c_youth"
	deal = {}
	# 开关一并复位（音量值留在 settings 里由下面统一处理）
	cheer_on = true
	concede_on = true
	crowd_on = false
	claimed = []
	games_played = 0
	for k: String in stats.keys():
		stats[k] = 0
	# 排位也一起清 —— 重置面板上写的是「清空全部进度」，
	# 留着段位就等于「重置了但没完全重置」。
	rank_points = 0
	rank_streak = 0
	rank_lose_streak = 0
	rank_shield_floor = -1
	rank_season = ""
	rank_season_peak = 0
	ranked = false
	# ★ 联赛（方案 A）也一起清。★ 之前只清了排位、漏了整届赛程 ——
	#   面板上写的是「清空全部进度」，结果重置之后联赛按钮还亮着
	#   「进行中 小组赛」、赛程表还在，那不是重置，是重置了一半。
	#   走 abandon_tournament() 是为了三处状态（赛程/局分/进场意图）一处都不漏，
	#   但它自己会 save_profile + emit，这里后面统一 save，重复写无害。
	abandon_tournament()
	tour_entry = false
	# 每日 / 每周一起清。★ 不清的话「重置」之后今天的任务还挂着昨天的进度，
	#   玩家会以为是 bug。清成空字典即可，daily_ensure() 会重新抽。
	daily = {}
	weekly = {}
	save_profile()
	coins_changed.emit(coins)
	arena_changed.emit(current_arena)


# ───────────── 金币 ─────────────
func add_coins(n: int) -> void:
	if n == 0:
		return
	coins = maxi(0, coins + n)
	save_profile()
	coins_changed.emit(coins)


func can_afford(n: int) -> bool:
	return coins >= n


func spend_coins(n: int) -> bool:
	if not can_afford(n):
		return false
	coins -= n
	save_profile()
	coins_changed.emit(coins)
	return true


# ───────────── 场馆 ─────────────
func get_arena(id: String) -> Dictionary:
	for a: Dictionary in ARENAS:
		if str(a["id"]) == id:
			return a
	return ARENAS[0]


func is_unlocked(id: String) -> bool:
	return unlocked.has(id)


## 买下并自动切换过去。已解锁时只切换，不再扣钱。
func buy_arena(id: String) -> bool:
	var a := get_arena(id)
	if is_unlocked(id):
		set_arena(id)
		return true
	if not spend_coins(int(a["price"])):
		return false
	unlocked.append(id)
	set_arena(id)
	save_profile()
	return true


func set_arena(id: String) -> void:
	if not is_unlocked(id):
		return
	current_arena = id
	save_profile()
	arena_changed.emit(id)


func current_theme() -> Dictionary:
	var a := get_arena(current_arena)
	return a.get("theme", {})


# ───────────── 球拍皮肤 ─────────────
## 找不到 / slot 对不上就退回 fallback。★ 读档时必须过这一道：
## 目录里删过条目、或者存档被手改过，未校验的 id 不会报错，
## 只会让 `skin_by_id()` 返回空字典 → 拍子变成「未定义颜色」。
func _valid_skin(id: String, slot: String, fallback: String) -> String:
	var s := skin_by_id(id)
	if s.is_empty() or str(s.get("slot", "")) != slot:
		return fallback
	return id


func skin_by_id(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for s: Dictionary in PADDLE_SKINS:
		if str(s["id"]) == id:
			return s
	return {}


func has_skin(id: String) -> bool:
	return skins.has(id)


## 装备到对应槽。已拥有的任意皮肤都能自由换，**换装不花钱** ——
## 买了还要再花钱换，玩家会觉得被二次收割。
func equip_skin(id: String) -> bool:
	if not has_skin(id):
		return false
	var s := skin_by_id(id)
	match str(s.get("slot", "")):
		"rubber":
			skin_rubber = id
		"wood":
			skin_wood = id
		"epic":
			# ★ 点已装备的史诗 = 摘下来（切回普通胶皮），不然没法回退
			skin_epic = "" if skin_epic == id else id
		_:
			return false
	save_profile()
	return true


func buy_skin(id: String) -> bool:
	if has_skin(id):
		return true
	var s := skin_by_id(id)
	if s.is_empty():
		return false
	if not spend_coins(int(s.get("price", 0))):
		return false
	skins.append(id)
	save_profile()
	equip_skin(id)
	return true


## 给 paddle_viewmodel 的一份「当前该怎么画」的快照。
## ★ 颜色在这里算好，不在视图层算 —— 视图层不该知道「epic 覆盖 rubber」这条规则。
func paddle_theme() -> Dictionary:
	var out := {
		"rubber": Color(0.600, 0.045, 0.055),
		"wood": Color(0.470, 0.290, 0.135),
		"glow": Color(0.0, 0.0, 0.0),
		"glow_speed": 1.0,
		"glow_on": false,
	}
	var r := skin_by_id(skin_rubber)
	if not r.is_empty() and r.has("rubber"):
		out["rubber"] = r["rubber"]
	var w := skin_by_id(skin_wood)
	if not w.is_empty() and w.has("wood"):
		out["wood"] = w["wood"]
	if not skin_epic.is_empty():
		var e := skin_by_id(skin_epic)
		if not e.is_empty() and skins.has(skin_epic):
			out["rubber"] = e.get("rubber", out["rubber"])
			out["glow"] = e.get("glow", Color(0.0, 0.0, 0.0))
			out["glow_speed"] = float(e.get("glow_speed", 1.0))
			out["glow_on"] = true
	return out


## 抽一次球拍外观。返回 {} 表示券不够。
##
## force_seed 是给无头探针用的：传非负数就按这个种子走，结果可复现；
## 不传就走真随机。**生产路径永远不传** —— 抽卡必须是真的不确定，
## 否则「不确定性奖励」那条设计意图就被自己架空了。
##
## 返回字典的字段：
##   id / name / slot / rarity  —— 抽到什么
##   dup: bool                  —— 是不是已有
##   coins: int                 —— 重复返还了多少（非重复为 0）
##   pity: bool                 —— 是不是保底出的史诗
##   left: int                  —— 还剩几张券
func draw_paddle_skin(force_seed: int = -1) -> Dictionary:
	if tickets_paddle < DRAW_COST_PADDLE:
		return {}
	tickets_paddle -= DRAW_COST_PADDLE

	var rng := RandomNumberGenerator.new()
	if force_seed >= 0:
		rng.seed = force_seed
	else:
		rng.randomize()

	var pity := draw_pity + 1 >= DRAW_PITY_EPIC
	var rarity := "epic" if pity else _roll_rarity(rng)
	var pool: Array[Dictionary] = []
	for s: Dictionary in PADDLE_SKINS:
		if str(s.get("rarity", "")) == rarity:
			pool.append(s)
	if pool.is_empty():
		# 目录被改坏时的兜底：退回普通档，绝不让玩家白扔 7 张券
		for s: Dictionary in PADDLE_SKINS:
			if str(s.get("rarity", "")) == "common":
				pool.append(s)
		rarity = "common"
	var pick: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	var pid := str(pick["id"])

	var dup := has_skin(pid)
	var back := 0
	if dup:
		back = int((DRAW_REFUND as Dictionary).get(rarity, 150))
		add_coins(back)
	else:
		skins.append(pid)
		# ★ 抽到新东西直接装上 —— 「抽完还要去装备」是多一步没意义的摩擦
		equip_skin(pid)

	if rarity == "epic":
		draw_pity = 0
	else:
		draw_pity += 1
	save_profile()

	return {
		"id": pid,
		"name": str(pick.get("name", "")),
		"slot": str(pick.get("slot", "")),
		"rarity": rarity,
		"dup": dup,
		"coins": back,
		"pity": pity and rarity == "epic",
		"left": tickets_paddle,
	}


## 先掷档位。DRAW_RARITY 从大到小排，取第一个「累计概率 ≥ 掷点」的。
func _roll_rarity(rng: RandomNumberGenerator) -> String:
	var r := rng.randf()
	var acc := 0.0
	for row: Array in DRAW_RARITY:
		acc += float(row[1])
		if r < acc:
			return str(row[0])
	return "common"


# ───────────── 场馆券 ─────────────
## 用一张场馆券直接兑一个场馆。★ 上限 ARENA_TICKET_MAX_PRICE：
## 券是「送你一个中档场馆」，不是「随便挑一个」，顶配三档必须自己攒钱买。
func use_arena_ticket(id: String) -> bool:
	if tickets_arena <= 0:
		return false
	var a := get_arena(id)
	if int(a.get("price", 0)) > ARENA_TICKET_MAX_PRICE:
		return false
	tickets_arena -= 1
	if not unlocked.has(id):
		unlocked.append(id)
	current_arena = id
	save_profile()
	arena_changed.emit(id)
	return true


# ───────────── 声音设置 ─────────────
## 音量键一律用小写。总线名是 "Master"/"SFX"/"Ambience"，而设置字典的键是
## "master"/"sfx"/"ambience" —— 两边直接混用会踩坑：apply_audio 曾拿总线名去查设置，
## 键对不上，Dictionary.get() 每次都返回默认值 1.0，三个滑杆全成了摆设。
func get_volume(bus: String) -> float:
	return clampf(float(settings.get(bus.to_lower(), 1.0)), 0.0, 1.0)


func set_volume(bus: String, v: float) -> void:
	var k := bus.to_lower()
	if not settings.has(k):
		return
	settings[k] = clampf(v, 0.0, 1.0)
	apply_audio()
	save_profile()
	settings_changed.emit()


# ───────────── 得分呐喊 / 失分奶龙笑 的开关与音量 ─────────────
## 这两条不是总线，而是**同一条 SFX 总线上的分项增益** ——
## 单独再开两条总线的话，「主音量 / 音效」两个滑杆就管不到它们了。
## pingpong_audio.gd 在播放前调 sfx_gain_db() 取增益叠到自己的 db 上。

func set_cheer_enabled(v: bool) -> void:
	cheer_on = v
	save_profile()
	settings_changed.emit()


func set_concede_enabled(v: bool) -> void:
	concede_on = v
	save_profile()
	settings_changed.emit()


## 背景人群底噪的开关。默认 false（用户要求只要玩法反馈音，不要背景噪音）。
## ★ 这个开关存在的意义：以前「现场氛围」滑杆和试听按钮都是**摆设**——
##   pingpong_audio 的 `enable_ambience` 写死 false，底噪永远不启动，
##   玩家拖滑杆 / 点试听都得不到任何反馈。现在这条链路是通的。
func set_crowd_enabled(v: bool) -> void:
	crowd_on = v
	save_profile()
	settings_changed.emit()


## 某一类音效的分项增益（dB）。关掉、或音量拖到 0 → 返回 -80（等于静音）。
##
## ★ 用和总线**同一条平方曲线**（见 apply_audio）：否则「滑杆 50%」在
##   主音量上听起来是一个响度、在呐喊上又是另一个，玩家会觉得两者对不上。
## ★ 返回 -80 而不是直接不播，是为了让 pingpong_audio 那边的逻辑保持
##   「一次 return」，不用在每个调用点分别判开关和判音量。
##
## ★ "crowd" 额外受 `crowd_on` 管：这个开关是**独立于 ambience 总线**的。
##   ambience 是「现场氛围」总闸（整条环境声总线），crowd 只管人群底噪这一条 ——
##   两层结构和主音量 / 击球音效一致，玩家能分别控制。
func sfx_gain_db(key: String) -> float:
	match key:
		"cheer":
			if not cheer_on:
				return -80.0
		"concede":
			if not concede_on:
				return -80.0
		"crowd":
			if not crowd_on:
				return -80.0
	var v := get_volume(key)
	return -80.0 if v <= 0.0001 else linear_to_db(v * v)


## 建出 SFX / Ambience 两条子总线。幂等，可以反复调。
## 默认总线路由里只有 Master，所以这一步必须显式做 —— 否则设置面板上
## 「音效」「现场氛围」两个滑杆写了值也听不出区别。
func ensure_audio_buses() -> void:
	for bus_name: String in [BUS_SFX, BUS_AMBIENCE]:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		# 送给 Master，这样「主音量」滑杆仍然是总闸
		AudioServer.set_bus_send(idx, BUS_MASTER)


## 把 0~1 的线性音量写进 AudioServer。
## 纯线性映射到分贝会让人声/音效在小音量区掉得太快，
## 所以这里用平方曲线：0.5 → -12 dB 左右，手感接近系统音量条。
func apply_audio() -> void:
	ensure_audio_buses()
	for bus_name: String in [BUS_MASTER, BUS_SFX, BUS_AMBIENCE]:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0:
			continue
		var v := get_volume(bus_name)
		var db := -80.0 if v <= 0.0001 else linear_to_db(v * v)
		AudioServer.set_bus_volume_db(idx, db)
		AudioServer.set_bus_mute(idx, v <= 0.0001)


# ───────────── 球拍 / 视角灵敏度 ─────────────
## 用户要的「拍移动灵敏度下降，同时提供灵敏度设置」。
##
## 球拍是挂在相机下的子节点，鼠标一动相机转、拍子跟着走 ——
## 所以这里存的就是「瞄准手感」这一个总闸，改它同时改鼠标转头和 ←/→ 转头。
##
## 为什么不直接存 0.0025 这种原始数值：设置字典读档时会被统一 clamp 到
## 0~1（见 load_profile 那段循环），存绝对灵敏度会被夹掉。所以存归一化值，
## 运行时映射成「相对原始设计值的倍率」。
##   0.0 → ×0.20（很稳，适合慢慢瞄）
##   0.25 → ×0.55（默认：比原来慢将近一半 = 用户要的「灵敏度下降」）
##   1.0 → ×1.60（比原来还快，给习惯甩鼠标的人留上限）
const SENS_MIN_MULT := 0.20
const SENS_MAX_MULT := 1.60
const SENS_DEFAULT := 0.25


func get_sens() -> float:
	return clampf(float(settings.get("sens", SENS_DEFAULT)), 0.0, 1.0)


func set_sens(v: float) -> void:
	settings["sens"] = clampf(v, 0.0, 1.0)
	save_profile()
	settings_changed.emit()


## 归一化值 → 相对基准的倍率。camera_controller 每帧读它。
func look_speed_mult() -> float:
	return lerpf(SENS_MIN_MULT, SENS_MAX_MULT, get_sens())


# ───────────── 统计与任务 ─────────────
func bump(key: String, amount: int = 1) -> void:
	if not stats.has(key):
		return
	stats[key] = int(stats[key]) + amount


func set_max(key: String, value: int) -> void:
	if not stats.has(key):
		return
	if value > int(stats[key]):
		stats[key] = value


## 记录一次对拉的连拍数，维护「今日最长」和「历史最长」。
##
## 返回 {today, all, today_new, all_new} —— 调用方（pingpong_game）据此决定
## 要不要在 HUD 上喊一条。判断和显示分开：单例只管数据，文案属于表现层。
##
## ★ 跨天判断放在这里，而不是靠定时器 / 启动时检查：单机没有「上线」这个事件，
##   玩家可能隔三天才开一次游戏，唯一可靠的触发点就是「真的要记一条纪录时」。
func note_rally(n: int) -> Dictionary:
	var today := Time.get_date_string_from_system()
	if rally_day != today:
		rally_day = today
		stats["rally_today"] = 0
	var t_before := int(stats.get("rally_today", 0))
	var a_before := int(stats.get("max_rally", 0))
	stats["rally_today"] = maxi(t_before, n)
	stats["max_rally"] = maxi(a_before, n)
	return {
		"today": int(stats["rally_today"]),
		"all": int(stats["max_rally"]),
		"today_new": int(stats["rally_today"]) > t_before,
		"all_new": int(stats["max_rally"]) > a_before,
	}


# ═════════════ 每日 / 每周任务（方案 B 第一期）═════════════
#
# ★ 三条工程纪律，改这里之前先读：
#   ① **跨天重置不能靠定时器**。单机没有「上线」事件，玩家可能隔三天才开一次游戏，
#      唯一可靠的触发点是「真的要读写每日数据时」。所以 `daily_ensure()`
#      必须在 **主菜单刷新** 和 **每局结算** 两处调，缺一不可。
#   ② **计数必须走「已上报数」去重**（见 pingpong_game._progress_stats 的写法）。
#      bump 不是幂等的，重复进结算会把「打完 3 局」记成 6 局。
#   ③ **维度键必须以 `_today` / `_week` 结尾**并存在 `daily.stats` / `weekly.stats` 里，
#      不能混进全局 `stats` —— 全局那个是历史累计，永远不会归零。
#
# ═════════════════════════════════════════════════════════

## 两个 "YYYY-MM-DD" 相差几天（b - a）。算打卡断没断用。
static func _day_gap(a: String, b: String) -> int:
	if a.length() < 10 or b.length() < 10:
		return 0
	var ta := Time.get_unix_time_from_datetime_string(a.substr(0, 10) + "T00:00:00")
	var tb := Time.get_unix_time_from_datetime_string(b.substr(0, 10) + "T00:00:00")
	return int(round(float(tb - ta) / 86400.0))


static func _pool_of(bucket: String) -> Array:
	var out: Array = []
	for q: Dictionary in DAILY_QUESTS:
		if str(q.get("bucket", "")) == bucket:
			out.append(q)
	return out


## 按日期抽 3 条。
##
## ★ 用**日期的哈希做种子**而不是 `randi()`：同一天全世界抽到一样的组合，
##   可复现、可调试，玩家改系统时钟也不会来回跳。
## ★ 三条各从不同桶抽（A 出勤 / B 技术 / C 极限），否则会出现
##   「赢 1 局 + 赢 3 局 + 打完 3 局」这种三条其实是一件事的组合。
func _roll_daily(day: String) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = day.hash()
	var ids: Array[String] = []
	# 新手保护：还没打过 3 局就只给出勤类，且互不相同
	if int(stats.get("matches_played", 0)) < DAILY_GREEN_MATCHES:
		var pool: Array = _pool_of("A")
		while ids.size() < 3 and not pool.is_empty():
			var i := rng.randi() % pool.size()
			ids.append(str((pool[i] as Dictionary)["id"]))
			pool.remove_at(i)
		return ids
	for b: String in ["A", "B", "C"]:
		var pool: Array = _pool_of(b)
		if pool.is_empty():
			continue
		ids.append(str((pool[rng.randi() % pool.size()] as Dictionary)["id"]))
	return ids


## 连续天数 → 金币倍率。档位从大到小取第一个满足的。
static func _streak_mult(streak: int) -> float:
	for t: Array in DAILY_STREAK_TIERS:
		if streak >= int(t[0]):
			return float(t[1])
	return 1.0


## 建立 / 跨天重置「今日任务」。**幂等**，可以随便调。
func daily_ensure() -> void:
	var today := Time.get_date_string_from_system()
	if str(daily.get("day", "")) == today:
		weekly_ensure()
		return
	var streak := int(daily.get("streak", 0))
	var best := int(daily.get("best", 0))
	var day := str(daily.get("day", ""))
	if not day.is_empty():
		# gap = 今天 - 上次活跃那天
		#   gap 1 → 昨天玩过，正常；gap 2 → 漏 1 天，**冻结**（什么都不做）
		#   gap 3 → 漏 2 天，-1；gap n → -(n-2)
		# ★ 永远不清零，见 DAILY_FREEZE_GAP 的注释
		var gap := _day_gap(day, today)
		if gap >= DAILY_FREEZE_GAP + 1:
			streak = maxi(streak - (gap - DAILY_FREEZE_GAP), 0)
	daily = {
		"day": today,
		"ids": _roll_daily(today),
		"stats": {},
		"claimed": [],
		"all": false,
		"streak": streak,
		"last": str(daily.get("last", "")),
		"best": maxi(best, streak),
		"mult": _streak_mult(streak),
	}
	weekly_ensure()
	save_profile()


func weekly_ensure() -> void:
	var k := season_key()
	if str(weekly.get("key", "")) == k:
		return
	weekly = {"key": k, "stats": {}, "claimed": [], "all": false}


## 今日计数 +n。
## ★ 调用方必须先 `daily_ensure()`，否则跨天之后会把昨天的数接着往上加。
func daily_note(key: String, n: int) -> void:
	if n <= 0:
		return
	var s: Dictionary = daily.get("stats", {})
	s[key] = int(s.get(key, 0)) + n
	daily["stats"] = s


## 今日计数取 max（「今天打出一次 8 连得分」这类**极值**维度用这个，不是 daily_note）。
func daily_max(key: String, v: int) -> void:
	var s: Dictionary = daily.get("stats", {})
	if v > int(s.get(key, 0)):
		s[key] = v
		daily["stats"] = s


func weekly_note(key: String, n: int) -> void:
	if n <= 0:
		return
	var s: Dictionary = weekly.get("stats", {})
	s[key] = int(s.get(key, 0)) + n
	weekly["stats"] = s


func weekly_max(key: String, v: int) -> void:
	var s: Dictionary = weekly.get("stats", {})
	if v > int(s.get(key, 0)):
		s[key] = v
		weekly["stats"] = s


func daily_quest_by_id(id: String) -> Dictionary:
	for q: Dictionary in DAILY_QUESTS:
		if str(q["id"]) == id:
			return q
	return {}


func daily_ids() -> Array:
	return daily.get("ids", []) as Array


func daily_progress(q: Dictionary) -> int:
	if q.is_empty():
		return 0
	return int((daily.get("stats", {}) as Dictionary).get(str(q["stat"]), 0))


func daily_goal(q: Dictionary) -> int:
	return maxi(1, int(q.get("goal", 1)))


func daily_complete(q: Dictionary) -> bool:
	return not q.is_empty() and daily_progress(q) >= daily_goal(q)


func daily_claimed(q: Dictionary) -> bool:
	return (daily.get("claimed", []) as Array).has(str(q.get("id", "")))


func daily_can_claim(q: Dictionary) -> bool:
	return daily_complete(q) and not daily_claimed(q)


## 领一条。返回**实际到账**的金币（已乘当天倍率）。
func daily_claim(q: Dictionary) -> int:
	if not daily_can_claim(q):
		return 0
	(daily.get("claimed", []) as Array).append(str(q["id"]))
	var r := int(round(float(int(q["reward"])) * float(daily.get("mult", 1.0))))
	add_coins(r)
	save_profile()
	return r


## 今天这 3 条是不是全完成了（只看完成，不看领没领）。
func daily_all_clear() -> bool:
	var ids := daily_ids()
	if ids.is_empty():
		return false
	for idv in ids:
		if not daily_complete(daily_quest_by_id(str(idv))):
			return false
	return true


## 领「全清奖励」—— 这是唯一会把连续天数 +1 的地方。
func daily_claim_all() -> int:
	if bool(daily.get("all", false)) or not daily_all_clear():
		return 0
	daily["all"] = true
	daily["last"] = str(daily.get("day", ""))
	var s := int(daily.get("streak", 0)) + 1
	daily["streak"] = s
	daily["best"] = maxi(int(daily.get("best", 0)), s)
	var r := int(round(float(DAILY_ALL_REWARD) * float(daily.get("mult", 1.0))))
	add_coins(r)
	# ★ 券是「每日 3/3」的真正的理由。7 张抽一次 → 一周全清正好抽一次，
	#   这个节奏和「每周任务」是同一批人，不会互相挤占。
	tickets_paddle += 1
	save_profile()
	return r


func daily_claimable_count() -> int:
	var n := 0
	for idv in daily_ids():
		if daily_can_claim(daily_quest_by_id(str(idv))):
			n += 1
	if daily_all_clear() and not bool(daily.get("all", false)):
		n += 1
	return n


## 主菜单 / 任务面板用的一份摘要。
func daily_summary() -> Dictionary:
	var ids := daily_ids()
	var done := 0
	for idv in ids:
		if daily_complete(daily_quest_by_id(str(idv))):
			done += 1
	return {
		"day": str(daily.get("day", "")),
		"total": ids.size(),
		"done": done,
		"mult": float(daily.get("mult", 1.0)),
		"streak": int(daily.get("streak", 0)),
		"best": int(daily.get("best", 0)),
		"all": bool(daily.get("all", false)),
		"all_clear": daily_all_clear(),
		"all_reward": DAILY_ALL_REWARD,
	}


## 结算面板上的「临近完成」提示。
##
## ★★★ 这是整期里**转化率最高的一条**：玩家刚打完一局，球拍还在手上、
## 手感正热，此刻告诉他「差一点点」最容易被推一把再来一局。
## 只挂在菜单里没用 —— 玩家在菜单里是不会为了 90 金币专门开一局的。
##
## 返回空串表示没什么好说的。
func daily_hint() -> String:
	if bool(daily.get("all", false)):
		return ""
	var best_q := {}
	var best_left := 0
	for idv in daily_ids():
		var q := daily_quest_by_id(str(idv))
		if q.is_empty() or daily_claimed(q):
			continue
		var left := daily_goal(q) - daily_progress(q)
		if left <= 0:
			continue
		if best_q.is_empty() or left < best_left:
			best_q = q
			best_left = left
	if best_q.is_empty():
		return ""
	var r := int(round(float(int(best_q["reward"])) * float(daily.get("mult", 1.0))))
	return "今日任务「%s」还差 %d（+%d 金币）" % [str(best_q["name"]), best_left, r]


# ── 每周（同一套逻辑，固定 3 条不抽签）──
func weekly_progress(q: Dictionary) -> int:
	if q.is_empty():
		return 0
	return int((weekly.get("stats", {}) as Dictionary).get(str(q["stat"]), 0))


func weekly_goal(q: Dictionary) -> int:
	return maxi(1, int(q.get("goal", 1)))


func weekly_complete(q: Dictionary) -> bool:
	return not q.is_empty() and weekly_progress(q) >= weekly_goal(q)


func weekly_claimed(q: Dictionary) -> bool:
	return (weekly.get("claimed", []) as Array).has(str(q.get("id", "")))


func weekly_can_claim(q: Dictionary) -> bool:
	return weekly_complete(q) and not weekly_claimed(q)


func weekly_claim(q: Dictionary) -> int:
	if not weekly_can_claim(q):
		return 0
	(weekly.get("claimed", []) as Array).append(str(q["id"]))
	var r := int(q["reward"])
	add_coins(r)
	save_profile()
	return r


func weekly_all_clear() -> bool:
	for q: Dictionary in WEEKLY_QUESTS:
		if not weekly_complete(q):
			return false
	return true


func weekly_claim_all() -> int:
	if bool(weekly.get("all", false)) or not weekly_all_clear():
		return 0
	weekly["all"] = true
	add_coins(WEEKLY_ALL_REWARD)
	tickets_arena += 1
	save_profile()
	return WEEKLY_ALL_REWARD


func weekly_claimable_count() -> int:
	var n := 0
	for q: Dictionary in WEEKLY_QUESTS:
		if weekly_can_claim(q):
			n += 1
	if weekly_all_clear() and not bool(weekly.get("all", false)):
		n += 1
	return n


## 存档读回来 / 老档升级时规整一遍。
##
## ★ **JSON 里没有 int**：读回来 `streak` 是 float、`ids` 是 Array[Variant]。
##   `claimed.has("d_win")` 对 String 没问题，但 `int()` 必须显式做，
##   否则 `streak = 3.0` 一进 `int()` 循环就变成字符串 "3.0" 那套老毛病。
func _normalize_daily(d: Dictionary) -> Dictionary:
	if d.is_empty():
		return {}
	var out := d.duplicate(true)
	out["day"] = str(out.get("day", ""))
	out["last"] = str(out.get("last", ""))
	out["all"] = bool(out.get("all", false))
	for k in ["streak", "best"]:
		out[k] = int(out.get(k, 0))
	out["mult"] = float(out.get("mult", _streak_mult(int(out.get("streak", 0)))))
	var ids: Array[String] = []
	for idv in (out.get("ids", []) as Array):
		ids.append(str(idv))
	out["ids"] = ids
	var claimed: Array[String] = []
	for cv in (out.get("claimed", []) as Array):
		claimed.append(str(cv))
	out["claimed"] = claimed
	var st: Dictionary = out.get("stats", {}) as Dictionary
	var st2: Dictionary = {}
	for sk in st.keys():
		st2[str(sk)] = int(st[sk])
	out["stats"] = st2
	return out


func _normalize_weekly(w: Dictionary) -> Dictionary:
	if w.is_empty():
		return {}
	var out := w.duplicate(true)
	out["key"] = str(out.get("key", ""))
	out["all"] = bool(out.get("all", false))
	var claimed: Array[String] = []
	for cv in (out.get("claimed", []) as Array):
		claimed.append(str(cv))
	out["claimed"] = claimed
	var st: Dictionary = out.get("stats", {}) as Dictionary
	var st2: Dictionary = {}
	for sk in st.keys():
		st2[str(sk)] = int(st[sk])
	out["stats"] = st2
	return out


func title_progress(t: Dictionary) -> int:
	return int(stats.get(str(t["stat"]), 0))


func title_completed(t: Dictionary) -> bool:
	return title_progress(t) >= int(t["goal"])


## 重新扫一遍所有称号，把刚达成的解锁出来。
## ★ 返回**本次新解锁**的 id —— 调用方（主菜单）拿它弹提示。
##   重复调用不会重复解锁（titles 里已经记着），所以可以放心每次刷新都调。
func title_refresh() -> Array[String]:
	var got: Array[String] = []
	for t: Dictionary in TITLES:
		var tid := str(t["id"])
		if titles.has(tid):
			continue
		if title_completed(t):
			titles.append(tid)
			got.append(tid)
	if title_current.is_empty() and not titles.is_empty():
		title_current = titles[0]
	return got


## ★ 再点一次已装备的 = 卸下（和特效拍面同一个交互逻辑）。
func title_equip(id: String) -> bool:
	if not titles.has(id):
		return false
	title_current = "" if title_current == id else id
	save_profile()
	return true


func title_of(id: String) -> Dictionary:
	for t: Dictionary in TITLES:
		if str(t["id"]) == id:
			return t
	return {}


func title_name() -> String:
	return str(title_of(title_current).get("name", ""))


func support_of(id: String) -> Dictionary:
	for s: Dictionary in SUPPORT_COLORS:
		if str(s["id"]) == id:
			return s
	return {}


func support_color() -> Color:
	var s := support_of(support_current)
	return (s.get("color", Color(1.0, 0.55, 0.15))) as Color


func support_buy(id: String) -> bool:
	if supports.has(id):
		return false
	var s := support_of(id)
	if s.is_empty():
		return false
	var price := int(s.get("price", 0))
	if coins < price:
		return false
	coins -= price
	supports.append(id)
	support_current = id
	save_profile()
	return true


func support_equip(id: String) -> bool:
	if not supports.has(id):
		return false
	support_current = id
	save_profile()
	return true


func cheer_of(id: String) -> Dictionary:
	for c: Dictionary in CHEER_SKINS:
		if str(c["id"]) == id:
			return c
	return {}


## 当前呐喊配置。查不到就退回初始款 —— 老档没有 cheers 键也不会崩。
func cheer_skin() -> Dictionary:
	var c := cheer_of(cheer_current)
	return c if not c.is_empty() else cheer_of("c_youth")


func cheer_buy(id: String) -> bool:
	if cheers.has(id):
		return false
	var c := cheer_of(id)
	if c.is_empty():
		return false
	var price := int(c.get("price", 0))
	if coins < price:
		return false
	coins -= price
	cheers.append(id)
	cheer_current = id
	save_profile()
	return true


func cheer_equip(id: String) -> bool:
	if not cheers.has(id):
		return false
	cheer_current = id
	save_profile()
	return true


## 限购候选池：所有「还没拥有、且原价 ≥ DEAL_MIN_PRICE」的外观。
func _deal_pool() -> Array:
	var pool: Array = []
	for a: Dictionary in ARENAS:
		if int(a.get("price", 0)) >= DEAL_MIN_PRICE and not unlocked.has(str(a["id"])):
			pool.append({"kind": "arena", "id": str(a["id"]),
				"name": str(a["name"]), "orig": int(a["price"])})
	for s: Dictionary in PADDLE_SKINS:
		if int(s.get("price", 0)) >= DEAL_MIN_PRICE and not skins.has(str(s["id"])):
			pool.append({"kind": "skin", "id": str(s["id"]),
				"name": str(s["name"]), "orig": int(s["price"])})
	for s: Dictionary in SUPPORT_COLORS:
		if int(s.get("price", 0)) >= DEAL_MIN_PRICE and not supports.has(str(s["id"])):
			pool.append({"kind": "support", "id": str(s["id"]),
				"name": str(s["name"]), "orig": int(s["price"])})
	for c: Dictionary in CHEER_SKINS:
		if int(c.get("price", 0)) >= DEAL_MIN_PRICE and not cheers.has(str(c["id"])):
			pool.append({"kind": "cheer", "id": str(c["id"]),
				"name": str(c["name"]), "orig": int(c["price"])})
	return pool


## 生成 / 取回今日限购。跨天自动换一件；同一天多次调用返回同一件。
func deal_ensure() -> Dictionary:
	var today := Time.get_date_string_from_system()
	if not deal.is_empty() and str(deal.get("day", "")) == today:
		return deal
	var pool := _deal_pool()
	if pool.is_empty():
		deal = {"day": today}
		return deal
	# ★ 用日期哈希选，不用 randf —— 同一天进出商店看到的必须是同一件，
	#   否则玩家「退出来再进」就能刷出别的折扣。
	var h := absi(today.hash()) + today.length()
	var pick: Dictionary = pool[h % pool.size()]
	var disc: float = DEAL_DISCOUNTS[(h / 7) % DEAL_DISCOUNTS.size()]
	deal = {
		"day": today, "kind": str(pick["kind"]), "id": str(pick["id"]),
		"name": str(pick["name"]), "orig": int(pick["orig"]),
		"price": int(round(float(int(pick["orig"])) * disc)), "bought": false,
	}
	return deal


## 买下今日限购。返回实际花掉的金币，-1 = 买不了（钱不够 / 已买过 / 已拥有）。
func deal_buy() -> int:
	var d := deal_ensure()
	if d.is_empty() or bool(d.get("bought", false)):
		return -1
	var price := int(d.get("price", 0))
	if coins < price:
		return -1
	var kind := str(d.get("kind", ""))
	var id := str(d.get("id", ""))
	match kind:
		"arena":
			if unlocked.has(id):
				return -1
			unlocked.append(id)
			current_arena = id
		"skin":
			if skins.has(id):
				return -1
			skins.append(id)
			equip_skin(id)
		"support":
			if supports.has(id):
				return -1
			supports.append(id)
			support_current = id
		"cheer":
			if cheers.has(id):
				return -1
			cheers.append(id)
			cheer_current = id
		_:
			return -1
	coins -= price
	deal["bought"] = true
	save_profile()
	return price


func quest_progress(q: Dictionary) -> int:
	return int(stats.get(str(q["stat"]), 0))


func quest_goal(q: Dictionary) -> int:
	return maxi(1, int(q["goal"]))


func is_quest_complete(q: Dictionary) -> bool:
	return quest_progress(q) >= quest_goal(q)


func is_quest_claimed(q: Dictionary) -> bool:
	return claimed.has(str(q["id"]))


## 可领取 = 达标了但还没领
func can_claim(q: Dictionary) -> bool:
	return is_quest_complete(q) and not is_quest_claimed(q)


func claim_quest(q: Dictionary) -> int:
	if not can_claim(q):
		return 0
	claimed.append(str(q["id"]))
	var r := int(q["reward"])
	add_coins(r)
	return r


func claimable_count() -> int:
	var n := 0
	for q: Dictionary in QUESTS:
		if can_claim(q):
			n += 1
	return n


# ───────────── 存档槽 ─────────────
func _slot_path(i: int) -> String:
	return "user://slot_%d.json" % (i + 1)


## 给存档面板用的一行摘要。空槽返回 {"empty": true}
func slot_info(i: int) -> Dictionary:
	var p := _slot_path(i)
	if not FileAccess.file_exists(p):
		return {"empty": true, "index": i}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {"empty": true, "index": i}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return {"empty": true, "index": i}
	var d := parsed as Dictionary
	return {
		"empty": false, "index": i,
		"time": str(d.get("saved_at", "")),
		"coins": int(d.get("coins", 0)),
		"points": int((d.get("stats", {}) as Dictionary).get("points", 0)),
		"won": int((d.get("stats", {}) as Dictionary).get("matches_won", 0)),
		"arena": get_arena(str(d.get("current_arena", "classic")))["name"],
		"rank": rank_name_of(int(d.get("rank_points", 0))),
	}


func has_slot(i: int) -> bool:
	return not bool(slot_info(i)["empty"])


func save_slot(i: int) -> void:
	var d := _to_dict()
	d["saved_at"] = Time.get_datetime_string_from_system(false, true)
	var f := FileAccess.open(_slot_path(i), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(d, "  "))
	f.close()


## 读档：把档案整个替换成槽里的内容，并立刻落盘
func load_slot(i: int) -> bool:
	var p := _slot_path(i)
	if not FileAccess.file_exists(p):
		return false
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return false
	_from_dict(parsed as Dictionary)
	save_profile()
	coins_changed.emit(coins)
	arena_changed.emit(current_arena)
	settings_changed.emit()
	return true


func delete_slot(i: int) -> void:
	var p := _slot_path(i)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


# ───────────── 比赛模式（32 人赛事）─────────────
## 赛程推进、对手模拟、名次统计全部在 tournament.gd（纯函数）；
## 这里只管「把那份字典存进档案」+ 发奖励 + 广播信号。
##
## 为什么赛程要落盘：一届赛事 = 小组赛 3 场 + 淘汰赛最多 4 场，是长跑。
## 中途关页面 / 退到主菜单再回来，赛程必须还在。
func tournament_active() -> bool:
	return (not tournament.is_empty()) \
		and str(tournament.get("stage", "done")) != "done"


## 开一届新赛事。会覆盖掉正在打的那一届（UI 负责先问一句）。
func new_tournament(player_name: String = "你", player_rating: float = 1020.0) -> void:
	# 种子带上「打过几届」，保证同一毫秒内重开也抽不到同一份签。
	# （原来乘的是 games_played，但那个字段从来没被写过 —— 恒等于 0，
	#   注释说的事其实没发生。换成真正会变的 tournaments_played。）
	var sd := int(Time.get_unix_time_from_system() * 1000.0) \
		+ int(stats.get("tournaments_played", 0)) * 7919
	tournament = Tournament.create(sd, player_name, player_rating)
	save_profile()
	tournament_changed.emit()


## 进游戏时调一次：这一场是不是赛事场次？顺便把局分清零（如果是新的一场）。
## 返回 {} = 自由对战，照菜单难度打。
##
## ★★ `tour_entry` 才是「要不要进赛事」的判据，**不是「档案里有没有赛事」**。
##   原来只判后者，于是「报名了一届联赛 → 从开始比赛进去」也被劫持成赛事场次，
##   菜单里选的难度作废（用户 2026-10-03 报的「开始游戏那里选难度无用」）。
##   只有联赛面板里点了「继续参赛」才置位；进自由对战/排位时必须清掉。
##
## 「同一场」的判据是 stage + 对阵双方 id：小组赛打 3 轮、每轮对手不同，
## 淘汰赛每轮也换人，所以这个 key 一变就说明是新的一场 —— 不用额外维护
## 「打完了要记得清零」这类容易漏掉的收尾动作。
func tour_begin() -> Dictionary:
	if not tour_entry:
		# 自由对战 / 排位场次：清 key，下次真的进赛事时不会被上一场的局分接上。
		tour_key = ""
		return {}
	var opp := tournament_opponent()
	if opp.is_empty():
		tour_key = ""
		return {}
	var nm := tournament_next_match()
	var key := "%s:%d-%d" % [str(opp["stage"]), int(nm.get("a", -1)), int(nm.get("b", -1))]
	if key != tour_key:
		tour_key = key
		tour_won = 0
		tour_lost = 0
	return opp


## 记一局的胜负。返回「这一场打完了吗」（有人先拿到 3 局）。
func tour_record_game(player_won: bool) -> bool:
	if player_won:
		tour_won += 1
	else:
		tour_lost += 1
	return tour_won >= Tournament.WIN_TARGET or tour_lost >= Tournament.WIN_TARGET


func tournament_next_match() -> Dictionary:
	if tournament.is_empty():
		return {}
	return Tournament.next_match(tournament)


## 进游戏前问一句「这一场打谁」。返回：
##   {"id", "name", "rating", "difficulty", "stage", "stage_name"}
## 不在赛事中 / 没有待打的比赛 → {}
##
## difficulty 是按对手评分折算的五档难度（0..4，见 rating_to_difficulty）。
## 这是把「评分」翻译成
## 游戏里那套球速/落点/容错的唯一一处 —— 评分本身只活在 tournament.gd。
func tournament_opponent() -> Dictionary:
	if not tournament_active():
		return {}
	var m := tournament_next_match()
	if m.is_empty():
		return {}
	var pid := Tournament.player_id(tournament)
	var opp := int(m["b"]) if int(m["a"]) == pid else int(m["a"])
	var rating := Tournament.rating_of(tournament, opp)
	var diff := rating_to_difficulty(rating)
	return {
		"id": opp,
		"name": Tournament.name_of(tournament, opp),
		"rating": rating,
		"difficulty": diff,
		"stage": str(tournament.get("stage", "group")),
		"stage_name": Tournament.stage_name(str(tournament.get("stage", "group"))),
	}


## 玩家打完自己那一场 BO5（5 局 3 胜，传局数）。返回摘要，含结算奖励。
func report_tournament_match(player_won: int, player_lost: int) -> Dictionary:
	if not tournament_active():
		return {}
	var res := Tournament.report_player(tournament, player_won, player_lost)
	if str(tournament.get("stage", "")) == "done":
		var place := int(tournament.get("place", 0))
		var prize := Tournament.prize_for_place(place)
		res["place"] = place
		res["prize"] = prize
		res["prize_label"] = Tournament.prize_label(place)
		bump("tournaments_played", 1)
		if place == 1:
			bump("tournaments_won", 1)
		var best := int(stats.get("best_place", 0))
		if place > 0 and (best == 0 or place < best):
			stats["best_place"] = place
		# add_coins 自己会 save_profile，所以放在最后
		add_coins(prize)
	res["stage_name"] = Tournament.stage_name(str(res.get("stage", "")))
	# 给结算面板补上「下一个对手是谁」—— reporter 只回了一份对阵 id，
	# UI 层不该再去翻赛程表。
	var nx := tournament_next_match()
	if not nx.is_empty():
		var pid := Tournament.player_id(tournament)
		var nid := int(nx["b"]) if int(nx["a"]) == pid else int(nx["a"])
		res["next_name"] = Tournament.name_of(tournament, nid)
		res["next_rating"] = int(Tournament.rating_of(tournament, nid))
		res["next_stage"] = Tournament.stage_name(str(nx.get("stage", "")))
	save_profile()
	tournament_changed.emit()
	return res


func abandon_tournament() -> void:
	tournament = {}
	tour_key = ""
	tour_won = 0
	tour_lost = 0
	# ★ 进场意图必须一起清。只清赛程不清它的话，「放弃本届赛事」之后
	#   从「开始比赛」进来仍然会走赛事分支 —— 而此时 tournament_opponent()
	#   返回空字典，看起来「没事」，实际是把难度判定让给了一个不存在的对手。
	tour_entry = false
	save_profile()
	tournament_changed.emit()


# ───────────── 排位赛（方案 B · 段位天梯）─────────────
## 设计目标：**无限可玩** —— 让 AI 永远刚好比你强一点点，于是「再打一局」
## 永远有意义。和赛事（有终点的 32 人淘汰赛）是两种互补的长期目标。
##
## 三根支柱（对应策划案「方案 B」的具体设计）：
##   ① 段位 = 隐藏分 + 分段名；赢加分、输扣分，**三连败以内有保底**；
##   ② 段位**直接映射 AI 参数** —— 这是排位最值钱的地方：不会出现
##      「打得太轻松」或「完全打不过」，难度永远贴着你的水平走；
##   ③ 连胜给金币加成，输一场清零 —— 把「手感正热」变成看得见的东西。
##
## 为什么存分数、不存段位字符串：分数 → 段位是一步除法，不需要查表，
## 也就不会出现「段位和分数对不上」这种脏状态。
const RANK_TIERS := ["青铜", "白银", "黄金", "铂金", "钻石", "大师", "王者"]
## 小级从低到高：Ⅲ → Ⅱ → Ⅰ（和棋类写法一致，Ⅲ 是最低的那个）
const RANK_DIVS := ["Ⅲ", "Ⅱ", "Ⅰ"]
const RANK_DIVS_PER_TIER := 3
## 每个小级 100 分。21 个小级 → 0~2100 分；配合「赢 +26 / 输 -18」，
## 大约 4 个胜场升一个小级、80 多个胜场上王者 —— 撑得住长期目标。
const RANK_STEP := 100
const RANK_MAX_DIV := 20

## 胜利基础分。
const RANK_WIN_BASE := 26
## 失败基础扣分。**故意比胜分小**：单机游戏不该让玩家越打越退，
## 26 : 18 意味着长期胜率只要超过 41% 就能缓慢上分。
const RANK_LOSS_BASE := 18
## 连胜对涨分的追加：第 3 连胜起，每多赢一场多加这么多，封顶 RANK_STREAK_BONUS_MAX。
## 于是 1/2 胜 = 26 分，3 胜 = 30、4 胜 = 34、5 胜 = 38，第 6 胜起吃满 42。
const RANK_STREAK_BONUS := 4
const RANK_STREAK_BONUS_MAX := 16
## 三连败以内不掉出当前小级（保底）。第 4 连败起保底失效，可以正常掉级。
const RANK_LOSS_SHIELD := 3
## 连胜到第几场开始给金币加成
const RANK_COIN_STREAK_FROM := 3
## 连胜金币倍率：3 连胜 ×1.2 / 4 连胜 ×1.4 / 5 连胜及以上 ×1.6
const RANK_COIN_STREAK_MULT := [1.2, 1.4, 1.6]
## 赛季结束后分数回落到 60%。不清零（那会让高段位玩家下赛季被新手打），
## 也不保留（那「赛季」就等于不存在）。
const RANK_SEASON_KEEP := 0.6

const MONTH_DAYS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

# ── 运行时状态 ──
## 排位隐藏分。0 = 青铜 Ⅲ（新号起点）。
var rank_points: int = 0
## 当前连胜（按场次）。赢了 +1、输了归零。
var rank_streak: int = 0
## 当前连败（按场次）。用来判保底还在不在。
var rank_lose_streak: int = 0
## 保底地板：连败刚开始时记下「当前小级的起点分」，前三连败不许跌破它。
## -1 = 当前没有保底。
var rank_shield_floor: int = -1
## 当前赛季标识（形如 "2026-S40"）。空字符串 = 还没建立过赛季。
var rank_season: String = ""
## 本赛季达到过的最高分 —— 赛季奖励按它发（不是按当前分，
## 否则玩家在赛季末掉分就等于白爬）。
var rank_season_peak: int = 0
## **本局是不是排位赛**。主菜单设、pingpong_game.apply_preferences 读。
## 放在单例上而不是场景里：场景重载（「再来一局」）之后必须还认得出来。
var ranked: bool = false


# ── 分数 ↔ 段位 ──
static func rank_div_of(points: int) -> int:
	return clampi(int(floor(float(maxi(points, 0)) / float(RANK_STEP))), 0, RANK_MAX_DIV)


static func rank_tier_of(points: int) -> int:
	return int(floor(float(rank_div_of(points)) / float(RANK_DIVS_PER_TIER)))


## 小级序号 → 「黄金 Ⅱ」这样的名字。
static func rank_div_label(div: int) -> String:
	var d := clampi(div, 0, RANK_MAX_DIV)
	var ti := int(floor(float(d) / float(RANK_DIVS_PER_TIER)))
	return "%s %s" % [RANK_TIERS[ti], RANK_DIVS[d - ti * RANK_DIVS_PER_TIER]]


static func rank_name_of(points: int) -> String:
	return rank_div_label(rank_div_of(points))


func rank_div() -> int:
	return rank_div_of(rank_points)


func rank_name() -> String:
	return rank_div_label(rank_div())


func rank_tier() -> int:
	return rank_tier_of(rank_points)


## 本小级内已经走了多少分（王者 Ⅰ 封顶后恒为 0，UI 据此显示「已到顶」）。
func rank_into_div() -> int:
	var d := rank_div()
	if d >= RANK_MAX_DIV:
		return 0
	return maxi(rank_points - d * RANK_STEP, 0)


## 本小级的**总分**（进度条的分母，UI 的 `UiKit.progress(into, span, …)` 用）。
##
## ★ 这个函数以前**根本不存在**，而 main_menu._panel_rank 在调它 ——
##   后果是点开「排位赛」面板直接抛
##   「Invalid call. Nonexistent function 'rank_div_span'」，
##   面板只建了一半（UI 报错了但界面不会提示，很容易被当成"排位面板加载慢"）。
##   GDScript 不会因为调用了不存在的方法在**解析期**报错（`Game` 是 autoload、
##   类型是 Node 而不是脚本类），所以编译全绿、运行才炸 —— 只能靠实跑面板发现。
##
## 封顶段（王者 Ⅰ）返回 0：那一段没有「下一小级」，进度条本来就该显示满。
func rank_div_span() -> int:
	var d := rank_div()
	if d >= RANK_MAX_DIV:
		return 0
	return RANK_STEP


func rank_next_name() -> String:
	var d := rank_div()
	if d >= RANK_MAX_DIV:
		return "已到顶"
	return rank_div_label(d + 1)


func rank_is_max() -> bool:
	return rank_div() >= RANK_MAX_DIV


## 本场赢了加多少分（读的是**更新后**的连胜，见 report_rank_match）。
func rank_win_delta() -> int:
	var extra := mini(maxi(rank_streak - 2, 0) * RANK_STREAK_BONUS, RANK_STREAK_BONUS_MAX)
	return RANK_WIN_BASE + extra


## 连胜带来的金币倍率。3 → 1.2 / 4 → 1.4 / 5+ → 1.6，否则 1.0。
##
## ★ 这个倍率乘在**整局全部金币**上（得分 + 连拍 + 赢局），不是只乘基础分 ——
##   连胜本来就是「一整套都打得顺」，只乘一份会显得小气。
func rank_coins_mult() -> float:
	if rank_streak < RANK_COIN_STREAK_FROM:
		return 1.0
	var i := mini(rank_streak - RANK_COIN_STREAK_FROM, RANK_COIN_STREAK_MULT.size() - 1)
	return float(RANK_COIN_STREAK_MULT[i])


## 段位 → 连续难度 t ∈ [0, 4]（0 = 简单 … 4 = 大师）。
##
## ★ 为什么是连续值而不是整数档：21 个小级映射到 5 个整数档的话，相邻
##   四五个小级的 AI 手感一模一样，「升了一级」根本感受不到；插值之后
##   每升一级球都真的快一点点、对手真的少失误一点。
## ★ 为什么是线性（4 × div / 20）：线性让「升一级 = 固定强度增幅」可预期，
##   玩家容易建立「我在稳步变强」的直觉。曲线（前松后紧之类）在这里
##   只会让玩家算不清自己在哪个位置。
func rank_difficulty_t() -> float:
	return 4.0 * float(rank_div()) / float(RANK_MAX_DIV)


# ── 赛季 ──
static func _day_of_year(y: int, m: int, d: int) -> int:
	var leap := (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
	var n := d
	for i in range(clampi(m - 1, 0, 11)):
		n += MONTH_DAYS[i]
	if leap and m > 2:
		n += 1
	return n


## 赛季标识 = 「年份 + 年内第几周」，例如 "2026-S40"。
##
## ★ 为什么不用严格 ISO 周（周一起算、跨年归属上一年第 52 周）：
##   单机游戏只需要一个「至少每周换一次、跨年不串桶」的标识。严格 ISO 周
##   要多写十几行跨年边界，收益为零 —— 玩家不会去核对「这周到底算第几周」，
##   他只关心「赛季换了、奖励发了」。
func season_key() -> String:
	var dt := Time.get_datetime_dict_from_system()
	var y := int(dt["year"])
	var doy := _day_of_year(y, int(dt["month"]), int(dt["day"]))
	return "%04d-S%02d" % [y, int(floor(float(doy - 1) / 7.0)) + 1]


## 赛季奖励：按「上赛季最高小级」发。
## 青铜（小级 0/1/2）不给 —— 没爬过山就没有战利品，
## 这也让「至少上白银」成为一个有意义的门槛。
static func rank_season_reward(div: int) -> int:
	return maxi(div - RANK_DIVS_PER_TIER + 1, 0) * 45


## 跨赛季结算。返回 {changed, ...}。
##
## ★ 幂等：rank_season 一写就相等了，所以主菜单每次刷新都调它是安全的，
##   不会重复发奖励。这也是为什么它不做定时器 / 不改用「登录时检查」——
##   单机没有「登录」这个事件，唯一可靠的触发点就是「要用到赛季数据时」。
func rank_ensure_season() -> Dictionary:
	var k := season_key()
	if rank_season == "":
		rank_season = k
		rank_season_peak = rank_points
		save_profile()
		return {"changed": false, "season": k, "first": true}
	if rank_season == k:
		return {"changed": false, "season": k}

	var old := rank_season
	var peak := rank_season_peak
	var peak_div := rank_div_of(peak)
	var reward := rank_season_reward(peak_div)
	var before := rank_points
	rank_season = k
	# 软重置：回落到 60%，再向下取整到小级边界 ——
	# 不取整的话会留下「黄金 Ⅰ 的 37 分」这种读了也不知道什么意义的数。
	rank_points = int(floor(float(before) * RANK_SEASON_KEEP / float(RANK_STEP))) * RANK_STEP
	rank_season_peak = rank_points
	rank_streak = 0
	rank_lose_streak = 0
	rank_shield_floor = -1
	if reward > 0:
		add_coins(reward)     # 内部会 save_profile
	else:
		save_profile()
	return {
		"changed": true, "old": old, "season": k,
		"peak_points": peak, "peak_div": peak_div,
		"peak_name": rank_div_label(peak_div),
		"reward": reward,
		"points_before": before, "points_after": rank_points,
		"name_before": rank_div_label(rank_div_of(before)),
		"name_after": rank_name(),
	}


## 记一场排位赛。
##
## ★ 调用时机很关键：必须在 _end_match **发金币之前**调 ——
##   连胜金币倍率要读刚刚更新过的 rank_streak。
##
## 返回一份完整的「本场变化」回执，UI 直接拿去渲染，不再自己算一遍
## （算两遍必然有一天两边不一样）。
func report_rank_match(won: bool) -> Dictionary:
	var before := rank_points
	var div_before := rank_div_of(before)
	var shielded := false
	var delta := 0

	if won:
		rank_streak += 1
		rank_lose_streak = 0
		rank_shield_floor = -1
		delta = rank_win_delta()
		rank_points = before + delta
	else:
		rank_lose_streak += 1
		rank_streak = 0
		delta = -RANK_LOSS_BASE
		# 连败刚开始 → 把「现在这个小级的起点」记成地板
		if rank_lose_streak == 1:
			rank_shield_floor = div_before * RANK_STEP
		if rank_lose_streak <= RANK_LOSS_SHIELD and rank_shield_floor >= 0:
			rank_points = maxi(before + delta, rank_shield_floor)
			shielded = rank_points > before + delta
		else:
			rank_points = maxi(before + delta, 0)
		# 被保底夹住时 delta 要按**实际变化**记，否则 UI 会显示「-18分」
		# 而分数根本没动。
		delta = rank_points - before

	var div_after := rank_div_of(rank_points)
	stats["rank_matches"] = int(stats["rank_matches"]) + 1
	if won:
		stats["rank_wins"] = int(stats["rank_wins"]) + 1
	set_max("rank_best_tier", div_after)
	rank_season_peak = maxi(rank_season_peak, rank_points)
	save_profile()
	return {
		"won": won,
		"delta": delta,
		"points_before": before, "points_after": rank_points,
		"div_before": div_before, "div_after": div_after,
		"name_before": rank_div_label(div_before),
		"name_after": rank_div_label(div_after),
		"promoted": div_after > div_before,
		"demoted": div_after < div_before,
		"shielded": shielded,
		"shield_left": maxi(RANK_LOSS_SHIELD - rank_lose_streak, 0),
		"streak": rank_streak, "lose_streak": rank_lose_streak,
		"coins_mult": rank_coins_mult(),
		"into": rank_into_div(), "span": RANK_STEP,
		"next_name": rank_next_name(),
		"is_max": rank_is_max(),
		"season": rank_season,
	}
