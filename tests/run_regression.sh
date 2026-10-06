#!/usr/bin/env bash
# 回归探针 —— 改难度系统 / 拆模块之前必须全绿。
#
# 用法：
#   bash tests/run_regression.sh          跑全部组
#   CS1_GROUPS=A bash tests/run_regression.sh    只跑难度插值
#   CS1_GROUPS="A B" bash tests/run_regression.sh 跑指定组
#
# 组：
#   A  难度插值基线（10 参数 × 5 档 + 钳位 + 单调性 = 142 项）
#   B  三个进场旗标（本局模式不落盘 / 模式偏好持久化 / reset_all 清干净）
#   C  关键几何常量（活动区 / 发球区 / court_builder 副本同步）
#   D  难度微调的值语义（不入树，用脚本实例）
#   E  难度微调的端到端链路（★ 进真树、跑真单例、会写真实存档）
#   F  凶度反馈（档位门槛 / 文案 / 「亮 == 真在加成」不变量）
#   G  凶度 HUD 布局（★ 进树：四条红边的锚点/厚度/贴边 + 提示字同步）
#   H  球拍不穿台面（★ 进树：低头+探拍时拍子最低点必须高于台面 0.760）
#   I  「球必须先落台才能击球」的真值表
#   J  发球预览的开销不变量（缓存 / 节流 / 出手点统一）
#   K  旋球折扣 + 快球反馈（★ 进树：HUD 建起来没有 + 大字内容 + 触发策略）
#   L  赛后称号 + 一键领取（★ 会写盘：靠下方存档兜底的两道防线）
#   M  发球预览 == 真实落点（出手照搬画框速度 + 不变量：环位置 == 该速度的落点）
#   N  体力耦合（扣杀扣 AI 自己体力 + 体力⇄够球范围正相关 + 接发球半径不变量）
#
# 退出码 0 = 全绿，1 = 有 FAIL。
#
# ★ 组名走环境变量而不是位置参数：这台机器的沙箱会往脚本的位置参数里
#   用户组 ID（实测本机 GROUPS=197121）—— 直接用这个名字会跑成
#   「未知组名 197121」。
GODOT="D:/dev/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.." || exit 1

# ★ 改了 .gd 必须先 --import：否则跑的是 .godot 里的旧字节码，
#   「0 error」是假阳性（import 必要但不充分 —— 返回 Variant 的函数
#   被:= 接收只在跑探针时才炸）。
"$GODOT" --headless --path . --import 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" | head -5

# ───────────── 玩家存档兜底 ─────────────
# ★★ 探针里有几组会在**离树实例**上调 `reset_all()`（B / D 组），而它结尾会
#    `save_profile()` —— 于是拿一份刚 new 出来的默认档案覆盖玩家真实的
#    profile.json：金币、战绩、称号、解锁场馆、难度**全部归零**，且**不报错**。
#    2026-10-06 才发现（跑完 A~K 核对存档：金币 5485→0、35 场→0）。
#    探针内部已经会自己快照 + 还原（见 regression_probe.gd 的 PROFILE_PATH 段），
#    这里再加一道**与探针无关**的兜底 —— 探针崩了、被 SIGTERM 掐了也挡得住。
PROFILE_DIR="${APPDATA:-$HOME/AppData/Roaming}/Godot/app_userdata/cs1"
PROFILE="$PROFILE_DIR/profile.json"
PROFILE_BAK=""
if [ -f "$PROFILE" ]; then
  PROFILE_BAK="$(mktemp -t cs1profile.XXXXXX)"
  cp "$PROFILE" "$PROFILE_BAK"
fi

STATUS=0
for g in ${CS1_GROUPS:-A B C D E F G H I J K L M N}; do
  echo "--- 组 $g ---"
  # 输出到文件再取：管道会把 Godot 的退出码吞掉，
  # 而「探针 exit 1」正是唯一的失败信号，不能靠肉眼看输出。
  OUT="$(mktemp -t cs1regress.XXXXXX)"
  timeout 240 "$GODOT" --headless --path . tests/regression_probe.tscn -- "$g" >"$OUT" 2>&1
  RC=$?
  grep -E "=====|FAIL|通过" "$OUT"
  # ★★ 探针只报「全部通过：N 项断言」，而 N 可以是 0 —— 源码里一句 Parse Error
  #    就能让 `load("res://pingpong_game.gd")` 返回空脚本，断言全跳过、照样打印
  #    「全部通过」。2026-10-06 实测：`_plan_serve` 里把局部变量 `own_cands`
  #    误写成 `own_x_cands` → A/F/G/I/J/K/L 全报 0 项却绿。
  #    这里既查出错行，也拒绝 0 项断言（有内容 = 真跑过）。
  if grep -qE "SCRIPT ERROR|Parse Error" "$OUT"; then
    grep -E "SCRIPT ERROR|Parse Error" "$OUT" | head -5
    echo "  ★ 组 $g 有脚本错误 —— 「通过」不可信。"
    STATUS=1
  fi
  if grep -qE "全部通过：0 项断言" "$OUT"; then
    echo "  ★ 组 $g 跑了 0 项断言 —— 探针没真正执行，按失败计。"
    STATUS=1
  fi
  if [ "$RC" -ne 0 ]; then
    echo "  (组 $g 退出码 $RC)"
    STATUS=1
  fi
  # 沙箱的 rm 包装器会拒绝对Windows 反斜杠绝对路径动手（embedded drive prefix），
  # 临时文件留在系统 temp 目录即可，不值得为它绕。
done

# ───────────── 存档核对（跑完必须和跑前逐字节一致）─────────────
if [ -n "$PROFILE_BAK" ]; then
  if cmp -s "$PROFILE" "$PROFILE_BAK"; then
    echo "存档核对：profile.json 与跑前一致。"
  else
    cp "$PROFILE_BAK" "$PROFILE"
    echo "★ 存档核对：profile.json 被探针改写过 —— 已从跑前备份还原。"
    echo "  （这是 bug，不是正常现象。查 B / D 组里的 reset_all 调用链。）"
    STATUS=1
  fi
fi

if [ "$STATUS" -eq 0 ]; then
  echo ""
  echo "全部组通过。"
else
  echo ""
  echo "有组失败 —— 见上面 FAIL 行。"
fi
exit $STATUS
