extends Node
## 一次性渲染规模探针（**不是**回归组，不进 run_regression.sh）。
##
## 用法：Godot --headless --path . tests/_perf_render.tscn
##
## 为什么要有它：无头下渲染器是 dummy，Performance 的渲染计数器全是 0，
## 所以这里**不测时间**，只数**几何规模**（顶点 / 三角面 / 节点数）——
## 这些是纯数据统计，与渲染器无关，也正是 GPU 上最吃性能的量。
##
## ★ 只把 pingpong.tscn 里的 Court 子树摘出来单独入树，
##   根节点的 pingpong_game.gd 永远不 _ready（不会改存档、不会发球）。

const TABLE_RES := "res://models/table_clean.res"
const PADDLE_GLB := "res://models/paddle_lite.glb"
const SPECTATOR_GLB := "res://models/spectator.glb"


func _ready() -> void:
	print("================ 渲染规模统计 ================")
	_mesh_stats("球台 table_clean.res", TABLE_RES)
	_mesh_stats("球拍 paddle_lite.glb", PADDLE_GLB)
	_mesh_stats("观众 spectator.glb", SPECTATOR_GLB)

	print("\n──────── 场馆（Court 子树单独入树）────────")
	var ps := load("res://pingpong.tscn") as PackedScene
	if ps == null:
		print("  !! pingpong.tscn 加载失败")
		get_tree().quit(1)
		return
	var inst := ps.instantiate()
	var court := inst.get_node_or_null("Court")
	if court == null:
		print("  !! 找不到 Court 节点")
		get_tree().quit(1)
		return
	inst.remove_child(court)
	add_child(court)
	await get_tree().process_frame
	await get_tree().process_frame

	var tally := _walk(court)
	print("  节点总数            %6d" % tally["nodes"])
	print("  MeshInstance3D      %6d   ← 大致等于 draw call 数（未计剔除）" % tally["mi"])
	print("  MultiMeshInstance3D %6d（实例合计 %d）" % [tally["mmi"], tally["mmi_inst"]])
	print("  三角面合计          %6d" % tally["tris"])
	print("  按 mesh 去重的三角面 %6d" % tally["uniq_tris"])
	var cb := court as Node
	if cb != null and cb.has_method("crowd_count"):
		print("  观众人数            %6d" % int(cb.call("crowd_count")))
	print("  三角面前 12 名：")
	var arr: Array = tally["top"]
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["tris"]) > int(b["tris"]))
	for i in mini(12, arr.size()):
		var e: Dictionary = arr[i]
		print("    %10d 面  x%-4d  %s" % [int(e["tris"]), int(e["n"]), str(e["name"])])
	print("==============================================")
	get_tree().quit(0)


func _mesh_stats(label: String, path: String) -> void:
	print("\n── %s ──" % label)
	var r := load(path)
	if r == null:
		print("  加载失败")
		return
	if r is PackedScene:
		var n: Node = (r as PackedScene).instantiate()
		var t := _walk(n)
		print("  三角面 %d   MeshInstance3D %d   MultiMesh %d"
			% [t["tris"], t["mi"], t["mmi"]])
		var first := _find_mi(n)
		if first != null and first.mesh != null and first.mesh.get_surface_count() > 0:
			var arr: Array = first.mesh.surface_get_arrays(0)
			var names := ["VERTEX", "NORMAL", "TANGENT", "COLOR", "UV", "UV2",
				"CUSTOM0", "CUSTOM1", "CUSTOM2", "CUSTOM3", "BONES", "WEIGHTS", "INDEX"]
			var have: Array = []
			for i in mini(names.size(), arr.size()):
				if arr[i] != null:
					have.append(names[i])
			print("  表面 0 具备属性: %s" % str(have))
			var mat := first.mesh.surface_get_material(0) as BaseMaterial3D
			if mat != null:
				print("  材质 vertex_color_use_as_albedo = %s" % str(mat.vertex_color_use_as_albedo))
		n.free()
	else:
		var t := _mesh_tris(r as Mesh)
		print("  类型 %s   表面 %d   顶点 %d   三角面 %d"
			% [r.get_class(), t["surfaces"], t["verts"], t["tris"]])


func _mesh_tris(m: Mesh) -> Dictionary:
	var out := {"tris": 0, "verts": 0, "surfaces": 0}
	if m == null:
		return out
	out["surfaces"] = m.get_surface_count()
	for s in range(m.get_surface_count()):
		var arrays: Array = m.surface_get_arrays(s)
		if arrays.is_empty():
			continue
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		out["verts"] += v.size()
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.size() > 0:
			out["tris"] += idx.size() / 3
		else:
			out["tris"] += v.size() / 3
	return out


func _find_mi(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c: Node in n.get_children():
		var r := _find_mi(c)
		if r != null:
			return r
	return null


func _walk(root: Node) -> Dictionary:
	var out := {"nodes": 0, "mi": 0, "mmi": 0, "mmi_inst": 0, "tris": 0,
		"uniq_tris": 0, "top": []}
	var uniq := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		out["nodes"] += 1
		for ch: Node in cur.get_children():
			stack.append(ch)
		var mi := cur as MeshInstance3D
		if mi != null and mi.mesh != null:
			out["mi"] += 1
			var t := _mesh_tris(mi.mesh)
			out["tris"] += t["tris"]
			out["top"].append({"name": str(mi.name), "tris": t["tris"], "n": 1})
			var key := mi.mesh.get_instance_id()
			if not uniq.has(key):
				uniq[key] = t["tris"]
		var mmi := cur as MultiMeshInstance3D
		if mmi != null and mmi.multimesh != null:
			out["mmi"] += 1
			var n := mmi.multimesh.instance_count
			out["mmi_inst"] += n
			var t2 := _mesh_tris(mmi.multimesh.mesh)
			out["tris"] += t2["tris"] * n
			out["top"].append({"name": str(mmi.name) + " (MultiMesh)",
				"tris": t2["tris"] * n, "n": n})
			var key2 := mmi.multimesh.mesh.get_instance_id()
			if not uniq.has(key2):
				uniq[key2] = t2["tris"]
	for v: int in uniq.values():
		out["uniq_tris"] += v
	return out
