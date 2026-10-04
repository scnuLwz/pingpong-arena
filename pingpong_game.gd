extends Node3D
## 乒乓球小游戏主控 (Godot 4.x, GDScript)
##
## 玩法：
##   1. 站在球台一端，手持乒乓球拍
##   2. 对方随机发球到你的半台，球会在台面弹一下
##   3. 鼠标左键 = 反手挥拍，右键 = 正手挥拍
##   4. 回球过网并落在对方台面 → 得分
##   5. **按住空格蓄力**，再按鼠标左/右键 → 反手「暴拧」/ 正手「爆冲」，
##      球更快更转更刁，但要消耗体力
##
## 乒乓球规则（简化版）：
##   - 回球必须过网（网高 0.1525 m）并落在对方半台 → 得分
##   - 下网 / 出界（没落到台面而直接落地） → 失分
##   - 球在自己半台弹两次还没打到 → 失分
##
## 坐标约定（与 pingpong.tscn 一致）：
##   - 球台沿 Z 轴铺开，球网在 z = 0
##   - 玩家半台：z > 0（接球侧）
##   - 对方半台：z < 0（发球侧 / 得分落点区）
##   - 台面 y = 0.76，台半长 1.37、半宽 0.7625
##   - 玩家被 player_movement 的活动区限制锁在 z > 0，进不了对面

signal score_changed(player: int, opponent: int)
signal message_changed(text: String)
signal stamina_changed(value: float, maximum: float)

enum State { IDLE, SERVE_DELAY, INCOMING, RALLY, POINT }

## 这一回合**最后一个碰到球的是谁**。
## 判分完全由它 + 球落在哪一侧决定，所以必须是三态而不是布尔量：
## 加了对手回球之后，「球落在对方半台」既可能是玩家打出的好球（→ 对手该接），
## 也可能是对手自己打回自己半台（→ 对手失误、玩家得分），
## 一个 `_player_hit: bool` 区分不了这两种。
enum Hitter { NONE, PLAYER, OPPONENT }

## HUD 中文字体。Godot 默认字体没有 CJK 字形，不加这个 HUD 上的中文全是「豆腐块」。
## 这是从系统 Noto Sans SC（OFL 1.1）子集化出来的，只含工程用到的字符。
## 已经在 project.godot 的 gui/theme/custom_font 里挂了同一份，
## 这里再显式指定一次，免得别处（比如编辑器预览）走了别的主题。
const HUD_FONT := preload("res://fonts/hud_cjk.otf")

## 进入「加分局」的比分（ITTF：10:10 之后每个运动员轮流发 1 分球）。
## 只影响发球顺序的时钟刻度，不改变胜负判定（见 _serve_side）。
const DEUCE_POINTS := 10

## 击球类型
enum HitKind { NORMAL, LOOP, FLICK }   # 普通 / 正手爆冲 / 反手暴拧

# ───────────── 双打 ─────────────
@export_group("双打")
## 我方两名队员各自的站位（世界 x 的绝对值）。
## 0 号在 -x 侧、1 号在 +x 侧；对手同样分 -x / +x，索引一致。
## 0.78 略大于半台宽 0.7625 —— 站在台侧一点，两人中间留出跑动通道。
@export var doubles_partner_x: float = 0.78
@export var doubles_opponent_x: float = 0.78
## 控制权在两人之间切换时，相机横移到位所需的时间（秒）。
## 必须明显短于对手回球的飞行时间（0.4~0.7 s），
## 否则球都到了人还没挪过去 —— 0.20 s 是「看得见移动但不耽误接球」的取值。
@export var doubles_switch_time: float = 0.20
## 是否画出你没在操控的那名队友。**画的是一把悬空球拍，不是人形** ——
##   用户明确要「渲染队友的乒乓球拍，不需要队友模型」。
##   理由和对手那边（opponent_player.gd 的 show_figure=false）完全一致：
##   相机离队友只有 1.56 m，人形会糊住半屏，而球拍才是真正要传递的信息
##   「他在哪一侧、他挥了没有」。而且复用同一个脚本，两边视觉语言统一。
@export var doubles_show_partner: bool = true
## 队友那把拍子站的位置（世界 z）。正数 = 我方半台，在底线 1.37 之后。
## 1.62 = 退台半步的站位（自己台边 1.37 之后 25 cm）。
## 玩家最前能走到台面中间（area_z_min 0.685，是他身前一大截），
## 所以第一人称下队友一般落在你侧方偏后 —— 不会挡在球台和你之间。
@export var doubles_partner_z: float = 1.62
## AI 队友那把拍子相对他站位的 z 偏移（负数 = 伸向球台）。
## ★ 不能用 opponent_player.paddle_plane_z()：队友是绕 Y 转了 180° 的，
##   那个函数把本地 blade_target.z 直接加到 global_position.z 上，
##   算出来的平面会落在队友背后（见 _update_partner_return）。
## AI 队友接球平面的前向微调（米）：拍面真实世界 z 之上再加这一量。
## 0 = 球一飞到拍面就打；正值 = 让队友打得更早一点（球还在拍面前方就出手），
## 负值 = 更晚。默认 0 即可，留着只为手感微调。
@export var partner_paddle_dz: float = 0.0
## AI 队友接球的可靠度（0~1，越大越强）。
## 0.95 = 队友漏接概率 5%（用户指定值）。★ 这个数就是「队友接球成功概率」本身 ——
## 前提是它必须是**唯一**的失败来源：掷骰通过就一定接得到。
## 原来不是（掷骰 96% 但实测端到端 0/56），因为队友的出手判据只盯「球飞过拍面
## 所在的那个固定平面」，而对手的发球/短球在我方半台**第二次落地**的位置
## 就在那个平面之前 —— 球先被判「没接到」，队友压根没机会出手。
## 修在 _update_partner_return（见 partner_bounce_hit_z 与 partner_return_timeout）。
@export var partner_ai_skill: float = 0.95
## 队友「等球飞到可击球带」的保险超时（秒）。
## ★ 必须比 opponent_return_timeout（对手回球的 0.85 s）宽得多：
##   对手**发球**要先把球送到我方半台弹一下再飞向队友，实测从出手到
##   「进入可击球带」要 0.9~1.3 s。按 0.85 s 收口的话，队友会在球到之前
##   就被 _cancel_partner_return 清掉 —— 这正是一条静默的 100% 漏球路径。
##   正常路径由 _point_over / 球已飞过判定兜底，这个超时只在球凭空消失时生效。
@export var partner_return_timeout: float = 1.80
## 队友「球已经在我方半台弹过一次」之后的出手门槛（世界 z）。
## ★ 为什么不能只等球飞过队友拍面（z≈1.14）：对手发球与台内短球的**第二跳
##   落点实测在 z=0.77~1.05**，比拍面还靠前 —— 球在够到拍面之前就二次落地判分。
##   补上这条「弹起后就打」（真人接发球就是这个时机），队友才真的接得到。
## 0.50 ≈ 球台中间一线：球过网、落台、弹起后走到这里就出手，留足时间余量。
@export var partner_bounce_hit_z: float = 0.50
## AI 队友回球的飞行时间倍率（乘在 return_flight_time 上）。
## 1.12 = 比玩家自己打（0.45 s）慢一点 —— 队友是「稳」，不是「凶」。
@export var partner_ai_flight_scale: float = 1.12
## AI 队友从「拿到发球权」到「把球发出去」的停顿（秒）。
## ★ 不能是 0：队友的发球是凭空 launch 出来的，没有「手拿球 → 抛球」这个
##   可见过程，停顿全免的话玩家只会看到球突然从自己面前飞走，不知道谁发的。
##   这 1.2 s 就是给「他举着球、拍子动一下、球出手」留的表演时间。
## ★ 也不能太长：发球权捏在队友手里干等，比自己发球还难受。
@export var partner_serve_delay: float = 1.20
## AI 队友发球的飞行时间倍率（乘在 _flight_time() 上）。
## 1.10 = 比玩家自己发稍慢一点点，落点更靠台内，对手接发球不占便宜。
@export var partner_serve_flight_scale: float = 1.10
## 双打赢下来给多少金币。**入场费在菜单里进场景之前就扣掉了**，
## 所以这里是纯奖金（50 进 / 150 赢 = 净赚 100）。
@export var doubles_prize: int = 150

# ───────────── 球台尺寸（ITTF 标准）─────────────
@export_group("球台")
@export var table_half_length: float = 1.37
@export var table_half_width: float = 0.7625
@export var table_height: float = 0.76
@export var net_height: float = 0.1525

# ───────────── 难度 ─────────────
@export_group("难度")
@export_enum("简单", "普通", "困难", "专家", "大师") var difficulty: int = 1
## 五档难度参数（0 简单 / 1 普通 / 2 困难 / 3 专家 / 4 大师）。
## 每个参数都有 easy_ / normal_ / hard_ / expert_ / master_ 五个前缀：
##   flight_time  发球飞到你半台所需时间（越小越快）
##   spread       落点随机范围（占半台比例）
##   reach_scale  玩家够球范围的倍率（越小越难够到）
##   serve_spin   对手发球的侧旋强度（越大越拐，接发球越难吃准）
##   serve_edge   对手发球把落点推向边线的程度（0 均匀 → 1 全贴边）
##   serve_short  对手发短球（落点靠网）的概率 —— 逼玩家上前，不能直接抽
##
## 大师档的定位是「很难战胜」：发球又快又贴边、对手几乎不失误、
## 玩家够球范围只有 0.60 倍。数值不是拍脑袋定的，见各参数下的推导。
## 发球飞行时间（秒）—— 越小越快、弧线越平。
##
## 这三个值原来给的是 1.50 / 1.15 / 0.85，是**错的**：
## 发球要飞的水平距离只有 1.7 m，用 1.5 s 去飞，水平速度只剩 1.1 m/s，
## 而解抛物线时必须用一个巨大的向上分量来「消耗」这些时间，
## 结果发球弧线顶点实测到了 **2.91 m**（球台才 0.76 m、玩家眼高 1.52 m）——
## 球大半程在画面上边之外，玩家既看不见也接不到，像在发排球高远球。
##
## 反推几何下界：发射点 y=0.98、网顶 y=0.9325（在 z=0）、落点 y=0.78，
## 理想抛物线要过网必须满足 y_net = 0.8256 + 0.864·t² >= 0.9325 → t >= 0.352 s。
## 所以大师档取 0.365 —— 已经贴着「能过网」的物理下限，
## 再快就只剩撞网一条解了（求解器会退化成一条撞网轨迹）。
@export var easy_flight_time: float = 0.46
@export var easy_spread: float = 0.35
@export var easy_reach_scale: float = 1.28

@export var normal_flight_time: float = 0.42
@export var normal_spread: float = 0.55
@export var normal_reach_scale: float = 1.00

@export var hard_flight_time: float = 0.40
@export var hard_spread: float = 0.72
@export var hard_reach_scale: float = 0.86

@export var expert_flight_time: float = 0.38
@export var expert_spread: float = 0.86
@export var expert_reach_scale: float = 0.78

@export var master_flight_time: float = 0.365
@export var master_spread: float = 0.96
## 0.68 倍意味着三轴半轴同时缩到 68% —— 横向容差满体力 0.13 m。
## 本来想给 0.60，探针一算：再乘上空体力的 0.55 就只剩 **6 cm**，
## 那不是「难战胜」，是物理上打不到球。0.68 + 空体力 = 0.071 m，
## 配合发球贴边、对手几乎不失误，已经是「认真走位才有一线机会」。
@export var master_reach_scale: float = 0.68

# ───────────── 对手发球（「接发球就得分」要难）─────────────
## ★ 用户要「人机开球就得分较难」。原来的发球只有「越快、越散」两个旋钮，
##   玩家站住不动就能抽回去，所以得分太容易。这里补三个真正影响接发球的维度：
##     serve_spin  侧旋。球落台后会往侧面拐（马格努斯 + 弹跳侧踢），
##                 拍面喂不正就直接飞出台外 —— 这是接发球失误的主因。
##     serve_edge  落点向边线偏。均匀随机时球大多落在半台中部，
##                 玩家不用动；推向边线后必须真的走位才够得到。
##     serve_short 短球概率。落点贴网时球第二跳还在台内、高度很低，
##                 抽不了，只能搓/挑 —— 直接封死「接发球一板爆冲得分」。
## ★ 2026-10-02 用户第二次反馈：「接球的得分控制在 10% 以内」「AI 发出来的球
##   不要太难接」。原来那组「让接发球变难」的数值是为上一版需求调的，
##   现在整体回调：侧旋砍掉约 1/4、边线强度砍掉一半、短球概率砍一半，
##   再叠一条发球飞行时间放慢（serve_flight_scale）。
##   目标是「对手发球直接得分（我根本没碰到球）」占总局数 ≤10%。
@export var easy_serve_spin: float = 0.25
@export var easy_serve_edge: float = 0.00
@export var easy_serve_short: float = 0.00

@export var normal_serve_spin: float = 0.38
@export var normal_serve_edge: float = 0.06
@export var normal_serve_short: float = 0.00

@export var hard_serve_spin: float = 0.58
@export var hard_serve_edge: float = 0.12
@export var hard_serve_short: float = 0.03

@export var expert_serve_spin: float = 0.78
@export var expert_serve_edge: float = 0.20
@export var expert_serve_short: float = 0.07

@export var master_serve_spin: float = 1.00
@export var master_serve_edge: float = 0.28
@export var master_serve_short: float = 0.12

# ───────────── 接发球（★ 用户要「所有对局里都难以发球就得分」）─────────────
@export_group("接发球（压制发球直接得分）")
## 「发球直接得分」= 球发出去、对方第一拍没碰到（或碰到但打丢），一分到手。
## 这条在**两个方向**上都要压住，否则 5 档难度就变成「比谁发球更刁」：
##   ① 我发球 → 对手接不到          （下面两条倍率压住：他几乎必回）
##   ② 对手发球 → 我接不到/我一板打死（放宽判定 + 削弱必杀：来回打起来）
## 实现上统一用一个 `_serve_phase` 标记：从发球出手到「接发球那一拍打出去」为止为真。
## 单打 / 双打走的是同一份代码，所以两个模式一起生效。
## 对手**接发球**时的失误率倍率。0.28 = 大师档 1.8% 直接压到 0.5%，
##   约 200 球才白送一分 —— 靠发球偷分这条路基本堵死。
## ★ 2026-10-03 用户要求「弱化发球得分」：0.28 → 0.12。
##   大师档 1.8% × 0.12 = **0.22%**，约 460 球才白送一分。
##   原来的 0.5% 听着已经很低，但那是**在对手够得到的前提下** ——
##   真正让发球能白拿分的是下面两条（够不到 / 接了出台），那才是要堵的口子。
@export var serve_return_miss_scale: float = 0.12
## 对手接发球时「碰到但回球出台」的倍率。同样压低，但压得比 miss 轻 ——
## 全挡住的话对手会变成一个墙，保留一点失误才有来有回。
## ★ 0.40 → 0.25：发球阶段对手几乎不送分，弱化发球得分。
@export var serve_return_out_scale: float = 0.25
## ★ 对手接发球时够球范围的倍率（用户要「弱化发球得分」时发现的漏洞）。
##
##   漏洞在横向：玩家发球瞄准范围是 ±serve_aim_x_span(0.95) × 半台宽
##   = **±0.724 m**，而对手的横向够球半径只有 `opponent_reach_x` = 0.66 m。
##   两端各有一条 **0.064 m 宽的死角**：球只要精确落在那儿，
##   `_schedule_opponent_return` 里的 `too_wide` 会**无条件判对手接不到** ——
##   这不是概率问题，是瞄哪儿哪儿白送分。
##   1.25 → 0.825 m > 0.724 m，死角被彻底盖掉。
##   ★ 只作用于接发球那一拍：玩家自己打出的球仍然要靠真跑动去够，
##     否则「打大角」这条战术就没了。
@export var opp_serve_reach_bonus: float = 1.25
## 玩家**接对手发球**时，够球范围放宽的比例。
##   发球本来就带侧旋、还往边线/贴网送（见 serve_spin / edge / short），
##   如果不放宽，「对手开球就得分」会非常常见 —— 那是运气不是难度。
##   放宽的是**够得到**，不是**打得死**：下面两条把回球质量压回去。
##   ★ 用户报「开球就得分」：贴网短球（落点 z≈0.22~0.47）原本就算伸手也差一截，
##   这里把放宽从 0.60 提到 0.90，配合探拍(table_reach_max 0.95→1.35)，
##   接发球判定盒明显更大，近网短球基本都能兜住。
##   ★ 2026-10-02 再提到 1.50（判定盒 ×2.5）：用户要「接球得分 ≤10%」，
##   单纯把球发慢还不够 —— 接发那一拍本身也要够得着，否则慢球照样漏。
@export var serve_return_reach_bonus: float = 1.50
## 对手发球的飞行时间倍率（>1 = 球更慢）。
##
## ★ 用户要「AI 发出来的球不要太难接」：这是最直接的一环 ——
##   球慢下来，玩家才有时间看清落点、挪到位。
##   正常档发球 0.42 s → ≈0.53 s；大师档 0.365 s → ≈0.46 s。
##   只作用于**对手**发球（见 _plan_serve），玩家自己发球的节奏不变。
##   上限受 serve_flight_max(0.70) 约束，解算器不会因此解不出合法发球。
@export var serve_flight_scale: float = 1.25
## 接发球那一拍的必杀率倍率。0.30 = 满体力的爆冲必杀从 0.80 掉到 0.24。
##   「接发球一板爆冲打死」这条捷径因此基本封死。
@export var serve_return_kill_scale: float = 0.30
## 接发球那一拍的回球飞行时间倍率。1.18 = 球更慢更高，
##   对手有充分时间跑到位 —— 接发球变成「把球放回去」，不是「一击制胜」。
@export var serve_return_flight_scale: float = 1.18

# ───────────── 击球 ─────────────
@export_group("击球")
## 挥拍判定窗口（秒），窗口内每帧都判一次，提前按也打得到
@export var swing_valid_duration: float = 0.30
## 回球飞行时间（秒）。乒乓球回球是又平又快的「抽」，
## 这个数直接决定弧线高度：0.70 会让球在网顶上方 0.64m 飞过（像羽毛球吊高球，不对），
## 0.45 时约在网顶上方 0.33m 掠过，接近真实乒乓球。
@export var return_flight_time: float = 0.45
## 时机不完美时落点的最大偏移（米）
@export var hit_error_max: float = 0.40
@export var show_landing_marker: bool = true

# ───────────── 击球判定（够球范围）─────────────
@export_group("击球判定（够球范围）")
## ★ 为什么从「一个球形半径」改成「三轴各自给半轴」：
##
##   旧实现是以拍面中心为球心、半径 r 乘上 (1.25, 1.55) 的椭球，
##   普通难度 r=0.45 → 横向容差 0.563 m、纵向 0.698 m。
##   实测（_tmp_hitgeo 探针，10 个对手来球）来球扫过玩家这一侧时球心恒在
##   y = 0.86~0.93 m —— 因为球是从 0.76 m 的台面弹起来的，在玩家这侧
##   根本飞不到拍面静止位那个高度（y ≈ 1.31 m），差 0.4 m。
##   旧判据正是靠那 0.698 m 的纵向半轴把这段差「吞」掉的，
##   代价是横向容差一起被放大 —— 于是站中间就能接到几乎所有球（用户反馈）。
##
##   新判据把三个方向拆开，各自对应一种玩家操作：
##     横向 x → 靠走位。给得最紧，这就是「不能站中间吃所有球」。
##     纵深 z → 靠站位前后。中等。
##     高度 y → 实测来球高度很稳定（0.86~0.93），中心直接挪到击球高度，
##              半轴给到 0.32 仍然够用，而且留了抬头的余地。
## ★ 用户要「减小击球成功判断范围」。三个半轴整体收紧约 25%：
##   0.26/0.38/0.32 → 0.19/0.28/0.24。
##   原来横向 ±0.26 m 太宽了，站着不动就能扫到半个台面宽的球，
##   走位这件事形同虚设。收紧之后「必须对准球」才打得到。
##   缺口用**探拍**补（table_reach_max，按住 Shift 把拍子送到台面上方）——
##   「够得到」从数值宽容变成操作，这才是用户真正想要的手感。
@export var hit_reach_x: float = 0.19
@export var hit_reach_z: float = 0.28
@export var hit_reach_y: float = 0.24
## 探拍（按住 R 把拍子送到球台上方）从收到完全伸出所需的时间（秒）。
## 0.18 s 是「来不及乱按」的下限：比挥拍窗口(0.30)短，但比人的反应(0.25)略长，
## 所以探拍必须**预判**，不能等球到了再按。
@export var table_reach_time: float = 0.18
## 击球高度中心（米）。实测来球 y ∈ [0.86, 0.93]，取中位 0.90 略抬一点。
@export var contact_height: float = 0.91
## 蓄力击球时够球范围放宽的比例（爆冲本身挥幅大，判定也该大一点）。
## 0.26 → 0.42：「提升蓄力收益」的一部分 —— 蓄满力不只是球更快，
## 判定范围也明显更宽，蓄力这一下在「打得到」这件事上同样有回报。
@export var power_reach_bonus: float = 0.42
## 必须落在视线前方，这个点积门槛约等于视野 ±72°
@export var hit_in_front_dot: float = 0.30
## 体力见底时够球范围缩到原来的比例（用户要的「体力与击球成功概率相关」）。
##
## ★ 0.72 → 0.55。原来只缩 28%，玩家几乎感觉不到「累了打不到球」；
##   现在见底时三轴半轴只剩 55%，横向容差从 0.50 m 掉到 0.28 m ——
##   「空体力站在中间也够不到边线球」，体力才真的和成功率挂上钩。
##   注意它是**乘**在 _reach_scale 上的，所以大师档 × 空体力 = 0.60 × 0.55
##   = 0.33 倍，这才是「大师档很难战胜」的真正来源。
@export var stamina_reach_floor: float = 0.55
## 待机时拍子自动保持的探拍基础量（0~1）。
##
## ★ 用户反复报「球拍上不了台 / 有空气墙」：根因是不按 R 时 _reach_extend 归零，
##   拍子缩回胸口高度（世界 y≈1.2），台面上的低球够不到。给个基础量，
##   让不按键时拍面也压在台面上方（配合 FH_REST_POS/BH_REST_POS 的 y=-0.34,z=-0.50），
##   按住 R 再全探贴台。0.4 = 待机半探，拍面落台面上方约 0.2 m，走路即能迎台上的球。
@export var reach_rest: float = 0.4
## 蹲姿够不到的「近台短球」界线：球落在玩家这侧、第一落点离网不到这个距离（米）就算短球。
## 用户要的「蹲下回球更有力量，但接不到近台的球」：
## 蹲着重心低、起不来也迈不开步，短球必须上前一步才够得着 —— 所以蹲姿直接判够不到。
##
## ★ 这个阈值是**实测标定**的，不是拍的：自动对打探针（_tmp_bal2）采了 36 个对手回球，
##   第一落点 z 的分布是 0.39~1.30、中位 0.82。0.62 正好切掉最短的那 25% ——
##   蹲姿因此变成「四分之三的球照打、四分之一的球只能站起来接」的取舍。
##   早先写 0.82（= 中位数）时实测封锁率 53%，蹲姿基本没法用。
@export var crouch_short_ball_z: float = 0.62

# ───────────── 挥拍节奏 ─────────────
@export_group("挥拍节奏")
## 一次挥拍动作走完 + 这段时间内不能再挥 —— 用户要的「不能连续挥拍」。
## 满节奏 ≈ swing_valid_duration + swing_recover ≈ 0.48 s，一秒最多两拍。
@export var swing_recover: float = 0.18
## 挥空判负：球在拍点的这个水平距离内却没打到 → 立刻判对方得分。
## 球在远处（比这个距离远）时挥空完全不受罚，随便挥。
@export var whiff_fault_radius: float = 0.95
## 挥空判罚的开关（调试/低难度可以关掉）
@export var whiff_fault_enable: bool = true

# ───────────── 蹲姿 ─────────────
@export_group("蹲姿")
## 蹲姿回球的飞行时间倍率 —— 小于 1 = 球更快更冲（用户要的「蹲下回球更有力量」）
@export var crouch_return_flight_scale: float = 0.84
## 蹲姿回球额外的旋转加成
@export var crouch_spin_bonus: float = 0.5

# ───────────── 发球（抛球 + 蓄力）─────────────
@export_group("发球（抛球 + 蓄力）")
## 抛球初速度（m/s，竖直向上）。3.4 → 抛起约 0.55 m（含空气阻力的实测值），滞空约 0.75 s。
@export var toss_speed: float = 3.4
## 球下落回到「出手高度」时就自动击出。
##
## ★ 这是**上限**：站立时持球点正好在 1.11（1.52 − 0.41），所以站立弹道逐位不变；
##   蹲下时持球点下沉，出手高度也跟着降下来（见 _serve_launch_y / _toss_strike_y）——
##   这就是「蹲下改发球线路」：出手点低 → 弧线更低平、第一跳更近台。
@export var toss_strike_height: float = 1.11
## 抛球后玩家一直不击球的兜底等待（秒）—— 到点自动替他击出去，绝不挂住球局
@export var toss_auto_strike: float = 1.9
## 满蓄力的发球飞行时间倍率（越小越快）—— 这是「发球也能蓄力」的体现
@export var serve_power_flight_scale: float = 0.60
## 发球球速上限（m/s）—— 用户要的「限制开球球速」，别让发球变成必杀
@export var serve_speed_max: float = 10.5

# ───────────── 发球：合规落点 + 发球区 ─────────────
@export_group("发球（合规落点 + 发球区）")
## ★ 用户报「发球出去后要先弹自己的桌面」—— 这是乒乓球规则：
##   合法发球必须先在**发球方自己的半台**弹一次、越网、再落到**接发球方的半台**。
##   原来的实现直接把落点设在对方半台（第一跳就在对面），等于作弊。
##   现在用「搜索式解算器」：枚举几组「己方第一跳点 + 飞行时间」，
##   取第一个「第一跳己方、不撞网、第二跳对方」的轨迹。
@export var serve_own_bounce_min_z: float = 0.20
@export var serve_own_bounce_max_z: float = 1.20
## 候选飞行时间（相对 _flight_time() 的倍率），解算器会逐个试
@export var serve_legal_flight_scales: Array[float] = [0.95, 1.05, 1.15, 1.30, 1.45, 1.60]
## 解算器最多枚举多少组候选（超出就退回旧的「直落对方台」兜底，绝不卡住球局）
## ★ 从 60 提到 200：候选组合是「己方落点 5 × 纵深 6 × 飞行时间 6 = 180」，
##   原来 60 次就停了 —— 只试得完前两组己方落点，正方向那几组永远轮不到，
##   于是「瞄右边却飞到左边」（实测偏差 0.94 m）。现在全量试完。
##   命中 accept_dist 会提前返回，所以多数发球不会真的跑满 180 次。
@export var serve_legal_attempts: int = 200
## 候选的第二跳落点离目标小于这个距离就直接采纳（早退，避免每帧跑满枚举）
@export var serve_legal_accept_dist: float = 0.32

## ★★ 解算步长（s）。**必须等于 `_physics_process` 的实际步长**，否则
##   「预测过网」和「实际过网」用的是两套不同的半隐式欧拉累积误差，
##   会出现「解算 y=0.9330 判定擦过（网顶 0.9325）、实际落到 y=0.9290 撞网」——
##   只差 3.5 mm，实际结果却是**发球直接下网、白送对手一分**。
##   → 预测和现实必须跑同一套数值积分，这才是根治；靠加安全余量只是掩盖，
##   而且余量一大就会把「擦网而过」这一整档合法球全毙掉（实测 22 mm → 接住 6/18）。
@export var serve_solve_dt: float = 1.0 / 60.0

## ★ 过网安全余量（m），只留**浮点级**的量。
## 步长对齐后剩下的差异只来自「解算里的碰撞判定」与「真实 _cross_net」的分支顺序，
## 实测在 1 mm 以内 —— 0.003 m 足够，再大就会误杀擦边高球。
## ★ 必须和 _build_serve_traj 用同一个值 —— 否则玩家看到的预览弧线
##   与实际球路不一致（预览能过、实际下网），会觉得是 bug。
@export var serve_net_clearance: float = 0.003

## 发球区：玩家必须站在台后这一带才能发球 —— 修「距离台面很远也可以发球」。
##   z < serve_zone_min：站在台内/贴网（不合规，也不能发）
##   z > serve_zone_max：离台太远（不合规，走回台后再发）
## ★ 1.39 = 端线(1.37) + 2 cm。ITTF 2.6.1 要求发球时球必须在**端线之后**，
##   所以玩家站位也必须整段落在端线后 —— 原来给的是 1.34（台内），
##   配合下面的出手点一起修。
@export var serve_zone_min_z: float = 1.39
## ★ 2.60 → 3.30（= player_movement 的 area_z_max）。
##   活动区域放宽到 3.30 之后，上沿还留在 2.60 会留下一条
##   z ∈ [2.60, 3.30] 的**死区**：玩家为了接深球退到那里，
##   下一分却因为 `_in_serve_zone` 否掉而发不了球，提示「离台太远」，
##   只好又走回来 —— 自己给自己挖坑。
##   ★ 这里**必须等于 area_z_max 而不是留余量**：留余量（试过 3.10）
##     等于承认「活动区里有一部分位置不能发球」。既然活动区本身已经是
##     「能站到的全部合法位置」，让两个上沿严格相等最干净 ——
##     想收紧就收紧 `area_z_max` 一个数，两个文件一起改。
##   ITTF 只要求发球点在端线之后（serve_zone_min_z），没有「离台太远」这回事，
##   所以上沿本来就该由**活动范围**决定，而不是另立一个规则。
@export var serve_zone_max_z: float = 3.30
## 出手点相对玩家：往身前（-z）多少米
@export var serve_launch_ahead: float = 0.14
## 发球时「球拿在手里」的位置：离**眼睛**往下多少米。
##
## ★ 修「自己下蹲时发球线路会改变」。原来持球点的高度是**世界**常量（1.11），
##   跟玩家姿势无关：站立时相机 1.52，球在眼睛下方 0.41 m（看着自然）；
##   蹲下相机沉到 0.97，同一个世界高度就跑到眼睛**上方** 0.14 m 去了 ——
##   实测持球点相对视线从 -50°（画面下方）跳到 +66°（画面**上方**，
##   已经在垂直 FOV ±35° 之外），抛球顶点更是 +94°，整个发球动作跑到画面外。
##   0.41 = 1.52 − 1.11，正好复现原来站立时的观感，站立时数值一点不动。
@export var serve_hold_below_eye: float = 0.41
## 持球点的世界高度下限（米）。ITTF 2.6.1：发球时球必须在比赛台面以上，
## 所以蹲到再低也不许把球放到台面以下。0.88 = 台面 0.76 + 0.12
## （和 _serve_strike 的出手高度下限用同一个值）。
@export var serve_hold_min_y: float = 0.88
## 发球出手点必须在端线之后留出的余量（ITTF 2.6.1：球须在端线之后）。
## ★ 出手点 = 玩家位置 − serve_launch_ahead（球拍往台面方向前伸），
##   所以光把 serve_zone_min_z 提到端线后还不够 —— 前伸 14 cm 会把球带回台内。
##   实测修前出手点被钳在 1.36 < 端线 1.37（球悬在台面正上方出手，不合规）。
@export var serve_end_line_margin: float = 0.02

## 发球轨迹提示线（用户要的「发球要有轨迹提示」）
@export var show_serve_trajectory: bool = true
## 提示线的颜色
## ★── 发球瞄准：转动视角选落点（「看哪落哪」）──────────────────────
## 视线与台面的交点就是目标落点：抬头看远 → 打底线，低头看近 → 放短球，
## 左右转头 → 打两条边线。原来落点是纯随机、且只覆盖半台中部，
## 玩家反馈「可选区域太少」，所以这里把可达范围放大到接近整个对方半台。
@export var serve_aim_enabled: bool = true
## 横向可达范围（占半台宽的比例）。0.95 = 两侧边线几乎都能打到
@export var serve_aim_x_span: float = 0.95
## 纵深可达范围（占半台长的比例）。近端不能贴到 0（球会挂网），
## 远端留一点余量 —— 打满 1.0 时解算器要同时满足「过网 + 不出界」，
## 反而经常解不出来，最后退回兜底轨迹。
@export var serve_aim_z_near: float = 0.12
@export var serve_aim_z_far: float = 0.94
@export var serve_traj_color: Color = Color(1.0, 0.86, 0.25, 0.9)
## 提示线的点距（米）：越小线越平滑、顶点越多
@export var serve_traj_step: float = 0.06

