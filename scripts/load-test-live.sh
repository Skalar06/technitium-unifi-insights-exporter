#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/live-test-common.sh"

readonly QUERY_FILE="${LIVE_TEST_ROOT}/tests/fixtures/dns-queries.txt"

usage() {
  cat <<'EOF'
Usage: scripts/load-test-live.sh --check
       scripts/load-test-live.sh --apply --profile A|B|C|D|E

--check validates the harness without sending DNS traffic.
--apply runs one bounded dnsperf profile against an explicitly named test node.

Required for --apply:
  EXPORTER_TEST_APPROVED=yes
  TEST_RESOLVER_IP=<numeric address>
  TEST_EXPORT_MODE=baseline|enabled

Optional:
  TEST_DNS_PORT=53
  TEST_PROFILE_DURATION=<seconds>
  TEST_PROFILE_QPS=<queries/second>

Profiles D and E do not mutate the receiver. Their approved outage or receiver
slowdown must be performed separately and recorded in the resulting report.
EOF
}

check_harness() {
  local command_name
  for command_name in awk date jq python3; do
    require_command "${command_name}"
  done
  [[ -s "${QUERY_FILE}" ]] || {
    printf 'Query fixture is missing or empty: %s\n' "${QUERY_FILE}" >&2
    return 1
  }
  assert_documentation_safe_fixtures
  if command -v dnsperf >/dev/null 2>&1; then
    printf '%s\n' 'dnsperf=available'
  else
    printf '%s\n' 'dnsperf=missing (required only for --apply)'
  fi
  printf '%s\n' 'live_execution=false'
}

if [[ "${1:-}" == "--check" && "$#" -eq 1 ]]; then
  check_harness
  exit 0
fi
if [[ "${1:-}" != "--apply" || "${2:-}" != "--profile" || "$#" -ne 3 ]]; then
  usage >&2
  exit 2
fi

check_harness >/dev/null
require_live_approval
require_command dnsperf

readonly PROFILE="${3^^}"
readonly RESOLVER_IP="${TEST_RESOLVER_IP:-}"
readonly DNS_PORT="${TEST_DNS_PORT:-53}"
readonly EXPORT_MODE="${TEST_EXPORT_MODE:-}"
require_numeric_ip "${RESOLVER_IP}"
require_port "${DNS_PORT}"
[[ "${EXPORT_MODE}" == "baseline" || "${EXPORT_MODE}" == "enabled" ]] || {
  printf '%s\n' 'TEST_EXPORT_MODE must be baseline or enabled.' >&2
  exit 2
}

case "${PROFILE}" in
  A) default_duration=600; default_qps=50 ;;
  B) default_duration=600; default_qps=250 ;;
  C) default_duration=60; default_qps=1000 ;;
  D) default_duration=300; default_qps=250 ;;
  E) default_duration=300; default_qps=5000 ;;
  *) printf 'Unknown profile: %s\n' "${PROFILE}" >&2; exit 2 ;;
esac

readonly DURATION="${TEST_PROFILE_DURATION:-${default_duration}}"
readonly QPS="${TEST_PROFILE_QPS:-${default_qps}}"
[[ "${DURATION}" =~ ^[1-9][0-9]*$ && "${QPS}" =~ ^[1-9][0-9]*$ ]] || {
  printf '%s\n' 'Duration and QPS must be positive integers.' >&2
  exit 2
}

umask 077
work_dir="$(mktemp -d /tmp/technitium-exporter-load.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT INT TERM
raw_output="${work_dir}/dnsperf.txt"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

set +e
dnsperf -s "${RESOLVER_IP}" -p "${DNS_PORT}" -d "${QUERY_FILE}" \
  -l "${DURATION}" -Q "${QPS}" -t 3 >"${raw_output}" 2>&1
exit_code=$?
set -e
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

value_after_colon() {
  local label="$1"
  awk -F: -v label="${label}" '$1 ~ label {sub(/^[[:space:]]+/, "", $2); split($2, values, /[[:space:]]+/); print values[1]; exit}' "${raw_output}"
}

queries_sent="$(value_after_colon '^  Queries sent')"
queries_completed="$(value_after_colon '^  Queries completed')"
queries_lost="$(value_after_colon '^  Queries lost')"
actual_qps="$(value_after_colon '^  Queries per second')"
average_latency="$(value_after_colon '^  Average Latency')"
servfail="$(awk '/^  Response codes:/{for (i = 1; i <= NF; i++) if ($i == "SERVFAIL") {print $(i + 1); exit}}' "${raw_output}")"

mkdir -p "${LIVE_TEST_RESULTS_DIR}"
profile_result="${work_dir}/profile.json"
jq -n \
  --arg profile "${PROFILE}" \
  --arg mode "${EXPORT_MODE}" \
  --arg startedAt "${started_at}" \
  --arg finishedAt "${finished_at}" \
  --argjson duration "${DURATION}" \
  --argjson targetQps "${QPS}" \
  --arg sent "${queries_sent}" \
  --arg completed "${queries_completed}" \
  --arg lost "${queries_lost}" \
  --arg measuredQps "${actual_qps}" \
  --arg averageLatency "${average_latency}" \
  --arg servfail "${servfail}" \
  --argjson exitCode "${exit_code}" \
  'def number_or_null: if length == 0 then null else try tonumber catch null end;
   {profile:$profile,exportMode:$mode,startedAt:$startedAt,finishedAt:$finishedAt,durationSeconds:$duration,targetQueriesPerSecond:$targetQps,dnsperf:{exitCode:$exitCode,queriesSent:($sent|number_or_null),queriesCompleted:($completed|number_or_null),queriesLost:($lost|number_or_null),queriesPerSecond:($measuredQps|number_or_null),averageLatencySeconds:($averageLatency|number_or_null)},latency:{p50Milliseconds:null,p95Milliseconds:null,p99Milliseconds:null,maximumMilliseconds:null},dns:{timeouts:($lost|number_or_null),servfail:($servfail|number_or_null)},resources:{technitiumCpuPercent:null,technitiumRamBytes:null,totalRamBytes:null,threads:null,sockets:null,queueUtilization:null},exporter:{sent:null,dropped:null,formatError:null,sendError:null},receiver:{packets:null,records:null},externalActions:(if $profile == "D" then ["stop receiver at t+60s", "start receiver at t+180s"] elif $profile == "E" then ["apply an approved bounded receiver slowdown until controlled dropping occurs"] else [] end)}' \
  >"${profile_result}"

summary="${LIVE_TEST_RESULTS_DIR}/load-summary.json"
if [[ -f "${summary}" ]] && jq -e '.schemaVersion == 1 and (.profiles | type == "array")' "${summary}" >/dev/null 2>&1; then
  jq --slurpfile result "${profile_result}" \
    '.status = (if $result[0].dnsperf.exitCode == 0 then "partially-executed" else "failed" end)
     | .executed = true
     | .profiles = ([.profiles[] | select(.profile != $result[0].profile or .exportMode != $result[0].exportMode)] + $result)' \
    "${summary}" >"${work_dir}/summary.json"
else
  jq -n --slurpfile result "${profile_result}" \
    '{schemaVersion:1,status:(if $result[0].dnsperf.exitCode == 0 then "partially-executed" else "failed" end),executed:true,profiles:$result,limitations:[]}' \
    >"${work_dir}/summary.json"
fi
mv "${work_dir}/summary.json" "${summary}"

printf 'Load profile %s (%s) finished with dnsperf exit code %s; result=%s\n' \
  "${PROFILE}" "${EXPORT_MODE}" "${exit_code}" "${summary}"
exit "${exit_code}"
