# Technitium UniFi Insights Exporter

`UniFi Insights Exporter` is a Technitium DNS Server query logger app that sends one dnsmasq-compatible RFC3164 UDP message per DNS query. It is designed for the DNS parser in UniFi Insights Plus 3.7.0.

```text
Technitium query callback
  -> validation and filters
  -> bounded in-memory channel
  -> background RFC3164 formatter
  -> long-lived UDP socket
  -> UniFi Insights Plus
```

The app never performs network I/O in Technitium's query callback. Queue saturation and export failures are fail-open: they increment counters and never fail DNS processing.

## Compatibility

- Technitium DNS Server 15.4.0
- .NET 10
- UniFi Insights Plus 3.7.0 dnsmasq parser
- IPv4 and IPv6 clients

Later Technitium major versions require a compatibility build and load test before production use.

## Output

```text
<134>Jul 21 14:05:07 resolver1.example.net dnsmasq[1]: query[A] example.org from 192.0.2.53
```

Exactly one `query[...]` message is emitted. The app does not emit `reply`, `forwarded`, or `cached` lines.

## Installation

1. Download the release ZIP and matching SHA256 file.
2. Verify the checksum.
3. In Technitium DNS Server, install the ZIP as `UniFi Insights Exporter`.
4. Keep the packaged `enabled: false` configuration for the first cluster load test.
5. Configure the numerical UDP receiver IP, port, and node allowlist.

Technitium preserves the existing `dnsApp.config` during an app update. See [installation](docs/installation.md) and [migration](docs/migration.md).

## Configuration

The package contains a disabled, public-safe example. A production configuration must explicitly enable export and provide at least one allowed server domain.

```json
{
  "enabled": true,
  "destination": {
    "address": "192.0.2.10",
    "port": 1516,
    "protocol": "UDP"
  },
  "nodePolicy": {
    "mode": "allowList",
    "serverDomains": ["resolver1.example.net", "resolver2.example.net"]
  }
}
```

Unknown properties and unsupported values disable export. No fallback destination is used. See [configuration](docs/configuration.md).

## Build and test

Docker is the only host prerequisite. The scripts use a digest-pinned .NET 10 SDK and verify the official Technitium 15.4.0 archive checksum.

```bash
./scripts/test.sh
./scripts/load-test.sh
./scripts/package.sh
./scripts/verify-reproducible.sh
```

Artifacts:

```text
dist/TechnitiumUniFiInsightsExporter-0.1.0.zip
dist/TechnitiumUniFiInsightsExporter-0.1.0.zip.sha256
```

## Security model

- no inbound listener;
- no credentials or secrets;
- numeric destination IP parsed once;
- no process spawning, per-query files, HTTP webhook, or dynamic code;
- bounded queue and bounded shutdown drain;
- no query names or client addresses in normal app logs;
- strict configuration and syslog-injection validation.

See [security](docs/security.md) and [rollback](docs/rollback.md).

## Known limitations

- UniFi Insights Plus stores the query name, query type, and client IP, but not the resolver node as a dedicated DNS field.
- UDP delivery is not acknowledged.
- RFC3164 contains no year or timezone. The configured timezone must match the receiver.
- RCODE, RTT, transport, answers, response type, and block status are available to the Technitium callback but intentionally lost in the downstream format.
- Unknown numeric DNS types are dropped because the Insights Plus 3.7.0 parser accepts alphabetic query types only.
- The exporter performs no downstream deduplication.

## Troubleshooting

- `disabled by configuration or node policy`: verify `enabled` and the exact local Technitium server domain.
- `sendError`: verify the numeric destination, UDP mapping, firewall, and receiver health.
- `dropped`: the bounded queue was full; inspect receiver health and load before increasing capacity.
- `formatError`: an event could not be represented safely or exceeded 1024 bytes.
- No DNS query data is written to app logs; use bounded receiver-side validation when diagnosing parsing.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