# ───────────── 体力 ─────────────
@export_group("体力")
@export var max_stamina: float = 100.0
## 每秒自然恢复量。
##
## ★ 用户要「自然体力下降速度很快」。原来 17.0/s 配 0.85s 延迟，意味着只要
##   两拍间隔超过 1.05 秒，这一拍扣掉的体力就被回满了 —— 净消耗随节奏变负，
##   打得稳一点就永远满体力，玩家根本感觉不到有体力这回事（那时是 9.0）。
##   现在**主要靠得分回血**，自然恢复只留一点点（2.5/s）：
##   一分球之间的停顿（point_pause 1.3 + serve_delay 1.2 ≈ 2.5 s）只能回 6 点，
##   还不够半拍的消耗 —— 于是「不得分就一路掉到底」这件事真的会发生。
@export var stamina_regen: float = 2.5
## 消耗后要等这么久才开始恢复（防止连点无惩罚）。
## 从 0.85 拉到 1.10：让「刚打完这一拍」这段时间彻底不回血。
@export var stamina_regen_delay: float = 1.10
## 正手爆冲消耗。
## ★ 26 → 23：体力系统改成「6 拍清零」后，一拍普通球就要 16.7，
##   爆冲 26 相当于 1.56 拍 —— 太贵了，没人愿意蓄力。
##   降到 23（1.38 拍）配合下面的必杀率提升，蓄力才划算。
@export var cost_forehand_loop: float = 23.0
## 反手暴拧消耗。21 → 18，同理。
@export var cost_backhand_flick: float = 18.0
## 蹲着挥拍时的体力折扣 —— 用户要的「下蹲体力消耗减少」。
## 0.6 = 蹲姿爆冲/暴拧只花六成体力，用来换「蹲着打省力但够不着高球」的取舍。
@export var crouch_cost_scale: float = 0.6
## ★ 用户要「体力**回合结束后**再结算（从发球到死球），6 个回合左右才消耗完」。
##   所以每拍不再扣体力，改成一整个回合收一次：
##     cost = stamina_cost_per_rally + stamina_cost_per_rally_hit × 本回合我打了几拍
##   9.0 + 1.9×4（一个普通回合四拍）≈ 16.6 → 6 个回合见底，正好。
##   这么改的另一个好处：回合**进行中**体力是恒定的，
##   不会出现「打第三拍时判定盒突然缩一圈」这种看不见的手感跳变。
## 每个回合的基础消耗（不管打了几拍都要付）。
@export var stamina_cost_per_rally: float = 9.0
## 回合内每多打一拍的额外消耗。长回合更累，短回合（比如发球直接失误）省一点。
@export var stamina_cost_per_rally_hit: float = 1.9
## 打赢一球立刻回这么多体力 —— 用户要「每次得分体力补充 2 球的体力」。
##   2 球 = 2 × 16.7 = 33.4。
##   这个数是整个体力系统的**节奏闸门**：得分率高于 1/3 就能一直维持，
##   低于 1/3 就必然见底 —— 体力因此变成「进攻压力」而不是「时间惩罚」。
@export var stamina_point_reward: float = 33.4
## ★ 输掉一球也回一点体力 —— 用户要的「输球也有体力补偿」。
##   只补**一个回合**的量（16.7），不像赢球那样补两拍（33.4）。
##   没有这一条的话，连丢 6 球就直接见底、之后再也打不动 ——
##   「输球 → 更没力气 → 更容易输」是个死亡螺旋，那是挫败感不是难度。
##   补一个回合 = 「这一分你确实打了，只是没赢」，仍然净亏，但不会一路滑到 0。
@export var stamina_loss_reward: float = 16.7
## 挥空（打丢）时的体力惩罚。比打到球轻一点（0.72 倍），
##   但一样是按「几球」量级算的 —— 空挥 8 次同样清零。
@export var stamina_cost_whiff: float = 12.0
## 体力见底时「出台概率」的额外倍率 —— 体力越低，拍形控制越差
@export var fatigue_out_extra: float = 1.25
## 蓄力下限：低于这个体力就蓄不了力（会在 HUD 上提示）。
##   ★ 12.0 而不是 18.0：以前「不到一拍的量就彻底不能蓄力」，
##     于是体力一掉到中段就进入「只能保守对拉 → 回合更长 → 体力更差」的死循环。
##     留出「残血也能搏一把」的空间，扣杀才真的是一条翻盘路线而不是顺风局的玩具。
@export var min_stamina_to_charge: float = 12.0
## ★ 用蓄力扣杀（正手爆冲 / 反手暴拧）**拿下这一分**时，额外回多少体力。
##   这是「鼓励蓄力扣杀」的主激励：保守对拉赢一球只回 33.4（两个回合），
##   搏杀赢一球回 33.4 + 18 = 51.4（三个回合）—— 一次扣杀顶半管体力，
##   「该不该搏」因此变成一个真的决策，而不是「反正稳一点更划算」。
@export var kill_point_bonus: float = 18.0
## ★ 扣杀拿分的那一回合，回合体力消耗打几折。
##   0.7 = 扣杀回合只付七成。爆冲/暴拧本来就是为了缩短回合，
##   回合短、拍数少，再打个折；反过来拖长回合要全额付账。
@export var kill_rally_discount: float = 0.70
## ★ 掷中「必杀」时退还多少比例的蓄力消耗。
##   必杀 = 这一拍直接打死，既然一分到手，当初蓄力付的那笔钱就该退一部分 ——
##   不退的话「蓄满 → 掷中必杀」和「蓄满 → 没掷中」付出的代价一样，
##   玩家只会记住自己白花了体力。
@export var kill_charge_refund: float = 0.5

# ───────────── AI 对手的体力 ─────────────
@export_group("AI 对手体力")
## ★ 用户要「AI 对手也有体力系统限制」。
##   之前只有玩家会累，AI 打到第 50 拍还是满状态 ——
##   于是「拖长回合」对玩家毫无收益，反而只有自己在掉体力，越打越亏。
##   现在 AI 同样按回合结算，累了的代价是**失误变多、回球变慢**，
##   于是「把回合拖长」第一次变成一条真的战术：磨他。
@export var opponent_max_stamina: float = 100.0
## AI 每个回合的基础消耗。比玩家略高（10.0 vs 9.0）——
##   AI 本来就不会走位失误，再让他更耐打就没得打了。
@export var opponent_cost_per_rally: float = 10.0
## AI 回合内每多接一拍的额外消耗
@export var opponent_cost_per_rally_hit: float = 1.9
## AI 赢下一分回多少体力（和玩家一样是「2 个回合」的量）
@export var opponent_point_reward: float = 33.4
## AI 输掉这一分回多少。和玩家的 `stamina_loss_reward` 对称（一个回合的量）——
##   ★ 这一条必须有：如果 AI 只有**赢球**才回血，那玩家靠「磨长回合」把他耗干之后，
##     他只要赢一分就满血复活，磨他这件事等于白做。两边对称，长回合才真是一条战术。
@export var opponent_loss_reward: float = 16.7
## AI 在两分之间每秒回多少。比玩家慢一点点，长局里他会先撑不住。
@export var opponent_stamina_regen: float = 2.0
## 体力见底时，AI「完全没接到」的概率放大到多少倍。
## 2.2 倍意味着大师档（1.8%）在 AI 体力耗尽时变成 4% —— 翻了一倍多，
## 但仍然不是白送；拖到他见底才拿得到这个收益。
@export var opponent_fatigue_miss_scale: float = 2.2
## 体力见底时 AI 回球飞行时间放大到多少倍（累了就打不出快球）
@export var opponent_fatigue_flight_scale: float = 1.22

# ───────────── 爆冲 / 暴拧 ─────────────
@export_group("爆冲 / 暴拧")
## 按住空格蓄满所需时间（秒）
@export var charge_full_time: float = 0.55
## 刚按下就放开时也有这么多力量（0.45 = 也有接近一半的增幅）
@export var charge_min_power: float = 0.45
## 正手爆冲的回球飞行时间（满蓄力）—— 比普通 0.45 明显更快更平
##
## ★ 0.30 是探针量出来的**物理下界**，不能再小：
##   击球点在玩家这侧 z≈1.6、y≈0.91，要到对方半台必须同时满足「过网」和「落台」，
##   而球的阻力 drag_k=0.14 在高速下极强（v=12 时加速度 20 m/s²，是重力的两倍）。
##   实测 t<=0.24 时无解 —— 求解器只能给出一条撞网的轨迹（落点误差 0.97 m）。
##   t=0.26 开始有解但误差偏大，t>=0.30 完全收敛（误差 0.000 m）。
@export var loop_flight_time: float = 0.30
## 正手爆冲刚按下（最低蓄力）时的飞行时间。和上面拉开差距，
## 否则「按一下」和「蓄满」打出来的球速一模一样 —— 用户反馈就是这个。
@export var loop_flight_time_weak: float = 0.46
## 反手暴拧（满蓄力）
@export var flick_flight_time: float = 0.33
## 反手暴拧（最低蓄力）
@export var flick_flight_time_weak: float = 0.48
## 回球球速上限（m/s）—— 纯粹是数值兜底。求解器已经改成必定收敛的二分，
## 正常不会再出现离谱值；但万一某条退化输入让落点解崩了，宁可砍速度也不要
## 让一颗 40 m/s 的球在台上瞬移。
@export var return_speed_max: float = 24.0

# ───────────── 旋球 ─────────────
@export_group("旋球")
## Z + 左键 = 上旋：球弹起后往前窜（spin_bounce_kick），飞行中被马格努斯压着下坠
@export var spin_top: float = 1.7
## C + 左键 = 下旋：球发飘、落台后明显减速甚至回弹
@export var spin_back: float = 1.6
## 不按 Z/C 时普通挥拍自带的默认旋转范围（原来就是这个数，保留手感）
@export var spin_default_min: float = 0.3
@export var spin_default_max: float = 1.1

# ───────────── 爆冲必杀 / 出台 ─────────────
@export_group("爆冲必杀 / 出台")
## 正手爆冲「必杀」的基础概率（对手必定接不到，跟落点无关）。
##
## ★ 用户要「提升蓄力收益」。0.22 → 0.34：
##   原来蓄满一管打出去，十次里只有两次多是必杀，还得先花掉 26 点体力 ——
##   性价比算下来不如平打，所以没人蓄力。提到 0.34 之后，
##   「蓄满 = 三分之一概率直接拿分」，这才配得上那一管体力和蓄力时间。
@export var loop_kill_base: float = 0.34
## 体力满时在基础概率上再加这么多 —— 用户要的「体力高时更加容易」。
## 0.38 → 0.46，满体力爆冲的必杀率 = 0.34 + 0.46 = **0.80**。
## 这条和「6 拍清零」的体力系统咬合得很好：趁体力还在就搏杀，
## 拖到见底就只剩 0.34 —— 什么时候该蓄力变成一个真问题。
@export var loop_kill_stamina_bonus: float = 0.46
## 扣杀（正手爆冲）的**距离门槛** —— 用户要的「远台球（在台边上）才能扣杀，
## 不能离网太近」。
##
## 判据取「这一拍在玩家半台的落点 z」÷ 半台长（1.37 m）：
##   0.0 = 贴着网　1.0 = 贴着底线
## 0.62 → 落点 z ≥ 0.85 m 才允许爆冲。
##
## ★ 为什么用**落点**而不是「球现在离我多远」：
##   短球和远台球的区别不在球飞到你面前时有多远（都在你手边），
##   而在它落在台上哪个位置 —— 落点靠网就必须上前一步用轻挑，
##   落点靠底线才有引拍空间去抡。用落点判才符合直觉、也才挡得住
##   「站在台边不动，把近网短球也一板闷死」。
##
## ★ 只卡正手爆冲（HitKind.LOOP），**不卡反手暴拧（FLICK）** ——
##   真实乒乓里拧拉本来就是专门处理近网短球的技术，卡掉反而不合理。
@export var smash_min_bounce_ratio: float = 0.62
## 拍面没喂正时的出台基础概率（再乘上「歪的程度」的平方）
@export var out_chance_base: float = 0.38
## 拍形偏离「甜点拍形」不超过这个度数 = 拍面正，必定不出台
@export var face_ok_deg: float = 6.0
## 偏离超过这个度数 = 拍面彻底翻着，按满概率出台
@export var face_bad_deg: float = 26.0

# ───────────── 发球轮换 / 卡死兜底 ─────────────
@export_group("发球轮换 / 兜底")
## 每人连发几个球（真实乒乓球就是每人 2 个）
@export var serves_per_player: int = 2
## 轮到玩家发球后，等这么久还没出手就在 HUD 上再提醒一次
@export var player_serve_notice: float = 8.0
## 之后每隔这么久重复提醒一次
@export var player_serve_remind: float = 12.0
## 最后兜底：等满这么久还没发就替他发出去，绝不把球局挂住。
##
## ★ 别把这个值设小。代发之后球进入回合，而「站在原地没动」的玩家
##   接不到对手的回球，于是「干等」会变成「白丢一分」——
##   实测 14 s 时，静默不动 15.6 s 就稳定送出 0:1。
@export var player_serve_timeout: float = 30.0
## 回合中球多久没有任何事件（弹台/撞网/落地/被击）就判定这一分作废。
## IDLE / INCOMING / RALLY 原来没有任何超时出口，数学上存在「球再也不产生
## 任何事件 → 整局永久停在『球来了』」的路径，这就是「打到某个时刻就不发了」。
@export var rally_stall_timeout: float = 4.0
## 发球重发（let）之后等这么久再重新摆球。
## 比 point_pause(1.3) 短 —— 重发不是「丢了一分」，不该让玩家干等那么久。
@export var let_delay: float = 0.9

# ───────────── 对手回球 ─────────────
@export_group("对手回球")
## 关掉就退化成「对面接不到任何球」——用来 A/B 对比，正常别关
@export var opponent_returns: bool = true
## 对手回球的飞行时间（秒）。比玩家的 return_flight_time(0.45) 略慢，
## 给玩家留出「看到球 → 移动 → 挥拍」的反应时间。
## 各难度再乘一个倍率，见 opponent_return_flight_* 。
@export var opponent_return_flight: float = 0.58
## 排定一次回球后，至少等这么久才允许触球（秒）。
## 必须有这个下限：落点靠底线时球一弹起就已经越过拍面平面，
## 没有下限的话会在 y≈0.78 的低点仓促碰到 —— 而球弹起后飞到 ≈1.0 m
## 高正好要 0.12 s 左右，等这一下，触球高度就和拍面静止位对上了。
@export var opponent_contact_delay: float = 0.12
## 排定一次回球后，最多等多久还等不到球飞到拍面就放弃（秒）。
## 正常 0.2~0.4 s 就能到；这是防止球半路落地后一直挂着的保险。
@export var opponent_return_timeout: float = 0.85
## 触球点希望落在「球的落点之后多少米」。
## 0.35 m 是反推出来的：球的 z 速度约 1.7~3 m/s，走 0.35 m 恰好在
## 弹起后 0.12~0.2 s，正是球爬到最高点（≈1.0 m）的时候 ——
## 也就是球拍静止位所在的高度。
@export var opponent_contact_lead: float = 0.35

## 各难度下对手「完全没接到」的概率（球从他身边飞过，玩家得分）。
## 大师档 0.018 —— 大约 55 个球才白送一分，基本等于「对手不失误」。
@export var opponent_miss_easy: float = 0.34
@export var opponent_miss_normal: float = 0.16
@export var opponent_miss_hard: float = 0.09
@export var opponent_miss_expert: float = 0.045
@export var opponent_miss_master: float = 0.018
## 各难度下对手「接到但回球出台」的概率（球飞回来但落到台外，玩家得分）。
## 和「没接到」分开是为了让画面有变化 —— 全是球从对面飞过去会很单调。
@export var opponent_out_easy: float = 0.12
@export var opponent_out_normal: float = 0.06
@export var opponent_out_hard: float = 0.035
@export var opponent_out_expert: float = 0.018
@export var opponent_out_master: float = 0.007
## 各难度下对手回球飞行时间的倍率（越小 = 回球越快，玩家反应时间越少）。
## 0.58 s 的基数下：简单档 0.68 s（慢悠悠），大师档 0.41 s（贴着抽）。
@export var opponent_return_flight_easy: float = 1.18
@export var opponent_return_flight_normal: float = 1.00
@export var opponent_return_flight_hard: float = 0.90
@export var opponent_return_flight_expert: float = 0.80
@export var opponent_return_flight_master: float = 0.70
## 各难度下对手回球的横向散布（占半台比例）。越高越贴边线，
## 玩家每球都得真的跑动，不能站中间守株待兔。
@export var opponent_return_spread_easy: float = 0.45
@export var opponent_return_spread_normal: float = 0.66
@export var opponent_return_spread_hard: float = 0.80
@export var opponent_return_spread_expert: float = 0.90
@export var opponent_return_spread_master: float = 0.97
## 落点横向超过这个值就必失 —— 对手会迈步，但迈不了那么远。
## 要和 opponent_player.step_limit_x(0.60) + stand_x(0.06) 对得上。
@export var opponent_reach_x: float = 0.66

# ───────────── 对手扣杀 ─────────────
@export_group("对手扣杀")
## 对手扣杀机制总开关。
##
## ★ 用户要的「自己发球冒高 → 对方扣球，而且球越高越容易触发」。
##
## 修之前这**不算一个机制**，是个副作用：对手在拍面平面处按球的当前位置解速度
## （_solve_return），球来得多高就从多高打出去 —— 于是「发球冒高」这种高球
## 自然解出一条又陡又快的弧线，看着像扣杀，但概率完全不受控、也没法调。
## 现在做成显式的：按触球高度决定概率，命中就走 `_opp_smash_*` 那一组参数。
@export var opp_smash_enabled: bool = true
## 触球高度低于这个值 = 低球，**完全没有**扣杀可能（老老实实挡回去）。
##
## ★ 这两个阈值是**按本工程实测标定**的，不是拍脑袋：探针跑 20 次玩家发球、
##   对手接发球，实测触球高度全部落在 **0.917 ~ 1.019 m** 这一条窄带里
##   （原因是 opponent_contact_lead 就是按「球爬到 ≈1.0 m 高、正好是球拍
##   静止位」反推出来的，见那边的注释）。
##   所以 0.84 / 1.22 这一组正好把这条带铺开：0.92 → 约 30%、1.02 → 约 50%、
##   再高一截（真的被打出高弧线）→ 95%。阈值定成 1.00~1.42 那种「按真人
##   身高想当然」的数是测出来只有 5~9% 的 —— 等于没生效。
@export var opp_smash_h_low: float = 0.84
## 触球高度达到这个值 = 高球，扣杀概率吃满 opp_smash_chance_high。
@export var opp_smash_h_full: float = 1.22
## 低球高度的扣杀概率（= opp_smash_h_low 处）。0 = 低球绝不扣杀。
@export var opp_smash_chance_low: float = 0.15
## 高球高度的扣杀概率（= opp_smash_h_full 处）。
## ★ 用户要「提升 AI 扣球概率」，所以给到 0.95。
@export var opp_smash_chance_high: float = 0.95
## 扣杀时飞行时间的倍率（乘在 opponent_return_flight × 难度倍率之上）。
## 0.68 ≈ 快三成。别压到 0.5 以下：普通档 0.58×0.68 ≈ 0.39 s 已经是
## 「看到就得抬拍」了，再快玩家根本没有反应窗口，那不叫难、叫没法接。
@export var opp_smash_flight_scale: float = 0.68
## 扣杀时的球速上限（普通回球是 return_speed_max = 24）。
## 必须单独给：_solve_return 末尾会按 return_speed_max 封顶，
## 不抬这个上限的话「扣杀」会被削回普通球速，只剩个名头。
@export var opp_smash_speed_max: float = 32.0
## 扣杀落点往底线压的程度（占半台长比例），比普通回球的 0.32~0.94 更深。
@export var opp_smash_deep_lo: float = 0.62
@export var opp_smash_deep_hi: float = 0.99
## 扣杀落点横向散布（占半台比例），比普通回球更靠边。
@export var opp_smash_spread: float = 0.95

# ───────────── 连拍爽感循环（方案 C）─────────────
##
## 设计目标：**不新增任何界面**，把「这一局」本身做到让人想再打一次。
## 三根支柱：
##   ① 越长的对拉越值钱（金币倍率）→ 玩家有理由不急着拍死；
##   ② 连拍计数器 + 里程碑爆发 → 把「我刚打了 17 拍」变成看得见的成就；
##   ③ 连击让对手变凶 → 「我压制住了」本身有反馈，而不是只有比分在动。
##
## ★ 为什么先做这一套而不是赛事天梯 / 排位：A、B 都要新建界面，做完之前玩家
##   感受不到任何变化；C 改完第一局就能感觉到不一样，而且它是 A/B/D 的公共底座
##   —— 不管最后做哪套，「这一局好不好玩」都是前提。
@export_group("连拍爽感")
## 连拍金币倍率 = 1 + 连拍 / rally_bonus_divisor。
## ★ 10 → 12（重标定）：长回合仍然值钱，但滚雪球变慢。
##   12 → 12 拍 2 倍、24 拍 3 倍（正好和下面的封顶对上）。
@export var rally_bonus_divisor: float = 12.0
## 倍率封顶。不封的话理论上能靠一个超长回合把金币经济打穿。
## ★ 4.0 → 3.0（重标定）：上限从 30 拍压到 24 拍，且整条曲线更平。
@export var rally_bonus_max: float = 3.0
## 里程碑档位（连拍数）：5 拍「好球」/ 10 拍「精彩对拉」/ 20 拍「神球」。
## 用数组而不是写死 if 链，是为了以后能调档位（比如把 20 降到 15）
## 而不用动逻辑 —— 文案按档位序号取，见 _milestone_text()。
@export var rally_milestones: Array[int] = [5, 10, 20]
## 里程碑文案在连拍 HUD 上停留的秒数。
@export var rally_toast_time: float = 2.2
## 连拍计数器从第几拍开始显示。1 拍就跳出来太吵 —— 每球都闪一下，
## 玩家会把它当噪音过滤掉，反而注意不到真正长的对拉。
@export var rally_hud_min: int = 2
## ── 连拍 HUD 的「冲击力」参数（用户要求「做得很大很有冲击力」）──
## 基础字号 + 每上一档加多少。默认 56 → 5 拍 74 → 10 拍 92 → 20 拍 110。
## 原来最大只有 62，和右上角的比分差不多大，长回合根本压不住画面。
@export var rally_hud_base_size: int = 56
@export var rally_hud_tier_step: int = 18
## 每打一拍数字的弹跳幅度（放大到 1 + 这个值）。0 = 关掉动画。
@export var rally_pop_amount: float = 0.42
## 弹跳衰减速度，越大回弹越快。
@export var rally_pop_decay: float = 5.5
## 里程碑闪屏：持续秒数 / 最亮时的不透明度。
## ★ 只做一层很淡的染色（0.22），不遮画面 —— 闪屏是为了「这一下不一样」，
##   不是为了挡住球。tier 越低越淡（见 _check_rally_milestone）。
@export var rally_flash_time: float = 0.38
@export var rally_flash_alpha: float = 0.22
## 玩家每连赢 1 分，对手的扣杀概率乘上 (1 + step × (连胜 - 1))，封顶 max。
## step 0.28 / max 1.80 => 2 连胜 1.28 倍、3 连胜 1.56 倍、4 连胜吃满 1.80 倍。
## ★ 只乘在**扣杀概率**上，不动反应速度和回球质量 —— 那两样一改，
##   对手会从「变凶」直接变成「换了个难度」，玩家会以为是自己手滑。
@export var streak_rage_step: float = 0.28
@export var streak_rage_max: float = 1.80

## 连续得多少分开始提示「对手压上来了」。1 分不算连击，从第 2 分起才有话说。
const STREAK_NOTE_AT := 2

# ───────────── 流程 ─────────────
@export_group("流程")
@export var serve_delay: float = 1.2
@export var point_pause: float = 1.3
@export var auto_serve: bool = true

# ───────────── 一局比赛 ─────────────
##
## ★ 2026-10-03 经济重标定（方案 B 第一期）。改之前：
##    赢 11:7 ≈ 261 金币 / 输 7:11 ≈ 90 / 长拉锯赢 ≈ 384；
##    而全游戏能买的东西合计只有 1150 —— 玩家 5~8 局就买空商店，
##    金币从此只是个数字，每日任务发金币也就毫无吸引力。
##   重标定目标：一局 40~135，约 4~5 局 = 一个中档外观。
##   ★ 顺序不能反：必须**先把金币变稀缺**，再让每日任务成为金币的主要来源。
##     只做每日任务而不动数值，等于继续发「没人要的金币」。
@export_group("一局比赛")
## 打到多少分算赢一局（真实乒乓球是 11 分制）。到分后停表结算，
## 由玩家选「再来一局」或「返回主菜单」。
##
## 没有这个上限的话分数会无限涨，胜负经济（金币 / 任务 / 存档里的战绩）
## 就没有落点 —— 商店和任务奖励都靠「赢一局」驱动。
##
## ★ 这个数只是**门槛**，不是胜负判据 —— 还必须同时满足 match_win_margin
##   的领先分（见 _game_decided）。ITTF 2.11.3：10:10 之后先多得 2 分者胜。
@export var match_target: int = 11
## 一局要赢必须领先的分数（ITTF 2.11.3）。
## 2 = 标准规则：10:10 之后要打到 12:10 / 13:11 … 才算赢，11:10 不结束。
## ★ 原来只判 `>= match_target`，于是 10:10 之后**先得 1 分就赢**（11:10 直接结束），
##   把「加分局」整个吃掉了 —— 这是本工程对 2.11 最直接的违反。
@export var match_win_margin: int = 2
## 赢一局的基础金币
## ★ 120 → 45（重标定）
@export var coins_per_win: int = 45
## 每一分的基础金币（输赢都给，正反馈）
## ★ 8 → 3（重标定）
@export var coins_per_point: int = 3
## 对手得分不超过这个数就算「大胜」，额外奖励
@export var blowout_max_conceded: int = 5
## ★ 80 → 25（重标定）
@export var coins_blowout_bonus: int = 25
## 输一局的安慰奖。
##
## ★ 为什么要单独列一项而不是让它隐含在「得分照给」里：旧版输了也能拿
##   8×7×1.6 ≈ 90 金币，和赢一局的 261 只差 3 倍 —— 「输了也有大收益」是
##   通胀的主因之一，而且它是**隐式的**，调参数时根本看不见。
##   显式化之后可以单独调，也让「输一局到底值多少」有明确答案。
@export var coins_per_loss: int = 10

## 发球弧线最高点的上限（米）。超过就说明这一拍是「往天上抛」，
## 球会跑出画面上边，必须把飞行时间调快压下来。
@export var serve_apex_limit: float = 1.38
## 发球过网时至少要有多少余量（米，在网顶之上）
@export var serve_net_margin: float = 0.04
## 发球飞行时间的允许区间：太快会撞网，太慢会变高抛
@export var serve_flight_min: float = 0.34
@export var serve_flight_max: float = 0.70

@export var ball_path: NodePath
@export var paddle_path: NodePath
@export var player_path: NodePath
@export var opponent_path: NodePath

# 说明：不用 `var _ball: PingPongBall` 是因为 class_name 依赖全局类缓存，
# 用 --check-only / 部分加载路径下会解析失败。改成 Node3D + 调用处 `as` 强转。
var _ball: Node3D
var _paddle: Node3D
var _player: CharacterBody3D
var _opponent: Node3D
var _audio: Node

var _state: State = State.IDLE
var _timer: float = 0.0
var _swing_timer: float = -1.0
var _hit_cooldown: float = 0.0
var _last_hitter: int = Hitter.NONE   # 本回合最后一个碰到球的是谁
## 本回合球在两侧各自弹过几次台面。
## 取代了原来的 `_player_hit` / `_serve_bounced` 两个布尔量 ——
## 「发球有没有上台」和「对手有没有把球打回我这边」本质是同一件事：
## 球有没有合法地落到那一侧的台面。一个计数器同时表达两者，不会互相打架。
var _bounces_player: int = 0
var _bounces_opp: int = 0
var _net_hit: bool = false         # 本回合是否撞过网
var _point_over: bool = false      # 防重复计分

# ── 对手回球 ──
## 已经排定一次对手回球，正在等球飞到球拍平面
var _opp_armed: bool = false
var _opp_armed_t: float = 0.0      # 保险计时，见 opponent_return_timeout
var _opp_min_t: float = 0.0        # 触球前的最小等待，见 opponent_contact_delay
var _opp_will_hit: bool = false    # 掷骰结果：这一次对手接不接得到
var _opp_will_out: bool = false    # 掷骰结果：接到了但会不会打出界
## 这一拍对手是不是扣杀（见 opp_smash_* 那一组）。
var _opp_smash: bool = false
## 上一次对手触球的高度（m）—— 扣杀概率就是按它算的。
## 留成成员变量是为了能被探针读到：不落盘的话「球越高越容易扣」这条
## 只能靠肉眼在游戏里猜，没法验证。
var _opp_contact_y: float = 0.0
## 累计对手扣杀次数（结算面板 / 探针用）
var _opp_smashes: int = 0

var _player_score: int = 0
var _opponent_score: int = 0

# ── 发球 / 兜底 ──
## 这一球该谁发。由比分推算（见 _serve_side），不额外存状态，
## 这样「再来一局」「返回主菜单再开一局」都不会出现发球方错乱。
var _server: int = Hitter.OPPONENT
## 轮到玩家发球时已经等了多久
var _serve_wait: float = 0.0
## 下一次该在 _serve_wait 到多少时提醒玩家发球
var _serve_remind_at: float = 0.0
## 本回合距上一次「球产生事件」过了多久（卡死兜底用）
var _stall_t: float = 0.0
## 本次正手爆冲是否掷中了「必杀」
var _loop_kill: bool = false
## ★ 接发球阶段：从「发球出手」到「接发球那一拍打出去」之间为真。
## 单打双打都用它来压制「发球就得分」，见上面 serve_return_* 那一组。
var _serve_phase: bool = false
## AI 对手的体力。和玩家同一套规则（回合结算 + 得分回血），
## 见 _settle_rally_stamina()。
var _opp_stamina: float = 100.0
## 本回合 AI 接了几拍（结算消耗要用）
var _opp_rally_hits: int = 0

# ── 双打状态 ──
## 本局是不是 2v2。由 Game.doubles 在 apply_preferences() 里带进来。
var _doubles: bool = false
## 两名对手的节点（索引 0 = -x 侧、1 = +x 侧）。
## `_opponent` 始终指向**当前该接球的那一个** —— 这样挥拍、迈步、
## paddle_plane_z 那些既有代码一行都不用改，只需要在换人时换掉这个引用。
var _opp_nodes: Array = []
## 队友的球拍（索引同 _my_turn）。被操控的那个会隐藏 ——
## 相机就在他身上，画出来等于把整块屏幕糊住。
var _partner_nodes: Array = []
## ★ AI 队友模式：你只守自己这一侧（`_player_slot`），另一半边由 AI 自己接。
##   相机不再横移（_begin_switch 直接返回），队友那把拍子会自己跑位、自己挥。
var _partner_ai: bool = false
## AI 队友模式下「你」占的是哪个位（0 = -x 侧）。另一侧就是 AI 队友。
var _player_slot: int = 0
## AI 队友已排定一次回球，正在等球飞到他那把拍子的平面
var _par_armed: bool = false
var _par_armed_t: float = 0.0
var _par_min_t: float = 0.0
var _par_will_hit: bool = false
## AI 队友的发球倒计时（秒）。>= 0 = 「这一发的球权在队友手里」，
## 到点由 _do_partner_serve() 自动出手。负数 = 不适用（单打 / 对方发球 / 玩家发球）。
## 用「>= 0」而不是单独的 bool：省一个变量，也天然表达「还剩多久出手」。
var _par_serve_t: float = -1.0
## 我方 / 对方「下一个该接球的人」（0 或 1）。-1 = 这一回合还没人打过。
var _my_turn: int = 0
var _opp_turn: int = 0
var _last_my: int = -1
var _last_opp: int = -1
## 本球发球方队伍里的第几个人
var _server_idx: int = 0
## 相机横移：_switch_t 从 0 走到 1，期间直接写 Player.position.x。
var _switch_t: float = 1.0
var _switch_from: float = 0.0
var _switch_to: float = 0.0

