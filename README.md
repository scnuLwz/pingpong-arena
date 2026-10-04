# 乒乓竞技场（PingPong Arena）

Godot 4.7.2 的第一人称乒乓球游戏。持球、对打、发球解算、AI 调度、联赛与排位、
球拍抽卡、10 个形态各异的场馆 —— 全部由 GDScript 生成，场景零手工拖拽。

## 跑起来

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
| 鼠标左键 / 右键 | 反手 / 正手挥拍 |
| 按住空格 | 蓄力，松开后打出「暴拧」/「爆冲」（更快更转，耗体力） |
| C | 蹲下（台内低球，抽不了） |
| Z | 点按切换视角预设 |
| Tab | 自由对战里循环切换难度 |
| Esc | 暂停 |

## 结构

| 文件 | 行数 | 职责 |
|---|---|---|
| `pingpong_game.gd` | 5286 | 主控：球物理、击球、发球、AI 调度、判分、HUD |
| `game_state.gd` | 2700 | autoload `Game`：存档、金币、任务、排位、赛事、音频设置 |
| `main_menu.gd` | 2121 | 全部菜单面板（代码生成，无 `.tscn` 布局） |
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

## 素材授权

音效（`audio/`）来自 [BigSoundBank](https://bigsoundbank.com)（Joseph SARDIN），
**CC0 1.0 / 可商用免署名**；`nailong_laugh.mp3` 来自奶龙页内联音频。详见
`audio/CREDITS.txt`。字体子集取自 Noto Sans SC（OFL 1.1）。
