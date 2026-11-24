using System.Text.Json.Nodes;

namespace Chirp;

internal static class FollowupChecks
{
    internal static async Task Run()
    {
        static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }
        Require(!DesktopText.English(1, ["en-US"]) && DesktopText.English(0, ["zh-Hant-TW", "en-US"]) &&
            !DesktopText.English(0, ["fr-FR", "zh-SG"]) && DesktopText.English(0, ["de-DE"]), "locale preference order");
        Console.WriteLine("PASS explicit language, simplified Chinese and ordered system fallback");

        var gate = new VoiceGate();
        var quiet = new short[960];
        var voiced = Enumerable.Repeat((short)4000, 960).ToArray();
        Require(gate.Process(voiced, false, -45) == 18, "open microphone should report the PCM RMS level");
        Require(!gate.Open && voiced[0] == 4000, "disabled gate modified a frame");
        Require(gate.Process(quiet, true, -45) == 127, "digital silence should report RFC 6464 level 127");
        Require(!gate.Open && gate.Level == -96, "silence opened the gate after enabling");
        var belowThreshold = Enumerable.Repeat((short)100, 960).ToArray();
        Require(gate.Process(belowThreshold, true, -45) == 127 && gate.Level > -96, "a closed gate must report silence even when the meter sees input");
        Require(gate.Process(voiced, true, -45) == 19, "voice activity should use the samples after the gain ramp");
        Require(gate.Open && voiced[0] < 40 && voiced[240] == 4000, "5 ms attack");
        for (var i = 0; i < 12; i++) gate.Process(quiet, true, -45);
        Require(gate.Open, "closed before 250 milliseconds of audio");
        gate.Process(quiet, true, -45);
        Require(!gate.Open, "did not close after 250 milliseconds of quiet PCM");
        Console.WriteLine("PASS sample-clock microphone activation and disabled-gate transition");

        var sample = new MicrophoneClip();
        var input = Enumerable.Range(0, 144017).Select(i => (short)(i % 25000)).ToArray();
        sample.Append(input);
        Require(sample.Finish(true).SequenceEqual(input.Skip(17)), "local clip order or duration");
        sample.Append(input);
        Require(sample.Count == 0 && sample.Finish(true).Length == 0, "late PCM after cleanup");
        var discarded = new MicrophoneClip(); discarded.Append(input);
        Require(discarded.Finish(false).Length == 0 && discarded.Finish(true).Length == 0, "stop retained local audio");
        using var audio = new AudioService();
        audio.BeginEntry("one"); audio.SetPeerVolume("peer", 175); audio.BeginEntry("one");
        Require(audio.PeerVolume("peer") == 175, "recovery lost level");
        audio.BeginEntry("new"); Require(audio.PeerVolume("peer") == 100, "per-entry level leaked");
        Console.WriteLine("PASS three-second microphone clip, discard, late callbacks and per-call volume");

        var requests = 0;
        var downloaded = new TaskCompletionSource();
        var delayed = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var profiles = new MemberProfiles<byte[]>(async (id, revision, token) =>
        {
            if (revision == "old") return await delayed.Task;
            if (Interlocked.Increment(ref requests) == 1) throw new ProtocolException(new JsonObject { ["temporary"] = true, ["error"] = "SERVER_UNAVAILABLE" });
            return [42];
        });
        JsonObject P(long version, string avatar, string name) => new() { ["id"] = "member_one", ["profile_revision"] = version, ["avatar_revision"] = avatar, ["display_name"] = name };
        profiles.Changed += () => { if (profiles.Image("member_one")?.FirstOrDefault() == 42) downloaded.TrySetResult(); };
        profiles.Apply(P(2, "old", "before"));
        profiles.Apply(P(4, "new", "after"));
        profiles.Apply(P(3, "", "stale"));
        await downloaded.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Require(profiles.Profile("member_one.login.entry").Str("display_name") == "after" && requests == 2, "stale snapshot or temporary download failure");
        profiles.Snapshot(new JsonArray(P(4, "new", "after")));
        Require(requests == 2, "cached revision fetched again");
        profiles.Apply(P(5, "", "removed"));
        Require(profiles.Image("member_one") is null, "avatar removal left an image");
        profiles.Reset(); delayed.SetResult([9]);
        await Task.Yield();
        Require(profiles.Profile("member_one") is null && profiles.Image("member_one") is null, "old login completed after logout");
        Console.WriteLine("PASS nickname revisions, avatar retry, reuse, deletion and sign-out");

        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "pairing-animated.png");
        var rejected = false;
        try { await AvatarImage.Prepare(path); }
        catch (IOException e) when (e.Message == "AVATAR_INVALID") { rejected = true; }
        Require(rejected, "animated PNG used as avatar");
        Console.WriteLine("PASS animated avatar rejected by the Windows import path");
    }
}
