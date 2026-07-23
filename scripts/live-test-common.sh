#!/usr/bin/env bash
set -euo pipefail

readonly LIVE_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LIVE_TEST_RESULTS_DIR="${LIVE_TEST_ROOT}/artifacts/test-results"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command is unavailable: %s\n' "$1" >&2
    return 1
  }
}

require_live_approval() {
  if [[ "${EXPORTER_TEST_APPROVED:-}" != "yes" ]]; then
    printf '%s\n' 'Live test refused: set EXPORTER_TEST_APPROVED=yes after the concrete action-gate approval.' >&2
    return 2
  fi
}

require_numeric_ip() {
  local value="$1"
  python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "${value}" >/dev/null 2>&1 || {
    printf '%s\n' 'Receiver address must be a numerical IPv4 or IPv6 address.' >&2
    return 2
  }
}

require_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || {
    printf '%s\n' 'Port must be an integer between 1 and 65535.' >&2
    return 2
  }
}

append_result() {
  local output="$1"
  local name="$2"
  local status="$3"
  local expected="$4"
  local observed="$5"
  jq -cn \
    --arg name "${name}" \
    --arg status "${status}" \
    --arg expected "${expected}" \
    --arg observed "${observed}" \
    '{name:$name,status:$status,expected:$expected,observed:$observed}' >>"${output}"
}

write_result_array() {
  local input="$1"
  local output="$2"
  jq -s '.' "${input}" >"${output}"
}

assert_documentation_safe_fixtures() {
  local fixture_root="${LIVE_TEST_ROOT}/tests/fixtures"
  if rg -n -i \
    'home\.arpa|10\.10\.[0-9]{1,3}\.[0-9]{1,3}|cluster\.althir\.net|(^|[^0-9])2[0-9a-f]{3}:[0-9a-f:]+' \
    "${fixture_root}"; then
    printf '%s\n' 'Fixture safety validation failed.' >&2
    return 1
  fi
  jq -e 'type == "array" and length > 0' "${fixture_root}/invalid-config-cases.json" >/dev/null
  jq -e 'type == "array" and length > 0' "${fixture_root}/node-policy-cases.json" >/dev/null
}
