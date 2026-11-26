# 更新日志（CHANGELOG）

GTA VI PC 移植 · 自动启动器 ｜ 作者：DKTTT
仓库：https://github.com/DKTTT/gta6-pc-launcher

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。
版本按**从新到旧**排列。

---

## [v1.9.1] - 2026-11-26

### 修复（预热完仍提示「没预热」）

用户实测：预热很久，启动还是弹「从未预热」；重新编译一次又永远判「缓存过期」。

| 旧行为 | 根因 | v1.9.1 |
|---|---|---|
| 启动前弹「没预热」 | 弹窗用 `$script:cacheState`（**选构建时**算的旧结果），预热完成后从未更新 | 启动前 `Test-LaunchCacheGate` **实时重算** |
| 记录读不到 | `builds-meta.json` 用**工程路径字符串**当 key，重扫/移动/大小写不一致就查不到 | 记录写进缓存目录 `launcher-warm.json`；旧 meta 仍兼容（工程路径 → exe 路径 → 缓存目录三级查找，key 规范化） |
| 编译后永远过期 | 用 exe 修改时间和预热时间比较，重新编译必然「更新」 | 改比**版本指纹**：翻译器源码指纹（仿 `victory-gpu/build.rs` 的输入）+ commit（短 sha / 全长 sha 前缀兼容）+ 显卡驱动版本 |
| 停止/关窗口 = 白做 | 只有完整跑完才写时间戳；`all` 链式预热时着色器阶段不落盘 | 每个阶段完成或中断都记录（`shadersDone/shadersComplete/pipesDone/pipesComplete`），可续传 |
| 判定依赖日志关键字 | 引擎输出一改就失效 | 以**缓存文件**为准：`shaders` 文件数、`warm-done.txt` 当前指纹行数、`early-pipelines.txt` 差集；日志关键字只作补充 |
| 弹窗时机不对 | 部分预热/只有着色器也拦 | 只有 `never`/`stale` 弹窗，`partial` 只写日志 |

新增「检查预热状态」按钮：不开游戏即可看到 缓存就绪 / 还差 N 条管线 / 版本变了要重做，日志里带 `build / warmShaders / warmPipes / translator / commit / driver / pipesFingerprint / fpLines / missingEarly` 全量诊断。

### 修复（`停止` 按钮无效 + 残留进程）

- **根因**：`Process.Kill($true)` 是 .NET Core 3.0+ 的重载，PowerShell 5.1（.NET Framework）上直接抛异常被 `catch{}` 吞掉 → 停止按钮和关窗口**从未真正杀掉**预热进程。
- 实测残留：1 个 `victory warm --used` + 6 个 `victory warm --these` 子进程继续占 CPU、锁缓存文件（启动报 `0x80070005` 的元凶之一）。
- 修复：`Stop-ProcTree` 按 `Win32_Process` 父子关系结束整棵树（预热 / 编译 cargo+rustc / 游戏通用）；`Clear-StaleWarmProcs` 在启动器启动和开始预热前清理上次残留。

### 新增/修改（更新不再卡界面）

| 操作 | 旧 | v1.9.1 |
|---|---|---|
| 检查上游更新（`git fetch`）| 同步阻塞，代理慢时界面假死 | 后台进程 + 实时日志 + 耗时显示 |
| 更新并编译（`git pull`）| 同步阻塞，之后才启动（本来异步的）编译 | 备份 exe → **后台** pull → 自动接续后台编译；成功/已是最新/失败按 HEAD 变化与输出判断 |
| 检查上游更新（非 git 构建，GitHub API）| `Invoke-RestMethod` 同步，最长 20s 假死 | 后台作业 |
| 编译结束 / 下载完成 / 回滚后重新扫描构建 | 同步递归扫描 10~35s（编译完那一刻卡死）| 后台作业扫描，回来只填列表 |
| 「重新扫描本地构建」按钮 | 同步 | 后台 |
| 启动时扫描 | 仍同步（窗口刚出现，等 10s）| 不变 |

