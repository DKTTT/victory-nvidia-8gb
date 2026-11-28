// Running Neptune: its tuned switch set ([`Preset`]), Series S with the title's own upscaler or
// Series X, auto-A; the PC's paths from Settings.
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Neptune;

sealed class Launch
{
    readonly App app;
    readonly string settingsFile;
    readonly string logDir;
    readonly string historyFile;
    JsonObject settings = new();
    JsonObject history = new();   // per build: its runs (start, minutes, exit code) and its last shader warm-up
    Process? game;
    string? gameId;
    bool stopping;   // Stop was pressed: the exit that follows is not a crash
    Process? job;
    readonly Queue<(string label, string file, List<string> args, string cwd, Dictionary<string, string> env, Action<int>? done, bool low)> jobs = new();
    // (Victory) 全量预热时看护内存：可用内存低于 1.5 GB 就把预热进程降到 BelowNormal（ps1 的看护进程）
    CancellationTokenSource? warmWatch;
    bool warmWatchSaid;

    public Launch(App app, string profile)
    {
        this.app = app;
        settingsFile = Path.Combine(profile, "settings.json");
        logDir = Path.Combine(profile, "logs");
        historyFile = Path.Combine(profile, "history.json");
        try { if (File.Exists(settingsFile)) settings = JsonNode.Parse(File.ReadAllText(settingsFile))!.AsObject(); } catch { settings = new(); }
        try { if (File.Exists(historyFile)) history = JsonNode.Parse(File.ReadAllText(historyFile))!.AsObject(); } catch { history = new(); }
    }

    JsonObject Hist(string id) => history[id] as JsonObject ?? (JsonObject)(history[id] = new JsonObject { ["runs"] = new JsonArray() });
    void SaveHistory() { lock (history) try { File.WriteAllText(historyFile, history.ToJsonString()); } catch { } }
    void AddRun(string id, DateTime start, int code, bool stopped)
    {
        lock (history)
        {
            var runs = (JsonArray)Hist(id)["runs"]!;
            runs.Add(new JsonObject { ["start"] = start.ToString("o"), ["minutes"] = Math.Round((DateTime.Now - start).TotalMinutes, 1), ["code"] = code, ["stopped"] = stopped });
            while (runs.Count > 50) runs.RemoveAt(0);
        }
        SaveHistory();
    }
    JsonNode HistoryCopy() { lock (history) return JsonNode.Parse(history.ToJsonString())!; }
    void SetWarm(string id, int code, string key, double minutes, string? tier = null, int jobs = 0)
    {
        lock (history)
        {
            var h = Hist(id); h["warmAt"] = DateTime.Now.ToString("o"); h["warmCode"] = code; h["warmKey"] = key; h.Remove("warmStale");
            // (Victory) 全量预热记录档位与进程数；下次打开档位窗时用来估计时间
            h["warmFull"] = tier != null;
            if (tier != null) { h["warmTier"] = tier; h["warmJobs"] = jobs; }
            if (code == 0) h["warmMinutes"] = Math.Round(minutes, 1);   // (Neptune) for the Play dialog's estimate
        }
        SaveHistory();
    }

