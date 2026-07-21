using System.Net;

namespace TechnitiumUniFiInsightsExporter;

internal sealed class ExporterRuntime : IAsyncDisposable
{
    private readonly QueryFilter? _filter;
    private readonly ExportQueue? _queue;
    private readonly UdpExportWorker? _worker;
    private readonly TimeSpan _drainTimeout;

    private ExporterRuntime(bool enabledForNode, QueryFilter? filter, ExportQueue? queue, UdpExportWorker? worker, Counters counters, TimeSpan drainTimeout)
    {
        EnabledForNode = enabledForNode;
        _filter = filter;
        _queue = queue;
        _worker = worker;
        Counters = counters;
        _drainTimeout = drainTimeout;
    }

    public bool EnabledForNode { get; }
    public Counters Counters { get; }

    public static ExporterRuntime Disabled() => new(false, null, null, null, new Counters(), TimeSpan.Zero);

    public static ExporterRuntime Create(ValidatedConfiguration validated, string serverDomain, Action<string> log)
    {
        ExporterConfiguration config = validated.Value;
        bool enabledForNode = config.Enabled && config.NodePolicy.ServerDomains.Contains(serverDomain, StringComparer.OrdinalIgnoreCase);
        if (!enabledForNode)
            return Disabled();

        Counters counters = new();
        ExportQueue queue = new(config.Queue.Capacity, counters);
        QueryFilter filter = new(config.Filters);
        Rfc3164Formatter formatter = new(config.Syslog, validated.TimeZone, serverDomain);
        IPEndPoint destination = new(validated.DestinationAddress!, config.Destination!.Port);
        UdpExportWorker worker = new(queue, counters, formatter, destination, log);
        return new ExporterRuntime(true, filter, queue, worker, counters, TimeSpan.FromSeconds(config.Queue.ShutdownDrainTimeoutSeconds));
    }

    public void Process(DateTime timestamp, IPAddress address, string qname, string qtype)
    {
        if (!EnabledForNode || _filter is null || _queue is null)
            return;
        QueryEvaluation evaluation = _filter.Evaluate(timestamp, address, qname, qtype, out QueryEvent? queryEvent);
        if (evaluation == QueryEvaluation.Filtered)
        {
            Counters.Filtered();
            return;
        }
        if (evaluation == QueryEvaluation.FormatError)
        {
            Counters.FormatError();
            return;
        }
        _queue.TryEnqueue(queryEvent!);
    }

    public async ValueTask DisposeAsync()
    {
        if (_worker is not null)
        {
            await _worker.StopAsync(_drainTimeout).ConfigureAwait(false);
            await _worker.DisposeAsync().ConfigureAwait(false);
        }
    }
}
