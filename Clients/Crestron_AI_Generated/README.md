# Crestron C# Metrics Client

C# client module for sending AV metric events from a Crestron program to AV-System-Metrics.

This is an initial Crestron-oriented implementation. It uses `HttpWebRequest`, background sends, timer-based flushing, and no external JSON package.

## IMPORTANT
**The Crestron module and this readme is AI written. The origional developer of AV-System-Metrics (mefranklin6) does not have access to Crestron equipment and has not taken Crestron training, so this sytem may or may not work**

Testing, feedback, fixes, and improvements by people who know Crestron are encouraged!

## Requirements

- `MetricsClient.cs` copied into your Crestron C# project.
- An AV-System-Metrics ingest endpoint setup using a supported server or serverless configuration, as documented in the [AV-System-Metrics README](../README.md)
- A bearer token that matches the server configuration.
- A logger callback such as `Action<string, string>`.

## Basic Usage

```csharp
using AVSystemMetrics.Crestron;

private Metrics metrics;

public void InitializeSystem()
{
    metrics = new Metrics(
        LogMetricClient,
        "boardroom-cp4",
        "https://example.lambda-url.us-west-1.on.aws/",
        "change-me-long-random-token");

    metrics.Trace("System Initialized");
}

private void LogMetricClient(string message, string level)
{
    // Replace with your normal Crestron logging call.
}
```

Example metric calls:

```csharp
metrics.Trace("Touchpanel Button Press");
metrics.Start("Display Power");
metrics.Stop("Display Power");
metrics.Custom("Muted", "Microphone 1");
```

For self-hosted deployments, include `/metrics` in the URI:

```csharp
metrics = new Metrics(
    LogMetricClient,
    "boardroom-cp4",
    "http://192.0.2.10:8080/metrics",
    "change-me-long-random-token");
```

## Methods

- `Trace(metricName)` - records a point-in-time event with action `Trace`.
- `Start(metricName)` - records a time bound metric start with action `Started`.
- `Stop(metricName)` - records a time bound metric stop with action `Stopped`.
- `Custom(action, metricName)` - records a custom action.
- `Flush()` - sends queued metrics immediately. You normally do not need to call this manually because the client automatically flushes on `flushIntervalSeconds` or when the queue reaches `batchSize`.

## Optional Settings

```csharp
metrics = new Metrics(
    LogMetricClient,
    "boardroom-cp4",
    "https://example.lambda-url.us-west-1.on.aws/",
    "change-me-long-random-token",
    20,
    10,
    250,
    100,
    300);
```

The client batches metrics as `{"messages": [...]}`. The current ingest services accept up to 25 messages per request, so `batchSize` must be between 1 and 25.

## Notes

If your Crestron environment has limited HTTPS/TLS support, use the self-hosted endpoint on a trusted network or place the service behind infrastructure that your processor can reach reliably.
