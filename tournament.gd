class_name Tournament
extends RefCounted
## 赛事（比赛模式）的纯数据模型 —— 32 人 / 8 组 / 小组赛→16强→8强→4强→决赛 / 每场 5 局 3 胜。
##
## 为什么单独一个文件、而且全是 static：
##   它是**纯函数**——输入一个赛事字典，输出新的赛事字典，自己不持有任何状态。
##   这样 game_state.gd 只负责「把这个字典塞进 profile.json」，
##   而赛程推进、对手模拟、排名统计这些逻辑全部可以脱离场景单独测（_tmp_tour 就是这么验的）。
##
## 数据形状（整份塞进存档）：
##   {
##     "seed": int,                  # 抽签随机种子（重开一届时换）
##     "stage": String,              # group / r16 / qf / sf / f / done
##     "group_round": int,           # 小组赛打到第几轮（0..2）
##     "entrants": [                 # 32 个人，下标就是 id
##        {"name": String, "rating": float, "player": bool}, ...
##     ],
##     "groups": [ [id,id,id,id] x8 ],
##     "matches": [                  # 所有已发生 / 待发生的比赛，一场一条
##        {"stage": "group"/"r16"/…, "group": int(-1=淘汰赛),
##         "a": id, "b": id, "sa": int, "sb": int, "done": bool},
##     ],
##     "out": bool,                  # 玩家是否已被淘汰
##     "place": int,                 # 玩家名次（1..32，未结束时 0）
##     "history": [ String ]         # 逐条战报，给 UI 的「数据」页用
##   }
##
## 名次怎么给：淘汰赛按「打到哪一轮」定档（决赛 1~2、4强 3~4、8强 5~8、16强 9~16、
## 小组未出线 17~32），同档内按小组赛胜场排。这样 32 个人人人有名次。

const SIZE := 32
const GROUP_COUNT := 8
const GROUP_SIZE := 4
const WIN_TARGET := 3        # 5 局 3 胜

## 段位表：key 是 stage，值给 UI 用
const STAGES := ["group", "r16", "qf", "sf", "f", "done"]
const STAGE_NAMES := {
	"group": "小组赛", "r16": "16 强", "qf": "8 强",
	"sf": "4 强", "f": "决赛", "done": "已结束",
}
## 每个淘汰轮的分组大小
const KO_SIZE := {"r16": 16, "qf": 8, "sf": 4, "f": 2}
const KO_NEXT := {"r16": "qf", "qf": "sf", "sf": "f", "f": "done"}

## 32 个 AI 选手名。都用「姓 + 名」，混一点外协选手，读起来像一份真的参赛名单。
const AI_NAMES := [
	"陈子墨", "林书航", "周昱衡", "吴柏霖", "郑一鸣", "何思远", "许承宇", "蔡嘉树",
	"高砚齐", "罗允辰", "梁慕白", "谢书宁", "韩砺锋", "彭亦然", "范知非", "邓可谦",
	"苏牧云", "蒋启元", "曹与真", "杜桓宇", "唐砚舟", "袁朗川", "石亦寒", "傅照野",
	"孟星阑", "严青梧", "钟雨珩", "崔景明", "白予安", "龚澈", "沈砚初", "陆怀瑾",
]


# ───────────────────────── 建赛 ─────────────────────────
## 抽签 + 分组。player_name / player_rating 把你塞进 32 人名单里（默认 id = 0 那一位随机）。
static func create(seed_value: int, player_name: String = "你",
		player_rating: float = 1020.0) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# 32 个 AI：评分在 900~1300 之间铺开，18 号种子最强（顺序就是种子序）
	var entrants: Array = []
	for i in SIZE:
		entrants.append({
			"name": AI_NAMES[i % AI_NAMES.size()],
			# 种子越靠前越强：i=0 → 1300，i=31 → 900
			"rating": 1300.0 - 400.0 * float(i) / float(SIZE - 1),
			"player": false,
		})

	# 玩家替换掉一个中游种子位（第 12 位），保证前期不会撞上最强的几个
	var pid := 11
	entrants[pid] = {"name": player_name, "rating": player_rating, "player": true}

	# 蛇形分档后打乱：先按种子分成 8 档，每档 4 人，再在档内洗牌，
	# 然后每档各一人进一个组 —— 这样 8 个组实力均衡，不会出现「死亡之组」。
	var ids: Array = []
	for i in SIZE:
		ids.append(i)
	var groups: Array = []
	for g in GROUP_COUNT:
		groups.append([])
	for band in GROUP_SIZE:
		var slice: Array = []
		for k in GROUP_COUNT:
			slice.append(ids[band * GROUP_COUNT + k])
		_shuffle(slice, rng)
		for g in GROUP_COUNT:
			(groups[g] as Array).append(slice[g])

	return {
		"seed": seed_value,
		"stage": "group",
		"group_round": 0,
		"entrants": entrants,
		"groups": groups,
		"matches": _make_group_matches(groups),
		"out": false,
		"place": 0,
		"history": ["抽签完成：32 人分入 8 个小组，每组 4 人循环，前 2 名进入 16 强。"],
	}


