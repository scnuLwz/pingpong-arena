extends Node3D
## 第一人称「手持乒乓球拍」视觉控制器 (Godot 4.x, GDScript)
##
## 挂载位置：Player/Head/Camera3D/PaddleRig
##
## 结构（原点 = 手腕，挥拍绕手腕转 —— 与 racket_viewmodel 同一套约定）：
##   PaddleRig (本节点)
##   └── Paddle (Node3D)              ← 待机 / 挥拍姿态写在这一层
##       └── Aim (Node3D)             ← 固定姿态：把模型长轴摆成「前上方 55°」
##           ├── PaddleModel          ← models/paddle_lite.glb（混元3D 真实球拍）
##           │   └── Head (Marker3D)  ← 拍面中心锚点，击球判定用；挂在模型下自动继承变换
##           └── Hand                 ← fp_hand.gd 生成的手
##
## 朝向：局部 -Z = 拍头方向（远离手），+Z = 朝肘，+Y = 拇指侧。
##       模型自带朝向：长轴沿 -Z、拍面法线沿 +Y、拍面宽沿 X（由顶点切片实测）。
##
## 尺寸：拍面直径 0.15 m，全长约 0.254 m，与真实球拍比例一致。

const HAND := preload("res://fp_hand.gd")

## 握拍模式：正手（拍头在画面右下，向右前挥）/ 反手（拍头在画面中下偏左，向左前挥）
enum GripMode { FOREHAND, BACKHAND }
## 反手相对正手的额外偏航（度）。单手横拍靠手腕外翻切换，不是大幅转身——
## 只小幅偏航让拍面略朝中线，主要靠 roll 翻腕。
const _GRIP_YAW: float = 20.0
## 反手额外的翻腕（绕拍柄轴 roll，度），让手腕姿态像外翻握拍（横拍反手手腕外翻明显）
const _GRIP_ROLL: float = 35.0

## 真实球拍模型。混元3D 原始文件 82MB（150 万三角面 + 3 张 4096² 贴图），
## 已减面到 6 万面、贴图降到 512²，压成 1.9MB —— 否则 pck 会多出 80MB。
const PADDLE_MODEL := preload("res://models/paddle_lite.glb")
## 拍子材质：不用模型自带的 AI 噪声贴图，改按几何分区手写着色（详见 .gdshader 里的说明）
const PADDLE_SHADER := preload("res://paddle_rubber.gdshader")
## 模型拍面直径 0.7043（模型单位）→ 真实 0.150 m
const MODEL_SCALE: float = 0.15 / 0.7043
## 模型空间里的拍面中心（按 Z 轴切片实测：拍面最宽处 z ≈ -0.77，直径 0.704）
const BLADE_CENTER_MODEL := Vector3(0.0, 0.0, -0.770)
## ── 反手拍头指向：前上方 42°、向左偏 66°。
## 关键约束是让「拍柄轴」不要指向相机 —— 手指是在垂直于柄轴的平面里绕柄的，
## 柄轴越接近视线方向，绕柄的弧度就越被压扁成一个点，四指就只剩四个"疙瘩"。
## |l·相机Z| 从 0.564 降到 0.302，绕柄的可见弧度从 sin(55°)=0.82 压到 0.95，
## 握持感看得出来了；同时拍面仍然基本正对玩家（投影法线 n ≈ +Z）。
const AIM_PITCH_DEG: float = 42.0
const AIM_YAW_DEG: float = -66.0
## ── 正手拍头指向：近似水平、指向右侧（用户要的「球拍向右横置」）。
## 拍头方向 l = (sin(yaw)cos(pitch), sin(pitch), -cos(yaw)cos(pitch))：
##   yaw 78° / pitch 8° → l ≈ (0.969, 0.139, -0.206)
## 即拍头朝右手边、略高、略前；(0,0,1) 在 ⊥l 上的投影 ≈ 拍面法线 n ≈ (0.20, 0.03, 0.98)，
## 拍面基本正对玩家 —— 看过去就是「球拍横在右侧、拍面朝着自己」。
##
## 为什么不像反手那样往左偏：正手本来就是右手持拍、拍在身体右前方，
## 拍头再往左指会横穿视野正中，把来球挡住。
const FH_AIM_PITCH_DEG: float = 8.0
const FH_AIM_YAW_DEG: float = 78.0
## 正手的手腕位置：整体往画面左侧收一点（0.21 → 0.17），
## 这样「柄在画面中偏右、拍头伸向右侧」横铺在右半边，
## 而不是整块拍子贴着屏幕右缘被切掉一半。
## 待机拍面相对相机的局部坐标。
## ★ 之前这俩 y 被改到 -0.50，使拍子相对相机的俯角达 ~52°，超出垂直 FOV 半角（~35°），
##   拍子被投影到屏幕底边之外 → 玩家看到「拍子消失」。（_tmp_probe.gd 量过相机局部几何
##   确认的，不是猜。）现在 y=-0.34、z 从 -0.34 拉远到 -0.50：
##   俯角约 -31°（在 FOV 内，拍子可见），拍面世界 y 落在台面上方约 0.27 m，
##   不按 R 拍子就悬在台面上方、走路能迎球，不再「够不到台 / 有空气墙感」。
##   按住 R 全探时前推 0.35 + 下压 0.05，拍面贴到台面上方约 0.18 m、不过网（见探针实测）。
const FH_REST_POS := Vector3(0.10, -0.34, -0.50)
const BH_REST_POS := Vector3(0.210, -0.34, -0.50)
## 手绕手柄轴的额外翻转（度）。
## 用离屏 dump + Python 光栅化把 0/90/180/270 四个角度一起渲染对比过：
##   0°   —— 掌挡在手柄与相机之间，四指只剩远端几个「疙瘩」，整只手读成一根原木；
##   90°  —— 四指真正「绕」在手柄上，四条指节横跨柄面，握持关系一眼可辨；
##   180° —— 也明显好于 0°，但掌跑到柄的上方，姿态偏怪；
##   270° —— 掌把柄整个盖住，最差。
## 所以取 90°。（注意：这个结论是对**当前**的指粗/前臂长度成立的，
## 早期指头更细、前臂更长时 90° 会被掌盖住 —— 改手部尺寸时这个值要重扫。）
const HAND_ROLL_DEG: float = 90.0

