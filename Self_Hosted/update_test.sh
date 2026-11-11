#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d "$SOURCE_DIR/.avsm-test.tmp.XXXXXX")"

cleanup() {
  if [[ -n "$TEST_ROOT" && "$TEST_ROOT" == "$SOURCE_DIR"/.avsm-test.tmp.* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}

trap cleanup EXIT

# "! command" does not fail a "set -e" script, so negative assertions use this.
refute() {
  if "$@"; then
    printf 'Unexpected success: %s
' "$*" >&2
    exit 1
  fi
}

FIXTURE_DIR="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$FIXTURE_DIR" "$MOCK_BIN"

for fixture_file in \
  docker-compose.yml \
  docker-compose.database-expose-false.yml \
  docker-compose.database-expose-true.yml \
  docker-compose.analytics-false.yml \
  docker-compose.analytics-true.yml \
  update.sh \
  maintenance.sh \
  lifecycle-events.sh; do
  cp -- "$SOURCE_DIR/$fixture_file" "$FIXTURE_DIR/$fixture_file"
done

cat > "$TEST_ROOT/base.env.example" <<'EOF'
A=old-default
B=old-default
CONFLICT=old-default
RETIRED=old-default
EXPOSE_DATABASE=false
METRICS_INGEST_IMAGE=ghcr.io/example/metrics-ingest:main

#### Do not modify below this line ####
COMPOSE_PATH_SEPARATOR=:
COMPOSE_FILE=docker-compose.yml:docker-compose.database-expose-${EXPOSE_DATABASE}.yml
EOF

NEW_COMPOSE_FILE='docker-compose.yml:docker-compose.database-expose-${EXPOSE_DATABASE}.yml:docker-compose.analytics-${ENABLE_ANALYTICS_API}.yml'
cat > "$FIXTURE_DIR/.env.example" <<EOF
A=new-default
B=old-default
CONFLICT=new-default
NEW_SETTING=new-value
EXPOSE_DATABASE=false
METRICS_INGEST_IMAGE=ghcr.io/example/metrics-ingest:main
ENABLE_ANALYTICS_API=false
ANALYTICS_API_TOKEN=change-me-long-random-analytics-token
ANALYTICS_DB_PASSWORD=change_me_url_safe_analytics_password
ANALYTICS_API_IMAGE=ghcr.io/example/analytics-api:main

#### Do not modify below this line ####
COMPOSE_PATH_SEPARATOR=:
COMPOSE_FILE=$NEW_COMPOSE_FILE
EOF

# The real template must keep the managed Compose selection last and include
# every overlay that update.sh validates.
grep -qx '#### Do not modify below this line ####' <(tr -d '\r' < "$SOURCE_DIR/.env.example")
grep -qx "COMPOSE_FILE=$NEW_COMPOSE_FILE" <(tr -d '\r' < "$SOURCE_DIR/.env.example")
grep -qx 'ENABLE_ANALYTICS_API=false' <(tr -d '\r' < "$SOURCE_DIR/.env.example")

cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
output_file=""
download_url=""
while (($#)); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    http*)
      download_url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
cp -- "$FIXTURE_DIR/${download_url##*/}" "$output_file"
EOF

cat > "$MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
arguments=" $* "
case "$arguments" in
  *' lifecycle_metric='*)
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    cat >> "$DOCKER_LOG"
    if [[ "$arguments" == *'lifecycle_metric=Update started '* && "${DEFER_START_MARKER:-false}" == true && ! -f "$DOCKER_LOG.ready" ]]; then exit 1; fi
    if [[ "$arguments" == *'lifecycle_metric=Update stopped:'* && "${STOP_MARKER_FAIL:-false}" == true ]]; then exit 1; fi
    ;;
  *" compose version --short "*)
    printf '%s\n' "${COMPOSE_VERSION:-2.29.1}"
    ;;
  *" config --images postgres "*)
    printf '%s\n' "$*" >> "$DOCKER_LOG.config"
    if [[ "$arguments" == *'.avsm-update.tmp.'* ]]; then
      printf '%s\n' "${STAGED_POSTGRES_IMAGE:-postgres:18-alpine}"
    else
      printf '%s\n' 'postgres:18-alpine'
    fi
    ;;
  *" config --images "*)
    # Every service's image: another service's postgres image comes first.
    printf '%s\n' "${STAGED_POSTGRES_IMAGE:-postgres:18-alpine}" 'ghcr.io/example/metrics-ingest:main' 'postgres:18-alpine'
    ;;
  *" config --quiet "*)
    printf '%s\n' "$*" >> "$DOCKER_LOG.config"
    ;;
  *" ps --services --status running "*)
    printf '%s\n' ${RUNNING_SERVICES:-postgres}
    ;;
  *" exec -T postgres pg_dump "*)
    printf '%s\n' fake-database-dump
    ;;
  *" pull "*)
    printf '%s\n' pull >> "$DOCKER_LOG"
    printf '%s\n' "$*" >> "$DOCKER_LOG.pull"
    [[ "${PULL_FAIL:-false}" == false ]]
    ;;
  *" compose up -d "*)
    printf '%s\n' up >> "$DOCKER_LOG"
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    touch "$DOCKER_LOG.ready"
    ;;
  *" compose ps "*)
    printf '%s\n' ps >> "$DOCKER_LOG"
    ;;
  *)
    printf 'Unexpected docker invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat > "$MOCK_BIN/scp" <<'EOF'
