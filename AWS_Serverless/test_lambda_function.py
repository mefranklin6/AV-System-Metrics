import importlib
import os
import sys
import types
import unittest
from unittest import mock


class DummyDynamoResource:
    def Table(self, _table_name):
        return object()


def load_lambda_function():
    boto3_stub = types.ModuleType("boto3")
    boto3_stub.resource = lambda _service_name: DummyDynamoResource()
    sys.modules["boto3"] = boto3_stub

    os.environ.setdefault("TABLE_NAME", "metrics")
    os.environ.setdefault("BEARER_TOKEN", "test-token")

    return importlib.import_module("AWS_Serverless.lambda_function")


lambda_function = load_lambda_function()


class ConfigTests(unittest.TestCase):
    def test_require_secret_env_rejects_example_bearer_token(self):
        with mock.patch.dict(
            os.environ,
            {"BEARER_TOKEN": "change-me-long-random-token"},
        ):
            with self.assertRaisesRegex(RuntimeError, "BEARER_TOKEN must be changed"):
                lambda_function.require_secret_env(
                    "BEARER_TOKEN",
                    lambda_function.EXAMPLE_BEARER_TOKENS,
                )

    def test_require_secret_env_accepts_changed_bearer_token(self):
        with mock.patch.dict(os.environ, {"BEARER_TOKEN": "test-token"}):
            self.assertEqual(
                lambda_function.require_secret_env(
                    "BEARER_TOKEN",
                    lambda_function.EXAMPLE_BEARER_TOKENS,
                ),
                "test-token",
            )

    def test_require_secret_env_rejects_missing_bearer_token(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "BEARER_TOKEN is required"):
                lambda_function.require_secret_env(
                    "BEARER_TOKEN",
                    lambda_function.EXAMPLE_BEARER_TOKENS,
                )

    def test_require_env_accepts_table_name(self):
        with mock.patch.dict(os.environ, {"TABLE_NAME": "metrics"}, clear=True):
            self.assertEqual(lambda_function.require_env("TABLE_NAME"), "metrics")

    def test_require_env_rejects_missing_table_name(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "TABLE_NAME is required"):
                lambda_function.require_env("TABLE_NAME")


class TimestampTests(unittest.TestCase):
    def test_build_item_normalizes_offset_timestamp_to_utc(self):
        item, error = lambda_function.build_item(
            {
                "clientname": "workstation",
                "metric": "trace",
                "action": "testing",
                "timestamp": "2026-06-16T21:00:00-07:00",
            },
            "192.0.2.10",
        )

        self.assertIsNone(error)
        self.assertEqual(item["timestamp"], "2026-06-17T04:00:00.000000Z")
        self.assertTrue(item["sk"].startswith("2026-06-17T04:00:00.000000Z#"))

    def test_build_item_treats_timezone_less_timestamp_as_utc(self):
        item, error = lambda_function.build_item(
            {
                "clientname": "workstation",
                "metric": "trace",
                "action": "testing",
                "timestamp": "2026-06-16T21:00:00",
            },
            "192.0.2.10",
        )

        self.assertIsNone(error)
        self.assertEqual(item["timestamp"], "2026-06-16T21:00:00.000000Z")

    def test_build_item_rejects_invalid_timestamp(self):
        item, error = lambda_function.build_item(
            {
                "clientname": "workstation",
                "metric": "trace",
                "action": "testing",
                "timestamp": "not-a-date",
            },
            "192.0.2.10",
        )

        self.assertIsNone(item)
        self.assertEqual(error, "Invalid timestamp format, expected ISO 8601")


if __name__ == "__main__":
    unittest.main()
