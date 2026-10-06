#!/usr/bin/env bash
# 导出产物自检 —— 用引擎加载 pck/exe 跑关键场景，验证资源确实打进去了。
#
# 为什么需要它：
#   export_presets.cfg 的 exclude_filter 是**硬排除**，会直接切断依赖链 ——
#   Godot 的依赖追踪不会把被你排掉的资源救回来。而主菜单只用到 .scn / 字体 / 音频，
#   比赛场景才是第一个用 3D 资源的地方，于是「主菜单正常但进不去比赛」极容易漏过。
#   （2026-10-06 真实踩过：table_clean.res 依赖的三张贴图被一条残留通配符排除，
#     桌面版和网页版**都**卡在「开始比赛」点不动。详见 PITFALLS.md K 节。）
#
# 用法：
#   bash tests/verify_export.sh                          # 默认验桌面版 exe
#   bash tests/verify_export.sh <产物路径> [场景]         # 也可验网页版 index.pck
#
# 环境变量：GODOT（引擎路径）、FRAMES（跑多少帧，默认 1800 ≈ 30 s）
#
# ★ 必须用**编辑器构建**的引擎（支持 path override）。官方导出模板编译时带
#   disable_path_overrides，给它直接传场景路径会报 compiled without support for path overrides。
set -u

GODOT="${GODOT:-D:/dev/_godot_dl/Godot_v4.7.2-stable_win64_console.exe}"
TARGET="${1:-D:/dev/cs1_desktop/pingpong-arena.exe}"
SCENE="${2:-res://pingpong.tscn}"
FRAMES="${FRAMES:-1800}"
LOG="${TEMP:-/tmp}/cs1_verify_export.log"

[ -f "$TARGET" ] || { echo "✗ 找不到产物：$TARGET"; exit 2; }
[ -f "$GODOT" ]  || { echo "✗ 找不到引擎：$GODOT"; exit 2; }

echo "产物 : $TARGET  ($(stat -c %s "$TARGET" 2>/dev/null || echo '?') 字节)"
echo "引擎 : $GODOT"
echo "场景 : $SCENE   帧数: $FRAMES"
echo

timeout 400 "$GODOT" --headless --main-pack "$TARGET" "$SCENE" \
        --quit-after "$FRAMES" > "$LOG" 2>&1
RC=$?

ERRS=$(grep -c 'ERROR' "$LOG" 2>/dev/null || true)
MISS=$(grep -c 'Resource file not found' "$LOG" 2>/dev/null || true)
ERRS=${ERRS:-0}; MISS=${MISS:-0}

echo "引擎退出码        : $RC"
echo "ERROR 行数        : $ERRS"
echo "缺失资源行数      : $MISS"
echo

if [ "$MISS" -gt 0 ]; then
	echo "✗ 有资源没打进包 —— 八成是 export_presets.cfg 的 exclude_filter 排掉了它："
	grep 'Resource file not found' "$LOG" | sort -u | head -10
	echo
	echo "  排查：grep -rn \"res://models/\" --include='*.gd' --include='*.tscn' ."
	echo "  ★ 别忘了**间接依赖** —— .res 里引用的贴图不会出现在 .gd/.tscn 里。"
	exit 1
fi

if [ "$ERRS" -gt 0 ]; then
	echo "✗ 场景加载或运行期报错："
	grep 'ERROR' "$LOG" | head -10
	exit 1
fi

if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ]; then
	echo "✗ 引擎非正常退出（码 $RC）"
	exit 1
fi

echo "✓ 通过：资源完整，场景加载与运行 $FRAMES 帧均无错误"
echo "  完整日志：$LOG"
