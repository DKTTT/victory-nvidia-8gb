// Project Neptune launcher: the page's messages go to the launcher or the save manager.
// Messages to the page are built as JsonObject, which needs no reflection (Native AOT).
using System.Text.Json.Nodes;

namespace Neptune;

sealed class App
{
    public const string Title = "GTA6 CN · Victory 启动器";
    public const string Page = "index.html";

    readonly IDesktopHost host;
    readonly bool test;
    readonly SaveManager saves;
    readonly Launch launch;

    // the launcher's own settings and browser data, apart from the save manager's
    public string ProfileDirectory { get; }

    public App(IDesktopHost host, bool test, string? saveDirectory)
    {
        this.host = host;
        this.test = test;
        var local = OperatingSystem.IsWindows()
            ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
            : (Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } x ? x
               : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share"));
        ProfileDirectory = Path.Combine(local, "VictoryLauncher" + (test ? "-test" : ""));
        Directory.CreateDirectory(ProfileDirectory);
        saves = new SaveManager(host, test, saveDirectory);
        launch = new Launch(this, ProfileDirectory);
    }

    public void Post(JsonObject message) => host.Post(message.ToJsonString());
    // what processes print, without the color codes some of them write (shown as "[2m" text otherwise)
    static readonly System.Text.RegularExpressions.Regex Ansi = new(@"\x1B\[[0-9;?]*[A-Za-z]");
    public void Out(string text, string? kind = null) => Post(new JsonObject { ["type"] = "out", ["text"] = Ansi.Replace(text, ""), ["kind"] = kind });
    public IDesktopHost Host => host;

    public void OnMessage(string raw)
    {
        JsonObject m;
        try { m = JsonNode.Parse(raw)!.AsObject(); } catch { return; }
        var cmd = (string?)m["cmd"] ?? "";
        try
        {
            switch (cmd)
            {
                case "init":
                    Post(new JsonObject { ["type"] = "app", ["title"] = Title, ["test"] = test, ["os"] = OperatingSystem.IsWindows() ? "windows" : "linux", ["frame"] = host.CustomFrame,
                        ["release"] = launch.ReleaseInfo() });
                    launch.SendSettings();
                    // (Victory) 启动时自动找一次游戏目录：只填空，不覆盖玩家已选的
                    _ = System.Threading.Tasks.Task.Run(() => launch.FindGame(quiet: true));
                    return;
            }
            if (cmd.StartsWith("win.")) { host.Window(cmd[4..]); return; }
            if (cmd.StartsWith("launch.")) { launch.OnMessage(cmd[7..], m); return; }
        }
        catch (Exception e) { Out($"\n{e.Message}\n", "bad"); return; }
        saves.OnMessage(raw);
    }

    public Launch Launcher => launch;
}
