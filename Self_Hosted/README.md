# AV-System-Metrics: Self-Hosted

Self-Hosted Docker Compose system using Go and PostgreSQL for AV system metric ingestion.

- Client: Any control system that can send REST web requests
- Server: Any server or VM running Docker Engine with Docker Compose

## Requirements

- A server running Docker Engine with Docker Compose and a SSH console session to said server. This server can be a virtual machine.
- Module added to your control processor codebase. See the "Clients" folder for current supported systems, or please consider writing one and sending a PR to add it here if your system is not listed.

## Architecture

AI generated image, may contain mistakes:
![overview_diagram](/Self_Hosted/images/self-hosted_workflow.png)

Docker Compose Stack stands up:

- `metrics-ingest` - the Go HTTP ingest service, published at `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest`
- `postgres` - PostgreSQL using the Alpine image
- `postgres_data` - named Docker volume for database persistence

PostgreSQL is only available inside the Compose network. It is not published to the host.

### Endpoints

- `POST /metrics` - authenticated metric ingest endpoint
- `GET /health` - unauthenticated database health check

## Configure

Copy the folder that contains this readme to your server and `cd` to the folder on your server.

Create a local `.env` file:

```sh
cp .env.example .env
```

Edit `.env` with your preferred editor before starting the stack:

Configuration values:

- `BEARER_TOKEN` - required. Make it a long random string and keep a note of it for when you setup your clients.
- `POSTGRES_PASSWORD` - required; password for the Compose-managed PostgreSQL user. Keep this URL-Safe; Avoid characters such as `@`, `/`, `:`, `?`, `#`, `&`, and spaces
- `APP_HOST` - optional; host address Docker binds for the app. Defaults to `127.0.0.1` which is for testing and reverse proxy usage. If you need to expose the service, use `0.0.0.0` but only on a trusted network.
- `APP_PORT` - optional; host port Docker publishes for the app. Defaults to `8080`.
- `ALLOWED_NET` - optional CIDR allow-list, for example `203.0.113.0/24`.
- `METRICS_INGEST_IMAGE` - optional; app image to run. Defaults to `ghcr.io/mefranklin6/av-system-metrics/metrics-ingest:latest`.
- `METRICS_INGEST_PULL_POLICY` - optional; Docker Compose pull behavior for the app image. Defaults to `always`.

## Start

Pull and start the full stack using the prebuilt containers:

```sh
docker compose pull
docker compose up -d
```

The stack uses the public GHCR app image and the upstream PostgreSQL image. You do not need Go installed on the server.

To update later:

```sh
docker compose pull
docker compose up -d
```

To pin a specific app image version, set `METRICS_INGEST_IMAGE` in `.env` to a branch tag or SHA tag published by CI:

```sh
METRICS_INGEST_IMAGE=ghcr.io/mefranklin6/av-system-metrics/metrics-ingest:sha-<commit>
```

## Local build

If you are developing the service and want to run a locally built image:

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

Check database health through the service:

```sh
curl -i http://127.0.0.1:8080/health
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
SELECT clientname, metric, action, event_timestamp, received_at FROM metric_events ORDER BY received_at DESC LIMIT 10;
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

Use `docker compose down -v` when you want PostgreSQL to re-run schema initialization from scratch.

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

## Limits

- Maximum request body size: 10 KB
- Maximum messages per request: 25
- Maximum length for `clientname`, `metric`, and `action`: 128 characters each
- Required message fields: `clientname`, `metric`, `action`, `timestamp`
- `timestamp` must be an ISO-8601-like string accepted by the service