#!/usr/bin/env bash
set -eu
[[ "$1" == -r && "$2" == -- ]]
[[ "$4" == "${EXPECTED_SCP_DESTINATION:-tester@workstation:/backups}/" ]]
if [[ "${SCP_FAIL:-false}" == true ]]; then
  exit 1
fi
cp -r -- "$3" "$WORKSTATION_BACKUP_DIR/"
EOF

chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/docker" "$MOCK_BIN/scp"
export FIXTURE_DIR DOCKER_LOG WORKSTATION_BACKUP_DIR

make_install() {
  local install_dir="$1"
  local image_value="$2"
  local extra_settings="${3:-}"
  mkdir -p "$install_dir"
  cp -- "$SOURCE_DIR/update.sh" "$install_dir/update.sh"
  cp -- "$TEST_ROOT/base.env.example" "$install_dir/.env.example"
  for compose_file in \
    docker-compose.yml \
    docker-compose.database-expose-false.yml \
    docker-compose.database-expose-true.yml; do
    cp -- "$SOURCE_DIR/$compose_file" "$install_dir/$compose_file"
  done
  cat > "$install_dir/.env" <<EOF
A=old-default
B=local-value
CONFLICT=local-value
RETIRED=local-value
EXPOSE_DATABASE=false
METRICS_INGEST_IMAGE=$image_value
COMPOSE_PATH_SEPARATOR=:
COMPOSE_FILE=docker-compose.yml:docker-compose.database-expose-\${EXPOSE_DATABASE}.yml
EOF
  if [[ -n "$extra_settings" ]]; then
    printf '%s\n' "$extra_settings" >> "$install_dir/.env"
  fi
}

NORMAL_INSTALL="$TEST_ROOT/normal-install"
DOCKER_LOG="$TEST_ROOT/normal-docker.log"
export DOCKER_LOG
: > "$DOCKER_LOG"
make_install "$NORMAL_INSTALL" 'ghcr.io/example/metrics-ingest:main'

normal_output="$(
  PATH="$MOCK_BIN:$PATH" \
  AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$NORMAL_INSTALL/update.sh" 2>&1
)"

grep -q '^A=new-default$' "$NORMAL_INSTALL/.env"
grep -q '^B=local-value$' "$NORMAL_INSTALL/.env"
grep -q '^CONFLICT=local-value$' "$NORMAL_INSTALL/.env"
grep -q '^NEW_SETTING=new-value$' "$NORMAL_INSTALL/.env"
grep -q '^RETIRED=local-value$' "$NORMAL_INSTALL/.env"
grep -q 'New settings added with their template defaults (5)' <<< "$normal_output"
grep -q 'Unmodified settings updated to new template defaults (1)' <<< "$normal_output"
grep -q 'Conflicts; local values were kept (1)' <<< "$normal_output"
grep -q 'Settings retained for review because they left the template (1)' <<< "$normal_output"
# Managed Compose settings always follow the template and are reported by name.
grep -qF "Managed settings below '#### Do not modify below this line ####' replaced with the new template values (1)" <<< "$normal_output"
grep -qx '  - COMPOSE_FILE' <<< "$normal_output"
grep -qxF "COMPOSE_FILE=$NEW_COMPOSE_FILE" "$NORMAL_INSTALL/.env"
grep -qx 'COMPOSE_PATH_SEPARATOR=:' "$NORMAL_INSTALL/.env"
grep -qx 'ENABLE_ANALYTICS_API=false' "$NORMAL_INSTALL/.env"
cmp -- "$SOURCE_DIR/docker-compose.analytics-false.yml" "$NORMAL_INSTALL/docker-compose.analytics-false.yml"
cmp -- "$SOURCE_DIR/docker-compose.analytics-true.yml" "$NORMAL_INSTALL/docker-compose.analytics-true.yml"
# Validation uses the overlays selected by the merged flags, in COMPOSE_FILE order.
grep -q 'docker-compose.yml -f .*docker-compose.database-expose-false.yml -f .*docker-compose.analytics-false.yml config --quiet' "$DOCKER_LOG.config"
refute grep -q 'analytics-true' "$DOCKER_LOG.config"
grep -q '^pull$' "$DOCKER_LOG"
grep -q '^up$' "$DOCKER_LOG"
cmp -- "$SOURCE_DIR/maintenance.sh" "$NORMAL_INSTALL/maintenance.sh"
cmp -- "$SOURCE_DIR/lifecycle-events.sh" "$NORMAL_INSTALL/lifecycle-events.sh"
grep -q 'lifecycle_metric=Update started' "$DOCKER_LOG"
grep -q 'lifecycle_metric=Update stopped: completed' "$DOCKER_LOG"
grep -q 'up -d --remove-orphans --wait --wait-timeout 120' "$DOCKER_LOG"
marker_start_line="$(grep -n 'lifecycle_metric=Update started' "$DOCKER_LOG" | cut -d: -f1)"
marker_stop_line="$(grep -n 'lifecycle_metric=Update stopped:' "$DOCKER_LOG" | cut -d: -f1)"
pull_line="$(grep -n '^pull$' "$DOCKER_LOG" | cut -d: -f1)"
up_line="$(grep -n '^up$' "$DOCKER_LOG" | cut -d: -f1)"
# Images are pulled with the validated new files before anything changes.
((pull_line < marker_start_line && marker_start_line < up_line && up_line < marker_stop_line))
[[ "$(grep -c '^pull$' "$DOCKER_LOG")" -eq 1 ]]
grep -q '\.avsm-update\.tmp\..*/docker-compose.yml .*docker-compose.analytics-false.yml pull' "$DOCKER_LOG.pull"
# The Postgres major-version guard reads the postgres service's image only.
grep -q 'config --images postgres' "$DOCKER_LOG.config"
# Files are installed by atomic rename, with the expected modes, and no
# temporary files remain.
[[ -z "$(find "$NORMAL_INSTALL" -maxdepth 1 -name '.avsm-new.*' -print -quit)" ]]
if [[ "$(stat -c %a "$NORMAL_INSTALL/.env" 2>/dev/null)" == 600 ]]; then
  [[ "$(stat -c %a "$NORMAL_INSTALL/update.sh")" == 755 && "$(stat -c %a "$NORMAL_INSTALL/maintenance.sh")" == 755 ]]
