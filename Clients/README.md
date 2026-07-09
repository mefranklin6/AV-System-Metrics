# Client Implementation Guide

Use the client module that matches your AV platform, import it into your existing program, and add metric calls around the logic you already have.

See each platform folder for setup instructions and example code.

## Basic Flow

1. Import or include the metrics client module in your control program.
2. Create a metrics client with your client name, endpoint URL, and bearer token.
3. Add calls to the public interface wherever your existing program changes state or detects an event.

## Public Interface

Clients expose these methods:

- `start(metric_name)` - records `Started`.
- `stop(metric_name)` - records `Stopped`.
- `connected(metric_name)` - records `Connected`.
- `disconnected(metric_name)` - records `Disconnected`.
- `custom(action, metric_name)` - records a custom action.
- `trace(metric_name)` - records a point-in-time trace event.
- `flush()` - sends queued metrics immediately.

The exact case and naming of the methods follow the language they were written in (such as `PascalCase` for C#, `snake_case` for Python).

## What to Track

- Add `start` and `stop` calls when turning devices on or off, including when restarting the processor.
- Add `connected` and `disconnected` calls to device monitors that would otherwise alert you or report to a central monitoring server.
- Add `custom` calls for state changes that need a specific action, such as `custom("Muted", "Microphone 1")`.
- Consider adding `trace` calls for user interaction events, such as button presses.
