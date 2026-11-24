using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Windows.Security.Credentials.UI;

namespace Chirp;

public sealed partial class MainPage
{
    private InfoBar? profileSyncNotice;
    private async Task<bool> Confirm(string title, string body, string action) =>
        await Dialogs.Box(XamlRoot, title, Text(body), T("取消", "Cancel"), action).ShowAsync() == ContentDialogResult.Primary;
    private async Task<string?> Prompt(string title, string label, string value = "")
    {
        var input = new TextBox { Header = label, Text = value, MaxLength = 4096 };
        var box = Dialogs.Box(XamlRoot, title, input, T("取消", "Cancel"), T("保存", "Save"));
        void Validate() => box.IsPrimaryButtonEnabled = input.Text.Trim() != value && DesktopText.ValidName(input.Text.Trim());
        input.TextChanged += (_, _) => Validate(); Validate();
        return await box.ShowAsync() == ContentDialogResult.Primary ? input.Text.Trim() : null;
    }
    private Button SettingsRow(string title, string detail, string glyph, Func<Task> action)
    {
        var copy = Stack(Text(title, 15, "ChirpHeading"), Secondary(detail));
        copy.Spacing = 2;
        var button = ActionButton(title, action);
        button.Style = Design("ChirpSurfaceButton");
        button.Content = Line(copy, IconTile(glyph), Glyph("\uE76C", 12));
        AutomationProperties.SetName(button, title);
        AutomationProperties.SetHelpText(button, detail);
        return button;
    }

    private static StackPanel SettingsGroup(string title, params UIElement[] rows)
    {
        var group = new StackPanel { Spacing = 8 };
        group.Children.Add(Heading(title, 17));
        foreach (var row in rows) group.Children.Add(row);
        return group;
    }

    private static Border SettingsPicker(string label, string glyph, ComboBox picker)
    {
        AutomationProperties.SetName(picker, label);
        picker.MinWidth = 130;
        picker.VerticalAlignment = VerticalAlignment.Center;
        return new Border
        {
            Style = Design("ChirpCard"), Padding = new Thickness(12),
            Child = Line(Text(label, 15, "ChirpHeading"), IconTile(glyph), picker)
        };
    }

    private ComboBox? themeChoice;

    private void RenderSettings()
    {
        var id = member.Str("id");
        var name = DisplayName(id, member.Str("display_name"));
        var identityName = Text(name, 21, "ChirpHeading");
        identityName.SetBinding(TextBlock.TextProperty, new Binding { Source = SidebarName, Path = new PropertyPath(nameof(TextBlock.Text)) });
        identityName.MaxLines = 2;
        identityName.TextTrimming = TextTrimming.CharacterEllipsis;
        var identity = Stack(identityName, Secondary(connection.Str("origin")));
        identity.Spacing = 3;
        var profile = ActionButton(T("编辑资料", "Edit profile"), Profile, glyph: "\uE70F");
        Stage.Children.Add(new Border { Style = Design("ChirpCard"), Child = Line(identity, ProfilePicture(id, 48, name), profile) });

        var theme = themeChoice = Choice("", [T("跟随系统", "System"), T("浅色", "Light"), T("深色", "Dark")], GetInt("theme", 0));
        theme.SelectionChanged += (_, _) =>
        {
            if (theme.SelectedIndex < 0 || theme.SelectedIndex == GetInt("theme", 0)) return;
            Set("theme", theme.SelectedIndex);
            foreach (var page in App.Pages) page.ApplyTheme();
        };
        var lang = Choice("", ["系统 / System", "简体中文", "English"], LanguageChoice.SelectedIndex);
        lang.SelectionChanged += (_, _) => LanguageChoice.SelectedIndex = lang.SelectedIndex;
        var preferences = Stack(
            SettingsGroup(T("常规", "General"),
                SettingsRow(T("声音设置", "Audio settings"), T("麦克风、扬声器与语音激活", "Microphone, speakers and voice activation"), "\uE9E9", AudioSettings),
                SettingsPicker(T("外观", "Appearance"), "\uE771", theme),
                SettingsPicker(T("界面语言", "Display language"), "\uE775", lang)),
            SettingsGroup(T("存储", "Storage"),
                SettingsRow(T("日志管理", "Log management"), T("记录、导出和清除脱敏日志", "Record, export and clear redacted logs"), "\uE7C3", LogSettings),
                SettingsRow(T("附件缓存", "Attachment cache"), T("查看占用空间与清理缓存", "View disk usage and clear cached files"), "\uE8B7", CacheSettings)));
        preferences.Spacing = 20;

        approveDeviceButton = SettingsRow(T("授权新设备", "Approve a new device"), canEnroll
            ? T("与另一台设备核对安全码", "Compare a security code with the other device")
            : T("请在拥有授权权限的设备上操作", "Use a device with approval permission"), "\uE8D7", () => Run(async () =>
        {
            if ((await Pair(false)).Str("step") == "complete") Show(() => T("新设备已获授权", "New device approved"), InfoBarSeverity.Success);
        }, requiresClock: true));
        approveDeviceButton.IsEnabled = canEnroll && ClockReady;
        var account = SettingsGroup(T("账号与安全", "Account and security"),
            SettingsRow(T("管理设备", "Manage devices"), T("查看、重命名和撤销已授权设备", "View, rename and revoke authorized devices"), "\uE772", Devices),
            approveDeviceButton,
            SettingsRow(T("黑名单", "Blacklist"), T("查看已禁用的账号和设备", "Review blocked accounts and devices"), "\uE8F8", Blacklist));

        var local = SettingsGroup(T("本机身份与数据", "Local identity and data"),
            SettingsRow(T("退出登录", "Sign out"), T("结束这台电脑上的登录和通话", "End your session and call on this PC"), "\uF3B1", async () =>
            {
                if (!await Confirm(T("退出登录", "Sign out"), T("结束本次登录和通话。", "End this sign-in and leave your call."), T("退出", "Sign out"))) return;
                var logout = Rpc("logout");
                SignedOut();
                await logout;
            }),
            SettingsRow(T("清空本地数据", "Clear local data"), T("移除此电脑上的身份、缓存和偏好设置", "Remove identities, cache and preferences from this PC"), "\uE74D", ClearLocalData));
        var identitySettings = Stack(account, local);
        identitySettings.Spacing = 20;
        var sections = new Grid { RowSpacing = 20 };
        sections.ColumnDefinitions.Add(new ColumnDefinition());
        var secondColumn = new ColumnDefinition { Width = new GridLength(0) };
        sections.ColumnDefinitions.Add(secondColumn);
        sections.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        sections.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(identitySettings, 1);
        sections.Children.Add(preferences);
        sections.Children.Add(identitySettings);
        sections.SizeChanged += (_, args) =>
        {
            var wide = args.NewSize.Width >= 720;
            secondColumn.Width = wide ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
            sections.ColumnSpacing = wide ? 20 : 0;
            sections.RowSpacing = wide ? 0 : 20;
            Grid.SetRow(identitySettings, wide ? 0 : 1);
            Grid.SetColumn(identitySettings, wide ? 1 : 0);
        };
        Stage.Children.Add(sections);
#if CHIRP_UNPACKAGED
        var version = typeof(App).Assembly.GetName().Version!;
#else
        var version = Windows.ApplicationModel.Package.Current.Id.Version;
#endif
        Stage.Children.Add(Secondary($"Chirp  ·  {version.Major}.{version.Minor}.{version.Build} ({version.Revision})", 12));
    }