fi
cmp -- "$SOURCE_DIR/update.sh" "$NORMAL_INSTALL/update.sh"
test -n "$(find "$NORMAL_INSTALL/.avsm-backups" -name metrics.dump -print -quit)"

PINNED_INSTALL="$TEST_ROOT/pinned-install"
DOCKER_LOG="$TEST_ROOT/pinned-docker.log"
export DOCKER_LOG
: > "$DOCKER_LOG"
make_install "$PINNED_INSTALL" 'ghcr.io/example/metrics-ingest:sha-deadbeef'

set +e
pinned_output="$(
  PATH="$MOCK_BIN:$PATH" \
  AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$PINNED_INSTALL/update.sh" 2>&1
)"
pinned_status=$?
set -e

[[ "$pinned_status" -eq 2 ]]
grep -q 'pinned to an immutable digest or commit tag' <<< "$pinned_output"
refute grep -qE '^(pull|up)$' "$DOCKER_LOG"
grep -q 'lifecycle_metric=Update stopped: configuration updated; containers unchanged' "$DOCKER_LOG"

WORKSTATION_INSTALL="$TEST_ROOT/workstation-install"
WORKSTATION_BACKUP_DIR="$TEST_ROOT/workstation-backups"
DOCKER_LOG="$TEST_ROOT/workstation-docker.log"
mkdir -p "$WORKSTATION_BACKUP_DIR"
: > "$DOCKER_LOG"
make_install "$WORKSTATION_INSTALL" 'ghcr.io/example/metrics-ingest:main'

workstation_output="$(
  PATH="$MOCK_BIN:$PATH" \
  AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$WORKSTATION_INSTALL/update.sh" \
    --backup-location workstation \
    --workstation-destination 'tester@workstation:/backups' 2>&1
)"

test -n "$(find "$WORKSTATION_BACKUP_DIR" -name metrics.dump -print -quit)"
test -n "$(find "$WORKSTATION_BACKUP_DIR" -name .env -print -quit)"
[[ -z "$(find "$WORKSTATION_INSTALL/.avsm-backups" -mindepth 1 -print -quit)" ]]
grep -q 'tester@workstation:/backups/' <<< "$workstation_output"

# Windows OpenSSH drive paths and domain-style users are accepted.
for destination in 'jdoe@campus.edu@win-pc:/C:/avsm-backups' 'tester@win-pc:D:/backups'; do
  rm -rf -- "$WORKSTATION_BACKUP_DIR" && mkdir -p "$WORKSTATION_BACKUP_DIR"
  : > "$DOCKER_LOG"
  windows_install="$TEST_ROOT/windows-install"
  rm -rf -- "$windows_install"
  make_install "$windows_install" 'ghcr.io/example/metrics-ingest:main'
  PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    EXPECTED_SCP_DESTINATION="$destination" \
    bash "$windows_install/update.sh" --backup-location workstation \
    --workstation-destination "$destination" >/dev/null 2>&1
  test -n "$(find "$WORKSTATION_BACKUP_DIR" -name metrics.dump -print -quit)"
done

# Unsafe or ambiguous destinations are rejected before any backup or change.
for destination in 'tester@win-pc:/C:/AVSM Backups' 'tester@workstation:/backups/../etc' \
  'tester@workstation:backups' 'workstation:/backups' 'tester@workstation:/C:' 'tester@work station:/backups'; do
  rejected_install="$TEST_ROOT/rejected-install"
  rm -rf -- "$rejected_install"
  make_install "$rejected_install" 'ghcr.io/example/metrics-ingest:main'
  : > "$DOCKER_LOG"
  if rejected_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    bash "$rejected_install/update.sh" --backup-location workstation \
    --workstation-destination "$destination" 2>&1)"; then
    printf 'Unsafe workstation destination accepted: %s\n' "$destination" >&2
    exit 1
  fi
  grep -q 'workstation destination must be' <<< "$rejected_output"
  [[ ! -e "$rejected_install/.avsm-backups" ]]
  [[ ! -s "$DOCKER_LOG" ]]
