using Microsoft.UI.Xaml;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using Microsoft.Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace Chirp;

internal static class Dialogs
{
    private static readonly Dictionary<XamlRoot, (ContentDialog Box, InfoBar Notice)> dialogs = new();
    public static ContentDialog Box(XamlRoot root, string title, FrameworkElement content, string close, string primary = "")
    {
        var notice = new InfoBar { IsOpen = false, IsClosable = true };
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition());
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.Children.Add(content);
        Grid.SetRow(notice, 1);
        layout.Children.Add(notice);
        var box = new ContentDialog { XamlRoot = root, Title = title, Content = layout, CloseButtonText = close, PrimaryButtonText = primary, DefaultButton = ContentDialogButton.None };
        if (root.Content is FrameworkElement owner) box.RequestedTheme = owner.RequestedTheme;
        if (App.Pages.FirstOrDefault(page => page.XamlRoot == root) is { } page) box.Language = page.Language;
        box.Opened += (_, _) => dialogs[root] = (box, notice);
        box.Closed += (_, _) => { if (dialogs.GetValueOrDefault(root).Box == box) dialogs.Remove(root); };
        return box;
    }
    internal static void Dismiss(XamlRoot? root)
    {
        if (root is not null && dialogs.TryGetValue(root, out var dialog)) dialog.Box.Hide();
    }
    internal static InfoBar? NoticeFor(XamlRoot? root) =>
        root is not null && dialogs.TryGetValue(root, out var dialog) ? dialog.Notice : null;

    public static async Task<string?> Open(MainWindow owner, params string[] extensions)
    {
        var p = new FileOpenPicker(owner.AppWindow.Id);
        foreach (var extension in extensions) p.FileTypeFilter.Add(extension);
        return (await p.PickSingleFileAsync())?.Path;
    }
    public static async Task<string?> Folder(MainWindow owner)
    {
        var picker = new FolderPicker(owner.AppWindow.Id);
        return (await picker.PickSingleFolderAsync())?.Path;
    }
    public static async Task<string?> Save(MainWindow owner, string filename, string extension)
    {
        var picker = new FileSavePicker(owner.AppWindow.Id) { DefaultFileExtension = extension };
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(filename);
        picker.FileTypeChoices.Add(extension, new List<string> { extension }); return (await picker.PickSaveFileAsync())?.Path;
    }
    public static async Task<byte[]> ReadLimited(string path, int limit)
    {
        using var file = File.OpenRead(path); if (file.Length > limit) throw new IOException("FILE_TOO_LARGE");
        var bytes = new byte[(int)file.Length]; await file.ReadExactlyAsync(bytes); return bytes;
    }
    public static Task<Image> Qr(string value) => Image(QrBytes(value), 236);
    public static byte[] QrBytes(string value)
    {
        using var data = QRCodeGenerator.GenerateQrCode(value, QRCodeGenerator.ECCLevel.M);
        using var qr = new PngByteQRCode(data); return qr.GetGraphic(6);
    }
    internal static async Task<BitmapImage> Bitmap(byte[] data)
    {
        using var stream = new InMemoryRandomAccessStream(); await stream.WriteAsync(data.AsBuffer()); stream.Seek(0);
        var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); return bitmap;
    }
    public static async Task<Image> Image(byte[] png, double size) => new() { Source = await Bitmap(png), Width = size, Height = size };
}
