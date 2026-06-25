# Client Module Developer Guide

Use this guide when writing a client module for another AV control platform, scripting environment, or programming language.

The included [Extron ECS Python client](/Clients/Extron%20ECS/metrics_client.py) is the reference implementation. The server-side contract comes from [AWS_Serverless/lambda_function.py](/AWS_Serverless/lambda_function.py) and [Self_Hosted/main.go](/Self_Hosted/main.go).

## Network Contract

All metrics are sent as authenticated JSON over HTTP.

- AWS Serverless: `POST` to the Lambda Function URL.
- Self-hosted: `POST /metrics`.
- Required header: `Authorization: Bearer <token>`.
- Required header: `Content-Type: application/json`.
- Success response: HTTP `201` with `{"ok": true, "count": <number>}`.

Current service limits:

- Maximum request body size: 10 KB.
- Maximum messages per request: 25.
- Maximum length for `clientname`, `metric`, and `action`: 128 characters each.
- `timestamp` must be an ISO 8601 string. UTC is recommended; the self-hosted service stores it as a PostgreSQL `TIMESTAMPTZ`.
- Empty message lists are rejected.

## Payload Shapes

The ingestion backends accept three JSON layouts. A client module can implement whichever layout fits the platform, but the wrapped list is recommended for batching.

Single message:

```json
{
  "clientname": "boardroom-cp4",
  "timestamp": "2026-06-23T16:20:00Z",
  "metric": "Display 1 Power",
  "action": "Started"
}
```

List of messages:

```json
[
  {
    "clientname": "boardroom-cp4",
    "timestamp": "2026-06-23T16:20:00Z",
    "metric": "System Power",
    "action": "Started"
  },
  {
    "clientname": "boardroom-cp4",
    "timestamp": "2026-06-23T16:21:05Z",
    "metric": "Source Select: HDMI 1",
    "action": "Trace"
  }
]
```

Wrapped list:

```json
{
  "messages": [
    {
      "clientname": "boardroom-cp4",
      "timestamp": "2026-06-23T16:22:12Z",
      "metric": "Microphone 1 Mute",
      "action": "Stopped"
    }
  ]
}
```

## Required Message Fields

| Field | Type | Required | Limit | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `clientname` | string | yes | 128 chars | Unique sender identifier, such as a processor, room, device, or workstation. |
| `timestamp` | string | yes | ISO 8601 | UTC is recommended. The self-hosted service stores it as `TIMESTAMPTZ`. |
| `metric` | string | yes | 128 chars | The thing being measured or tracked. |
| `action` | string | yes | 128 chars | The event or state change. Standard client actions are `Started`, `Stopped`, and `Trace`. |

## Client Methods

To match the supported client API, expose these public methods. Use the naming conventions of your target platform if exact names are not practical, but keep a direct mapping to these actions.

- `start(metric_name)` - queues a message with `action` set to `Started`.
- `stop(metric_name)` - queues a message with `action` set to `Stopped`.
- `trace(metric_name)` - queues a message with `action` set to `Trace`.
- `custom(action, metric_name)` - queues a message using the provided action.
- `flush()` - sends queued messages immediately.

Conceptual template:

```text
class Metrics:
    constructor(client_name, endpoint_uri, bearer_token, options)

    start(metric_name)
    stop(metric_name)
    trace(metric_name)
    custom(action, metric_name)
    flush()
```

The module should also accept these settings during construction or initialization:

- Client name, written to the `clientname` field.
- Endpoint URI.
- Bearer token.
- Optional logger or logging callback.
- Optional batch size, no more than 25.
- Optional flush interval.
- Optional maximum local cache size for retry/backlog protection.

## Expected Client Behavior

A production client module should avoid blocking AV control logic while sending telemetry.

- Generate timestamps at the moment the event is recorded.
- Prefer UTC timestamps, such as `2026-06-23T16:20:00Z` or `2026-06-23T16:20:00+00:00`.
- Queue metrics locally instead of blocking control-system logic on every event.
- Flush immediately when the queue reaches the configured batch size.
- Use a timer-based fallback flush so low-volume events are eventually sent.
- Send batches as `{"messages": [...]}` when batching is supported by the platform.
- Keep batches at or below 25 messages. The reference client defaults to 20.
- Validate successful responses by requiring `ok` to be `true` and `count` to match the number of messages sent.
- Retry transient failures, including network failures, HTTP `429`, and HTTP `5xx` responses.
- Treat HTTP `400`, `401`, `403`, `405`, and `413` responses as configuration or payload errors rather than endlessly retrying them.
- Requeue failed transient batches ahead of newer metrics to preserve order.
- Cap the local cache so a long outage cannot exhaust memory.
- Log send failures clearly enough for field troubleshooting.

## Reference Client Notes

The included Python client records messages with these action mappings:

- `start("Display")` sends `{"metric": "Display", "action": "Started"}`.
- `stop("Display")` sends `{"metric": "Display", "action": "Stopped"}`.
- `trace("Button Press")` sends `{"metric": "Button Press", "action": "Trace"}`.
- `custom("Muted", "Microphone 1")` sends `{"metric": "Microphone 1", "action": "Muted"}`.

The Python client supports `aws_lambda` and `self-hosted` URI types. `aws_api_gateway` is reserved in the code but currently raises `NotImplementedError`.

For self-hosted deployments, point the URI at the `/metrics` endpoint, for example:

```text
http://127.0.0.1:8080/metrics
```

For AWS Serverless deployments, point the URI at the Lambda Function URL.
