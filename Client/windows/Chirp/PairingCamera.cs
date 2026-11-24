using Microsoft.UI.Xaml.Controls;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace Chirp;

public sealed partial class MainPage
{
    private sealed record PairingInput(string Code, bool Imported);
    private async Task<PairingInput?> PairingCode()
    {
        var title = T("读取新设备配对码", "Read the new device's pairing code");
        var entry = new TextBox { Header = T("也可以粘贴配对码", "Or paste a pairing code"), MaxLength = 4096 };
        var camera = false;
        var panel = Stack(Secondary(L("仅批准您本人持有的新设备。图片在本机识别，不上传服务器；导入图片必须核对新设备当前显示的安全码。")), entry);
        var chooser = Dialogs.Box(XamlRoot, title, panel, T("取消", "Cancel"), T("使用配对码", "Use code"));
        chooser.IsPrimaryButtonEnabled = false;
        entry.TextChanged += (_, _) => chooser.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(entry.Text);
        chooser.SecondaryButtonText = T("导入二维码图片", "Open QR image");
        panel.Children.Insert(1, ActionButton(T("用摄像头扫描", "Scan with camera"), () => { camera = true; chooser.Hide(); return Task.CompletedTask; }));
        var action = await chooser.ShowAsync();
        if (camera)
        {
            using var screen = LogScreen("pairingCamera");
            using var capture = new MediaCapture();
            try { await capture.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = StreamingCaptureMode.Video, MemoryPreference = MediaCaptureMemoryPreference.Cpu }); }
            catch (Exception ex) when (ex is UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
            { throw new IOException("CAMERA_UNAVAILABLE", ex); }
            var source = capture.FrameSources.Values.FirstOrDefault(x => x.Info.SourceKind == MediaFrameSourceKind.Color && x.Info.MediaStreamType == MediaStreamType.VideoPreview)
                ?? capture.FrameSources.Values.FirstOrDefault(x => x.Info.SourceKind == MediaFrameSourceKind.Color);
            if (source is null) throw new IOException("CAMERA_UNAVAILABLE");
            using var video = MediaSource.CreateFromMediaFrameSource(source);
            using var player = new MediaPlayer { Source = video, AutoPlay = true };
            var preview = new MediaPlayerElement { AreTransportControlsEnabled = false, Height = 240 }; preview.SetMediaPlayer(player);
            var reader = Dialogs.Box(XamlRoot, title, Stack(preview, Secondary(L("请扫描您本人新设备当前显示的 Chirp 设备授权二维码。扫描后仍需核对安全码并确认批准。"))), T("取消", "Cancel"), T("手动读取", "Read manually"));
            using var stop = new CancellationTokenSource();
            string? scanned = null;
            reader.Closing += (_, _) => stop.Cancel();
            try
            {
                var showing = reader.ShowAsync();
                var scanning = ScanFrames(capture, source, stop.Token, value => { scanned = value; reader.Hide(); });
                ContentDialogResult choice;
                try { choice = await showing; }
                finally { stop.Cancel(); await scanning; }
                if (scanned is not null) return new(scanned, false);
                if (choice != ContentDialogResult.Primary) return null;
                using var stream = new InMemoryRandomAccessStream();
                await capture.CapturePhotoToStreamAsync(ImageEncodingProperties.CreateJpeg(), stream);
                return new(await PairingImages.Read(stream, false), false);
            }
            finally { preview.SetMediaPlayer(null); }
        }
        if (action == ContentDialogResult.Primary) return new(entry.Text.Trim(), true);
        if (action != ContentDialogResult.Secondary || await LogPicker("selectPairingImage", () => Dialogs.Open(Owner, "*")) is not { } path) return null;
        return new(await PairingImages.ReadFile(path), true);
    }

    private static async Task ScanFrames(MediaCapture capture, MediaFrameSource source, CancellationToken stop, Action<string> found)
    {
        try
        {
            var format = source.CurrentFormat.VideoFormat;
            if (format is null || format.Width == 0 || format.Height == 0) return;
            var scale = Math.Min(1, 1600d / Math.Max(format.Width, format.Height));
            var size = new BitmapSize { Width = (uint)Math.Max(1, format.Width * scale), Height = (uint)Math.Max(1, format.Height * scale) };
            using var frames = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Argb32, size);
            if (stop.IsCancellationRequested || await frames.StartAsync() != MediaFrameReaderStartStatus.Success) return;
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    await Task.Delay(250, stop);
                    using var frame = frames.TryAcquireLatestFrame();
                    using var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
                    if (bitmap is null) continue;
                    var code = await Task.Run(() => PairingImages.ReadFrame(bitmap), stop);
                    if (code is null || stop.IsCancellationRequested) continue;
                    found(code);
                    return;
                }
            }
            finally { await frames.StopAsync(); }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        // Drivers without a compatible preview frame reader can still capture a photo.
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException or ArgumentException or UnauthorizedAccessException) { }
    }
}
