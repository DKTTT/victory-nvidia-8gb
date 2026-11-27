# GTA6 PC 转译层 · CN 构建 使用说明

本说明对应仓库 `DKTTT/victory-nvidia-8gb` 的 CN 构建（分支 `cn-f1`）。
转译层把 Xbox Series 的 GTA6（v1.0.2.1）转译到 Windows PC；**仓库与发布包都不含游戏文件**。

## 1. 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Windows 11（22H2 或更新） |
| 显卡 | NVIDIA RTX 20 / 30 / 40 / 50；8 GB 显存起步（本构建针对 8G） |
| 驱动 | NVIDIA 580+ 建议（帧生成需要较新驱动） |
| 游戏 | 自备 Xbox Series 版 GTA6 v1.0.2.1 转储（`game_scarlett_master.exe` 所在目录） |
| 其他 | 已安装 VC++ 运行库；40 GB+ 空闲磁盘 |

## 2. 安装与启动

1. 下载 Release 里的 zip：
   - **老 N 卡（20/30 系）**：`GTA6-CN-8G-oldN-FSR-*.zip`，默认 FSR 3 插帧 2X，无需插件。
   - **新 N 卡（40/50 系）**：`GTA6-CN-8G-newN-FG-FSR-*.zip`，默认原生 DLSS 帧生成。
   - 30 系想要 3X-6X：两个包都带 `dlssg-sm86` 插件，用 `启动-多倍插帧(DLSS-G).bat`。
2. 解压**整个文件夹**（不要只拷 exe，`amd-sdk` / `nvidia-sdk` / `dlssg-sm86` 缺一不可）。
3. 双击 `启动.bat`。
4. 首次启动会比较慢（编译着色器）；以后启动可用 `预热.bat` 提前编译。
   想一次做到底（含全部管线、写进管线库，进世界最顺）就运行 `预热-火力全开.bat`；
   它可能要几十分钟到几小时，中途 Ctrl+C 不会白做，下次接着来。

> 游戏目录：bat 会自动在包内、`E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK` 里找；都不是时把包放进游戏目录，或传参：`启动.bat "D:\你的游戏目录"`。

## 3. 启动脚本说明

| 脚本 | 内容 |
| --- | --- |
| `启动.bat` | 老 N 卡 = FSR 2X；新 N 卡 = 原生 DLSS |
| `启动-多倍插帧(DLSS-G).bat` | DLSS-G 插件（2X/3X/4X/5X/6X），30/20 系可用 |
| `启动-FSR插帧.bat` | FSR 3 插帧 2X（40/50 也可用） |
| `启动-不插帧(最稳).bat` | 关闭帧生成，排查问题用 |
| `启动-8G平衡.bat` | FSR 2X + 纹理少一级 mip + 显存窗口 256MB |
| `预热.bat` | 提前编译着色器（不进游戏） |
| `预热-火力全开.bat` | 预热全部内容：全核编译着色器 → 反复预热所有管线 → 写入管线库（按 CPU 核心数分档、开始前弹窗确认耗时与卡顿提示；可中断续跑）。加 `-Fast` 只做加载期（分钟级） |
| `重置F1设置(卡崩时用).bat` | 清空 `%LOCALAPPDATA%\victory\victory-settings.txt`，原文件备份为 `.bak` |

## 4. F1 菜单详解

进游戏按 **F1** 打开（Esc 关闭），↑↓ 选择，←→ 修改，动作项按回车。

- **DLSS**：超分档位。画质 / 均衡 / 性能 / DLAA(原生) / 关。
- **帧生成**：关 / 2X / 3X / 4X / 5X / 6X。选择 **FSR 3** 后端时最多 2X。
- **帧生成类型(重启)**：自动（有 DLSS 帧生成就用 DLSS，否则保持我们的 FSR 路径）/ DLSS / FSR 3(老卡)。切换需保存重启。
- **帧率上限**：无 / 120 / 60 / 30(游戏)。
- **顶部帧率**：左上角 FPS 行开关。
- **状态面板(F3)**：F3 诊断面板。
- **全屏(无边框)**、**鼠标捕获**、**英文键盘**：窗口/输入。
- **主机模式**：系列 X / 系列 S(更快)。默认系列 S。
- **画面尺寸**：2560x1440 / 1080p拉伸 / 3840x2160。
- **DLSS 模型**：默认 / K / J / M / L。30 系推荐 K。
- **纹理少 mip**：0=最清晰，1=8G 平衡，2/3=更省显存。
- **显存窗口**、**卡片步进**、**间接批次**、**比较起点** 等：进阶显存/性能调参，默认即可。
- **动作**：
  1. **立即保存并重启**：保存当前设置并重启游戏。
  2. **保存(下次启动)**：只写文件，不重启。
  3. **预载着色器(重启游戏)**：保存 → 关游戏 → 跑 `victory preload` 编译全部着色器 → 再进游戏（可能很久）。
  4. **全部恢复默认**：删除设置文件，下次启动用默认值。
  5. **关闭**。

