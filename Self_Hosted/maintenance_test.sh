#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d "$SOURCE_DIR/.avsm-maintenance-test.XXXXXX")"
cleanup() {
  if [[ -n "$TEST_ROOT" && "$TEST_ROOT" == "$SOURCE_DIR"/.avsm-maintenance-test.* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/install"
cp "$SOURCE_DIR/maintenance.sh" "$TEST_ROOT/install/maintenance.sh"
cp "$SOURCE_DIR/lifecycle-events.sh" "$TEST_ROOT/install/lifecycle-events.sh"
: > "$TEST_ROOT/install/.env"
export TEST_ROOT TEST_LOG="$TEST_ROOT/log" TEST_COMPACTED="$TEST_ROOT/compacted" TEST_INGEST_STOPPED="$TEST_ROOT/stopped"

cat > "$TEST_ROOT/bin/flock" <<'EOF'
#!/usr/bin/env bash
[[ "${LOCK_FAIL:-false}" == false ]]
EOF
cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_LOG"
case " $* " in
  *'.State.Health'*' test-ingest '*)
    printf '%s\n' "${INGEST_HEALTH:-healthy}" ;;
  *'.State.Health'*)
    [[ "${ANALYTICS_INSPECT_FAIL:-false}" == false ]] || exit 1
    if [[ "${ANALYTICS_HEALTH:-healthy}" == starting-then-healthy ]]; then
      if [[ -f "$TEST_ROOT/health-polled" ]]; then echo healthy; else touch "$TEST_ROOT/health-polled"; echo starting; fi
    else
      printf '%s\n' "${ANALYTICS_HEALTH:-healthy}"
    fi
    ;;
  *' compose ps --quiet analytics-api '*)
    printf '%s\n' "${ANALYTICS_CONTAINER_ID-test-analytics}" ;;
  *' compose stop --timeout 30 analytics-api '*)
    [[ "${ANALYTICS_STOP_FAIL:-false}" == false ]] ;;
  *' start test-analytics '*)
    [[ "${ANALYTICS_START_FAIL:-false}" == false ]] ;;
  *' compose ps --all --quiet metrics-ingest '*)
    printf '%s\n' "${INGEST_CONTAINER-test-ingest}" ;;
  *' inspect --type container --format '*)
    [[ "${INSPECT_FAIL:-false}" == false ]] || exit 1
    if [[ "${USE_PURGE_DEFAULTS:-false}" == false ]]; then
      printf 'PURGE_HEARTBEAT=%s\nHEARTBEAT_RETENTION_DAYS=%s\n' "${PURGE_ENABLED:-true}" "${RETENTION_DAYS:-30}"
    fi
    ;;
  *' retention_days='*)
    cat >> "$TEST_LOG"
    [[ "${PURGE_QUERY_FAIL:-false}" == false ]] || exit 1
    if [[ -f "$TEST_INGEST_STOPPED" ]]; then
      printf '%s\n' "${PURGE_COMPLETE_AFTER_STOP:-${PURGE_COMPLETE:-ready}}"
    else
      printf '%s\n' "${PURGE_COMPLETE:-ready}"
    fi
    ;;
  *' lifecycle_metric='*)
    cat >> "$TEST_LOG"
    if [[ " $* " == *'lifecycle_metric=Maintenance started '* && "${START_MARKER_FAIL:-false}" == true ]]; then exit 1; fi
    if [[ " $* " == *'lifecycle_metric=Maintenance stopped:'* && "${STOP_MARKER_FAIL:-false}" == true ]]; then exit 1; fi
    ;;
  *' compose version --short '*)
    printf '%s\n' "${COMPOSE_VERSION:-2.29.1}" ;;
  *' compose version '*|*' config --quiet '*) ;;
  *' ps --services --status running '*)
    printf '%s\n' "${RUNNING_SERVICES:-postgres metrics-ingest}" | tr ' ' '\n' ;;
  *'-Atc SELECT pg_total_relation_size('* )
    if [[ -f "$TEST_COMPACTED" ]]; then echo 400; else echo 1000; fi ;;
  *' pg_size_pretty('*) echo 'size report' ;;
  *' df -h '*) echo 'available space report' ;;
  *' stop --timeout 30 metrics-ingest '*)
    [[ "${STOP_FAIL:-false}" == false ]] || exit 1
    touch "$TEST_INGEST_STOPPED" ;;
  *' VACUUM (FULL, ANALYZE) public.metric_events;'*)
    if [[ "${INTERRUPT_VACUUM:-false}" == true ]]; then kill -TERM "$PPID"; exit 143; fi
    [[ "${VACUUM_FAIL:-false}" == false ]] || exit 1
    touch "$TEST_COMPACTED" ;;
  *' SELECT pg_terminate_backend('* )
    if [[ "${CANCEL_FAIL:-false}" == true ]]; then echo f; else echo t; fi ;;
  *' start test-ingest '*)
    rm -f "$TEST_INGEST_STOPPED"
    [[ "${START_FAIL:-false}" == false ]] ;;
  *) printf 'Unexpected invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/flock"
