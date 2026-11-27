# CN 构建（中文 F1 菜单 / XSS 默认 / 30 系插帧）

本分支 = 上游 `trustno1-coder/VIctory-NVIDIA`（foxhound 基线，已合并到 `959dcaf`）
+ 汉化 F1 菜单 + 默认主机模式改为 Series S（XSS）+ `dlssg_for_sm86` 插帧加载器（来自 VIctory_sm86）。

## 相对上游的改动

1. **F1 菜单汉化**
   - `crates/victory-gpu/src/host/menu.rs`：全部标签/档位/动作/提示改中文
   - `crates/victory-gpu/src/host/font_cn.rs`（新增）：8x16 ASCII + 16x16 中文点阵字库（199 字）
   - `crates/victory-gpu/src/host.rs`：声明 `mod font_cn`
   - 菜单渲染从 5x7 字符网格改为变宽像素渲染（ASCII 8px / 中文 16px），1080p 下 2 倍放大
2. **默认主机模式 = 系列 S（XSS）**
   - `apps/victory/src/play.rs`：`series_s` 默认开；新增 `--series-x` 切回 Series X
   - 其它设置保持上游原版默认（DLSS 质量、光照估算等）
3. **30/20 系插帧**（来自 `whiteh4cker-tr/VIctory_sm86`，GPL 源码方式移植）
   - 新增 `crates/victory-gpu/src/streamline/sm86.rs`、`crates/victory-gpu/src/adapter.rs`
   - `streamline.rs`：FG 求情时在 `slInit` 前加载第三方 `dlssg_for_sm86` 的 `version.dll`
   - 用法：`--framegen 2 --set "VICTORY_DLSSG_SM86_DIR=<插件目录>"`
   - 插件（86MB，含 NVIDIA 专有二进制）**不在本仓库**；从
     https://github.com/sdli1995/dlssg_for_sm86/releases 下载，仅个人实验
   - 实测 RTX 3070 Ti Laptop：日志 `DLSS Frame Generation: N presents with it on, N frames shown (status 0x0)`，2x

## 构建

```powershell
cargo build --release -p victory
```

## 启动

```powershell
# 普通（XSS 默认）
victory.exe play "<游戏目录>\game_scarlett_master.exe"

# 插帧（需先下载 dlssg_for_sm86 插件）
victory.exe play "<游戏目录>\game_scarlett_master.exe" --framegen 2 --set "VICTORY_DLSSG_SM86_DIR=<插件目录>"
```

游戏内 F1 中文菜单，F3 帧率面板。首次运行要翻译着色器（`victory shaders`）/预编译管线（`victory warm`）。

## 已知限制

- 插帧只在启动时就开着 FG 时 F1 菜单才显示「即时」，否则保存重启生效
- 帧数低于约 5fps 时 `dlssg` 可能自动关闭插帧
- 老基线（非 foxhound）的 8GB 调优分支（mip-drop 等）移植后无收益，未纳入