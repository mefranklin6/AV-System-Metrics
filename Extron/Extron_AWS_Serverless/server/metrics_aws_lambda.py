"""AWS Lambda function that receives metric data and inserts into DynamoDB"""

import hmac
import ipaddress
import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3  # type: ignore

ALLOWED_NET_CIDR = os.environ.get("ALLOWED_NET", None)

if ALLOWED_NET_CIDR:
    ALLOWED_NET = ipaddress.ip_network(ALLOWED_NET_CIDR)

TABLE_NAME = os.environ["TABLE_NAME"]
BEARER_TOKEN = os.environ["BEARER_TOKEN"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)

MAX_BODY_BYTES = 10_240
MAX_FIELD_LEN = 128
MAX_MESSAGES = 25


class ClientError(Exception):
    """Expected request/client error."""

    def __init__(self, status_code, message, details=None):
        self.status_code = status_code
        self.message = message
        self.details = details
        super().__init__(message)


def lambda_handler(event, context):
    source_ip = event.get("requestContext", {}).get("http", {}).get("sourceIp", "")

    try:
        validate_source_ip(source_ip)
        validate_auth(event)
        validate_method(event)

        body = parse_body(event)
        messages = normalize_messages(body)

        if len(messages) > MAX_MESSAGES:
            raise ClientError(
                400,
                f"Too many messages. Maximum allowed is {MAX_MESSAGES}",
            )

        items = []
        validation_errors = []

        for index, message in enumerate(messages):
            item, error = build_item(message, source_ip)

            if error:
                validation_errors.append(
                    {
                        "index": index,
                        "error": error,
                    }
                )
            else:
                items.append(item)

        if validation_errors:
            raise ClientError(
                400,
                "One or more messages failed validation",
                {"errors": validation_errors},
            )

        write_items(items)

        return response(
            201,
            {
                "ok": True,
                "count": len(items),
            },
        )

    except ClientError as e:
        logging.warning(e.message)

        body = {"error": e.message}
        if e.details:
            body.update(e.details)

        return response(e.status_code, body)

    except Exception:
        logging.exception("Unexpected error while processing request")
        return response(500, {"error": "Internal Server Error"})


def validate_source_ip(source_ip):
    if not ALLOWED_NET_CIDR:
        return

    try:
        if ipaddress.ip_address(source_ip) not in ALLOWED_NET:
            logging.warning(f"Unauthorized IP: {source_ip}")
            raise ClientError(403, "Forbidden")
    except ValueError:
        logging.warning(f"Invalid IP address received: {source_ip}")
        raise ClientError(403, "Forbidden")


def validate_auth(event):
    headers = event.get("headers", {}) or {}
    auth_header = headers.get("authorization") or headers.get("Authorization")

    if not auth_header or not auth_header.startswith("Bearer "):
        raise ClientError(401, "Missing or invalid Authorization header")

    token = auth_header.split(" ", 1)[1]

    if not hmac.compare_digest(token, BEARER_TOKEN):
        raise ClientError(403, "Invalid token")


def validate_method(event):
    method = event.get("requestContext", {}).get("http", {}).get("method")

    if method != "POST":
        raise ClientError(405, "Method not allowed")


def parse_body(event):
    raw_body = event.get("body") or "{}"

    if len(raw_body.encode("utf-8")) > MAX_BODY_BYTES:
        raise ClientError(413, "Request body too large")

    try:
        return json.loads(raw_body)
    except json.JSONDecodeError:
        raise ClientError(400, "Invalid JSON body")


def normalize_messages(body):
    """
    Accepts any of the following payload shapes:

    Single message:
    {
        "clientname": "...",
        "metric": "...",
        "action": "...",
        "timestamp": "..."
    }

    List of messages:
    [
        {
            "clientname": "...",
            "metric": "...",
            "action": "...",
            "timestamp": "..."
        }
    ]

    Wrapped list:
    {
        "messages": [
            {
                "clientname": "...",
                "metric": "...",
                "action": "...",
                "timestamp": "..."
            }
        ]
    }
    """

    match body:
        case list():
            messages = body

        case {"messages": list() as messages}:
            pass

        case dict():
            messages = [body]

        case _:
            raise ClientError(400, "Request body must be an object or list of objects")

    if not messages:
        raise ClientError(400, "Request body must contain at least one message")

    for message in messages:
        if not isinstance(message, dict):
            raise ClientError(400, "Each message must be an object")

    return messages


def build_item(message, source_ip):
    clientname = message.get("clientname")
    metric = message.get("metric")
    action = message.get("action")
    timestamp = message.get("timestamp")

    if not clientname or not metric or not action or not timestamp:
        return None, "Missing required fields: clientname, metric, action, timestamp"

    for field_name, field_value in (
        ("clientname", clientname),
        ("metric", metric),
        ("action", action),
    ):
        if not isinstance(field_value, str) or len(field_value) > MAX_FIELD_LEN:
            return (
                None,
                f"Field '{field_name}' must be a string of at most {MAX_FIELD_LEN} characters",
            )

    if not isinstance(timestamp, str):
        return None, "Field 'timestamp' must be a string in ISO 8601 format"

    try:
        datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        logging.error(f"Invalid timestamp format: {timestamp}")
        return None, "Invalid timestamp format, expected ISO 8601"

    event_id = str(uuid.uuid4())

    item = {
        "clientname": clientname,
        "sk": f"{timestamp}#{event_id}",
        "timestamp": timestamp,
        "metric": metric,
        "action": action,
        "event_id": event_id,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "source_ip": source_ip,
    }

    return item, None


def write_items(items):
    with table.batch_writer() as batch:
        for item in items:
            batch.put_item(Item=item)


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }