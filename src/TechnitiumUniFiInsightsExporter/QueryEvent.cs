using System.Net;

namespace TechnitiumUniFiInsightsExporter;

public sealed record QueryEvent(
    DateTime TimestampUtc,
    IPAddress ClientAddress,
    string Domain,
    string QueryType);
