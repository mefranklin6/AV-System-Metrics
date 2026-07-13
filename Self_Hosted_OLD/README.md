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
