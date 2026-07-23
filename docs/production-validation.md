# Production validation

## Status

Current recommendation: **not production-ready on the evidence collected in this branch**.

The code-level, packaging, security-content, synthetic load, isolated lifecycle/receiver-ingestion, and isolated receiver failure/recovery gates pass with documented measurement gaps. Packet capture, live baseline comparison, queue saturation, and the 12-hour stability run remain unexecuted. This status must not be upgraded from partial evidence.

## Executed checks

Initial unchanged run on 2026-07-21:

| Command | Runtime | Exit | Result | Relevant warning |
|---|---:|---:|---|---|
| `./scripts/test.sh` | 27.32 s | 0 | 50/50 passed | non-fatal SDK workload-verification warning |
| `./scripts/load-test.sh` | 35.57 s | 0 | all four synthetic profiles passed | none material |
| `./scripts/package.sh` | 5.20 s | 0 | package and SHA256 produced | none material |
| `./scripts/verify-reproducible.sh` | 14.82 s | 0 | same-mode reproducibility passed | none material |
| `./scripts/validate-public-content.sh` | under 1 s | 0 | public-content policy passed | none |

Cross-mode regression proof:

- Before correction, `CI=false` and `CI=true` produced different package SHA256 values; the cross-mode check failed with exit 1 in 17.69 seconds.
- The minimal correction makes `scripts/package.sh` invoke the existing build with `CI=true` and makes the reproducibility test compare `CI=false` against `CI=true` callers.
- After correction, the cross-mode check passed in 14.66 seconds with package SHA256 `ec9bad16a0ac4ea4fa22a58b00367304b7d4b0b9d9c22221e808f0cab4b9713b`.

Full post-correction rerun:

| Command | Runtime | Exit | Result |
|---|---:|---:|---|
| `./scripts/test.sh` | 27.93 s | 0 | 50/50 passed |
| `./scripts/load-test.sh` | 39.27 s | 0 | all profiles passed, zero drops |
| `./scripts/package.sh` | 8.74 s | 0 | pass |
| `./scripts/verify-reproducible.sh` | 15.08 s | 0 | cross-mode pass |
| `./scripts/validate-public-content.sh` | 0.10 s | 0 | pass |

Dependency audit reported no vulnerable packages. The observed GitHub Actions CI and CodeQL state at the base commit was successful; branch CI is not available until the branch is pushed and a pull request exists.

## Isolated E2E execution

On 2026-07-22, a digest-pinned disposable Technitium 15.4 node was tested against UniFi Insights Plus 3.7.0. The run lasted from `2026-07-21T22:11:11Z` through `2026-07-21T22:11:32Z`.

- 37 cases recorded: 15 pass, 22 `not-measured`, 0 fail;
- 11 expected and 11 observed receiver records;
- correct QNAME, A/AAAA/MX/TXT QTYPE, and documentation-safe client address;
- no receiver duplicates, disallowed allowlist records, or injection-name records;
- fresh installation and reinstall both loaded `enabled=false`;
- reload, restart, update, uninstall, and reinstall completed without DNS failure;
- no fixture QNAME was found in normal Technitium logs;
- no disposable Docker resource remained after cleanup.

The 22 `not-measured` results are network packet-count assertions. Host packet-capture privileges were unavailable, so exact datagram counts and raw PCAP validation are not claimed. Receiver-side correlation passed independently.

## Isolated receiver failure and recovery

On 2026-07-22, `EXPORTER_TEST_APPROVED=yes ./scripts/integration-test.sh --receiver-failure-recovery` completed in 238 seconds with exit 0. The report status is `partial` because host PCAP, kernel delivery acknowledgement for UDP, and send-error log-rate-limit behavior were not measured; all functional acceptance criteria exercised by this isolated test passed. Rate limiting was not exercised because the local UDP stack signaled no send error.

- Technitium 15.4 answered 85/85 queries across baseline, receiver-process outage, receiver-network disconnect, and both recovery phases; there were 0 timeouts and 0 SERVFAIL responses.
- Baseline ingestion was 5/5 with no duplicate. Process recovery and network recovery were each 10/10 with no duplicates, correct A/QNAME/client fields, and correct dnsmasq format.
- Recovery required no exporter reload and no Technitium restart.
- Of 50 events generated while the receiver process and listener were absent, 48 were observed after recovery. Of 10 events generated while the receiver was disconnected from the Docker bridge, 0 were observed after reconnect. This difference is recorded as observed UDP buffering behavior, not a delivery guarantee.
- Exporter counters advanced from accepted/sent 0/0 to 85/85. `dropped`, `formatError`, `sendError`, and final queue depth remained 0. A zero UDP `sendError` is not treated as proof of remote delivery.
- Normal Technitium logs contained 0 test QNAMEs, 0 test-client addresses in error lines, and 0 exception patterns. Three client-address matches were normal Technitium admin audit records and are separately identified with redacted context in the report.
- RSS rose by 9,132 KiB between the first and final sample but was not monotonic; threads fell from 32 to 27, while sockets stayed at 8 and file descriptors at 259. No sustained leak signal was observed in this bounded run.
- Cleanup left no named test container, test network, password file, or harness temporary directory.

No production exporter defect was demonstrated, so production code, queue policy, timeouts, logging intervals, socket lifecycle, configuration schema, and packet format were not changed. The authoritative result is `artifacts/test-results/receiver-failure-recovery-summary.json`.

Final validation after the receiver harness and documentation changes:

| Command | Runtime | Exit | Result |
|---|---:|---:|---|
| `./scripts/test.sh` | 28.106 s | 0 | 50/50 passed |
| `./scripts/load-test.sh` | 39.511 s | 0 | all four synthetic profiles passed, zero drops |
| `./scripts/package.sh` | 8.713 s | 0 | package structure valid |
| `./scripts/verify-reproducible.sh` | 14.628 s | 0 | cross-mode SHA256 matched |
| `./scripts/validate-public-content.sh` | 0.055 s | 0 | pass after neutralizing two temporary harness variable names |

The .NET commands continued to emit the known non-fatal workload-verification warning. Builds themselves reported zero warnings and zero errors. The final package SHA256 remained `ec9bad16a0ac4ea4fa22a58b00367304b7d4b0b9d9c22221e808f0cab4b9713b`.

## Prepared but not executed

- privileged packet capture;
- true IPv6-client and DNS-over-TCP validation;
- false-but-routable destination, explicit ICMP-unreachable, and host-firewall block variants;
- baseline and enabled profiles A through E;
- shutdown and reload under DNS load;
- at least 12 hours of stability metrics.

The machine-readable files under `artifacts/test-results/` are authoritative for execution status. `executed: false` means no result may be inferred.

## Staged rollout recommendation

After every prepared test passes and is documented:

1. Back up both resolver configurations, the installed app/config, and receiver configuration.
2. Keep the fallback resolver unchanged.
3. Install on one test resolver with `enabled: false`; verify DNS and zero egress.
4. Add one narrow resolver-to-receiver UDP rule and enable only that resolver.
5. Observe counters, DNS latency, receiver records, and logs through the agreed canary period.
6. Stop and roll back on any trigger in `rollback.md`.
7. Consider the second resolver only after explicit review and approval of the first-resolver evidence.

No release, tag, merge, or two-resolver enablement is justified by the current evidence.
