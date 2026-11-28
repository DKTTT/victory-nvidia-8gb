# Victory 启动器（GTA6 CN）

GTA6 CN 的图形启动器：选游戏目录、开始游戏、预热着色器（带进度条/剩余时间）、设置、
存档管理、电脑配置检查。

- 双击 `VictoryLauncher.exe`；首次用 Browse 选 `game_scarlett_master.exe`，或点「自动查找」
  （启动器文件夹 / 上一级 / `game-path.txt` / `VICTORY_GAME_DIR` / 常见路径 / 各盘 `*GTA6*` 文件夹）。
- 「预热着色器」先选「火力全开」档位（安静/平衡/暴力/极强，算法同 `预热-火力全开.ps1`：
  进程数、优先级、批量，带内存保险），确认后跑全量预热（`victory warm --jobs N`），
  进度条与停止按钮照旧，可随时停、已完成的部分保留。
- 设置里可切 Series S/X、DLSS、帧生成；启动器会把设置通过 `victory play --set ...` 传给内核。
- 存档页管理 `%LOCALAPPDATA%\victory\data\7952987A\saves`。

## 来源与许可

本启动器移植自 **Project Neptune VI 1.0.2** 的启动器（GPL-3.0-or-later，
作者 Project Neptune VI 团队），由 DKTTT 改名为 GTA6 CN · Victory 并对接本项目的
`victory.exe`（`play` / `warm --used`、FSR/DLSS 目录、存档目录），修改处见 git 历史。
源码同样以 GPL-3.0-or-later 发布；完整许可见仓库根目录 LICENSE。

## 构建

需要 .NET 8 SDK。

普通（开发）版：一个自包含 exe（约 75 MB），`ui` 文件夹放在它旁边：

```
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

产物 `dist\VictoryLauncher.exe` + `dist\ui\` + `dist\victory.ico`，和 `victory.exe`
放同一目录即用。

单文件发行版：把内核、`ui`、`amd-sdk`、`shvi` 和说明文档都打进 exe，玩家只看到一个
`VictoryLauncher.exe`：

```
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Bundle E:\path\to\package
```

- 内核取自本仓库 `target\release\victory.exe`（没有则用包里的），`amd-sdk`、`shvi`、
  文档与 `启动-*.bat`、`README-中文.txt` 等取自 `-Bundle` 指向的包目录（先删掉旧的
  `payload\` 与 `payload.zip` 再重新暂存，两者都在 `.gitignore` 里）。
- 打包后的 exe 第一次运行会把内置 zip 解到
  `%LOCALAPPDATA%\VictoryLauncher\payload-<版本>-<内容哈希>\`（写入 `.payload-stamp`；
  同样的 exe 下次直接跳过，重新构建后内容哈希变化会解到新目录，旧目录在下次启动时清掉）。
  内核、`ui`、`amd-sdk`、`shvi`、文档都从该目录取；WebView2 也映射该目录下的 `ui\`。
- 旁边有真的 `victory.exe` / `ui\` 时仍优先用旁边的（完整包目录、开发调试的覆盖方式，
  和以前一样）。`nvidia-sdk\`、`dlssg-sm86\` 不打进 exe：需要时放在 exe 旁边或解出的
  payload 目录里即可。
- `dist\` 里连 `ui\`、`*.txt`、`*.bat` 都不留，只有 `VictoryLauncher.exe`。

## 测试钩子

`VICTORY_LAUNCHER_E2E=<javascript>`：页面加载后执行一段 JS（无人值守测试用，平时不用设）。


【排错：只看到人物的眼睛和嘴、其他全没】
这是 Mesh Shader 没跑起来——最常见原因是 Windows 把游戏分给了核显（笔记本双显卡常见）。
处理：
1) Windows 设置 → 系统 → 屏幕 → 显示卡 → 把 game_scarlett_master.exe 和 victory.exe 设为「高性能」；
2) 或 NVIDIA 控制面板 → 管理 3D 设置 → 程序设置 → 选 victory.exe → 首选图形处理器 = 高性能 NVIDIA 处理器；
3) AMD 显卡在驱动里同样指定「高性能」。
注意：GTX 10xx / RX 5000 及更老显卡没有 Mesh Shader，本层不支持。
