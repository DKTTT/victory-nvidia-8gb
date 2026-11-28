using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Neptune;

// GTK owns the window and dialogs. WebKit hosts the same bundled page as WebView2.
sealed class LinuxHost(bool test, string? saveDirectory) : IDesktopHost
{
    readonly string page = new Uri(Path.Combine(Payload.UiDir, App.Page)).AbsoluteUri;
    readonly List<Delegate> signalHandlers = [];
    readonly int uiThread = Environment.CurrentManagedThreadId;
    App controller = null!;
    IntPtr window;
    IntPtr view;
    bool handlingMessage;
    bool closed;

    public int Run()
    {
        controller = new App(this, test, saveDirectory);
        try
        {
            if (gtk_init_check(IntPtr.Zero, IntPtr.Zero) == 0)
                throw new InvalidOperationException("需要图形化的 Wayland 或 X11 会话。");
            if (webkit_get_major_version() < 2 || (webkit_get_major_version() == 2 && webkit_get_minor_version() < 40))
                throw new InvalidOperationException("需要 WebKitGTK 4.1（2.40 或更新版本）。");
        }
        catch (DllNotFoundException error)
        {
            throw new InvalidOperationException("请安装 GTK3 和 WebKitGTK 4.1 以启动 Linux 版。", error);
        }

        window = gtk_window_new(0);
        gtk_window_set_title(window, App.Title + (test ? "（测试配置）" : ""));
        gtk_window_set_default_size(window, 1280, 820);
        gtk_widget_set_size_request(window, 960, 600);
        // our own title bar, as on Windows: the page draws it and its buttons, and asks for moves and resizes
        gtk_window_set_decorated(window, 0);
        Connect(window, "window-state-event", new StateCallback(StateChanged));
        gtk_window_set_position(window, 1); // GTK_WIN_POS_CENTER
        // GTK reads SVG icons through gdk-pixbuf
        gtk_window_set_icon_from_file(window, Path.Combine(Payload.UiDir, "victory-icon.svg"), IntPtr.Zero);
        Connect(window, "destroy", new DestroyCallback((_, _) => { closed = true; gtk_main_quit(); }));

        var context = webkit_web_context_new_ephemeral();
        view = webkit_web_view_new_with_context(context);
        g_object_unref(context);
        var navy = new GdkRgba { Red = 17 / 255.0, Green = 17 / 255.0, Blue = 21 / 255.0, Alpha = 1 };   // no white flash before the page draws
        webkit_web_view_set_background_color(view, ref navy);
        // This local interface needs no GPU compositing. Software rendering also
        // works on X11 sessions without DRI3 and in remote desktops.
        webkit_settings_set_hardware_acceleration_policy(webkit_web_view_get_settings(view), 2);
        gtk_container_add(window, view);
        Connect(view, "context-menu", new ContextMenuCallback((_, _, _, _, _) => 1));
        Connect(view, "decide-policy", new PolicyCallback(DecidePolicy));
        Connect(view, "load-failed", new LoadFailedCallback((_, _, _, _, _) =>
        {
            Console.Error.WriteLine(App.Title + "：无法加载内置界面。");
            return 0;
        }));
        var manager = webkit_web_view_get_user_content_manager(view);
        Connect(manager, "script-message-received::vism", new MessageCallback(Receive));
        if (webkit_user_content_manager_register_script_message_handler(manager, "vism") == 0)
            throw new InvalidOperationException("无法注册 WebKit 消息通道。");

        gtk_widget_show_all(window);
        webkit_web_view_load_uri(view, page);
        gtk_main();
        return 0;
    }

    void Connect(IntPtr instance, string signal, Delegate handler)
    {
        signalHandlers.Add(handler);
        g_signal_connect_data(instance, signal, Marshal.GetFunctionPointerForDelegate(handler), IntPtr.Zero, IntPtr.Zero, 0);
    }

    int DecidePolicy(IntPtr webView, IntPtr decision, int type, IntPtr data)
    {
        if (type == 0) // WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION
        {
            var action = webkit_navigation_policy_decision_get_navigation_action(decision);
            var request = webkit_navigation_action_get_request(action);
            if (Marshal.PtrToStringUTF8(webkit_uri_request_get_uri(request)) == page) return 0;
        }
        else if (type == 2) // WEBKIT_POLICY_DECISION_TYPE_RESPONSE
        {
            return 0;
        }
        webkit_policy_decision_ignore(decision);
        return 1;
    }

