using System.Text.Json.Nodes;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace Chirp;

public sealed partial class MainPage
{
    private static readonly Dictionary<string, AttachmentStatus> transfers = new();
    private bool? showChat;
    private bool syncingChatToggle;
    private readonly Dictionary<string, Action<JsonNode?>> peerStatus = new();
    private static readonly Dictionary<string, Microsoft.UI.Xaml.Media.ImageSource> thumbnails = new();
    private async Task Refresh()
    {
        if (member is null) return;
        if (refreshing) { refreshQueued = true; return; }
        refreshing = true;
        try
        {
            do
            {
                refreshQueued = false;
                var login = member;
                var visibility = directoryVisibility;
                JsonNode? next;
                try { next = await Rpc("state"); }
                catch when (!ReferenceEquals(login, member) || visibility != directoryVisibility || !directoryActive) { continue; }
                catch { MarkDirectoryStale(); throw; }
                if (!ReferenceEquals(login, member) || member is null || directoryVisibility != visibility || !directoryActive) continue;
                profiles.Snapshot(next.List("members"));
                var digest = next?.ToJsonString() ?? "";
                if (digest == lastDirectory && !directoryStale) continue;
                lastDirectory = digest; directory = next; SetDirectoryStale(false);
                foreach (var page in App.Pages)
                {
                    if (!directory.List("rooms").Any(r => r.Str("room_id") == page.selected)) page.selected = directory.List("rooms").FirstOrDefault().Str("room_id");
                    page.BuildNav();
                    if (page.selectionType == "room") page.Render();
                }
            } while (refreshQueued && member is not null);
        }
        finally { refreshing = false; }
    }
    private static void SetDirectoryStale(bool value)
    {
        directoryStale = value;
        foreach (var page in App.Pages)
            if (page.profileSyncNotice is { } notice) notice.IsOpen = value;
    }
    private static void MarkDirectoryStale()
    {
        if (member is null || directoryStale) return;
        SetDirectoryStale(true);
        foreach (var page in App.Pages) { page.BuildNav(); if (page.selectionType == "room") page.Render(); }
    }
    private static NavigationViewItem NavItem(string title, string tag, string glyph, string? detail = null)
    {
        var item = new NavigationViewItem { Content = title, Tag = tag, Icon = Glyph(glyph) };
        if (detail is not null)
        {
            var label = new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = FontWeights.SemiBold };
            var summary = Secondary(detail, 12);
            summary.TextWrapping = TextWrapping.NoWrap;
            summary.TextTrimming = TextTrimming.CharacterEllipsis;
            var lines = Stack(label, summary);
            lines.Spacing = 2;
            item.Content = lines;
            item.MinHeight = 52;
        }
        Label(item, detail is null ? title : title + " · " + detail);
        return item;
    }

    private NavigationViewItem? returnCallItem;

    private void BuildNav()
    {
        buildingNav = true;
        try
        {
            Nav.MenuItems.Clear();
            Nav.FooterMenuItems.Clear();
            Nav.MenuItems.Add(new NavigationViewItemHeader { Content = T("房间", "Rooms") });
            foreach (var room in directory.List("rooms"))
            {
                var id = room.Str("room_id");
                var inCall = call.Str("room") == id;
                var item = NavItem(room.Str("display_name"), "room:" + id,
                    inCall ? "\uE717" : room.Bool("password_required") ? "\uE72E" : "\uE95B",
                    inCall ? T("当前通话", "Current call") : RoomPresenceLabel(room));
                Nav.MenuItems.Add(item);
                if (selectionType == "room" && selected == id) Nav.SelectedItem = item;
            }
            var contacts = NavItem(T("好友", "Friends"), "friends", "\uE716");
            Nav.FooterMenuItems.Add(contacts);
            if (selectionType == "friends") Nav.SelectedItem = contacts;
            returnCallItem = null;
            if (call is not null)
            {
                returnCallItem = NavItem(T("返回通话", "Return to call"), "return", "\uE717");
                returnCallItem.SelectsOnInvoked = false;
                returnCallItem.Visibility = Visible(selectionType != "room" || selected != call.Str("room"));
                Nav.FooterMenuItems.Add(returnCallItem);
            }
            var preferences = NavItem(T("设置", "Settings"), "settings", "\uE713");
            Nav.FooterMenuItems.Add(preferences);
            if (selectionType == "settings") Nav.SelectedItem = preferences;
            UpdateSidebarIdentity();
        }
        finally { buildingNav = false; }
    }

    private void UpdateSidebarIdentity()
    {
        var id = member.Str("id");
        var name = DisplayName(id, member.Str("display_name"));
        if (SidebarAvatar.Content is not null && SidebarName.Text == name) return;
        SidebarName.Text = name;
        SidebarAvatar.Content = ProfilePicture(id, 32, name);
    }

    private void Navigated(NavigationView sender, NavigationViewSelectionChangedEventArgs e)
    {
        if (buildingNav || member is null || e.SelectedItem is not NavigationViewItem { Tag: string tag }) return;
        if (tag.StartsWith("room:", StringComparison.Ordinal))
        {
            selectionType = "room";
            selected = tag[5..];
        }
        else selectionType = tag;
        LogUI(selectionType);
        if (returnCallItem is not null) returnCallItem.Visibility = Visible(selectionType != "room" || selected != call.Str("room"));
        StageScroll.ChangeView(null, 0, null, true);
        Render();
        MoveSurface(StageScroll, y: 12);
    }

    private void NavInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer != returnCallItem || call is null || returnCallItem is null) return;
        Nav.SelectedItem = Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => Equals(item.Tag, "room:" + call.Str("room")));
    }

    private JsonNode? SelectedRoom() => directory.List("rooms").FirstOrDefault(r => r.Str("room_id") == selected);

    private void Render()
    {
        pageGeneration++;
        Stage.Children.Clear();
        peerStatus.Clear();
        themeChoice = null;
        var room = selectionType == "room" ? SelectedRoom() : null;
        RenderRoomVerificationNotice(room is not null && selected == call.Str("room") ? call : null);
        RoomCover.Visibility = RoomKindIcon.Visibility = Visible(room is not null);
        RoomKindIcon.Glyph = room.Bool("password_required") ? "\uE72E" : "\uE8BD";
        Grid.SetRow(HeaderTitle, room is null ? 0 : 1);
        Grid.SetRow(HeaderContext, room is null ? 1 : 0);
        RoomDescription.Visibility = RoomDetails.Visibility = Visible(room is not null);
        if (selectionType == "settings")
        {
            WorkspaceTitle.Text = T("设置", "Settings");
            WorkspaceSubtitle.Text = T("管理声音、外观、账号和这台电脑上的数据。", "Manage audio, appearance, your account and data on this PC.");
            RenderSettings();
        }
        else if (selectionType == "friends")
        {
            WorkspaceTitle.Text = T("好友", "Friends");
            WorkspaceSubtitle.Text = T("查看好友及已信任的设备。", "View your friends and their trusted devices.");
            _ = Run(() => RenderFriends(pageGeneration));
        }
        else
        {
            WorkspaceTitle.Text = room?.Str("display_name") ?? T("语音房间", "Voice rooms");
            WorkspaceSubtitle.Text = room is null ? "" :
                (room.Bool("is_default") ? T("主房间", "Main room") : T("语音房间", "Voice room")) + " · " +
                (room.Bool("password_required") ? T("入房需要密码", "Password required") : T("入房无需密码", "Open to signed-in members"));
            if (room is not null)
            {
                var description = room.Str("description");
                RoomDescription.Text = string.IsNullOrWhiteSpace(description) ? L("一个房间，几个朋友，随时聊聊。") : description;
                RenderRoom(room);
            }
            else if (directory is null && !directoryStale)
                Stage.Children.Add(Line(Text(T("正在读取房间…", "Loading rooms…")), new ProgressRing { IsActive = true, Width = 20, Height = 20 }));
            else if (directoryStale)
                Stage.Children.Add(EmptyState(T("暂时无法加载房间", "Rooms couldn’t be loaded"),
                    T("连接恢复后会自动更新房间列表。", "The room list will update when the connection resumes."), IconTile("\uF384")));
            else
                Stage.Children.Add(EmptyState(T("暂未找到房间", "No rooms available"),
                    T("可加入的房间会显示在这里。", "Available rooms will appear here."), IconTile("\uE95B")));
        }
        HeaderContext.Visibility = Visible(WorkspaceSubtitle.Text.Length > 0);
        HeaderContext.ColumnSpacing = room is null ? 0 : 6;
        FitHeader();
        RenderDock();
        LayoutChat();
    }

    private void RenderVerification(JsonObject verification)
    {
        var peer = verification.Str("Peer"); var id = verification.Str("ID"); var step = verification.Str("Step");
        Task Verify(string action) => Rpc("verify", new { action, peer, id });
        var title = step switch
        {
            "sent" => L("等待朋友接受邀请"),
            "incoming" => L("朋友邀请你核验设备"),
            "accepted" => L("正在生成安全码"),
            "compare" => L("一起核对这三组数字"),
            "confirmed" => L("你已确认，等待朋友"),
            "completed" => L("设备互认完成"),
            "trustPending" => L("设备信任尚未同步"),
            "mismatch" => L("安全码不一致，已停止核验"),
            "timedOut" => L("核验等待超时"),
            "peerBusy" => T("对方正忙", "Participant busy"),
            "peerCancelled" => L("朋友已取消这次核验"),
            "roomChanged" => L("房间成员已变化"),
            "cancelled" => T("已取消设备互认", "Device verification cancelled"),
            _ => L("这次核验未完成")
        };
        var content = Stack(Line(Stack(Heading(title, 18), Secondary(verification.Str("Name"))), IconTile("\uE8D7")));
        if (step is "sent" or "incoming" or "accepted" or "compare" or "confirmed")
        {
            var number = step == "compare" ? 2 : step == "confirmed" ? 3 : 1;
            var stage = number == 1 ? L("准备核验") : number == 2 ? L("比较安全码") : L("双方确认");
            var caption = T($"第 {number} 步，共 3 步 · {stage}", $"Step {number} of 3 · {stage}");
            var progress = new ProgressBar { Minimum = 0, Maximum = 3, Value = number };
            AutomationProperties.SetName(progress, caption);
            content.Children.Add(Stack(Secondary(caption), progress));
        }
        var actions = Row();
        if (step == "incoming")
        {
            content.Children.Add(Text(L("先确认你正在与本人联系，再接受邀请。接受邀请不会立即建立信任。")));
            actions.Children.Add(ActionButton(T("接受并显示安全码", "Accept and show code"), () => Verify("accept"), true));
        }
        else if (step is "compare" or "confirmed")
        {
            content.Children.Add(SecurityCode(verification, "Decimals"));
            content.Children.Add(Text(L("请当面或通过另一条已认证的渠道核对全部三组数字。不要通过本房间或未经核验的聊天核对。")));
            if (step == "compare")
            {
                actions.Children.Add(ActionButton(T("三组数字全部一致", "All three groups match"), () => Verify("confirm"), true));
                actions.Children.Add(ActionButton(T("数字不一致", "Numbers differ"), () => Verify("mismatch")));
            }
            else content.Children.Add(Text(L("请让朋友也点击「三组数字全部一致」。双方都确认后，才会保存设备信任。")));
        }
        else content.Children.Add(Text(step switch
        {
            "completed" => L("你已信任朋友的当前设备。以后使用同一台设备相聚时，可复用这份信任。"),
            "trustPending" => L("安全码已由双方确认，但信任记录尚未同步。请保持联网后重试同步，无需再次比较数字。"),
            "timedOut" => L("对方可能暂时离开或网络不稳定。这次核验已结束，联系上对方后可以重新开始。"),
            "peerBusy" => T("对方正在核验设备，请稍后重新邀请。", "This participant is verifying a device. Try inviting them again later."),
            "peerCancelled" => L("这次核验没有建立新的设备信任。可以先联系对方，准备好后再试一次。"),
            "cancelled" => L("这次核验已取消，没有建立新的设备信任。准备好后可以重新开始。"),
            "mismatch" => L("这次核验没有建立新的设备信任。请先通过可信渠道确认联系的是本人，再重新核验。"),
            "roomChanged" => L("为确保核验的是当前参与的设备，这次核验已结束。请确认对方仍在房间后重新开始。"),
            "failed" => L("核验遇到了问题，没有建立新的设备信任。请检查网络与对方的在线状态后重试。"),
            "sent" => L("邀请已准备好。请提醒对方打开 Chirp，接受设备互认邀请；安全码会自动出现。"),
            _ => L("双方正在交换核验信息，请保持 Chirp 打开，稍候片刻。")
        }));
        if (step == "trustPending") actions.Children.Add(ActionButton(T("重试同步", "Retry sync"), () => Verify("retryTrust"), true));
        if (step == "peerBusy" && call.Bool("canRetryVerification"))
            actions.Children.Add(ActionButton(T("重新邀请", "Invite again"), () => Verify("retry"), true));
        else if (call.Bool("canRetryVerification"))
            actions.Children.Add(ActionButton(L("重新准备核验"), () => MemberInfo(peer, id), true));
        else if (call.List("peers").Any(p => p.Str("id") == peer))
            actions.Children.Add(ActionButton(L("账号与设备详情"), () => MemberInfo(peer)));
        if (step is "sent" or "incoming" or "accepted" or "compare" or "confirmed")
            actions.Children.Add(ActionButton(T("取消核验", "Cancel verification"), () => Verify("cancel")));
        else actions.Children.Add(ActionButton(L("返回房间"), () => Verify("dismiss")));
        content.Children.Add(actions);
        Stage.Children.Add(Card(content));
    }

    private FrameworkElement SecurityCode(JsonNode? data, string key)
    {
        var groups = Row();
        var number = 0;
        foreach (var value in data.List(key))
        {
            var digits = value?.GetValue<int>().ToString("0000", System.Globalization.CultureInfo.InvariantCulture) ?? "";
            var position = ++number;
            var caption = SecurityCodeGroupLabel(position);
            var code = Text(digits, 24, "ChirpHeading");
            code.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            var block = Stack(Secondary(caption, 12), code);
            block.Spacing = 2;
            groups.Children.Add(new Border { Style = Design("ChirpInset"), Padding = new Thickness(12, 8, 12, 8), Child = block });
        }
        return groups;
    }

    private string PeerIdentityStatus(JsonNode? peer) => peer.Bool("self") ? L("当前设备") :
        peer.Bool("trusted") ? T("已核验的设备", "Verified device") : T("设备待核验", "Unverified device");
    private async Task MemberInfo(string id, string? retryID = null)
    {
        using var screen = LogScreen("memberInfo");
        var p = call.List("peers").FirstOrDefault(x => x.Str("id") == id); if (p is null) return;
        var status = Text(PeerIdentityStatus(p)); var diagnostics = Text("");
        var audioStatus = MemberAudioIndicators(showLabels: true);
        var keys = new Expander { Header = T("身份指纹", "Identity fingerprints"), Content = Stack(Text(T("设备指纹", "Device fingerprint")), CopyText(DesktopText.Fingerprint(p.Str("key"))), Text(T("账号指纹", "Account fingerprint")), CopyText(DesktopText.Fingerprint(p.Str("root")))) };
        var friendStatus = Text("");
        var rows = Stack(status, audioStatus.View, CopyText(id.Split('.')[0]), friendStatus, keys, new Expander
        {
            Header = T("连接诊断", "Connection diagnostics"),
            Content = Stack(Secondary(L("这些信息来自本机接收侧观测。")), diagnostics, Secondary(L("静音时事件可能不更新，不代表音频连接中断。")))
        });
        var entry = ownEntry;
        bool Current() => ownEntry == entry && call.List("peers").Any(x =>
            x.Str("id") == id && x.Str("key") == p.Str("key") && x.Str("root") == p.Str("root"));
        if (retryID is null && call?["verification"] is JsonObject current &&
            current.Str("Step") == "peerBusy" && current.Str("Peer") == id)
            retryID = current.Str("ID");
        bool CanStart() => Current() && CanInvitePeer(id, retryID);
        var volume = VolumeSlider(T("成员音量", "Participant volume"), audio.PeerVolume(id), v => { if (Current() && v != audio.PeerVolume(id)) { audio.SetPeerVolume(id, v); LogUI("memberVolume"); } });
        var unmuted = volume.Value > 0 ? volume.Value : 100;
        var mute = ActionButton("", () =>
        {
            if (volume.Value == 0) volume.Value = unmuted;
            else { unmuted = volume.Value; volume.Value = 0; }
            return Task.CompletedTask;
        });
        var sound = Stack(volume, Secondary(T("只影响你听到的声音", "Only affects what you hear")), Row(mute,
            ActionButton(T("恢复默认音量", "Reset volume"), () => { volume.Value = 100; return Task.CompletedTask; })));
        if (!p.Bool("self")) rows.Children.Add(sound);
        rows.Children.Insert(0, ProfilePicture(id, 72, DisplayName(id, p.Str("name"))));
        Button? addFriend = null;
        if (!p.Bool("self"))
        {
            rows.Children.Add(Secondary(L("添加好友是单向操作，不代表已核验设备。")));
            addFriend = ActionButton(T("添加好友", "Add friend"), async () =>
            {
                if (!Current()) return;
                await Rpc("friend", new { peer = id });
                await RefreshFriendNames();
                Show(() => T("已加入好友", "Friend added"), InfoBarSeverity.Success);
            });
            rows.Children.Add(addFriend);
        }
        var box = Dialogs.Box(XamlRoot, DisplayName(id, p.Str("name")), new ScrollViewer { Content = rows, MaxHeight = 430 }, T("关闭", "Close"));
        if (!p.Bool("self"))
            box.PrimaryButtonText = p.Bool("trusted") ? T("重新核验", "Verify again") : T("验证身份", "Verify identity");
        void SetMuteLabel() => mute.Content = volume.Value == 0 ? T("恢复收听", "Unmute locally") : T("本机静音", "Mute locally");
        volume.ValueChanged += (_, _) => SetMuteLabel();
        void Update()
        {
            var peer = ownEntry == entry ? call.List("peers").FirstOrDefault(x => x.Str("id") == id) : null;
            box.IsPrimaryButtonEnabled = CanStart();
            friendStatus.Text = peer.Bool("self") ? T("你的账号", "Your account") : peer.Str("friendName").Length > 0 ? L("你的好友") : L("房间成员");
            if (addFriend is not null) addFriend.Visibility = Visible(peer is not null && peer.Str("friendName").Length == 0);
            sound.Visibility = Visible(peer is not null);
            status.Text = peer is null ? T("成员已离房", "Participant left the room") : PeerIdentityStatus(peer);
            audioStatus.View.Visibility = Visible(peer is not null);
            if (peer is null) return;
            audioStatus.Update(peer);
            box.Title = DisplayName(id, peer.Str("name"));
            diagnostics.Text = TrackDiagnostics(peer);
            volume.Value = audio.PeerVolume(id);
            SetMuteLabel();
        }
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; timer.Tick += (_, _) => Update();
        Update(); timer.Start();
        try
        {
            if (await box.ShowAsync() == ContentDialogResult.Primary && CanStart())
                await Rpc("verify", new { action = retryID is null ? "start" : "retry", peer = id, id = retryID });
        }
        finally { timer.Stop(); }
    }
    private string DisplayName(string entry, string fallback)
    {
        var id = entry.Split('.')[0];
        var peer = call.List("peers").FirstOrDefault(p => p.Str("id") == entry);
        if (peer.Str("friendName") is { Length: > 0 } boundName) return boundName;
        var profile = profiles.Profile(id);
        if (profile.Str("display_name") is { Length: > 0 } name) return name;
        return fallback.Length > 0 ? fallback : id.Length > 0 ? id : L("房间成员");
    }
    private async Task Join(JsonNode room)
    {
        if (joiningKey.Length != 0) return;
        var login = member;
        var id = room.Str("room_id");
        string? attempt = null;
        if (room.Bool("password_required"))
        {
            var input = new PasswordBox { Header = T("房间密码", "Room password") };
            var feedback = new InfoBar { IsClosable = false };
            var hint = call is null ? T("输入房间密码，加入时麦克风会保持静音。", "Enter the room password. Your microphone starts muted.") :
                T("输入密码即可加入。验证通过前，你会留在当前通话中。", "Enter the password to join. You will stay in your current call until verification succeeds.");
            using var screen = LogScreen("joinPrompt");
            var dialog = Dialogs.Box(XamlRoot, room.Str("display_name"), Stack(Text(hint), input, feedback), T("取消", "Cancel"), T("验证并加入", "Verify and join"));
            var dismissed = false;
            void SetFeedback(string message, InfoBarSeverity severity)
            {
                feedback.Severity = severity;
                feedback.Message = message;
                feedback.IsOpen = true;
            }
            dialog.PrimaryButtonClick += async (_, click) =>
            {
                click.Cancel = true;
                if (!dialog.IsPrimaryButtonEnabled) return;
                if (System.Text.Encoding.UTF8.GetByteCount(input.Password) > 512)
                {
                    SetFeedback(T("房间密码不能超过 512 字节。", "The room password must be at most 512 bytes."), InfoBarSeverity.Error);
                    return;
                }
                dialog.IsPrimaryButtonEnabled = input.IsEnabled = false;
                SetFeedback(T("正在验证入房…", "Verifying access…"), InfoBarSeverity.Informational);
                try { if (await Submit(input.Password) && !dismissed) dialog.Hide(); }
                catch (Exception ex) { if (!dismissed) SetFeedback(ErrorText(ex), InfoBarSeverity.Error); }
                finally
                {
                    if (!dismissed)
                    {
                        dialog.IsPrimaryButtonEnabled = input.IsEnabled = true;
                        input.Focus(FocusState.Programmatic);
                    }
                }
            };
            dialog.Closing += (_, _) =>
            {
                dismissed = true;
                if (attempt is { } key && joiningKey == key)
                    _ = Run(async () => { await Rpc("cancelJoin", new { key }); });
            };
            try { await dialog.ShowAsync(); }
            finally { input.Password = ""; }
            return;
        }
        await Submit("");

        async Task<bool> Submit(string password)
        {
            if (member is null || !ReferenceEquals(login, member) || joiningKey.Length != 0) return false;
            var key = Guid.NewGuid().ToString("D");
            attempt = joiningKey = key;
            joiningRoom = id;
            audio.CancelTest();
            RedrawRooms();
            try
            {
                await Rpc("join", new { id, password, key });
                if (joiningKey != key || !ReferenceEquals(login, member)) return false;
                ApplyCall(await Rpc("room"));
                return true;
            }
            catch (ProtocolException e) when (e.Message == "JOIN_CANCELLED") { return false; }
            catch when (joiningKey != key || !ReferenceEquals(login, member)) { return false; }
            finally
            {
                attempt = null;
                if (joiningKey == key) { joiningKey = joiningRoom = ""; RedrawRooms(); }
            }
        }
    }
    private async Task CancelJoin()
    {
        var key = joiningKey;
        if (key.Length == 0) return;
        await Rpc("cancelJoin", new { key });
        if (joiningKey == key) { joiningKey = joiningRoom = ""; RedrawRooms(); }
    }
    private static void RedrawRooms()
    {
        foreach (var page in App.Pages)
        {
            page.BuildNav();
            if (page.selectionType == "room") page.Render();
            else page.RenderDock();
        }
    }
    private async Task Leave() { audio.Reset(); await Rpc("leave"); }
    private async Task Mute()
    {
        if (changingMicrophone || ownEntry == "") return;
        var enable = call.Bool("muted");
        captureFailedEntry = "";
        var entry = ownEntry;
        changingMicrophone = true;
        try
        {
            if (!enable) audio.StopCapture();
            await Rpc("mute", new { entry, group = call.Str("group"), enabled = !enable });
        }
        finally { changingMicrophone = false; }
        if (ownEntry == entry) ApplyCall(await Rpc("room"));
    }
    private async Task RoomInfo()
    {
        using var screen = LogScreen("roomInfo");
        var room = SelectedRoom();
        if (room is null) return;
        var id = selected;
        var entry = ownEntry;
        var inRoom = call.Str("room") == id && entry.Length > 0;
        var rules = Stack(Text(room.Bool("password_required") ? T("入房需要密码", "A password is required to join") : T("已登录成员可以入房", "Signed-in members can join")),
            Text(T("人数不限", "No participant limit")), Text(T("入房麦克风默认静音", "Microphones are muted on entry")),
            Text(T("成员互相验证设备后，才能收发语音、聊天和附件。", "Participants verify each other’s devices before sharing voice, messages or files.")));
        if (inRoom) rules.Children.Add(CopyText("MLS · Chirp V5"));
        var progress = Text("");
        var description = CopyText(RoomDescription.Text);
        var details = inRoom ? Stack(progress, new Expander { Header = T("房间规则与协议", "Room rules and protocol"), Content = rules }) : rules;
        var content = new ScrollViewer { Content = Stack(description, details), MaxHeight = 430 };
        void Update()
        {
            var now = AudioService.Now;
            var observed = call.Num("informationObservedAt");
            var info = call?["information"];
            if (ownEntry != entry || call.Str("room") != id)
            { progress.Text = T("已离开房间", "You have left this room"); return; }
            if (call.Str("status") == "verify")
            { progress.Text = T("等待设备互认；完成后建立安全连接并安排换钥。", "Waiting for device verification before establishing the connection and scheduling key rotation."); return; }
            if (info is null)
            { progress.Text = T("房间安全状态待同步", "Waiting for room security information"); return; }
            var fresh = !call.Bool("informationUnavailable") && RoomClock.Fresh(observed, now);
            string At(string key) => info.Num(key) is > 0 and <= 253402300799999 ? DateTimeOffset.FromUnixTimeMilliseconds(info.Num(key)).ToLocalTime().ToString("G", DisplayCulture) : L("尚未建立");
            var seconds = RoomClock.Remaining(observed, now, info.Num("server_time_ms"), info.Num("next_rotation_at_ms"));
            var rotation = info.Str("rotation_phase");
            var phase = rotation switch {
                "collecting" or "welcoming" => T("正在准备新密钥", "Preparing new keys"),
                "confirming" or "ready" => T("等待全员确认", "Waiting for confirmation"),
                "switching" => T("正在切换与确认", "Switching keys"),
                _ => info.Num("established_at_ms") > 0 ? T("本轮已完成", "Complete") : T("等待建立安全连接", "Establishing secure connection") };
            var reason = info.Str("update_reason") switch {
                "initial_connection" => T("首次建立连接", "Initial connection"), "members_changed" => T("房间成员变化", "Membership changed"),
                "scheduled_rotation" => T("例行换钥", "Scheduled rotation"), _ => T("重新建立连接", "Connection recovery") };
            var pending = T("等待同步", "Waiting for synchronization");
            var next = !fresh ? pending : rotation == "switching" ? T("等待全员完成", "Waiting for all devices")
                : seconds switch { null => L("尚未安排"), 0 => L("正在更新"), _ => At("next_rotation_at_ms") + T($"（约 {seconds} 秒后）", $" (in about {seconds} s)") };
            var epoch = info["key_epoch"]?.GetValue<ulong>() ?? 0;
            var lines = new List<string> {
                fresh ? T("已同步当前房间状态", "Current room state synchronized") : T("房间状态暂时无法同步", "Room state is temporarily unavailable"),
                T("密钥轮次", "Key round") + "   " + (fresh ? (epoch + 1).ToString() : pending),
                T("本次安全连接建立", "Connection established") + "   " + At("established_at_ms"),
                T("上次确认的换钥", "Last confirmed rotation") + "   " + At("last_rotation_at_ms"), T("下次计划换钥", "Next planned rotation") + "   " + next,
                T("换钥阶段", "Rotation phase") + "   " + (fresh ? phase : pending), T("最近更新原因", "Last update reason") + "   " + reason,
                L("例行计划间隔") + "   " + T($"{info.Num("rotation_interval_ms") / 1000} 秒", $"{info.Num("rotation_interval_ms") / 1000} s")
            };
            if (fresh && rotation.Length > 0)
            {
                lines.Add(T("已确认设备", "Confirmed devices") + $"   {info.Num("confirmed_members")} / {info.Num("member_count")}");
                lines.Add(T("已切换设备", "Switched devices") + $"   {info.Num("activated_members")} / {info.Num("member_count")}");
            }
            progress.Text = string.Join("\n", lines);
        }
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += (_, _) => Update();
        if (inRoom) { Update(); timer.Start(); }
        var subscription = RoomDescription.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) =>
        {
            if (selected == id) description.Text = RoomDescription.Text;
        });
        try { await Dialogs.Box(XamlRoot, room.Str("display_name"), content, T("关闭", "Close")).ShowAsync(); }
        finally
        {
            RoomDescription.UnregisterPropertyChangedCallback(TextBlock.TextProperty, subscription);
            timer.Stop();
        }
    }
    private string TrackDiagnostics(JsonNode? peer)
    {
        var diagnostic = peer?["diagnostic"];
        var tracks = diagnostic.List("tracks");
        var lines = new List<string> { T("已解密的语音包", "Decrypted packets") + "   " + peer.Num("packets") };
        if (tracks.Count == 0) lines.Add(FormatTrack(diagnostic));
        for (var index = 0; index < tracks.Count; index++)
        {
            if (tracks.Count > 1) lines.Add(T($"音轨 {index + 1}", $"Track {index + 1}"));
            lines.Add(FormatTrack(tracks[index]));
        }
        return string.Join("\n", lines);
    }
    private string FormatTrack(JsonNode? track)
    {
        string Number(string key, string unit = "") => track?[key]?.ToString() is { Length: > 0 } n ? n + unit : "—";
        var state = track.Str("encryption") switch
        {
            "verified" => T("解密正常", "Verified"),
            "missingKey" => T("缺少密钥", "Missing key"),
            "decryptionFailed" => T("解密失败", "Decryption failed"),
            "waiting" => T("等待已加密数据包", "Waiting for encrypted packets"),
            _ => T("暂无音轨", "No audio track")
        };
        var details = string.Join("\n", T("订阅", "Subscription") + "   " + (track.Bool("subscriptionFailed") ? T("失败", "Failed") : track.Bool("subscribed") ? T("已订阅", "Subscribed") : T("未订阅", "Unsubscribed")),
            T("音轨", "Track") + "   " + (track.Bool("muted") ? T("静音", "Muted") : state), T("加密状态", "Encryption") + "   " + state,
            T("接收包数", "Packets received") + "   " + Number("packetsReceived"), T("丢包数", "Packets lost") + "   " + Number("packetsLost"),
            T("抖动", "Jitter") + "   " + Number("jitterMs", " ms"), T("往返时间", "Round-trip time") + "   " + Number("roundTripMs", " ms"),
            T("连接质量", "Connection quality") + "   " + (track.Str("quality") switch
            {
                "excellent" => L("网络良好"), "good" => L("网络正常"),
                "poor" => L("网络较差"), "lost" => L("网络连接丢失"), _ => L("网络状态待确认")
            }));
        if (track?["lastDecryptionEventAgeMs"] is not null)
        {
            var seconds = Math.Clamp(track.Num("lastDecryptionEventAgeMs") / 1000, 0, 86_400);
            details += "\n" + T($"最近一次成功解密在 {seconds} 秒前", seconds == 1 ? "Last successful decryption was 1 second ago" : $"Last successful decryption was {seconds} seconds ago");
        }
        return details;
    }
    private void OnNotification(string kind, JsonNode? data)
    {
        if (kind == "mediaLease")
        {
            var entry = data.Str("entry"); var group = data.Str("group"); var deadline = data.Num("deadline");
            if (!routeSuspended && audio.Renew(entry, group, deadline, data.Num("revision")) && deadline <= AudioService.Now)
                DispatcherQueue.TryEnqueue(() => { if (ownEntry == entry && !audio.Permitted(entry, call.Str("group"))) audio.StopCapture(); });
            return;
        }
        if (kind == "audio")
        {
            try { audio.Play(data.Str("entry"), data.Str("group"), data.Str("sender"), Convert.FromBase64String(data.Str("packet")), data.Num("deadline")); }
            catch (Exception ex) { DispatcherQueue.TryEnqueue(() => ShowError(ex)); }
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (closed) return;
            switch (kind)
            {
                case "directoryChanged": if (directoryActive && directoryWatch == data.Str("watch")) _ = Run(Refresh); break;
                case "directoryStale": if (directoryActive && directoryWatch == data.Str("watch")) MarkDirectoryStale(); break;
                case "room": ApplyCall(data); break;
                case "joined":
                    ClearCall(); ownEntry = data.Str("identity"); audio.BeginEntry(ownEntry); ApplyAttachmentScope(data);
                    _ = Run(PublishListening);
                    break;
                case "left": ClearCall(); RedrawRooms(); break;
                case "roomError": App.Shell.Page.ShowError(data?.ToString() ?? ""); break;
                case "chat":
                    if (data.Str("entry") != ownEntry || (data?["file"] is not null && !AttachmentCurrent(data))) break;
                    var sender = data.Str("sender");
                    if (sender == ownEntry && data?["file"] is null) break;
                    var name = sender == ownEntry ? T("你", "You") : DisplayName(sender, call.List("peers").FirstOrDefault(p => p.Str("id") == sender).Str("name"));
                    transcript.Receive(name, data.Str("text"), data?["file"], mine: sender == ownEntry);
                    if (data.Str("thumbnail") is { Length: > 0 } thumb && data?["file"] is { } item) _ = LoadThumbnail(item.Str("id"), thumb, data.Str("entry"), data.Str("revision"));
                    DrawMessages(followLocal: sender == ownEntry); break;
                case "attachmentError":
                    if (AttachmentCurrent(data)) ShowError(data.Str("error"));
                    break;
                case "transfer":
                    ApplyTransfer(data); break;
                case "cacheCleared":
                    if (data.Str("entry") == ownEntry && (attachmentRevision == data.Str("previous") || clearingRevision == data.Str("previous")))
                    {
                        RetireAttachments(data.Str("previous"));
                        attachmentRevision = data.Str("revision");
                        clearingRevision = "";
                        DrawMessages();
                    }
                    break;
                case "signedOut":
                    SignedOut(reason: data?.ToString() ?? "UNAUTHORIZED");
                    break;
                case "stopped":
                    if (App.Exiting) break;
                    SignedOut(restore: false, reason: data?.ToString() ?? "PROTOCOL_STOPPED");
                    break;
            }
        });
    }
    private void ApplyCall(JsonNode? next)
    {
        if (next is null || ownEntry.Length == 0 || next.Str("entry") != ownEntry) return;
        if ((!next.Bool("ready") || routeSuspended) && transcript.Pending is { } pending && transcript.Finish(pending, false)) DrawMessages();
        call = next;
        KeepRoomOutput();
        ApplyAttachmentScope(next);
        var ready = !routeSuspended && next.Bool("ready") && next.Num("deadline") > AudioService.Now;
        var currentMedia = !routeSuspended && audio.Renew(ownEntry, ready ? next.Str("group") : "", ready ? next.Num("deadline") : 0, next.Num("leaseRevision"));
        if (currentMedia && !ready && transcript.Pending is { } sending && transcript.Finish(sending, false)) DrawMessages();
        if (ready && audio.Permitted(ownEntry, next.Str("group")))
        {
            transcript.Activate();
            foreach (var joined in presence.Confirm(next.List("peers").Select(p => p.Str("id")), ownEntry)) App.Primary.Page.Sound(joined);
        }
        else if (next.Str("status") is "reconnecting" or "MEDIA_DISCONNECTED") { StopCues(); presence.Resynchronize(); }
        if (currentMedia && (!ready || next.Bool("muted"))) audio.StopCapture();
        else if (currentMedia && ready && !next.Bool("muted") && !audio.Capturing(next.Str("group")) && !changingMicrophone && captureFailedEntry != ownEntry)
        {
            try { audio.StartCapture(next.Str("group")); }
            catch (Exception e) { CaptureFailed(e.Message); }
        }
        foreach (var page in App.Pages) page.UpdateCallView(next);
    }
    private void UpdatePeerIndicators(JsonNode? roomCall)
    {
        foreach (var peer in roomCall.List("peers"))
            if (peerStatus.TryGetValue(peer.Str("id"), out var update)) update(peer);
    }

    private void UpdateCallView(JsonNode next)
    {
        UpdatePeerIndicators(next);
        var roster = string.Join(",", next.List("peers").Select(p =>
            p.Str("id") + p.Str("name") + p.Str("friendName") + p.Bool("trusted") + p.Str("root") + p.Str("key")));
        var fingerprint = string.Join("|", next.Str("room"), next.Str("status"), next.Bool("ready"), transcript.Activated, roster,
            next?["verification"]?.ToJsonString(), next.Bool("canRetryVerification"));
        if (fingerprint == lastRoomRender)
        {
            if (lastDockMuted != next.Bool("muted")) RenderDock();
            return;
        }
        if (lastRoomRender.Length == 0) BuildNav();
        lastRoomRender = fingerprint;
        if (selectionType == "room") Render();
        else RenderDock();
    }
    private async Task LoadThumbnail(string id, string base64, string entry, string revision)
    {
        try
        {
            var bytes = Convert.FromBase64String(base64);
            if (bytes.Length > 6144) return;
            Microsoft.UI.Xaml.Media.ImageSource image;
            try { image = await DecodeAttachmentForDisplay(bytes, 256); }
            finally { Array.Clear(bytes); }
            if (!AttachmentCurrent(entry, revision) || unavailableFiles.Contains(id)) return;
            thumbnails[id] = image;
            DrawMessages();
        }
        catch (Exception ex) when (ex is IOException or FormatException or ArgumentException or System.Runtime.InteropServices.COMException) { }
    }
    private void ClearChat()
    {
        transcript.Clear(); transfers.Clear(); thumbnails.Clear(); ResetAttachmentScope(); ResetDraft();
        foreach (var page in App.Pages)
        {
            page.Messages.Items.Clear();
            page.followChatEnd = true;
            page.lastChatOffset = 0;
            page.ChatEmpty.Visibility = Visibility.Visible;
            page.lastReadSequence = 0;
            page.showChat = null;
            page.chatClosing = false;
        }
    }
    private void ClearCall()
    {
        call = null; ownEntry = ""; captureFailedEntry = ""; nextPlaybackCheck = 0; presence.Reset(); StopCues(); audio.Reset(); ClearChat();
        foreach (var page in App.Pages)
        {
            page.lastRoomRender = "";
            page.RenderRoomVerificationNotice(null);
        }
    }
    private void SignedOut(bool restore = true, string? reason = null)
    {
        LogUI("login");
        directoryActive = false; directoryWatch = ""; directoryVisibility++;
        profiles.Reset();
        App.Primary.Page.refresh.Stop(); ClearCall(); member = directory = null; connection = null; lastDirectory = joiningKey = joiningRoom = ""; friends = new(); authGeneration++;
        foreach (var page in App.Pages)
        {
            Dialogs.Dismiss(page.XamlRoot);
            page.Stage.Children.Clear(); page.peerStatus.Clear(); page.Nav.MenuItems.Clear(); page.Nav.FooterMenuItems.Clear();
            page.SidebarAvatar.Content = null; page.SidebarName.Text = ""; page.RoomDock.Visibility = Visibility.Collapsed;
            page.UpdateLoginStage();
            page.LoginNotice.IsOpen = page.Notice.IsOpen = false;
            page.LoginNotice.Tag = page.Notice.Tag = null;
            page.StopMotions();
            page.Nav.Visibility = page.AuthActions.Visibility = Visibility.Collapsed; page.LoginGrid.Visibility = Visibility.Visible;
            if (reason is not null) page.Show(() => page.ErrorText(reason), InfoBarSeverity.Error, page.LoginNotice);
        }
        if (restore) _ = Run(RestoreConfirmed);
    }
    private bool CompactWorkspace => WorkspaceGrid.ActualWidth < 748;

    private void LayoutChat()
    {
        if (ChatPanel is null) return;
        var available = transcript.Activated && selectionType == "room" && call is not null && call.Str("room") == selected;
        var narrow = CompactWorkspace;
        var visible = available && (showChat ?? !narrow);
        var presented = visible || (available && chatClosing);
        if (visible) lastReadSequence = transcript.LatestSequence;
        var unread = transcript.UnreadAfter(lastReadSequence);
        ChatToggle.Visibility = Visible(available);
        syncingChatToggle = true;
        try { ChatToggle.IsChecked = visible; }
        finally { syncingChatToggle = false; }
        ChatToggleLabel.Text = T("聊天", "Chat");
        ChatUnread.Value = unread;
        ChatUnread.Visibility = Visible(unread != 0);
        AutomationProperties.SetName(ChatToggle, unread == 0 ? T("房间聊天", "Room chat") :
            T($"房间聊天，{unread} 条新消息", unread == 1 ? "Room chat, 1 new message" : $"Room chat, {unread} new messages"));
        ToolTipService.SetToolTip(ChatToggle, visible ? T("收起聊天 (Ctrl+Shift+B)", "Hide chat (Ctrl+Shift+B)") :
            T("打开聊天 (Ctrl+Shift+B)", "Show chat (Ctrl+Shift+B)"));
        StageScroll.Visibility = Visible(!(presented && narrow));
        var chatWidth = Math.Clamp(WorkspaceGrid.ActualWidth * 0.38, 320, 396);
        StageWidth.Width = new GridLength(presented && narrow ? 0 : 1, GridUnitType.Star);
        ChatWidth.Width = presented ? (narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(chatWidth)) : new GridLength(0);
        ChatPanel.Visibility = Visible(presented);
        ChatPanel.IsHitTestVisible = visible;
        ChatPanel.BorderThickness = narrow ? new Thickness(0) : new Thickness(1, 0, 0, 0);
        var shortPane = WorkspaceGrid.ActualHeight < 300;
        EmptyChatDetail.Visibility = ChatEmptyIcon.Visibility = Visible(!shortPane);
        ChatHeader.Padding = shortPane ? new Thickness(12, 8, 12, 8) : new Thickness(16, 14, 16, 12);
        ChatTitle.Visibility = Visible(!shortPane);
        ChatComposer.Padding = shortPane ? new Thickness(8) : new Thickness(12);
        Draft.MaxHeight = shortPane ? 64 : 100;
        Draft.IsEnabled = available;
        Attach.IsEnabled = available && !routeSuspended && call.Bool("ready") && !SendingAttachment;
        ChatInputHint.Visibility = Visible(!shortPane || routeSuspended || !call.Bool("ready"));
        ChatInputHint.Text = routeSuspended ? T("恢复音频后可继续发送。", "Resume audio to send messages.") :
            call.Str("status") == "verify" ? T("设备互认完成后可发送消息和附件。", "Verify devices to send messages and attachments.") :
            !call.Bool("ready") ? T("安全连接建立后可继续发送。", "You can send when the secure connection is ready.") :
            T("Enter 发送，Shift+Enter 换行", "Enter to send · Shift+Enter for a new line");
        UpdateSendButton();
    }

    private void ChatToggled(object sender, RoutedEventArgs args)
    {
        if (syncingChatToggle) return;
        showChat = ChatToggle.IsChecked == true;
        LogUI("roomChat", enabled: showChat == true);
        chatClosing = showChat == false && ChatPanel.Visibility == Visibility.Visible;
        LayoutChat();
        if (chatClosing)
            MoveSurface(ChatPanel, x: 16, leaving: true, finished: () =>
            {
                chatClosing = false;
                LayoutChat();
            });
        else if (ChatPanel.Visibility == Visibility.Visible)
            MoveSurface(ChatPanel, x: 20);
    }

    private void ChatShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ChatToggle.Visibility != Visibility.Visible) return;
        args.Handled = true;
        ChatToggle.IsChecked = ChatToggle.IsChecked != true;
        if (ChatToggle.IsChecked == true) Draft.Focus(FocusState.Keyboard);
        else ChatToggle.Focus(FocusState.Keyboard);
    }

    private void DrawMessages(bool followLocal = false)
    {
        foreach (var page in App.Pages) { page.LayoutChat(); page.DrawMessagesHere(followLocal); }
    }
    private void DrawMessagesHere(bool followLocal = false)
    {
        var scroller = ObserveChatScroller();
        var offset = scroller?.VerticalOffset ?? 0;
        var follow = followLocal || scroller is null || scroller.ScrollableHeight - offset < 100;
        Messages.Items.Clear();
        restoreButtons.Clear();
        Attach.IsEnabled = !routeSuspended && call.Bool("ready") && !SendingAttachment;
        if (preparingAttachment is { } preparing)
            Messages.Items.Add(Stack(Text(T("正在准备附件", "Preparing attachment")), ActionButton(T("取消准备", "Cancel preparation"), () => { preparing.Cancel(); return Task.CompletedTask; })));
        if (transcript.Trimmed) Messages.Items.Add(Text(T("较早的消息已清理，仅保留最近 1000 条。", "Earlier messages were removed. The latest 1,000 are kept.")));
        var visibleFiles = new HashSet<string>();
        foreach (var row in transcript.Messages)
        {
            var sender = Text(row.Mine ? T("你", "You") : row.Sender, 13, "ChirpHeading");
            sender.TextTrimming = TextTrimming.CharacterEllipsis;
            sender.MaxLines = 1;
            var time = Secondary(row.Time.ToLocalTime().ToString("t", DisplayCulture), 12);
            var content = Stack(Line(sender, trailing: time));
            content.Spacing = 4;
            if (row.File is { } file)
            {
                visibleFiles.Add(file.Str("id"));
                AddAttachmentActions(content, file);
            }
            else
            {
                var body = Text(row.Text);
                body.IsTextSelectionEnabled = true;
                content.Children.Add(body);
                AddDelivery(content, row);
            }
            Messages.Items.Add(new Border
            {
                Style = Design(row.Mine ? "ChirpOwnMessage" : "ChirpMessage"), Child = content,
                Margin = row.Mine ? new Thickness(20, 3, 1, 3) : new Thickness(1, 3, 20, 3)
            });
        }
        foreach (var (id, t) in transfers)
        {
            if (!visibleFiles.Contains(id) && (!t.Mine || t.Announced)) continue;
            var caption = t switch
            {
                { Terminal: true, Remote: "cancelled" } => T("发送方已取消附件", "The sender cancelled the attachment"),
                { Terminal: true } => t.Error.Length > 0 ? ErrorText(t.Error) : T("附件已不可用", "File unavailable"),
                { Cancelling: true } => T("正在确认取消", "Confirming cancellation"),
                { Running: true, Network: "paused" } => T("语音优先，传输已暂停", "Transfer paused for voice"),
                { Running: true, Network: "constrained" } => T("语音优先，正在低速传输", "Transferring at a reduced rate for voice"),
                { Running: true, Operation: "export" } => T("正在保存到文件夹", "Saving to folder"),
                { Running: true, Operation: "download", Progress: 100 } => T("正在验证附件", "Verifying attachment"),
                { Running: true } => (t.Operation == "upload" ? T("上传", "Uploading") : T("下载", "Downloading")) + " " + t.Progress + "%",
                { Error: "ATTACHMENT_PAUSED" } => T("下载已暂停", "Download paused"),
                { Error.Length: > 0 } => ErrorText(t.Error),
                { Complete: true, Remote: "delivered" } => T("服务器副本已删除，本地仍可用", "Server copy removed. Local copy available."),
                { Complete: true, Remote: "expired" } => T("服务器副本已过期，本地仍可用", "Server copy expired. Local copy available."),
                { Complete: true } => T("已完成", "Complete"),
                { Remote: "delivered" or "expired", Cached: false } => T("附件已不可用", "File unavailable"),
                { Remote: "paused" } => T("发送方已暂停上传", "The sender paused the upload"),
                { Remote: "completed" } => T("附件可下载", "Available to download"),
                _ => T("等待上传完成", "Waiting for upload")
            };
            var content = Stack(Text(t.Name + "  " + caption));
            if (t.CanPause) content.Children.Add(ActionButton(T("暂停下载", "Pause download"), () => FileAction("pauseFile", id)));
            if (t.CanRetry && (!t.Mine || !SendingAttachment)) content.Children.Add(ActionButton(t.Mine ? T("重试上传", "Retry upload") : T("继续下载", "Resume download"), () => FileAction("resumeFile", id)));
            if (t.CanCancel && !cancellationRequests.Contains((attachmentRevision, id))) content.Children.Add(ActionButton(t.Cancelling ? T("重试取消", "Retry cancellation") : T("取消上传", "Cancel upload"), () => CancelFile(id)));
            Messages.Items.Add(content);
        }
        ChatEmpty.Visibility = Visible(Messages.Items.Count == 0);
        if (Messages.Items.Count == 0) return;
        if (follow) Messages.ScrollIntoView(Messages.Items[^1]);
        else { Messages.UpdateLayout(); scroller?.ChangeView(null, offset, null, true); }
    }
    private async void SendClick(object sender, RoutedEventArgs args) => await Run(SendDraft);
    private async void DraftKey(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Enter || composing || InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down)) return;
        args.Handled = true; await Run(SendDraft);
    }
    private async void AttachClick(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        var entry = ownEntry;
        var revision = attachmentRevision;
        var group = call.Str("group");
        bool Current() => !closed && !routeSuspended && AttachmentCurrent(entry, revision) && call.Str("group") == group && call.Bool("ready");
        if (!Current() || SendingAttachment) return;
        var path = await LogPicker("selectFile", () => Dialogs.Open(Owner, "*"));
        if (path is null || !Current() || SendingAttachment) return;
        using var preparation = new CancellationTokenSource();
        preparingAttachment = preparation;
        DrawMessages();
        byte[]? thumbnail = null;
        try
        {
            thumbnail = await Images.Thumbnail(path, preparation.Token);
            if (!Current() || preparation.IsCancellationRequested) return;
            var result = await Rpc("upload", new { path, file = thumbnail, entry, revision, group });
            if (!AttachmentCurrent(result)) return;
            if (preparation.IsCancellationRequested) { await Rpc("cancelFile", new { id = result.Str("id"), entry, revision }); return; }
            transfers.TryAdd(result.Str("id"), new AttachmentStatus(Path.GetFileName(path), true));
            DrawMessages();
        }
        catch (OperationCanceledException) when (preparation.IsCancellationRequested) { }
        finally
        {
            if (thumbnail is not null) Array.Clear(thumbnail);
            if (preparingAttachment == preparation) preparingAttachment = null;
            DrawMessages();
        }
    });
}