## 4 人小组的循环赛程（轮转法），3 轮每轮 2 场
static func _make_group_matches(groups: Array) -> Array:
	var out: Array = []
	for g in groups.size():
		var grp: Array = groups[g]
		var order := [[0, 1, 2, 3], [0, 2, 3, 1], [0, 3, 1, 2]]
		for r in 3:
			var o: Array = order[r]
			out.append({"stage": "group", "group": g, "round": r,
				"a": grp[o[0]], "b": grp[o[1]], "sa": 0, "sb": 0, "done": false})
			out.append({"stage": "group", "group": g, "round": r,
				"a": grp[o[2]], "b": grp[o[3]], "sa": 0, "sb": 0, "done": false})
	return out


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# ───────────────────────── 查询 ─────────────────────────
static func player_id(t: Dictionary) -> int:
	var es: Array = t["entrants"]
	for i in es.size():
		if bool((es[i] as Dictionary).get("player", false)):
			return i
	return -1


static func name_of(t: Dictionary, id: int) -> String:
	var es: Array = t["entrants"]
	if id < 0 or id >= es.size():
		return "—"
	return str((es[id] as Dictionary)["name"])


static func rating_of(t: Dictionary, id: int) -> float:
	var es: Array = t["entrants"]
	if id < 0 or id >= es.size():
		return 0.0
	return float((es[id] as Dictionary)["rating"])


static func stage_name(s: String) -> String:
	return str(STAGE_NAMES.get(s, s))


## 玩家接下来要打的那一场（没有就返回空字典）
static func next_match(t: Dictionary) -> Dictionary:
	var pid := player_id(t)
	if pid < 0 or bool(t.get("out", false)):
		return {}
	var st := str(t["stage"])
	if st == "done":
		return {}
	var r := -1 if st != "group" else int(t.get("group_round", 0))
	for m: Dictionary in t["matches"]:
		if bool(m["done"]):
			continue
		if str(m["stage"]) != st:
			continue
		if st == "group" and int(m.get("round", -1)) != r:
			continue
		if int(m["a"]) == pid or int(m["b"]) == pid:
			return m
	return {}


## 某人在某张小组的排名表 [{id, w, l, pts, diff}]
static func group_table(t: Dictionary, g: int) -> Array:
	var grp: Array = (t["groups"] as Array)[g]
	var rows: Array = []
	for id in grp:
		var w := 0
		var l := 0
		var diff := 0
		for m: Dictionary in t["matches"]:
			if not bool(m["done"]) or str(m["stage"]) != "group" or int(m.get("group", -1)) != g:
				continue
			if int(m["a"]) == int(id):
				diff += int(m["sa"]) - int(m["sb"])
				if int(m["sa"]) > int(m["sb"]):
					w += 1
				else:
					l += 1
			elif int(m["b"]) == int(id):
				diff += int(m["sb"]) - int(m["sa"])
				if int(m["sb"]) > int(m["sa"]):
					w += 1
				else:
					l += 1
		rows.append({"id": int(id), "w": w, "l": l, "pts": w, "diff": diff})
	rows.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if int(x["w"]) != int(y["w"]):
			return int(x["w"]) > int(y["w"])
		return int(x["diff"]) > int(y["diff"])
	)
	return rows


## 淘汰赛某一轮的对阵 [{a, b, sa, sb, done, winner}]
static func ko_round(t: Dictionary, stage: String) -> Array:
	var out: Array = []
	for m: Dictionary in t["matches"]:
		if str(m["stage"]) != stage:
			continue
		out.append(m)
	return out


