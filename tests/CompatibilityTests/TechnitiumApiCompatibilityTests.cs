using System.Net;
using System.Reflection;
using DnsServerCore.ApplicationCommon;
using TechnitiumLibrary.Net.Dns;

namespace TechnitiumUniFiInsightsExporter.CompatibilityTests;

public sealed class TechnitiumApiCompatibilityTests
{
    [Fact]
    public void AppImplementsExactTechnitium154Interfaces()
    {
        Type appType = typeof(App);
        Assert.True(typeof(IDnsApplication).IsAssignableFrom(appType));
        Assert.True(typeof(IDnsQueryLogger).IsAssignableFrom(appType));
        Assert.NotNull(appType.GetConstructor(Type.EmptyTypes));

        MethodInfo method = typeof(IDnsQueryLogger).GetMethod(nameof(IDnsQueryLogger.InsertLogAsync))!;
        Assert.Equal(typeof(Task), method.ReturnType);
        Assert.Equal(
            [typeof(DateTime), typeof(DnsDatagram), typeof(IPEndPoint), typeof(DnsTransportProtocol), typeof(DnsDatagram)],
            method.GetParameters().Select(parameter => parameter.ParameterType).ToArray());
    }

    [Fact]
    public void AssemblyTargetsExpectedVersionAndHasNoThirdPartyRuntimeDependencies()
    {
        Assembly assembly = typeof(App).Assembly;
        Assert.Equal(new Version(0, 1, 0, 0), assembly.GetName().Version);
        string[] allowedPrefixes = ["System", "DnsServerCore.ApplicationCommon", "TechnitiumLibrary"];
        Assert.All(assembly.GetReferencedAssemblies(), reference =>
            Assert.Contains(allowedPrefixes, prefix => reference.Name!.StartsWith(prefix, StringComparison.Ordinal)));
    }

    [Fact]
    public async Task DisabledConfigurationLoadsWithoutStartingExport()
    {
        IDnsServer server = DispatchProxy.Create<IDnsServer, ServerProxy>();
        using App app = new();
        await app.InitializeAsync(server, "{\"enabled\":false}");
        Assert.Contains("disabled", ((ServerProxy)(object)server).Messages.Single(), StringComparison.OrdinalIgnoreCase);
    }

    public class ServerProxy : DispatchProxy
    {
        public List<string> Messages { get; } = [];

        protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
        {
            return targetMethod?.Name switch
            {
                "get_ApplicationName" => "UniFi Insights Exporter",
                "get_ServerDomain" => "resolver1.example.net",
                "WriteLog" => Capture(args),
                _ => targetMethod?.ReturnType.IsValueType == true ? Activator.CreateInstance(targetMethod.ReturnType) : null,
            };
        }

        private object? Capture(object?[]? args)
        {
            if (args is { Length: > 0 } && args[0] is string message)
                Messages.Add(message);
            return null;
        }
    }
}
