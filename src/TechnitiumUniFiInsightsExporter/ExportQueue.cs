using System.Threading.Channels;

namespace TechnitiumUniFiInsightsExporter;

public sealed class ExportQueue
{
    private readonly Channel<QueryEvent> _channel;
    private readonly Counters _counters;

    public ExportQueue(int capacity, Counters counters)
    {
        _counters = counters;
        _channel = Channel.CreateBounded<QueryEvent>(new BoundedChannelOptions(capacity)
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
            FullMode = BoundedChannelFullMode.Wait,
        });
    }

    public ChannelReader<QueryEvent> Reader => _channel.Reader;

    public bool TryEnqueue(QueryEvent queryEvent)
    {
        if (!_channel.Writer.TryWrite(queryEvent))
        {
            _counters.Dropped();
            return false;
        }
        _counters.Accepted();
        _counters.Enqueued();
        return true;
    }

    public void Complete() => _channel.Writer.TryComplete();
}
