using System.Globalization;
using System.Text;

namespace TechnitiumUniFiInsightsExporter;

public sealed class Rfc3164Formatter
{
    public const int MaximumDatagramBytes = 1024;
    private static readonly string[] Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    private readonly SyslogConfiguration _configuration;
    private readonly TimeZoneInfo _timeZone;
    private readonly string _hostname;

    public Rfc3164Formatter(SyslogConfiguration configuration, TimeZoneInfo timeZone, string hostname)
    {
        _configuration = configuration;
        _timeZone = timeZone;
        _hostname = ValidateHostname(hostname);
    }

    public bool TryFormat(QueryEvent queryEvent, out byte[]? bytes)
    {
        bytes = null;
        DateTime local = TimeZoneInfo.ConvertTimeFromUtc(queryEvent.TimestampUtc, _timeZone);
        string message = string.Create(
            CultureInfo.InvariantCulture,
            $"<{_configuration.Priority}>{Months[local.Month - 1]} {local.Day,2} {local:HH:mm:ss} {_hostname} {_configuration.AppName}[{_configuration.ProcessId}]: query[{queryEvent.QueryType}] {queryEvent.Domain} from {queryEvent.ClientAddress}");
        if (!message.All(char.IsAscii) || Encoding.ASCII.GetByteCount(message) > MaximumDatagramBytes)
            return false;
        bytes = Encoding.ASCII.GetBytes(message);
        return true;
    }

    private static string ValidateHostname(string hostname)
    {
        if (!QueryFilter.TryNormalizeDomain(hostname, true, out string? candidate) || candidate is null || candidate.Contains('*'))
            throw new ArgumentException("Server domain is not a safe RFC3164 hostname.", nameof(hostname));
        return candidate;
    }
}
