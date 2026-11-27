namespace Chirp;

// Shared by every window on the UI dispatcher. The first foreground attempt
// consumes automatic prompting, even if Hello is cancelled or the network fails.
internal sealed class LoginLock
{
    public long Expires { get; private set; }
    public byte[] WrappedKey { get; private set; } = [];
    public bool Locked => Expires != 0;
    public string? Attempt { get; private set; }
    private bool automatic;

    public void Load(long expires, byte[] wrappedKey, long now)
    {
        Clear();
        if (expires <= now || wrappedKey.Length != 256) return;
        Expires = expires;
        WrappedKey = wrappedKey;
        automatic = true;
    }

    public string? Begin(bool manual, long now)
    {
        if (Expires <= now || Attempt is not null || !manual && !automatic) return null;
        automatic = false;
        return Attempt = Guid.NewGuid().ToString("N");
    }

    public bool Current(string id, long now) => Attempt == id && Expires > now;
    public void Interrupt() => Attempt = null;
    public void Clear() { Interrupt(); Expires = 0; WrappedKey = []; automatic = false; }
}