## 球台半宽 / 半长（m），用来判断「拍子是否在台面上方」（见 _update_crouch_lift）。
## ★ 跨脚本硬约定：与 camera_controller.table_half_width / table_half_length、
##   pingpong_ball 的同名字段同值，改要一起改。
const TABLE_HALF_WIDTH := 0.7625
const TABLE_HALF_LENGTH := 1.37

@export_group("挥拍（反手：向左前抡）")
## 挥拍最大角度（度）。绕手腕转，55° 时拍头甩到画面下方之外又收回，力度感够。
@export var swing_degrees: float = 55.0
@export var swing_yaw_degrees: float = 14.0
@export var swing_duration: float = 0.26
@export var swing_reach: float = 0.08

@export_group("推击（正手：向右横置、往前推）")
## 正手不再是「抡」，而是**向前推**：以前推位移为主，手腕几乎不转。
## 拍子横着往对手方向送出去，读起来就是「推挡/推球」而不是「劈」。
##
## 三个量的配比是刻意做的：
##   reach 大（0.14 m）—— 前推是主要动作，球拍整块沿视线往前送；
##   pitch 小（7°）—— 只是收拍时的一点点压腕，不破坏「横置」的读感；
##   yaw 小（4°）—— 手臂自然外旋那一点点。
## 注意前推在屏幕上还附带「变小」：距离从 0.34 m 涨到 0.48 m，
## 拍面屏幕尺寸缩到约 7 成，正好做出「伸出去」的纵深感。
## reach 一开始给的是 0.14，实拍发现**几乎看不出来**：距离只从 0.34 m 变到 0.48 m，
## 屏幕上只小了 30%，而且截图窗口期内的 f7 通常只有 0.5，前推量还要再打对折。
## 改成 0.19 之后前推量在峰值是真人的量级（Aim 局部 -Z 就是视线前方，
## 拍子整块往前送 19 cm，距离涨到 0.53 m，拍面缩到 6 成），一眼能看出是「推」。
@export var fh_push_reach: float = 0.19
## ★ 探拍：按住键时拍子最多能往球台上方再送出去多少米。
##
## 用户要「可以将拍移动至球台上接近台球」。原来拍面永远锁在相机前 0.34 m 处，
## 球飞到台面上空时拍子根本够不着，只能靠把判定盒放大来「代偿」——
## 那就是「站中间吃所有球」的来源。现在判定盒收紧（hit_reach_* 全部调小），
## 缺口用这个前推量补：按住 Shift 把拍子送到台面上方，拍面真的靠近球，
## 「打得到」从数值宽容变成**操作**。
## 0.45 m 是够到近网球的量：球台半长 1.37 m，玩家站 z≈1.6 时，
## 0.34 + 0.45 = 0.79 m 的前伸正好覆盖台面中段。
## ★ 之前把前伸一路加到 1.35 m，是因为身体被钳在台边外 8 cm（area_z_min=1.45）、
##   不走到台前就够不到短球。现在 area_z_min 收到 0.685（最前到台面中间）、
##   **不按 R 拍面静止位就已经在台面上方**，不需要那么长的前推了。
##   1.35 m 在「站近台」时会把拍面甩到网对面(z≈-0.87)——明显穿网、不好看。
##   收回到 0.35 m：站在近台(z≈1.0)时（相机俯视约 21°，前推自带 -Z 外的少量下沉）
##   拍面落到 z≈0.30（台面中段偏网、贴网短球落点区 0.22~0.47 之内），**不过网**；
##   拍面 y 仅比待机再沉约 0.13 m，停在台面上方约 0.04 m，几乎贴台、**不穿模**。
@export var table_reach_max: float = 0.35
## 探拍时球拍额外往下压的量（米，按 _reach_extend 0~1 插值）。
##
## ★ 单纯往前推只能把拍面送到「同一个高度、更靠前」的位置，
##   而近台短球往往贴着台面飞（y≈0.76~0.9），拍面停在眼高（≈1.3）差半个拍面够不到。
##   这一项是显式下压：前伸的瞬间拍面一起往台面沉，迎上低球。
##   现在待机拍面已经沉到台面上方（见 FH_REST_POS/BH_REST_POS 的 y），
##   探拍只要「再往前送一点 + 轻微下压」就够了，不需要大下压：
##   0.05 m 让拍面贴到台面上方约 0.02 m 去迎最低短球，配合前推自带的约 0.13 m 下沉，
##   稳定态拍面中心停在台面之上约 0.01 m（不穿台面 0.760）。前推 0.35 配俯视相机
##   既把拍面送向近网短球落点区，又只带最少下沉，整体「上台接近台球」且不穿模、不过网。
@export var table_reach_dip: float = 0.05
## 正手推击时手腕的俯仰（度）。**实测正 = 拍面往上翻**（不是压腕，代码里的
## `rot.x -= amt` 推不出方向，得看挂点朝向，所以这个是量出来的）。
##
## ★ 用户报「正手球拍往前推而不是向下压」。
##   实测这个参数**不是**主因：从 +9 改到 −2，刀面世界位置只挪 ±4 mm、
##   法线俯角只差 2.6°（_tmp_fh.gd 逐帧量的）。
##   真正的「往下压」来自照抄反手的那条拍形曲线，已由 fh_face_*_scale 处理。
##   这里取 +3：让推击整段法线俯角落在 +7° ~ +18°，拍面始终端平偏上，
##   既不朝下按，也不像「铲」。
@export var fh_push_pitch_deg: float = 3.0
@export var fh_push_yaw_deg: float = 4.0
## 正手蓄力时上翻的折扣。反手蓄力是「拉弓上举」，正手横置时上举 24° 会把拍子
## 掀起来破坏横置读感，所以只保留 35%（约 8°），主要靠 charge_pullback 往后收。
@export var fh_charge_windup_scale: float = 0.35
## 正手推击的时长。比反手抡拍短一点：推是一个短促的动作。
@export var fh_push_duration: float = 0.20

