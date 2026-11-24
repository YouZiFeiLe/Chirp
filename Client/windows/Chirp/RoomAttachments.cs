using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace Chirp;

public sealed partial class MainPage
{
    private static string attachmentRevision = "";
    private static string clearingRevision = "";
    private static CancellationTokenSource? preparingAttachment;
    private static bool SendingAttachment => preparingAttachment is not null || transfers.Values.Any(t => t.Running && t.Operation == "upload");
    private static readonly HashSet<(string Revision, string Id)> cancellationRequests = new();
    private static void StopAttachmentPreparation()
    {
        var previous = preparingAttachment;
        preparingAttachment = null;
        previous?.Cancel();
    }
    private static readonly HashSet<string> retiredRevisions = new();
    private static readonly HashSet<string> unavailableFiles = new();
    private ContentDialog? attachmentPreview;
    private string previewId = "";

    private static bool AttachmentCurrent(string entry, string revision) =>
        entry.Length != 0 && revision.Length != 0 && entry == ownEntry && revision == attachmentRevision && clearingRevision.Length == 0;
    private static bool AttachmentCurrent(JsonNode? data) => AttachmentCurrent(data.Str("entry"), data.Str("revision"));

    private void ApplyAttachmentScope(JsonNode? room)
    {
        var next = room.Str("cacheRevision");
        if (next.Length == 0 || retiredRevisions.Contains(next) || clearingRevision.Length != 0) return;
        if (attachmentRevision.Length != 0 && attachmentRevision != next) RetireAttachments(attachmentRevision);
        attachmentRevision = next;
    }

    private static void ResetAttachmentScope()
    {
        StopAttachmentPreparation();
        attachmentRevision = clearingRevision = "";
        retiredRevisions.Clear();
        unavailableFiles.Clear();
        ClosePreviews();
    }

    private static void ClosePreviews(string? id = null)
    {
        foreach (var page in App.Pages)
            if (id is null || page.previewId == id) page.attachmentPreview?.Hide();
    }

    private static void RetireAttachments(string previous)
    {
        StopAttachmentPreparation();
        if (previous.Length != 0) retiredRevisions.Add(previous);
        ClosePreviews();
        thumbnails.Clear();
        transfers.Clear();
        unavailableFiles.Clear();
        transcript.RemoveFiles();
    }

    private async Task<bool> ClearAttachmentCache(string entry, string revision)
    {
        if (entry.Length == 0 && revision.Length == 0 && ownEntry.Length == 0 && call is null)
        {
            await Rpc("clearCache", new { entry, revision });
            return true;
        }
        if (!AttachmentCurrent(entry, revision)) return false;
        clearingRevision = revision;
        StopAttachmentPreparation();
        ClosePreviews();
        try
        {
            var result = await Rpc("clearCache", new { entry, revision });
            if (entry == ownEntry && clearingRevision == revision)
            {
                RetireAttachments(revision);
                attachmentRevision = result.Str("revision");
            }
            return entry == ownEntry && result.Str("revision") == attachmentRevision;
        }
        finally
        {
            if (clearingRevision == revision) clearingRevision = "";
            DrawMessages();
        }
    }

    private void ApplyTransfer(JsonNode? update)
    {
        if (update is null || !AttachmentCurrent(update)) return;
        var id = update.Str("id");
        var last = transfers.GetValueOrDefault(id) ?? new AttachmentStatus("", false);
        var state = last.Apply(update);
        if (ReferenceEquals(last, state)) return;
        transfers[id] = state;
        if (state.Terminal)
        {
            unavailableFiles.Add(id); ClosePreviews(id); thumbnails.Remove(id);
        }
        DrawMessages();
    }

    private Task<JsonNode?> FileAction(string op, string id) =>
        Rpc(op, new { id, entry = ownEntry, revision = attachmentRevision });

    private async Task CancelFile(string id)
    {
        if (!transfers.TryGetValue(id, out var state) || !state.CanCancel) return;
        var request = (attachmentRevision, id);
        if (!cancellationRequests.Add(request)) return;
        DrawMessages();
        try { await FileAction("cancelFile", id); }
        finally { cancellationRequests.Remove(request); DrawMessages(); }
    }

    private void AddAttachmentActions(StackPanel content, JsonNode file)
    {
        var id = file.Str("id");
        var name = file.Str("name");
        if (thumbnails.TryGetValue(id, out var thumbnail))
        {
            var image = new Image { Source = thumbnail, MaxHeight = 100, MaxWidth = 150, HorizontalAlignment = HorizontalAlignment.Left };
            if (transfers.GetValueOrDefault(id)?.CanOpen == true)
                image.Tapped += async (_, _) => await Run(() => PreviewAttachment(id, name));
            content.Children.Add(image);
        }
        content.Children.Add(Text(name + " · " + Math.Ceiling(file.Num("size") / 1024d) + " KB"));
        if (unavailableFiles.Contains(id) || !AttachmentCurrent(ownEntry, attachmentRevision) || transfers.GetValueOrDefault(id)?.CanOpen != true) return;
        if (file.Str("mimeType") is "image/jpeg" or "image/png" or "image/gif" or "image/webp" or "image/heic" or "image/heif")
            content.Children.Add(ActionButton(T("预览原图", "Preview image"), () => PreviewAttachment(id, name)));
        content.Children.Add(ActionButton(T("保存到文件夹", "Save to folder"), async () =>
        {
            var entry = ownEntry; var revision = attachmentRevision;
            var ready = await Rpc("prepareExport", new { id, entry, revision });
            if (closed || !AttachmentCurrent(ready) || unavailableFiles.Contains(id)) return;
            var folder = await LogPicker("exportAttachment", () => Dialogs.Folder(Owner));
            if (closed || folder is null || !AttachmentCurrent(entry, revision) || unavailableFiles.Contains(id)) return;
            await Rpc("download", new { id, entry, revision, path = Path.Combine(folder, ready.Str("name")) });
        }));
    }

    private static async Task<Microsoft.UI.Xaml.Media.Imaging.SoftwareBitmapSource> DecodeAttachmentForDisplay(byte[] bytes, int side)
    {
        using var bitmap = await Images.AttachmentImage(bytes, side);
        var source = new Microsoft.UI.Xaml.Media.Imaging.SoftwareBitmapSource();
        await source.SetBitmapAsync(bitmap);
        return source;
    }

    private async Task PreviewAttachment(string id, string name)
    {
        using var screen = LogScreen("attachmentPreview");
        var entry = ownEntry; var revision = attachmentRevision;
        var result = await FileAction("previewFile", id);
        if (closed || !AttachmentCurrent(entry, revision) || !AttachmentCurrent(result) || unavailableFiles.Contains(id)) return;
        var bytes = Convert.FromBase64String(result.Str("file"));
        var view = new Image { MaxWidth = 920, MaxHeight = 640 };
        try { view.Source = await DecodeAttachmentForDisplay(bytes, 2048); }
        finally { Array.Clear(bytes); }
        if (closed || !AttachmentCurrent(entry, revision) || unavailableFiles.Contains(id)) return;
        var dialog = Dialogs.Box(XamlRoot, name, view, T("关闭", "Close"));
        previewId = id; attachmentPreview = dialog;
        try { await dialog.ShowAsync(); }
        finally { view.Source = null; attachmentPreview = null; previewId = ""; }
    }
}
