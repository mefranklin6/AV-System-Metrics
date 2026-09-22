#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  if [[ -n "$TEST_ROOT" && "$TEST_ROOT" == /tmp/* ]]; then
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
  update.sh; do
  cp -- "$SOURCE_DIR/$fixture_file" "$FIXTURE_DIR/$fixture_file"
done

cat > "$TEST_ROOT/base.env.example" <<'EOF'
A=old-default
B=old-default
CONFLICT=old-default
RETIRED=old-default
EXPOSE_DATABASE=false
LEGACY_METRICS_INGEST_IMAGE=ghcr.io/example/metrics-ingest:main
EOF

cat > "$FIXTURE_DIR/.env.example" <<'EOF'
A=new-default
B=old-default
CONFLICT=new-default
NEW_SETTING=new-value
EXPOSE_DATABASE=false
LEGACY_METRICS_INGEST_IMAGE=ghcr.io/example/metrics-ingest:main
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
    ;;
  *" compose up -d "*)
    printf '%s\n' up >> "$DOCKER_LOG"
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

chmod +x "$MOCK_BIN/curl" "$MOCK_BIN/docker"
export FIXTURE_DIR DOCKER_LOG

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
LEGACY_METRICS_INGEST_IMAGE=$image_value
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
[[ ! -s "$DOCKER_LOG" ]]

printf 'update.sh tests passed\n'


