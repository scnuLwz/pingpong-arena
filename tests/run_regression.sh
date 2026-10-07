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
# 存档核对要用它做逐键 JSON 比对（见文件末尾）。★ 路径写死而不是 `python`：
# 这台机器的 PATH 里没有可用的 python。
PYTHON="C:/Users/赖文钊/.workbuddy/binaries/python/envs/default/Scripts/python.exe"
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

# ───────────── 存档核对（跑完必须和跑前一致）─────────────
# ★★ 为什么不能只比字节：`daily_ensure()` 是**跨天幂等重置**——探针只要碰到
#    任何会调它的代码路径（B/D 组的 reset_all 链、L 组的写盘链），就会把
#    `daily` 块刷成今天：`day` +1、`ids` 按新日期哈希重抽、`*_today` 归零。
#    这是**正常游戏行为**（玩家今天一开游戏也会发生同样的事），
#    但字节比对看不出来 —— 于是每逢「跑回归那天 != 存档里记的那天」就误报，
#    还顺手把存档**退回昨天**（等于凭空抹掉一次合法的日切）。
#    2026-10-07 连续踩了两轮才定位：跑前后逐键比只差 `daily` 一个键，
#    `coins`/`stats.points`/`streak` 全等，而报的是「这是 bug」。
#
#    判据改成**逐键语义比对**：
#      · 只有 `daily` 一个键变、其它键全等 → 日切，**保留探针写出的新档**，只提示不失败
#      · 出现别的键变化，或 `daily` 里 `streak`/`best`（真实进度）变了 → 真 bug，
#        还原 + STATUS=1
#    ★ 还原方向也反过来了：日切时**不回退**（回退才是丢数据）。
if [ -n "$PROFILE_BAK" ]; then
  if cmp -s "$PROFILE" "$PROFILE_BAK"; then
    echo "存档核对：profile.json 与跑前一致。"
  else
    VERDICT="$("$PYTHON" - "$PROFILE" "$PROFILE_BAK" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        cur = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f:
        bak = json.load(f)
except Exception as exc:                       # noqa: BLE001
    print("UNREADABLE\t%s" % exc)
    raise SystemExit(0)

changed = sorted(k for k in set(list(cur) + list(bak)) if cur.get(k) != bak.get(k))
if not changed:
    print("IDENTICAL\t")                       # 仅格式/顺序不同
elif changed == ["daily"]:
    # 日切必须只体现在「日期 + 任务池 + 今日计数」；连续天数与最高纪录是真实进度，
    # 变了就说明不只是日切。
    c, b = cur.get("daily") or {}, bak.get("daily") or {}
    keep = [k for k in ("streak", "best") if c.get(k) != b.get(k)]
    if keep:
        print("REAL\t连续天数/最高纪录被改动：%s" % ",".join(keep))
    else:
        print("ROLLOVER\t%s -> %s" % (b.get("day"), c.get("day")))
else:
    print("REAL\t变动键：%s" % ",".join(changed))
PYEOF
)"
    KIND="${VERDICT%%$'\t'*}"
    DETAIL="${VERDICT#*$'\t'}"
    case "$KIND" in
      IDENTICAL)
        echo "存档核对：profile.json 与跑前语义一致。"
        ;;
      ROLLOVER)
        # 探针把日任务切到了今天 —— 这是玩家今天开游戏也会发生的事，
        # 保留新档（回退反而抹掉这次合法日切），不算失败。
        echo "存档核对：日任务跨天滚动（$DETAIL）—— 正常行为，保留探针写出的新档。"
        ;;
      *)
        cp "$PROFILE_BAK" "$PROFILE"
        echo "★ 存档核对：profile.json 被探针改坏了 —— 已从跑前备份还原。"
        echo "  （这是 bug，不是正常现象。查 B / D 组里的 reset_all 调用链。）"
        [ -n "$DETAIL" ] && echo "  差异：$DETAIL"
        STATUS=1
        ;;
    esac
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
