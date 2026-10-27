# AV-System-Metrics: Legacy Self-Hosted Adapter

Deprecated transition stack for control processors that still use the archived
[`REST_Connector.py`](https://github.com/mefranklin6/ExtronDatabaseConnector/blob/main/Control_Processor_Files/REST_Connector.py).

The adapter keeps the old Extron HTTP contract while using the current
AV-System-Metrics architecture:

- Go HTTP server
- PostgreSQL with the same `metric_events` schema as [`Self_Hosted`](../Self_Hosted/README.md)
- Docker Compose deployment and persistent PostgreSQL volume

Use the regular [`Self_Hosted`](../Self_Hosted/README.md) stack for new client
installations. This project exists so older Extron ControlScript (ECS) programs can migrate server-side
before their control-processor code can be updated.

## Legacy compatibility

The archived client posts this object without an authorization header:

```json
{
  "room": "Langdon 100",
  "time": "2026-07-13T09:30:00",
  "metric": "System On",
  "action": "Started"
}
```

For compatibility with both sides of the archived project, the adapter:

- accepts `room` from `REST_Connector.py` or `processor` from the old FastAPI model;
- accepts metric POSTs at `/data` and `/`;
- provides the global-enable check at `/data/global/enable` and `/global/enable`;
- returns `{"message":"200"}` after a successful insert;
- returns the JSON string `"True"` from the global-enable endpoint when PostgreSQL is healthy, otherwise `"False"`.

The recommended legacy client configuration is:

```python
API = REST_Connector(
    "Langdon 100",
    "http://192.0.2.10:8080/data",
)
```

The client appends `/global/enable` to that value, producing the historical
`/data/global/enable` route. A bare server URL also works for deployments that
were configured that way.

## Database mapping

Legacy fields are translated into the current PostgreSQL schema:

| Legacy field | `metric_events` column |
| --- | --- |
| `room` or `processor` | `clientname` |
| `time` | `event_timestamp` |
| `metric` | `metric` |
| `action` | `action` |

The adapter generates `sort_key`, `event_id`, `received_at`, and `source_ip`.
Because the old client sends a local time without a UTC offset, set
`LEGACY_TIMEZONE` to the IANA time zone used by the control processors. The
adapter converts that wall-clock value to UTC for PostgreSQL.

## Requirements

- Docker Engine
- Docker Compose v2
- A server or VM reachable by the legacy control processors

## Configure

Download the Compose files and example environment file:

```sh
mkdir -p av-system-metrics-legacy
cd av-system-metrics-legacy

AVSM_REF=main
BASE_URL="https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted_OLD"

curl -fsSL "${BASE_URL}/docker-compose.yml" -o docker-compose.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-false.yml" -o docker-compose.database-expose-false.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-true.yml" -o docker-compose.database-expose-true.yml
curl -fsSL "${BASE_URL}/.env.example" -o .env
```

Edit `.env` before starting the stack.

Required setting:

- `POSTGRES_PASSWORD`: a URL-safe password for the Compose-managed PostgreSQL user. The stack rejects the example password.

Important optional settings:

- `LEGACY_TIMEZONE`: IANA time zone used for offset-free legacy timestamps, such as `America/Los_Angeles`. Defaults to `UTC` if omitted.
- `APP_HOST`: host interface for the adapter. The safe default is `127.0.0.1`; remote processors normally require `0.0.0.0` or a specific server IP.
- `APP_PORT`: published adapter port. Defaults to `8080`.
- `ALLOWED_NET`: CIDR allow-list for control processors, such as `10.20.30.0/24`. This is strongly recommended because the old client cannot authenticate.
- `EXPOSE_DATABASE`: set to `true` only when PostgreSQL must be published for an administration or reporting tool.

Keep `COMPOSE_PATH_SEPARATOR` and `COMPOSE_FILE` at the bottom of `.env`. They
select the database port override based on `EXPOSE_DATABASE`.

## Start

```sh
docker compose pull
docker compose up -d
```

The application waits for PostgreSQL, creates the current schema when needed,
and then starts accepting legacy requests.

## Verify

Check the Docker health endpoint:

```sh
curl -i http://127.0.0.1:8080/health
```

Check the exact endpoint used by a client configured with a `/data` URL:

```sh
curl -i http://127.0.0.1:8080/data/global/enable
```

A healthy response has HTTP status `200` and a JSON string body:

```json
"True"
```

Send a representative legacy metric:

```sh
curl -i -X POST http://127.0.0.1:8080/data \
  -H 'Content-Type: application/json' \
  -d '{"room":"workstation","time":"2026-07-13T09:30:00","metric":"trace","action":"Started"}'
```

The success response is:

```json
{"message":"200"}
```

## Updating the System

Fetch the current updater from GitHub before each update. Run this from the server directory that contains the existing Compose files and `.env`:

```sh
AVSM_REF=main
curl -fsSL "https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted_OLD/update.sh" -o update.latest.sh
bash update.latest.sh --ref "$AVSM_REF" && rm -f update.latest.sh
```

This also works for installations created before `update.sh` was included. The updater saves the previous `update.sh` with the other configuration files, then installs the current copy. If the update fails, remove `update.latest.sh` after investigating the error.

Do not download `.env.example` over `.env`. On the first update, the script will note that it has no previous template and conservatively preserve every existing value. It installs `.env.example` as the baseline for three-way merges on later updates.

The updater:

- Downloads the latest Compose files, `.env.example`, updater, and lifecycle event helper from the selected repository ref.
- Performs a three-way `.env` merge using the previous template. Local values and secrets are preserved, unchanged defaults adopt new template defaults, new settings are added, and conflicting or retired settings are reported by name without printing their values.
- Validates the merged Compose configuration before changing live files.
- Refuses automatic PostgreSQL major-version changes.
- Asks whether to back up the PostgreSQL database (the default is yes), then whether to store the backup on the server or on a workstation. The previous configuration is always backed up.
- For a server backup, shows the proposed directory (`.avsm-backups/` in the stack directory). Press Enter to accept it or type another absolute directory, such as a mounted backup volume; the updater creates a timestamped folder inside it.
- The workstation choice copies the previous configuration and PostgreSQL dump with SCP before applying the update.
- Records `Update started` and `Update stopped: <outcome>` events in `metric_events` under the client name `AVSM-System`, so gaps in legacy data can be matched to update windows.
- Pulls the configured images, recreates the services with `docker compose up -d`, and waits up to 120 seconds for them to become healthy. The `postgres_data` named volume remains in place; the updater never runs `docker compose down -v`.

Preview and validate an update without changing files, backing up the database, or restarting containers:

```sh
bash update.sh --check
```

The default source for the managed stack files is the `main` branch. Use `--ref` to select another branch, tag, or commit; the container image remains controlled separately by `LEGACY_METRICS_INGEST_IMAGE` in `.env`:

```sh
bash update.sh --ref <branch-tag-or-commit>
```

For a workstation backup, the workstation must run an SSH server reachable from the AV server. Create the destination directory on the workstation first, and make sure the SSH account can write to it. At the prompt, enter a destination such as `backupuser@workstation.example:/home/backupuser/avsm-backups`. For a Windows workstation running OpenSSH Server, use a drive path such as `backupuser@workstation.example:/C:/avsm-backups`; domain accounts such as `jdoe@campus.edu@workstation.example:/C:/avsm-backups` are accepted. Paths may not contain spaces or `..`. To use a non-default SSH port or key, define a `Host` alias in the server's `~/.ssh/config` and use that alias as the host. The updater temporarily builds the backup under `.avsm-backups/` on the server, copies it to the workstation, and removes the server copy after SCP succeeds. If SCP fails, the update stops and leaves the server copy available for recovery. Windows workstations usually do not run an SSH server; see [Backing Up to a Windows Workstation](../Self_Hosted/README.md#backing-up-to-a-windows-workstation) to pull an on-server backup instead.

For an unattended update, select the destination with options:

```sh
bash update.sh --backup-location workstation --workstation-destination backupuser@workstation.example:/home/backupuser/avsm-backups
```

Use `--backup-location server` for an unattended server backup, and add `--backup-dir /absolute/path` to store it outside the stack directory (`--backup-dir` alone implies a server backup). When no terminal is available and no location is selected, the updater uses `.avsm-backups/` on the server. `--check` skips the backup prompts.

If `LEGACY_METRICS_INGEST_IMAGE` is pinned to a `sha-<commit>` tag or image digest, the updater installs and validates the new stack files but stops before pulling or restarting containers. Review `.env`, select the intended image, and run the updater again.

By default, an update stops without changing the stack when the running PostgreSQL service cannot be backed up. Answering `n` to the database backup prompt, or passing `--skip-database-backup`, overrides that protection and should only be used when you already have a verified backup or explicitly accept the risk.

## Inspect PostgreSQL

Open `psql` inside the database container:

```sh
docker compose exec postgres psql -U metrics_user -d metrics
```

Show recent legacy events:

```sql
SELECT clientname, event_timestamp, metric, action
FROM metric_events
ORDER BY event_timestamp DESC
LIMIT 10;
```

## Operations

View logs:

```sh
docker compose logs -f
```

Stop the stack while preserving data:

```sh
docker compose down
```

Delete the stack and its PostgreSQL data only when intentional:

```sh
docker compose down -v
```

## Security and limits

The old connector has no authentication support and uses unencrypted HTTP. Run
this stack only on a trusted, restricted network. Bind only the necessary server
interface, set `ALLOWED_NET`, and enforce equivalent firewall rules at the host
or routed firewall.

- Maximum request body: 10 KB
- Maximum `room`/`processor`, `metric`, and `action` length: 128 characters, matching the PostgreSQL schema
- One metric object per request, matching the archived client
- Required fields: `room` or `processor`, `time`, `metric`, and `action`

The containers retain the hardening used by the current self-hosted stack:
non-root users, dropped Linux capabilities, read-only root filesystems, bounded
temporary filesystems and resources, health checks, bounded logs, and an
internal-only database network by default.
