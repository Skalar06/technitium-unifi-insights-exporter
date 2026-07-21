# Configuration

Configuration is strict JSON. Comments and trailing commas are accepted; unknown properties are rejected. When validation fails, export remains disabled and Technitium DNS continues normally.

| Field | Meaning |
| --- | --- |
| `enabled` | Global export switch. |
| `destination.address` | Numeric IPv4 or IPv6 destination. Names are rejected to prevent per-event DNS resolution. |
| `destination.port` | UDP port, 1-65535. |
| `destination.protocol` | Must be `UDP`. |
| `nodePolicy.mode` | Must be `allowList`. |
| `nodePolicy.serverDomains` | Exact, case-insensitive Technitium server domains allowed to export. |
| `syslog.priority` | RFC3164 PRI, 0-191. |
| `syslog.hostnameMode` | Must be `serverDomain`. |
| `syslog.appName` / `processId` | Safe ASCII syslog tokens. |
| `syslog.timeZone` | IANA timezone used for the RFC3164 timestamp. |
| `queue.capacity` | Bounded queue capacity, 1-1,000,000. |
| `queue.fullMode` | Must be `dropNewest`; the incoming event is rejected when full. |
| `queue.shutdownDrainTimeoutSeconds` | Bounded drain timeout, 0-60 seconds. |
| `filters.excludeQueryTypes` | Case-insensitive QTYPE denylist. |
| `filters.excludeDomains` | Exact case-insensitive domain denylist. |
| `filters.excludeSuffixes` | Domain and child-suffix denylist. |
| `filters.excludeRegex` | Case-insensitive non-backtracking expressions with a 100 ms timeout. |
| `filters.stripTrailingDot` | Removes the final QNAME root dot. |
| `filters.clusterNoise` | Applies only when both a listed client IP and a configured cluster/reverse condition match. |
| `observability.counterIntervalSeconds` | Counter summary interval, 10-86400 seconds. |
| `observability.includeQueryDataInLogs` | Must remain `false`. |

The public package is disabled and contains documentation addresses only. Production node names, client addresses, and internal suffixes belong in the protected runtime configuration and must not be committed.
