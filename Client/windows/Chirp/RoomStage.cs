using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;

namespace Chirp;

public sealed partial class MainPage
{
    private static bool HasPresence(JsonNode? room) => !directoryStale && room.Str("media_status") == "available";

    private string RoomPresenceLabel(JsonNode? room)
    {
        if (!HasPresence(room)) return T("在线状态待同步", "Presence unavailable");
        var count = room.List("participants").Count;
        return count == 0 ? T("暂无成员", "No one in the room") : MemberCount(count);
    }

    private string MemberCount(int count) => T($"{count} 位成员", count == 1 ? "1 member" : $"{count} members");

    private string verificationMessage = "";

    private void FitVerificationNotice()
    {
        if (!RoomVerificationNotice.IsOpen) return;
        var compact = ActualHeight > 0 && ActualHeight < 560 && VerificationTargets.Children.Count > 0;
        VerificationActions.MaxHeight = compact ? 36 : 88;
        RoomVerificationNotice.Message = compact ? "" : verificationMessage;
        AutomationProperties.SetHelpText(RoomVerificationNotice, compact ? verificationMessage : "");
    }

    private void RenderRoomVerificationNotice(JsonNode? roomCall)
    {
        var pending = roomCall.Str("status") == "verify";
        VisualStateManager.GoToState(this, pending ? "RoomAwaitingVerification" : "NormalRoom", false);
        VerificationTargets.Children.Clear();
        if (!pending)
        {
            RoomVerificationNotice.IsOpen = false;
            RoomVerificationNotice.Visibility = Visibility.Collapsed;
            return;
        }

        var entry = roomCall.Str("entry");
        var targets = roomCall.List("peers").OfType<JsonObject>()
            .Where(p => !p.Bool("self") && !p.Bool("trusted"))
            .Select(p => (Peer: p, Name: DisplayName(p.Str("id"), p.Str("name"))))
            .OrderBy(target => target.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
        var verification = roomCall?["verification"];
        var busy = verification.Str("Step") == "peerBusy";
        var verifying = verification is not null && !busy;
        if (busy && targets.Any(target => target.Peer.Str("id") == verification.Str("Peer")))
        {
            var name = DisplayName(verification.Str("Peer"), verification.Str("Name"));
            RoomVerificationNotice.Title = T($"对方正忙 · {name}", $"{name} is busy");
            verificationMessage = targets.Length > 1
                ? T("请稍后重新邀请，也可以先核验其他成员。", "Try inviting them again later, or verify another participant.")
                : T("请稍后重新邀请。", "Try inviting them again later.");
        }
        else if (targets.Length == 0)
        {
            RoomVerificationNotice.Title = L("等待其他成员互认");
            verificationMessage = L("你已核验房间内的设备。正在等待其他成员完成互认或同步结果。");
        }
        else
        {
            RoomVerificationNotice.Title = T($"有 {targets.Length} 台设备待核验", targets.Length == 1 ? "1 device needs verification" : $"{targets.Length} devices need verification");
            verificationMessage = verifying
                ? T("语音和聊天已暂停。请先完成当前核验。", "Voice and chat are paused. Finish the current verification first.")
                : T("语音和聊天已暂停。选择成员，核对双方设备上的三组安全码。", "Voice and chat are paused. Choose a participant to compare the three security codes.");
        }
        if (verifying)
        {
            var current = ActionButton(T("查看当前核验", "View current verification"), () =>
            {
                RevealVerification();
                return Task.CompletedTask;
            });
            current.MinHeight = 32;
            VerificationTargets.Children.Add(current);
        }
        var byName = targets.ToLookup(target => target.Name, StringComparer.CurrentCultureIgnoreCase);
        foreach (var (peer, name) in targets)
        {
            var deviceName = byName[name].Count() > 1 && DesktopText.Fingerprint(peer.Str("key")) is { Length: >= 8 } fingerprint
                ? $"{name} · {fingerprint[..8]}" : name;
            var retryID = busy && peer.Str("id") == verification.Str("Peer") ? verification.Str("ID") : null;
            var label = retryID is null ? T($"核验 {deviceName}", $"Verify {deviceName}") :
                T($"重新邀请 {deviceName}", $"Invite {deviceName} again");
            var button = ActionButton(label, () => VerifyRoomPeer(entry, peer, retryID));
            button.Content = new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis };
            button.MaxWidth = 260;
            button.MinHeight = 32;
            button.IsEnabled = CanInvitePeer(peer.Str("id"), retryID);
            Label(button, label);
            VerificationTargets.Children.Add(button);
        }
        VerificationActions.Visibility = Visible(VerificationTargets.Children.Count != 0);
        RoomVerificationNotice.Visibility = Visibility.Visible;
        RoomVerificationNotice.IsOpen = true;
        FitVerificationNotice();
    }

