# Integration test

This document separates completed local validation from prepared live validation. It contains only documentation-safe addresses and query names.

## Environment and topology

- Repository base: `5a57c0752e9aaa35bc4bf466fb7cf0a17aaca327`
- Branch: `test/integration-and-load-validation`
- Isolated image: digest-pinned Technitium DNS Server 15.4
- Receiver parser version observed before preparation: UniFi Insights Plus 3.7.0
- Fixtures: RFC 5737 IPv4, RFC 3849 IPv6, and `example.org`, `example.net`, `example.com`

```text
documentation-safe DNS client
  -> disposable Technitium 15.4 container
  -> one explicitly approved UDP receiver address and port
```

The disposable container is not a cluster member and does not modify either production resolver. Its packaged first-load configuration must contain `"enabled": false`.

## Commands

Preparation-only validation:

```bash
./scripts/package.sh
./scripts/integration-test.sh --check
```

Live execution, only after a separate concrete action-gate approval for the receiver traffic:

```bash
EXPORTER_TEST_APPROVED=yes \
TEST_RECEIVER_IP=<NUMERIC_TEST_RECEIVER_IP> \
TEST_RECEIVER_PORT=<UDP_PORT> \
./scripts/integration-test.sh --apply
```

`--apply` creates only `technitium-exporter-integration`, installs the package, verifies disabled first load, exercises invalid configurations and node policy cases, performs reload/restart/update/uninstall/reinstall checks, and removes the disposable resources on exit.

## Test matrix

The harness covers:

- fresh installation and disabled first load;
- enable, reload, disable, restart, same-package update, uninstall, reinstall;
- invalid numerical IP, hostname destination, invalid port, unsupported protocol, empty allowlist, unknown property, and wrong type;
- exact, case-insensitive, whitespace, empty, and unknown node names;
- A, AAAA, MX, TXT, NXDOMAIN, Punycode, and a maximum-length safe QNAME fixture;
- zero or one matching UDP datagram, subject to packet-capture permission;
- absence of fixture QNAMEs in normal Technitium logs.

Each case records expected and observed behavior in `artifacts/test-results/integration-summary.json`. Receiver-side acceptance and field correlation are deliberately not inferred from packet capture; they require a separate read-only receiver query after the run.

## Results as of 2026-07-22

Actually executed:

- command `EXPORTER_TEST_APPROVED=yes TEST_RECEIVER_IP=<redacted> TEST_RECEIVER_PORT=1516 ./scripts/integration-test.sh --apply`, runtime 21 seconds, exit 0;
- disposable Technitium 15.4 lifecycle test against UniFi Insights Plus 3.7.0;
- 37 recorded cases: 15 direct passes, 22 packet-count cases marked `not-measured`, and no failures;
- fresh install, disabled first load, enable/disable reload, restart, same-package update, uninstall, and reinstall;
- all seven invalid configurations with DNS remaining functional;
- exact and case-insensitive allowlist matches, with whitespace, empty, and unknown names rejected;
- 11 expected receiver records and 11 observed receiver records in the exact run window;
- correct A, AAAA, MX, and TXT fields and client address `192.0.2.1`;
- zero unexpected disallowed-name or injection-name records and no receiver duplicates;
- reinstall loaded the packaged `enabled=false` configuration;
- disposable container, network, and root-owned temporary files removed after the run.

Relevant warning: host packet-capture privileges were unavailable, so 22 network-layer assertions remain `not-measured` even though receiver-side ingestion was correlated successfully.

Prepared but not executed at the time of the lifecycle run:

- privileged packet capture and independent UDP datagram count;
- true IPv6-client and DNS-over-TCP source tests;
- receiver outage and recovery scenarios (executed separately below).

Actually executed locally:

- 50 automated tests passed: 43 unit, 4 UDP integration, and 3 API compatibility tests;
- package first-load configuration was verified as disabled;
- package generation and same-mode reproducibility passed;
- cross-mode reproduction initially failed and then passed after the CI-normalized package fix documented in `production-validation.md`.

The E2E receiver acceptance result is a pass with measurement gaps. It is not a full network-layer pass because packet capture was unavailable. The exact machine-readable status is in `artifacts/test-results/integration-summary.json`.

## Receiver failure and recovery execution

The isolated receiver failure/recovery mode reuses the lifecycle harness and does not reference a production resolver, receiver, firewall, VLAN, or secret:

```bash
EXPORTER_TEST_APPROVED=yes \
./scripts/integration-test.sh --receiver-failure-recovery
```

The completed run on 2026-07-22 used this documentation-safe topology:

