# AV-System-Metrics: Self-Hosted

Self-Hosted Docker Compose system using Go and PostgreSQL for AV system metric ingestion.

- Client: Any control system that can send REST web requests
- Server: Any server or VM running Docker Engine with Docker Compose

## Requirements

- A server running Docker Engine with Docker Compose and a SSH console session to said server. This server can be a virtual machine.
- `curl` or another way to download the stack files to the server.
- Module added to your control processor codebase. See the [Clients](/Clients/) folder for current supported systems, or please consider writing one with the [Developer Guide](/Clients/Developer%20Guide/README.md) and sending a PR to add it here if your system is not listed.

## Architecture

AI generated image, may contain mistakes:
![overview_diagram](/Self_Hosted/images/self-hosted_workflow.png)

Docker Compose Stack stands up:

- `metrics-ingest` - the Go HTTP ingest service, published at `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest`
- `postgres` - PostgreSQL Alpine from DockerHub
- `postgres_data` - named Docker volume for database persistence

PostgreSQL is only available inside the Compose network by default. Set `EXPOSE_DATABASE=true` in `.env` when you need to publish it for pgAdmin or similar database tools.

### Endpoints

- `POST /metrics` - authenticated metric ingest endpoint
- `GET /health` - unauthenticated database health check

## Configure

The server needs the following files from this repo:

- `docker-compose.yml` - defines the app and PostgreSQL services
- `docker-compose.database-expose-false.yml` and `docker-compose.database-expose-true.yml`
- `update.sh` - safely updates the stack and merges new configuration settings
- `maintenance.sh` - reclaims disk space during a manually started maintenance window
- `lifecycle-events.sh` - required support file for updates and maintenance
- `.env.example` - the configuration template used when merging updates
- `.env` - local secrets and runtime settings

Commands to create a working directory and download the stack files:

```sh
mkdir -p av-system-metrics
cd av-system-metrics

AVSM_REF=main
BASE_URL="https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted"

curl -fsSL "${BASE_URL}/docker-compose.yml" -o docker-compose.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-false.yml" -o docker-compose.database-expose-false.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-true.yml" -o docker-compose.database-expose-true.yml
curl -fsSL "${BASE_URL}/.env.example" -o .env.example
curl -fsSL "${BASE_URL}/update.sh" -o update.sh
curl -fsSL "${BASE_URL}/maintenance.sh" -o maintenance.sh
curl -fsSL "${BASE_URL}/lifecycle-events.sh" -o lifecycle-events.sh
cp .env.example .env
chmod +x update.sh
chmod +x maintenance.sh
```

Leave all downloaded files together in this directory.

***Edit `.env` with your preferred editor (such as `sudo nano .env`) before starting the stack!***

### Required Configuration Values

- `BEARER_TOKEN` - required. Make it a long random string and keep a note of it for when you setup your clients.
- `POSTGRES_PASSWORD` - required; password for the Compose-managed PostgreSQL user. Keep this URL-Safe; Avoid characters such as `@`, `/`, `:`, `?`, `#`, `&`, and spaces

The stack refuses to start if `BEARER_TOKEN` is still `change-me-long-random-token` or `POSTGRES_PASSWORD` is still `change_me_url_safe_database_password` from `.env.example`.

### Optional Configuration Values

