using System.Text.Json;

namespace TechnitiumUniFiInsightsExporter.UnitTests;

public sealed class ConfigurationTests
{
    private static readonly JsonSerializerOptions CamelCaseJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    [Fact]
    public void MinimalDisabledConfigurationIsValid()
    {
        Assert.True(ConfigurationValidator.TryParse("{\"enabled\":false}", out ValidatedConfiguration? result, out string error), error);
        Assert.False(result!.Value.Enabled);
    }

    [Fact]
    public void CompleteEnabledConfigurationIsValid()
    {
        string json = JsonSerializer.Serialize(CreateValidConfiguration(), CamelCaseJson);
        Assert.True(ConfigurationValidator.TryParse(json, out ValidatedConfiguration? result, out string error), error);
        Assert.Equal("192.0.2.10", result!.DestinationAddress!.ToString());
    }

    [Theory]
    [InlineData("{\"enabled\":true}")]
    [InlineData("{\"enabled\":true,\"destination\":{\"address\":\"target.example\",\"port\":1516},\"nodePolicy\":{\"serverDomains\":[\"resolver.example\"]}}")]
    [InlineData("{\"enabled\":true,\"destination\":{\"address\":\"192.0.2.10\",\"port\":0},\"nodePolicy\":{\"serverDomains\":[\"resolver.example\"]}}")]
    [InlineData("{\"enabled\":true,\"destination\":{\"address\":\"192.0.2.10\",\"port\":1516}}")]
    [InlineData("{\"enabled\":false,\"unknownOption\":true}")]
    public void RejectsInvalidConfiguration(string json) => Assert.False(ConfigurationValidator.TryParse(json, out _, out _));

    [Fact]
    public void RejectsQueryLoggingAndUnsupportedRegex()
    {
        ExporterConfiguration config = WithObservabilityQueryLogging();
        Assert.False(ConfigurationValidator.TryParse(JsonSerializer.Serialize(config, CamelCaseJson), out _, out _));

        static ExporterConfiguration WithObservabilityQueryLogging() => new()
        {
            Enabled = true,
            Destination = new DestinationConfiguration { Address = "192.0.2.10", Port = 1516 },
            NodePolicy = new NodePolicyConfiguration { ServerDomains = ["resolver.example"] },
            Observability = new ObservabilityConfiguration { IncludeQueryDataInLogs = true },
        };
    }

    [Fact]
    public async Task NodeAllowListDisablesUnlistedServerBeforeQueueCreation()
    {
        ExporterConfiguration config = CreateValidConfiguration();
        ValidatedConfiguration validated = new(config, System.Net.IPAddress.Parse("192.0.2.10"), TimeZoneInfo.Utc);
        ExporterRuntime runtime = ExporterRuntime.Create(validated, "unlisted.example", _ => { });
        Assert.False(runtime.EnabledForNode);
        await runtime.DisposeAsync();
    }

    private static ExporterConfiguration CreateValidConfiguration() => new()
    {
        Enabled = true,
        Destination = new DestinationConfiguration { Address = "192.0.2.10", Port = 1516 },
        NodePolicy = new NodePolicyConfiguration { ServerDomains = ["resolver.example"] },
    };
}
