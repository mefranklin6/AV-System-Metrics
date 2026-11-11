#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CHECK_ONLY=false
TIMEOUT_MINUTES=120
RESTORE_INGEST=false
RESTORE_ANALYTICS=false
INGEST_CONTAINER=""
ANALYTICS_CONTAINER=""
VACUUM_ACTIVE=false
WINDOW_STARTED=false
APP_NAME="avsm-maintenance-$(date +%s)-$$-$RANDOM"

usage() {
  cat <<'EOF'
Usage: bash maintenance.sh [--check] [--timeout-minutes MINUTES]

Run a disk-reclamation maintenance window for metric_events.
Stops ingestion (and the optional Analytics API), runs VACUUM (FULL, ANALYZE),
and restores each service that was running. Reads and writes to metric_events
are blocked during compaction.
Requires heartbeat purging to be enabled in the existing ingest container
and a successful purge in the last 26 hours with its original backlog cleared.

  --check                    Verify prerequisites and report sizes without downtime
  --timeout-minutes MINUTES   Vacuum time limit (default: 120; maximum: 35791)
  -h, --help                 Show this help

Run from the installed stack directory. Requires Bash, Docker Compose v2,
and flock (normally provided by util-linux). Do not run updates concurrently.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=true; shift ;;
    --timeout-minutes)
      (($# >= 2)) || die "--timeout-minutes requires a value"
      [[ "$2" =~ ^[1-9][0-9]{0,4}$ ]] || die "timeout must be a positive whole number of minutes"
      ((10#$2 <= 35791)) || die "timeout must not exceed 35791 minutes"
      TIMEOUT_MINUTES="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

cd "$SCRIPT_DIR"
[[ -f .env ]] || die ".env was not found in $SCRIPT_DIR"
for command_name in docker flock; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
# The Compose files use depends_on "required: false", added in Compose 2.20.
compose_version="$(docker compose version --short 2>/dev/null)" || die "Docker Compose v2 is required"
compose_version="${compose_version#v}"
if [[ "$compose_version" =~ ^([0-9]+)\.([0-9]+) ]] &&
  ((10#${BASH_REMATCH[1]} < 2 || (10#${BASH_REMATCH[1]} == 2 && 10#${BASH_REMATCH[2]} < 20))); then
  die "Docker Compose $compose_version is too old; upgrade the Docker Compose plugin to version 2.20 or newer"
fi
docker compose config --quiet

# Keep the lock file in place: removing it would let another process lock a
# different inode. The operating system releases the lock when this shell exits.
exec 9> .avsm-maintenance.lock
flock -n 9 || die "another maintenance window is already running"

[[ -f "$SCRIPT_DIR/lifecycle-events.sh" ]] || die "lifecycle-events.sh is missing; install it alongside maintenance.sh"
source "$SCRIPT_DIR/lifecycle-events.sh"

psql_query() {
  docker compose exec -T -e 'PGOPTIONS=-c lock_timeout=10s -c statement_timeout=30s' \
    postgres psql -X -U metrics_user -d metrics -v ON_ERROR_STOP=1 "$@"
}

cleanup() {
  local status=$?
  local termination_result
  local outcome
  outcome="$(lifecycle_outcome "$status")"
  trap - EXIT INT TERM HUP
  # Docker's exec client can exit before the server-side statement does.
  # Terminate only this run's named session before allowing ingestion back in.
  if [[ "$VACUUM_ACTIVE" == true ]]; then
    printf 'Stopping the maintenance database session...\n'
    if ! termination_result="$(psql_query -Atc "SELECT pg_terminate_backend(pid, 10000) FROM pg_stat_activity WHERE application_name = '$APP_NAME' AND pid <> pg_backend_pid();")" || [[ "$termination_result" == *f* ]]; then
      printf 'ERROR: Could not stop the maintenance session. Ingestion remains stopped; inspect PostgreSQL before running docker start %s.\n' "${INGEST_CONTAINER:-<metrics-ingest container>}" >&2
      if [[ "$RESTORE_ANALYTICS" == true ]]; then
        printf 'ERROR: The Analytics API also remains stopped; start it afterwards with docker start %s.\n' "$ANALYTICS_CONTAINER" >&2
      fi
      exit 1
    fi
  fi
  if [[ "$RESTORE_INGEST" == true ]]; then
    printf 'Restoring ingestion and waiting for health...\n'
    if ! restore_container "$INGEST_CONTAINER" 60; then
      printf 'ERROR: Ingestion did not become healthy. Inspect docker compose logs metrics-ingest.\n' >&2
      status=1
      outcome="ingestion restart failed"
    fi
  fi
  if [[ "$RESTORE_ANALYTICS" == true ]]; then
    printf 'Restoring the Analytics API and waiting for health...\n'
    if ! restore_container "$ANALYTICS_CONTAINER" 90; then
      printf 'ERROR: The Analytics API did not become healthy. Inspect docker compose logs analytics-api.\n' >&2
      if [[ "$status" -eq 0 ]]; then
        outcome="analytics API restart failed"
      fi
      status=1
    fi
  fi
  if [[ "$WINDOW_STARTED" == true ]]; then
    if ! record_lifecycle_event "Maintenance stopped: $outcome"; then
      printf 'ERROR: Could not record the maintenance stop marker in the database.\n' >&2
      status=1
    fi
  fi
  exit "$status"
}

# Restart exactly the container that maintenance stopped and wait up to
# MAX_SECONDS for it to become healthy. "docker compose start" would also start
# the service's dependencies: the provisioning job for the Analytics API, and
# the one-shot analytics-db-disable job for ingestion, which fails when that
# exited container has been pruned.
restore_container() {
  local container="$1"
  local max_seconds="$2"
  local health_state attempt
  [[ -n "$container" ]] || return 1
  docker start "$container" >/dev/null || return 1
  for ((attempt = 1; attempt <= max_seconds; attempt++)); do
    health_state="$(docker inspect --type container --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")" || return 1
    case "$health_state" in
      healthy) return 0 ;;
      unhealthy|exited|dead) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

running_services="$(docker compose ps --services --status running)"
[[ $'\n'"$running_services"$'\n' == *$'\npostgres\n'* ]] || die "PostgreSQL must already be running"
# The optional Analytics API provisioning job builds indexes concurrently;
# compaction would wait on (and could time out against) that work.
if [[ $'\n'"$running_services"$'\n' == *$'\nanalytics-db-provision\n'* ]]; then
  die "Analytics API database provisioning is still running; wait for it to finish and rerun maintenance"
fi

check_purge_prerequisites() {
  local ingest_container purge_settings setting_name setting_value purge_complete
  local purge_enabled=true retention_days=30
  ingest_container="$(docker compose ps --all --quiet metrics-ingest)" || die "could not find the existing ingest container"
  [[ -n "$ingest_container" && "$ingest_container" != *$'\n'* ]] || die "exactly one existing ingest container is required to verify heartbeat purge settings"
  # Whitelist these two settings in Docker's template; never print credentials.
  purge_settings="$(docker inspect --type container --format '{{range .Config.Env}}{{if or (eq (index (split . "=") 0) "PURGE_HEARTBEAT") (eq (index (split . "=") 0) "HEARTBEAT_RETENTION_DAYS")}}{{println .}}{{end}}{{end}}' "$ingest_container")" || die "could not inspect the ingest container's heartbeat purge settings"
  while IFS='=' read -r setting_name setting_value; do
    # Match the Go service's whitespace handling and defaults for empty values.
    setting_value="${setting_value#"${setting_value%%[![:space:]]*}"}"
    setting_value="${setting_value%"${setting_value##*[![:space:]]}"}"
    case "$setting_name" in
      PURGE_HEARTBEAT) purge_enabled="${setting_value:-true}" ;;
      HEARTBEAT_RETENTION_DAYS) retention_days="${setting_value:-30}" ;;
    esac
  done <<< "$purge_settings"
  # Accept exactly the values Go's strconv.ParseBool accepts.
  case "$purge_enabled" in
    1|t|T|true|TRUE|True) ;;
    0|f|F|false|FALSE|False) die "heartbeat purging is disabled in the ingest container; enable PURGE_HEARTBEAT and recreate ingestion before maintenance" ;;
    *) die "the ingest container has an invalid PURGE_HEARTBEAT setting" ;;
  esac
  [[ "$retention_days" =~ ^\+?[0-9]+$ && "$retention_days" =~ [1-9] ]] || die "the ingest container has an invalid HEARTBEAT_RETENTION_DAYS setting"

  # Allow heartbeats that expired since the scheduled pass. Only require the
  # backlog covered by that pass's fixed cutoff to have been cleared.
  if ! purge_complete="$(psql_query -At -v retention_days="$retention_days" <<'SQL'
SELECT COALESCE((
    SELECT CASE
        WHEN status = 'running' THEN 'running'
        WHEN status <> 'succeeded' THEN 'failed'
        WHEN retention_days <> :'retention_days'::integer THEN 'retention_changed'
        WHEN finished_at IS NULL OR finished_at < started_at
          OR finished_at > CURRENT_TIMESTAMP
          OR finished_at < CURRENT_TIMESTAMP - INTERVAL '26 hours' THEN 'stale'
        WHEN EXISTS (
            SELECT 1 FROM public.metric_events
            WHERE action = 'Heartbeat' AND received_at < purge.cutoff
        ) THEN 'backlog'
        ELSE 'ready'
    END
    FROM public.heartbeat_purge_status AS purge WHERE id = 1
), 'missing');
SQL
  )"; then
    die "could not verify heartbeat purge completion; no maintenance actions were performed"
  fi
  case "$purge_complete" in
    ready) printf 'Prerequisites passed: heartbeat purge enabled; a successful pass within 26 hours used retention %s days and cleared its original cutoff.\n' "$retention_days" ;;
    running) die "heartbeat purge is running or was interrupted; wait for a successful pass and rerun maintenance --check" ;;
    failed) die "the latest heartbeat purge failed; wait for its retry to succeed and rerun maintenance --check" ;;
    retention_changed) die "heartbeat retention changed since the latest successful purge; wait for a pass with the current settings" ;;
    stale) die "the latest successful heartbeat purge is older than 26 hours or has invalid timestamps; a recent successful pass is required" ;;
    backlog) die "heartbeat records older than the completed purge's cutoff remain; wait for a successful purge and rerun maintenance --check" ;;
    missing) die "no completed heartbeat purge is recorded; update/start ingestion and wait for a successful pass" ;;
    *) die "unexpected heartbeat purge completion result; no maintenance actions were performed" ;;
  esac
}

