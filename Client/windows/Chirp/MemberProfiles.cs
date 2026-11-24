using System.Text.Json.Nodes;

namespace Chirp;

// This cache belongs to one login and is accessed on the UI dispatcher.
internal sealed class MemberProfiles<TImage>(Func<string, string, CancellationToken, Task<TImage>> download) where TImage : class
{
    private sealed class Member(JsonNode value)
    {
        internal JsonNode Value = value;
        internal TImage? Image;
        internal CancellationTokenSource? Loading;
    }

    private readonly Dictionary<string, Member> members = new();
    private readonly SemaphoreSlim slots = new(4);
    internal event Action? Changed;

    internal JsonNode? Profile(string identity) => members.GetValueOrDefault(identity.Split('.')[0])?.Value;
    internal TImage? Image(string identity) => members.GetValueOrDefault(identity.Split('.')[0])?.Image;

    internal void Reset()
    {
        foreach (var member in members.Values) member.Loading?.Cancel();
        members.Clear();
        Changed?.Invoke();
    }

    internal void Apply(JsonNode profile)
    {
        Merge(profile);
        Changed?.Invoke();
    }

    internal void Snapshot(JsonArray snapshot)
    {
        var present = new HashSet<string>();
        foreach (var profile in snapshot)
        {
            if (profile is null) continue;
            present.Add(profile.Str("id"));
            Merge(profile);
        }
        foreach (var id in members.Keys.Where(id => !present.Contains(id)).ToArray())
        {
            members[id].Loading?.Cancel();
            members.Remove(id);
        }
        Changed?.Invoke();
    }

    private void Merge(JsonNode profile)
    {
        var id = profile.Str("id");
        if (!members.TryGetValue(id, out var member)) members[id] = member = new Member(profile);
        if (profile.Num("profile_revision") < member.Value.Num("profile_revision")) return;
        var revision = profile.Str("avatar_revision");
        if (revision != member.Value.Str("avatar_revision"))
        {
            member.Loading?.Cancel();
            member.Loading = null;
            member.Image = null;
        }
        member.Value = profile;
        if (revision.Length == 0 || member.Image is not null || member.Loading is not null) return;
        var work = new CancellationTokenSource();
        member.Loading = work;
        _ = Fetch(member, id, revision, work);
    }

    private async Task Fetch(Member member, string id, string revision, CancellationTokenSource work)
    {
        try
        {
            await slots.WaitAsync(work.Token);
            try
            {
                for (var attempt = 0; ; attempt++)
                {
                    try
                    {
                        var image = await download(id, revision, work.Token);
                        if (work.IsCancellationRequested) return;
                        member.Image = image;
                        Changed?.Invoke();
                        return;
                    }
                    catch (ProtocolException ex) when (ex.Transient && attempt < 2)
                    { await Task.Delay(TimeSpan.FromMilliseconds(500 * (attempt + 1)), work.Token); }
                }
            }
            finally { slots.Release(); }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or FormatException or
            ArgumentException or System.Runtime.InteropServices.COMException) { /* A later snapshot retries. */ }
        finally
        {
            if (member.Loading == work) member.Loading = null;
            work.Dispose();
        }
    }
}