> 说明：PS 5.1 里带 `-RedirectStandard*` 的 `Start-Process` 拿不到 `ExitCode`（实测恒为空），所以后台进程的成败改为看**输出文本 + 命令自身的副作用**（如 pull 后 HEAD 是否变化、fetch 后能否 `rev-list`）。

### 其它

- `launcher-config.json` 不再把键位页的示例注释当成用户配置写入。
- 版本号：脚本头部与启动日志 → v1.9.1。

---

## [v1.8.0] - 2026-11-26

### 修改（推荐算法 v2）

用户日志证实旧算法的问题，逐条修正：

| 旧问题 | v2 修正 |
|---|---|
| 只在另一家显卡上测试的项目也拿 0.3 分 | 只认 `tested.gpu` 里真实出现的厂商；只在另一家测试 = **0 分** |
| 显存解析过宽（可能把内存 GB 当显存）| 严格匹配 `with N GB` / `N GB card\|VRAM`，仅取 4~32GB |
| 速度取"最高帧"（轻场景 30fps 当 6/6）| 改用**最低 fps**（最差场景）分档 |
| 没测稳定性按 0 分惩罚 | 未测数据统一按中性 0.5 处理 |
| 每个项目都跑一次 git 查本地构建 | 循环前**预计算一次**映射 |

### 新增评分项

| 因素 | 权重 | 说明 |
|---|---|---|
| 厂商匹配 | 4.0 | 真实测试过本机厂商才得分 |
| 显存接近 | 2.0 | 4~32GB 范围，未知=中性 0.5 |
| 速度 | 1.5 | 按最低 fps 分档 |
| 稳定性 | 1.0 | 未测=中性 |
| 画面 | 1.0 | |
| 8GB 实测证据 | +0.3 | 8GB 用户专属加分 |
| 本地已有构建 | +0.4 | 可直接用 |
| 排名加成 | ≤0.2 | 弱化社区排名噪声 |

### 修复
- **推荐计算慢**：48 项目 × 27 构建 × 2~3 次 git ≈ 3000+ 进程调用，用户日志显示 **21 秒** → 预计算后实测 **约 5 秒**。
- 清理误插入到 `Update-Race` 里的重复状态变量行。

### 测试记录

**算法自测（race-data.json）**

NVIDIA 8GB（用户配置）Top4：
```
1. VI-BR-PORT       8.31  厂商匹配,显存接近,8GB实测
2. victory-unified  8.27  厂商匹配,显存接近,8GB实测
3. ztrx             8.14  厂商匹配,显存接近,8GB实测
4. AnyXboxX         8.10  厂商匹配,显存接近,8GB实测
AMD-only 项目：7900XTX 3.2 / Belobug 3.24 / BRVIctory 2.75（被正确压低）
```

NVIDIA 16GB：Vice-Tay / klbf-lab / Kelvaroq
AMD 16GB：klbf-lab / Belobug-AMD / 7900XTX

**GUI 实测**：`list filled → scored=26` 约 4~5 秒

---

## [v1.7.3] - 2026-11-26

### 修复
- 构建根目录为**无效盘符**（如 `Z:\nonexistent`）时 `Join-Path` 报错 → 改为静默回退。

### 测试记录（真实模拟用户环境）
```
隐藏 E:\gta6\work，BuildRoot = Z:\nonexistent
→ 自动切换 D:\gta6\work
→ builds=2：vf-test [diag] 13.6MB、cool_fox-pareto-residency-windows-x64 [exe] 9.5MB
```

---

## [v1.7.2] - 2026-11-26

