# Extron ECS Metrics Client

Extron ECS Python client module for sending AV metric events from to AV-System-Metrics.

The same module can also run on a workstation for basic testing.

## Requirements

- `metrics_client.py` copied into your Extron ControlScript project.
- An AV-System-Metrics ingest endpoint setup using a supported server or serverless configuration, as documented in the [AV-System-Metrics README](../README.md):
- A bearer token that matches the server configuration.
- A logger callable, such as an Extron `ProgramLog`-style function.

## Basic Usage

```python
from metrics_client import Metrics

metrics = Metrics(
    logger=logger,
    processor_name="sci100",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
)

# Example to track button action events
@event
def button_action(button, state):
    metrics.trace(f"Button {button} State {state}")

# Example to track system startup events
def startup():
    metrics.start("System")
    # <Code to turn on projector 1 here>
    metrics.start("Projector 1")

# Example to track microphone mute events
def mute_microphone(mic_number):
    # <Code to mute the microphone here>
    metrics.custom("Muted", f"Microphone {mic_number}")
```

For self-hosted deployments, include `/metrics` in the URI:

```python
metrics = Metrics(
    logger=logger,
    processor_name="sci100",
    uri="http://192.0.2.10:8080/metrics",
    bearer_token="change-me-long-random-token",
)
```

## GVE Piggybacking

*If you already use GlobalView Enterprise (GVE) for device status, you can modify the GVE module to send all status updates to AV-System-Metrics.* Feel free to reach out to the author or open an issue to get information about how to configure this in your environment.

## Methods

- `heartbeat(_timer=None, _count=None)` - records metric `Ok` with action `Heartbeat` for uptime monitoring. It accepts the two arguments supplied by an `extronlib.system.Timer` callback; both are optional so it can also be called directly.
- `trace(metric_name)` - records a point-in-time event with action `Trace`.
- `start(metric_name)` - records a time bound metric start with action `Started`.
- `stop(metric_name)` - records a time bound metric stop with action `Stopped`.
- `custom(action, metric_name)` - records a custom action.
- `flush()` - sends queued metrics immediately. You don't need to call this manually under normal operation, as the client automatically flushes on `flush_interval` or when the cache reaches `batch_size`.

## Optional Settings

```python
metrics = Metrics(
    logger=logger,
    processor_name="sci100",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
    batch_size=20,
    flush_interval=10,
    max_cache_size=250,
    failure_drop_message_threshold=100,
    failure_drop_time_threshold=300,
    request_timeout=10.0,
    send_heartbeat=True,
)
```

All values shown above are the defaults:

- `batch_size` - maximum number of queued metrics sent in one request. Must be at least `1`. The current ingest services accept up to 25 messages per request, so keep this at `25` or lower.
- `flush_interval` - seconds to wait before sending a partially filled batch. Must be greater than `0`.
- `max_cache_size` - number of queued metrics retained after sustained send failures. Must be greater than or equal to `batch_size`. The cache is allowed to temporarily exceed this value until a failure threshold is reached.
- `failure_drop_message_threshold` - failed-message count after which the oldest cached metrics may be discarded to enforce `max_cache_size`. Must be at least `1`.
- `failure_drop_time_threshold` - seconds after the first send failure after which the oldest cached metrics may be discarded to enforce `max_cache_size`. Must be greater than `0`.
- `request_timeout` - HTTP request timeout in seconds. Must be greater than `0`.
- `send_heartbeat` - when `True`, calls to `heartbeat()` queue heartbeat metrics; when `False`, they do nothing.

The client batches metrics as `{"messages": [...]}`. A failed batch is queued again and retried; permanent HTTP client errors other than rate limiting are dropped.

## Workstation Test

Edit the `uri` and `bearer` values at the bottom of `metrics_client.py`, then run:

```sh
python metrics_client.py
```

The script sends a few test metrics and waits long enough for the flush timer to run.
