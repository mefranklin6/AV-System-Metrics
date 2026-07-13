"""
AMX MUSE Python module for sending batched AV-System-Metrics events.

Requirements: an AV-System-Metrics ingest endpoint and bearer token.
Find the ingest system code and documentation here:
https://github.com/mefranklin6/AV-System-Metrics

Usage Example:

from metrics_client import Metrics

metrics = Metrics(
    logger=logger,
    processor_name="boardroom-muse",
    uri="https://example.lambda-url.us-west-1.on.aws/",
    bearer_token="change-me-long-random-token",
)

metrics.trace("System Initialized")
"""

from datetime import datetime, timezone
import json
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple
import urllib.error
import urllib.request


MAX_BATCH_SIZE = 25
MAX_FIELD_LENGTH = 128


class MockLogger:
    def __call__(self, message: Any, level: str = "info") -> None:
        print("{}: {}".format(level.upper(), message))


class Metrics:
    """Client for queueing and sending AV-System-Metrics events from AMX MUSE."""

    __version__ = "1.0.0"

    def __init__(
        self,
        logger: Optional[Callable[..., None]],
        processor_name: str,
        uri: str,
        bearer_token: str,
        batch_size: int = 20,
        flush_interval: int = 10,
        max_cache_size: int = 250,
        failure_drop_message_threshold: int = 100,
        failure_drop_time_threshold: int = 300,
        request_timeout: float = 10.0,
    ) -> None:
        self.logger = logger or MockLogger()
        self.processor_name = processor_name
        self.uri = uri
        self.bearer_token = bearer_token

        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self.max_cache_size = max_cache_size
        self.failure_drop_message_threshold = failure_drop_message_threshold
        self.failure_drop_time_threshold = failure_drop_time_threshold
        self.request_timeout = request_timeout

        self._lock = threading.RLock()
        self._metric_cache: List[Dict[str, str]] = []
        self._flush_timer: Optional[threading.Timer] = None
        self._flush_scheduled = False
        self._sending = False
        self._closed = False

        self._failed_message_count = 0
        self._first_failure_time: Optional[float] = None

        self._validate_settings()

    def _validate_settings(self) -> None:
        self._validate_field("processor_name", self.processor_name)

        if not self.uri:
            raise ValueError("uri can not be empty")

        if not self.bearer_token:
            raise ValueError("bearer_token can not be empty")

        if self.batch_size < 1 or self.batch_size > MAX_BATCH_SIZE:
            raise ValueError(
                "batch_size must be between 1 and {}".format(MAX_BATCH_SIZE)
            )

        if self.flush_interval <= 0:
            raise ValueError("flush_interval must be greater than 0")

        if self.max_cache_size < self.batch_size:
            raise ValueError(
                "max_cache_size must be greater than or equal to batch_size"
            )

        if self.failure_drop_message_threshold < 1:
            raise ValueError("failure_drop_message_threshold must be at least 1")

        if self.failure_drop_time_threshold <= 0:
            raise ValueError("failure_drop_time_threshold must be greater than 0")

        if self.request_timeout <= 0:
            raise ValueError("request_timeout must be greater than 0")

        self._log("Metrics settings validated successfully", "info")

    def _validate_field(self, field_name: str, value: Any) -> str:
        if value is None:
            raise ValueError("{} can not be empty".format(field_name))

        if not isinstance(value, str):
            raise ValueError("{} must be a string".format(field_name))

        if not value:
            raise ValueError("{} can not be empty".format(field_name))

        if len(value) > MAX_FIELD_LENGTH:
            raise ValueError(
                "{} must be {} characters or fewer".format(
                    field_name,
                    MAX_FIELD_LENGTH,
                )
            )

        return value

    def _log(self, message: Any, level: str = "info") -> None:
        try:
            self.logger(message, level)
        except TypeError:
            try:
                self.logger("{}: {}".format(level.upper(), message))
            except Exception:
                pass
        except Exception:
            pass

    def _now_iso_utc(self) -> str:
        return (
            datetime.now(timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace(
                "+00:00",
                "Z",
            )
        )

    def _can_drop_oldest_metrics_locked(self) -> bool:
        if self._failed_message_count >= self.failure_drop_message_threshold:
            return True

        if self._first_failure_time is not None:
            failure_duration = time.time() - self._first_failure_time

            if failure_duration >= self.failure_drop_time_threshold:
                return True

        return False

    def _trim_cache_if_allowed_locked(self) -> None:
        if len(self._metric_cache) <= self.max_cache_size:
            return

        if not self._can_drop_oldest_metrics_locked():
            self._log(
                "Metric cache size is {}, max is {}, but dropping is not allowed yet.".format(
                    len(self._metric_cache),
                    self.max_cache_size,
                ),
                "warning",
            )
            return

        drop_count = len(self._metric_cache) - self.max_cache_size
        del self._metric_cache[:drop_count]

        self._log(
            "Dropping {} oldest cached metrics after send failures. Failed message count: {}".format(
                drop_count,
                self._failed_message_count,
            ),
            "warning",
        )

    def _cache_metric(self, action: str, metric: str) -> None:
        action = self._validate_field("action", action)
        metric = self._validate_field("metric_name", metric)

        should_flush = False

        with self._lock:
            if self._closed:
                return

            self._metric_cache.append(
                {
                    "clientname": self.processor_name,
                    "timestamp": self._now_iso_utc(),
                    "metric": metric,
                    "action": action,
                }
            )

            self._trim_cache_if_allowed_locked()

            if len(self._metric_cache) >= self.batch_size:
                should_flush = True
            else:
                self._schedule_flush_locked()

        if should_flush:
            self.flush()

    def _schedule_flush_locked(self) -> None:
        if self._flush_scheduled or self._closed:
            return

        self._flush_scheduled = True

        def _delayed_flush() -> None:
            with self._lock:
                self._flush_scheduled = False
                self._flush_timer = None

            self.flush()

        self._flush_timer = threading.Timer(self.flush_interval, _delayed_flush)
        self._flush_timer.daemon = True
        self._flush_timer.start()

    def flush(self) -> None:
        """Send queued metrics in the background."""
        with self._lock:
            if self._closed:
                return

            if self._sending:
                self._schedule_flush_locked()
                return

            if not self._metric_cache:
                return

            batch = self._metric_cache[: self.batch_size]
            del self._metric_cache[: self.batch_size]
            self._sending = True

        try:
            sender = threading.Thread(target=self._send_batch, args=(batch,))
            sender.daemon = True
            sender.start()
        except Exception as error:
            self._log(error, "error")
            with self._lock:
                self._sending = False
                self._metric_cache = batch + self._metric_cache
                self._schedule_flush_locked()

    def _send_batch(self, messages: List[Dict[str, str]]) -> None:
        try:
            payload = json.dumps(
                {"messages": messages},
                separators=(",", ":"),
            ).encode("utf-8")

            request = urllib.request.Request(
                self.uri,
                data=payload,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer {}".format(self.bearer_token),
                },
                method="POST",
            )

            with urllib.request.urlopen(
                request,
                timeout=self.request_timeout,
            ) as response:
                status = getattr(response, "status", response.getcode())
                response_body = response.read().decode("utf-8", "replace")

                if 200 <= status < 300:
                    self._log("Server response status: {}".format(status), "info")
                    if response_body:
                        self._log(response_body, "info")

                    ack_ok, ack_error = self._validate_server_ack(
                        response_body,
                        len(messages),
                    )

                    if ack_ok:
                        self._reset_failure_state()
                    else:
                        self._log(
                            "Server acknowledgement validation failed: {}. Will retry {} metrics.".format(
                                ack_error,
                                len(messages),
                            ),
                            "error",
                        )
                        self._record_send_failure(messages)
                else:
                    self._handle_http_failure(status, messages, response_body)

        except urllib.error.HTTPError as error:
            self._handle_http_failure(
                error.code,
                messages,
                self._read_error_body(error),
            )

        except urllib.error.URLError as error:
            self._log(error, "error")
            self._record_send_failure(messages)

        except Exception as error:
            self._log(error, "error")
            self._record_send_failure(messages)

        finally:
            with self._lock:
                self._sending = False
                if self._metric_cache and not self._closed:
                    self._schedule_flush_locked()

    def _handle_http_failure(
        self,
        status_code: int,
        messages: List[Dict[str, str]],
        response_body: str = "",
    ) -> None:
        if status_code == 429:
            self._log(
                "Server rate limited request (429). Will retry {} metrics.".format(
                    len(messages)
                ),
                "warning",
            )
            self._record_send_failure(messages)
            return

        if 400 <= status_code < 500:
            self._log(
                "Permanent client error {}. Dropping {} metrics.".format(
                    status_code,
                    len(messages),
                ),
                "error",
            )
            if response_body:
                self._log(response_body, "error")
            return

        if status_code >= 500:
            self._log(
                "Server error {}. Will retry {} metrics.".format(
                    status_code,
                    len(messages),
                ),
                "error",
            )
            self._record_send_failure(messages)
            return

        self._log(
            "Unexpected HTTP status {}. Dropping {} metrics.".format(
                status_code,
                len(messages),
            ),
            "error",
        )

    def _validate_server_ack(
        self,
        response_body: str,
        expected_count: int,
    ) -> Tuple[bool, str]:
        if not response_body:
            return False, "empty response body"

        try:
            ack = json.loads(response_body)
        except ValueError as error:
            return False, "invalid JSON response: {}".format(error)

        if not isinstance(ack, dict):
            return False, "response JSON was not an object"

        if ack.get("ok") is not True:
            return False, "response ok was not true"

        count = ack.get("count")
        if isinstance(count, bool) or not isinstance(count, int):
            return False, "response count was not an integer"

        if count != expected_count:
            return False, "response count {} did not match sent count {}".format(
                count,
                expected_count,
            )

        return True, ""

    def _record_send_failure(self, messages: List[Dict[str, str]]) -> None:
        with self._lock:
            if self._first_failure_time is None:
                self._first_failure_time = time.time()

            self._failed_message_count += len(messages)
            self._metric_cache = messages + self._metric_cache
            self._trim_cache_if_allowed_locked()

    def _reset_failure_state(self) -> None:
        with self._lock:
            self._failed_message_count = 0
            self._first_failure_time = None

    def _read_error_body(self, error: urllib.error.HTTPError) -> str:
        try:
            return error.read().decode("utf-8", "replace")
        except Exception:
            return ""

    def start(self, metric_name: str) -> None:
        """Record a 'Started' event for a metric."""
        self._cache_metric("Started", metric_name)

    def stop(self, metric_name: str) -> None:
        """Record a 'Stopped' event for a metric."""
        self._cache_metric("Stopped", metric_name)

    def trace(self, metric_name: str) -> None:
        """Record a non-timebound event, such as a button press."""
        self._cache_metric("Trace", metric_name)

    def connected(self, metric_name: str) -> None:
        """Record a 'Connected' event for a metric."""
        self._cache_metric("Connected", metric_name)

    def disconnected(self, metric_name: str) -> None:
        """Record a 'Disconnected' event for a metric."""
        self._cache_metric("Disconnected", metric_name)

    def custom(self, action: str, metric_name: str) -> None:
        """Record a custom action."""
        self._cache_metric(action, metric_name)

    def close(self) -> None:
        """Stop future timer flushes. Already-running sends are allowed to finish."""
        with self._lock:
            self._closed = True
            timer = self._flush_timer
            self._flush_timer = None
            self._flush_scheduled = False

        if timer is not None:
            timer.cancel()


if __name__ == "__main__":
    # Simple workstation smoke test. Replace these values before using it.
    uri = "<your_uri>"
    bearer = "<your_bearer_token>"

    test = Metrics(
        logger=MockLogger(),
        processor_name="test_amx_muse",
        uri=uri,
        bearer_token=bearer,
        flush_interval=10,
    )

    print("Testing Metrics...")
    print(
        "This will take {} seconds due to flush interval...".format(
            test.flush_interval + 5
        )
    )

    test.trace("Hello World")
    test.start("TestStart")
    test.stop("TestStop")
    test.custom("CustomAction", "TestCustom")

    time.sleep(test.flush_interval + 5)
    print("Test complete.")