### 修复（用户实机反馈）
- **任意盘的构建都能扫到**：用户构建在 `D:\gta6\work`，默认根目录 `E:\gta6\work` 扫不到。
- **Release 解压版识别**：`victory.exe` 不在 `target\diag|release\` 下的（如 `cool_fox-pareto-residency-windows-x64\victory.exe`）也能识别，显示 `[exe]`。
- 自动兜底目录：`E:\gta6\work`、`D:\gta6\work`、`%USERPROFILE%\gta6\work`、启动器目录\work、启动器目录，以及**所有盘符的 `X:\gta6\work` / `X:\gta6`**。

### 测试记录
- 标准构建 17 个 + 预编译 10 个 = **27 个全部识别**。

---

## [v1.7.1] - 2026-11-26

### 修复
- **扫描不到本地构建**：构建根目录为空/无效时直接返回 0，界面空白无提示。
- 扫不到时自动尝试常见目录，找到后**自动切换并写回配置**，日志逐条显示候选目录结果。
- 全部失败时弹窗提示，并给出目录结构要求：
  `工程名\target\diag\victory.exe` 或 `工程名\target\release\victory.exe`。

### 测试记录
```
正常配置：builds=17
BuildRoot=Z:\nonexistent：自动兜底到 E:\gta6\work，builds=17
```

---

## [v1.7] - 2026-11-26

### 修复
- **推荐区显示不全**：旧版把 13 行推荐文字塞进 150px 高的标签，底部"本地构建在榜情况/★本地最佳"被裁掉。
- 改为：推荐前 3 名 → **可点击列表**；本地构建在榜 → **单行摘要**。
- 程序化布局校验：页面最大底部 538px < 页面高度 568px，无溢出、无重叠。

### 新增
- **推荐项可直接拉取**：点选/双击推荐项 → 走"硬件适配检查 → Release/源码 ZIP"流程。
- **「打开项目仓库」按钮**。

---

## [v1.6] - 2026-11-26

### 新增
- **崩溃记录**：每次启动游戏将输出重定向到 `logs\game-时间.log`。
- **自动判定崩溃**：Breakpad/minidump、`panic`、设备移除（`0x887A0006` / `DXGI_ERROR_DEVICE`）、非 0 退出码、启动 10 秒内退出。
- **记录内容**：`logs\crashes.jsonl`（时间/原因/构建/主机模式/分辨率/缓存目录/运行秒数/最后 30 行日志）+ `logs\crash-时间.log`。
- **③ 页显示**：`崩溃记录：N 次 / 10（满 10 次自动清理日志）`。
- **满 10 次自动清理**：归档为 `crashes-archive-时间.jsonl`，游戏日志只留最近 2 个。
- **「打开日志目录」按钮**。

### 测试记录
- 模拟 11 次崩溃：自动归档触发（archives=1），清理后重新计数 ✅
- 真实启动：日志正常重定向（stdout 0.8KB / stderr 1.6MB），正常退出不误报 ✅

---

## [v1.5] - 2026-11-26

### 新增
- **没有 Release 也能拉**：无可用附件时弹窗「没有 Release，是否改为下载源码 ZIP？是/否」。
- **格式自适应**：Release 附件支持 `zip / 7z / tar.gz / tgz / exe`（7z 需装 7-Zip，tar.gz 用系统 tar）。
- **自动编译 + 自动部署**：源码 ZIP → 解压 → 自动找 Cargo.toml（支持嵌套）→ 编译（先 `--profile diag`，失败自动 `--release`）→ 找 `victory.exe` → 复制到规范目录并登记 → 自动刷新构建列表。

### 测试记录（真实端到端）
```
项目：avatarmanz/VIctory-7900XTX（无 Release）
releaseAssets=0 → 自动转源码 ZIP
下载 2,216 KB → 解压成功 → 自动找到 Cargo.toml
编译 1 分 35 秒 → 产物 victory.exe 11.2 MB
构建列表 16 → 17，可直接选择使用 ✅
```

---

## [v1.4] - 2026-11-26

### 修复
- **排版修复**：窗口 1060×820 → **1120×900**，Tab 区 1012×520 → **1072×600**，修复底部文字/按钮被裁切、⑤ 页控件重叠。

### 新增
- **排行榜可点击 → 拉取构建**：④ 页列表支持点选（或双击）项目后「拉取选中项目构建」。
- **不适配提醒**：拉取前检查项目测试硬件（厂商/显存）；不匹配时弹窗
  `配置可能不适配 … 是=继续，否=取消`。
- **拉取方式选择**：是=下载源码并编译 / 否=只下载源码 ZIP / 取消。

---

## [v1.3.1] - 2026-11-26

### 修复
- **`0x80070005`（拒绝访问）**：多开检测以前只检查"有窗口的 victory 进程"，另一个实例还在加载（窗口未出现）时拦不住，第二个实例因缓存/存档文件锁报错。
- 现在检测**任意 victory 进程**，提示具体 PID 并拒绝启动。

---

## [v1.3] - 2026-11-26

### 新增
- **⑤ 键盘映射**：每行一条 `源键 = 目标键`（如 `CapsLock = Escape`），支持 `#` 注释。
- 可用键名：`A-Z 0-9 F1-F12 Space Enter Esc Tab Shift Ctrl Alt CapsLock Backspace 方向键 Home End PgUp PgDn Insert Delete Num0-9`，也支持 `0x41` 形式的 VK 值。
- 系统级低级键盘钩子（`keymap.cs`），**仅在游戏窗口聚焦时生效**。
- `Ctrl+Alt+M` 随时开/关；勾选「启动游戏时自动开启映射」；关闭启动器自动卸载。
- 「测试按键」+ 状态栏显示最后捕获的键。

