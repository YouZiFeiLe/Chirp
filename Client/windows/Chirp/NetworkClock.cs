using System.Buffers.Binary;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace Chirp;

internal enum ClockStatus { Checking, Ready, OutOfSync, Unavailable }
internal readonly record struct ClockReading(ClockStatus Status, TimeSpan LocalOffset = default);
internal readonly record struct NetworkTimeSample(DateTimeOffset Utc, long Timestamp, TimeSpan RoundTrip);

// Shared by all windows on the UI dispatcher. Only elapsed time advances the network reference.
internal sealed class NetworkClock(TimeProvider time, Func<TimeProvider, CancellationToken, Task<NetworkTimeSample?[]>> query)
{
    // A new pairing code uses 297 seconds of the protocol's 300-second window.
    internal static readonly TimeSpan Tolerance = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ReferenceLifetime = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan ManualRetryInterval = TimeSpan.FromSeconds(16);
    private NetworkTimeSample? reference;
    private Task? inFlight;
    private long? lastAttempt;
    private bool lastAttemptSucceeded;

    internal NetworkClock() : this(TimeProvider.System, NtpTime.QueryAsync) { }

    internal ClockReading Read()
    {
        if (reference is { } sample)
        {
            var age = time.GetElapsedTime(sample.Timestamp);
            if (age < ReferenceLifetime)
            {
                var offset = time.GetUtcNow() - sample.Utc - age;
                return new(offset.Duration() <= Tolerance ? ClockStatus.Ready : ClockStatus.OutOfSync, offset);
            }
        }
        return new(lastAttempt is null || inFlight is { IsCompleted: false } ? ClockStatus.Checking : ClockStatus.Unavailable);
    }

    private bool Due(TimeSpan interval) => lastAttempt is not { } previous || time.GetElapsedTime(previous) >= interval;
    internal bool CanRetry => inFlight is not { IsCompleted: false } && Due(ManualRetryInterval);

    internal Task RefreshAsync(bool manual = false)
    {
        if (inFlight is { IsCompleted: false }) return inFlight;
        var interval = manual ? ManualRetryInterval : lastAttemptSucceeded ? RefreshInterval : RetryInterval;
        if (!Due(interval)) return Task.CompletedTask;
        lastAttempt = time.GetTimestamp();
        return inFlight = MeasureAsync();
    }

    private async Task MeasureAsync()
    {
        using var timeout = new CancellationTokenSource(NtpTime.Timeout);
        var samples = await query(time, timeout.Token);
        var now = time.GetTimestamp();
        var estimates = samples.OfType<NetworkTimeSample>()
            .Select(s => s with { Utc = s.Utc + time.GetElapsedTime(s.Timestamp, now), Timestamp = now })
            .OrderBy(s => s.Utc).ToArray();
        lastAttemptSucceeded = estimates.Length > 0;
        if (!lastAttemptSucceeded) return;
        // Any valid reply suffices. Prefer the lower round trip for two, and the median for three.
        reference = estimates.Length == 2 ? estimates.MinBy(s => s.RoundTrip) : estimates[estimates.Length / 2];
    }
}

internal static class NtpTime
{
    internal static readonly TimeSpan Timeout = TimeSpan.FromSeconds(4);
    private static readonly string[] Servers = ["time.windows.com", "ntp.aliyun.com", "time.cloudflare.com"];

    internal static Task<NetworkTimeSample?[]> QueryAsync(TimeProvider time, CancellationToken token) =>
        Task.WhenAll(Servers.Select(host => QueryServerAsync(host, 123, time, token)));

    internal static async Task<NetworkTimeSample?> QueryServerAsync(string host, int port, TimeProvider time, CancellationToken token)
    {
        try
        {
            using var socket = new Socket(SocketType.Dgram, ProtocolType.Udp);
            await socket.ConnectAsync(host, port, token).ConfigureAwait(false);
            var request = new byte[48];
            request[0] = 0x23; // NTPv4 client mode. The server echoes our per-query transmit nonce.
            RandomNumberGenerator.Fill(request.AsSpan(40));
            var response = new byte[512];
            var start = time.GetTimestamp();
            await socket.SendAsync(request, SocketFlags.None, token).ConfigureAwait(false);
            var length = await socket.ReceiveAsync(response, SocketFlags.None, token).ConfigureAwait(false);
            var end = time.GetTimestamp();
            var roundTrip = time.GetElapsedTime(start, end);
            return EstimateUtc(response.AsSpan(0, length), request.AsSpan(40), roundTrip) is { } utc
                ? new(utc, end, roundTrip) : null;
        }
        catch (SocketException) { return null; }
        catch (NotSupportedException) { return null; }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return null; }
    }

    internal static DateTimeOffset? EstimateUtc(ReadOnlySpan<byte> reply, ReadOnlySpan<byte> nonce, TimeSpan roundTrip)
    {
        if (reply.Length < 48 || (reply[0] & 7) != 4 || ((reply[0] >> 3) & 7) is not (3 or 4) ||
            reply[0] >> 6 == 3 || reply[1] is 0 or > 15 || !reply.Slice(24, 8).SequenceEqual(nonce) ||
            roundTrip < TimeSpan.Zero || roundTrip > Timeout) return null;
        var received = ReadTimestamp(reply[32..]);
        var sent = ReadTimestamp(reply[40..]);
        if (received is null || sent is null || sent < received) return null;
        var transit = roundTrip - (sent.Value - received.Value);
        return transit >= TimeSpan.Zero ? sent.Value + transit / 2 : null;
    }

    private static DateTimeOffset? ReadTimestamp(ReadOnlySpan<byte> bytes)
    {
        if (BinaryPrimitives.ReadUInt64BigEndian(bytes) == 0) return null;
        // Unfold the NTP seconds field into 1970–2106, including the 2036 rollover,
        // independently of the Windows clock we are trying to check.
        var unix = unchecked(BinaryPrimitives.ReadUInt32BigEndian(bytes) - 2_208_988_800u);
        var fraction = BinaryPrimitives.ReadUInt32BigEndian(bytes[4..]);
        return DateTimeOffset.FromUnixTimeSeconds(unix).AddTicks(((long)fraction * TimeSpan.TicksPerSecond) >> 32);
    }
}
