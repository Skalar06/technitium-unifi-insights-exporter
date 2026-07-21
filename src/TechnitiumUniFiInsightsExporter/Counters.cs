namespace TechnitiumUniFiInsightsExporter;

public sealed record CounterSnapshot(
    long Accepted,
    long Filtered,
    long Sent,
    long Dropped,
    long FormatError,
    long SendError,
    long QueueDepth,
    DateTime? LastSuccessfulSendUtc,
    DateTime? LastErrorUtc);

public sealed class Counters
{
    private long _accepted;
    private long _filtered;
    private long _sent;
    private long _dropped;
    private long _formatError;
    private long _sendError;
    private long _queueDepth;
    private long _lastSuccessfulSendTicks;
    private long _lastErrorTicks;

    public void Accepted() => Interlocked.Increment(ref _accepted);
    public void Filtered() => Interlocked.Increment(ref _filtered);
    public void Dropped() => Interlocked.Increment(ref _dropped);
    public void FormatError() => Interlocked.Increment(ref _formatError);
    public void Enqueued() => Interlocked.Increment(ref _queueDepth);
    public void Dequeued() => Interlocked.Decrement(ref _queueDepth);
    public void DropPending(long count)
    {
        if (count <= 0)
            return;
        Interlocked.Add(ref _dropped, count);
        Interlocked.Add(ref _queueDepth, -count);
    }
    public void Sent()
    {
        Interlocked.Increment(ref _sent);
        Interlocked.Exchange(ref _lastSuccessfulSendTicks, DateTime.UtcNow.Ticks);
    }
    public void SendError()
    {
        Interlocked.Increment(ref _sendError);
        Interlocked.Exchange(ref _lastErrorTicks, DateTime.UtcNow.Ticks);
    }

    public CounterSnapshot Snapshot() => new(
        Interlocked.Read(ref _accepted),
        Interlocked.Read(ref _filtered),
        Interlocked.Read(ref _sent),
        Interlocked.Read(ref _dropped),
        Interlocked.Read(ref _formatError),
        Interlocked.Read(ref _sendError),
        Interlocked.Read(ref _queueDepth),
        AsDateTime(Interlocked.Read(ref _lastSuccessfulSendTicks)),
        AsDateTime(Interlocked.Read(ref _lastErrorTicks)));

    private static DateTime? AsDateTime(long ticks) => ticks == 0 ? null : new DateTime(ticks, DateTimeKind.Utc);
}
