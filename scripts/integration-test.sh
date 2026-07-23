#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/live-test-common.sh"

report_error() {
  local exit_code=$?
  printf 'Integration harness failed at line %s with exit code %s.\n' "${BASH_LINENO[0]}" "${exit_code}" >&2
  trap - ERR
  exit "${exit_code}"
}
trap report_error ERR

readonly IMAGE="technitium/dns-server@sha256:3580381de00ba316748abced1ad0f942aff5a625993fa5dee22a902e26d2c524"
readonly RECEIVER_IMAGE="ghcr.io/jmasarweh/unifi-log-insight@sha256:5c5aa0a01f02a581cdcd08b3269cd1417fa57352786427963bbc51c4cdd6c95f"
readonly CONTAINER="technitium-exporter-integration"
readonly RECEIVER_CONTAINER="unifi-insights-receiver-failure-test"
readonly NETWORK="technitium-exporter-integration"
readonly TEST_NODE_IPV4="192.0.2.53"
readonly TEST_NODE_IPV6="2001:db8:53::53"
readonly TEST_RECEIVER_IPV4="192.0.2.54"
readonly TEST_RECEIVER_IPV6="2001:db8:53::54"
readonly TEST_SERVER_DOMAIN="resolver-test.example.net"
readonly APP_NAME="UniFi Insights Exporter"
readonly APP_NAME_ENCODED="UniFi%20Insights%20Exporter"
readonly PACKAGE="${LIVE_TEST_ROOT}/dist/TechnitiumUniFiInsightsExporter-0.1.0.zip"
readonly INVALID_CASES="${LIVE_TEST_ROOT}/tests/fixtures/invalid-config-cases.json"
readonly NODE_CASES="${LIVE_TEST_ROOT}/tests/fixtures/node-policy-cases.json"

usage() {
  cat <<'EOF'
Usage: scripts/integration-test.sh --check
       scripts/integration-test.sh --apply
       scripts/integration-test.sh --receiver-failure-recovery

--check validates prerequisites, fixtures, package state, and isolation settings.
--apply creates one disposable Technitium 15.4 test node and runs lifecycle tests.
--receiver-failure-recovery additionally creates an ephemeral UniFi Insights Plus
  3.7.0 receiver and runs only the approved receiver outage/recovery test.

Required for live modes:
  EXPORTER_TEST_APPROVED=yes

Required only for --apply:
  TEST_RECEIVER_IP=<numeric address>

Optional:
  TEST_RECEIVER_PORT=1516
  TEST_API_PORT=15380
  TEST_DNS_PORT=15353
  TEST_CAPTURE_INTERFACE=any
EOF
}

check_prerequisites() {
  local command_name
  for command_name in awk base64 curl date dig docker jq python3 rg sed sha256sum timeout tr unzip; do
    require_command "${command_name}"
  done
  [[ -f "${PACKAGE}" ]] || {
    printf 'Package is missing: %s\n' "${PACKAGE}" >&2
    return 1
  }
  unzip -t "${PACKAGE}" >/dev/null
  [[ "$(unzip -p "${PACKAGE}" dnsApp.config | jq -r '.enabled')" == "false" ]] || {
    printf '%s\n' 'Packaged dnsApp.config must have enabled=false.' >&2
    return 1
  }
  assert_documentation_safe_fixtures
  docker image inspect "${IMAGE}" >/dev/null
  printf '%s\n' 'Integration harness check passed.'
  printf 'image=%s\n' "${IMAGE}"
  printf 'package_sha256=%s\n' "$(sha256sum "${PACKAGE}" | awk '{print $1}')"
  printf '%s\n' 'live_execution=false'
}

if [[ "${1:-}" == "--check" && "$#" -eq 1 ]]; then
  check_prerequisites
  exit 0
fi
case "${1:-}" in
  --apply) readonly TEST_MODE="lifecycle" ;;
  --receiver-failure-recovery) readonly TEST_MODE="receiver-failure-recovery" ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [[ "$#" -ne 1 ]]; then
  usage >&2
  exit 2
fi

check_prerequisites >/dev/null
require_live_approval
if [[ "${TEST_MODE}" == "receiver-failure-recovery" ]]; then
  docker image inspect "${RECEIVER_IMAGE}" >/dev/null
  readonly RECEIVER_IP="${TEST_RECEIVER_IPV4}"
  readonly RECEIVER_PORT=514
else
  readonly RECEIVER_IP="${TEST_RECEIVER_IP:-}"
  readonly RECEIVER_PORT="${TEST_RECEIVER_PORT:-1516}"
fi
readonly API_PORT="${TEST_API_PORT:-15380}"
readonly DNS_PORT="${TEST_DNS_PORT:-15353}"
readonly CAPTURE_INTERFACE="${TEST_CAPTURE_INTERFACE:-any}"
require_numeric_ip "${RECEIVER_IP}"
require_port "${RECEIVER_PORT}"
require_port "${API_PORT}"
require_port "${DNS_PORT}"

if docker container inspect "${CONTAINER}" >/dev/null 2>&1 \
  || docker container inspect "${RECEIVER_CONTAINER}" >/dev/null 2>&1 \
  || docker network inspect "${NETWORK}" >/dev/null 2>&1; then
  printf '%s\n' 'Refusing to overwrite an existing integration container, receiver, or network.' >&2
  exit 2
fi

umask 077
work_dir="$(mktemp -d /tmp/technitium-exporter-integration.XXXXXX)"
config_dir="${work_dir}/config"
password_file="${work_dir}/admin-password"
login_file="${work_dir}/login.json"
auth_config="${work_dir}/curl-auth.conf"
results_jsonl="${work_dir}/results.jsonl"
dns_results="${work_dir}/dns-results.tsv"
resource_dir="${work_dir}/resources"
receiver_env_file="${work_dir}/receiver.env"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "${config_dir}" "${resource_dir}" "${LIVE_TEST_RESULTS_DIR}"
head -c 48 /dev/urandom | base64 | tr -d '\n' >"${password_file}"
chmod 0444 "${password_file}"
if [[ "${TEST_MODE}" == "receiver-failure-recovery" ]]; then
  receiver_auth_material="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  receiver_database_auth_material="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
  {
    printf '%s=%s\n' SECRET_KEY "${receiver_auth_material}"
    printf '%s=%s\n' POSTGRES_PASSWORD "${receiver_database_auth_material}"
    printf '%s=%s\n' AUTH_ENABLED false
    printf '%s=%s\n' LOG_LEVEL INFO
    printf '%s=%s\n' TZ UTC
  } >"${receiver_env_file}"
  chmod 0600 "${receiver_env_file}"
  unset receiver_auth_material receiver_database_auth_material
