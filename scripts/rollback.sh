#!/usr/bin/env bash
set -euo pipefail

backup_path="${BACKUP_PATH:-}"
if [[ -z "${backup_path}" || ! -d "${backup_path}" ]]; then
  printf '%s\n' 'Rollback refused: BACKUP_PATH must identify a verified backup directory.' >&2
  exit 2
fi

if [[ "${1:-}" != "--apply" || "${TECHNITIUM_CHANGE_APPROVED:-}" != "yes" ]]; then
  printf 'Rollback dry-run using backup: %s\n' "${backup_path}"
  printf '%s\n' '1. Disable UniFi Insights Exporter.'
  printf '%s\n' '2. Restore the captured Log Exporter configuration.'
  printf '%s\n' '3. Reactivate the captured n8n workflow version.'
  printf '%s\n' '4. Start the preserved relay stack.'
  printf '%s\n' '5. Verify relay reachability, both resolvers, Insights ingestion, and cluster health.'
  exit 0
fi

printf '%s\n' 'Rollback mutation must run through the approved operator Gateway/MCP tools; no credentials are accepted by this script.' >&2
exit 2
