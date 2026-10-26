"""Offline checks of outage diagnostics, using synchronous background work."""

import io
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

import metrics_client


class FailureLoggingTests(unittest.TestCase):
    def setUp(self):
        self.logs = []
        self.client = metrics_client.Metrics(
            lambda message, level: self.logs.append((str(message), level)),
            "test", "https://example.invalid/metrics", "token",
            batch_size=2, max_cache_size=3, failure_drop_message_threshold=4,
        )
        self.addCleanup(self.client.close)
        timer_patch = patch.object(metrics_client.threading, "Timer")
        self.timer = timer_patch.start()
        self.addCleanup(timer_patch.stop)

    def has_log(self, text, level):
        return any(text in message and severity == level for message, severity in self.logs)

    def queue(self, count=2):
        with patch.object(self.client, "flush"):
            for index in range(count):
                self.client.trace("event-{}".format(index))

    def send(self, failure=None, body=b'{"ok": true, "count": 2}'):
        response = MagicMock()
        response.__enter__.return_value.status = 201
        response.__enter__.return_value.read.return_value = body

        def sender(target, args):
            thread = MagicMock()
            thread.start.side_effect = lambda: target(*args)
            return thread

        with patch.object(metrics_client.threading, "Thread", side_effect=sender), \
                patch.object(metrics_client.urllib.request, "urlopen",
                             side_effect=failure, return_value=response):
            self.client.flush()

    def test_network_failure_and_recovery(self):
        self.assertTrue(self.has_log("memory-only", "info"))
        self.queue()
        original = list(self.client._metric_cache)
        self.send(urllib.error.URLError("connection refused"))
        self.assertEqual(original, self.client._metric_cache)
        self.assertTrue(self.has_log("network request failed", "error"))
        self.assertTrue(self.has_log("Requeued 2 metrics ahead of newer events", "warning"))
        self.assertTrue(self.has_log("Retry flush interval: 10s", "warning"))
        self.send()
        self.assertEqual([], self.client._metric_cache)
        self.assertTrue(self.has_log("Acknowledged 2 metrics; 0 metrics remain", "info"))
        self.assertIsNone(self.client._first_failure_time)
        self.assertEqual(0, self.client._failed_message_count)
        self.queue()
        self.send()
        self.assertEqual(1, sum("delivery recovered" in message for message, _ in self.logs))

    def test_retryable_failures_preserve_batch(self):
        for failure, body in [
            (TimeoutError("timed out"), b""),
            (urllib.error.HTTPError("url", 429, "limited", {}, None), b""),
            (urllib.error.HTTPError("url", 503, "unavailable", {}, None), b""),
            (None, b'{"ok": true, "count": 1}'),
        ]:
            with self.subTest(failure=failure, body=body):
                self.client._metric_cache = []
                self.logs.clear()
                self.queue()
                original = list(self.client._metric_cache)
                self.send(failure, body)
                self.assertEqual(original, self.client._metric_cache)
                self.assertTrue(self.has_log("Requeued 2 metrics", "warning"))
                self.assertFalse(self.has_log("delivery recovered", "info"))

    def test_permanent_error_drops_batch(self):
        self.queue()
        self.send(urllib.error.HTTPError("url", 401, "unauthorized", {}, io.BytesIO(b"bad token")))
        self.assertEqual([], self.client._metric_cache)
        self.assertTrue(self.has_log("Permanent client error 401. Dropping 2 metrics", "error"))
        self.assertFalse(self.has_log("Requeued", "warning"))

    def test_both_drop_thresholds(self):
        for elapsed, attempts in [(1, 4), (301, 2)]:
            with self.subTest(elapsed=elapsed, attempts=attempts):
                self.client._metric_cache = []
                self.client._first_failure_time = None
                self.client._failed_message_count = 0
                self.logs.clear()
                self.queue(4)
                self.assertTrue(self.has_log("dropping is not allowed yet", "warning"))
                oldest = self.client._metric_cache[:2]
                self.client._metric_cache = self.client._metric_cache[2:]
                self.client._first_failure_time = 1000
                self.client._failed_message_count = attempts - 2
                with patch.object(metrics_client.time, "time", return_value=1000 + elapsed):
                    self.client._record_send_failure(oldest)
                self.assertEqual(3, len(self.client._metric_cache))
                self.assertTrue(self.has_log("Dropping 1 oldest cached metrics", "warning"))
                self.assertTrue(self.has_log("retained: 3 metrics", "warning"))

    def test_broken_logger_does_not_interrupt_delivery(self):
        def broken_logger(*args):
            raise RuntimeError("logger unavailable")
        self.client.logger = broken_logger
        self.queue()
        self.send(TimeoutError("timed out"))
        self.assertEqual(2, len(self.client._metric_cache))
        self.assertFalse(self.client._sending)
        self.send()
        self.assertEqual([], self.client._metric_cache)


if __name__ == "__main__":
    unittest.main()
