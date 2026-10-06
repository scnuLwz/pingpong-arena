# 乒乓竞技场（PingPong Arena）

> **⬇ [下载 Windows 版 · 77.2 MB · 免安装](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena-win64.zip)**
> —— 解压后双击 `pingpong-arena.exe` 即玩。

Godot 4.7.2 的第一人称乒乓球游戏。持球、对打、发球解算、AI 调度、联赛与排位、
球拍抽卡、10 个形态各异的场馆 —— 全部由 GDScript 生成，场景零手工拖拽。

## ⬇ 下载玩（Windows 64 位）

不想折腾源码？直接下打包好的版本：**绿色免安装**，解压双击就玩。

| 文件 | 大小 | 说明 |
|---|---|---|
| **[pingpong-arena-win64.zip](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena-win64.zip)** | 77.2 MB | **推荐** —— 解压后双击 `pingpong-arena.exe` |
| [pingpong-arena.exe](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena.exe) | 173.7 MB | 单文件，免解压，直接双击运行 |

> **2026-10-06 更新**：修掉了旧版本「进得了主菜单、点开始比赛没反应」的问题，
> 请用本版本。详见 [Release 说明](https://github.com/scnuLwz/pingpong-arena/releases/latest)。

**开玩前读三条**

1. **首次运行会弹 SmartScreen 蓝框** —— 未签名程序的通病，不是病毒：
   点「**更多信息**」→「**仍要运行**」。
2. **必须用电脑**：键盘 + 鼠标操作，手机玩不了。
3. Windows 10/11 64 位。原生 **Forward+ 渲染 + 4× MSAA + Jolt 物理** ——
   就是开发机上按 F5 那一套；网页版受浏览器限制，画质是精简过的。

存档在 `%APPDATA%\Godot\app_userdata\cs1\profile.json`；
完整说明与 SHA-256 见 [Releases](https://github.com/scnuLwz/pingpong-arena/releases/latest)。

## 跑起来（从源码）

```bash
# 桌面版
Godot_v4.7.2-stable_mono_win64.exe --path .

# Web 导出（必须用**标准版** Godot，Mono 版不能导出 Web）
bash build_web2.sh          # → D:/dev/cs1_web
python -m http.server 8971 --bind 127.0.0.1
```

首次拉取后先跑一次导入，让 `.godot/` 生成（它不入库）：

```bash
Godot_v4.7.2-stable_mono_win64_console.exe --headless --path . --import
```

## 操作

| 键 | 作用 |
|---|---|
| 鼠标左键 | 反手挥拍（近台短球靠它） |
| 鼠标右键 | 正手推击（向前推，不往下压） |
| F | 挥拍（键盘等价键） |
| 按住空格 | 蓄力。**蓄满不会自动挥拍**，仍要按鼠标：左键 = 反手「暴拧」/ 右键 = 正手「爆冲」（更快更转，耗体力） |
| Z / C | **上旋 / 下旋**球开关（点按切换、再按取消；发球时同样吃这个状态） |
| WASD | 移动 |
| Shift | 冲刺 |
| Ctrl | 蹲下（省体力、回球更冲，但够不到近台短球） |
| V | 跳跃 |
| ↓ | 循环切换难度 |
| Q / R | 换握 / 探拍 |
| ← / → | 左右转头（鼠标被浏览器拒绝锁定时用） |
| Esc | 暂停 |

**发球**：先点左键抛球 → 球下落时再点左键击出（按住空格可蓄力加速；不点会自动打出去）。

正手「爆冲」（扣杀）只对**远台球**有效 —— 球得落在自己半台靠底线的位置，近网短球抡不起来（反手「暴拧」不受此限）。

## 结构

| 文件 | 行数 | 职责 |
|---|---|---|
| `pingpong_game.gd` | 6591 | 主控：球物理、击球、发球、AI 调度、判分、HUD |
| `game_state.gd` | 2756 | autoload `Game`：存档、金币、任务、排位、赛事、音频设置 |
| `main_menu.gd` | 2259 | 全部菜单面板（代码生成，无 `.tscn` 布局） |
| `court_builder.gd` | 1837 | 场馆生成：看台、桁架、观众、围栏、场边器材 |
| `tournament.gd` / `opponent_player.gd` | 545 / 537 | 赛程与对手 |
| `pingpong_audio.gd` | 568 | 三条分项（欢呼 / 嘲笑 / 人群底噪）独立开关与音量 |

**架构约定（改之前先读）**

- **「本局模式」旗标不落盘**：`doubles` / `ranked` / `tour_entry` 都只活在 `Game` 单例上，
  `_from_dict()` / `reset_all()` / `abandon_tournament()` 各清一次。
  读档必须回到自由对战。
- **玩家活动范围与场边家具是同一约束的两端**：`player_movement.gd` 定范围，
  `court_builder.gd` 有一份显式副本（`player_reach_*`），所有家具位置由它算出。
  改范围要同步这两个文件。
- **预测必须与真实物理跑同一套数值积分**：`serve_solve_dt` 必须等于 `_physics_process` 的
  步长（1/60）。曾经 1/120 vs 1/60 导致解算判「擦过」而物理撞网，发球白送一分。
- **新增中文文案后必须重跑字体子集**：字体是子集快照，缺字会显示豆腐块。
  工具见 `docs/` 说明。

## 文档

- [`docs/优化方案_2026-10-04.md`](docs/优化方案_2026-10-04.md) —— 难度表重构、
  拆分主控脚本、难度曲线重调的执行方案
- [`docs/perf/`](docs/perf/) —— 发球解算性能实测（`serve_perf_*.txt`）与
  旋球 / 球速标定数据（`spin_speed_data.txt`）

## 测试

回归探针覆盖发球解算、球物理、AI 调度、排位与任务、存档保护等，共 400 余项断言：

```bash
bash tests/run_regression.sh
```

跑之前会备份玩家存档、跑完逐字节比对，不一致即判定失败并还原
（探针若在离树实例上调 `reset_all()`，会拿默认档案覆盖真实存档且不报错）。

导出产物另有一道自检 —— 用引擎加载打好的包跑一遍关键场景，确认资源真的都进包了：

```bash
bash tests/verify_export.sh                            # 默认验桌面版 exe
bash tests/verify_export.sh D:/dev/cs1_web/index.pck   # 也可以验网页版
```

`export_presets.cfg` 的 `exclude_filter` 是**硬排除**、会切断依赖链，而主菜单只用到
字体和音频 —— 所以「主菜单正常但进不去比赛」这类问题必须靠这道检查兜住。

## 素材授权

音效（`audio/`）来自 [BigSoundBank](https://bigsoundbank.com)（Joseph SARDIN），
**CC0 1.0 / 可商用免署名**；`nailong_laugh.mp3` 来自奶龙页内联音频。详见
`audio/CREDITS.txt`。字体子集取自 Noto Sans SC（OFL 1.1）。
