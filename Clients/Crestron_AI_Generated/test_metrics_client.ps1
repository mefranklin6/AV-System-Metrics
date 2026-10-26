$ErrorActionPreference = 'Stop'
$clientSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'MetricsClient.cs') -Raw
$testSource = @'
public static class FailureLoggingChecks
{
    private static System.Reflection.BindingFlags Flags =
        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
    private static object Read(object client, string name)
    { return client.GetType().GetField(name, Flags).GetValue(client); }
    private static void Set(object client, string name, object value)
    { client.GetType().GetField(name, Flags).SetValue(client, value); }
    private static void Call(object client, string name, params object[] args)
    { client.GetType().GetMethod(name, Flags).Invoke(client, args); }
    private static void Check(bool condition, string message)
    { if (!condition) throw new System.Exception(message); }

    public static void Run()
    {
        var logs = new System.Collections.Generic.List<string>();
        using (var client = new AVSystemMetrics.Crestron.Metrics(
            (message, level) => logs.Add(level + ":" + message),
            "test", "https://example.invalid/metrics", "token", 2, 10, 3, 4, 300))
        {
            Check(logs.Exists(s => s.Contains("info:Metrics queue is memory-only")), "Missing startup log");
            var cache = (System.Collections.IList)Read(client, "metricCache");
            var batch = (System.Collections.IList)System.Activator.CreateInstance(cache.GetType());
            var messageType = cache.GetType().GetGenericArguments()[0];
            batch.Add(System.Activator.CreateInstance(messageType, "test", "2026-01-01T00:00:00Z", "one", "Trace"));
            batch.Add(System.Activator.CreateInstance(messageType, "test", "2026-01-01T00:00:01Z", "two", "Trace"));
            Call(client, "HandleHttpFailure", 503, batch, "unavailable");
            Check(cache.Count == 2, "Server error lost batch");
            Check(logs.Exists(s => s.Contains("warning:Requeued 2 metrics ahead of newer events")), "Missing retry log");
            cache.Clear();
            Call(client, "ResetFailureState", 2);
            Check(logs.Exists(s => s.Contains("Acknowledged 2 metrics; 0 metrics remain queued")), "Missing recovery log");
            Check((int)Read(client, "failedMessageCount") == 0, "Failure count not reset");
            Check(Read(client, "firstFailureUtc") == null, "Failure time not reset");
            Call(client, "ResetFailureState", 2);
            Check(logs.FindAll(s => s.Contains("delivery recovered")).Count == 1, "Duplicate recovery log");
            foreach (int elapsed in new int[] { 1, 301 })
            {
                cache.Clear(); logs.Clear();
                Set(client, "failedMessageCount", 0); Set(client, "firstFailureUtc", null);
                cache.Add(batch[0]); cache.Add(batch[1]); cache.Add(batch[0]); cache.Add(batch[1]);
                Call(client, "TrimCacheIfAllowedLocked");
                Check(cache.Count == 4, "Trimmed before threshold");
                Check(logs.Exists(s => s.Contains("dropping is not allowed yet")), "Missing overflow log");
                cache.Clear(); cache.Add(batch[0]); cache.Add(batch[1]);
                Set(client, "failedMessageCount", elapsed == 1 ? 2 : 0);
                Set(client, "firstFailureUtc", System.DateTime.UtcNow.AddSeconds(-elapsed));
                Call(client, "RecordSendFailure", batch);
                Check(cache.Count == 3, "Threshold did not trim oldest metric");
                Check(logs.Exists(s => s.Contains("Dropping 1 oldest cached metrics")), "Missing drop log");
                Check(logs.Exists(s => s.Contains("retained: 3 metrics")), "Missing retained count");
            }
            cache.Clear(); logs.Clear();
            Call(client, "HandleHttpFailure", 401, batch, "bad token");
            Check(cache.Count == 0, "Permanent error was requeued");
            Check(logs.Exists(s => s.Contains("Permanent client error 401. Dropping 2 metrics")), "Missing permanent error log");
            Call(client, "HandleHttpFailure", 429, batch, "limited");
            Check(cache.Count == 2, "Rate limited batch lost");
        }
        using (var client = new AVSystemMetrics.Crestron.Metrics(
            (message, level) => { throw new System.Exception("logger unavailable"); },
            "test", "https://example.invalid/metrics", "token"))
        { Call(client, "Log", "test", "error"); }
    }
}
'@
Add-Type -TypeDefinition ($clientSource + [Environment]::NewLine + $testSource)
[FailureLoggingChecks]::Run()
Write-Output 'Crestron offline logging checks passed'
