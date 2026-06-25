#pragma warning disable SYSLIB0014

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace AVSystemMetrics.Crestron
{
    /// <summary>
    /// Client for sending batched AV-System-Metrics events from a Crestron C# program.
    /// </summary>
    public sealed class Metrics : IDisposable
    {
        private const int MaxBatchSize = 25;

        private readonly object syncRoot = new object();
        private readonly Action<string, string> logger;
        private readonly string processorName;
        private readonly string uriType;
        private readonly string uri;
        private readonly string bearerToken;
        private readonly int batchSize;
        private readonly int flushIntervalMs;
        private readonly int maxCacheSize;
        private readonly int failureDropMessageThreshold;
        private readonly int failureDropTimeThresholdSeconds;
        private readonly List<MetricMessage> metricCache;

        private Timer flushTimer;
        private bool flushScheduled;
        private bool sending;
        private int failedMessageCount;
        private DateTime? firstFailureUtc;
        private bool disposed;

        public Metrics(
            Action<string, string> logger,
            string processorName,
            string uriType,
            string uri,
            string bearerToken)
            : this(
                logger,
                processorName,
                uriType,
                uri,
                bearerToken,
                20,
                10,
                250,
                100,
                300)
        {
        }

        public Metrics(
            Action<string, string> logger,
            string processorName,
            string uriType,
            string uri,
            string bearerToken,
            int batchSize,
            int flushIntervalSeconds,
            int maxCacheSize,
            int failureDropMessageThreshold,
            int failureDropTimeThresholdSeconds)
        {
            this.logger = logger ?? NoopLogger;
            this.processorName = processorName;
            this.uriType = (uriType ?? string.Empty).ToLowerInvariant();
            this.uri = uri;
            this.bearerToken = bearerToken;
            this.batchSize = batchSize;
            this.flushIntervalMs = flushIntervalSeconds * 1000;
            this.maxCacheSize = maxCacheSize;
            this.failureDropMessageThreshold = failureDropMessageThreshold;
            this.failureDropTimeThresholdSeconds = failureDropTimeThresholdSeconds;
            this.metricCache = new List<MetricMessage>();

            ValidateSettings(flushIntervalSeconds);
            Log("Metrics settings validated successfully", "info");
        }

        public void Start(string metricName)
        {
            CacheMetric("Started", metricName);
        }

        public void Stop(string metricName)
        {
            CacheMetric("Stopped", metricName);
        }

        public void Trace(string metricName)
        {
            CacheMetric("Trace", metricName);
        }

        public void Custom(string action, string metricName)
        {
            CacheMetric(action, metricName);
        }

        public void Flush()
        {
            List<MetricMessage> batch;

            lock (syncRoot)
            {
                if (disposed)
                {
                    return;
                }

                if (sending)
                {
                    ScheduleFlushLocked();
                    return;
                }

                if (metricCache.Count == 0)
                {
                    return;
                }

                int count = Math.Min(batchSize, metricCache.Count);
                batch = metricCache.GetRange(0, count);
                metricCache.RemoveRange(0, count);
                sending = true;
            }

            ThreadPool.QueueUserWorkItem(delegate { SendBatch(batch); });
        }

        public void Dispose()
        {
            lock (syncRoot)
            {
                disposed = true;
                if (flushTimer != null)
                {
                    flushTimer.Dispose();
                    flushTimer = null;
                }
            }
        }

        private void ValidateSettings(int flushIntervalSeconds)
        {
            if (uriType != "aws_lambda" && uriType != "self-hosted" && uriType != "aws_api_gateway")
            {
                throw new ArgumentException("URI type must be one of: aws_lambda, self-hosted, aws_api_gateway");
            }

            if (uriType == "aws_api_gateway")
            {
                throw new NotSupportedException("aws_api_gateway is not implemented yet for AV-System-Metrics");
            }

            if (string.IsNullOrEmpty(processorName))
            {
                throw new ArgumentException("processorName can not be empty");
            }

            if (string.IsNullOrEmpty(uri))
            {
                throw new ArgumentException("uri can not be empty");
            }

            if (string.IsNullOrEmpty(bearerToken))
            {
                throw new ArgumentException("bearerToken can not be empty");
            }

            if (batchSize < 1 || batchSize > MaxBatchSize)
            {
                throw new ArgumentException("batchSize must be between 1 and 25");
            }

            if (flushIntervalSeconds <= 0)
            {
                throw new ArgumentException("flushIntervalSeconds must be greater than 0");
            }

            if (maxCacheSize < batchSize)
            {
                throw new ArgumentException("maxCacheSize must be greater than or equal to batchSize");
            }

            if (failureDropMessageThreshold < 1)
            {
                throw new ArgumentException("failureDropMessageThreshold must be at least 1");
            }

            if (failureDropTimeThresholdSeconds <= 0)
            {
                throw new ArgumentException("failureDropTimeThresholdSeconds must be greater than 0");
            }
        }

        private void CacheMetric(string action, string metricName)
        {
            bool shouldFlush;

            lock (syncRoot)
            {
                if (disposed)
                {
                    return;
                }

                metricCache.Add(new MetricMessage(
                    processorName,
                    DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
                    metricName,
                    action));

                TrimCacheIfAllowedLocked();

                shouldFlush = metricCache.Count >= batchSize;
                if (!shouldFlush)
                {
                    ScheduleFlushLocked();
                }
            }

            if (shouldFlush)
            {
                Flush();
            }
        }

        private void ScheduleFlushLocked()
        {
            if (flushScheduled || disposed)
            {
                return;
            }

            flushScheduled = true;

            if (flushTimer != null)
            {
                flushTimer.Dispose();
            }

            flushTimer = new Timer(
                delegate
                {
                    lock (syncRoot)
                    {
                        flushScheduled = false;
                    }

                    Flush();
                },
                null,
                flushIntervalMs,
                Timeout.Infinite);
        }

        private void SendBatch(List<MetricMessage> messages)
        {
            try
            {
                byte[] data = Encoding.UTF8.GetBytes(BuildPayload(messages));
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
                request.Method = "POST";
                request.ContentType = "application/json";
                request.Headers["Authorization"] = "Bearer " + bearerToken;
                request.ContentLength = data.Length;
                request.Timeout = 10000;
                request.ReadWriteTimeout = 10000;

                using (Stream requestStream = request.GetRequestStream())
                {
                    requestStream.Write(data, 0, data.Length);
                }

                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    int statusCode = (int)response.StatusCode;
                    string responseBody = ReadResponseBody(response);
                    if (statusCode >= 200 && statusCode < 300)
                    {
                        Log("Server response status: " + statusCode, "info");
                        if (!string.IsNullOrEmpty(responseBody))
                        {
                            Log(responseBody, "info");
                        }

                        string acknowledgementError;
                        if (ValidateAcknowledgement(responseBody, messages.Count, out acknowledgementError))
                        {
                            ResetFailureState();
                        }
                        else
                        {
                            Log(
                                "Server acknowledgement validation failed: " + acknowledgementError + ". Will retry " + messages.Count + " metrics.",
                                "error");
                            RecordSendFailure(messages);
                        }
                    }
                    else
                    {
                        HandleHttpFailure(statusCode, messages, responseBody);
                    }
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse response = ex.Response as HttpWebResponse;
                if (response != null)
                {
                    using (response)
                    {
                        HandleHttpFailure((int)response.StatusCode, messages, ReadResponseBody(response));
                    }
                }
                else
                {
                    Log(ex.Message, "error");
                    RecordSendFailure(messages);
                }
            }
            catch (Exception ex)
            {
                Log(ex.Message, "error");
                RecordSendFailure(messages);
            }
            finally
            {
                bool hasQueuedMetrics;

                lock (syncRoot)
                {
                    sending = false;
                    hasQueuedMetrics = metricCache.Count > 0 && !disposed;
                    if (hasQueuedMetrics)
                    {
                        ScheduleFlushLocked();
                    }
                }
            }
        }

        private void HandleHttpFailure(int statusCode, List<MetricMessage> messages, string responseBody)
        {
            if (statusCode == 429)
            {
                Log("Server rate limited request (429). Will retry " + messages.Count + " metrics.", "warning");
                RecordSendFailure(messages);
                return;
            }

            if (statusCode >= 400 && statusCode < 500)
            {
                Log("Permanent client error " + statusCode + ". Dropping " + messages.Count + " metrics.", "error");
                if (!string.IsNullOrEmpty(responseBody))
                {
                    Log(responseBody, "error");
                }

                return;
            }

            if (statusCode >= 500)
            {
                Log("Server error " + statusCode + ". Will retry " + messages.Count + " metrics.", "error");
                RecordSendFailure(messages);
                return;
            }

            Log("Unexpected HTTP status " + statusCode + ". Dropping " + messages.Count + " metrics.", "error");
        }

        private void RecordSendFailure(List<MetricMessage> messages)
        {
            lock (syncRoot)
            {
                if (!firstFailureUtc.HasValue)
                {
                    firstFailureUtc = DateTime.UtcNow;
                }

                failedMessageCount += messages.Count;
                metricCache.InsertRange(0, messages);
                TrimCacheIfAllowedLocked();
            }
        }

        private void ResetFailureState()
        {
            lock (syncRoot)
            {
                failedMessageCount = 0;
                firstFailureUtc = null;
            }
        }

        private void TrimCacheIfAllowedLocked()
        {
            if (metricCache.Count <= maxCacheSize)
            {
                return;
            }

            if (!CanDropOldestMetricsLocked())
            {
                Log(
                    "Metric cache size is " + metricCache.Count + ", max is " + maxCacheSize + ", but dropping is not allowed yet.",
                    "warning");
                return;
            }

            int dropCount = metricCache.Count - maxCacheSize;
            metricCache.RemoveRange(0, dropCount);

            Log(
                "Dropping " + dropCount + " oldest cached metrics after send failures. Failed message count: " + failedMessageCount,
                "warning");
        }

        private bool CanDropOldestMetricsLocked()
        {
            if (failedMessageCount >= failureDropMessageThreshold)
            {
                return true;
            }

            if (firstFailureUtc.HasValue)
            {
                TimeSpan failureDuration = DateTime.UtcNow - firstFailureUtc.Value;
                return failureDuration.TotalSeconds >= failureDropTimeThresholdSeconds;
            }

            return false;
        }

        private string BuildPayload(List<MetricMessage> messages)
        {
            StringBuilder builder = new StringBuilder();
            builder.Append("{\"messages\":[");

            for (int i = 0; i < messages.Count; i++)
            {
                if (i > 0)
                {
                    builder.Append(",");
                }

                MetricMessage message = messages[i];
                builder.Append("{");
                builder.Append("\"clientname\":\"").Append(JsonEscape(message.ClientName)).Append("\",");
                builder.Append("\"timestamp\":\"").Append(JsonEscape(message.Timestamp)).Append("\",");
                builder.Append("\"metric\":\"").Append(JsonEscape(message.Metric)).Append("\",");
                builder.Append("\"action\":\"").Append(JsonEscape(message.Action)).Append("\"");
                builder.Append("}");
            }

            builder.Append("]}");
            return builder.ToString();
        }

        private static string JsonEscape(string value)
        {
            if (value == null)
            {
                return string.Empty;
            }

            StringBuilder builder = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                switch (c)
                {
                    case '"':
                        builder.Append("\\\"");
                        break;
                    case '\\':
                        builder.Append("\\\\");
                        break;
                    case '\b':
                        builder.Append("\\b");
                        break;
                    case '\f':
                        builder.Append("\\f");
                        break;
                    case '\n':
                        builder.Append("\\n");
                        break;
                    case '\r':
                        builder.Append("\\r");
                        break;
                    case '\t':
                        builder.Append("\\t");
                        break;
                    default:
                        if (c < 32)
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }

                        break;
                }
            }

            return builder.ToString();
        }

        private static bool ValidateAcknowledgement(string responseBody, int expectedCount, out string errorMessage)
        {
            if (string.IsNullOrEmpty(responseBody))
            {
                errorMessage = "empty response body";
                return false;
            }

            bool okValue;
            if (!TryReadJsonBoolean(responseBody, "ok", out okValue))
            {
                errorMessage = "response ok was missing or not a boolean";
                return false;
            }

            if (!okValue)
            {
                errorMessage = "response ok was not true";
                return false;
            }

            int countValue;
            if (!TryReadJsonInteger(responseBody, "count", out countValue))
            {
                errorMessage = "response count was missing or not an integer";
                return false;
            }

            if (countValue != expectedCount)
            {
                errorMessage = "response count " + countValue + " did not match sent count " + expectedCount;
                return false;
            }

            errorMessage = string.Empty;
            return true;
        }

        private static bool TryReadJsonBoolean(string json, string propertyName, out bool value)
        {
            int valueStart;
            value = false;

            if (!TryFindJsonPropertyValue(json, propertyName, out valueStart))
            {
                return false;
            }

            if (StartsWithJsonLiteral(json, valueStart, "true"))
            {
                value = true;
                return true;
            }

            if (StartsWithJsonLiteral(json, valueStart, "false"))
            {
                value = false;
                return true;
            }

            return false;
        }

        private static bool TryReadJsonInteger(string json, string propertyName, out int value)
        {
            int valueStart;
            value = 0;

            if (!TryFindJsonPropertyValue(json, propertyName, out valueStart))
            {
                return false;
            }

            int valueEnd = valueStart;
            if (valueEnd < json.Length && json[valueEnd] == '-')
            {
                valueEnd++;
            }

            int digitStart = valueEnd;
            while (valueEnd < json.Length && char.IsDigit(json[valueEnd]))
            {
                valueEnd++;
            }

            if (digitStart == valueEnd)
            {
                return false;
            }

            if (valueEnd < json.Length &&
                json[valueEnd] != ',' &&
                json[valueEnd] != '}' &&
                !char.IsWhiteSpace(json[valueEnd]))
            {
                return false;
            }

            return int.TryParse(
                json.Substring(valueStart, valueEnd - valueStart),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out value);
        }

        private static bool TryFindJsonPropertyValue(string json, string propertyName, out int valueStart)
        {
            string propertyToken = "\"" + propertyName + "\"";
            int propertyIndex = json.IndexOf(propertyToken, StringComparison.Ordinal);
            valueStart = -1;

            if (propertyIndex < 0)
            {
                return false;
            }

            int colonIndex = json.IndexOf(':', propertyIndex + propertyToken.Length);
            if (colonIndex < 0)
            {
                return false;
            }

            valueStart = colonIndex + 1;
            while (valueStart < json.Length && char.IsWhiteSpace(json[valueStart]))
            {
                valueStart++;
            }

            return valueStart < json.Length;
        }

        private static bool StartsWithJsonLiteral(string json, int valueStart, string literal)
        {
            if (valueStart + literal.Length > json.Length)
            {
                return false;
            }

            if (string.Compare(json, valueStart, literal, 0, literal.Length, StringComparison.Ordinal) != 0)
            {
                return false;
            }

            int nextIndex = valueStart + literal.Length;
            return nextIndex >= json.Length ||
                json[nextIndex] == ',' ||
                json[nextIndex] == '}' ||
                char.IsWhiteSpace(json[nextIndex]);
        }

        private static string ReadResponseBody(WebResponse response)
        {
            try
            {
                using (Stream stream = response.GetResponseStream())
                {
                    if (stream == null)
                    {
                        return string.Empty;
                    }

                    using (StreamReader reader = new StreamReader(stream))
                    {
                        return reader.ReadToEnd();
                    }
                }
            }
            catch
            {
                return string.Empty;
            }
        }

        private void Log(string message, string level)
        {
            try
            {
                logger(message, level);
            }
            catch
            {
            }
        }

        private static void NoopLogger(string message, string level)
        {
        }

        private sealed class MetricMessage
        {
            public MetricMessage(string clientName, string timestamp, string metric, string action)
            {
                ClientName = clientName;
                Timestamp = timestamp;
                Metric = metric;
                Action = action;
            }

            public string ClientName { get; private set; }

            public string Timestamp { get; private set; }

            public string Metric { get; private set; }

            public string Action { get; private set; }
        }
    }
}
