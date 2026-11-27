# 更新日志

## 未发布（qol 测试线）

- 新增 `预热-火力全开.bat` / `.ps1`：全核编译全部着色器 → 反复预热所有管线 → 写入管线库；可断点续跑，参数 `-SkipShaders` / `-WarmLimit` / `-FullRebuild`
- F1 菜单汉化补完：补齐字库（240 字）、`未设置`、`回车执行`、预载说明中文
- 启动提示改中文，开 F1 时自动隐藏
- 菜单单元测试修复（字模/宽度/预载说明/FSR 两档）

## 2026-11-28 · **v5 正式版 / v5 stable**

**中文**

- **PR#49 白窗口修复**：present 到标题自己的窗口，而不是伪控制台的 0x0 窗口（部分 40 系显卡白屏的根因）
- **PR#58 placed views padding words**：修"人脸彩纸 / 材质抽搐"类画面错误
- **PR#57 host list 拷贝源池化**：内存压力下只裁到 128 MiB，不再裁光
- sm86 修复：confetti faces、placed order 默认开启、aliased texture pin、列表上传 arena
- 保留 v4 全部：FSR 3 插帧 2X + DLSS-G 多倍插帧 + 全中文 F1 菜单 + 默认系列 S + 8G 调参 + 保存重启不丢设置 + 依赖全内置
- **未包含**（仍在测试）：shader PR#42/#41/#43/#48/#45、QoL（启动提示/预载着色器）

**English**

- **PR#49 white-window fix**: present to the title's own window instead of a pseudoconsole's 0x0 window (root cause of white screens on some RTX 40 cards)
- **PR#58 placed-view padding words**: fixes "confetti on faces" / material corruption
- **PR#57 host list copy-source pooling**: memory pressure trims spares to 128 MiB, not to nothing
- sm86 fixes: confetti faces, placed order on by default, aliased texture pin, list upload arenas
- Everything from v4 kept; **not included** (still tested): shader PRs #42/#41/#43/#48/#45 and QoL (start notice / preload)

## 2026-11-28 · v4 稳定版 / v4 stable

**中文**

- 新增 **AMD FSR 3 帧生成**（官方运行时，2X，通用；包内 `amd-sdk`，无需第三方插件）
- 保留 **DLSS-G 多倍插帧**：2X–6X（RTX 40/50 原生；20/30 用包内 `dlssg_for_sm86` 插件）
- F1 菜单新增「帧生成后端(需重启)」：DLSS / FSR 3
- **修复「保存并重启后帧生成又关了」**：重启命令会带上插件目录与 FSR 目录，并自动在 exe 旁查找
- **修复「保存并重启后设置复原」**：设置文件统一在 `%LOCALAPPDATA%\victory\victory-settings.txt`，重启沿用
- 新增 `VICTORY_TEXTURE_MIP_DROP=0~3`（8G 省显存）
- 新增 `重置F1设置(卡崩时用).bat`
- **依赖全内置**：NVIDIA Streamline/DLSS（67MB）、AMD FSR 运行库、DLSS-G 插件；解压即用，无需联网下载
- 合入上游 sm86 修复：confetti faces、placed order 默认、aliased texture pin、列表上传 arena
- 合入上游 PR：#58 padding words、#57 host list 池化、#49 白窗口修复

**English**

- **AMD FSR 3 frame generation** added (official runtime, 2x, universal; bundled `amd-sdk`, no third-party add-on)
- **DLSS-G multi-frame** kept: 2x–6x (native on RTX 40/50; RTX 20/30 via the bundled `dlssg_for_sm86` add-on)
- New F1 menu item **FRAME GEN BACKEND (restart)**: DLSS / FSR 3
- **Fixed "frame generation turns off after save and restart"**: the restart now carries the add-on and FSR folders, and finds them beside `victory.exe`
- **Fixed "settings reset after restart"**: one shared settings file, applied on every start
- New `VICTORY_TEXTURE_MIP_DROP=0..3` (8 GB VRAM saving)
- New `重置F1设置(卡崩时用).bat` (reset F1 settings when it crashes)
- **All dependencies bundled**: NVIDIA Streamline/DLSS (67 MB), AMD FSR runtime, DLSS-G add-on; no internet needed
- Upstream sm86 fixes: confetti faces, placed order on by default, aliased texture pin, list upload arenas
- Upstream PRs: #58 padding words, #57 host list pooling, #49 white-window fix

## 2026-11-27 · v3（依赖内置 / dependencies bundled）

- 把 NVIDIA Streamline/DLSS、FSR、DLSS-G 插件全部放进发布包（zip 26.8MB → 61.4MB），用户不再需要单独下载 156MB 运行库
- All runtimes bundled into the release zips; users no longer need to download ~156 MB separately

## 2026-11-27 · v2（CN 构建 / CN build）

- 全中文 F1 菜单（点阵字体内置）
- 默认系列 S；`VICTORY_TEXTURE_MIP_DROP` 等 8G 调参
- 修复启动崩在 Game Init（坏设置组合）
- Fully Chinese F1 menu; Series S default; 8 GB tuning; Game-Init crash fix for bad saved settings

## 2026-11-27 · v1（初版 / first build）

- 基于上游 VIctory-NVIDIA 的 NVIDIA 支持 + 中文菜单初版
- First build on top of upstream VIctory-NVIDIA with a Chinese menu

## 测试分支 / Test branch

- `qol`（未发布 / unreleased）：上游 v2026.11.27 的启动提示、F1 预载着色器、NOT SET 显示、独立控制台重启；以及 shader 优化 PR #42/#41/#43、动态槽 #48、水面修复 #45
- `qol` (unreleased): upstream v2026.11.27 start notice, F1 shader preload, NOT SET rows, own-console restart; plus shader PRs #42/#41/#43, dynamic slots #48, water fix #45