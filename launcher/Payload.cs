// The release the launcher came in. A build made by `build.ps1 -Bundle` carries the package's files
// (victory.exe, ui, amd-sdk, shvi, the docs and bats) as one zip embedded in the exe. On the first
// start the zip is extracted to %LOCALAPPDATA%\VictoryLauncher\payload-<version>-<hash> and the
// launcher runs from there, so the player only sees a single exe. A real victory.exe beside the
// launcher wins over the payload: package folders and development builds work exactly as before.
using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;

namespace Neptune;

static class Payload
{
    // the name build.ps1 gives the embedded zip (Neptune.csproj: LogicalName)
    public const string ResourceName = "VictoryLauncher.payload.zip";
    const string StampName = ".payload-stamp";
    static readonly object gate = new();
    static bool resolved;
    static string? root;

    // the extracted payload folder; null when this build has no payload, a real victory.exe sits beside
    // the launcher, or extraction failed (the launcher then works as a plain build)
    public static string? Root
    {
        get
        {
            lock (gate)
            {
                if (!resolved) { root = Resolve(); resolved = true; }
                return root;
            }
        }
    }

    // extract before the window opens: the first start after each build pays a moment, later starts only
    // check the stamp (about a tenth of a second)
    public static void Prepare() => _ = Root;

    // the page's folder: beside the launcher when it came in a package folder, else in the payload
    public static string UiDir
    {
        get
        {
            var beside = Path.Combine(AppContext.BaseDirectory, "ui");
            if (Directory.Exists(beside)) return beside;
            if (Root is string r && Directory.Exists(Path.Combine(r, "ui"))) return Path.Combine(r, "ui");
            return beside;
        }
    }

    // the launcher's own icon: beside the exe or in the payload (the exe also has it embedded)
    public static string? IconFile
    {
        get
        {
            var beside = Path.Combine(AppContext.BaseDirectory, "victory.ico");
            if (File.Exists(beside)) return beside;
            if (Root is string r && File.Exists(Path.Combine(r, "victory.ico"))) return Path.Combine(r, "victory.ico");
            return null;
        }
    }

    static string? Resolve()
    {
        try
        {
            // a package folder (victory.exe beside the launcher) and development builds: no payload needed
            if (File.Exists(Path.Combine(AppContext.BaseDirectory, "victory.exe"))) return null;
            using var embedded = typeof(Payload).Assembly.GetManifestResourceStream(ResourceName);
            if (embedded == null) return null;   // a build made without -Bundle
            using var zip = new MemoryStream();
            embedded.CopyTo(zip);
            var hash = Convert.ToHexString(SHA256.HashData(zip.GetBuffer().AsSpan(0, (int)zip.Length)));
            zip.Position = 0;
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (local.Length == 0)
                local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
            var baseDir = Path.Combine(local, "VictoryLauncher");
            Directory.CreateDirectory(baseDir);
            var version = typeof(Payload).Assembly.GetName().Version?.ToString(3) ?? "0";
            var name = $"payload-{version}-{hash[..16].ToLowerInvariant()}";
            var dir = Path.Combine(baseDir, name);
            if (Stamped(dir, hash)) { CleanOld(baseDir, dir); return dir; }
            Extract(zip, baseDir, name, hash);
            if (!Stamped(dir, hash)) return null;
            CleanOld(baseDir, dir);
            return dir;
        }
        catch { return null; }
    }

    // the stamp holds the payload zip's hash: the same build skips extraction, a rebuild extracts beside it
    static bool Stamped(string dir, string hash)
    {
        try
        {
            return File.Exists(Path.Combine(dir, StampName))
                && File.ReadAllText(Path.Combine(dir, StampName)).Trim().Equals(hash, StringComparison.OrdinalIgnoreCase)
                && File.Exists(Path.Combine(dir, "victory.exe"))
                && File.Exists(Path.Combine(dir, "ui", App.Page));
        }
        catch { return false; }
    }

    // unzip to a temporary name, stamp it, then move it into place: a crash or a killed start never leaves
    // a half-written payload where the next start would trust it
    static void Extract(Stream zip, string baseDir, string name, string hash)
    {
        var target = Path.Combine(baseDir, name);
        var temp = Path.Combine(baseDir, name + ".tmp-" + Environment.ProcessId + "-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            Directory.CreateDirectory(temp);
            using (var archive = new ZipArchive(zip, ZipArchiveMode.Read, leaveOpen: true))
                archive.ExtractToDirectory(temp);
            File.WriteAllText(Path.Combine(temp, StampName), hash);
            if (Stamped(target, hash)) return;   // another start (the --test profile) extracted it meanwhile
            if (Directory.Exists(target)) Directory.Delete(target, true);
            try { Directory.Move(temp, target); }
            catch (IOException) { if (!Stamped(target, hash)) throw; }
        }
        finally { TryDelete(temp); }
    }

    // payloads of older builds: removed when no game is running from one. A start in the last half hour is
    // left alone (another launcher window of this build may still be using it)
    static void CleanOld(string baseDir, string current)
    {
        try
        {
            var now = DateTime.UtcNow;
            foreach (var dir in Directory.GetDirectories(baseDir, "payload-*"))
            {
                if (string.Equals(Path.GetFullPath(dir), Path.GetFullPath(current), StringComparison.OrdinalIgnoreCase)) continue;
                var temp = Path.GetFileName(dir).Contains(".tmp-", StringComparison.Ordinal);
                try { if (!temp && now - Directory.GetLastWriteTimeUtc(dir) < TimeSpan.FromMinutes(30)) continue; } catch { continue; }
                if (!temp && Process.GetProcessesByName("victory").Length > 0) return;
                TryDelete(dir);
            }
        }
        catch { }
    }

    static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
        catch { }
    }
}