@export_group("蹲姿")
## 蹲下时整条球拍 rig 的抬升量（米，满蹲时）。
##
## ★ 为什么必须有：rig 挂在相机下，蹲下时整条跟着下沉 0.55 m，
##   而刀面静止位相对相机是 y ≈ −0.21 —— 站起来 1.309，蹲下正好 0.759，
##   也就是**正好压在台面 0.760 上**。实测蹲姿刀面 AABB y ∈ [0.673, 0.840]，
##   半个刀面埋在台里（_tmp_crouch.gd 量的）。
##   真人下蹲是屈膝、上身还挺着，手比头低得少，所以这里不让它吃满整个下沉量。
@export var crouch_lift: float = 0.32
## 刀面中心的世界 y 下限（米）—— 硬保险，和俯仰角无关。
## 上面那条抬升只按「蹲多深」算，管不住「玩家把视线压多低」：
## rig 在相机前方 0.34 m，低头就能把这 0.34 m 折成一段下沉。
## 所以再加一条绝对下限：刀面中心一旦低于这个值，就把整条 rig 顶上去。
## 0.890 = 台面 0.760 + 刀面半高 0.084（实测 AABB [1.223,1.390]）+ 余量 0.046
##
## ★ 2026-10-04 用户报「在球台附近低头时球拍与球台穿模」。实测
##   （`tests/_diag_paddle_table.gd` 扫俯仰角 × 探拍两档）：
##     站着低头**本身不穿** —— 俯到 -55° 时拍子最低点 0.827，还在台面(0.760)之上；
##     真正会穿的是**低头 + 探拍**（按住 Shift 把拍子再往前送 0.35 m）：
##     俯到 -40° 就穿台，-70° 时拍面中心掉到 0.564、拍子最低点 0.498 ——
##     比台面低 26 cm，半个拍子埋进台体里。
##   根因见 _update_crouch_lift()：这条下限当时被 `c <= 0.01` 挡着，只在蹲下时生效。
@export var blade_floor_y: float = 0.890
## 台面范围的判定外扩（m）。只有拍面中心的水平投影落进「台面 ± 这个值」以内，
## 才启用 blade_floor_y 那条下限 —— 站在台外低头是正常俯视，
## 把拍子硬顶在半空反而僵。
## ★ 判断用的是 x/z，而抬升只改 y，所以不存在「抬起→出界→落下→回界」的抖动。
@export var blade_clear_pad: float = 0.12

@export_group("待机")
@export var idle_bob_degrees: float = 1.2
@export var idle_bob_frequency: float = 1.25
@export var walk_bob_degrees: float = 2.0
@export var walk_bob_frequency: float = 4.2

@export_group("蓄力")
## 蓄力时球拍向上后收的角度（度）—— 像拉弓，让玩家看得出「在攒劲」
@export var charge_windup_deg: float = 24.0
## 蓄力时球拍向后收的距离（米），+Z 是朝相机（收回来）
@export var charge_pullback: float = 0.050

