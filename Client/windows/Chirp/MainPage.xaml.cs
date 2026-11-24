using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage;
using Windows.System;

namespace Chirp;

public sealed partial class MainPage : Page
{
    private const string RecoveryFileExtension = ".chirpkey";
    // All windows live on the same UI dispatcher and share one authenticated engine and audio session.
    private static ProtocolClient? protocol => App.Protocol;
    private static AudioService audio => App.Audio;
    internal MainWindow Owner { get; init; } = null!;
    internal static MainWindow? LoginWindow { get; private set; }
    internal bool InEnglish => english;
    private readonly DispatcherTimer refresh = new() { Interval = TimeSpan.FromSeconds(30) };
#if CHIRP_UNPACKAGED
    private static readonly ApplicationData data = ApplicationData.GetForUnpackaged("cn.youzifeile.Chirp", "Windows");
#else
    private static readonly ApplicationData data = ApplicationData.GetDefault();
#endif
    private readonly ApplicationDataContainer settings = data.LocalSettings;
    private static JsonNode? connection, member, directory, call;
    private string selected = "", selectionType = "room", pendingCallback = "";
    private static bool busy, refreshing, refreshQueued, canEnroll, directoryStale;
    private bool buildingNav, english, loaded, closed;
    private bool editingAddress;
    private string lastAddressText = "";
    private static int authGeneration;
    private static bool hasSavedAccounts;
    private int pageGeneration;
    private long lastReadSequence;
    private string lastRoomRender = "";
    private static string lastDirectory = "", ownEntry = "", joiningKey = "", joiningRoom = "";
    private static readonly ChatTimeline transcript = new();
    private static readonly RoomPresence presence = new();
    private static JsonArray friends = new();

