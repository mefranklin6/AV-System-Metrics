# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

AV control processors (Extron, Crestron, AMX, Q-SYS) send usage events (`clientname`, `timestamp`, `metric`, `action`) as authenticated JSON over HTTP to an ingest backend that stores them in a database. The repo has several independent components but no top-level build. Each component is built and tested on its own:

| Path | What it is |
| :--- | :--- |
| `Self_Hosted/` | Main backend: Go ingest service (`main.go`) + PostgreSQL, deployed with Docker Compose, plus Bash ops scripts (`update.sh`, `maintenance.sh`, `lifecycle-events.sh`) |
| `AWS_Serverless/` | Alternative backend: single-file Python Lambda (`lambda_function.py`) writing to DynamoDB; deployed by pasting into the AWS console |
| `Clients/` | Per-platform client modules that run on control processors. `Clients/Extron ECS/metrics_client.py` is the reference implementation; the others are AI-generated and not field-tested |
| `Self_Hosted_OLD/` | Deprecated adapter that keeps the archived ExtronDatabaseConnector HTTP contract (no auth header) but writes the same `metric_events` schema. Leave it alone unless the task is about it |
| `Self_Hosted/analytics_api/` | Optional, read-only Analytics API: a separate Go module and image that serves `metric_events` to the visualizer and third-party apps (OpenAPI 3.1 spec in `openapi.yaml`). Off by default (`ENABLE_ANALYTICS_API` in `.env`) |
| `visualizer_app/metrics_visualizer/` | Flutter "Metrics Visualizer" for AV managers: loads a CSV/psql export or reads from the Analytics API, then computes usage, issue flags and forecasts on the client |

## Commands

Self-hosted Go service (run from `Self_Hosted/`):

```sh
go test ./...                                  # all tests
go test -run TestName ./...                    # single test
go vet ./...
docker build -t metrics-ingest .               # image (Go 1.27 alpine -> distroless static)
```

Analytics API (run from `Self_Hosted/analytics_api/`; it is its own Go module, so `go test` in `Self_Hosted/` does not cover it):

```sh
gofmt -l . && go vet ./... && go test ./...
bash ./Self_Hosted/analytics_api/analytics_integration_test.sh   # from repo root; needs Docker
```

`db_integration_test.go` is skipped unless `ANALYTICS_TEST_DATABASE_URL` points at an admin connection to a throwaway Postgres.

Self-hosted shell-script tests (run from repo root; need Bash, and on Windows Git Bash). CI runs all of them:

```sh
bash ./Self_Hosted/update_test.sh
bash ./Self_Hosted/maintenance_test.sh
bash ./Self_Hosted/maintenance_integration_test.sh   # needs Docker; starts a throwaway postgres:18-alpine
```

AWS Lambda tests (run from the **repo root**, because the test imports `AWS_Serverless.lambda_function` and stubs `boto3`):

```sh
python -m unittest AWS_Serverless.test_lambda_function
python -m unittest AWS_Serverless.test_lambda_function.ConfigTests.<test_name>
```

Python client tests (run from **inside** the client directory, because they `import metrics_client`; offline, no hardware needed):

```sh
cd "Clients/Extron ECS" && python -m unittest test_metrics_client
cd Clients/AMX_AI_Generated && python -m unittest test_metrics_client
```

Crestron client check (compiles `MetricsClient.cs` in-process via PowerShell):

```powershell
pwsh Clients/Crestron_AI_Generated/test_metrics_client.ps1
```

Flutter visualizer (from `visualizer_app/metrics_visualizer/`):

```sh
flutter pub get
flutter analyze
flutter test                                   # unit, widget and accessibility-guideline tests
flutter test test/analytics                    # one directory
flutter build web --release                    # CI builds this; it catches dart2js-only errors (e.g. int64 literals) that VM tests miss
flutter run -d windows                         # or -d chrome
```

## Architecture and cross-cutting contracts

### The ingest contract is duplicated, so keep the copies in sync

The same request contract is implemented in `Self_Hosted/main.go` and `AWS_Serverless/lambda_function.py`, documented in `Clients/Developer Guide/README.md`, and relied on by every client:

- Three body shapes: a single object, a bare list, or `{"messages": [...]}`.
- Limits: 10 KB body, 25 messages per request, 128 characters each for `clientname`/`metric`/`action`. All four fields are required.
- `Authorization: Bearer <token>` (constant-time compare), optional `ALLOWED_NET` CIDR allow-list.
- Success is `201 {"ok": true, "count": N}`. Validation failures return `400` with a per-index `errors` array, and the whole batch is rejected.
- Clients retry network errors, `429` and `5xx`, and drop batches on `400/401/403/405/413`. They also check that `count` matches the number of messages sent.

A change to limits, payload shape, or status codes needs to be made in both backends, the Developer Guide, and the READMEs.

### Data model

`sort_key` is `<UTC timestamp with nanoseconds>Z#<uuid v4>`. This is the DynamoDB sort key (`sk`, partition key `clientname`), and the self-hosted schema keeps the same column so the two backends produce comparable data. Standard actions are `Started`, `Stopped`, `Trace`, `Connected`, `Disconnected`, and `Heartbeat` (whose `metric` is `Ok`); `custom()` allows any other action. Production data mixes button traces like `Btn_Volume_Up Pressed`/`Trace` with device state like `Projector_1`/`Started`, plus `Program Audio Volume`/`Level 31 (Device -18.8)`.

### Self-hosted service internals