export PATH="$TEST_ROOT/bin:$PATH"

run_case() {
  : > "$TEST_LOG"
  rm -f "$TEST_COMPACTED" "$TEST_INGEST_STOPPED" "$TEST_ROOT/health-polled"
  bash "$TEST_ROOT/install/maintenance.sh" "$@"
}
has_call() { grep -Fq -- "$1" "$TEST_LOG"; }
# "! command" does not fail a "set -e" script, so negative assertions use this.
refute() {
  if "$@"; then
    printf 'Unexpected success: %s
' "$*" >&2
    exit 1
  fi
}

output="$(run_case --check)"
[[ "$output" == *'No services were stopped'* ]]
[[ "$output" == *'Prerequisites passed'* ]]
refute has_call 'stop --timeout'
refute has_call 'VACUUM (FULL'
refute has_call 'lifecycle_metric='

output="$(run_case --timeout-minutes 5)"
[[ "$output" == *'reduction=600 bytes'* ]]
has_call 'statement_timeout=300000'
has_call 'stop --timeout 30 metrics-ingest'
has_call 'start test-ingest'
refute has_call 'SELECT pg_terminate_backend'
has_call 'lifecycle_metric=Maintenance started'
has_call 'lifecycle_metric=Maintenance stopped: completed'
marker_start_line="$(grep -n 'lifecycle_metric=Maintenance started' "$TEST_LOG" | cut -d: -f1)"
marker_stop_line="$(grep -n 'lifecycle_metric=Maintenance stopped:' "$TEST_LOG" | cut -d: -f1)"
stop_line="$(grep -n 'stop --timeout' "$TEST_LOG" | cut -d: -f1)"
vacuum_line="$(grep -n 'VACUUM (FULL' "$TEST_LOG" | cut -d: -f1)"
start_line="$(grep -n 'start test-ingest' "$TEST_LOG" | cut -d: -f1)"
((stop_line < vacuum_line && vacuum_line < start_line))
((marker_start_line < stop_line && start_line < marker_stop_line))
prereq_line="$(grep -n 'retention_days=30' "$TEST_LOG" | head -n 1 | cut -d: -f1)"
((prereq_line < marker_start_line))
recheck_line="$(grep -n 'retention_days=30' "$TEST_LOG" | tail -n 1 | cut -d: -f1)"
((stop_line < recheck_line && recheck_line < vacuum_line))
# Without the optional Analytics API, maintenance never touches it.
refute has_call 'analytics-api'
refute has_call 'start test-analytics'

output="$(RETENTION_DAYS=7 run_case --check)"
has_call 'retention_days=7'
[[ "$output" == *'used retention 7 days'* ]]
output="$(USE_PURGE_DEFAULTS=true run_case --check)"
has_call 'retention_days=30'
# Mirror Go's strconv.ParseBool so maintenance agrees with the ingest service.
for enabled_value in 1 t T true TRUE True; do
  PURGE_ENABLED="$enabled_value" run_case --check >/dev/null
