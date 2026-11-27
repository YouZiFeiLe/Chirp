using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using Chirp;
using Concentus;
using Concentus.Enums;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

if (args.Contains("--hello-probe") || args.Contains("--hello-unlock"))
{
    await LoginResumptionChecks.CheckProvider(args.Contains("--hello-unlock"));
    return;
}
LoginResumptionChecks.CheckLock();
await FollowupChecks.Run();
await NetworkClockChecks.Run();

static void Check(bool pass, string reason)
{
    if (!pass) throw new InvalidOperationException(reason);
}

var backupClock = new BackupConfirmationClock();
backupClock.SetVisible(true, 1000);
backupClock.SetVisible(false, 3500);
Check(backupClock.Remaining(60000) == 3, "recovery confirmation excludes background time");
backupClock.SetVisible(true, 60000);
Check(backupClock.Remaining(62499) == 1 && backupClock.Remaining(62500) == 0, "recovery confirmation resumes accumulated foreground time");
Check(new BackupConfirmationClock().Remaining(62500) == 5, "a new confirmation starts a fresh interval");
Console.WriteLine("PASS recovery confirmation foreground clock");

var text = string.Concat(Enumerable.Repeat("😀", 1024));
Check(DesktopText.CanSend(text) && !DesktopText.FitsDraft(text + "a"), "4096 UTF-8 byte boundary");
Check(DesktopText.WireText(" a\r\n b\rc ") == " a\n b\nc " && DesktopText.CanSend("\t test \n"), "whitespace and multiline text");
Check(!DesktopText.CanSend(" \t\n") && !DesktopText.CanSend("a\u0001b") && !DesktopText.CanSend("a\u0085b"), "invalid chat text");
Console.WriteLine("PASS UTF-8 editing and normalized multiline messages");

var timeline = new ChatTimeline { Draft = "  first  " };
Check(!timeline.Activated, "chat waits for its admission's first secure activation");
timeline.Activate();
var attempt = timeline.Begin("entry-a", "me")!;
timeline.Draft = "second";
Check(timeline.Begin("entry-a", "me") is null && timeline.Finish(attempt, false) && timeline.Draft == "second", "single send preserves new typing");
Check(!timeline.Restore(attempt, "entry-a"), "failed send cannot overwrite draft");
timeline.Draft = "";
Check(!timeline.Restore(attempt, "entry-b") && timeline.Restore(attempt, "entry-a") && timeline.Draft == "  first  ", "admission-bound restoration");
for (var i = 0; i < 999; i++) timeline.Receive("other", i.ToString(), null);
var newest = timeline.Begin("entry-a", "me")!;
Check(timeline.UnreadAfter(0) == 1000 && timeline.UnreadAfter(newest.Sequence) == 0, "window read positions count retained messages");
Check(timeline.Messages.Count == 1000 && timeline.Trimmed && !timeline.Restore(attempt, "entry-a") && ReferenceEquals(timeline.Messages[^1], newest), "one bounded transcript preserves ordering");
timeline.Receive("other", "", new System.Text.Json.Nodes.JsonObject());
var fileRead = timeline.LatestSequence;
timeline.RemoveFiles(); Check(timeline.Messages.Count == 999 && timeline.Finish(newest, true), "attachment removal preserves delivery states");
Check(timeline.UnreadAfter(newest.Sequence) == 0 && timeline.UnreadAfter(0) == 999, "removed attachments leave no unread badge");
timeline.Receive("other", "later", null);
Check(timeline.UnreadAfter(fileRead) == 1 && timeline.Activated, "a removed read anchor preserves per-window history");
timeline.Clear(); Check(!timeline.Trimmed && !timeline.Finish(newest, false) && timeline.Pending is null, "late result cannot restore ended admission");
Check(!timeline.Activated && timeline.LatestSequence == 0 && timeline.UnreadAfter(0) == 0, "new room starts with fresh visibility and read state");
timeline.Receive("You", "Hello", null);
timeline.Receive("你", "", new System.Text.Json.Nodes.JsonObject(), mine: true);
Check(newest.Mine && !timeline.Messages[0].Mine && timeline.Messages[1].Mine, "bubble ownership survives language changes and includes own attachments");
Console.WriteLine("PASS send, failure restoration and unified 1,000-message history");