## 8 个小组的出线名单（前 2）
static func qualifiers(t: Dictionary) -> Array:
	var out: Array = []
	for g in GROUP_COUNT:
		var tab := group_table(t, g)
		out.append(int((tab[0] as Dictionary)["id"]) if tab.size() > 0 else -1)
		out.append(int((tab[1] as Dictionary)["id"]) if tab.size() > 1 else -1)
	return out


## 最终名次表（1..32，顺序即名次）。未结束返回 []。
##
## 名次规则：淘汰赛的**出局轮次**定档 ——
##   冠军 1、亚军 2、半决赛败者 3~4、8 强败者 5~8、16 强败者 9~16、
##   小组未出线 17~32（按小组赛胜场排）。这样 32 个人人人有名次、且不重号。
##
## ★ 上一版是「先算档位再回填 base 游标」，结果决赛那一档把胜者和败者都写成
##   名次 1（base 在两个 append 之间只加了 1）。改成顺着签表铺一遍、最后统一编号，
##   逻辑短一半也不会串号。
static func standings(t: Dictionary) -> Array:
	if str(t["stage"]) != "done":
		return []
	var wins := {}
	for g in GROUP_COUNT:
		for r: Dictionary in group_table(t, g):
			wins[int(r["id"])] = int(r["w"])

	var rows: Array = []
	var placed := {}

	# 决赛：胜者 = 冠军，败者 = 亚军
	for m: Dictionary in ko_round(t, "f"):
		var w := int(m["winner"])
		var l := int(m["a"]) if w == int(m["b"]) else int(m["b"])
		rows.append({"id": w, "tier": "f"})
		placed[w] = true
		rows.append({"id": l, "tier": "f"})
		placed[l] = true

	# 半决赛 / 8 强 / 16 强：这些轮的**败者**依次是 3~4 / 5~8 / 9~16
	for st in ["sf", "qf", "r16"]:
		var losers: Array = []
		for m: Dictionary in ko_round(t, st):
			var w := int(m["winner"])
			var l := int(m["a"]) if w == int(m["b"]) else int(m["b"])
			if not placed.has(l):
				losers.append(l)
				placed[l] = true
		losers.sort_custom(func(x: int, y: int) -> bool:
			return int(wins.get(x, 0)) > int(wins.get(y, 0))
		)
		for l in losers:
			rows.append({"id": l, "tier": st})

	# 小组未出线的：按小组赛胜场排
	var rest: Array = []
	for i in SIZE:
		if not placed.has(i):
			rest.append(i)
	rest.sort_custom(func(x: int, y: int) -> bool:
		return int(wins.get(x, 0)) > int(wins.get(y, 0))
	)
	for id in rest:
		rows.append({"id": id, "tier": "group"})

	# 顺着铺好的顺序编号 1..32
	for i in rows.size():
		(rows[i] as Dictionary)["place"] = i + 1
	return rows


# ───────────────────────── 推进 ─────────────────────────
## 玩家把自己那一场打完了。player_won / player_lost 是局数（BO5，3 局为胜）。
## 返回一份摘要 {"stage", "player_won", "opponent", "out", "next"} 供 UI 提示。
static func report_player(t: Dictionary, player_won: int, player_lost: int) -> Dictionary:
	var pid := player_id(t)
	var m := next_match(t)
	if m.is_empty():
		return {}
	# 写进对局
	var a_is_player := int(m["a"]) == pid
	m["sa"] = player_won if a_is_player else player_lost
	m["sb"] = player_lost if a_is_player else player_won
	m["done"] = true
	m["winner"] = int(m["a"]) if int(m["sa"]) > int(m["sb"]) else int(m["b"])

	var opp := int(m["b"]) if a_is_player else int(m["a"])
	var opp_name := name_of(t, opp)
	var won := player_won > player_lost
	var st := str(t["stage"])
	var hist: Array = t["history"]
	# 小组赛说「胜 / 负」，淘汰赛才说「晋级 / 出局」—— 小组赛输一场并不回家。
	if st == "group":
		hist.append("小组赛第 %d 轮　你 %d - %d %s　%s"
			% [int(t.get("group_round", 0)) + 1, player_won, player_lost, opp_name,
			   "✓ 胜" if won else "× 负"])   # ✔/✘ 在 Noto Sans SC 里无字形（豆腐块），换成 ✓/×
	else:
		hist.append("%s　你 %d - %d %s%s"
			% [stage_name(st), player_won, player_lost, opp_name,
			   "　✓ 晋级" if won else "　× 出局"])   # 同上：✔/✘ 无字形

	# 把同轮其它场次一次性模拟掉
	_simulate_round(t, st, m)

	# ★ 小组赛是 4 人循环 3 轮，输一场不淘汰 —— 得打满 3 轮看排名取前 2。
	#   淘汰赛才是输一场就回家。
	if st == "group":
		t["group_round"] = int(t.get("group_round", 0)) + 1
	elif not won:
		t["out"] = true

	_advance_if_round_done(t)

	# ★ 小组赛打满 3 轮后签表会切到 16 强，这时才知道玩家有没有出线。
	var st2 := str(t["stage"])
	if not bool(t["out"]) and st2 != "group" and st2 != "done" and not _player_in_ko(t, st2):
		t["out"] = true
		hist.append("小组赛 3 轮战罢，你排名第 %d，未能出线。" % _group_rank(t))

	# ★ 玩家一旦出局就没有「下一场」了 —— 剩下的签表必须自动跑完，
	#   否则名次永远算不出来（standings 只在 stage=="done" 时才给结果）。
	if bool(t["out"]) and str(t["stage"]) != "done":
		_simulate_to_end(t)
		hist.append("你已出局，其余赛程已自动推演完毕。")

	return {"stage": st, "won": won, "opponent": opp_name,
			"player_won": player_won, "player_lost": player_lost,
			"out": bool(t["out"]), "next": next_match(t)}