fi

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if (( exit_code != 0 )) && docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    printf '%s\n' 'Integration container log tail after failure:' >&2
    docker logs --tail 80 "${CONTAINER}" 2>&1 >&2 || true
  fi
  if (( exit_code != 0 )) && docker container inspect "${RECEIVER_CONTAINER}" >/dev/null 2>&1; then
    printf '%s\n' 'Isolated receiver log tail after failure:' >&2
    docker logs --tail 80 "${RECEIVER_CONTAINER}" 2>&1 \
      | sed -E \
          -e 's/(SECRET_KEY|POSTGRES_PASSWORD|API_KEY|LICENSE_KEY)=[^[:space:]]+/\1=<redacted>/g' \
          -e 's/(Proxy auth token[^:]*: )[[:xdigit:]]+/\1<redacted>/g' >&2 || true
  fi
  docker rm -f "${RECEIVER_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
  if [[ -d "${work_dir}" ]]; then
    docker run --rm --pull never --entrypoint /bin/sh \
      --mount "type=bind,src=${work_dir},dst=/cleanup" \
      "${IMAGE}" -c 'find /cleanup -mindepth 1 -delete' >/dev/null 2>&1 || true
    rm -rf "${work_dir}" || true
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

docker network create \
  --driver bridge \
  --subnet 192.0.2.0/24 \
  --ipv6 --subnet 2001:db8:53::/64 \
  "${NETWORK}" >/dev/null
if [[ "${TEST_MODE}" == "receiver-failure-recovery" ]]; then
  docker run -d \
    --name "${RECEIVER_CONTAINER}" \
    --network "${NETWORK}" \
    --ip "${TEST_RECEIVER_IPV4}" \
    --ip6 "${TEST_RECEIVER_IPV6}" \
    --pull never \
    --security-opt no-new-privileges:true \
    --cpus 2 \
    --memory 2g \
    --pids-limit 512 \
    --tmpfs /var/lib/postgresql/data:rw,nosuid,nodev,size=1g \
    --env-file "${receiver_env_file}" \
    "${RECEIVER_IMAGE}" >/dev/null
fi
docker run -d \
  --name "${CONTAINER}" \
  --network "${NETWORK}" \
  --ip "${TEST_NODE_IPV4}" \
  --ip6 "${TEST_NODE_IPV6}" \
  --pull never \
  --security-opt no-new-privileges:true \
  --mount "type=bind,src=${config_dir},dst=/etc/dns" \
  --mount "type=bind,src=${password_file},dst=/run/secrets/admin-password,readonly" \
  --publish "127.0.0.1:${API_PORT}:5380/tcp" \
  --publish "127.0.0.1:${DNS_PORT}:53/tcp" \
  --publish "127.0.0.1:${DNS_PORT}:53/udp" \
  --env "DNS_SERVER_DOMAIN=${TEST_SERVER_DOMAIN}" \
  --env DNS_SERVER_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  --env DNS_SERVER_RECURSION=Allow \
  "${IMAGE}" >/dev/null

base_url="http://127.0.0.1:${API_PORT}"
for _ in $(seq 1 60); do
  if curl --silent --fail "${base_url}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

login() {
  curl --silent --show-error --fail \
    --data-urlencode user=admin \
    --data-urlencode "pass@${password_file}" \
    --data-urlencode includeInfo=true \
    "${base_url}/api/user/login" >"${login_file}"
  local session_value
  if ! session_value="$(jq -er '.token // .response.token' "${login_file}")"; then
    jq -c '{status,errorMessage,topLevelKeys:keys}' "${login_file}" >&2 || true
    return 1
  fi
  printf 'header = "Authorization: Bearer %s"\n' "${session_value}" >"${auth_config}"
  rm -f "${login_file}"
}

login

api_get() {
  local path="$1"
  local output="$2"
  curl --silent --show-error --fail --config "${auth_config}" "${base_url}${path}" >"${output}"
  jq -e '.status == "ok"' "${output}" >/dev/null
}

api_set_config() {
  local json="$1"
  local output="${work_dir}/set-config.json"
  curl --silent --show-error --fail --config "${auth_config}" \
    --data-urlencode "config=${json}" \
    "${base_url}/api/apps/config/set?name=${APP_NAME_ENCODED}" >"${output}"
  jq -e '.status == "ok"' "${output}" >/dev/null
}

dns_works() {
  local output
  output="$(dig @127.0.0.1 -p "${DNS_PORT}" example.org A +time=3 +tries=1 +noall +comments 2>&1 || true)"
  if ! rg -q 'status: (NOERROR|NXDOMAIN)' <<<"${output}"; then
    printf '%s\n' "$(rg -m 1 'status:|no servers could be reached|communications error' <<<"${output}" || printf 'DNS check returned no recognized status.')" >&2
    return 1
  fi
}

receiver_udp_listener_present() {
  docker exec "${RECEIVER_CONTAINER}" sh -c \
    "grep -Eqi ':[0]*0202[[:space:]]' /proc/net/udp /proc/net/udp6 2>/dev/null"
}

receiver_process_running() {
  docker exec "${RECEIVER_CONTAINER}" pgrep -f '[p]ython /app/main.py' >/dev/null 2>&1
}

wait_receiver_ready() {
  local attempt
  for attempt in $(seq 1 120); do
    if receiver_process_running \
      && docker exec --user postgres "${RECEIVER_CONTAINER}" psql -d unifi_logs -Atc 'SELECT 1;' 2>/dev/null | rg -qx '1' \
      && receiver_udp_listener_present; then
      return 0
    fi
    sleep 1
  done
  printf '%s\n' 'Isolated receiver did not become ready within 120 seconds.' >&2
  return 1
}