- `EXPOSE_DATABASE` - optional; set to `true` to publish PostgreSQL for pgAdmin or similar tools. Defaults to `false`.
- `DATABASE_HOST` - optional; host address Docker binds for PostgreSQL when `EXPOSE_DATABASE=true`. Defaults to `127.0.0.1`.
- `DATABASE_PORT` - optional; host port Docker publishes for PostgreSQL when `EXPOSE_DATABASE=true`. Defaults to `5432`.
- `APP_HOST` - optional; host address Docker binds for the app. Defaults to `127.0.0.1` which is for testing and reverse proxy usage. If you need to expose the service, use `0.0.0.0` but only on a trusted network.
- `APP_PORT` - optional; host port Docker publishes for the app. Defaults to `8080`.
- `ALLOWED_NET` - optional CIDR allow-list, for example `203.0.113.0/24`.
- `METRICS_INGEST_IMAGE` - optional; app image to run. Defaults to `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest:main`. For stricter change control, pin this to a `sha-<commit>` tag or image digest.
- `METRICS_INGEST_PULL_POLICY` - optional; Docker Compose pull behavior for the app image. Defaults to `always`.
- `METRICS_INGEST_CPUS`, `METRICS_INGEST_MEMORY_LIMIT`, `METRICS_INGEST_PIDS_LIMIT` - optional runtime ceilings for the app container.
- `POSTGRES_CPUS`, `POSTGRES_MEMORY_LIMIT`, `POSTGRES_PIDS_LIMIT` - optional runtime ceilings for the PostgreSQL container.

Keep `COMPOSE_PATH_SEPARATOR` and `COMPOSE_FILE` in `.env`. Docker Compose reads `docker-compose.yml` first, then selects either `docker-compose.database-expose-false.yml` or `docker-compose.database-expose-true.yml` from the `EXPOSE_DATABASE` flag. The `false` file intentionally changes nothing. The `true` file adds the PostgreSQL host port mapping.