### 测试记录
- 映射表解析 3 条有效、错误键被识别（1 个错误）✅
- 键盘钩子安装/卸载正常：`installed=True → False` ✅

---

## [v1.2] - 2026-11-26

### 新增
- **④ 排行榜与推荐**：每次启动从 GTA VI PC Race（`vuyp.github.io/gta6-pc-race`）拉取排行榜，离线用缓存。
- 显示前 25 名：排名/阶段/画面/速度/稳定/仓库。
- **本机推荐**：按硬件打分（算法细节见 v1.8.0）。
- **本地构建在榜情况**：每个本地构建对应榜上项目及名次，白屏的 cool_fox 标注 ⚠。
- **★ 本地最适合你的构建**：自动排除已知问题构建。

---

## [v1.1] - 2026-11-26

### 首次整合发布
- 三个标签页：**① 设备与配置 / ② 构建与下载 / ③ 预热与启动**。
- **硬件自动检测**：NVIDIA 用 `nvidia-smi` 读显存，其它用 WMI；按厂商/显存推荐构建、主机模式、渲染分辨率。
- **构建管理**：扫描 `*/target/diag|release/victory.exe`，按硬件智能选择默认构建；显示分支@commit、翻译器版本、缓存状态。
- **GitHub 下载**：下载源码 ZIP / 下载 Release / 编译选中的源码（cargo）。
- **上游更新**：检查更新（git fetch，走代理）、更新并编译（自动备份 exe）、回滚上一版本。
- **预热**：预热着色器（`victory shaders shaders.rpf`）、预编译管线（`victory warm --used`）、全部预热（自动接续）；可中断续传。
- **启动游戏**：自动设置渲染缩放、两平面合成（修白屏）、纹理等待、光追跳过列表等环境变量。
- **防多开**、缓存过期提醒、配置持久化（`launcher-config.json`）。

### 修复的内部问题
- 预热成功判定：`Start-Process` 的 `ExitCode` 在 PowerShell 里始终为空 → 改为检测输出关键字（`shaders in the cache` / `file scan complete` / `made in \d+`）。
- .NET 异步 `OutputDataReceived` 导致预热闪退 → 改为临时文件轮询。
- 单选框互相取消（同容器分组问题）→ 每组放进独立 Panel。
- `New-Label` 未赋值会输出到 stdout → 改为 `$null =`。
- `Set-BuildEnv` 参数传哈希表导致目录为空 → 修正参数传递并加校验。