    private static ComboBox Choice(string label, string[] choices, int index) => new()
    {
        Header = label.Length > 0 ? label : null,
        ItemsSource = choices,
        SelectedIndex = Math.Clamp(index, 0, Math.Max(0, choices.Length - 1)),
        HorizontalAlignment = HorizontalAlignment.Stretch
    };
    private async Task Profile()
    {
        using var screen = LogScreen("profile");
        var login = member;
        if (login is null) return;
        var profile = profiles.Profile(login.Str("id"));
        if (profile is null && !directoryStale)
        {
            try { ApplyOwnProfile(login, await Rpc("profile")); }
            catch (ProtocolException ex) when (ex.Transient) { MarkDirectoryStale(); }
            if (!ReferenceEquals(login, member)) return;
            profile = profiles.Profile(login.Str("id"));
        }
        var original = (profile ?? login).Str("display_name");
        var name = new TextBox { Header = T("昵称", "Display name"), Text = original };
        var panel = Stack(ProfilePicture(login.Str("id"), 80, original), name);
        var syncNotice = new InfoBar
        {
            IsOpen = directoryStale, IsClosable = false, Severity = InfoBarSeverity.Warning,
            Message = T("成员资料暂时无法同步，当前显示上次资料。", "Member profiles are temporarily unavailable. Showing the last saved profile.")
        };
        profileSyncNotice = syncNotice;
        panel.Children.Add(Secondary(T("支持中文、字母和表情，最多 80 个字符。", "Your display name can contain up to 80 characters, including emoji.")));
        panel.Children.Add(syncNotice);
        var box = Dialogs.Box(XamlRoot, T("编辑资料", "Edit profile"), panel, T("关闭", "Close"), T("保存昵称", "Save name"));
        void ValidateName()
        {
            var limited = DesktopText.LimitName(name.Text);
            if (limited.Length != name.Text.Length) { name.Text = limited; name.SelectionStart = limited.Length; }
            var trimmed = limited.Trim();
            box.IsPrimaryButtonEnabled = trimmed != original && DesktopText.ValidName(trimmed);
        }
        name.TextChanged += (_, _) => ValidateName(); ValidateName();
        box.SecondaryButtonText = T("更改头像", "Change avatar");
        ContentDialogResult choice;
        try { choice = await box.ShowAsync(); }
        finally { profileSyncNotice = null; }
        if (!ReferenceEquals(login, member)) return;
        if (choice == ContentDialogResult.Primary)
        {
            ApplyOwnProfile(login, await Rpc("rename", new { name = name.Text.Trim() }));
            if (ReferenceEquals(login, member)) Show(() => L("昵称已更新"), InfoBarSeverity.Success);
        }
        if (choice == ContentDialogResult.Secondary)
        {
            var image = Dialogs.Box(XamlRoot, T("头像", "Avatar"),
                Text(T("选择小于 5 MB 的 JPEG、PNG 或 HEIF 图片。头像会居中裁剪，请确认预览后保存。",
                    "Choose a JPEG, PNG or HEIF image under 5 MB. Review the centered crop before saving.")), T("取消", "Cancel"), T("选择图片", "Choose image"));
            if (profile.Str("avatar_revision") != "") image.SecondaryButtonText = T("移除头像", "Remove avatar");
            var action = await image.ShowAsync();
            if (!ReferenceEquals(login, member)) return;
            if (action == ContentDialogResult.Primary && await LogPicker("selectAvatar", () => Dialogs.Open(Owner, ".png", ".jpg", ".jpeg", ".heic", ".heif")) is { } path)
            {
                var bytes = await AvatarImage.Prepare(path);
                var preview = await Dialogs.Image(bytes, 192);
                if (ReferenceEquals(login, member) && await Dialogs.Box(XamlRoot, T("头像预览", "Avatar preview"), preview, T("取消", "Cancel"), T("保存头像", "Save avatar")).ShowAsync() == ContentDialogResult.Primary && ReferenceEquals(login, member))
                {
                    ApplyOwnProfile(login, await Rpc("avatar", new { file = bytes }));
                    if (ReferenceEquals(login, member)) Show(() => L("头像已更新"), InfoBarSeverity.Success);
                }
            }
            else if (action == ContentDialogResult.Secondary)
            {
                ApplyOwnProfile(login, await Rpc("removeAvatar"));
                if (ReferenceEquals(login, member)) Show(() => L("头像已移除"), InfoBarSeverity.Success);
            }
        }
        await Refresh(); if (selectionType == "settings") Render();
    }
    private async Task RefreshFriendNames()
    {
        var login = member;
        var list = await Rpc("friends") as JsonArray;
        if (login is null || !ReferenceEquals(login, member)) return;
        friends = list ?? new();
        RedrawRooms();
    }
    private async Task RenderFriends(int generation)
    {
        var query = new AutoSuggestBox
        {
            Header = T("搜索好友", "Search friends"),
            PlaceholderText = T("姓名或账号", "Name or account"),
            QueryIcon = new SymbolIcon(Symbol.Find)
        };
        var list = Stack();
        JsonArray bans = new();
        void Filter()
        {
            list.Children.Clear();
            var value = query.Text.Trim();
            foreach (var f in friends.OrderBy(f => f.Str("name"), StringComparer.CurrentCultureIgnoreCase))
            {
                var id = f.Str("id"); var root = f.Str("root"); var name = f.Str("name");
                if (!name.Contains(value, StringComparison.CurrentCultureIgnoreCase) && !id.Contains(value, StringComparison.OrdinalIgnoreCase)) continue;
                var details = Stack(Secondary(T("账号", "Account")), CopyText(id), Secondary(T("账号指纹", "Account fingerprint")), CopyText(DesktopText.Fingerprint(root)));
                var accountBlocked = bans.Any(b => b.Str("kind") == "account" && (b.Str("subject") == id || b.Str("account_key") == root));
                if (accountBlocked) details.Children.Add(Text(T("账号已被管理员禁用", "Account blocked by administrator")));
                foreach (var key in f.List("devices"))
                {
                    var leaf = key!.ToString(); details.Children.Add(Secondary(T("设备指纹", "Device fingerprint"))); details.Children.Add(CopyText(DesktopText.Fingerprint(leaf)));
                    if (accountBlocked || bans.Any(b => b.Str("kind") == "device" && b.Str("subject") == leaf))
                        details.Children.Add(Text(T("设备已被禁用", "Device blocked")));
                    details.Children.Add(ActionButton(T("取消设备信任", "Remove device trust"), async () =>
                    {
                        if (await Confirm(name, T("下次通话需要重新验证此设备。", "You will need to verify this device again."), T("取消信任", "Remove trust"))) { await Rpc("untrust", new { id, root, key = leaf }); await RefreshFriendNames(); Filter(); }
                    }));
                }
                details.Children.Add(ActionButton(T("移除好友", "Remove friend"), async () =>
                {
                    if (await Confirm(name, T("从好友列表中移除，并取消对其设备的信任。", "Remove this friend and their trusted devices."), T("移除", "Remove"))) { await Rpc("removeFriend", new { id, root }); await RefreshFriendNames(); Filter(); }
                }));
                var devices = f.List("devices").Count;
                var summary = accountBlocked ? T("账号已被管理员禁用", "Account blocked by administrator") : devices == 0 ? L("尚未核验设备") :
                    T($"{devices} 台受信任设备", devices == 1 ? "1 trusted device" : $"{devices} trusted devices");
                var identity = Stack(Text(name, 16, "ChirpHeading"), Secondary(summary));
                identity.Spacing = 2;
                var friend = new Expander
                {
                    Header = Line(identity, ProfilePicture(id, 40, name)), Content = details,
                    HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch
                };
                AutomationProperties.SetName(friend, name + " · " + summary);
                friend.Expanding += (_, _) => LogUI("friendInfo");
                friend.Collapsed += (_, _) => LogUI("friendInfo", enabled: false);
                list.Children.Add(friend);
            }
            if (list.Children.Count == 0)
                list.Children.Add(EmptyState(value.Length == 0 ? T("还没有好友", "No friends yet") : T("未找到匹配的好友", "No matching friends"),
                    value.Length == 0 ? L("进入房间，点击成员头像即可添加好友。也可以核对安全码，信任对方的设备。") :
                    T("试试其他姓名或账号。", "Try a different name or account."), IconTile("\uE716")));
        }
        async Task Reload()
        {
            await RefreshFriendNames();
            if (pageGeneration != generation) return;
            bans = await Rpc("cachedBlacklist") as JsonArray ?? new();
            if (pageGeneration == generation) Filter();
        }
        query.TextChanged += (_, _) => Filter();
        var refresh = ActionButton(T("刷新好友", "Refresh friends"), Reload);
        refresh.Style = Design("ChirpToolbarButton");
        refresh.Content = Glyph("\uE72C");
        refresh.Width = 40;
        refresh.VerticalAlignment = VerticalAlignment.Bottom;
        Label(refresh, T("刷新好友", "Refresh friends"));
        Stage.Children.Add(Line(query, trailing: refresh));
        Stage.Children.Add(list);
        if (friends.Count > 0) Filter();
        else list.Children.Add(Line(Secondary(T("正在获取好友…", "Loading friends…")),
            new ProgressRing { IsActive = true, Width = 20, Height = 20 }));
        try { await Reload(); }
        catch
        {
            if (pageGeneration == generation && friends.Count == 0)
            {
                list.Children.Clear();
                list.Children.Add(EmptyState(T("暂时无法加载好友", "Friends couldn’t be loaded"),
                    T("请检查网络后刷新好友列表。", "Check your connection, then refresh your friends list."), IconTile("\uE716")));
            }
            throw;
        }
    }
    private static TextBlock CopyText(string s) { var t = Text(s, 13); t.IsTextSelectionEnabled = true; return t; }
    private async Task Devices()
    {
        using var screen = LogScreen("devices");
        while (true)
        {
            var state = await Rpc("devices");
            string? selectedKey = null; string selectedName = ""; var revoke = false;
            var rows = Stack(Secondary(T("账号指纹", "Account fingerprint")), CopyText(DesktopText.Fingerprint(state.Str("root"))));
            var box = Dialogs.Box(XamlRoot, T("管理设备", "Manage devices"), new ScrollViewer { Content = rows, MaxHeight = 440 }, T("完成", "Done"));
            if (state.List("devices").Count == 0)
                rows.Children.Add(EmptyState(L("暂无设备"), L("已登记的个人设备将在这里显示。"), IconTile("\uE772")));
            foreach (var d in state.List("devices"))
            {
                var key = d.Str("device_key"); var current = key == state.Str("current"); var revoked = d.Bool("revoked");
                var device = Stack(Line(Text(d.Str("name") + (current ? T("（本设备）", " (this device)") : ""), 17, "ChirpHeading"), IconTile("\uE772")));
                if (key == state.Str("pendingRevocation")) device.Children.Add(Text(T("本机已禁用，等待签名授权服务确认撤销。", "Disabled locally. Awaiting signed revocation.")));
                var platform = d.Str("platform") switch
                {
                    "ios" => "iOS", "macos" => "macOS", "windows" => "Windows", "android" => "Android",
                    "" => T("设备平台未知", "Unknown platform"), var name => name
                };
                device.Children.Add(Secondary(platform + (revoked ? T(" · 已撤销", " · Revoked") : "")));
                device.Children.Add(CopyText(DesktopText.Fingerprint(key)));
                string Date(string field) => d.Num(field) is > 0 and <= 253402300799 ? DateTimeOffset.FromUnixTimeSeconds(d.Num(field)).ToLocalTime().ToString("g", DisplayCulture) : "—";
                device.Children.Add(Text(T("首次登记", "Registered") + "   " + Date("created_at")));
                device.Children.Add(Text(T("最后上线", "Last seen") + "   " + Date("last_login_at")));
                var buttons = Row(ActionButton(T("重命名", "Rename"), () => { selectedKey = key; selectedName = d.Str("name"); box.Hide(); return Task.CompletedTask; }));
                if (!current && !revoked && state.Bool("canEnroll")) buttons.Children.Add(ActionButton(T("撤销设备", "Revoke device"), () => { selectedKey = key; selectedName = d.Str("name"); revoke = true; box.Hide(); return Task.CompletedTask; }));
                device.Children.Add(buttons);
                rows.Children.Add(Card(device));
            }
            await box.ShowAsync(); if (selectedKey is null) return;
            if (revoke)
            {
                if (await Confirm(T($"撤销「{selectedName}」？", $"Revoke “{selectedName}”?"),
                    T("此设备的授权将被永久撤销。请核对设备指纹后确认。", "This device will permanently lose its authorization. Check its fingerprint before confirming.") +
                    "\n\n" + DesktopText.Fingerprint(selectedKey), T("撤销设备", "Revoke device"))) await Rpc("revoke", new { key = selectedKey });
            }
            else if (await Prompt(T("重命名设备", "Rename device"), T("设备名称", "Device name"), selectedName) is { } name) await Rpc("renameDevice", new { key = selectedKey, name });
        }
    }
    private async Task Blacklist()
    {
        using var screen = LogScreen("blacklist");
        var list = await Rpc("blacklist") as JsonArray; var panel = Stack();
        if (list is null || list.Count == 0) panel.Children.Add(EmptyState(T("黑名单为空", "The blacklist is empty"),
            T("这里会列出已禁用的账号与设备。", "Blocked accounts and devices will appear here."), IconTile("\uE8F8")));
        else foreach (var group in list.GroupBy(b => (Id: b.Str("account_id"), Root: b.Str("account_key"))).OrderByDescending(g => g.Max(b => b.Num("sequence"))))
        {
            var entries = group.OrderBy(b => b.Num("sequence")).ToList();
            var name = entries.LastOrDefault(b => b.Str("username").Length > 0).Str("username");
            var account = Stack(Text(name.Length > 0 ? name : group.Key.Id, 17, "ChirpHeading"));
            account.Children.Add(CopyText(group.Key.Id));
            account.Children.Add(CopyText(T("账号指纹", "Account fingerprint") + "  " + DesktopText.Fingerprint(group.Key.Root)));
            if (entries.Any(b => b.Str("kind") == "account")) account.Children.Add(Text(T("账号已禁用", "Account blocked")));
            foreach (var b in entries.Where(b => b.Str("kind") == "device"))
            {
                account.Children.Add(CopyText(T("禁用的设备", "Blocked device") + "  " + DesktopText.Fingerprint(b.Str("subject"))));
                if (b.Num("created_at") is > 0 and <= 253402300799)
                    account.Children.Add(Text(DateTimeOffset.FromUnixTimeSeconds(b.Num("created_at")).ToLocalTime().ToString("g", DisplayCulture)));
            }
            panel.Children.Add(Card(account));
        }
        await Dialogs.Box(XamlRoot, T("黑名单", "Blacklist"), new ScrollViewer { Content = panel, MaxHeight = 400 }, T("关闭", "Close")).ShowAsync();
    }
    private async Task<JsonNode?> Pair(bool newDevice, string? accountID = null)
    {
        RequireNetworkClock();
        using var screen = LogScreen("devicePairing");
        var title = T("授权新设备", "Pair a new device");
        var entry = newDevice ? null : await PairingCode();
        if (!newDevice && string.IsNullOrWhiteSpace(entry?.Code)) return null;
        var state = await Rpc(newDevice ? "pairNew" : "pairOld", new { code = entry?.Code, id = accountID, action = newDevice ? "deferLogin" : entry?.Imported == true ? "import" : "camera" });
        var id = state.Str("id");
        var feedback = "";
        var allowEnrollment = true;
        try
        {
            while (state.Str("step") == "pair")
            {
                RequireNetworkClock();
                var waiting = state.Bool("confirmed") || !state.Bool("ready");
                if (waiting)
                {
                    var waitingText = state.Bool("confirmed")
                        ? newDevice ? T("已确认，等待原设备批准。", "Confirmed. Waiting for approval on your other device.") : L("已确认，等待新设备确认安全码。")
                        : newDevice ? L("等待旧设备扫描或导入二维码…") : L("正在生成安全码");
                    var status = Text(waitingText);
                    var expiry = state.Num("expires");
                    var lifetime = Secondary("");
                    void UpdateExpiry()
                    {
                        if (expiry <= 0) return;
                        var seconds = Math.Max(0, expiry - DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                        lifetime.Text = seconds > 0 ? T($"本次请求还剩 {seconds} 秒", $"Request expires in {seconds} s") : L("本次授权已停止，请重新生成二维码。");
                    }
                    UpdateExpiry();
                    var panel = Stack(status);
                    if (expiry > 0) panel.Children.Add(lifetime);
                    if (newDevice && !state.Bool("confirmed"))
                    {
                        var value = state.Str("code");
                        panel.Children.Add(Text(L("在其他已授权设备的设置中选择授权新设备。扫描二维码后，请保持两台设备的授权页面打开。")));
                        var qr = await Dialogs.Qr(value);
                        AutomationProperties.SetName(qr, T("设备授权二维码", "Device authorization QR code"));
                        panel.Children.Add(qr);
                        panel.Children.Add(new TextBox { Header = T("设备授权请求", "Device authorization request"), Text = value, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 64 });
                        panel.Children.Add(ActionButton(L("保存二维码为 PNG"), async () =>
                        {
                            if (await LogPicker("savePairingImage", () => Dialogs.Save(Owner, "Chirp-device-pairing.png", ".png")) is not { } path) return;
                            await File.WriteAllBytesAsync(path, Dialogs.QrBytes(value));
                            Show(() => T("配对二维码已保存。", "Pairing QR code saved."), InfoBarSeverity.Success);
                        }));
                    }
                    var box = Dialogs.Box(XamlRoot, title, new ScrollViewer { Content = panel, MaxHeight = 440 }, T("取消", "Cancel"));
                    var dismissed = false;
                    box.Closing += (_, _) => dismissed = true;
                    var shown = box.ShowAsync().AsTask();
                    try
                    {
                        while (!shown.IsCompleted)
                        {
                            await Task.WhenAny(shown, Task.Delay(900)); if (shown.IsCompleted) return null;
                            UpdateExpiry();
                            try { state = await Rpc("pairPoll", new { id }); status.Text = waitingText; }
                            catch (ProtocolException ex) when (ex.Transient)
                            {
                                status.Text = T("暂时无法连接授权服务，正在重试…", "The approval service is unavailable. Retrying…");
                                continue;
                            }
                            if (dismissed || closed) return null;
                            if (state.Str("step") != "pair" || !state.Bool("confirmed") && state.Bool("ready")) break;
                        }
                    }
                    finally { box.Hide(); await shown; }
                    continue;
                }
                var allow = new CheckBox { IsChecked = allowEnrollment, Content = L("允许新设备继续授权其他设备") };
                var hint = entry?.Imported == true ? T("请依次输入新设备授权页面上的三组安全码，每组 4 位。二维码图片不能代替这一步核验。", "Enter the three 4-digit groups in the order shown on the new device’s approval screen. The QR image alone cannot verify this step.")
                    : L("请直接核对旧设备显示的三组安全码。两台设备上的码完全一致后，再确认。不要通过尚未验证的通话核对。");
                if (!newDevice && entry?.Imported != true) hint = L("请核对新设备上的三组安全码，必须完全一致。");
                var body = Stack(Text(hint));
                var compare = Dialogs.Box(XamlRoot, title, body, T("取消", "Cancel"), newDevice ? L("三组数字全部一致") : L("核对安全码并批准设备"));
                TextBox[] codeGroups = [];
                if (entry?.Imported == true) codeGroups = AddPairingCodeFields(body, compare);
                else body.Children.Add(SecurityCode(state, "digits"));
                if (!newDevice)
                {
                    body.Children.Add(Secondary(L("请确认这是您本人新设备上生成的请求，且双方安全码完全一致。批准后该设备将获得账号授权；新设备成功登录后，账号原有在线会话将自动退出。")));
                    body.Children.Add(allow);
                }
                if (feedback.Length > 0)
                    body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = feedback });
                if (await compare.ShowAsync() != ContentDialogResult.Primary) return null;
                allowEnrollment = allow.IsChecked == true;
                if (!newDevice)
                {
                    var code = string.Concat(codeGroups.Select(group => group.Text));
                    try { await Rpc("pairCheckCode", new { id, code }); }
                    catch (ProtocolException ex) when (ex.Message == "PAIRING_CODE_MISMATCH") { feedback = ErrorText(ex.Message); continue; }
                    var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(WinRT.Interop.WindowNative.GetWindowHandle(Owner), title);
                    if (result != UserConsentVerificationResult.Verified) { feedback = ErrorText("USER_VERIFICATION_FAILED"); continue; }
                }
                try { state = await Rpc("pairConfirm", new { id, enabled = allowEnrollment }); }
                catch (ProtocolException ex) when (ex.Transient) { if (state is JsonObject active) active["confirmed"] = true; }
            }
            if (state.Str("step") == "paired" && !closed) state = await Rpc("finishPair", new { id });
            return state;
        }
        finally { if (state.Str("step") is "pair" or "paired") await Rpc("pairCancel", new { id }); }
    }
    private static Slider VolumeSlider(string name, double value, Action<double> update, int min = 0, int max = 200)
    {
        var slider = new Slider { Header = name, Minimum = min, Maximum = max, Value = value, StepFrequency = 1, MinWidth = 150 };
        slider.ValueChanged += (_, args) => update(args.NewValue); return slider;
    }
    private static ToggleSwitch AudioSwitch(string label, bool enabled)
    {
        var toggle = new ToggleSwitch { IsOn = enabled, OnContent = label, OffContent = label };
        AutomationProperties.SetName(toggle, label);
        return toggle;
    }
    private void LoadAudio()
    {
        audio.InputId = Preference("input"); audio.OutputId = Preference("output");
        audio.Master = Math.Clamp(GetInt("volume", 100), 0, 200); audio.InputGain = Math.Clamp(GetInt("gain", 100), 0, 200); audio.Listen = true;
        audio.Activation = GetInt("activation", 0) == 1; audio.Threshold = Math.Clamp(GetInt("threshold", -45), -80, -10);
        audio.Preset = GetInt("preset", AudioService.SystemCommunicationsPreset);
        SyncLogAudio();
    }
    private Task PublishListening() => Rpc("setListening", new { entry = ownEntry, enabled = audio.Listen });

    private async Task AudioSettings()
    {
        using var screen = LogScreen("audioSettings");
        var owner = Guid.NewGuid();
        var inputs = AudioService.Endpoints(true); var outputs = AudioService.Endpoints(false);
        ComboBox Picker(string title, List<AudioService.Endpoint> options, string id) =>
            Choice(title, new[] { T("系统通信设备", "System communications device") }.Concat(options.Select(d => d.Name)).ToArray(), options.FindIndex(d => d.Id == id) + 1);
        var input = Picker(T("麦克风", "Microphone"), inputs, audio.InputId);
        var output = Picker(T("扬声器", "Speakers"), outputs, audio.OutputId);
        var preset = Choice(T("语音处理", "Voice processing"), [T("系统通信处理和 RNNoise", "Windows communications and RNNoise"), T("系统通信处理", "Windows communications"), T("软件回声消除、自动增益和 RNNoise", "Software echo cancellation, automatic gain and RNNoise")], CurrentRoute().Preset);
        var updating = false;
        var routeNotice = new InfoBar { Severity = InfoBarSeverity.Error };
        void RouteChanged(object sender, SelectionChangedEventArgs args)
        {
            if (updating || (ReferenceEquals(sender, preset) && preset.SelectedIndex < 0)) return;
            var action = ReferenceEquals(sender, input) ? "selectInput" : ReferenceEquals(sender, output) ? "preferOutput" : "changePreset";
            LogUI(action, outcome: "started");
            try
            {
                var candidate = CurrentRoute();
                if (ReferenceEquals(sender, input)) candidate = candidate with { Input = input.SelectedIndex > 0 ? inputs[input.SelectedIndex - 1].Id : "" };
                if (ReferenceEquals(sender, output)) candidate = candidate with { Output = output.SelectedIndex > 0 ? outputs[output.SelectedIndex - 1].Id : "" };
                if (ReferenceEquals(sender, preset)) candidate = candidate with { Preset = preset.SelectedIndex };
                ChangeRoute(candidate);
                LogUI(action, outcome: "succeeded");
                routeFellBack = false;
                routeNotice.IsOpen = false;
                RoutesChanged?.Invoke();
            }
            catch (Exception ex)
            {
                LogUI(action, outcome: "failed");
                routeNotice.Message = ErrorText(ex);
                routeNotice.IsOpen = true;
            }
            finally
            {
                updating = true;
                input.SelectedIndex = inputs.FindIndex(d => d.Id == audio.InputId) + 1;
                output.SelectedIndex = outputs.FindIndex(d => d.Id == audio.OutputId) + 1;
                preset.SelectedIndex = CurrentRoute().Preset; updating = false;
            }
        }
        input.SelectionChanged += RouteChanged; output.SelectionChanged += RouteChanged; preset.SelectionChanged += RouteChanged;
        void ReloadDevices()
        {
            updating = true;
            try
            {
                inputs = AudioService.Endpoints(true); outputs = AudioService.Endpoints(false);
                input.ItemsSource = new[] { T("系统通信设备", "System communications device") }.Concat(inputs.Select(d => d.Name)).ToArray();
                output.ItemsSource = new[] { T("系统通信设备", "System communications device") }.Concat(outputs.Select(d => d.Name)).ToArray();
                input.SelectedIndex = inputs.FindIndex(d => d.Id == audio.InputId) + 1; output.SelectedIndex = outputs.FindIndex(d => d.Id == audio.OutputId) + 1;
                preset.SelectedIndex = CurrentRoute().Preset;
            }
            finally { updating = false; }
        }
        var listen = AudioSwitch(T("收听房间语音", "Listen to room audio"), audio.Listen);
        listen.Toggled += async (_, _) =>
        {
            if (call is null || listen.IsOn == audio.Listen) return;
            audio.Listen = listen.IsOn;
            SyncLogAudio();
            if (!audio.Listen) StopCues();
            await Run(PublishListening);
        };
        var gate = AudioSwitch(T("语音激活", "Voice activation"), audio.Activation);
        var cues = AudioSwitch(T("成员进出房间提示音", "Room join and leave sounds"), GetInt("sounds", 1) == 1);
        cues.Toggled += (_, _) => { Set("sounds", cues.IsOn ? 1 : 0); if (!cues.IsOn) StopCues(); };
        gate.Toggled += (_, _) => { audio.Activation = gate.IsOn; Set("activation", audio.Activation ? 1 : 0); };
        var currentRoutes = Secondary("");
        var resume = ActionButton(T("恢复音频", "Resume audio"), ResumeAudio);
        var routes = Card(Heading(T("音频设备", "Audio devices"), 16), input, output, currentRoutes, routeNotice, resume);
        var playback = Card(Heading(T("收听与提示", "Playback and sounds"), 16), listen, Secondary(L("收听开关只影响本机播放，麦克风静音状态保持不变。")), cues,
            VolumeSlider(T("输出音量", "Output volume"), audio.Master, v => { audio.Master = (int)v; Set("volume", (int)v); }));
        var meter = new ProgressBar { Minimum = -96, Maximum = 0, Value = -96 };
        AutomationProperties.SetName(meter, T("麦克风输入电平", "Microphone input level"));
        var gateState = Secondary("");
        var threshold = VolumeSlider(T("激活阈值（dBFS）", "Activation threshold (dBFS)"), audio.Threshold,
            v => { audio.Threshold = (int)v; Set("threshold", (int)v); }, -80, -10);
        var thresholdHint = Secondary(T("提高阈值可减少底噪触发。如果轻声说话时声音被截断，请降低阈值。",
            "Raise the threshold if background noise opens the microphone. Lower it if quiet speech is cut off."));
        void ShowThreshold() => threshold.Visibility = thresholdHint.Visibility = Visible(gate.IsOn);
        gate.Toggled += (_, _) => ShowThreshold();
        ShowThreshold();
        var presetHint = Secondary("");
        var capture = Card(Heading(T("麦克风输入", "Microphone input"), 16), preset,
            presetHint,
            VolumeSlider(T("输入增益", "Input gain"), audio.InputGain, v => { audio.InputGain = (int)v; Set("gain", (int)v); }), gate,
            threshold, thresholdHint, meter, gateState);
        var start = ActionButton(T("测试麦克风", "Test microphone"), () => { if (call is null && joiningKey == "" && !routeSuspended) { LogUI("microphoneTestStarted"); audio.StartTest(owner); } return Task.CompletedTask; });
        var stop = ActionButton(T("停止测试", "Stop test"), () => { LogUI("microphoneTestStopped"); audio.EndTest(owner); return Task.CompletedTask; });
        var replay = ActionButton(T("停止并试听", "Stop and play sample"), () => { LogUI("playMicrophoneTest"); audio.PlayTest(owner); return Task.CompletedTask; });
        var sampleState = Secondary("");
        var sample = Card(Heading(L("麦克风测试"), 16), Secondary(L("仅在本机测试，最长采集十秒。试听最近三秒，不上传、不保存文件。")),
            sampleState, Row(start, stop, replay));
        var pane = Stack(routes, playback, capture, sample);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        void Update()
        {
            audio.UpdateTest(owner);
            var canChange = !audio.TestBusy && !changingMicrophone && !routeSuspended && joiningKey.Length == 0;
            input.IsEnabled = output.IsEnabled = canChange; preset.IsEnabled = canChange && (call is null || call.Bool("ready"));
            var inputName = inputs.FirstOrDefault(d => d.Id == resolvedInput)?.Name ?? "—";
            var outputName = outputs.FirstOrDefault(d => d.Id == resolvedOutput)?.Name ?? "—";
            currentRoutes.Text = T("当前输入", "Current input") + "   " + inputName + "\n" + T("当前输出", "Current output") + "   " + outputName
                + (routeFellBack ? "\n" + T("原设备已断开，已回退到系统默认设备。", "The selected device disconnected. Using the system default.") : "");
            resume.Visibility = Visible(routeSuspended && call is not null); resume.IsEnabled = !resumingAudio;
            presetHint.Text = preset.SelectedIndex switch
            {
                0 => T("Windows 处理通话音频，RNNoise 再过滤背景噪声。", "Windows processes the call audio, then RNNoise filters background noise."),
                1 => T("使用 Windows 通信设备提供的音频处理。", "Use the processing provided by the Windows communications device."),
                _ => T("在本机使用软件回声消除、自动增益和 RNNoise 降噪。", "Use software echo cancellation, automatic gain and RNNoise on this PC.")
            };
            listen.IsEnabled = call is not null; listen.IsOn = audio.Listen;
            meter.Value = Math.Clamp(audio.Level, -96, 0);
            gateState.Text = !audio.HasInput ? T("未采集音频", "Microphone idle") : !audio.Activation ? T("语音激活已关闭", "Voice activation off") :
                audio.GateOpen ? T("已检测到声音", "Voice detected") : L("等待声音超过阈值");
            sampleState.Text = audio.IsTesting(owner) ? T("正在采集本机麦克风…", "Recording a local microphone sample…") :
                audio.OwnsTest(owner) ? L("正在试听本机录音") : call is not null ? L("离开语音后可测试麦克风") :
                audio.TestBusy ? T("另一窗口正在测试麦克风。", "Another window is testing the microphone.") : "";
            sampleState.Visibility = Visible(sampleState.Text.Length > 0);
            start.IsEnabled = call is null && canChange && !audio.HasInput;
            stop.IsEnabled = audio.OwnsTest(owner); replay.IsEnabled = audio.HasClip(owner);
        }
        timer.Tick += (_, _) => Update();
        RoutesChanged += ReloadDevices; Update(); timer.Start();
        try { await Dialogs.Box(XamlRoot, T("声音设置", "Audio settings"), new ScrollViewer { Content = pane, MaxHeight = 460 }, T("完成", "Done")).ShowAsync(); }
        finally { RoutesChanged -= ReloadDevices; timer.Stop(); audio.EndTest(owner); }
    }
    private async Task CacheSettings()
    {
        using var screen = LogScreen("cacheSettings");
        var entry = ownEntry; var revision = attachmentRevision;
        var size = await Rpc("cacheSize");
        var storage = Math.Ceiling(size.Num("bytes") / 1024d);
        var body = Stack(Heading(T($"本机缓存占用 {storage:N0} KB", $"Local cache size: {storage:N0} KB"), 16),
            Text(L("清理此设备上全部房间的附件缓存并取消传输。当前聊天中的附件将失效，语音和文字消息保留。你保存到其他文件夹的文件不会被删除。")),
            Secondary(L("离房时自动清理附件缓存；如果应用意外退出，下次启动时也会自动清理。")));
        var dialog = Dialogs.Box(XamlRoot, T("附件缓存", "Attachment cache"), body, T("取消", "Cancel"), T("清空缓存", "Clear cache"));
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && await ClearAttachmentCache(entry, revision))
            Show(() => L("附件缓存已清空"), InfoBarSeverity.Success);
    }
}
