# Architecture

## Technitium interface

The app implements the Technitium DNS Server 15.4 interfaces:

```csharp
Task IDnsApplication.InitializeAsync(IDnsServer dnsServer, string? config)
string? IDnsApplication.Description { get; }
void IDisposable.Dispose()
Task IDnsQueryLogger.InsertLogAsync(
    DateTime timestamp,
    DnsDatagram request,
    IPEndPoint remoteEP,
    DnsTransportProtocol protocol,
    DnsDatagram response)
```

Technitium invokes query loggers from its statistics consumer and does not await their returned tasks. The callback therefore catches every exception, performs no async or network work, calls `TryWrite`, and returns `Task.CompletedTask`.

Available callback data includes timestamp, client endpoint, QNAME, QTYPE, QCLASS, transport, RCODE, response type, answers, EDNS, and recursive round-trip metadata. Version 0.1.0 exports only timestamp, client IP, QNAME, and QTYPE because that is all the downstream parser can preserve.

## Data flow

```mermaid
flowchart LR
    A[Technitium query callback] --> B[Validate and filter]
    B --> C[Bounded in-memory channel]
    C --> D[Single background worker]
    D --> E[RFC3164 dnsmasq message]
    E --> F[Long-lived UDP socket]
    F --> G[UniFi Insights Plus]
```

1. Atomically read the current immutable runtime.
2. Check node policy before allocating an event.
3. Normalize and filter QTYPE, QNAME, and client address.
4. Add an immutable event with non-blocking `TryWrite` to a bounded channel.
5. A single worker formats and sends each accepted event through one UDP socket.
6. Errors update counters and are logged at most once per minute without query content.

The queue uses a capacity of 50,000, one reader, multiple writers, disabled synchronous continuations, and controlled rejection of the newest incoming write when full.

## Lifecycle

`InitializeAsync` is also the configuration reload hook. It validates a complete replacement runtime, atomically swaps it, stops periodic reporting for the old runtime, and drains the old queue within its configured timeout. Invalid configuration swaps to a disabled runtime.

`Dispose` stops reporting, completes the queue, drains for at most the configured timeout, cancels remaining work, and closes the socket. DNS processing never depends on successful export shutdown.

## Package

Technitium installs a flat ZIP of compiled application output. Technitium 15.4 discovers application assemblies from matching `*.deps.json` files, so both `TechnitiumUniFiInsightsExporter.dll` and `TechnitiumUniFiInsightsExporter.deps.json` are mandatory package entries. The project metadata manifest is informational; Technitium reads version and description from assembly metadata and stores configuration in `dnsApp.config`.