# ── 统计（任务奖励 / 结算用）──
var _won_points: int = 0
var _lost_points: int = 0
var _rally_hits: int = 0          # 本回合已经对拉几拍
var _max_rally: int = 0           # 本局最长对拉
## ── 连拍爽感循环（方案 C）──
## 连续得分。输一分归零。只用来算对手的「凶度」，不影响判分。
var _win_streak: int = 0
## 本局因连拍倍率**多拿**的那部分金币（基础部分仍记在 _coins_from_points）。
## 单拎出来是为了结算面板能把它单独列一行 —— 「这局多亏了长回合」要看得见。
var _coins_from_rally: int = 0
## 当前正在闪的里程碑文案（空串 = 没在闪）与剩余秒数。
var _rally_toast: String = ""
var _rally_toast_t: float = 0.0
var _loop_winners: int = 0        # 用正手爆冲打出的制胜分
var _flick_winners: int = 0       # 用反手暴拧打出的制胜分
## 已经上报给单例的数量，用来去重（见 _progress_stats）
var _reported_loop: int = 0
var _reported_flick: int = 0
var _reported_serve_returns: int = 0
var _reported_rally10: int = 0
var _reported_rally20: int = 0
## 蹲着接到球的次数（任务「低姿防守」）
var _crouch_hits: int = 0
var _rally_last_kind: int = HitKind.NORMAL   # 本回合最后一拍是什么，用来归因制胜分
## ── 任务扩充（2026-10-03）新增的本局计数 ──
## ★ 全部做成「本局累计、结束时统一上报」而不是像 crouch_hits 那样即时 bump：
##   这几项都是**稀疏事件**（一个回合才可能 +1），攒着报没有滞后感；
##   而蹲接是高频动作，即时上报才不会漏。两种写法的差别只在这一点上。
var _serve_returns: int = 0      # 接住对手发球的次数
var _rally10_count: int = 0      # 本局打出几个 ≥10 拍的回合
var _rally20_count: int = 0      # 本局打出几个 ≥20 拍的回合
var _rally30_count: int = 0      # 本局打出几个 ≥30 拍的回合（周常用）
var _best_streak: int = 0        # 本局最长连续得分（任务「五连击」）
## ── 每日 / 每周任务的「今日维度」同步（经济重做第一期）──
##
## ★ 为什么另起一个字典而不是再铺十几个 _reported_xxx 成员：
##   今日维度和上面的生涯维度是**一一对应**的（winners_loop ↔ loop_today），
##   共用一个「已上报数」表就够，加维度时只改一处。
## ★ 键是「今日维度名」，值是**本局累计到多少了**（不是已上报数）——
##   因为一局里 _progress_stats 会被调很多次，只能靠差值上报。
var _today_sync: Dictionary = {}
## ── 排位（方案 B）──
## 连胜金币加成的**实际金额**（由 _end_match 结算，单独一行给玩家看）。
var _streak_bonus: int = 0

# ── 体力 / 蓄力状态 ──
var _stamina: float = 100.0
var _stamina_hold: float = 0.0     # > 0 时暂停恢复
var _charging: bool = false
var _charge_t: float = 0.0         # 0 ~ 1
## 探拍状态：_reach_holding 是「Shift 是否按下」，_reach_extend 是平滑后的 0~1。
var _reach_holding: bool = false
var _reach_extend: float = 0.0
var _hit_power: float = 0.0        # 本次挥拍携带的力量
var _hit_kind: int = HitKind.NORMAL
## 本次蓄力扣杀实际付了多少体力 —— 掷中「必杀」时按比例退还（见 _do_hit）。
## 不记的话「蓄满 → 打死」和「蓄满 → 没打死」付一样的钱，
## 玩家只会记住自己白花了体力，于是再也不肯蓄力。
var _last_charge_cost: float = 0.0
## 最近一次出球的球速 / 飞行时间（debug 与平衡探针用）
var _last_shot_speed: float = 0.0
var _last_shot_flight: float = 0.0
var _ambience_started: bool = false

# ── 挥拍节奏 / 挥空判罚 ──
## 挥拍锁：> 0 时不允许再挥（用户要的「不能连续挥拍」）。
## 值 = swing_valid_duration + swing_recover，也就是一次完整挥拍动作的时长。
var _swing_lock: float = 0.0
## 本次挥拍的窗口内有没有打到球 —— 没打到就是「挥空」，见 _on_swing_end()
var _swing_hit: bool = false

# ── 发球抛球 ──
## true = 正在「抛球中」。此时球不进飞行态，而是每帧被手动摆到抛物线上
## —— 所以它不会触发弹台/落地/判分那些信号，纯粹是个可见的抛球动作。
var _tossing: bool = false
var _toss_t: float = 0.0
var _toss_x: float = 0.0
var _toss_z: float = 1.30
var _toss_y: float = 1.11
var _toss_vy: float = 0.0
## 这一发「球落回多高就击出」。= 抛球起点的高度（跟着蹲姿走），见 _serve_launch_y。
var _toss_strike_y: float = 1.11

# ── 蹲姿取舍：来球在玩家这侧的落点 z ──
## 用户要的「蹲下回球更有力量，但接不到近台的短球」。
## 记的是**球弹在我方半台那一下的 z**（不是球当下的 z）：短球是「落在台内靠网处」的球，
## 蹲下时重心低、够不到网前的短球，这是真实乒乓里的取舍。
## -1 = 本回合还没有球落在我方半台。
var _player_bounce_z: float = -1.0

# ── 一局 / 暂停 ──
## 一局结束后不再发球、不再计分，等玩家在结算面板里选下一步
var _match_over: bool = false
var _overlay: CanvasLayer
var _pause_open: bool = false
## 本局靠得分赚到的金币（结算面板展示用，赢局奖励另外算）
var _coins_from_points: int = 0
## ── 连拍 HUD（屏幕中上方）──
## 见 _build_rally_hud() / _update_rally_hud()。
var _rally_hud_root: VBoxContainer
var _rally_label: Label
var _rally_sub_label: Label
## 每打一拍的弹跳强度（1 → 0，见 rally_pop_decay）。
var _rally_pop: float = 0.0
## 上一帧显示的连拍数。用来判断「又打了一拍」—— 只看数字有没有变大，
## 换球归零再涨回来不算。
var _rally_shown: int = 0
## 里程碑闪屏（叠在 _hud 最底层的一块全屏色块）。
var _rally_flash: ColorRect
var _rally_flash_t: float = 0.0
var _rally_flash_peak: float = 0.0

# ── 合规发球（先弹己方半台）+ 发球轨迹提示 ──
## 这一发的落点计划：{server_side, own_x_cands, opp_x, opp_z, flight, spin}。
## 整发期间固定 —— 轨迹提示线和实际发出的一模一样。
var _serve_plan: Dictionary = {}
var _serve_traj: MeshInstance3D
var _serve_traj_mesh: ImmediateMesh
var _serve_traj_rings: Array = []
var _serve_preview_t: float = 0.0

var _hud: CanvasLayer
var _label: Label
var _score_label: Label
## 右上角比分区的大数字（左=自己，右=对手）—— 见 _build_score_hud。
## 单独两个 Label 而不是塞进一个字符串，是为了能分别上色/加粗，
## 让「哪个数字是我的」不用靠数第几个来猜。
var _player_score_label: Label
var _opp_score_label: Label
var _score_panel: PanelContainer
## 比分面板上一次刷新的值 —— 只在变化时才重刷主题（见 _update_hud）
var _hud_score_cache := Vector2i(-999, -999)
var _grip_mode: int = 0
## 旋转开关状态（用户要的「Z/C 点按触发、再按取消」）：
##   +1 = 上旋球（Z）　0 = 普通　-1 = 下旋球（C）
## 一按到底、状态常驻，不再需要按住 —— 见 _unhandled_input 里那段。
var _spin_mode: int = 0
var _landing_marker: Node3D
var _stamina_bar: ProgressBar
var _stamina_fill: StyleBoxFlat
var _opp_stamina_bar: ProgressBar
var _opp_stamina_fill: StyleBoxFlat
var _charge_bar: ProgressBar
var _charge_fill: StyleBoxFlat
var _power_label: Label

# ── 联赛（比赛模式）的单场 BO5 ──
## 本场是不是赛事场次。为 true 时：
##   · 难度由对手评分锁死（且不回写单例，免得打一届联赛把玩家的全局难度改掉）
##   · 一局结束**不**计战绩、不给赢局金币，只记局分
##   · 攒够 3 局才把整场结果交给 Game.report_tournament_match()
## 局分本身存在单例上（见 game_state.gd 的 tour_won/tour_lost）——
## 「打下一局」是重载场景，场景里的成员变量活不过 reload。
var _tour: bool = false
var _tour_opp: Dictionary = {}
var _difficulty_locked: bool = false
## 本局是不是排位赛。由 Game.ranked 在 apply_preferences() 里带进来。
var _ranked: bool = false
## 排位赛的「本场变化」回执（Game.report_rank_match 的返回值）。结算面板读它。
var _rank_report: Dictionary = {}
## ★ 连续难度 t ∈ [0, 4]：0 = 简单、1 = 普通、2 = 困难、3 = 专家、4 = 大师。
##
## 为什么要有这个浮点，而不是直接用整数 difficulty：
##   排位有 21 个小级，映射到 5 个整数档的话相邻四五级手感完全一样，
##   「升了一级」感受不到。所有 AI 参数改走 _tier5() 插值之后，
##   每升一级球都真的快一点点。
##
## ★ 自由对战 / 赛事仍然用整数档：_tier5() 在 t 取整数时逐位等于原来的
##   那一档（小数部分为 0），所以**既有手感一点没变**，不需要重新标定。
var _diff_t: float = 1.0
var _tour_label: Label


func _ready() -> void:
	# 不 randomize() 的话 Godot 每次用同一个默认种子，"随机发球"会变成固定落点
	randomize()
	_stamina = max_stamina
	apply_preferences()
	_resolve_refs()
	if _doubles:
		_setup_doubles()
	_build_landing_marker()
	_build_serve_traj()
	_build_hud()
	_build_pause()
	_self_check()
	set_state(State.IDLE)
	# 排位赛开打前把「现在什么段位、AI 强度多少」讲清楚 ——
	# 不讲的话玩家只会觉得「今天 AI 怎么突然变准了」，会归因成作弊。
	if _ranked:
		_announce_rank()
	# 面板开着时游戏一直在跑（_ready 里 auto_serve 会立刻开始发球），
	# 所以结算面板必须先建好、但不能挡着开局。
	if auto_serve:
		start_serve()


## 启动自检：缺了任何一样关键引用就在屏幕上直接喊出来。
##
## ★ 为什么要有这一段：pingpong_game 拿不到球 / 球拍 / 玩家时**不会报错**，
##   它只是「什么都不做」—— 发球没反应、按键没反应、球定在原地，
##   从外面看就是「游戏卡死了」，而控制台干干净净、一个错误都没有。
##   这种静默失效排查一次要半天（这次就是这么过去的），
##   所以宁可在这里明着喊一句，也不要再让玩家对着卡住的画面猜。
func _self_check() -> void:
	var missing: Array[String] = []
	if _ball == null:
		missing.append("球(Ball)")
	if _paddle == null:
		missing.append("球拍(PaddleRig)")
	if _player == null:
		missing.append("玩家(Player)")
	if _opponent == null:
		missing.append("对手(Opponent)")
	if missing.is_empty():
		return
	var txt := "启动自检失败：找不到 " + "、".join(missing) \
		+ "　—— 场景节点名或路径对不上，本局无法开始"
	push_error(txt)
	_msg(txt)


## 把主菜单里选好的难度应用到本局。
## 场馆主题不在这里管 —— court_builder._ready() 自己会去读 Game.current_theme()，
## 而且它跑在父节点 _ready() 之前（Godot 子节点先就绪），这里再设也晚了。
##
## 赛事场次压过菜单难度：联赛里遇到的对手有强有弱，那一场该多难由对手评分说了算，
## 而不是玩家在菜单里挑的那一档。
func apply_preferences() -> void:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return
	# ★ 双打优先于赛事判定，而且必须放在 tour_begin() **之前**：
	#   只要档案里有一届没打完的赛事，tour_begin() 就会返回一个对手，
	#   于是「双打」会被静默降级成一场赛事单打 —— 玩家付了 50 金币入场，
	#   结果打的是 1v1，连队友都没有。双打是独立付费买的模式，直接把赛事摘掉。
	if bool(g.get("doubles")):
		_doubles = true
		_partner_ai = bool(g.get("partner_ai"))
		_tour = false
		_tour_opp = {}
		_difficulty_locked = false
		_ranked = false
		set_difficulty_t(float(clampi(int(g.get("difficulty")), 0, 4)))
		return

	# ── 排位赛（方案 B）──
	# 排位也压过赛事：排位是「我想上分」的明确选择，不能被一个没打完的
	# 联赛赛程劫走。难度由段位算出来（连续值），不是菜单里那一档。
	if bool(g.get("ranked")):
		_ranked = true
		_tour = false
		_tour_opp = {}
		# 排位的难度是**算出来的**，所以不能让 set_difficulty_t 写回档案 ——
		# 置上 _difficulty_locked 就走「特殊模式」那条分支。
		_difficulty_locked = true
		set_difficulty_t(float(g.call("rank_difficulty_t")))
		return

	_ranked = false
	# ★ 赛事场次。`tour_begin()` 自己会判 `Game.tour_entry` —— 只有联赛面板里
	#   点了「开始本场」才返回对手，所以这里无条件调它是对的。
	#   ★ 原来 `tour_begin()` 只看「档案里有没有没打完的赛事」，于是**点「开始比赛」
	#   进比赛也被劫持成赛事场次**，难度跟着对手评分走、菜单里选的那一档完全作废
	#   （用户 2026-10-03 报的）。现在「有赛事」和「这一场是赛事」是两件事。
	if g.has_method("tour_begin"):
		_tour_opp = g.call("tour_begin")
		_tour = not _tour_opp.is_empty()
	if _tour:
		_difficulty_locked = true
		difficulty = clampi(int(_tour_opp.get("difficulty", 1)), 0, 4)
		_diff_t = float(difficulty)
		return
	_difficulty_locked = false
	set_difficulty_t(float(clampi(int(g.get("difficulty")), 0, 4)))


func _resolve_refs() -> void:
	if ball_path != NodePath(""):
		_ball = get_node_or_null(ball_path)
	if _ball == null:
		_ball = get_node_or_null("Ball")
	if _ball != null:
		_connect(_ball, "bounced_table", Callable(self, "_on_bounced_table"))
		_connect(_ball, "bounced_twice", Callable(self, "_on_bounced_twice"))
		_connect(_ball, "hit_net", Callable(self, "_on_hit_net"))
		_connect(_ball, "landed_floor", Callable(self, "_on_landed_floor"))

	if paddle_path != NodePath(""):
		_paddle = get_node_or_null(paddle_path)
	if _paddle == null:
		_paddle = get_tree().get_first_node_in_group("paddle")

	if player_path != NodePath(""):
		_player = get_node_or_null(player_path)
	if _player == null:
		var p := get_tree().get_first_node_in_group("player")
		if p is CharacterBody3D:
			_player = p

	if opponent_path != NodePath(""):
		_opponent = get_node_or_null(opponent_path)
	if _opponent == null:
		_opponent = get_node_or_null("Opponent")

	_audio = get_node_or_null("Audio")


func _connect(src: Node, sig: String, cb: Callable) -> void:
	if src.has_signal(sig) and not src.is_connected(sig, cb):
		src.connect(sig, cb)


## 统一走 callv，音效节点缺失（比如离屏做几何导出时）也不会报错
func _audio_call(m: String, args: Array = []) -> void:
	if _audio != null and _audio.has_method(m):
		_audio.callv(m, args)


# ───────────── 双打 ─────────────
## 双打的规则骨架（用户定的三条）：
##   ① 2v2，我和队友各守半边
##   ② **必须轮流击球** —— 同一人连打两次直接判失分
##   ③ 控制权**自动**在两人之间切换：轮到谁接球，相机就挪到他身上
##
## ③ 是 ② 的自然结果：既然规则强制换人，那就别让玩家再按一次键 ——
##   相机横移到该接球的那个人身上，玩家只要「打」，不用管「用谁打」。
##
## ★ 接发球的轮换按真实双打来：
##   发球顺序 A0 → B0 → A1 → B1（每 serves_per_player 分换一次发球方），
##   接发球的是**对角**那个人，所以「接发球者索引 = 1 - 发球者索引」；
##   之后各队内部严格交替 —— A0 发球 → B1 接 → A1 接 → B0 接 → A0……
##   四个人正好轮满一圈，不会有人连打两次。

## 某名我方队员**这一分**的站位 x。
## ★ 双打里它是动态的：站在自己右半区的那个人随发球块轮换（见 _my_right_idx），
##   所以同一个索引在不同分上会落在不同的 x —— 这正是「两人换位」。
func _my_x(idx: int = -1) -> float:
	var i := _my_turn if idx < 0 else idx
	if _doubles:
		return doubles_partner_x if i == _my_right_idx() else -doubles_partner_x
	return -doubles_partner_x if i == 0 else doubles_partner_x


func _opp_x(idx: int) -> float:
	if _doubles:
		# 对手在 z<0、朝 +z 看 → 它的右半区在世界 x < 0
		return -doubles_opponent_x if idx == _opp_right_idx() else doubles_opponent_x
	return -doubles_opponent_x if idx == 0 else doubles_opponent_x


## 把 `_opponent` 指向当前该接球的那名对手。
## 这是整个双打里最省事的一招：挥拍、迈步、paddle_plane_z 那些既有代码
## 全都只认 `_opponent` 一个引用，换人时换掉它，一行都不用改。
func _set_active_opponent(idx: int) -> void:
	if not _doubles or _opp_nodes.size() != 2:
		return
	_opponent = _opp_nodes[clampi(idx, 0, 1)]


## 布置双打的场面：第二名对手 + 队友模型。
func _setup_doubles() -> void:
	if _opponent == null:
		return
	var parent := _opponent.get_parent()
	if parent == null:
		return
	# 0 号站 -x、1 号站 +x。stand_x 是 opponent_player 的导出量，
	# 它每帧按「stand_x + 迈步偏移」重算 position，所以改这个量它自己就走过去了。
	_opponent.set("stand_x", _opp_x(0))
	if _opponent.has_method("reset_stance"):
		_opponent.call("reset_stance")
	# ★ 第二名对手：新建一个挂同一份脚本的空节点，而不是 duplicate() 现有的那个。
	#   duplicate() 会把已经建好的 ArmR / Paddle 一起拷过来，而 _ready() 又会
	#   再建一遍同名节点 —— 两套同名的球拍叠在一起，get_node() 取到哪一个全看顺序。
	#   空节点 + set_script 让 _ready() 从头干净地建一次。
	var o2 := Node3D.new()
	o2.name = "OpponentB"
	o2.set_script(_opponent.get_script())
	# stand_x 必须在 add_child **之前**设好：opponent_player._ready() 会拿它定位，
	# 而 _ready 在进树那一刻就跑完了，之后再设只能靠迈步慢慢挪过去。
	o2.set("stand_x", _opp_x(1))
	parent.add_child(o2)
	_opp_nodes = [_opponent, o2]      # 0 = -x，1 = +x
	_build_partners()
	if _partner_ai and _player != null:
		# AI 队友模式：把玩家摆到他自己那一侧。
		# 之后就交给 player_movement 了 —— 他爱往哪走往哪走，
		# 但「自己这一侧」得有个明确的起点，不然开局站在台中间很怪。
		_player.position.x = _my_x(_player_slot)
		_apply_partner_visibility()


## 队友的**球拍**。
##
## ★ 用户明确要「渲染队友的乒乓球拍，不需要队友模型」。
##   上一版是拿看台那个顶点色角色（spectator.glb）当队友，实测两个问题：
##   · 相机离队友只有 1.56 m，一具 1.74 m 的身体在屏幕上糊掉一大块，
##     而且切换控制权时要靠「藏起来 / 亮出来」躲穿模，切换那一瞬间会闪；
##   · 观众席已经有 200 多个同款人了，场上再摆两个一模一样的，反而廉价。
##   现在改成和对手同一套语言：**一把悬空球拍**。要传达的信息就两件事
##   （他在哪一侧、他挥了没有），球拍完全够用，而且两边视觉风格统一。
##
## 实现上直接复用 opponent_player.gd：它本来就有 show_figure=false 的
## 「只留球拍」分支（关节枢轴保留、只是不画身体），整体镜像过来即可。
func _build_partners() -> void:
	if not doubles_show_partner:
		return
	var sc := load("res://opponent_player.gd")
	if not (sc is Script):
		push_warning("双打：队友球拍脚本没载入成功，这一局不画队友")
		return
	var parent := _opponent.get_parent() if _opponent != null else self
	for i in range(2):
		var n := Node3D.new()
		n.name = "PartnerPaddle%d" % i
		n.set_script(sc)
		# ★ 站位必须在 add_child **之前**设好：opponent_player._ready() 会拿
		#   stand_x / stand_z 定位，而 _ready 在进树那一刻就跑完了。
		n.set("stand_x", _my_x(i))
		n.set("stand_z", doubles_partner_z)
		n.set("show_figure", false)
		# ★ 转 180° = 把对手那套配置整体镜像到我方半台，一步到位：
		#   blade_target 的 +z 变成世界 -z（拍面伸向球台），
		#   法线 (0,0,1) 变成 (0,0,-1)（拍面朝球台）。
		#   不用另配一套镜像参数，少一处能对不上的地方。
		n.rotation_degrees = Vector3(0.0, 180.0, 0.0)
		parent.add_child(n)
		_partner_nodes.append(n)


## 相机（= Player 本体）横移到第 idx 名队员的站位。
func _begin_switch(idx: int) -> void:
	_my_turn = idx
	# ★ AI 队友模式：相机**不横移**。
	#   你只守自己那一侧（`_player_slot`），另一半边的球由 AI 队友自己接，
	#   所以这里只记「下一拍该谁」，画面保持在玩家身上 ——
	#   这也是这个模式和「自动切换」唯一的画面差别。
	if _partner_ai:
		# ★ 严格 ITTF（用户定）：AI 队友模式**也要换位** ——
		#   ITTF 2.6.3 要求发球 / 接发球的人都得站在自己右半区，
		#   而那个人每 2 个发球块轮换一次，于是玩家本人也跟着左右换边。
		#   走的是和「自动切换」同一套平滑插值（_update_switch），
		#   所以看到的是横移过去，不是瞬移。
		_apply_partner_visibility()
		if _player == null:
			_switch_t = 1.0
			return
		var ptx := _my_x(_player_slot)
		if absf(_player.position.x - ptx) < 0.02:
			_player.position.x = ptx
			_switch_t = 1.0
			return
		_switch_from = _player.position.x
		_switch_to = ptx
		_switch_t = 0.0
		return
	if not _doubles or _player == null:
		_apply_partner_visibility()
		return
	# ★ 移动途中两个队友**都先藏起来**。
	#   相机要从 A 点的位置走到 B 点，而 A 点上正好站着 A 本人 ——
	#   如果这一刻就把 A 显示出来，等于把相机塞进他身体里，整屏都是肉色内面。
	#   等走完了（_update_switch 里）再亮出「现在没被操控的那一个」，
	#   这时相机和他隔着 1.56 m，才是正常的队友视角。
	for p in _partner_nodes:
		p.visible = false
	var tx := _my_x(idx)
	if absf(_player.position.x - tx) < 0.02:
		_player.position.x = tx
		_switch_t = 1.0
		_apply_partner_visibility()
		return
	_switch_from = _player.position.x
	_switch_to = tx
	_switch_t = 0.0


## 只显示「现在没被操控」的那个队友 ——
## 被操控的那个人身上就是相机，画出来等于拿一具身体糊住整个屏幕。
func _apply_partner_visibility() -> void:
	# AI 队友模式里「被操控的」恒定是玩家自己那一侧（`_player_slot`），
	# 不跟着 _my_turn 走 —— 相机压根没动过。
	var hide_idx := _player_slot if _partner_ai else _my_turn
	for i in range(_partner_nodes.size()):
		_partner_nodes[i].visible = (i != hide_idx)


func _update_switch(delta: float) -> void:
	# ★ 这里**不能**再排除 `_partner_ai`：用户选了「严格按 ITTF 每 2 分换位」，
	#   AI 队友模式下玩家本人也要跟着左右换边（见 _begin_switch）。
	#   原来一句 `_partner_ai → return` 把换位目标设了却永远走不到 ——
	#   实测玩家 x 恒为自己开局那一侧，换位整个失效。
	if not _doubles or _switch_t >= 1.0 or _player == null:
		return
	_switch_t = minf(1.0, _switch_t + delta / maxf(doubles_switch_time, 0.001))
	_player.position.x = lerpf(_switch_from, _switch_to,
							   smoothstep(0.0, 1.0, _switch_t))
	if _switch_t >= 1.0:
		# 走到位了才把「另一个人」亮出来 —— 这时候相机离他 1.56 m，不会穿模
		_apply_partner_visibility()


## 我方击球后的轮换记账。
func _note_my_hit() -> void:
	_last_my = _my_turn
	if _last_opp >= 0:
		_opp_turn = 1 - _last_opp
	# _last_opp < 0 表示这是我方发球后的第一拍 ——
	# 接发球的人已经按「对角」规则在 start_serve 里排好了，这里不能动。


## 对方击球后的轮换记账，并立刻把控制权交给下一个该接球的人。
func _note_opp_hit() -> void:
	_last_opp = _opp_turn
	if _last_my >= 0:
		_my_turn = 1 - _last_my
	_begin_switch(_my_turn)


# ───────────── 难度 ─────────────
## 五档难度的名字。和 @export_enum 上那一串必须保持一致。
const DIFF_NAMES := ["简单", "普通", "困难", "专家", "大师"]

## 五档参数之间线性插值。
##
## ★ t 取整数时逐位等于原来那一档（小数部分为 0），所以「自由对战 / 赛事」
##   的手感**一点没变**，不需要重新标定；只有排位的新档位才落在中间。
## ★ 用 match 而不是临时数组：这个函数在每帧路径上会被调好几次，
##   每次建一个 5 元素 Array 是白白的内存抖动。
func _tier5(a: float, b: float, c: float, d: float, e: float) -> float:
	var t := clampf(_diff_t, 0.0, 4.0)
	var i := int(floor(t))
	var f := t - float(i)
	var lo := b
	var hi := b
	match i:
		0: lo = a; hi = b
		1: lo = b; hi = c
		2: lo = c; hi = d
		3: lo = d; hi = e
		_: lo = e; hi = e
	return lerpf(lo, hi, f)


func _flight_time() -> float:
	return _tier5(easy_flight_time, normal_flight_time, hard_flight_time,
		expert_flight_time, master_flight_time)


func _spread() -> float:
	return _tier5(easy_spread, normal_spread, hard_spread,
		expert_spread, master_spread)


## 够球范围的难度倍率。乘在 hit_reach_x / z / y 三个半轴上。
func _reach_scale() -> float:
	return _tier5(easy_reach_scale, normal_reach_scale, hard_reach_scale,
		expert_reach_scale, master_reach_scale)


## 对手发球的侧旋强度。落在 [-s, +s] 之间，符号随机 ——
## 左右都会拐，玩家不能靠「站偏一边」预习。
func _serve_spin() -> float:
	return _tier5(easy_serve_spin, normal_serve_spin, hard_serve_spin,
		expert_serve_spin, master_serve_spin)


## 发球落点向边线偏的程度（0 = 半台内均匀，1 = 几乎全贴边线）。
func _serve_edge() -> float:
	return _tier5(easy_serve_edge, normal_serve_edge, hard_serve_edge,
		expert_serve_edge, master_serve_edge)


## 发短球的概率。短球落点贴网，第二跳还在台内且很低，抽不了。
func _serve_short_chance() -> float:
	return _tier5(easy_serve_short, normal_serve_short, hard_serve_short,
		expert_serve_short, master_serve_short)


## 体力对「够球范围」的折扣 —— 用户要的「体力与击球成功概率正相关」。
## 满体力 = 1.0，空体力 = stamina_reach_floor（默认 0.72）。
func _stamina_reach_scale() -> float:
	var sl := clampf(_stamina / maxf(max_stamina, 0.01), 0.0, 1.0)
	return lerpf(stamina_reach_floor, 1.0, sl)


## 三轴半轴（米）。这是 _check_hit() 的全部容差来源，单独抽出来方便探针量。
func _reach_box() -> Vector3:
	var k := _reach_scale() * _stamina_reach_scale() * (1.0 + power_reach_bonus * _hit_power)
	# ★ 接发球时够球范围放宽：对手的发球带侧旋、还往边线/贴网送，
	#   不放宽的话「开球就得分」会非常常见 —— 那是运气不是难度。
	#   放宽的是**够得到**，不是**打得死**（杀伤力在 _do_hit 里被压回去了）。
	if _serve_phase:
		k *= 1.0 + serve_return_reach_bonus
	return Vector3(hit_reach_x * k, hit_reach_y * k, hit_reach_z * k)


func difficulty_name() -> String:
	if _ranked:
		return "排位"
	return DIFF_NAMES[clampi(difficulty, 0, 4)]


func set_difficulty(d: int) -> void:
	set_difficulty_t(float(clampi(d, 0, 4)))


## 设定**连续难度**。整数档传进来等价于原来的行为（小数部分为 0）。
## 排位用 _diff_t 的中间值让 AI 强度跟着段位平滑爬。
func set_difficulty_t(t: float) -> void:
	_diff_t = clampf(t, 0.0, 4.0)
	# difficulty 仍然维护着：Tab 键在自由对战里还是按整数档循环，
	# 结算面板 / HUD 上显示的也是这个整数档的名字。
	difficulty = clampi(int(round(_diff_t)), 0, 4)
	# 同步回单例：局内 Tab 调过之后回主菜单，「开始比赛」面板上显示的
	# 应当还是刚玩的那一档，不然下次进局难度会莫名变回去。
	# 赛事场次 / 排位赛除外 —— 那两种的难度是跟着对手走的，写回去会把玩家
	# 在菜单里设的全局难度悄悄改掉。
	var g := get_node_or_null("/root/Game")
	if g != null and not _difficulty_locked and not _ranked:
		g.call("set_difficulty", difficulty)
	if _ranked:
		# 排位里 Tab 也允许调（当作「手热/手冷」的临时微调），但不写回档案 ——
		# 段位算出来的强度才是这个模式的「正版难度」。
		_msg("排位赛　AI 强度 %.2f / 4（段位 %s）"
			% [_diff_t, _rank_name()])
	elif _difficulty_locked and _tour:
		_msg("赛事场次　对手 %s　难度固定为 %s"
			% [str(_tour_opp.get("name", "?")), difficulty_name()])
	else:
		_msg("难度：" + difficulty_name())


func _rank_name() -> String:
	var g := get_node_or_null("/root/Game")
	if g == null or not g.has_method("rank_name"):
		return "—"
	return str(g.call("rank_name"))


## 排位赛开场提示。放在 _build_hud() 之后调，否则会被 HUD 的初始化文案盖掉。
func _announce_rank() -> void:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return
	_msg("排位赛　%s　AI 强度 %.2f / 4　距 %s 还差 %d 分"
		% [_rank_name(), _diff_t, str(g.call("rank_next_name")),
			maxi(int(g.call("rank_div_span")) - int(g.call("rank_into_div")), 0)])


# ───────────── 状态机 ─────────────
func set_state(s: State) -> void:
	_state = s


## ───────────── 发球轮换 ─────────────
## 现在该谁发球 —— 严格按 ITTF 2.13（含双打的 2.13.5）推。
##
## 用比分当发球顺序的时钟、而不是另存一个计数器，好处是它天然幂等：
## 场景重载（「再来一局」）之后分数归零，发球顺序自动跟着回到开头，
## 不会出现「上一局攒的发球计数被带进下一局」这种脏状态。
##
## 单打：每 serves_per_player 分换发球方。
##
## 双打（A = 我方，A0 = 玩家、A1 = AI 队友；B = 对手）：
##   ITTF 2.13.5 —— 每一方连发 serves_per_player 分后换边，**换边的同时队内也换人**
##   （上一发球员的同伴成为发球员、上一接发球员的同伴成为接发球员）。
##   于是发球人按 A0 → B0 → A1 → B1 → A0 → … 四步一循环、8 分回到起点：
##   玩家发第 1-2 分，对手 A 发第 3-4 分，**队友发第 5-6 分**，对手 B 发第 7-8 分。
##   映射到代码：换边看 block 的奇偶，队内换人看 block/2 的奇偶
##   （GDScript 的 int / int 是整除，block/2 正好把 0,1 → 0、2,3 → 1）。
##
## 10:10 之后（ITTF 2.13.6）：改成**每个运动员轮流发 1 分**。
##   做法是把「每 2 分一块」拆成「每 1 分一块」，块号从 10:10 那一刻的块号接着往下数
##   （20/per + 已打的加时分），所以接续处连续、不会跳人。
##   队内换人仍是「每 2 块一换」，正好等于加分局里每人各发 1 分。
func _serve_side() -> int:
	var block := _serve_block()
	if _doubles:
		_server_idx = (block / 2) % 2
	return Hitter.PLAYER if block % 2 == 0 else Hitter.OPPONENT


