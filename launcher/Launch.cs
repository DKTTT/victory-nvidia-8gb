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
    void SetWarm(string id, int code, string key, double minutes)
    {
        lock (history)
        {
            var h = Hist(id); h["warmAt"] = DateTime.Now.ToString("o"); h["warmCode"] = code; h["warmKey"] = key; h.Remove("warmStale");
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
            ["filesOk"] = ReleaseDir() != null, ["bundled"] = File.Exists(Path.Combine(Bundled, "victory.exe")),
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
        if (!OperatingSystem.IsWindows()) why = "NVIDIA's files are checked on Windows only";
        else if (gen < 20) why = "no NVIDIA RTX card found";
        if (why == null && frames > 0 && gen < 40) { notes.Add("frame generation needs an RTX 40 or 50 card: off"); frames = 0; }
        if (why == null && frames > 1 && gen < 50) { notes.Add("more than 2x needs an RTX 50 card: 2x"); frames = 1; }
        if (frames > 0 && !env.ContainsKey("VICTORY_THIN") && env.GetValueOrDefault("VICTORY_ASYNC_SUBMIT") != "1")
        { notes.Add("frame generation needs Extra draw threads (Settings › Performance): off"); frames = 0; }
        if (frames > 0 && !dlss && B("seriesX", false))
        { notes.Add("frame generation on Sharp (Series X) needs DLSS upscaling as well: off"); frames = 0; }
        if (why == null && frames == 0 && !dlss) why = "nothing left to turn on";
        if (why == null && Streamline.Missing(SlDir(), Streamline.Needed(frames > 0, dlss)) is string missing)
            why = missing + " (Settings › Graphics › Get NVIDIA's files)";
        if (why != null) { notes.Add("DLSS and frame generation off: " + why); return false; }
        env["VICTORY_STREAMLINE_DIR"] = WinPath(Path.GetFullPath(SlDir()));
        // VICTORY_FRAMEGEN_FRAMES: frames generated between two rendered (ours); VICTORY_FRAMEGEN_X: frames shown
        // for each rendered one (the base's streamline.rs, which reads either).
        if (frames > 0) { env["VICTORY_FRAMEGEN"] = "1"; env["VICTORY_FRAMEGEN_FRAMES"] = frames.ToString(); env["VICTORY_FRAMEGEN_X"] = (frames + 1).ToString(); }
        if (dlss) env["VICTORY_DLSS"] = "1";
        notes.Add($"using NVIDIA's Streamline: DLSS upscaling {(dlss ? "on" : "off")}, frame generation {(frames > 0 ? (frames + 1) + "x" : "off")}, NVIDIA's files in {SlDir()}");
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
                if (app.Host.PickFile("Your game: game_scarlett_master.exe", "game_scarlett_master.exe", "The game (game_scarlett_master.exe)") is string g) Set("game", g);
                SendSettings(); break;
            case "pickFolder":
                var key = (string?)m["key"] ?? "";
                if (key is "optiScaler" or "neptuneDir" or "streamlineDir" && app.Host.PickFolder((string?)m["title"] ?? "Choose a folder") is string f) Set(key, f);
                SendSettings(); break;
            case "pickFile":
                if ((string?)m["key"] == "fsrDll" && app.Host.PickFile("A PC amd_fidelityfx_upscaler_dx12.dll", "*.dll", "DLL files (*.dll)") is string d) Set("fsrDll", d);
                if ((string?)m["key"] == "keyIcons" && app.Host.PickFile("Keyboard prompt icons (tools\\gfx_input_icons.py)", "*.gfx", "GFX movies (*.gfx)") is string k) Set("keyIcons", k);
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
                    catch (Exception e) { app.Out($"\nCouldn't start the game: {e.Message}\n", "bad"); }
                    finally { Interlocked.Exchange(ref starting, 0); }
                });
                break;
            case "warm": Warm((string?)m["id"] ?? "public"); break;
            case "stop": stopping = true; try { game?.Kill(true); } catch { } break;
            case "cancelJob": try { job?.Kill(true); } catch { } break;
            case "openLogs": Directory.CreateDirectory(logDir); Open(logDir); break;
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
        if (game != null) { app.Out("\nThe game is already running.\n", "bad"); return; }
        // (Neptune) a count being asked (victory.exe warm --count, a second or so) ends first
        for (int i = 0; i < 120 && Volatile.Read(ref counting) != 0; i++) Thread.Sleep(100);
        if (Process.GetProcessesByName("victory").Length > 0) { app.Out("\nA victory.exe is already running: close it first.\n", "bad"); return; }
        var (exeDir, play, label) = Target(id);
        var exe = exeDir == null ? "" : Path.Combine(exeDir, "victory.exe");
        if (!File.Exists(exe)) { app.Out($"\nNo victory.exe in {exeDir ?? "(no folder set)"}: build it or set the Neptune folder.\n", "bad"); return; }
        var gamePath = S("game");
        if (!File.Exists(gamePath)) { app.Out("\nSet your game first (Settings › Game).\n", "bad"); return; }

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
                    app.Out("\nA new game build since the last warm-up: its pipelines are made during play (stutter, dark areas). Warm again for this build.\n", "bad");
                else
                    app.Out("\nThe flags changed since this build's warm-up: shaders may be translated during play (stutter, 100% CPU). Warm again with these flags.\n", "bad");
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
        foreach (var n in notes) { log.WriteLine("launcher: " + n); app.Out($"\nlauncher: {n}\n", n.StartsWith("using ") || (n.StartsWith("keyboard prompt icons: ") && !n.Contains("pad buttons")) ? "ok" : "bad"); }
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
            app.Out($"\n--- the game ended (code {code}); log: {logPath} ---\n", code == 0 ? "ok" : "bad");
            app.Post(new JsonObject { ["type"] = "game", ["state"] = "end", ["id"] = id, ["code"] = code });
            SendSettings();
        };
        game = p; gameId = id; stopping = false;
        p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
        app.Out($"\n=== {label}: running ===\n", "h");
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
        // victory-cache.txt beside the launcher: one line, the cache folder
        var pinned = Pinned("victory-cache.txt");
        if (!env.ContainsKey("VICTORY_CACHE_DIR"))
            env["VICTORY_CACHE_DIR"] = WinPath(pinned ?? Path.Combine(Bundled, "cache"));
        env["VICTORY_DATA_DIR"] = WinPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "victory", "data"));
        env["VICTORY_GAME_DIR"] = WinPath(Path.GetDirectoryName(Path.GetFullPath(S("game")))!);
        // the package's own upscaler / frame-generation folders, beside victory.exe
        if (exeDir.Length > 0)
        {
            var amd = Path.Combine(exeDir, "amd-sdk");
            if (Directory.Exists(amd) && !env.ContainsKey("VICTORY_FSR_DIR")) env["VICTORY_FSR_DIR"] = WinPath(amd);
            var sm86 = Path.Combine(exeDir, "dlssg-sm86");
            if (Directory.Exists(sm86) && !env.ContainsKey("VICTORY_DLSSG_SM86_DIR")) env["VICTORY_DLSSG_SM86_DIR"] = WinPath(sm86);
            foreach (var n in new[] { "nvidia-sdk", "dlssg-sm86", "dlssg", "streamline" })
            {
                var d = Path.Combine(exeDir, n);
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

    void Warm(string id)
    {
        var (exeDir, play, label) = Target(id);
        var exe = exeDir == null ? "" : Path.Combine(exeDir, "victory.exe");
        if (!File.Exists(exe)) { app.Out("\nNo victory.exe to warm with yet.\n", "bad"); return; }
        if (!File.Exists(S("game"))) { app.Out("\nSet your game first (Settings › Game).\n", "bad"); return; }
        // threads: every pipeline the driver builds at once takes its own memory, and on all 16
        // threads the driver ran out ("Not enough memory resources", pipelines refused)
        var (file, all) = Wrap(exe, ["warm", "--jobs", WarmJobs().ToString(), "--used"]);
        // the same switches the run will have , so the run finds what this makes;
        // VICTORY_LOG=warn: only its progress ("120 s  2000 shaders") and the summary, not a line per shader
        var env = Env(id, exeDir!, play, null, [], say: false);
        var key = WarmKey(env, exe);
        env["VICTORY_LOG"] = "warn";
        var began = DateTime.Now;
        // (Neptune) nothing known yet (a PC where the game has not run): nothing to warm
        if (ShaderState(id).state == "empty")
        {
            app.Out("\nNothing to prepare yet: play once so the game lists its shaders, then warm them here.\n", "bad");
            return;
        }
        Queue($"{label}: prepare the shaders (warm)", file, all, exeDir!, env,
            code =>
            {
                // a warm-up over nothing known is not a warm-up: it is not recorded (the card stays Cold)
                if (code == 0 && CountNow(exe, exeDir!, env) is (0, _))
                    app.Out("\nNothing was prepared: the game has not listed its shaders yet. Play once, then warm them here.\n", "bad");
                else SetWarm(id, code, key, (DateTime.Now - began).TotalMinutes);
                SendSettings();
            }, low: true);
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
                app.Out(code == 0 ? "--- done ---\n" : $"--- FAILED (exit code {code}) ---\n", code == 0 ? "ok" : "bad");
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
            app.Out($"Couldn't start {file}: {e.Message}\n", "bad");
            app.Post(new JsonObject { ["type"] = "job", ["state"] = "end", ["label"] = label, ["code"] = -1 });
        }
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
