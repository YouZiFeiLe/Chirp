using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Chirp;

internal static class AvatarImage
{
    internal static async Task<byte[]> Prepare(string path)
    {
        using var file = File.OpenRead(path);
        if (file.Length >= 5_000_000) throw new IOException("AVATAR_TOO_LARGE");
        var source = new byte[(int)file.Length]; await file.ReadExactlyAsync(source);
        using var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(source.AsBuffer()); stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        var format = decoder.DecoderInformation.CodecId;
        if (decoder.FrameCount != 1 || format == BitmapDecoder.PngDecoderId && !PngFrames.Single(source) ||
            format != BitmapDecoder.PngDecoderId && format != BitmapDecoder.JpegDecoderId && format != BitmapDecoder.HeifDecoderId)
            throw new IOException("AVATAR_INVALID");
        var w = decoder.PixelWidth; var h = decoder.PixelHeight;
        if (w is 0 or > 8192 || h is 0 or > 8192 || (ulong)w * h > 32_000_000) throw new IOException("AVATAR_DIMENSIONS_EXCEEDED");
        const int size = 512;
        var scale = Math.Min(1d, size / (double)Math.Min(w, h));
        var transform = new BitmapTransform { ScaledWidth = (uint)Math.Max(1, Math.Round(w * scale)), ScaledHeight = (uint)Math.Max(1, Math.Round(h * scale)), InterpolationMode = BitmapInterpolationMode.Fant };
        using var oriented = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        var width = oriented.PixelWidth; var height = oriented.PixelHeight;
        var pixels = new byte[width * height * 4];
        oriented.CopyToBuffer(pixels.AsBuffer());
        var side = Math.Min(width, height); var square = new byte[side * side * 4];
        for (var y = 0; y < side; y++)
            Array.Copy(pixels, (((height - side) / 2 + y) * width + (width - side) / 2) * 4, square, y * side * 4, side * 4);
        using var dest = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, dest);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)side, (uint)side, 96, 96, square);
        encoder.BitmapTransform.ScaledWidth = size; encoder.BitmapTransform.ScaledHeight = size;
        encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Cubic;
        await encoder.FlushAsync(); dest.Seek(0);
        using var reader = new DataReader(dest); await reader.LoadAsync((uint)dest.Size);
        var data = new byte[(int)dest.Size]; reader.ReadBytes(data); return data;
    }
}
