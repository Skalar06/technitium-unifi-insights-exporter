using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace TechnitiumUniFiInsightsExporter;

public sealed record ValidatedConfiguration(
    ExporterConfiguration Value,
    IPAddress? DestinationAddress,
    TimeZoneInfo TimeZone);

public static class ConfigurationValidator
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        PropertyNameCaseInsensitive = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    public static bool TryParse(string? json, out ValidatedConfiguration? validated, out string error)
    {
        validated = null;
        error = string.Empty;

        try
        {
            ExporterConfiguration config = JsonSerializer.Deserialize<ExporterConfiguration>(json ?? "{}", JsonOptions)
                ?? throw new JsonException("Configuration is empty.");
            List<string> errors = Validate(config);
            if (errors.Count > 0)
            {
                error = string.Join(" ", errors);
                return false;
            }

            IPAddress? address = null;
            if (config.Enabled)
                _ = IPAddress.TryParse(config.Destination!.Address, out address);

            validated = new ValidatedConfiguration(config, address, TimeZoneInfo.FindSystemTimeZoneById(config.Syslog.TimeZone));
            return true;
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            error = $"Configuration is invalid: {ex.Message}";
            return false;
        }
        catch (Exception ex)
        {
            error = $"Configuration is invalid ({ex.GetType().Name}).";
            return false;
        }
    }

    public static List<string> Validate(ExporterConfiguration config)
    {
        List<string> errors = [];

        if (config.Observability is null || config.Queue is null || config.NodePolicy is null || config.Syslog is null || config.Filters is null)
        {
            errors.Add("Configuration sections nodePolicy, syslog, queue, filters, and observability must not be null.");
            return errors;
        }
        if (config.Filters.ClusterNoise is null)
        {
            errors.Add("filters.clusterNoise must not be null.");
            return errors;
        }

        if (config.Observability.IncludeQueryDataInLogs)
            errors.Add("observability.includeQueryDataInLogs must be false.");
        if (config.Observability.CounterIntervalSeconds is < 10 or > 86_400)
            errors.Add("observability.counterIntervalSeconds must be between 10 and 86400.");
        if (config.Queue.Capacity is < 1 or > 1_000_000)
            errors.Add("queue.capacity must be between 1 and 1000000.");
        if (config.Queue.ShutdownDrainTimeoutSeconds is < 0 or > 60)
            errors.Add("queue.shutdownDrainTimeoutSeconds must be between 0 and 60.");
        if (!config.Queue.FullMode.Equals("dropNewest", StringComparison.OrdinalIgnoreCase))
            errors.Add("queue.fullMode must be dropNewest.");
        if (!config.NodePolicy.Mode.Equals("allowList", StringComparison.OrdinalIgnoreCase))
            errors.Add("nodePolicy.mode must be allowList.");
        if (config.Enabled && config.NodePolicy.ServerDomains.Length == 0)
            errors.Add("nodePolicy.serverDomains must not be empty when enabled.");
        if (config.Syslog.Priority is < 0 or > 191)
            errors.Add("syslog.priority must be between 0 and 191.");
        if (!config.Syslog.HostnameMode.Equals("serverDomain", StringComparison.OrdinalIgnoreCase))
            errors.Add("syslog.hostnameMode must be serverDomain.");
        if (!IsSafeToken(config.Syslog.AppName, 1, 48))
            errors.Add("syslog.appName contains unsafe characters.");
        if (!IsSafeToken(config.Syslog.ProcessId, 1, 16))
            errors.Add("syslog.processId contains unsafe characters.");

        try
        {
            _ = TimeZoneInfo.FindSystemTimeZoneById(config.Syslog.TimeZone);
        }
        catch (Exception ex) when (ex is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            errors.Add("syslog.timeZone is invalid.");
        }

        if (config.Enabled)
        {
            if (config.Destination is null)
                errors.Add("destination is required when enabled.");
            else
            {
                if (!IPAddress.TryParse(config.Destination.Address, out _))
                    errors.Add("destination.address must be a numeric IPv4 or IPv6 address.");
                if (config.Destination.Port is < 1 or > 65_535)
                    errors.Add("destination.port must be between 1 and 65535.");
                if (!config.Destination.Protocol.Equals("UDP", StringComparison.OrdinalIgnoreCase))
                    errors.Add("destination.protocol must be UDP.");
            }
        }

        ValidateStringArray(config.NodePolicy.ServerDomains, "nodePolicy.serverDomains", errors, 255);
        ValidateStringArray(config.Filters.ExcludeQueryTypes, "filters.excludeQueryTypes", errors, 32);
        ValidateStringArray(config.Filters.ExcludeDomains, "filters.excludeDomains", errors, 253);
        ValidateStringArray(config.Filters.ExcludeSuffixes, "filters.excludeSuffixes", errors, 253);
        ValidateStringArray(config.Filters.ClusterNoise.DomainContains, "filters.clusterNoise.domainContains", errors, 253);

        foreach (string value in config.Filters.ClusterNoise.ClientAddresses)
        {
            if (!IPAddress.TryParse(value, out _))
                errors.Add("filters.clusterNoise.clientAddresses contains an invalid IP address.");
        }

        foreach (string pattern in config.Filters.ExcludeRegex)
        {
            try
            {
                _ = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(100));
            }
            catch (ArgumentException)
            {
                errors.Add("filters.excludeRegex contains an invalid or unsupported expression.");
            }
        }

        return errors;
    }

    private static bool IsSafeToken(string value, int min, int max) =>
        value.Length >= min && value.Length <= max && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.');

    private static void ValidateStringArray(IEnumerable<string> values, string name, List<string> errors, int maxLength)
    {
        if (values.Any(value => string.IsNullOrWhiteSpace(value) || value.Length > maxLength || value.Any(char.IsControl)))
            errors.Add($"{name} contains an empty, overlong, or unsafe value.");
    }
}