@export_group("拍形（开合）")
## 挥拍过程中拍面绕「柄轴横轴」转的角度，做成一条**显式曲线**而不是靠挥拍顺带产生。
##
## 为什么必须显式给：
##   主控的「拍面没喂正 → 出台」判据要读拍面法线。早先拍面法线的变化是挥拍动作
##   **顺带**带来的（反手绕相机 X 轴抡 55°，法线跟着扫过去），量出来刚好
##   「挥到中途 = 拍面正对来球」，所以那条判据能跑。
##   但正手改成「横向推击」之后手腕几乎不转（7°），法线全程几乎不动 ——
##   实测 |dot(法线, 出球方向)| 一路 0.93~0.98，判别力等于零，这条机制会静默失效。
##   所以改成:拍面角度由这条曲线**主动给出**，两种握拍都吃同一套「推早了拍面还开着」。
##
## 曲线形状：起手时拍面开着（+），到 face_square_at 回正（0），之后压低（−）。
## 正号 = 拍面朝天（开），负号 = 拍面压低（闭）—— 在相机坐标系里定义的，
## 所以抬头低头不会影响它。
## 待机拍形（度）。**别设 0**：主控判「拍面正不正」比的是拍面法线和
## 「−出球方向」。而球是压着往对方半台飞的（实测出球方向约 (0,-0.19,-0.98)，
## 下倾 11°），所以「完全水平」的拍面其实偏了 12.7°。
## 把待机拍形压到 −12° 之后，实测偏差降到 6.3°（该姿态下能达到的最小值，
## 因为法线还带一个 0.2 的横向分量），计分上算「正」。
##
## ★ 这个量是实测调出来的，不是拍脑袋：改出球解算（_solve_return / 目标高度）
##   或改握拍姿态之后，都要用 _tmp_face2.gd 重新量一遍待机偏差。
##
## ★ 两种握拍**符号是反的**，必须分开写：反手在 Paddle 层还叠了
##   roll +35°（翻腕），把 Aim 的「柄轴横轴」整根转了过去，
##   于是同一个方向的开合对正手是「打开」、对反手却是「压住」。
##   实测：正手 face=−12 → 偏差 6.2°（最优），反手 face=−12 → 偏差 25.1°（更差）；
##         反手要 +14 才能到最优。
@export var fh_face_rest_deg: float = -12.0
@export var bh_face_rest_deg: float = 14.0
@export var face_open_deg: float = 26.0
@export var face_close_deg: float = 30.0
## 拍面回正发生在挥拍的第几成。要和主控的 `_timing_quality()` 甜点对齐（0.40）。
@export var face_square_at: float = 0.40
## 两种握拍各自的**摆动补偿**（按挥拍幅度 f7 加权，待机时为 0）。
## 反手是绕相机横轴抡 55° 的大动作，手臂本身会把拍面掀起来 ~35°，
## 所以给一个负值把它压回去，保证「打在甜点上 = 拍面正」对反手一样成立。
## 待机时不生效，所以不会把反手待机姿态也带歪。
##
## ★ 实测结论：**这个补偿最后设成了 0**。
##   一度按实测斜率反解出反手要 −28°，结果偏差反而从 35.8° 涨到 54°——
##   因为「拍形角 → 法线偏差角」不是单调的：两者绕的不是同一根轴
##   （拍形绕 Aim 局部 Z，抡拍绕相机 X），球面上的夹角会拐弯。
##   所以主控那边也换掉了判据：不再读法线夹角，直接读**拍形角**（见
##   pingpong_game._face_out_chance）。保留这两个导出只是给以后调姿态用。
@export var fh_face_bias_deg: float = 0.0
@export var bh_face_bias_deg: float = 0.0

## 正手推击的拍形曲线折扣（开段 / 闭合段）。
##
## ★ 用户报「正手球拍往前推而不是向下压」，实测根因**不在手腕俯仰**：
##   `fh_push_pitch_deg` 从 +9 改到 −2，刀面位置只挪 ±4 mm、法线只差 2.6°。
##   真正的「往下压」来自对照反手原样抄的那条拍形曲线 ——
##   实测正手一整段推击里法线俯角是 +28° → −20°（_tmp_fh.gd 逐帧量的），
##   读起来就是「把拍子按下去」。
## 所以给正手单独打两折：
##   闭合段砍到只剩一成（−20° → −2°，拍子再也不朝下）；
##   开段保留七成（起手依然看得出拍形在变）。
## 出界判据的判别力不受影响：它比的是「当前拍形角 vs 待机拍形角」的偏离量，
## 只要起手有开段，偏离就还在。
@export var fh_face_open_scale: float = 0.70
@export var fh_face_close_scale: float = 0.10

@export_group("惯性")
@export var sway_degrees: float = 2.4
@export var sway_speed: float = 6.0

@export_group("外观")
@export var show_paddle: bool = true

@export_group("手")
## 默认关闭：程序化生成的手（fp_hand.gd）在近距离特写下精度不够，
## 掌心/指节看起来像几段圆柱拼的疙瘩，反而拉低了画面。
## 生成器保留着，想对比效果把这里或 pingpong.tscn 里的 show_hand 改回 true。
@export var show_hand: bool = false
@export_enum("正手", "反手") var grip_mode: int = GripMode.FOREHAND
## 皮肤反照率。原来是 (0.56,0.42,0.345)，那是**旧场景（室外亮天空）**下调的；
## 换成室内场馆后整体照度下降，同样的值显得发白发灰，压到 0.47/0.335/0.265。
@export var skin_color: Color = Color(0.47, 0.335, 0.265, 1.0)
## 挥拍时手腕的滞后比例（0 = 手与拍刚性一体，0.2 = 明显的甩腕）
@export var wrist_lag_ratio: float = 0.18

@export_group("补光")
@export var enable_fill_light: bool = true
@export var fill_light_color: Color = Color(1.0, 0.97, 0.92, 1.0)
## 头灯式补光：灯挂在**相机原点**略上方，朝相机的那一面必定被照亮。
## 早先把灯放在 (0.05, 0.14, 0.28)（相机右后上方），结果手的掌背朝外、
## 不朝灯，一半体积直接掉到近黑（真机渲染实测：手掌暗面 RGB ≈ 30）。
## 能量也不能给大：给到 1.6 时近端直接过曝到 255，同一只手上出现
## 「死白 + 近黑」两极。0.85 配皮肤自发光底线（见 fp_hand._make_skin）后，
## 实测：只调灯会在「近端 255 过曝 / 远端 87 近黑」之间反复横跳，
## 所以灯只给 0.45 打形体、皮肤再补 0.42 的自发光作下限。
## 半径只给 0.85 m，保证只照到手和拍、不污染 1 m 开外的球台。
## 能量从 0.45 降到 0.28：室内场景的环境光已经够亮，0.45 会把掌面顶到近白。
@export var fill_light_energy: float = 0.28
@export var fill_light_range: float = 0.85

var _paddle: Node3D
## 固定姿态层（拍头指向 / 拍面朝向）。正手反手用同一节点、不同变换。
var _aim: Node3D
var _head: Marker3D
var _hand: Node3D
var _player: CharacterBody3D
var _cam: Camera3D

