using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Chirp;

public sealed partial class MainPage
{
    private static readonly NetworkClock networkClock = new();
    private static DispatcherTimer? clockTimer;
    private ClockStatus? displayedClockStatus;
    private Button? approveDeviceButton;
    private int activeAuthFlows;
    private static bool loginInitialized;

    private static bool ClockReady => networkClock.Read().Status == ClockStatus.Ready;
    private sealed class ClockRequiredException : Exception { }

    private static void RequireNetworkClock()
    {
        if (!ClockReady) throw new ClockRequiredException();
    }

    private static void StartNetworkClock()
    {
        if (clockTimer is null)
        {
            clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            clockTimer.Tick += async (_, _) => await CheckNetworkClock();
            clockTimer.Start();
        }
        _ = CheckNetworkClock();
    }

    private static async Task CheckNetworkClock(bool manual = false)
    {
        var query = networkClock.RefreshAsync(manual);
        UpdateClockWindows();
        if (query.IsCompletedSuccessfully) return;
        await query;
        if (!App.Exiting) UpdateClockWindows();
    }

    private static void UpdateClockWindows()
    {
        var reading = networkClock.Read();
        foreach (var page in App.Pages)
            if (page.loaded && !page.closed) page.RenderClock(reading);
        UpdateUnlockActivity();
    }

    private void RenderClock(ClockReading reading, bool languageChanged = false)
    {
        var status = reading.Status;
        var changed = displayedClockStatus != status;
        if (changed)
        {
            if (displayedClockStatus == ClockStatus.Ready && activeAuthFlows > 0) Dialogs.Dismiss(XamlRoot);
            displayedClockStatus = status;
            UpdateLoginBusy();
            ResumePendingCallback();
        }
        if (!changed && !languageChanged && status == ClockStatus.Ready) return;
        ClockNotice.Visibility = Visible(status != ClockStatus.Ready);
        ClockNotice.IsOpen = status != ClockStatus.Ready;
        if (status == ClockStatus.Ready) return;

        ClockNotice.Severity = status == ClockStatus.Checking ? InfoBarSeverity.Informational : InfoBarSeverity.Warning;
        ClockActions.Visibility = Visible(status != ClockStatus.Checking);
        ClockSettings.Content = T("打开日期和时间设置", "Open date and time settings");
        ClockSettings.Visibility = Visible(status == ClockStatus.OutOfSync);
        ClockRetry.Content = T("重新校验", "Check again");
        ClockRetry.IsEnabled = networkClock.CanRetry;
        switch (status)
        {
            case ClockStatus.OutOfSync:
                ClockNotice.Title = T("请同步 Windows 时间", "Sync your Windows clock");
                var seconds = Math.Abs(reading.LocalOffset.TotalSeconds).ToString("N1", DisplayCulture);
                var offset = reading.LocalOffset > TimeSpan.Zero
                    ? T($"本机时间比网络时间快约 {seconds} 秒。", $"Your PC is about {seconds} seconds ahead of network time. ")
                    : T($"本机时间比网络时间慢约 {seconds} 秒。", $"Your PC is about {seconds} seconds behind network time. ");
                ClockNotice.Message = offset + T("请在日期和时间设置中选择“立即同步”。时间校准后即可登录或授权设备。",
                    "Select “Sync now” in Date and time settings. Sign-in and device approval will unlock automatically.");
                break;
            case ClockStatus.Unavailable:
                ClockNotice.Title = T("暂时无法核实网络时间", "Network time could not be verified");
                ClockNotice.Message = T("所有时间源都未返回有效时间。请检查网络是否允许 NTP（UDP 123），再重新校验。校验通过后即可登录或授权设备。",
                    "None of the time servers returned a valid time. Check that your network allows NTP (UDP 123) and try again to enable sign-in and device approval.");
                break;
            default:
                ClockNotice.Title = T("正在校验系统时间", "Checking your system clock");
                ClockNotice.Message = T("校验通过后即可登录或授权设备。", "Sign-in and device approval will be available once the check passes.");
                break;
        }
    }

    private async void ClockRetryClick(object sender, RoutedEventArgs args) => await CheckNetworkClock(manual: true);

    private async void ClockSettingsClick(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!await Launcher.LaunchUriAsync(new Uri("ms-settings:dateandtime")))
            Show(() => T("请在 Windows 设置中打开“时间和语言”下的“日期和时间”，然后选择“立即同步”。",
                "In Windows Settings, open Time & language, then Date & time, and select “Sync now”."), InfoBarSeverity.Warning);
    });

    private void ResumePendingCallback()
    {
        if (pendingCallback.Length == 0 || !loaded || closed || busy || !loginInitialized ||
            networkClock.Read().Status == ClockStatus.Checking) return;
        var callback = pendingCallback;
        pendingCallback = "";
        DispatcherQueue.TryEnqueue(() => HandleCallback(callback));
    }
}
