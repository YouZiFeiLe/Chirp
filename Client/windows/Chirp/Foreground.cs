namespace Chirp;

public sealed partial class MainPage
{
    private static bool directoryActive;
    private static int directoryVisibility;
    private static string directoryWatch = "";

    private static bool? loggingForeground;

    internal void WindowActivity()
    {
        if (closed || !loaded || App.Exiting) return;
        UpdateUnlockActivity();
        if (Owner.IsForeground) _ = CheckNetworkClock();
        var foreground = App.Pages.Any(p => p.Owner.IsForeground && p.Owner.AppWindow.IsVisible);
        if (protocol is not null && foreground != loggingForeground)
        {
            loggingForeground = foreground;
            protocol.Notify("logActivity", new { enabled = foreground });
        }
        var language = LanguageChoice.SelectedIndex;
        if (Owner.IsForeground && language == 0 &&
            english != DesktopText.English(language, Windows.System.UserProfile.GlobalizationPreferences.Languages))
            ApplyLanguage(language);
        if (member is not null) _ = Run(SyncForeground);
    }

    private async Task SyncForeground()
    {
        var active = App.Pages.Any(p => p.Owner.IsForeground && p.Owner.AppWindow.IsVisible);
        if (member is null || directoryActive == active) return;
        var login = member;
        var revision = ++directoryVisibility;
        directoryActive = active;
        if (!active)
        {
            directoryWatch = "";
            App.Primary.Page.refresh.Stop();
            MarkDirectoryStale();
            await Rpc("unwatchDirectory");
            return;
        }
        App.Primary.Page.refresh.Start();
        directoryWatch = Guid.NewGuid().ToString("D");
        await Rpc("watchDirectory", new { key = directoryWatch });
        if (revision != directoryVisibility || !ReferenceEquals(login, member)) return;
        await Refresh();
        if (revision == directoryVisibility && ReferenceEquals(login, member)) await RefreshFriendNames();
    }
}