var routes = new AudioRoute("fixed-input", "fixed-output", 2);
Check(routes.WithAvailableEndpoints((capture, id) => capture ? "" : id) == new AudioRoute("", "fixed-output", 2), "fixed device disappeared");
var original = new AudioRoute("", "", 0);
var installed = original;
try
{
    routes.ApplyOrRestore(() => { installed = routes; throw new IOException("fixture"); }, () => installed = original, _ => throw new Exception("unexpected"));
}
catch (IOException e) when (e.Message == "fixture") { }
Check(installed == original, "failed preset rolls back");
Console.WriteLine("PASS route fallback and preset rollback");

using (var service = new AudioService())
{
    Check(service.Preset == 1 && service.Communications && !service.Denoise, "default to Windows communications without RNNoise");
    service.Preset = 0;
    Check(service.Communications && service.Denoise, "saved Windows communications and RNNoise preset");
    service.Preset = 2;
    Check(!service.Communications && service.Denoise, "saved software processing and RNNoise preset");
    service.Preset = 1;
    Check(service.Communications && !service.Denoise, "switch back to Windows communications");
    service.Preset = -1;
    Check(service.Preset == 1 && !service.Denoise, "unknown preset falls back to Windows communications");
    Check(!service.Activation, "fresh installation should leave voice activation off");
    service.BeginEntry("entry-A");
    var until = AudioService.Now + 20_000;
    Check(service.Renew("entry-A", "group", until, 1) && service.Permitted("entry-A", "group"), "matching admission lease");
    Check(!service.Renew("entry-B", "group", until, 9), "foreign admission renewal");
    Check(service.Renew("entry-A", "group", 0, 3) && !service.Renew("entry-A", "group", until, 2) && !service.Permitted("entry-A", "group"), "revocation beats delayed snapshot");
    service.BeginEntry("entry-B");
    Check(!service.Renew("entry-A", "group", until, 4), "previous admission cannot renew");
}
var mixer = new AudioService.Mixer { Listen = false };
var deadline = AudioService.Now + 10_000;
mixer.SetDeadline(deadline);
mixer.Add("peer", [500], deadline); mixer.Add("local-test", [1250], deadline);
byte[] output = new byte[2]; mixer.Read(output);
Check(MemoryMarshal.Cast<byte, short>(output)[0] == 1250, "local replay while room listening is off");
mixer.Listen = true; mixer.Add("peer", [500], deadline); mixer.SetDeadline(AudioService.Now - 1); mixer.Read(output);
Check(MemoryMarshal.Cast<byte, short>(output)[0] == 0, "withdrawal applies to already queued audio");
Console.WriteLine("PASS local playback, VAD default and audio lease revocation");

using (var decoder = OpusCodecFactory.CreateDecoder(48000, 1))
{
    // One 20 ms, 400 Hz SILK frame. The same peer alternates between voice and DTX.
    var tone = Convert.FromHexString("28822e38f043dbaec91bf391756b9e04f658daa09409930b46f83cbbe22968267e636b99ddb9babf93d938e0d564fbc0");
    Check(AudioService.DecodePacket(decoder, [0xF8, 0xFF, 0xFE]).Length == 960, "initial WebRTC silence");
    foreach (var (packet, duration) in new (byte[], int)[]
    {
        ([0x28], 960), ([0x28, 0], 960), ([0xF8], 960),
        ([0x39], 5760), ([0x2B, 0x41, 2, 0, 0], 960)
    })
    {
        Check(AudioService.DecodePacket(decoder, tone).Any(s => Math.Abs((int)s) > 500), "speech after a silent interval");
        Check(AudioService.DecodePacket(decoder, packet).Length == duration, "DTX after speech must decode for its full duration");
    }
    Check(AudioService.DecodePacket(decoder, [0x2B]).Length == 0, "incomplete frame count");
    Check(AudioService.DecodePacket(decoder, [0x29, 0]).Length == 0, "truncated two-frame packet");
    var mixed = AudioService.DecodePacket(decoder, [0x2A, 0, .. tone.AsSpan(1)]);
    Check(mixed.Length == 1920 && mixed.Skip(960).Any(s => Math.Abs((int)s) > 500), "voice in the same packet after DTX stays audible");

    using var encoder = OpusCodecFactory.CreateEncoder(48000, 1, OpusApplication.OPUS_APPLICATION_VOIP);
    const string prefix = "libopus ";
    var codecName = decoder.GetVersionString();
    Check(codecName.StartsWith(prefix, StringComparison.Ordinal) &&
        Version.TryParse(codecName[prefix.Length..], out var nativeVersion) && nativeVersion >= new Version(1, 6, 1) &&
        encoder.GetVersionString() == codecName, $"expected native libopus 1.6.1 or newer, got {codecName}");
    var speechSamples = AudioService.DecodePacket(decoder, tone);
    var compressedSpeech = new byte[1275];
    var encodedLength = encoder.Encode(speechSamples, speechSamples.Length, compressedSpeech, compressedSpeech.Length);
    using var receiver = OpusCodecFactory.CreateDecoder(48000, 1);
    var decodedSpeech = AudioService.DecodePacket(receiver, compressedSpeech.AsSpan(0, encodedLength));
    Check(decodedSpeech.Length == speechSamples.Length && decodedSpeech.Any(s => Math.Abs((int)s) > 500), "native speech round trip");
    Console.WriteLine($"PASS {codecName} voice encoding and decoding");
}
Console.WriteLine("PASS Opus speech, DTX, invalid packet recovery and resumed speech");