done

FAILED_INSTALL="$TEST_ROOT/failed-install"
DOCKER_LOG="$TEST_ROOT/failed-docker.log"
: > "$DOCKER_LOG"
make_install "$FAILED_INSTALL" 'ghcr.io/example/metrics-ingest:main'

set +e
failed_output="$(
  PATH="$MOCK_BIN:$PATH" \
  AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  SCP_FAIL=true \
  bash "$FAILED_INSTALL/update.sh" \
    --backup-location workstation \
    --workstation-destination 'tester@workstation:/backups' 2>&1
)"
failed_status=$?
set -e

[[ "$failed_status" -ne 0 ]]
grep -q 'workstation backup transfer failed' <<< "$failed_output"
grep -q '^A=old-default$' "$FAILED_INSTALL/.env"
test -n "$(find "$FAILED_INSTALL/.avsm-backups" -name metrics.dump -print -quit)"
[[ ! -s "$DOCKER_LOG" ]]

# A server backup can be redirected to another absolute directory.
CUSTOM_INSTALL="$TEST_ROOT/custom-install"
CUSTOM_BACKUP_ROOT="$TEST_ROOT/custom backups"
DOCKER_LOG="$TEST_ROOT/custom-docker.log"
: > "$DOCKER_LOG"
make_install "$CUSTOM_INSTALL" 'ghcr.io/example/metrics-ingest:main'
custom_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$CUSTOM_INSTALL/update.sh" --backup-dir "$CUSTOM_BACKUP_ROOT/" 2>&1)"
test -n "$(find "$CUSTOM_BACKUP_ROOT" -name metrics.dump -print -quit)"
[[ ! -e "$CUSTOM_INSTALL/.avsm-backups" ]]
grep -qF "$CUSTOM_BACKUP_ROOT/" <<< "$custom_output"

# Relative directories and workstation conflicts are rejected before any change.
for rejected_arguments in 'relative-backups' "/backups --backup-location workstation --workstation-destination tester@workstation:/backups"; do
  rejected_install="$TEST_ROOT/rejected-dir-install"
  rm -rf -- "$rejected_install"
  make_install "$rejected_install" 'ghcr.io/example/metrics-ingest:main'
  : > "$DOCKER_LOG"
  # shellcheck disable=SC2086
  if PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    bash "$rejected_install/update.sh" --backup-dir $rejected_arguments >/dev/null 2>&1; then
    printf 'Invalid backup directory accepted: %s\n' "$rejected_arguments" >&2
    exit 1
  fi
  grep -q '^A=old-default$' "$rejected_install/.env"
  [[ ! -s "$DOCKER_LOG" ]]
done

# On a terminal, the updater asks about the database and proposes the directory.
if script -qec true /dev/null >/dev/null 2>&1; then
  PROMPT_BACKUP_ROOT="$TEST_ROOT/prompted-backups"
  for answers in "y|1|$PROMPT_BACKUP_ROOT" 'n|1|'; do
    prompt_install="$TEST_ROOT/prompt-install"
    rm -rf -- "$prompt_install" "$PROMPT_BACKUP_ROOT"
    make_install "$prompt_install" 'ghcr.io/example/metrics-ingest:main'
    : > "$DOCKER_LOG"
    prompt_output="$(printf '%s\n' "${answers//|/$'\n'}" | PATH="$MOCK_BIN:$PATH" \
      AVSM_REPOSITORY_URL='https://example.invalid/repository' \
      script -qec "bash '$prompt_install/update.sh'" /dev/null 2>&1)"
    grep -q 'Back up the PostgreSQL database before updating' <<< "$prompt_output"
    grep -qF "$prompt_install/.avsm-backups" <<< "$prompt_output"
    case "$answers" in
      y*)
        test -n "$(find "$PROMPT_BACKUP_ROOT" -name metrics.dump -print -quit)"
        [[ ! -e "$prompt_install/.avsm-backups" ]]
        ;;
      n*)
        grep -q 'database backup explicitly skipped' <<< "$prompt_output"
        test -n "$(find "$prompt_install/.avsm-backups" -name .env -print -quit)"
        [[ -z "$(find "$prompt_install/.avsm-backups" -name metrics.dump -print -quit)" ]]
        ;;
    esac
  done
else
  printf 'Skipping interactive prompt tests: util-linux script is unavailable\n'
fi

# A preview validates downloads but never records an operational window.
: > "$DOCKER_LOG"
PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$NORMAL_INSTALL/update.sh" --check >/dev/null
[[ ! -s "$DOCKER_LOG" ]]

