using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Neptune;

sealed class WindowsHost : Form, IDesktopHost
{
    readonly WebView2 ui = new();
    readonly string root = AppContext.BaseDirectory;
    readonly App controller;

    public WindowsHost(bool test)
    {
        controller = new App(this, test, null);
        Text = App.Title + (test ? " (test profile)" : "");
        try { Icon = new Icon(Path.Combine(root, "victory.ico")); } catch { }
        BackColor = Color.FromArgb(0x11, 0x11, 0x15);
        ClientSize = new Size(1240, 800);
        MinimumSize = new Size(960, 600);
        StartPosition = FormStartPosition.CenterScreen;
        ui.Dock = DockStyle.Fill;
        ui.DefaultBackgroundColor = BackColor;
        Controls.Add(ui);
        Load += async (_, _) => await InitAsync();
    }

    // ---- our own title bar: the page draws the whole window, top edge included ----
    // The caption is taken away (WM_NCCALCSIZE) but the rest of the normal frame stays, so the
    // side and bottom edges still resize and Windows still draws the shadow. The page marks its
    // header `app-region: drag` (dragging, snapping, double-click to maximize) and draws its own
    // minimize, maximize and close buttons.
    public bool CustomFrame { get; private set; }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        FitToScreen();
        try
        {
            int dark = 1, navy = 0x00151111;   // #111115 as 0x00BBGGRR
            DwmSetWindowAttribute(Handle, 20, ref dark, 4);   // dark frame
            DwmSetWindowAttribute(Handle, 34, ref navy, 4);   // border color (Windows 11)
            DwmSetWindowAttribute(Handle, 35, ref navy, 4);   // caption color: the thin resize band Windows still paints along the top edge
            CustomFrame = true;
            SetWindowPos(Handle, IntPtr.Zero, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010);   // FRAMECHANGED, NOMOVE, NOSIZE, NOZORDER, NOACTIVATE
        }
        catch { CustomFrame = false; }
    }

    protected override void WndProc(ref Message m)
    {
        const int WM_NCCALCSIZE = 0x0083;
        if (m.Msg == WM_NCCALCSIZE && m.WParam != IntPtr.Zero && CustomFrame)
        {
            var p = Marshal.PtrToStructure<NcCalcSizeParams>(m.LParam);
            int top = p.Rect0.Top;
            base.WndProc(ref m);   // the normal frame
            p = Marshal.PtrToStructure<NcCalcSizeParams>(m.LParam);
            // no caption; a maximized window hangs past the screen edge by its frame, so keep that much
            p.Rect0.Top = top + (WindowState == FormWindowState.Maximized ? FrameThickness() : 0);
            Marshal.StructureToPtr(p, m.LParam, false);
            m.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref m);
    }

    int FrameThickness()
    {
        try { var dpi = GetDpiForWindow(Handle); return GetSystemMetricsForDpi(33, dpi) + GetSystemMetricsForDpi(92, dpi); }   // SM_CYFRAME + SM_CXPADDEDBORDER
        catch { return 8; }
    }

    // sizes are in screen pixels: on a scaled display (125%, 150%...) the page is drawn larger, so the
    // window grows by the same amount, without going past the screen it opens on
    void FitToScreen()
    {
        var scale = DeviceDpi / 96f;
        var area = Screen.FromHandle(Handle).WorkingArea;
        int W(float w) => Math.Min((int)(w * scale), (int)(area.Width * .94));
        int H(float h) => Math.Min((int)(h * scale), (int)(area.Height * .94));
        StartPosition = FormStartPosition.Manual;   // centered here, after the size is right
        MinimumSize = new Size(W(960), H(600));
        Size = new Size(W(1280), H(820));
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
    }

    // the page's buttons, and the maximize button's look following the window
    public void Window(string cmd)
    {
        switch (cmd)
        {
            case "min": WindowState = FormWindowState.Minimized; break;
            case "max": WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized; break;
            case "close": Close(); break;
        }
    }
    FormWindowState lastState = FormWindowState.Normal;
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (WindowState == lastState) return;
        lastState = WindowState;
        Post($"{{\"type\":\"win\",\"max\":{(WindowState == FormWindowState.Maximized ? "true" : "false")}}}");
    }

    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct NcCalcSizeParams { public Rect Rect0, Rect1, Rect2; public IntPtr Pos; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);

    async Task InitAsync()
    {
        Directory.CreateDirectory(controller.ProfileDirectory);
        var env = await CoreWebView2Environment.CreateAsync(null, controller.ProfileDirectory);
        await ui.EnsureCoreWebView2Async(env);
        var core = ui.CoreWebView2;
        core.SetVirtualHostNameToFolderMapping("app.neptune", Path.Combine(root, "ui"), CoreWebView2HostResourceAccessKind.Allow);
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        try { core.Settings.IsNonClientRegionSupportEnabled = true; } catch { }   // the header's app-region: drag
        core.WebMessageReceived += (_, e) => controller.OnMessage(e.WebMessageAsJson);
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith("https://app.neptune/", StringComparison.OrdinalIgnoreCase)) e.Cancel = true; };
        core.Navigate("https://app.neptune/" + App.Page);

        // (GTA6 CN) end-to-end test hook: VICTORY_LAUNCHER_E2E=<javascript> runs once the page is up.
        var e2e = Environment.GetEnvironmentVariable("VICTORY_LAUNCHER_E2E");
        if (!string.IsNullOrEmpty(e2e))
        {
            core.NavigationCompleted += async (_, _) =>
            {
                await Task.Delay(2500);
                try { await core.ExecuteScriptAsync(e2e); } catch { }
            };
        }
    }

    public void Post(string json)
    {
        if (IsDisposed || !IsHandleCreated) return;
        void PostMessage() { ui.CoreWebView2?.PostWebMessageAsJson(json); }
        if (InvokeRequired) BeginInvoke(PostMessage); else PostMessage();
    }

    public string? ChooseExport(string filename)
    {
        using var dialog = new SaveFileDialog
        {
            Title = "Share this save as a zip", Filter = "GTA VI save (*.zip)|*.zip",
            FileName = filename, DefaultExt = "zip",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
        };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null;
    }

    public string[] ChooseImports()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Import GTA VI saves", Filter = "Save zips (*.zip)|*.zip", Multiselect = true,
        };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileNames : [];
    }

    public string? ChooseSaveFolder(string? current) => null;

    public string? PickFolder(string title)
    {
        using var dialog = new FolderBrowserDialog { Description = title, UseDescriptionForTitle = true, ShowNewFolderButton = true };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedPath : null;
    }

    public string? PickFile(string title, string pattern, string patternName)
    {
        using var dialog = new OpenFileDialog { Title = title, Filter = $"{patternName}|{pattern}|All files (*.*)|*.*" };
        return dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null;
    }

    public void RevealExport(string path)
    {
        try { Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { }
    }
}
