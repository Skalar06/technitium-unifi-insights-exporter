using System.Net;

namespace TechnitiumUniFiInsightsExporter.UnitTests;

public sealed class QueryFilterTests
{
    [Theory]
    [InlineData("example.org.", "example.org")]
    [InlineData("EXAMPLE.Org", "EXAMPLE.Org")]
    [InlineData("bücher.example", "xn--bcher-kva.example")]
    [InlineData("_dns._udp.example.org", "_dns._udp.example.org")]
    public void NormalizesValidNames(string input, string expected)
    {
        Assert.True(QueryFilter.TryNormalizeDomain(input, true, out string? result));
        Assert.Equal(expected, result);
    }

    [Theory]
    [InlineData("bad name.example")]
    [InlineData("bad\nname.example")]
    [InlineData(".example.org")]
    [InlineData("example.org..")]
    [InlineData("bad@name.example")]
    public void RejectsUnsafeNames(string input) => Assert.False(QueryFilter.TryNormalizeDomain(input, true, out _));

    [Fact]
    public void RejectsOverlongLabelAndDomain()
    {
        Assert.False(QueryFilter.TryNormalizeDomain(new string('a', 64) + ".example", true, out _));
        Assert.False(QueryFilter.TryNormalizeDomain(string.Join('.', Enumerable.Repeat(new string('a', 63), 5)), true, out _));
    }

    [Theory]
    [InlineData("A")]
    [InlineData("AAAA")]
    [InlineData("HTTPS")]
    [InlineData("SVCB")]
    [InlineData("PTR")]
    [InlineData("TXT")]
    [InlineData("CAA")]
    public void AcceptsSupportedAlphabeticTypes(string type)
    {
        QueryFilter filter = new(new FilterConfiguration());
        Assert.True(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, "example.org", type, out QueryEvent? result));
        Assert.Equal(type, result!.QueryType);
    }

    [Theory]
    [InlineData("SOA")]
    [InlineData("IXFR")]
    [InlineData("AXFR")]
    [InlineData("65280")]
    [InlineData("TYPE65280")]
    public void RejectsExcludedOrInsightsIncompatibleTypes(string type)
    {
        QueryFilter filter = new(new FilterConfiguration());
        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, "example.org", type, out _));
    }

    [Fact]
    public void DistinguishesFormatErrorsFromConfiguredFilters()
    {
        QueryFilter filter = new(new FilterConfiguration());
        Assert.Equal(QueryEvaluation.FormatError, filter.Evaluate(DateTime.UtcNow, IPAddress.Loopback, "bad name.example", "A", out _));
        Assert.Equal(QueryEvaluation.FormatError, filter.Evaluate(DateTime.UtcNow, IPAddress.Loopback, "example.org", "65280", out _));
        Assert.Equal(QueryEvaluation.Filtered, filter.Evaluate(DateTime.UtcNow, IPAddress.Loopback, "example.org", "SOA", out _));
    }

    [Fact]
    public void MapsIpv4MappedIpv6()
    {
        QueryFilter filter = new(new FilterConfiguration());
        Assert.True(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Parse("::ffff:192.0.2.53"), "example.org", "A", out QueryEvent? result));
        Assert.Equal("192.0.2.53", result!.ClientAddress.ToString());
    }

    [Fact]
    public void AppliesDomainSuffixRegexAndClusterNoiseFilters()
    {
        FilterConfiguration configuration = new()
        {
            ExcludeDomains = ["exact.example"],
            ExcludeSuffixes = ["suffix.example"],
            ExcludeRegex = ["^regex[0-9]+\\.example$"],
            ClusterNoise = new ClusterNoiseConfiguration
            {
                ClientAddresses = ["192.0.2.10"],
                DomainContains = ["cluster.example"],
                ExcludeReverseLookups = true,
            },
        };
        QueryFilter filter = new(configuration);

        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, "exact.example", "A", out _));
        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, "child.suffix.example", "A", out _));
        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Loopback, "regex12.example", "A", out _));
        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Parse("192.0.2.10"), "node.cluster.example", "A", out _));
        Assert.False(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Parse("192.0.2.10"), "1.2.0.192.in-addr.arpa", "PTR", out _));
        Assert.True(filter.TryCreateEvent(DateTime.UtcNow, IPAddress.Parse("192.0.2.11"), "node.cluster.example", "A", out _));
    }
}
