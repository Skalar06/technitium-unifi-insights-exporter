#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"${PROJECT_ROOT}/scripts/build.sh"

for project in \
  tests/UnitTests/TechnitiumUniFiInsightsExporter.UnitTests.csproj \
  tests/IntegrationTests/TechnitiumUniFiInsightsExporter.IntegrationTests.csproj \
  tests/CompatibilityTests/TechnitiumUniFiInsightsExporter.CompatibilityTests.csproj; do
  run_dotnet test "${project}" \
    --configuration Release \
    --no-build \
    -p:TechnitiumReferencePath=/src/.references/15.4.0 \
    --logger "console;verbosity=normal"
done

run_dotnet format TechnitiumUniFiInsightsExporter.slnx \
  --verify-no-changes \
  --no-restore
