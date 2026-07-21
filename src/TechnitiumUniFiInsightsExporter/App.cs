using System.Net;
using DnsServerCore.ApplicationCommon;
using TechnitiumLibrary.Net.Dns;

namespace TechnitiumUniFiInsightsExporter;

public sealed class App : IDnsApplication, IDnsQueryLogger
{
    private readonly SemaphoreSlim _configurationLock = new(1, 1);
    private ExporterRuntime _runtime = ExporterRuntime.Disabled();
    private CancellationTokenSource? _counterCancellation;
    private Task? _counterTask;
    private IDnsServer? _dnsServer;
    private int _disposed;

    public string Description => "Exports DNS queries as dnsmasq-compatible RFC3164 UDP messages for UniFi Insights Plus without blocking DNS processing.";

    public async Task InitializeAsync(IDnsServer dnsServer, string? config)
    {
        ArgumentNullException.ThrowIfNull(dnsServer);
        await _configurationLock.WaitAsync().ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
            _dnsServer = dnsServer;

            if (!ConfigurationValidator.TryParse(config, out ValidatedConfiguration? validated, out string error))
            {
                dnsServer.WriteLog($"[{dnsServer.ApplicationName}] Export disabled: {error}");
                await ReplaceRuntimeAsync(ExporterRuntime.Disabled(), null).ConfigureAwait(false);
                return;
            }

            ExporterRuntime replacement;
            try
            {
                replacement = ExporterRuntime.Create(validated!, dnsServer.ServerDomain, message => SafeLog(message));
            }
            catch (Exception ex)
            {
                dnsServer.WriteLog($"[{dnsServer.ApplicationName}] Export disabled: runtime initialization failed ({ex.GetType().Name}).");
                replacement = ExporterRuntime.Disabled();
            }

            await ReplaceRuntimeAsync(replacement, validated).ConfigureAwait(false);
            if (validated!.Value.Observability.LogStartupSummary)
            {
                string state = replacement.EnabledForNode ? "enabled" : "disabled by configuration or node policy";
                dnsServer.WriteLog($"[{dnsServer.ApplicationName}] Initialized: {state}; serverDomain={dnsServer.ServerDomain}; queueCapacity={validated.Value.Queue.Capacity}; destination={(replacement.EnabledForNode ? "configured UDP endpoint" : "inactive")}.");
            }
        }
        finally
        {
            _configurationLock.Release();
        }
    }

    public Task InsertLogAsync(DateTime timestamp, DnsDatagram request, IPEndPoint remoteEP, DnsTransportProtocol protocol, DnsDatagram response)
    {
        try
        {
            if (Volatile.Read(ref _disposed) != 0 || request.Question.Count == 0)
                return Task.CompletedTask;
            DnsQuestionRecord question = request.Question[0];
            Volatile.Read(ref _runtime).Process(timestamp, remoteEP.Address, question.Name, question.Type.ToString());
        }
        catch (Exception)
        {
            // Query logging is fail-open by design. Never affect DNS resolution.
        }
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;

        _configurationLock.Wait();
        try
        {
            StopCounterLoopAsync().GetAwaiter().GetResult();
            ExporterRuntime previous = Interlocked.Exchange(ref _runtime, ExporterRuntime.Disabled());
            previous.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            SafeLog($"Shutdown completed with an exporter error ({ex.GetType().Name}); DNS server shutdown continues.");
        }
        finally
        {
            _configurationLock.Release();
            _configurationLock.Dispose();
        }
    }

    private async Task ReplaceRuntimeAsync(ExporterRuntime replacement, ValidatedConfiguration? validated)
    {
        await StopCounterLoopAsync().ConfigureAwait(false);
        ExporterRuntime previous = Interlocked.Exchange(ref _runtime, replacement);
        await previous.DisposeAsync().ConfigureAwait(false);

        if (replacement.EnabledForNode && validated!.Value.Observability.LogPeriodicCounters)
        {
            _counterCancellation = new CancellationTokenSource();
            _counterTask = LogCountersAsync(replacement, TimeSpan.FromSeconds(validated.Value.Observability.CounterIntervalSeconds), _counterCancellation.Token);
        }
    }

    private async Task StopCounterLoopAsync()
    {
        CancellationTokenSource? cancellation = Interlocked.Exchange(ref _counterCancellation, null);
        Task? task = Interlocked.Exchange(ref _counterTask, null);
        if (cancellation is null)
            return;
        cancellation.Cancel();
        if (task is not null)
        {
            try
            {
                await task.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        cancellation.Dispose();
    }

    private async Task LogCountersAsync(ExporterRuntime runtime, TimeSpan interval, CancellationToken cancellationToken)
    {
        using PeriodicTimer timer = new(interval);
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            CounterSnapshot counters = runtime.Counters.Snapshot();
            SafeLog($"Counters: accepted={counters.Accepted}, filtered={counters.Filtered}, sent={counters.Sent}, dropped={counters.Dropped}, formatError={counters.FormatError}, sendError={counters.SendError}, queueDepth={counters.QueueDepth}, lastSuccessfulSendUtc={FormatTimestamp(counters.LastSuccessfulSendUtc)}, lastErrorUtc={FormatTimestamp(counters.LastErrorUtc)}.");
        }
    }

    private void SafeLog(string message)
    {
        try
        {
            IDnsServer? server = _dnsServer;
            server?.WriteLog($"[{server.ApplicationName}] {message}");
        }
        catch (Exception)
        {
        }
    }

    private static string FormatTimestamp(DateTime? timestamp) => timestamp?.ToString("O") ?? "never";
}
