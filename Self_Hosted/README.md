# AV-System-Metrics: Self-Hosted

Self-Hosted Docker Compose system using Go and PostgreSQL for AV system metric ingestion.

- Client: Any control system that can send REST web requests
- Server: Any server or VM running Docker Engine with Docker Compose

## Requirements

- A server running Docker Engine with Docker Compose and a SSH console session to said server. This server can be a virtual machine.
- `curl` or another way to download the stack files to the server.
- Module added to your control processor codebase. See the "Clients" folder for current supported systems, or please consider writing one and sending a PR to add it here if your system is not listed.

## Architecture

AI generated image, may contain mistakes:
![overview_diagram](/Self_Hosted/images/self-hosted_workflow.png)

Docker Compose Stack stands up:

- `metrics-ingest` - the Go HTTP ingest service, published at `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest`
- `postgres` - PostgreSQL using the Alpine image
- `postgres_data` - named Docker volume for database persistence

The app container applies and migrates the database schema at startup, so the server does not need a local `schema.sql` file.

PostgreSQL is only available inside the Compose network by default. Set `EXPOSE_DATABASE=true` in `.env` when you need to publish it for pgAdmin or similar database tools.

### Endpoints

- `POST /metrics` - authenticated metric ingest endpoint
- `GET /health` - unauthenticated database health check

## Configure

You do not need to clone this repository on the server. The app container is prebuilt and published to GHCR, so the server only needs:

- `docker-compose.yml` - defines the app and PostgreSQL services
- `docker-compose.database-expose-false.yml` and `docker-compose.database-expose-true.yml` - Compose overrides controlled by `EXPOSE_DATABASE`
- `.env` - local secrets and runtime settings

Create a working directory and download the stack files:

```sh
mkdir -p av-system-metrics-self-hosted
cd av-system-metrics-self-hosted

AVSM_REF=main
BASE_URL="https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted"

curl -fsSL "${BASE_URL}/docker-compose.yml" -o docker-compose.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-false.yml" -o docker-compose.database-expose-false.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-true.yml" -o docker-compose.database-expose-true.yml
curl -fsSL "${BASE_URL}/.env.example" -o .env
```

Leave all downloaded files together in this directory. Edit `.env` with your preferred editor before starting the stack:

Configuration values:

- `BEARER_TOKEN` - required. Make it a long random string and keep a note of it for when you setup your clients.
- `POSTGRES_PASSWORD` - required; password for the Compose-managed PostgreSQL user. Keep this URL-Safe; Avoid characters such as `@`, `/`, `:`, `?`, `#`, `&`, and spaces
- `EXPOSE_DATABASE` - optional; set to `true` to publish PostgreSQL for pgAdmin or similar tools. Defaults to `false`.
- `DATABASE_HOST` - optional; host address Docker binds for PostgreSQL when `EXPOSE_DATABASE=true`. Defaults to `127.0.0.1`.
- `DATABASE_PORT` - optional; host port Docker publishes for PostgreSQL when `EXPOSE_DATABASE=true`. Defaults to `5432`.
- `APP_HOST` - optional; host address Docker binds for the app. Defaults to `127.0.0.1` which is for testing and reverse proxy usage. If you need to expose the service, use `0.0.0.0` but only on a trusted network.
- `APP_PORT` - optional; host port Docker publishes for the app. Defaults to `8080`.
- `ALLOWED_NET` - optional CIDR allow-list, for example `203.0.113.0/24`.
- `METRICS_INGEST_IMAGE` - optional; app image to run. Defaults to `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest:latest`.
- `METRICS_INGEST_PULL_POLICY` - optional; Docker Compose pull behavior for the app image. Defaults to `always`.

Keep `COMPOSE_PATH_SEPARATOR` and `COMPOSE_FILE` in `.env`. Docker Compose reads `docker-compose.yml` first, then selects either `docker-compose.database-expose-false.yml` or `docker-compose.database-expose-true.yml` from the `EXPOSE_DATABASE` flag. The `false` file intentionally changes nothing. The `true` file adds the PostgreSQL host port mapping.

## Start

Pull and start the full stack from the directory containing `docker-compose.yml`:

```sh
docker compose pull
docker compose up -d
```

The stack uses the public GHCR app image and the upstream PostgreSQL image. You do not need Go installed on the server.

On startup, `metrics-ingest` connects to PostgreSQL and creates or migrates the required database table and indexes.

To update the running app and database images later:

```sh
docker compose pull
docker compose up -d
```

