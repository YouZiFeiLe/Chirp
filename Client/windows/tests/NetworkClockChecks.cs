using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;

namespace Chirp;

internal static class NetworkClockChecks
{
    private sealed class TestTime : TimeProvider
    {
        internal DateTimeOffset NetworkUtc = new(2026, 11, 21, 6, 40, 0, TimeSpan.Zero);
        internal TimeSpan Offset;
        private long timestamp;
        public override DateTimeOffset GetUtcNow() => NetworkUtc + Offset;
        public override long GetTimestamp() => timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        internal void Advance(TimeSpan duration) { NetworkUtc += duration; timestamp += duration.Ticks; }
        internal NetworkTimeSample Sample(int offsetSeconds = 0, int rttMs = 10) => new(NetworkUtc.AddSeconds(offsetSeconds), timestamp, TimeSpan.FromMilliseconds(rttMs));
    }

    private static void Check(bool condition, string reason)
    {
        if (!condition) throw new InvalidOperationException(reason);
    }

    internal static async Task Run()
    {
        var time = new TestTime();
        var response = new TaskCompletionSource<NetworkTimeSample?[]>();
        var calls = 0;
        var clock = new NetworkClock(time, (_, _) => { calls++; return response.Task; });
        var initial = clock.RefreshAsync();
        Check(ReferenceEquals(initial, clock.RefreshAsync(true)) && calls == 1 &&
            clock.Read().Status == ClockStatus.Checking && !clock.CanRetry, "startup waits for a single shared check");
        var first = time.Sample();
        time.Advance(TimeSpan.FromSeconds(1));
        response.SetResult([first, time.Sample(), time.Sample(60)]);
        await initial;
        Check(clock.Read() == new ClockReading(ClockStatus.Ready), "timestamp alignment and two agreeing sources exclude the outlier");
        foreach (var ticks in new[] { -1L, 1L })
        {
            time.Offset = ticks * TimeSpan.FromSeconds(2);
            Check(clock.Read() == new ClockReading(ClockStatus.Ready, time.Offset), "inclusive two-second boundary");
            time.Offset += TimeSpan.FromTicks(ticks);
            Check(clock.Read() == new ClockReading(ClockStatus.OutOfSync, time.Offset), "ahead and behind are both blocked");
        }
        time.Offset = TimeSpan.Zero;
        Check(clock.Read().Status == ClockStatus.Ready && calls == 1, "a Windows clock correction immediately reopens access");
        time.Advance(TimeSpan.FromMinutes(10));
        response = new();
        response.SetResult([null, null, null]);
        await clock.RefreshAsync();
        Check(clock.Read().Status == ClockStatus.Ready && calls == 2, "a brief outage preserves the fresh reference");
        time.Offset = TimeSpan.FromSeconds(-35);
        Check(clock.Read().Status == ClockStatus.OutOfSync, "losing a source cannot clear known skew");
        time.Advance(TimeSpan.FromMinutes(5));
        Check(clock.Read().Status == ClockStatus.Unavailable, "an expired reference cannot authorize");
        response = new();
        response.SetResult([null, null, null]);
        await clock.RefreshAsync();
        Check(clock.Read().Status == ClockStatus.Unavailable, "all three sources failed");
        await clock.RefreshAsync(true);
        Check(calls == 3 && !clock.CanRetry, "manual retries respect the minimum interval");
        time.Advance(TimeSpan.FromSeconds(16));
        time.Offset = TimeSpan.Zero;
        response = new();
        response.SetResult([null, time.Sample(), null]);
        await clock.RefreshAsync(true);
        Check(clock.Read().Status == ClockStatus.Ready && calls == 4, "one responding source unlocks access after an outage");
        for (var i = 0; i < 3; i++)
        {
            NetworkTimeSample?[] samples = [null, null, null];
            samples[i] = time.Sample();
            var single = new NetworkClock(time, (_, _) => Task.FromResult(samples));
            await single.RefreshAsync();
            Check(single.Read().Status == ClockStatus.Ready, "any one of the three sources suffices at startup");
            time.Offset = TimeSpan.FromSeconds(7);
            Check(single.Read().Status == ClockStatus.OutOfSync, "one valid source detects skew independently of connectivity");
            time.Offset = TimeSpan.Zero;
        }
        var two = new NetworkClock(time, (_, _) => Task.FromResult<NetworkTimeSample?[]>([time.Sample(15, 400), null, time.Sample()]));
        await two.RefreshAsync();
        Check(two.Read().Status == ClockStatus.Ready, "two replies use the lower round-trip measurement");
        await CheckNtp();
        Console.WriteLine("PASS NTP packets, single-source fallback, clock drift, outages and automatic recovery");
    }

    private static async Task CheckNtp()
    {
        // Across the 2036 NTP era rollover, T2 is 0.25 s before and T3 is 0.25 s after.
        var reply = new byte[48];
        reply[0] = 0x24;
        reply[1] = 2;
        byte[] nonce = [1, 2, 3, 4, 5, 6, 7, 8];
        nonce.CopyTo(reply, 24);
        BinaryPrimitives.WriteUInt64BigEndian(reply.AsSpan(32), 0xffffffffc0000000);
        BinaryPrimitives.WriteUInt64BigEndian(reply.AsSpan(40), 0x0000000040000000);
        var roundTrip = TimeSpan.FromSeconds(1);
        var rollover = new DateTimeOffset(2036, 2, 7, 6, 28, 16, TimeSpan.Zero);
        Check(NtpTime.EstimateUtc(reply, nonce, roundTrip) == rollover.AddMilliseconds(500), "subtract server processing from network transit");
        foreach (var (position, value) in new (int, byte)[] { (0, 0xe4), (0, 0x23), (0, 0x0c), (1, 0), (1, 16), (24, 0) })
        {
            var invalid = (byte[])reply.Clone();
            invalid[position] = value;
            Check(NtpTime.EstimateUtc(invalid, nonce, roundTrip) is null, "ignore invalid NTP synchronization, mode, version, stratum or origin");
        }
        Check(NtpTime.EstimateUtc(reply, nonce, TimeSpan.FromSeconds(3)) == rollover.AddSeconds(1.5), "a slow reply inside the timeout still counts");
        Check(NtpTime.EstimateUtc(reply[..40], nonce, roundTrip) is null &&
            NtpTime.EstimateUtc(reply, nonce, TimeSpan.FromSeconds(5)) is null, "ignore short and timed-out replies");
        Array.Clear(reply, 32, 8);
        Check(NtpTime.EstimateUtc(reply, nonce, roundTrip) is null, "a missing receive timestamp cannot verify time");

        using var server = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var port = ((IPEndPoint)server.Client.LocalEndPoint!).Port;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var reading = NtpTime.QueryServerAsync("127.0.0.1", port, TimeProvider.System, timeout.Token);
        var request = await server.ReceiveAsync(timeout.Token);
        Check(request.Buffer.Length == 48 && request.Buffer[0] == 0x23, "NTP client request on UDP");
        request.Buffer.AsSpan(40, 8).CopyTo(reply.AsSpan(24));
        reply.AsSpan(40, 8).CopyTo(reply.AsSpan(32));
        await server.SendAsync(reply, request.RemoteEndPoint, timeout.Token);
        var sample = await reading;
        Check(sample.HasValue && (sample.Value.Utc - rollover).TotalSeconds is >= 0.25 and <= 1.25, "parse a matched UDP server reply");
        using var cancelled = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        Check(await NtpTime.QueryServerAsync("127.0.0.1", port, TimeProvider.System, cancelled.Token) is null, "an unresponsive source times out");
    }
}
