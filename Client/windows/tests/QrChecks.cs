using System.Runtime.InteropServices.WindowsRuntime;
using Chirp;
using QRCoder;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

internal static class QrChecks
{
    private const string Value = "chirp-device-pair-v1:abcdef0123456789";

    internal static async Task Run()
    {
        await Check("single pairing QR", BitmapEncoder.PngEncoderId, true, true, [Value]);
        await Check("two different pairing QRs", BitmapEncoder.PngEncoderId, true, false, [Value, "chirp-device-pair-v1:1234567890abcdef"]);
        await Check("two identical QRs", BitmapEncoder.PngEncoderId, true, false, [Value, Value]);
        await Check("mixed pairing and unrelated QRs", BitmapEncoder.PngEncoderId, true, false, [Value, "unrelated QR"]);
        await Check("unrelated QR", BitmapEncoder.PngEncoderId, true, false, ["unrelated QR"]);
        await Check("imported JPEG pairing QR", BitmapEncoder.JpegEncoderId, true, true, [Value]);
        await Check("imported BMP pairing QR", BitmapEncoder.BmpEncoderId, true, true, [Value]);
        await Check("imported single-frame GIF pairing QR", BitmapEncoder.GifEncoderId, true, true, [Value]);
        await Check("animated pairing GIF", BitmapEncoder.GifEncoderId, true, false, [Value], frames: 2);
        await Check("two pairing QRs in a JPEG", BitmapEncoder.JpegEncoderId, true, false, [Value, Value]);
        await Check("camera JPEG", BitmapEncoder.JpegEncoderId, false, true, [Value]);

        using var notImage = new InMemoryRandomAccessStream();
        await notImage.WriteAsync(System.Text.Encoding.UTF8.GetBytes(Value).AsBuffer());
        await Verify("pairing text imported as an image", notImage, true, false);

        // Two valid APNG frames each contain the same pairing QR. WIC can expose
        // this fixture as a single PNG frame and successfully decode the QR.
        using var animated = new InMemoryRandomAccessStream();
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "pairing-animated.png");
        await animated.WriteAsync((await File.ReadAllBytesAsync(path)).AsBuffer());
        await Verify("animated pairing PNG", animated, true, false);
    }

    private static async Task Check(string name, Guid format, bool imported, bool accepted, string[] values, int frames = 1)
    {
        const int scale = 5;
        var codes = values.Select(v => QRCodeGenerator.GenerateQrCode(v, QRCodeGenerator.ECCLevel.M)).ToArray();
        var width = codes.Sum(q => q.ModuleMatrix.Count) * scale;
        var height = codes.Max(q => q.ModuleMatrix.Count) * scale;
        var pixels = Enumerable.Repeat((byte)255, width * height * 4).ToArray();
        var left = 0;
        foreach (var qr in codes)
        {
            var matrix = qr.ModuleMatrix;
            for (var y = 0; y < matrix.Count * scale; y++)
                for (var x = 0; x < matrix.Count * scale; x++)
                    if (matrix[y / scale][x / scale])
                        pixels.AsSpan(((left + x) + y * width) * 4, 3).Clear();
            left += matrix.Count * scale;
            qr.Dispose();
        }
        using var frame = SoftwareBitmap.CreateCopyFromBuffer(pixels.AsBuffer(), BitmapPixelFormat.Bgra8, width, height);
        var expectedFrame = values is [Value] ? Value : null;
        if (PairingImages.ReadFrame(frame) != expectedFrame) throw new InvalidOperationException("live frame: " + name);
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(format, stream);
        for (var i = 0; i < frames; i++)
        {
            if (i > 0) await encoder.GoToNextFrameAsync();
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
        }
        await encoder.FlushAsync();
        await Verify(name, stream, imported, accepted);
    }

    private static async Task Verify(string name, IRandomAccessStream stream, bool imported, bool accepted)
    {
        try
        {
            var value = imported ? await Import(stream) : await PairingImages.Read(stream, false);
            if (!accepted || value != Value) throw new InvalidOperationException(name);
        }
        catch (IOException ex) when (!accepted && ex.Message == "INVALID_PAIRING_IMAGE") { }
        Console.WriteLine("PASS " + name);
    }

    private static async Task<string> Import(IRandomAccessStream stream)
    {
        // A .tmp extension exercises the same content-based import used after forwarding a picture.
        var path = Path.GetTempFileName();
        try
        {
            using (var input = stream.GetInputStreamAt(0).AsStreamForRead())
            using (var file = File.OpenWrite(path))
                await input.CopyToAsync(file);
            return await PairingImages.ReadFile(path);
        }
        finally { File.Delete(path); }
    }
}
