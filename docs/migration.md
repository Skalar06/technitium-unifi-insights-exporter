# Migration

1. Validate the disabled app on the full cluster.
2. Canary one resolver through the node allowlist.
3. Expand the allowlist to both production resolvers and verify their distinct RFC3164 hostnames.
4. Disable all legacy Log Exporter sinks while keeping the app installed.
5. Deactivate only the DNS-specific n8n workflow.
6. Stop, but do not delete, the dedicated relay stack.
7. Keep n8n and unrelated workflows running.
8. Observe counters, DNS latency, receiver parsing, duplicate rate, and cluster health for 30 minutes, then retain rollback components for at least 24 hours.

Avoid extended parallel operation because UniFi Insights Plus performs no deduplication.

The previously reconstructed legacy filters exclude SOA, IXFR, AXFR and optionally suppress cluster/reverse traffic only for configured resolver-origin client addresses. This behavior maps to `filters.clusterNoise`; no internal values belong in the repository.
