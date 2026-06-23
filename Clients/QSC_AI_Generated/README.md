# QSC Q-SYS Lua Metrics Client

Q-SYS Lua client module for sending AV metric events from a Q-SYS Core or Q-SYS Designer control script to AV-System-Metrics.

This is an initial Q-SYS-oriented implementation. It uses Q-SYS `HttpClient.Upload`, `Timer.CallAfter`, and `rapidjson` for nonblocking batched HTTP sends.

## IMPORTANT

**The Q-SYS module and this readme are AI-written. The original developer of AV-System-Metrics (mefranklin6) does not have Q-SYS hardware to validate, so this system may or may not work in your environment.**

Testing, feedback, fixes, and improvements by people who know Q-SYS are encouraged.

## Requirements

- `metrics_client.lua` added to your Q-SYS design as a Lua Module named `metrics_client`.
- A Q-SYS Control Script or Text Controller that can `require("metrics_client")`.
- An AV-System-Metrics ingest endpoint:
  - AWS Lambda Function URL, using `uri_type = "aws_lambda"`.
  - Self-hosted `/metrics` endpoint, using `uri_type = "self-hosted"`.
- A bearer token that matches the server configuration.
- Outbound HTTP or HTTPS access from the Q-SYS Core to the ingest endpoint.

`aws_api_gateway` is listed for future compatibility but is not implemented yet.

## Basic Usage

```lua
local Metrics = require("metrics_client")

metrics = Metrics.new({
    logger = function(message, level)
        print(string.format("%s: %s", string.upper(level or "info"), tostring(message)))
    end,
    processor_name = "boardroom-qsys-core",
    uri_type = "aws_lambda",
    uri = "https://example.lambda-url.us-west-1.on.aws/",
    bearer_token = "change-me-long-random-token"
})

metrics:trace("System Initialized")
```

The settings object accepts `processor_name` or `client_name` for the value written to the `clientname` metric field. Extron-style positional construction is also supported: `Metrics.new(logger, processor_name, uri_type, uri, bearer_token)`.

Example metric calls:

```lua
metrics:trace("Touchpanel Button Press")
metrics:start("Display Power")
metrics:stop("Display Power")
metrics:custom("Muted", "Microphone 1")
```

For self-hosted deployments, include `/metrics` in the URI:

```lua
metrics = Metrics.new({
    processor_name = "boardroom-qsys-core",
    uri_type = "self-hosted",
    uri = "http://192.0.2.10:8080/metrics",
    bearer_token = "change-me-long-random-token"
})
```

## Control Example

```lua
Controls.PowerOn.EventHandler = function(control)
    if control.Boolean then
        metrics:start("System")
    end
end

Controls.SourceHDMI1.EventHandler = function(control)
    if control.Boolean then
        metrics:trace("Source Select: HDMI 1")
    end
end

Controls.Mic1Mute.EventHandler = function(control)
    metrics:custom(control.Boolean and "Muted" or "Unmuted", "Microphone 1")
end
```

Keep a reference to the metrics client for the life of the script. The examples use the global `metrics` variable for that reason.

## Methods

- `trace(metric_name)` - records a point-in-time event with action `Trace`.
- `start(metric_name)` - records a time-bound metric start with action `Started`.
- `stop(metric_name)` - records a time-bound metric stop with action `Stopped`.
- `custom(action, metric_name)` - records a custom action.
- `flush()` - sends queued metrics immediately. You normally do not need to call this manually because the client automatically flushes on `flush_interval` or when the queue reaches `batch_size`.

PascalCase aliases are also available for Q-SYS scripts that prefer them: `Trace`, `Start`, `Stop`, `Custom`, and `Flush`.

## Optional Settings

```lua
metrics = Metrics.new({
    processor_name = "boardroom-qsys-core",
    uri_type = "aws_lambda",
    uri = "https://example.lambda-url.us-west-1.on.aws/",
    bearer_token = "change-me-long-random-token",
    batch_size = 20,
    flush_interval = 10,
    max_cache_size = 250,
    failure_drop_message_threshold = 100,
    failure_drop_time_threshold = 300,
    request_timeout = 10
})
```

The client batches metrics as `{"messages": [...]}`. The current ingest services accept up to 25 messages per request, so `batch_size` must be between 1 and 25.

## Notes

- Timestamps are generated when each metric is queued and are formatted as UTC ISO 8601 strings when `os.date("!...")` is available.
- Transient failures, HTTP `429`, and HTTP `5xx` responses are retried by requeueing the failed batch ahead of newer metrics.
- HTTP `4xx` responses other than `429` are treated as configuration or payload errors and are dropped after logging.
- If HTTPS/TLS support or firewall policy prevents the Q-SYS Core from reaching the AWS Lambda URL, use the self-hosted endpoint on a trusted network or place the service behind infrastructure the Core can reach reliably.
