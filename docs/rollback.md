# Rollback

Rollback triggers include app exceptions, DNS degradation, container restarts, cluster errors, missing receiver events, sustained queue growth, drops or send errors, incorrect client addresses or QTYPEs, duplicates, or measurable resource regression.

## Required backups before a productive canary

- Technitium configuration export for the selected test resolver;
- exact installed app ZIP, SHA256, and current `dnsApp.config`;
- UniFi Insights Plus configuration export or documented receiver backup;
- current narrow firewall rule state;
- timestamps and checksums recorded outside public artifacts.

Do not store credentials, internal names, private addresses, public IPv6 prefixes, or real query data in this repository.

## Procedure

1. Disable `UniFi Insights Exporter` through the primary/admin node.
2. Restore the exact backed-up Log Exporter configuration.
3. Reactivate the backed-up version of the DNS-specific n8n workflow.
4. Start the preserved relay stack.
5. Verify relay reachability without exposing credentials.
6. Run direct tests through both resolvers.
7. Confirm correctly parsed receiver events and cluster health.
8. Record timestamps, actions, and observed recovery.

`scripts/rollback.sh` is intentionally dry-run by default and never accepts or prints secrets. Production mutations remain operator approval-gated and use the established Gateway/MCP paths.

## Exporter-only canary rollback

Use the least disruptive step that restores safe DNS operation:

1. Set the test resolver app configuration to `{ "enabled": false }` and verify zero exporter egress.
2. If reload is unhealthy, uninstall only the exporter from the test resolver and verify DNS directly.
3. Restore the backed-up app ZIP and `dnsApp.config` only if the prior version is required.
4. Remove only the dedicated resolver-to-receiver UDP firewall rule.
5. Verify the unchanged fallback resolver, then the test resolver, and record recovery.

Any restart, uninstall, restore, firewall change, or receiver lifecycle action requires its own concrete action-gate approval.

## Isolated harness cleanup

`scripts/integration-test.sh --apply` uses a trap to remove only the exact disposable container and network named `technitium-exporter-integration` plus its private temporary directory. It refuses to start if either Docker object already exists. If an interrupted shell leaves them behind, inspect their identity before any manual removal; do not use broad Docker prune commands.
