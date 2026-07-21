# Rollback

Rollback triggers include app exceptions, DNS degradation, container restarts, cluster errors, missing receiver events, sustained queue growth, drops or send errors, incorrect client addresses or QTYPEs, duplicates, or measurable resource regression.

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