To refresh the Compose files from the repository, rerun the download commands from the Configure section. Existing PostgreSQL data stays in the Docker volume unless you intentionally run `docker compose down -v`.

To pin a specific app image version, set `METRICS_INGEST_IMAGE` in `.env` to a branch tag or SHA tag published by CI:

```sh
METRICS_INGEST_IMAGE=ghcr.io/mefranklin6/av-system-metrics/metrics-ingest:sha-<commit>
```

## Local build

Cloning the repository is only needed when you are developing the service or building the image yourself. From the `Self_Hosted` source directory:

```sh
docker build -t metrics-ingest:local .
METRICS_INGEST_IMAGE=metrics-ingest:local METRICS_INGEST_PULL_POLICY=never docker compose up -d
```

## Image publishing

The `.github/workflows/self-hosted-ghcr.yml` workflow builds and publishes the `metrics-ingest` image to GHCR when a push changes `Self_Hosted/**` or the workflow file itself. It publishes:

- `latest` for the repository default branch
- a sanitized branch tag for branch pushes
- `sha-<commit>` for every scoped push

GHCR package visibility is managed in GitHub Packages. After the first publish, confirm the package visibility is set to Public so unauthenticated servers can pull it.

## Test request

Use the same token you put in `.env`:

```sh
curl -i -X POST http://127.0.0.1:8080/metrics \
  -H 'Authorization: Bearer change-me-long-random-token' \
  -H 'Content-Type: application/json' \
  -d '{"clientname":"workstation","metric":"trace","action":"testing","timestamp":"2026-06-16T21:00:00Z"}'
```

Successful requests return HTTP `201`:

```json
{"ok":true,"count":1}
```

Clients send `timestamp` as an ISO 8601 JSON string. The service parses that value, normalizes it to UTC, and stores it in PostgreSQL as `TIMESTAMPTZ` in the `event_timestamp` column. Payloads with timezone offsets are converted to the same instant in UTC; timezone-less accepted values are treated as UTC for compatibility.

Check database health through the service:

```sh
curl -i http://127.0.0.1:8080/health
```

## Schema Troubleshooting

Older setup instructions mounted `schema.sql` into the PostgreSQL container. On Linux servers with restrictive file permissions, PostgreSQL could fail with:

```text
psql: error: /docker-entrypoint-initdb.d/001_schema.sql: Permission denied
```

Current installs no longer use that mount. Refresh the Compose files, pull the current app image, and restart:

```sh
AVSM_REF=main
BASE_URL="https://raw.githubusercontent.com/mefranklin6/AV-System-Metrics/${AVSM_REF}/Self_Hosted"
curl -fsSL "${BASE_URL}/docker-compose.yml" -o docker-compose.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-false.yml" -o docker-compose.database-expose-false.yml
curl -fsSL "${BASE_URL}/docker-compose.database-expose-true.yml" -o docker-compose.database-expose-true.yml

docker compose pull
docker compose up -d
```

If you already have a running PostgreSQL container from the older setup and want to apply your local `schema.sql` migration without deleting data:

```sh
cat schema.sql | docker compose exec -T postgres psql -U metrics_user -d metrics -v ON_ERROR_STOP=1
docker compose restart metrics-ingest
docker compose exec postgres psql -U metrics_user -d metrics -c '\dt'
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
SELECT clientname, metric, action, event_timestamp, received_at FROM metric_events ORDER BY event_timestamp DESC LIMIT 10;
```

`event_timestamp` and `received_at` are stored as PostgreSQL `TIMESTAMPTZ` columns. To display them explicitly in UTC from any SQL client:

```sql
SELECT
  clientname,
  metric,
  action,
  event_timestamp AT TIME ZONE 'UTC' AS event_timestamp_utc,
  received_at AT TIME ZONE 'UTC' AS received_at_utc
FROM metric_events
ORDER BY event_timestamp DESC
LIMIT 10;
```

To inspect the database from pgAdmin, DBeaver, Power BI, or another external tool, set these values in `.env` and restart the stack:

```sh
EXPOSE_DATABASE=true
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
```

Then connect with:

- Host: `127.0.0.1` or the server address when `DATABASE_HOST=0.0.0.0`
- Port: the value of `DATABASE_PORT`
- Database: `metrics`
- Username: `metrics_user`
- Password: the value of `POSTGRES_PASSWORD`

Use `DATABASE_HOST=127.0.0.1` for local tools or SSH tunnels. Use `DATABASE_HOST=0.0.0.0` only on a trusted admin network or behind firewall rules that limit who can reach the database port.

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
