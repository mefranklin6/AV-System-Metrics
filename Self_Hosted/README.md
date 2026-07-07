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
curl -fsSL "${BASE_URL}/.env.example" -o .env
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

## Start

Pull and start the full stack from the directory containing `docker-compose.yml`:

```bash
docker compose pull
docker compose up -d
```

Once started, the services will remain running until `docker compose down` or a system shutdown. The services will restart if the host restarts.

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