foreach (var joined in new[] { true, false })
{
    var cue = await Task.Run(() => AudioService.ReadCue(joined));
    Check(cue.Length > 0 && cue.Any(sample => Math.Abs((int)sample) > 100), "room cue must decode to audible mono PCM from the application directory");
}
mixer.Master = 50;
mixer.SetDeadline(deadline);
mixer.Add("peer", [500, 500], deadline);
mixer.AddCue([2000, 2000], deadline);
mixer.Read(output);
Check(MemoryMarshal.Cast<byte, short>(output)[0] == 1250, "room cue and peer share the master output gain");
mixer.ClearCues();
mixer.Read(output);
Check(MemoryMarshal.Cast<byte, short>(output)[0] == 250, "cancelling a cue keeps the peer audible");
mixer.Listen = false;
mixer.AddCue([2000], deadline);
mixer.Read(output);
Check(MemoryMarshal.Cast<byte, short>(output)[0] == 0, "room cues follow the listening control");
Console.WriteLine("PASS installed room entry and exit sounds decode for the WASAPI mixer");

var roster = new RoomPresence();
Check(roster.Confirm(["other"], "me").Count == 0 && roster.Confirm(["me", "a"], "me").SequenceEqual([true]), "secure baseline");
Check(roster.Confirm(["me", "b"], "me").SequenceEqual([false, true]), "simultaneous departure and arrival");
roster.Resynchronize();
Check(roster.Confirm(["me", "c"], "me").Count == 0 && roster.Confirm(["me", "c", "d"], "me").SequenceEqual([true]), "silent reconnection");
Check(RoomClock.Fresh(1000, 6999) && !RoomClock.Fresh(1000, 7000) && !RoomClock.Fresh(1000, 999), "six-second freshness");
Check(RoomClock.Remaining(1000, 3200, 30000, 35000) == 3 && RoomClock.Remaining(1000, 6999, 30000, 35000) == 0 && RoomClock.Remaining(1000, 7100, 30000, 35000) is null, "monotonic countdown");
Console.WriteLine("PASS confirmed roster changes, reconnection and room clock");

