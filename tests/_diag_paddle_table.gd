## 一次性诊断：站立 + 低头 → 球拍会不会穿进球台台面。
##
## ★ 为什么不直接跑 pingpong.tscn：那个场景根上挂着 pingpong_game.gd，
##   它每帧会摆位、发球、判定，变量太多；这里只搭出**与 tscn 逐字一致**
##   的玩家三级链（Player@(0,0.9,z) → Head@(0,0.62,0) → Camera3D → PaddleRig），
##   再把 Head 的俯仰手动设成各个角度，量的就是纯几何。
## ★ 不挂 camera_controller：它会按 _pitch_floor_deg() 夹角度，而站立时
##   台面上方 h=0.76 > table_guard_band(0.62)，夹出来就是 pitch_min=-89°，
##   也就是说玩家**真的**能把视线压到底。这里直接设角度更直观。
##
## 用法：Godot --headless --path . tests/_diag_paddle_table.tscn
extends Node

const PADDLE_SCRIPT := "res://paddle_viewmodel.gd"
## 台面顶（与 pingpong_ball.table_height / camera_controller.table_top_y 同值）
const TABLE_TOP_Y := 0.760
const TABLE_HALF_X := 0.7625
const TABLE_HALF_Z := 1.37

var _rig: Node3D
var _head: Node3D
var _player: CharacterBody3D


func _ready() -> void:
	_build()
	await get_tree().process_frame
	await get_tree().process_frame
	print("PaddleRig 就绪：_paddle=%s  _head=%s"
		% [str(_rig.get("_paddle")), str(_rig.get("_head"))])
	await _sweep("站立", 0.685, 0.0)
	await _sweep("站立+探拍", 0.685, 1.0)
	get_tree().quit(0)


func _build() -> void:
	_player = CharacterBody3D.new()
	_player.name = "Player"
	_player.position = Vector3(0.0, 0.9, 0.685)
	add_child(_player)

	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, 0.62, 0.0)
	_player.add_child(_head)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	_head.add_child(cam)

	var rig: Node3D = (load(PADDLE_SCRIPT) as GDScript).new()
	rig.name = "PaddleRig"
	cam.add_child(rig)
	_rig = rig


func _sweep(label: String, z: float, reach: float) -> void:
	_player.position = Vector3(0.0, 0.9, z)
	_rig.call("set_reach_extend", reach)
	print("")
	print("════ %s :  player.z=%.3f  探拍=%.1f  ════" % [label, z, reach])
	print("  %6s | %9s | %9s | %9s | %8s | %8s"
		% ["pitch°", "拍面中心y", "AABB最低y", "AABB最高y", "中心x", "中心z"])
	for deg: float in [0.0, -21.3, -40.0, -55.0, -70.0, -85.0, -89.0]:
		_head.rotation.x = deg_to_rad(deg)
		await get_tree().process_frame
		await get_tree().process_frame
		# set_reach_extend 会被 pingpong_game 每帧驱动，这里每轮补一次
		_rig.call("set_reach_extend", reach)
		await get_tree().process_frame
		var c: Vector3 = _rig.call("head_position")
		var ab := _world_aabb(_rig)
		var over_table := absf(c.x) <= TABLE_HALF_X and absf(c.z) <= TABLE_HALF_Z
		var verdict := "—"
		if ab.position.y < TABLE_TOP_Y:
			verdict = "★穿台" if over_table else "低于台面(台外)"
		print("  %6.1f | %9.4f | %9.4f | %9.4f | %8.4f | %8.4f   %s"
			% [deg, c.y, ab.position.y, ab.position.y + ab.size.y, c.x, c.z, verdict])


## 把整棵子树的 mesh 顶点**逐个变换到世界**再重新包一次 AABB。
## ★ 不能只把局部 AABB 的 position/size 变换一下 —— 那是错的（记忆坑 #30）：
##   旋转会让局部包围盒变「小」，量出来的最低点比真实值高。
func _world_aabb(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for ch: Node in cur.get_children():
			stack.append(ch)
		var mi := cur as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := mi.global_transform
		var a := mi.mesh.get_aabb()
		for i: int in range(8):
			var w: Vector3 = xf * a.get_endpoint(i)
			if first:
				out = AABB(w, Vector3.ZERO)
				first = false
			else:
				out = out.expand(w)
	return out