    private void RevealVerification()
    {
        if (CompactWorkspace && ChatPanel.Visibility == Visibility.Visible)
        {
            showChat = false;
            chatClosing = false;
            LayoutChat();
        }
        StageScroll.ChangeView(null, 0, null, true);
    }

    private bool CanInvitePeer(string peer, string? retryID)
    {
        var current = call?["verification"];
        if (retryID is not null)
            return call.Bool("canRetryVerification") && current.Str("Peer") == peer && current.Str("ID") == retryID;
        return current is null || current.Str("Step") == "peerBusy" && current.Str("Peer") != peer;
    }

    private async Task VerifyRoomPeer(string entry, JsonObject target, string? retryID = null)
    {
        if (selectionType != "room" || selected != call.Str("room") || ownEntry != entry ||
            call.Str("status") != "verify") return;
        var id = target.Str("id");
        var peer = call.List("peers").FirstOrDefault(p => p.Str("id") == id);
        if (!CanInvitePeer(id, retryID) || peer is null || peer.Bool("self") || peer.Bool("trusted") ||
            peer.Str("key") != target.Str("key") || peer.Str("root") != target.Str("root")) return;
        RevealVerification();
        await Rpc("verify", new { action = retryID is null ? "start" : "retry", peer = id, id = retryID });
    }

    private string CallStatus() => routeSuspended ? T("系统音频已中断", "System audio interrupted")
        : call.Bool("ready") ? T("加密通话已就绪", "Encrypted call ready")
        : call.Str("status") switch
        {
            "verify" => T("等待成员互相验证", "Waiting for mutual verification"),
            "securing" => T("正在建立安全连接", "Establishing a secure connection"),
            "connecting" or "" => T("正在建立语音连接", "Connecting to voice"),
            "reconnecting" => T("连接暂时中断，正在重试…", "Connection interrupted. Reconnecting…"),
            "audioInterrupted" => T("系统音频已中断", "System audio interrupted"),
            "paused" => T("通话已暂停", "Call paused"),
            var other => ErrorText(other)
        };

