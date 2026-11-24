using System.Security.Cryptography;
using System.Text;

namespace Chirp;

internal static class DesktopText
{
    internal static bool English(int choice, IEnumerable<string> preferred)
    {
        if (choice != 0) return choice == 2;
        foreach (var tag in preferred)
        {
            var parts = tag.Replace('_', '-').ToLowerInvariant().Split('-');
            if (parts[0] == "en") return true;
            if (parts[0] != "zh") continue;
            if (parts.Contains("hans")) return false;
            if (parts.Contains("hant") || parts.Any(x => x is "tw" or "hk" or "mo")) continue;
            return false;
        }
        return true;
    }

    internal static string Fingerprint(string key)
    {
        try
        {
            var bytes = Convert.FromBase64String(key);
            return bytes.Length == 32 ? Convert.ToHexStringLower(SHA256.HashData(bytes)) : "—";
        }
        catch (FormatException) { return "—"; }
    }

    internal static string WireText(string value) => value.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
    internal static bool FitsDraft(string value) => Encoding.UTF8.GetByteCount(value) <= 4096;
    internal static bool CanSend(string text) => !string.IsNullOrWhiteSpace(text) && FitsDraft(text)
        && !text.EnumerateRunes().Any(r => Rune.IsControl(r) && r.Value is not ('\n' or '\t'));
    internal static bool ValidName(string text) => text.Length > 0 && text.Trim() == text
        && text.EnumerateRunes().Count() <= 80 && !text.EnumerateRunes().Any(Rune.IsControl);
    internal static string LimitName(string text)
    {
        int length = 0, count = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (++count > 80) break;
            length += rune.Utf16SequenceLength;
        }
        return length == text.Length ? text : text[..length];
    }
}

internal sealed class RoomPresence
{
    private HashSet<string>? peers;
    private bool rebaseline;

    internal void Resynchronize() => rebaseline = peers is not null;
    internal void Reset() { peers = null; rebaseline = false; }
    internal List<bool> Confirm(IEnumerable<string> identities, string self)
    {
        var next = identities.ToHashSet(StringComparer.Ordinal);
        var sounds = new List<bool>();
        if (self.Length == 0 || !next.Remove(self)) return sounds;
        if (peers is null) sounds.Add(true);
        else if (!rebaseline)
        {
            if (!peers.IsSubsetOf(next)) sounds.Add(false);
            if (!next.IsSubsetOf(peers)) sounds.Add(true);
        }
        peers = next;
        rebaseline = false;
        return sounds;
    }
}

internal static class RoomClock
{
    internal static bool Fresh(long observed, long now) => observed > 0 && now >= observed && now - observed < 6000;
    internal static long? Remaining(long observed, long now, long server, long next)
    {
        if (!Fresh(observed, now) || next <= 0 || server <= 0) return null;
        return (long)Math.Max(0, Math.Ceiling(((double)next - server - (now - observed)) / 1000));
    }
}

internal sealed record AudioRoute(string Input, string Output, int Preset)
{
    internal AudioRoute WithAvailableEndpoints(Func<bool, string, string> activeId) => this with
    {
        Input = Input.Length > 0 && activeId(true, Input) == "" ? "" : Input,
        Output = Output.Length > 0 && activeId(false, Output) == "" ? "" : Output
    };

    internal void ApplyOrRestore(Action apply, Action restore, Action<Exception> restoreFailed)
    {
        try { apply(); }
        catch
        {
            try { restore(); }
            catch (Exception error) { restoreFailed(error); }
            throw;
        }
    }
}
