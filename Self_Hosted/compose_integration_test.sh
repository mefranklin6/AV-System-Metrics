#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end test of the real Compose stack as operators run it: the shipped
# docker-compose*.yml files selected through COMPOSE_FILE in a .env made from
# .env.example, locally built images, and "docker compose up --wait" exactly as
# update.sh runs it. It checks, in order:
#   1. the default install (ENABLE_ANALYTICS_API=false) becomes healthy and the
#      one-shot analytics-db-disable job exits 0,
#   2. enabling the Analytics API provisions metrics_reader and serves requests,
#   3. disabling it removes the API containers and disables the database login,
#   4. stopping ingestion and restarting it by container ID (as maintenance.sh
#      does) works even after the exited one-shot job has been pruned.
# Requires Docker with Compose 2.20 or newer. Ports are published on 127.0.0.1.

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_ID="$$-$RANDOM"
export COMPOSE_PROJECT_NAME="avsm-compose-it-$RUN_ID"
INGEST_IMAGE="avsm-compose-it/metrics-ingest:$RUN_ID"
ANALYTICS_IMAGE="avsm-compose-it/analytics-api:$RUN_ID"
APP_PORT="${AVSM_IT_APP_PORT:-18080}"
ANALYTICS_PORT="${AVSM_IT_ANALYTICS_PORT:-18081}"
WORK_DIR="$(mktemp -d)"

docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }
random_hex() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

BEARER="ingest-$(random_hex)$(random_hex)"
DATABASE_PASSWORD="db_$(random_hex)"
ANALYTICS_TOKEN="analytics-$(random_hex)$(random_hex)"
READER_PASSWORD="reader_$(random_hex)"

