# GTA6 PC 转译层 · CN 构建（8GB NVIDIA 优化）

<<<<<<< Updated upstream
## Quick start: how to run it
=======
# VIctory on NVIDIA · CN build (tuned for 8 GB NVIDIA cards)

> 本项目是 [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) 的个人中文化/8G 优化分支。
> 它把 Xbox Series 版 GTA6（v1.0.2.1）的官方可执行文件转译到 Windows PC 上运行。
> **仓库不含任何游戏文件**，你需要自备游戏转储（dump）。
>
> This is a personal Chinese-localised, 8 GB-tuned branch of
> [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA),
> a translation layer that runs your own dump of the Xbox Series build of
> GTA6 (v1.0.2.1) on Windows. **No game files are included.**

**中文** · [English](#english)　|　[详细使用说明](docs/CN-使用说明.md) · [Detailed usage](docs/EN-USAGE.md) · [更新日志](docs/CHANGELOG.md)

---

## 这个分支做了什么 / What this fork adds

| 功能 | 说明 |
| --- | --- |
| **全中文 F1 设置菜单** | 所有选项、提示、动作按钮均已汉化，用点阵字体内置渲染 |
| **双插帧后端** | ① AMD FSR 3（官方运行时，**2X**，通用）② DLSS-G（NVIDIA，**2X～6X**，40/50 原生，30/20 用包内 `dlssg_for_sm86` 插件） |
| **默认 Series S** | 系列 S 主机配置，帧数优先；F1 可切系列 X |
| **8G 显存调参** | `VICTORY_TEXTURE_MIP_DROP=0~3`、`VICTORY_CARD_WINDOWS_MB` 等已做成菜单项和启动脚本 |
| **设置不再丢** | 修复「保存并重启后帧生成又关了」「设置复原」：重启会带上插件/FSR 目录，自动在 exe 旁查找 |
| **依赖全内置** | Release 包内含 NVIDIA Streamline/DLSS（67MB）、AMD FSR 运行库、DLSS-G 插件，解压即用、无需再联网下载 |
| **上游同步** | 已合入上游 v2026.11.27 的 FSR 帧生成、启动提示、F1 预载着色器、NOT SET 显示、独立控制台重启等 |

**English**

| Feature | Notes |
| --- | --- |
| Fully Chinese F1 settings menu | Every item, hint and action translated; drawn with the bundled bitmap font |
| Two frame-generation backends | ① AMD FSR 3 (official runtime, **2x**, works on any RTX) ② DLSS-G (**2x–6x**, native on RTX 40/50, `dlssg_for_sm86` add-on for RTX 20/30) |
| Series S by default | Series-S console profile for frame rate; switch to Series X from the F1 menu |
| 8 GB VRAM tuning | `VICTORY_TEXTURE_MIP_DROP=0..3`, `VICTORY_CARD_WINDOWS_MB`, exposed as menu items and launch scripts |
| Settings that survive a restart | The "save and restart" path carries the add-on/FSR folders and finds them beside `victory.exe`, so frame generation stays on |
| All dependencies bundled | The release zips ship NVIDIA Streamline/DLSS (67 MB), the AMD FSR runtime and the DLSS-G add-on — no extra downloads |
| Upstream sync | Includes upstream v2026.11.27: FSR frame generation, the start notice, F1 shader preload, NOT SET rows, own-console restart |

---

## 下载 / Downloads

**稳定版 / Stable: [Releases](https://github.com/DKTTT/victory-nvidia-8gb/releases)**

| 文件 / Asset | 默认插帧 / Default FG | 适合 / For |
| --- | --- | --- |
| `GTA6-CN-8G-oldN-FSR-*.zip` | AMD FSR 3 · 2X（无需插件 / no add-on） | 20/30 系老 N 卡，通用 / RTX 20–30, universal |
| `GTA6-CN-8G-newN-FG-FSR-*.zip` | DLSS-G 原生（40/50）、FSR 3 可选 / native DLSS-G (40/50), FSR 3 selectable | 40/50 系，或 30 系想用多倍插帧 / RTX 40–50, or 30-series wanting 3x–6x |

> 每个包约 61 MB（解压约 121 MB），已含全部运行库。需要你自己的 GTA6 Xbox Series 转储（v1.0.2.1）。

> Each zip is about 61 MB (121 MB extracted) with every runtime bundled.
> You must supply your own dump of the Xbox Series build (v1.0.2.1).
>>>>>>> Stashed changes

---

## 快速开始 / Quick start

1. 下载并解压任意一个 zip（**整个文件夹**，不要只拿 exe）。
2. 双击 `启动.bat`（老 N 卡 = FSR 插帧；新 N 卡 = 原生 DLSS 帧生成）。
3. 想换档位：进游戏按 **F1** 打开菜单，方向键选择，左右修改，「立即保存并重启」生效。
4. 卡崩/白屏：先运行 `重置F1设置(卡崩时用).bat`，再启动。

**English**

1. Download and extract a zip (the **whole folder**, not just the exe).
2. Double-click `启动.bat` (old-N cards = FSR frame generation; new-N = native DLSS frame generation).
3. Press **F1** in game for the settings menu; arrows to navigate, left/right to change, then "立即保存并重启" (save and restart now).
4. If it crashes, run `重置F1设置(卡崩时用).bat` first, then start again.

> ⚠️ **必须用 bat 启动**：bat 会把存档目录指向 `E:\gta6\work\perf-data`（或包内回退路径）。
> 直接双击 `victory.exe` 会使用 `%LOCALAPPDATA%\victory\data`，看起来像"存档丢了"。
>
> ⚠️ **Launch with the .bat**: it points the save folder at the configured path.
> Double-clicking `victory.exe` directly uses `%LOCALAPPDATA%\victory\data`, which looks like a lost save.

---

## 包内文件 / What's in the zip

| 文件 / File | 作用 / Purpose |
| --- | --- |
| `启动.bat` | 默认启动（老 N = FSR / 新 N = 原生 DLSS）/ default launcher |
| `启动-多倍插帧(DLSS-G).bat` | DLSS-G 插件，2X～6X / DLSS-G add-on, 2x–6x |
| `启动-FSR插帧.bat` | FSR 3，2X / FSR 3, 2x |
| `启动-不插帧(最稳).bat` | 关闭帧生成，最稳 / frame generation off |
| `启动-8G平衡.bat` | FSR 2X + 少一级 mip + 显存窗口 / FSR 2x + mip drop + card window |
| `预热.bat` | 预先编译着色器 / pre-translate shaders |
| `重置F1设置(卡崩时用).bat` | 清空已保存的 F1 设置 / clear the saved F1 settings |
| `victory.exe` | 转译层本体 / the layer itself |
| `nvidia-sdk/` | NVIDIA Streamline + DLSS 运行库 / NVIDIA runtimes |
| `amd-sdk/` | AMD FidelityFX FSR 3 运行库 / AMD FSR runtime |
| `dlssg-sm86/` | DLSS-G 多倍插帧插件（30/20 系）/ DLSS-G add-on for RTX 20/30 |

---

## F1 菜单速查 / F1 menu reference

| 菜单项 / Item | 含义 / Meaning |
| --- | --- |
| DLSS | 超分档位：画质 / 均衡 / 性能 / DLAA(原生) / 关 |
| 帧生成 | 关 / 2X / 3X / 4X / 5X / 6X（选择 FSR 后端时最多 2X） |
| 帧生成类型(重启) | 自动 / DLSS / FSR 3(老卡)，切换后需重启生效 |
| 帧率上限 | 无 / 120 / 60 / 30(游戏) |
| 顶部帧率 | 开 / 关（左上角 FPS 行） |
| 状态面板(F3) | 开 / 关（F3 诊断面板） |
| 全屏(无边框) / 鼠标捕获 / 英文键盘 | 窗口与输入选项 |
| 主机模式 | 系列 X / 系列 S(更快)，默认系列 S |
| 画面尺寸 | 2560x1440 / 1080p拉伸 / 3840x2160 |
| DLSS 模型 | 默认 / K / J / M / L（30 系推荐 K） |
| 纹理少 mip / 显存窗口 / 卡片步进 … | 8G 显存调参 |
| 动作 | 立即保存并重启 / 保存(下次启动) / 预载着色器(重启游戏) / 全部恢复默认 / 关闭 |

英文对照见 [docs/EN-USAGE.md](docs/EN-USAGE.md)。

---

## 存档与设置位置 / Save and settings locations

| 内容 / What | 路径 / Path |
| --- | --- |
| 存档 / Save | `E:\gta6\work\perf-data\7952987A`（bat 配置；直接跑 exe 时为 `%LOCALAPPDATA%\victory\data`） |
| F1 设置 / F1 settings | `%LOCALAPPDATA%\victory\victory-settings.txt`（所有构建共用 / shared by every build） |
| 日志 / Logs | `%LOCALAPPDATA%\victory\logs\victory-nvidia-play-*.log` |
| 着色器缓存 / Shader cache | bat 配置的 `CACHE_DIR`（默认 `E:\gta6\cache-vf-cn`） |

> 换构建不会丢存档，但**换存档目录会**。迁移时整个 `7952987A` 文件夹一起复制。
> Changing builds does not lose saves; changing the save folder does. Copy the whole `7952987A` folder when migrating.

---

## 常见问题 / Troubleshooting

| 现象 / Symptom | 原因 / Cause | 处理 / Fix |
| --- | --- | --- |
| 保存并重启后帧生成又关了 / FG off after save & restart | 旧版重启丢失插件/FSR 目录 / old restart dropped the add-on and FSR folders | 更新到本仓库最新版 / update to the latest build |
| 启动时崩在 Game Init / crash at Game Init | 保存的 F1 设置不兼容 / incompatible saved F1 settings | 运行 `重置F1设置(卡崩时用).bat` / run the reset bat |
| 存档"没了" / "lost" save | 直接双击了 exe / the exe was started directly | 用 bat 启动，或手动设 `VICTORY_DATA_DIR` / start via the bat or set `VICTORY_DATA_DIR` |
| 退出码 -2147483645 / exit code -2147483645 | `0x80000003` STATUS_BREAKPOINT：游戏内部断言（int3） / the title asserted (int3) | 记录场景与 `*.crash.log`，试 `重置F1设置` 或换回稳定版 / note the scene and crash log; reset settings or use the stable build |
| 退出码 -1073741819 / exit code -1073741819 | `0xC0000005` 访问冲突 / access violation | 附日志反馈 / report with logs |
| 帧生成显示"关"但设置没动 / FG shows off | 30/20 系需要 DLSS-G 插件、FSR 需要 `amd-sdk` / RTX 20/30 needs the add-on, FSR needs `amd-sdk` | 用包里对应的 bat，别只拷 exe / use the matching bat, keep the whole folder |
| TDR / 驱动重置 / driver reset | 显卡驱动超时 / driver timeout | 降低画面尺寸或 mip drop，更新驱动 / lower resolution or mip drop, update the driver |

---

## 性能建议 / Performance notes

- 这层是 **CPU 瓶颈**（转译 + 提交线程），帧生成（FSR 2X / DLSS-G 多倍）是提升"观感帧数"最有效的手段。
- 8 GB 显存：`纹理少 mip=1`（菜单「纹理少 mip」）通常是最佳平衡；爆显存再调到 2/3。
- 系列 S（默认）比系列 X 快；1080p 拉伸（`1080to1440`）比原生 1440p 快。
- FSR 3 只有 2X；要 3X-6X 只能 DLSS-G（30/20 系用插件，风险自负）。

**English**

- The layer is **CPU-bound** (translation + submission); frame generation (FSR 2x / DLSS-G multi-frame) is the most effective way to raise *perceived* frame rate.
- 8 GB VRAM: `TEXTURE MIP DROP = 1` is usually the sweet spot; raise to 2/3 only if you hit VRAM pressure.
- Series S (default) is faster than Series X; 1080p→1440p upscaling is faster than native 1440p.
- FSR 3 is 2x only; 3x–6x needs the DLSS-G path (RTX 20/30 via the add-on, at your own risk).

---

## 从源码构建 / Build from source

```powershell
git clone https://github.com/DKTTT/victory-nvidia-8gb.git
cd victory-nvidia-8gb
git checkout cn-f1          # 稳定版 / stable
cargo build --release -p victory
```

依赖（按需放入 `victory.exe` 旁边）/ runtimes (place beside `victory.exe`):

- NVIDIA：`nvidia-sdk\Streamline\bin\x64\`（`victory get-dlss` 可下载）/ NVIDIA Streamline DLLs
- AMD FSR：`amd-sdk\amd_fidelityfx_dx12.dll`（`Get-AMD-FSR.cmd` 可下载）/ AMD FidelityFX runtime

---

## 鸣谢 / Credits

- [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) — 上游转译层 / upstream layer
- [whiteh4cker-tr/VIctory_sm86](https://github.com/whiteh4cker-tr/VIctory_sm86) — DLSS-G SM86 支持与多项修复 / SM86 support and fixes
- [GPUOpen-LibrariesAndSDKs/FidelityFX-SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) — AMD FSR 运行时 / AMD FSR runtime
- `dlssg_for_sm86` 的作者与 CGBJ 项目的思路参考 / the `dlssg_for_sm86` author and the CGBJ project

## 免责声明 / Disclaimer

- 仓库**不包含任何 GTA6 游戏文件**，也不提供下载；请使用你自有的游戏转储。
- NVIDIA / AMD 运行库版权归各自所有者，仅用于本转译层的运行。
- 仅供个人备份与研究使用，请支持正版。

- **No game files are included or distributed.** Use your own dump.
- NVIDIA / AMD runtimes belong to their owners and are included only so the layer can run.
- For personal backup and research use only; buy the game.

---

<a id="english"></a>
# English

Short version of the same content; the full English guide is in [docs/EN-USAGE.md](docs/EN-USAGE.md).

**What it is.** A translation layer that runs your own dump of the Xbox Series
build of GTA6 (v1.0.2.1) on Windows 11 with an NVIDIA GPU. This fork adds a
fully Chinese F1 menu, Series S by default, 8 GB VRAM tuning, two frame-generation
backends (AMD FSR 3 at 2x, and NVIDIA DLSS-G at 2x–6x with the bundled add-on on
RTX 20/30), and fixes so settings survive a save-and-restart.

**Download and run.**

1. Grab a zip from [Releases](https://github.com/DKTTT/victory-nvidia-8gb/releases).
   `oldN-FSR` = FSR 3 by default; `newN-FG-FSR` = native DLSS-G by default.
2. Extract the whole folder and run `启动.bat` ("start").
3. Press **F1** in game for the settings menu.
4. If it crashes, run `重置F1设置(卡崩时用).bat` ("reset F1 settings") first.

**Notes.**

- Launch with the bat: it pins the save folder; a bare `victory.exe` uses
  `%LOCALAPPDATA%\victory\data` instead.
- Settings live in `%LOCALAPPDATA%\victory\victory-settings.txt`, logs in
  `%LOCALAPPDATA%\victory\logs\`.
- Exit code `-2147483645` (`0x80000003`) means the title asserted (int3);
  `-1073741819` (`0xC0000005`) is an access violation — both want the crash log.
- The layer is CPU-bound; frame generation is the biggest perceived-FPS win,
  and `TEXTURE MIP DROP = 1` is the usual 8 GB sweet spot.

<<<<<<< Updated upstream
**Tested, not assumed**

- Every pull request sent here was read line by line and, where it touched the
  game, built and run on this card before it was merged: ten so far.

Where each of these is today: this fork's own code in this tree is the F1
menu, the stats panel in every build, the water light switch, frame
generation from 2x to 6x with its live switching and memory handling, the
lifted frame rate cap, the frame rate line, the launcher and the NVIDIA file
fetcher. The foxhound line carries the descriptor slots, the
compares on the card, the interface plane and the face network in its own
form. The black-blob scrub, the graphics card picker and the ray-tracing
builder path are in this repository's history, and come over as this base
turns out to need them.

### The base since 2026-11-26: foxhound

On 2026-11-26 this fork moved onto
[readmet3xt-lab/foxhound](https://github.com/readmet3xt-lab/foxhound)
(`02fc18a`, GPL-3.0-or-later). On the same PC it ran the same rooms at close to
twice the frame rate of what this fork had, at a higher resolution, so its
tree is now this one's, with its history kept, and this fork's own additions
are on top. What foxhound is and how it got there is in its own README, kept as
[docs/README-foxhound.md](docs/README-foxhound.md); its measurements are in
[docs/findings.md](docs/findings.md).

What foxhound brings:

- the Series X profile at a native 2560x1440;
- DLSS Super Resolution and DLSS Frame Generation through NVIDIA Streamline,
  loaded when the game runs (nothing of NVIDIA's is needed to build);
- an estimate of indirect light and of reflections in place of the title's ray
  tracing, and fewer stalls at scene cuts.

What this fork has on top of it is under
[What this fork brings](#what-this-fork-brings) above.

## Where it stands

Tested on one PC: Windows 11, Ryzen 7 9800X3D, 64 GB RAM, **GeForce RTX 5070
12 GB**; the title's Xbox Series build v1.0.2.1, Series X profile, 2560x1440
output, DLSS Quality. Frame rates are the layer's own count, in the opening
rooms.

| | |
|---|---|
| Opening rooms | mostly 26-30 frames a second rendered (33-38 ms a frame) |
| Frame generation | 2x to 6x on top of that: by Streamline's own count, exactly 2, 4 and 6 frames shown for each one rendered |
| Device losses, crashes | none in the measured runs |
| Before this base (Series S, 720p to 1080p by DLSS) | 15-17 frames a second in the same rooms |

foxhound's own measurements, on an RTX 4070 SUPER, are in its README.

What is known to be wrong:

- **No ray tracing.** The title's own is off (`VICTORY_BVH_BUILDER=1`, or the
  menu's RAY TRACING, turns it on: slow and with a broken picture on this
  base). An estimate stands in for indirect light and reflections.
- **Frame generation needs room in the card's memory.** The layer fills the
  card with textures up to its budget; with frame generation on from the start
  the launcher holds a fifth of the budget back (a little less while it is only
  ready), so a few more textures can come late. Switched on from the menu on a
  full 12 GB card it can still say that memory is past the budget; it then
  runs, perhaps unevenly.
- **Frames are only generated while the game's window has the focus**, and
  about a second passes after a change before they come.
- **The first run of every new build stutters** while the driver compiles
  pipelines (foxhound's README, *Warming up*, says how to make them ahead).
- "SAVE AND RESTART NOW" can leave the old game's process behind without a
  window; it goes when the PC restarts.
- What foxhound lists as wrong (the heat-haze pass left out, hitches in
  cutscenes) applies here too.

## How to run it

You need Windows 10 or 11 (x64), a CPU with AVX2, 32 GB of RAM or more, an
SSD, an NVIDIA GeForce RTX card with a recent driver (RTX 40 or later for frame
generation, with hardware-accelerated GPU scheduling on; more than 2x needs an
RTX 50), [Rust](https://rustup.rs) (the toolchain is pinned), the Visual Studio
Build Tools with "Desktop development with C++", and **your own dump** of the
title's Xbox Series build v1.0.2.1 (the folder with
`game_scarlett_master.exe`).

```powershell
git clone https://github.com/trustno1-coder/VIctory-NVIDIA
cd VIctory-NVIDIA
copy victory.example.toml victory.toml      # then set game_dir to your dump's folder, outside this one
.\Get-NVIDIA-DLSS.cmd                        # once: NVIDIA's DLSS and frame generation files, about 70 MB
scripts\play-nvidia.ps1 -Exe 'D:\Games\MyDump\game_scarlett_master.exe'
```

The first start builds the layer (a few minutes). `Get-NVIDIA-DLSS.cmd` gets
NVIDIA's files from
[NVIDIA-RTX/Streamline](https://github.com/NVIDIA-RTX/Streamline) into
`nvidia-sdk\` (git-ignored). They are NVIDIA's, under NVIDIA's licences, which
are saved beside them; this repository does not carry them and may not. Nothing
is downloaded unless you run that file; `VICTORY_STREAMLINE_DIR` names another
folder if you have the Streamline SDK already.

`scripts\play-nvidia.ps1` is `scripts\play-foxhound.ps1` under the name this
fork has always had; its options:

| Option | What |
|---|---|
| *(none)* | Series X profile, 2560x1440, DLSS Quality, no frame rate cap, frame generation ready but off |
| `-FrameGen`, `-FrameGenX 4` | frame generation on from the start, 2 to 6 frames shown for each one rendered |
| `-Dlss off` / `dlaa` / `balanced` / `performance` | the title's own upscaling, or another DLSS mode |
| `-Fps 60` | a frame rate cap (30 is the title's own) |
| `-SeriesS` | the Series S profile: 1280x720 inside, faster, softer |
| `-Res 1080to1440` / `4k` | scene at 1080p upscaled by the title / the stock 3840x2160 output |
| `-NoFrameGenReady` | frame generation only with `-FrameGen` (it is otherwise made ready at every start, so the menu can switch it) |
| `-Build diag` | the diagnostics build (slower; captures, timelines, recording time in the F3 panel) |
| `-More @{VICTORY_X='1'}` | add or override any switch |

What the F1 menu saved (`victory-settings.txt`) goes over these at every start;
delete that file to go back to them. Full screen: start the game, then run
`.\scripts\fullscreen.ps1` in another window. Logs go to
`%LOCALAPPDATA%\victory\logs`, saves to `%LOCALAPPDATA%\victory\data`.

## How it works, and the findings

- [docs/README-foxhound.md](docs/README-foxhound.md): foxhound's own README
  (set-up by hand, warming up, its switches).
- [docs/architecture.md](docs/architecture.md): the layer's parts.
- [docs/findings.md](docs/findings.md): measurements behind the choices.
- [docs/dlss.md](docs/dlss.md): DLSS and Frame Generation.
- [docs/fsr-framegen.md](docs/fsr-framegen.md): selectable FSR 3.1 frame-generation prototype (including RTX 30), with DLSS upscaling.
- [docs/fork-ray-tracing.md](docs/fork-ray-tracing.md): the title's ray tracing
  and the light estimate.
- [docs/asset-policy.md](docs/asset-policy.md): what may and may not be in this
  repository.

## Credits

A tree of other people's work with a little on top; the history is kept.

- **[foxhound](https://github.com/readmet3xt-lab/foxhound)** by
  readmet3xt-lab: the base of this fork since 2026-11-26, and through it:
- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its
  contributors: the loader, the runtime services, the Direct3D 12 back end and
  the shader recompiler.
- **[fxceless/victory-fork](https://github.com/fxceless/victory-fork)**,
  **[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)**,
  **[codec-d/cool_fox](https://github.com/codec-d/cool_fox)**,
  **[DexNom/VIctory](https://github.com/DexNom/VIctory)**,
  **[Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD)**
  and the others foxhound's README names.
- Everyone who sent pull requests to this fork before the move; that work is
  in the history, on the branch that was `main` until then.
- NVIDIA Streamline, DLSS and Reflex are NVIDIA's; they are loaded at run time
  from a folder you supply.
- Much of this fork's code was written with
  [Claude Code](https://claude.com/claude-code).

## License

GPL-3.0-or-later, as VIctory and foxhound. See [LICENSE](LICENSE); the one file
that is not covered is named in [docs/asset-policy.md](docs/asset-policy.md).
=======
**Credits.** Upstream [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA);
SM86 fixes by [whiteh4cker-tr/VIctory_sm86](https://github.com/whiteh4cker-tr/VIctory_sm86);
FSR runtime from AMD's FidelityFX SDK; DLSS-G add-on by its respective author.
No game files are included or distributed.
>>>>>>> Stashed changes