## 当前是第几个「发球块」—— 每 serves_per_player 分一块。
## 双打里这一个数同时决定三件事：哪一队发、队内第几个人发、
## 以及**谁站在自己右半区**（见 _my_right_idx / _opp_right_idx）。
func _serve_block() -> int:
	var per := maxi(serves_per_player, 1)
	var played := _player_score + _opponent_score
	if _player_score >= DEUCE_POINTS and _opponent_score >= DEUCE_POINTS:
		return int(2 * DEUCE_POINTS / per) + (played - 2 * DEUCE_POINTS)
	return int(played / per)


## 这一分**我方（A 队）站在自己右半区**（世界 x > 0）的队员索引。
##
## ★ ITTF 2.6.3 规定双打的球须依次触及「发球方的右半区」和「接发球方的右半区」；
##   2.13.5 又规定每次换发球时「前一个接发球者成为发球者、前一个发球者的搭档
##   成为接发球者」。两条合起来就逼出一个结论：**发球方和接发球方都必须由
##   站在自己右半区的人执行**，而这个人每 2 个发球块在两队各自轮换一次
##   —— 也就是真人双打里两个人不停地左右换位的那个走位。
##   所以「谁站右半区」是随块号走的动态量，不是固定值。
##
## （从数值上看，它正好是「A 队这一分的关键人」：
##   A 队发球的块上是发球者，B 队发球的块上是接发球者。）
func _my_right_idx() -> int:
	return int((_serve_block() + 1) / 2) % 2


## 对手（B 队）站在**自己**右半区（朝 +z 看 → 世界 x < 0）的队员索引。
func _opp_right_idx() -> int:
	return int(_serve_block() / 2) % 2


## 现在是不是「轮到玩家发球、正在等他出手」
##
## ★ 球权在队友身上时不算 —— 双打发球顺序是 2 分一换、队内 4 分一轮，
##   轮到队友那一发如果他不上手，整个发球轮换就作废了（见 _partner_serving）。
func waiting_player_serve() -> bool:
	return not _match_over and _state == State.SERVE_DELAY \
		and _server == Hitter.PLAYER and not _partner_serving()


## 这一发的球权是不是在 AI 队友手里。
##
## 三个条件缺一不可：双打 + 开了 AI 队友 + 这一发该我方发但发球人不是玩家。
## `_server_idx` 由 _serve_side() 在本局每次发球前算好（队内第几个人发）。
func _partner_serving() -> bool:
	return _doubles and _partner_ai and _server == Hitter.PLAYER \
		and _server_idx != _player_slot


func start_serve() -> void:
	# 一局已结束时不再发球 —— 结算面板开着，底下不该还有球在飞
	if _match_over:
		return
	_server = _serve_side()
	_timer = serve_delay
	_serve_wait = 0.0
	_tossing = false
	_toss_t = 0.0
	_serve_remind_at = player_serve_notice
	if _doubles:
		_begin_doubles_point()
	set_state(State.SERVE_DELAY)
	if _server == Hitter.PLAYER:
		# 这一发的落点计划现在定下来（轨迹提示线跟着它走）
		_serve_plan = _plan_serve(1)
		_serve_preview_t = 0.0
		if _partner_serving():
			# ★ 球权在队友手里：不摆到玩家手上，改成「持球等他出手」。
			#   原来这里一律走玩家分支，于是每次轮到队友发球都变成
			#   「站在自己半边的人替队友发球」—— 双打的发球轮换等于白排。
			_par_serve_t = partner_serve_delay
			_hold_ball_for_partner()
			_msg("轮到队友发球…")
		else:
			_par_serve_t = -1.0
			_hold_ball_for_serve()
			_msg("该你发球　先点左键抛球 → 等球下落时再点左键击出（按住空格可蓄力）")
	else:
		_par_serve_t = -1.0
		_msg("准备接球…")


## 每一分开局时排好双打的轮换指针。
##
## 接发球的是**对角**那个人（真实双打的发球要过对角），
## 所以「接发球者索引 = 1 - 发球者索引」。之后的交替交给 _note_my_hit / _note_opp_hit。
func _begin_doubles_point() -> void:
	_last_my = -1
	_last_opp = -1
	# 每分开始先按新的发球块把四人摆到各自该站的半区（含玩家换位）
	_layout_doubles()
	# ★ `_begin_switch(_my_right_idx())`：无论哪一方发球，我方这一分的「关键人」
	#   （发球者或接发球者）就是站在自己右半区的那个人 —— 这也是相机 / 控制权
	#   该在的位置。原来对手发球时传的是 `1 - _server_idx`，那是另一个人的索引。
	_begin_switch(_my_right_idx())
	if _server == Hitter.PLAYER:
		_last_my = _server_idx
		# ★ 接发球者是**对手站在自己右半区的那个人**（球会落到那边）。
		#   原来是 `1 - _server_idx` —— 在 A 队发球的块上算出来的是对面左半区的人
		#   （实测发球落点因此反向，32 发只合规 16 发）。
		_opp_turn = _opp_right_idx()
	else:
		_last_opp = _server_idx
	# 对手那边：轮到他发球就让发球者当「当前对手」；我方发球则先亮出接发球的那个
	_set_active_opponent(_server_idx if _server == Hitter.OPPONENT else _opp_turn)


## 把双打的四个人按当前发球块摆到 ITTF 要求的半区上。
##
## ★ 每次换发球都要重摆 —— 因为「谁站在自己右半区」随块号轮换，
##   两队各自是**两人互相换位**（发球者与接发球者交替）。
##   玩家的位置不在这里硬设：交给 _begin_switch 走同一套平滑插值，
##   否则会看到他瞬移。
##
## ★★ 光改 `stand_x` 不够，必须同时 `reset_stance()` —— 用户报的
##   「轮换时 AI 队友（没）换位置」就是这个：
##     opponent_player 的实际站位是 `stand_x + _step_x`，而 `_step_x`
##     是**上一分的迈步残留**（去接球时最多迈出去 step_limit_x = 0.60 m）。
##     换块时 stand_x 跳了 1.56 m，残留的 _step_x 却原封不动留着，
##     于是「换位后」的实际站位 = 新 stand_x + 旧迈步，最多偏 0.60 m。
##     实测：队友 stand_x=+0.78 而实际站在 x=+0.18（几乎台中间）！
##     看起来就是「他根本没换过去」。清掉残留之后，他才会落到新半区。
func _layout_doubles() -> void:
	if not _doubles:
		return
	for i in range(_partner_nodes.size()):
		var n: Node = _partner_nodes[i]
		n.set("stand_x", _my_x(i))
		if n.has_method("reset_stance"):
			n.call("reset_stance")
	for i in range(_opp_nodes.size()):
		var n: Node = _opp_nodes[i]
		n.set("stand_x", _opp_x(i))
		if n.has_method("reset_stance"):
			n.call("reset_stance")


## 把球「拿在手里」——实际是摆在拍面前上方，每帧跟着拍子走。
##
## stop() 会把球从飞行态摘出来，pingpong_ball._physics_process 随即直接返回，
## 所以它既不会被重力拽下去，也不会误触发弹台/落地判分；
## 而 visible 保持 true，玩家看得见手里有球，视觉上就是「准备发球」。
func _hold_ball_for_serve() -> void:
	var b := _ball as PingPongBall
	if b == null:
		return
	b.stop()
	b.global_position = _serve_hold_point()
	_reset_rally_state()
	_hit_cooldown = 0.0
	_tossing = false
	_toss_t = 0.0
	set_state(State.SERVE_DELAY)


## 发球出手 / 持球的世界高度。
##
## ★ 唯一的定义点，三处共用：持球点（_serve_hold_point）、抛球击出判定
##   （_begin_toss → _toss_strike_y）、轨迹提示线（_update_serve_traj）。
##   分散写死的话三处会各说各话 —— 提示线画的是一条不会发生的弹道。
##
## 站立：相机 1.52 − 0.41 = 1.11（和原来写死的常量相同，站立弹道一点不动）
## 蹲下：相机 0.97 − 0.41 = 0.56 → 被 serve_hold_min_y(0.88) 兜住
##   （ITTF 2.6.1：球必须在比赛台面以上）。
func _serve_launch_y() -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return toss_strike_height
	return maxf(cam.global_position.y - serve_hold_below_eye, serve_hold_min_y)


## 这一发的**击出高度** —— 持球点的高度，但夹在
## [台面上方 12 cm, toss_strike_height] 之间。
##
## 单一定义点，抛球判定（_begin_toss / _update_toss）和轨迹提示线
## （_update_serve_traj）都用它，否则提示线画的是一条不会发生的弹道。
func _serve_strike_y() -> float:
	return clampf(_serve_launch_y(), table_height + 0.12, toss_strike_height)


## 发球时球「拿在手里」的位置。
##
## ★ 为什么不挂在拍点正前方（第一版就是这么写的，被实拍打回来了）：
##   第一人称球拍是贴在相机跟前的一层视图模型，拍点正前方 10cm 的球投影到
##   屏幕 (0.65, 0.41)，正好落在那块大红胶皮中间 —— 玩家根本看不见手里的球。
##   所以改成「发球出手点 + 沿镜头左右轴往自己这侧推开」，让球待在拍面左边。
##
## 基准点直接取 _player_serve 的出手点附近（x=0 / z=1.32），
## 这样出手那一刻球最多横移二十几厘米，看不出「跳」。
##
## ★ 高度不写死：按「离眼睛 serve_hold_below_eye」算（见 _serve_launch_y），
##   所以蹲下时球会跟着人一起沉 —— 既不会悬在头顶外面，也让**出手点真的变低**，
##   于是发球弹道随蹲姿改变（用户要的「蹲下改发球线路」）。
func _serve_hold_point() -> Vector3:
	# ★ 出手点跟着玩家走（原来是写死的 z=1.50）：玩家在台后哪一站，
	#   球就摆在身前的发球区里。这样「站多远都能发球」这个 bug 一并解决 ——
	#   离台太远时球会被钳回发球区上沿，同时 _player_serve 会拒绝出手。
	var base := Vector3(0.0, 1.05, 1.50)
	if _player != null:
		var pz := clampf(_player.global_position.z - serve_launch_ahead,
						table_half_length + serve_end_line_margin, serve_zone_max_z)
		var px := clampf(_player.global_position.x, -0.55, 0.55)
		if _doubles:
			px = _my_x(_server_idx)
		base = Vector3(px, 1.05, pz)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return base + Vector3(-0.24, 0.0, 0.0)
	var right := cam.global_transform.basis.x
	# 只用水平分量：抬头/低头不该把球甩出画面。
	right.y = 0.0
	if right.length_squared() < 1e-4:
		right = Vector3(1.0, 0.0, 0.0)
	# 高度跟着**眼睛**走，不再是世界常量 —— 修「自己下蹲时发球线路会改变」。
	return Vector3(base.x, _serve_launch_y(), base.z) - right.normalized() * 0.24


## 把「这一回合」的所有共用状态清干净。发球前 / 击球后都要做一遍，
## 漏一项就会串场（上一拍的弹跳计数留到这一拍 = 直接判错分）。
func _reset_rally_state() -> void:
	_last_hitter = Hitter.NONE
	_bounces_player = 0
	_bounces_opp = 0
	_net_hit = false
	_point_over = false
	_cancel_opponent_return()
	_cancel_partner_return()
	_rally_hits = 0
	_opp_rally_hits = 0
	# 里程碑文案跟着这一回合一起结束 —— 下一球开始了还挂着上一球的「神球！」，
	# 玩家会以为刚才那一拍又响了一次。
	_rally_toast = ""
	_rally_toast_t = 0.0
	# 接发球阶段标记在发球出手之后才置真（见 _player_serve / _do_serve）
	_serve_phase = false
	_rally_last_kind = HitKind.NORMAL
	_stall_t = 0.0
	_player_bounce_z = -1.0


## ───────────── 发球：抛球 ─────────────
## 用户要的「发球时球要向上抛」。
##
## 为什么不用 b.launch() 真的让它飞：
##   一旦进飞行态，球的 bounced_table / landed_floor / hit_net 信号就开始参与判分。
##   一个「刚抛起来还没被击出」的球被判分 = 直接串场。
##   所以抛球期间保持 b.stop()（is_flying() 为 false，_physics_process 直接返回），
##   由 _update_toss 每帧把球摆到抛物线上。位置是真的抛物线（连空气阻力都按
##   球自己的 gravity / drag_k 算），看得见、也会真的掉下来，只是不参与物理。
func _begin_toss(mode: int) -> void:
	var b := _ball as PingPongBall
	if b == null or _tossing:
		return
	# ★ 发球区限制：离台太远 / 站到台内都不许发球（修「距离台面很远也可以发球」）
	if not _in_serve_zone():
		_msg("走到球台后面的发球区再发球（现在离台太远 / 站到台内了）")
		return
	if _paddle != null and _paddle.has_method("set_grip"):
		var m := int(_paddle.call("set_grip", mode))
		_grip_mode = m
	var p := _serve_hold_point()
	_toss_x = p.x
	_toss_z = p.z
	# 出手高度就用「拿在手里」那个高度，避免抛起来的一瞬间球跳一下
	_toss_y = p.y
	# ★ 击出高度 = **这一发的抛球起点**（原来写死 toss_strike_height）。
	#   这样蹲姿把出手点压低之后，球还是「落回自己手里那个高度」被击出 ——
	#   出手点真的低了，弹道也就真的不一样了（用户要的「蹲下改发球线路」）。
	#   上限取 toss_strike_height：站起来（甚至跳起来）时仍按 1.11 出手，
	#   站立弹道逐位不变。
	_toss_strike_y = _serve_strike_y()
	_toss_vy = toss_speed
	_toss_t = 0.0
	_tossing = true
	_msg("抛球！按住空格蓄力　等球落下时点左键击出（不点会自动打出去）")


func _update_toss(delta: float) -> void:
	var b := _ball as PingPongBall
	if b == null:
		_tossing = false
		return
	_toss_t += delta
	var g := float(b.get("gravity"))
	var k := float(b.get("drag_k"))
	# 竖直方向的空气阻力：阻力与速度反向，所以上升时减速更快、下落时更慢
	_toss_vy -= (g + k * _toss_vy * absf(_toss_vy)) * delta
	_toss_y += _toss_vy * delta
	b.global_position = Vector3(_toss_x, _toss_y, _toss_z)
	# 落回出手高度（或兜底超时）→ 自动击出，绝不把球局挂住
	if (_toss_vy < 0.0 and _toss_y <= _toss_strike_y) or _toss_t >= toss_auto_strike:
		_serve_strike()


## 把抛起的球击出去。
##
## ★ 用户要的「必须先抛球后才能击球」。这里加一层**上升期禁止出手**：
##   球还在往上飞的时候点左键一律不算，只给提示。
##
##   为什么必须卡：原来这里没有任何时序判断，于是「抛球」和「击球」之间
##   只要连点两下左键就能完成 —— 抛球动作被压成一两帧，玩家看到的是
##   「球直接从手上飞出去」，等于没有抛球这一步。
##   真实发球规则同样是「球抛起、**下落中**击球」，刚脱手就捅是不合法的。
func _serve_strike() -> void:
	if not _tossing:
		return
	if _toss_vy > 0.0:
		_msg("球还在上升 —— 等它落到腰高再打")
		return
	_tossing = false
	# 球在哪个高度就从这个高度出手
	var from := Vector3(_toss_x, maxf(_toss_y, table_height + 0.12), _toss_z)
	swing()
	_player_serve(from)


## 开球限速 —— 用户要的「限制开球球速」。
##
## 不能直接砍速度：砍完之后球可能就过不了网了（发球本来就在「过网」和
## 「弧顶别太高」两条约束之间走钢丝）。所以砍完先验一遍过网高度，
## 过不了就退回原速度 —— 宁可这一发快一点，也绝不能发出一个撞网的球。
func _cap_serve_speed(from: Vector3, v: Vector3) -> Vector3:
	var sp := v.length()
	if sp <= serve_speed_max or sp < 0.01:
		return v
	var scaled := v * (serve_speed_max / sp)
	var b := _ball as PingPongBall
	if b == null:
		return scaled
	var need := table_height + net_height + serve_net_margin
	if b.simulate_net_height(from, scaled) >= need:
		return scaled
	return v


## ───────────── 合规发球（先弹己方半台）+ 轨迹提示 ─────────────
##
## 用户报的两个 bug：
##   1. 「发球出去后要先弹自己的桌面」—— 合法发球必须先在己方半台弹一次。
##   2. 「距离台面很远也可以发球」—— 发球必须站在台后发球区里。
## 以及需求「发球要有轨迹提示」。

## 生成「这一发」的落点计划（随机一次、整发期间固定），
## 这样轨迹提示线跟实际发出的一模一样。
## use_edge=true 时按难度把落点推向边线（对手发球用）。
func _plan_serve(server_side: int, use_edge: bool = false) -> Dictionary:
	var own_cands: Array[float] = []
	var opp_x := 0.0
	var opp_z := 0.0
	if _doubles:
		# ★ ITTF 2.6.3：球须**依次触及发球方的右半区、再触及接发球方的右半区**。
		#   坐标约定：我方在 z>0、朝 -z 看 → 我们的右半区是世界 x > 0；
		#             对手在 z<0、朝 +z 看 → 它的右半区是世界 x < 0。
		#   所以两跳的符号**只由 `server_side`（哪一队发球）决定**，
		#   跟「发球的是队内第几个人」无关 —— 原来拿接发球者的固定站位定符号，
		#   于是 A0 / B1 发球时整条对角线是反的（实测 32 发只有 16 发合规，正好一半）。
		var own_sign := float(server_side)            # 第一跳：发球方的右半区
		opp_x = -own_sign * table_half_width * randf_range(0.30, 0.80)
		opp_z = -float(server_side) * randf_range(table_half_length * 0.30, table_half_length * 0.85)
		for a in [0.10, 0.26, 0.44, 0.62]:
			own_cands.append(own_sign * a)
	else:
		# 横向落点：难度越高越贴边
		if use_edge:
			var spp := _spread()
			var u := randf()
			u = lerpf(u, sqrt(randf()), _serve_edge())
			opp_x = (1.0 if randf() < 0.5 else -1.0) * table_half_width * spp * u
		else:
			opp_x = randf_range(-table_half_width * 0.60, table_half_width * 0.60)
		# 纵深：按概率发短球 / 长球
		if randf() < _serve_short_chance():
			opp_z = -float(server_side) * randf_range(table_half_length * 0.16, table_half_length * 0.34)
		else:
			opp_z = -float(server_side) * randf_range(table_half_length * 0.42, table_half_length * 0.90)
		for a in [-0.45, -0.20, 0.0, 0.20, 0.45]:
			own_cands.append(a)
	var spin := 0.0
	if server_side > 0:
		spin = _shot_spin(0.7)
	else:
		var s := _serve_spin()
		spin = randf_range(-s, s)
	# ★ 对手的发球整体放慢一档（玩家自己发球节奏不动）—— 见 serve_flight_scale。
	#   这里只改「基准飞行时间」，解算器仍会在 serve_flight_min/max 之间
	#   逐个候选试，保证解出来的还是合规发球（先弹己方 → 过网 → 弹对方）。
	var flight := _flight_time()
	if server_side < 0:
		flight *= serve_flight_scale
	return {
		"server_side": server_side,
		"own_x_cands": own_cands,
		"opp_x": opp_x,
		"opp_z": opp_z,
		"flight": flight,
		"spin": spin,
	}


## 视线与台面的交点 = 玩家想让球落在哪（「看哪落哪」）。
##
## 原来玩家发球的落点是 `_plan_serve(1)` 纯随机出来的，
## 且横向只覆盖 ±60% 半台宽、纵深只有「短球 / 长球」两段 ——
## 玩家既没法主动选点，可选区域也窄。现在改成由相机朝向实时决定。
##
## ★ 为什么用「射线打台面」而不是直接把 yaw/pitch 线性映射成落点：
##   线性映射下，同一个俯仰角在站得远 / 站得近时对应的落点会飘；
##   射线求交天然跟着站位走 —— 站在台后往哪看，落点就在哪，不会跑偏。
func _serve_aim_point() -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector2(0.0, -table_half_length * 0.60)
	var origin := cam.global_transform.origin
	var dir := -cam.global_transform.basis.z
	# ★ 视线水平或仰头时射线与台面没有交点（或交点在身后），
	#   这时按「极限平射」处理：落点取对方底线附近。
	var dy := dir.y
	if dy > -0.05:
		dy = -0.05
	var t := (table_height - origin.y) / dy
	if t < 0.0:
		t = 0.0
	var hit := origin + dir * t
	var x := clampf(hit.x,
		-table_half_width * serve_aim_x_span, table_half_width * serve_aim_x_span)
	# 对方半台在 z < 0（玩家 server_side = 1）
	var z := clampf(hit.z,
		-table_half_length * serve_aim_z_far, -table_half_length * serve_aim_z_near)
	return Vector2(x, z)


## 把瞄准点写进发球计划。预览（10 Hz）和真正出手都要调一次 ——
## 只在一处写的话，转完视角预览会停在旧落点上，或者预览和实际不一致。
func _apply_serve_aim(plan: Dictionary) -> void:
	if not serve_aim_enabled or plan.is_empty():
		return
	var ap := _serve_aim_point()
	var x := ap.x
	# ★ 双打要守 ITTF 2.6.3 的对角线：只能瞄接发球方的右半区。
	#   不夹的话，玩家把视角转到另一边就会发出不合规的球
	#   （_solve_legal_serve 只验弹跳顺序，验不出半区，会静默放过）。
	if _doubles:
		var side := int(plan.get("server_side", 1))
		if side > 0:
			x = clampf(x, -table_half_width * serve_aim_x_span, -0.08)
		else:
			x = clampf(x, 0.08, table_half_width * serve_aim_x_span)
	plan["opp_x"] = x
	plan["opp_z"] = ap.y


## 求解「合规发球」的速度：第一跳己方半台 → 不撞网 → 第二跳对方半台。
##
## 枚举「己方第一跳的 x / z + 飞行时间」若干候选，逐个解速度并做全路径模拟，
## 挑**第二跳最接近目标落点**的合法解。
## 找不到合法解时返回 ok=false，调用方退回旧的「直落对方台」轨迹
## —— 宁可这一发略不合规，也绝不能让球撞网 / 卡住球局。
func _solve_legal_serve(from: Vector3, plan: Dictionary) -> Dictionary:
	var b := _ball as PingPongBall
	if b == null:
		return {"ok": false, "v": Vector3.ZERO}
	var server_side := int(plan.get("server_side", 1))
	var own_x_cands: Array = plan.get("own_x_cands", [0.0])
	var opp_x := float(plan.get("opp_x", 0.0))
	var opp_z := float(plan.get("opp_z", -0.7))
	var flight := float(plan.get("flight", 0.42))
	var spin := float(plan.get("spin", 0.0))
	var z_hi := minf(serve_own_bounce_max_z, maxf(serve_own_bounce_min_z + 0.05, absf(from.z) - 0.10))
	var n_z := 6
	var want := Vector2(opp_x, opp_z)
	var best := Vector3.ZERO
	var best_d := 1e9
	var best_second := Vector3.ZERO
	var attempts := 0
	for own_x in own_x_cands:
		for i in range(n_z):
			var fz := lerpf(serve_own_bounce_min_z, z_hi, float(i) / float(maxi(n_z - 1, 1)))
			var own_z := float(server_side) * fz
			for fs in serve_legal_flight_scales:
				if attempts >= serve_legal_attempts:
					break
				attempts += 1
				var t := clampf(flight * float(fs), serve_flight_min, serve_flight_max)
				var target := Vector3(float(own_x), table_height + 0.02, own_z)
				var v := b.solve_velocity(from, target, t)
				var sp := v.length()
				if sp > serve_speed_max and sp > 0.001:
					v = v * (serve_speed_max / sp)
				var r: Dictionary = b.simulate_path(from, v, spin, 2.5,
				serve_solve_dt, serve_net_clearance)
				var ev: Array = r["events"]
				if not b.is_legal_serve(ev, server_side):
					continue
				var bl: Array = r["bounces"]
				var second: Vector3 = bl[1] if bl.size() > 1 else Vector3.ZERO
				var d := Vector2(second.x - want.x, second.z - want.y).length()
				if d < best_d:
					best_d = d
					best = v
					best_second = second
				if d <= serve_legal_accept_dist:
					return {"ok": true, "v": v, "second": second}
	if best == Vector3.ZERO or best_d >= 1e8:
		return {"ok": false, "v": Vector3.ZERO}
	# "second" = 实际第二跳（落到接发球方半台的那一点）。
	# 调用方拿它来判「短球提示」—— 不能拿计划落点判：慢发球
	# （serve_flight_scale）会让弧线变高、实际落点比目标浅，
	# 用计划值会漏报一大半短球。见 _do_serve。
	return {"ok": true, "v": best, "second": best_second}


## 发球区判定：玩家必须站在台后这一带。
func _in_serve_zone() -> bool:
	if _player == null:
		return true
	var z := _player.global_position.z
	return z >= serve_zone_min_z and z <= serve_zone_max_z


## ── 轨迹提示线 ──
func _build_serve_traj() -> void:
	_serve_traj_mesh = ImmediateMesh.new()
	_serve_traj = MeshInstance3D.new()
	_serve_traj.name = "ServeTraj"
	_serve_traj.mesh = _serve_traj_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = serve_traj_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_serve_traj.material_override = mat
	add_child(_serve_traj)
	# 两个落点环：己方第一跳 / 对方第二跳
	for i in range(2):
		var ring := _make_ring_mesh(0.10 if i == 0 else 0.12,
									 Color(0.35, 0.85, 1.0, 0.9) if i == 0 else serve_traj_color)
		ring.visible = false
		_serve_traj.add_child(ring)
		_serve_traj_rings.append(ring)


