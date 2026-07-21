using System.Net;
using System.Net.Sockets;

namespace TechnitiumUniFiInsightsExporter;

public sealed class UdpExportWorker : IAsyncDisposable
{
    private static readonly TimeSpan[] Backoff =
    [
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(5),
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(30),
    ];

    private readonly ExportQueue _queue;
    private readonly Counters _counters;
    private readonly Rfc3164Formatter _formatter;
    private readonly IPEndPoint _destination;
    private readonly Action<string> _log;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _workerTask;
    private Socket? _socket;
    private DateTime _nextErrorLogUtc;

    public UdpExportWorker(ExportQueue queue, Counters counters, Rfc3164Formatter formatter, IPEndPoint destination, Action<string> log)
    {
        _queue = queue;
        _counters = counters;
        _formatter = formatter;
        _destination = destination;
        _log = log;
        _workerTask = Task.Run(RunAsync);
    }

    private async Task RunAsync()
    {
        int backoffIndex = 0;
        try
        {
            await foreach (QueryEvent queryEvent in _queue.Reader.ReadAllAsync(_cancellation.Token).ConfigureAwait(false))
            {
                _counters.Dequeued();
                if (!_formatter.TryFormat(queryEvent, out byte[]? payload))
                {
                    _counters.FormatError();
                    continue;
                }

                try
                {
                    _socket ??= CreateSocket();
                    int sent = await _socket.SendToAsync(payload!, SocketFlags.None, _destination, _cancellation.Token).ConfigureAwait(false);
                    if (sent != payload!.Length)
                        throw new SocketException((int)SocketError.MessageSize);
                    _counters.Sent();
                    backoffIndex = 0;
                }
                catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
                {
                    _counters.SendError();
                    CloseSocket();
                    RateLimitedLog($"UDP export failed ({ex.GetType().Name}); the DNS query path remains unaffected.");
                    TimeSpan delay = Backoff[Math.Min(backoffIndex++, Backoff.Length - 1)];
                    try
                    {
                        await Task.Delay(delay, _cancellation.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        break;
                    }
                }
            }
        }
        catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            _counters.SendError();
            RateLimitedLog($"UDP export worker stopped unexpectedly ({ex.GetType().Name}); the DNS query path remains unaffected.");
        }
        finally
        {
            CloseSocket();
        }
    }

    public async ValueTask StopAsync(TimeSpan timeout)
    {
        _queue.Complete();
        Task completed = await Task.WhenAny(_workerTask, Task.Delay(timeout)).ConfigureAwait(false);
        bool timedOut = completed != _workerTask;
        if (timedOut)
        {
            _cancellation.Cancel();
        }
        try
        {
            await _workerTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        if (timedOut)
            _counters.DropPending(_counters.Snapshot().QueueDepth);
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation.Cancel();
        _queue.Complete();
        try
        {
            await _workerTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        CloseSocket();
        _cancellation.Dispose();
    }

    private Socket CreateSocket() => new(_destination.AddressFamily, SocketType.Dgram, ProtocolType.Udp);

    private void CloseSocket()
    {
        Socket? socket = Interlocked.Exchange(ref _socket, null);
        socket?.Dispose();
    }

    private void RateLimitedLog(string message)
    {
        DateTime now = DateTime.UtcNow;
        if (now < _nextErrorLogUtc)
            return;
        _nextErrorLogUtc = now.AddMinutes(1);
        _log(message);
    }
}
