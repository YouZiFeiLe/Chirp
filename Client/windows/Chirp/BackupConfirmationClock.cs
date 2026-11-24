namespace Chirp;

internal sealed class BackupConfirmationClock
{
    private long elapsed;
    private long? visibleSince;

    internal void SetVisible(bool visible, long now)
    {
        if (visibleSince is long start) elapsed += Math.Max(0, now - start);
        visibleSince = visible ? now : null;
    }

    internal int Remaining(long now)
    {
        var time = elapsed + (visibleSince is long start ? Math.Max(0, now - start) : 0);
        return (int)((Math.Max(0, 5000 - time) + 999) / 1000);
    }
}
