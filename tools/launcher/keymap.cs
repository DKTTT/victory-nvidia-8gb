using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class KeyMap
{
    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr GetModuleHandle(string name);

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    static extern uint SendInput(uint n, INPUT[] p, int size);

    public static Dictionary<int, int> Map = new Dictionary<int, int>();
    public static IntPtr GameWindow = IntPtr.Zero;
    public static bool Enabled = false;
    public static string LastKey = "";
    public static int Toggles = 0;

    static HookProc _proc = Hook;
    static IntPtr _hook = IntPtr.Zero;

    public static bool Install()
    {
        if (_hook != IntPtr.Zero) return true;
        _hook = SetWindowsHookEx(13, _proc, GetModuleHandle(null), 0);
        return _hook != IntPtr.Zero;
    }

    public static void Uninstall()
    {
        Enabled = false;
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }

    public static string Status()
    {
        return "installed=" + (_hook != IntPtr.Zero) + " enabled=" + Enabled +
               " mappings=" + Map.Count + " game=" + GameWindow +
               " last=" + LastKey + " toggles=" + Toggles;
    }

    static void SendKey(int vk)
    {
        INPUT[] a = new INPUT[2];
        a[0].type = 1;
        a[0].ki.wVk = (ushort)vk;
        a[0].ki.dwFlags = 0;
        a[1].type = 1;
        a[1].ki.wVk = (ushort)vk;
        a[1].ki.dwFlags = 2;
        SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
    }

    static IntPtr Hook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0)
            {
                KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                bool injected = (k.flags & 0x10) != 0;
                int msg = (int)wParam;
                if (!injected)
                {
                    LastKey = "vk=" + k.vkCode;
                    // Ctrl+Alt+M: 开/关映射
                    if (k.vkCode == 0x4D && (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x12) & 0x8000) != 0)
                    {
                        Enabled = !Enabled;
                        Toggles++;
                        return (IntPtr)1;
                    }
                    bool focused = GameWindow != IntPtr.Zero && GetForegroundWindow() == GameWindow;
                    if (Enabled && focused)
                    {
                        int target;
                        if (Map.TryGetValue((int)k.vkCode, out target))
                        {
                            if (msg == 0x100 || msg == 0x104)
                            {
                                SendKey(target);
                                return (IntPtr)1;
                            }
                            if (msg == 0x101 || msg == 0x105)
                            {
                                return (IntPtr)1;
                            }
                        }
                    }
                }
            }
        }
        catch { }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}