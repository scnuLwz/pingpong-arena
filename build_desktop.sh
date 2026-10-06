#!/usr/bin/env bash
# 把 cs-1 导出成 Windows 原生 exe（给别人下载了直接玩）。
#
# 为什么需要它：
#   1) 网页版是「single-threaded wasm + gl_compatibility」—— 为了能在浏览器里跑，
#      线程和 Forward+ 都被拿掉了，所以卡。桌面版**不做任何降级**：
#      Forward+ / d3d12 / Jolt 全保留，就是你本机按 F5 的那一套。
#   2) 导出前必须临时摘掉 godot_mcp 的 MCPRuntimeProbe autoload 与插件 ——
#      它是个编辑器插件，打进玩家包会起一个调试探针；而且只要编辑器一启动，
#      插件就会在内存里把 autoload 加回来（改文件那一行没用），所以插件开关也要关。
#   3) 窗口尺寸覆盖值本机是 3072x1980（比常见显示器还大），发给别人会开出一个
#      超出屏幕的窗口。这里在**导出副本**里改成 1600x900，不动你本机的 project.godot。
#
# ★ 本脚本全程只改 project.godot 的**临时副本**，结束（含异常）一定还原，
#   并在最后核对 md5 —— 桌面版和网页版可以交替跑而不会互相污染。
set -e

GODOT="D:/dev/_godot_dl/Godot_v4.7.2-stable_win64_console.exe"
PROJ="C:/Users/赖文钊/Documents/cs-1"
OUT="D:/dev/cs1_desktop"
BAK="project.godot.deskbak"

cd "$PROJ"

# ── 防呆：先处理上一轮异常中断的残留 ──
if [ -f "$BAK" ]; then
	echo "!! 发现上次残留的 $BAK，先还原 project.godot"
	mv -f "$BAK" project.godot
fi
if ! grep -q '^MCPRuntimeProbe=' project.godot; then
	echo "!! project.godot 里没有 MCPRuntimeProbe，像是上一轮打完补丁没还原 → 从 git 取回"
	git checkout -- project.godot
fi

cp project.godot "$BAK"
BEFORE=$(md5sum project.godot | cut -d' ' -f1)
echo "project.godot 基线 md5: $BEFORE"

# 无论中间哪一步失败，都要把 project.godot 还原回去
trap 'mv -f "$BAK" project.godot 2>/dev/null; echo "=== 已还原 project.godot（含异常退出） ==="' EXIT

echo "=== 1/3 先导入（让编辑器把该写回的都写回） ==="
"$GODOT" --headless --path "$PROJ" --import 2>&1 | tail -3

echo "=== 2/3 打「发行」补丁 ==="
python - "$PROJ/project.godot" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()

# 1) 摘掉 MCP 调试探针的 autoload
s = re.sub(r'^MCPRuntimeProbe=.*\r?\n', '', s, flags=re.M)
# 2) 关掉编辑器插件（否则 --export 启动编辑器时它会在内存里把 autoload 加回来）
s = s.replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")',
              'enabled=PackedStringArray()')
# 3) 窗口尺寸覆盖值换成能装进普通显示器的大小。
#    ★ 故意不动 application/config/name —— 它决定 user:// 的落盘目录
#      (%APPDATA%/Godot/app_userdata/<name>/)，改了会让本机存档「看起来消失」。
s = re.sub(r'^window_width_override=\d+$', 'window_width_override=1600', s, flags=re.M)
s = re.sub(r'^window_height_override=\d+$', 'window_height_override=900', s, flags=re.M)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
PY
grep -n "^window_width_override\|^window_height_override\|^MCPRuntimeProbe" project.godot || echo "(MCPRuntimeProbe 已移除)"
grep -n "^enabled=PackedStringArray" project.godot

# 不删目录：导出本来就会覆盖同名文件；一次性删除大目录会触发批量删除确认
mkdir -p "$OUT"
rm -f "$OUT/pingpong-arena.exe"

echo "=== 3/3 导出 Windows ==="
"$GODOT" --headless --path "$PROJ" --export-release "Windows" 2>&1 | tail -8

# 还原，保证本机开发不受影响
mv -f "$BAK" project.godot
trap - EXIT
AFTER=$(md5sum project.godot | cut -d' ' -f1)
echo "=== 已还原 project.godot ==="
if [ "$BEFORE" = "$AFTER" ]; then
	echo "✓ md5 与跑前一致（$AFTER）"
else
	echo "✗★ md5 变了！跑前 $BEFORE → 跑后 $AFTER"
	exit 1
fi

echo "=== 产物 ==="
ls -la "$OUT"
