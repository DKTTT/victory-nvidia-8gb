# VIctory on NVIDIA · CN build — Usage Guide

This guide covers the CN build in `DKTTT/victory-nvidia-8gb` (branch `cn-f1`).
The layer translates the Xbox Series build of GTA6 (v1.0.2.1) to Windows.
**Neither the repository nor the release zips contain game files.**

## 1. Requirements

| Item | Requirement |
| --- | --- |
| OS | Windows 11 (22H2 or newer) |
| GPU | NVIDIA RTX 20 / 30 / 40 / 50, 8 GB VRAM or more (this build targets 8 GB) |
| Driver | NVIDIA 580+ recommended (frame generation needs a recent driver) |
| Game | Your own dump of the Xbox Series build v1.0.2.1 (the folder holding `game_scarlett_master.exe`) |
| Other | VC++ runtime, 40 GB+ free disk |

## 2. Install and run

1. Download a zip from Releases:
   - **RTX 20/30 ("old N")**: `GTA6-CN-8G-oldN-FSR-*.zip` — AMD FSR 3 at 2x by default, no add-on needed.
   - **RTX 40/50 ("new N")**: `GTA6-CN-8G-newN-FG-FSR-*.zip` — native DLSS frame generation by default.
   - RTX 30 wanting 3x–6x: both zips ship the `dlssg-sm86` add-on; use `启动-多倍插帧(DLSS-G).bat`.
2. Extract the **whole folder** (`amd-sdk`, `nvidia-sdk` and `dlssg-sm86` are all required).
3. Double-click `启动.bat` ("start").
4. The first start is slow (shaders are translated); later you can run `预热.bat` ("preload") first.
   For the full job (all pipelines, baked into the pipeline library) run `预热-火力全开.bat`:
   it can take a long time, and Ctrl+C is safe — the next run continues where it stopped.

> Game folder: the bat looks inside its own folder and at `E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK`;
> otherwise put the zip inside your game folder or pass it: `启动.bat "D:\your\game\folder"`.

## 3. Launch scripts

| Script | What it does |
| --- | --- |
| `启动.bat` | RTX 20/30: FSR 2x; RTX 40/50: native DLSS frame generation |
| `启动-多倍插帧(DLSS-G).bat` | DLSS-G add-on, 2x/3x/4x/5x/6x (RTX 20/30; 40/50 can use it too) |
| `启动-FSR插帧.bat` | FSR 3 frame generation at 2x |
| `启动-不插帧(最稳).bat` | Frame generation off (for troubleshooting) |
| `启动-8G平衡.bat` | FSR 2x + one mip level dropped + 256 MB card window |
| `预热.bat` | Translate shaders ahead of time (no game start) |
| `预热-火力全开.bat` | Full-power preload: every shader (all cores), every pipeline, baked into the pipeline library; long but resumable |
| `重置F1设置(卡崩时用).bat` | Clears `%LOCALAPPDATA%\victory\victory-settings.txt` (backed up as `.bak`) |

## 4. The F1 menu

Press **F1** in game (Esc closes). Arrows select, left/right change, Enter runs an action.