done
for disabled_value in 0 f F false FALSE False; do
  if output="$(PURGE_ENABLED="$disabled_value" run_case --check 2>&1)"; then
    printf 'Disabled purge value accepted: %s\n' "$disabled_value" >&2
    exit 1
  fi
  [[ "$output" == *'heartbeat purging is disabled'* ]]
done

for check_mode in run preview; do
  check_args=()
  [[ "$check_mode" == run ]] || check_args=(--check)
  for scenario in disabled backlog running failed stale missing retention-changed bad-bool bad-retention missing-container inspection-failed query-failed unexpected-result; do
    settings=()
    case "$scenario" in
      disabled) settings=(PURGE_ENABLED=false) ;;
      backlog) settings=(PURGE_COMPLETE=backlog) ;;
      running|failed|stale|missing) settings=("PURGE_COMPLETE=$scenario") ;;
      retention-changed) settings=(PURGE_COMPLETE=retention_changed) ;;
      bad-bool) settings=(PURGE_ENABLED=maybe) ;;
      bad-retention) settings=(RETENTION_DAYS=0) ;;
      missing-container) settings=(INGEST_CONTAINER=) ;;
      inspection-failed) settings=(INSPECT_FAIL=true) ;;
      query-failed) settings=(PURGE_QUERY_FAIL=true) ;;
      unexpected-result) settings=(PURGE_COMPLETE=unknown) ;;
    esac
    : > "$TEST_LOG"
    rm -f "$TEST_INGEST_STOPPED"
    if env "${settings[@]}" bash "$TEST_ROOT/install/maintenance.sh" "${check_args[@]}" > "$TEST_ROOT/rejected-output" 2>&1; then
      printf 'Expected prerequisite rejection: %s (%s)\n' "$scenario" "$check_mode" >&2
      exit 1
    fi
    refute has_call 'lifecycle_metric='
    refute has_call 'stop --timeout'
    refute has_call 'start test-ingest'
    refute has_call 'VACUUM (FULL'
    case "$scenario" in
      disabled) grep -q 'purging is disabled' "$TEST_ROOT/rejected-output" ;;
      backlog) grep -q "completed purge's cutoff remain" "$TEST_ROOT/rejected-output" ;;
    esac
  done
done

if output="$(PURGE_COMPLETE_AFTER_STOP=running run_case 2>&1)"; then echo 'Expected purge race rejection' >&2; exit 1; fi
has_call 'stop --timeout'
has_call 'start test-ingest'
has_call 'lifecycle_metric=Maintenance stopped: failed (exit 1)'
refute has_call 'VACUUM (FULL'

output="$(RUNNING_SERVICES=postgres run_case)"
refute has_call 'stop --timeout'
refute has_call 'start test-ingest'

if output="$(VACUUM_FAIL=true run_case 2>&1)"; then echo 'Expected vacuum failure' >&2; exit 1; fi
has_call 'SELECT pg_terminate_backend'
has_call 'start test-ingest'
has_call 'lifecycle_metric=Maintenance stopped: failed (exit 1)'

if output="$(INTERRUPT_VACUUM=true run_case 2>&1)"; then echo 'Expected interrupted vacuum failure' >&2; exit 1; fi
has_call 'SELECT pg_terminate_backend'
has_call 'start test-ingest'
has_call 'lifecycle_metric=Maintenance stopped: interrupted (exit 143)'

if output="$(VACUUM_FAIL=true CANCEL_FAIL=true run_case 2>&1)"; then echo 'Expected cancellation failure' >&2; exit 1; fi
[[ "$output" == *'Ingestion remains stopped'* ]]
refute has_call 'start test-ingest'
refute has_call 'lifecycle_metric=Maintenance stopped:'

if output="$(STOP_FAIL=true run_case 2>&1)"; then echo 'Expected stop failure' >&2; exit 1; fi
refute has_call 'VACUUM (FULL'
has_call 'start test-ingest'

if output="$(START_FAIL=true run_case 2>&1)"; then echo 'Expected restart failure' >&2; exit 1; fi
[[ "$output" == *'did not become healthy'* ]]
has_call 'lifecycle_metric=Maintenance stopped: ingestion restart failed'

