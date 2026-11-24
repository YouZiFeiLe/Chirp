using System.Text.Json.Nodes;

namespace Chirp;

internal sealed class ChatTimeline
{
    internal enum Delivery { Received, Sending, Sent, Failed }
    internal sealed class Message(string sender, string text, JsonNode? file, string entry, Delivery delivery, bool mine)
    {
        internal string Sender { get; } = sender;
        internal string Text { get; } = text;
        internal JsonNode? File { get; } = file;
        internal string Entry { get; } = entry;
        internal bool Mine { get; } = mine;
        internal long Sequence { get; set; }
        internal DateTimeOffset Time { get; } = DateTimeOffset.Now;
        internal Delivery Status { get; set; } = delivery;
    }
    private readonly List<Message> messages = new();
    internal IReadOnlyList<Message> Messages => messages;
    internal Message? Pending { get; private set; }
    internal bool Trimmed { get; private set; }
    internal bool Activated { get; private set; }
    internal long LatestSequence { get; private set; }
    internal void Activate() => Activated = true;
    internal int UnreadAfter(long sequence) => sequence == LatestSequence ? 0 : messages.Count(row => row.Sequence > sequence);
    internal string Draft { get; set; } = "";
    internal bool CanSend => Pending is null && DesktopText.CanSend(Draft);
    internal void Receive(string sender, string text, JsonNode? file, bool mine = false) =>
        Append(new(sender, text, file, "", Delivery.Received, mine));
    private void Append(Message row)
    {
        row.Sequence = ++LatestSequence;
        messages.Add(row);
        if (messages.Count <= 1000) return;
        messages.RemoveAt(0); Trimmed = true;
    }
    internal Message? Begin(string entry, string name)
    {
        if (!CanSend || entry.Length == 0) return null;
        var row = new Message(name, Draft, null, entry, Delivery.Sending, true);
        Draft = ""; Pending = row; Append(row); return row;
    }
    internal bool Finish(Message row, bool succeeded)
    {
        if (!ReferenceEquals(row, Pending)) return false;
        row.Status = succeeded ? Delivery.Sent : Delivery.Failed; Pending = null; return true;
    }
    internal bool Restore(Message row, string entry)
    {
        if (Draft.Length != 0 || row.Entry != entry || row.Status != Delivery.Failed || !messages.Contains(row)) return false;
        Draft = row.Text; return true;
    }
    internal void RemoveFiles() => messages.RemoveAll(row => row.File is not null);
    internal void Clear() { messages.Clear(); Pending = null; Draft = ""; Trimmed = Activated = false; LatestSequence = 0; }
}