func _make_ring_mesh(r: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = r * 0.72
	tor.outer_radius = r
	tor.rings = 24
	tor.ring_segments = 6
	mi.mesh = tor
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	return mi


## 每帧刷新轨迹提示：只在本方发球「手持球 / 抛球」期间显示。
func _update_serve_traj(delta: float) -> void:
	if _serve_traj == null or _serve_traj_mesh == null:
		return
	var b := _ball as PingPongBall
	# ★ 队友发球时不画轨迹线：这条线的出手点/落点都是按**玩家的拍面**算的
	#   （见下面 _serve_hold_point），队友那一发画出来是一条根本不会发生的弹道。
	if b == null or not show_serve_trajectory or _server != Hitter.PLAYER \
		or _par_serve_t >= 0.0 \
		or _state != State.SERVE_DELAY or b.is_flying() or _match_over:
		_serve_traj.visible = false
		for r in _serve_traj_rings:
			r.visible = false
		return
	# 节流：约 10 Hz 重算，避免每帧跑解算器
	_serve_preview_t -= delta
	if _serve_preview_t > 0.0 and _serve_traj.visible:
		return
	_serve_preview_t = 0.1
	if _serve_plan.is_empty():
		return
	# ★ 瞄准点每次重算都刷一遍 —— 转视角时预览落点要跟着走，
	#   只建一次的话预览会一直停在开局随机出来的那个点上。
	_apply_serve_aim(_serve_plan)
	# 提示用的出手点：拿在手里的球的位置（y 抬到出手高度）
	var hp := _serve_hold_point()
	var from := Vector3(hp.x, _serve_strike_y(), hp.z)
	var res := _solve_legal_serve(from, _serve_plan)
	var v: Vector3 = res["v"] if bool(res["ok"]) else Vector3.ZERO
	if v == Vector3.ZERO:
		_serve_traj.visible = false
		for r in _serve_traj_rings:
			r.visible = false
		return
	var path := _sim_serve_polyline(from, v, float(_serve_plan.get("spin", 0.0)))
	if path.size() < 2:
		_serve_traj.visible = false
		return
	_serve_traj_mesh.clear_surfaces()
	_serve_traj_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p in path:
		_serve_traj_mesh.surface_add_vertex(p)
	_serve_traj_mesh.surface_end()
	_serve_traj.visible = true
	# 两个落点环
	var r2: Dictionary = b.simulate_path(from, v,
		float(_serve_plan.get("spin", 0.0)), 2.5,
		serve_solve_dt, serve_net_clearance)
	var bl: Array = r2["bounces"]
	for i in range(_serve_traj_rings.size()):
		if i < bl.size():
			_serve_traj_rings[i].visible = true
			var bp: Vector3 = bl[i]
			_serve_traj_rings[i].global_position = Vector3(bp.x, table_height + 0.03, bp.z)
		else:
			_serve_traj_rings[i].visible = false


## 采样整条弹道（含反弹）成折线点列，供轨迹提示线使用。
## 物理常数直接读球自己的导出量，保证画面上的线和真实飞行一致。
func _sim_serve_polyline(from: Vector3, v: Vector3, spin: float = 0.0) -> Array:
	var out: Array = []
	var p := from
	var vel := v
	var dt := 1.0 / 90.0
	var t := 0.0
	var top := table_height + 0.02
	var g := 9.8
	var k := 0.14
	var magnus := 0.012
	var b := _ball as PingPongBall
	if b != null:
		g = b.gravity
		k = b.drag_k
		magnus = b.magnus_coeff
	while t < 2.2:
		var acc := Vector3(0, -g, 0)
		var spd := vel.length()
		if spd > 0.0001:
			acc -= vel.normalized() * k * spd * spd
		if absf(spin) > 0.01:
			acc.y -= spin * magnus * Vector2(vel.x, vel.z).length()
		vel += acc * dt
		var next := p + vel * dt
		# 台面反弹：折线拐一下
		if p.y > top and next.y <= top and absf(next.x) <= table_half_width and absf(next.z) <= table_half_length:
			out.append(Vector3(next.x, top, next.z))
			vel.y = -vel.y * 0.85
			vel.x *= 0.88
			vel.z *= 0.88
			p = Vector3(next.x, top, next.z)
			t += dt
			continue
		out.append(next)
		p = next
		t += dt
		if out.size() > 400:
			break
	return out


## 玩家自己发球。
##
## 方向固定朝对方半台（不做瞄准，和对手发球的简化程度对齐），
## 旋转由 Z/C 决定 —— 这就是「Z+左键=上旋 / C+左键=下旋」在发球上的体现。
## 用 _solve_serve 而不是 _solve_return：前者会同时保证「过网」并且
## 「弧顶不超过 serve_apex_limit」，后者不封顶，从玩家这边发容易抛成高球。
##
## from_override 非零时用它当出手点 —— 抛球之后球在手上方，必须从球所在
## 位置出手，不然会看到球「瞬移」回固定出手点。
func _player_serve(from_override: Vector3 = Vector3.ZERO) -> void:
	if _match_over or not waiting_player_serve():
		return
	var b := _ball as PingPongBall
	if b == null:
		return
	# ★ 修「距离台面很远也可以发球」：必须站在台后的发球区里才能发。
	#   抛球途中的击出（from_override 非零）不再重复检查 —— 抛球那一刻已经查过。
	if from_override == Vector3.ZERO and not _in_serve_zone():
		_msg("走到球台后面的发球区再发球（现在离台太远 / 站到台内了）")
		return
	_tossing = false

	var from := from_override
	if from == Vector3.ZERO:
		var fx := randf_range(-0.30, 0.30)
		if _doubles:
			# 发球的人不一定站在台中间 —— 从他自己的站位出手
			fx = _my_x(_server_idx) + randf_range(-0.12, 0.12)
		# 出手点跟着玩家在台后的位置走（不再是写死的 1.30）。
		# ★ 下限用端线而不是发球区下沿：球拍会往台面方向前伸 serve_launch_ahead，
		#   按发球区下沿钳的话球会被带回端线**之内**（实测 1.36 < 1.37），违反 2.6.1。
		var pz := 1.50
		if _player != null:
			pz = clampf(_player.global_position.z - serve_launch_ahead,
						table_half_length + serve_end_line_margin, serve_zone_max_z)
		# 高度也走 _serve_strike_y()：蹲着等发球被兜底代发时，
		# 出手高度不会从手里的 0.88 突然跳到 1.02。
		from = Vector3(fx, _serve_strike_y(), pz)

	# ★ 发球也能蓄力 —— 用户报的「发球无法蓄力」。
	#   根因：_serve_grip 走的是「切握拍 + 挥一下 + 直接发出去」这条独立路径，
	#   从头到尾没读过 _charge_t / _charging，所以按住空格对发球毫无作用。
	#   现在按蓄力深度压缩飞行时间（越小越快），并受 serve_speed_max 限速。
	var power := 0.0
	if _charging and _charge_t > 0.0:
		power = clampf(charge_min_power + (1.0 - charge_min_power) * _charge_t, 0.0, 1.0)
	if _serve_plan.is_empty():
		_serve_plan = _plan_serve(1)
	# ★ 出手这一刻再取一次瞄准点：预览是 10 Hz 的，可能在玩家刚转完视角
	#   和真正出手之间差了不到 0.1 s，拿旧值会打偏一点点。
	_apply_serve_aim(_serve_plan)
	_serve_plan["spin"] = _shot_spin(0.7)
	var flight := float(_serve_plan.get("flight", _flight_time())) \
		* lerpf(1.0, serve_power_flight_scale, power)

	# ★ 合规发球：先弹己方半台 → 过网 → 再弹对方半台（用户报的「要先弹自己的桌面」）。
	var plan := _serve_plan.duplicate()
	plan["flight"] = flight
	var res := _solve_legal_serve(from, plan)
	var v: Vector3
	if bool(res["ok"]):
		v = res["v"]
	else:
		# 兜底：旧的「直落对方台」轨迹（宁可略不合规，也不能让球撞网卡住球局）
		var target := Vector3(float(_serve_plan.get("opp_x", 0.0)),
							  table_height + 0.02, float(_serve_plan.get("opp_z", -0.7)))
		v = _solve_serve(from, target, flight)
		v = _cap_serve_speed(from, v)

	_reset_rally_state()
	b.launch(from, v, _shot_spin(0.7))
	_serve_plan = {}
	_last_hitter = Hitter.PLAYER
	# 刚出手的一瞬间球就贴着拍面，不锁一下冷却会被 _check_hit 立刻「再打一次」
	_hit_cooldown = 0.24
	_swing_timer = -1.0
	# 蓄力用掉了，清干净（不然下一拍会白带一次力量）
	_charge_t = 0.0
	_charging = false
	set_state(State.RALLY)
	# ★ 进入「接发球阶段」：这一拍之前对手几乎必回、我也没法一板打死
	#   （见 serve_return_* 那一组导出量），发球偷分这条路因此堵死。
	_serve_phase = true
	_audio_call("play_hit", [0.85, _hit_audio_kind(HitKind.NORMAL)])
	_msg("发球！　球速 %.1f m/s%s%s"
		% [v.length(), "（蓄力）" if power > 0.02 else "", _spin_note()])


func _do_serve() -> void:
	# 双保险：start_serve 已经拦了一道，但 _do_serve 是可被脚本直接调的，
	# 一局结束后不该还能凭空发一个球出来；轮到玩家发球时也不该由对手代劳。
	if _match_over or _server != Hitter.OPPONENT:
		return
	var b := _ball as PingPongBall
	if b == null:
		return

	# 发射点：对方半台后上方。
	# y 从 0.98 提到 1.02 —— 只比网顶(0.9325)高 9cm，抬一点点能显著放宽
	# 「又要过网、又不能高抛」这对矛盾约束。
	var from_x := randf_range(-0.28, 0.28)
	# 落点往哪一侧甩。单打随机；双打固定送到**接发球那个人**的半边
	# （真实双打发球要走对角），否则玩家会被迫横向狂奔半个台。
	if _doubles:
		_set_active_opponent(_server_idx)
		from_x = _opp_x(_server_idx) + randf_range(-0.12, 0.12)
	var from := Vector3(from_x, 1.02, -1.30)

	# 这一发的落点计划（含难度散布）；合规解算器负责保证「先弹对方半台」。
	var plan := _plan_serve(-1, true)
	var plan_spin := float(plan.get("spin", 0.0))
	var flight := float(plan.get("flight", _flight_time()))

	# ★ 合规发球：先弹**发球方自己**的半台（这里是对方半台）→ 过网 → 再弹玩家半台。
	var res := _solve_legal_serve(from, plan)
	var v: Vector3
	if bool(res["ok"]):
		v = res["v"]
	else:
		# 兜底：旧的「直落玩家台」轨迹（绝不发出撞网的球 / 挂住球局）
		var target := Vector3(float(plan.get("opp_x", 0.0)),
							  table_height + 0.02, float(plan.get("opp_z", 0.7)))
		v = _solve_serve(from, target, flight)
		v = _cap_serve_speed(from, v)
	# ★ 短球提示按**实际第二跳**判，不按计划落点。
	#   慢发球（serve_flight_scale）让弧线抬高、实际落点比目标浅一大截
	#   （实测长球目标 z≈0.58~1.23，实际落在 ≈0.55），照计划值判会漏报短球，
	#   而玩家正是靠这句话决定要不要上前 —— 漏报等于少一次提示。
	var land_z := float(plan.get("opp_z", 1.0))
	if bool(res["ok"]) and res.has("second"):
		land_z = (res["second"] as Vector3).z
	var is_short := absf(land_z) < table_half_length * 0.42
	b.launch(from, v, plan_spin)

	# 对手也「真的挥一下」。
	# 球是凭空 launch 出来的，如果只给对面摆一把静止的球拍，
	# 看起来就是「雕塑在发球」；这里让肩关节跟着扫一下（球已出手，算随挥）。
	# 音效同理 —— 修之前整条发球链路是**静音**的，只有之后的落台 bounce 声，
	# 玩家听不出「对面打了一拍」。
	if _opponent != null:
		# ★ 发球同样分正反手：按抛球点相对身体决定，和回球用同一套判定。
		_opponent_swing(from.x)
		# 每球回到初始站位，不然上一球的迈步会累积到这一球
		if _opponent.has_method("reset_stance"):
			_opponent.call("reset_stance")
	_audio_call("play_opponent_hit", [0.9])

	_reset_rally_state()
	_hit_cooldown = 0.0
	set_state(State.INCOMING)
	# ★ 进入「接发球阶段」：这一拍够球范围放宽、但一板打死的能力被压住
	#   （见 serve_return_* 那一组），对手开球偷分这条路因此堵死。
	_serve_phase = true
	# ★ 双打里对手发球若轮到队友接，让队友直接接管接发（和回合中一样走
	#   _schedule_partner_return）—— 玩家不用每次都被迫手动接发，对手发球
	#   偷分几乎被堵死，回合继续到玩家这一拍，比分由玩家表现决定。
	#   玩家若想自己接也行：照样挥拍，_do_hit 会先取消队友接发、由玩家打。
	if _doubles and _partner_ai and _my_turn != _player_slot:
		_schedule_partner_return()
	_msg("球来了！　短球，上前接" if is_short else "球来了！")


## 求一个「像乒乓球发球」的初速度 —— 既要过网，又不能把弧线抛上天。
##
## 为什么不能直接把 target 丢给 solve_velocity：
##   它只保证「约 flight_time 秒后落到 target」，不关心中间走什么路线。
##   而它的解析式 v.y = Δy/t + 0.5·g·t 里，t 越大 v.y 越大 ——
##   飞行时间一长，解出来的就是一条高抛慢球（实测 t=1.5 时弧顶 2.91 m）。
##
## 所以这里在两条约束之间调飞行时间：
##   过不了网  → 放慢（t 变大，弧线抬高）
##   弧顶超限  → 加快（t 变小，弧线压平）
## 由于几何上 t >= 0.352 s 才可能过网、而 0.38~0.46 的弧顶只有 ~1.15 m，
## 这两个条件在合理取值下是相容的，循环基本一两轮就收敛。
func _solve_serve(from: Vector3, target: Vector3, flight: float) -> Vector3:
	var b := _ball as PingPongBall
	if b == null:
		return Vector3(0.0, 0.0, 1.0)

	var need := table_height + net_height + serve_net_margin
	var t := clampf(flight, serve_flight_min, serve_flight_max)
	var fallback := b.solve_velocity(from, target, t)
	# 兜底候选：只用「能过网」这一个条件筛，取弧顶最低的那个。
	# 万一两条约束在边界上打架（加快就撞网、放慢就高抛），
	# 宁可要一个略高的弧线，也绝不能要一个撞网的发球。
	var best_net := Vector3.ZERO
	var best_net_apex := 1e9

	for _i in range(14):
		var v := b.solve_velocity(from, target, t)
		var nh := b.simulate_net_height(from, v)
		if nh < need:
			t = minf(serve_flight_max, t + 0.03)
			continue
		var apex := b.simulate_apex(from, v)
		if apex < best_net_apex:
			best_net_apex = apex
			best_net = v
		if apex <= serve_apex_limit:
			return v
		t = maxf(serve_flight_min, t - 0.03)

	if best_net != Vector3.ZERO:
		return best_net
	return fallback


func _input(event: InputEvent) -> void:
	# 浏览器要求「用户手势」之后才允许出声，所以现场呐喊不放在 _ready，
	# 而是等到第一次真正的按键 / 点击（鼠标移动不算手势，不能用它触发）。
	if _ambience_started:
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		_ambience_started = true
		_audio_call("start_ambience")
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_ambience_started = true
		_audio_call("start_ambience")


func _process(delta: float) -> void:
	_guard_mouse_mode()
	match _state:
		State.SERVE_DELAY:
			if _par_serve_t >= 0.0:
				# 队友发球：倒计时到点自动出手（见 _update_partner_serve）
				_update_partner_serve(delta)
			elif _server == Hitter.PLAYER:
				if _tossing:
					# 抛球中：球被手动摆在抛物线上，别去动它的位置、也别计超时
					_update_toss(delta)
				else:
					# 玩家的发球：等他自己点左键。
					# 「等玩家出手」天然是个有可能永远不满足的条件，所以要有出口；
					# 但出口先给「提醒」而不是直接代发 —— 代发之后球进入回合，
					# 站着没动的玩家接不到对手回球，干等就变成了白丢一分。
					_serve_wait += delta
					var b := _ball as PingPongBall
					if b != null and not b.is_flying():
						b.global_position = _serve_hold_point()
					if _serve_wait >= _serve_remind_at and _serve_wait < player_serve_timeout:
						_serve_remind_at = _serve_wait + player_serve_remind
						if not _in_serve_zone():
							_msg("走到球台后面的发球区再发球　（按 W 上前）")
						else:
							_msg("还在等你发球　点鼠标左键（或按 F 键）　Z=上旋 / C=下旋")
					if _serve_wait >= player_serve_timeout:
						# 兜底：玩家就是不肯走回发球区也不能把球局挂死 ——
						# 把他送回发球区再发。
						if not _in_serve_zone() and _player != null:
							var pp := _player.global_position
							_player.global_position = Vector3(pp.x, pp.y,
								clampf(1.55, serve_zone_min_z + 0.02, serve_zone_max_z))
							_msg("自动回到发球区发球")
						_player_serve()
			else:
				_timer -= delta
				if _timer <= 0.0:
					_do_serve()
		State.POINT:
			_timer -= delta
			if _timer <= 0.0 and auto_serve:
				start_serve()
		State.INCOMING, State.RALLY:
			_watch_stall(delta)

	if _swing_timer > 0.0:
		_swing_timer -= delta
		if _swing_timer <= 0.0:
			_swing_timer = -1.0
			_on_swing_end()
	if _swing_lock > 0.0:
		_swing_lock -= delta
	if _hit_cooldown > 0.0:
		_hit_cooldown -= delta

	_update_opponent_return(delta)
	_update_partner_return(delta)
	_update_stamina(delta)
	_update_charge(delta)
	_update_reach_extend(delta)
	_update_switch(delta)
	_update_serve_traj(delta)
	# 里程碑文案的倒计时（连拍 HUD 的副行靠它决定显示文案还是金币倍率）
	if _rally_toast_t > 0.0:
		_rally_toast_t = maxf(_rally_toast_t - delta, 0.0)
	_update_hud(delta)


## 探拍：按住 Shift 把拍子往球台上方送出去，松开收回。
##
## ★ 用户要「可以将拍移动至球台上接近台球」。判定盒收紧之后（hit_reach_* 全调小），
##   球飞到台面上空时拍子够不着，这个前推量就是补那个缺口的 ——
##   「够得到」因此变成**操作**而不是数值宽容。
##   偏移加在球拍 rig 上（不是主控里另算一个判定中心），
##   所以视觉和判定永远一致：head_position() 读的就是偏移后的世界坐标。
func _update_reach_extend(delta: float) -> void:
	var want := 1.0 if _reach_holding else reach_rest
	var step := delta / maxf(table_reach_time, 0.001)
	_reach_extend = move_toward(_reach_extend, want, step)
	if _paddle != null and _paddle.has_method("set_reach_extend"):
		_paddle.call("set_reach_extend", _reach_extend)


## 回合卡死兜底。
##
## 状态机原本只有 SERVE_DELAY / POINT 两个状态有计时器，IDLE / INCOMING / RALLY
## **完全没有超时出口** —— 只要某条路径让球不再发出 bounced_table / hit_net /
## landed_floor，这一分就永远收不掉，整局停在「球来了」上，玩家看到的就是
## 「打到某个时刻后就不发了」。这类路径不好穷举（阻力/旋转/网碰撞的数值边界、
## 场景切换留下的半死球都可能是），所以用兜底替代穷举：
##   球已经不在飞了（判分信号丢了）→ 0.6 s 后强制收分
##   球还在飞但 4 s 没任何事件      → 也强制收分
## 0.6 s 那个缓冲是必须的：落地信号和这一帧的时序可能差一帧，
## 立即收分会把正常的一拍误判掉。
func _watch_stall(delta: float) -> void:
	_stall_t += delta
	var b := _ball as PingPongBall
	var dead := b == null or not b.is_flying()
	var limit := 0.6 if dead else rally_stall_timeout
	if _stall_t >= limit:
		_resolve_stall()


func _resolve_stall() -> void:
	if _match_over or _point_over:
		return
	var b := _ball as PingPongBall
	if b != null:
		b.stop()
	# 谁最后碰的球，就判谁这一拍没打成 —— 和「出界/没接到」的取向一致
	if _last_hitter == Hitter.PLAYER:
		_opponent_score += 1
		_finish("这一拍没打成… %d" % _opponent_score, false)
	else:
		_player_score += 1
		_credit_winner()
		_finish("对方没打成 —— +%d" % _player_score, true)


func _physics_process(_delta: float) -> void:
	# 挥拍窗口内持续判定 —— 「能打到球」的关键
	if _swing_timer > 0.0:
		_check_hit()
	_update_landing_marker()


# ───────────── 体力 ─────────────
func _update_stamina(delta: float) -> void:
	if _stamina_hold > 0.0:
		_stamina_hold -= delta
	elif _stamina < max_stamina:
		_stamina = minf(max_stamina, _stamina + stamina_regen * delta)
	# AI 对手同样在两分之间慢慢回血（比玩家慢一点，长局里他会先撑不住）
	if _opp_stamina < opponent_max_stamina:
		_opp_stamina = minf(opponent_max_stamina,
							_opp_stamina + opponent_stamina_regen * delta)


## 按住空格 = 蓄力。蓄满后不会自动挥拍，仍然由鼠标左右键决定用不用、用哪一招。
func _update_charge(delta: float) -> void:
	var want := InputMap.has_action("charge") and Input.is_action_pressed("charge") \
			   and _stamina >= min_stamina_to_charge
	if want:
		_charging = true
		_charge_t = minf(1.0, _charge_t + delta / maxf(charge_full_time, 0.01))
	else:
		_charging = false
		_charge_t = 0.0

	# 蓄力时球拍往后收一点，给动作一个预兆
	if _paddle != null and _paddle.has_method("set_charge"):
		_paddle.call("set_charge", _charge_t)


# ───────────── 输入 ─────────────
func _unhandled_input(event: InputEvent) -> void:
	# Esc = 暂停。注意这里只负责「开」：暂停之后本节点被冻结，
	# 收不到任何输入，把暂停面板收掉的是 game_overlay（它挂在
	# PROCESS_MODE_ALWAYS 那一支上）。
	if event.is_action_pressed("ui_cancel"):
		if not _match_over:
			_pause()
		get_viewport().set_input_as_handled()
		return

	# 结算面板 / 暂停面板开着时不吃任何游戏操作 ——
	# 否则会隔着半透明面板把球打出去（面板是画在 HUD 上的，不挡输入分发）。
	if _match_over or _pause_open:
		return

	# 左键 = 反手、右键 = 正手：切到对应握拍后立刻挥拍
	#
	# ★ 这里原来还多要求一个 Input.mouse_mode == MOUSE_MODE_CAPTURED，
	#   那是个真坑，也是「点左键没反应 / 打到一半就不发球了」的根因：
	#     1) 浏览器只允许在「用户手势」里申请指针锁定，而 camera_controller
	#        在 _ready 里申请、Web 上还被主动跳过 —— 所以进比赛后的第一次点击
	#        必然拿不到锁，于是那一下既没锁住鼠标、也不算挥拍/发球，
	#        玩家会以为键坏了，得再点一下；
	#     2) 中途任何原因丢锁（切窗口回来、浏览器弹提示、系统快捷键），
	#        鼠标操作就整体失效，而且不会自己恢复；
	#     3) 它和 camera_controller._unhandled_input 谁先跑还要看节点顺序，
	#        行为随场景层级漂 —— 太脆。
	#   现在鼠标键一律照常处理（暂停 / 结算面板在上面已经早退拦掉了），
	#   同时顺手补一次指针锁定：mousedown 本身就是合法的用户手势，能锁上。
	#   于是「点一下就能打」既成立了，丢锁也能自愈。
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse()
		# 轮到玩家发球时，同一个左键改成「发球」——
		# 用户要的就是「Z/C + 鼠标左键」这个组合，发球和击球用同一套手感。
		if waiting_player_serve():
			if _tossing:
				_serve_strike()
			else:
				_serve_grip(1 if event.button_index == MOUSE_BUTTON_LEFT else 0)
			get_viewport().set_input_as_handled()
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_swing_with_grip(1)
			MOUSE_BUTTON_RIGHT:
				_swing_with_grip(0)
	# 同上：InputMap 里只有 "hit"，"attack" 没注册，直接判断会刷 ERROR
	for act in ["hit", "attack"]:
		if InputMap.has_action(act) and event.is_action_pressed(act):
			if waiting_player_serve():
				if _tossing:
					_serve_strike()
				else:
					_serve_grip(_grip_mode)
			else:
				swing()
			break
	if event.is_action_pressed("difficulty"):
		# 赛事 / 排位的难度都不是菜单里那一档：前者跟着对手评分、后者跟着段位。
		# 局内不开放手动切换 —— 尤其排位，能手动降档的话「AI 永远贴着你的水平」
		# 这个前提就破了，段位也就不代表水平。
		if _ranked:
			_msg("排位赛的对手强度由段位决定，不能手动切换")
		elif _difficulty_locked:
			_msg("赛事场次难度由对手实力决定，不能手动切换")
		else:
			set_difficulty((difficulty + 1) % 5)
	# Q / E 也能切握拍（纯键盘事件，不锁鼠标）
	if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
		if _paddle != null and _paddle.has_method("toggle_grip"):
			_grip_mode = int(_paddle.call("toggle_grip"))
			_msg("握拍：" + grip_name())

	# ★ 探拍：按住 R 把拍子往球台上方送出去。
	#   （Shift 已被冲刺占用，所以另挑 R —— 和 F(击球) 在同一排，左手够得着。）
	#   只认 pressed / released 两个边沿，中间那些 echo 事件直接丢掉 ——
	#   Windows 长按会疯狂补发 pressed，用它去设状态等于每帧重设一次。
	if event is InputEventKey and event.keycode == KEY_R:
		if event.is_echo():
			return
		_reach_holding = event.pressed
		if event.pressed:
			_msg("探拍　松开收回")

	# ★★ 上下旋改成**点按开关**（用户要的「点按触发 / 取消」）。
	#
	#   原来是按住式（Input.is_key_pressed），有三个毛病：
	#     1) 要一边按住 Z 一边点鼠标左键，手腕别着；
	#     2) **发不了球** —— 发球是「左键抛球 → 左键击出」两下，
	#        中间要一直按着 Z，而 C 又被绑成了蹲下，等于发球时选旋转
	#        就会莫名其妙蹲下去；
	#     3) 玩家没有任何「现在是什么旋转」的确认，松手就没了。
	#   改成点按切换之后：按一下开、再按一下关，状态一直挂着，
	#   鼠标手完全解放；发球照样吃这个状态（_player_serve 走 _shot_spin）；
	#   并且 project.godot 里已经把 C 从 crouch 动作里摘掉了。
	#
	#   echo 过滤是必须的：Windows 长按会每帧补发 pressed，
	#   不丢的话按一下会被当成按了几十下，状态疯狂翻转。
	if event is InputEventKey and event.pressed and not event.is_echo() \
		and (event.keycode == KEY_Z or event.keycode == KEY_C):
		var want := 1 if event.keycode == KEY_Z else -1
		_spin_mode = 0 if _spin_mode == want else want
		_msg("旋转：%s　（再按一下取消）" % ["普通（不转）",
			"上旋　球弹起后往前窜", "下旋　球弹起后往下扎"][_spin_mode + 1])


## 这一拍够不够「远」，能不能扣杀 —— 见 smash_min_bounce_ratio。
##
## 返回 {"ok": bool, "z": float}：
##   z 是判据用的「离网距离」（米）。优先用这一拍在玩家半台的**落点**；
##   球还没落台（半高球直接迎前打）时退回用球当前的 z。
##   z < 0 表示这一拍在我方半台没有有效落点（比如球还在对面）—— 一律不许扣杀。
func smash_spot() -> Dictionary:
	var z := _player_bounce_z
	if z <= 0.0:
		var b := _ball as PingPongBall
		if b != null:
			z = b.global_position.z
	var need := table_half_length * clampf(smash_min_bounce_ratio, 0.0, 1.0)
	return {"ok": z >= need, "z": z, "need": need}


## 切到指定握拍并挥拍。mode: 0 正手 / 1 反手
##
## 蓄力判定就在这里：空格按住且体力够 → 正手出「爆冲」、反手出「暴拧」，
## 并扣掉对应体力；体力不够就自动退化成普通挥拍（不会白扣）。
##
## ★ 正手爆冲额外要求「这一拍是远台球」（见 smash_min_bounce_ratio）：
##   近网短球只能上前轻挑，扣杀不了。暴拧不受此限（它本来就是处理短球的）。
##
## 蹲姿打折：蹲着的时候重心低、发力靠大腿而不是靠挥臂，所以爆冲/暴拧的
## 体力开销按 crouch_cost_scale 打折（用户要的「下蹲体力消耗减少」）。
func _swing_with_grip(mode: int) -> void:
	# 挥拍锁挡掉的连点：不切握拍、不扣体力、不出招
	if not can_swing():
		return
	if _paddle != null and _paddle.has_method("set_grip"):
		var m := int(_paddle.call("set_grip", mode))
		if m != _grip_mode:
			_grip_mode = m
			_msg("握拍：" + grip_name())

	var power := 0.0
	var kind: int = HitKind.NORMAL

	if _charging and _charge_t > 0.0:
		var cost := cost_backhand_flick if mode == 1 else cost_forehand_loop
		var crouched := is_crouching()
		if crouched:
			cost *= crouch_cost_scale
		# 正手爆冲的距离门槛：太靠网就降级成普通挥拍（**不扣体力**，
		# 玩家不该为一个被判无效的动作买单）。
		var spot := smash_spot()
		var too_short := mode == 0 and not bool(spot["ok"])
		if _stamina >= cost and not too_short:
			kind = HitKind.FLICK if mode == 1 else HitKind.LOOP
			# 蓄力越久力量越大，但按下即用也有 charge_min_power 的底子
			power = clampf(charge_min_power + (1.0 - charge_min_power) * _charge_t,
						   0.0, 1.0)
			_stamina = maxf(0.0, _stamina - cost)
			_stamina_hold = stamina_regen_delay
			# 记下这笔账：掷中「必杀」时要退还一部分（见 _do_hit）。
			# 不记的话「蓄满 → 打死」和「蓄满 → 没打死」付一样的钱，
			# 玩家只会记住自己白花了体力，于是再也不肯蓄力。
			_last_charge_cost = cost
			_msg(("反手暴拧！" if mode == 1 else "正手爆冲！")
				 + "　体力 -%d" % int(round(cost))
				 + ("　（蹲姿省力）" if crouched else ""))
		elif too_short:
			# 球在台上落得太靠网 —— 没有引拍空间，抡不起来。
			# 说清楚「球落在哪」和「要落在哪」，玩家才知道下次站哪等。
			_msg("球太靠网（落点 %.2f m）—— 扣杀不了，只能普通回球　站远一点等底线球"
				 % float(spot["z"]))
		else:
			_msg("体力不足，只能普通挥拍")

	_hit_power = power
	_hit_kind = kind
	_charge_t = 0.0
	_charging = false
	swing()


## 发球用的「切握拍 + 抛球」。
##
## 不能直接复用 _swing_with_grip：那个会去判蓄力、扣体力、出爆冲，
## 而发球（尤其是这一下抛球）不该消耗体力。
##
## ★ 这里原来是「swing() + 直接 _player_serve()」—— 两条毛病：
##   1) 没有抛球动作，球是从手里瞬移出去的（用户要「发球时球要向上抛」）；
##   2) 完全不读 _charge_t，所以按住空格蓄力对发球毫无作用（用户报的 bug）。
##   现在只负责「抛起来」，真正的击出交给 _serve_strike()。
func _serve_grip(mode: int) -> void:
	_begin_toss(mode)


# ───────────── 击球 ─────────────
## 现在能不能挥拍。挥拍锁期间一律不能 —— 用户要的「不能连续挥拍」。
func can_swing() -> bool:
	return _swing_lock <= 0.0 and not _match_over and not _point_over


## 挥拍。返回 false = 这一下被挥拍锁挡掉了。
func swing() -> bool:
	if not can_swing():
		return false
	if _paddle != null and _paddle.has_method("trigger_swing"):
		_paddle.call("trigger_swing")
	_swing_timer = swing_valid_duration
	# 一次挥拍动作要走完这段时间才能再挥（≈0.48 s，一秒最多两拍）
	_swing_lock = swing_valid_duration + swing_recover
	_swing_hit = false
	# 破风声：普通挥拍明显一点（因为没有击球的「啪」盖住它）
	_audio_call("play_whoosh", [lerpf(1.0, 0.5, _hit_power)])
	_check_hit()
	return true


## 挥拍窗口走完还没打到球 → 挥空。
##
## 用户要的规则：**球就在近身范围内**时挥空 → 立刻判对方得分；
## 球在远处挥空完全不受罚（随便挥、提前挥都不罚）。
## 这样「乱抡」在球没到的时候是安全的，但球到眼前还打空就是真的失误。
func _on_swing_end() -> void:
	if _swing_hit or _point_over or _match_over or not whiff_fault_enable:
		return
	var b := _ball as PingPongBall
	if b == null or not b.is_flying():
		return
	var rp := _paddle_point()
	var d := b.global_position - rp
	if Vector2(d.x, d.z).length() > whiff_fault_radius:
		return
	_stamina = maxf(0.0, _stamina - stamina_cost_whiff)
	_stamina_hold = stamina_regen_delay
	_opponent_score += 1
	_audio_call("play_whoosh", [1.0])
	_finish("挥空了！球都没碰到　对方得分 %d : %d"
			% [_player_score, _opponent_score], false)


func _paddle_point() -> Vector3:
	if _paddle != null and _paddle.has_method("head_position"):
		return _paddle.call("head_position") as Vector3
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return global_position
	var fwd := -cam.global_transform.basis.z
	return cam.global_position + fwd * 0.35


func _timing_quality() -> float:
	if _paddle != null and _paddle.has_method("swing_progress"):
		var p := float(_paddle.call("swing_progress"))
		if p >= 0.0:
			return clampf(1.0 - absf(p - 0.40) / 0.40, 0.0, 1.0)
	return 1.0


## 够球判定。
##
## ★ 判定盒的原点与「球拍视觉位置」刻意不一致，这一点是**量出来的**，不是拍脑袋：
##   横向/纵深取拍面中心的水平位置（跟着视线转 → 玩家用视线对准球），
##   高度中心取 contact_height(0.91) —— 而不是拍面中心的 y(≈1.31)。
##   原因见 hit_reach_x 上面的那段注释：玩家这侧的来球永远在 0.86~0.93，
##   把高度中心留在 1.31 就等于用一个 0.4 m 的死区换掉 0.4 m 的横向容差。
##
## 三轴各自对应一种操作：
##   x → 走位（最紧）
##   z → 站位前后（墩姿时朝网一侧收窄）
##   y → 实测来球高度很稳，给一个够用的带
func _check_hit() -> bool:
	var b := _ball as PingPongBall
	if b == null or not b.is_flying():
		return false
	if _hit_cooldown > 0.0:
		return false
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return false

	var rp := _paddle_point()
	var bp := b.global_position
	var box := _reach_box()

	# 蹲姿：够不到近台短球 —— 用户要的那条取舍。
	# 判据用「这一拍在玩家这侧落在哪」而不是「球现在离我多远」：
	# 短球的本质是「球落得离网近、必须上前一步」，蹲着迈不开步就是够不着。
	if is_crouching() and _player_bounce_z > 0.0 and _player_bounce_z < crouch_short_ball_z:
		return false

	var dx := (bp.x - rp.x) / maxf(box.x, 0.001)
	var dy := (bp.y - contact_height) / maxf(box.y, 0.001)
	var dz := (bp.z - rp.z) / maxf(box.z, 0.001)
	if dx * dx + dy * dy + dz * dz > 1.0:
		return false

	var fwd := -cam.global_transform.basis.z
	var to_ball := (bp - cam.global_position).normalized()
	if to_ball.dot(fwd) < hit_in_front_dot:
		return false

	_do_hit()
	return true


func _do_hit() -> void:
	var b := _ball as PingPongBall
	if b == null:
		return

	# ★ 双打的核心规则：同一队的两个人必须**轮流**击球。
	#   自动切换已经把相机送到了该接球的人身上，所以正常流程下这里不会触发；
	#   它兜的是「自己打出去的球又弹回来、同一个人又打了一次」这种情况 ——
	#   比如球撞网回弹到自己半台，站着不动再补一拍，这在双打里就是违例。
	if _doubles and _last_my == _my_turn:
		_opponent_score += 1
		_finish("违例：同一人连打两次　%d" % _opponent_score, false)
		return

	var from := b.global_position
	var quality := _timing_quality()
	var kind := _hit_kind
	var power := _hit_power
	# 掷中「必杀」时退还的体力（见下面那段），>0 才在提示行里显示
	var refund := 0

	# 力量越大，落点越准（失误偏移被压缩）
	var err := (1.0 - quality) * hit_error_max * lerpf(1.0, 0.42, power)

	# 落点：力量越大越往对方底线压
	var depth := lerpf(0.88, 0.97, power)
	var tx := randf_range(-table_half_width * 0.70, table_half_width * 0.70) \
			 + randf_range(-err, err)
	var tz := -randf_range(table_half_length * lerpf(0.30, 0.22, power),
						   table_half_length * depth) + randf_range(-err, err)

	var spin := _shot_spin(randf_range(spin_default_min, spin_default_max))
	var player_spin := _spin_input()
	if kind == HitKind.FLICK:
		# 反手暴拧（香蕉拧）：强侧旋，落点明显甩向一侧
		var side := 1.0 if randf() < 0.5 else -1.0
		tx += side * table_half_width * randf_range(0.25, 0.62)
		if player_spin == 0.0:
			spin = side * randf_range(1.4, 2.2)
		else:
			# 玩家自己按了 Z/C：侧旋的「侧」留着，上下旋听玩家的
			spin = side * absf(spin)
	elif kind == HitKind.LOOP:
		# 正手爆冲：强上旋，弹起后往前窜
		if player_spin == 0.0:
			spin = randf_range(1.2, 2.0)

	tx = clampf(tx, -table_half_width * 0.92, table_half_width * 0.92)

	# 蹲姿回球更冲：旋转加成（用户要的「蹲下回球更有力量」）
	if is_crouching():
		spin *= 1.0 + crouch_spin_bonus

	# ★ 飞行时间随蓄力深度插值 —— 这是「蓄力后球速明显更快」的关键。
	#   旧实现里 LOOP / FLICK 的飞行时间是写死的常数，于是「按一下」和
	#   「蓄满」打出来的球速一模一样（用户反馈就是这个「没差别」）。
	var flight := return_flight_time
	if kind == HitKind.LOOP:
		flight = lerpf(loop_flight_time_weak, loop_flight_time, power)
	elif kind == HitKind.FLICK:
		flight = lerpf(flick_flight_time_weak, flick_flight_time, power)
	# 蹲姿：整条弧线再压快一档
	if is_crouching():
		flight *= crouch_return_flight_scale
	# ★ 接发球那一拍：球更慢更高，对手有充分时间跑到位 —— 接发球变成
	#   「把球放回去」，不是「一击制胜」（serve_return_flight_scale）。
	if _serve_phase:
		flight *= serve_return_flight_scale

	# ── 先按「该落哪」解一版 ──
	var target := Vector3(tx, table_height + 0.02, tz)
	var v := _solve_return(from, target, flight)
	_last_shot_flight = flight

	# ── 拍面没喂正 → 有一定概率直接打出台（用户要的那条）──
	# 判据用的是**真实的出球速度方向**和拍面法线的关系，见 _face_out_chance。
	var out_p := _face_out_chance(v)
	var will_out := out_p > 0.0 and randf() < out_p
	if will_out:
		# 出台：整条弧线推出底线之外，球会落到台外 → 按落地判分给对手
		target.z = -table_half_length * randf_range(1.12, 1.42)
		target.x = clampf(tx * 1.2, -table_half_width * 1.4, table_half_width * 1.4)
		v = _solve_return(from, target, flight)

	# ── 正手爆冲的「必杀」掷骰（体力越高越容易）──
	_loop_kill = false
	if kind == HitKind.LOOP:
		var sl := clampf(_stamina / maxf(max_stamina, 1.0), 0.0, 1.0)
		var kill_p := loop_kill_base + loop_kill_stamina_bonus * sl
		# ★ 接发球那一拍的必杀率大幅压缩（用户要「难以发球就得分」的另一半）：
		#   接发球一板爆冲打死是条捷径，压住它，这一拍变成「把球放回去」。
		if _serve_phase:
			kill_p *= serve_return_kill_scale
		# ★ 再兜一道距离门槛（正主在 _swing_with_grip，这里防的是「挥拍那
		#   一瞬间球还没落台、按下之后才落到靠网处」这类边缘时序）——
		#   必杀绝不允许在近网短球上生效。
		_loop_kill = randf() < kill_p and bool(smash_spot()["ok"])
	# ★ 掷中必杀 → 退还一部分蓄力消耗。
	#   这一拍已经直接拿下一分了，当初蓄力付的那笔钱不该照收。
	if _loop_kill and _last_charge_cost > 0.0:
		refund = int(round(_last_charge_cost * kill_charge_refund))
		_stamina = minf(max_stamina, _stamina + float(refund))
	_last_charge_cost = 0.0

	b.launch(from, v, spin)

	_swing_timer = -1.0
	_swing_hit = true
	_hit_cooldown = 0.30
	_last_hitter = Hitter.PLAYER
	if _doubles:
		_note_my_hit()
	# 新的一段弧线开始了：两侧的弹跳计数归零。
	# 不归零的话，上一段弧线的弹跳会继续累加，`_bounces_opp >= 1` 会永远为真，
	# 之后任何一次落地都会被判成「对手没接到」。
	_bounces_player = 0
	_bounces_opp = 0
	_cancel_opponent_return()
	_cancel_partner_return()
	_stall_t = 0.0
	_rally_hits += 1
	# 接发球那一拍已经打出去了 —— 阶段结束，后面的对拉恢复成正常规则。
	# ★ 这里就是「接住对手发球」的唯一判定点：_serve_phase 为真且走进 _do_hit，
	#   只可能是玩家在把对手的发球打回去（玩家自己发球不经过 _do_hit，
	#   见 _on_bounced_table 里「发球上台」那条分支的注释）。
	if _serve_phase:
		_serve_returns += 1
	_serve_phase = false
	_max_rally = maxi(_max_rally, _rally_hits)
	_rally_last_kind = kind
	# 连拍爽感循环：查里程碑 + 更新今日 / 历史最长对拉纪录
	_on_rally_hit()
	# ★ 体力**不在这一拍扣**，改成整个回合（发球 → 死球）结束时一次性结算，
	#   见 _settle_rally_stamina()。这样回合进行中体力条是不动的，
	#   不会出现「打到第三拍判定盒突然缩一圈」这种看不见的手感跳变。
	# 蹲着接到的球单独计数（任务「低姿防守」）。
	# 直接走单例而不是攒到结算板 —— 蹲接是个即时动作，攒着反而容易漏。
	if is_crouching():
		_crouch_hits += 1
		var g := get_node_or_null("/root/Game")
		if g != null:
			g.call("bump", "crouch_hits", 1)
			g.call("daily_ensure")
			g.call("daily_note", "crouch_today", 1)
	set_state(State.RALLY)

	_audio_call("play_hit", [quality, _hit_audio_kind(kind)])
	var tail := ""
	if will_out:
		tail = "　打飞了！"
	elif _loop_kill:
		tail = "　必杀！"
	if refund > 0:
		tail += "　体力 +%d" % refund
	elif quality > 0.6:
		tail = "　好球！"
	# 把实际球速打进提示行 —— 蓄力与否的差别要能被「看见」而不只是感觉到
	_last_shot_speed = v.length()
	tail += "　球速 %.1f m/s" % v.length()
	if kind == HitKind.LOOP:
		_msg("正手爆冲！" + tail)
	elif kind == HitKind.FLICK:
		_msg("反手暴拧！" + tail)
	else:
		_msg("击球！" + tail + _spin_note())

	_hit_power = 0.0
	_hit_kind = HitKind.NORMAL


# ───────────── 旋球 / 拍面 / 蹲姿 ─────────────
## 当前是否按着旋球键。返回 +1 上旋（Z）、-1 下旋（C）、0 无。
##
## 用 Input.is_key_pressed 而不是新建 InputMap 动作：
## C 已经绑给「蹲下」了，再挂一个动作会两边抢事件；
## 而且这两个键必须能和鼠标键**同时**判，直接查物理键最省事也最稳。
func _spin_input() -> float:
	# ★ 点按开关状态（见 _unhandled_input 里 KEY_Z / KEY_C 那段）。
	#   原来这里是 Input.is_key_pressed(KEY_Z / KEY_C)，改成状态量之后
	#   发球、回球、蓄力击球全都自动跟着走 —— 它们本来都只调这一个函数。
	return float(_spin_mode)


## 这一拍实际的旋转值。base 是不按 Z/C 时的默认旋转。
func _shot_spin(base: float) -> float:
	var s := _spin_input()
	if s > 0.0:
		return spin_top
	if s < 0.0:
		return -spin_back
	return base


## 给 HUD / 提示词用的旋转说明
func _spin_note() -> String:
	var s := _spin_input()
	if s > 0.0:
		return "　上旋"
	if s < 0.0:
		return "　下旋"
	return ""


## 击球音效的 kind：0 普通 / 1 爆冲 / 2 暴拧 / 3 上旋拉 / 4 下旋搓。
## 普通挥拍带上旋/下旋时换一个音色 —— 用户要求「打球音效」要能听出差别。
func _hit_audio_kind(kind: int) -> int:
	if kind != HitKind.NORMAL:
		return kind
	var s := _spin_input()
	if s > 0.0:
		return 3
	if s < 0.0:
		return 4
	return 0


## 拍面法线（世界）。委托给 paddle_viewmodel，拿不到就退化成「朝对手」。
func _paddle_normal() -> Vector3:
	if _paddle != null and _paddle.has_method("face_normal"):
		return _paddle.call("face_normal") as Vector3
	return Vector3(0.0, 0.0, -1.0)


## 玩家的**拍形角**（度，正 = 拍面朝天）。
func _paddle_face_angle() -> float:
	if _paddle != null and _paddle.has_method("get_face_angle"):
		return float(_paddle.call("get_face_angle"))
	return 0.0


## 当前握拍的**甜点拍形**（待机拍形）。出台概率是相对它算的。
func _paddle_face_rest() -> float:
	if _paddle != null and _paddle.has_method("get_face_rest"):
		return float(_paddle.call("get_face_rest"))
	return 0.0


## 「拍面没喂正 → 出台」的概率。
##
## 判据 = **当前拍形角偏离「甜点拍形」多少度**。拍形由 paddle_viewmodel 的
## 开合曲线给出：起手拍面朝天（开）→ 击球点回正 → 收拍压死。
## 所以「推早了拍面还开着 / 推晚了拍面压死」都会出台，正打在点上则稳。
##
## ★ 为什么不用「拍面法线 · 出球方向」这个更"物理"的判据（前后试过两版）：
##   1. **没有判别力**。球本来就是沿拍面法线的反向弹出去的，两者天然接近反向，
##      实测 |dot| 全程只落在 0.93~0.98（换成夹角 11°~21°），可用区间 10°。
##      原来那套 0.85/0.55 的点积阈值等于永远不触发。
##   2. **不可调**。那个夹角同时被「挥拍姿态」和「拍形曲线」两个来源搅在一起，
##      而且不是单调的：实测给反手加 −18.7° 的拍形补偿，偏差反而涨了 18°——
##      因为拍形绕的是 Aim 局部 Z 轴、抡拍绕的是相机 X 轴，球面上的夹角会拐弯，
##      线性外推直接失效。
##   拍形角只有一个来源、单调、和玩家的动作一一对应，所以它是可调的那一个。
func _face_out_chance(_v: Vector3) -> float:
	var off := absf(_paddle_face_angle() - _paddle_face_rest())
	var span := maxf(face_bad_deg - face_ok_deg, 0.01)
	var excess := clampf((off - face_ok_deg) / span, 0.0, 1.0)
	# 体力越低，拍形控制越差 → 出台概率上升（用户要的「体力与击球成功率正相关」）。
	# 够球范围那边已经缩过一次（stamina_reach_floor），这里是第二重体现：
	# 低体力时就算勉强够到球，也更容易「翻着拍面打飞」。
	var fatigue := 1.0 - clampf(_stamina / maxf(max_stamina, 0.01), 0.0, 1.0)
	var f := lerpf(1.0, fatigue_out_extra, fatigue)
	return out_chance_base * excess * excess * f


## 玩家的蹲姿。player_movement 里蹲下是插值量，>0.5 才算「蹲住了」。
func is_crouching() -> bool:
	if _player != null and _player.has_method("is_crouching"):
		return bool(_player.call("is_crouching"))
	return false


## 求一拍能过网、且尽量落在 target 的初速度。
## 先按 flight_time 解一次，模拟发现过不了网就把弧线拉高重试。
func _solve_return(from: Vector3, target: Vector3, flight_time: float = -1.0,
				   speed_max: float = -1.0) -> Vector3:
	var b := _ball as PingPongBall
	if b == null:
		return Vector3(0, 0, -1)
	var need := table_height + net_height + 0.015
	var t := return_flight_time if flight_time <= 0.0 else flight_time
	var cap := return_speed_max if speed_max <= 0.0 else speed_max
	for _i in range(8):
		var v := b.solve_velocity(from, target, t)
		var h := b.simulate_net_height(from, v)
		if h >= need:
			return _clamp_return_speed(v, cap)
		t += 0.06
	return _clamp_return_speed(b.solve_velocity(from, target, t), cap)


## 回球球速的数值兜底（见 return_speed_max 的注释）
##
## speed_max <= 0 时用默认的 return_speed_max；扣杀会传一个更大的上限进来
## （见 opp_smash_speed_max）—— 不区分的话扣杀会被削回普通球速。
func _clamp_return_speed(v: Vector3, speed_max: float = -1.0) -> Vector3:
	var cap := return_speed_max if speed_max <= 0.0 else speed_max
	var sp := v.length()
	if sp <= cap or sp < 0.01:
		return v
	return v * (cap / sp)


# ───────────── 对手回球 ─────────────
## 对手球拍所在的 z 平面。
## 这是**跨脚本硬约定**：opponent_player.gd 里 stand_z(-1.78) + blade_target.z(0.48)，
## 也正是 _do_serve() 的发射点 z。改那边的话这里要一起改。
const OPP_PADDLE_Z: float = -1.30


## 对手该用正手还是反手。
##
## ★ 用户要「对手也有正反手切换」。判定用的是**触球点相对对手身体的左右**，
##   和真人一样：球到持拍手那一侧就正手抽，到了身体另一侧就只能反手挡。
##   对手面朝 +Z，所以它的右手边是 +X（right = up × forward = Y × Z = X）。
## 返回 0 = 正手 / 1 = 反手，和玩家 _grip_mode 的取值一致。
func _opponent_grip_for(contact_x: float) -> int:
	var body_x := 0.0
	if _opponent != null and _opponent.has_method("step_offset"):
		var off: Vector2 = _opponent.call("step_offset")
		body_x = off.x
	return 0 if contact_x >= body_x else 1


## 让对手以指定握拍挥一次拍。脚本里所有「对手击球」的地方都走这里，
## 保证握拍状态和动作永远一致（不会出现「说好反手、挥的是正手」）。
func _opponent_swing(contact_x: float) -> void:
	if _opponent == null:
		return
	var grip := _opponent_grip_for(contact_x)
	if _opponent.has_method("set_grip"):
		_opponent.call("set_grip", grip)
	if _opponent.has_method("trigger_swing"):
		_opponent.call("trigger_swing")


## 对手各难度的失误率
func _opponent_miss_chance() -> float:
	var base := _tier5(opponent_miss_easy, opponent_miss_normal, opponent_miss_hard,
		opponent_miss_expert, opponent_miss_master)
	# ★ 接发球阶段几乎必回（用户要「所有对局里都难以发球就得分」）。
	#   大师档 1.8% 压到 0.5%，约 200 球才白送一分 —— 发球偷分这条路堵死。
	if _serve_phase:
		base *= serve_return_miss_scale
	# ★ AI 累了失误变多：体力见底时把失误率放大 opponent_fatigue_miss_scale 倍。
	#   这是「把回合拖长」第一次变成真战术的原因 —— 磨他是有收益的。
	var fatigue := 1.0 - clampf(_opp_stamina / maxf(opponent_max_stamina, 0.01), 0.0, 1.0)
	return base * lerpf(1.0, opponent_fatigue_miss_scale, fatigue)


func _opponent_out_chance() -> float:
	var base := _tier5(opponent_out_easy, opponent_out_normal, opponent_out_hard,
		opponent_out_expert, opponent_out_master)
	# 接发球时「碰到但回球出台」也压低，但压得比 miss 轻 ——
	# 全挡住的话对手会变成一堵墙，保留一点失误才有来有回。
	if _serve_phase:
		base *= serve_return_out_scale
	return base


## 对手回球飞行时间的倍率（乘在 opponent_return_flight 上）。
func _opponent_return_flight_scale() -> float:
	var base := _tier5(opponent_return_flight_easy, opponent_return_flight_normal,
		opponent_return_flight_hard, opponent_return_flight_expert,
		opponent_return_flight_master)
	# ★ AI 累了就打不出快球：飞行时间被拉长，回球又高又慢，玩家更好上手。
	var fatigue := 1.0 - clampf(_opp_stamina / maxf(opponent_max_stamina, 0.01), 0.0, 1.0)
	return base * lerpf(1.0, opponent_fatigue_flight_scale, fatigue)


## 对手回球落点的横向散布（占半台比例）。
func _opponent_return_spread() -> float:
	return _tier5(opponent_return_spread_easy, opponent_return_spread_normal,
		opponent_return_spread_hard, opponent_return_spread_expert,
		opponent_return_spread_master)


## 球合法落在对方半台 —— 排一次对手回球。
##
## 时机不用「算延迟」，改成**逐帧轮询球有没有飞到球拍所在的 z 平面**。
## 原因：一开始我是用「(拍面 z − 球 z) / 球的 z 速度」外推延迟的，
## 但因为空气阻力，球在飞行中会持续减速，线性外推必然**偏早** ——
## 实测排出 0.17 s，球那时候才到 z=-1.20，离拍面还差 0.14 m，
## 看起来就是「球在半空中自己拐了个弯」。
## 轮询则完全不受阻力/旋转/弹跳影响，接触点永远精确落在拍面上。
func _schedule_opponent_return(pos: Vector3) -> void:
	if not opponent_returns or _opponent == null or _match_over:
		return
	# 擦网。球撞网后速度被削成近乎垂直下落（见 pingpong_ball._cross_net），
	# 就算蹭过网落到对面也只剩几厘米的水平速度 —— 这时候再让对手
	# 「从台子中间把球打回去」会非常假。让它自生自灭：球会在某一侧
	# 二次弹跳或落地，正常判分即可。
	if _net_hit:
		return
	var b := _ball as PingPongBall
	if b == null or not b.is_flying():
		return
	if _doubles:
		# 换人：球飞过去的时候，接球的那个对手要变成「当前对手」，
		# 这样迈步（step_toward）和后面的挥拍都作用在他身上。
		_set_active_opponent(_opp_turn)

	# 够不着就必失。这一条比随机数更「讲道理」：
	# 玩家把球打到边线大角，对手是**因为跑不到**才没接住，而不是运气。
	# ★ 接发球那一拍放宽（opp_serve_reach_bonus）：玩家的瞄准范围比对手的
	#   够球半径大，两端有一条「瞄哪儿就白送分」的死角，见那条参数的注释。
	var reach_x := opponent_reach_x
	if _serve_phase:
		reach_x *= opp_serve_reach_bonus
	var too_wide := absf(pos.x) > reach_x
	_opp_will_hit = (not too_wide) and randf() >= _opponent_miss_chance()
	_opp_will_out = _opp_will_hit and randf() < _opponent_out_chance()

	# 正手爆冲的「必杀」：这一拍掷中了就直接判对手接不到，跟落点、够不够得着
	# 都无关 —— 用户要的就是「爆冲有一定概率直接打死」。
	if _loop_kill:
		_opp_will_hit = false
		_opp_will_out = false

	_opp_armed = true
	_opp_armed_t = opponent_return_timeout
	_opp_min_t = opponent_contact_delay

	# 让对手挪到「球弹起后爬到最高点」的那个位置去等球。
	#
	# x 要用**预测值**，不能直接用落点 x：球落台后横向速度并不会消失
	# （实测一个球落点 x=+0.47，飞到触球点时已经飘到 +0.68，差了 21 cm），
	# 照着落点站过去，触球瞬间球已经横着跑掉了。
	# z 则用落点直接 + 固定前瞻量：球飞完这 0.35 m 正好爬到 ≈1.0 m 高，
	# 也就是球拍静止位所在的高度（见 opponent_contact_lead）。
	var dt := clampf(opponent_contact_lead / maxf(-b.velocity.z, 0.5), 0.10, 0.40)
	var predict_x := pos.x + b.velocity.x * dt
	if _opponent.has_method("step_toward"):
		_opponent.call("step_toward", predict_x, pos.z - opponent_contact_lead)


func _cancel_opponent_return() -> void:
	_opp_armed = false
	_opp_armed_t = 0.0
	_opp_min_t = 0.0
	_opp_will_hit = false
	_opp_will_out = false


func _update_opponent_return(delta: float) -> void:
	if not _opp_armed:
		return
	_opp_armed_t -= delta
	if _opp_min_t > 0.0:
		_opp_min_t -= delta
	var b := _ball as PingPongBall
	if b == null or not b.is_flying() or _point_over or _match_over \
		or _opp_armed_t <= 0.0:
		_cancel_opponent_return()
		return
	if not _opp_will_hit:
		return
	if _opp_min_t > 0.0:
		return
	# 球拍平面是**实时**的：对手可能正在前后迈步，拍面跟着一起动。
	var plane := OPP_PADDLE_Z
	if _opponent.has_method("paddle_plane_z"):
		plane = float(_opponent.call("paddle_plane_z"))
	if b.global_position.z <= plane:
		_do_opponent_return()
	# 判成「没接到」的话就干等，等球落地 / 二次弹跳去判分（见 _on_bounced_twice）。
	# 球的 z 速度在整段飞行里恒为负，所以「等不到球飞进拍面」只可能是它先落地了，
	# 那种情况下 _finish 会把这一拍收掉。


## 给定触球高度 h（m），返回对手的扣杀概率。
##
## 曲线：h ≤ opp_smash_h_low 时是 opp_smash_chance_low（低球几乎不扣），
## h ≥ opp_smash_h_full 时吃满 opp_smash_chance_high（高球基本必扣），
## 中间线性过渡 —— 用户要的「球越高越容易触发」。
## 抽成独立函数是为了能被探针直接扫曲线，不然只能靠肉眼在游戏里猜。
func opp_smash_chance_at(h: float) -> float:
	if not opp_smash_enabled:
		return 0.0
	var k := clampf(inverse_lerp(opp_smash_h_low, opp_smash_h_full, h), 0.0, 1.0)
	return clampf(lerpf(opp_smash_chance_low, opp_smash_chance_high, k) * _opp_rage(),
		0.0, 1.0)


## 对手的「凶度」倍数：玩家连续得分时他扣得更凶（方案 C 的第三根支柱）。
##
## ★ 只乘在**扣杀概率**上，不动反应速度 / 回球质量 —— 那两样一改，对手就从
##   「变凶」直接变成「换了个难度」，玩家会以为自己手滑，而不是「我被压住了」。
## ★ 从第 2 连胜才开始加（1 分不算连击），4 连胜吃满 streak_rage_max。
func _opp_rage() -> float:
	return clampf(1.0 + streak_rage_step * float(maxi(_win_streak - 1, 0)),
		1.0, streak_rage_max)


func _do_opponent_return() -> void:
	var b := _ball as PingPongBall
	if b == null or not b.is_flying() or _point_over or _match_over:
		_cancel_opponent_return()
		return

	# 挥拍**就在这一瞬间**开始，而不是提前 60 ms。
	# 挥拍的缓动是前重后轻的（_process 里 sin(f·π)，p 刚过 0.06 就已经到 55% 幅度），
	# 提前哪怕 0.02 s，拍子也已经甩到球上方十几厘米了 ——
	# 实测提前 0.062 s 时拍面中心在 y=1.37、而球在 y=0.97，差 0.4 m，
	# 2.5 m 外能明显看出「球不是被拍子打的」。
	# 现在改成「球到拍面 → 同时挥拍」，接触瞬间拍子正好在静止位（也就是球的位置），
	# 挥拍动作自然变成随挥。
	#
	# ★ 握拍按**触球点**决定：球到对手身体右侧就正手、左侧就反手。
	#   所以触球点得先算出来 —— 原来 from 是在挥拍之后才取的，这里提前。
	var from := b.global_position

	# ★★ 对手扣杀：按**触球这一帧的高度**给概率（用户要的「发球冒高会被扣、
	#    而且球越高越容易触发」）。
	#    ★ 为什么在触球时算而不是在 _schedule_opponent_return 排定时算：
	#      排定那一刻球刚弹起、还在往上爬，那时候读到的 y 根本不是触球高度。
	#      只有逐帧轮询到球真的飞进拍面平面，才知道这一拍是低平球还是高球。
	#    ★ 修之前这甚至不算一个机制：对手就在球的当前位置解速度，
	#      球来得多高就从多高打出去，于是高球自然解出一条陡而快的弧线 ——
	#      看着像扣杀，但概率不可控、也没法调。现在概率、球速、落点全可调。
	_opp_contact_y = from.y
	_opp_smash = false
	if opp_smash_enabled and not _opp_will_out:
		_opp_smash = randf() < opp_smash_chance_at(from.y)
	if _opp_smash:
		_opp_smashes += 1

	if _doubles:
		_set_active_opponent(_opp_turn)
	_opponent_swing(from.x)
	_audio_call("play_opponent_hit", [1.0])

	var sp := opp_smash_spread if _opp_smash else _opponent_return_spread()
	var tx := randf_range(-table_half_width * sp, table_half_width * sp)
	if _doubles:
		# ★ 换人必须发生在**算落点之前**：_note_opp_hit() 里会把 _my_turn
		#   翻到另一个人，并把相机挪过去；然后落点跟着往他那半边送 ——
		#   于是「换人」和「球往哪来」永远一致，玩家不会站在错误的一侧干等。
		_note_opp_hit()
		var side := -1.0 if _my_turn == 0 else 1.0
		tx = side * randf_range(table_half_width * 0.16, table_half_width * sp)
	var tz := randf_range(table_half_length * 0.32, table_half_length * 0.94)
	if _opp_smash:
		# 扣杀往底线压（普通回球是 0.32~0.94，扣杀是 0.62~0.99）
		tz = randf_range(table_half_length * opp_smash_deep_lo,
						 table_half_length * opp_smash_deep_hi)
	if _opp_will_out:
		# 回球出台：故意打过底线，球会落到台外 → 落地后玩家得分
		tz = table_half_length * randf_range(1.10, 1.38)
	var target := Vector3(tx, table_height + 0.02, tz)

	var flight := opponent_return_flight * _opponent_return_flight_scale()
	var cap := return_speed_max
	if _opp_smash:
		flight *= opp_smash_flight_scale
		cap = opp_smash_speed_max

	var v := _solve_return(from, target, flight, cap)
	b.launch(from, v, randf_range(-0.5, 0.9))

	_last_hitter = Hitter.OPPONENT
	_bounces_player = 0
	_bounces_opp = 0
	_hit_cooldown = 0.0
	_opp_armed = false
	_stall_t = 0.0
	# 本回合 AI 又接了一拍 —— 回合结束结算体力时要用（见 _settle_rally_stamina）
	_opp_rally_hits += 1
	# 对手这一拍把球接回去了，接发球阶段到此结束
	_serve_phase = false
	set_state(State.INCOMING)
	# ★ AI 队友模式：这一拍该队友接的话，这里就把他的回球排上。
	#   必须排在**算出落点之后** —— _note_opp_hit() 已经把 _my_turn 翻到接球那个人了，
	#   这时候才知道「球是飞向你还是飞向队友」。
	_schedule_partner_return()
	if _opp_smash:
		# 扣杀单独喊一句：球又平又快，玩家得立刻抬拍，不能再像普通回球那样等
		_msg("★ 对手扣杀！　快挥拍！")
	elif _doubles:
		_msg("对手回球！轮到%s侧接球　挥拍！" % ["左", "右"][_my_turn])
	else:
		_msg("对手回球！　挥拍！")


# ───────────── AI 队友的回球 ─────────────
# 和对手回球同一套「排定 → 逐帧轮询球飞到拍面 → 击出」的结构，
# 差别只有两点：拍面在**我方**半台（球 z 从小到大穿过），以及
# 击球者记在我方账上（_last_hitter = PLAYER）。
func _schedule_partner_return() -> void:
	if not _partner_ai or not _doubles:
		return
	# 这一拍轮到玩家自己 —— 交回给玩家，别抢
	if _my_turn == _player_slot:
		return
	var b := _ball as PingPongBall
	if b == null or not b.is_flying():
		return
	# 对手这一拍出界了：球会落到台外，不该再有人去接
	if _opp_will_out:
		return
	_par_will_hit = randf() >= (1.0 - partner_ai_skill)
	_par_armed = true
	# ★ 用队友专用的超时，不要借 opponent_return_timeout(0.85 s) ——
	#   那是按「对手回球」的短航程标定的，接对手发球时球到不了（见参数注释）。
	_par_armed_t = partner_return_timeout
	_par_min_t = opponent_contact_delay
	# 让队友那把拍子往球这一侧挪一点 —— 看得见他在动，不是根柱子
	var node := _partner_paddle()
	if node != null and node.has_method("step_toward"):
		var dt := clampf(opponent_contact_lead / maxf(b.velocity.z, 0.5), 0.10, 0.40)
		node.call("step_toward", clampf(b.global_position.x + b.velocity.x * dt,
										-1.2, 1.2), doubles_partner_z)


func _partner_paddle() -> Node:
	if _my_turn >= 0 and _my_turn < _partner_nodes.size():
		return _partner_nodes[_my_turn] as Node
	return null


func _cancel_partner_return() -> void:
	_par_armed = false
	_par_armed_t = 0.0
	_par_min_t = 0.0
	_par_will_hit = false


func _update_partner_return(delta: float) -> void:
	if not _par_armed:
		return
	_par_armed_t -= delta
	if _par_min_t > 0.0:
		_par_min_t -= delta
	var b := _ball as PingPongBall
	if b == null or not b.is_flying() or _point_over or _match_over \
		or _par_armed_t <= 0.0:
		_cancel_partner_return()
		return
	if not _par_will_hit or _par_min_t > 0.0:
		return
	# 拍面在队友身前（他站在 doubles_partner_z、绕 Y 转 180°、拍子伸向球台 -z 方向）。
	# ★ 不能用 opponent_player.paddle_plane_z()：那个函数直接把本地 blade_target.z
	#   加到 global_position.z 上，而队友是绕 Y 转了 180° 的，本地 +z 实际指向世界 -z，
	#   照它算出来的平面在队友**背后**（实测 2.10，比站位还靠后）—— 球还没飞到那儿就
	#   可能落地/出台，于是「队友永远不接球」。这里改用 blade_position() 读真实世界拍面
	#   中心（已用 to_global 吃掉 180° 旋转），实测 = 站位 − 0.48 ≈ 1.14，正好在台面上。
	var node := _partner_paddle()
	var plane := 9.9
	if node != null and node.has_method("blade_position"):
		plane = float(node.call("blade_position").z) + partner_paddle_dz
	var bz := b.global_position.z
	# ★ 出手判据有两条，缺一不可（原来只有第一条，队友端到端成功率实测 0/56）：
	#   ① 球飞过了队友拍面所在平面 —— 长球、高球走这条；
	#   ② 球已经在我方半台**弹过一次**、并且越过了 partner_bounce_hit_z ——
	#      对手发球 / 台内短球的第二跳落点实测只有 z=0.77~1.05，比拍面(≈1.14)**还靠前**，
	#      球会在够到拍面之前就二次落地被判「没接到」，队友永远出不了手。
	#      ② 就是真人接发球的那个时机：球第一次落台弹起就打。
	if bz >= plane or (_bounces_player >= 1 and bz >= partner_bounce_hit_z):
		_do_partner_return()


func _do_partner_return() -> void:
	var b := _ball as PingPongBall
	if b == null or not b.is_flying() or _point_over or _match_over:
		_cancel_partner_return()
		return
	var from := b.global_position
	var node := _partner_paddle()
	if node != null:
		if node.has_method("set_grip"):
			node.call("set_grip", 0 if from.x >= _my_x(_my_turn) else 1)
		if node.has_method("trigger_swing"):
			node.call("trigger_swing")
	_audio_call("play_opponent_hit", [0.8])

	# 落点：送到「下一个该接球的对手」那半边，和对手回球对称
	var sp := _spread()
	var side := -1.0 if _opp_turn == 0 else 1.0
	var tx := side * randf_range(table_half_width * 0.16,
								 table_half_width * clampf(sp, 0.2, 0.85))
	var tz := -randf_range(table_half_length * 0.32, table_half_length * 0.94)
	var flight := return_flight_time * partner_ai_flight_scale
	var v := _solve_return(from, Vector3(tx, table_height + 0.02, tz), flight)
	b.launch(from, v, randf_range(-0.5, 0.9))

	# ★ 队友是我方的人：最后击球者记 PLAYER，轮换走 _note_my_hit()
	_last_hitter = Hitter.PLAYER
	if _doubles:
		_note_my_hit()
	_rally_hits += 1
	_max_rally = maxi(_max_rally, _rally_hits)
	# 队友这一拍也计入连拍 —— 双打里玩家感知的连拍数是「我们俩一起打了多少拍」
	_on_rally_hit()
	_bounces_player = 0
	_bounces_opp = 0
	_par_armed = false
	_opp_armed = false
	_stall_t = 0.0
	set_state(State.RALLY)
	_msg("队友回球！")


# ───────────── AI 队友的发球 ─────────────
# 和 _player_serve 走**同一套**出口（同一份 _serve_plan、同一个合规解算器
# _solve_legal_serve），差别只有三处：
#   ① 出手点来自队友那把拍子的真实世界位置；
#   ② 不吃玩家的蓄力（_charge_t 是玩家的输入，队友没这回事）；
#   ③ 出手前有一段 partner_serve_delay 的停顿，让「他发球」这件事看得见。

## 队友那把拍子（按显式索引取，不用 _partner_paddle()）。
##
## ★ 不能用 _partner_paddle()：它按 `_my_turn` 取，而发球时 _my_turn 的语义
##   是「下一个该接球的人」，跟「发球的人」不一定同一个人。发球这一拍
##   认准 _server_idx 才稳。
func _partner_node_at(idx: int) -> Node:
	if idx >= 0 and idx < _partner_nodes.size():
		return _partner_nodes[idx] as Node
	return null


## 队友发球时「球拿在他手里」的位置（也是出手点）。
##
## ★ 读 blade_position()（真实世界拍面中心，已用 to_global 吃掉队友那 180° 镜像），
##   不按本地偏移硬加 —— 队友是 rotation_degrees.y = 180 镜像过来的，本地 +z
##   指向世界 -z，硬加会算到他**背后**去。这个坑 _update_partner_return 踩过一次。
func _partner_serve_hold_point() -> Vector3:
	var base := Vector3(_my_x(_server_idx), 1.02, doubles_partner_z - 0.30)
	var node := _partner_node_at(_server_idx)
	if node != null and node.has_method("blade_position"):
		var bp: Vector3 = node.call("blade_position")
		base = Vector3(bp.x, maxf(bp.y, 0.98), bp.z)
	# 往拍面外侧推开一点，球别埋在胶皮里
	return base + Vector3(0.0, 0.06, 0.10)


## 队友的「持球」状态：球 stop 住摆在队友拍前，等他出手。
## 和 _hold_ball_for_serve 同一套路 —— 球停在非飞行态，不参与物理，
## 所以不会被弹台 / 落地 / 触网那些判分信号误触发。
func _hold_ball_for_partner() -> void:
	var b := _ball as PingPongBall
	if b == null:
		return
	b.stop()
	b.global_position = _partner_serve_hold_point()
	_reset_rally_state()
	_hit_cooldown = 0.0
	_tossing = false
	_toss_t = 0.0
	set_state(State.SERVE_DELAY)


## 队友发球的倒计时：每帧把球摆回他拍前（他挪步时球跟着走），到点出手。
func _update_partner_serve(delta: float) -> void:
	if not _partner_serving():
		# 中途球权变了（局结束 / 被脚本改过状态）→ 收掉倒计时，别留个死循环
		_par_serve_t = -1.0
		return
	_par_serve_t -= delta
	var b := _ball as PingPongBall
	if b != null and not b.is_flying():
		b.global_position = _partner_serve_hold_point()
	if _par_serve_t <= 0.0:
		_do_partner_serve()


## 队友把球发出去。
func _do_partner_serve() -> void:
	_par_serve_t = -1.0
	if _match_over or _point_over or not _partner_serving():
		return
	var b := _ball as PingPongBall
	if b == null:
		return

	var node := _partner_node_at(_server_idx)
	var from := _partner_serve_hold_point()
	# 出手点不能低到台面以下 —— 低于台面解出来的球必撞网
	from.y = maxf(from.y, table_height + 0.16)

	if _serve_plan.is_empty():
		_serve_plan = _plan_serve(1)
	# 队友发球也跟着视角走：同一队的落点由玩家决定（见 _apply_serve_aim 的双打夹取）
	_apply_serve_aim(_serve_plan)
	_serve_plan["spin"] = _shot_spin(0.7)
	var flight := float(_serve_plan.get("flight", _flight_time())) * partner_serve_flight_scale
	var plan := _serve_plan.duplicate()
	plan["flight"] = flight

	# ★ 和玩家发球同一个解算器：先弹己方半台 → 过网 → 再弹对方半台。
	var res := _solve_legal_serve(from, plan)
	var v: Vector3
	if bool(res["ok"]):
		v = res["v"]
	else:
		# 兜底：旧的「直落对方台」轨迹（宁可略不合规，也不能撞网卡住球局）
		var target := Vector3(float(_serve_plan.get("opp_x", 0.0)),
							  table_height + 0.02, float(_serve_plan.get("opp_z", -0.7)))
		v = _solve_serve(from, target, flight)
		v = _cap_serve_speed(from, v)

	# 队友也真的挥一下拍。球是凭空 launch 出来的，拍子不动就是「雕塑发球」——
	# 和 _do_serve 里让对手挥那一下同一个理由。
	if node != null:
		if node.has_method("set_grip"):
			node.call("set_grip", 0)
		if node.has_method("trigger_swing"):
			node.call("trigger_swing")

	var spin := _shot_spin(0.7)
	_reset_rally_state()
	b.launch(from, v, spin)
	_serve_plan = {}
	_last_hitter = Hitter.PLAYER        # 我方发的球，对手才会去排回球
	_hit_cooldown = 0.24
	_swing_timer = -1.0
	set_state(State.RALLY)
	# 和 _player_serve 一样进「接发球阶段」：这一拍对手几乎必回、队友也打死不了
	_serve_phase = true
	# 队友的手感音用「对面那一拍」的音色 —— 一听就知道球不是自己打的
	_audio_call("play_opponent_hit", [0.85])
	_msg("队友发球！　球速 %.1f m/s" % v.length())


# ───────────── 计分 / 音效反馈 ─────────────
## 判分总表（加了对手回球之后，一切都由「谁最后碰球」+「球落在哪一侧」决定）：
##   球落对方半台 + 最后碰球的是玩家   → 玩家的好球，轮到对手接（不判分）
##   球落对方半台 + 最后碰球的是对手   → 对手把自己打丢了，玩家得分
##   球落我方半台 + 最后碰球的是对手   → 对手的回球到了，玩家该挥拍
##   球落我方半台 + 最后碰球的是玩家   → 玩家的球回到自己半台（下网回弹），对手得分
##   球落我方半台 + 还没人碰过球       → 发球上台，玩家该挥拍
## 落地 / 二次弹跳只是「没接到」的两种表现形式，最后都收敛到上面这套判断。
func _on_bounced_table(pos: Vector3, side: int) -> void:
	_stall_t = 0.0
	# 球台弹跳声：离玩家越近听起来越实
	var d := 0.0
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		d = cam.global_position.distance_to(pos)
	_audio_call("play_bounce", [clampf(1.0 - d / 9.0, 0.15, 1.0)])

	if _point_over:
		return
	if side < 0:
		_bounces_opp += 1
		if _last_hitter == Hitter.PLAYER:
			if _bounces_opp == 1:
				# 玩家的球合法落在对方半台 —— 该对手出手了
				_schedule_opponent_return(pos)
			# _bounces_opp >= 2 走 _on_bounced_twice
		elif _last_hitter == Hitter.OPPONENT:
			# 对手把自己的回球打回了自己半台（刮到自己台面），玩家得分
			_player_score += 1
			_credit_winner()
			_finish("对方失误！+%d" % _player_score, true)
	else:
		_bounces_player += 1
		# 记下落点 z：蹲姿够不到近台短球的判据要用它（见 _check_hit）
		_player_bounce_z = pos.z
		# ★★ 合法发球的**第一跳本来就必须落在发球方自己半台**（见 _solve_legal_serve）。
		#   所以这一跳绝不能按「没过网」判分 —— 判了的话玩家一发球就直接丢分、
		#   对手连球都摸不到。用户报的「自己发球 AI 不会接球」+「计分把我和
		#   AI 的分记错」就是这一条：探针实测 t=35 球弹在 z=+0.24（自己半台，
		#   合规），t=36 比分就成了 0:1。
		#   判据用 `_serve_phase and _rally_hits == 0`：发球出手之后到「接发球
		#   那一拍」打出去之前，中间没有任何一拍是我打出去的（_rally_hits 在
		#   发球前被 _reset_rally_state 归零），所以此时落在自己半台的第一跳
		#   只可能是发球本身。
		#   ★ 还要卡 `_last_hitter == Hitter.PLAYER`：对手发球时 _last_hitter
		#     是 NONE（_do_serve 不设它），那时候 `_serve_phase / _rally_hits`
		#     同样成立 —— 不卡的话会把对手发球时的「球弹起了 —— 挥拍！」
		#     换成「发球上台」，等于把该不该挥拍的提示弄丢了。
		if _serve_phase and _rally_hits == 0 and _bounces_player == 1 \
			and _last_hitter == Hitter.PLAYER:
			_msg("发球上台 —— 过网")
		elif _last_hitter == Hitter.PLAYER:
			# 玩家打出的球落回自己半台 —— 撞网回弹 / 直接打丢
			_opponent_score += 1
			_finish("没过网… %d" % _opponent_score, false)
		elif _bounces_player == 1:
			_msg("球弹起了 —— 挥拍！")


func _on_bounced_twice(_pos: Vector3, side: int) -> void:
	if _point_over:
		return
	if side > 0:
		# ★ 发球没过去：自己的第一跳（合法）之后又在同一侧弹第二次，
		#   说明这一发根本没到对方半台 —— 这是**发球失误**，不是「玩家没接到」。
		#   两种都判给对手，只是提示要分清楚，否则玩家看提示会一头雾水。
		if _serve_phase and _rally_hits == 0 and _last_hitter == Hitter.PLAYER:
			_opponent_score += 1
			_finish("发球没过网… %d" % _opponent_score, false)
			return
		# 我方半台弹两次 = 玩家没接到
		_opponent_score += 1
		_finish("没接到… %d" % _opponent_score, false)
		return
	# 对方半台弹两次。**但如果已经排定了对手回球，这一下不算数** ——
	# 球在飞向对手的路上（或刚过他身边）难免再蹭一下台面，
	# 那不是「对手失误」，是这一拍还没打完。
	if _opp_armed:
		return
	_player_score += 1
	_credit_winner()
	_finish("对手没接到！+%d" % _player_score, true)


## 归因制胜分：这一分的最后一拍是爆冲还是暴拧
func _credit_winner() -> void:
	if _rally_last_kind == HitKind.LOOP:
		_loop_winners += 1
	elif _rally_last_kind == HitKind.FLICK:
		_flick_winners += 1


## 把本局的过程型统计同步给单例（任务奖励用）。
##
## 用「已上报数」而不是「上报完清零」来去重：_loop_winners 还要留在
## 结算面板上给玩家看，清零了就只能显示 0。累计值天然幂等，重入也安全。
func _progress_stats() -> void:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return
	# set_max 天然幂等（只在变大时写），bump 不是 —— 所以计数项一律走
	# 「已上报数」去重。★ _progress_stats 每得一分就被 _finish 调一次，
	#   不去重的话「接住 5 次发球」会被记成几十次（第一局就这么踩过）。
	g.call("set_max", "max_rally", _max_rally)
	g.call("set_max", "best_streak", _best_streak)
	if _loop_winners > _reported_loop:
		g.call("bump", "winners_loop", _loop_winners - _reported_loop)
		_reported_loop = _loop_winners
	if _flick_winners > _reported_flick:
		g.call("bump", "winners_flick", _flick_winners - _reported_flick)
		_reported_flick = _flick_winners
	if _serve_returns > _reported_serve_returns:
		g.call("bump", "serve_returns", _serve_returns - _reported_serve_returns)
		_reported_serve_returns = _serve_returns
	if _rally10_count > _reported_rally10:
		g.call("bump", "rally_10plus", _rally10_count - _reported_rally10)
		_reported_rally10 = _rally10_count
	if _rally20_count > _reported_rally20:
		g.call("bump", "rally_20plus", _rally20_count - _reported_rally20)
		_reported_rally20 = _rally20_count
	# ── 今日 / 每周维度 ──
	# ★ 必须先 daily_ensure()：跨了天的话它把计数清零，之后才是本局的增量。
	#   不调的话「昨天打了 3 局」会被记成今天的。
	g.call("daily_ensure")
	_sync_daily("loop_today", _loop_winners)
	_sync_daily("flick_today", _flick_winners)
	_sync_daily("serve_today", _serve_returns)
	_sync_daily("rally10_today", _rally10_count)
	_sync_daily("rally20_today", _rally20_count)
	_sync_daily("rally30_week", _rally30_count, true)
	# 极值维度走 max，不是累加
	g.call("daily_max", "streak_today", _best_streak)


## 把「本局累计值」的**增量**报给今日（或本周）计数。
##
## ★ 用差值而不是直接 +=1：_progress_stats 每得一分就跑一次，
##   直接累加会把同一个事件重复记很多次。这和上面 _reported_xxx 是同一套思路，
##   只是把「已上报数」收进一个字典，避免每加一个维度就多一个成员。
func _sync_daily(key: String, cur: int, week: bool = false) -> void:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return
	var last := int(_today_sync.get(key, 0))
	if cur <= last:
		return
	_today_sync[key] = cur
	if week:
		g.call("weekly_note", key, cur - last)
	else:
		g.call("daily_note", key, cur - last)


func _on_hit_net(pos: Vector3) -> void:
	_stall_t = 0.0
	_net_hit = true
	_audio_call("play_net")
	_audio_call("play_bounce", [0.25])
	# ★ 发球擦网 / 下网 → 重发（let），不判分、不换发球权。
	#   用户报的「下网之后就发不了球」就是这条路径：撞网后球被削成近乎垂直下落，
	#   落点飘忽（有时弹自己台面、有时直接落地），判分分支一走岔就收不掉这一分，
	#   状态机停在 RALLY 上再也回不到 SERVE_DELAY。
	#   与其去穷举那些落点分支，不如在源头收口：发球这一下没过网就重来。
	if _serve_phase and _rally_hits == 0:
		_call_let(pos)
		return
	_msg("下网了…")


## 发球重发（let）。
##
## ★ 关键：把球 stop() 掉并置 `_point_over = true`。
##   撞网那一帧球还在飞（速度被削成近乎垂直），后面的 bounced_table /
##   landed_floor 迟早会来一次；不置 `_point_over` 的话，那些回调会照样判分，
##   于是「重发」和「判分」两条路同时跑 —— 这正是原来卡死的地方。
##   置上之后所有判分回调开头那句 `if _point_over: return` 会把它们全部挡掉。
func _call_let(_pos: Vector3) -> void:
	var b := _ball as PingPongBall
	if b != null:
		b.stop()
	_cancel_opponent_return()
	_cancel_partner_return()
	_point_over = true
	_serve_phase = false
	_msg("发球擦网 —— 重发")
	_timer = let_delay
	set_state(State.POINT)


func _on_landed_floor(pos: Vector3) -> void:
	_audio_call("play_bounce", [0.35])
	if _point_over:
		return
	var bounced_to_other := false
	match _last_hitter:
		Hitter.PLAYER:
			# 玩家的球有没有合法上台，是「对手没接到」和「自己打出台」的分水岭
			bounced_to_other = _bounces_opp >= 1
		Hitter.OPPONENT:
			bounced_to_other = _bounces_player >= 1
		_:
			# 还没人碰过球 = 这是对手的发球
			bounced_to_other = _bounces_player >= 1

	if _last_hitter == Hitter.PLAYER:
		if bounced_to_other:
			_player_score += 1
			_credit_winner()
			_finish("对手没接到！+%d" % _player_score, true)
		else:
			_opponent_score += 1
			if _net_hit:
				_finish("下网… %d" % _opponent_score, false)
			else:
				_finish("出界了… %d" % _opponent_score, false)
	elif _last_hitter == Hitter.OPPONENT:
		if bounced_to_other:
			# 对手的回球上台了，是玩家没接到
			_opponent_score += 1
			_finish("没接到… %d" % _opponent_score, false)
		else:
			_player_score += 1
			_credit_winner()
			if _net_hit:
				_finish("对方下网！+%d" % _player_score, true)
			else:
				_finish("对方回球出台！+%d" % _player_score, true)
	else:
		# 发球方（对手）这一下发丢了 —— 玩家得分。
		# 注意这里的「上台了但玩家没接到」已经被 bounced_to_other 分流到上面去了，
		# 修复前这两种混在一起，导致对方发球发丢反而给对面加分。
		if bounced_to_other:
			_opponent_score += 1
			_finish("没接到… %d" % _opponent_score, false)
		else:
			_player_score += 1
			if _net_hit:
				_finish("对方发球下网！+%d" % _player_score, true)
			else:
				_finish("对方发球出台！+%d" % _player_score, true)


func _finish(msg: String, player_won: bool = false) -> void:
	_point_over = true
	# ★ 这一分结束了 —— 球立刻转「死球」：抽掉水平动力，让它自己坠下去。
	#   不这样做的话球会照旧在台面上再弹两三下才落地，玩家看到「分加了、
	#   球还在跳」，会以为这一分没结束、还能再挥一拍。
	_kill_ball()
	# 这一分已经结束了，球路上还排着的对手回球作废 ——
	# 不收掉的话它会在一秒后凭空把已经落地的球再打回来。
	_cancel_opponent_return()
	# 连击计数：连续得分让对手扣得更凶（见 _opp_rage）。
	# _best_streak 单独记一份「本局最长」，因为 _win_streak 输一分就归零，
	# 结算时再去问它已经晚了 —— 任务「五连击」看的是这条。
	if player_won:
		_win_streak += 1
		_best_streak = maxi(_best_streak, _win_streak)
	else:
		_win_streak = 0
	_msg(msg + _streak_note(player_won))
	if player_won:
		_won_points += 1
		_credit_points()
	else:
		_lost_points += 1
	# ★ 体力在**回合结束**时一次性结算（发球 → 死球），见 _settle_rally_stamina。
	#   赢球补两拍、输球补一拍、扣杀再补一刀 —— 全部在这里收口。
	_settle_rally_stamina(player_won)
	emit_signal("score_changed", _player_score, _opponent_score)
	# ★ 得分 → 真实观众呐喊；失分 → 奶龙大笑（挖苦音）。两者语义互斥，
	#   玩家光靠听就能判断刚才是谁拿的分（2026-10-03 用户指定）。
	#   一条调用搞定「呐喊 + 人群先让路再爆发」，别再单独 swell 一次 ——
	#   两个 tween 同时写人群音量会互相覆盖，音量会卡在中间值。
	if player_won:
		_audio_call("play_score_cheer", [false])
	else:
		_audio_call("play_concede")
	_progress_stats()
	# 先判胜局，再决定要不要进 POINT 状态 —— 一局结束时不排下一球
	if _game_decided():
		_end_match()
		return
	_timer = point_pause
	set_state(State.POINT)


## 让球立刻「死掉」——抽掉水平动力、自然坠地。实现在 PingPongBall.die()。
## 用 has_method 而不是直接调：探针里 _ball 未必是 PingPongBall，
## 别让一条提示性的改动把整条判分路径带崩。
func _kill_ball() -> void:
	var b := _ball as PingPongBall
	if b != null and b.has_method("die"):
		b.die()


## 连击提示。连续得分时把「对手开始压上来」说明白 ——
## 不说的话玩家只会觉得「AI 怎么突然变准了」，会以为是自己手滑。
func _streak_note(player_won: bool) -> String:
	if not player_won or _win_streak < STREAK_NOTE_AT:
		return ""
	return "　连得 %d 分 —— 对手开始压上来了" % _win_streak


## 这一局分出胜负了吗 —— ITTF 2.11.1 / 2.11.3：
##   先到 match_target 分，**并且领先至少 match_win_margin 分**。
## 10:10 之后走的就是后半句：11:10 不算赢（分差 1），12:10 才赢。
## 返回 +1 = 玩家赢、-1 = 对手赢、0 = 还没结束。
func _game_decided() -> int:
	var diff := _player_score - _opponent_score
	if _player_score >= match_target and diff >= match_win_margin:
		return 1
	if _opponent_score >= match_target and -diff >= match_win_margin:
		return -1
	return 0


## 回合结束时的体力结算 —— 玩家和 AI 走同一套公式。
##
## ★ 为什么放在回合结束而不是每一拍（用户要求）：
##   每一拍都扣的话，回合进行中体力条一直在动，`_stamina_reach_scale()` 也跟着动，
##   于是「同一个动作、隔了两拍、判定盒却小了一圈」—— 玩家看不见原因，
##   只会觉得手感在飘。回合结算之后，一整段来回里体力是恒定的，
##   「累」的变化只发生在两分之间，看得见也说得清。
##
## 消耗：基础量 + 每拍追加。所以长回合更累，短回合（发球就失误）省一点。
## 回补：赢 = 两个回合的量，输 = 一个回合的量（用户要的「输球也有补偿」）。
##   ★ 扣杀激励：最后一拍是爆冲/暴拧**并且赢了**，再额外奖励一笔 ——
##     这是「鼓励蓄力扣杀」最直接的那一环：保守对拉只是少亏，搏杀才回本。
func _settle_rally_stamina(player_won: bool) -> void:
	# ── 玩家 ──
	var cost := stamina_cost_per_rally + stamina_cost_per_rally_hit * float(_rally_hits)
	# 这一分是靠蓄力扣杀拿下的 → 回合消耗打折。
	# 扣杀本来就是为了缩短回合，回合短、拍数少，再打个折合情合理；
	# 反过来「保守对拉十几拍」的回合就要全额付账 —— 于是「拖」是有代价的。
	var killed := _rally_last_kind == HitKind.LOOP or _rally_last_kind == HitKind.FLICK
	if player_won and killed:
		cost *= kill_rally_discount
	_stamina = maxf(0.0, _stamina - cost)
	if player_won:
		_stamina += stamina_point_reward
		if killed:
			_stamina += kill_point_bonus
	else:
		_stamina += stamina_loss_reward
	_stamina = clampf(_stamina, 0.0, max_stamina)
	_stamina_hold = 0.0

	# ── AI 对手 ──
	var ocost := opponent_cost_per_rally + opponent_cost_per_rally_hit * float(_opp_rally_hits)
	_opp_stamina = maxf(0.0, _opp_stamina - ocost)
	_opp_stamina += opponent_loss_reward if player_won else opponent_point_reward
	_opp_stamina = clampf(_opp_stamina, 0.0, opponent_max_stamina)


## 每得 1 分就记一笔，并立刻发金币。
## 刻意做成「即时到账」而不是结算时一次性给 —— 中途退出也不会白打。
func _credit_points() -> void:
	var g := get_node_or_null("/root/Game")
	if g == null:
		return
	g.call("bump", "points", 1)
	if coins_per_point > 0:
		# ★ 连拍倍率（方案 C 的第一根支柱）：越长的对拉越值钱。
		#   为什么用**这一回合的击球数**而不是整局累计：倍率要奖励的是
		#   「刚才那一板来回打得久」。整局累计的话，打到最后谁都是 4 倍，
		#   这个数就退化成常数了，玩家也感觉不到自己在为长回合努力。
		#   _rally_hits 在死球之后、下一球开始之前仍保留着本回合的值
		#   （归零发生在 _reset_rally_state），所以此刻读到的一定是刚结束那回合。
		var base := coins_per_point
		var gain := int(round(float(base) * _rally_coin_mult()))
		g.call("add_coins", gain)
		_coins_from_points += base
		_coins_from_rally += maxi(gain - base, 0)


## 这一回合的金币倍率 = 1 + 连拍 / rally_bonus_divisor，封顶 rally_bonus_max。
## 10 → 10 拍 2 倍、20 拍 3 倍、30 拍 4 倍。
func _rally_coin_mult() -> float:
	return clampf(1.0 + float(_rally_hits) / maxf(rally_bonus_divisor, 0.001),
		1.0, rally_bonus_max)


## 我方又打出去一拍 —— 查里程碑、更新个人纪录。
## 玩家击球和队友回球两条路都要调它（那里各自有一句 _rally_hits += 1）。
func _on_rally_hit() -> void:
	# 任务计数：用 == 而不是 >= —— _rally_hits 每拍只 +1，
	# 所以「正好等于 10」在一个回合里只会命中一次，天然去重。
	# 用 >= 的话第 11、12 拍都会再加一次，数字直接爆掉。
	if _rally_hits == 10:
		_rally10_count += 1
	elif _rally_hits == 20:
		_rally20_count += 1
	elif _rally_hits == 30:
		_rally30_count += 1
	# 里程碑优先：它闪的时候不让纪录文案抢位 —— 20 拍破纪录时，
	# 玩家想看到的是「神球！！」，不是「新纪录 20 拍」。
	if not _check_rally_milestone():
		_note_rally_record()


## 连拍里程碑：正好踩到档位就给一次「文字 + 呐喊」的爆发。
## 返回这一拍有没有触发里程碑（调用方据此决定要不要让纪录提示抢位）。
func _check_rally_milestone() -> bool:
	var tier := 0
	for i in range(rally_milestones.size()):
		if _rally_hits == int(rally_milestones[i]):
			tier = i + 1
			break
	if tier <= 0:
		return false
	_rally_toast = _milestone_text(tier)
	_rally_toast_t = rally_toast_time
	# ── 闪屏 ──
	# ★ 档位越低越淡：5 拍只是「打得不错」，不该和 20 拍一样把整块屏幕点亮。
	_rally_flash_peak = rally_flash_alpha * (
		0.45 if tier == 1 else (0.75 if tier == 2 else 1.0))
	_rally_flash_t = rally_flash_time
	if _rally_flash != null:
		_rally_flash.color = _rally_color()
	# tier 决定呐喊的规格：2 = 普通音量的观众呐喊，3 = 更响 + 更大的人群爆发。
	# ★ 两档都用真实呐喊，不用奶龙 —— 奶龙已经改派给「失分」，见 play_concede()。
	_audio_call("play_rally_cheer", [tier])
	return true


## 里程碑文案。按**档位序号**取，所以加档位只改 rally_milestones、不用动这里。
func _milestone_text(tier: int) -> String:
	match tier:
		1: return "好球！"
		2: return "精彩对拉！"
		3: return "神球！！"
	return "连拍 ×%d！" % _rally_hits


## 把这一回合的连拍数报给单例，维护「今日最长 / 历史最长」。
##
## 破历史纪录喊「新纪录」，只破当天纪录就说「今日新高」—— 两者分开是因为
## 「今天手感好」和「生涯最强」对玩家是两种不同的爽点，混成一句话就都没了。
func _note_rally_record() -> void:
	var g := get_node_or_null("/root/Game")
	if g == null or not g.has_method("note_rally"):
		return
	var r: Dictionary = g.call("note_rally", _rally_hits)
	if bool(r.get("all_new", false)):
		_rally_toast = "新纪录！%d 拍" % int(r.get("all", 0))
		_rally_toast_t = maxf(_rally_toast_t, rally_toast_time)
	elif bool(r.get("today_new", false)):
		_rally_toast = "今日新高 %d 拍" % int(r.get("today", 0))
		_rally_toast_t = maxf(_rally_toast_t, rally_toast_time)


## 一局结束：结算金币、写战绩、弹结果面板
func _end_match() -> void:
	if _match_over:
		return
	_match_over = true
	set_state(State.POINT)
	_timer = 99999.0        # 掐掉 POINT → 自动发球那条路
	# ★ 一局打完必须把鼠标放出来。
	#   结算是靠浮层面板（game_overlay）显示「再来一局 / 返回菜单」的，
	#   而第一人称的鼠标是 CAPTURED —— 光标隐藏、点击也不派发给 Control。
	#   原来只有 _pause() 释放鼠标，这条路漏了：玩家打完一局看到结算面板，
	#   却看不见光标、按钮一个都点不动，只能强退游戏。
	_release_mouse()

	var won := _player_score > _opponent_score

	# ★ 赛事场次走另一条路：一局只是 5 局 3 胜里的一小局，
	#   计战绩、发赢局金币、弹「本局结算」都还太早。
	if _tour:
		_end_tour_game(won)
		return

	var g := get_node_or_null("/root/Game")
	var coins := 0
	if g != null:
		_progress_stats()
		g.call("bump", "matches_played", 1)
		# ── 今日 / 每周的「一局级」维度 ──
		# （「分数级」的 loop_today / serve_today 那些在 _progress_stats 里同步）
		# ★ daily_ensure() 必须在最前面：它负责跨天清零，之后记的才属于今天。
		g.call("daily_ensure")
		g.call("daily_note", "played_today", 1)
		if won:
			g.call("daily_note", "wins_today", 1)
			g.call("weekly_note", "wins_week", 1)
			if _opponent_score == 0:
				g.call("daily_note", "zero_today", 1)
		if _ranked:
			g.call("daily_note", "rank_today", 1)
			g.call("weekly_note", "rank_week", 1)
			if won:
				g.call("daily_note", "rankwin_today", 1)
		if won:
			g.call("bump", "matches_won", 1)
			coins += coins_per_win
		else:
			# 输一局的安慰奖（重标定里新增的一项，见 coins_per_loss 的注释）
			coins += coins_per_loss
		# 大胜额外奖励：既赢得漂亮又不能太容易拿满
		if won and _opponent_score <= blowout_max_conceded:
			coins += coins_blowout_bonus
		# 零封（11:0）单独记一笔。大胜奖励的门槛比 0 分松，
		# 拿它当零封判据会把「对手得了 3 分」也算成零封。
		if won and _opponent_score == 0:
			g.call("bump", "zero_games", 1)
		# 双打奖金。入场费已经在菜单里付过了，这里只发赢的那一笔。
		if won and _doubles:
			coins += doubles_prize
		# ── 排位（方案 B）：先记结果，再按**新的连胜**算这一局的加成 ──
		#   顺序不能反：report_rank_match 会把连胜 +1，
		#   而「三连胜那两连胜的第三场就该吃 ×1.2」正是玩家期待的反馈。
		_streak_bonus = 0
		var mult := 1.0
		if _ranked and g.has_method("report_rank_match"):
			_rank_report = g.call("report_rank_match", won)
			mult = float(_rank_report.get("coins_mult", 1.0))
		else:
			# 非排位必须把回执清掉：不然结算面板会拿着上一场的排位数据
			# 画出一块「段位变化」，玩家点开自由对战会莫名其妙。
			_rank_report = {}
		if mult > 1.0:
			# 加成的基数是**这一局全部金币**（含已经即时到账的得分 / 连拍），
			# 所以这里补发的是差额而不是重发一遍。
			var base_all := _coins_from_points + _coins_from_rally + coins
			_streak_bonus = int(round(float(base_all) * (mult - 1.0)))
			coins += _streak_bonus
		if coins > 0:
			g.call("add_coins", coins)
		g.call("save_profile")

	if won:
		_audio_call("play_score_cheer", [true])
		# 双打：把奖金写进提示行 —— 入场费是开局前扣的，玩家得看见「赚回来了」
		_msg("赢下这一局！%d : %d%s%s" % [_player_score, _opponent_score,
			("　奖金 +%d" % doubles_prize) if _doubles else "", _rank_suffix()])
	else:
		_msg("这一局输了　%d : %d%s" % [_player_score, _opponent_score, _rank_suffix()])
	_show_result(won, coins)


## 排位结果的一句话摘要：分数变化 + 晋级 / 降级 / 保底提示。
## 非排位返回空串，所以可以直接拼在既有提示后面。
func _rank_suffix() -> String:
	if not _ranked or _rank_report.is_empty():
		return ""
	var d := int(_rank_report.get("delta", 0))
	var ds := "+%d" % d if d >= 0 else str(d)
	var s := "　排位 %s　%d → %d（%s）" % [
		str(_rank_report.get("name_after", "")),
		int(_rank_report.get("points_before", 0)),
		int(_rank_report.get("points_after", 0)), ds]
	if bool(_rank_report.get("promoted", false)):
		s += "　晋级！"
	elif bool(_rank_report.get("demoted", false)):
		s += "　掉级"
	elif bool(_rank_report.get("shielded", false)):
		s += "　连败保底"
	return s


## ───────────── 赛事场次（BO5）的收尾 ─────────────
## 一局打完：先把这一局记进单例的局分，谁先拿到 3 局就把整场结果交给赛事模型。
##
## 赛事场次**不**发赢局金币、**不**记 matches_won / matches_played ——
## 那些是「自由对战」的战绩。混在一起统计就失真了：打一届联赛最多 7 场 BO5，
## 赢局数会虚高到毫无意义。得分金币照给（_credit_points 每分即时到账，不动）。
func _end_tour_game(won: bool) -> void:
	var g := get_node_or_null("/root/Game")
	var series_over := false
	if g != null and g.has_method("tour_record_game"):
		series_over = bool(g.call("tour_record_game", won))

	if won:
		_audio_call("play_score_cheer", [true])
		_msg("赢下这一局！%d : %d" % [_player_score, _opponent_score])
	else:
		_msg("这一局输了　%d : %d" % [_player_score, _opponent_score])

	var res: Dictionary = {}
	if series_over and g != null and g.has_method("report_tournament_match"):
		res = g.call("report_tournament_match",
			int(g.get("tour_won")), int(g.get("tour_lost")))
	_show_tour_result(won, series_over, res)


func _show_tour_result(won: bool, series_over: bool, res: Dictionary) -> void:
	if _overlay == null:
		return
	var g := get_node_or_null("/root/Game")
	var claimable := 0
	if g != null and g.has_method("claimable_count"):
		claimable = int(g.call("claimable_count"))
	_overlay.call("open_result", {
		"won": won,
		"own": _player_score,
		"opp": _opponent_score,
		"max_rally": _max_rally,
		"loop": _loop_winners,
		"flick": _flick_winners,
		"crouch": _crouch_hits,
		"coins_points": _coins_from_points,
		"coins_rally": _coins_from_rally,
		"coins_win": 0,
		"coins_blowout": 0,
		"coins_total": _coins_from_points + _coins_from_rally,
		"claimable": claimable,
		"tour": {
			"opp": str(_tour_opp.get("name", "?")),
			"stage": str(_tour_opp.get("stage_name", "")),
			"rating": int(_tour_opp.get("rating", 0)),
			"won": int(g.get("tour_won")) if g != null else 0,
			"lost": int(g.get("tour_lost")) if g != null else 0,
			"series_over": series_over,
			"res": res,
		},
	})


func _msg(t: String) -> void:
	emit_signal("message_changed", t)
	if _label:
		_label.text = t


# ───────────── 落点预测圈 ─────────────
func _build_landing_marker() -> void:
	_landing_marker = Node3D.new()
	_landing_marker.name = "LandingMarker"
	add_child(_landing_marker)

	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var rm := TorusMesh.new()
	rm.inner_radius = 0.055
	rm.outer_radius = 0.075
	rm.rings = 28
	rm.ring_segments = 8
	ring.mesh = rm
	ring.rotation_degrees = Vector3(90, 0, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.20, 0.9)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.set_surface_override_material(0, m)
	_landing_marker.add_child(ring)
	_landing_marker.visible = false


## 球落点提示环。
##
## ★ 预报的是「**玩家该去接的那一下**」的落点，不是球的首次触台。
##
## 为什么不能用 simulate_first_contact：合规发球必须先在**发球方自己半台**
## 弹一下（见 _solve_legal_serve / is_legal_serve）。所以对手发球时，
## 球的首次触台在**对面半台** —— 提示环会亮在对手那边，玩家看着那边去站位，
## 球其实是要落到自己这半台的。信息不是不够，是**指错了地方**。
##
## 现在的判据：玩家是最后一拍的出球方 → 盯对方半台的那一跳；
## 否则（对手发球 / 对手回球）→ 盯玩家半台的下一跳。
func _update_landing_marker() -> void:
	if _landing_marker == null:
		return
	var b := _ball as PingPongBall
	if b == null or not b.is_flying() or not show_landing_marker:
		_landing_marker.visible = false
		return
	var want_side := -1.0 if _last_hitter == Hitter.PLAYER else 1.0
	# dt 放粗到 1/60：这只是个提示环，不需要解算器那种精度，
	# 但每次 _physics_process 都要跑，步数减半省一半开销。
	var r: Dictionary = b.simulate_path(b.global_position, b.velocity,
										b.get_spin(), 1.6, 1.0 / 60.0)
	var bounces: Array = r["bounces"]
	var found := false
	var target := Vector3.ZERO
	for bp: Variant in bounces:
		var v := bp as Vector3
		if signf(v.z) == want_side:
			target = v
			found = true
			break
	if not found and not bounces.is_empty():
		# 这一拍要么已经飞过目标侧、要么直接出界：退回最近的一跳当兜底，
		# 总比不显示强（出界球玩家也该看见它飞出去）。
		target = bounces[0] as Vector3
		found = true
	_landing_marker.visible = found
	if found:
		_landing_marker.global_position = Vector3(target.x, table_height + 0.035, target.z)


# ───────────── HUD ─────────────
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "GameHUD"
	add_child(_hud)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16, 16)
	_hud.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_label = Label.new()
	_label.text = "乒乓球"
	_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_label)

	var hint := Label.new()
	hint.text = "左键=反手挥拍　右键=正手推击（向前推，不往下压）　F=挥拍\n" \
		+ "★ 发球：先点左键抛球 → 球下落时再点左键击出（按住空格可蓄力加速）\n" \
		+ "Z=上旋球开关　C=下旋球开关（点按切换 / 再按取消，发球时也吃这个状态）\n" \
		+ "按住空格蓄力 + 左键=反手暴拧 / 右键=正手爆冲（扣杀）\n" \
		+ "★ 正手爆冲（扣杀）只在**远台球**上有效：球要落在自己半台靠底线的位置，\n" \
		+ "　 近网短球抡不起来（反手暴拧不受此限，它本来就是处理短球的）\n" \
		+ "★ **自己发球冒高 = 送对手扣杀** —— 球越高越容易被一板打死，发球务必压低\n" \
		+ "★ 球到眼前却挥空 = 直接判对方得分；球还在远处时挥空不受罚\n" \
		+ "★ 每挥一拍要等动作走完才能再挥（不能连点乱抡）\n" \
		+ "WASD=移动　Shift=冲刺　Ctrl=蹲下（省体力、回球更冲，但够不到近台短球）\n" \
		+ "★ 站到球后面才接得到 —— 站中间不动会被打穿　　V=跳跃　↓=难度　Q=换握　R=探拍\n" \
		+ "←/→=左右转头（鼠标被浏览器拒绝锁定时用这个）\n" \
		+ "Esc=暂停（比赛时鼠标会隐藏，按 Esc 或一局打完就自动显示出来）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(1, 1, 1, 0.78)
	vbox.add_child(hint)

	_build_score_hud()
	_build_stamina_hud()
	_build_rally_hud()

	# 统一给 HUD 里所有 Label 套上中文字体（含刚建好的比分/体力条那组）
	_apply_hud_font(_hud)


