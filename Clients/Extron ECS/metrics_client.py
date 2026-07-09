"""
Extron Processor Module for sending batched metric data.

You can also run this module on a workstation for testing.

Requirements: A server or serverless system for ingestion.
Find the ingest system code and documentation here: https://github.com/mefranklin6/AV-System-Metrics

Usage Example:

from metrics_client import Metrics

metrics = Metrics(
    logger=logger, # such as your instance of ProgramLog
    processor_name="my_processor",
    uri_type="aws_lambda",
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
    from extronlib.system import Wait  # type: ignore
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


class Metrics:
    __version__ = "2.1.2"

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
        request_timeout: float = 10.0,
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
        self.request_timeout = request_timeout

        self.valid_uri_types = ["aws_lambda", "aws_api_gateway", "self-hosted"]

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

        if self.uri_type == "aws_api_gateway":
            raise NotImplementedError(
                "aws_api_gateway is not implemented yet for AWS Serverless Metrics"
            )

        if not self.bearer_token:
            raise ValueError("Bearer token can not be empty")

        if self.batch_size < 1:
            raise ValueError("batch_size must be at least 1")

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

        self.logger("Metrics Settings validated successfully", "info")

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
            "Dropping {} oldest cached metrics after send failures. Failed message count: {}".format(
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
        self._sending = True

        try:
            self._send_batch(batch)
        except Exception as e:
            self.logger(e, "error")
            self._sending = False
            self._metric_cache = batch + self._metric_cache
            self._schedule_flush()

    def _send_batch(self, messages) -> None:
        def _send_batch_inner(messages):
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
                with urllib.request.urlopen(
                    req,
                    timeout=self.request_timeout,
                ) as response:
                    response_body = response.read().decode("utf-8", "replace")
                    # self.logger(
                    #     "Server response status: {}".format(response.status),
                    #     "info",
                    # )
                    # if response_body:
                    #     self.logger(response_body, "info")

                    ack_ok, ack_error = self._validate_server_ack(
                        response_body,
                        len(messages),
                    )

                    if ack_ok:
                        self._failed_message_count = 0
                        self._first_failure_time = None
                    else:
                        self.logger(
                            "Server acknowledgement validation failed: {}. Will retry {} metrics.".format(
                                ack_error,
                                len(messages),
                            ),
                            "error",
                        )
                        self._record_send_failure(messages)

            except urllib.error.HTTPError as e:
                if e.code == 429:
                    self.logger(
                        "Server rate limited request (429). Will retry {} metrics.".format(
                            len(messages)
                        ),
                        "warning",
                    )
                    self._record_send_failure(messages)

                elif 400 <= e.code < 500:
                    self.logger(
                        "Permanent client error {}. Dropping {} metrics.".format(
                            e.code,
                            len(messages),
                        ),
                        "error",
                    )

                    try:
                        self.logger(e.read(), "error")
                    except Exception:
                        pass

                else:
                    self.logger(
                        "Server error {}. Will retry {} metrics.".format(
                            e.code,
                            len(messages),
                        ),
                        "error",
                    )
                    self._record_send_failure(messages)

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

    def _validate_server_ack(self, response_body, expected_count):
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

    def _record_send_failure(self, messages) -> None:
        if self._first_failure_time is None:
            self._first_failure_time = time.time()

        self._failed_message_count += len(messages)

        # Requeue failed messages at the front so they are retried before newer metrics.
        self._metric_cache = messages + self._metric_cache

        self._trim_cache_if_allowed()

    def start(self, metric_name: str) -> None:
        """Record a 'Started' event for a metric.

        args:
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric("Started", metric_name)

    def stop(self, metric_name: str) -> None:
        """Record a 'Stopped' event for a metric.

        args:
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric("Stopped", metric_name)

    def trace(self, metric_name: str) -> None:
        """Record a non-timebound event, such as a button press.

        args:
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric("Trace", metric_name)

    def connected(self, metric_name: str) -> None:
        """Record a 'Connected' event for a metric.

        args:
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric("Connected", metric_name)

    def disconnected(self, metric_name: str) -> None:
        """Record a 'Disconnected' event for a metric.

        args:
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric("Disconnected", metric_name)

    def custom(self, action: str, metric_name: str) -> None:
        """Record a custom action.

        args:
            action (str): The custom action to record.
            metric_name (str): The name of the metric to record.
        """
        self._cache_metric(action, metric_name)


if __name__ == "__main__":
    # Simple test that runs on a workstation
    uri = "<your_uri>"
    bearer = "<your_bearer_token>"

    logger = MockLogger()

    test = Metrics(
        logger,
        "test_pc",
        "aws_lambda",  # or 'self-hosted'
        uri,
        bearer,
        flush_interval=10,
    )
    print("Testing Metrics...")
    print(
        "This will take {} seconds due to flush interval...".format(
            test.flush_interval + 5
        )
    )

    test.trace("Hello World!")
    test.start("TestStart")
    test.stop("TestStop")
    test.custom("CustomAction", "TestCustom")

    # Keep workstation script alive long enough for delayed flush.
    time.sleep(test.flush_interval + 5)
    print("Test complete.")
