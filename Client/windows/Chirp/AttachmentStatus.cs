using System.Text.Json.Nodes;

namespace Chirp;

internal sealed record AttachmentStatus(string Name, bool Mine)
{
    internal long Number { get; init; }
    internal string Remote { get; init; } = "";
    internal bool Cached { get; init; }
    internal bool Running { get; init; }
    internal string Operation { get; init; } = "";
    internal bool Announced { get; init; }
    internal bool Complete { get; init; }
    internal bool Terminal { get; init; }
    internal bool Cancelling { get; init; }
    internal bool Retryable { get; init; }
    internal string Error { get; init; } = "";
    internal long Progress { get; init; }
    internal string Network { get; init; } = "";
    internal bool CanOpen => !Terminal && !Cancelling && !Running && Error.Length == 0 && (Cached || Remote == "completed");
    internal bool CanPause => !Mine && Running && Operation == "download" && !Terminal && !Cancelling;
    internal bool CanCancel => Mine && !Complete && !Terminal;
    internal bool CanRetry => Retryable && !Running && !Cancelling && !Terminal;

    internal AttachmentStatus Apply(JsonNode update)
    {
        var number = update.Num("number");
        if (number <= Number || Terminal) return this;
        return new(update.Str("name"), update.Bool("mine"))
        {
            Number = number, Remote = update.Str("state"), Cached = update.Bool("cached"), Complete = update.Bool("done"),
            Running = update.Bool("running"), Operation = update.Str("operation"), Announced = update.Bool("announced"),
            Terminal = update.Bool("terminal"), Cancelling = update.Bool("cancelling"),
            Retryable = update.Bool("retryable"), Error = update.Str("error"), Progress = update.Num("progress"), Network = update.Str("network")
        };
    }
}
