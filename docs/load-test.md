# Load test

## Two distinct test layers

`./scripts/load-test.sh` is the deterministic in-process exporter stress test. `./scripts/load-test-live.sh` is the prepared DNS E2E harness and requires `dnsperf`, a numeric test-resolver address, and explicit approval.

## Completed synthetic run

Command:

```bash
./scripts/load-test.sh
```

Observed on 2026-07-21 after the packaging correction:

| Target rate | Result | Dropped | Final queue | p99 callback |
|---:|---|---:|---:|---:|
| 100/s | pass | 0 | 0 | 129.32 us |
| 500/s | pass | 0 | 0 | 109.69 us |
| 1,000/s | pass | 0 | 0 | 44.85 us |
| 5,000/s | pass | 0 | 0 | 33.48 us |

Runtime was 39.27 seconds and peak process RSS was 55,574,528 bytes. This validates the isolated callback/queue implementation, not DNS server latency or receiver ingestion.

## Prepared live profiles

| Profile | Duration | Target rate | Purpose |
|---|---:|---:|---|
| A | 10 min | 50 q/s | homelab continuous load |
| B | 10 min | 250 q/s | elevated mixed-QTYPE load |
| C | 60 s | 1,000 q/s | bounded burst or environment limit |
| D | 5 min | 250 q/s | receiver stopped at +60 s and restarted at +180 s |
| E | 5 min default | 5,000 q/s default | deliberately induced bounded queue saturation |

Validate without traffic:

```bash
./scripts/load-test-live.sh --check
```

Run one approved profile:

```bash
EXPORTER_TEST_APPROVED=yes \
TEST_RESOLVER_IP=<NUMERIC_TEST_RESOLVER_IP> \
TEST_EXPORT_MODE=baseline \
./scripts/load-test-live.sh --apply --profile A

EXPORTER_TEST_APPROVED=yes \
TEST_RESOLVER_IP=<NUMERIC_TEST_RESOLVER_IP> \
TEST_EXPORT_MODE=enabled \
./scripts/load-test-live.sh --apply --profile A
```

Profiles D and E never stop, slow, or reconfigure a receiver themselves. Those external actions need their own production-impact assessment and action-gate approval.

## Measurements and acceptance

`artifacts/test-results/load-summary.json` records dnsperf counts, throughput, and mean latency. Fields that need a separate metrics source—p50/p95/p99/max, CPU, RAM, threads, sockets, queue, exporter counters, receiver packets, and receiver records—remain JSON `null` until measured. Missing values are not treated as zero.

Baseline and enabled runs must use the same resolver, fixtures, duration, QPS, and surrounding conditions. Acceptance requires:

- no exporter-induced DNS failures, deadlocks, crashes, or unbounded growth;
- p95 increase no greater than 5% or 1 ms, whichever allowance is larger;
- dropping only during deliberate saturation;
- automatic recovery after receiver return;
- no sensitive DNS content in normal logs.

## Current status

The live profiles are prepared but not executed. `dnsperf` was not installed in the preparation environment, so no baseline-versus-export latency claim is made.
