using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Chirp;

public sealed partial class MainPage
{
    private bool composing;
    private int compositionRevision;

    private void BeforeDraftChange(TextBox sender, TextBoxBeforeTextChangingEventArgs e)
    {
        if (DesktopText.FitsDraft(DesktopText.WireText(e.NewText))) return;
        e.Cancel = true; Show(() => SharedCopy.Error("CLIENT_CHAT_TEXT_TOO_LONG", english), InfoBarSeverity.Warning);
    }
    private void DraftChanged(object sender, TextChangedEventArgs e)
    {
        var value = DesktopText.WireText(Draft.Text);
        if (value == transcript.Draft) return;
        if (value.Length == 0 || transcript.Draft.Length == 0) LogUI(value.Length == 0 ? "clearDraft" : "compose");
        transcript.Draft = value;
        foreach (var page in App.Pages) { page.SynchronizeDraft(); page.UpdateRestoreButtons(); }
    }
    private readonly List<Button> restoreButtons = new();
    private void UpdateRestoreButtons() { foreach (var button in restoreButtons) button.IsEnabled = transcript.Draft.Length == 0; }
    private void UpdateSendButton() => SendChat.IsEnabled = !routeSuspended && call.Bool("ready") && transcript.CanSend;
    private void SynchronizeDraft()
    {
        if (DesktopText.WireText(Draft.Text) != transcript.Draft) Draft.Text = transcript.Draft;
        UpdateSendButton();
    }
    private void CompositionStarted(TextBox sender, TextCompositionStartedEventArgs e) { compositionRevision++; composing = true; }
    private void CompositionEnded(TextBox sender, TextCompositionEndedEventArgs e)
    {
        var revision = compositionRevision;
        DispatcherQueue.TryEnqueue(() => { if (compositionRevision == revision) composing = false; });
    }
    private static void ResetDraft()
    {
        foreach (var page in App.Pages) { page.restoreButtons.Clear(); page.SynchronizeDraft(); }
    }
    private static ScrollViewer? FindScroller(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            if (FindScroller(VisualTreeHelper.GetChild(root, i)) is { } child) return child;
        return null;
    }
    private bool followChatEnd = true;
    private double lastChatOffset;
    private ScrollViewer? chatScroller;
    private ScrollViewer? ObserveChatScroller()
    {
        var scroll = FindScroller(Messages);
        if (chatScroller == scroll) return scroll;
        if (chatScroller is not null) chatScroller.ViewChanged -= ChatViewChanged;
        chatScroller = scroll;
        if (scroll is not null) scroll.ViewChanged += ChatViewChanged;
        return scroll;
    }
    private void ChatViewChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (sender is not ScrollViewer scroll || scroll.VerticalOffset == lastChatOffset) return;
        lastChatOffset = scroll.VerticalOffset;
        followChatEnd = scroll.ScrollableHeight - lastChatOffset <= 16;
    }
    private void ChatViewportResized(object sender, SizeChangedEventArgs args)
    {
        var scroll = ObserveChatScroller();
        if (scroll is null || !followChatEnd || args.NewSize.Height <= 0 || Messages.Items.Count == 0) return;
        // The list calculates its final extent after text reflows at the new width.
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (followChatEnd && ChatPanel.Visibility == Visibility.Visible && scroll == chatScroller)
                scroll.ChangeView(null, scroll.ScrollableHeight, null, true);
        });
    }
    private void AddDelivery(StackPanel content, ChatTimeline.Message row)
    {
        if (row.Status == ChatTimeline.Delivery.Sending) content.Children.Add(Text(T("正在发送", "Sending")));
        if (row.Status != ChatTimeline.Delivery.Failed) return;
        content.Children.Add(Text(T("发送失败", "Failed to send")));
        var restore = ActionButton(T("恢复到草稿", "Restore to draft"), () =>
        {
            if (transcript.Restore(row, ownEntry))
            {
                LogUI("restoreDraft");
                foreach (var page in App.Pages) { page.SynchronizeDraft(); page.UpdateRestoreButtons(); }
            }
            return Task.CompletedTask;
        });
        restore.IsEnabled = transcript.Draft.Length == 0; restoreButtons.Add(restore); content.Children.Add(restore);
    }
    private async Task SendDraft()
    {
        if (composing || routeSuspended || !call.Bool("ready") || transcript.Begin(ownEntry, T("你", "You")) is not { } row) return;
        foreach (var page in App.Pages) page.SynchronizeDraft();
        DrawMessages(followLocal: true);
        try
        {
            await Rpc("chat", new { entry = row.Entry, group = call.Str("group"), text = row.Text });
            transcript.Finish(row, true);
        }
        catch { if (transcript.Finish(row, false)) throw; }
        finally
        {
            if (ownEntry == row.Entry)
            {
                DrawMessages();
                foreach (var page in App.Pages) page.UpdateSendButton();
            }
        }
    }
}
