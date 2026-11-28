// (Neptune) NVIDIA DLSS upscaling and DLSS Frame Generation run on NVIDIA's own Streamline DLLs, which are
// not ours to ship. Settings › Graphics has a button that, when the player presses it (never on its own), fetches
// NVIDIA's Streamline SDK release from NVIDIA's GitHub, checks its size and SHA-256, keeps only the few DLLs a run
// needs (bin\x64, not the development ones) in %LOCALAPPDATA%\Neptune\streamline, and keeps each only when it has a
// valid Authenticode signature by "NVIDIA Corporation". The request is anonymous: a plain GET of that one fixed URL.
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Neptune;

static class Streamline
{
    public const string Url = "https://github.com/NVIDIA-RTX/Streamline/releases/download/v2.14.16/streamline-sdk-v2.14.16.zip";
    const long ZipSize = 276_016_170;
    const string ZipSha256 = "32041e51db0cab709a271b72a352281b690c2abbd669a827809401a5dd23956b";
    const string Signer = "NVIDIA Corporation";

    // always: the interposer and its common plugin
    static readonly string[] Base = ["sl.interposer.dll", "sl.common.dll"];
    // frame generation: 9.9 MB with the two above
    static readonly string[] FrameGen = ["sl.dlss_g.dll", "nvngx_dlssg.dll", "sl.reflex.dll", "sl.pcl.dll"];
    // DLSS upscaling: 56.6 MB more
    static readonly string[] Upscale = ["sl.dlss.dll", "nvngx_dlss.dll"];

    public static string DefaultDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "victory", "streamline");

    public static string[] Needed(bool framegen, bool dlss) => [.. Base, .. framegen ? FrameGen : [], .. dlss ? Upscale : []];

    // The card's RTX generation from its name ("RTX 5070 Ti" -> 50, "RTX 2060" -> 20); 0 for any other card.
    // 40 and 50 generate frames, only 50 more than one between two; 20 and 30 upscale only.
    public static int RtxGeneration(string? gpu)
    {
        var m = Regex.Match(gpu ?? "", @"\bRTX\s*([2-9])0[5-9]0\b", RegexOptions.IgnoreCase);
        return m.Success ? (m.Groups[1].Value[0] - '0') * 10 : 0;
    }

    // why `dir` can't serve these files (the first one missing or not NVIDIA's), or null when it can
    public static string? Missing(string dir, IEnumerable<string> files)
    {
        if (dir.Length == 0 || !Directory.Exists(dir)) return $"没有文件夹 {dir}";
        foreach (var f in files)
        {
            var path = Path.Combine(dir, f);
            if (!File.Exists(path)) return $"{dir} 中没有 {f}";
            if (Check(path) is string why) return why;
        }
        return null;
    }

    // ---- the signature: valid (WinVerifyTrust) and its signer NVIDIA Corporation; null when so ----
    static readonly Dictionary<string, (long size, DateTime at, string? why)> checkedFiles = new(StringComparer.OrdinalIgnoreCase);
    public static string? Check(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists) return $"{info.Name} 不存在";
        lock (checkedFiles)
            if (checkedFiles.TryGetValue(path, out var c) && c.size == info.Length && c.at == info.LastWriteTimeUtc) return c.why;
        var why = Verify(path);
        lock (checkedFiles) checkedFiles[path] = (info.Length, info.LastWriteTimeUtc, why);
        return why;
    }

