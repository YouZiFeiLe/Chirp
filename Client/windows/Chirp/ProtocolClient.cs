using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Chirp;

internal sealed class ProtocolException(JsonNode reply) : IOException(reply.Str("error"))
{
    public long RetryAfter { get; } = reply.Num("retryAfter");
    public string MinimumVersion { get; } = reply.Str("minimumVersion");
    public long MinimumBuild { get; } = reply.Num("minimumBuild");
    public bool Transient { get; } = reply.Bool("temporary");
}

internal sealed class ProtocolClient : IAsyncDisposable
{
    private readonly Process process;
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonNode?>> calls = new();
    private readonly SemaphoreSlim writer = new(1);
    private long counter;
    private volatile bool closed;
    private string stopReason = "PROTOCOL_STOPPED";
    private readonly Action<string, JsonNode?> notify;

    public ProtocolClient(string storage, string logCache, Action<string, JsonNode?> notify)
    {
        this.notify = notify;
        var info = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Chirp.Protocol.exe"))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8
        };
        info.ArgumentList.Add("-data");
        info.ArgumentList.Add(storage);
        info.ArgumentList.Add("-log-cache");
        info.ArgumentList.Add(logCache);
#if DEBUG
        info.ArgumentList.Add("-loopback");
#endif
        try { process = Process.Start(info) ?? throw new IOException("PROTOCOL_START_FAILED"); }
        catch (System.ComponentModel.Win32Exception ex) { throw new IOException("PROTOCOL_START_FAILED", ex); }
        _ = ReadAsync();
    }

    private async Task ReadAsync()
    {
        try
        {
            while (await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                var reply = JsonNode.Parse(line);
                if (reply?["event"] is { } name)
                {
                    if (name.ToString() == "fatal")
                    {
                        stopReason = reply["data"]?.GetValue<string>() ?? stopReason;
                        break;
                    }
                    notify(name.ToString(), reply["data"]);
                    continue;
                }
                if (reply?["id"]?.GetValue<long>() is not { } id || !calls.TryRemove(id, out var pending)) continue;
                if (reply["error"] is not null) pending.TrySetException(new ProtocolException(reply));
                else pending.TrySetResult(reply["data"]);
            }
        }
        catch (Exception error) when (error is IOException or JsonException or ObjectDisposedException or InvalidOperationException) { }
        finally
        {
            closed = true;
            foreach (var call in calls.Values) call.TrySetException(new IOException(stopReason));
            calls.Clear();
            notify("stopped", JsonValue.Create(stopReason));
        }
    }

    public async Task<JsonNode?> Send(string op, object? args = null)
    {
        if (closed) throw new IOException(stopReason);
        var id = Interlocked.Increment(ref counter);
        var promise = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        calls[id] = promise;
        try
        {
            await writer.WaitAsync().ConfigureAwait(false);
            try
            {
                if (closed) throw new IOException(stopReason);
                await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, op, args })).ConfigureAwait(false);
            }
            finally { writer.Release(); }
            return await promise.Task.ConfigureAwait(false);
        }
        finally { calls.TryRemove(id, out _); }
    }

    public void Notify(string op, object args) => _ = NotifyAsync(op, args);

    private async Task NotifyAsync(string op, object args)
    {
        try { await Send(op, args).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException) { }
    }

    public void Voice(string group, byte[] packet, byte audioLevel)
    {
        // Capture never builds an unbounded queue behind a busy protocol pipe.
        if (closed || !writer.Wait(0)) return;
        try { process.StandardInput.WriteLine(JsonSerializer.Serialize(new { op = "voice", args = new { group, packet, audioLevel } })); }
        catch (Exception e) when (e is IOException or InvalidOperationException) { }
        finally { writer.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        closed = true;
        if (await writer.WaitAsync(TimeSpan.FromMilliseconds(500)))
        {
            try { process.StandardInput.Close(); }
            catch (IOException) { }
            finally { writer.Release(); }
        }
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4)); }
        catch (TimeoutException)
        {
            if (!process.HasExited) process.Kill(true);
            await process.WaitForExitAsync();
        }
        finally { process.Dispose(); }
    }
}

internal static class JsonValueAccess
{
    public static string Str(this JsonNode? node, string key) => node?[key]?.ToString() ?? "";
    public static bool Bool(this JsonNode? node, string key) => node?[key]?.GetValue<bool>() == true;
    public static long Num(this JsonNode? node, string key) => node?[key]?.GetValue<long>() ?? 0;
    public static JsonArray List(this JsonNode? node, string key) => node?[key] as JsonArray ?? new();
}
