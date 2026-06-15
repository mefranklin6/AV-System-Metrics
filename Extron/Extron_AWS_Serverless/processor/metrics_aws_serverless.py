"""
Extron Processor Module for sending batched metric data to Amazon Web Services.

You can also run this module on a workstation for testing.

Usage Example:

import metrics_aws_serverless

metrics = AWS_ServerlessMetrics(
    logger=logger, # such as your instance of ProgramLog
    processor_name="my_processor",
    uri_type="lambda",
    uri="https://myrandomlambdainstance.lambda-url.us-west-1.on.aws/",
    bearer_token="myrandombearertoken",
)

metrics.trace("Hello World!")
"""

from datetime import datetime, timezone
import json
import time
import urllib.error
import urllib.request

try:
    from extronlib.system import Wait # type: ignore
except ImportError:  # Not running on Extron processor
    # Mock extronlib classes here so we can run on a workstation for testing

    from functools import wraps
    import threading

    class Wait:
        def __init__(self, delay_time: float = 0):
            self.delay_time = delay_time

        def __call__(self, func):
            @wraps(func)
            def wrapper(*args, **kwargs):
                return func(*args, **kwargs)

            timer = threading.Timer(self.delay_time, wrapper)
            timer.daemon = True
            timer.start()

            return wrapper

class MockLogger:
    def __call__(self, message, level="info"):
        print("{}: {}".format(level.upper(), message))


class AWS_ServerlessMetrics:
    __version__ = "2.0.1"

    def __init__(
        self,
        logger,
        processor_name: str,
        uri_type: str,
        uri: str,
        bearer_token: str,
        batch_size: int = 20,
        flush_interval: int = 10,
        max_cache_size: int = 250,
        failure_drop_message_threshold: int = 100,
        failure_drop_time_threshold: int = 300,
    ) -> None:
        self.logger = logger
        self.processor_name = processor_name
        self.uri_type = uri_type.lower()
        self.uri = uri
        self.bearer_token = bearer_token

        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self.max_cache_size = max_cache_size
        self.failure_drop_message_threshold = failure_drop_message_threshold
        self.failure_drop_time_threshold = failure_drop_time_threshold

        self.valid_uri_types = ["lambda", "api_gateway"]

        self._metric_cache = []
        self._flush_scheduled = False
        self._sending = False

        self._failed_message_count = 0
        self._first_failure_time = None

        self._validate_settings()

    def _validate_settings(self) -> None:
        if self.uri_type not in self.valid_uri_types:
            raise ValueError(
                "URI Type must be one of: {}".format(str(self.valid_uri_types))
            )

        if self.uri_type == "api_gateway":
            raise NotImplementedError(
                "api_gateway is not implemented yet for AWS Serverless Metrics"
            )

        if not self.bearer_token:
            raise ValueError("Bearer token can not be empty")

        if self.batch_size < 1:
            raise ValueError("batch_size must be at least 1")

        if self.batch_size > 25:
            raise ValueError(
                "batch_size must be 25 or less to match Lambda MAX_MESSAGES"
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

    def _can_drop_oldest_metrics(self) -> bool:
        if self._failed_message_count >= self.failure_drop_message_threshold:
            return True

        if self._first_failure_time is not None:
            failure_duration = time.time() - self._first_failure_time

            if failure_duration >= self.failure_drop_time_threshold:
                return True

        return False

    def _trim_cache_if_allowed(self) -> None:
        if len(self._metric_cache) <= self.max_cache_size:
            return

        if not self._can_drop_oldest_metrics():
            self.logger(
                "Metric cache size is {}, max is {}, but dropping is not allowed yet.".format(
                    len(self._metric_cache),
                    self.max_cache_size,
                ),
                "warning",
            )
            return

        drop_count = len(self._metric_cache) - self.max_cache_size

        self.logger(
            "Dropping {} oldest cached metrics after AWS send failures. Failed message count: {}".format(
                drop_count,
                self._failed_message_count,
            ),
            "warning",
        )

        self._metric_cache = self._metric_cache[drop_count:]

    def _cache_metric(self, action: str, metric: str) -> None:
        self._metric_cache.append(
            {
                "clientname": self.processor_name,
                "timestamp": datetime.now(timezone.utc).isoformat(),  # noqa: UP017
                "metric": metric,
                "action": action,
            }
        )

        self._trim_cache_if_allowed()

        if len(self._metric_cache) >= self.batch_size:
            self.flush()
        else:
            self._schedule_flush()

    def _schedule_flush(self) -> None:
        if self._flush_scheduled:
            return

        self._flush_scheduled = True

        @Wait(self.flush_interval)
        def _delayed_flush():
            self._flush_scheduled = False
            self.flush()

    def flush(self) -> None:
        if self._sending:
            self._schedule_flush()
            return

        if not self._metric_cache:
            return

        batch = self._metric_cache[: self.batch_size]
        self._metric_cache = self._metric_cache[self.batch_size :]

        self._send_batch(batch)

    def _send_batch(self, messages) -> None:
        def _send_batch_inner(messages):
            self._sending = True

            data = json.dumps({"messages": messages}).encode("utf-8")

            req = urllib.request.Request(
                self.uri,
                data=data,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer {}".format(self.bearer_token),
                },
                method="POST",
            )

            try:
                with urllib.request.urlopen(req) as response:
                    self.logger(
                        "AWS Metrics response status: {}".format(response.status),
                        "info",
                    )
                    self.logger(response.read(), "info")

                self._failed_message_count = 0
                self._first_failure_time = None

            except urllib.error.URLError as e:
                self.logger(e, "error")
                self._record_send_failure(messages)

            except Exception as e:
                self.logger(e, "error")
                self._record_send_failure(messages)

            finally:
                self._sending = False

                if self._metric_cache:
                    self._schedule_flush()

        @Wait(0)
        def _multi_thread_metric_send():
            _send_batch_inner(messages)

    def _record_send_failure(self, messages) -> None:
        if self._first_failure_time is None:
            self._first_failure_time = time.time()

        self._failed_message_count += len(messages)

        # Requeue failed messages at the front so they are retried before newer metrics.
        self._metric_cache = messages + self._metric_cache

        self._trim_cache_if_allowed()

    def start(self, metric_name: str) -> None:
        """Record a 'Started' event for a metric."""
        self._cache_metric("Started", metric_name)

    def stop(self, metric_name: str) -> None:
        """Record a 'Stopped' event for a metric."""
        self._cache_metric("Stopped", metric_name)

    def trace(self, metric_name: str) -> None:
        """Record a non-timebound event, such as a button press."""
        self._cache_metric("Trace", metric_name)

    def custom(self, action: str, metric_name: str) -> None:
        """Record a custom action."""
        self._cache_metric(action, metric_name)


if __name__ == "__main__":
    # Simple test that runs on a workstation
    uri = "<your_uri>"
    bearer = "<your_bearer_token>"

    logger =  MockLogger()

    test = AWS_ServerlessMetrics(
        logger,
        "test_pc",
        "lambda",
        uri,
        bearer,
        flush_interval=10,
    )
    print("Testing AWS Serverless Metrics...")
    print(
        "This will take {} seconds due to flush interval...".format(
            test.flush_interval + 5
        )
    )

    test.trace("Hello AWS!")
    test.start("TestStart")
    test.stop("TestStop")
    test.custom("CustomAction", "TestCustom")

    # Keep workstation script alive long enough for delayed flush.
    time.sleep(test.flush_interval + 5)
    print("Test complete.")