- **DLSS**: upscaling preset — quality / balanced / performance / DLAA (native) / off.
- **FRAME GENERATION** (帧生成): off / 2x / 3x / 4x / 5x / 6x. 2x at most on the FSR backend.
- **FRAME GEN TYPE** (帧生成类型, restart): auto / DLSS / FSR 3 (older cards). Needs a save-and-restart.
- **FRAME RATE CAP** (帧率上限): none / 120 / 60 / 30 (the game's).
- **FPS AT THE TOP** (顶部帧率), **STATS PANEL (F3)** (状态面板).
- **FULLSCREEN** (全屏), **MOUSE CAPTURE** (鼠标捕获), **ENGLISH KEYBOARD** (英文键盘).
- **CONSOLE** (主机模式): Series X / Series S (faster). Series S by default.
- **PICTURE** (画面尺寸): 2560x1440 / 1080p upscaled / 3840x2160.
- **DLSS PRESET** (DLSS 模型): default / K / J / M / L. K is recommended on RTX 30.
- **TEXTURE MIP DROP** (纹理少 mip): 0 clearest, 1 the 8 GB sweet spot, 2/3 save more VRAM.
- **CARD WINDOW** (显存窗口), **CARD STEPS** (卡片步进), **INDIRECT BATCH** (间接批次) and friends: advanced VRAM/performance levers; defaults are fine.
- **Actions** (动作):
  1. Save and restart now (立即保存并重启)
  2. Save for next start (保存)
  3. Preload shaders, restarting the game (预载着色器) — <kbd>Enter</kbd> twice to confirm; can take a long time
  4. Reset all to play defaults (全部恢复默认)
  5. Close (关闭)

> `*` = changed, applies at the next start; `即时` = live; `NOT SET` = the launcher did not provide a value.

## 5. Saves and settings

| What | Path |
| --- | --- |
| Main save (bat default) | `E:\gta6\work\perf-data\7952987A` |
| Save when running the exe directly | `%LOCALAPPDATA%\victory\data\7952987A` |
| F1 settings | `%LOCALAPPDATA%\victory\victory-settings.txt` |
| Logs | `%LOCALAPPDATA%\victory\logs\victory-nvidia-play-*.log` |
| Shader cache | the bat's `CACHE_DIR` (default `E:\gta6\cache-vf-cn`) |

- Changing builds does not lose saves; changing the save folder does. Copy the whole `7952987A` folder.
- To use another save folder, edit `SAVE_DIR` in the bat or set `VICTORY_DATA_DIR`.

## 6. Troubleshooting

### 6.1 Frame generation shows "off"

- RTX 20/30 without the add-on cannot run DLSS frame generation: use `启动-多倍插帧(DLSS-G).bat` (the zip's `dlssg-sm86`).
- FSR needs `amd-sdk/amd_fidelityfx_dx12.dll`: make sure the zip was fully extracted.
- Read the start notice (top of the picture for 30 s, and in the console): it names the GPU, whether DLSS is on, which frame generation runs and why not.
- Settings lost after save-and-restart: update to the latest build (the folders are now carried over).

### 6.2 Crash at Game Init / white screen

Run `重置F1设置(卡崩时用).bat` ("reset F1 settings") first, then start with the default script.
An old saved combination (e.g. 2x + DLAA + upscaling) could crash the init.

### 6.3 Exit codes

| Exit code | Meaning |
| --- | --- |
| `-2147483645` | `0x80000003` breakpoint: the title asserted (int3). Report with `*.crash.log` |
| `-1073741819` | `0xC0000005` access violation |
| `-1073740791` | `0xC0000409` fail-fast (abort / stack overrun) |
| `0` | Clean exit; if it closed instantly, check the end of the log |

### 6.4 "Lost" save

Nine times out of ten it is the launch method: the bat uses `E:\gta6\work\perf-data`,
while a bare `victory.exe` uses `%LOCALAPPDATA%\victory\data`. Both may exist; copy/merge them.

## 7. Performance notes

- The layer is CPU-bound (translation and submission); **frame generation is the biggest perceived-FPS win**.
- 8 GB VRAM: `TEXTURE MIP DROP = 1` is usually best; 1080p upscaling plus Series S is the cheapest.
- FSR 3 is 2x only; 3x–6x needs the DLSS-G path (RTX 20/30 via the add-on — mind VRAM and stability).
- Stutter: turn off the F3 panel and the top FPS line first, then lower the picture size, and only then touch the VRAM levers.

## 8. Build from source

```powershell
git clone https://github.com/DKTTT/victory-nvidia-8gb.git
cd victory-nvidia-8gb
git checkout cn-f1
cargo build --release -p victory
```

Runtimes:
- NVIDIA: `victory get-dlss` (downloads into `%LOCALAPPDATA%\victory\nvidia-sdk`), or place `nvidia-sdk\Streamline\bin\x64\` beside the exe.
- AMD FSR: `Get-AMD-FSR.cmd` (downloads into the repo's `amd-sdk\`), or drop `amd_fidelityfx_dx12.dll` there yourself.

## 9. Credits and disclaimer

Upstream [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA);
SM86 support and fixes from [whiteh4cker-tr/VIctory_sm86](https://github.com/whiteh4cker-tr/VIctory_sm86);
the FSR runtime comes from AMD's FidelityFX SDK; the DLSS-G add-on is by its respective author,
with thanks to the CGBJ project for ideas.

**No game files are included in the repository or the releases.** NVIDIA/AMD runtimes
belong to their owners. For personal backup and research use only; please buy the game.