    void Receive(IntPtr manager, IntPtr result, IntPtr data)
    {
        if (closed || handlingMessage || Marshal.PtrToStringUTF8(webkit_web_view_get_uri(view)) != page) return;
        var value = webkit_javascript_result_get_js_value(result);
        var text = jsc_value_to_string(value);
        if (text == IntPtr.Zero) return;
        handlingMessage = true;
        try
        {
            if (Marshal.PtrToStringUTF8(text) is string json) controller.OnMessage(json);
        }
        catch (Exception error) { Console.Error.WriteLine(App.Title + ": " + error.Message); }
        finally
        {
            handlingMessage = false;
            g_free(text);
        }
    }

    public void Post(string json)
    {
        void Deliver()
        {
            if (!closed)
                webkit_web_view_evaluate_javascript(view, $"window.vismReceive?.({json});", -1,
                    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }
        if (Environment.CurrentManagedThreadId == uiThread) Deliver();
        else g_idle_add(DeliverOnUiThread, GCHandle.ToIntPtr(GCHandle.Alloc((Action)Deliver)));
    }

    static readonly IdleCallback DeliverOnUiThread = data =>
    {
        var handle = GCHandle.FromIntPtr(data);
        try { ((Action)handle.Target!).Invoke(); }
        finally { handle.Free(); }
        return 0;
    };

    public string? ChooseExport(string filename) => ChooseFiles("将此存档分享为 zip", 1,
        Environment.GetFolderPath(Environment.SpecialFolder.Desktop), filename).FirstOrDefault();

    public string[] ChooseImports() => ChooseFiles("导入 GTA VI 存档", 0, multi: true);

    public string? ChooseSaveFolder(string? current) => ChooseFiles("选择 Victory 存档文件夹", 2,
        current ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).FirstOrDefault();

    public void RevealExport(string path)
    {
        if (Path.GetDirectoryName(path) is not string folder) return;
        try { Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true }); } catch { }
    }

    public string? PickFolder(string title) => ChooseFiles(title, 2, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), pattern: null).FirstOrDefault();
    // ---- the title bar: the page's buttons and drag regions ----
    public bool CustomFrame => true;
    public void Window(string cmd)
    {
        if (window == IntPtr.Zero) return;
        switch (cmd)
        {
            case "min": gtk_window_iconify(window); break;
            case "max": if (gtk_window_is_maximized(window) != 0) gtk_window_unmaximize(window); else gtk_window_maximize(window); break;
            case "close": gtk_window_close(window); break;
            case "drag":
                // started from the page's mousedown while the button is still held: the window manager takes it from there
                // (X11 and Wayland alike: GTK uses the press it just saw)
                if (Pointer(out var x, out var y)) gtk_window_begin_move_drag(window, 1, x, y, 0);
                break;
            default:
                if (cmd.StartsWith("resize:") && int.TryParse(cmd[7..], out var edge) && edge is >= 0 and <= 7 && Pointer(out var rx, out var ry))
                    gtk_window_begin_resize_drag(window, edge, 1, rx, ry, 0);
                break;
        }
    }
    static bool Pointer(out int x, out int y)
    {
        x = y = 0;
        var seat = gdk_display_get_default_seat(gdk_display_get_default());
        var pointer = seat == IntPtr.Zero ? IntPtr.Zero : gdk_seat_get_pointer(seat);
        if (pointer == IntPtr.Zero) return false;
        gdk_device_get_position(pointer, out _, out x, out y);
        return true;
    }
    int StateChanged(IntPtr widget, IntPtr ev, IntPtr data)
    {
        // GdkEventWindowState: type, window, send_event, changed_mask, new_window_state
        var state = Marshal.ReadInt32(ev, 24);
        var max = (state & (4 | 2 | 16)) != 0;   // maximized, fullscreen, or tiled (snapped)
        Post($"{{\"type\":\"win\",\"max\":{(max ? "true" : "false")}}}");
        return 0;
    }
    public string? PickFile(string title, string pattern, string patternName) => ChooseFiles(title, 0, pattern: pattern, patternName: patternName).FirstOrDefault();

    string[] ChooseFiles(string title, int action, string? directory = null, string? filename = null, bool multi = false,
        string? pattern = "*.[zZ][iI][pP]", string patternName = "存档压缩包 (*.zip)")
    {
        var dialog = gtk_file_chooser_native_new(title, window, action,
            action == 1 ? "保存" : action == 2 ? "选择" : "打开", "取消");
        try
        {
            gtk_file_chooser_set_select_multiple(dialog, multi ? 1 : 0);
            if (action == 2) gtk_file_chooser_set_show_hidden(dialog, 1);
            if (directory != null && Directory.Exists(directory)) gtk_file_chooser_set_current_folder(dialog, directory);
            if (filename != null)
            {
                gtk_file_chooser_set_current_name(dialog, filename);
                gtk_file_chooser_set_do_overwrite_confirmation(dialog, 1);
            }
            if (action != 2 && pattern != null)
            {
                var filter = gtk_file_filter_new();
                gtk_file_filter_set_name(filter, patternName);
                gtk_file_filter_add_pattern(filter, pattern);
                gtk_file_chooser_add_filter(dialog, filter);
            }
            if (gtk_native_dialog_run(dialog) != -3) return []; // GTK_RESPONSE_ACCEPT
            var list = gtk_file_chooser_get_filenames(dialog);
            var files = new List<string>();
            try
            {
                for (var item = list; item != IntPtr.Zero; item = Marshal.ReadIntPtr(item, IntPtr.Size))
                {
                    var file = Marshal.ReadIntPtr(item);
                    try { if (Marshal.PtrToStringUTF8(file) is string path) files.Add(path); }
                    finally { g_free(file); }
                }
            }
            finally { g_slist_free(list); }
            return files.ToArray();
        }
        finally { g_object_unref(dialog); }
    }

    const string Gtk = "libgtk-3.so.0";
    const string WebKit = "libwebkit2gtk-4.1.so.0";
    const string JavaScriptCore = "libjavascriptcoregtk-4.1.so.0";
    const string GLib = "libglib-2.0.so.0";
    const string GObject = "libgobject-2.0.so.0";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void DestroyCallback(IntPtr widget, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void MessageCallback(IntPtr manager, IntPtr result, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int PolicyCallback(IntPtr view, IntPtr decision, int type, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ContextMenuCallback(IntPtr view, IntPtr menu, IntPtr ev, IntPtr hit, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int LoadFailedCallback(IntPtr view, int ev, IntPtr uri, IntPtr error, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int IdleCallback(IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int StateCallback(IntPtr widget, IntPtr ev, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct GdkRgba { public double Red, Green, Blue, Alpha; }
    const string Gdk = "libgdk-3.so.0";
    [DllImport(Gtk)] static extern void gtk_window_set_decorated(IntPtr window, int setting);
    [DllImport(Gtk)] static extern void gtk_window_iconify(IntPtr window);
    [DllImport(Gtk)] static extern void gtk_window_maximize(IntPtr window);
    [DllImport(Gtk)] static extern void gtk_window_unmaximize(IntPtr window);
    [DllImport(Gtk)] static extern int gtk_window_is_maximized(IntPtr window);
    [DllImport(Gtk)] static extern void gtk_window_close(IntPtr window);
    [DllImport(Gtk)] static extern void gtk_window_begin_move_drag(IntPtr window, int button, int rootX, int rootY, uint timestamp);
    [DllImport(Gtk)] static extern void gtk_window_begin_resize_drag(IntPtr window, int edge, int button, int rootX, int rootY, uint timestamp);
    [DllImport(Gdk)] static extern IntPtr gdk_display_get_default();
    [DllImport(Gdk)] static extern IntPtr gdk_display_get_default_seat(IntPtr display);
    [DllImport(Gdk)] static extern IntPtr gdk_seat_get_pointer(IntPtr seat);
    [DllImport(Gdk)] static extern void gdk_device_get_position(IntPtr device, out IntPtr screen, out int x, out int y);
    [DllImport(WebKit)] static extern void webkit_web_view_set_background_color(IntPtr view, ref GdkRgba color);

    [DllImport(Gtk)] static extern int gtk_init_check(IntPtr argc, IntPtr argv);
    [DllImport(Gtk)] static extern void gtk_main();
    [DllImport(Gtk)] static extern void gtk_main_quit();
    [DllImport(Gtk)] static extern IntPtr gtk_window_new(int type);
    [DllImport(Gtk)] static extern void gtk_window_set_title(IntPtr window, string title);
    [DllImport(Gtk)] static extern void gtk_window_set_default_size(IntPtr window, int width, int height);
    [DllImport(Gtk)] static extern void gtk_window_set_position(IntPtr window, int position);
    [DllImport(Gtk)] static extern int gtk_window_set_icon_from_file(IntPtr window, string filename, IntPtr error);
    [DllImport(Gtk)] static extern void gtk_widget_set_size_request(IntPtr widget, int width, int height);
    [DllImport(Gtk)] static extern void gtk_widget_show_all(IntPtr widget);
    [DllImport(Gtk)] static extern void gtk_container_add(IntPtr container, IntPtr widget);
    [DllImport(Gtk)] static extern IntPtr gtk_file_chooser_native_new(string title, IntPtr parent, int action, string acceptLabel, string cancelLabel);
    [DllImport(Gtk)] static extern void gtk_file_chooser_set_select_multiple(IntPtr chooser, int value);
    [DllImport(Gtk)] static extern void gtk_file_chooser_set_show_hidden(IntPtr chooser, int value);
    [DllImport(Gtk)] static extern int gtk_file_chooser_set_current_folder(IntPtr chooser, string folder);
    [DllImport(Gtk)] static extern void gtk_file_chooser_set_current_name(IntPtr chooser, string name);
    [DllImport(Gtk)] static extern void gtk_file_chooser_set_do_overwrite_confirmation(IntPtr chooser, int value);
    [DllImport(Gtk)] static extern IntPtr gtk_file_filter_new();
    [DllImport(Gtk)] static extern void gtk_file_filter_set_name(IntPtr filter, string name);
    [DllImport(Gtk)] static extern void gtk_file_filter_add_pattern(IntPtr filter, string pattern);
    [DllImport(Gtk)] static extern void gtk_file_chooser_add_filter(IntPtr chooser, IntPtr filter);
    [DllImport(Gtk)] static extern int gtk_native_dialog_run(IntPtr dialog);
    [DllImport(Gtk)] static extern IntPtr gtk_file_chooser_get_filenames(IntPtr chooser);
    [DllImport(WebKit)] static extern uint webkit_get_major_version();
    [DllImport(WebKit)] static extern uint webkit_get_minor_version();
    [DllImport(WebKit)] static extern IntPtr webkit_web_context_new_ephemeral();
    [DllImport(WebKit)] static extern IntPtr webkit_web_view_new_with_context(IntPtr context);
    [DllImport(WebKit)] static extern IntPtr webkit_web_view_get_settings(IntPtr view);
    [DllImport(WebKit)] static extern void webkit_settings_set_hardware_acceleration_policy(IntPtr settings, int policy);
    [DllImport(WebKit)] static extern IntPtr webkit_web_view_get_user_content_manager(IntPtr view);
    [DllImport(WebKit)] static extern int webkit_user_content_manager_register_script_message_handler(IntPtr manager, string name);
    [DllImport(WebKit)] static extern IntPtr webkit_javascript_result_get_js_value(IntPtr result);
    [DllImport(WebKit)] static extern void webkit_web_view_load_uri(IntPtr view, string uri);
    [DllImport(WebKit)] static extern IntPtr webkit_web_view_get_uri(IntPtr view);
    [DllImport(WebKit)] static extern void webkit_web_view_evaluate_javascript(IntPtr view, string script, nint length, IntPtr world, IntPtr uri, IntPtr cancellation, IntPtr callback, IntPtr data);
    [DllImport(WebKit)] static extern IntPtr webkit_navigation_policy_decision_get_navigation_action(IntPtr decision);
    [DllImport(WebKit)] static extern IntPtr webkit_navigation_action_get_request(IntPtr action);
    [DllImport(WebKit)] static extern IntPtr webkit_uri_request_get_uri(IntPtr request);
    [DllImport(WebKit)] static extern void webkit_policy_decision_ignore(IntPtr decision);
    [DllImport(JavaScriptCore)] static extern IntPtr jsc_value_to_string(IntPtr value);
    [DllImport(GLib)] static extern void g_free(IntPtr data);
    [DllImport(GLib)] static extern void g_slist_free(IntPtr list);
    [DllImport(GLib)] static extern uint g_idle_add(IdleCallback callback, IntPtr data);
    [DllImport(GObject)] static extern void g_object_unref(IntPtr obj);
    [DllImport(GObject)] static extern nuint g_signal_connect_data(IntPtr obj, string signal, IntPtr handler, IntPtr data, IntPtr destroy, int flags);
}
