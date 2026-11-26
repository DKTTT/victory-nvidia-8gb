# GTA VI PC 移植 - 本地启动器与补丁集

本分支收集 2026-11-26 的本地成果：图形启动器、开发辅助脚本、以及各版本补丁。

## 目录

| 路径 | 内容 |
|---|---|
| `tools/launcher/` | 图形启动器（选择构建/主机模式/渲染分辨率/预热/启动）|
| `tools/dev/` | 开发辅助：白屏检测、帧率基准、自动转视角测量 |
| `patches/vf-main-stable/` | vf-main 稳定版本地集成补丁（渲染缩放钩子、两平面合成修复白屏、BCPack 缓存、NVIDIA 脚本）|
| `patches/vf-nvidia/` | vf-nvidia 分支 3 个本地提交（BCPack 缓存、d1f883e 蒙版修复移植、跳过 12 个 wave64 shader）|
| `patches/experimental-picks/` | **实验性**：从新上游摘取的 wave32/GPU 修复（10 个补丁），已知问题见下 |

## 实测性能（RTX 3070 Ti Laptop 8GB / i9-12900H / 32GB）

| 版本 | 模式 | 帧时间 | 帧率 |
|---|---|---|---|
| vf-nvidia（构建 1）| Series S 540p | 58~80 ms | 12~17 fps |
| vf-main 稳定版（构建 2）| Series S 540p | 78~130 ms | 8~13 fps |
| 新上游合并版 | Series S 540p | 500~600 ms | 2~3 fps |
| 摘取修复实验版 | Series S 540p | 200~480 ms | 2~5 fps |

## 实验性补丁的已知问题

- `experimental-picks` 全套应用后：着色器翻译 100% 通过（被拒管线 12 → 0），
  但会出现**白屏**（诊断类提交 PR#69/#106 在旧基底不兼容）和**约 150 秒崩溃**（PR#77）。
- 目前**不建议用于游玩**；稳定版用 `vf-main-stable` + `vf-nvidia` 补丁。

## 启动器使用

1. 把 `tools/launcher/` 放到任意目录
2. 双击 `GTA6启动器-GUI.bat`
3. 选择构建（构建 1 = 最快）、主机模式（Series S）、渲染分辨率（540p 均衡）
4. 先点「预热全部」，完成后再「启动游戏」