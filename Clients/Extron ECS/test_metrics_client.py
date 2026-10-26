"""Offline checks of delivery behavior and diagnostic logs; no hardware required."""

import io
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

import metrics_client


class FailureLoggingTests(unittest.TestCase):
    def setUp(self):
        self.logs = []
        self.client = metrics_client.Metrics(
            lambda message, level: self.logs.append((message, level)),
            "test-processor", "https://example.invalid/metrics", "test-token",
            batch_size=2, max_cache_size=3,
            failure_drop_message_threshold=4,
        )
        self.scheduled = []

        def fake_wait(delay):
            def decorate(callback):
                if delay == 0:
                    callback()
                else:
                    self.scheduled.append((delay, callback))
                return callback
            return decorate

        self.wait_patch = patch.object(metrics_client, "Wait", fake_wait)
        self.wait_patch.start()
        self.addCleanup(self.wait_patch.stop)

    def has_log(self, text, level):
        return any(text in message and severity == level
                   for message, severity in self.logs)

    def send(self, failure=None, body=b'{"ok": true, "count": 2}'):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = body
        with patch.object(metrics_client.urllib.request, "urlopen",
                          side_effect=failure, return_value=response):
            self.client.flush()

    def queue(self, count=2):
        # Prevent automatic batch flush while arranging the input.
        with patch.object(self.client, "flush"):
            for index in range(count):
                self.client.trace("event-{}".format(index))

    def test_network_failure_and_recovery(self):
        self.assertTrue(self.has_log("memory-only", "info"))
        self.queue()
        original = list(self.client._metric_cache)
        self.send(urllib.error.URLError("connection refused"))
        self.assertEqual(original, self.client._metric_cache)
        self.assertTrue(self.has_log("network request failed", "error"))
        self.assertTrue(self.has_log("Requeued 2 metrics ahead of newer events", "warning"))
        self.assertTrue(self.has_log("scheduled in 10s", "warning"))
        self.assertEqual(10, self.scheduled[0][0])

        self.send()
        self.assertEqual([], self.client._metric_cache)
        self.assertTrue(self.has_log("delivery recovered", "info"))
        self.assertTrue(self.has_log("Acknowledged 2 metrics; 0 metrics remain", "info"))
        self.assertEqual(0, self.client._failed_message_count)
        self.assertIsNone(self.client._first_failure_time)
        self.queue()
        self.send()
        self.assertEqual(1, sum("delivery recovered" in message for message, _ in self.logs))

    def test_retryable_failures_keep_batch(self):
        for failure, body in [
            (TimeoutError("timed out"), b""),
            (urllib.error.HTTPError("url", 429, "limited", {}, None), b""),
            (urllib.error.HTTPError("url", 503, "unavailable", {}, None), b""),
            (None, b'{"ok": true, "count": 1}'),
        ]:
            with self.subTest(failure=failure, body=body):
                self.client._metric_cache = []
                self.queue()
                original = list(self.client._metric_cache)
                self.logs.clear()
                self.send(failure, body)
                self.assertEqual(original, self.client._metric_cache)
                self.assertTrue(self.has_log("Requeued 2 metrics", "warning"))
                self.assertFalse(self.has_log("delivery recovered", "info"))

    def test_permanent_error_logs_drop_without_retry(self):
        self.queue()
        self.send(urllib.error.HTTPError(
            "url", 401, "unauthorized", {}, io.BytesIO(b"invalid token")
        ))
        self.assertEqual([], self.client._metric_cache)
        self.assertTrue(self.has_log("Permanent client error 401. Dropping 2 metrics", "error"))
        self.assertFalse(self.has_log("Requeued", "warning"))

    def test_trimming_logs_message_and_time_thresholds(self):
        for elapsed, attempts in [(1, 4), (301, 2)]:
            with self.subTest(elapsed=elapsed, attempts=attempts):
                self.client._metric_cache = []
                self.client._failed_message_count = 0
                self.client._first_failure_time = None
                self.logs.clear()
                self.queue(4)
                self.assertTrue(self.has_log("dropping is not allowed yet", "warning"))
                oldest = self.client._metric_cache[:2]
                self.client._metric_cache = self.client._metric_cache[2:]
                self.client._failed_message_count = attempts - 2
                self.client._first_failure_time = 1000
                with patch.object(metrics_client.time, "time", return_value=1000 + elapsed):
                    self.client._record_send_failure(oldest)
                self.assertEqual(3, len(self.client._metric_cache))
                self.assertTrue(self.has_log("Dropping 1 oldest cached metrics", "warning"))
                self.assertTrue(self.has_log("retained: 3 metrics", "warning"))

    def test_broken_logger_does_not_interrupt_retry_or_recovery(self):
        def broken_logger(*args):
            raise RuntimeError("logger unavailable")

        self.client.logger = broken_logger
        self.queue()
        self.send(TimeoutError("timed out"))
        self.assertEqual(2, len(self.client._metric_cache))
        self.assertFalse(self.client._sending)
        self.send()
        self.assertEqual([], self.client._metric_cache)
        self.assertIsNone(self.client._first_failure_time)


if __name__ == "__main__":
    unittest.main()
