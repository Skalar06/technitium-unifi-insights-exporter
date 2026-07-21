using System.Net;
using System.Text;

namespace TechnitiumUniFiInsightsExporter.UnitTests;

public sealed class FormatterTests
{
    public static TheoryData<DateTime, string> TimestampCases => new()
    {
        { new DateTime(2026, 7, 1, 12, 5, 7, DateTimeKind.Utc), "Jul  1 14:05:07" },
        { new DateTime(2026, 7, 21, 12, 5, 7, DateTimeKind.Utc), "Jul 21 14:05:07" },
        { new DateTime(2026, 8, 1, 0, 0, 0, DateTimeKind.Utc), "Aug  1 02:00:00" },
        { new DateTime(2025, 12, 31, 23, 30, 0, DateTimeKind.Utc), "Jan  1 00:30:00" },
        { new DateTime(2026, 6, 1, 12, 0, 0, DateTimeKind.Utc), "Jun  1 14:00:00" },
        { new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc), "Jan  1 13:00:00" },
    };

    [Theory]
    [MemberData(nameof(TimestampCases))]
    public void FormatsRfc3164Timestamp(DateTime timestamp, string expectedTimestamp)
    {
        Rfc3164Formatter formatter = CreateFormatter();
        Assert.True(formatter.TryFormat(new QueryEvent(timestamp, IPAddress.Parse("192.0.2.53"), "example.org", "A"), out byte[]? payload));
        string line = Encoding.ASCII.GetString(payload!);
        Assert.Equal($"<134>{expectedTimestamp} resolver1.example.net dnsmasq[1]: query[A] example.org from 192.0.2.53", line);
    }

    [Fact]
    public void FormatsIpv6WithoutAdditionalLines()
    {
        Rfc3164Formatter formatter = CreateFormatter();
        Assert.True(formatter.TryFormat(new QueryEvent(new DateTime(2026, 7, 21, 12, 5, 7, DateTimeKind.Utc), IPAddress.Parse("2001:db8::53"), "example.org", "HTTPS"), out byte[]? payload));
        string line = Encoding.ASCII.GetString(payload!);
        Assert.EndsWith("query[HTTPS] example.org from 2001:db8::53", line);
        Assert.DoesNotContain('\n', line);
        Assert.DoesNotContain('\r', line);
    }

    private static Rfc3164Formatter CreateFormatter() => new(
        new SyslogConfiguration(),
        TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin"),
        "resolver1.example.net");
}
