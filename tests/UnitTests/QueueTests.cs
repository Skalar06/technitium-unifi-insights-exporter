using System.Net;

namespace TechnitiumUniFiInsightsExporter.UnitTests;

public sealed class QueueTests
{
    [Fact]
    public void FullQueueDropsNewestWithoutBlocking()
    {
        Counters counters = new();
        ExportQueue queue = new(1, counters);
        QueryEvent queryEvent = new(DateTime.UtcNow, IPAddress.Loopback, "example.org", "A");

        Assert.True(queue.TryEnqueue(queryEvent));
        Assert.False(queue.TryEnqueue(queryEvent));
        CounterSnapshot snapshot = counters.Snapshot();
        Assert.Equal(1, snapshot.Accepted);
        Assert.Equal(1, snapshot.Dropped);
        Assert.Equal(1, snapshot.QueueDepth);
    }

    [Fact]
    public async Task CompletionAllowsReaderToFinish()
    {
        Counters counters = new();
        ExportQueue queue = new(2, counters);
        queue.TryEnqueue(new QueryEvent(DateTime.UtcNow, IPAddress.Loopback, "example.org", "A"));
        queue.Complete();
        List<QueryEvent> events = [];
        await foreach (QueryEvent item in queue.Reader.ReadAllAsync(TestContext.Current.CancellationToken))
            events.Add(item);
        Assert.Single(events);
    }
}