for scenario in deferred-start pull-failure stop-marker-failure; do
  scenario_install="$TEST_ROOT/$scenario"
  DOCKER_LOG="$TEST_ROOT/$scenario.log"
  : > "$DOCKER_LOG"
  make_install "$scenario_install" 'ghcr.io/example/metrics-ingest:main'
  defer_start=false
  pull_fail=false
  stop_marker_fail=false
  case "$scenario" in
    deferred-start) defer_start=true ;;
    pull-failure) pull_fail=true ;;
    stop-marker-failure) stop_marker_fail=true ;;
  esac
  set +e
  scenario_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    DEFER_START_MARKER="$defer_start" PULL_FAIL="$pull_fail" STOP_MARKER_FAIL="$stop_marker_fail" \
    bash "$scenario_install/update.sh" 2>&1)"
  scenario_status=$?
  set -e
  case "$scenario" in
    deferred-start)
      [[ "$scenario_status" -eq 0 ]]
      [[ "$(grep -c 'lifecycle_metric=Update started' "$DOCKER_LOG")" -eq 2 ]]
      [[ "$(grep 'lifecycle_metric=Update started' "$DOCKER_LOG" | sort -u | wc -l)" -eq 1 ]]
      grep -q 'lifecycle_metric=Update stopped: completed' "$DOCKER_LOG"
      ;;
    pull-failure)
      [[ "$scenario_status" -eq 1 ]]
      grep -q 'pulling the container images failed; no live files or containers were changed' <<< "$scenario_output"
      refute grep -q 'lifecycle_metric=' "$DOCKER_LOG"
      refute grep -q '^up$' "$DOCKER_LOG"
      grep -q '^A=old-default$' "$scenario_install/.env"
      [[ ! -e "$scenario_install/docker-compose.analytics-false.yml" ]]
      ;;
    stop-marker-failure)
      [[ "$scenario_status" -eq 1 ]]
      [[ "$scenario_output" == *'could not record the update stop marker'* ]]
      ;;
  esac
done

# A first update without a previous template preserves local values, but the
# managed Compose settings still adopt the new template so new overlays apply.
FIRST_INSTALL="$TEST_ROOT/first-install"
DOCKER_LOG="$TEST_ROOT/first-docker.log"
: > "$DOCKER_LOG"
make_install "$FIRST_INSTALL" 'ghcr.io/example/metrics-ingest:main'
rm -f -- "$FIRST_INSTALL/.env.example"
sed -i 's/^COMPOSE_PATH_SEPARATOR=.*/COMPOSE_PATH_SEPARATOR=;/' "$FIRST_INSTALL/.env"
first_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$FIRST_INSTALL/update.sh" 2>&1)"
grep -q 'no previous .env.example was found' <<< "$first_output"
grep -q 'except the managed Compose settings' <<< "$first_output"
grep -qF "replaced with the new template values (2)" <<< "$first_output"
grep -qx '  - COMPOSE_PATH_SEPARATOR' <<< "$first_output"
grep -qx '  - COMPOSE_FILE' <<< "$first_output"
grep -qxF "COMPOSE_FILE=$NEW_COMPOSE_FILE" "$FIRST_INSTALL/.env"
grep -qx 'COMPOSE_PATH_SEPARATOR=:' "$FIRST_INSTALL/.env"
grep -qx 'A=old-default' "$FIRST_INSTALL/.env"
grep -qx 'CONFLICT=local-value' "$FIRST_INSTALL/.env"

# Enabling the Analytics API validates its overlay, allows longer for first-time
# provisioning, removes orphans, and never prints the secrets.
ANALYTICS_TOKEN_ONE='analytics-token-one-0123456789abcdefghijklmnop'
ANALYTICS_TOKEN_TWO='analytics-token-two-0123456789abcdefghijklmnop'
ANALYTICS_PASSWORD='Reader.Password_0123~xyz-'
INGEST_TOKEN='ingest-token-0123456789abcdefghijklmnopqrstuv'
DATABASE_PASSWORD='database_password_0123456789'
analytics_settings() {
  local enabled="${1:-true}"
  local tokens="${2-$ANALYTICS_TOKEN_ONE, $ANALYTICS_TOKEN_TWO}"
  local password="${3-$ANALYTICS_PASSWORD}"
  local image="${4:-ghcr.io/example/analytics-api:main}"
  printf '%s\n' \
    "BEARER_TOKEN=$INGEST_TOKEN" \
    "POSTGRES_PASSWORD=$DATABASE_PASSWORD" \
    "ENABLE_ANALYTICS_API=$enabled" \
    "ANALYTICS_API_TOKEN=$tokens" \
    "ANALYTICS_DB_PASSWORD=$password" \
    "ANALYTICS_API_IMAGE=$image"
}
assert_no_secrets() {
  local text="$1"
  local secret
  for secret in "$ANALYTICS_TOKEN_ONE" "$ANALYTICS_TOKEN_TWO" "$ANALYTICS_PASSWORD" "$INGEST_TOKEN" "$DATABASE_PASSWORD"; do
    if grep -qF -- "$secret" <<< "$text"; then
      printf 'A secret value was printed by update.sh\n' >&2
      exit 1
    fi
  done
}

