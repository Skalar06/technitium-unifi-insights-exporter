#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CI=false "${PROJECT_ROOT}/scripts/package.sh"
first="$(sha256sum "${PROJECT_ROOT}/dist/TechnitiumUniFiInsightsExporter-0.1.0.zip" | awk '{print $1}')"
rm -rf "${PROJECT_ROOT}/src/TechnitiumUniFiInsightsExporter/bin" "${PROJECT_ROOT}/src/TechnitiumUniFiInsightsExporter/obj"
CI=true "${PROJECT_ROOT}/scripts/package.sh"
second="$(sha256sum "${PROJECT_ROOT}/dist/TechnitiumUniFiInsightsExporter-0.1.0.zip" | awk '{print $1}')"

if [[ "${first}" != "${second}" ]]; then
  printf 'Package is not reproducible: %s != %s\n' "${first}" "${second}" >&2
  exit 1
fi
printf 'Reproducible package SHA256: %s\n' "${second}"
