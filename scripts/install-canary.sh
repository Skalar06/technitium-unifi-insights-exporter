#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "--apply" || "${TECHNITIUM_CHANGE_APPROVED:-}" != "yes" ]]; then
  printf '%s\n' 'Dry-run only. Installation requires --apply, TECHNITIUM_CHANGE_APPROVED=yes, a verified backup, and an explicit operator approval.'
  printf '%s\n' 'Install app name: UniFi Insights Exporter'
  printf '%s\n' 'Package: dist/TechnitiumUniFiInsightsExporter-0.1.0.zip'
  printf '%s\n' 'Initial config: {"enabled":false}'
  exit 0
fi

printf '%s\n' 'Direct production mutation is intentionally not embedded in this public script.' >&2
printf '%s\n' 'Use the approved Technitium Admin API/Gateway path documented in docs/installation.md.' >&2
exit 2
