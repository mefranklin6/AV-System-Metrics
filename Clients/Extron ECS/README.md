# Extron ECS Metrics Client

Extron ECS Python client module for sending AV metric events from to AV-System-Metrics.

The same module can also run on a workstation for basic testing.

## Requirements

- `metrics_client.py` copied into your Extron ControlScript project.
- An AV-System-Metrics ingest endpoint:
  - AWS Lambda Function URL, using `uri_type="aws_lambda"`.
  - Self-hosted `/metrics` endpoint, using `uri_type="self-hosted"`.
- A bearer token that matches the server configuration.
- A logger callable, such as an Extron `ProgramLog`-style function.

## Basic Usage

```python
from metrics_client import Metrics

metrics = Metrics(
    logger=logger,
    processor_name="boardroom-cp4",
    uri_type="aws_lambda",
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
    processor_name="boardroom-cp4",
    uri_type="self-hosted",
    uri="http://192.0.2.10:8080/metrics",
    bearer_token="change-me-long-random-token",
)
```

## Methods

- `trace(metric_name)` - records a point-in-time event with action `Trace`.
- `start(metric_name)` - records a time bound metric start with action `Started`.
- `stop(metric_name)` - records a time bound metric stop with action `Stopped`.
- `custom(action, metric_name)` - records a custom action.
- `flush()` - sends queued metrics immediately. You don't need to call this manually under normal operation, as the client automatically flushes on `flush_interval` or when the cache reaches the `max_cache_size` limit.

## Optional Settings

```python
metrics = Metrics(
    logger=logger,
    processor_name="boardroom-cp4",
    uri_type="aws_lambda",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
)
```

The client batches metrics as `{"messages": [...]}`. The current ingest services accept up to 25 messages per request, so keep `batch_size` at 25 or lower.

## Workstation Test

Edit the `uri` and `bearer` values at the bottom of `metrics_client.py`, then run:

```sh
python metrics_client.py
```

The script sends a few test metrics and waits long enough for the flush timer to run.
