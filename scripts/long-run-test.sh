#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/live-test-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/long-run-test.sh --check
       scripts/long-run-test.sh --apply

--check validates the collector without contacting a resolver.
--apply records bounded DNS and host metrics for at least 12 hours by default.

Required for --apply:
  EXPORTER_TEST_APPROVED=yes
  TEST_RESOLVER_IP=<numeric address>

Optional:
  TEST_DNS_PORT=53
  LONG_RUN_DURATION_SECONDS=43200
  LONG_RUN_SAMPLE_INTERVAL_SECONDS=60
  TEST_CONTAINER_NAME=<isolated Technitium container name>

Run the approved realistic load generator separately. The collector itself
sends one documentation-safe DNS probe per sample interval.
EOF
}

check_harness() {
  local command_name
  for command_name in date dig jq python3 ss; do
    require_command "${command_name}"
  done
  printf 'docker=%s\n' "$(command -v docker >/dev/null 2>&1 && printf available || printf missing)"
  printf 'lsof=%s\n' "$(command -v lsof >/dev/null 2>&1 && printf available || printf missing)"
  printf 'pidstat=%s\n' "$(command -v pidstat >/dev/null 2>&1 && printf available || printf missing)"
  printf 'dotnet-counters=%s\n' "$(command -v dotnet-counters >/dev/null 2>&1 && printf available || printf missing)"
  printf '%s\n' 'live_execution=false'
}

if [[ "${1:-}" == "--check" && "$#" -eq 1 ]]; then
  check_harness
  exit 0
fi
if [[ "${1:-}" != "--apply" || "$#" -ne 1 ]]; then
  usage >&2
  exit 2
fi

check_harness >/dev/null
require_live_approval
readonly RESOLVER_IP="${TEST_RESOLVER_IP:-}"
readonly DNS_PORT="${TEST_DNS_PORT:-53}"
readonly DURATION="${LONG_RUN_DURATION_SECONDS:-43200}"
readonly INTERVAL="${LONG_RUN_SAMPLE_INTERVAL_SECONDS:-60}"
readonly CONTAINER_NAME="${TEST_CONTAINER_NAME:-}"
require_numeric_ip "${RESOLVER_IP}"
require_port "${DNS_PORT}"
[[ "${DURATION}" =~ ^[1-9][0-9]*$ && "${INTERVAL}" =~ ^[1-9][0-9]*$ ]] || {
  printf '%s\n' 'Duration and sample interval must be positive integers.' >&2
  exit 2
}
(( DURATION >= 43200 )) || {
  printf '%s\n' 'Long-run apply requires at least 43200 seconds (12 hours).' >&2
  exit 2
}
if [[ -n "${CONTAINER_NAME}" ]]; then
  require_command docker
  docker container inspect "${CONTAINER_NAME}" >/dev/null
fi

umask 077
work_dir="$(mktemp -d /tmp/technitium-exporter-long-run.XXXXXX)"
trap 'rm -rf "${work_dir}"' EXIT INT TERM
samples="${work_dir}/samples.jsonl"
started_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
deadline=$((started_epoch + DURATION))

while (( $(date +%s) < deadline )); do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dig_output="$(dig @"${RESOLVER_IP}" -p "${DNS_PORT}" example.org A +time=3 +tries=1 +stats +comments 2>&1 || true)"
  dns_status="$(awk '/status:/{sub(/,.*/, "", $6); print $6; exit}' <<<"${dig_output}")"
  query_time_ms="$(awk '/Query time:/{print $4; exit}' <<<"${dig_output}")"
  socket_total="$(ss -s | awk '/^Total:/{print $2; exit}')"
  container_stats='null'
  if [[ -n "${CONTAINER_NAME}" ]]; then
    container_stats="$(docker stats --no-stream --format '{{json .}}' "${CONTAINER_NAME}" | jq -c '{cpuPercent:.CPUPerc,memoryUsage:.MemUsage,pids:(.PIDs|tonumber?)}')"
  fi
  lsof_count='null'
  if command -v lsof >/dev/null 2>&1 && [[ -n "${CONTAINER_NAME}" ]]; then
    container_pid="$(docker inspect --format '{{.State.Pid}}' "${CONTAINER_NAME}")"
    lsof_count="$(lsof -p "${container_pid}" 2>/dev/null | awk 'END {print NR + 0}')"
  fi
  jq -cn \
    --arg timestamp "${timestamp}" \
    --arg dnsStatus "${dns_status:-unknown}" \
    --arg queryTimeMs "${query_time_ms:-}" \
    --arg socketTotal "${socket_total:-}" \
    --argjson container "${container_stats}" \
    --argjson lsofCount "${lsof_count}" \
    'def number_or_null: if length == 0 then null else try tonumber catch null end;
     {timestamp:$timestamp,dns:{status:$dnsStatus,queryTimeMilliseconds:($queryTimeMs|number_or_null)},host:{socketTotal:($socketTotal|number_or_null),lsofCount:$lsofCount},container:$container}' \
    >>"${samples}"
  sleep "${INTERVAL}"
done

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "${LIVE_TEST_RESULTS_DIR}"
jq -s \
  --arg startedAt "${started_at}" \
  --arg finishedAt "${finished_at}" \
  --argjson duration "${DURATION}" \
  --argjson interval "${INTERVAL}" \
  '{schemaVersion:1,status:(if length > 0 and all(.[]; .dns.status == "NOERROR" or .dns.status == "NXDOMAIN") then "completed" else "failed" end),executed:true,startedAt:$startedAt,finishedAt:$finishedAt,durationSeconds:$duration,sampleIntervalSeconds:$interval,environment:{resolverAddress:"redacted"},summary:{samples:length,dnsFailures:map(select(.dns.status != "NOERROR" and .dns.status != "NXDOMAIN"))|length,first:.[0],last:.[-1]},samples:.,limitations:["Exporter and receiver counters require separately captured redacted snapshots.","dotnet-counters is optional and was not invoked automatically."]}' \
  "${samples}" >"${LIVE_TEST_RESULTS_DIR}/long-run-summary.json"

printf 'Long-run test completed; result=%s\n' "${LIVE_TEST_RESULTS_DIR}/long-run-summary.json"