ANALYTICS_INSTALL="$TEST_ROOT/analytics-install"
DOCKER_LOG="$TEST_ROOT/analytics-docker.log"
: > "$DOCKER_LOG"
make_install "$ANALYTICS_INSTALL" 'ghcr.io/example/metrics-ingest:main' "$(analytics_settings)"
analytics_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$ANALYTICS_INSTALL/update.sh" 2>&1)"
grep -qx 'ENABLE_ANALYTICS_API=true' "$ANALYTICS_INSTALL/.env"
grep -qxF "ANALYTICS_API_TOKEN=$ANALYTICS_TOKEN_ONE, $ANALYTICS_TOKEN_TWO" "$ANALYTICS_INSTALL/.env"
grep -q 'docker-compose.database-expose-false.yml -f .*docker-compose.analytics-true.yml config --quiet' "$DOCKER_LOG.config"
refute grep -q 'analytics-false' "$DOCKER_LOG.config"
# Default ANALYTICS_PROVISION_TIMEOUT (15m) plus 3 minutes.
grep -q 'up -d --remove-orphans --wait --wait-timeout 1080' "$DOCKER_LOG"
grep -q 'first-time database provisioning may take several minutes' <<< "$analytics_output"
grep -q 'lifecycle_metric=Update stopped: completed' "$DOCKER_LOG"
assert_no_secrets "$analytics_output"

# A preview validates the enabled overlay without changes.
: > "$DOCKER_LOG"
rm -f -- "$DOCKER_LOG.config"
check_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$ANALYTICS_INSTALL/update.sh" --check 2>&1)"
grep -q 'Check complete' <<< "$check_output"
grep -q 'analytics-true.yml config --quiet' "$DOCKER_LOG.config"
[[ ! -s "$DOCKER_LOG" ]]
assert_no_secrets "$check_output"

# Invalid flags and unsafe Analytics API settings stop before any backup or change.
run_rejected_analytics() {
  local expected_message="$1"
  local settings="$2"
  local rejected_install="$TEST_ROOT/rejected-analytics-install"
  local rejected_output
  rm -rf -- "$rejected_install"
  make_install "$rejected_install" 'ghcr.io/example/metrics-ingest:main' "$settings"
  cp -- "$rejected_install/.env" "$TEST_ROOT/rejected-analytics.env"
  : > "$DOCKER_LOG"
  if rejected_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    bash "$rejected_install/update.sh" --backup-location server 2>&1)"; then
    printf 'Invalid Analytics API settings accepted: %s\n' "$expected_message" >&2
    exit 1
  fi
  grep -qF -- "$expected_message" <<< "$rejected_output" || {
    printf 'Missing rejection message: %s\n%s\n' "$expected_message" "$rejected_output" >&2
    exit 1
  }
  cmp -- "$TEST_ROOT/rejected-analytics.env" "$rejected_install/.env"
  [[ ! -e "$rejected_install/.avsm-backups" ]]
  [[ ! -s "$DOCKER_LOG" ]]
  [[ ! -e "$rejected_install/docker-compose.analytics-true.yml" ]]
  assert_no_secrets "$rejected_output"
}
run_rejected_analytics 'ENABLE_ANALYTICS_API must be either true or false' "$(analytics_settings yes)"
run_rejected_analytics 'ENABLE_ANALYTICS_API must be either true or false' "$(analytics_settings True)"
run_rejected_analytics 'ANALYTICS_API_TOKEN must be changed from the .env.example value' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE,change-me-long-random-analytics-token")"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 2 must be 32 to 512 characters' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE,short-token")"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 1 must be 32 to 512 characters' \
  "$(analytics_settings true "$(printf 'x%.0s' {1..513})")"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 1 may only contain letters, digits' \
  "$(analytics_settings true 'analytics token with spaces 0123456789abcdef')"
# Compose would interpolate $NAME in .env, so the API would get another token.
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 2 may only contain letters, digits' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE,"'analytics-token-$HOME-0123456789abcdefghij')"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 1 may only contain letters, digits' \
  "$(analytics_settings true 'analytics-token-with#hash-0123456789abcdef')"
run_rejected_analytics 'ANALYTICS_PROVISION_TIMEOUT must be whole hours, minutes, or seconds' \
  "$(analytics_settings)"$'\n''ANALYTICS_PROVISION_TIMEOUT=1.5h'
run_rejected_analytics 'ANALYTICS_PROVISION_TIMEOUT must be longer than zero' \
  "$(analytics_settings)"$'\n''ANALYTICS_PROVISION_TIMEOUT=0m'

run_rejected_analytics 'ANALYTICS_API_TOKEN entry 2 must not reuse BEARER_TOKEN' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE,$INGEST_TOKEN")"
run_rejected_analytics 'ANALYTICS_API_TOKEN is required' "$(analytics_settings true '')"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 1 is empty' "$(analytics_settings true ' , ')"
run_rejected_analytics 'ANALYTICS_API_TOKEN entry 2 is empty' "$(analytics_settings true "$ANALYTICS_TOKEN_ONE,")"
run_rejected_analytics 'ANALYTICS_API_TOKEN may list at most 64 tokens' \
  "$(analytics_settings true "$(printf "$ANALYTICS_TOKEN_ONE,%.0s" {1..64})$ANALYTICS_TOKEN_TWO")"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD is required' "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" '')"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD must be changed from the .env.example value' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" 'change_me_url_safe_analytics_password')"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD must be 16 to 128 characters' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" 'Short_pw.123')"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD must be 16 to 128 characters' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" 'has@unsafe/characters#0123')"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD must be 16 to 128 characters' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" "$(printf 'p%.0s' {1..129})")"