    private void RenderRoom(JsonNode room)
    {
        var joined = call.Str("room") == selected;
        if (!joined && call is not null)
        {
            var switchRoom = ActionButton(T("切换到此房间", "Switch to this room"), () => Join(room), true, "\uE717");
            switchRoom.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = VirtualKey.Enter, Modifiers = VirtualKeyModifiers.Control });
            switchRoom.IsEnabled = joiningKey.Length == 0;
            Stage.Children.Add(Card(Heading(T("切换房间", "Switch rooms"), 17),
                Secondary(T("新房间通过入房检查后会接替当前通话，麦克风默认静音。",
                    "After access is verified, you’ll move to the new room with your microphone muted.")), switchRoom));
        }

        var members = joined ? call.List("peers") : room.List("participants");
        var known = joined || HasPresence(room);
        if (joined && call?["verification"] is JsonObject verification)
            RenderVerification(verification);
        else if (!known)
            Stage.Children.Add(new InfoBar
            {
                IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational,
                Message = members.Count > 0
                    ? T("暂时无法取得最新成员，当前显示上次同步的名单。", "Live presence is unavailable. Showing the last known roster.")
                    : T("暂时无法取得最新成员，稍后会自动更新。", "Live presence is unavailable. The roster will update automatically.")
            });

        var rosterTitle = Heading(T("房间成员", "Participants"), 18);
        Stage.Children.Add(Line(rosterTitle, trailing: known ? Secondary(MemberCount(members.Count)) : null));
        if (members.Count == 1)
            Stage.Children.Add(MemberTile(members[0], joined, solo: true));
        else if (members.Count > 1)
        {
            var tiles = new List<UIElement>(members.Count);
            foreach (var person in members) tiles.Add(MemberTile(person, joined));
            Stage.Children.Add(new ItemsRepeater
            {
                ItemsSource = tiles,
                Layout = new UniformGridLayout
                {
                    MinItemWidth = 174, MinRowSpacing = 12, MinColumnSpacing = 12,
                    ItemsStretch = UniformGridLayoutItemsStretch.Fill, Orientation = Orientation.Horizontal
                }
            });
        }
        else
        {
            var title = joined ? T("正在为你连接", "Connecting you") : known ? T("房间里还没有人", "No one is in this room") : T("等待房间状态", "Waiting for room status");
            var detail = joined ? CallStatus() : known
                ? T("你可以先静音加入，等朋友进来。", "Join with your microphone muted and wait for a friend.")
                : T("连接恢复后会自动更新成员名单。", "Participants will appear when the connection resumes.");
            var copy = Stack(IconTile("\uE716"), Heading(title, 21), Secondary(detail, 14));
            copy.HorizontalAlignment = HorizontalAlignment.Center;
            foreach (var child in copy.Children.OfType<TextBlock>()) child.TextAlignment = TextAlignment.Center;
            Stage.Children.Add(new Border { Style = Design("ChirpCard"), Padding = new Thickness(20, 34, 20, 34), Child = copy });
        }
    }

    private FrameworkElement MemberTile(JsonNode? person, bool joined, bool solo = false)
    {
        var id = person.Str("id");
        var name = DisplayName(id, person.Str(joined ? "name" : "display_name"));
        var self = joined && person.Bool("self");
        var title = Text(name + (self ? T("（你）", " (you)") : ""), solo ? 21 : 16, "ChirpHeading");
        title.TextAlignment = TextAlignment.Center;
        title.MaxLines = 2;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var status = Secondary(joined ? PeerIdentityStatus(person) : T("已加入房间", "In the room"), 12);
        status.TextAlignment = TextAlignment.Center;
        var avatarSize = solo ? 72 : 50;
        var portrait = new Grid { Width = avatarSize + 32, Height = avatarSize + 32, HorizontalAlignment = HorizontalAlignment.Center };
        portrait.Children.Add(ProfilePicture(id, avatarSize, name));
        var copy = Stack(title, status);
        copy.Spacing = 3;
        var identity = Stack(portrait, copy);
        identity.Spacing = solo ? 10 : 5;
        var tile = new Grid { Padding = new Thickness(4, solo ? 18 : 6, 4, solo ? 18 : 6) };
        tile.Children.Add(identity);
        if (!joined) return new Border { Style = Design("ChirpCard"), Padding = new Thickness(12), Child = tile };
        var audioStatus = MemberAudioIndicators(showLabels: false);
        identity.Children.Add(audioStatus.View);
        var chevron = Glyph("\uE76C", 12);
        chevron.HorizontalAlignment = HorizontalAlignment.Right;
        chevron.VerticalAlignment = VerticalAlignment.Top;
        tile.Children.Add(chevron);
        var halo = new SpeakingHalo();
        portrait.Children.Add(halo);
        var button = ActionButton(name, () => MemberInfo(id));
        button.Style = Design("ChirpSurfaceButton");
        button.Content = tile;
        var action = self ? T("成员信息", "Participant details") : T("成员信息与音量", "Participant details and volume");
        AutomationProperties.SetName(button, name + " · " + action);
        ToolTipService.SetToolTip(button, action);
        var wasSpeaking = false;
        void Update(JsonNode? current)
        {
            var audioSummary = audioStatus.Update(current);
            var speaking = IsSpeaking(current);
            halo.Update(speaking, motionSettings.AnimationsEnabled);
            if (wasSpeaking != speaking)
            {
                button.Style = Design(speaking ? "ChirpSpeakingTile" : "ChirpSurfaceButton");
                wasSpeaking = speaking;
            }
            AutomationProperties.SetHelpText(button, status.Text + " · " + audioSummary);
        }
        peerStatus[id] = Update;
        Update(person);
        return button;
    }

    private readonly HashSet<Button> pendingDockActions = new();
    private bool lastDockMuted;

    private void RenderDock()
    {
        var joined = call is not null;
        var room = selectionType == "room" ? SelectedRoom() : null;
        RoomDock.Visibility = Visible(joined || room is not null);
        if (RoomDock.Visibility == Visibility.Collapsed) return;

        var joining = joiningKey.Length > 0;
        var here = joined && selectionType == "room" && selected == call.Str("room");
        var muted = lastDockMuted = call.Bool("muted");
        var ready = call.Bool("ready") && !routeSuspended;
        var activeName = here ? "" : directory.List("rooms").FirstOrDefault(r => r.Str("room_id") == call.Str("room")).Str("display_name");
        DockStatusIcon.Glyph = !joined ? "\uE717" : routeSuspended ? "\uE7BA" : !ready ? "\uE72E" : muted ? "\uEC54" : "\uE720";
        if (joined)
        {
            var microphone = muted ? T("麦克风已静音", "Microphone muted") : ready
                ? T("麦克风已开启", "Microphone on") : T("麦克风暂停发送", "Microphone transmission paused");
            DockTitle.Text = activeName.Length > 0 ? activeName : CallStatus();
            DockDetail.Text = activeName.Length > 0 ? $"{CallStatus()} · {microphone}" : microphone;
        }
        else
        {
            DockTitle.Text = joining && room.Str("room_id") == joiningRoom
                ? T("正在加入房间…", "Joining the room…") : T("加入语音通话", "Join voice");
            DockDetail.Text = T("入房麦克风默认静音", "Your microphone starts muted");
        }
        var pendingMic = pendingDockActions.Contains(DockMic);
        var leaving = pendingDockActions.Contains(DockLeave);
        var resuming = resumingAudio || pendingDockActions.Contains(DockResume);
        var pending = joining || pendingMic || leaving || resuming || joined && !routeSuspended &&
            call.Str("status") is "connecting" or "reconnecting" or "securing";
        DockProgress.IsActive = pending;
        DockProgress.Visibility = Visible(pending);
        DockStatusIcon.Visibility = Visible(!pending);
        if (leaving) DockDetail.Text = L("正在离开语音");
        else if (resuming) DockDetail.Text = L("正在恢复音频与安全连接");
        else if (pendingMic) DockDetail.Text = L("正在更新麦克风");
        DockResume.Content = T("恢复音频", "Resume audio");
        DockCancel.Content = T("取消加入", "Cancel joining");
        ButtonLabel(DockJoin, T("加入房间", "Join room"), "\uE717");
        ButtonLabel(DockMic, muted ? T("开启麦克风", "Unmute") : T("静音", "Mute"), muted ? "\uE720" : "\uEC54");
        ButtonLabel(DockLeave, T("离开房间", "Leave room"), "\uE778");
        void Present(Button button, bool visible, bool enabled = true)
        {
            button.Visibility = Visible(visible);
            button.IsEnabled = enabled && !pendingDockActions.Contains(button);
        }
        Present(DockAudio, true);
        Present(DockResume, joined && routeSuspended, !resumingAudio);
        Present(DockCancel, joining);
        Present(DockJoin, !joined, !joining);
        Present(DockMic, joined, ready);
        Present(DockLeave, joined);
        FitDock();
    }

    private async void DockActionClick(object sender, RoutedEventArgs args)
    {
        var button = (Button)sender;
        if (!button.IsEnabled || !pendingDockActions.Add(button)) return;
        RenderDock();
        try
        {
            await Run(button.Name switch
            {
                nameof(DockAudio) => AudioSettings,
                nameof(DockResume) => ResumeAudio,
                nameof(DockCancel) => CancelJoin,
                nameof(DockJoin) => () => SelectedRoom() is { } room ? Join(room) : Task.CompletedTask,
                nameof(DockMic) => Mute,
                nameof(DockLeave) => Leave,
                _ => throw new InvalidOperationException()
            });
        }
        finally
        {
            pendingDockActions.Remove(button);
            if (!closed) RenderDock();
        }
    }

    private void DockResized(object sender, SizeChangedEventArgs e) => FitDock();

    private void FitDock()
    {
        if (DockCommands is null || DockLayout.ActualWidth <= 0) return;
        var unconstrained = new Size(double.PositiveInfinity, double.PositiveInfinity);
        DockCommands.Measure(unconstrained);
        DockStatus.Measure(unconstrained);
        var stacked = DockLayout.ActualWidth < DockCommands.DesiredSize.Width + DockLayout.ColumnSpacing + Math.Min(270, DockStatus.DesiredSize.Width);
        Grid.SetColumn(DockCommands, stacked ? 0 : 1);
        Grid.SetColumnSpan(DockCommands, stacked ? 2 : 1);
        Grid.SetRow(DockCommands, stacked ? 1 : 0);
        Grid.SetColumnSpan(DockStatus, stacked ? 2 : 1);
        DockLayout.RowSpacing = stacked ? 8 : 0;
    }
}
