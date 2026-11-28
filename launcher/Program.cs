// GTA6 CN Victory launcher, adapted (GPL-3.0) from the Project Neptune VI launcher. The save manager below comes from VI Save Manager.
using System.Diagnostics;
using Microsoft.Win32;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Neptune;

static class Program
{
    // Win10 ships without the Evergreen runtime; Win11 usually has it. Check before WebView2 is created.
    static bool WebView2RuntimePresent()
    {
        var id = @"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        foreach (var (root, path) in new[]
        {
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" + id),
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\EdgeUpdate\Clients\" + id),
            (Registry.CurrentUser, @"Software\Microsoft\EdgeUpdate\Clients\" + id),
        })
        {
            using var k = root.OpenSubKey(path);
            if (k?.GetValue("pv") is string pv && pv.Length > 0 && pv != "0.0.0.0") return true;
        }
        return false;
    }

    [STAThread]
    static int Main(string[] args)
    {
        bool test = args.Contains("--test", StringComparer.OrdinalIgnoreCase);
        // one window at a time (per edition, and the test profile apart): a second start shows the first one
        var name = "VictoryLauncher" + (test ? "-test" : "");
        using var single = new Mutex(true, (OperatingSystem.IsWindows() ? @"Local\" : "") + name + "-single", out bool first);
        if (!first)
        {
#if WINDOWS
            ShowOther();
#else
            Console.Error.WriteLine(App.Title + " 已在运行。");
#endif
            return 0;
        }
        // a -Bundle build unpacks its release before the window opens (the first start after a build only)
        Payload.Prepare();
#if WINDOWS
        if (!WebView2RuntimePresent())
        {
            MessageBox.Show("未检测到 Microsoft Edge WebView2 运行时，启动器界面无法显示。\n\n请下载并安装 WebView2（Windows 10/11 通用），装好后重新打开启动器：\nhttps://go.microsoft.com/fwlink/p/?LinkId=2124703\n\n（Win11 通常自带；Win10 可能需要手动安装一次）",
                "GTA6 CN · Victory", MessageBoxButtons.OK, MessageBoxIcon.Error);
            try { Process.Start(new ProcessStartInfo { FileName = "https://go.microsoft.com/fwlink/p/?LinkId=2124703", UseShellExecute = true }); } catch { }
            return 1;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new WindowsHost(test));
        return 0;
#else
        string? saveDirectory = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i].Equals("--test", StringComparison.OrdinalIgnoreCase)) continue;
            if (args[i] == "--save-dir" && i + 1 < args.Length && !args[i + 1].StartsWith("--"))
            {
                saveDirectory = args[++i];
                continue;
            }
            if (args[i] == "--help" || args[i] == "-h")
            {
                Console.WriteLine("用法：VictoryLauncher.exe [--test | --save-dir PATH]");
                return 0;
            }
            Console.Error.WriteLine($"无法识别或不完整的参数：{args[i]}。参见 --help。");
            return 2;
        }
        if (test && saveDirectory != null)
        {
            Console.Error.WriteLine("--test 使用自己的存档文件夹。请勿同时使用 --save-dir。");
            return 2;
        }
        try { return new LinuxHost(test, saveDirectory).Run(); }
        catch (Exception error)
        {
            Console.Error.WriteLine(App.Title + ": " + error.Message);
            return 1;
        }
#endif
    }

