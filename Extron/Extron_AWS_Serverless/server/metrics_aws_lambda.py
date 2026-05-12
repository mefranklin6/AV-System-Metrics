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


def lambda_handler(event, context):
    source_ip = event.get("requestContext", {}).get("http", {}).get("sourceIp", "")

    if ALLOWED_NET_CIDR:
        # Check for allowed source IP
        try:
            if ipaddress.ip_address(source_ip) not in ALLOWED_NET:
                logging.warning(f"Unauthorized IP: {source_ip}")
                return response(403, {"error": "Forbidden"})
        except ValueError:
            logging.warning(f"Invalid IP address received: {source_ip}")
            return response(403, {"error": "Forbidden"})
        except Exception as e:
            logging.error(repr(e))
            return response(500, {"error": "Internal Server Error"})

    # Check for bearer token
    headers = event.get("headers", {}) or {}
    auth_header = headers.get("authorization") or headers.get("Authorization")

    if not auth_header or not auth_header.startswith("Bearer "):
        logging.warning(f"Missing or invalid Authorization header: {auth_header}")
        return response(401, {"error": "Missing or invalid Authorization header"})

    token = auth_header.split(" ", 1)[1]

    if not hmac.compare_digest(token, BEARER_TOKEN):
        logging.warning("Invalid token")
        return response(403, {"error": "Invalid token"})

    try:
        method = event.get("requestContext", {}).get("http", {}).get("method")
        if method != "POST":
            logging.error("Method not allowed")
            return response(405, {"error": "Method not allowed"})

        raw_body = event.get("body") or "{}"
        if len(raw_body.encode("utf-8")) > 10_240:
            logging.error("Request body too large")
            return response(413, {"error": "Request body too large"})
        body = json.loads(raw_body)

        clientname = body.get("clientname")
        metric = body.get("metric")
        action = body.get("action")
        timestamp = body.get("timestamp")

        if not clientname or not metric or not action or not timestamp:
            logging.error("Missing required fields")
            return response(
                400,
                {
                    "error": "Missing required fields: clientname, metric, action, timestamp"
                },
            )

        MAX_FIELD_LEN = 128
        for field_name, field_value in (
            ("clientname", clientname),
            ("metric", metric),
            ("action", action),
        ):
            if not isinstance(field_value, str) or len(field_value) > MAX_FIELD_LEN:
                logging.error(
                    f"Field '{field_name}' must be a string of at most {MAX_FIELD_LEN} characters"
                )
                return response(
                    400,
                    {
                        "error": f"Field '{field_name}' must be a string of at most {MAX_FIELD_LEN} characters"
                    },
                )

        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            logging.error(f"Invalid timestamp format: {timestamp}")
            return response(
                400, {"error": "Invalid timestamp format, expected ISO 8601"}
            )

        event_id = str(uuid.uuid4())

        item = {
            "clientname": clientname,  # PK
            "sk": f"{timestamp}#{event_id}",  # SK
            "timestamp": timestamp,
            "metric": metric,
            "action": action,
            "event_id": event_id,
            "received_at": datetime.now(timezone.utc).isoformat(),
            "source_ip": source_ip,
        }

        table.put_item(Item=item)

        return response(
            201,
            {
                "ok": True,
            },
        )

    except Exception as e:
        logging.error(repr(e))
        return response(500, {"error": "Internal Server Error"})


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }
