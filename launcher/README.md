# Victory 启动器（GTA6 CN）

GTA6 CN 的图形启动器：选游戏目录、开始游戏、预热着色器（带进度条/剩余时间）、设置、
存档管理、电脑配置检查。

- 双击 `VictoryLauncher.exe`；首次用 Browse 选 `game_scarlett_master.exe`。
- 「预热着色器」只做以前真正画过的管线（`victory warm --used`），几分钟，Esc/取消可停；
  全量预热仍用包里的「预热-火力全开.bat」。
- 设置里可切 Series S/X、DLSS、帧生成；启动器会把设置通过 `victory play --set ...` 传给内核。
- 存档页管理 `%LOCALAPPDATA%\victory\data\7952987A\saves`。

## 来源与许可

本启动器移植自 **Project Neptune VI 1.0.2** 的启动器（GPL-3.0-or-later，
作者 Project Neptune VI 团队），由 DKTTT 改名为 GTA6 CN · Victory 并对接本项目的
`victory.exe`（`play` / `warm --used`、FSR/DLSS 目录、存档目录），修改处见 git 历史。
源码同样以 GPL-3.0-or-later 发布；完整许可见仓库根目录 LICENSE。

## 构建

需要 .NET 8 SDK：

``
powershell -ExecutionPolicy Bypass -File .\build.ps1
``

产物 `dist\VictoryLauncher.exe` + `dist\ui\` + `dist\victory.ico`，和 `victory.exe`
放同一目录即用。

## 测试钩子

`VICTORY_LAUNCHER_E2E=<javascript>`：页面加载后执行一段 JS（无人值守测试用，平时不用设）。