# Ingestion is restored by container ID, never with "docker compose start",
# which would also start (or fail on a pruned) analytics-db-disable job.
output="$(run_case)"
refute has_call 'compose start'
has_call 'compose ps --all --quiet metrics-ingest'
has_call "inspect --type container --format {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} test-ingest"
for ingest_health in unhealthy exited; do
  if output="$(INGEST_HEALTH="$ingest_health" run_case 2>&1)"; then
    printf 'Expected ingest restore failure: %s\n' "$ingest_health" >&2; exit 1
  fi
  [[ "$output" == *'Ingestion did not become healthy'* ]]
  has_call 'lifecycle_metric=Maintenance stopped: ingestion restart failed'
done

# Compose older than 2.20 cannot read the depends_on "required" key.
if output="$(COMPOSE_VERSION=2.19.1 run_case --check 2>&1)"; then echo 'Expected old Compose rejection' >&2; exit 1; fi
[[ "$output" == *'upgrade the Docker Compose plugin to version 2.20 or newer'* ]]
refute has_call 'config --quiet'
output="$(COMPOSE_VERSION=v2.20.0 run_case --check)"

if output="$(START_MARKER_FAIL=true run_case 2>&1)"; then echo 'Expected start marker failure' >&2; exit 1; fi
refute has_call 'stop --timeout'
refute has_call 'VACUUM (FULL'
refute has_call 'lifecycle_metric=Maintenance stopped:'

if output="$(STOP_MARKER_FAIL=true run_case 2>&1)"; then echo 'Expected stop marker failure' >&2; exit 1; fi
has_call 'start test-ingest'
[[ "$output" == *'Could not record the maintenance stop marker'* ]]

if output="$(LOCK_FAIL=true run_case 2>&1)"; then echo 'Expected overlapping run rejection' >&2; exit 1; fi
refute has_call 'VACUUM (FULL'

if output="$(RUNNING_SERVICES=metrics-ingest run_case 2>&1)"; then echo 'Expected database preflight failure' >&2; exit 1; fi
refute has_call 'stop --timeout'

for invalid in 0 -1 1.5 99999 01; do
  if run_case --timeout-minutes "$invalid" >/dev/null 2>&1; then
    printf 'Invalid timeout accepted: %s\n' "$invalid" >&2
    exit 1
  fi
done
# The optional Analytics API is paused during compaction so its read queries
# cannot hold locks that make VACUUM FULL wait, then restored with plain
# "docker start" so Compose does not also start its dependencies.
line_of() { grep -nF -- "$1" "$TEST_LOG" | head -n 1 | cut -d: -f1; }
ANALYTICS_SERVICES='postgres metrics-ingest analytics-api'
output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" run_case)"
[[ "$output" == *'Pausing the Analytics API during compaction'* ]]
[[ "$output" == *'Restoring the Analytics API and waiting for health'* ]]
has_call 'lifecycle_metric=Maintenance stopped: completed'
refute has_call 'start --wait --wait-timeout 60 analytics-api'
ingest_stop_line="$(line_of 'stop --timeout 30 metrics-ingest')"
analytics_stop_line="$(line_of 'compose stop --timeout 30 analytics-api')"
recheck_line="$(grep -n 'retention_days=30' "$TEST_LOG" | tail -n 1 | cut -d: -f1)"
vacuum_line="$(line_of 'VACUUM (FULL')"
ingest_start_line="$(line_of 'start test-ingest')"
analytics_start_line="$(line_of 'start test-analytics')"
health_line="$(grep -n 'State.Health.*test-analytics' "$TEST_LOG" | head -n 1 | cut -d: -f1)"
marker_stop_line="$(line_of 'lifecycle_metric=Maintenance stopped:')"
((ingest_stop_line < analytics_stop_line && analytics_stop_line < recheck_line && recheck_line < vacuum_line))
((vacuum_line < ingest_start_line && ingest_start_line < analytics_start_line))
((analytics_start_line < health_line && health_line < marker_stop_line))

