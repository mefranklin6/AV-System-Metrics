# AMX MUSE Python Metrics Client

Python client module for sending AV metric events from an AMX MUSE project to AV-System-Metrics.

This initial AMX-oriented implementation uses only the Python standard library: `urllib`, `threading`, `json`, and `datetime`. It mirrors the Extron ECS client behavior with local queueing, background sends, timer-based flushing, transient retry handling, and the same `start`, `stop`, `trace`, `custom`, and `flush` API shape.

## IMPORTANT

**The AMX MUSE module and this README are AI written. The original developer of AV-System-Metrics (mefranklin6) does not have AMX hardware or AMX training so this system may or may not work without platform-specific adjustment.**

Having said that, the workstation test at the bottom has been tested and is functional.

Testing, feedback, fixes, and improvements by people who know AMX MUSE are encouraged.

## Requirements

- `metrics_client.py` copied into your AMX MUSE Python project.
- An AV-System-Metrics ingest endpoint setup using a supported server or serverless configuration, as documented in the [AV-System-Metrics README](../README.md):
- A bearer token that matches the server configuration.
- A logger callable that accepts `(message, level)`, or `None` to use the included console logger.

## Basic Usage

```python
from metrics_client import Metrics


def log_metric_client(message, level="info"):
    # Replace this with your normal AMX MUSE logging call if available.
    print("[{}] {}".format(level.upper(), message))


metrics = Metrics(
    logger=log_metric_client,
    processor_name="boardroom-muse",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
)

metrics.trace("System Initialized")
```

Example metric calls from your MUSE callbacks or control logic:

```python
metrics.trace("Touchpanel Button Press")
metrics.start("Display Power")
metrics.stop("Display Power")
metrics.custom("Muted", "Microphone 1")
```

For self-hosted deployments, include `/metrics` in the URI:

```python
metrics = Metrics(
    logger=log_metric_client,
    processor_name="boardroom-muse",
    uri="http://192.0.2.10:8080/metrics",
    bearer_token="change-me-long-random-token",
)
```

## Methods

- `trace(metric_name)` - records a point-in-time event with action `Trace`.
- `start(metric_name)` - records a time bound metric start with action `Started`.
- `stop(metric_name)` - records a time bound metric stop with action `Stopped`.
- `custom(action, metric_name)` - records a custom action.
- `flush()` - starts a background send for queued metrics. You normally do not need to call this manually because the client automatically flushes on `flush_interval` or when the queue reaches `batch_size`.
- `close()` - cancels future timer flushes. Already-running background sends are allowed to finish.

## Optional Settings

```python
metrics = Metrics(
    logger=log_metric_client,
    processor_name="boardroom-muse",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
    batch_size=20,
    flush_interval=10,
    max_cache_size=250,
    failure_drop_message_threshold=100,
    failure_drop_time_threshold=300,
    request_timeout=10.0,
)
```

The client batches metrics as `{"messages": [...]}`. The current ingest services accept up to 25 messages per request, so `batch_size` must be between 1 and 25.

Metric `clientname`, `metric`, and `action` fields must be non-empty strings of 128 characters or fewer to match the backend validation rules.

## Workstation Test

Edit the `uri` and `bearer` values at the bottom of `metrics_client.py`, then run:

```sh
python metrics_client.py
```

The script queues a few test metrics and waits long enough for the flush timer to run.

## Notes

If the AMX MUSE Python runtime has HTTPS/TLS or outbound internet restrictions, use the self-hosted endpoint on a trusted network or place the service behind infrastructure that the controller can reach reliably.
