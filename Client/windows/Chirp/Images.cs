using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Chirp;

internal static class Images
{
    internal static async Task<byte[]?> Thumbnail(string path, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        if (!new[] { ".png", ".jpg", ".jpeg", ".jpe", ".jfif", ".pjpeg", ".pjp", ".webp", ".heic", ".heif", ".hif", ".gif" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) return null;
        using var file = File.OpenRead(path);
        if (file.Length > 20 * 1024 * 1024) throw new IOException("ATTACHMENT_QUOTA");
        using var stream = file.AsRandomAccessStream();
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellation);
        foreach (var side in new[] { 256, 192, 128, 96 })
        {
            cancellation.ThrowIfCancellationRequested();
            using var bitmap = await DecodeImage(decoder, side, BitmapAlphaMode.Ignore, cancellation);
            using var dest = new InMemoryRandomAccessStream();
            var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(0.5f, Windows.Foundation.PropertyType.Single) };
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, dest, options);
            encoder.SetSoftwareBitmap(bitmap);
            await encoder.FlushAsync().AsTask(cancellation);
            if (dest.Size > 6144 - 28) continue;
            dest.Seek(0);
            using var reader = new DataReader(dest);
            await reader.LoadAsync((uint)dest.Size);
            var data = new byte[(int)dest.Size];
            reader.ReadBytes(data);
            return data;
        }
        throw new IOException("ATTACHMENT_INVALID");
    }

    private static async Task<SoftwareBitmap> DecodeImage(BitmapDecoder decoder, int side, BitmapAlphaMode alpha, CancellationToken cancellation = default)
    {
        var w = decoder.PixelWidth;
        var h = decoder.PixelHeight;
        if (w == 0 || h == 0 || (ulong)w * h > 60_000_000) throw new IOException("ATTACHMENT_INVALID");
        var scale = Math.Min(1, side / (double)Math.Max(w, h));
        var transform = new BitmapTransform { ScaledWidth = (uint)Math.Max(1, w * scale), ScaledHeight = (uint)Math.Max(1, h * scale), InterpolationMode = BitmapInterpolationMode.Fant };
        return await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, alpha, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(cancellation);
    }

    internal static async Task<SoftwareBitmap> AttachmentImage(byte[] bytes, int side)
    {
        if (bytes.Length > 20 * 1024 * 1024) throw new IOException("ATTACHMENT_INVALID");
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(bytes.AsBuffer());
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        return await DecodeImage(decoder, side, BitmapAlphaMode.Premultiplied);
    }
}
