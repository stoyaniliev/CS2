"""
SOAR event collector.

Single ingress point for every security-relevant event, whatever its origin:

  - Prometheus Alertmanager webhooks (cloud workloads)
  - rsyslog / Fluent Bit forwarders (on-premises servers and workstations)
  - CloudWatch alarms delivered through SNS (managed AWS services)

Each source has its own wire format. This function normalises all of them into
one internal event schema so that the rule engine never has to know where an
event came from. Adding a fourth source later means adding one parser here and
changing nothing downstream.

Flow: API Gateway (private) -> this function -> DynamoDB (audit) + SQS (work).
"""

import hashlib
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")

EVENTS_TABLE = os.environ["EVENTS_TABLE"]
INGEST_QUEUE_URL = os.environ["INGEST_QUEUE_URL"]
EVENT_TTL_DAYS = int(os.environ.get("EVENT_TTL_DAYS", "30"))

table = dynamodb.Table(EVENTS_TABLE)

SEVERITY_MAP = {
    "critical": "critical", "crit": "critical", "emergency": "critical",
    "page": "critical", "error": "high", "err": "high", "high": "high",
    "warning": "medium", "warn": "medium", "medium": "medium",
    "notice": "low", "info": "low", "low": "low", "none": "low",
}

# Recognises the failed-password lines OpenSSH writes on a rejected login.
SSHD_FAILED = re.compile(
    r"Failed (?:password|publickey) for (?:invalid user )?(?P<user>\S+) "
    r"from (?P<ip>\d{1,3}(?:\.\d{1,3}){3}) port (?P<port>\d+)"
)
SUDO_FAILURE = re.compile(r"sudo:.*authentication failure.*user=(?P<user>\S+)")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _normalise_severity(value) -> str:
    return SEVERITY_MAP.get(str(value or "").strip().lower(), "medium")


def _new_event(**kwargs) -> dict:
    """Build an event carrying every field the rule engine may inspect."""
    event = {
        "event_id": str(uuid.uuid4()),
        "received_at": _now_iso(),
        "source": "unknown",
        "event_type": "unclassified",
        "severity": "medium",
        "source_ip": "unknown",       # DynamoDB GSI key: never leave empty
        "target_host": "unknown",
        "target_instance_id": "",
        "description": "",
        "raw": {},
    }
    event.update({k: v for k, v in kwargs.items() if v is not None})
    event["expires_at"] = int(time.time()) + EVENT_TTL_DAYS * 86400
    return event


# --------------------------------------------------------------------------
# Source-specific parsers
# --------------------------------------------------------------------------

def parse_alertmanager(body: dict) -> list:
    """Alertmanager posts a batch; only firing alerts are actionable."""
    events = []
    for alert in body.get("alerts", []):
        if alert.get("status") != "firing":
            continue
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        events.append(_new_event(
            source="alertmanager",
            event_type=labels.get("soar_event_type") or labels.get("alertname", "unclassified"),
            severity=_normalise_severity(labels.get("severity")),
            source_ip=labels.get("source_ip") or "unknown",
            target_host=labels.get("instance", "unknown"),
            target_instance_id=labels.get("instance_id", ""),
            description=annotations.get("summary") or annotations.get("description", ""),
            raw={"labels": labels, "annotations": annotations},
        ))
    return events


def parse_syslog(body: dict) -> list:
    """
    On-premises forwarder payload:
        {"host": "corp-server", "message": "...", "severity": "err"}

    The raw line is inspected for patterns worth acting on. Anything
    unrecognised is still stored — an event nobody has written a rule for yet
    is a gap in coverage, not something to discard silently.
    """
    message = body.get("message", "")
    host = body.get("host", "unknown")
    severity = _normalise_severity(body.get("severity"))

    match = SSHD_FAILED.search(message)
    if match:
        return [_new_event(
            source="syslog",
            event_type="ssh_auth_failure",
            severity="high",
            source_ip=match.group("ip"),
            target_host=host,
            description=f"Failed SSH authentication for user {match.group('user')}",
            raw={"message": message, "user": match.group("user")},
        )]

    match = SUDO_FAILURE.search(message)
    if match:
        return [_new_event(
            source="syslog",
            event_type="privilege_escalation_attempt",
            severity="high",
            target_host=host,
            description=f"sudo authentication failure for {match.group('user')}",
            raw={"message": message},
        )]

    return [_new_event(
        source="syslog",
        event_type="syslog_generic",
        severity=severity,
        target_host=host,
        description=message[:400],
        raw={"message": message},
    )]


def parse_cloudwatch(body: dict) -> list:
    alarm = body.get("AlarmName", "unknown")
    return [_new_event(
        source="cloudwatch",
        event_type="cloudwatch_alarm",
        severity="high" if body.get("NewStateValue") == "ALARM" else "low",
        target_host=alarm,
        description=body.get("NewStateReason", "")[:400],
        raw=body,
    )]


def detect_and_parse(body: dict) -> list:
    if "alerts" in body and "receiver" in body:
        return parse_alertmanager(body)
    if "AlarmName" in body:
        return parse_cloudwatch(body)
    if "message" in body:
        return parse_syslog(body)
    return [_new_event(
        source="direct",
        event_type=body.get("event_type", "unclassified"),
        severity=_normalise_severity(body.get("severity")),
        source_ip=body.get("source_ip", "unknown"),
        target_host=body.get("target_host", "unknown"),
        target_instance_id=body.get("target_instance_id", ""),
        description=body.get("description", ""),
        raw=body,
    )]


# --------------------------------------------------------------------------
# Observability of the SOAR system itself (REQ-NCA-P2-08)
# --------------------------------------------------------------------------

def emit_metric(name: str, value: float, **dimensions):
    """
    CloudWatch Embedded Metric Format: a structured log line that CloudWatch
    turns into a metric. Cheaper and faster than PutMetricData, because it adds
    no synchronous API call to the request path.
    """
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "Innovatech/SOAR",
                "Dimensions": [list(dimensions.keys())] if dimensions else [[]],
                "Metrics": [{"Name": name, "Unit": "Count"}],
            }],
        },
        **dimensions,
        name: value,
    }))


def handler(lambda_event, context):
    try:
        raw_body = lambda_event.get("body", lambda_event)
        body = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
    except (json.JSONDecodeError, TypeError) as exc:
        log.error("Unparseable payload: %s", exc)
        emit_metric("EventsRejected", 1, Reason="malformed_json")
        return {"statusCode": 400, "body": json.dumps({"error": "invalid JSON"})}

    events = detect_and_parse(body)
    accepted = 0

    for event in events:
        try:
            # Written before queuing: if the rule engine later fails, the
            # event still exists and can be replayed.
            table.put_item(Item=event)

            sqs.send_message(
                QueueUrl=INGEST_QUEUE_URL,
                MessageBody=json.dumps(event),
                MessageAttributes={
                    "event_type": {"StringValue": event["event_type"], "DataType": "String"},
                    "severity": {"StringValue": event["severity"], "DataType": "String"},
                },
            )
            accepted += 1
            emit_metric("EventsIngested", 1,
                        Source=event["source"], Severity=event["severity"])
            log.info("Ingested %s %s from %s",
                     event["event_id"], event["event_type"], event["source"])
        except Exception:
            log.exception("Failed to ingest event %s", event.get("event_id"))
            emit_metric("EventsRejected", 1, Reason="storage_failure")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "accepted": accepted,
            "event_ids": [e["event_id"] for e in events[:accepted]],
        }),
    }

# pipeline verification run