check_purge_prerequisites

size_bytes() {
  psql_query -Atc "SELECT pg_total_relation_size('public.metric_events');"
}
report_sizes() {
  psql_query -c "SELECT pg_size_pretty(pg_table_size('public.metric_events')) AS table_size,
    pg_size_pretty(pg_indexes_size('public.metric_events')) AS indexes_size,
    pg_size_pretty(pg_total_relation_size('public.metric_events')) AS total_size,
    pg_size_pretty(pg_database_size(current_database())) AS database_size;"
  docker compose exec -T postgres sh -c 'df -h "$PGDATA"'
}

printf 'Before maintenance (table size includes reusable space):\n'
before_bytes="$(size_bytes)"
[[ "$before_bytes" =~ ^[0-9]+$ ]] || die "could not read table size"
report_sizes
printf 'VACUUM FULL needs additional disk space for the rewritten table, indexes, and WAL.\n'
if [[ "$CHECK_ONLY" == true ]]; then
  printf 'Preview complete. No services were stopped and no compaction was run.\n'
  exit 0
fi

# Commit the start marker before stopping ingestion or locking the table.
# Abort before downtime if the database cannot record it.
record_lifecycle_event 'Maintenance started'
WINDOW_STARTED=true

if [[ $'\n'"$running_services"$'\n' == *$'\nmetrics-ingest\n'* ]]; then
  # The prerequisite check verified there is exactly one ingest container.
  INGEST_CONTAINER="$(docker compose ps --all --quiet metrics-ingest)" || die "could not find the running ingest container"
  [[ -n "$INGEST_CONTAINER" && "$INGEST_CONTAINER" != *$'\n'* ]] || die "exactly one running ingest container is required"
  # Set this before stopping so a partially failed stop still restores service.
  RESTORE_INGEST=true
  printf 'Opening maintenance window: stopping ingestion...\n'
  docker compose stop --timeout 30 metrics-ingest
