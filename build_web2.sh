#!/usr/bin/env bash
# 把 cs-1 项目导出成可在浏览器里跑的 HTML5 版本。
#
# 为什么需要这个脚本：
#   1) Mono(.NET) 版 Godot 不能导出 Web，必须用标准版编辑器。
#   2) 项目本地用的是 Forward+ 渲染 + Jolt 物理，这两样 Web 上都没有，
#      导出前临时切成 gl_compatibility + GodotPhysics3D，导完再还原，
#      这样你本机开发时的画面质量不受影响。
#   3) 补丁必须在 --import 之后、--export 之前打：
#      import 阶段编辑器会启动，godot_mcp 插件会把 MCPRuntimeProbe autoload
#      重新写回 project.godot，先打会被它冲掉。
set -e

GODOT="D:/dev/_godot_dl/Godot_v4.7.2-stable_win64_console.exe"
PROJ="C:/Users/赖文钊/Documents/cs-1"
OUT="D:/dev/cs1_web"

cd "$PROJ"

# 防呆：如果上一轮异常中断、project.godot 还留着 Web 补丁，就直接拿它当基线，
# 否则会把「已打补丁」误当成原始配置备份下来，越导越偏（踩过一次）。
if grep -q 'renderer/rendering_method="gl_compatibility"' project.godot; then
	echo "!! 检测到 project.godot 仍是 Web 补丁状态，先还原成桌面配置"
	sed -i 's|^renderer/rendering_method="gl_compatibility"$||' project.godot
	sed -i 's|^3d/physics_engine="GodotPhysics3D"$|3d/physics_engine="Jolt Physics"|' project.godot
fi

cp project.godot project.godot.webbak
# 无论中间哪一步失败，都要把 project.godot 还原回去
trap 'mv -f project.godot.webbak project.godot 2>/dev/null; echo "=== 已还原 project.godot（含异常退出） ==="' EXIT

echo "=== 1/3 先导入（让编辑器把该写回的都写回） ==="
"$GODOT" --headless --path "$PROJ" --import 2>&1 | tail -3

echo "=== 2/3 打 Web 兼容补丁 ==="
python - "$PROJ/project.godot" <<'PY'
import sys, io, re
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
s = s.replace('3d/physics_engine="Jolt Physics"',
              '3d/physics_engine="GodotPhysics3D"')
if 'renderer/rendering_method' not in s:
    s = s.replace('[rendering]\n',
                  '[rendering]\n\nrenderer/rendering_method="gl_compatibility"\n')
# 导出预设排除了 addons/*，但 --export 阶段编辑器会启动并加载 godot_mcp 插件，
# 插件在内存里把 MCPRuntimeProbe autoload 加回来（改文件没用），所以这里把插件
# 和 autoload 一起去掉，否则启动报 "Failed to instantiate an autoload"。
s = re.sub(r'^MCPRuntimeProbe=.*\r?\n', '', s, flags=re.M)
s = s.replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")',
              'enabled=PackedStringArray()')
# 3D MSAA 改成 0 —— 网页版按「性能优先」。
#   Godot 4.3 起（PR #83976）Compatibility 渲染器**也**支持 3D MSAA 了，
#   所以项目里为桌面版开的 4× 会实打实落到网页版上，而网页版本来就是
#   single-threaded wasm，再叠 MSAA 只会更卡。桌面版仍走项目里的 4×。
s = re.sub(r'^anti_aliasing/quality/msaa_3d=\d+$',
           'anti_aliasing/quality/msaa_3d=0', s, flags=re.M)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('已切换 GodotPhysics3D + gl_compatibility，移除 MCPRuntimeProbe autoload，并关掉 3D MSAA')
PY

# 不删目录：目录里已有 50+ 文件，一次性删除会触发批量删除确认；导出本来就会覆盖 index.*
mkdir -p "$OUT"

echo "=== 3/3 导出 Web ==="
"$GODOT" --headless --path "$PROJ" --export-release "Web" 2>&1 | tail -6

# 还原，保证本机桌面版不受影响（trap 也会兜底，这里提前做一次以便后面读 pck）
mv -f project.godot.webbak project.godot
trap - EXIT
echo "=== 已还原 project.godot ==="
python - <<'PY'
import io
d = io.open(r'D:/dev/cs1_web/index.pck','rb').read()
print('pck 内残留 autoload:', b'MCPRuntimeProbe' in d, '| 大小 KB:', len(d)//1024)
PY
ls -la "$OUT"
