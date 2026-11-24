using System.Text.Json.Nodes;
using Chirp;

internal static class AttachmentActionChecks
{
    internal static async Task Run()
    {
        static void Check(bool pass, string reason) { if (!pass) throw new InvalidOperationException(reason); }
        var incoming = new AttachmentStatus("photo", false);
        var active = incoming.Apply(JsonNode.Parse("""{"number":1,"running":true,"operation":"download","state":"completed","network":"constrained"}""")!);
        Check(active.CanPause && !active.CanCancel && !active.CanRetry && !active.CanOpen && active.Network == "constrained", "incoming download actions");
        var paused = active.Apply(JsonNode.Parse("""{"number":2,"retryable":true,"error":"ATTACHMENT_PAUSED"}""")!);
        Check(paused.CanRetry && !paused.CanPause && !paused.CanCancel && !paused.CanOpen, "paused download actions");
        var failed = active.Apply(JsonNode.Parse("""{"number":3,"error":"ATTACHMENT_INTEGRITY"}""")!);
        Check(!failed.CanOpen && !failed.CanRetry, "integrity check failure cannot resume");
        var delivered = active.Apply(JsonNode.Parse("""{"number":4,"state":"delivered","cached":true,"done":true}""")!);
        Check(delivered.CanOpen && !delivered.CanCancel && delivered.Complete, "delivered cached copy can export");
        var exporting = delivered.Apply(JsonNode.Parse("""{"number":5,"state":"delivered","cached":true,"done":true,"running":true,"operation":"export"}""")!);
        Check(!exporting.CanPause && !exporting.CanCancel, "saving a local copy exposed remote transfer actions");
        Check(ReferenceEquals(delivered, delivered.Apply(JsonNode.Parse("""{"number":2,"running":true}""")!)), "late progress after completion");
        var cancelling = incoming.Apply(JsonNode.Parse("""{"number":5,"mine":true,"cancelling":true,"state":"reserved"}""")!);
        Check(cancelling.CanCancel && !cancelling.CanRetry && !cancelling.CanOpen, "unconfirmed outgoing cancellation");
        var expired = delivered.Apply(JsonNode.Parse("""{"number":6,"state":"expired","terminal":true}""")!);
        Check(!expired.CanOpen && !expired.CanCancel && !expired.CanRetry, "expired descriptor has no actions");
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        try { await Images.Thumbnail("cancelled.jpg", cancel.Token); throw new InvalidOperationException("cancelled selection opened a file"); }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
        Console.WriteLine("PASS attachment preparation cancellation, transfer permissions, cached export and stale progress");
    }
}