cleanup() {
  local status=$?
  if ((status != 0)); then
    (cd "$WORK_DIR" && docker compose ps --all >&2 && docker compose logs --tail 40 >&2) || true
  fi
  (cd "$WORK_DIR" && docker compose down --volumes --remove-orphans >/dev/null 2>&1) || true
  docker image rm "$INGEST_IMAGE" "$ANALYTICS_IMAGE" >/dev/null 2>&1 || true
  rm -rf -- "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT

step "Building the ingest and Analytics API images"
docker build --quiet --tag "$INGEST_IMAGE" "$SOURCE_DIR" >/dev/null
docker build --quiet --tag "$ANALYTICS_IMAGE" "$SOURCE_DIR/analytics_api" >/dev/null

for stack_file in docker-compose.yml docker-compose.database-expose-false.yml docker-compose.database-expose-true.yml \
  docker-compose.analytics-false.yml docker-compose.analytics-true.yml .env.example; do
  tr -d '\r' < "$SOURCE_DIR/$stack_file" > "$WORK_DIR/$stack_file"
done
cd "$WORK_DIR"

# set_env NAME VALUE replaces one setting in .env (values never contain '|').
set_env() {
  grep -q "^$1=" .env || fail "$1 is missing from .env.example"
  sed -i "s|^$1=.*|$1=$2|" .env
}
cp .env.example .env
set_env BEARER_TOKEN "$BEARER"
set_env POSTGRES_PASSWORD "$DATABASE_PASSWORD"
set_env APP_PORT "$APP_PORT"
set_env METRICS_INGEST_IMAGE "$INGEST_IMAGE"
set_env METRICS_INGEST_PULL_POLICY never
set_env ANALYTICS_API_IMAGE "$ANALYTICS_IMAGE"
set_env ANALYTICS_API_PULL_POLICY never
set_env ANALYTICS_PORT "$ANALYTICS_PORT"
set_env ANALYTICS_API_TOKEN "$ANALYTICS_TOKEN"
set_env ANALYTICS_DB_PASSWORD "$READER_PASSWORD"

# The same command update.sh runs after installing the files.
compose_up() { docker compose up -d --remove-orphans --wait --wait-timeout 300; }

# service_containers SERVICE lists the project's containers for a service,
# including stopped ones and services no longer in the configuration.
service_containers() {
  docker ps --all --quiet \
    --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
    --filter "label=com.docker.compose.service=$1"
}

expect_exited_zero() {
  local container state
  container="$(service_containers "$1")"
  [[ -n "$container" && "$container" != *$'\n'* ]] || fail "expected exactly one $1 container"
  state="$(docker inspect --type container --format '{{.State.Status}} {{.State.ExitCode}}' "$container")"
  [[ "$state" == 'exited 0' ]] || fail "$1 finished as '$state', want 'exited 0'"
}

reader_can_login() {
  docker compose exec -T postgres psql -X -U metrics_user -d metrics -Atc \
    "SELECT COALESCE((SELECT rolcanlogin::text FROM pg_roles WHERE rolname = 'metrics_reader'), 'missing')"
}

expect_ingest_healthy() {
  curl -fsS "http://127.0.0.1:$APP_PORT/health" >/dev/null || fail "ingest /health failed"
}

step "Starting the default stack (Analytics API disabled)"
grep -qx 'ENABLE_ANALYTICS_API=false' .env || fail ".env.example must default to ENABLE_ANALYTICS_API=false"
compose_up
expect_ingest_healthy
expect_exited_zero analytics-db-disable
[[ "$(reader_can_login)" == missing ]] || fail "metrics_reader exists on a fresh install"
[[ -z "$(service_containers analytics-api)" ]] || fail "analytics-api runs while disabled"

step "Enabling the Analytics API"
set_env ENABLE_ANALYTICS_API true
compose_up
expect_ingest_healthy
expect_exited_zero analytics-db-provision
[[ -z "$(service_containers analytics-db-disable)" ]] || fail "--remove-orphans kept analytics-db-disable"
[[ "$(reader_can_login)" == true ]] || fail "metrics_reader cannot log in after enabling"
curl -fsS "http://127.0.0.1:$ANALYTICS_PORT/health" >/dev/null || fail "analytics /health failed"
curl -fsS -H "Authorization: Bearer $ANALYTICS_TOKEN" "http://127.0.0.1:$ANALYTICS_PORT/api/v1/info" | grep -q '"api_version":"1"' \
  || fail "authenticated /api/v1/info failed"
status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong-token-wrong-token-wrong-token-0' \
  "http://127.0.0.1:$ANALYTICS_PORT/api/v1/info")"
[[ "$status" == 403 ]] || fail "wrong token returned HTTP $status, want 403"
api_logs="$(docker compose logs analytics-db-provision analytics-api 2>&1)"
[[ "$api_logs" != *"$ANALYTICS_TOKEN"* && "$api_logs" != *"$READER_PASSWORD"* && "$api_logs" != *"$DATABASE_PASSWORD"* ]] \
  || fail "Analytics API logs contain a secret"

step "Disabling the Analytics API"
set_env ENABLE_ANALYTICS_API false
compose_up
expect_ingest_healthy
expect_exited_zero analytics-db-disable
[[ -z "$(service_containers analytics-api)" && -z "$(service_containers analytics-db-provision)" ]] \
  || fail "Analytics API containers remain after disabling"
[[ "$(reader_can_login)" == false ]] || fail "metrics_reader can still log in after disabling"

step "Restarting ingestion by container ID after pruning the one-shot job"
docker rm "$(service_containers analytics-db-disable)" >/dev/null
ingest_container="$(docker compose ps --all --quiet metrics-ingest)"
docker compose stop --timeout 30 metrics-ingest >/dev/null
docker start "$ingest_container" >/dev/null
for attempt in {1..90}; do
  health="$(docker inspect --type container --format '{{.State.Health.Status}}' "$ingest_container")"
  [[ "$health" != healthy ]] || break
  [[ "$attempt" != 90 ]] || fail "ingestion did not become healthy after docker start"
  sleep 1
done
expect_ingest_healthy

echo 'Compose stack integration tests passed'