---

## 已知问题

| 问题 | 说明 |
|---|---|
| 上游 93 提交版本 | 在 8GB NVIDIA 上实测白屏/崩溃，不建议更新；可用「回滚上一版本」 |
| cool_fox 构建 | 白屏（已知问题），排行榜推荐里会标 ⚠ |
| vf-main 榜位映射 | 因 git origin 是 trustno1 仓库，显示为 VIctory-NVIDIA（已尽量按跟踪远端优先）|
| 排行榜数据 | 社区自报 + 第三方核实，仅供参考；推荐只代表硬件匹配度，不代表一定能跑 |
| 键盘钩子 | 部分游戏用 DirectInput 原始输入时可能收不到；杀毒软件可能拦截 |
| 拉取构建 | 需要能访问 GitHub（代理）与 Rust 工具链；源码仓库没有 Release 时会下载源码并编译（几分钟）|
| 8GB NVIDIA 性能 | 540p 下 GPU 满载，静止约 150ms/帧；降分辨率最有效 |
| 扫描器 | 只识别 `victory.exe` / `victory*.exe`；源码未编译（无 exe）的工程不会显示 |

---

## 版本命名说明

- 主版本 `1.x`：启动器功能集
- 次版本：新增功能（v1.2 排行榜、v1.3 键盘映射、v1.4 拉取构建、v1.5 Release 兜底、v1.6 崩溃记录、v1.7 排版修复、v1.8 推荐算法 v2）
- 修订版本 `.x`：问题修复（v1.3.1 多开、v1.7.1 扫描兜底、v1.7.2 任意盘扫描、v1.7.3 盘符容错）
## [v1.8.1] - 2026-11-26

### 修复
- **编译卡死 GUI**：编译从同步阻塞改为后台异步进程，主定时器轮询日志。
  - 状态栏实时显示 `编译中… mm:ss | <当前编译的 crate>`
  - 日志框每 3 秒追加最新输出行
  - 编译期间界面完全可操作；完成后自动部署 + 刷新构建列表
  - 失败自动重试 `cargo build --release`
- 新增 `Stop-Compile`（可停止正在进行的编译）

### 新增
- **git submodule 支持**：检测到 `.gitmodules` 时改用 `git clone --recursive --depth 1`（ZIP 不包含子模块内容）。

### 测试记录
- 编译可行性（2/2 成功）：
  - avatarmanz/VIctory-7900XTX：ZIP 2,216KB → 编译 1m35s → victory.exe 11.2MB
  - Itsbatt/victory-unified：ZIP 1,461KB → 编译 1m20s → victory.exe 8MB
  - 两个产物执行 `--version` 均输出 `victory 0.1.0`
- submodule 仓库：LooperSalty/AnyXboxX clone --recursive 成功（third_party/tombox 1616 文件）
- 异步编译实测：90 秒长编译期间界面定时器 tick 持续（elapsed 1→90），状态栏实时刷新

## [v1.9.0] - 2026-11-26

### 修复
- **legacy 包「有声音没画面」**：bat 里 `VICTORY_RESOLUTION`/`CARD_BUFFERS_MB` 写在 `victory.exe run` 之后不生效；启动器现在按构建能力补 env（legacy 用 `VICTORY_RESOLUTION`，新构建用 `RENDER_SCALE`），并统一 `VICTORY_WINDOW_PERCENT=88` 防止窗口盖满屏幕黑屏。
- Build-Env 切换构建时清理残留 env（避免 legacy→新构建残留 RESOLUTION）。
- 重打包 legacy 包（bat 顺序已修，原 zip 留 .bak）与 20261126b 包。

### 验证
- ENVDUMP 实测：legacy 构建 → `RESOLUTION=960x540 WINDOW_PERCENT=88`；新构建 → `RENDER_SCALE=0.5 WINDOW_PERCENT=88`
- bat 顺序验证：`set` 行（22-24）在 `victory.exe run`（25）之前