## 右上角的比分面板 —— 用户要的「计分 UI 放到右上角显著位置」。
##
## ★ 为什么单独拎出来做大：
##   原来比分挤在左上角那块「状态行 + 操作提示」的面板里，和消息、提示文字
##   混成一坨，一眼扫不到；而且只有孤零零一个 "3 : 2"，**哪个数字是谁全靠猜**
##   —— 用户报的「计分把自己和 AI 的分记错」，一半是判分 bug（已修），
##   另一半就是这个。所以这里：① 挪到右上角（视线扫一眼就到、不挡球路）；
##   ② 数字放到 58pt；③ 每个数字**正上方贴名字**（你 / 对手），
##   ④ 自己 = 青色、对手 = 橙色，领先方的颜色更亮 + 白描边。
func _build_score_hud() -> void:
	var wrap := PanelContainer.new()
	wrap.name = "ScoreHUD"
	wrap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# 用 offset 把面板从右边缘推进来（grow 向左/向下，改窗口大小也不会跑偏）
	wrap.offset_left = -272.0
	wrap.offset_top = 16.0
	wrap.offset_right = -16.0
	wrap.offset_bottom = 0.0
	wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	wrap.grow_vertical = Control.GROW_DIRECTION_END

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.030, 0.040, 0.070, 0.84)
	style.set_corner_radius_all(12)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.82, 0.32, 0.90)
	style.set_content_margin_all(12.0)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	style.shadow_size = 8
	wrap.add_theme_stylebox_override("panel", style)
	_hud.add_child(wrap)
	_score_panel = wrap

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	wrap.add_child(col)

	# ── 名字行：和下面的数字行用**同样的列宽/间距**，保证一一对齐 ──
	var cap := HBoxContainer.new()
	cap.alignment = BoxContainer.ALIGNMENT_CENTER
	cap.add_theme_constant_override("separation", _SCORE_COL_GAP)
	col.add_child(cap)
	cap.add_child(_score_caption("你", 17))
	var colon_cap := _score_caption("", 17)
	colon_cap.custom_minimum_size = Vector2(_SCORE_COLON_W, 0.0)
	cap.add_child(colon_cap)
	cap.add_child(_score_caption("对手", 17))

	# ── 数字行 ──
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", _SCORE_COL_GAP)
	col.add_child(row)

	_player_score_label = Label.new()
	_player_score_label.text = "0"
	_player_score_label.custom_minimum_size = Vector2(_SCORE_COL_W, 0.0)
	_player_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_player_score_label.add_theme_font_size_override("font_size", 58)
	row.add_child(_player_score_label)

	var colon := Label.new()
	colon.text = ":"
	colon.custom_minimum_size = Vector2(_SCORE_COLON_W, 0.0)
	colon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	colon.add_theme_font_size_override("font_size", 44)
	colon.add_theme_color_override("font_color", Color(1.0, 0.82, 0.32))
	row.add_child(colon)

	_opp_score_label = Label.new()
	_opp_score_label.text = "0"
	_opp_score_label.custom_minimum_size = Vector2(_SCORE_COL_W, 0.0)
	_opp_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_opp_score_label.add_theme_font_size_override("font_size", 58)
	row.add_child(_opp_score_label)

	# ── 难度 / 握拍（原来挤在比分同一行里，现在单独一行小字）──
	_score_label = Label.new()
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_label.add_theme_font_size_override("font_size", 14)
	_score_label.add_theme_color_override("font_color", Color(0.80, 0.86, 0.95, 0.90))
	col.add_child(_score_label)

	# 赛事场次才显示：对手是谁 + 本场局分（5 局 3 胜打到 3 局）。
	# 非赛事局直接 visible = false —— 空占位会把下面的字顶下去。
	_tour_label = Label.new()
	_tour_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tour_label.add_theme_font_size_override("font_size", 14)
	_tour_label.add_theme_color_override("font_color", Color(1.0, 0.83, 0.34))
	_tour_label.visible = false
	col.add_child(_tour_label)