#if WINDOWS
    static string? Verify(string path)
    {
        var name = Path.GetFileName(path);
        var code = WinTrust.Verify(path);
        if (code != 0) return $"{name} 未通过有效签名校验（0x{code:X8}）";
        string subject;
        try
        {
#pragma warning disable SYSLIB0057
            using var cert = new System.Security.Cryptography.X509Certificates.X509Certificate2(
                System.Security.Cryptography.X509Certificates.X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            subject = cert.GetNameInfo(System.Security.Cryptography.X509Certificates.X509NameType.SimpleName, false);
        }
        catch (Exception e) { return $"{name}：无法读取签名者（{e.Message}）"; }
        return IsNvidia(subject) ? null : $"{name} 的签名者是“{subject}”，而非 {Signer}";
    }
#else
    static string? Verify(string path) => "NVIDIA 的 DLL 仅在 Windows 上校验";
#endif
    public static bool IsNvidia(string? subject) => (subject ?? "").Trim() == Signer;

    // ---- the button: download, check, keep only what is needed ----
    static int busy;
    public static bool Busy => busy != 0;

    public static async Task FetchAsync(App app, bool dlss, Action done)
    {
        if (Interlocked.Exchange(ref busy, 1) != 0) return;
        var dir = DefaultDir;
        var need = Needed(true, dlss);
        string? work = null;
        void Say(string state, string text, long got = 0) =>
            app.Post(new JsonObject { ["type"] = "sl", ["state"] = state, ["text"] = text, ["got"] = got, ["total"] = ZipSize });
        try
        {
            if (Missing(dir, need) == null) { Say("done", $"NVIDIA 文件已在 {dir}，由 {Signer} 签名。"); return; }
            Directory.CreateDirectory(dir);
            // a new, empty folder for the download, apart from what is kept
            work = Path.Combine(Path.GetDirectoryName(dir)!, "streamline-download-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            var zip = Path.Combine(work, "streamline-sdk-v2.14.16.zip");
            Say("progress", "正在连接 github.com…");
            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(60) })
            using (var req = new HttpRequestMessage(HttpMethod.Get, Url))
            {
                req.Headers.UserAgent.ParseAdd("ProjectNeptuneVI");
                using var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead);
                if (!res.IsSuccessStatusCode) { Say("error", $"GitHub 返回 {(int)res.StatusCode}：未下载任何内容。"); return; }
                using var from = await res.Content.ReadAsStreamAsync();
                using var to = File.Create(zip);
                using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buf = new byte[1 << 20];
                long got = 0; var shown = Environment.TickCount64;
                for (int n; (n = await from.ReadAsync(buf)) > 0;)
                {
                    got += n;
                    if (got > ZipSize) { Say("error", "下载内容大于 NVIDIA 的发布包：已停止，未保留任何文件。"); return; }
                    sha.AppendData(buf, 0, n);
                    await to.WriteAsync(buf.AsMemory(0, n));
                    if (Environment.TickCount64 - shown > 400) { shown = Environment.TickCount64; Say("progress", $"正在下载 NVIDIA Streamline SDK · {got >> 20} / {ZipSize >> 20} MB", got); }
                }
                if (got != ZipSize) { Say("error", $"下载在 {got:N0} / {ZipSize:N0} 字节处结束：未保留任何文件。"); return; }
                var hash = Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
                if (hash != ZipSha256) { Say("error", "下载的 SHA-256 与 NVIDIA 发布包不符：未保留任何文件。"); return; }
            }
            Say("progress", "正在校验 NVIDIA 签名…", ZipSize);
            var kept = new List<string>(); var refused = new List<string>();
            using (var archive = ZipFile.OpenRead(zip))
                foreach (var f in need)
                {
                    // bin/x64/<name>, maybe under the archive's own top folder; never bin/x64/development
                    var entry = archive.Entries.FirstOrDefault(e =>
                    {
                        var p = e.FullName.Replace('\\', '/');
                        return p.Equals("bin/x64/" + f, StringComparison.OrdinalIgnoreCase) || p.EndsWith("/bin/x64/" + f, StringComparison.OrdinalIgnoreCase);
                    });
                    if (entry == null) { refused.Add($"{f}（不在 SDK 中）"); continue; }
                    var fresh = Path.Combine(work, f);
                    entry.ExtractToFile(fresh, true);
                    if (Check(fresh) is string why) { File.Delete(fresh); refused.Add(why); continue; }
                    File.Move(fresh, Path.Combine(dir, f), true);
                    kept.Add(f);
                }
            long size = kept.Sum(f => new FileInfo(Path.Combine(dir, f)).Length);
            if (refused.Count > 0) Say("error", $"已在 {dir} 保留 {kept.Count} 个 NVIDIA 文件；拒绝：{string.Join("；", refused)}。");
            else Say("done", $"就绪：{kept.Count} 个 NVIDIA 签名文件，{size / 1048576.0:F1} MB，位于 {dir}。下载文件已删除。");
        }
        catch (Exception e) { Say("error", e is TaskCanceledException ? "GitHub 停止响应：未保留任何文件。" : "无法获取 NVIDIA 的文件：" + e.Message); }
        finally
        {
            if (work != null) try { Directory.Delete(work, true); } catch { }
            Interlocked.Exchange(ref busy, 0);
            try { done(); } catch { }
        }
    }
}

#if WINDOWS
// WinVerifyTrust on a file, offline (no revocation check, no downloads)
static class WinTrust
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct FileInfo { public uint cbStruct; public IntPtr pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct Data
    {
        public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice; public uint fdwRevocationChecks;
        public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction; public IntPtr hWVTStateData; public IntPtr pwszURLReference;
        public uint dwProvFlags; public uint dwUIContext; public IntPtr pSignatureSettings;
    }
    [System.Runtime.InteropServices.DllImport("wintrust.dll", ExactSpelling = true)]
    static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref Data data);
    static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    public static int Verify(string path)
    {
        var name = System.Runtime.InteropServices.Marshal.StringToHGlobalUni(path);
        var file = System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf<FileInfo>());
        try
        {
            System.Runtime.InteropServices.Marshal.StructureToPtr(new FileInfo { cbStruct = (uint)System.Runtime.InteropServices.Marshal.SizeOf<FileInfo>(), pcwszFilePath = name }, file, false);
            var data = new Data
            {
                cbStruct = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Data>(),
                dwUIChoice = 2,              // WTD_UI_NONE
                fdwRevocationChecks = 0,     // WTD_REVOKE_NONE
                dwUnionChoice = 1,           // WTD_CHOICE_FILE
                pFile = file,
                dwStateAction = 1,           // WTD_STATEACTION_VERIFY
                dwProvFlags = 0x1000 | 0x10, // WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_NONE
            };
            var action = GenericVerifyV2;
            var code = WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            data.dwStateAction = 2;          // WTD_STATEACTION_CLOSE
            WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            return code;
        }
        finally
        {
            System.Runtime.InteropServices.Marshal.FreeHGlobal(file);
            System.Runtime.InteropServices.Marshal.FreeHGlobal(name);
        }
    }
}
#endif
