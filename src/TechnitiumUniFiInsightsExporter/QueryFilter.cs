using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

namespace TechnitiumUniFiInsightsExporter;

public enum QueryEvaluation
{
    Accepted,
    Filtered,
    FormatError,
}

public sealed class QueryFilter
{
    private readonly FilterConfiguration _configuration;
    private readonly HashSet<string> _excludedTypes;
    private readonly HashSet<string> _excludedDomains;
    private readonly string[] _excludedSuffixes;
    private readonly Regex[] _excludedRegex;
    private readonly HashSet<IPAddress> _clusterClientAddresses;

    public QueryFilter(FilterConfiguration configuration)
    {
        _configuration = configuration;
        _excludedTypes = new HashSet<string>(configuration.ExcludeQueryTypes, StringComparer.OrdinalIgnoreCase);
        _excludedDomains = new HashSet<string>(configuration.ExcludeDomains.Select(NormalizeConfiguredDomain), StringComparer.OrdinalIgnoreCase);
        _excludedSuffixes = configuration.ExcludeSuffixes.Select(NormalizeConfiguredDomain).ToArray();
        _excludedRegex = configuration.ExcludeRegex.Select(pattern => new Regex(
            pattern,
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking,
            TimeSpan.FromMilliseconds(100))).ToArray();
        _clusterClientAddresses = configuration.ClusterNoise.ClientAddresses
            .Select(IPAddress.Parse)
            .Select(NormalizeAddress)
            .ToHashSet();
    }

    public bool TryCreateEvent(DateTime timestamp, IPAddress address, string qname, string qtype, out QueryEvent? queryEvent)
        => Evaluate(timestamp, address, qname, qtype, out queryEvent) == QueryEvaluation.Accepted;

    public QueryEvaluation Evaluate(DateTime timestamp, IPAddress address, string qname, string qtype, out QueryEvent? queryEvent)
    {
        queryEvent = null;
        string normalizedType = qtype.ToUpperInvariant();
        if (normalizedType.Length == 0 || normalizedType.Any(c => !char.IsAsciiLetter(c)))
            return QueryEvaluation.FormatError;
        if (_excludedTypes.Contains(normalizedType))
            return QueryEvaluation.Filtered;
        if (!TryNormalizeDomain(qname, _configuration.StripTrailingDot, out string? normalizedDomain) || normalizedDomain is null)
            return QueryEvaluation.FormatError;
        string domain = normalizedDomain;
        if (_excludedDomains.Contains(domain))
            return QueryEvaluation.Filtered;
        if (_excludedSuffixes.Any(suffix => domain.Equals(suffix, StringComparison.OrdinalIgnoreCase) || domain.EndsWith('.' + suffix, StringComparison.OrdinalIgnoreCase)))
            return QueryEvaluation.Filtered;
        if (_excludedRegex.Any(regex => regex.IsMatch(domain)))
            return QueryEvaluation.Filtered;

        IPAddress normalizedAddress = NormalizeAddress(address);
        if (_clusterClientAddresses.Contains(normalizedAddress))
        {
            bool containsClusterName = _configuration.ClusterNoise.DomainContains.Any(value => domain.Contains(value, StringComparison.OrdinalIgnoreCase));
            bool reverse = _configuration.ClusterNoise.ExcludeReverseLookups &&
                (domain.EndsWith(".in-addr.arpa", StringComparison.OrdinalIgnoreCase) || domain.EndsWith(".ip6.arpa", StringComparison.OrdinalIgnoreCase));
            if (containsClusterName || reverse)
                return QueryEvaluation.Filtered;
        }

        queryEvent = new QueryEvent(
            timestamp.Kind switch
            {
                DateTimeKind.Utc => timestamp,
                DateTimeKind.Local => timestamp.ToUniversalTime(),
                _ => DateTime.SpecifyKind(timestamp, DateTimeKind.Utc),
            },
            normalizedAddress,
            domain,
            normalizedType);
        return QueryEvaluation.Accepted;
    }

    public static bool TryNormalizeDomain(string value, bool stripTrailingDot, out string? normalized)
    {
        normalized = null;
        if (string.IsNullOrEmpty(value) || value.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)))
            return false;

        string candidate = stripTrailingDot && value.EndsWith('.') ? value[..^1] : value;
        if (candidate.Length is < 1 or > 253 || candidate.StartsWith('.') || candidate.EndsWith('.'))
            return false;

        IdnMapping idn = new();
        string[] labels = candidate.Split('.');
        for (int index = 0; index < labels.Length; index++)
        {
            string label = labels[index];
            if (label.Length is < 1 or > 63)
                return false;
            try
            {
                if (label.Any(c => c > 127))
                    label = idn.GetAscii(label);
            }
            catch (ArgumentException)
            {
                return false;
            }

            if (label.Length is < 1 or > 63 || label.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '-' or '_' || (c == '*' && index == 0))))
                return false;
            labels[index] = label;
        }

        candidate = string.Join('.', labels);
        if (candidate.Length > 253)
            return false;
        normalized = candidate;
        return true;
    }

    private static string NormalizeConfiguredDomain(string value) => value.Trim().TrimEnd('.');
    private static IPAddress NormalizeAddress(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
}