> `*` = 已修改，下次启动生效；`即时` = 立即生效；`NOT SET` = 启动器未提供该值。

## 5. 存档与设置

| 内容 | 路径 |
| --- | --- |
| 主存档 | `E:\gta6\work\perf-data\7952987A`（bat 默认） |
| 直接跑 exe 的存档 | `%LOCALAPPDATA%\victory\data\7952987A` |
| F1 设置 | `%LOCALAPPDATA%\victory\victory-settings.txt` |
| 日志 | `%LOCALAPPDATA%\victory\logs\victory-nvidia-play-*.log` |
| 着色器缓存 | bat 的 `CACHE_DIR`（默认 `E:\gta6\cache-vf-cn`） |

- 换构建不丢存档；**换存档目录会**。迁移时复制整个 `7952987A` 文件夹。
- 想用别的存档目录：在 bat 里改 `SAVE_DIR`，或设 `VICTORY_DATA_DIR`。

## 6. 常见问题

### 6.1 帧生成显示"关"

- 30/20 系没有插件时 DLSS 帧生成不可用：用 `启动-多倍插帧(DLSS-G).bat`（需包内 `dlssg-sm86`）。
- FSR 需要 `amd-sdk/amd_fidelityfx_dx12.dll`：确认包解压完整。
- 看启动提示（前 30 秒画面顶部）：会写明 GPU、DLSS 状态、帧生成跑哪个后端以及原因。
- 保存并重启后丢设置：更新到最新版（已修复插件/FSR 目录携带）。

### 6.2 启动崩在 Game Init / 白屏

先 `重置F1设置(卡崩时用).bat`，再用默认脚本启动。旧版可能有坏设置组合（如 2X + DLAA + 拉伸）。

### 6.3 退出码含义

| 退出码 | 含义 |
| --- | --- |
| `-2147483645` | `0x80000003` 断点异常：游戏内部断言（int3）。附 `*.crash.log` 反馈 |
| `-1073741819` | `0xC0000005` 访问冲突（空指针/越界） |
| `-1073740791` | `0xC0000409` 快速失败（abort/栈溢出） |
| `0` | 正常退出；若闪退看日志最后一屏 |

### 6.4 存档"没了"

90% 是启动方式不同：bat 用 `E:\gta6\work\perf-data`，直接双击 exe 用 `%LOCALAPPDATA%\victory\data`。两个目录都存在，复制合并即可。

## 7. 性能建议

- 本层瓶颈在 CPU（转译与提交），**帧生成是提升观感帧率最有效手段**。
- 8G 显存：`纹理少 mip=1` 通常最佳；1080p 拉伸 + 系列 S 最省。
- FSR 3 只有 2X；3X-6X 只有 DLSS-G（30/20 用插件，注意显存与稳定性）。
- 卡顿/掉帧明显：先关 F3 面板与顶部帧率，再降画面尺寸，最后才动显存参数。

## 8. 从源码构建

```powershell
git clone https://github.com/DKTTT/victory-nvidia-8gb.git
cd victory-nvidia-8gb
git checkout cn-f1
cargo build --release -p victory
```

运行库：
- NVIDIA：`victory get-dlss`（下载到 `%LOCALAPPDATA%\victory\nvidia-sdk`），或把 `nvidia-sdk\Streamline\bin\x64\` 放 exe 旁。
- AMD FSR：`Get-AMD-FSR.cmd`（下载到仓库 `amd-sdk\`），或手动放 `amd_fidelityfx_dx12.dll`。

## 9. 致谢与免责

上游 [trustno1-coder/VIctory-NVIDIA](https://github.com/trustno1-coder/VIctory-NVIDIA)；
SM86 支持与修复 [whiteh4cker-tr/VIctory_sm86](https://github.com/whiteh4cker-tr/VIctory_sm86)；
FSR 运行时来自 AMD FidelityFX SDK；DLSS-G 插件作者与 CGBJ 项目。

**仓库与发布包不含任何游戏文件**；NVIDIA/AMD 运行库版权归各自所有者；仅供个人备份与研究，请支持正版。