    public MainPage()
    {
        InitializeComponent();
        RoomVerificationNotice.Translation = new(0, 0, 16);
        ((ThemeShadow)RoomVerificationNotice.Shadow).Receivers.Add(WorkspaceGrid);
        LanguageChoice.ItemsSource = new[] { "系统 / System", "简体中文", "English" };
        LanguageChoice.SelectedIndex = Math.Clamp(GetInt("language", 1), 0, 2);
        Nav.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty, (_, _) => UpdatePaneChrome());
        UpdatePaneChrome();
        UpdateLanguage();
        ApplyTheme();
        SetAddressText(Preference("address"));
        Address.LostFocus += (_, _) => editingAddress = false;
        refresh.Tick += async (_, _) => await Run(Refresh);
        SizeChanged += (_, args) =>
        {
            var shortWindow = args.NewSize.Height < 500;
            FitHeader();
            FitVerificationNotice();
            RoomDock.Padding = shortWindow ? new Thickness(12, 8, 12, 8) : new Thickness(16, 12, 16, 12);
        };
        Loaded += (_, _) => Start();
    }

    private void Start()
    {
        if (loaded || closed) return;
        loaded = true;
        motionSettings.AnimationsEnabledChanged += MotionPreferenceChanged;
        ApplyTheme();
        StartNetworkClock();
        UpdateLoginBusy();
        if (member is null) MoveSurface(LoginCard, y: 12);
        try
        {
            if (protocol is not null)
            {
                ApproveSaved.Visibility = Visible(hasSavedAccounts);
                if (member is not null) ShowWorkspace();
                else if (connection is not null) ShowConnection();
                return;
            }
            LoadAudio();
#if CHIRP_UNPACKAGED
            var logCache = data.LocalPath;
#else
            var logCache = data.LocalCachePath;
#endif
            App.Protocol = new ProtocolClient(data.LocalPath, logCache, OnNotification);
            SyncLogAudio();
            audio.CaptureInitialized += denoise => LogUI("captureInitialized", enabled: denoise, outcome: "succeeded");
            audio.Encoded += (group, packet, level) => protocol?.Voice(group, packet, level);
            audio.Failed += (version, message) => DispatcherQueue.TryEnqueue(() => { if (audio.IsCurrentInput(version)) AudioFailed(message); });
            WatchAudioRoutes();
            _ = Run(async () =>
            {
                ApplyLogState(await Rpc("logState"));
                LogUI("login");
                WindowActivity();
                try { await RestoreConfirmed(); }
                finally
                {
                    loginInitialized = true;
                    foreach (var page in App.Pages) page.ResumePendingCallback();
                }
            });
        }
        catch (Exception e) { ShowError(e); }
    }

    private string T(string zh, string en) => english ? en : zh;
    private string L(string key) => SharedCopy.Text(key, english);
    private CultureInfo DisplayCulture => CultureInfo.GetCultureInfo(english ? "en-US" : "zh-CN");
    private string Preference(string name, string fallback = "") => settings.Values.TryGetValue(name, out var value) ? value?.ToString() ?? fallback : fallback;
    private int GetInt(string key, int fallback) => int.TryParse(Preference(key), out int n) ? n : fallback;
    private void Set(string key, object value)
    {
        if (settings.Values.TryGetValue(key, out var previous) && Equals(value, previous)) return;
        settings.Values[key] = value;
        var action = key switch
        {
            "language" => "changeLanguage", "theme" => "changeTheme", "sounds" => "changeSoundEffects",
            "volume" => "changeOutputVolume", "gain" => "changeInputGain", "activation" => "changeVoiceActivation",
            "threshold" => "changeActivationThreshold", _ => null
        };
        if (action is not null) LogUI(action);
    }
    private Task<JsonNode?> Rpc(string op, object? args = null)
    {
        // A browser callback, picker or Windows Hello prompt can outlive the last clock check.
        if (op is "browser" or "exchange" or "phone" or "pollPhone" or "finishPhone" or "recover"
            or "backup" or "unlockBackup" or "backupExported" or "verifyBackup" or "finishBackup"
            or "pairNew" or "pairOld" or "pairPoll" or "pairCheckCode" or "pairConfirm" or "finishPair")
            RequireNetworkClock();
        return protocol?.Send(op, args) ?? Task.FromException<JsonNode?>(new IOException("PROTOCOL_STOPPED"));
    }

    private void UpdateLanguage()
    {
        english = DesktopText.English(LanguageChoice.SelectedIndex, Windows.System.UserProfile.GlobalizationPreferences.Languages);
        Language = english ? "en-US" : "zh-CN";
        WelcomeHeading.Text = L("和朋友，随时碰头。");
        WelcomeDesc.Text = L("通行密钥登录 · 端到端加密通话");
        Address.Header = T("服务器地址", "Server address");
        ButtonLabel(ConnectButton, T("连接服务器", "Connect to server"), "\uE774");
        ButtonLabel(Passkey, T("使用通行密钥登录", "Sign in with a passkey"), "\uE8D7");
        ButtonLabel(Phone, T("用手机扫码登录", "Sign in with your phone"), "\uE8EA");
        Register.Content = T("申请注册", "Request an account");
        LanguageChoice.Header = T("界面语言", "Display language");
        AutomationProperties.SetName(Working, T("正在处理登录请求", "Processing sign-in request"));
        LocalOptions.Content = T("本机选项", "This device");
        ManageLogs.Text = T("日志管理", "Log management");
        ClearDevice.Text = T("清空本地数据", "Clear local data");
        ApproveSaved.Text = T("本机已保存的身份与设备授权", "Saved identities and device approval");
        ProfileLabel.Text = T("个人资料", "My profile");
        Label(ProfileButton, T("编辑个人资料", "Edit profile"));
        Nav.PaneTitle = T("工作区", "Workspace");
        Label(RoomDetails, T("房间信息", "Room information"));
        Label(DockAudio, T("声音设置", "Audio settings"));
        ChatTitle.Text = T("房间聊天", "Room chat");
        ChatLifetime.Text = L("消息仅在本次相聚时保留，离房后清空。");
        EmptyChatLabel.Text = T("还没有消息", "No messages yet");
        EmptyChatDetail.Text = L("只显示本次加入后收到的消息。");
        Draft.PlaceholderText = T("输入消息", "Write a message");
        AutomationProperties.SetName(Draft, T("房间聊天消息", "Room chat message"));
        Label(SendChat, T("发送消息 (Enter)", "Send message (Enter)"));
        Label(Attach, T("添加附件", "Add attachment"));
        UpdateLoginStage();
        RenderClock(networkClock.Read(), languageChanged: true);
        RefreshNotice();
    }

    private void UpdateLoginStage()
    {
        var confirmed = connection is not null;
        LoginHeading.Text = confirmed ? T("登录 Chirp", "Sign in to Chirp") : T("连接到 Chirp", "Connect to Chirp");
        LoginIntro.Text = confirmed ? T("服务器已连接。请选择登录方式。", "Connected to your server. Choose how to sign in.")
            : T("输入你的 Chirp 服务器地址，即可开始登录。", "Enter your Chirp server address to get started.");
        ConnectButton.Visibility = Visible(!confirmed);
        AuthActions.Visibility = Visible(confirmed);
        Phone.Visibility = Visible(connection.Bool("phone"));
        Register.Visibility = Visible(connection.Bool("registration"));
    }

    private void ApplyTheme()
    {
        var theme = (ElementTheme)Math.Clamp(GetInt("theme", 0), 0, 2);
        RequestedTheme = theme;
        if (Owner?.Content is FrameworkElement root)
        {
            root.RequestedTheme = theme;
            Owner.AppWindow.TitleBar.PreferredTheme = theme switch
            {
                ElementTheme.Light => Microsoft.UI.Windowing.TitleBarTheme.Light,
                ElementTheme.Dark => Microsoft.UI.Windowing.TitleBarTheme.Dark,
                _ => Microsoft.UI.Windowing.TitleBarTheme.UseDefaultAppMode
            };
        }
        if (themeChoice is not null) themeChoice.SelectedIndex = (int)theme;
    }

    private void UpdatePaneChrome() => SidebarIdentity.Visibility = Visible(Nav.IsPaneOpen);

    private async void ProfileClick(object sender, RoutedEventArgs args) => await Run(Profile);
    private async void RoomDetailsClick(object sender, RoutedEventArgs args) => await Run(RoomInfo);

    private void LanguageChanged(object sender, SelectionChangedEventArgs args)
    {
        if (LanguageChoice.SelectedIndex < 0 || !loaded || syncingLanguage) return;
        Set("language", LanguageChoice.SelectedIndex);
        foreach (var page in App.Pages) page.ApplyLanguage(LanguageChoice.SelectedIndex);
    }
    private bool syncingLanguage;
    private void ApplyLanguage(int choice)
    {
        syncingLanguage = true;
        try { LanguageChoice.SelectedIndex = choice; UpdateLanguage(); Owner?.RefreshMenuLanguage(); }
        finally { syncingLanguage = false; }
        if (member is not null) { BuildNav(); Render(); DrawMessagesHere(); }
    }
    private void LoginSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 860 || e.NewSize.Height < 480;
        LoginViewport.MinHeight = e.NewSize.Height;
        LoginViewport.Padding = new Thickness(narrow ? 16 : 32, 24, narrow ? 16 : 32, 24);
        LoginCard.MaxWidth = narrow ? 492 : 1000;
        LoginForm.Padding = narrow ? new Thickness(24) : new Thickness(38, 34, 38, 34);
        BrandColumn.Width = narrow ? new GridLength(0) : new GridLength(1.08, GridUnitType.Star);
        BrandPanel.Visibility = Visible(!narrow);
    }
    private void WorkspaceResized(object sender, SizeChangedEventArgs e)
    {
        FitHeader();
        LayoutChat();
    }

    private void FitHeader()
    {
        var room = RoomCover.Visibility == Visibility.Visible;
        var compact = ActualHeight < 500 || WorkspaceGrid.ActualWidth < 540;
        var artwork = room && !compact && WorkspaceGrid.ActualWidth >= 700;
        RoomRibbon.Visibility = Visible(artwork);
        HeaderArtColumn.Width = artwork ? new GridLength(0.9, GridUnitType.Star) : new GridLength(0);
        HeaderContent.Padding = compact ? new Thickness(14, 9, 14, 9) : new Thickness(24, 16, 24, 16);
        HeaderContent.MinHeight = compact ? 0 : room ? 108 : 76;
        WorkspaceTitle.FontSize = compact ? 22 : room ? 32 : 28;
    }
    private void StageResized(object sender, SizeChangedEventArgs e)
    {
        var inset = e.NewSize.Width < 520 ? 16 : 24;
        Stage.Padding = new Thickness(inset, 20, inset, 24);
    }
    private void SetAddressText(string address)
    {
        // WinUI can deliver TextChanged after the Text assignment returns.
        lastAddressText = address;
        if (Address.Text != address) Address.Text = address;
    }
    private void AddressChanged(object sender, TextChangedEventArgs e) => ApplyAddressEdit();
    private void ApplyAddressEdit()
    {
        if (!loaded || member is not null || Address.Text == lastAddressText) return;
        lastAddressText = Address.Text;
        if (!editingAddress) { editingAddress = true; LogUI("editServer"); }
        authGeneration++; connection = null;
        if (protocol is not null) _ = Run(async () => await Rpc("invalidateConnection"));
        if (string.IsNullOrWhiteSpace(lastAddressText)) settings.Values.Remove("address");
        foreach (var page in App.Pages)
        {
            page.UpdateLoginStage();
            page.LoginNotice.IsOpen = false;
        }
    }
    private async void AddressKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || busy) return;
        if (connection is not null && Address.Text == lastAddressText) return;
        e.Handled = true;
        await ConnectFromForm();
    }
    private async void ConnectClick(object sender, RoutedEventArgs e) => await ConnectFromForm();
    private async Task ConnectFromForm()
    {
        await Run(Discover, true);
        if (!closed && Passkey.IsEnabled && connection is not null && member is null && Owner.IsForeground)
            Passkey.Focus(FocusState.Programmatic);
    }
    private async void ClearLocalClick(object sender, RoutedEventArgs e) => await Run(ClearLocalData, true);
    private async Task ClearLocalData()
    {
        if (!await Confirm(T("清空本地数据？", "Clear local data?"),
            T("此电脑上的所有 Chirp 设备密钥、待确认的恢复文件、好友信任记录、附件缓存、日志和偏好设置将被删除。下次登录需要重新授权此设备或导入已保存的恢复文件。服务器账号和你自行导出的文件会保留。",
              "This removes all Chirp device keys, pending recovery exports, local trust records, attachment cache, logs and preferences on this PC. You will need another authorized device or your saved recovery file to sign in again. Your server account and exported files are kept."),
            T("清空本地数据", "Clear local data"))) return;
        await Rpc("clearLocalData");
        ApplyLogState(await Rpc("logState"));
        settings.Values.Clear(); SignedOut();
        foreach (var page in App.Pages) { page.SetAddressText(""); page.ApplyLanguage(1); page.ApplyTheme(); }
        LoadAudio();
        Show(() => T("本地数据已清空", "Local data cleared"), InfoBarSeverity.Success);
    }
    private async Task Discover()
    {
        // Submitting can precede the final TextChanged from typing or pasting.
        ApplyAddressEdit();
        var generation = ++authGeneration;
        var id = Guid.NewGuid().ToString("N");
        await Rpc("discover", new { address = lastAddressText, action = "stage", id });
        if (generation != authGeneration || closed) return;
        var result = await Rpc("confirmConnection", new { id });
        if (generation != authGeneration) return;
        ApplyConfirmed(result);
        LoginNotice.IsOpen = false;
    }
    private void ShowConnection()
    {
        var entering = AuthActions.Visibility != Visibility.Visible;
        UpdateLoginStage();
        ApproveSaved.Visibility = Visible(hasSavedAccounts);
        if (entering && AuthActions.Visibility == Visibility.Visible && loaded) MoveSurface(AuthActions, y: 8);
    }
    private async Task RestoreConfirmed()
    {
        var generation = authGeneration;
        hasSavedAccounts = await Rpc("savedAccounts") is JsonArray { Count: > 0 };
        foreach (var page in App.Pages) page.ApproveSaved.Visibility = Visible(hasSavedAccounts);
        if (generation != authGeneration || member is not null || closed) return;
        var saved = await Rpc("restoreConnection");
        if (generation != authGeneration || saved is null || member is not null || closed) return;
        ApplyConfirmed(saved);
    }
    private void ApplyConfirmed(JsonNode? saved)
    {
        var confirmed = saved.Str("address");
        foreach (var page in App.Pages) page.SetAddressText(confirmed);
        Set("address", confirmed);
        connection = saved;
        foreach (var page in App.Pages) page.ShowConnection();
    }
    private async void ApproveSavedClick(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        var generation = authGeneration;
        if (await Rpc("savedAccounts") is not JsonArray { Count: > 0 } saved) return;
        if (generation != authGeneration || closed) return;
        var identities = saved.Select(s => s.Str("origin") + " · " + s.Str("id")).ToArray();
        var choice = Choice(T("已保存的账号身份", "Saved account identity"), identities, 0);
        var fingerprint = CopyText("");
        var permission = Secondary("");
        var box = Dialogs.Box(XamlRoot, T("本机已保存的身份", "Saved identities"), Stack(choice, fingerprint, permission), T("关闭", "Close"), T("授权新设备", "Approve a device"));
        void SelectIdentity()
        {
            if (choice.SelectedIndex < 0) { box.IsPrimaryButtonEnabled = false; return; }
            var selected = saved[choice.SelectedIndex];
            fingerprint.Text = T("账号指纹", "Account fingerprint") + "\n" + DesktopText.Fingerprint(selected.Str("root")) + "\n" + T("设备指纹", "Device fingerprint") + "\n" + DesktopText.Fingerprint(selected.Str("key"));
            var sameServer = connection is not null && selected.Str("origin") == connection.Str("origin");
            box.IsPrimaryButtonEnabled = selected.Bool("canApprove") && sameServer;
            permission.Text = !selected.Bool("canApprove") ? T("此身份没有授权新设备的权限。", "This identity cannot approve a new device.") :
                !sameServer ? T("请先连接到此身份所属的服务器，再授权新设备。", "Connect to this identity’s server before approving a new device.") : "";
            permission.Visibility = Visible(permission.Text.Length > 0);
        }
        choice.SelectionChanged += (_, _) => SelectIdentity(); SelectIdentity();
        if (await box.ShowAsync() != ContentDialogResult.Primary) return;
        if (generation != authGeneration || closed) return;
        if ((await Pair(false, saved[choice.SelectedIndex].Str("id"))).Str("step") == "complete") Show(() => T("新设备已获授权", "New device approved"), InfoBarSeverity.Success);
    }, true, requiresClock: true);
    private static Task OpenLoginBrowser(string action, string url) => LogAction(action, async () =>
    {
        if (!await Launcher.LaunchUriAsync(new Uri(url))) throw new IOException("BROWSER_UNAVAILABLE");
        return true;
    });

    private async void RegisterClick(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        var generation = authGeneration;
        var c = await Rpc("register");
        if (generation != authGeneration || closed) return;
        await OpenLoginBrowser("openRegistration", c.Str("url"));
        Show(() => L("请在浏览器完成注册，管理员批准后返回登录。"));
    }, true);
    private async void PasskeyClick(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        LoginWindow = Owner;
        var generation = authGeneration;
        var r = await Rpc("browser");
        if (generation != authGeneration || closed) return;
        RequireNetworkClock();
        await OpenLoginBrowser("openBrowser", r.Str("url"));
        Show(() => T("请在系统浏览器中使用通行密钥登录。", "Finish signing in with your passkey in the browser."));
    }, true, requiresClock: true);
    internal void HandleCallback(string uri)
    {
        if (!loaded || !loginInitialized || busy || networkClock.Read().Status == ClockStatus.Checking) { pendingCallback = uri; return; }
        pendingCallback = "";
        if (connection is null || member is not null) return;
        _ = Run(async () => await AfterLogin(await Rpc("exchange", new { url = uri })), true, requiresClock: true);
    }
    private async void PhoneClick(object sender, RoutedEventArgs e) => await Run(async () =>
    {
        var generation = ++authGeneration;
        while (generation == authGeneration && !closed)
        {
            var start = await Rpc("phone");
            var id = start.Str("id");
            var expires = DateTimeOffset.FromUnixTimeSeconds(start.Num("expires"));
            var interval = TimeSpan.FromSeconds(Math.Max(1, start.Num("interval")));
            var claimed = false;
            ContentDialogResult choice;
            try
            {
                var qr = await Dialogs.Qr(start.Str("url"));
                RequireNetworkClock();
                AutomationProperties.SetName(qr, T("手机扫码登录二维码", "Phone sign-in QR code"));
                var countdown = Secondary("");
                var waiting = T("等待手机确认，完成后会自动登录。", "Waiting for confirmation on your phone. You will be signed in automatically.");
                var status = Secondary(waiting);
                var instructions = Text(T("用手机扫描二维码，在手机浏览器中使用通行密钥确认登录。", "Scan the code and confirm with a passkey in your phone’s browser."));
                var box = Dialogs.Box(XamlRoot, T("用手机扫码登录", "Sign in with your phone"), Stack(instructions, qr, countdown, status), T("取消", "Cancel"));
                box.SecondaryButtonText = T("刷新二维码", "Refresh QR code");
                using var cancel = new CancellationTokenSource();
                box.Closing += (_, _) => cancel.Cancel();
                void UpdateTime()
                {
                    var remaining = Math.Max(0, (int)Math.Ceiling((expires - DateTimeOffset.UtcNow).TotalSeconds));
                    countdown.Text = remaining > 0 ? T($"剩余 {remaining} 秒", remaining == 1 ? "1 second remaining" : $"{remaining} seconds remaining") : T("二维码已过期，请刷新。", "The code expired. Refresh it to continue.");
                    status.Visibility = Visible(remaining > 0);
                }
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                timer.Tick += (_, _) => UpdateTime(); UpdateTime(); timer.Start();
                var shown = box.ShowAsync().AsTask();
                try
                {
                    var delay = interval;
                    while (!cancel.IsCancellationRequested && generation == authGeneration && !closed && DateTimeOffset.UtcNow < expires)
                    {
                        await Task.Delay(delay, cancel.Token);
                        if (DateTimeOffset.UtcNow >= expires) break;
                        try
                        {
                            var result = await Rpc("pollPhone", new { id });
                            if (cancel.IsCancellationRequested || generation != authGeneration || closed) break;
                            if (result.Str("step") == "claimed") { claimed = true; break; }
                            status.Text = waiting;
                            delay = interval;
                        }
                        catch (ProtocolException ex) when (ex.Transient)
                        {
                            status.Text = ErrorText(ex);
                            delay = TimeSpan.FromSeconds(Math.Min(Math.Max(start.Num("interval"), ex.RetryAfter), Math.Max(1, (expires - DateTimeOffset.UtcNow).TotalSeconds)));
                        }
                        catch (ProtocolException ex) when (ex.Message == "LOGIN_EXPIRED" || DateTimeOffset.UtcNow >= expires)
                        { status.Text = ErrorText(ex); break; }
                    }
                    if (claimed || closed || generation != authGeneration) box.Hide();
                    choice = await shown;
                }
                catch (OperationCanceledException) { choice = await shown; }
                finally { timer.Stop(); box.Hide(); }
                if (claimed && generation == authGeneration && !closed)
                {
                    await AfterLogin(await Rpc("finishPhone", new { id }));
                    return;
                }
            }
            finally { await Rpc("cancelLogin", new { id }); }
            if (choice != ContentDialogResult.Secondary) return;
        }
    }, true, requiresClock: true);

    private async Task AfterLogin(JsonNode? result)
    {
        var id = result.Str("id");
        try
        {
            if (result.Str("step") is "backup" or "resumeBackup") result = await PrepareBackup(result);
            else if (result.Str("step") == "recover") result = await RecoverLogin(id, result.Bool("conflict"));
        }
        finally
        {
            if (id.Length != 0 && result.Str("step") != "signedIn") await Rpc("cancelLogin", new { id });
        }
        if (result.Str("step") != "signedIn") return;
        member = result?["member"]; canEnroll = result.Bool("canEnroll"); lastDirectory = ""; directoryStale = false;
        foreach (var page in App.Pages) page.ShowWorkspace();
        await SyncForeground();
    }

    private async Task<JsonNode?> RecoverLogin(string id, bool conflict)
    {
        var detail = conflict
            ? T("另一台设备已建立不同的账号根。请选择授权或恢复此账号的身份。", "Another device established this account's identity. Pair with it or use the recovery file for that identity.")
            : T("使用恢复文件恢复身份，或请已有设备扫描授权二维码。", "Recover your identity with your recovery file or scan the authorization QR code with an existing device.");
        while (!closed)
        {
            RequireNetworkClock();
            var options = Dialogs.Box(XamlRoot, T("在此设备上登录", "Sign in on this device"), Text(detail), T("取消", "Cancel"), T("授权新设备", "Pair this device"));
            options.SecondaryButtonText = T("使用恢复文件", "Use recovery file");
            var choice = await options.ShowAsync();
            if (choice == ContentDialogResult.None) break;
            var result = choice == ContentDialogResult.Primary ? await Pair(true, id) : await ReadRecovery("recover", id);
            if (result is not null) return result;
        }
        return null;
    }

    private void ShowWorkspace()
    {
        selectionType = "room"; selected = call.Str("room");
        LogUI("room");
        if (selected == "") selected = directory.List("rooms").FirstOrDefault().Str("room_id");
        lastRoomRender = "";
        LoginGrid.Visibility = Visibility.Collapsed;
        Nav.Visibility = Visibility.Visible;
        LoginNotice.IsOpen = Notice.IsOpen = false;
        BuildNav(); Render(); DrawMessagesHere(); SynchronizeDraft();
        MoveSurface(HeaderContent, y: 8);
        MoveSurface(StageScroll, y: 12);
    }

    private async Task<JsonNode?> PrepareBackup(JsonNode? state)
    {
        RequireNetworkClock();
        using var screen = LogScreen("backup");
        var id = state.Str("id");
        if (state.Str("step") == "resumeBackup")
        {
            state = await ReadRecovery("unlockBackup", id, state.Str("key"));
            if (state is null || state.Str("step") == "signedIn") return state;
        }
        else
        {
            var password = new PasswordBox { Header = T("恢复文件密码（至少 16 个字符）", "Recovery file password (at least 16 characters)") };
            var confirmation = new PasswordBox { Header = T("再次输入恢复文件密码", "Re-enter your recovery file password") };
            var status = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
            var intro = Text(T("设备丢失或更换时，用这份文件和密码恢复你的加密身份。", "Use this file and its password to recover your encrypted identity if you lose or replace a device."));
            var form = Dialogs.Box(XamlRoot, T("创建恢复文件", "Create a recovery file"),
                Stack(intro, Secondary(L("恢复文件保存账号根身份，不包含 Passkey、聊天记录或附件。管理员不能找回文件密码。")), password, confirmation, status),
                T("取消", "Cancel"), T("加密并准备文件", "Encrypt and prepare file"));
            form.PrimaryButtonClick += (_, click) =>
            {
                click.Cancel = password.Password != confirmation.Password || password.Password.EnumerateRunes().Count() < 16 || Encoding.UTF8.GetByteCount(password.Password) > 1024;
                if (click.Cancel)
                {
                    status.Message = password.Password != confirmation.Password
                        ? T("两次输入的密码不同，请重新确认。", "The passwords differ. Enter the same password in both fields.")
                        : ErrorText("INVALID_RECOVERY_PASSWORD");
                    status.IsOpen = true;
                }
            };
            if (await form.ShowAsync() != ContentDialogResult.Primary) return null;
            state = await Rpc("backup", new { id, password = password.Password });
            password.Password = confirmation.Password = "";
        }
        var key = state.Str("key");
        var username = string.Concat(state.Str("username").EnumerateRunes().Select(r => Rune.IsLetterOrDigit(r) || r.Value is '_' or '-' ? r.ToString() : "_"));
        var filename = $"{username}_{DateTime.Now:yyyy-MM-dd}_Windows{RecoveryFileExtension}";
        var saved = state.Bool("exported");
        var verified = false;
        while (!closed)
        {
            var status = Text(verified ? T("已校验恢复文件。", "Recovery file verified.") : saved
                ? T("建议重新选择刚才保存的文件，确认它可以用密码解锁。你也可以直接继续。", "Choose the file you just saved to check that your password unlocks it. You can also continue without checking.")
                : T("加密文件已准备好。选择一个安全的位置保存，之后再校验文件。", "Your encrypted file is ready. Save it somewhere safe, then check the saved copy."));
            var savedFile = Stack(status);
            var box = Dialogs.Box(XamlRoot, T("保存恢复文件", "Save your recovery file"), savedFile, T("取消", "Cancel"),
                saved ? T("继续完成设置", "Continue setup") : T("选择保存位置", "Choose location"));
            if (saved)
            {
                box.SecondaryButtonText = T("校验恢复文件", "Verify a saved file");
                savedFile.Children.Add(ActionButton(T("再次保存同一恢复文件", "Save another copy"), async () =>
                {
                    if (await LogPicker("saveBackup", () => Dialogs.Save(Owner, filename, RecoveryFileExtension)) is { } path)
                    {
                        await File.WriteAllBytesAsync(path, Convert.FromBase64String(state.Str("file")));
                        await Rpc("backupExported", new { id, key, enabled = true });
                        Show(() => L("恢复文件已保存"), InfoBarSeverity.Success);
                    }
                }));
            }
            var choice = await box.ShowAsync();
            if (choice == ContentDialogResult.None) return null;
            if (!saved)
            {
                if (await LogPicker("saveBackup", () => Dialogs.Save(Owner, filename, RecoveryFileExtension)) is not { } path) continue;
                try { await File.WriteAllBytesAsync(path, Convert.FromBase64String(state.Str("file"))); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ShowError(ex); continue; }
                state = await Rpc("backupExported", new { id, key, enabled = true });
                saved = state.Bool("exported");
            }
            else if (choice == ContentDialogResult.Secondary) verified = await ReadRecovery("verifyBackup", id, key) is not null;
            else if (await ConfirmSavedBackup()) return await Rpc("finishBackup", new { id, key });
        }
        return null;
    }

    private async Task<bool> ConfirmSavedBackup()
    {
        var box = Dialogs.Box(XamlRoot, T("确认恢复文件已妥善保存", "Confirm your recovery file is safe"),
            Stack(Text(T("确认文件和密码都已妥善保存，即可完成身份设置。", "Make sure your file and password are safely stored to finish setting up your identity.")),
                new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning,
                    Message = T("恢复加密身份需要文件和密码。文件密码只有你能保管，遗忘后无法找回。", "Recovering your encrypted identity requires both the file and its password. Keep the password safe. It cannot be recovered if you forget it.") }),
            T("返回检查", "Back"), T("完成设置", "Finish setup"));
        var clock = new BackupConfirmationClock();
        void Update()
        {
            var left = clock.Remaining(AudioService.Now);
            box.IsPrimaryButtonEnabled = Owner.IsForeground && left == 0;
            box.PrimaryButtonText = left == 0 ? T("完成设置", "Finish setup") : T($"请等待 {left} 秒", $"Wait {left} s");
        }
        void Activation(object sender, WindowActivatedEventArgs args)
        {
            clock.SetVisible(args.WindowActivationState != WindowActivationState.Deactivated, AudioService.Now);
            Update();
        }
        box.Opened += (_, _) => { clock.SetVisible(Owner.IsForeground, AudioService.Now); Update(); };
        box.PrimaryButtonClick += (_, click) => click.Cancel = !Owner.IsForeground || clock.Remaining(AudioService.Now) > 0;
        box.IsPrimaryButtonEnabled = false;
        Owner.Activated += Activation;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        timer.Tick += (_, _) => Update(); timer.Start();
        try { return await box.ShowAsync() == ContentDialogResult.Primary; }
        finally { timer.Stop(); Owner.Activated -= Activation; }
    }

    private async Task<JsonNode?> ReadRecovery(string operation, string id, string key = "")
    {
        var usesFile = operation != "unlockBackup";
        while (!closed)
        {
            byte[]? file = null;
            if (usesFile)
            {
                if (await LogPicker("selectBackup", () => Dialogs.Open(Owner, RecoveryFileExtension)) is not { } path) return null;
                try { file = await Dialogs.ReadLimited(path, 65606); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ShowError(ex); continue; }
            }
            var message = "";
            while (!closed)
            {
                var password = new PasswordBox { Header = T("恢复文件密码", "Recovery file password") };
                var hint = usesFile
                    ? T("请输入创建此文件时设置的密码。密码只在本机用于解密。", "Enter the password you set when creating this file. It is used only on this device to decrypt the file.")
                    : T("输入上次设置的文件密码，继续保存同一份恢复文件。", "Enter the password you previously set to continue saving the same recovery file.");
                var status = new InfoBar { IsOpen = message.Length > 0, IsClosable = false, Severity = InfoBarSeverity.Error, Message = message };
                var prompt = Dialogs.Box(XamlRoot, T("解锁恢复文件", "Unlock your recovery file"), Stack(Text(hint), password, status), T("返回", "Back"), T("解锁", "Unlock"));
                if (usesFile) prompt.SecondaryButtonText = T("重新选择文件", "Choose another file");
                var action = await prompt.ShowAsync();
                if (action == ContentDialogResult.Secondary) break;
                if (action != ContentDialogResult.Primary) return null;
                try { return await Rpc(operation, new { id, key, file, password = password.Password }); }
                catch (ProtocolException ex) when (ex.Message is not ("LOGIN_EXPIRED" or "PROTOCOL_STOPPED" or "IDENTITY_STORE_UNAVAILABLE")) { message = ErrorText(ex); }
            }
        }
        return null;
    }

    private async Task Run(Func<Task> action, bool loginBusy = false, bool requiresClock = false)
    {
        if (closed || loginBusy && busy) return;
        if (loginBusy)
        {
            busy = true;
            foreach (var page in App.Pages) page.UpdateLoginBusy();
        }
        if (requiresClock) activeAuthFlows++;
        try
        {
            if (requiresClock) RequireNetworkClock();
            await action();
        }
        catch (ClockRequiredException) { if (!closed) RenderClock(networkClock.Read()); }
        catch (Exception ex)
        {
            if (member is null && ex is ProtocolException { Message: "CLIENT_UPDATE_REQUIRED" })
            {
                connection = null;
                foreach (var page in App.Pages) page.UpdateLoginStage();
            }
            if (!closed) ShowError(ex);
        }
        finally
        {
            if (requiresClock) activeAuthFlows--;
            if (loginBusy)
            {
                busy = false;
                foreach (var page in App.Pages)
                {
                    if (!page.closed) page.UpdateLoginBusy();
                    page.ResumePendingCallback();
                }
            }
        }
    }
    private void UpdateLoginBusy()
    {
        Address.IsEnabled = ConnectButton.IsEnabled = Register.IsEnabled = LocalOptions.IsEnabled = !busy;
        var ready = ClockReady;
        Passkey.IsEnabled = Phone.IsEnabled = ApproveSaved.IsEnabled = !busy && ready;
        if (approveDeviceButton is not null) approveDeviceButton.IsEnabled = canEnroll && ready;
        Working.Visibility = Visible(busy);
    }

    private void Show(Func<string> text, InfoBarSeverity severity = InfoBarSeverity.Informational, InfoBar? target = null)
    {
        var noticeOwner = target ?? Dialogs.NoticeFor(XamlRoot) ?? (member is null ? LoginNotice : Notice);
        noticeOwner.Tag = text;
        noticeOwner.Severity = severity;
        noticeOwner.Message = text();
        noticeOwner.IsOpen = true;
    }
    private void RefreshNotice()
    {
        foreach (var owner in new[] { LoginNotice, Notice, Dialogs.NoticeFor(XamlRoot) })
            if (owner is { IsOpen: true, Tag: Func<string> text }) owner.Message = text();
    }
    private void ShowError(Exception error) => Show(() => ErrorText(error), InfoBarSeverity.Error);
    private void ShowError(string code) => Show(() => ErrorText(code), InfoBarSeverity.Error);
    private string ErrorText(Exception error)
    {
        if (error is UnauthorizedAccessException)
            return T("Windows 拒绝了访问请求。请检查应用权限，或选择你有权访问的文件位置。",
                "Windows denied access. Check app permissions or choose a file location you can access.");
        if (error is FileNotFoundException or DirectoryNotFoundException)
            return T("找不到所选文件或文件夹，请重新选择。", "The file or folder could not be found. Choose it again.");
        var message = ErrorText(error.Message);
        if (error is not ProtocolException reply) return message;
        if (reply.MinimumVersion.Length != 0) message += T($" 最低版本 {reply.MinimumVersion}（构建 {reply.MinimumBuild}）。", $" Minimum version {reply.MinimumVersion} (build {reply.MinimumBuild}).");
        if (reply.RetryAfter > 0) message += T($" 请在 {reply.RetryAfter} 秒后重试。", reply.RetryAfter == 1 ? " Try again in 1 second." : $" Try again in {reply.RetryAfter} seconds.");
        return message;
    }
    private string ErrorText(string code) => code switch
    {
        "INVALID_RESPONSE" when member is null && connection is null => T("请检查服务器地址，确认它指向你的 Chirp 服务。", "Check that the server address points to your Chirp service."),
        "INVALID_SERVER_ADDRESS" => T("请输入有效的 Chirp 服务器地址，例如 chirp.example.com。", "Enter a valid Chirp server address, such as chirp.example.com."),
        "SERVER_UNAVAILABLE" => T("无法连接服务器，请检查地址和网络后重试。", "Could not reach the server. Check the address and your connection."),
        "CLIENT_UPDATE_REQUIRED" => T("此服务器要求更新版本的 Chirp。", "This server requires a newer version of Chirp."),
        "SERVER_CONFIGURATION_CHANGED" => T("登录、API 或群组服务地址已更改，请重新确认连接。", "The sign-in, API, or group service address has changed. Confirm the connection again."),
        "PAIRING_CODE_MISMATCH" => T("数字不匹配，请查看新设备后重试。", "The numbers differ. Check the new device and try again."),
        "PAIRING_ATTEMPTS_EXHAUSTED" => T("三次核验均未通过，请在新设备上重新发起配对。", "Three attempts failed. Start a new pairing on the new device."),
        "REVOCATION_PENDING" => T("本机已禁用该设备，联网后将自动同步撤销。", "This device is disabled locally. Revocation will sync when connected."),
        "PEER_IDENTITY_BLOCKED" => T("此账号或设备已被禁用。", "This account or device has been blocked."),
        "INVALID_LOGIN_CALLBACK" or "LOGIN_EXPIRED" => T("登录请求已失效，请重新登录。", "This sign-in request expired. Start again."),
        "INVALID_RECOVERY_PASSWORD" => T("请输入两次相同的密码，至少 16 个字符，最长 1024 个 UTF-8 字节。", "Use the same password twice, with at least 16 characters and at most 1024 UTF-8 bytes."),
        "wrong password or damaged recovery file" => T("无法解锁恢复文件。请核对密码和文件。", "Could not unlock the recovery file. Check the password and file."),
        "RECOVERY_IDENTITY_MISMATCH" => T("请选择属于当前服务器和账号的恢复文件。", "Choose the recovery file for this account and server."),
        "DEVICE_APPROVAL_NOT_ALLOWED" => T("请选择有授权权限的设备身份。", "Choose a device identity with approval permission."),
        "INVALID_PAIRING_IMAGE" => T("无法读取配对码。请重新拍摄，或选择只含一个设备配对二维码的清晰静态图片。", "Could not read the pairing code. Retake the photo or choose a clear still image with a single device pairing QR code."),
        "INVALID_PAIRING_REQUEST" => T("配对请求无效。请在要授权的新设备上重新生成二维码。", "The pairing request is invalid. Generate a new QR code on the device you want to approve."),
        "DEVICE_PAIRING_EXPIRED" => T("配对码已过期。请在新设备上重新生成二维码。如果是刚生成的，请先同步两台设备的时间。", "The pairing code has expired. Generate a new QR code on the new device. If you just generated it, sync the clocks on both devices first."),
        "PAIRING_CLOCK_MISMATCH" => T("按本机时间，此配对码尚未生效。请同步两台设备的时间，再在新设备上重新生成二维码。", "This pairing code is not yet valid according to this PC’s clock. Sync the clocks on both devices, then generate a new QR code on the new device."),
        "PAIRING_SERVER_MISMATCH" => T("两台设备连接的服务器不同。请在 Windows 上连接新设备使用的服务器。", "The devices are connected to different servers. Connect this PC to the server used by the new device."),
        "PAIRING_ACCOUNT_MISMATCH" => T("两台设备的账号身份不同。请在 Windows 上选择新设备正在登录的账号。", "The account identities differ. On this PC, select the account the new device is signing in to."),
        "USER_VERIFICATION_FAILED" => T("未能完成 Windows 用户验证。请重试。", "Windows user verification was unsuccessful. Try again."),
        "AEC_UNAVAILABLE" or "RNNOISE_UNAVAILABLE" or "AUDIO_PROCESSING_FAILED" => T("无法启动语音处理。请在语音设置中检查设备和处理模式。", "Audio processing is unavailable. Check the devices and processing mode in Audio settings."),
        "AUDIO_DECODE_FAILED" => T("无法解码收到的语音。请重新加入房间。", "Could not decode incoming audio. Please rejoin the room."),
        "MEDIA_DISCONNECTED" or "MEDIA_CONNECTION_FAILED" => T("无法连接语音服务器，请检查网络后重新入房。", "Could not connect to the voice server. Check your connection and rejoin the room."),
        "AUTHORIZATION_KEY_MISSING" => T("安装包的授权公钥缺失或无效。请重新安装包含此服务授权公钥的 Chirp 客户端。", "The app's authorization public key is missing or invalid. Reinstall Chirp with the public key for this service."),
        "LOG_STORAGE_UNAVAILABLE" => T("无法访问本机日志。请检查可用磁盘空间后重试。", "Could not access local logs. Check the available disk space and try again."),
        "PROTOCOL_STOPPED" or "PROTOCOL_START_FAILED" => T("无法打开本机身份服务。请关闭并重新打开 Chirp。", "The local identity service is unavailable. Close and reopen Chirp."),
        "IDENTITY_STORE_UNAVAILABLE" => T("无法读取本机身份库。可以清空本地数据后，通过恢复文件或其他授权设备重新登录。", "The local identity store could not be read. Clear local data and sign in using a recovery file or another authorized device."),
        "CHAT_BUSY" or "TRANSFER_BUSY" => T("请等待当前传输完成后重试。", "Wait for the current transfer, then try again."),
        "CONTENT_PAUSED" => T("内容已暂停，正在等待安全连接。", "Content is paused while the secure connection is established."),
        "ATTACHMENT_PREPARATION_FAILED" => T("文件准备失败，请重新选择原文件。", "File preparation failed. Select the original file again."),
        "ATTACHMENT_PAUSED" => T("传输已暂停", "Transfer paused"),
        "ATTACHMENT_PUBLICATION_UNKNOWN" => T("正在确认取消此附件。", "Confirming cancellation of this attachment."),
        "ATTACHMENT_NO_RECIPIENTS" => T("房间里需要至少一位其他成员才能发送附件。", "Another participant must be in the room to receive the attachment."),
        "AUDIO_DEVICE_UNAVAILABLE" => T("音频设备已断开或无法使用。请在声音设置中选择其他设备。", "The audio device is unavailable. Choose another device in Audio settings."),
        "AUDIO_TEST_BUSY" => T("正在通话或测试麦克风。结束后可重新测试。", "End the current call or microphone test before starting a new test."),
        "BROWSER_UNAVAILABLE" => T("无法打开默认浏览器。请在 Windows 设置中选择默认浏览器后重试。", "Choose a default browser in Windows Settings and try again."),
        "CAMERA_UNAVAILABLE" => T("无法打开摄像头。请检查摄像头连接和权限，或导入配对二维码图片。", "Check the camera connection and permissions, or import an image of the pairing QR code."),
        "FILE_TOO_LARGE" => T("所选文件过大，请重新选择符合大小限制的文件。", "This file is too large. Choose a file within the size limit."),
        "DEVICE_REVOKED" => T("此设备的授权已撤销，请使用其他已授权设备登录。", "This device’s authorization was revoked. Sign in on another authorized device."),
        "IDENTITY_KEY_CHANGED" => T("成员的身份密钥已变化。请通过可信渠道确认对方身份并重新核验。", "A participant’s identity key changed. Contact them through a trusted channel and verify their device again."),
        "INVALID_MESSAGE" => SharedCopy.Error("CLIENT_CHAT_PREPARATION_FAILED", english),
        "JOIN_CANCELLED" => T("已取消加入房间。", "Joining the room was cancelled."),
        "LOGIN_REQUIRED" => T("请重新登录以继续。", "Sign in again to continue."),
        "NATIVE_MEDIA_BUILD_REQUIRED" => T("安装包缺少语音组件，请重新安装完整的 Windows 客户端。", "Reinstall the full Windows client to restore the missing voice components."),
        "RECOVERY_EXPORT_PENDING" => T("请先保存恢复文件并确认已妥善保管，再继续登录。", "Save your recovery file and confirm you have stored it safely to finish signing in."),
        "REGISTRATION_CLOSED" => T("此服务暂未开放注册，请联系管理员。", "Registration is closed on this server. Contact the administrator."),
        "ROOM_PASSWORD_TOO_LONG" => T("房间密码不能超过 512 字节。", "The room password must be at most 512 bytes."),
        "SOCIAL_SYNC_PENDING" => T("好友与设备信任记录仍在同步，请保持联网后重试。", "Friend and device trust records are syncing. Stay online and try again."),
        "UNKNOWN_COMMAND" => T("此版本无法执行该操作，请更新 Chirp 后重试。", "This version cannot complete that action. Update Chirp and try again."),
        "CEREMONY_EXPIRED" => T("本次通行密钥请求已过期，请重新开始。", "This passkey request expired. Start again."),
        "PASSKEY_INVALID" => T("通行密钥验证未完成，请重新选择此账号的通行密钥。", "Passkey verification did not complete. Choose the passkey for this account and try again."),
        "ORIGIN_NOT_ALLOWED" => T("此服务未允许当前登录地址。请确认服务器地址或联系管理员。", "This sign-in address is not allowed. Check the server address or contact the administrator."),
        "REGISTRATION_EXISTS" => T("这个昵称已有注册申请，请联系管理员查看进度。", "A registration request already exists for that name. Contact the administrator to check its status."),
        "INVALID_NICKNAME" => T("注册昵称需要使用 3 至 15 个英文字母。", "Use 3 to 15 English letters for the registration name."),
        "NOT_FOUND" => T("请求的项目已不存在，请刷新后重试。", "The requested item is no longer available. Refresh and try again."),
        "JSON_REQUIRED" => SharedCopy.Error("CLIENT_HTTP_FAILURE", english),
        "GROUP_BUDGET" => T("房间请求过于频繁，请稍候再试。", "Too many room requests. Wait a moment and try again."),
        "GROUP_CHANGED" or "GROUP_CONFLICT" or "REPLAYED_REQUEST" => T("房间状态已更新，请等待同步后重试。", "The room state changed. Wait for it to sync and try again."),
        "V5_IDENTITY_UNAVAILABLE" => T("身份授权服务暂时不可用，请稍后重试。", "The identity authorization service is unavailable. Try again shortly."),
        "MLS unavailable" or "MLS initialization failed" or "MLS key expired" => SharedCopy.Error("CLIENT_SECURE_CONNECTION_RECOVERY_FAILED", english),
        "context canceled" => T("操作已取消。", "The operation was cancelled."),
        "context deadline exceeded" => SharedCopy.Error("CLIENT_NETWORK_TIMEOUT", english),
        _ => SharedCopy.Error(code, english)
    };
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    internal void Detach()
    {
        if (closed) return;
        closed = true;
        motionSettings.AnimationsEnabledChanged -= MotionPreferenceChanged;
        StopMotions();
        refresh.Stop();
        Dialogs.Dismiss(XamlRoot);
    }
    internal void Shutdown() { clockTimer?.Stop(); UnwatchAudioRoutes(); StopCues(); audio.Dispose(); }
}