Check(DesktopText.Fingerprint(Convert.ToBase64String(new byte[32])) == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925", "known SHA-256 fingerprint");
Check(DesktopText.Fingerprint("invalid") == "—", "invalid key");
var nickname = string.Concat(Enumerable.Repeat("😀", 80));
Check(DesktopText.ValidName(nickname) && !DesktopText.ValidName(nickname + "A") && !DesktopText.ValidName("name\t"), "nickname scalar limit");
Check(DesktopText.LimitName(nickname + "A") == nickname && DesktopText.LimitName("昵称") == "昵称", "profile edit limit preserves complete Unicode scalars");
Console.WriteLine("PASS cross-platform fingerprints and Unicode nickname bounds");

var temp = Directory.CreateTempSubdirectory("ChirpAvatar-");
try
{
    async Task<byte[]> Encode(Guid codec)
    {
        const int w = 100, h = 50;
        var pixels = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var offset = (y * w + x) * 4;
                pixels[offset + (x is < 25 or >= 75 ? 1 : x < 50 ? 2 : 0)] = 255;
                pixels[offset + 3] = 255;
            }
        using var dest = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(codec, dest);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, w, h, 96, 96, pixels);
        await encoder.FlushAsync(); dest.Seek(0);
        using var reader = new DataReader(dest); await reader.LoadAsync((uint)dest.Size);
        var bytes = new byte[(int)dest.Size]; reader.ReadBytes(bytes); return bytes;
    }
    async Task CheckAvatar(byte[] bytes, string ext, bool rotated)
    {
        var path = Path.Combine(temp.FullName, "input." + ext);
        await File.WriteAllBytesAsync(path, bytes);
        var thumbnail = await Images.Thumbnail(path);
        Check(thumbnail is { Length: > 28 and <= 6116 } && thumbnail[0] == 0xff && thumbnail[1] == 0xd8, "wire-sized JPEG thumbnail");
        using var preview = await Images.AttachmentImage(bytes, 2048);
        using var thumbnailPreview = await Images.AttachmentImage(thumbnail!, 256);
        Check(preview.PixelWidth == thumbnailPreview.PixelWidth && preview.PixelHeight == thumbnailPreview.PixelHeight
            && ((preview.PixelWidth < preview.PixelHeight) == rotated), "original and thumbnail EXIF orientation");
        var png = await AvatarImage.Prepare(path);
        Check(!Encoding.UTF8.GetString(png).Contains("PRIVATE-FIXTURE-DATA", StringComparison.Ordinal), "original metadata retained");
        using var result = new InMemoryRandomAccessStream();
        await result.WriteAsync(png.AsBuffer()); result.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(result);
        Check(decoder.DecoderInformation.CodecId == BitmapDecoder.PngDecoderId && decoder.PixelWidth == 512 && decoder.PixelHeight == 512, "normalized avatar PNG");
        var data = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
        int Pixel(int x, int y, int component) => data[(y * 512 + x) * 4 + component];
        Check(rotated ? Pixel(256, 128, 2) > 200 && Pixel(256, 384, 0) > 200 : Pixel(128, 256, 2) > 200 && Pixel(384, 256, 0) > 200, "center crop or EXIF orientation");
    }
    var invalidImage = Path.Combine(temp.FullName, "invalid.jpg");
    await File.WriteAllTextAsync(invalidImage, "not a JPEG");
    var rejected = false;
    try { await Images.Thumbnail(invalidImage); } catch { rejected = true; }
    Check(rejected && await Images.Thumbnail(Path.ChangeExtension(invalidImage, ".txt")) is null, "supported image must decode before upload");
    await CheckAvatar(await Encode(BitmapEncoder.PngEncoderId), "png", false);
    var jpeg = await Encode(BitmapEncoder.JpegEncoderId);
    await CheckAvatar(jpeg, "jfif", false);
    // JPEG APP1 encodes TIFF orientation 6 (90° clockwise); COM is private source metadata.
    var exif = Convert.FromHexString("FFE1002245786966000049492A0008000000010012010300010000000600000000000000");
    var comment = Encoding.ASCII.GetBytes("PRIVATE-FIXTURE-DATA");
    await CheckAvatar([..jpeg[..2], ..exif, 0xFF, 0xFE, 0, (byte)(comment.Length + 2), ..comment, ..jpeg[2..]], "jpeg", true);
    Console.WriteLine("PASS Windows PNG/JPEG thumbnails, original image previews, EXIF rotation, avatar crop and metadata removal");
    if (args.FirstOrDefault() is { } heif)
    {
        await CheckAvatar(await File.ReadAllBytesAsync(heif), "heic", false);
        Console.WriteLine("PASS Windows HEIF decoding and normalization");
    }
    else
    {
        byte[]? encoded = null;
        try { encoded = await Encode(BitmapEncoder.HeifEncoderId); }
        catch (Exception e) when (e is COMException or NotSupportedException or ArgumentException)
        { Console.WriteLine($"SKIP HEIF generation — encoder {e.HResult:X8}"); }
        if (encoded is not null) { await CheckAvatar(encoded, "heic", false); Console.WriteLine("PASS Windows HEIF decoding and normalization"); }
    }
}
finally { temp.Delete(true); }

await QrChecks.Run();
await AttachmentActionChecks.Run();
