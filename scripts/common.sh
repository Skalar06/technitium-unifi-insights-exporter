#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0.100@sha256:c7445f141c04f1a6b454181bd098dcfa606c61ba0bd213d0a702489e5bd4cd71"
readonly TECHNITIUM_VERSION="15.4.0"
readonly TECHNITIUM_ARCHIVE_SHA256="461ac09d4304ace85093fc17b10a7ee13a8796eae0adb4393866bd4d66ab283f"
readonly TECHNITIUM_ARCHIVE_URL="https://download.technitium.com/dns/archive/15.4.0/DnsServerPortable.tar.gz"
readonly TECHNITIUM_REFERENCE_DIR="${PROJECT_ROOT}/.references/${TECHNITIUM_VERSION}"

run_dotnet() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env DOTNET_CLI_HOME=/tmp/dotnet \
    --env NUGET_PACKAGES=/src/.cache/nuget \
    --env TechnitiumReferencePath=/src/.references/15.4.0 \
    --env CI="${CI:-false}" \
    --volume "${PROJECT_ROOT}:/src" \
    --workdir /src \
    "${SDK_IMAGE}" \
    dotnet "$@"
}