var _rest_rot: Vector3 = Vector3.ZERO
var _rest_pos: Vector3 = Vector3.ZERO
var _base_rest_rot: Vector3 = Vector3.ZERO
## 当前握拍的 Aim 基准姿态（拍头指向 + 拍面朝向），拍形开合叠在它上面
var _aim_base: Basis = Basis.IDENTITY
## 当前拍形角度（度），正 = 开。给主控 / 自测读。
var _face_angle_deg: float = 0.0

var _swing_time: float = -1.0
var _pending: bool = false
var _idle_phase: float = 0.0
var _walk_phase: float = 0.0
var _sway: Vector2 = Vector2.ZERO
var _last_basis: Basis = Basis.IDENTITY
## rig 在场景里配的基准位。每帧的垂直修正都从它重新算 ——
## ★ 不能只在上一帧的 position 上累加：修正量里有横向分量，会逐帧漂移。
var _rig_home: Vector3 = Vector3.ZERO
var _charge: float = 0.0
## 探拍量 0..1，见 set_reach_extend()。
var _reach_extend: float = 0.0


func _ready() -> void:
	_rig_home = position
	_player = _find_player()
	_cam = get_parent() as Camera3D
	if _cam:
		_last_basis = _cam.global_transform.basis

	_paddle = _build_paddle()
	add_child(_paddle)
	_rest_rot = _base_rest_rot
	_rest_pos = _paddle.position
	_apply_grip()

	if enable_fill_light:
		_create_fill_light()
	_paddle.visible = show_paddle


func _find_player() -> CharacterBody3D:
	var n: Node = self
	while n:
		if n is CharacterBody3D:
			return n as CharacterBody3D
		n = n.get_parent()
	return null


# ───────────── 生成球拍（真实模型） ─────────────
func _build_paddle() -> Node3D:
	var root := Node3D.new()
	root.name = "Paddle"

	var aim := Node3D.new()
	aim.name = "Aim"
	aim.transform = _aim_transform(AIM_PITCH_DEG, AIM_YAW_DEG)
	root.add_child(aim)
	_aim = aim

	var model: Node3D = PADDLE_MODEL.instantiate()
	model.name = "PaddleModel"
	model.scale = Vector3.ONE * MODEL_SCALE
	aim.add_child(model)
	_apply_clean_material(model)

	# 拍面中心锚点挂在模型下：朝向和缩放自动继承，不用手算到手腕坐标系
	var head := Marker3D.new()
	head.name = "Head"
	head.position = BLADE_CENTER_MODEL
	model.add_child(head)
	_head = head

	# ── 握拍的手（挂在 Aim 下 → 挥拍时手跟着拍一起走）──
	if show_hand:
		var h := HAND.new()
		h.skin_color = skin_color
		# 真实球拍手柄实测（模型换算后）：z ∈ [-0.0916, 0]，截面半宽 0.0165 / 半厚 0.0145
		h.handle_half_x = 0.0165
		h.handle_half_y = 0.0145
		h.knuckle_z0 = -0.070      # 食指掌指关节，离拍面约 0.02
		h.knuckle_dz = 0.019       # 四指沿柄间距（真人约 19mm）
		h.palm_offset_x = -(h.handle_half_x + h.palm_semi.x)   # 掌的 +X 面贴住柄面
		_hand = h.build()
		_hand.rotation.z = deg_to_rad(HAND_ROLL_DEG)
		aim.add_child(_hand)

	# ── 待机位姿：原点 = 手腕 ──
	# rotation 全部交给 Aim，Paddle 自身保持零旋转：
	# 这样挥拍时 `rot.x -= amt` 绕的就是屏幕水平轴，拍子自然地在画面里上下划过。
	#
	# 手腕垂直角 19.9°、位于屏高 76%，离底边还有余量；前臂沿 -l 向右下出画。
	# 拍面中心落在屏幕 (60%, 52%)，拍尖 (54%, 42%)。
	# 距离 0.34 m 比对早先的 0.31 m 略远一档：手在画面里小一圈，不那么压画面。
	root.position = FH_REST_POS
	_base_rest_rot = Vector3.ZERO
	root.rotation = _base_rest_rot
	return root


## 把混元3D 自带的那套 AI 噪声贴图材质整个换掉（红底米斑 + 噪法线 = 揉皱的锡纸）。
## 用手写的 ShaderMaterial 按「手柄段 / 拍面段」分区上色，不采样任何 UV。
func _apply_clean_material(root: Node) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = PADDLE_SHADER
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i: int in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, mat)
	_apply_skin(mat)


## 把 Game 里装备的球拍皮肤铺到 shader 上（经济二期）。
## ★ 只在建材质这一处调，换皮肤时走 refresh_skin() —— 换装不用重建模型。
func _apply_skin(mat: ShaderMaterial) -> void:
	var t := _skin_theme()
	mat.set_shader_parameter("rubber_color", t["rubber"])
	mat.set_shader_parameter("wood_color", t["wood"])
	mat.set_shader_parameter("epic_glow", 1.0 if bool(t["glow_on"]) else 0.0)
	mat.set_shader_parameter("glow_color", t["glow"])
	mat.set_shader_parameter("glow_speed", float(t["glow_speed"]))


## 从单例取当前皮肤快照。拿不到（离屏探针直接实例化场景）就用 shader 的默认值，
## 也就是「红黑经典 + 原木柄」，正好是初始款。
func _skin_theme() -> Dictionary:
	var g := get_node_or_null("/root/Game")
	if g != null and g.has_method("paddle_theme"):
		return g.call("paddle_theme")
	return {
		"rubber": Color(0.600, 0.045, 0.055),
		"wood": Color(0.470, 0.290, 0.135),
		"glow": Color(0.0, 0.0, 0.0),
		"glow_speed": 1.0,
		"glow_on": false,
	}


