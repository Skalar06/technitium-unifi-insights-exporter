using System.Diagnostics;
using System.Net;
using TechnitiumUniFiInsightsExporter;

int[] rates = [100, 500, 1000];
foreach (int rate in rates)
    await RunScenarioAsync(rate, TimeSpan.FromSeconds(10));
await RunScenarioAsync(5000, TimeSpan.FromSeconds(2));

static async Task RunScenarioAsync(int rate, TimeSpan duration)
{
    QueryFilter filter = new(new FilterConfiguration());
    Counters counters = new();
    ExportQueue queue = new(50_000, counters);
    long[] samples = new long[rate * (int)Math.Ceiling(duration.TotalSeconds)];
    Task consumer = Task.Run(async () =>
    {
        await foreach (QueryEvent _ in queue.Reader.ReadAllAsync())
            counters.Dequeued();
    });
    using Process process = Process.GetCurrentProcess();
    TimeSpan cpuStart = process.TotalProcessorTime;
    long rssStart = process.WorkingSet64;
    Stopwatch total = Stopwatch.StartNew();
    for (int index = 0; index < samples.Length; index++)
    {
        long started = Stopwatch.GetTimestamp();
        if (filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, $"q{index}.example.org", "A", out QueryEvent? queryEvent))
            queue.TryEnqueue(queryEvent!);
        samples[index] = Stopwatch.GetTimestamp() - started;
        TimeSpan expected = TimeSpan.FromSeconds((index + 1d) / rate);
        TimeSpan wait = expected - total.Elapsed;
        if (wait > TimeSpan.Zero)
            Thread.Sleep(wait);
    }
    total.Stop();
    queue.Complete();
    await consumer;
    process.Refresh();
    Array.Sort(samples);
    static double Micros(long ticks) => ticks * 1_000_000d / Stopwatch.Frequency;
    long allocated = GC.GetTotalAllocatedBytes(precise: true);
    double p99 = Micros(samples[(int)(samples.Length * .99)]);
    CounterSnapshot snapshot = counters.Snapshot();
    Console.WriteLine($"rate={rate}/s events={samples.Length} elapsed={total.Elapsed.TotalSeconds:F2}s p50={Micros(samples[(int)(samples.Length * .50)]):F2}us p95={Micros(samples[(int)(samples.Length * .95)]):F2}us p99={p99:F2}us queueDepth={snapshot.QueueDepth} dropped={snapshot.Dropped} cpuMs={(process.TotalProcessorTime - cpuStart).TotalMilliseconds:F0} rssStart={rssStart} rssEnd={process.WorkingSet64} peakRss={process.PeakWorkingSet64} allocated={allocated} gen0={GC.CollectionCount(0)} gen1={GC.CollectionCount(1)} gen2={GC.CollectionCount(2)}");
    if (snapshot.Dropped != 0 || snapshot.QueueDepth != 0 || p99 >= 1000)
        Environment.ExitCode = 1;
}
