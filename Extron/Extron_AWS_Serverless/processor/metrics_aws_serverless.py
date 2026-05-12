"""
Extron Processor Module for sending metric data to Amazon Web Services.

You can also run this module on a workstation for testing.

Usage Example:

import metrics_aws_serverless
metrics = AWS_ServerlessMetrics(
    processor_name="my_processor",
    uri_type="lambda",
    uri="https://myrandomlambdainstance.lambda-url.us-west-1.on.aws/",
    bearer_token="myrandombearertoken"
)
metrics.trace("Hello World!")
"""

import json
import urllib.error
import urllib.request
from datetime import datetime

try:
    from extronlib.system import Wait

    # Replace the Logger with whatever your project uses
    from modules.project.logger import Logger  # type: ignore

    ON_EXTRON = True
except ImportError:
    ON_EXTRON = False

if not ON_EXTRON:

    class Logger:
        def _log(self, message, level):
            print("{} - {}".format(level, message))

        def info(self, message):
            self._log(message, "info")

        def warning(self, message):
            self._log(message, "warning")

        def error(self, message):
            self._log(message, "error")


if Logger:  # type: ignore
    logger = Logger()


class AWS_ServerlessMetrics:
    __version__ = "1.0.0"

    def __init__(
        self, processor_name: str, uri_type: str, uri: str, bearer_token: str
    ) -> None:
        self.processor_name = processor_name
        self.uri_type = uri_type
        self.uri = uri
        self.bearer_token = bearer_token

        self.valid_uri_types = ["lambda", "api_gateway"]

        self._validate_init()

    def _validate_init(self):
        if self.uri_type.lower() not in self.valid_uri_types:
            raise ValueError(
                "URI Type must be one of: {}".format(str(self.valid_uri_types))
            )

        if self.uri_type == "api_gateway":  # TODO: Add api_gateway capibility
            raise NotImplementedError(
                "api_gateway is not implemented yet for AWS Serverless Metrics"
            )

        if self.bearer_token is None or self.bearer_token == "":
            raise ValueError("Bearer token can not be empty")

    def _send_metric(self, action: str, metric: str) -> None:
        time_str = datetime.now().isoformat()

        def _send_metric_inner(action, metric):
            data = json.dumps(
                {
                    "clientname": self.processor_name,
                    "timestamp": time_str,
                    "metric": metric,
                    "action": action,
                }
            ).encode("utf-8")

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
                    logger.info(response.status)
                    logger.info(response.read())
            except urllib.error.URLError as e:
                logger.error(e)
            except Exception as e:
                logger.error(e)

        if ON_EXTRON:

            @Wait(0)  # type: ignore
            def _multi_thread_metric_send():
                _send_metric_inner(action, metric)
        else:
            _send_metric_inner(action, metric)

    def start(self, metric_name: str) -> None:
        """Record a 'Started' event for a metric.

        Args:
            metric_name: Name of the metric to start (e.g. 'Audience_Camera', 'Projector').
        """
        self._send_metric("Started", metric_name)

    def stop(self, metric_name: str) -> None:
        """Record a 'Stopped' event for a metric.

        Args:
            metric_name: Name of the metric to stop.
        """
        self._send_metric("Stopped", metric_name)

    def trace(self, metric_name: str) -> None:
        """Record a non-timebound event, such as a button press.

        Args:
            metric_name: Name of the metric to fire a trace for.
        """
        self._send_metric("Trace", metric_name)

    def custom(self, action: str, metric_name: str) -> None:
        """Record a custom action, such as a button press

        Args:
            action: Name of the custom action
            metric_name: Name of the metric

        Example:
            metric.custom("Pressed", "Btn_On")
        """
        self._send_metric(action, metric_name)


if __name__ == "__main__":
    # Quick self-test. Make sure to enter your Lambda URI and Bearer Token
    uri = ""
    bearer = ""
    test = AWS_ServerlessMetrics("test_pc", "lambda", uri, bearer)
    test.trace("Hello AWS!")
    test.start("TestStart")
    test.stop("TestStop")