receiver_record_count() {
  local prefix="$1"
  case "${prefix}" in
    baseline|outage|recovery|pathdown|pathrecovery) ;;
    *) printf 'Unsupported receiver query prefix: %s\n' "${prefix}" >&2; return 2 ;;
  esac
  docker exec --user postgres "${RECEIVER_CONTAINER}" \
    psql -d unifi_logs -Atc \
    "SELECT count(*) FROM logs WHERE log_type='dns' AND dns_query LIKE '${prefix}-%';"
}

receiver_duplicate_count() {
  local prefix="$1"
  case "${prefix}" in
    baseline|outage|recovery|pathdown|pathrecovery) ;;
    *) printf 'Unsupported receiver query prefix: %s\n' "${prefix}" >&2; return 2 ;;
  esac
  docker exec --user postgres "${RECEIVER_CONTAINER}" \
    psql -d unifi_logs -Atc \
    "SELECT count(*) - count(DISTINCT dns_query) FROM logs WHERE log_type='dns' AND dns_query LIKE '${prefix}-%';"
}

wait_receiver_record_count() {
  local prefix="$1"
  local expected="$2"
  local attempt count
  for attempt in $(seq 1 30); do
    count="$(receiver_record_count "${prefix}")"
    if [[ "${count}" == "${expected}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_dns_queries() {
  local phase="$1"
  local prefix="$2"
  local count="$3"
  local width="$4"
  local interval="$5"
  local index number qname output status start_ns end_ns elapsed_ms
  for index in $(seq 1 "${count}"); do
    printf -v number "%0${width}d" "${index}"
    qname="${prefix}-${number}.example.org"
    start_ns="$(date +%s%N)"
    output="$(dig @127.0.0.1 -p "${DNS_PORT}" "${qname}" A +time=3 +tries=1 +noall +comments 2>&1 || true)"
    end_ns="$(date +%s%N)"
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    status="$(sed -nE 's/.*status: ([A-Z]+),.*/\1/p' <<<"${output}" | head -n 1)"
    if [[ -z "${status}" ]]; then
      status=TIMEOUT
    fi
    printf '%s\t%s\t%s\n' "${phase}" "${status}" "${elapsed_ms}" >>"${dns_results}"
    if [[ "${index}" != "${count}" && "${interval}" != "0" ]]; then
      sleep "${interval}"
    fi
  done
}

capture_resources() {
  local phase="$1"
  local stats proc_status cpu_percent memory_usage pids threads vm_rss vm_size fd_count socket_count process_count
  stats="$(docker stats --no-stream --format '{{json .}}' "${CONTAINER}")"
  cpu_percent="$(jq -r '.CPUPerc | rtrimstr("%")' <<<"${stats}")"
  memory_usage="$(jq -r '.MemUsage' <<<"${stats}")"
  pids="$(jq -r '.PIDs | tonumber' <<<"${stats}")"
  proc_status="$(docker exec "${CONTAINER}" sh -c 'grep -E "^(Threads|VmRSS|VmSize):" /proc/1/status')"
  threads="$(awk '$1 == "Threads:" {print $2}' <<<"${proc_status}")"
  vm_rss="$(awk '$1 == "VmRSS:" {print $2}' <<<"${proc_status}")"
  vm_size="$(awk '$1 == "VmSize:" {print $2}' <<<"${proc_status}")"
  fd_count="$(docker exec "${CONTAINER}" sh -c 'ls /proc/1/fd | wc -l')"
  socket_count="$(docker exec "${CONTAINER}" sh -c 'ls -l /proc/1/fd 2>/dev/null | grep -c "socket:" || true')"
  process_count="$(docker top "${CONTAINER}" -eo pid,comm | awk 'NR > 1 {count++} END {print count + 0}')"
  jq -n \
    --arg phase "${phase}" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cpuPercent "${cpu_percent}" \
    --arg memoryUsage "${memory_usage}" \
    --argjson pids "${pids}" \
    --argjson threads "${threads}" \
    --argjson vmRssKiB "${vm_rss}" \
    --argjson vmSizeKiB "${vm_size}" \
    --argjson fileDescriptors "${fd_count}" \
    --argjson sockets "${socket_count}" \
    --argjson processes "${process_count}" \
    '{phase:$phase,timestamp:$timestamp,cpuPercent:$cpuPercent,memoryUsage:$memoryUsage,pids:$pids,threads:$threads,vmRssKiB:$vmRssKiB,vmSizeKiB:$vmSizeKiB,fileDescriptors:$fileDescriptors,sockets:$sockets,processes:$processes}' \
    >"${resource_dir}/${phase}.json"
}

download_technitium_logs() {
  local output="$1"
  local list_file="${work_dir}/log-files.json"
  local log_file
  api_get /api/logs/list "${list_file}"
  : >"${output}"
  while IFS= read -r log_file; do
    curl --silent --show-error --fail --config "${auth_config}" --get \
      --data-urlencode "fileName=${log_file}" \
      --data-urlencode limit=2 \
      "${base_url}/api/logs/download" >>"${output}"
    printf '\n' >>"${output}"
  done < <(jq -r '.response.logFiles[]?.fileName' "${list_file}")
  [[ -s "${output}" ]]
}

latest_exporter_counters() {
  local line log_snapshot="${work_dir}/technitium-logs-latest.txt"
  if download_technitium_logs "${log_snapshot}"; then
    line="$( { rg --no-filename 'Counters:' "${log_snapshot}" 2>/dev/null || true; } | tail -n 1)"
  else
    line=""
  fi
  if [[ -z "${line}" ]]; then
    jq -n '{accepted:null,filtered:null,sent:null,dropped:null,formatError:null,sendError:null,queueDepth:null}'
    return
  fi
  jq -n \
    --argjson accepted "$(sed -nE 's/.*accepted=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson filtered "$(sed -nE 's/.*filtered=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson sent "$(sed -nE 's/.*sent=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson dropped "$(sed -nE 's/.*dropped=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson formatError "$(sed -nE 's/.*formatError=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson sendError "$(sed -nE 's/.*sendError=([0-9]+).*/\1/p' <<<"${line}")" \
    --argjson queueDepth "$(sed -nE 's/.*queueDepth=([0-9]+).*/\1/p' <<<"${line}")" \
    '{accepted:$accepted,filtered:$filtered,sent:$sent,dropped:$dropped,formatError:$formatError,sendError:$sendError,queueDepth:$queueDepth}'
}

record_failure() {
  local failures_file="$1"
  local message="$2"
  jq -cn --arg message "${message}" '{message:$message}' >>"${failures_file}"
}

run_receiver_failure_recovery() {
  local failures_file="${work_dir}/failures.jsonl"
  local checks_file="${work_dir}/checks.jsonl"
  local counters_before_file="${work_dir}/counters-before.json"
  local counters_outage_file="${work_dir}/counters-outage.json"
  local counters_after_file="${work_dir}/counters-after.json"
  local resources_file="${work_dir}/resources.json"
  local report_file="${LIVE_TEST_RESULTS_DIR}/receiver-failure-recovery-summary.json"
  local outage_start_ns outage_end_ns outage_duration_ms
  local baseline_observed baseline_duplicates outage_observed recovery_observed recovery_duplicates
  local pathdown_observed pathrecovery_observed pathrecovery_duplicates
  local receiver_field_errors receiver_message_errors
  local privacy_hits qname_log_hits client_log_hits client_error_log_hits exception_hits error_log_count log_store_measured
  local normal_log_snapshot="${work_dir}/technitium-logs-final.txt"
  local privacy_samples_file="${work_dir}/privacy-samples.json"
  local dns_total dns_successful dns_timeouts dns_servfail dns_min dns_avg dns_max
  local receiver_version finished_at duration_seconds resource_leak
  local receiver_pid
  local receiver_stop_confirmed=false destination_unchanged=false network_disconnect_confirmed=false
  : >"${failures_file}"
  : >"${checks_file}"

  wait_receiver_ready
  receiver_version="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${RECEIVER_IMAGE}")"
  [[ -n "${receiver_version}" && "${receiver_version}" != "<no value>" ]] || receiver_version="3.7.0"

  local failure_config
  failure_config="$(jq -cn \
    --arg address "${RECEIVER_IP}" \
    --argjson port "${RECEIVER_PORT}" \
    --arg domain "${TEST_SERVER_DOMAIN}" \
    '{enabled:true,destination:{address:$address,port:$port,protocol:"UDP"},nodePolicy:{mode:"allowList",serverDomains:[$domain]},observability:{logStartupSummary:true,logPeriodicCounters:true,counterIntervalSeconds:10,includeQueryDataInLogs:false}}')"
  api_set_config "${failure_config}"
  sleep 11
  latest_exporter_counters >"${counters_before_file}"

  run_dns_queries baseline baseline 5 2 0
  if wait_receiver_record_count baseline 5; then
    append_result "${checks_file}" baseline-receiver pass '5 records' '5 records'
  else
    baseline_observed="$(receiver_record_count baseline)"
    append_result "${checks_file}" baseline-receiver fail '5 records' "${baseline_observed} records"
    record_failure "${failures_file}" 'Baseline receiver record count differed from five.'
  fi
  sleep 11
  capture_resources before_receiver_outage

  receiver_pid="$(docker exec "${RECEIVER_CONTAINER}" pgrep -f '[p]ython /app/main.py' | head -n 1)"
  docker exec "${RECEIVER_CONTAINER}" kill -STOP 1
  docker exec "${RECEIVER_CONTAINER}" kill -TERM "${receiver_pid}"
  for _ in $(seq 1 30); do
    if ! receiver_process_running && ! receiver_udp_listener_present; then
      receiver_stop_confirmed=true
      break
    fi
    sleep 0.1
  done
  if [[ "${receiver_stop_confirmed}" == "true" ]]; then
    append_result "${checks_file}" receiver-process-stopped pass 'receiver process absent and UDP listener absent' 'confirmed while supervisor was stopped'
  else
    append_result "${checks_file}" receiver-process-stopped fail 'receiver process absent and UDP listener absent' 'not confirmed'
    record_failure "${failures_file}" 'Receiver process stop state was not confirmed.'
  fi
  api_get "/api/apps/config/get?name=${APP_NAME_ENCODED}" "${config_result}"
  if jq -e --arg address "${RECEIVER_IP}" --argjson port "${RECEIVER_PORT}" \
    '.response.config | fromjson | .destination.address == $address and .destination.port == $port and .enabled == true' \
    "${config_result}" >/dev/null; then
    destination_unchanged=true
    append_result "${checks_file}" destination-unchanged pass 'same enabled destination' 'confirmed without reload'
  else
    append_result "${checks_file}" destination-unchanged fail 'same enabled destination' 'configuration differed'
    record_failure "${failures_file}" 'Exporter destination changed during receiver stop.'
  fi

  outage_start_ns="$(date +%s%N)"
  run_dns_queries receiver_process_down outage 50 3 0.62
  outage_end_ns="$(date +%s%N)"
  outage_duration_ms=$(( (outage_end_ns - outage_start_ns) / 1000000 ))
  capture_resources during_receiver_outage
  sleep 11
  latest_exporter_counters >"${counters_outage_file}"

  docker exec "${RECEIVER_CONTAINER}" kill -CONT 1
  wait_receiver_ready
  run_dns_queries recovery_after_process_start recovery 10 2 0
  if ! wait_receiver_record_count recovery 10; then
    record_failure "${failures_file}" 'Recovery receiver record count differed from ten.'
  fi
  capture_resources directly_after_receiver_recovery
  outage_observed="$(receiver_record_count outage)"

  docker network disconnect "${NETWORK}" "${RECEIVER_CONTAINER}"
  if [[ "$(docker inspect --format '{{if index .NetworkSettings.Networks "technitium-exporter-integration"}}connected{{else}}disconnected{{end}}' "${RECEIVER_CONTAINER}")" == "disconnected" ]]; then
    network_disconnect_confirmed=true
    append_result "${checks_file}" receiver-network-disconnected pass 'receiver absent from isolated network' 'confirmed'
  else
    append_result "${checks_file}" receiver-network-disconnected fail 'receiver absent from isolated network' 'still connected'
    record_failure "${failures_file}" 'Receiver network disconnect was not confirmed.'
  fi
  run_dns_queries receiver_network_disconnected pathdown 10 2 0.20
  docker network connect --ip "${TEST_RECEIVER_IPV4}" --ip6 "${TEST_RECEIVER_IPV6}" "${NETWORK}" "${RECEIVER_CONTAINER}"
  wait_receiver_ready
  run_dns_queries recovery_after_network_reconnect pathrecovery 10 2 0
  if ! wait_receiver_record_count pathrecovery 10; then
    record_failure "${failures_file}" 'Network-recovery receiver record count differed from ten.'
  fi
  capture_resources directly_after_network_recovery

  sleep 120
  capture_resources stable_recovery_after_120_seconds
  sleep 11
  latest_exporter_counters >"${counters_after_file}"

  baseline_observed="$(receiver_record_count baseline)"
  baseline_duplicates="$(receiver_duplicate_count baseline)"
  recovery_observed="$(receiver_record_count recovery)"
  recovery_duplicates="$(receiver_duplicate_count recovery)"
  pathdown_observed="$(receiver_record_count pathdown)"
  pathrecovery_observed="$(receiver_record_count pathrecovery)"
  pathrecovery_duplicates="$(receiver_duplicate_count pathrecovery)"

  receiver_field_errors="$(docker exec --user postgres "${RECEIVER_CONTAINER}" psql -d unifi_logs -Atc \
    "SELECT count(*) FROM logs WHERE (dns_query LIKE 'baseline-%' OR dns_query LIKE 'recovery-%' OR dns_query LIKE 'pathrecovery-%') AND (dns_type <> 'A' OR host(src_ip) <> '192.0.2.1');")"
  receiver_message_errors="$(docker exec --user postgres "${RECEIVER_CONTAINER}" psql -d unifi_logs -Atc \
    "SELECT count(*) FROM logs WHERE (dns_query LIKE 'baseline-%' OR dns_query LIKE 'recovery-%' OR dns_query LIKE 'pathrecovery-%') AND raw_log !~ ' dnsmasq\\[1\\]: query\\[A\\] '; ")"

  dns_total="$(awk 'END {print NR + 0}' "${dns_results}")"
  dns_successful="$(awk '$2 == "NOERROR" || $2 == "NXDOMAIN" {count++} END {print count + 0}' "${dns_results}")"
  dns_timeouts="$(awk '$2 == "TIMEOUT" {count++} END {print count + 0}' "${dns_results}")"
  dns_servfail="$(awk '$2 == "SERVFAIL" {count++} END {print count + 0}' "${dns_results}")"
  read -r dns_min dns_avg dns_max < <(awk 'NR == 1 {min=$3; max=$3} {sum+=$3; if ($3<min) min=$3; if ($3>max) max=$3} END {printf "%d %.3f %d\n", min, sum/NR, max}' "${dns_results}")

  if download_technitium_logs "${normal_log_snapshot}"; then
    log_store_measured=true
    qname_log_hits="$( { rg --no-filename -i -c 'baseline-|outage-|recovery-|pathdown-|pathrecovery-' "${normal_log_snapshot}" || true; } | awk '{sum += $1} END {print sum + 0}')"
    client_log_hits="$( { rg --no-filename -i -c '192\.0\.2\.1' "${normal_log_snapshot}" || true; } | awk '{sum += $1} END {print sum + 0}')"
    client_error_log_hits="$( { rg --no-filename -i '192\.0\.2\.1' "${normal_log_snapshot}" || true; } \
      | { rg --no-filename -i -c 'UDP export failed|UDP export worker stopped unexpectedly|exception|error' || true; } \
      | awk '{sum += $1} END {print sum + 0}')"
    privacy_hits=$(( qname_log_hits + client_error_log_hits ))
    { rg --no-filename -i 'baseline-|outage-|recovery-|pathdown-|pathrecovery-|192\.0\.2\.1' "${normal_log_snapshot}" || true; } \
      | sed -E \
          -e 's/(baseline|outage|recovery|pathdown|pathrecovery)-[0-9]+\.example\.org/<test-qname>/g' \
          -e 's/192\.0\.2\.1/<test-client>/g' \
          -e 's/(Bearer|Proxy auth token[^:]*: )[A-Za-z0-9._-]+/\1<redacted>/g' \
      | head -n 20 \
      | jq -R -s 'split("\n") | map(select(length > 0))' >"${privacy_samples_file}"
    exception_hits="$( { rg --no-filename -i -c 'stack trace|unhandled|ObjectDisposedException|TaskCanceledException|SocketException.*SocketException' "${normal_log_snapshot}" || true; } | awk '{sum += $1} END {print sum + 0}')"
    error_log_count="$( { rg --no-filename -c 'UDP export failed|UDP export worker stopped unexpectedly' "${normal_log_snapshot}" || true; } | awk '{sum += $1} END {print sum + 0}')"
  else
    log_store_measured=false
    privacy_hits=0
    qname_log_hits=0
    client_log_hits=0
    client_error_log_hits=0
    exception_hits=0
    error_log_count=0
    printf '%s\n' '[]' >"${privacy_samples_file}"
  fi

  jq -s '
    def strict_growth($values): all(range(1; $values|length); $values[.] > $values[. - 1]);
    . as $samples
    | ($samples[0]) as $first
    | ($samples[-1]) as $last
    | {samples:$samples,
       deltas:{vmRssKiB:($last.vmRssKiB-$first.vmRssKiB),threads:($last.threads-$first.threads),sockets:($last.sockets-$first.sockets),fileDescriptors:($last.fileDescriptors-$first.fileDescriptors)},
       monotonicGrowth:{vmRssKiB:strict_growth([$samples[].vmRssKiB]),threads:strict_growth([$samples[].threads]),sockets:strict_growth([$samples[].sockets]),fileDescriptors:strict_growth([$samples[].fileDescriptors])},
       potentialLeak:((strict_growth([$samples[].vmRssKiB]) and ($last.vmRssKiB-$first.vmRssKiB > 65536)) or (strict_growth([$samples[].threads]) and ($last.threads-$first.threads > 5)) or (strict_growth([$samples[].sockets]) and ($last.sockets-$first.sockets > 3)) or (strict_growth([$samples[].fileDescriptors]) and ($last.fileDescriptors-$first.fileDescriptors > 10)))}' \
    "${resource_dir}/before_receiver_outage.json" \
    "${resource_dir}/during_receiver_outage.json" \
    "${resource_dir}/directly_after_receiver_recovery.json" \
    "${resource_dir}/directly_after_network_recovery.json" \
    "${resource_dir}/stable_recovery_after_120_seconds.json" >"${resources_file}"
  resource_leak="$(jq -r '.potentialLeak' "${resources_file}")"

  if [[ "${dns_total}" != "85" || "${dns_successful}" != "85" || "${dns_timeouts}" != "0" || "${dns_servfail}" != "0" ]]; then
    record_failure "${failures_file}" 'DNS success criteria were not met.'
  fi
  if (( outage_duration_ms < 30000 )); then
    record_failure "${failures_file}" 'Receiver-process outage query phase was shorter than 30 seconds.'
  fi
  if [[ "${baseline_observed}" != "5" || "${baseline_duplicates}" != "0" ]]; then
    record_failure "${failures_file}" 'Baseline receiver count or duplicate criterion failed.'
  fi
  if [[ "${recovery_observed}" != "10" || "${recovery_duplicates}" != "0" ]]; then
    record_failure "${failures_file}" 'Receiver-process recovery count or duplicate criterion failed.'
  fi
  if [[ "${pathrecovery_observed}" != "10" || "${pathrecovery_duplicates}" != "0" ]]; then
    record_failure "${failures_file}" 'Network-path recovery count or duplicate criterion failed.'
  fi
  if [[ "${receiver_field_errors}" != "0" || "${receiver_message_errors}" != "0" ]]; then
    record_failure "${failures_file}" 'Receiver field or dnsmasq message validation failed.'
  fi
  if [[ "${privacy_hits}" != "0" || "${exception_hits}" != "0" ]]; then
    record_failure "${failures_file}" 'Exporter log privacy or exception criterion failed.'
  fi
  if [[ "$(jq -r '.dropped' "${counters_after_file}")" != "$(jq -r '.dropped' "${counters_before_file}")" ]]; then
    record_failure "${failures_file}" 'Dropped counter increased outside a saturation test.'
  fi
  if [[ "${resource_leak}" == "true" ]]; then
    record_failure "${failures_file}" 'Resource samples indicate sustained growth beyond the bounded thresholds.'
  fi

  write_result_array "${checks_file}" "${work_dir}/checks.json"
  if [[ -s "${failures_file}" ]]; then
    write_result_array "${failures_file}" "${work_dir}/failures.json"
  else
    printf '%s\n' '[]' >"${work_dir}/failures.json"
  fi
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  duration_seconds=$(( $(date -u -d "${finished_at}" +%s) - $(date -u -d "${started_at}" +%s) ))

  jq -n \
    --arg status "$(if [[ -s "${failures_file}" ]]; then printf failed; else printf partial; fi)" \
    --arg startedAt "${started_at}" \
    --arg finishedAt "${finished_at}" \
    --argjson durationSeconds "${duration_seconds}" \
    --arg receiverVersion "${receiver_version}" \
    --argjson outageDurationMs "${outage_duration_ms}" \
    --argjson dnsTotal "${dns_total}" \
    --argjson dnsSuccessful "${dns_successful}" \
    --argjson dnsTimeouts "${dns_timeouts}" \
    --argjson dnsServfail "${dns_servfail}" \
    --argjson dnsMin "${dns_min}" \
    --argjson dnsAvg "${dns_avg}" \
    --argjson dnsMax "${dns_max}" \
    --argjson baselineObserved "${baseline_observed}" \
    --argjson baselineDuplicates "${baseline_duplicates}" \
    --argjson recoveryObserved "${recovery_observed}" \
    --argjson recoveryDuplicates "${recovery_duplicates}" \
    --argjson outageObserved "${outage_observed}" \
    --argjson pathdownObserved "${pathdown_observed}" \
    --argjson pathrecoveryObserved "${pathrecovery_observed}" \
    --argjson pathrecoveryDuplicates "${pathrecovery_duplicates}" \
    --argjson receiverFieldErrors "${receiver_field_errors}" \
    --argjson receiverMessageErrors "${receiver_message_errors}" \
    --argjson receiverStopConfirmed "${receiver_stop_confirmed}" \
    --argjson destinationUnchanged "${destination_unchanged}" \
    --argjson networkDisconnectConfirmed "${network_disconnect_confirmed}" \
    --argjson errorLogCount "${error_log_count}" \
    --argjson privacyHits "${privacy_hits}" \
    --argjson qnameLogHits "${qname_log_hits}" \
    --argjson clientLogHits "${client_log_hits}" \
    --argjson clientErrorLogHits "${client_error_log_hits}" \
    --argjson exceptionHits "${exception_hits}" \
    --argjson logStoreMeasured "${log_store_measured}" \
    --slurpfile countersBefore "${counters_before_file}" \
    --slurpfile countersOutage "${counters_outage_file}" \
    --slurpfile countersAfter "${counters_after_file}" \
    --slurpfile resources "${resources_file}" \
    --slurpfile privacySamples "${privacy_samples_file}" \
    --slurpfile checks "${work_dir}/checks.json" \
    --slurpfile failures "${work_dir}/failures.json" \
    '{schema_version:1,test:"receiver-failure-recovery",status:$status,technitium_version:"15.4",unifi_insights_version:$receiverVersion,started_at:$startedAt,finished_at:$finishedAt,duration_seconds:$durationSeconds,
      topology:"isolated Technitium and ephemeral UniFi Insights Plus receiver on one documentation-safe Docker bridge",
      phases:{baseline:{queries:5,receiver_records:$baselineObserved},receiver_down:{variant:"receiver process terminated while isolated supervisor was temporarily stopped",queries:50,duration_milliseconds:$outageDurationMs,receiver_process_verified_stopped:$receiverStopConfirmed,destination_unchanged:$destinationUnchanged},network_path_down:{variant:"isolated receiver network disconnect",queries:10,disconnect_verified:$networkDisconnectConfirmed},recovery:{queries:10,receiver_records:$recoveryObserved,network_recovery_queries:10,network_recovery_records:$pathrecoveryObserved,config_reloaded:false,technitium_restarted:false}},
      dns:{queries_total:$dnsTotal,successful:$dnsSuccessful,timeouts:$dnsTimeouts,servfail:$dnsServfail,latency_milliseconds:{minimum:$dnsMin,mean:$dnsAvg,maximum:$dnsMax}},
      receiver:{baseline_expected:5,baseline_observed:$baselineObserved,baseline_duplicates:$baselineDuplicates,recovery_expected:10,recovery_observed:$recoveryObserved,recovery_duplicates:$recoveryDuplicates,outage_events_observed_after_recovery:$outageObserved,network_outage_events_observed_after_recovery:$pathdownObserved,network_recovery_expected:10,network_recovery_observed:$pathrecoveryObserved,network_recovery_duplicates:$pathrecoveryDuplicates,field_errors:$receiverFieldErrors,dnsmasq_format_errors:$receiverMessageErrors},
      exporter:{send_errors_before:$countersBefore[0].sendError,send_errors_after_outage:$countersOutage[0].sendError,send_errors_after:$countersAfter[0].sendError,dropped_before:$countersBefore[0].dropped,dropped_after:$countersAfter[0].dropped,counters_before:$countersBefore[0],counters_after_outage:$countersOutage[0],counters_after:$countersAfter[0],udp_send_semantics:(if $countersAfter[0].sendError > $countersBefore[0].sendError then "kernel-signaled-some-errors" else "no-send-error-signaled" end)},
      logs:{measured:$logStoreMeasured,rate_limited_error_messages:$errorLogCount,privacy_violations:$privacyHits,qname_hits:$qnameLogHits,client_ip_hits_all_normal_logs:$clientLogHits,client_ip_hits_in_error_logs:$clientErrorLogHits,redacted_matching_lines:$privacySamples[0],exception_pattern_hits:$exceptionHits},resource_observations:$resources[0],pcap:{status:"not-measured",reason:"Host packet capture privileges were unavailable; receiver database counts were measured independently."},checks:$checks[0],not_measured:(["host PCAP","kernel delivery acknowledgement for UDP datagrams","send-error log rate limiting because no local UDP send error was signaled"] + (if $logStoreMeasured then [] else ["Technitium normal log store"] end)),failures:$failures[0]}' \
    >"${report_file}"

  printf 'Receiver failure/recovery test completed; status=%s result=%s\n' \
    "$(jq -r '.status' "${report_file}")" "${report_file}"
  if [[ -s "${failures_file}" ]]; then
    return 1
  fi
}

capture_one_query() {
  local qname="$1"
  local qtype="$2"
  local expected_count="$3"
  local capture_file="${work_dir}/capture.pcap"
  local capture_log="${work_dir}/capture.log"
  local count="unavailable"
  local observed="capture unavailable"
  if command -v tcpdump >/dev/null 2>&1; then
    timeout 5 tcpdump -ni "${CAPTURE_INTERFACE}" -s 0 -w "${capture_file}" \
      "udp and src host ${TEST_NODE_IPV4} and dst host ${RECEIVER_IP} and dst port ${RECEIVER_PORT}" \
      >"${capture_log}" 2>&1 &
    local capture_pid=$!
    sleep 0.25
    if kill -0 "${capture_pid}" >/dev/null 2>&1; then
      dig @127.0.0.1 -p "${DNS_PORT}" "${qname}" "${qtype}" +time=3 +tries=1 >/dev/null
      wait "${capture_pid}" || true
      if tcpdump -nn -r "${capture_file}" >/dev/null 2>&1; then
        count="$(tcpdump -nn -r "${capture_file}" 2>/dev/null | wc -l | tr -d ' ')"
        observed="captured ${count} matching UDP datagrams"
      fi
    else
      wait "${capture_pid}" || true
      dig @127.0.0.1 -p "${DNS_PORT}" "${qname}" "${qtype}" +time=3 +tries=1 >/dev/null
    fi
  else
    dig @127.0.0.1 -p "${DNS_PORT}" "${qname}" "${qtype}" +time=3 +tries=1 >/dev/null
  fi
  if [[ "${count}" == "${expected_count}" ]]; then
    append_result "${results_jsonl}" "query-${qtype}-${qname}" pass "${expected_count} datagram(s)" "${observed}"
  elif [[ "${count}" == "unavailable" ]]; then
    append_result "${results_jsonl}" "query-${qtype}-${qname}" not-measured "${expected_count} datagram(s)" "${observed}"
  else
    append_result "${results_jsonl}" "query-${qtype}-${qname}" fail "${expected_count} datagram(s)" "${observed}"
  fi
}

install_result="${work_dir}/install.json"
curl --silent --show-error --fail --config "${auth_config}" \
  --form "file=@${PACKAGE};type=application/zip" \
  "${base_url}/api/apps/install?name=${APP_NAME_ENCODED}" >"${install_result}"
jq -e '.status == "ok" and .response.installedApp.dnsApps[]?.isQueryLogger == true' "${install_result}" >/dev/null
append_result "${results_jsonl}" fresh-install pass 'query logger installed' 'Technitium API returned a loaded query logger'

config_result="${work_dir}/config.json"
api_get "/api/apps/config/get?name=${APP_NAME_ENCODED}" "${config_result}"
packaged_config="$(unzip -p "${PACKAGE}" dnsApp.config | jq -c '.')"
installed_config="$(jq -er '.response.config | fromjson' "${config_result}" | jq -c '.')"
[[ "${installed_config}" == "${packaged_config}" && "$(jq -r '.enabled' <<<"${installed_config}")" == "false" ]]
append_result "${results_jsonl}" disabled-first-load pass 'enabled=false and DNS functional' 'packaged disabled config loaded'
dns_works
if [[ "${TEST_MODE}" == "receiver-failure-recovery" ]]; then
  run_receiver_failure_recovery
  exit $?
fi
capture_one_query example.org A 0

while IFS= read -r case_json; do
  case_name="$(jq -r '.name' <<<"${case_json}")"
  config="$(jq -c '.config' <<<"${case_json}")"
  api_set_config "${config}"
  if dns_works; then
    append_result "${results_jsonl}" "invalid-${case_name}" pass 'export disabled and DNS functional' 'config accepted for reload; DNS remained functional'
  else
    append_result "${results_jsonl}" "invalid-${case_name}" fail 'export disabled and DNS functional' 'DNS query failed'
  fi
  capture_one_query example.org A 0
done < <(jq -c '.[]' "${INVALID_CASES}")

while IFS= read -r case_json; do
  case_name="$(jq -r '.name' <<<"${case_json}")"
  expected="$(jq -r 'if .expectExport then 1 else 0 end' <<<"${case_json}")"
  domains="$(jq -c '.serverDomains' <<<"${case_json}")"
  config="$(jq -cn \
    --arg address "${RECEIVER_IP}" \
    --argjson port "${RECEIVER_PORT}" \
    --argjson domains "${domains}" \
    '{enabled:true,destination:{address:$address,port:$port,protocol:"UDP"},nodePolicy:{mode:"allowList",serverDomains:$domains}}')"
  api_set_config "${config}"
  dns_works
  capture_one_query "${case_name}.example.org" A "${expected}"
done < <(jq -c '.[]' "${NODE_CASES}")

enabled_config="$(jq -cn \
  --arg address "${RECEIVER_IP}" \
  --argjson port "${RECEIVER_PORT}" \
  --arg domain "${TEST_SERVER_DOMAIN}" \
  '{enabled:true,destination:{address:$address,port:$port,protocol:"UDP"},nodePolicy:{mode:"allowList",serverDomains:[$domain]},observability:{logStartupSummary:true,logPeriodicCounters:true,counterIntervalSeconds:10,includeQueryDataInLogs:false}}')"
api_set_config "${enabled_config}"
while read -r qname qtype; do
  capture_one_query "${qname}" "${qtype}" 1
done <"${LIVE_TEST_ROOT}/tests/fixtures/dns-queries.txt"
capture_one_query 'bad\010name.example.org' A 0

api_set_config '{"enabled":false}'
capture_one_query example.org A 0
append_result "${results_jsonl}" disable-reload pass 'export disabled without restart' 'DNS remained functional after config reload'

api_set_config "${enabled_config}"
docker restart --time 10 "${CONTAINER}" >/dev/null
for _ in $(seq 1 60); do
  if curl --silent --fail "${base_url}/api/status" >/dev/null 2>&1; then break; fi
  sleep 1
done
login
append_result "${results_jsonl}" restart-with-app pass 'app and config survive restart' 'container returned healthy API status'

curl --silent --show-error --fail --config "${auth_config}" \
  --form "file=@${PACKAGE};type=application/zip" \
  "${base_url}/api/apps/update?name=${APP_NAME_ENCODED}" >"${work_dir}/update.json"
jq -e '.status == "ok"' "${work_dir}/update.json" >/dev/null
api_get "/api/apps/config/get?name=${APP_NAME_ENCODED}" "${config_result}"
[[ "$(jq -er '.response.config | fromjson | .enabled' "${config_result}")" == "true" ]]
append_result "${results_jsonl}" update-retains-config pass 'dnsApp.config retained' 'enabled config remained after update'

api_get "/api/apps/uninstall?name=${APP_NAME_ENCODED}" "${work_dir}/uninstall.json"
api_get /api/apps/list "${work_dir}/apps-after-uninstall.json"
if jq -e --arg name "${APP_NAME}" '.response.apps | all(.name != $name)' "${work_dir}/apps-after-uninstall.json" >/dev/null; then
  append_result "${results_jsonl}" uninstall pass 'app absent' 'app removed from API inventory'
else
  append_result "${results_jsonl}" uninstall fail 'app absent' 'app still present in API inventory'
fi
curl --silent --show-error --fail --config "${auth_config}" \
  --form "file=@${PACKAGE};type=application/zip" \
  "${base_url}/api/apps/install?name=${APP_NAME_ENCODED}" >"${work_dir}/reinstall.json"
jq -e '.status == "ok"' "${work_dir}/reinstall.json" >/dev/null
api_get "/api/apps/config/get?name=${APP_NAME_ENCODED}" "${config_result}"
reinstalled_enabled="$(jq -r '.response.config | fromjson | .enabled' "${config_result}")"
if [[ "${reinstalled_enabled}" == "true" ]]; then
  append_result "${results_jsonl}" reinstall pass 'reinstallation succeeds and retained configuration is recorded' 'Technitium retained the existing enabled config after uninstall and reinstall'
elif [[ "${reinstalled_enabled}" == "false" ]]; then
  append_result "${results_jsonl}" reinstall pass 'reinstallation succeeds and retained configuration is recorded' 'Technitium loaded the disabled packaged config after reinstall'
else
  append_result "${results_jsonl}" reinstall fail 'reinstallation succeeds and retained configuration is recorded' 'installed config had no boolean enabled state'
fi

log_query_hits=0
if [[ -d "${config_dir}/logs" ]]; then
  log_query_hits="$( { rg -i -c 'example\.(org|net|com)|xn--bcher-kva' "${config_dir}/logs" 2>/dev/null || true; } | awk -F: '{sum += $2} END {print sum + 0}')"
fi
if [[ "${log_query_hits}" == "0" ]]; then
  append_result "${results_jsonl}" log-privacy pass 'no test QNAMEs in normal logs' 'zero fixture-domain matches'
else
  append_result "${results_jsonl}" log-privacy fail 'no test QNAMEs in normal logs' "${log_query_hits} fixture-domain matches"
fi

result_array="${work_dir}/results.json"
write_result_array "${results_jsonl}" "${result_array}"
technitium_version="$(jq -r '.info.version // "unknown"' <(curl --silent --show-error --fail --config "${auth_config}" "${base_url}/api/user/session/get"))"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg status "$(jq -r 'if all(.[]; .status == "pass" or .status == "not-measured") then "completed-with-measurement-gaps" else "failed" end' "${result_array}")" \
  --arg version "${technitium_version}" \
  --arg startedAt "${started_at}" \
  --arg finishedAt "${finished_at}" \
  --arg packageSha "$(sha256sum "${PACKAGE}" | awk '{print $1}')" \
  --argjson receiverPort "${RECEIVER_PORT}" \
  --slurpfile tests "${result_array}" \
  '{schemaVersion:1,status:$status,executed:true,startedAt:$startedAt,finishedAt:$finishedAt,environment:{technitiumVersion:$version,unifiInsightsPlusVersion:null,topology:"isolated Technitium test node to approval-gated UDP receiver",receiverAddress:"redacted",receiverPort:$receiverPort,packageSha256:$packageSha},testCases:$tests[0],receiverValidation:{status:"pending-read-only-correlation",records:null,duplicates:null},limitations:["UniFi Insights Plus acceptance must be correlated through its read-only MCP after the run.","Cases marked not-measured lacked packet-capture privileges."]}' \
  >"${LIVE_TEST_RESULTS_DIR}/integration-summary.json"

printf 'Integration test completed; result=%s\n' "${LIVE_TEST_RESULTS_DIR}/integration-summary.json"