# A preview never stops the Analytics API.
output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" run_case --check)"
refute has_call 'analytics-api'
refute has_call 'start test-analytics'

# Health is polled until the restored container reports healthy.
output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" ANALYTICS_HEALTH=starting-then-healthy run_case)"
[[ "$(grep -c 'State.Health.*test-analytics' "$TEST_LOG")" -eq 2 ]]
has_call 'lifecycle_metric=Maintenance stopped: completed'

# When ingestion was already stopped it stays stopped; the API is still restored.
output="$(RUNNING_SERVICES='postgres analytics-api' run_case)"
has_call 'compose stop --timeout 30 analytics-api'
has_call 'start test-analytics'
refute has_call 'stop --timeout 30 metrics-ingest'
refute has_call 'start test-ingest'

for failure in ANALYTICS_HEALTH=unhealthy ANALYTICS_HEALTH=exited ANALYTICS_START_FAIL=true ANALYTICS_INSPECT_FAIL=true; do
  if output="$(export "$failure"; RUNNING_SERVICES="$ANALYTICS_SERVICES" run_case 2>&1)"; then
    printf 'Expected Analytics API restore failure: %s\n' "$failure" >&2
    exit 1
  fi
  [[ "$output" == *'The Analytics API did not become healthy'* ]]
  has_call 'start test-ingest'
  has_call 'lifecycle_metric=Maintenance stopped: analytics API restart failed'
done

# An ingestion restart failure remains the reported outcome; the API is still restored.
if output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" START_FAIL=true run_case 2>&1)"; then
  echo 'Expected restart failure' >&2; exit 1
fi
has_call 'start test-analytics'
has_call 'lifecycle_metric=Maintenance stopped: ingestion restart failed'

# A failed compaction restores both services.
if output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" VACUUM_FAIL=true run_case 2>&1)"; then
  echo 'Expected vacuum failure' >&2; exit 1
fi
has_call 'SELECT pg_terminate_backend'
has_call 'start test-ingest'
has_call 'start test-analytics'
has_call 'lifecycle_metric=Maintenance stopped: failed (exit 1)'

# If the compaction session cannot be stopped, both services stay stopped.
if output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" VACUUM_FAIL=true CANCEL_FAIL=true run_case 2>&1)"; then
  echo 'Expected cancellation failure' >&2; exit 1
fi
[[ "$output" == *'Ingestion remains stopped'* ]]
[[ "$output" == *'The Analytics API also remains stopped'* ]]
refute has_call 'start test-ingest'
refute has_call 'start test-analytics'

# A failed Analytics API stop aborts before compaction and restores both services.
if output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" ANALYTICS_STOP_FAIL=true run_case 2>&1)"; then
  echo 'Expected Analytics API stop failure' >&2; exit 1
fi
refute has_call 'VACUUM (FULL'
has_call 'start test-ingest'
has_call 'start test-analytics'

# A missing container ID aborts before compaction and restores ingestion only.
if output="$(RUNNING_SERVICES="$ANALYTICS_SERVICES" ANALYTICS_CONTAINER_ID= run_case 2>&1)"; then
  echo 'Expected missing Analytics API container failure' >&2; exit 1
fi
[[ "$output" == *'exactly one running Analytics API container is required'* ]]
refute has_call 'VACUUM (FULL'
refute has_call 'compose stop --timeout 30 analytics-api'
refute has_call 'start test-analytics'
has_call 'start test-ingest'

# Analytics API provisioning builds indexes concurrently; wait for it first.
for check_args in '' '--check'; do
  # shellcheck disable=SC2086
  if output="$(RUNNING_SERVICES='postgres metrics-ingest analytics-db-provision analytics-api' run_case $check_args 2>&1)"; then
    echo 'Expected provisioning-in-progress rejection' >&2; exit 1
  fi
  [[ "$output" == *'provisioning is still running'* ]]
  refute has_call 'lifecycle_metric='
  refute has_call 'stop --timeout'
  refute has_call 'VACUUM (FULL'
done

printf 'maintenance.sh tests passed\n'
