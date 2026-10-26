#!/usr/bin/env bash
set -Eeuo pipefail

# Real PostgreSQL and the production schema/preflight query; only Compose
# service control is simulated. No ports, host mounts, or persistent volumes.
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_CONTAINER="avsm-maintenance-integration-$$-$RANDOM"
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
cleanup() { docker rm --force "$TEST_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --detach --rm --name "$TEST_CONTAINER" --network none \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_USER=metrics_user \
  -e POSTGRES_DB=metrics postgres:18-alpine >/dev/null
for attempt in {1..30}; do
  if docker exec "$TEST_CONTAINER" pg_isready -U metrics_user -d metrics >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 30 ]]; then printf 'Test PostgreSQL did not start\n' >&2; exit 1; fi
  sleep 1
done
docker exec "$TEST_CONTAINER" sh -c 'mkdir -p /tmp/avsm/bin; touch /tmp/avsm/.env'
for test_file in maintenance.sh lifecycle-events.sh schema.sql; do
  docker exec -i "$TEST_CONTAINER" sh -c 'cat > "/tmp/avsm/$1"; sed -i "s/\r$//" "/tmp/avsm/$1"' sh "$test_file" < "$SOURCE_DIR/$test_file"
done
docker exec "$TEST_CONTAINER" psql -X -U metrics_user -d metrics -v ON_ERROR_STOP=1 -f /tmp/avsm/schema.sql >/dev/null
docker exec -i "$TEST_CONTAINER" sh -c 'cat > /tmp/avsm/bin/docker; chmod +x /tmp/avsm/bin/docker' <<'ADAPTER'
#!/bin/bash
set -eu
if [[ "$1" == inspect ]]; then printf 'PURGE_HEARTBEAT=true\nHEARTBEAT_RETENTION_DAYS=30\n'; exit 0; fi
[[ "$1" == compose ]]; shift
case "$1" in
  version|config) exit 0 ;;
  ps)
    if [[ "$*" == *'--all --quiet metrics-ingest'* ]]; then echo test-ingest; exit 0; fi
    printf 'postgres\n'; [[ -f /tmp/avsm/stopped ]] || printf 'metrics-ingest\n'; exit 0 ;;
  stop) touch /tmp/avsm/stopped ;;
  start) rm /tmp/avsm/stopped ;;
  exec)
    shift
    [[ "$1" == -T ]]; shift
    while [[ "$1" == -e ]]; do export "$2"; shift 2; done
    [[ "$1" == postgres ]]; shift
    exec "$@" ;;
  *) exit 1 ;;
esac
ADAPTER
docker exec "$TEST_CONTAINER" sed -i 's/\r$//' /tmp/avsm/bin/docker
docker exec -i "$TEST_CONTAINER" sh -c 'cat > /tmp/avsm/check.sh; sed -i "s/\r$//" /tmp/avsm/check.sh' <<'CHECKS'
#!/bin/bash
set -euo pipefail
export PATH=/tmp/avsm/bin:$PATH
sql() { psql -X -U metrics_user -d metrics -v ON_ERROR_STOP=1 -Atc "$1"; }
reject() {
  local output
  for mode in preview run; do
    local args=()
    [[ "$mode" == run ]] || args=(--check)
    if output="$(bash /tmp/avsm/maintenance.sh "${args[@]}" 2>&1)"; then
      printf 'Expected rejection: %s\n' "$1" >&2; exit 1
    fi
    [[ "$output" == *"$1"* ]] || { printf '%s\n' "$output" >&2; exit 1; }
    [[ ! -f /tmp/avsm/stopped ]]
    [[ $(sql "SELECT count(*) FROM metric_events WHERE clientname='AVSM-System';") == 0 ]]
  done
}
reject 'no completed heartbeat purge is recorded'
sql "INSERT INTO heartbeat_purge_status VALUES (1,'succeeded',now()-interval '24 hours',now()-interval '23 hours',now()-interval '31 days',30,10);"
# This heartbeat expired after the saved cutoff, and must not block maintenance.
sql "INSERT INTO metric_events (clientname,sort_key,event_timestamp,metric,action,event_id,received_at,source_ip)
VALUES ('test','newly-expired',now(),'test','Heartbeat',gen_random_uuid(),now()-interval '30 days 12 hours','127.0.0.1');"
bash /tmp/avsm/maintenance.sh --check >/dev/null
[[ $(sql "SELECT count(*) FROM metric_events WHERE clientname='AVSM-System';") == 0 ]]
sql "UPDATE heartbeat_purge_status SET status='running',finished_at=NULL;"
reject 'purge is running'
sql "UPDATE heartbeat_purge_status SET status='failed',finished_at=now();"
reject 'latest heartbeat purge failed'
sql "UPDATE heartbeat_purge_status SET status='succeeded',started_at=now()-interval '28 hours',finished_at=now()-interval '27 hours';"
reject 'older than 26 hours'
sql "UPDATE heartbeat_purge_status SET finished_at=now()+interval '1 minute';"
reject 'invalid timestamps'
sql "UPDATE heartbeat_purge_status SET finished_at=now()-interval '23 hours',retention_days=31;"
reject 'retention changed'
sql "UPDATE heartbeat_purge_status SET retention_days=30;"
sql "INSERT INTO metric_events (clientname,sort_key,event_timestamp,metric,action,event_id,received_at,source_ip)
VALUES ('test','leftover',now(),'test','Heartbeat',gen_random_uuid(),now()-interval '32 days','127.0.0.1');"
reject "completed purge's cutoff remain"
sql "DELETE FROM metric_events WHERE sort_key='leftover';"
bash /tmp/avsm/maintenance.sh --timeout-minutes 1 >/dev/null
[[ ! -f /tmp/avsm/stopped ]]
[[ $(sql "SELECT count(*) FROM metric_events WHERE clientname='AVSM-System';") == 2 ]]
[[ $(sql "SELECT count(*) FROM metric_events WHERE sort_key='newly-expired';") == 1 ]]
echo 'Schedule-aware maintenance PostgreSQL integration tests passed'
CHECKS
docker exec "$TEST_CONTAINER" bash /tmp/avsm/check.sh