else
  printf 'Ingestion is already stopped; it will remain stopped after maintenance.\n'
fi

# The optional Analytics API only reads, but an in-flight query holds a lock
# that would make VACUUM FULL wait (and fail after its 10-second lock wait
# limit), and its requests would queue behind the compaction lock anyway.
if [[ $'\n'"$running_services"$'\n' == *$'\nanalytics-api\n'* ]]; then
  ANALYTICS_CONTAINER="$(docker compose ps --quiet analytics-api)" || die "could not find the running Analytics API container"
  [[ -n "$ANALYTICS_CONTAINER" && "$ANALYTICS_CONTAINER" != *$'\n'* ]] || die "exactly one running Analytics API container is required"
  # Set this before stopping so a partially failed stop still restores service.
  RESTORE_ANALYTICS=true
  printf 'Pausing the Analytics API during compaction...\n'
  docker compose stop --timeout 30 analytics-api
fi

# Stopping ingestion also stops its purge worker. Recheck the recorded result
# before compaction in case a scheduled pass began after the initial check.
check_purge_prerequisites

printf 'Compacting metric_events (time limit: %s minutes; lock wait limit: 10 seconds)...\n' "$TIMEOUT_MINUTES"
VACUUM_ACTIVE=true
docker compose exec -T -e "PGAPPNAME=$APP_NAME" \
  -e "PGOPTIONS=-c lock_timeout=10s -c statement_timeout=$((TIMEOUT_MINUTES * 60000))" \
  postgres psql -X -U metrics_user -d metrics -v ON_ERROR_STOP=1 \
  -c 'VACUUM (FULL, ANALYZE) public.metric_events;'
VACUUM_ACTIVE=false

after_bytes="$(size_bytes)"
[[ "$after_bytes" =~ ^[0-9]+$ ]] || die "could not read compacted table size"
printf 'After maintenance:\n'
report_sizes
printf 'metric_events including indexes: before=%s bytes, after=%s bytes, reduction=%s bytes.\n' \
  "$before_bytes" "$after_bytes" "$((before_bytes - after_bytes))"
printf 'Compaction complete. Filesystem free space may also reflect retained WAL and other database activity.\n'
