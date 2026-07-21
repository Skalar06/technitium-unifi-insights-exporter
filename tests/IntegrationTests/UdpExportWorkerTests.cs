using System.Net;
using System.Net.Sockets;
using System.Text;

namespace TechnitiumUniFiInsightsExporter.IntegrationTests;

public sealed class UdpExportWorkerTests
{
    [Fact]
    public async Task SendsExactlyOneByteExactDatagramPerEvent()
    {
        using UdpClient receiver = new(new IPEndPoint(IPAddress.Loopback, 0));
        IPEndPoint endpoint = (IPEndPoint)receiver.Client.LocalEndPoint!;
        Counters counters = new();
        ExportQueue queue = new(10, counters);
        Rfc3164Formatter formatter = new(new SyslogConfiguration(), TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin"), "resolver1.example.net");
        await using UdpExportWorker worker = new(queue, counters, formatter, endpoint, _ => { });

        queue.TryEnqueue(new QueryEvent(new DateTime(2026, 7, 21, 12, 5, 7, DateTimeKind.Utc), IPAddress.Parse("192.0.2.53"), "example.org", "A"));
        UdpReceiveResult received = await receiver.ReceiveAsync(TestContext.Current.CancellationToken).AsTask().WaitAsync(TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken);

        Assert.Equal("<134>Jul 21 14:05:07 resolver1.example.net dnsmasq[1]: query[A] example.org from 192.0.2.53", Encoding.ASCII.GetString(received.Buffer));
        using (CancellationTokenSource noSecondDatagram = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken))
        {
            noSecondDatagram.CancelAfter(TimeSpan.FromMilliseconds(150));
            await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await receiver.ReceiveAsync(noSecondDatagram.Token));
        }
        await worker.StopAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(1, counters.Snapshot().Sent);
    }

    [Fact]
    public async Task SendsIpv6AndConcurrentEventsWithoutAdditionalLines()
    {
        using UdpClient receiver = new(new IPEndPoint(IPAddress.Loopback, 0));
        IPEndPoint endpoint = (IPEndPoint)receiver.Client.LocalEndPoint!;
        Counters counters = new();
        ExportQueue queue = new(500, counters);
        Rfc3164Formatter formatter = new(new SyslogConfiguration(), TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin"), "resolver1.example.net");
        await using UdpExportWorker worker = new(queue, counters, formatter, endpoint, _ => { });

        const int count = 200;
        Parallel.For(0, count, index =>
        {
            IPAddress address = index == 0 ? IPAddress.Parse("2001:db8::53") : IPAddress.Parse("192.0.2.53");
            Assert.True(queue.TryEnqueue(new QueryEvent(DateTime.UtcNow, address, $"q{index}.example.org", "AAAA")));
        });

        List<string> messages = [];
        for (int index = 0; index < count; index++)
        {
            UdpReceiveResult result = await receiver.ReceiveAsync(TestContext.Current.CancellationToken).AsTask().WaitAsync(TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken);
            messages.Add(Encoding.ASCII.GetString(result.Buffer));
        }
        await worker.StopAsync(TimeSpan.FromSeconds(1));

        Assert.Equal(count, messages.Count);
        Assert.All(messages, message => Assert.DoesNotContain('\n', message));
        Assert.Contains(messages, message => message.EndsWith("from 2001:db8::53", StringComparison.Ordinal));
        Assert.Equal(count, counters.Snapshot().Sent);
    }

    [Fact]
    public async Task ShutdownDuringLoadIsBounded()
    {
        using UdpClient receiver = new(new IPEndPoint(IPAddress.Loopback, 0));
        IPEndPoint endpoint = (IPEndPoint)receiver.Client.LocalEndPoint!;
        Counters counters = new();
        ExportQueue queue = new(20, counters);
        Rfc3164Formatter formatter = new(new SyslogConfiguration(), TimeZoneInfo.Utc, "resolver1.example.net");
        await using UdpExportWorker worker = new(queue, counters, formatter, endpoint, _ => { });
        for (int index = 0; index < 1000; index++)
            queue.TryEnqueue(new QueryEvent(DateTime.UtcNow, IPAddress.Loopback, $"q{index}.example.org", "A"));

        await worker.StopAsync(TimeSpan.FromMilliseconds(250));
        CounterSnapshot snapshot = counters.Snapshot();
        Assert.Equal(snapshot.Accepted, snapshot.Sent + snapshot.FormatError + snapshot.SendError + snapshot.QueueDepth);
    }

    [Fact]
    public async Task WorkerContainsSocketErrorsAndKeepsDnsPathIndependent()
    {
        Counters counters = new();
        ExportQueue queue = new(2, counters);
        Rfc3164Formatter formatter = new(new SyslogConfiguration(), TimeZoneInfo.Utc, "resolver1.example.net");
        // Sending to the IPv4 limited broadcast address with SO_BROADCAST disabled
        // deterministically exercises the SocketException path without a receiver.
        IPEndPoint unreachable = new(IPAddress.Broadcast, 1516);
        await using UdpExportWorker worker = new(queue, counters, formatter, unreachable, _ => { });
        Assert.True(queue.TryEnqueue(new QueryEvent(DateTime.UtcNow, IPAddress.Loopback, "example.org", "A")));

        DateTime deadline = DateTime.UtcNow.AddSeconds(3);
        while (counters.Snapshot().SendError == 0 && DateTime.UtcNow < deadline)
            await Task.Delay(20, TestContext.Current.CancellationToken);

        Assert.True(counters.Snapshot().SendError > 0);
        await worker.StopAsync(TimeSpan.FromMilliseconds(100));
    }
}