## 把整届赛事剩下的比赛全部模拟掉并结算名次。
## 从任意阶段都能调（玩家在小组赛出局 / 在 8 强出局都走这里）。
static func _simulate_to_end(t: Dictionary) -> void:
	var guard := 0
	while str(t["stage"]) != "done" and guard < 24:
		guard += 1
		var st := str(t["stage"])
		if st == "group":
			for r in range(int(t.get("group_round", 0)), 3):
				t["group_round"] = r
				_simulate_stage_round(t, "group", r)
			t["group_round"] = 3
			_build_ko(t, "r16")
		else:
			_simulate_stage_round(t, st, -1)
			var nxt := str(KO_NEXT.get(st, "done"))
			if nxt == "done":
				t["stage"] = "done"
			else:
				_build_ko(t, nxt)
	t["stage"] = "done"
	t["place"] = _find_place(t, player_id(t))


## 把某阶段某一轮的待打比赛全模拟掉（round < 0 = 淘汰赛，不分轮）
static func _simulate_stage_round(t: Dictionary, stage: String, round: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(t.get("seed", 0)) * 7919 + t["matches"].size() * 104729 + round * 31 + 13
	for m: Dictionary in t["matches"]:
		if bool(m["done"]) or str(m["stage"]) != stage:
			continue
		if round >= 0 and int(m.get("round", -1)) != round:
			continue
		var sc := _simulate_bo5(t, int(m["a"]), int(m["b"]), rng)
		_play(t, m, int(sc[0]), int(sc[1]))


## 评级 → 胜率 → 逐局掷骰，凑出 5 局 3 胜的比分。返回 [a, b]。
## ★ 必须返回数组：GDScript 的 int 是值传递，写成出参（sa/sb）在调用方根本改不动。
static func _simulate_bo5(t: Dictionary, ida: int, idb: int,
		rng: RandomNumberGenerator) -> Array:
	var ra := rating_of(t, ida)
	var rb := rating_of(t, idb)
	# Elo 胜率：分差 400 分 → 约 10:1
	var p := 1.0 / (1.0 + pow(10.0, (rb - ra) / 400.0))
	var a := 0
	var b := 0
	while a < WIN_TARGET and b < WIN_TARGET:
		if rng.randf() < p:
			a += 1
		else:
			b += 1
	return [a, b]


## 把同一轮里还没打的比赛按评分模拟掉
static func _simulate_round(t: Dictionary, stage: String, mine: Dictionary) -> void:
	_simulate_stage_round(t, stage, int(mine.get("round", -1)))


static func _play(t: Dictionary, m: Dictionary, sa: int, sb: int) -> void:
	m["sa"] = sa
	m["sb"] = sb
	m["done"] = true
	m["winner"] = int(m["a"]) if sa > sb else int(m["b"])


## 一轮打完了就推进到下一阶段 / 下一轮
static func _advance_if_round_done(t: Dictionary) -> void:
	var st := str(t["stage"])
	if st == "group":
		# 本轮的 8 组 × 2 场都打完了吗
		var r := int(t.get("group_round", 0))
		var pending := false
		for m: Dictionary in t["matches"]:
			if str(m["stage"]) == "group" and int(m.get("round", -1)) == r and not bool(m["done"]):
				pending = true
				break
		if pending:
			return
		if r >= 2:
			_build_ko(t, "r16")
		return
	# 淘汰赛：本轮全打完 → 下一轮
	for m: Dictionary in t["matches"]:
		if str(m["stage"]) == st and not bool(m["done"]):
			return
	var nxt := str(KO_NEXT.get(st, "done"))
	if nxt == "done":
		t["stage"] = "done"
		t["place"] = _find_place(t, player_id(t))
		return
	_build_ko(t, nxt)


## 由小组排名 / 上一轮胜者搭出下一轮对阵
static func _build_ko(t: Dictionary, stage: String) -> void:
	if stage == "r16":
		# 种子位：1..8 = 各组第一，9..16 = 各组第二
		var seeds: Array = []
		for g in GROUP_COUNT:
			var tab := group_table(t, g)
			seeds.append(int((tab[0] as Dictionary)["id"]) if tab.size() > 0 else -1)
		for g in GROUP_COUNT:
			var tab := group_table(t, g)
			seeds.append(int((tab[1] as Dictionary)["id"]) if tab.size() > 1 else -1)
		# 标准 16 签位表：1v16 / 8v9 / 4v13 / 5v12 / 2v15 / 7v10 / 3v14 / 6v11
		# 这样 1、2 号种子最早只可能在决赛相遇，不会一上来就撞。
		var order := [1, 16, 8, 9, 4, 13, 5, 12, 2, 15, 7, 10, 3, 14, 6, 11]
		var i := 0
		while i + 1 < order.size():
			_append_ko(t, stage, int(seeds[int(order[i]) - 1]), int(seeds[int(order[i + 1]) - 1]))
			i += 2
	else:
		var prev := ""
		for k: String in KO_NEXT.keys():
			if str(KO_NEXT[k]) == stage:
				prev = k
				break
		var winners: Array = []
		for m: Dictionary in ko_round(t, prev):
			winners.append(int(m.get("winner", -1)))
		# 相邻胜者配对 —— 签位顺序天然保住了上下半区
		var j := 0
		while j + 1 < winners.size():
			_append_ko(t, stage, int(winners[j]), int(winners[j + 1]))
			j += 2
	t["stage"] = stage


static func _append_ko(t: Dictionary, stage: String, a: int, b: int) -> void:
	(t["matches"] as Array).append({
		"stage": stage, "group": -1, "round": -1,
		"a": a, "b": b, "sa": 0, "sb": 0, "done": false,
	})


static func _find_place(t: Dictionary, pid: int) -> int:
	for r: Dictionary in standings(t):
		if int(r["id"]) == pid:
			return int(r["place"])
	return 0


## 玩家在某个淘汰轮里还有比赛吗（用来判断小组赛结束后有没有出线）
static func _player_in_ko(t: Dictionary, stage: String) -> bool:
	var pid := player_id(t)
	if pid < 0:
		return false
	for m: Dictionary in ko_round(t, stage):
		if int(m["a"]) == pid or int(m["b"]) == pid:
			return true
	return false


## 玩家在自己那个小组里的名次（1..4，未开赛时给 4）
static func _group_rank(t: Dictionary) -> int:
	var pid := player_id(t)
	for g in (t["groups"] as Array).size():
		var tab := group_table(t, g)
		for i in tab.size():
			if int((tab[i] as Dictionary)["id"]) == pid:
				return i + 1
	return GROUP_SIZE


# ───────────────────────── 名次 / 奖励 ─────────────────────────
## 名次对应的金币奖励。冠军最多，小组赛出局也有安慰奖。
static func prize_for_place(p: int) -> int:
	if p <= 0:
		return 0
	if p == 1:
		return 2000
	if p == 2:
		return 1200
	if p <= 4:
		return 800
	if p <= 8:
		return 500
	if p <= 16:
		return 300
	return 150


static func prize_label(p: int) -> String:
	if p <= 0:
		return "—"
	if p == 1:
		return "冠军"
	if p == 2:
		return "亚军"
	if p <= 4:
		return "四强"
	if p <= 8:
		return "八强"
	if p <= 16:
		return "十六强"
	return "小组赛"
