#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"${PROJECT_ROOT}/scripts/prepare-references.sh"

run_dotnet restore TechnitiumUniFiInsightsExporter.slnx \
  -p:TechnitiumReferencePath=/src/.references/15.4.0
run_dotnet build TechnitiumUniFiInsightsExporter.slnx \
  --configuration Release \
  --no-restore \
  -p:TechnitiumReferencePath=/src/.references/15.4.0