## 玩家在工坊里换了皮肤 —— 重新铺一遍参数，不重建任何节点。
func refresh_skin() -> void:
	if _paddle == null:
		return
	var stack: Array[Node] = [_paddle]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c: Node in n.get_children():
			stack.append(c)
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i: int in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(i) as ShaderMaterial
			if m != null:
				_apply_skin(m)


## 把模型长轴（手柄 → 拍头）摆到 l 方向，同时让拍面尽量正对玩家。
## 用 looking_at 而不是手搓 Basis：Godot 里 Basis 的行/列约定很容易搞反，
## 而 looking_at(target, up) 的语义明确是「-Z 指向 target」，正好对上模型的拍头方向。
func _aim_transform(pitch_deg: float, yaw_deg: float) -> Transform3D:
	var p := deg_to_rad(pitch_deg)
	var y := deg_to_rad(yaw_deg)
	var l := Vector3(sin(y) * cos(p), sin(p), -cos(y) * cos(p)).normalized()
	# 取「相机方向 +Z」在垂直于 l 的平面上的投影作为 up → 拍面法线尽量朝向玩家
	var n := (Vector3(0.0, 0.0, 1.0) - l * Vector3(0.0, 0.0, 1.0).dot(l)).normalized()
	return Transform3D(Basis(), Vector3.ZERO).looking_at(l, n)


func _create_fill_light() -> void:
	var l := OmniLight3D.new()
	l.name = "PaddleFillLight"
	l.light_color = fill_light_color
	l.light_energy = fill_light_energy
	l.omni_range = fill_light_range
	l.omni_attenuation = 0.5
	# 灯 = 相机头灯（略高于视点，给掌心留一点上亮下暗的形体感）
	l.position = Vector3(0.0, 0.08, 0.0)
	l.shadow_enabled = false
	add_child(l)


# ───────────── 挥拍 ─────────────
func trigger_swing() -> void:
	if _swing_time < 0.0:
		_swing_time = 0.0
	else:
		_pending = true


func is_swinging() -> bool:
	return _swing_time >= 0.0


## 当前握拍下的挥拍总时长。正手是「推」——短促；反手是「抡」——留出划弧的时间。
func _swing_duration() -> float:
	return fh_push_duration if grip_mode == GripMode.FOREHAND else swing_duration


func swing_progress() -> float:
	if _swing_time < 0.0:
		return -1.0
	return clampf(_swing_time / maxf(_swing_duration(), 0.001), 0.0, 1.0)


## 由主控每帧写入 0~1 的蓄力进度（按住空格时增长）。
## 只影响姿态，不影响挥拍判定 —— 判定在 pingpong_game 里。
func set_charge(v: float) -> void:
	_charge = clampf(v, 0.0, 1.0)


func get_charge() -> float:
	return _charge


## 探拍量（0..1）。由 pingpong_game 按住 Shift 时驱动，见 table_reach_max。
## 传给这里而不是主控自己算偏移，是为了让**视觉和判定同一个数** ——
## head_position() 读的就是 _head.global_position，偏移加在 rig 上之后
## 判定自动跟着走，不会出现「看着够到了、判定说没有」。
func set_reach_extend(v: float) -> void:
	_reach_extend = clampf(v, 0.0, 1.0)


func get_reach_extend() -> float:
	return _reach_extend


## 拍面中心的世界坐标（击球判定的核心点）
func head_position() -> Vector3:
	if _head != null and is_instance_valid(_head):
		return _head.global_position
	return global_position


## 拍面法线（世界，单位向量）。
##
## 给主控判断「这一拍拍面朝哪」用（出界概率）。取球拍节点的局部 +Y：
## _aim_transform() 用 looking_at(l, n) 摆姿态，Godot 的 looking_at 会把
## -Z 指向 l（拍头方向，见 BLADE_CENTER_MODEL）、+Y 尽量贴 n，
## 而 n 正是「相机 +Z 在垂直于拍柄轴的平面上的投影」= 拍面法线。
## 所以**Aim 节点**自身的 basis.y 就是拍面朝向。
##
## ★ 这里曾经写的是 `_paddle.global_transform.basis.y`，那是个 bug：
##   `_paddle` 是外层那个只承载「待机 / 挥拍姿态」的 Paddle 节点，
##   它的 rotation 平时就是零（`_rest_rot`），basis.y 实际等于**相机的上方向**，
##   跟拍面朝向毫无关系。实测过：待机时读出来是 (0, 0.933, -0.361) ——
##   正好等于相机自身的 up，一眼就能认出取错了节点。
##   出界判定因此实际是在量「挥到第几拍」，不是「拍面朝哪」。
##   注意两面的拍子：拍面正反都能打，调用方要对结果取绝对值。
func face_normal() -> Vector3:
	if _aim == null or not is_instance_valid(_aim):
		return Vector3(0.0, 0.0, 1.0)
	var n: Vector3 = _aim.global_transform.basis.y
	if n.length_squared() < 1e-6:
		return Vector3(0.0, 0.0, 1.0)
	return n.normalized()


## 正手向右前挥、反手向左前挥（挥拍偏航方向）
func _grip_dir() -> float:
	return 1.0 if grip_mode == GripMode.FOREHAND else -1.0


