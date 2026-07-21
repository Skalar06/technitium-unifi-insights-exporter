#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for pattern in \
  '10\.10\.[0-9]{1,3}\.[0-9]{1,3}' \
  'cluster\.althir\.net' \
  'home\.arpa' \
  'Tg9HDazIJTo8ycJs' \
  '(api[_-]?key|token|password|secret)[[:space:]]*[:=][[:space:]]*[^[:space:]$<{]'; do
  if rg -n -i --no-messages \
    --glob '!scripts/validate-public-content.sh' \
    --glob '!dist/**' --glob '!artifacts/**' --glob '!.cache/**' --glob '!.references/**' \
    --glob '!bin/**' --glob '!obj/**' \
    -- "${pattern}" "${PROJECT_ROOT}"; then
    printf 'Public-content validation failed for pattern category: %s\n' "${pattern}" >&2
    exit 1
  fi
done

printf '%s\n' 'Public-content validation passed.'
