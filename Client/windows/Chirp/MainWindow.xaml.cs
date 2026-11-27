using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Chirp;

public sealed partial class MainWindow : Window
{
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern nint GetSystemMenu(nint hwnd, bool revert);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool ModifyMenu(nint menu, uint item, uint flags, nuint id, string text);
    private delegate nint WindowProcedure(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, WindowProcedure callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, WindowProcedure callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out int process);
    [DllImport("wtsapi32.dll")] private static extern bool WTSRegisterSessionNotification(nint hwnd, uint flags);
    [DllImport("wtsapi32.dll")] private static extern bool WTSUnRegisterSessionNotification(nint hwnd);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, uint attribute, in int value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmSetIconicThumbnail(nint hwnd, nint bitmap, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmSetIconicLivePreviewBitmap(nint hwnd, nint bitmap, nint position, uint flags);
    [DllImport("gdi32.dll")] private static extern nint CreateBitmap(int width, int height, uint planes, uint depth, in uint pixel);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint handle);

    // WM_SYSCOMMAND reserves the low four bits and command IDs at or above 0xF000.
    private const uint NewWindowCommand = 0x1000, QuitCommand = 0x1010;
    private const nuint MenuSubclass = 2;
    private readonly WindowProcedure menuProcedure;
    private readonly nint systemMenu;
    private readonly nint hwnd;
    private string NewWindowLabel => Page.InEnglish ? "New window" : "新建窗口";
    private string QuitLabel => Page.InEnglish ? "Quit Chirp" : "退出 Chirp";
    internal MainPage Page { get; }
    internal bool IsForeground { get; private set; }

    public MainWindow()
    {
        InitializeComponent();
        Activated += (_, args) =>
        {
            IsForeground = args.WindowActivationState != WindowActivationState.Deactivated;
            DispatcherQueue.TryEnqueue(() => Page?.WindowActivity());
        };
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        AppWindow.Resize(new SizeInt32(Math.Min((int)(1184 * scale), workArea.Width), Math.Min((int)(780 * scale), workArea.Height)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(420 * scale);
            presenter.PreferredMinimumHeight = (int)(420 * scale);
        }
        Page = new MainPage { Owner = this };
        RootFrame.Content = Page;
        menuProcedure = HandleSystemCommand;
        if (SetWindowSubclass(hwnd, menuProcedure, MenuSubclass, 0))
        {
            WTSRegisterSessionNotification(hwnd, 0);
            const int enabled = 1;
            DwmSetWindowAttribute(hwnd, 7, enabled, sizeof(int));  // DWMWA_FORCE_ICONIC_REPRESENTATION
            DwmSetWindowAttribute(hwnd, 10, enabled, sizeof(int)); // DWMWA_HAS_ICONIC_BITMAP
            DwmSetWindowAttribute(hwnd, 11, enabled, sizeof(int)); // DWMWA_DISALLOW_PEEK
            systemMenu = GetSystemMenu(hwnd, false);
            if (systemMenu != 0)
            {
                const uint separator = 0x0800;
                AppendMenu(systemMenu, separator, 0, null);
                AppendMenu(systemMenu, 0, NewWindowCommand, NewWindowLabel);
                AppendMenu(systemMenu, 0, QuitCommand, QuitLabel);
            }
        }
        AppWindow.Closing += OnClosing;
        Closed += (_, _) =>
        {
            WTSUnRegisterSessionNotification(hwnd);
            RemoveWindowSubclass(hwnd, menuProcedure, MenuSubclass);
            Page.Detach();
        };
    }

    internal bool AtFront() => AppWindow.IsVisible && !IsIconic(hwnd) && GetForegroundWindow() == hwnd;

    internal bool HasHelloForeground()
    {
        if (!AppWindow.IsVisible || IsIconic(hwnd)) return false;
        var front = GetForegroundWindow();
        // The secure desktop can temporarily have no readable foreground HWND.
        if (front == 0 || GetAncestor(front, 3 /* GA_ROOTOWNER */) == hwnd) return true;
        GetWindowThreadProcessId(front, out var pid);
        try
        {
            using var broker = System.Diagnostics.Process.GetProcessById(pid);
            return string.Equals(broker.MainModule?.FileName, Path.Combine(Environment.SystemDirectory, "CredentialUIBroker.exe"),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return false; }
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        // Keep every window alive until the shared session has finished shutting down.
        args.Cancel = true;
        RequestQuit();
    }

    private void RequestQuit() => DispatcherQueue.TryEnqueue(async () => await App.Quit());

    internal void CloseAfterShutdown()
    {
        AppWindow.Closing -= OnClosing;
        Close();
    }

    internal void RefreshMenuLanguage()
    {
        if (systemMenu == 0) return;
        ModifyMenu(systemMenu, NewWindowCommand, 0, NewWindowCommand, NewWindowLabel);
        ModifyMenu(systemMenu, QuitCommand, 0, QuitCommand, QuitLabel);
    }

    private nint HandleSystemCommand(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        if (message == 0x02B1 /* WM_WTSSESSION_CHANGE */ && wParam is 7 or 8)
            MainPage.SessionLockChanged(wParam == 7);
        if (message == 0x001C /* WM_ACTIVATEAPP */ && wParam == 0)
            MainPage.LeftForeground();
        if (message == 0x0005 /* WM_SIZE */ && wParam == 1 /* SIZE_MINIMIZED */)
            MainPage.UpdateUnlockActivity();
        if (message is 0x0323 or 0x0326) // DWM iconic thumbnail / live preview
        {
            // Supply an opaque thumbnail even while a popup or a call is visible.
            uint pixel = 0xff242424;
            var bitmap = CreateBitmap(1, 1, 1, 32, pixel);
            if (bitmap != 0)
            {
                if (message == 0x0323) DwmSetIconicThumbnail(hwnd, bitmap, 0);
                else DwmSetIconicLivePreviewBitmap(hwnd, bitmap, 0, 0);
                DeleteObject(bitmap);
            }
            return 0;
        }
        const uint systemCommand = 0x0112;
        if (message == systemCommand)
        {
            switch (wParam & 0xfff0)
            {
                case NewWindowCommand:
                    DispatcherQueue.TryEnqueue(App.NewWindow);
                    return 0;
                case QuitCommand:
                    RequestQuit();
                    return 0;
            }
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }
}
