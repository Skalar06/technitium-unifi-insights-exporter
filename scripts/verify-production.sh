#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'Production verification checklist:'
printf '%s\n' '- DNS resolution succeeds independently on both resolvers.'
printf '%s\n' '- App status and cluster state are healthy on all nodes.'
printf '%s\n' '- Counters show sent events without sustained queue depth, drops, or send errors.'
printf '%s\n' '- Insights contains exactly one correctly parsed A, AAAA, and HTTPS query per direct test.'
printf '%s\n' '- The legacy n8n workflow has no new DNS executions and the relay is stopped.'
