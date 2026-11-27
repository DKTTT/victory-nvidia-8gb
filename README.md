# GTA6 PC 转译层 · CN 构建（8GB NVIDIA 优化）
# VIctory on NVIDIA · CN build (tuned for 8 GB NVIDIA cards)

> 中文 · [English](#english) · [详细使用说明](docs/CN-使用说明.md) · [Detailed usage](docs/EN-USAGE.md) · [更新日志 / Changelog](docs/CHANGELOG.md)

本项目是 [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA) 的个人中文化 + 8G 优化分支。
它把 Xbox Series 版 GTA6（v1.0.2.1）的官方可执行文件转译到 Windows PC 上运行。
**仓库与发布包不含任何游戏文件**，你需要自备游戏转储（dump）。

This is a personal Chinese-localised, 8 GB-tuned branch of
[trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA),
a translation layer that runs your own dump of the Xbox Series build of
GTA6 (v1.0.2.1) on Windows. **No game files are included.**

---

## 这个分支做了什么 / What this fork adds

| 功能 Feature | 说明 Notes |
| --- | --- |
| **全中文 F1 菜单** | 所有选项、提示、动作按钮汉化（点阵字体内置渲染）/ fully Chinese F1 menu with the bundled bitmap font |
| **双插帧后端** | ① AMD FSR 3：官方运行时，**2X**，通用；② DLSS-G：**2X～6X**，40/50 原生，30/20 用包内 `dlssg_for_sm86` 插件 / two FG backends: FSR 3 at 2x, DLSS-G at 2x–6x |
| **默认 Series S** | 帧数优先；F1 可切系列 X / Series S default, Series X selectable |
| **8G 显存调参** | `VICTORY_TEXTURE_MIP_DROP=0~3`、显存窗口等做成菜单项与启动脚本 / 8 GB VRAM levers as menu items and scripts |
| **设置不再丢** | 修复「保存并重启后帧生成又关了」「设置复原」；重启会带上插件/FSR 目录并自动在 exe 旁查找 / settings survive save-and-restart |
| **依赖全内置** | 发布包内含 NVIDIA Streamline/DLSS（67MB）、AMD FSR 运行库、DLSS-G 插件，解压即用 / every runtime bundled, no downloads |
| **上游同步** | 已合入上游 v2026.11.27（启动提示、F1 预载着色器、NOT SET、独立控制台重启）与 sm86/PR 修复 / synced with upstream v2026.11.27 and sm86/PR fixes |

---

## 下载 / Downloads

**稳定版 Stable: [Releases](https://github.com/DKTTT/victory-nvidia-8gb/releases)**

| 文件 Asset | 默认插帧 Default FG | 适合 For |
| --- | --- | --- |
| `GTA6-CN-8G-oldN-FSR-*.zip` | AMD FSR 3 · 2X（无需插件 / no add-on） | 20/30 系，通用 / RTX 20–30, universal |
| `GTA6-CN-8G-newN-FG-FSR-*.zip` | 原生 DLSS 帧生成 (40/50)，FSR 3 可选 / native DLSS-G, FSR 3 selectable | 40/50 系，或 30 系想多倍 / RTX 40–50, or 30-series wanting 3x–6x |

每个包约 61 MB（解压约 121 MB），含全部运行库；需自备 Xbox Series v1.0.2.1 转储。
Each zip is ~61 MB (121 MB extracted) with all runtimes; bring your own v1.0.2.1 dump.

---

## 快速开始 / Quick start

1. 下载并解压**整个文件夹** / download and extract the **whole folder**
2. 双击 `启动.bat`（老 N = FSR 插帧；新 N = 原生 DLSS）/ double-click `启动.bat`
3. 进游戏按 **F1** 打开菜单，方向键选择、左右修改，「立即保存并重启」生效 / press **F1** in game
4. 崩溃时先运行 `重置F1设置(卡崩时用).bat` / run the reset-settings bat if it crashes

> ⚠️ **必须用 bat 启动**：bat 把存档指向 `E:\gta6\work\perf-data`；直接双击 `victory.exe` 会用 `%LOCALAPPDATA%\victory\data`，看起来像"存档丢了"。
> ⚠️ **Launch with the bat**: it pins the save folder; a bare `victory.exe` uses `%LOCALAPPDATA%\victory\data`.

---

## 包内文件 / What's in the zip

| 文件 File | 作用 Purpose |
| --- | --- |
| `启动.bat` | 默认启动（老 N = FSR / 新 N = 原生 DLSS） |
| `启动-多倍插帧(DLSS-G).bat` | DLSS-G 插件 2X～6X / add-on, 2x–6x |
| `启动-FSR插帧.bat` | FSR 3 2X |
| `启动-不插帧(最稳).bat` | 关闭帧生成 / FG off |
| `启动-8G平衡.bat` | FSR 2X + 少一级 mip + 显存窗口 |
| `预热.bat` | 预先编译着色器 / preload shaders |
| `重置F1设置(卡崩时用).bat` | 清空已保存的 F1 设置 / clear F1 settings |
| `victory.exe` | 转译层本体 / the layer |
| `nvidia-sdk/` `amd-sdk/` `dlssg-sm86/` | NVIDIA / AMD / DLSS-G 运行库与插件 / runtimes |

---

## F1 菜单速查 / F1 menu reference

| 菜单项 Item | 含义 Meaning |
| --- | --- |
| DLSS | 超分：画质 / 均衡 / 性能 / DLAA(原生) / 关 |
| 帧生成 FRAME GENERATION | 关 / 2X / 3X / 4X / 5X / 6X（FSR 后端最多 2X） |
| 帧生成类型 FRAME GEN TYPE | 自动 / DLSS / FSR 3(老卡)，切换需重启 / needs restart |
| 帧率上限 / 顶部帧率 / 状态面板(F3) | 帧率上限、FPS 行、F3 面板 / cap, FPS line, F3 panel |
| 全屏 / 鼠标捕获 / 英文键盘 | 窗口与输入 / window and input |
| 主机模式 CONSOLE | 系列 X / 系列 S(更快)，默认 S |
| 画面尺寸 PICTURE | 2560x1440 / 1080p拉伸 / 3840x2160 |
| DLSS 模型 PRESET | 默认 / K / J / M / L；30 系推荐 K |
| 纹理少 mip MIP DROP | 0 最清晰，1 = 8G 平衡，2/3 更省显存 |
| 显存窗口 / 卡片步进 / 间接批次 | 进阶显存与性能调参，默认即可 |
| 动作 Actions | 立即保存并重启 / 保存 / 预载着色器 / 全部恢复默认 / 关闭 |

说明：`*` = 已修改，下次启动生效；`即时` = 立即生效；`NOT SET` = 启动器未提供该值。
英文对照与细节见 [docs/EN-USAGE.md](docs/EN-USAGE.md)。

---

## 存档与设置 / Saves and settings

| 内容 What | 路径 Path |
| --- | --- |
| 主存档 Save（bat 默认） | `E:\gta6\work\perf-data\7952987A` |
| 直接跑 exe 的存档 | `%LOCALAPPDATA%\victory\data\7952987A` |
| F1 设置 Settings | `%LOCALAPPDATA%\victory\victory-settings.txt`（所有构建共用 / shared） |
| 日志 Logs | `%LOCALAPPDATA%\victory\logs\victory-nvidia-play-*.log` |
| 着色器缓存 Cache | bat 的 `CACHE_DIR`（默认 `E:\gta6\cache-vf-cn`） |

换构建不丢存档，换存档目录会；迁移时复制整个 `7952987A` 文件夹。
Changing builds does not lose saves; changing the save folder does. Copy the whole `7952987A` folder.

---

## 常见问题 / Troubleshooting

| 现象 Symptom | 原因 Cause | 处理 Fix |
| --- | --- | --- |
| 保存并重启后帧生成关了 / FG off after restart | 旧版重启丢插件/FSR 目录 / old restart dropped folders | 用最新版 / update to the latest |
| 崩在 Game Init / 白屏 / crash at init | 保存的 F1 设置不兼容 / bad saved settings | `重置F1设置(卡崩时用).bat` |
| 存档"没了" / "lost" save | 直接双击了 exe / launched the exe directly | 用 bat，或设 `VICTORY_DATA_DIR` |
| 退出码 -2147483645 | `0x80000003` 断点：游戏内部断言 / title asserted (int3) | 附 `*.crash.log` 反馈 |
| 退出码 -1073741819 | `0xC0000005` 访问冲突 / access violation | 附日志反馈 |
| 帧生成显示"关" | 20/30 系需插件；FSR 需 `amd-sdk` / add-on or runtime missing | 用对应 bat，别只拷 exe |
| TDR / 驱动重置 / driver reset | 驱动超时 / timeout | 降画面尺寸或 mip drop，更新驱动 |

---

## 性能建议 / Performance notes

- 本层是 **CPU 瓶颈**（转译 + 提交），**帧生成是提升观感帧率最有效的手段**。
- 8G 显存：`纹理少 mip=1` 通常最佳；1080p 拉伸 + 系列 S 最省。
- FSR 3 只有 2X；3X-6X 只能 DLSS-G（30/20 用插件，注意显存与稳定性）。
- The layer is **CPU-bound**; frame generation is the biggest perceived-FPS win.
- 8 GB VRAM: `MIP DROP = 1` is the usual sweet spot; 1080p→1440p + Series S is cheapest.
- FSR 3 is 2x only; 3x–6x needs the DLSS-G path (RTX 20/30 via the add-on).

---

## 从源码构建 / Build from source

```powershell
git clone https://github.com/DKTTT/victory-nvidia-8gb.git
cd victory-nvidia-8gb
git checkout cn-f1          # 稳定版 / stable
cargo build --release -p victory
```

运行库（放在 `victory.exe` 旁）/ runtimes (beside `victory.exe`):
NVIDIA `nvidia-sdk\Streamline\bin\x64\`（`victory get-dlss` 可下载）；AMD FSR `amd-sdk\amd_fidelityfx_dx12.dll`（`Get-AMD-FSR.cmd` 可下载）。

---

## 鸣谢与免责 / Credits and disclaimer

- 上游 upstream: [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA)
- SM86 支持与修复: [whiteh4cker-tr/VIctory_sm86](https://github.com/whiteh4cker-tr/VIctory_sm86)
- FSR 运行时: AMD [FidelityFX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK)；DLSS-G 插件作者；CGBJ 项目思路
- **No game files are included or distributed.** NVIDIA/AMD runtimes belong to their owners. For personal backup and research use only; please buy the game.
- **仓库与发布包不含任何游戏文件**；仅供个人备份与研究，请支持正版。

---

<a id="english"></a>
# English

**What it is.** A translation layer that runs your own dump of the Xbox Series
build of GTA6 (v1.0.2.1) on Windows 11 with an NVIDIA GPU. This fork adds a fully
Chinese F1 menu, Series S by default, 8 GB VRAM tuning, two frame-generation
backends (AMD FSR 3 at 2x; NVIDIA DLSS-G at 2x–6x with the bundled add-on on
RTX 20/30), and fixes so settings survive a save-and-restart.

**Download and run.**

1. Grab a zip from [Releases](https://github.com/DKTTT/victory-nvidia-8gb/releases).
   `oldN-FSR` = FSR 3 by default; `newN-FG-FSR` = native DLSS-G by default.
2. Extract the whole folder and run `启动.bat`.
3. Press **F1** in game for the settings menu.
4. If it crashes, run `重置F1设置(卡崩时用).bat` first.

**Notes.**

- Launch with the bat: it pins the save folder; a bare `victory.exe` uses
  `%LOCALAPPDATA%\victory\data` instead.
- Settings live in `%LOCALAPPDATA%\victory\victory-settings.txt`, logs in
  `%LOCALAPPDATA%\victory\logs\`.
- Exit code `-2147483645` (`0x80000003`) means the title asserted (int3);
  `-1073741819` (`0xC0000005`) is an access violation — both want the crash log.
- The layer is CPU-bound; frame generation is the biggest perceived-FPS win,
  and `TEXTURE MIP DROP = 1` is the usual 8 GB sweet spot.

Full English guide: [docs/EN-USAGE.md](docs/EN-USAGE.md).