## 根据 grip_mode 重算待机姿态：反手手腕外翻（roll）+ 适度拍面翻转（yaw），
## 手始终在画面右下，单手握拍感，不大幅转身。
func _apply_grip() -> void:
	var fh := grip_mode == GripMode.FOREHAND
	_rest_rot = _base_rest_rot
	if not fh:
		_rest_rot.y += deg_to_rad(_GRIP_YAW)
		_rest_rot.z += deg_to_rad(_GRIP_ROLL)
	_rest_pos = FH_REST_POS if fh else BH_REST_POS
	# 拍头指向 / 拍面朝向也在这一层切换：正手横置向右、反手斜举向左前
	if _aim != null and is_instance_valid(_aim):
		var t := _aim_transform(
			FH_AIM_PITCH_DEG if fh else AIM_PITCH_DEG,
			FH_AIM_YAW_DEG if fh else AIM_YAW_DEG)
		_aim_base = t.basis
		_aim.transform = t
		_face_angle_deg = _face_rest()
		_apply_face_angle()
	# 立即把姿态写到节点，避免等下一帧 _process（自测 / 切换时即时生效）
	if _paddle != null:
		_paddle.rotation = _rest_rot
		_paddle.position = _rest_pos


## 切换正手 / 反手，返回新模式（0 正手 / 1 反手），供主控 HUD 显示
func toggle_grip() -> int:
	grip_mode = GripMode.BACKHAND if grip_mode == GripMode.FOREHAND else GripMode.FOREHAND
	_apply_grip()
	return grip_mode


## 直接指定握拍模式（0 正手 / 1 反手），返回实际生效的模式。
## 鼠标左键 = 反手、右键 = 正手就是靠这个接口。
func set_grip(mode: int) -> int:
	grip_mode = clampi(mode, 0, 1)
	_apply_grip()
	return grip_mode


func get_grip_name() -> String:
	return "正手" if grip_mode == GripMode.FOREHAND else "反手"


## 当前拍形角度（度，正 = 拍面朝天）。给主控 HUD / 自测读。
func get_face_angle() -> float:
	return _face_angle_deg


## 当前握拍的待机拍形。主控拿它当「甜点拍形」基准：
## 出台概率看的就是「此刻拍形相对它偏了多少度」。
func get_face_rest() -> float:
	return _face_rest()


## 输入统一由 pingpong_game.gd 处理（左键=反手、右键=正手、F=挥拍），
## 这里不再抢事件：否则左键会被触发两次（多queue一次挥拍），而且右键没法带握拍切换。
## InputMap 里实际只注册了 "hit"，直接 is_action_pressed("attack"/"swing")
## 会在每次输入事件时刷 ERROR: The InputMap action "xxx" doesn't exist。


func _process(delta: float) -> void:
	if _paddle == null:
		return
	_update_swing(delta)
	_update_idle(delta)
	_update_sway(delta)
	_update_crouch_lift()


## rig 垂直修正：蹲姿抬升 + 「刀面不得埋进台面」的硬下限。
## 都作用在 rig 自己的位置（不动 _paddle，免得和挥拍 / 蓄力的位移打架）。
func _update_crouch_lift() -> void:
	var c := 0.0
	if _player != null and _player.has_method("crouch_amount"):
		c = clampf(float(_player.call("crouch_amount")), 0.0, 1.0)
	# ★ 每帧从**基准位整体重置**，而不是照旧只写 y：下面的下限补偿是沿世界竖直
	#   方向做的，在带俯仰的父空间里会解出横向分量；只重置 y 的话那些分量会逐帧
	#   累积，拍子会慢慢飘出画面（原实现只写 y 也能活，是因为它只做抬升、不带横向）。
	position = _rig_home + Vector3(0.0, crouch_lift * c, 0.0)
	if _head == null or not is_instance_valid(_head):
		return
	# ── 硬下限：刀面中心不得低于 blade_floor_y ──
	# ★ 这里**不能**再夹一句 `c > 0`（原实现就是那样，于是只在蹲下时生效）。
	#   站着时头确实不下降，但探头会随俯仰折成一段下沉、探拍又把它从 0.34 m
	#   拉长到 0.69 m —— 低头 + 探拍照样穿台（实测见 blade_floor_y 的注释）。
	var probe: Vector3 = _head.global_position
	if absf(probe.x) > TABLE_HALF_WIDTH + blade_clear_pad:
		return
	if absf(probe.z) > TABLE_HALF_LENGTH + blade_clear_pad:
		return
	var deficit := blade_floor_y - probe.y
	if deficit <= 0.0:
		return
	# 沿**世界竖直**方向抬，再换算成父空间里的位移。
	# ★ 不能沿 rig 的 local y 抬：低头时局部 y 几乎是水平的，想用它抬起世界高度
	#   得除以接近 0 的 cos —— -89° 时 cos=0.017，局部要挪 57 倍，拍子瞬间被甩到
	#   二十米之外（屏幕上是「拍子凭空消失」）。换算成世界位移就没有这个病。
	var p := get_parent() as Node3D
	if p == null:
		position.y += deficit
		return
	position += p.global_transform.basis.inverse() * Vector3(0.0, deficit, 0.0)