## 比分面板三个列宽常量 —— 名字行和数字行共用，保证纵向对齐。
const _SCORE_COL_W := 84.0
const _SCORE_COLON_W := 30.0
const _SCORE_COL_GAP := 4


func _score_caption(t: String, size: int) -> Label:
	var l := Label.new()
	l.text = t
	l.custom_minimum_size = Vector2(_SCORE_COL_W, 0.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.66, 0.73, 0.85))
	return l


func _apply_hud_font(n: Node) -> void:
	for c in n.get_children():
		if c is Label:
			(c as Label).add_theme_font_override("font", HUD_FONT)
		_apply_hud_font(c)


## 底部中央的体力条 + 蓄力条
func _build_stamina_hud() -> void:
	var wrap := VBoxContainer.new()
	wrap.name = "StaminaHUD"
	wrap.anchor_left = 0.5
	wrap.anchor_right = 0.5
	wrap.anchor_top = 1.0
	wrap.anchor_bottom = 1.0
	wrap.offset_left = -210.0
	wrap.offset_right = 210.0
	wrap.offset_top = -116.0
	wrap.offset_bottom = -24.0
	wrap.alignment = BoxContainer.ALIGNMENT_END
	wrap.add_theme_constant_override("separation", 4)
	_hud.add_child(wrap)

	_power_label = Label.new()
	_power_label.text = ""
	_power_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_power_label.add_theme_font_size_override("font_size", 15)
	_power_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45))
	# 固定高度：不然文字在「蓄力中…」和空串之间来回切换时，下面的条会上下跳
	_power_label.custom_minimum_size = Vector2(0.0, 20.0)
	wrap.add_child(_power_label)

	var stam := ProgressBar.new()
	stam.custom_minimum_size = Vector2(420.0, 19.0)
	stam.show_percentage = false
	stam.max_value = max_stamina
	stam.value = max_stamina
	wrap.add_child(stam)
	_stamina_bar = stam
	_stamina_fill = _style_bar(stam, Color(0.06, 0.07, 0.10, 0.72),
							   Color(0.32, 0.84, 0.46))

	var opp_lbl := Label.new()
	opp_lbl.text = "对手体力"
	opp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	opp_lbl.add_theme_font_size_override("font_size", 12)
	opp_lbl.add_theme_color_override("font_color", Color(0.72, 0.78, 0.90))
	opp_lbl.custom_minimum_size = Vector2(0.0, 16.0)
	wrap.add_child(opp_lbl)

	# ★ AI 对手的体力条 —— 用户要「AI 也有体力限制」，但**看不见的限制等于没有**：
	#   玩家只有看见他在掉血，才会意识到「拖长回合」是条战术。
	#   刻意做得比自己的那条细、颜色偏冷，避免和玩家体力条抢注意力。
	var ostam := ProgressBar.new()
	ostam.custom_minimum_size = Vector2(300.0, 7.0)
	ostam.show_percentage = false
	ostam.max_value = opponent_max_stamina
	ostam.value = opponent_max_stamina
	wrap.add_child(ostam)
	_opp_stamina_bar = ostam
	_opp_stamina_fill = _style_bar(ostam, Color(0.06, 0.07, 0.10, 0.55),
								   Color(0.38, 0.62, 0.90))

	var chg := ProgressBar.new()
	chg.custom_minimum_size = Vector2(420.0, 8.0)
	chg.show_percentage = false
	chg.max_value = 1.0
	chg.value = 0.0
	wrap.add_child(chg)
	_charge_bar = chg
	_charge_fill = _style_bar(chg, Color(0.06, 0.07, 0.10, 0.55),
							  Color(1.0, 0.78, 0.22))