run_rejected_analytics 'ANALYTICS_DB_PASSWORD must not reuse POSTGRES_PASSWORD' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" "$DATABASE_PASSWORD")"

# Disabled installs never need Analytics API secrets, even the example values.
DISABLED_INSTALL="$TEST_ROOT/disabled-install"
DOCKER_LOG="$TEST_ROOT/disabled-docker.log"
: > "$DOCKER_LOG"
make_install "$DISABLED_INSTALL" 'ghcr.io/example/metrics-ingest:main' \
  "$(analytics_settings false 'change-me-long-random-analytics-token' 'change_me_url_safe_analytics_password' 'ghcr.io/example/analytics-api:sha-deadbeef')"
PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$DISABLED_INSTALL/update.sh" >/dev/null 2>&1
grep -q 'analytics-false.yml config --quiet' "$DOCKER_LOG.config"
grep -q 'up -d --remove-orphans --wait --wait-timeout 120' "$DOCKER_LOG"

# A pinned Analytics API image stops before containers change, like the ingest image.
PINNED_ANALYTICS_INSTALL="$TEST_ROOT/pinned-analytics-install"
DOCKER_LOG="$TEST_ROOT/pinned-analytics-docker.log"
: > "$DOCKER_LOG"
make_install "$PINNED_ANALYTICS_INSTALL" 'ghcr.io/example/metrics-ingest:main' \
  "$(analytics_settings true "$ANALYTICS_TOKEN_ONE" "$ANALYTICS_PASSWORD" 'ghcr.io/example/analytics-api@sha256:0123456789abcdef')"
set +e
pinned_analytics_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$PINNED_ANALYTICS_INSTALL/update.sh" 2>&1)"
pinned_analytics_status=$?
set -e
[[ "$pinned_analytics_status" -eq 2 ]]
grep -q 'ANALYTICS_API_IMAGE is pinned to an immutable digest or commit tag' <<< "$pinned_analytics_output"
refute grep -q 'METRICS_INGEST_IMAGE is pinned' <<< "$pinned_analytics_output"
refute grep -qE '^(pull|up)$' "$DOCKER_LOG"
grep -qx 'ENABLE_ANALYTICS_API=true' "$PINNED_ANALYTICS_INSTALL/.env"

# A longer provisioning limit lengthens the wait for the stack to become healthy.
TIMEOUT_INSTALL="$TEST_ROOT/timeout-install"
DOCKER_LOG="$TEST_ROOT/timeout-docker.log"
: > "$DOCKER_LOG"
make_install "$TIMEOUT_INSTALL" 'ghcr.io/example/metrics-ingest:main' \
  "$(analytics_settings)"$'\n''ANALYTICS_PROVISION_TIMEOUT=1h'
PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$TIMEOUT_INSTALL/update.sh" >/dev/null 2>&1
grep -q 'up -d --remove-orphans --wait --wait-timeout 3780' "$DOCKER_LOG"
grep -qx 'ANALYTICS_PROVISION_TIMEOUT=1h' "$TIMEOUT_INSTALL/.env"

# The real template carries ANALYTICS_PROVISION_TIMEOUT so it is never "retired".
grep -qx 'ANALYTICS_PROVISION_TIMEOUT=15m' <(tr -d '\r' < "$SOURCE_DIR/.env.example")

# Docker Compose older than 2.20 is refused before any backup or change.
for old_version in 2.19.1 v2.17.3 1.29.2; do
  old_install="$TEST_ROOT/old-compose-install"
  rm -rf -- "$old_install"
  make_install "$old_install" 'ghcr.io/example/metrics-ingest:main'
  cp -- "$old_install/.env" "$TEST_ROOT/old-compose.env"
  : > "$DOCKER_LOG"
  if old_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
    COMPOSE_VERSION="$old_version" bash "$old_install/update.sh" 2>&1)"; then
    printf 'Old Docker Compose accepted: %s\n' "$old_version" >&2
    exit 1
  fi
  grep -q 'upgrade the Docker Compose plugin to version 2.20 or newer' <<< "$old_output"
  cmp -- "$TEST_ROOT/old-compose.env" "$old_install/.env"
  [[ ! -e "$old_install/.avsm-backups" ]]
done

# The PostgreSQL major-version guard reads the postgres service's own image, not
# the first postgres image of any service.
MAJOR_INSTALL="$TEST_ROOT/major-install"
DOCKER_LOG="$TEST_ROOT/major-docker.log"
: > "$DOCKER_LOG"
make_install "$MAJOR_INSTALL" 'ghcr.io/example/metrics-ingest:main'
if major_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  STAGED_POSTGRES_IMAGE='postgres:19-alpine' bash "$MAJOR_INSTALL/update.sh" 2>&1)"; then
  echo 'PostgreSQL major-version change accepted' >&2
  exit 1