- `schema.sql` is embedded with `//go:embed` and re-applied on every startup, so it must stay idempotent (`IF NOT EXISTS`, guarded `DO $$` migrations). It is also loaded directly by `maintenance_integration_test.sh`.
- The heartbeat purge runs as a goroutine at startup and then every 24h. It deletes `action = 'Heartbeat'` rows older than `HEARTBEAT_RETENTION_DAYS` in committed batches, using the `id = ANY(ARRAY(...))` form on purpose; the comment in `main.go` explains the query-plan reason. Each pass records its state in the single-row `heartbeat_purge_status` table. `maintenance.sh` refuses to run unless that row shows a recent successful pass, and a crash that leaves `running` deliberately blocks maintenance.
- The service refuses to start if `BEARER_TOKEN` or the password in `DATABASE_URL` still has the `.env.example` placeholder value. The Compose `postgres` entrypoint and the Lambda make the same check.
- `metrics-ingest healthcheck` is a subcommand used by the Docker healthcheck, because the distroless image has no curl.

### Self-hosted deployment and ops scripts

- Operators download the Compose files, `.env.example`, and the scripts straight from `raw.githubusercontent.com/.../main/Self_Hosted/`, and the GHCR image is published on every push touching `Self_Hosted/**` (tags `main`, `latest`, `sha-<commit>`). **Anything merged to `main` under `Self_Hosted/` reaches production installs on their next update.**
- `docker-compose.yml` is always combined with either `docker-compose.database-expose-false.yml` (a no-op) or `-true.yml` (publishes the Postgres port), selected through `COMPOSE_FILE` in `.env`.
- `update.sh` does a three-way merge of `.env` using the previously installed `.env.example` as the base. New settings must be added to `.env.example` to reach existing installs, and renaming or removing a key shows up as "retired". It validates the config before touching live files, refuses Postgres major-version changes, offers a `pg_dump` backup to `.avsm-backups/` or to a workstation over SCP, and never runs `down -v`.
- `lifecycle-events.sh` is sourced by both `update.sh` and `maintenance.sh`. It records their start and outcome as `Trace` rows with `clientname = 'AVSM-System'` by running `psql` inside the postgres container.
- The Compose stack is hardened on purpose: non-root users, `cap_drop: ALL`, read-only root filesystem, tmpfs, resource limits, and an internal-only `db_net`. Keep these settings when editing it.
- The shell tests copy the real scripts into temp dirs and put mock `docker` binaries on `PATH`. Update the mocks when a script starts calling Docker in a new way.

### Clients

Every client exposes the same API: `heartbeat()`, `start()`, `stop()`, `trace()`, `connected()`, `disconnected()`, `custom(action, metric)`, `flush()`. Each one queues events, flushes on batch size (default 20, max 25) or on a timer, requeues failed batches ahead of newer events, and caps its cache. The Extron client falls back to mock `extronlib` classes when that library isn't installed, so it also runs as a plain Python 3 client on a workstation. A client never needs to know which backend it is talking to; only the endpoint URI changes.

### Analytics API and visualizer

- The Analytics API is optional and fully separate from ingest. `COMPOSE_FILE` also includes `docker-compose.analytics-${ENABLE_ANALYTICS_API}.yml`. The `-true` overlay runs a one-shot `analytics-db-provision` (the image's `provision` subcommand; it is the only analytics container that gets owner credentials) and then `analytics-api`. The `-false` overlay runs a one-shot that sets `metrics_reader` to `NOLOGIN` and ends its sessions, so turning the feature off revokes database access.
- Provisioning is idempotent. It creates the `metrics_reader` role with column-level `SELECT` that excludes `source_ip` and `sort_key`, read-only session defaults and a statement timeout, and builds two partial indexes `CONCURRENTLY`. The indexes live in provisioning rather than `schema.sql` because the ingest service applies the schema under a short startup timeout.
- At startup the API checks that its role cannot write and refuses to run if it can. Every query runs in a `READ ONLY` transaction. Requests need `Authorization: Bearer` with one of the comma-separated `ANALYTICS_API_TOKEN` values (at least 32 characters each).
- A change to endpoints, parameters or error codes must be made in `handlers.go`/`store.go`, `openapi.yaml`, `analytics_api/README.md`, and the Flutter client `lib/data/api_client.dart`.
- `update.sh` duplicates the analytics secret checks from `config.go`/`provision.go`, and `analytics_integration_test.sh` repeats the `NOLOGIN` statement from the `-false` overlay. Keep those copies in sync.
- Visualizer layout:
  - `lib/data`: models, the CSV/psql importer, the API client, demo data.
  - `lib/analytics`: a pure-Dart engine with no Flutter imports; it runs in an isolate. Its `README.md` documents session semantics.
  - `lib/state`: `ChangeNotifier`s.
  - `lib/ui`: theme, shared accessible widgets and screens.
- Data semantics come from the Extron ControlScript template:
  - Inputs are `Started` with a source key and never `Stopped`.
  - `System - User`, `System - Restore` and `System - GVE` `Started` begin a system session; any `System - *` `Stopped` ends it.
  - `Initialize` is a processor boot.
  - `AVSM-System` is excluded from analysis.
- Accessibility is a release requirement: target WCAG 2.2 AA, VPAT and higher-ed ITPR. Every chart needs a text summary and a table view. Every animation must go through the app's motion settings, which honor reduce motion. Screens are tested with `meetsGuideline` at 200% text and narrow widths. `ACCESSIBILITY.md` is the ACR/VPAT basis, so update it when behavior changes.
