# AV-System-Metrics: Analytics API (optional)

The Analytics API is an **optional, read-only** web service that lets the
[Metrics Visualizer](../../visualizer_app/) and your own reporting tools read
the room and device usage events stored by the self-hosted ingest service.

- It is **off by default**. Turning it on or off never affects data collection.
- It **only reads**. It cannot add, change, or delete data, and it never exposes
  the IP addresses of your control processors.
- It is a separate program (`analytics-api`) in its own container image
  (`ghcr.io/mefranklin6/av-system-metrics/analytics-api`) with its own token
  and its own database account.

The machine-readable API description is [`openapi.yaml`](openapi.yaml)
(OpenAPI 3.1). A running server also serves it at `/openapi.yaml`, so you can
load it into Swagger UI, Postman, Insomnia, or a client code generator.

```text
Visualizer / your app ──HTTPS──> reverse proxy ──> analytics-api ──(metrics_reader, read-only)──> PostgreSQL
Control processors ──HTTP──> metrics-ingest ──(metrics_user)──────────────────────────────────────┘
```

## Contents

- [Security model](#security-model)
- [Enable the API](#enable-the-api)
- [Reverse proxy examples](#reverse-proxy-examples)
- [Disable the API](#disable-the-api)
- [Configuration reference](#configuration-reference)
- [Using the API](#using-the-api)
- [Endpoints](#endpoints)
- [Pagination](#pagination)
- [Errors](#errors)
- [Rate limits and lockout](#rate-limits-and-lockout)
- [Build your own app](#build-your-own-app)
- [Database indexes and maintenance](#database-indexes-and-maintenance)
- [Development and testing](#development-and-testing)

## Security model

The API is designed so that a stolen API token, or a bug in the API, still
cannot change or destroy your data. Each layer works on its own:

| Layer | What it does |
| --- | --- |
| Disabled by default | `ENABLE_ANALYTICS_API=false` in `.env`. Nothing listens and the database login stays disabled until you opt in. |
| Separate API token | `ANALYTICS_API_TOKEN` is different from the ingest `BEARER_TOKEN`, so a control processor token cannot read data and an analytics token cannot write data (the updater refuses an analytics token equal to `BEARER_TOKEN`). Tokens are 32 to 512 characters from `A-Z a-z 0-9 . _ ~ + / = -`, compared in constant time as SHA-256 digests, and never logged. Up to 64 comma-separated tokens are allowed for rotation or per-person access. |
| Separate database role | The API connects as `metrics_reader`, never as the database owner. The one-shot `analytics-db-provision` container creates it with `NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS`, a connection limit of 10, and no role memberships. Its password (`ANALYTICS_DB_PASSWORD`) is set by PostgreSQL's own `format('%L')` quoting, with statement logging disabled for that transaction. |
| Column-level grants | `metrics_reader` may `SELECT` only `id, clientname, event_timestamp, metric, action, event_id, received_at` from `metric_events`, plus `heartbeat_purge_status`. It cannot read `source_ip` or `sort_key`, and holds no `INSERT`, `UPDATE`, `DELETE`, or `TRUNCATE` privilege. It cannot create tables or schemas, temporary tables, or large objects: provisioning revokes PostgreSQL's default `TEMPORARY` database privilege and `EXECUTE` on `lo_create`, `lo_creat`, `lo_from_bytea`, and `lo_put` from `PUBLIC` (only the database owner, a superuser, keeps them). |
| Read-only by default | The role's sessions default to `default_transaction_read_only = on` with `statement_timeout = 30s`, `idle_in_transaction_session_timeout = 60s`, and `lock_timeout = 5s`. These are defaults a session could change, so the grants above are what actually prevent writes. Every API query also runs in an explicit `READ ONLY` transaction, fully parameterized, with a 20-second request deadline and at most 5 database connections. |
| Startup self-check | Before listening, the API checks its own database session. It **refuses to start** if the session is not read-only by default, if the role is a superuser or can create roles/databases, bypass row-level security, replicate, or `SET ROLE` to another role, if it holds any table- or column-level `INSERT` or `UPDATE` privilege or `DELETE`/`TRUNCATE` on the tables it reads, if it can create objects in `public`, schemas or temporary tables in the database, or large objects, or if it can read `source_ip` or `sort_key`. There is no override. |
| Network allow-list | `ANALYTICS_ALLOWED_NET` limits which client IP addresses may use the API (CIDR list). `X-Forwarded-For` is ignored on purpose, so behind a reverse proxy the API sees the proxy (see [Publish it safely](#enable-the-api)). |
| Rate limiting | Requests with a valid token: about 10 per second (bursts of 40) and at most 3 at a time, per token and client address. Requests without a valid token: about 10 per second per client address, and ten failed sign-ins within 5 minutes block further failing attempts from that address for 15 minutes. A valid token is never blocked by that lockout, so wrong tokens sent through a shared reverse proxy cannot lock out everyone else. |
| Browser hardening | No CORS by default; only exact origins listed in `ANALYTICS_CORS_ORIGINS` are allowed (never `*`). Every response the API writes carries `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`, and `X-Frame-Options: DENY`. Only `GET`, `HEAD`, and `OPTIONS` are accepted. |
| Encryption in transit | With the bundled Compose files the API serves plain HTTP; publish it through a TLS reverse proxy. (`ANALYTICS_TLS_CERT_FILE` and `ANALYTICS_TLS_KEY_FILE` apply only when you run the binary or image yourself; the Compose files do not pass them or mount certificates.) Use plain HTTP only on a trusted network: the token travels in every request. |
| Disabling revokes access | Setting `ENABLE_ANALYTICS_API=false` and restarting runs `analytics-db-disable`, which sets `metrics_reader` to `NOLOGIN` and ends its open sessions. |
| No secrets in output | Error responses never repeat request values or database errors. Logs never contain tokens or passwords. |

Requests are checked in this order:

1. Client address allow-list (`/health` is exempt).
2. HTTP method. Anything other than `GET` or `HEAD` on an `/api/` path, and
   every request to `/health`, `/openapi.yaml`, a path outside `/api/`, or a
   CORS preflight, is charged to the client address's rate limit and answered
   without authentication.
3. Authentication of `GET`/`HEAD` requests to `/api/` paths.
   - Missing, malformed, or wrong token: the failed-sign-in lockout, then the
     client address's rate limit, then `401` or `403`.
   - Valid token: the rate limit for that token and address, `404` for an
     unknown `/api/` path, then the cap of 3 requests in progress.
4. Query parameters, and only then the database query.

## Enable the API

These steps assume the self-hosted stack from [`../README.md`](../README.md) is
already running.

1. **Create two long random secrets** on the server.

   ```bash
   openssl rand -hex 32   # use as ANALYTICS_API_TOKEN (64 characters)
   openssl rand -hex 24   # use as ANALYTICS_DB_PASSWORD (48 characters)
   ```

   On Windows (PowerShell 7+):

   ```powershell
   [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLower()
   [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLower()
   ```

   `ANALYTICS_DB_PASSWORD` must be 16 to 128 characters of letters, digits,
   `.`, `_`, `~`, or `-` (it is placed inside a database URL) and must differ
   from `POSTGRES_PASSWORD`. Each `ANALYTICS_API_TOKEN` must be 32 to 512
   characters of letters, digits, `.`, `_`, `~`, `+`, `/`, `=`, or `-`, and
   must differ from `BEARER_TOKEN`. Other characters, such as `$`, quotes, or
   `#`, are refused because Docker Compose would change them when it reads
   `.env`.

2. **Edit `.env`** in your install directory:

   ```dotenv
   ENABLE_ANALYTICS_API=true
   ANALYTICS_API_TOKEN=<first secret>
   ANALYTICS_DB_PASSWORD=<second secret>
   ANALYTICS_HOST=127.0.0.1      # keep for a reverse proxy on the same host
   ANALYTICS_PORT=8081
   ANALYTICS_ALLOWED_NET=        # e.g. 10.50.0.0/16 (see below)
   ANALYTICS_CORS_ORIGINS=       # e.g. https://viz.example.edu for the web Visualizer
   ```

   Put each value on its own line: Compose does not strip comments after a
   value. The services refuse to start while the `.env.example` values are
   still in place.

   **Using the web build of the Metrics Visualizer?** A browser only lets the
   app read the API when the app's exact origin (scheme, host, and port, such
   as `https://viz.example.edu` or `http://localhost:8080`) is listed in
   `ANALYTICS_CORS_ORIGINS`. Without it the web app reports a network error.
   The Windows and macOS desktop builds do not need it.

3. **Apply the change.** Always include `--remove-orphans` so switching the
   feature off later also removes the API container.

   ```bash
   docker compose up -d --remove-orphans
   ```

   Compose first waits for the ingest service to be healthy (it creates the
   tables), then runs the one-shot `analytics-db-provision` container, then
   starts `analytics-api`. On a large database the first provisioning run can
   take several minutes while it builds two indexes without blocking ingestion.
   `ANALYTICS_PROVISION_TIMEOUT` (default `15m`) bounds it; the updater waits
   that long plus three minutes.

4. **Check it.**

   ```bash
   docker compose ps analytics-api
   docker compose logs analytics-db-provision analytics-api
   curl -fsS http://127.0.0.1:8081/health
   ```

   The provisioning log ends with `analytics provisioning complete`, and the API
   log shows `passed the read-only self-check`.

5. **Publish it safely.** Put the API behind your TLS reverse proxy (nginx,
   Caddy, IIS ARR, a campus load balancer) and point the proxy at
   `127.0.0.1:8081`. This is the only supported way to add TLS with the
   bundled Compose files. If you must expose the port directly, set
   `ANALYTICS_HOST=0.0.0.0` only on a trusted network and restrict it with
   `ANALYTICS_ALLOWED_NET` and your firewall.

   Firewall rule to add: **trusted admin / reporting workstations (or your
   reverse proxy) to the analytics port only.** Control processors never need
   access to it.

   Let the proxy pass query strings of at least 8 KiB. Apps that filter by
   many rooms send long URLs: the Metrics Visualizer keeps each query string
   under about 6 KiB. nginx's default (an 8 KiB request line) is enough. IIS
   request filtering allows only 2,048 bytes of query string by default and
   answers longer ones with `404.15`, which apps cannot tell apart from a
   missing page; raise `maxQueryString` to `8192` for the API's site.

   See [Reverse proxy examples](#reverse-proxy-examples) for nginx, Caddy,
   and IIS configurations.

> `ANALYTICS_ALLOWED_NET` matches the address the API sees, and
> `X-Forwarded-For` is ignored. Behind a reverse proxy every request comes from
> the proxy, so do the per-user address filtering, rate limiting, and failed
> sign-in limiting at the proxy too.
>
> - A proxy on **another host** appears with its own address: list it, for
>   example `ANALYTICS_ALLOWED_NET=10.20.0.15/32`.
> - A proxy on **the same host** that connects to `127.0.0.1:8081` does not
>   appear as `127.0.0.1`: Docker forwards the connection from the gateway of
>   the API's network, an address such as `172.19.0.1`. Listing `127.0.0.1/32`
>   blocks every request. List the gateway of each of the API's networks with
>   `docker inspect --format '{{range $name, $net := .NetworkSettings.Networks}}{{println $name $net.Gateway}}{{end}}' "$(docker compose ps -q analytics-api)"`
>   and use the gateway of the network whose name ends in `_analytics_net` (as `/32`), or read
>   it from the API log line `rejected request from address outside
>   ANALYTICS_ALLOWED_NET: <address>`. The gateway can change if the network is
>   recreated, so the firewall and `ANALYTICS_HOST=127.0.0.1` remain the main
>   protection.
>
> Health probes (`/health`) are always allowed so Docker and load balancers can
> check the service.

## Reverse proxy examples

These are minimal starting points for a TLS reverse proxy **on the same
host** as the Compose stack, forwarding to the API at `127.0.0.1:8081`
(`ANALYTICS_HOST=127.0.0.1`, the default). Replace the host name and
certificate paths with your own. They are not exercised by this repository's
tests, so check the result with the `curl` commands at the end.

Whatever proxy you use:

- **Keep the token out of logs.** The token travels in the `Authorization`
  header. Default access-log formats of nginx, Caddy, and IIS do not record
  it; do not add that header to a custom log format, and do not log request
  headers in a debugging mode on a production proxy. Query strings (room and
  input names) are logged, which is normally acceptable.
- **Do not cache API responses.** Every response carries
  `Cache-Control: no-store`. Do not enable `proxy_cache`, Caddy cache
  plugins, or IIS output caching for the API.
- **Pass long query strings** (at least 8 KiB) and leave the `Authorization`
  header untouched.
- **Do the per-user limits at the proxy.** The API sees every request coming
  from the proxy (see the note on `ANALYTICS_ALLOWED_NET` above), so address
  filtering and request rate limiting by client belong at the proxy.
- **Path prefix.** Serving the API under a path such as
  `https://avsm.example.edu/analytics/` works: strip the prefix at the proxy,
  and give apps the address with the prefix (the Metrics Visualizer accepts
  `https://avsm.example.edu/analytics`).
- **Web Visualizer.** If the web build of the Metrics Visualizer calls the
  API, list its origin in `ANALYTICS_CORS_ORIGINS`. The API answers CORS
  itself, so the proxy must pass `OPTIONS` requests and the `Origin` header
  through unchanged and must not add its own CORS headers.

### nginx

```nginx
# In the http { } block: about 10 requests per second per client address.
limit_req_zone $binary_remote_addr zone=avsm_api:10m rate=10r/s;

server {
    listen 443 ssl;
    server_name avsm.example.edu;

    ssl_certificate     /etc/ssl/certs/avsm.example.edu.fullchain.pem;
    ssl_certificate_key /etc/ssl/private/avsm.example.edu.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;

    # Long query strings for apps that filter by many rooms.
    large_client_header_buffers 4 16k;

    location / {
        # Optional address filtering, for example the reporting VLAN:
        # allow 10.50.0.0/16;
        # deny  all;
        limit_req zone=avsm_api burst=20 nodelay;

        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_read_timeout 60s;
    }
}
```

To serve the API under `/analytics/` instead, use this location (the
trailing `/` on `proxy_pass` strips the prefix):

```nginx
    location /analytics/ {
        limit_req zone=avsm_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:8081/;
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_read_timeout 60s;
    }
```

### Caddy

```caddyfile
avsm.example.edu {
    # Caddy obtains a certificate automatically when the name is public.
    # On an internal network use your own certificate instead:
    # tls /etc/ssl/certs/avsm.example.edu.fullchain.pem /etc/ssl/private/avsm.example.edu.key
    reverse_proxy 127.0.0.1:8081
}
```

With a path prefix, `handle_path` strips it:

```caddyfile
avsm.example.edu {
    handle_path /analytics/* {
        reverse_proxy 127.0.0.1:8081
    }
}
```

Caddy redacts the `Authorization` header in its access logs unless the
`log_credentials` global option is turned on; leave it off.

### IIS (Application Request Routing)

IIS normally runs on a separate Windows server. Then the hop from IIS to the
API is plain HTTP: set `ANALYTICS_HOST=0.0.0.0` on the metrics server, set
`ANALYTICS_ALLOWED_NET` to the IIS server's address (for example
`10.20.0.15/32`), allow only that address to port 8081 in the firewall, and
keep both servers on a trusted network segment.

1. Install the **URL Rewrite** and **Application Request Routing** modules.
2. In IIS Manager, select the server, open **Application Request Routing
   Cache > Server Proxy Settings**, and tick **Enable proxy**. Leave disk
   caching off for the API.
3. Create an HTTPS site for `avsm.example.edu` with your certificate, and put
   this `web.config` in its root (replace `10.20.0.20` with the metrics
   server's address):

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <configuration>
     <system.webServer>
       <rewrite>
         <rules>
           <rule name="AVSM Analytics API" stopProcessing="true">
             <match url="(.*)" />
             <action type="Rewrite" url="http://10.20.0.20:8081/{R:1}" appendQueryString="true" />
           </rule>
         </rules>
       </rewrite>
       <security>
         <requestFiltering>
           <requestLimits maxQueryString="8192" />
         </requestFiltering>
       </security>
     </system.webServer>
   </configuration>
   ```

   For a prefix, create an application (for example `/analytics`) and put
   the same `web.config` in it; the rule then sees the path without the
   prefix.
4. Use **Dynamic IP Restrictions** for per-address rate limits and **IP
   Address and Domain Restrictions** to limit who can connect. Do not add
   `Authorization` as a custom field in IIS logging.

### Check the proxy

From a workstation that should have access:

```bash
curl -fsS https://avsm.example.edu/health
curl -fsS -H "Authorization: Bearer $TOKEN" https://avsm.example.edu/api/v1/info
```

The first prints `{"ok":true}` and the second the server
information. A `401` or `403` on the second means the token is wrong; a
`404.15` (IIS) or `414` means the proxy refuses long query strings; a network
error from the web Visualizer usually means its origin is missing from
`ANALYTICS_CORS_ORIGINS`.

### Rotating the token

`ANALYTICS_API_TOKEN` accepts a comma-separated list. Add the new token next to
the old one, run `docker compose up -d --remove-orphans`, move your apps to the
new token, then remove the old one and apply again. You can also give each
person or app its own token and remove it when they leave.

### Rotating the database password

Change `ANALYTICS_DB_PASSWORD` and run `docker compose up -d --remove-orphans`.
The provisioning container sets the new password before the API restarts.

## Disable the API

```dotenv
ENABLE_ANALYTICS_API=false
```

```bash
docker compose up -d --remove-orphans
```

The API container is removed, and the one-shot `analytics-db-disable`
container sets `metrics_reader` to `NOLOGIN` and ends its open database
sessions. Data collection is unaffected. Turning the feature back on
re-enables the login.

- Do not disable the API while `analytics-db-provision` is still running
  (`docker compose ps analytics-db-provision`). Stopping it in the middle of an
  index build leaves an invalid index behind until provisioning runs again.
- If you apply the change with `update.sh` while `METRICS_INGEST_IMAGE` is
  pinned to an image digest (`@sha256:`) or a `sha-<commit>` tag, the updater
  installs the new `.env` but stops before restarting containers, so the API
  keeps running with its old settings. Run `docker compose stop analytics-api`
  to revoke access at once, then `docker compose up -d --remove-orphans`.
- The two supporting indexes stay in place (see
  [Database indexes and maintenance](#database-indexes-and-maintenance) to
  remove them).

## Configuration reference

With the bundled Compose files you only edit `.env`. The overlay passes
`ANALYTICS_API_TOKEN`, `ANALYTICS_ALLOWED_NET`, and `ANALYTICS_CORS_ORIGINS`
from `.env`, builds `ANALYTICS_DATABASE_URL` from `ANALYTICS_DB_PASSWORD`, and
sets `ADDR=:8081`. It does **not** pass `ANALYTICS_TLS_CERT_FILE` or
`ANALYTICS_TLS_KEY_FILE` or mount certificates, so adding them to `.env` has no
effect: use a TLS reverse proxy.

**Compose settings in `.env`** (besides the ones passed to the API)

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_ANALYTICS_API` | `false` | `true` selects `docker-compose.analytics-true.yml`; `false` selects `docker-compose.analytics-false.yml`, which runs `analytics-db-disable`. |
| `ANALYTICS_DB_PASSWORD` | none | Password of `metrics_reader`; required when enabled (rules in [Enable the API](#enable-the-api)). |
| `ANALYTICS_HOST`, `ANALYTICS_PORT` | `127.0.0.1`, `8081` | Host address and port where Docker publishes the API. |
| `ANALYTICS_PROVISION_TIMEOUT` | `15m` | Upper bound for the provisioning job (see below). |
| `ANALYTICS_API_IMAGE`, `ANALYTICS_API_PULL_POLICY` | `ghcr.io/mefranklin6/av-system-metrics/analytics-api:main`, `always` | Image for both `analytics-db-provision` and `analytics-api`. |
| `ANALYTICS_API_CPUS`, `ANALYTICS_API_MEMORY_LIMIT`, `ANALYTICS_API_PIDS_LIMIT` | `0.50`, `256m`, `100` | Resource limits for both containers. |

The full list below is for people who run the binary or image directly.

**API server** (`analytics-api`)

| Variable | Required | Description |
| --- | --- | --- |
| `ANALYTICS_API_TOKEN` | yes | One token, or up to 64 separated by commas. Each 32 to 512 characters from `A-Z a-z 0-9 . _ ~ + / = -` (for example `openssl rand -hex 32`). |
| `ANALYTICS_DATABASE_URL` | yes | PostgreSQL URL for `metrics_reader`, e.g. `postgres://metrics_reader:<pw>@postgres:5432/metrics?sslmode=disable&connect_timeout=5`. |
| `ADDR` | no | Listen address. Default `:8081`. |
| `ANALYTICS_ALLOWED_NET` | no | Comma-separated CIDR allow-list (at most 256 entries), e.g. `10.20.0.0/16,192.0.2.10/32`. Empty allows any address that can reach the port. |
| `ANALYTICS_CORS_ORIGINS` | no | Comma-separated exact origins (at most 32) allowed to call the API from a browser, e.g. `https://viz.example.edu`. Required for the web build of the Metrics Visualizer. Empty disables CORS. Wildcards and `null` are rejected. |
| `ANALYTICS_TLS_CERT_FILE`, `ANALYTICS_TLS_KEY_FILE` | no | Direct runs only (not passed by the Compose files). PEM certificate and key readable by UID 65532. When both are set the API serves HTTPS only (TLS 1.2+) and sends `Strict-Transport-Security`. |
| `GOMEMLIMIT` | no | Go heap limit. When unset, the API sets it to 80% of the container's memory limit. |
| `HEALTHCHECK_URL` | no | Override the URL used by `analytics-api healthcheck`. |

**Provisioning** (`analytics-api provision`)

| Variable | Required | Description |
| --- | --- | --- |
| `PROVISION_DATABASE_URL` | yes | Admin (database owner) URL, e.g. `postgres://metrics_user:<POSTGRES_PASSWORD>@postgres:5432/metrics?sslmode=disable`. |
| `ANALYTICS_DB_PASSWORD` | yes | Password to set for `metrics_reader` (rules above). |
| `ANALYTICS_PROVISION_TIMEOUT` | no | Upper bound for the role changes and index builds. Default `15m`. In `.env`, use whole hours, minutes, or seconds (such as `15m` or `1h30m`); the updater waits this long plus three minutes. |

Provisioning is idempotent: every run re-applies the role attributes, password,
session defaults, and grants, removes any role memberships, and creates (or
repairs) the indexes. It also revokes PostgreSQL defaults from `PUBLIC` in the
`metrics` database: `TEMPORARY` (creating temporary tables), `EXECUTE` on the
large-object creation functions (`lo_create`, `lo_creat`, `lo_from_bytea`,
`lo_put`), and `CREATE` on schema `public` (already the default since
PostgreSQL 15). Any other non-superuser role you created yourself, for example
for a reporting tool, loses them too; grant them back to that role explicitly
if it needs them.

## Using the API

All examples below read the token from an environment variable so it does not
end up in your shell history:

```bash
export AVSM_ANALYTICS_TOKEN='<token>'
export AVSM_ANALYTICS_URL='http://127.0.0.1:8081'
```

```powershell
$env:AVSM_ANALYTICS_TOKEN = Read-Host -Prompt 'Analytics API token' -MaskInput   # PowerShell 7
$env:AVSM_ANALYTICS_URL   = 'https://analytics.example.edu'
$headers = @{ Authorization = "Bearer $env:AVSM_ANALYTICS_TOKEN" }
```

On Windows PowerShell 5.1 use `Read-Host -AsSecureString` or paste the token,
and run `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'` once per
session before calling an HTTPS address.

### Conventions

- Authentication: `Authorization: Bearer <token>` on every `/api/v1` request.
- Responses are JSON (`application/json; charset=utf-8`).
- Timestamps in responses are UTC with six fractional digits:
  `2026-11-11T00:22:09.709041Z`.
- `from` and `to` are RFC 3339 timestamps **with** a time zone offset
  (`2026-09-01T00:00:00Z` or `2026-09-01T00:00:00-07:00`). The range is
  half-open, `[from, to)`. Defaults: `to` = now, `from` = 30 days before `to`.
  The range may span at most 400 days. URL-encode `+` as `%2B`
  (`curl --data-urlencode` and `[uri]::EscapeDataString` do this for you).
- `client` filters are exact and case-sensitive (`HOLT_155` and `Holt_155` are
  different rooms) and can be repeated up to 200 times (1 to 128 characters
  each; repeated names are ignored). Keep each encoded query string well under
  8 KiB: split longer room lists across several requests and merge the results
  (see [Errors](#errors) for `414` and `431`).
- Single-value parameters (`from`, `to`, `limit`, `cursor`, `bucket`,
  `include_heartbeats`) may appear only once.
- Unknown query parameters are rejected, so typos are caught instead of being
  silently ignored.
- Heartbeat rows (`action` = `Heartbeat`) are excluded unless
  `include_heartbeats=true`. The ingest service deletes heartbeats older than
  `HEARTBEAT_RETENTION_DAYS` (default 30).
- The server never hides any client. `AVSM-System` holds server update and
  maintenance traces; leave it out of room statistics in your app.

## Endpoints

| Method and path | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | Database reachability (`{"ok":true}` or 503 `{"ok":false}`) |
| `GET /openapi.yaml` | none | This API's OpenAPI 3.1 description |
| `GET /api/v1/info` | token | Server time, data coverage, heartbeat purge status |
| `GET /api/v1/clients` | token | Rooms seen in a range with counts and last-seen times |
| `GET /api/v1/events` | token | Raw events, paginated |
| `GET /api/v1/summary` | token | Counts grouped by room, metric, and action |
| `GET /api/v1/heartbeats` | token | Heartbeats per room per hour or day (online coverage) |

### `GET /health`

```bash
curl -fsS "$AVSM_ANALYTICS_URL/health"
```

```powershell
Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/health"
```

### `GET /api/v1/info`

No query parameters.

```bash
curl -fsS -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "$AVSM_ANALYTICS_URL/api/v1/info"
```

```powershell
Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/api/v1/info" -Headers $headers
```

```json
{
  "api_version": "1",
  "server_time": "2026-11-11T00:22:09.709041Z",
  "activity_range": {"first_event": "2026-02-03T14:00:01.000000Z", "last_event": "2026-11-11T00:20:55.103221Z"},
  "heartbeat_purge": {"enabled_status": "succeeded", "retention_days": 30,
                      "cutoff": "2026-10-11T03:00:00.000000Z", "finished_at": "2026-11-10T03:00:12.512000Z"}
}
```

`activity_range` covers non-heartbeat events. `heartbeat_purge` describes the
ingest service's latest heartbeat cleanup (`running`, `succeeded`, or
`failed`); every field is `null` if none has run. Use `retention_days` and
`cutoff` to know how far back heartbeat-based online statistics are complete.

### `GET /api/v1/clients`

Parameters: `from`, `to`.

```bash
curl -fsS -G -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "$AVSM_ANALYTICS_URL/api/v1/clients" \
  --data-urlencode 'from=2026-10-01T00:00:00-07:00' --data-urlencode 'to=2026-11-01T00:00:00-07:00'
```

```powershell
$from = [uri]::EscapeDataString('2026-10-01T00:00:00-07:00')
$to   = [uri]::EscapeDataString('2026-11-01T00:00:00-07:00')
(Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/api/v1/clients?from=$from&to=$to" -Headers $headers).clients |
  Format-Table clientname, event_count, heartbeat_count, last_event, last_heartbeat
```

```json
{"from": "2026-10-01T07:00:00.000000Z", "to": "2026-11-01T07:00:00.000000Z",
 "clients": [{"clientname": "BSS_245", "event_count": 1840, "heartbeat_count": 8640,
              "first_event": "2026-10-01T14:01:22.120000Z", "last_event": "2026-10-31T22:15:09.004000Z",
              "last_heartbeat": "2026-11-01T06:59:40.000000Z"}]}
```

One entry per room with any event in the range, sorted by name (binary order).
`event_count`, `first_event`, and `last_event` ignore heartbeats; a room that
only sent heartbeats has `event_count` 0 and `null` event times.

### `GET /api/v1/events`

Parameters: `from`, `to`, `client` (repeatable), `metric` (repeatable, max 50),
`action` (repeatable, max 50), `include_heartbeats` (`true`/`false`, default
`false`), `limit` (1 to 5000, default 1000), `cursor`.

```bash
# Every input selection and power event in two rooms during September
curl -fsS -G -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "$AVSM_ANALYTICS_URL/api/v1/events" \
  --data-urlencode 'from=2026-09-01T00:00:00Z' --data-urlencode 'to=2026-10-01T00:00:00Z' \
  -d client=BSS_245 -d client=HOLT_155 -d action=Started -d action=Stopped -d limit=5000
```

```powershell
$q = 'from={0}&to={1}&client=BSS_245&client=HOLT_155&action=Started&action=Stopped&limit=5000' -f `
  [uri]::EscapeDataString('2026-09-01T00:00:00Z'), [uri]::EscapeDataString('2026-10-01T00:00:00Z')
$page = Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/api/v1/events?$q" -Headers $headers
$page.events | Select-Object -First 5
$page.next_cursor
```

```json
{"from": "2026-09-01T00:00:00.000000Z", "to": "2026-10-01T00:00:00.000000Z",
 "events": [{"id": 2993012, "clientname": "Holt_171", "event_timestamp": "2026-09-10T23:47:27.225600Z",
             "metric": "System - User", "action": "Stopped",
             "event_id": "f5ba6c9f-571c-472c-8d6a-6002f03d8209", "received_at": "2026-09-10T23:47:37.295791Z"}],
 "next_cursor": "AQAGX_SzbZMA9bpsn1ccRyyNamAC8D2CCQ"}
```

Events are ordered by `event_timestamp`, then `event_id`. See
[Pagination](#pagination) to read every page.

### `GET /api/v1/summary`

Parameters: `from`, `to`, `client` (repeatable), `include_heartbeats`.

```bash
curl -fsS -G -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "$AVSM_ANALYTICS_URL/api/v1/summary" \
  --data-urlencode 'from=2026-08-24T00:00:00Z' --data-urlencode 'to=2026-12-12T00:00:00Z'
```

```powershell
$s = Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/api/v1/summary" -Headers $headers
# Most-selected video inputs campus-wide over the last 30 days
$inputs = 'pc','hdmi','usb','VGA','wireless','doc_cam','dvd','blu_ray'
$s.rows | Where-Object { $_.action -eq 'Started' -and $_.metric -in $inputs } |
  Group-Object metric | ForEach-Object { [pscustomobject]@{ input = $_.Name; selections = ($_.Group | Measure-Object count -Sum).Sum } } |
  Sort-Object selections -Descending
```

```json
{"from": "2026-08-24T00:00:00.000000Z", "to": "2026-12-12T00:00:00.000000Z", "truncated": false,
 "rows": [{"clientname": "BSS_245", "metric": "hdmi", "action": "Started", "count": 41,
           "first_event": "2026-08-25T15:02:11.000000Z", "last_event": "2026-12-10T19:44:03.120000Z"}]}
```

One row per (room, metric, action), ordered by those columns. At most 50,000
rows; `truncated: true` means more exist. The rows you received are complete
counts, but later rows are missing: repeat the request for groups of rooms
(names from `/api/v1/clients`) or for shorter ranges, and add up matching rows
across time pieces.

### `GET /api/v1/heartbeats`

Parameters: `from`, `to`, `client` (repeatable), `bucket` (`hour` default, or
`day`). With `bucket=hour` the range may span at most 92 days.

```bash
curl -fsS -G -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "$AVSM_ANALYTICS_URL/api/v1/heartbeats" \
  --data-urlencode 'from=2026-11-01T00:00:00Z' -d client=BSS_245 -d bucket=hour
```

```powershell
$hb = Invoke-RestMethod "$env:AVSM_ANALYTICS_URL/api/v1/heartbeats?client=BSS_245&bucket=day" -Headers $headers
$hb.series | ForEach-Object { [pscustomobject]@{ room = $_.clientname; days_online = $_.buckets.Count } }
```

```json
{"from": "2026-11-01T00:00:00.000000Z", "to": "2026-11-11T00:22:09.709041Z", "bucket": "hour", "truncated": false,
 "series": [{"clientname": "BSS_245", "buckets": [{"start": "2026-11-01T00:00:00.000000Z", "count": 12},
                                                  {"start": "2026-11-01T01:00:00.000000Z", "count": 12}]}]}
```

Buckets are UTC hours or days. Only buckets with at least one heartbeat are
returned: a missing hour means the processor did not report (offline, powered
down, or unreachable). Hourly coverage divided by the hours in the range gives
an "online %" per room, within the heartbeat retention window.

At most 200,000 buckets are returned per request (for example 500 rooms for
about 16 days of hours). `truncated: true` means the response is incomplete:
the last room's series may be missing buckets and later rooms are missing
entirely. Do not report it as full coverage. Keep the series before the last
one (they are complete), then fetch the rest in smaller pieces: fewer rooms per
request (split the `client` list, using names from `/api/v1/clients`), shorter
ranges, or `bucket=day`. Repeat until no piece is truncated and merge the
series.

## Pagination

`/api/v1/events` returns at most `limit` events and a `next_cursor`. Repeat the
**same request** with `cursor=<next_cursor>` until `next_cursor` is `null`. The
cursor is an opaque token: pass it back unchanged. Omit `cursor` for the first
page (an empty `cursor=` is rejected). Pages are keyed on the last event's time
and ID, so a pass never returns an event twice.

Events are ordered by the time the device recorded them (`event_timestamp`),
not the time they reached the server. Control processors buffer events while
the server is unreachable (for example during an outage or a maintenance
window) and upload them later with their original times. An event that
arrives during a pass with a time earlier than the cursor is not returned by
that pass. Treat the most recent data as provisional: re-fetch at least the
last 48 hours (longer after an outage) before you store a range as final.

```bash
cursor=''
while :; do
  args=(-G --data-urlencode 'from=2026-09-01T00:00:00Z' --data-urlencode 'to=2026-10-01T00:00:00Z' -d limit=5000)
  [[ -n "$cursor" ]] && args+=(--data-urlencode "cursor=$cursor")
  page="$(curl -fsS -H "Authorization: Bearer $AVSM_ANALYTICS_TOKEN" "${args[@]}" "$AVSM_ANALYTICS_URL/api/v1/events")"
  jq -c '.events[]' <<<"$page" >> events.jsonl
  cursor="$(jq -r '.next_cursor // empty' <<<"$page")"
  [[ -n "$cursor" ]] || break
done
```

```powershell
$base  = "$env:AVSM_ANALYTICS_URL/api/v1/events?limit=5000&from={0}&to={1}" -f `
  [uri]::EscapeDataString('2026-09-01T00:00:00Z'), [uri]::EscapeDataString('2026-10-01T00:00:00Z')
$all = [System.Collections.Generic.List[object]]::new()
$cursor = $null
do {
  $uri = if ($cursor) { "$base&cursor=$cursor" } else { $base }
  $page = Invoke-RestMethod $uri -Headers $headers
  foreach ($e in $page.events) { $all.Add($e) }
  $cursor = $page.next_cursor
} while ($cursor)
# PowerShell 7 turns the timestamps into dates and Export-Csv would write them
# in your regional format (losing the microseconds), so write them back as UTC
# text exactly as the API sent them. Windows PowerShell 5.1 keeps them as text.
$utc = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", [cultureinfo]::InvariantCulture) } else { $v } }
$all | Select-Object id, clientname,
    @{ n = 'event_timestamp'; e = { & $utc $_.event_timestamp } }, metric, action, event_id,
    @{ n = 'received_at'; e = { & $utc $_.received_at } } |
  Export-Csv -NoTypeInformation -Encoding utf8 -Path .\events-2026-09.csv
"Saved $($all.Count) events"
```

The CSV written above can be loaded into the Metrics Visualizer. (A plain
`$all | Export-Csv` is not safe in PowerShell 7: depending on your regional
settings the dates are written day-first or in a format the Visualizer cannot
read.)

## Errors

Every error response has the same shape and never repeats your input:

```json
{"error": {"code": "bad_request", "message": "Parameter 'from' must be earlier than 'to' (the range is [from, to))."}}
```

| HTTP | `code` | Meaning and fix |
| --- | --- | --- |
| 400 | `bad_request` | A parameter is unknown, repeated, malformed, or out of range. The message names the parameter and the rule. |
| 401 | `unauthorized` | `Authorization` header missing or malformed. Comes with `WWW-Authenticate: Bearer realm="avsm-analytics"`. |
| 403 | `forbidden` | Token not valid, client address outside `ANALYTICS_ALLOWED_NET`, or browser origin not in `ANALYTICS_CORS_ORIGINS`. |
| 404 | `not_found` | No such endpoint. |
| 405 | `method_not_allowed` | Only `GET`, `HEAD`, and `OPTIONS` exist. See the `Allow` header. |
| 414 | none (not JSON) | URI Too Long, from a reverse proxy: the query string is longer than the proxy allows. Split the `client` list across several requests. |
| 429 | `too_many_requests` | Rate limit, too many requests in progress at once, or failed-sign-in lockout. See [Rate limits and lockout](#rate-limits-and-lockout) for which is which and how to retry. |
| 431 | none (not JSON) | Request Header Fields Too Large, from the API (request line plus headers over about 16 KiB) or a reverse proxy. Split the `client` list across several requests. |
| 500 | `internal` | Unexpected server error. Details are only in the server log (`docker compose logs analytics-api`). |
| 503 | `unavailable` | Database unreachable, or the query exceeded its time limit. Narrow the range, filter by room, or retry later. |

`414` and `431` are produced by the HTTP server or a proxy before the request
reaches the API, so their body is plain text (or a proxy's HTML page) rather
than the JSON shape above, and they carry no CORS headers: a browser app sees
them only as a network error. The same applies to a proxy's own errors, such
as `502` and `504`. Check `Content-Type` before parsing an error body, and
avoid these errors up front by keeping each encoded query string well under
8 KiB (at most 200 `client` values per request). The Metrics Visualizer budgets
about 6 KiB of encoded query and 200 room names per request, and on a `414` or
`431` it repeats the request with the room list split in half.

## Rate limits and lockout

Three different limits answer `429 too_many_requests`. Every `429` carries a
`Retry-After` header in whole seconds.

| Limit | Applies to | `Retry-After` | What to do |
| --- | --- | --- | --- |
| Rate limit | Requests with a valid token: about 10 per second with bursts up to 40, per token and client address. Requests without a valid token (missing, malformed, or wrong), `/health`, `/openapi.yaml`, and CORS preflights: a separate budget of the same size per client address. | Usually `1` | Wait, then retry the same request. |
| Requests in progress | At most 3 requests at once per token and client address. | Always `1` | Wait, then retry. Better: send one request at a time. |
| Failed-sign-in lockout | 10 failed sign-ins (`401` or `403` for the token) within 5 minutes block further **failing** requests from that address for 15 minutes; the block is logged once. Requests with a valid token are never blocked by it. | Up to `900` | Stop. This `429` means the token you send is missing or wrong; fix it before trying again. |

- People who share one token through the same reverse proxy share its budget,
  so give each person or app its own token.
- IPv6 clients are grouped by /64.
- Recommended retry behaviour: on a `429` with `Retry-After` of 60 seconds or
  less, wait that long and retry the same request, at most a few times. Treat
  a longer `Retry-After` as the lockout and stop. Retry `503` later with a
  growing delay. Do not retry `400`, `401`, `403`, `404`, `405`, `414`, or
  `431` unchanged. The Metrics Visualizer retries a `429` up to 3 times when
  `Retry-After` is 60 seconds or less and reports longer waits instead.
- PowerShell 7's `Invoke-RestMethod -MaximumRetryCount` retries every `4xx`
  and `5xx` response, including a wrong token and the lockout, so in scripts
  check the status code and `Retry-After` yourself instead.

## Build your own app

1. **Ask for a token.** Ask your server administrator to add a token for your
   app to `ANALYTICS_API_TOKEN` (one per app or person makes it easy to revoke).
   Keep it out of source control and out of URLs.
2. **Start with `/api/v1/info`** to learn the data coverage and the heartbeat
   retention, then `/api/v1/clients` to list rooms.
3. **Prefer `/api/v1/summary` for counts** (input popularity, button usage,
   off-reasons). It is one small request instead of thousands of events.
4. **Use `/api/v1/events` for timelines and durations** (system on time, device
   on hours, input time on screen, connection history). Pair `Started` with the
   next `Stopped` of the same `metric` in the same room. Video inputs are never
   `Stopped`: an input stays on screen until another input starts, the system
   powers off, or the processor reboots (`Initialize`).
5. **Use `/api/v1/heartbeats` for availability** (rooms offline, online %).
6. **Respect limits.** Page with `limit=5000`, send one request at a time,
   split long ranges (at most 400 days, or 92 days for hourly heartbeats),
   split long room lists (at most 200 names and well under 8 KiB of encoded
   query per request), follow the retry rules in
   [Rate limits and lockout](#rate-limits-and-lockout), and when `truncated` is
   `true` split the request by rooms or time and fetch again. Cache older
   results you have already fetched, but re-fetch the last 48 hours or more
   (see [Pagination](#pagination)) because devices upload buffered events late.
7. **Generate a client** if you like: point
   [OpenAPI Generator](https://openapi-generator.tech/) or your language's
   tooling at `/openapi.yaml`.
8. **From a browser** (including the web build of the Metrics Visualizer), add
   your app's exact origin to `ANALYTICS_CORS_ORIGINS`; otherwise the browser
   blocks every response. Never put a token into a public web page: use a
   sign-in proxy or keep the app on trusted staff machines.

Minimal Python example (standard library only):

```python
import json, os, time, urllib.error, urllib.parse, urllib.request

BASE = os.environ["AVSM_ANALYTICS_URL"]
HEADERS = {"Authorization": f"Bearer {os.environ['AVSM_ANALYTICS_TOKEN']}"}

def get(path, **params):
    query = urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(f"{BASE}{path}?{query}", headers=HEADERS)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as err:
            # Wait out short rate limits; a long Retry-After is the failed
            # sign-in lockout, so give up and check the token.
            retry_after = err.headers.get("Retry-After", "")
            wait = int(retry_after) if retry_after.isdigit() else 0
            if err.code != 429 or not 0 < wait <= 60 or attempt == 3:
                raise
            time.sleep(wait)

def all_events(**params):
    cursor = None
    while True:
        page = get("/api/v1/events", limit=5000, **params, **({"cursor": cursor} if cursor else {}))
        yield from page["events"]
        cursor = page["next_cursor"]
        if cursor is None:
            return

power_ons = sum(1 for e in all_events(metric="System - User", action="Started"))
print("System power-ons in the last 30 days:", power_ons)
```

## Database indexes and maintenance

Provisioning adds two partial indexes, built with
`CREATE INDEX CONCURRENTLY` so ingestion keeps running:

- `idx_metric_events_activity_ts` on `(event_timestamp, event_id)` for
  non-heartbeat rows (time-ordered event queries and pagination).
- `idx_metric_events_heartbeat_client_ts` on `(clientname, event_timestamp)`
  for heartbeat rows (online coverage).

If a build is interrupted (for example by `ANALYTICS_PROVISION_TIMEOUT` or a
restart), PostgreSQL leaves an invalid index behind; the next provisioning run
detects it, drops it concurrently, and rebuilds it. The indexes are ordinary
indexes of `metric_events`, so `maintenance.sh` (`VACUUM FULL`) rebuilds and
keeps them. They are created by this optional feature only; the ingest schema
does not depend on them, and disabling the API leaves them in place (they only
cost a little disk space and insert time). To remove them after disabling the
API for good (ingestion keeps running):

```bash
docker compose exec postgres psql -U metrics_user -d metrics -c 'DROP INDEX CONCURRENTLY IF EXISTS idx_metric_events_activity_ts;'
docker compose exec postgres psql -U metrics_user -d metrics -c 'DROP INDEX CONCURRENTLY IF EXISTS idx_metric_events_heartbeat_client_ts;'
```

Enabling the API again rebuilds them.

## Development and testing

```bash
cd Self_Hosted/analytics_api
gofmt -l .        # must print nothing
go vet ./...
go test ./...     # unit tests, no database needed (CI also runs them with -race)
go build -o analytics-api .
```

Database-backed tests (`db_integration_test.go`) run when
`ANALYTICS_TEST_DATABASE_URL` points at an **admin** connection to a disposable
database. They apply `../schema.sql`, provision `metrics_reader`, and prove it
cannot `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, create tables or temporary
tables, create large objects, `SET ROLE`, or read `source_ip`/`sort_key`, then
exercise every query and the pagination end to end.

`analytics_integration_test.sh` runs everything in throwaway containers on an
internal Docker network (CI runs it on every change):

```bash
bash Self_Hosted/analytics_api/analytics_integration_test.sh
```

It builds the image, provisions twice, checks that the server refuses to start
with the superuser role, probes the running API, runs the database-backed Go
tests, and verifies that the disable statement revokes the login.

`../compose_integration_test.sh` runs the real Compose files the way operators
do (default install, enable, disable, and restarting ingestion by container
ID). CI runs it before publishing either image.

Code layout: `main.go` (subcommands, HTTP server), `config.go` (environment
validation), `server.go` (security pipeline, CORS, auth, errors),
`handlers.go` (endpoints and parameter validation), `store.go` (read-only SQL
and the startup self-check), `provision.go` (role, grants, indexes),
`ratelimit.go`, `cursor.go`, and `openapi.yaml` (embedded into the binary).
Keep `openapi.yaml`, this README, and the handlers in sync when you change the
API; `TestOpenAPIDocumentsEveryRoute` catches missing routes.
