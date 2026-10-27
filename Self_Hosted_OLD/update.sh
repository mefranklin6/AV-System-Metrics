#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_URL="${AVSM_REPOSITORY_URL:-https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics}"
AVSM_REF="${AVSM_REF:-main}"
CHECK_ONLY=false
SKIP_DATABASE_BACKUP=false
BACKUP_LOCATION=""
WORKSTATION_DESTINATION=""
BACKUP_ROOT=""
STAGE_DIR=""
UPDATE_STARTED=false
UPDATE_MARKER_PENDING=false
UPDATE_START_TIME=""
UPDATE_OUTCOME=""

usage() {
  cat <<'EOF'
Usage: ./update.sh [options]

Download and apply the latest AV-System-Metrics self-hosted stack.

Options:
  --ref REF                 Update from a branch, tag, or commit (default: main)
  --check                   Download, merge, and validate without changing anything
  --skip-database-backup    Update without a PostgreSQL backup (prompts on a terminal)
  --backup-location PLACE   Backup on server or workstation (prompts on a terminal)
  --backup-dir PATH         Absolute server directory for backups
                            (default: <stack directory>/.avsm-backups)
  --workstation-destination USER@HOST:/absolute/path
                            SCP destination directory on the workstation
                            (Windows: USER@HOST:/C:/path)
  -h, --help                Show this help

Environment overrides:
  AVSM_REF                  Same as --ref
  AVSM_REPOSITORY_URL       Raw repository base URL (primarily for testing)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

cleanup() {
  local status=$?
  local outcome
  trap - EXIT INT TERM HUP
  if [[ "$UPDATE_STARTED" == true ]]; then
    outcome="${UPDATE_OUTCOME:-$(lifecycle_outcome "$status")}"
    if [[ "$UPDATE_MARKER_PENDING" == true ]]; then
      if ! record_lifecycle_event 'Update started' "$UPDATE_START_TIME"; then
        warn "could not record the update start marker in the database"
        status=1
      fi
    fi
    if ! record_lifecycle_event "Update stopped: $outcome"; then
      warn "could not record the update stop marker in the database"
      status=1
    fi
  fi
  if [[ -n "$STAGE_DIR" && "$STAGE_DIR" == "$SCRIPT_DIR"/.avsm-update.tmp.* ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while (($#)); do
  case "$1" in
    --ref)
      (($# >= 2)) || die "--ref requires a value"
      AVSM_REF="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --skip-database-backup)
      SKIP_DATABASE_BACKUP=true
      shift
      ;;
    --backup-location)
      (($# >= 2)) || die "--backup-location requires a value"
      BACKUP_LOCATION="$2"
      shift 2
      ;;
    --backup-dir)
      (($# >= 2)) || die "--backup-dir requires a value"
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --workstation-destination)
      (($# >= 2)) || die "--workstation-destination requires a value"
      WORKSTATION_DESTINATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$AVSM_REF" =~ ^[A-Za-z0-9._/-]+$ && "$AVSM_REF" != *..* ]] || die "invalid update ref: $AVSM_REF"
[[ -f "$SCRIPT_DIR/.env" ]] || die ".env was not found in $SCRIPT_DIR"
cd "$SCRIPT_DIR"

for command_name in curl docker awk mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

STAGE_DIR="$(mktemp -d "$SCRIPT_DIR/.avsm-update.tmp.XXXXXX")"
EMPTY_TEMPLATE="$STAGE_DIR/empty.env.example"
MERGED_ENV="$STAGE_DIR/.env"
MERGE_REPORT="$STAGE_DIR/env-merge-report.txt"
: > "$EMPTY_TEMPLATE"
: > "$MERGE_REPORT"

readonly -a MANAGED_FILES=(
  docker-compose.yml
  docker-compose.database-expose-false.yml
  docker-compose.database-expose-true.yml
  .env.example
  update.sh
  lifecycle-events.sh
)

printf 'Downloading self-hosted files from %s at ref %s...\n' "$REPOSITORY_URL" "$AVSM_REF"
for managed_file in "${MANAGED_FILES[@]}"; do
  download_url="${REPOSITORY_URL}/${AVSM_REF}/Self_Hosted_OLD/${managed_file}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    --retry 3 --output "$STAGE_DIR/$managed_file" "$download_url"
  [[ -s "$STAGE_DIR/$managed_file" ]] || die "downloaded file is empty: $managed_file"
done

source "$STAGE_DIR/lifecycle-events.sh"

merge_env() {
  local base_template="$1"
  local local_env="$2"
  local new_template="$3"
  local output_env="$4"
  local report_file="$5"

  awk \
    -v base_file="$base_template" \
    -v local_file="$local_env" \
    -v new_file="$new_template" \
    -v report_file="$report_file" '
    function parse_setting(line,    normalized, equals_at, candidate) {
      normalized = line
      sub(/^[[:space:]]*/, "", normalized)
      sub(/\r$/, "", normalized)
      if (normalized == "" || substr(normalized, 1, 1) == "#") {
        return 0
      }

      equals_at = index(normalized, "=")
      if (equals_at < 2) {
        return -1
      }

      candidate = substr(normalized, 1, equals_at - 1)
      sub(/[[:space:]]*$/, "", candidate)
      if (candidate !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
        return -1
      }

      parsed_key = candidate
      parsed_value = substr(normalized, equals_at + 1)
      return 1
    }

    FILENAME == base_file {
      parsed = parse_setting($0)
      if (parsed == 1) {
        if (parsed_key in base_seen) {
          print "ERROR\tDuplicate setting in previous .env.example: " parsed_key >> report_file
          errors = 1
        }
        base_seen[parsed_key] = 1
        base_value[parsed_key] = parsed_value
      } else if (parsed == -1) {
        print "ERROR\tUnsupported line in previous .env.example at line " FNR >> report_file
        errors = 1
      }
      next
    }

    FILENAME == local_file {
      parsed = parse_setting($0)
      if (parsed == 1) {
        if (parsed_key in local_seen) {
          print "ERROR\tDuplicate setting in .env: " parsed_key >> report_file
          errors = 1
        }
        local_seen[parsed_key] = 1
        local_value[parsed_key] = parsed_value
      } else if (parsed == -1) {
        print "ERROR\tUnsupported line in .env at line " FNR >> report_file
        errors = 1
      }
      next
    }

    FILENAME == new_file {
      parsed = parse_setting($0)
      if (parsed == 0) {
        print $0
        next
      }
      if (parsed == -1) {
        print "ERROR\tUnsupported line in new .env.example at line " FNR >> report_file
        errors = 1
        next
      }
      if (parsed_key in new_seen) {
        print "ERROR\tDuplicate setting in new .env.example: " parsed_key >> report_file
        errors = 1
        next
      }

      key = parsed_key
      upstream_value = parsed_value
      new_seen[key] = 1

      if (!(key in local_seen)) {
        selected_value = upstream_value
        print "NEW\t" key >> report_file
      } else if (!(key in base_seen)) {
        selected_value = local_value[key]
      } else if (upstream_value != base_value[key] && local_value[key] == base_value[key]) {
        selected_value = upstream_value
        print "DEFAULT_UPDATED\t" key >> report_file
      } else if (upstream_value != base_value[key] && local_value[key] != base_value[key] && local_value[key] != upstream_value) {
        selected_value = local_value[key]
        print "CONFLICT\t" key >> report_file
      } else {
        selected_value = local_value[key]
      }

      print key "=" selected_value
      next
    }

    END {
      retired_header_printed = 0
      for (key in local_seen) {
        if (!(key in new_seen)) {
          if (!retired_header_printed) {
            print ""
            print "# Settings retained from the previous .env but no longer present in .env.example."
            print "# Review these settings; a future update may require removing them."
            retired_header_printed = 1
          }
          print key "=" local_value[key]
          print "RETIRED\t" key >> report_file
        }
      }

      if (errors) {
        exit 2
      }
    }
  ' "$base_template" "$local_env" "$new_template" > "$output_env"
}

BASE_TEMPLATE="$SCRIPT_DIR/.env.example"
if [[ ! -f "$BASE_TEMPLATE" ]]; then
  BASE_TEMPLATE="$EMPTY_TEMPLATE"
  warn "no previous .env.example was found; local values will be preserved conservatively"
fi

if ! merge_env "$BASE_TEMPLATE" "$SCRIPT_DIR/.env" "$STAGE_DIR/.env.example" "$MERGED_ENV" "$MERGE_REPORT"; then
  cat "$MERGE_REPORT" >&2
  die ".env could not be merged; no live files were changed"
fi

report_count() {
  local category="$1"
  awk -F '\t' -v category="$category" '$1 == category { count++ } END { print count + 0 }' "$MERGE_REPORT"
}

print_report_category() {
  local category="$1"
  local heading="$2"
  local count
  count="$(report_count "$category")"
  if ((count > 0)); then
    printf '%s (%s):\n' "$heading" "$count"
    awk -F '\t' -v category="$category" '$1 == category { print "  - " $2 }' "$MERGE_REPORT"
  fi
}

print_report_category NEW "New settings added with their template defaults"
print_report_category DEFAULT_UPDATED "Unmodified settings updated to new template defaults"
print_report_category CONFLICT "Conflicts; local values were kept"
print_report_category RETIRED "Settings retained for review because they left the template"

env_value() {
  local env_file="$1"
  local setting_name="$2"
  awk -v setting_name="$setting_name" '
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      equals_at = index(line, "=")
      key = substr(line, 1, equals_at - 1)
      sub(/[[:space:]]*$/, "", key)
      if (key == setting_name) {
        value = substr(line, equals_at + 1)
        sub(/\r$/, "", value)
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
          value = substr(value, 2, length(value) - 2)
        }
        print value
        exit
      }
    }
  ' "$env_file"
}

NEW_EXPOSE_DATABASE="$(env_value "$MERGED_ENV" EXPOSE_DATABASE)"
case "$NEW_EXPOSE_DATABASE" in
  true|false) ;;
  *) die "EXPOSE_DATABASE must be either true or false" ;;
esac

printf 'Validating the downloaded Compose configuration...\n'
docker compose \
  --env-file "$MERGED_ENV" \
  -f "$STAGE_DIR/docker-compose.yml" \
  -f "$STAGE_DIR/docker-compose.database-expose-${NEW_EXPOSE_DATABASE}.yml" \
  config --quiet

postgres_image() {
  local env_file="$1"
  local compose_directory="$2"
  local expose_database
  expose_database="$(env_value "$env_file" EXPOSE_DATABASE)"
  docker compose \
    --env-file "$env_file" \
    -f "$compose_directory/docker-compose.yml" \
    -f "$compose_directory/docker-compose.database-expose-${expose_database}.yml" \
    config --images | awk '/(^|\/)postgres:[0-9]+/ { print; exit }'
}

postgres_major() {
  local image="$1"
  if [[ "$image" =~ (^|/)postgres:([0-9]+)($|[-.]) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  OLD_POSTGRES_IMAGE="$(postgres_image "$SCRIPT_DIR/.env" "$SCRIPT_DIR")"
  NEW_POSTGRES_IMAGE="$(postgres_image "$MERGED_ENV" "$STAGE_DIR")"
  OLD_POSTGRES_MAJOR="$(postgres_major "$OLD_POSTGRES_IMAGE")"
  NEW_POSTGRES_MAJOR="$(postgres_major "$NEW_POSTGRES_IMAGE")"
  if [[ -n "$OLD_POSTGRES_MAJOR" && -n "$NEW_POSTGRES_MAJOR" && "$OLD_POSTGRES_MAJOR" != "$NEW_POSTGRES_MAJOR" ]]; then
    die "automatic PostgreSQL major-version updates are not supported (${OLD_POSTGRES_MAJOR} to ${NEW_POSTGRES_MAJOR}); perform a documented database migration instead"
  fi
fi

if [[ "$CHECK_ONLY" == true ]]; then
  printf 'Check complete. The downloaded files and merged .env are valid; no live files were changed.\n'
  exit 0
fi

if [[ "$SKIP_DATABASE_BACKUP" == false && -t 0 ]]; then
  read -r -p 'Back up the PostgreSQL database before updating? [Y/n]: ' database_choice || die "could not read database backup choice"
  case "$database_choice" in
    ''|[Yy]|[Yy][Ee][Ss]) ;;
    [Nn]|[Nn][Oo]) SKIP_DATABASE_BACKUP=true ;;
    *) die "answer y or n for the database backup" ;;
  esac
fi

if [[ -z "$BACKUP_LOCATION" && -n "$WORKSTATION_DESTINATION" ]]; then
  BACKUP_LOCATION=workstation
elif [[ -z "$BACKUP_LOCATION" && -n "$BACKUP_ROOT" ]]; then
  BACKUP_LOCATION=server
fi

if [[ -z "$BACKUP_LOCATION" ]]; then
  if [[ -t 0 ]]; then
    printf 'Where should the pre-update backup be stored?\n  1) On this server\n  2) On your workstation via SCP\n'
    read -r -p 'Choose 1 or 2: ' backup_choice || die "could not read backup choice"
    case "$backup_choice" in
      1) BACKUP_LOCATION=server ;;
      2) BACKUP_LOCATION=workstation ;;
      *) die "choose 1 or 2 for the backup location" ;;
    esac
  else
    BACKUP_LOCATION=server
    printf 'No terminal available; using an on-server backup.\n'
  fi
fi

DEFAULT_BACKUP_ROOT="$SCRIPT_DIR/.avsm-backups"
case "$BACKUP_LOCATION" in
  server)
    [[ -z "$WORKSTATION_DESTINATION" ]] || die "--workstation-destination requires a workstation backup"
    if [[ -z "$BACKUP_ROOT" && -t 0 ]]; then
      printf 'The backup will be saved in a timestamped folder under:\n  %s\n' "$DEFAULT_BACKUP_ROOT"
      read -r -p 'Press Enter to accept, or type another absolute directory: ' BACKUP_ROOT || die "could not read backup directory"
    fi
    BACKUP_ROOT="${BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
    if [[ "$BACKUP_ROOT" == "~" || "$BACKUP_ROOT" == "~/"* ]]; then
      BACKUP_ROOT="$HOME${BACKUP_ROOT:1}"
    fi
    BACKUP_ROOT="${BACKUP_ROOT%/}"
    [[ "$BACKUP_ROOT" == /?* ]] || die "backup directory must be an absolute path other than /"
    ;;
  workstation)
    [[ -z "$BACKUP_ROOT" ]] || die "--backup-dir requires a server backup"
    # The backup is staged on the server, then copied to the workstation.
    BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
    command -v scp >/dev/null 2>&1 || die "scp is required for a workstation backup"
    if [[ -z "$WORKSTATION_DESTINATION" && -t 0 ]]; then
      read -r -p 'Workstation SCP destination (user@host:/absolute/path or user@host:/C:/path): ' WORKSTATION_DESTINATION || die "could not read workstation destination"
    fi
    # The user may contain '@' for domain accounts (scp splits at the last '@').
    # Paths are POSIX absolute (/path) or Windows drive (/C:/path or C:/path).
    # Set ports and keys with a Host alias in ~/.ssh/config.
    destination_pattern='^[A-Za-z0-9._@-]+@[A-Za-z0-9._-]+:(/?[A-Za-z]:)?/[A-Za-z0-9._/-]+$'
    [[ "$WORKSTATION_DESTINATION" =~ $destination_pattern && "$WORKSTATION_DESTINATION" != *..* ]] || die "workstation destination must be user@host:/absolute/path or user@host:/C:/path without spaces or '..'"
    ;;
  *) die "backup location must be server or workstation" ;;
