#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
"${PROJECT_ROOT}/scripts/build.sh"

readonly VERSION="0.1.0"
readonly OUTPUT_DIR="${PROJECT_ROOT}/src/TechnitiumUniFiInsightsExporter/bin/Release/net10.0"
readonly STAGE_DIR="${PROJECT_ROOT}/artifacts/package-stage"
readonly DIST_DIR="${PROJECT_ROOT}/dist"
readonly ZIP_PATH="${DIST_DIR}/TechnitiumUniFiInsightsExporter-${VERSION}.zip"

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}" "${DIST_DIR}"
for file in TechnitiumUniFiInsightsExporter.dll TechnitiumUniFiInsightsExporter.deps.json dnsApp.config README.md LICENSE CHANGELOG.md package-manifest.json; do
  cp "${OUTPUT_DIR}/${file}" "${STAGE_DIR}/${file}"
done

find "${STAGE_DIR}" -type f -exec touch -d '2026-01-01T00:00:00Z' {} +
rm -f "${ZIP_PATH}" "${ZIP_PATH}.sha256"
(
  cd "${STAGE_DIR}"
  TZ=UTC LC_ALL=C find . -type f -printf '%P\n' | TZ=UTC LC_ALL=C sort | TZ=UTC zip -X -q "${ZIP_PATH}" -@
)
(
  cd "${DIST_DIR}"
  sha256sum "$(basename "${ZIP_PATH}")" > "$(basename "${ZIP_PATH}").sha256"
)
unzip -t "${ZIP_PATH}"
