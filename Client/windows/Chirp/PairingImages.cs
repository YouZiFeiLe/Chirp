using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using ZXing;
using ZXing.Common;

namespace Chirp;

internal static class PairingImages
{
    internal static async Task<string> ReadFile(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        using var stream = await file.OpenReadAsync();
        return await Read(stream, true);
    }

    internal static async Task<string> Read(IRandomAccessStream stream, bool imported)
    {
        if (stream.Size == 0) throw new IOException("INVALID_PAIRING_IMAGE");
        if (stream.Size > 8 * 1024 * 1024) throw new IOException(imported ? "FILE_TOO_LARGE" : "INVALID_PAIRING_IMAGE");
        stream.Seek(0);
        try
        {
            var decoder = await BitmapDecoder.CreateAsync(stream);
            if (imported)
            {
                if (decoder.FrameCount != 1 || decoder.PixelWidth > 4096 || decoder.PixelHeight > 4096) throw new IOException("INVALID_PAIRING_IMAGE");
                if (decoder.DecoderInformation.CodecId == BitmapDecoder.PngDecoderId) await RequireSinglePngFrame(stream);
            }
            if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0 || (ulong)decoder.PixelWidth * decoder.PixelHeight > 32_000_000) throw new IOException("INVALID_PAIRING_IMAGE");
            double scale = imported ? 1 : Math.Min(1, 1800d / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
            var transform = new BitmapTransform { ScaledWidth = (uint)Math.Max(1, decoder.PixelWidth * scale), ScaledHeight = (uint)Math.Max(1, decoder.PixelHeight * scale) };
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            var source = new RGBLuminanceSource(data.DetachPixelData(), (int)transform.ScaledWidth, (int)transform.ScaledHeight, RGBLuminanceSource.BitmapFormat.BGRA32);
            return await Task.Run(() => Decode(source)) ?? throw new IOException("INVALID_PAIRING_IMAGE");
        }
        catch (Exception ex) when (ex is COMException or ArgumentException)
        {
            throw new IOException("INVALID_PAIRING_IMAGE", ex);
        }
    }

    internal static string? ReadFrame(SoftwareBitmap bitmap)
    {
        using var gray = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Gray8);
        var pixels = new byte[checked(gray.PixelWidth * gray.PixelHeight)];
        gray.CopyToBuffer(pixels.AsBuffer());
        return Decode(new RGBLuminanceSource(pixels, gray.PixelWidth, gray.PixelHeight, RGBLuminanceSource.BitmapFormat.Gray8));
    }

    private static string? Decode(RGBLuminanceSource source)
    {
        var reader = new BarcodeReaderGeneric { AutoRotate = true, Options = new DecodingOptions { TryHarder = true, PossibleFormats = [BarcodeFormat.QR_CODE] } };
        var results = reader.DecodeMultiple(source);
        var result = results?.Length == 1 ? results[0].Text : null;
        return result is { Length: > 0 and <= 4096 } && result.StartsWith("chirp-device-pair-v1:", StringComparison.Ordinal) ? result : null;
    }

    private static async Task RequireSinglePngFrame(IRandomAccessStream stream)
    {
        var data = new byte[(int)stream.Size];
        using (var input = stream.GetInputStreamAt(0).AsStreamForRead()) await input.ReadExactlyAsync(data);
        if (!PngFrames.Single(data)) throw new IOException("INVALID_PAIRING_IMAGE");
    }
}
