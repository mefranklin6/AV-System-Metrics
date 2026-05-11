import ipaddress
import json
import logging
import os
import uuid
from datetime import datetime

import boto3

ALLOWED_NET_CIDR = os.environ.get("ALLOWED_NET", None)

if ALLOWED_NET_CIDR:
    ALLOWED_NET = ipaddress.ip_network(ALLOWED_NET_CIDR)

TABLE_NAME = os.environ.get("TABLE_NAME", "")
BEARER_TOKEN = os.environ.get("BEARER_TOKEN", "")

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
            return response(500, {"error": str(e)})

    # Check for bearer token
    headers = event.get("headers", {}) or {}
    auth_header = headers.get("authorization") or headers.get("Authorization")

    if not auth_header or not auth_header.startswith("Bearer "):
        logging.warning(f"Missing or invalid Authorization header: {auth_header}")
        return response(401, {"error": "Missing or invalid Authorization header"})

    token = auth_header.split(" ", 1)[1]

    if token != BEARER_TOKEN:
        logging.warning(f"Invalid token: {token}")
        return response(403, {"error": "Invalid token"})

    try:
        method = event.get("requestContext", {}).get("http", {}).get("method")
        if method != "POST":
            return response(405, {"error": "Method not allowed"})

        body = json.loads(event.get("body") or "{}")

        clientname = body.get("clientname")
        metric = body.get("metric")
        action = body.get("action")
        timestamp = body.get("timestamp")

        if not clientname or not metric or not action or not timestamp:
            return response(
                400,
                {
                    "error": "Missing required fields: clientname, metric, action, timestamp"
                },
            )

        event_id = str(uuid.uuid4())

        item = {
            "clientname": clientname,  # PK
            "sk": f"{timestamp}#{event_id}",  # SK
            "timestamp": timestamp,
            "metric": metric,
            "action": action,
            "event_id": event_id,
            "received_at": datetime.now().isoformat(),
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
        return response(500, {"error": str(e)})


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }
