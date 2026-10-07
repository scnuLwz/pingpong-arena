# 乒乓竞技场（PingPong Arena）

> **⬇ [下载 Windows 版 · 51.7 MB · 免安装](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena-win64.zip)**
> —— 解压后双击 `pingpong-arena.exe` 即玩。

Godot 4.7.2 的第一人称乒乓球游戏。持球、对打、发球解算、AI 调度、联赛与排位、
球拍抽卡、10 个形态各异的场馆 —— 全部由 GDScript 生成，场景零手工拖拽。

## ⬇ 下载玩（Windows 64 位）

不想折腾源码？直接下打包好的版本：**绿色免安装**，解压双击就玩。

| 文件 | 大小 | 说明 |
|---|---|---|
| **[pingpong-arena-win64.zip](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena-win64.zip)** | 51.7 MB | **推荐** —— 解压后双击 `pingpong-arena.exe` |
| [pingpong-arena.exe](https://github.com/scnuLwz/pingpong-arena/releases/latest/download/pingpong-arena.exe) | 150.3 MB | 单文件，免解压，直接双击运行 |

> **2026-10-07 更新**：球台与观众模型减面（一帧三角面 −89%），安装包随之变小；
> 击球 / 弹台音效换回早先的合成音（更干净、延迟更低）。
> 同时 **网页版已下线** —— 请下载下方桌面版；源码仍然开源，想自己导出可以按本文件的说明来。
> **2026-10-06 更新**：修掉了旧版本「进得了主菜单、点开始比赛没反应」的问题。
> 详见 [Release 说明](https://github.com/scnuLwz/pingpong-arena/releases/latest)。

### ⚠️ 首次运行会被 Windows 拦一下 —— 点两下就能过

```
   ┌────────────────────────────────────────────────────┐
   │   Windows 已保护你的电脑                            │
   │   Microsoft Defender SmartScreen 阻止了...          │
   │                                                    │
   │   [ 不运行 ]                    [ 更多信息 ]  ← ①  │
   └────────────────────────────────────────────────────┘
                                          [ 仍要运行 ]  ← ②
```

1. 先点「**更多信息**」（点完会多出一个按钮）
2. 再点「**仍要运行**」—— 游戏就开了

> **只点「不运行」或者把窗口关掉，是打不开的**，很容易以为程序坏了。
> 为什么会这样：程序没有购买代码签名证书（一年几百美元），而**没签名的 exe
> 只要是从网上下载的，Windows 就会一律先拦一下** —— 这是规矩，跟程序本身有没有
> 问题是两回事。源码全部开源、下载页贴了 SHA-256 校验值，你可以自己核对。
>
> 点完「更多信息」没冒出「仍要运行」按钮？照着下面排查 ↓

<details>
<summary><b>照做了还是打不开 / 没有「仍要运行」按钮 —— 点这里（按顺序试）</b></summary>

1. **先解压再运行** —— 别在压缩包预览窗口里直接双击 exe。先把整个 zip 完整解压到
   一个真实文件夹（比如 `D:\游戏\乒乓竞技场\`），再从文件夹里双击 `pingpong-arena.exe`。
2. **检查文件有没有被「锁定」** —— 右键 `pingpong-arena.exe` → 属性 →
   看最下面有没有「**解除锁定 / 取消阻止**」的勾选框。有就打勾 → 确定 → 再双击。
3. **别从 U 盘 / 网络盘 / 同步盘里运行** —— 先复制到本地硬盘（桌面或 D 盘）再跑。
4. **被安全软件误报拦了** —— 少数杀软（尤其国产的）会误报引擎打包出来的程序。
   加进信任 / 白名单，或临时关掉防护再运行一次。
5. **还是不行** —— 把报错窗口截图发 issue，看到具体文案就能判断是哪一类。

</details>

**另外两条**

- **必须用电脑**：键盘 + 鼠标操作，手机玩不了。
- Windows 10/11 64 位。原生 **Forward+ 渲染 + 4× MSAA + Jolt 物理** ——
  就是开发机上按 F5 那一套，不打任何折扣。

存档在 `%APPDATA%\Godot\app_userdata\cs1\profile.json`；
完整说明与 SHA-256 见 [Releases](https://github.com/scnuLwz/pingpong-arena/releases/latest)。

## 跑起来（从源码）

```bash
# 桌面版
Godot_v4.7.2-stable_mono_win64.exe --path .
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
bash tests/verify_export.sh                            # 验桌面版 exe
```

`export_presets.cfg` 的 `exclude_filter` 是**硬排除**、会切断依赖链，而主菜单只用到
字体和音频 —— 所以「主菜单正常但进不去比赛」这类问题必须靠这道检查兜住。

## 素材授权

音效（`audio/`）来自 [BigSoundBank](https://bigsoundbank.com)（Joseph SARDIN），
**CC0 1.0 / 可商用免署名**；`nailong_laugh.mp3` 来自奶龙页内联音频。详见
`audio/CREDITS.txt`。字体子集取自 Noto Sans SC（OFL 1.1）。
