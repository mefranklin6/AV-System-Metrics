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

FIXTURE_DIR="$TEST_ROOT/fixture"
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$FIXTURE_DIR" "$MOCK_BIN"

for fixture_file in \
  docker-compose.yml \
  docker-compose.database-expose-false.yml \
  docker-compose.database-expose-true.yml \
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
EOF

cat > "$FIXTURE_DIR/.env.example" <<'EOF'
A=new-default
B=old-default
CONFLICT=new-default
NEW_SETTING=new-value
EXPOSE_DATABASE=false
METRICS_INGEST_IMAGE=ghcr.io/example/metrics-ingest:main
EOF

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
  *" compose version "*) ;;
  *" config --images "*)
    printf '%s\n' 'ghcr.io/example/metrics-ingest:main' 'postgres:18-alpine'
    ;;
  *" config --quiet "*) ;;
  *" ps --services --status running "*)
    printf '%s\n' postgres
    ;;
  *" exec -T postgres pg_dump "*)
    printf '%s\n' fake-database-dump
    ;;
  *" compose pull "*)
    printf '%s\n' pull >> "$DOCKER_LOG"
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
EOF
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
grep -q 'New settings added with their template defaults (1)' <<< "$normal_output"
grep -q 'Unmodified settings updated to new template defaults (1)' <<< "$normal_output"
grep -q 'Conflicts; local values were kept (1)' <<< "$normal_output"
grep -q 'Settings retained for review because they left the template (1)' <<< "$normal_output"
grep -q '^pull$' "$DOCKER_LOG"
grep -q '^up$' "$DOCKER_LOG"
cmp -- "$SOURCE_DIR/maintenance.sh" "$NORMAL_INSTALL/maintenance.sh"
cmp -- "$SOURCE_DIR/lifecycle-events.sh" "$NORMAL_INSTALL/lifecycle-events.sh"
grep -q 'lifecycle_metric=Update started' "$DOCKER_LOG"
grep -q 'lifecycle_metric=Update stopped: completed' "$DOCKER_LOG"
grep -q 'up -d --wait --wait-timeout 120' "$DOCKER_LOG"
marker_start_line="$(grep -n 'lifecycle_metric=Update started' "$DOCKER_LOG" | cut -d: -f1)"
marker_stop_line="$(grep -n 'lifecycle_metric=Update stopped:' "$DOCKER_LOG" | cut -d: -f1)"
pull_line="$(grep -n '^pull$' "$DOCKER_LOG" | cut -d: -f1)"
up_line="$(grep -n '^up$' "$DOCKER_LOG" | cut -d: -f1)"
((marker_start_line < pull_line && up_line < marker_stop_line))
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
! grep -qE '^(pull|up)$' "$DOCKER_LOG"
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
      grep -q 'lifecycle_metric=Update stopped: failed (exit 1)' "$DOCKER_LOG"
      ! grep -q '^up$' "$DOCKER_LOG"
      ;;
    stop-marker-failure)
      [[ "$scenario_status" -eq 1 ]]
      [[ "$scenario_output" == *'could not record the update stop marker'* ]]
      ;;
  esac
done

printf 'update.sh tests passed\n'