```text
host dig client through 127.0.0.1:<ephemeral-published-port>
  -> Technitium 15.4 at 192.0.2.53 on an isolated Docker bridge
  -> UniFi Insights Plus 3.7.0 at 192.0.2.54:514/udp on the same bridge
```

Both images were digest-pinned. The receiver published no host port. Temporary receiver credentials existed only in a mode-0600 file in the harness work directory and were deleted during cleanup.

The final command ran for 238 seconds and exited 0. Its machine-readable status is `partial` because host PCAP, kernel-level UDP delivery acknowledgement, and active send-error log-rate-limit behavior were not measured. The latter could not be exercised because the local UDP stack reported no send error.

| Phase | Input | DNS result | Receiver result |
|---|---:|---:|---:|
| Receiver available | 5 `baseline-*` A queries | 5/5 successful | 5/5 records, 0 duplicates |
| Receiver process absent | 50 `outage-*` A queries over 35.080 s | 50/50 successful, 0 timeout, 0 SERVFAIL | 48 appeared after recovery |
| Process recovery | 10 `recovery-*` A queries | 10/10 successful | 10/10 records, 0 duplicates |
| Receiver disconnected from bridge | 10 `pathdown-*` A queries | 10/10 successful | 0 appeared after reconnect |
| Network recovery | 10 `pathrecovery-*` A queries | 10/10 successful | 10/10 records, 0 duplicates |

Across all 85 queries, measured DNS latency was 40 ms minimum, 71.294 ms mean, and 98 ms maximum. This is a functional outage test, not a baseline/export performance comparison.

The process-stop variant temporarily stopped only the isolated container's supervisor, terminated the isolated receiver process, and confirmed both process and UDP listener were absent. Resuming the supervisor restarted the receiver automatically. The second variant disconnected only the receiver container from the disposable bridge and reconnected it with the same documentation address. Neither variant reloaded the exporter nor restarted Technitium.

Exporter counters were measured through Technitium's authenticated local log API:

- before traffic: accepted/sent 0/0, dropped 0, sendError 0, queue depth 0;
- after the process outage: accepted/sent 55/55, dropped 0, sendError 0, queue depth 0;
- after both recoveries: accepted/sent 85/85, dropped 0, sendError 0, queue depth 0.

The zero `sendError` result is consistent with UDP semantics: an unconnected UDP send can succeed once the kernel accepts the datagram even when no remote listener or path exists. The receiver observations, not `sendError`, establish recovery. The 48 delayed process-outage records and zero delayed network-disconnect records are observed results; the harness does not assume a fixed buffering policy.

Normal Technitium logs contained zero test QNAMEs, zero test-client matches in error lines, zero unhandled-exception patterns, and zero exporter send-error messages. Consequently, log spam was absent but active send-error rate limiting was not exercised. Three occurrences of the documentation client address were separately classified as Technitium admin audit entries for login, app installation, and config save; they were not DNS query or exporter error records. Redacted examples are retained in the JSON report.

Resource samples before outage, during outage, after both recoveries, and after 120 seconds of stable recovery showed:

- RSS 127,564 KiB before and 136,696 KiB after stable recovery; growth was not monotonic;
- threads 32 before and 27 after stable recovery;
- sockets 8 at every sample;
- file descriptors 259 at every sample;
- no sustained resource growth matching the harness leak thresholds.

UniFi Insights Plus emitted schema-migration ownership warnings during ephemeral database initialization, but its database, parser, UDP listener, and API remained operational. These receiver-image warnings did not affect the measured exporter recovery result.

Harness defects found and corrected before the final run were limited to test infrastructure: an invalid Supervisor readiness assumption, a missing newline in latency aggregation, an `INET` comparison that omitted `host()`, an incorrect filesystem log location for Technitium 15.4, missing redaction for a receiver-generated proxy token, and an over-broad client-IP privacy matcher. No exporter production-code change was made.

## Acceptance criteria

- DNS remains functional for every configuration and lifecycle case.
- Invalid configuration results in no exported datagram and no fallback destination.
- Accepted queries produce exactly one message, no `reply`, `forwarded`, or `cached` message.
- Messages are at most 1024 bytes and contain no CR/LF injection.
- No unhandled exception and no query content in normal logs.
- Receiver fields match the captured QNAME, QTYPE, and client address without duplicates.

## Known limitations

- Packet capture may require privileges not available to the invoking user; such cases are marked `not-measured`, never passed by assumption.
- The current harness probes DNS over the published UDP endpoint. TCP and a true IPv6 client source require explicit environment-specific execution and documentation.
- Productive backups, firewall changes, receiver stop/start, and resolver configuration are intentionally outside this isolated harness.
