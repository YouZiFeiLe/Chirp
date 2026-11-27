using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace Chirp;

public partial class App : Application
{
#if CHIRP_UNPACKAGED
    // Setup and Uninstall wait for the application process to finish.
    private readonly Mutex installerMutex = new(false, @"Local\cn.youzifeile.Chirp.Desktop.Running");
#endif
    private static readonly List<MainWindow> windows = new();
    internal static readonly AudioService Audio = new();
    internal static ProtocolClient? Protocol { get; set; }
    internal static MainWindow Primary => windows[0];
    internal static MainWindow Shell { get; private set; } = null!;
    internal static MainPage[] Pages => windows.Select(w => w.Page).ToArray();
    internal static bool Exiting { get; private set; }
    private AppInstance? instance;
    public App() => InitializeComponent();

    protected override async void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        instance = AppInstance.FindOrRegisterForKey("Chirp");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(activation);
            Exit();
            return;
        }
        AddWindow();
        var dispatcher = Primary.DispatcherQueue;
        instance.Activated += (_, next) => dispatcher.TryEnqueue(() => { if (!Exiting) Activate(next); });
        Activate(activation);
    }

    private static void Activate(AppActivationArguments args)
    {
        var window = Shell.AppWindow.IsVisible ? Shell : windows.LastOrDefault(w => w.AppWindow.IsVisible) ?? Shell;
        if (args.Data is IProtocolActivatedEventArgs protocol)
        {
            window = MainPage.LoginWindow ?? Primary;
            window.Page.HandleCallback(protocol.Uri.AbsoluteUri);
        }
        Show(window);
    }

    private static void Show(MainWindow window)
    {
        window.AppWindow.Show();
        window.Activate();
    }
    private static MainWindow AddWindow()
    {
        var window = new MainWindow();
        windows.Add(window);
        Shell = window;
        window.Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) Shell = window; };
        window.Closed += (_, _) =>
        {
            windows.Remove(window);
            if (windows.Count > 0 && Shell == window) Shell = windows[^1];
        };
        return window;
    }
    internal static void NewWindow()
    {
        if (!Exiting) { MainPage.LogUI("newWindow"); Show(AddWindow()); }
    }

    internal static async Task Quit()
    {
        if (Exiting) return;
        Exiting = true;
        MainPage.InterruptUnlock();
        try
        {
            foreach (var window in windows) window.Page.Detach();
            Primary.Page.Shutdown();
            if (Protocol is not null) await Protocol.DisposeAsync();
        }
        finally
        {
            foreach (var window in windows.ToArray()) window.CloseAfterShutdown();
            Current.Exit();
        }
    }
}