esac

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
mkdir -p -- "$BACKUP_DIR" || die "could not create backup directory $BACKUP_DIR"
if [[ "$BACKUP_ROOT" == "$DEFAULT_BACKUP_ROOT" ]]; then
  chmod 700 "$BACKUP_ROOT"
fi
chmod 700 "$BACKUP_DIR"

for managed_file in "${MANAGED_FILES[@]}" .env; do
  if [[ -f "$SCRIPT_DIR/$managed_file" ]]; then
    cp -p -- "$SCRIPT_DIR/$managed_file" "$BACKUP_DIR/$managed_file"
  fi
done
cp -- "$MERGE_REPORT" "$BACKUP_DIR/env-merge-report.txt"
chmod 600 "$BACKUP_DIR/.env" "$BACKUP_DIR/env-merge-report.txt" 2>/dev/null || true

if [[ "$SKIP_DATABASE_BACKUP" == false ]]; then
  if docker compose ps --services --status running 2>/dev/null | awk '$0 == "postgres" { found = 1 } END { exit !found }'; then
    printf 'Backing up PostgreSQL...\n'
    if docker compose exec -T postgres pg_dump -U metrics_user -d metrics -Fc > "$BACKUP_DIR/metrics.dump.part"; then
      mv -- "$BACKUP_DIR/metrics.dump.part" "$BACKUP_DIR/metrics.dump"
      chmod 600 "$BACKUP_DIR/metrics.dump"
    else
      rm -f -- "$BACKUP_DIR/metrics.dump.part"
      die "database backup failed; the stack was not changed (use --skip-database-backup only if you accept this risk)"
    fi
  else
    die "PostgreSQL is not running, so a backup cannot be made; the stack was not changed (start it or use --skip-database-backup)"
  fi
