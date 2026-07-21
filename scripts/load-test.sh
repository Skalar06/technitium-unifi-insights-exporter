#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"${PROJECT_ROOT}/scripts/build.sh"
run_dotnet run \
  --project tests/LoadTests/TechnitiumUniFiInsightsExporter.LoadTests.csproj \
  --configuration Release \
  --no-build \
  -p:TechnitiumReferencePath=/src/.references/15.4.0
