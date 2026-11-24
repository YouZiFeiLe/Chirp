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

    // WM_SYSCOMMAND reserves the low four bits and command IDs at or above 0xF000.
    private const uint NewWindowCommand = 0x1000, QuitCommand = 0x1010;
    private const nuint MenuSubclass = 2;
    private readonly WindowProcedure menuProcedure;
    private readonly nint systemMenu;
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
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
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
            RemoveWindowSubclass(hwnd, menuProcedure, MenuSubclass);
            Page.Detach();
        };
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