#if WINDOWS
    // bring the window that's already open to the front (restored if it was minimized)
    static void ShowOther()
    {
        var me = System.Diagnostics.Process.GetCurrentProcess();
        foreach (var p in System.Diagnostics.Process.GetProcessesByName(me.ProcessName))
        {
            if (p.Id == me.Id || p.MainWindowHandle == IntPtr.Zero) continue;
            if (IsIconic(p.MainWindowHandle)) ShowWindow(p.MainWindowHandle, 9);   // SW_RESTORE
            SetForegroundWindow(p.MainWindowHandle);
            return;
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
#endif
}

interface IDesktopHost
{
    void Post(string json);
    string? ChooseExport(string filename);
    string[] ChooseImports();
    string? ChooseSaveFolder(string? current);
    void RevealExport(string path);
    string? PickFolder(string title);
    string? PickFile(string title, string pattern, string patternName);
    bool Confirm(string title, string text);
    bool CustomFrame { get; }          // the page draws the title bar (Windows)
    void Window(string cmd);           // min, max, close from the page's own buttons
}

sealed class SaveManager(IDesktopHost host, bool test, string? saveDirectory, Func<string?>? dataDir = null)
{
    const string TitleId = SaveLocations.TitleId;
    readonly SaveLocations locations = new(test, saveDirectory, dataDir);
    public string ProfileDirectory => locations.ProfileDirectory;
    string SnapsRoot => Path.Combine(ProfileDirectory, "saves");
    static string TeamRoot => Path.Combine(AppContext.BaseDirectory, "team-saves");

    // (Victory) launcher-side refresh: launch.findSaves changed the save root, so the page re-reads the list
    public void Refresh(string? note = null, bool ok = true) => SendSaves(note, ok);

    // messages to the page: types known at build time, so Native AOT needs no reflection
    void Send(SavesMessage value) => host.Post(JsonSerializer.Serialize(value, VismJson.Default.SavesMessage));

    public void OnMessage(string raw)
    {
        JsonObject m;
        try { m = JsonNode.Parse(raw)!.AsObject(); } catch { return; }
        var name = (string?)m["name"];
        switch ((string?)m["cmd"])
        {
            case "list": ImportShipped(); SendSaves(); break;
            case "chooseSaveFolder": ChooseSaveFolder(); break;
            case "snap": SaveSnap(name); break;
            case "load": SaveLoad(name, (string?)m["kind"] == "team"); break;
            case "delete": SaveDelete(name); break;
            case "fresh": SaveFresh(); break;
            case "share": Share(name, (string?)m["kind"] ?? "spot"); break;
            case "import": Import(); break;
            case "openFolder": Directory.CreateDirectory(SnapsRoot); Open(SnapsRoot); break;
        }
    }

    // ---- files ----
    void ChooseSaveFolder()
    {
        if (test || !OperatingSystem.IsLinux()) return;
        try
        {
            var folder = host.ChooseSaveFolder(SavesDir());
            if (folder == null) { SendSaves(); return; }
            locations.SetLocation(folder);
            SendSaves("已选择游戏存档文件夹。");
        }
        catch (Exception error) { SendSaves(error.Message, false); }
    }

    string? SavesDir() => locations.GetSaveDirectory();
    static readonly EnumerationOptions SaveTree = new() { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint };
    static long DirSize(string d) { try { return Directory.EnumerateFiles(d, "*", SaveTree).Sum(f => new FileInfo(f).Length); } catch { return 0; } }
    static DateTime DirNewest(string d)
    {
        try { return Directory.EnumerateFiles(d, "*", SaveTree).Where(f => Path.GetFileName(f) != "about.txt").Select(f => File.GetLastWriteTime(f)).DefaultIfEmpty(DateTime.MinValue).Max(); }
        catch { return DateTime.MinValue; }
    }
    static void CopyDir(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var entry in new DirectoryInfo(from).EnumerateFileSystemInfos())
        {
            if ((entry.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"存档在 {entry.Name} 处包含链接。");
            var target = Path.Combine(to, entry.Name);
            if (entry is DirectoryInfo) CopyDir(entry.FullName, target);
            else File.Copy(entry.FullName, target, true);
        }
    }
    static void DeleteDir(string d)
    {
        if (!Directory.Exists(d)) return;
        if (OperatingSystem.IsWindows() && (File.GetAttributes(d) & FileAttributes.ReparsePoint) == 0)
            foreach (var f in Directory.EnumerateFiles(d, "*", SaveTree)) { try { File.SetAttributes(f, FileAttributes.Normal); } catch { } }
        Directory.Delete(d, true);
    }
    static string SafeName(string? n)
    {
        const string windowsInvalid = "<>:\\|?*/\"";
        var s = string.Concat((n ?? "").Trim().Select(c => c < ' ' || windowsInvalid.Contains(c) ? '-' : c)).Trim('.', ' ');
        return s.Length > 60 ? s[..60] : s;
    }
    static string Note(string dir) { var a = Path.Combine(dir, "about.txt"); try { return File.Exists(a) ? File.ReadAllText(a).Trim() : ""; } catch { return ""; } }
    static string Unique(string parent, string name)
    {
        var n = name; var i = 2;
        while (Directory.Exists(Path.Combine(parent, n))) n = $"{name} ({i++})";
        return n;
    }
    // a VIctory build that is running would write over a save loaded under it
    bool GameRunning()
    {
        if (test) return false;
        if (OperatingSystem.IsLinux())
        {
            static bool IsVictory(string value)
            {
                var name = Path.GetFileName(value.Replace('\\', '/'));
                return name.Equals("victory", StringComparison.OrdinalIgnoreCase) || name.Equals("victory.exe", StringComparison.OrdinalIgnoreCase);
            }
            foreach (var pid in Directory.EnumerateDirectories("/proc"))
            {
                if (!char.IsAsciiDigit(Path.GetFileName(pid)[0])) continue;
                try
                {
                    if (IsVictory(File.ReadAllText(Path.Combine(pid, "comm")).TrimEnd())) return true;
                    var args = File.ReadAllText(Path.Combine(pid, "cmdline")).Split('\0', 3);
                    if (IsVictory(args[0]) || (args.Length > 1 && Path.GetFileName(args[0]).StartsWith("wine", StringComparison.Ordinal) && IsVictory(args[1]))) return true;
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            return false;
        }
        try { return Process.GetProcessesByName("victory").Length > 0; } catch { return false; }
    }
    static void Open(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { } }

    // ---- the list the page shows ----
    void SendSaves(string? note = null, bool ok = true)
    {
        var dir = SavesDir();
        SaveItem Item(string d) => new(Path.GetFileName(d), DirSize(d), DirNewest(d).ToString("yyyy-MM-dd HH:mm"), KeptTime(d).ToString("yyyy-MM-dd HH:mm"), Note(d), Path.GetFileName(d).StartsWith("auto "));
        var spots = (Directory.Exists(SnapsRoot) ? Directory.GetDirectories(SnapsRoot) : Array.Empty<string>()).OrderByDescending(KeptTime).Select(Item).ToList();
        var team = (Directory.Exists(TeamRoot) ? Directory.GetDirectories(TeamRoot) : Array.Empty<string>()).OrderBy(d => d).Select(Item).ToList();
        Send(new SavesMessage(
            "saves", note, ok, test, OperatingSystem.IsLinux() && !test,
            dir, locations.DataRoot,
            dir != null && DirSize(dir) > 0,
            dir != null ? DirSize(dir) : 0,
            dir != null ? DirNewest(dir).ToString("yyyy-MM-dd HH:mm") : "",
            GameRunning(), spots, team));
    }

    static DateTime KeptTime(string directory) => OperatingSystem.IsWindows()
        ? Directory.GetCreationTime(directory) : Directory.GetLastWriteTime(directory);

    static void MarkKept(string directory)
    {
        if (OperatingSystem.IsWindows()) Directory.SetCreationTime(directory, DateTime.Now);
        else Directory.SetLastWriteTime(directory, DateTime.Now);
    }

    void SaveSnap(string? name)
    {
        try
        {
            var n = SafeName(name);
            var dir = SavesDir();
            if (n.Length == 0) { SendSaves("请先给存档起个名字。", false); return; }
            if (dir == null || !Directory.Exists(dir)) { SendSaves("还没有找到游戏存档。", false); return; }
            var target = Path.Combine(SnapsRoot, n);
            if (Directory.Exists(target)) { SendSaves($"已存在名为“{n}”的存档。请换一个名字，或先删除它。", false); return; }
            CopyDir(dir, target);
            MarkKept(target);
            SendSaves($"已将当前游戏保存为“{n}”。");
        }
        catch (Exception e) { SendSaves("无法保存：" + e.Message, false); }
    }

    // keeps the current save as "auto <time>" (the 5 newest of those stay) before anything replaces it
    string? Backup()
    {
        var dir = SavesDir();
        if (dir == null || !Directory.Exists(dir) || !Directory.EnumerateFileSystemEntries(dir).Any()) return null;
        var backup = Path.Combine(SnapsRoot, Unique(SnapsRoot, "auto " + DateTime.Now.ToString("yyyy-MM-dd HHmmss")));
        CopyDir(dir, backup);
        MarkKept(backup);
        foreach (var old in Directory.GetDirectories(SnapsRoot).Where(d => Path.GetFileName(d).StartsWith("auto "))
                     .OrderByDescending(KeptTime).Skip(5)) DeleteDir(old);
        return Path.GetFileName(backup);
    }

    void SaveLoad(string? name, bool fromTeam)
    {
        try
        {
            if (GameRunning()) { SendSaves("请先关闭游戏：游戏自动保存时会覆盖该存档。", false); return; }
            var label = SafeName(name);
            if (label.Length == 0) { SendSaves("请选择要载入的存档。", false); return; }
            var src = Path.Combine(fromTeam ? TeamRoot : SnapsRoot, label);
            if (!Directory.Exists(src)) { SendSaves("该存档已不存在。", false); return; }
            var dir = locations.RequireWritableLocation();
            if (Path.GetFullPath(src).Equals(Path.GetFullPath(dir), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                throw new IOException("请选择存档库之外的游戏存档文件夹。");
            string? backup = null;
            Directory.CreateDirectory(Path.GetDirectoryName(dir)!);
            var staged = dir + ".vism-new-" + Guid.NewGuid().ToString("N");
            var previous = dir + ".vism-old-" + Guid.NewGuid().ToString("N");
            try
            {
                CopyDir(src, staged);
                File.Delete(Path.Combine(staged, "about.txt"));
                backup = Backup();
                if (GameRunning()) throw new IOException("替换存档前请先关闭游戏。");
                if (Directory.Exists(dir)) Directory.Move(dir, previous);
                try { Directory.Move(staged, dir); }
                catch
                {
                    if (Directory.Exists(previous)) Directory.Move(previous, dir);
                    throw;
                }
                DeleteDir(previous);
            }
            finally { DeleteDir(staged); }
            SendSaves($"已载入“{SafeName(name)}”。{(backup != null ? $"之前的存档已保留为“{backup}”。" : "")}启动游戏后选择“继续”。");
        }
        catch (Exception e) { SendSaves("无法载入：" + e.Message, false); }
    }

    void SaveDelete(string? name)
    {
        try
        {
            var label = SafeName(name);
            if (label.Length == 0) { SendSaves("请选择要删除的存档。", false); return; }
            DeleteDir(Path.Combine(SnapsRoot, label));
            SendSaves($"已删除“{label}”。");
        }
        catch (Exception e) { SendSaves("无法删除：" + e.Message, false); }
    }

    // a new story: the current save is kept, the story slots are cleared, the settings slot stays
    void SaveFresh()
    {
        try
        {
            if (GameRunning()) { SendSaves("请先关闭游戏。", false); return; }
            var dir = SavesDir();
            if (dir == null || !Directory.Exists(dir)) { SendSaves("还没有存档：游戏本来就会开始新剧情。"); return; }
            dir = locations.RequireWritableLocation();
            var backup = Backup();
            if (GameRunning()) { SendSaves("清空剧情前请先关闭游戏。", false); return; }
            var cleared = 0;
            foreach (var blob in Directory.GetDirectories(dir, "*~*", SaveTree))
            {
                if (Path.GetFileName(blob).StartsWith("SettingsProfileSettings", StringComparison.OrdinalIgnoreCase) || !Directory.Exists(blob)) continue;
                DeleteDir(blob); cleared++;
            }
            SendSaves($"已清空剧情（{cleared} 个存档槽）。{(backup != null ? $"之前的存档已保留为“{backup}”。" : "")}下次运行将开始新游戏。");
        }
        catch (Exception e) { SendSaves("无法清空存档：" + e.Message, false); }
    }

    // ---- share: one save as a zip (save-info.json + saves\...) ----
    void Share(string? name, string kind)
    {
        try
        {
            string src, label;
            if (kind == "current") { src = SavesDir() ?? ""; label = "当前存档 " + DateTime.Now.ToString("yyyy-MM-dd HHmm"); }
            else { label = SafeName(name); src = label.Length == 0 ? "" : Path.Combine(kind == "team" ? TeamRoot : SnapsRoot, label); }
            if (src.Length == 0 || !Directory.Exists(src)) { SendSaves("没有可分享的内容。", false); return; }
            var filename = host.ChooseExport($"GTA VI 存档 - {label}.zip");
            if (filename == null) { SendSaves(); return; }
            using (var zip = new ZipArchive(File.Create(filename), ZipArchiveMode.Create))
            {
                var info = new SaveInfo(label, Note(src), "GTA VI（Xbox Series），Title ID " + TitleId, DirNewest(src).ToString("yyyy-MM-dd HH:mm"), "VI 存档管理器");
                var e = zip.CreateEntry("save-info.json");
                using (var w = new StreamWriter(e.Open(), new UTF8Encoding(false))) w.Write(JsonSerializer.Serialize(info, VismJsonIndented.Default.SaveInfo));
                foreach (var f in Directory.EnumerateFiles(src, "*", SaveTree))
                {
                    if (Path.GetFileName(f) == "about.txt") continue;
                    zip.CreateEntryFromFile(f, "saves/" + Path.GetRelativePath(src, f).Replace('\\', '/'));
                }
            }
            host.RevealExport(filename);
            SendSaves($"已生成 {Path.GetFileName(filename)}：发给任何人，对方点击导入即可。");
        }
        catch (Exception e) { SendSaves("无法生成 zip：" + e.Message, false); }
    }

    // ---- import: a zip from Share, or any zip with a game save folder in it ----
    static readonly Regex UserFolder = new("^[0-9A-Fa-f]{16}$");
    void Import()
    {
        var files = host.ChooseImports();
        if (files.Length == 0) { SendSaves(); return; }
        var done = new List<string>(); var failed = new List<string>();
        foreach (var file in files)
        {
            try { done.Add(ImportZip(file, shipped: false)); }
            catch (Exception e) { failed.Add($"{Path.GetFileName(file)} ({e.Message})"); }
        }
        var msg = (done.Count > 0 ? $"已导入：{string.Join("、", done)}。按“载入”即可从该存档开始游戏。" : "")
                + (failed.Count > 0 ? $" 无法导入：{string.Join("；", failed)}。" : "");
        SendSaves(msg.Trim(), failed.Count == 0);
    }

    // one zip into the kept saves; its name there. `shipped`: a starter save from the release's saves folder,
    // named after its zip, with "Shipped with GTA6 CN Victory" before its own note.
    string ImportZip(string file, bool shipped)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "vism-" + Guid.NewGuid().ToString("N"));
        try
        {
            if (new FileInfo(file).Length > 200L * 1024 * 1024) throw new Exception("超过 200 MB，不是存档");
            ZipFile.ExtractToDirectory(file, tmp);   // refuses entries that point outside tmp
            // the save root is the folder that holds the user folder (16 hex digits, e.g. 0009000000000001)
            var root = new[] { tmp }.Concat(Directory.GetDirectories(tmp, "*", SearchOption.AllDirectories))
                .FirstOrDefault(d => Directory.GetDirectories(d).Any(c => UserFolder.IsMatch(Path.GetFileName(c))))
                ?? throw new Exception("其中没有 GTA VI 存档");
            string name = Path.GetFileNameWithoutExtension(file).Replace("GTA VI 存档 - ", "").Replace("GTA VI save - ", ""), note = "";
            var infoPath = Path.Combine(tmp, "save-info.json");
            if (File.Exists(infoPath))
            {
                var info = JsonNode.Parse(File.ReadAllText(infoPath));
                if (!shipped) name = (string?)info?["name"] ?? name;
                note = (string?)info?["note"] ?? "";
            }
            if (shipped) note = "随 GTA6 CN · Victory 附带" + (note.Length > 0 ? " · " + note : "");
            name = Unique(SnapsRoot, SafeName(name).Length > 0 ? SafeName(name) : "导入的存档");
            var target = Path.Combine(SnapsRoot, name);
            foreach (var user in Directory.GetDirectories(root).Where(c => UserFolder.IsMatch(Path.GetFileName(c))))
                CopyDir(user, Path.Combine(target, Path.GetFileName(user)));
            File.WriteAllText(Path.Combine(target, "about.txt"), note.Length > 0 ? note : "导入自 " + Path.GetFileName(file));
            MarkKept(target);
            return name;
        }
        finally { try { DeleteDir(tmp); } catch { } }
    }

    // ---- (Neptune) starter saves: the zips in the saves folder beside the launcher (launcher/saves in the
    //      source tree) are taken into the kept saves once each, by file name and size, remembered in
    //      shipped-saves.txt in the profile: a shipped save the player deleted does not come back. Nothing is
    //      loaded: they are listed like any import, with Load.
    static string ShippedRoot => Path.Combine(AppContext.BaseDirectory, "saves");
    string ShippedFile => Path.Combine(ProfileDirectory, "shipped-saves.txt");
    bool shippedChecked;
    public void ImportShipped()
    {
        if (shippedChecked) return;
        shippedChecked = true;
        try
        {
            if (!Directory.Exists(ShippedRoot)) return;
            var taken = File.Exists(ShippedFile) ? File.ReadAllLines(ShippedFile).ToHashSet() : [];
            foreach (var zip in Directory.GetFiles(ShippedRoot, "*.zip").OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
            {
                var key = $"{Path.GetFileName(zip)}\t{new FileInfo(zip).Length}";
                if (taken.Contains(key)) continue;
                try { ImportZip(zip, shipped: true); }
                catch { continue; }   // not a save: tried again next start
                Directory.CreateDirectory(ProfileDirectory);
                File.AppendAllLines(ShippedFile, [key]);
                taken.Add(key);
            }
        }
        catch { }
    }
}

// ---- the JSON this app writes, generated at build time (Native AOT has no reflection) ----
record SaveItem(string Name, long Size, string GameTime, string Kept, string Note, bool Auto);
record SavesMessage(string Type, string? Note, bool Ok, bool Test, bool CanChooseSaveFolder, string? SaveDirectory, string? DataDir,
    bool Found, long Size, string Newest, bool Running, List<SaveItem> Spots, List<SaveItem> Team);
// save-info.json inside a shared zip
record SaveInfo(string Name, string Note, string Game, string SavedAt, string MadeWith);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(SavesMessage))]
partial class VismJson : JsonSerializerContext { }

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true)]
[JsonSerializable(typeof(SaveInfo))]
partial class VismJsonIndented : JsonSerializerContext { }