func _update_swing(delta: float) -> void:
	var amt := 0.0
	var yaw := 0.0
	var reach := 0.0
	var dur := _swing_duration()
	var p := 0.0
	var f7 := 0.0

	if _swing_time >= 0.0:
		_swing_time += delta
		p = clampf(_swing_time / maxf(dur, 0.001), 0.0, 1.0)
		# MC 式缓动：f6 = 1-(1-p)^3, f7 = sin(f6 * PI)
		var f6 := 1.0 - p
		f6 = f6 * f6 * f6
		f6 = 1.0 - f6
		f7 = sin(f6 * PI)
		if grip_mode == GripMode.FOREHAND:
			# 正手 = 推挡：手腕几乎不转，主要是把拍子整块往前送出去
			amt = f7 * deg_to_rad(fh_push_pitch_deg)
			yaw = f7 * deg_to_rad(fh_push_yaw_deg)
			reach = f7 * fh_push_reach
		else:
			amt = f7 * deg_to_rad(swing_degrees)
			yaw = f7 * deg_to_rad(swing_yaw_degrees) * _grip_dir()
			reach = f7 * swing_reach
		if _swing_time >= dur:
			_swing_time = -1.0
			if _pending:
				_pending = false
				trigger_swing()

	# 正手横置时上举会破坏「横」的读感，蓄力上翻打个折，主要靠往后收
	var windup := charge_windup_deg
	if grip_mode == GripMode.FOREHAND:
		windup *= fh_charge_windup_scale

	var rot := _rest_rot
	rot.x -= amt
	rot.y += yaw
	# 蓄力：往上向后收，像拉满弓；松手挥拍时 _charge 已被主控清零，自然「放出去」
	rot.x += deg_to_rad(windup) * _charge
	_paddle.rotation = rot
	_paddle.position = _rest_pos
	_paddle.position.z -= reach
	_paddle.position.z += charge_pullback * _charge
	# ★ 探拍：把拍子往球台上方送出去（_reach_extend ∈ [0,1]，由主控按住 Shift 驱动）。
	#   减 z = 沿相机前方推出 —— 和挥拍的 reach 同一条轴、同一套局部坐标，
	#   所以挥拍和探拍能自然叠加，不会互相打架。
	_paddle.position.z -= table_reach_max * _reach_extend
	# 同时下压：迎上台面上空的低短球（见 table_reach_dip 注释）。
	_paddle.position.y -= table_reach_dip * _reach_extend
	_paddle.position.y += 0.02 * _charge

	# 手腕滞后：拍子先走、手慢半拍，收拍时自然回弹
	if _hand != null:
		_hand.rotation.x = -amt * wrist_lag_ratio

	# ── 拍形开合 ──
	# 挥拍中按曲线走（起手开着 → 甜点回正 → 收拍压低），待机时回到偏置值。
	# 这条曲线是**独立于上面那套挥拍姿态**的：它单独转 Aim 节点，
	# 所以「拍面朝哪」不再取决于「手腕转了多少」——
	# 正手那种几乎不转的横置推击同样有清晰的拍形变化。
	_face_angle_deg = _face_rest() + _face_curve(p, f7) if _swing_time >= 0.0 else _face_rest()
	_apply_face_angle()


## 当前握拍的待机拍形。
func _face_rest() -> float:
	return fh_face_rest_deg if grip_mode == GripMode.FOREHAND else bh_face_rest_deg


## 当前握拍的**摆动补偿**。按挥拍幅度 f7 加权，所以待机时是 0 ——
## 它只负责抵消「挥起来之后手臂多掀的那点拍面」，不参与待机姿态。
func _face_bias(f7: float) -> float:
	return (fh_face_bias_deg if grip_mode == GripMode.FOREHAND else bh_face_bias_deg) * f7


## 拍形角度曲线：起手 face_open_deg（开）→ face_square_at 处回正 → 收拍 −face_close_deg（压）。
## 正手另吃一对折扣（见 fh_face_open_scale / fh_face_close_scale）：
## 「推挡」不该有往下压的收拍。
func _face_curve(p: float, f7: float) -> float:
	var sq := clampf(face_square_at, 0.05, 0.95)
	var open := face_open_deg
	var close := face_close_deg
	if grip_mode == GripMode.FOREHAND:
		open *= fh_face_open_scale
		close *= fh_face_close_scale
	var a := 0.0
	if p <= sq:
		a = lerpf(open, 0.0, p / sq)
	else:
		a = lerpf(0.0, -close, (p - sq) / (1.0 - sq))
	return a + _face_bias(f7)


## 把拍形角度写进 Aim：绕 Aim 的局部 Z 轴转。
## Aim 的局部 -Z 是拍头方向，所以局部 Z 就是「柄轴的横轴」，
## 绕它转 = 法线在竖直平面里开合 = 拍面朝天 / 压拍，正是要的那个轴。
func _apply_face_angle() -> void:
	if _aim == null or not is_instance_valid(_aim):
		return
	_aim.basis = _aim_base * Basis(Vector3(0.0, 0.0, 1.0), deg_to_rad(_face_angle_deg))


func _update_idle(delta: float) -> void:
	_idle_phase += delta * idle_bob_frequency
	var speed := 0.0
	if _player:
		var v := _player.velocity
		speed = Vector2(v.x, v.z).length()
	_walk_phase += delta * walk_bob_frequency * clampf(speed / 5.0, 0.0, 1.8)
	var walking := clampf(speed / 2.0, 0.0, 1.0)
	var bob := sin(_idle_phase) * idle_bob_degrees \
			 + sin(_walk_phase) * walk_bob_degrees * walking
	_paddle.rotation.x += deg_to_rad(bob) * 0.35
	_paddle.position.y += deg_to_rad(bob) * 0.004


func _update_sway(delta: float) -> void:
	if _cam == null:
		return
	var basis := _cam.global_transform.basis
	var d := basis.inverse() * _last_basis
	_last_basis = basis
	var e := d.get_euler()
	var target := Vector2(
		clampf(-e.y * sway_degrees * 12.0, -sway_degrees, sway_degrees),
		clampf(e.x * sway_degrees * 12.0, -sway_degrees, sway_degrees)
	)
	_sway = _sway.lerp(target, clampf(sway_speed * delta, 0.0, 1.0))
	_paddle.rotation.y += deg_to_rad(_sway.x) * 0.3
	_paddle.rotation.x += deg_to_rad(_sway.y) * 0.3