func _style_bar(bar: ProgressBar, bg: Color, fill: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(4)
	sb.border_color = Color(1, 1, 1, 0.22)
	sb.set_border_width_all(1)
	bar.add_theme_stylebox_override("background", sb)

	var sf := StyleBoxFlat.new()
	sf.bg_color = fill
	sf.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", sf)
	return sf


## 屏幕中上方的连拍计数器（方案 C 的第二根支柱）。
##
## ★ 位置为什么是中上方：左上角那一块已经有「状态行 + 操作提示 + 消息」三行字，
##   连拍数塞进去会被淹掉；中上方正好落在球台远景上方的空白处，不挡球路 ——
##   而且「抬头就能看见数字在涨」这件事本身就是爽感的一部分。
## ★ 为什么从第 rally_hud_min 拍才显示：每球都闪一下的话，玩家会把这一块
##   当成常驻噪音过滤掉，真正打出长对拉时反而注意不到。
func _build_rally_hud() -> void:
	var wrap := VBoxContainer.new()
	wrap.name = "RallyHUD"
	wrap.anchor_left = 0.5
	wrap.anchor_right = 0.5
	wrap.offset_left = -420.0
	wrap.offset_right = 420.0
	wrap.offset_top = 56.0
	wrap.offset_bottom = 56.0
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_theme_constant_override("separation", 0)
	# 纯显示层，绝不接受鼠标事件 —— HUD 挡到点击会让「点一下挥拍」失灵
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(wrap)
	_rally_hud_root = wrap

	# ★ 盒子从 ±240 加宽到 ±420：20 拍那一档字号是 110，"×20" 三个字符
	#   在 480 px 宽里会被裁掉一点（原来最大才 62，所以没暴露）。

	# ── 里程碑闪屏 ──
	# ★ 加完立刻 move_child 到最底层：后加的控件画在它上面，
	#   所以闪光不会把连拍数字本身盖掉。
	var flash := ColorRect.new()
	flash.name = "RallyFlash"
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash.color = Color(1.0, 1.0, 1.0)
	flash.modulate = Color(1.0, 1.0, 1.0, 0.0)
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.visible = false
	_hud.add_child(flash)
	_hud.move_child(flash, 0)
	_rally_flash = flash

	_rally_label = Label.new()
	_rally_label.text = ""
	_rally_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rally_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_rally_label.add_theme_font_size_override("font_size", rally_hud_base_size)
	_rally_label.custom_minimum_size = Vector2(0.0, 124.0)
	_rally_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(_rally_label)

	_rally_sub_label = Label.new()
	_rally_sub_label.text = ""
	_rally_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rally_sub_label.add_theme_font_size_override("font_size", 16)
	_rally_sub_label.custom_minimum_size = Vector2(0.0, 36.0)
	_rally_sub_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_child(_rally_sub_label)

	wrap.visible = false


## 连拍 HUD 每帧刷新。只在与上一帧不同时才写 Label ——
## add_theme_*_override 每次都触发一次主题重算 + 重绘，和上面比分那块同理。
func _update_rally_hud(delta: float) -> void:
	if _rally_hud_root == null or _rally_label == null:
		return

	# ── 闪屏衰减 ──
	# ★ 放在 visible 判断**之前**：回合结束 HUD 会隐藏，
	#   要是把衰减放在隐藏之后，最后一次闪光会永远卡在屏幕上。
	if _rally_flash != null:
		if _rally_flash_t > 0.0:
			_rally_flash_t = maxf(_rally_flash_t - delta, 0.0)
			var k := _rally_flash_t / maxf(rally_flash_time, 0.001)
			_rally_flash.visible = true
			# ★ k 的平方而不是线性：亮起来快、退得慢，像「被击中那一下」
			_rally_flash.modulate.a = _rally_flash_peak * k * k
		elif _rally_flash.visible:
			_rally_flash.visible = false
			_rally_flash.modulate.a = 0.0

	# ── 弹跳衰减 ──
	if _rally_pop > 0.0:
		_rally_pop = maxf(_rally_pop - delta * rally_pop_decay, 0.0)

	# 死球之后不显示：这一回合已经结束、连拍不再增长，
	# 留在屏幕上会让人以为「还在对拉」。
	var show := _rally_hits >= rally_hud_min and not _point_over and not _match_over
	_rally_hud_root.visible = show
	if not show:
		_rally_shown = 0
		return

	# ★ 数字变大了就来一次弹跳。只在**增加**时触发，且要求 _rally_shown > 0
	#   —— 换球归零后涨回来的第一拍不算「又打了一拍」，不该弹。
	if _rally_hits > _rally_shown and _rally_shown > 0:
		_rally_pop = 1.0
	_rally_shown = _rally_hits

	var txt := "×%d" % _rally_hits
	if txt != _rally_label.text:
		_rally_label.text = txt
		_rally_label.add_theme_font_size_override("font_size", _rally_font_size())
		_rally_label.add_theme_color_override("font_color", _rally_color())
		_rally_label.add_theme_constant_override("outline_size", _rally_outline())
		_rally_label.add_theme_color_override("font_outline_color",
			Color(0.04, 0.05, 0.09, 0.92))

	# 弹跳。★ pivot_offset 必须取控件中心，否则会从左上角放大、数字往右下跑。
	if _rally_label.size.x > 1.0:
		_rally_label.pivot_offset = _rally_label.size * 0.5
	var s := 1.0 + rally_pop_amount * _rally_pop
	_rally_label.scale = Vector2(s, s)

	# 副行：里程碑文案优先（限时），平时显示当前金币倍率 ——
	# 倍率一直看得见，玩家才知道「把这一回合拖长」是有回报的。
	var sub: String
	var sub_size := 16
	var sub_col := Color(0.78, 0.84, 0.95)
	if _rally_toast_t > 0.0:
		sub = _rally_toast
		sub_size = 30
		sub_col = _rally_color()
	else:
		sub = "金币 ×%.1f" % _rally_coin_mult()
	if sub != _rally_sub_label.text:
		_rally_sub_label.text = sub
		_rally_sub_label.add_theme_font_size_override("font_size", sub_size)
		_rally_sub_label.add_theme_color_override("font_color", sub_col)
		_rally_sub_label.add_theme_constant_override("outline_size", 6)
		_rally_sub_label.add_theme_color_override("font_outline_color",
			Color(0.04, 0.05, 0.09, 0.90))


## 第 i 档里程碑的连拍数。越界返回一个不可能达到的大数 ——
## 这样 rally_milestones 被调短也不会让颜色 / 字号判断炸掉。
func _milestone_at(i: int) -> int:
	if i < 0 or i >= rally_milestones.size():
		return 1 << 30
	return int(rally_milestones[i])


## 连拍数的颜色：第 1 档黄 / 第 2 档橙 / 第 3 档红（方案 C 定的档位）。
func _rally_color() -> Color:
	if _rally_hits >= _milestone_at(2):
		return Color(1.00, 0.32, 0.26)
	if _rally_hits >= _milestone_at(1):
		return Color(1.00, 0.58, 0.18)
	if _rally_hits >= _milestone_at(0):
		return Color(1.00, 0.86, 0.32)
	return Color(0.86, 0.90, 0.96)


## 连拍数的字号：随档位放大，让「越来越夸张」一眼可见。
func _rally_font_size() -> int:
	return rally_hud_base_size + rally_hud_tier_step * _rally_tier()


## 描边也跟着档位加粗 —— 字号到 110 还用 7 px 描边，在亮场馆里会糊边。
func _rally_outline() -> int:
	return 8 + 4 * _rally_tier()


## 当前连拍处在第几档（0 = 还没到第一档）。
func _rally_tier() -> int:
	if _rally_hits >= _milestone_at(2):
		return 3
	if _rally_hits >= _milestone_at(1):
		return 2
	if _rally_hits >= _milestone_at(0):
		return 1
	return 0


func _update_hud(delta: float) -> void:
	_update_rally_hud(delta)
	# ── 右上角大比分 ──
	# ★ 只在与上一帧不同时才重刷：add_theme_*_override 每次都会触发一次
	#   主题重算 + 重绘，而 _update_hud 是每帧调的 —— 不缓存的话
	#   光这一处每帧就白刷 8 次，纯浪费。
	if _player_score_label != null and _opp_score_label != null:
		var sc := Vector2i(_player_score, _opponent_score)
		if sc != _hud_score_cache:
			_hud_score_cache = sc
			_player_score_label.text = str(_player_score)
			_opp_score_label.text = str(_opponent_score)
			# 领先方亮 + 白描边，落后方压暗 —— 余光一扫就知道现在谁在前面
			var lead := signi(_player_score - _opponent_score)
			_player_score_label.add_theme_color_override("font_color",
				Color(0.44, 0.93, 1.00) if lead >= 0 else Color(0.26, 0.55, 0.65))
			_opp_score_label.add_theme_color_override("font_color",
				Color(1.00, 0.58, 0.28) if lead <= 0 else Color(0.60, 0.34, 0.19))
			_player_score_label.add_theme_constant_override("outline_size",
				7 if lead > 0 else 0)
			_opp_score_label.add_theme_constant_override("outline_size",
				7 if lead < 0 else 0)
			var oc := Color(1.0, 1.0, 1.0, 0.90)
			_player_score_label.add_theme_color_override("font_outline_color", oc)
			_opp_score_label.add_theme_color_override("font_outline_color", oc)

	if _score_label != null:
		# ★ 把当前旋转状态挂在这一行常驻显示。原来是按住式，松手就没了、
		#   玩家根本不知道这一拍带不带旋；改成点按开关之后状态是长期挂着的，
		#   那就必须让它在屏幕上一直看得见，否则「开着而不自知」比原来更糟。
		var spin_txt := ""
		if _spin_mode > 0:
			spin_txt = " · ★上旋"
		elif _spin_mode < 0:
			spin_txt = " · ★下旋"
		else:
			spin_txt = " · 无旋"
		_score_label.text = "%s · %s%s" % [difficulty_name(), grip_name(), spin_txt]

	if _tour_label != null:
		_tour_label.visible = _tour
		if _tour:
			var g := get_node_or_null("/root/Game")
			var w := 0
			var l := 0
			if g != null:
				w = int(g.get("tour_won"))
				l = int(g.get("tour_lost"))
			_tour_label.text = "联赛 %s vs %s　本场 %d : %d（5 局 3 胜）" % [
				str(_tour_opp.get("stage_name", "")), str(_tour_opp.get("name", "?")), w, l
			]

	if _stamina_bar == null:
		return
	var ratio := clampf(_stamina / maxf(max_stamina, 0.01), 0.0, 1.0)
	_stamina_bar.value = _stamina
	# 绿 → 黄 → 红：越高越健康
	if ratio > 0.5:
		_stamina_fill.bg_color = Color(0.95, 0.72, 0.24).lerp(Color(0.32, 0.84, 0.46),
															  (ratio - 0.5) * 2.0)
	else:
		_stamina_fill.bg_color = Color(0.90, 0.26, 0.22).lerp(Color(0.95, 0.72, 0.24),
															  ratio * 2.0)
	emit_signal("stamina_changed", _stamina, max_stamina)

	if _opp_stamina_bar != null and _opp_stamina_fill != null:
		_opp_stamina_bar.value = _opp_stamina
		var oratio := clampf(_opp_stamina / maxf(opponent_max_stamina, 0.01), 0.0, 1.0)
		# 蓝 → 青：他越累，颜色越亮（提示你「他快撑不住了，继续磨」）
		_opp_stamina_fill.bg_color = Color(0.90, 0.30, 0.26).lerp(
			Color(0.38, 0.62, 0.90), oratio)

	if _charge_bar != null:
		_charge_bar.value = _charge_t
		var active := _charging or _charge_t > 0.0
		_charge_bar.visible = active
		if _charge_fill != null:
			_charge_fill.bg_color = Color(1.0, 0.80, 0.25).lerp(
				Color(1.0, 0.42, 0.12), _charge_t)

	if _power_label != null:
		if _charging:
			if _charge_t >= 0.999:
				_power_label.text = "蓄力满 —— 按住鼠标：左=暴拧　右=爆冲"
			else:
				_power_label.text = "蓄力中… %d%%" % int(_charge_t * 100.0)
		elif _stamina < min_stamina_to_charge:
			_power_label.text = "体力不足"
		else:
			_power_label.text = ""


func grip_name() -> String:
	return "正手" if _grip_mode == 0 else "反手"


func get_score() -> Vector2i:
	return Vector2i(_player_score, _opponent_score)


# ───────────── 对外接口（自动化测试用）─────────────
func get_state() -> int:
	return _state


func get_state_name() -> String:
	return State.keys()[_state]


## 够球范围的「等效半径」，只给 UI / 探针看的概览值。
## 真正的判定是三轴椭球，见 _reach_box()。
func get_hit_radius() -> float:
	return _reach_box().x


## 当前够球三轴半轴（debug / 探针用）
func get_reach_box() -> Vector3:
	return _reach_box()


func get_flight_time() -> float:
	return _flight_time()


func get_paddle_point() -> Vector3:
	return _paddle_point()


func get_stamina() -> float:
	return _stamina


func get_charge() -> float:
	return _charge_t


func is_charging() -> bool:
	return _charging


func get_last_hit_kind() -> int:
	return _hit_kind


## 供离屏自测直接调：模拟一次带蓄力的挥拍
func debug_swing(mode: int, charge: float) -> void:
	_charge_t = clampf(charge, 0.0, 1.0)
	_charging = charge > 0.0
	_swing_with_grip(mode)


# ───────────── 暂停 / 结算 / 场景切换 ─────────────
func _build_pause() -> void:
	# 脚本实例化：game_overlay.gd 的基类是 CanvasLayer，.new() 直接得到
	# 一个挂了该脚本的 CanvasLayer。它自己在 _ready 里把自己设成 ALWAYS。
	_overlay = preload("res://game_overlay.gd").new()
	_overlay.name = "Overlay"
	add_child(_overlay)
	# 用字符串连信号：_overlay 的静态类型是 CanvasLayer，直接写
	# _overlay.resume_pressed 会被静态检查判成「属性不存在」。
	_overlay.connect("resume_pressed", Callable(self, "_on_resume_pressed"))
	_overlay.connect("restart_pressed", Callable(self, "_on_restart_pressed"))
	_overlay.connect("menu_pressed", Callable(self, "_back_to_menu"))

	# 音效节点设成 ALWAYS：AudioStreamPlayer 会响应 NOTIFICATION_PAUSED
	# 把自己静音，于是暂停时现场呐喊会整段消失、试听按钮也哑掉。
	# 体育馆不会因为你按了暂停就安静下来。
	if _audio != null:
		(_audio as Node).process_mode = Node.PROCESS_MODE_ALWAYS


func _pause() -> void:
	if _pause_open or _match_over:
		return
	_pause_open = true
	_release_mouse()
	get_tree().paused = true
	_overlay.call("open_pause")


func _on_resume_pressed() -> void:
	_pause_open = false
	_overlay.call("close")
	get_tree().paused = false
	_capture_mouse()


func _on_restart_pressed() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# reload 会把整个场景重建：比分、体力、统计全部归零，
	# 这正是「再来一局」该有的语义（不想自己写一套 reset 是因为
	# 场景里还有球、观众 MultiMesh、音频循环都要复位）。
	get_tree().reload_current_scene()


func _back_to_menu() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://main_menu.tscn")


## 关窗口前把进度落盘。得分是即时发金币的，但金币只在结算和读档时才写文件，
## 所以中途直接关窗口会丢掉这一局赚的东西。
## 刻意不用 NOTIFICATION_PREDELETE —— 那是在对象销毁流程里，再去碰
## autoload 容易在退出阶段冒出难查的报错。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		var g := get_node_or_null("/root/Game")
		if g != null:
			g.call("save_profile")


func _capture_mouse() -> void:
	# 走 camera_controller 而不是直接设 Input.mouse_mode：那边还要把
	# _user_released 清掉，否则窗口重新获得焦点时不会自动锁回来。
	# 先退出 UI 模式 —— 否则 capture_mouse() 会被它那道保护直接拒绝。
	var cc := get_node_or_null("Player/Head")
	if cc != null and cc.has_method("capture_mouse"):
		if cc.has_method("set_ui_mode"):
			cc.call("set_ui_mode", false)
		cc.call("capture_mouse")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	# 进 UI 模式（set_ui_mode 内部会顺手释放鼠标），
	# 这样之后任何 capture_mouse() 都抢不走光标。
	var cc := get_node_or_null("Player/Head")
	if cc != null and cc.has_method("release_mouse"):
		if cc.has_method("set_ui_mode"):
			cc.call("set_ui_mode", true)
		else:
			cc.call("release_mouse")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## 鼠标可见性守卫：一局打完（结算面板）之后，鼠标必须是「UI 模式」。
##
## 真正的拦截在 camera_controller.capture_mouse() 里（ui_mode 为 true 就
## 拒绝锁定），这里只负责「把状态纠正过来」——因为 _end_match() 之外还有
## 重载场景、外部脚本等路径可能把 ui_mode 落回 false。
##
## 判据刻意用 cc 的 ui_mode 这个**纯逻辑布尔量**，不读 Input.mouse_mode：
## 后者在无头环境里恒为 VISIBLE，会让守卫误判成「已经放出来了」而空过。
##
## 注意 `_pause_open` 期间整棵树是 paused 的，本函数不会被调用；
## 那条路靠 _pause() 里那次显式释放。
func _guard_mouse_mode() -> void:
	if not _match_over:
		return
	var cc := get_node_or_null("Player/Head")
	if cc == null:
		return
	if bool(cc.get("ui_mode")):
		return
	_release_mouse()


func _show_result(won: bool, coins_win: int) -> void:
	if _overlay == null:
		return
	# 赢局奖励已含大胜加成，这里反推出两块分别是多少，好在结算面板上分列
	var blowout := 0
	if won and _opponent_score <= blowout_max_conceded:
		blowout = coins_blowout_bonus
	var claimable := 0
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_method("claimable_count"):
		claimable = int(g.call("claimable_count"))
	# 连胜加成也从 coins_win 里剥出来单列 —— 它是这一局唯一「靠历史连胜挣的钱」，
	# 混进「赢局奖励」里玩家就看不见连胜在起作用了。
	var win_only := maxi(coins_win - blowout - _streak_bonus, 0)

	_overlay.call("open_result", {
		"won": won,
		"own": _player_score,
		"opp": _opponent_score,
		"max_rally": _max_rally,
		"loop": _loop_winners,
		"flick": _flick_winners,
		"crouch": _crouch_hits,
		"coins_points": _coins_from_points,
		"coins_rally": _coins_from_rally,
		"coins_win": win_only,
		"coins_blowout": blowout,
		"coins_streak": _streak_bonus,
		"coins_total": _coins_from_points + _coins_from_rally + coins_win,
		"claimable": claimable,
		"rank": _rank_report,
	})


# ───────────── 对外接口（自动化测试用，续）─────────────
func get_match_target() -> int:
	return match_target


func is_match_over() -> bool:
	return _match_over


func is_paused_ui_open() -> bool:
	return _pause_open


func debug_end_match() -> void:
	_player_score = match_target
	_opponent_score = 2
	_end_match()


## 同上，但让玩家输。赛事场次要跑「先输一局再连赢三局」这类剧本，
## 光能赢是验不出局分与淘汰分支的。
func debug_end_match_loss() -> void:
	_player_score = 2
	_opponent_score = match_target
	_end_match()


# ───────────── 对外接口（自动化测试用，续 2）─────────────
## 这一球该谁发（Hitter.PLAYER / Hitter.OPPONENT）
func get_serve_side() -> int:
	return _server


func is_waiting_player_serve() -> bool:
	return waiting_player_serve()


## 拍面法线（世界），给探针/自测看「拍面朝哪」
func get_paddle_normal() -> Vector3:
	return _paddle_normal()


## 拍面没喂正 → 出台的概率。传一个代表性出球方向（朝对方半台略向上）
func get_face_out_chance() -> float:
	return _face_out_chance(Vector3(0.0, 0.45, -3.0))


func get_loop_kill() -> bool:
	return _loop_kill


func get_loop_kill_chance() -> float:
	var sl := clampf(_stamina / maxf(max_stamina, 1.0), 0.0, 1.0)
	return loop_kill_base + loop_kill_stamina_bonus * sl


## 供离屏自测直接调：替玩家发一个球
func debug_player_serve() -> void:
	_player_serve()


## 供离屏自测直接调：把球按住不让它飞（复现「球不动了」的卡死场景）
func debug_freeze_ball() -> void:
	var b := _ball as PingPongBall
	if b != null:
		b.stop()