Heartbeat records are automatically deleted 30 days after receipt. Change `HEARTBEAT_RETENTION_DAYS` to adjust retention, or set `PURGE_HEARTBEAT=false` to keep them indefinitely. Cleanup runs at startup and daily; other metrics are retained. To reclaim disk space after a large cleanup, see [Maintenance](#maintenance).

## Start

Pull and start the full stack from the directory containing `docker-compose.yml`:

```bash
docker compose pull
docker compose up -d
```

Once started, the services will remain running until `docker compose down` or a system shutdown. The services will restart if the host restarts.

## Updating the System

Fetch the current updater from GitHub before each update. Run this from the server directory that contains the existing Compose files and `.env`:

```sh
AVSM_REF=main
curl -fsSL "https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted/update.sh" -o update.latest.sh
bash update.latest.sh --ref "$AVSM_REF" && rm -f update.latest.sh
```

This also works for installations created before `update.sh` was included. The updater saves the previous `update.sh` with the other configuration files, then installs the current copy. If the update fails, remove `update.latest.sh` after investigating the error.

Do not download `.env.example` over `.env`. On this first update, the script will note that it has no previous template and conservatively preserve every existing value. It installs `.env.example` as the baseline for three-way merges on later updates.

The updater:

- Downloads the latest Compose files, `.env.example`, updater, and maintenance command from the selected repository ref.
- Performs a three-way `.env` merge using the previous template. Local values and secrets are preserved, unchanged defaults adopt new template defaults, new settings are added, and conflicting or retired settings are reported by name without printing their values.
- Validates the merged Compose configuration before changing live files.
- Refuses automatic PostgreSQL major-version changes.
- Asks whether to back up the PostgreSQL database (the default is yes), then whether to store the backup on the server or on a workstation. The previous configuration is always backed up.
- For a server backup, shows the proposed directory (`.avsm-backups/` in the stack directory). Press Enter to accept it or type another absolute directory, such as a mounted backup volume; the updater creates a timestamped folder inside it.
- The workstation choice copies the previous configuration and PostgreSQL dump with SCP before applying the update.
- Pulls the configured images and recreates the services with `docker compose up -d`. The `postgres_data` named volume remains in place; the updater never runs `docker compose down -v`.

Preview and validate an update without changing files, backing up the database, or restarting containers:

```sh
bash update.sh --check
```

The default source for the managed stack files is the `main` branch. Use `--ref` to select another branch, tag, or commit; the container image remains controlled separately by `METRICS_INGEST_IMAGE` in `.env`:

```sh
bash update.sh --ref <branch-tag-or-commit>
```

### Backing up to a Linux Workstation

For a workstation backup, the workstation must run an SSH server reachable from the AV server (Windows workstations usually do not; see [Backing Up to a Windows Workstation](#backing-up-to-a-windows-workstation)). Create the destination directory on the workstation first, and make sure the SSH account can write to it. At the prompt, enter a destination such as `backupuser@workstation.example:/home/backupuser/avsm-backups`. For a Windows workstation running OpenSSH Server, use a drive path such as `backupuser@workstation.example:/C:/avsm-backups`; domain accounts such as `jdoe@campus.edu@workstation.example:/C:/avsm-backups` are accepted. Paths may not contain spaces or `..`. To use a non-default SSH port or key, define a `Host` alias in the server's `~/.ssh/config` and use that alias as the host. The updater temporarily builds the backup under `.avsm-backups/` on the server, copies it to the workstation, and removes the server copy after SCP succeeds. If SCP fails, the update stops and leaves the server copy available for recovery.

For an unattended update, select the destination with options:

```sh
bash update.sh --backup-location workstation --workstation-destination backupuser@workstation.example:/home/backupuser/avsm-backups
```

Use `--backup-location server` for an unattended server backup, and add `--backup-dir /absolute/path` to store it outside the stack directory (`--backup-dir` alone implies a server backup). When no terminal is available and no location is selected, the updater uses `.avsm-backups/` on the server. `--check` skips the backup prompts.

If `METRICS_INGEST_IMAGE` is pinned to a `sha-<commit>` tag or image digest, the updater installs and validates the new stack files but stops before pulling or restarting containers. Review `.env`, select the intended image, and run the updater again.

By default, an update stops without changing the stack when the running PostgreSQL service cannot be backed up. Answering `n` to the database backup prompt, or passing `--skip-database-backup`, overrides that protection and should only be used when you already have a verified backup or explicitly accept the risk.

### Backing Up to a Windows Workstation

Windows workstations don't run an SSH server by default, so option 2 won't work. Use option 1 and pull the backup instead:

1. Run the update and choose `1`. Note the backup path it prints:

   ```text
   Update complete. Configuration and database backup: /home/avadmin/av-system-metrics/.avsm-backups/20261027T180000Z
   ```

2. On the workstation, in PowerShell:

   ```powershell
   scp -r avadmin@avserver.example:/home/avadmin/av-system-metrics/.avsm-backups/20261027T180000Z C:\avsm-backups\
   ```

   Use the same account that ran the update.

3. Verify the hashes match:

   ```sh
   sha256sum .avsm-backups/20261027T180000Z/metrics.dump    # server
   ```

   ```powershell
   Get-FileHash C:\avsm-backups\20261027T180000Z\metrics.dump    # workstation
   ```

4. On the server, from the stack directory, remove the server copy:

   ```sh
   rm -rf -- .avsm-backups/20261027T180000Z
   ```

The backup includes `.env`, so store it securely.

## Maintenance

Run maintenance to reclaim disk space after deleting a large number of heartbeats, such as after shortening retention. Routine cleanup frees space for future metrics; maintenance compacts the database to return unused space to the filesystem. It is started manually, so choose a quiet period.

From the server's stack directory, check readiness and preview disk usage without downtime:

```sh
bash maintenance.sh --check
```

Heartbeat purging must be enabled and have completed successfully recently. Resolve any problems reported by the check, then run:

```sh
bash maintenance.sh
```

The command pauses ingestion, compacts stored metrics, reports space reclaimed, and restores ingestion if it was running. **Metrics generated during this window depend on client buffering and may be lost.** Database queries are also interrupted. Compaction requires spare disk space and has a default time limit of two hours; use `bash maintenance.sh --help` for options.

Keep all downloaded stack files together. Maintenance requires Bash, Docker Compose v2, and `flock` (usually included with Linux). Run it separately from updates and follow any recovery instructions if it fails. Maintenance and updates record their start, stop, and outcome as trace events under `AVSM-System` in the metric history.

## Testing your setup

### Healthcheck

```text
curl -i http://<host address>:<port from env file>/health
```

### Send a test metric from a workstation

Use the same token you put in `.env`:

```sh
curl -i -X POST http://127.0.0.1:8080/metrics \
  -H 'Authorization: Bearer <change-me-long-random-token>' \
  -H 'Content-Type: application/json' \
  -d '{"clientname":"workstation","metric":"trace","action":"testing","timestamp":"2026-06-16T21:00:00Z"}'
```

Successful requests return HTTP `201`:

```json
{"ok":true,"count":1}
```

## Inspecting the Database

You can `psql` inside the PostgreSQL container:

```sh
docker compose exec postgres psql -U metrics_user -d metrics
```

To exit `psql` at any time and go back to the server shell: `exit;`

Count stored events in psql:

```sql
SELECT count(*) FROM metric_events;
```

Show recent events in psql:

```sql
SELECT clientname, event_timestamp, metric, action FROM metric_events ORDER BY event_timestamp DESC LIMIT 10;
```

Show recent events in PST time zone

```sql
SELECT 
    clientname, 
    event_timestamp AT TIME ZONE 'America/Los_Angeles' AS local_timestamp, 
    metric, 
    action 
FROM metric_events 
ORDER BY event_timestamp DESC 
LIMIT 10;
```

To inspect the database from pgAdmin, DBeaver, Power BI, or another external tool, set these values in `.env` and restart the stack:

```sh
EXPOSE_DATABASE=true
DATABASE_HOST=127.0.0.1 # or 0.0.0.0
DATABASE_PORT=5432
```

## View logs

```sh
docker compose logs -f
```

View only app logs:

```sh
docker compose logs -f metrics-ingest
```

View only database logs:

```sh
docker compose logs -f postgres
```

## Stop

Stop containers but keep PostgreSQL data:

```sh
docker compose down
```

Stop containers and delete PostgreSQL data:

```sh
docker compose down -v
```

Use `docker compose down -v` only when you intentionally want to delete stored metric data. The app will recreate the schema on next startup.

## Accepted payload shapes

Single message:

```json
{"clientname":"workstation","metric":"trace","action":"testing","timestamp":"2026-06-16T21:00:00Z"}
```

List of messages:

```json
[
  {"clientname":"workstation","metric":"trace","action":"testing","timestamp":"2026-06-16T21:00:00Z"}
]
```

Wrapped list:

```json
{
  "messages": [
    {"clientname":"workstation","metric":"trace","action":"testing","timestamp":"2026-06-16T21:00:00Z"}
  ]
}
```

## Security

Note that this system uses unencrypted HTTP for transmission, due to limitations of your typical AV control processor. Anyone listening on the wire can see the full payload, including the bearer token, so you should only deploy this system **on a trusted network or behind a reverse proxy or VPN bridge**

Other than the data in transit being plain text, this system follows best zero-trust least-privilege practices. The containers are minimal and hardened, the service accounts are non-root, and container network itself is restricted to admins with access to the host server.

The Compose stack applies the repository-controlled parts of CIS Docker Benchmark-style hardening: explicit non-root users, dropped Linux capabilities, `no-new-privileges`, read-only root filesystems, bounded writable `tmpfs` paths, health checks, PID/memory/CPU limits, bounded JSON logs, and an internal-only database network. Note: Full CIS compliance also depends on the Docker host configurations that are not part of this project.

### Firewall Rules

It is best practice to lock down your firewall rules to only the below, and route across a L3 firewall for extra security.

- Trusted admin workstation to server SSH for administration
- Control Processors to whatever port you selected in your .env
- Trusted admin workstation to the database port only when `EXPOSE_DATABASE=true`

## Limits

- Maximum request body size: 10 KB
- Maximum messages per request: 25
- Maximum length for `clientname`, `metric`, and `action`: 128 characters each
- Required message fields: `clientname`, `metric`, `action`, `timestamp`
- `timestamp` must be an ISO-8601-like string accepted by the service; it is stored as a UTC `TIMESTAMPTZ` value
