namespace TechnitiumUniFiInsightsExporter;

public sealed class ExporterConfiguration
{
    public bool Enabled { get; init; }
    public DestinationConfiguration? Destination { get; init; }
    public NodePolicyConfiguration NodePolicy { get; init; } = new();
    public SyslogConfiguration Syslog { get; init; } = new();
    public QueueConfiguration Queue { get; init; } = new();
    public FilterConfiguration Filters { get; init; } = new();
    public ObservabilityConfiguration Observability { get; init; } = new();
}

public sealed class DestinationConfiguration
{
    public string? Address { get; init; }
    public int Port { get; init; }
    public string Protocol { get; init; } = "UDP";
}

public sealed class NodePolicyConfiguration
{
    public string Mode { get; init; } = "allowList";
    public string[] ServerDomains { get; init; } = [];
}

public sealed class SyslogConfiguration
{
    public int Priority { get; init; } = 134;
    public string HostnameMode { get; init; } = "serverDomain";
    public string AppName { get; init; } = "dnsmasq";
    public string ProcessId { get; init; } = "1";
    public string TimeZone { get; init; } = "Europe/Berlin";
}

public sealed class QueueConfiguration
{
    public int Capacity { get; init; } = 50_000;
    public string FullMode { get; init; } = "dropNewest";
    public int ShutdownDrainTimeoutSeconds { get; init; } = 5;
}

public sealed class FilterConfiguration
{
    public string[] ExcludeQueryTypes { get; init; } = ["SOA", "IXFR", "AXFR"];
    public string[] ExcludeDomains { get; init; } = [];
    public string[] ExcludeSuffixes { get; init; } = [];
    public string[] ExcludeRegex { get; init; } = [];
    public bool StripTrailingDot { get; init; } = true;
    public ClusterNoiseConfiguration ClusterNoise { get; init; } = new();
}

public sealed class ClusterNoiseConfiguration
{
    public string[] ClientAddresses { get; init; } = [];
    public string[] DomainContains { get; init; } = [];
    public bool ExcludeReverseLookups { get; init; }
}

public sealed class ObservabilityConfiguration
{
    public bool LogStartupSummary { get; init; } = true;
    public bool LogPeriodicCounters { get; init; } = true;
    public int CounterIntervalSeconds { get; init; } = 300;
    public bool IncludeQueryDataInLogs { get; init; }
}