else
  warn "database backup explicitly skipped"
fi

if [[ "$BACKUP_LOCATION" == workstation ]]; then
  printf 'Copying pre-update backup to %s...\n' "$WORKSTATION_DESTINATION"
  if ! scp -r -- "$BACKUP_DIR" "$WORKSTATION_DESTINATION/"; then
    die "workstation backup transfer failed; the stack was not changed and the server backup remains at $BACKUP_DIR"
  fi
  BACKUP_RESULT="${WORKSTATION_DESTINATION%/}/$TIMESTAMP"
  rm -rf -- "$BACKUP_DIR"
else
  BACKUP_RESULT="$BACKUP_DIR"
fi

UPDATE_START_TIME="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
UPDATE_STARTED=true
if ! record_lifecycle_event 'Update started' "$UPDATE_START_TIME"; then
  # Permit updates that recover a stopped database. Retry after the stack is
  # healthy, preserving the original start time in event_timestamp.
  UPDATE_MARKER_PENDING=true
  warn "update start marker deferred until PostgreSQL is available"
fi

printf 'Installing the validated stack files...\n'
for managed_file in "${MANAGED_FILES[@]}"; do
  cp -- "$STAGE_DIR/$managed_file" "$SCRIPT_DIR/$managed_file"
done
cp -- "$MERGED_ENV" "$SCRIPT_DIR/.env"
chmod 755 "$SCRIPT_DIR/update.sh"
chmod 600 "$SCRIPT_DIR/.env"

METRICS_IMAGE="$(env_value "$SCRIPT_DIR/.env" LEGACY_METRICS_INGEST_IMAGE)"
case "$METRICS_IMAGE" in
  *@sha256:*|*:sha-[0-9a-fA-F]*)
    warn "LEGACY_METRICS_INGEST_IMAGE is pinned to an immutable digest or commit tag"
    warn "stack files and .env were updated, but containers were not pulled or restarted"
    warn "review $SCRIPT_DIR/.env, select the intended image, and run this updater again"
    printf 'Configuration backup: %s\n' "$BACKUP_RESULT"
    UPDATE_OUTCOME='configuration updated; containers unchanged'
    exit 2
    ;;
esac

printf 'Pulling configured container images...\n'
if ! (
  cd "$SCRIPT_DIR" &&
    docker compose pull &&
    docker compose up -d --wait --wait-timeout 120 &&
    docker compose ps
); then
  warn "the container update did not complete"
  warn "previous configuration and the database backup are available at $BACKUP_RESULT"
  exit 1
fi

printf 'Update complete. Configuration and database backup: %s\n' "$BACKUP_RESULT"