    // ---- settings ----
    string S(string key, string fallback = "") => (string?)settings[key] ?? fallback;
    bool B(string key, bool fallback) => settings[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    void Save() { File.WriteAllText(settingsFile, settings.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true })); }
    public string Setting(string key) => S(key);
    public void Set(string key, string value) { settings[key] = value; Save(); }
    // (Victory) the save data root chosen by launch.findSaves (empty: the %LOCALAPPDATA% default)
    public string DataDir => S("dataDir");

    public void SendSettings()
    {
        var copy = JsonNode.Parse(settings.ToJsonString())!.AsObject();
        var state = ShaderState("public");
        app.Post(new JsonObject
        {
            ["type"] = "settings", ["settings"] = copy,
            ["gameOk"] = File.Exists(S("game")) && Path.GetFileName(S("game")).Equals("game_scarlett_master.exe", StringComparison.OrdinalIgnoreCase),
            ["running"] = game != null, ["runningId"] = gameId, ["busy"] = job != null,
            ["warmJobsDefault"] = Math.Max(2, Environment.ProcessorCount / 2), ["cores"] = Environment.ProcessorCount,
            ["filesOk"] = ReleaseDir() != null, ["bundled"] = BundledRelease,
            ["fsrOk"] = S("fsrDll").Length == 0 || File.Exists(S("fsrDll")),
            ["dlssOn"] = B("dlss", false) && Rtx() >= 20,
            ["sl"] = SlStatus(),
            ["history"] = HistoryCopy(),
            // (Neptune) cold, failed, build, flags or warm, and the key it was judged by
            ["shaderState"] = state.state, ["warmKeyNow"] = state.key, ["toMake"] = state.toMake,
        });
    }

    // ---- (Neptune) DLSS and frame generation: NVIDIA RTX cards only, NVIDIA's files fetched on a click ----
    int rtx = -1;
    int Rtx()
    {
        if (rtx >= 0) return rtx;
        string gpu = "", driver = ""; long vram = 0;
        try { Gpu(ref gpu, ref driver, ref vram); } catch { }
        return rtx = Streamline.RtxGeneration(gpu);
    }
    // frames generated between two of the title's: 0 (off), 1 (2x), 2 (3x), 3 (4x), 5 (6x)
    int FrameGen() => settings["framegen"] is JsonValue v && v.TryGetValue<int>(out var n) && n is >= 0 and <= 5 ? n : 0;
    string SlDir() => S("streamlineDir") is { Length: > 0 } d ? d : Streamline.DefaultDir;
    JsonObject? SlStatus()
    {
        if (Rtx() < 20) return null;
        var dir = SlDir();
        return new JsonObject
        {
            ["dir"] = dir, ["own"] = S("streamlineDir").Length > 0, ["busy"] = Streamline.Busy,
            ["frameOk"] = Streamline.Missing(dir, Streamline.Needed(true, false)) == null,
            ["dlssOk"] = Streamline.Missing(dir, Streamline.Needed(false, true)) == null,
        };
    }
    // the switches for DLSS and frame generation, when asked for and possible; otherwise none, and why
    bool StreamlineEnv(Dictionary<string, string> env, List<string> notes)
    {
        var frames = FrameGen();
        var dlss = B("dlss", false);
        // (base, 5b8ef4975) The in-game F1 menu's last choice (menu.txt, read into env above) is newer than
        // Settings: it wins, through the same checks. It names frames shown per rendered one (VICTORY_FRAMEGEN_X).
        if (env.Remove("VICTORY_DLSS", out var menuDlss)) dlss = menuDlss.Trim() == "1";
        env.Remove("VICTORY_FRAMEGEN_X", out var menuTimes);
        if (env.Remove("VICTORY_FRAMEGEN", out var menuFg))
            frames = menuFg.Trim() != "1" ? 0 : int.TryParse(menuTimes, out var x) && x >= 2 ? Math.Min(x - 1, 5) : 1;
        if (frames == 0 && !dlss) return false;
        var gen = Rtx();
        string? why = null;
        if (!OperatingSystem.IsWindows()) why = "NVIDIA 的文件仅在 Windows 上检查";
        else if (gen < 20) why = "未找到 NVIDIA RTX 显卡";
        if (why == null && frames > 0 && gen < 40) { notes.Add("帧生成需要 RTX 40 或 50 显卡：已关闭"); frames = 0; }
        if (why == null && frames > 1 && gen < 50) { notes.Add("超过 2 倍需要 RTX 50 显卡：改为 2 倍"); frames = 1; }
        if (frames > 0 && !env.ContainsKey("VICTORY_THIN") && env.GetValueOrDefault("VICTORY_ASYNC_SUBMIT") != "1")
        { notes.Add("帧生成需要“额外绘制线程”（设置 › 性能）：已关闭"); frames = 0; }
        if (frames > 0 && !dlss && B("seriesX", false))
        { notes.Add("在清晰（Series X）模式下开启帧生成还需要 DLSS 超分：已关闭"); frames = 0; }
        if (why == null && frames == 0 && !dlss) why = "没有可开启的选项";
        if (why == null && Streamline.Missing(SlDir(), Streamline.Needed(frames > 0, dlss)) is string missing)
            why = missing + "（设置 › 画面 › 获取 NVIDIA 文件）";
        if (why != null) { notes.Add("DLSS 与帧生成已关闭：" + why); return false; }
        env["VICTORY_STREAMLINE_DIR"] = WinPath(Path.GetFullPath(SlDir()));
        // VICTORY_FRAMEGEN_FRAMES: frames generated between two rendered (ours); VICTORY_FRAMEGEN_X: frames shown
        // for each rendered one (the base's streamline.rs, which reads either).
        if (frames > 0) { env["VICTORY_FRAMEGEN"] = "1"; env["VICTORY_FRAMEGEN_FRAMES"] = frames.ToString(); env["VICTORY_FRAMEGEN_X"] = (frames + 1).ToString(); }
        if (dlss) env["VICTORY_DLSS"] = "1";
        notes.Add($"使用 NVIDIA Streamline：DLSS 超分{(dlss ? "开启" : "关闭")}，帧生成 {(frames > 0 ? (frames + 1) + "x" : "关闭")}，NVIDIA 文件位于 {SlDir()}");
        return dlss;
    }

    public void OnMessage(string cmd, JsonObject m)
    {
        switch (cmd)
        {
            case "set":
                foreach (var kv in m["values"]!.AsObject()) settings[kv.Key] = kv.Value?.DeepClone();
                Save(); SendSettings(); break;
            case "pickGame":
                if (app.Host.PickFile("你的游戏：game_scarlett_master.exe", "game_scarlett_master.exe", "游戏（game_scarlett_master.exe）") is string g) Set("game", g);
                SendSettings(); break;
            case "pickFolder":
                var key = (string?)m["key"] ?? "";
                if (key is "optiScaler" or "neptuneDir" or "streamlineDir" && app.Host.PickFolder((string?)m["title"] ?? "选择文件夹") is string f) Set(key, f);
                SendSettings(); break;
            case "pickFile":
                if ((string?)m["key"] == "fsrDll" && app.Host.PickFile("PC 版 amd_fidelityfx_upscaler_dx12.dll", "*.dll", "DLL 文件 (*.dll)") is string d) Set("fsrDll", d);
                if ((string?)m["key"] == "keyIcons" && app.Host.PickFile("键盘提示图标（tools\\gfx_input_icons.py）", "*.gfx", "GFX 影片 (*.gfx)") is string k) Set("keyIcons", k);
                SendSettings(); break;
            case "preset":
                var t = Target((string?)m["id"] ?? "public");
                app.Post(new JsonObject { ["type"] = "preset", ["id"] = (string?)m["id"], ["flags"] = PresetJson(t.playPs1),
                    ["exe"] = t.exeDir == null ? null : Path.Combine(t.exeDir, "victory.exe") });
                break;
            // (Neptune) off the UI thread: the start may make the keyboard prompt icons first (KeyIcons)
            case "run":
                if (Interlocked.Exchange(ref starting, 1) != 0) break;
                var (rid, rov, rargs) = ((string?)m["id"] ?? "public", m["overrides"] as JsonObject, (string?)m["args"] ?? "");
                _ = Task.Run(() =>
                {
                    try { Run(rid, rov, rargs); }
                    catch (Exception e) { app.Out($"\n无法启动游戏：{e.Message}\n", "bad"); }
                    finally { Interlocked.Exchange(ref starting, 0); }
                });
                break;
            // (Victory) 预热着色器：先给页面「火力全开」的档位与警告，确认后再跑全量预热（不带 --used）
            case "warm": SendWarmTiers((string?)m["id"] ?? "public"); break;
            case "warmStart": StartWarmTier((string?)m["id"] ?? "public", (string?)m["tier"] ?? "balanced"); break;
            // (Victory) 自动查找游戏目录（欢迎向导与设置里都有按钮）
            case "findGame": _ = Task.Run(() => FindGame()); break;
            // (Victory) 自动查找本地存档（存档页与 设置 › 存档 都有按钮）
            case "findSaves": _ = Task.Run(() => FindSaves()); break;
            case "stop": stopping = true; try { game?.Kill(true); } catch { } break;
            case "cancelJob": try { job?.Kill(true); } catch { } break;
            case "openLogs": Directory.CreateDirectory(logDir); Open(logDir); break;
            // (Victory) the docs shipped with the release: opened from the package folder or the extracted payload
            case "openDoc": OpenDoc((string?)m["key"] ?? ""); break;
            case "pcinfo": _ = Task.Run(SendPcInfo); break;
            // (Neptune) the only download of NVIDIA's files: on the player's click
            case "getStreamline":
                if (Rtx() < 20 || Streamline.Busy) break;
                Set("streamlineDir", "");
                // full: the home page's Get DLSS asks for all eight files (frame generation and upscaling)
                var full = m["full"] is JsonValue fv && fv.TryGetValue<bool>(out var fb) && fb;
                _ = Task.Run(() => Streamline.FetchAsync(app, full || B("dlss", false), SendSettings));
                break;
        }
    }

    // ---- which build: the public one (a release folder) or, in the dev edition, a branch ----
    public (string? exeDir, string? playPs1, string label) Target(string id) => (ReleaseDir(), null, "victory");

    // the release this launcher came in: it ships beside victory.exe. A folder chosen in
    // Settings is only for a launcher that isn't in a release folder (testing from a build).
    static string Bundled => AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    // a single-exe build (-Bundle) carries its release inside the exe: Payload extracts it to %LOCALAPPDATA%
    static string? PayloadDir => Payload.Root;
    // this launcher carries its own release: a package folder (victory.exe beside it) or the extracted payload
    static bool BundledRelease => File.Exists(Path.Combine(Bundled, "victory.exe")) || PayloadDir != null;
    // built from a source tree (launcher\dist\ProjectNeptuneVI): the tree's root, where Neptune-Launcher.cmd is
    static string Tree => Path.GetFullPath(Path.Combine(Bundled, "..", "..", ".."));
    // (Neptune) the first line of a text file beside Neptune-Launcher.cmd (or in the chosen Neptune folder, or
    // beside the launcher), quotes allowed; null when there is none
    string? Pinned(string name) => new[] { Tree, S("neptuneDir"), Bundled }.Where(d => d.Length > 0).Select(d => Path.Combine(d, name))
        .Where(File.Exists).Select(f => { try { return File.ReadLines(f).FirstOrDefault()?.Trim().Trim('"') ?? ""; } catch { return ""; } })
        .FirstOrDefault(l => l.Length > 0);
    public string? ReleaseDir()
    {
        if (File.Exists(Path.Combine(Bundled, "victory.exe"))) return Bundled;
        // a -Bundle build: victory.exe, ui, amd-sdk and shvi came out of the exe's payload
        if (PayloadDir is string payload && File.Exists(Path.Combine(payload, "victory.exe"))) return payload;
        var tree = Tree;
        var chosen = S("neptuneDir");
        // (Neptune) neptune-build.txt beside Neptune-Launcher.cmd: one line, the folder of a victory.exe built
        // outside the tree (CARGO_TARGET_DIR\release), or that victory.exe; it comes before the tree's target\release
        var pinned = Pinned("neptune-build.txt");
        if (pinned != null && pinned.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) pinned = Path.GetDirectoryName(pinned);
        // a chosen release folder, or a source tree (or a folder inside it) with its build in target\release
        var dirs = new List<string>();
        if (!string.IsNullOrEmpty(pinned)) dirs.Add(pinned);
        dirs.Add(Path.Combine(tree, "target", "release"));
        if (chosen.Length > 0) dirs.AddRange([chosen, Path.Combine(chosen, "target", "release"), Path.Combine(chosen, "..", "target", "release")]);
        return dirs.Select(Path.GetFullPath).FirstOrDefault(d => File.Exists(Path.Combine(d, "victory.exe")));
    }
    // this release, for the header: release.json beside victory.exe (version, commit, date), or a team
    // build's commit.txt (its commit, no version); nothing for a dev build
    public JsonObject ReleaseInfo()
    {
        var dir = ReleaseDir();
        var info = new JsonObject();
        try
        {
            var file = dir == null ? null : Path.Combine(dir, "release.json");
            if (file != null && File.Exists(file) && JsonNode.Parse(File.ReadAllText(file)) is JsonObject j)
            {
                foreach (var key in new[] { "version", "commit", "date" })
                    if (j[key] is JsonValue v) info[key] = v.ToString();
            }
            else if (dir != null && File.Exists(Path.Combine(dir, "commit.txt")))
                info["commit"] = File.ReadAllText(Path.Combine(dir, "commit.txt")).Trim();
        }
        catch { }
        return info;
    }

    // ---- the tuned switch set: (name, value, note) ----
    static readonly (string, string, string)[] Switches =
    [
        ("VICTORY_TEXTURE_MIP_DROP", "1", "textures lose their smallest level: less video memory"),
        ("VICTORY_CARD_WINDOWS_MB", "256", "video memory the card window may hold"),
        ("VICTORY_TEXTURE_ROOM_PERCENT", "92", "share of the card's memory textures may fill"),
        ("VICTORY_TEXTURE_STAGE_MB", "256", "staging for texture uploads"),
        ("VICTORY_BAKE_TEXTURES_MS", "3000", "longer texture bake at load: fewer unlit or missing textures"),
        ("VICTORY_EARLY_TEXTURES_MS", "35", "early upload budget: fewer missing textures in the first frames"),
        ("VICTORY_CARD_ROOM_FOR_TARGETS_MB", "768", "room kept for render targets"),
        ("VICTORY_AMBIENT", "0.8", "the stand-in for the indirect light the rays would trace"),
        ("VICTORY_AMBIENT_AIR", "1.5", "what the air scatters indoors, bounded by the light around"),
        ("VICTORY_THIN", "1", "draw calls translated by more threads"),
        ("VICTORY_JOIN_PARTS", "8", ""),
        ("VICTORY_JOIN_COPIES", "1", ""),
        ("VICTORY_UPLOAD_AHEAD", "1", ""),
        ("VICTORY_CARD_AWAKE", "1", ""),
        ("VICTORY_CARD_STEPS", "2", ""),
        ("VICTORY_INDIRECT_WINDOW", "1", ""),
        ("VICTORY_INDIRECT_BATCH", "2", ""),
        ("VICTORY_PLACED_ORDER", "1", "a draw reading a card-side buffer copy waits for that copy only"),
        ("VICTORY_SHOW_AFTER", "1", ""),
        ("VICTORY_RELAY", "2", ""),
        ("VICTORY_RELAY_COPY", "1", ""),
        ("VICTORY_WIDE_BACK", "1", ""),
        ("VICTORY_MAP_THREADS", "1", ""),
        ("VICTORY_CARD_BUFFERS_MIN_KB", "64", ""),
        ("VICTORY_LEVELS_ON_DEMAND", "1", "textures hold only the mip levels in use (8 GB cards)"),
        ("VICTORY_CARD_REHASH_RUNS", "1", ""),
        ("VICTORY_PIPELINE_BOOK", "1", "the pipelines a run uses are written down; Warm then makes them ahead"),
        ("VICTORY_LOG", "warn", ""),
    ];
    public static List<(string name, string value, string note)> Preset(string? _) => [.. Switches];
    static JsonArray PresetJson(string? playPs1)
    {
        var a = new JsonArray();
        foreach (var (n, v, note) in Preset(playPs1)) a.Add(new JsonObject { ["name"] = n, ["value"] = v, ["note"] = note });
        return a;
    }

    // ---- the run ----
    int starting;   // a Play is being started (on a worker thread): a second click waits for it
    void Run(string id, JsonObject? overrides, string extraArgs)
    {
        if (game != null) { app.Out("\n游戏已在运行。\n", "bad"); return; }
        // (Neptune) a count being asked (victory.exe warm --count, a second or so) ends first
        for (int i = 0; i < 120 && Volatile.Read(ref counting) != 0; i++) Thread.Sleep(100);
        if (Process.GetProcessesByName("victory").Length > 0) { app.Out("\n已有 victory.exe 在运行：请先关闭。\n", "bad"); return; }
        var (exeDir, play, label) = Target(id);
        var exe = exeDir == null ? "" : Path.Combine(exeDir, "victory.exe");
        if (!File.Exists(exe)) { app.Out($"\n在 {exeDir ?? "（未设置文件夹）"} 中没有 victory.exe：请构建它，或设置 Neptune 文件夹。\n", "bad"); return; }
        var gamePath = S("game");
        if (!File.Exists(gamePath)) { app.Out("\n请先设置你的游戏（设置 › 通用）。\n", "bad"); return; }

        var console = new List<string>();
        var notes = new List<string>();
        var env = Env(id, exeDir!, play, overrides, console, say: true, notes);
        // the shader cache is keyed on the switches the translator reads: a warm-up made with
        // other flags may not be found, and the run then translates as it plays
        var key = WarmKey(env, exe);
        lock (history)
            if (Hist(id)["warmAt"] != null && (string?)Hist(id)["warmKey"] != key)
            {
                Hist(id)["warmStale"] = true;
                if (BuildPart((string?)Hist(id)["warmKey"]) != BuildPart(key))
                    app.Out("\n自上次预热后游戏版本已更新：其管线将在游玩时生成（卡顿、暗区）。请为此版本重新预热。\n", "bad");
                else
                    app.Out("\n自上次预热后设置已更改：着色器可能在游玩时转译（卡顿、CPU 占用 100%）。请使用当前设置重新预热。\n", "bad");
            }

        var args = new List<string> { "play", WinPath(Path.GetFullPath(gamePath)) };
        args.AddRange(console);
        var fgFrames = FrameGen();
        var dlssOn = B("dlss", false);
        if (dlssOn) { args.AddRange(["--dlss", S("dlssMode", "quality")]); env["VICTORY_DLSS"] = "1"; }
        if (fgFrames > 0)
        {
            args.AddRange(["--framegen", (fgFrames + 1).ToString()]);
            if (dlssOn) args.AddRange(["--fg-type", "dlss"]);
        }
        // `play` clears the VICTORY_* it inherits: the switches go in with --set
        foreach (var kv in env) args.AddRange(["--set", kv.Key + "=" + kv.Value]);
        args.AddRange(SplitArgs(extraArgs));
        var (file, all) = Wrap(exe, args);
        Directory.CreateDirectory(logDir);
        var logPath = Path.Combine(logDir, label + "-run.log");
        var log = new StreamWriter(logPath, false, new UTF8Encoding(false)) { AutoFlush = true };
        log.WriteLine("launcher: " + string.Join(" ", env.Where(kv => kv.Key.StartsWith("VICTORY_")).Select(kv => $"{kv.Key}={kv.Value}")));
        foreach (var n in notes) { log.WriteLine("launcher: " + n); app.Out($"\nlauncher: {n}\n", n.StartsWith("使用 NVIDIA") || (n.StartsWith("键盘提示图标：") && !n.Contains("手柄")) ? "ok" : "bad"); }
        var psi = Start(file, all, exeDir!, env);
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        var started = DateTime.Now;
        var pending = new StringBuilder(); var gate = new object();
        void Line(string? s) { if (s == null) return; log.WriteLine(s); lock (gate) { if (pending.Length < 200_000) pending.AppendLine(s); } }
        p.OutputDataReceived += (_, e) => Line(e.Data);
        p.ErrorDataReceived += (_, e) => Line(e.Data);
        var timer = new System.Threading.Timer(_ => { string t; lock (gate) { t = pending.ToString(); pending.Clear(); } if (t.Length > 0) app.Out(t, "game"); }, null, 250, 250);
        p.Exited += (_, _) =>
        {
            timer.Dispose();
            string t; lock (gate) { t = pending.ToString(); pending.Clear(); }
            if (t.Length > 0) app.Out(t, "game");
            var code = 0; try { code = p.ExitCode; } catch { }
            log.WriteLine($"launcher: ended with code {code}"); log.Dispose();
            game = null; gameId = null;
            AddRun(id, started, code, stopping);
            stopping = false;
            app.Out($"\n--- 游戏已结束（代码 {code}）；日志：{logPath} ---\n", code == 0 ? "ok" : "bad");
            app.Post(new JsonObject { ["type"] = "game", ["state"] = "end", ["id"] = id, ["code"] = code });
            SendSettings();
        };
        game = p; gameId = id; stopping = false;
        p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
        app.Out($"\n=== {label}：运行中 ===\n", "h");
        app.Post(new JsonObject { ["type"] = "game", ["state"] = "start", ["id"] = id });
        SendSettings();
    }

    // the run's switches, the tuned set, then the tester's own changes
    // notes: what the launcher turned off and why, for the run's log (null for the warm-up)
    Dictionary<string, string> Env(string id, string exeDir, string? play, JsonObject? overrides, List<string> console, bool say, List<string>? notes = null)
    {
        var env = new Dictionary<string, string>();
        foreach (var (n, v, _) in Preset(play)) env[n] = v;
        // (GTA6 CN) the console profile is a flag of `play`, not an env switch
        console.AddRange([B("seriesX", false) ? "--series-x" : "--series-s"]);
        // victory-cache.txt beside the launcher: one line, the cache folder; a single-exe build keeps the
        // cache in its extracted payload, not in whatever folder the player happened to launch from
        var pinned = Pinned("victory-cache.txt");
        var home = File.Exists(Path.Combine(Bundled, "victory.exe")) ? Bundled : (PayloadDir ?? Bundled);
        if (!env.ContainsKey("VICTORY_CACHE_DIR"))
            env["VICTORY_CACHE_DIR"] = WinPath(pinned ?? Path.Combine(home, "cache"));
        // (Victory) the save data root: the auto-found/selected dataDir, else %LOCALAPPDATA%\victory\data
        env["VICTORY_DATA_DIR"] = WinPath(S("dataDir") is { Length: > 0 } dataDir
            ? dataDir
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "victory", "data"));
        env["VICTORY_GAME_DIR"] = WinPath(Path.GetDirectoryName(Path.GetFullPath(S("game")))!);
        // the release's own upscaler / frame-generation folders, beside victory.exe (the package folder or
        // the extracted payload), then optional drop-in folders beside a single-exe launcher as an override
        foreach (var baseDir in new[] { exeDir, Bundled }.Where(d => d.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var amd = Path.Combine(baseDir, "amd-sdk");
            if (Directory.Exists(amd) && !env.ContainsKey("VICTORY_FSR_DIR")) env["VICTORY_FSR_DIR"] = WinPath(amd);
            var sm86 = Path.Combine(baseDir, "dlssg-sm86");
            if (Directory.Exists(sm86) && !env.ContainsKey("VICTORY_DLSSG_SM86_DIR")) env["VICTORY_DLSSG_SM86_DIR"] = WinPath(sm86);
            foreach (var n in new[] { "nvidia-sdk", "dlssg-sm86", "dlssg", "streamline" })
            {
                var d = Path.Combine(baseDir, n);
                if (Directory.Exists(d) && !env.ContainsKey("VICTORY_STREAMLINE_DIR")) { env["VICTORY_STREAMLINE_DIR"] = WinPath(d); break; }
            }
        }
        // "Save video memory", for cards under 16 GB
        if (B("vramSaver", false)) { env.Remove("VICTORY_CARD_WINDOWS_MB"); env["VICTORY_CARD_BUFFERS_MB"] = "1024"; }
        overrides ??= settings["ov:" + id] as JsonObject;
        if (overrides != null)
            foreach (var kv in overrides)
            {
                if (!Regex.IsMatch(kv.Key, "^[A-Z][A-Z0-9_]{1,63}$")) continue;
                var val = (kv.Value as JsonValue)?.ToString() ?? "";
                if (val.Length == 0) env.Remove(kv.Key); else env[kv.Key] = val;
            }
        if (!B("thin", true)) env.Remove("VICTORY_THIN");
        // (Victory) the bundled script hook + trainer: F4 in game
        if (B("trainer", false) && exeDir.Length > 0)
        {
            var shvi = Path.Combine(exeDir, "shvi", "shvi_core.dll");
            if (File.Exists(shvi)) env["VICTORY_LOAD_DLLS"] = WinPath(shvi);
            else notes?.Add("the trainer (shvi\\shvi_core.dll) is missing: started without it");
        }
        // (Victory) keyboard and mouse (on by default, as the reference): off = controller only
        if (!B("keyboard", true)) env["VICTORY_KEYBOARD"] = "0";
        // (Victory) keyboard prompt icons: a .gfx of the player's, or one made from their own data.rpf,
        // replacing the title's controller prompts through VICTORY_REPLACE_STREAMS.
        if (B("keyIcons", true) && !env.ContainsKey("VICTORY_REPLACE_STREAMS"))
        {
            try
            {
                var game = S("game");
                string? icons = null;
                var from = "your own file";
                var own = S("keyIconsFile");
                if (own.Length > 0 && File.Exists(own)) icons = own;
                if (icons == null)
                {
                    foreach (var d in new[] { exeDir, Bundled, Path.GetDirectoryName(game) ?? "" })
                    {
                        if (d.Length == 0) continue;
                        var f = Path.Combine(d, "mods", "input_icons_kbm.gfx");
                        if (File.Exists(f)) { icons = f; from = "the mods folder"; break; }
                    }
                }
                if (icons == null && game.Length > 0 && File.Exists(game))
                {
                    icons = KeyIcons.Ensure(Path.GetDirectoryName(Path.GetFullPath(game))!, notes);
                    from = "your game files";
                }
                if (icons != null && File.Exists(icons))
                {
                    env["VICTORY_REPLACE_STREAMS"] = "data.rpf@293433344=" + WinPath(Path.GetFullPath(icons));
                    notes?.Add($"keyboard prompt icons: {icons} ({from})");
                }
            }
            catch (Exception e) { notes?.Add("keyboard prompt icons: skipped (" + e.Message + ")"); }
        }
        return env;
    }
    public int WarmJobs()
    {
        var n = settings["warmJobs"] is JsonValue v && v.TryGetValue<int>(out var i) ? i
              : settings["warmJobs"] is JsonValue w && int.TryParse(w.ToString(), out var j) ? j : 0;
        return n >= 1 ? Math.Min(n, Environment.ProcessorCount) : Math.Max(2, Environment.ProcessorCount / 2);
    }

    // (Neptune) What a warm-up is good for: the game build and the switches the translator reads.
    // The build is victory.exe's size and time of writing, as the runtime stamps its pipeline store with
    // (crates/victory-gpu/src/pipeline/library.rs, this_build: another build sets the store aside). The
    // switches are those of the translation key (crates/victory-gpu/src/shader_cache.rs, build(); and
    // VICTORY_RAW_VIEWS through host_settings()): nothing else, so Series S / Series X, the memory saver,
    // DLSS and the rest never make a warm-up stale. Keep this list in step with shader_cache.rs.
    static readonly string[] TranslatorSwitches =
    [
        "VICTORY_WAVE_WIDE", "VICTORY_WAVE_DEEP_SKIPS", "VICTORY_WAVE_OWN_BITS", "VICTORY_WAVE_LOCAL", "VICTORY_WAVE_PAIRS",
        "VICTORY_WAVE_AFTER_LOOPS", "VICTORY_LDS_FLAGS", "VICTORY_WAVE_SCALAR_JOINS", "VICTORY_F16_NEAREST", "VICTORY_HELPER_OWN",
        "VICTORY_FIRSTLANE_OWN", "VICTORY_FIRST_HALF", "VICTORY_STRICT_JOINS", "VICTORY_MESH_OUTPUT_STRICT", "VICTORY_BVH_FENCES",
        "VICTORY_BVH_BOUNDS", "VICTORY_NAN_GUARD", "VICTORY_SHADER_LOOP_LIMIT", "VICTORY_GROUP_SYNC", "VICTORY_SHADER_OPT",
        "VICTORY_RAW_VIEWS",
    ];
    static string BuildStamp(string exe)
    {
        try { var f = new FileInfo(exe); return f.Exists ? $"{f.Length} {new DateTimeOffset(f.LastWriteTimeUtc).ToUnixTimeSeconds()}" : "none"; }
        catch { return "none"; }
    }
    // "build=<size> <unix seconds>|NAME=value;NAME=value" (only the translator's switches that are set)
    static string WarmKey(Dictionary<string, string> env, string exe) => "build=" + BuildStamp(exe) + "|" + string.Join(";", env
        .Where(kv => TranslatorSwitches.Contains(kv.Key))
        .OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => kv.Key + "=" + kv.Value));
    static string BuildPart(string? key) => key != null && key.StartsWith("build=") && key.IndexOf('|') is int i and > 0 ? key[..i] : "";

    // (Neptune) "Out of date" only when this many pipelines or more are still to make: fewer are made
    // during play without being noticed (a rebuild re-made about 300 in a second).
    const int OutOfDateAt = 1000;

    // the shader state for these switches and this build: cold, failed, build (another build), flags, out
    // (the same build and switches, but OutOfDateAt or more to make), warm; and how many are to make
    // (victory.exe warm --count; null until known, or for an exe without --count: then the key alone decides)
    (string state, string? key, int? toMake) ShaderState(string id)
    {
        try
        {
            var exeDir = ReleaseDir();
            if (exeDir == null || !File.Exists(S("game"))) return ("cold", null, null);
            var exe = Path.Combine(exeDir, "victory.exe");
            var env = Env(id, exeDir, null, null, [], say: false);
            var key = WarmKey(env, exe);
            lock (history)
            {
                var h = Hist(id);
                var warmed = h["warmAt"] != null;
                var ok = h["warmCode"] is JsonValue c && c.TryGetValue<int>(out var code) && code == 0;
                var had = (string?)h["warmKey"];
                // asked once per build and switches, and again after each warm-up and each session (the first
                // session writes the list of pipelines the count reads)
                var countKey = key + "|" + (string?)h["warmAt"] + "|" + ((h["runs"] as JsonArray)?.Count ?? 0);
                (int known, int left)? n; bool asked;
                lock (toMake) asked = toMake.TryGetValue(countKey, out n);
                if (!asked) AskCount(countKey, exe, exeDir, env);
                // nothing known yet: the title writes its list of pipelines the first time it runs, so a
                // new PC has nothing to warm before one session ("empty": no warning at Play either)
                if (n is (0, _)) return ("empty", key, 0);
                if (n is (_, int left))
                {
                    if (left < OutOfDateAt) return ("warm", key, left);
                    if (!warmed) return ("cold", key, left);
                    if (!ok) return ("failed", key, left);
                    return (had == key ? "out" : BuildPart(had) != BuildPart(key) ? "build" : "flags", key, left);
                }
                if (!warmed) return ("cold", key, null);
                if (!ok) return ("failed", key, null);
                if (had == key) return ("warm", key, null);
                return (BuildPart(had) != BuildPart(key) ? "build" : "flags", key, null);
            }
        }
        catch { return ("cold", null, null); }
    }

    // ---- (Neptune) how many pipelines a warm-up would make now: victory.exe warm --count ----
    readonly Dictionary<string, (int known, int left)?> toMake = new();   // count key -> known, to make (null: not to be told)
    readonly Dictionary<string, bool> knowsCount = new();  // build stamp -> its warm command has --count
    int counting;
    static readonly Regex ToMakeLine = new(@"(\d+) pipelines known, (\d+) made before \([^)]*\), (\d+) bad; (\d+) to make");
    public static int? ParseToMake(string text) => ParseCount(text)?.left;
    // (known, to make) from the warm command's first line
    public static (int known, int left)? ParseCount(string text) =>
        ToMakeLine.Match(text) is { Success: true } m && int.TryParse(m.Groups[1].Value, out var k) && int.TryParse(m.Groups[4].Value, out var n) ? (k, n) : null;

    // off the UI thread, hidden, with the warm-up's own switches; never while the game or a job runs. An exe
    // without --count would start a real warm-up, so its warm --help must name the flag first.
    void AskCount(string countKey, string exe, string exeDir, Dictionary<string, string> env)
    {
        if (game != null || job != null || Interlocked.Exchange(ref counting, 1) != 0) return;
        var envCopy = new Dictionary<string, string>(env) { ["VICTORY_LOG"] = "warn" };
        _ = Task.Run(() =>
        {
            var n = CountNow(exe, exeDir, envCopy);
            lock (toMake) toMake[countKey] = n;
            Interlocked.Exchange(ref counting, 0);
            SendSettings();
        });
    }
    // the count now (a few tenths of a second), or null: no --count in this exe, a timeout, a failure
    (int known, int left)? CountNow(string exe, string exeDir, Dictionary<string, string> env)
    {
        try
        {
            var stamp = BuildStamp(exe);
            bool knows, asked;
            lock (toMake) asked = knowsCount.TryGetValue(stamp, out knows);
            if (!asked)
            {
                var (hc, help) = RunQuiet(exe, ["warm", "--help"], exeDir, env);
                knows = hc == 0 && help.Contains("--count");
                lock (toMake) knowsCount[stamp] = knows;
            }
            if (knows && RunQuiet(exe, ["warm", "--count"], exeDir, env) is (0, var text)) return ParseCount(text);
        }
        catch { }
        return null;
    }
    (int code, string text) RunQuiet(string exe, List<string> args, string cwd, Dictionary<string, string> env)
    {
        var (file, all) = Wrap(exe, args);
        using var p = new Process { StartInfo = Start(file, all, cwd, env) };
        var sb = new StringBuilder();
        p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (sb) sb.AppendLine(e.Data); };
        p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
        try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        if (!p.WaitForExit(10_000)) { try { p.Kill(true); } catch { } return (-1, ""); }
        p.WaitForExit();
        lock (sb) return (p.ExitCode, sb.ToString());
    }

    // ---- (Victory) 预热着色器：「火力全开」档位（照 预热-火力全开.ps1 的算法） ----
    // 安静/平衡/暴力/极强：预热进程数、内核子进程优先级、每批管线数；进程数封顶 48。
    // ps1 里分别叫 静音/平衡/暴力/极限，这里是同一套算法与数值。
    sealed record WarmTier(string Key, string Name, string Alias, int Jobs, string Priority, string PriorityText, string Batch);

    static List<WarmTier> Tiers(int cores)
    {
        static int Cap(int n) => Math.Clamp(n, 1, 48);
        return
        [
            new("quiet",    "安静", "静音", Cap(Math.Max(1, cores / 8)),                     "idle",   "空闲",     "40"),
            new("balanced", "平衡", "",     Cap(Math.Max(2, (int)Math.Floor(cores * 0.75))), "normal", "普通",     "40"),
            new("turbo",    "暴力", "",     Cap(Math.Min(Math.Max(4, cores * 2), 48)),       "above",  "高于普通", "80"),
            new("extreme",  "极强", "极限", Cap(Math.Min(Math.Max(4, cores * 2), 48)),       "high",   "高",       "160"),
        ];
    }

    // (Victory) ps1 的内存保险：每个预热进程约 0.75 GB，另外给系统留 4 GB：
    // 只有 freeGB ≥ jobs×0.75 + 4 才开得下；否则 cap = max(2, floor((freeGB − 3) / 0.75))，并封顶 48。
    static double FreeGb()
    {
        long total = 0, free = 0;
        Memory(ref total, ref free);
        return free / 1073741824.0;
    }
    static (int jobs, string? note) GuardJobs(int want)
    {
        var jobs = Math.Clamp(want, 1, 48);
        string? note = jobs < want ? $"预热进程数上限 48：从 {want} 降到 {jobs}（安全起见）" : null;
        double free;
        try { free = FreeGb(); } catch { return (jobs, note); }
        if (free > 0 && free < jobs * 0.75 + 4)
        {
            var cap = Math.Max(2, (int)Math.Floor((free - 3) / 0.75));
            if (jobs > cap)
            {
                note = $"内存只有 {free:N1} GB 空闲，预热进程数从 {jobs} 降到 {cap}（安全起见）";
                jobs = Math.Max(2, cap);
            }
        }
        return (jobs, note);
    }
    double LastWarmMinutes(string id)
    {
        lock (history)
        {
            var v = Hist(id)["warmMinutes"];
            if (v is JsonValue j && j.TryGetValue<double>(out var d)) return d;
            if (v is JsonValue i && i.TryGetValue<int>(out var n)) return n;
            return 0;
        }
    }
    // 预计时间：用上次预热在历史里记下的分钟数；还没有就照实说
    string EtaText(string id)
    {
        var mins = LastWarmMinutes(id);
        if (mins <= 0) return "首次无法准确估计";
        if (mins < 1) return "上次不到 1 分钟";
        var m = (int)Math.Round(mins);
        return m < 60 ? $"上次约 {m} 分钟" : $"上次约 {m / 60} 小时 {m % 60} 分钟";
    }
    // 页面点「预热着色器」时先给档位表：数值与真正运行时一致（进程数已按当前内存下调）
    void SendWarmTiers(string id)
    {
        var cores = Environment.ProcessorCount;
        double free = 0; try { free = FreeGb(); } catch { }
        var tiers = new JsonArray();
        var lowered = false;
        foreach (var t in Tiers(cores))
        {
            var (jobs, note) = GuardJobs(t.Jobs);
            if (note != null) lowered = true;
            tiers.Add(new JsonObject
            {
                ["key"] = t.Key, ["name"] = t.Name, ["alias"] = t.Alias.Length > 0 ? t.Alias : null,
                ["jobs"] = jobs, ["priority"] = t.Priority, ["priorityText"] = t.PriorityText, ["batch"] = t.Batch,
                ["eta"] = EtaText(id),
            });
        }
        app.Post(new JsonObject
        {
            ["type"] = "warmTiers", ["cores"] = cores, ["freeGb"] = Math.Round(free, 1),
            ["lastMinutes"] = Math.Round(LastWarmMinutes(id), 1),
            ["tiers"] = tiers,
            ["ramNote"] = free > 0 && lowered ? $"当前可用内存 {free:N1} GB：部分档位的进程数已按内存自动下调（每个进程约 0.75 GB，另给系统留 4 GB）。" : null,
        });
    }
    // 确认档位后跑全量预热（不带 --used，等于 ps1 的「火力全开」），优先级/批量交给内核
    void StartWarmTier(string id, string key)
    {
        var (exeDir, play, label) = Target(id);
        var exe = exeDir == null ? "" : Path.Combine(exeDir, "victory.exe");
        if (!File.Exists(exe)) { app.Out("\n还没有可用于预热的 victory.exe。\n", "bad"); return; }
        if (!File.Exists(S("game"))) { app.Out("\n请先设置你的游戏（设置 › 通用）。\n", "bad"); return; }
        if (Busy) { app.Out("\n已有其它任务在运行：请等它结束再预热。\n", "bad"); return; }
        var tiers = Tiers(Environment.ProcessorCount);
        var tier = tiers.FirstOrDefault(t => t.Key == key) ?? tiers[1];
        // (Neptune) nothing known yet (a PC where the game has not run): nothing to warm
        if (ShaderState(id).state == "empty")
        {
            app.Out("\n暂无需准备：先玩一次，让游戏列出着色器，再在这里预热。\n", "bad");
            return;
        }
        // 内存保险：不够就少开进程，并把原因写进输出
        var (jobs, ramNote) = GuardJobs(tier.Jobs);
        if (ramNote != null) app.Out("\n" + ramNote + "\n", "bad");
        var (file, all) = Wrap(exe, ["warm", "--jobs", jobs.ToString()]);
        // the same switches the run will have, so the run finds what this makes;
        // VICTORY_LOG=warn: only its progress ("120 s  2000 shaders") and the summary, not a line per shader
        var env = Env(id, exeDir!, play, null, [], say: false);
        var warmKey = WarmKey(env, exe);
        env["VICTORY_LOG"] = "warn";
        env["VICTORY_WARM_PRIORITY"] = tier.Priority;
        env["VICTORY_WARM_BATCH"] = tier.Batch;
        var began = DateTime.Now;
        app.Out($"\n预热档位：{tier.Name} —— 进程 {jobs}、优先级 {tier.PriorityText}、每批 {tier.Batch} 条。\n", "h");
        StartWarmWatch();
        Queue($"{label}：预热着色器（{tier.Name}档，{jobs} 进程）", file, all, exeDir!, env,
            code =>
            {
                StopWarmWatch();
                // a warm-up over nothing known is not a warm-up: it is not recorded (the card stays Cold)
                if (code == 0 && CountNow(exe, exeDir!, env) is (0, _))
                    app.Out("\n没有准备任何内容：游戏尚未列出着色器。先玩一次，再在这里预热。\n", "bad");
                else SetWarm(id, code, warmKey, (DateTime.Now - began).TotalMinutes, tier.Key, jobs);
                SendSettings();
            }, low: true);
    }

    // 全量预热期间：可用内存低于 1.5 GB 时把本次的预热进程降到 BelowNormal（ps1 的看护进程）
    void StartWarmWatch()
    {
        StopWarmWatch();
        var cts = new CancellationTokenSource();
        warmWatch = cts; warmWatchSaid = false;
        var began = DateTime.Now.AddSeconds(-3);
        _ = Task.Run(async () =>
        {
            try
            {
                while (!cts.IsCancellationRequested)
                {
                    await Task.Delay(2000, cts.Token).ConfigureAwait(false);
                    if (job == null) break;   // the warm-up ended
                    double free = 0; try { free = FreeGb(); } catch { }
                    if (free <= 0 || free >= 1.5) continue;
                    foreach (var p in Process.GetProcessesByName("victory"))
                    {
                        try
                        {
                            if (p.StartTime < began) continue;   // not one of this warm-up's
                            if (p.PriorityClass != ProcessPriorityClass.BelowNormal) p.PriorityClass = ProcessPriorityClass.BelowNormal;
                        }
                        catch { }
                        finally { p.Dispose(); }
                    }
                    if (!warmWatchSaid)
                    {
                        warmWatchSaid = true;
                        app.Out($"\n可用内存只有 {free:N1} GB：已把预热进程优先级降到 BelowNormal（防止系统卡死）。\n", "bad");
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch { }
        });
    }
    void StopWarmWatch()
    {
        var c = warmWatch;
        if (c == null) return;
        warmWatch = null;
        try { c.Cancel(); } catch { }
    }

    // ---- (Victory) 自动查找游戏目录：顺序照 预热-火力全开.ps1 / 启动脚本 ----
    // 启动器文件夹 → 它的上一级 → 启动器旁的 game-path.txt 第一行 → VICTORY_GAME_DIR →
    // 常见路径 → 每个盘根目录下的 *GTA6* 文件夹；第一个含 game_scarlett_master.exe 的即命中。
    static string? GameExeIn(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var p = path.Trim().Trim('"');
            if (p.Length == 0) return null;
            if (File.Exists(p) && Path.GetFileName(p).Equals("game_scarlett_master.exe", StringComparison.OrdinalIgnoreCase))
                return Path.GetFullPath(p);
            var exe = Path.Combine(p, "game_scarlett_master.exe");
            return File.Exists(exe) ? Path.GetFullPath(exe) : null;
        }
        catch { return null; }
    }
    static IEnumerable<string> GameCandidates()
    {
        yield return Bundled;
        var parent = Path.GetDirectoryName(Bundled);
        if (!string.IsNullOrEmpty(parent)) yield return parent;
        var pathFile = Path.Combine(Bundled, "game-path.txt");
        if (File.Exists(pathFile))
        {
            string? saved = null;
            try { saved = File.ReadLines(pathFile).FirstOrDefault()?.Trim().Trim('"'); } catch { }
            if (!string.IsNullOrWhiteSpace(saved)) yield return saved;
        }
        if (Environment.GetEnvironmentVariable("VICTORY_GAME_DIR") is { Length: > 0 } env) yield return env;
        foreach (var known in new[] { @"E:\GTA6.Xbox.v1.0.2.1-CYBERLEEK", @"D:\GTA6.Xbox.v1.0.2.1-CYBERLEEK", @"C:\GTA6.Xbox.v1.0.2.1-CYBERLEEK" })
            yield return known;
        DriveInfo[] drives;
        try { drives = DriveInfo.GetDrives(); } catch { yield break; }
        foreach (var drive in drives.OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase))
        {
            bool ready;
            try { ready = drive.IsReady && drive.DriveType is (DriveType.Fixed or DriveType.Removable); } catch { continue; }
            if (!ready) continue;
            string[] dirs;
            try { dirs = Directory.GetDirectories(drive.RootDirectory.FullName, "*GTA6*"); } catch { continue; }
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);
            foreach (var dir in dirs) yield return dir;
        }
    }
    public string? ScanGame()
    {
        foreach (var candidate in GameCandidates())
            if (GameExeIn(candidate) is string exe) return exe;
        return null;
    }
    // quiet: 启动时只填空，不覆盖玩家已选的游戏
    public void FindGame(bool quiet = false)
    {
        string? exe = null;
        try { exe = ScanGame(); } catch { }
        if (exe == null)
        {
            if (quiet) return;
            app.Out("\n自动查找没有找到游戏：文件夹里需要有 game_scarlett_master.exe。请点「浏览…」手动选择游戏。\n", "bad");
            app.Post(new JsonObject { ["type"] = "findGame", ["ok"] = false, ["path"] = null });
            return;
        }
        Set("game", exe);
        app.Out($"\n已自动找到游戏：{exe}\n", "ok");
        app.Post(new JsonObject { ["type"] = "findGame", ["ok"] = true, ["path"] = exe });
        SendSettings();
    }

    // ---- (Victory) 自动查找本地存档：dataDir = 包含 7952987A 的文件夹 ----
    // 候选顺序：设置里的 dataDir → %LOCALAPPDATA%\victory\data → 旧版（VIctory / VIctory-Trainer /
    // Neptune / ProjectNeptune）的 data → 启动器/解包目录的 data、perf-data → 游戏目录的 data、perf-data →
    // VICTORY_DATA_DIR → %LOCALAPPDATA% 下名字含 victory/neptune 的文件夹里的 data。
    // 有效 = 该根目录下有 7952987A；找到多个时取 7952987A\saves 里最新文件写入时间最新的一个。
    // 只选路径：不移动、不改写任何存档文件。quiet = 启动时的静默扫描：只补空，不覆盖本来就能用的默认目录。
    public void FindSaves(bool quiet = false)
    {
        var found = ScanSaveRoots();
        var results = new JsonArray();
        foreach (var f in found) results.Add(new JsonObject { ["path"] = f.root, ["from"] = f.from });
        if (found.Count == 0)
        {
            if (quiet) return;
            const string note = "没有找到本地存档：这些位置都没有 7952987A 文件夹。先玩一次游戏生成存档，再试一次。";
            app.Out("\n" + note + "\n", "bad");
            app.Post(new JsonObject { ["type"] = "findSaves", ["ok"] = false, ["path"] = null, ["found"] = results });
            try { app.RefreshSaves(note, false); } catch { }
            return;
        }
        var best = found[0];
        // 默认目录本来就能用：启动时的静默扫描不写 dataDir，保持原来的默认行为
        if (quiet && SamePath(best.root, DefaultSaveRoot())) return;
        Set("dataDir", best.root);
        var where = best.newest == DateTime.MinValue ? "还没有存档文件" : "最近写入 " + best.newest.ToString("yyyy-MM-dd HH:mm");
        if (!quiet)
        {
            var others = found.Count > 1 ? $"\n共找到 {found.Count} 处：" + string.Join("", found.Select(f =>
                $"\n  · {f.root}（{f.from}；{(f.newest == DateTime.MinValue ? "还没有存档文件" : "最近写入 " + f.newest.ToString("yyyy-MM-dd HH:mm"))}）")) : "";
            app.Out($"\n已自动找到本地存档：{best.root}\n（{best.from}；{where}）{others}\n", "ok");
            app.Post(new JsonObject { ["type"] = "findSaves", ["ok"] = true, ["path"] = best.root, ["from"] = best.from, ["found"] = results });
            try { app.RefreshSaves($"已自动找到本地存档（共 {found.Count} 处，已选最新写入的一处）：{best.root}"); } catch { }
        }
        SendSettings();
    }

    static string DefaultSaveRoot() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "victory", "data");

    static bool SamePath(string a, string b) => string.Equals(
        Path.TrimEndingDirectorySeparator(a), Path.TrimEndingDirectorySeparator(b), StringComparison.OrdinalIgnoreCase);

    // every candidate data root that actually holds 7952987A, best first (newest file in 7952987A\saves)
    List<(string root, string from, DateTime newest)> ScanSaveRoots()
    {
        var list = new List<(string root, string from)>();
        void Add(string? root, string from)
        {
            if (string.IsNullOrWhiteSpace(root)) return;
            try
            {
                var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root.Trim().Trim('"')));
                if (full.Length > 0) list.Add((full, from));
            }
            catch { }
        }
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        // 1. the setting already chosen (by an earlier scan or hand-edited)
        Add(S("dataDir"), "设置中已选的存档目录");
        // 2. the default the launcher has always used
        Add(Path.Combine(local, "victory", "data"), "默认存档目录");
        // 3. old builds' names
        foreach (var legacy in new[] { "VIctory", "VIctory-Trainer", "Neptune", "ProjectNeptune" })
            Add(Path.Combine(local, legacy, "data"), $"旧版存档目录（{legacy}）");
        // 4. beside the launcher / in its extracted payload
        foreach (var dir in new[] { Bundled, PayloadDir }.Where(d => !string.IsNullOrEmpty(d)).Distinct(StringComparer.OrdinalIgnoreCase))
            foreach (var name in new[] { "data", "perf-data" })
                Add(Path.Combine(dir!, name), "启动器所在目录");
        // 5. beside the game itself
        try
        {
            if (S("game") is { Length: > 0 } game && Path.GetDirectoryName(Path.GetFullPath(game)) is { Length: > 0 } gameDir)
                foreach (var name in new[] { "data", "perf-data" })
                    Add(Path.Combine(gameDir, name), "游戏所在目录");
        }
        catch { }
        // 6. the runner's own environment
        Add(Environment.GetEnvironmentVariable("VICTORY_DATA_DIR"), "VICTORY_DATA_DIR 环境变量");
        // 7. any %LOCALAPPDATA% folder whose name mentions victory or neptune
        try
        {
            foreach (var dir in Directory.GetDirectories(local))
            {
                var name = Path.GetFileName(dir);
                if (name.Contains("victory", StringComparison.OrdinalIgnoreCase) || name.Contains("neptune", StringComparison.OrdinalIgnoreCase))
                    Add(Path.Combine(dir, "data"), $"LOCALAPPDATA 下的 {name}");
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        var found = new List<(string root, string from, DateTime newest)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (root, from) in list)
        {
            try
            {
                if (!seen.Add(root)) continue;
                if (!Directory.Exists(Path.Combine(root, SaveLocations.TitleId))) continue;
                found.Add((root, from, NewestSave(root)));
            }
            catch { }
        }
        // newest saves first; equal times keep the candidate order above (default before legacy)
        return found.OrderByDescending(f => f.newest).ToList();
    }

    // the newest write time of any file in 7952987A\saves (MinValue when there is none)
    static DateTime NewestSave(string root)
    {
        var newest = DateTime.MinValue;
        try
        {
            foreach (var file in Directory.EnumerateFiles(Path.Combine(root, SaveLocations.TitleId, "saves"), "*", SearchOption.AllDirectories))
                try { var t = File.GetLastWriteTime(file); if (t > newest) newest = t; } catch { }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return newest;
    }

    // ---- Windows runs victory.exe itself; Linux runs it through Wine/Proton (Settings › Runner) ----
    (string file, List<string> args) Wrap(string exe, List<string> args)
    {
        if (OperatingSystem.IsWindows()) return (exe, args);
        var runner = SplitArgs(S("wine", "wine"));
        var all = runner.Skip(1).ToList(); all.Add(exe); all.AddRange(args);
        return (runner.Count > 0 ? runner[0] : "wine", all);
    }
    static string WinPath(string p) => OperatingSystem.IsWindows() ? p : "Z:" + p.Replace('/', '\\');

    static ProcessStartInfo Start(string file, List<string> args, string cwd, Dictionary<string, string> env)
    {
        var psi = new ProcessStartInfo(file) { WorkingDirectory = cwd, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        foreach (var a in args) psi.ArgumentList.Add(a);
        // a clean slate: no VICTORY_* left over from the shell the launcher started from
        foreach (var k in psi.Environment.Keys.Where(k => k.StartsWith("VICTORY_")).ToList()) psi.Environment.Remove(k);
        psi.Environment["NO_COLOR"] = "1";
        psi.Environment["CARGO_TERM_COLOR"] = "never";
        foreach (var kv in env) psi.Environment[kv.Key] = kv.Value;
        return psi;
    }

    public static List<string> SplitArgs(string s)
    {
        var list = new List<string>(); var cur = new StringBuilder(); bool q = false, any = false;
        foreach (var c in s)
        {
            if (c == '"') { q = !q; any = true; continue; }
            if (char.IsWhiteSpace(c) && !q) { if (any) { list.Add(cur.ToString()); cur.Clear(); any = false; } continue; }
            cur.Append(c); any = true;
        }
        if (any) list.Add(cur.ToString());
        return list;
    }

    // ---- jobs: one at a time (git, cargo, warm), output streamed to the page ----
    // low: below-normal priority, so a long job on every core leaves the PC usable
    public void Queue(string label, string file, List<string> args, string cwd, Dictionary<string, string> env, Action<int>? done = null, bool low = false)
    {
        lock (jobs) jobs.Enqueue((label, file, args, cwd, env, done, low));
        Next();
    }
    public bool Busy => job != null || jobs.Count > 0;
    static readonly Process Placeholder = new();

    // our warm prints "[progress] a/b (p%) | mm:ss | rate/s | ETA mm:ss" and "[done] n made in s s (...)",
    // the page reads "a of b, s s" and "n made in s s ("
    static readonly Regex ProgressLine = new(@"^\[progress\] (\d+)/(\d+) \([\d.]+%\) \| (\d+):(\d+) \|");
    static string ForPage(string line)
    {
        var m = ProgressLine.Match(line);
        if (m.Success)
            return $"{m.Groups[1].Value} of {m.Groups[2].Value}, {(int.Parse(m.Groups[3].Value) * 60 + int.Parse(m.Groups[4].Value))} s";
        return line.StartsWith("[done] ") ? line[7..] : line;
    }

    void Next()
    {
        (string label, string file, List<string> args, string cwd, Dictionary<string, string> env, Action<int>? done, bool low) next;
        lock (jobs)
        {
            if (job != null || jobs.Count == 0) return;
            next = jobs.Dequeue();
            job = Placeholder;   // taken: another thread can't start a second job meanwhile
        }
        var (label, file, args, cwd, env, done, low) = next;
        app.Out($"\n=== {label} ===\n> {file} {string.Join(" ", args)}\n", "h");
        app.Post(new JsonObject { ["type"] = "job", ["state"] = "start", ["label"] = label });
        Process p;
        try
        {
            p = new Process { StartInfo = Start(file, args, cwd, env), EnableRaisingEvents = true };
            p.OutputDataReceived += (_, e) => { if (e.Data != null) app.Out(ForPage(e.Data) + "\n"); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) app.Out(ForPage(e.Data) + "\n"); };
            p.Exited += (_, _) =>
            {
                p.WaitForExit();
                var code = 0; try { code = p.ExitCode; } catch { }
                app.Out(code == 0 ? "--- 完成 ---\n" : $"--- 失败（退出代码 {code}）---\n", code == 0 ? "ok" : "bad");
                job = null;
                if (code != 0) lock (jobs) jobs.Clear();   // a failed step stops the steps queued after it
                try { done?.Invoke(code); } catch (Exception e) { app.Out(e.Message + "\n", "bad"); }
                app.Post(new JsonObject { ["type"] = "job", ["state"] = "end", ["label"] = label, ["code"] = code });
                Next();
            };
            job = p;
            p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
            if (low) try { p.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
        }
        catch (Exception e)
        {
            job = null; lock (jobs) jobs.Clear();
            app.Out($"无法启动 {file}：{e.Message}\n", "bad");
            app.Post(new JsonObject { ["type"] = "job", ["state"] = "end", ["label"] = label, ["code"] = -1 });
        }
    }

    // ---- (Victory) the docs that ship with the release: 教程 / 启动器说明 / 修改器说明 / BUILD-INFO ----
    static readonly (string key, string name, string[] patterns)[] Docs =
    [
        ("tutorial", "从零开始教程", ["从零开始教程*.txt"]),
        ("readme", "启动器说明", ["README*.txt"]),
        ("trainer", "修改器说明", ["修改器说明*.txt"]),
        ("buildinfo", "构建信息", ["BUILD-INFO*.txt"]),
        ("changelog", "更新说明", ["更新说明*.txt"]),
    ];
    // a package folder keeps them beside the launcher; a single-exe build extracted them into its payload
    IEnumerable<string> DocDirs()
    {
        yield return Bundled;
        if (ReleaseDir() is string release) yield return release;
        if (PayloadDir is string payload) yield return payload;
    }
    void OpenDoc(string key)
    {
        var doc = Docs.FirstOrDefault(d => d.key == key);
        if (doc.key == null) return;
        foreach (var dir in DocDirs().Distinct(StringComparer.OrdinalIgnoreCase))
            foreach (var pattern in doc.patterns)
                try
                {
                    var file = Directory.GetFiles(dir, pattern).OrderBy(f => f, StringComparer.OrdinalIgnoreCase).FirstOrDefault();
                    if (file != null) { Open(file); return; }
                }
                catch { }
        app.Out($"\n没有找到“{doc.name}”：它应随发行包一起提供（启动器文件夹或解出的 payload 中）。\n", "bad");
    }

    static void Open(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { } }

    // ---- the PC checks: graphics card, its memory and driver, system memory, free disk ----
    void SendPcInfo()
    {
        string gpu = "", driver = ""; long vram = 0, ram = 0, ramFree = 0, disk = -1;
        try { Gpu(ref gpu, ref driver, ref vram); } catch { }
        try { Memory(ref ram, ref ramFree); } catch { }
        try { if (File.Exists(S("game"))) disk = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(S("game")))!).AvailableFreeSpace; } catch { }
        app.Post(new JsonObject { ["type"] = "pc", ["gpu"] = gpu, ["driver"] = driver, ["vram"] = vram, ["ram"] = ram, ["ramFree"] = ramFree, ["disk"] = disk,
            ["cpu"] = Environment.ProcessorCount, ["rtx"] = Streamline.RtxGeneration(gpu) });
    }
