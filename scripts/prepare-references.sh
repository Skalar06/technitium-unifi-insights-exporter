#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

archive_dir="${PROJECT_ROOT}/.cache/technitium"
archive_path="${archive_dir}/DnsServerPortable-${TECHNITIUM_VERSION}.tar.gz"
mkdir -p "${archive_dir}" "${TECHNITIUM_REFERENCE_DIR}"

if [[ ! -f "${archive_path}" ]]; then
  curl --fail --location --silent --show-error --output "${archive_path}" "${TECHNITIUM_ARCHIVE_URL}"
fi

actual_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${TECHNITIUM_ARCHIVE_SHA256}" ]]; then
  printf 'Technitium archive checksum mismatch.\n' >&2
  exit 1
fi

for assembly in DnsServerCore.ApplicationCommon.dll TechnitiumLibrary.Net.dll TechnitiumLibrary.dll; do
  tar --extract --gzip --file "${archive_path}" --directory "${TECHNITIUM_REFERENCE_DIR}" "${assembly}"
done