fi
grep -q 'automatic PostgreSQL major-version updates are not supported (18 to 19)' <<< "$major_output"
grep -q '^A=old-default$' "$MAJOR_INSTALL/.env"
[[ ! -s "$DOCKER_LOG" ]]

# A local edit below the managed marker is replaced, with a prominent warning.
EDITED_INSTALL="$TEST_ROOT/edited-install"
DOCKER_LOG="$TEST_ROOT/edited-docker.log"
: > "$DOCKER_LOG"
make_install "$EDITED_INSTALL" 'ghcr.io/example/metrics-ingest:main'
sed -i 's/^COMPOSE_FILE=.*/&:docker-compose.local.yml/' "$EDITED_INSTALL/.env"
edited_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  bash "$EDITED_INSTALL/update.sh" --check 2>&1)"
grep -q "WARNING: COMPOSE_FILE was changed locally below" <<< "$edited_output"
grep -q 'removes the containers of their services' <<< "$edited_output"
refute grep -q 'changed locally' <<< "$normal_output"

# With a pinned image the update stops before containers change, so a running
# Analytics API is not restarted and the operator is told access was not revoked.
PINNED_RUNNING_INSTALL="$TEST_ROOT/pinned-running-install"
DOCKER_LOG="$TEST_ROOT/pinned-running-docker.log"
: > "$DOCKER_LOG"
make_install "$PINNED_RUNNING_INSTALL" 'ghcr.io/example/metrics-ingest:sha-deadbeef' "$(analytics_settings false)"
set +e
pinned_running_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  RUNNING_SERVICES='postgres metrics-ingest analytics-api' bash "$PINNED_RUNNING_INSTALL/update.sh" 2>&1)"
pinned_running_status=$?
set -e
[[ "$pinned_running_status" -eq 2 ]]
grep -q 'no access was revoked' <<< "$pinned_running_output"
grep -q 'docker compose stop analytics-api' <<< "$pinned_running_output"
refute grep -q 'no access was revoked' <<< "$pinned_output"
assert_no_secrets "$pinned_running_output"

# update.sh replaces itself while it runs. It must keep running its own copy,
# so a new update.sh whose bytes at any offset are harmful never executes.
HOSTILE_FIXTURE_DIR="$TEST_ROOT/hostile-fixture"
cp -r -- "$FIXTURE_DIR" "$HOSTILE_FIXTURE_DIR"
{
  printf '#!/usr/bin/env bash\n'
  for _ in {1..3000}; do printf 'echo SELF_OVERWRITE_HAZARD; exit 97\n'; done
} > "$HOSTILE_FIXTURE_DIR/update.sh"
SELF_INSTALL="$TEST_ROOT/self-install"
DOCKER_LOG="$TEST_ROOT/self-docker.log"
: > "$DOCKER_LOG"
make_install "$SELF_INSTALL" 'ghcr.io/example/metrics-ingest:main'
self_output="$(PATH="$MOCK_BIN:$PATH" AVSM_REPOSITORY_URL='https://example.invalid/repository' \
  FIXTURE_DIR="$HOSTILE_FIXTURE_DIR" bash "$SELF_INSTALL/update.sh" 2>&1)"
refute grep -q SELF_OVERWRITE_HAZARD <<< "$self_output"
grep -q 'Update complete' <<< "$self_output"
cmp -- "$HOSTILE_FIXTURE_DIR/update.sh" "$SELF_INSTALL/update.sh"
grep -q 'lifecycle_metric=Update stopped: completed' "$DOCKER_LOG"

# Earlier releases copied update.sh over itself in place, so bash resumed reading
# the NEW file at the byte offset where the old loop ended (raw GitHub serves LF).
# Each known offset must land in the leading '#' block and reach the guard,
# which stops the old updater without running anything else.
NEW_UPDATER_LF="$TEST_ROOT/update.lf.sh"
mkdir -p "$TEST_ROOT/empty"
tr -d '\r' < "$SOURCE_DIR/update.sh" > "$NEW_UPDATER_LF"
for resume_offset in 11574 13969 15538 17193 $(seq 1000 997 19000); do
  if resumed_output="$(cd "$TEST_ROOT/empty" && PATH="$MOCK_BIN:$PATH" bash -c '
      set -Eeuo pipefail
      readonly -a MANAGED_FILES=(docker-compose.yml update.sh)
      STAGE_DIR=/nonexistent
      eval "$(tail -c +"$2" "$1")"
      echo RESUMED_PAST_GUARD' resume "$NEW_UPDATER_LF" "$((resume_offset + 1))" 2>&1)"; then
    printf 'Resumed old updater was not stopped at offset %s\n%s\n' "$resume_offset" "$resumed_output" >&2
    exit 1
  fi
  grep -q 'the previous update.sh replaced itself while it was running' <<< "$resumed_output" || {
    printf 'Unexpected output when resuming at offset %s:\n%s\n' "$resume_offset" "$resumed_output" >&2
    exit 1
  }
  refute grep -q RESUMED_PAST_GUARD <<< "$resumed_output"
done
# Run from the start, the guard does nothing.
PATH="$MOCK_BIN:$PATH" bash "$SOURCE_DIR/update.sh" --help | grep -q 'Usage: ./update.sh'

printf 'update.sh tests passed\n'