#if WINDOWS
    // the display adapters' entries in the registry: the card with the most memory
    static void Gpu(ref string name, ref string driver, ref long vram)
    {
        using var cls = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
        if (cls == null) return;
        foreach (var sub in cls.GetSubKeyNames())
        {
            if (!int.TryParse(sub, out _)) continue;
            using var k = cls.OpenSubKey(sub);
            if (k?.GetValue("DriverDesc") is not string desc || desc.Contains("Basic Display")) continue;
            long mem = k.GetValue("HardwareInformation.qwMemorySize") switch { long l => l, int i => (uint)i, byte[] b when b.Length >= 8 => BitConverter.ToInt64(b), byte[] b when b.Length >= 4 => BitConverter.ToUInt32(b), _ => 0 };
            if (mem == 0) mem = k.GetValue("HardwareInformation.MemorySize") switch { long l => l, int i => (uint)i, byte[] b when b.Length >= 4 => BitConverter.ToUInt32(b), _ => 0 };
            if (mem < vram) continue;
            vram = mem; name = desc.Replace("NVIDIA GeForce ", "").Replace("AMD Radeon ", "Radeon ").Trim();
            var ver = k.GetValue("DriverVersion") as string ?? "";
            // NVIDIA's own number is the last five digits of Windows' version: 32.0.16.2140 -> 621.40
            var digits = string.Concat(ver.Split('.').Skip(2));
            driver = desc.Contains("NVIDIA") && digits.Length >= 5 ? $"{digits[^5..^2]}.{digits[^2..]}" : ver;
        }
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct MemStatus { public uint Length, Load; public ulong Total, Avail, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemStatus status);
    static void Memory(ref long total, ref long free)
    {
        var m = new MemStatus { Length = (uint)System.Runtime.InteropServices.Marshal.SizeOf<MemStatus>() };
        if (GlobalMemoryStatusEx(ref m)) { total = (long)m.Total; free = (long)m.Avail; }
    }
#else
    static void Gpu(ref string name, ref string driver, ref long vram)
    {
        // the first card the kernel's DRM lists with a known vendor
        foreach (var dev in Directory.Exists("/sys/class/drm") ? Directory.GetDirectories("/sys/class/drm", "card?") : [])
        {
            var vendor = File.Exists(Path.Combine(dev, "device", "vendor")) ? File.ReadAllText(Path.Combine(dev, "device", "vendor")).Trim() : "";
            name = vendor switch { "0x10de" => "NVIDIA card", "0x1002" => "AMD card", "0x8086" => "Intel graphics", _ => name };
            var total = Path.Combine(dev, "device", "mem_info_vram_total");   // AMD
            if (File.Exists(total) && long.TryParse(File.ReadAllText(total).Trim(), out var v)) vram = v;
            if (name.Length > 0) break;
        }
        // NVIDIA's driver names its cards: /proc/driver/nvidia/gpus/<bus>/information, "Model: NVIDIA GeForce RTX 4070"
        foreach (var info in Directory.Exists("/proc/driver/nvidia/gpus") ? Directory.GetFiles("/proc/driver/nvidia/gpus", "information", SearchOption.AllDirectories) : [])
        {
            var m = Regex.Match(File.ReadAllText(info), @"Model:\s*(.+)");
            if (m.Success) { name = m.Groups[1].Value.Trim().Replace("NVIDIA GeForce ", ""); break; }
        }
        if (File.Exists("/proc/driver/nvidia/version"))
        {
            var m = Regex.Match(File.ReadAllText("/proc/driver/nvidia/version"), @"Kernel Module\s+([\d.]+)");
            if (m.Success) driver = m.Groups[1].Value;
        }
    }
    static void Memory(ref long total, ref long free)
    {
        foreach (var line in File.ReadLines("/proc/meminfo"))
        {
            var m = Regex.Match(line, @"^(MemTotal|MemAvailable):\s+(\d+) kB");
            if (!m.Success) continue;
            if (m.Groups[1].Value == "MemTotal") total = long.Parse(m.Groups[2].Value) << 10; else free = long.Parse(m.Groups[2].Value) << 10;
        }
    }
#endif
}
