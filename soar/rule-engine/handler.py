"""
SOAR rule engine.

Consumes normalised events from SQS, evaluates them against the declarative
playbooks in playbooks.json, and dispatches matched actions onto an EventBridge
bus. It never performs a response action itself.

That separation is deliberate. The engine holds no AWS mutation permissions at
all — it can publish an event saying "this IP should be blocked", but it cannot
block anything. A flaw in rule evaluation therefore cannot directly damage the
environment, and each action's blast radius is bounded by its own IAM role.
"""

import ipaddress
import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Key

log = logging.getLogger()
log.setLevel(logging.INFO)

events_client = boto3.client("events")
dynamodb = boto3.resource("dynamodb")

EVENT_BUS = os.environ["EVENT_BUS_NAME"]
EVENTS_TABLE = os.environ["EVENTS_TABLE"]
PLAYBOOK_PATH = os.environ.get("PLAYBOOK_PATH", "playbooks.json")

table = dynamodb.Table(EVENTS_TABLE)

with open(PLAYBOOK_PATH) as fh:
    PLAYBOOKS = json.load(fh)

INTERNAL_NETS = [
    ipaddress.ip_network(c)
    for c in PLAYBOOKS.get("defaults", {}).get("internal_networks", [])
]


def emit_metric(name: str, value: float, **dimensions):
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


def is_external(ip: str) -> bool:
    """Unparseable or absent addresses are treated as internal, so that a
    malformed event can never trigger a block."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return not any(addr in net for net in INTERNAL_NETS)


def count_recent(source_ip: str, window_minutes: int) -> int:
    """
    Correlation via the source_ip GSI.

    This is what makes a threshold rule possible: one failed login is noise,
    five in five minutes from the same address is an attack. Querying the index
    rather than scanning keeps the cost flat as the table grows.
    """
    if source_ip in ("unknown", ""):
        return 0

    since = (datetime.now(timezone.utc) - timedelta(minutes=window_minutes)).isoformat()
    try:
        response = table.query(
            IndexName="source_ip-received_at-index",
            KeyConditionExpression=Key("source_ip").eq(source_ip) & Key("received_at").gte(since),
            Select="COUNT",
        )
        return response.get("Count", 0)
    except Exception:
        log.exception("Correlation query failed for %s", source_ip)
        # Fail closed: report 1 so a threshold rule does not fire on bad data.
        return 1


def matches(playbook: dict, event: dict) -> tuple:
    """Return (matched, reason). The reason is logged so that a rule which
    does not fire during a demonstration can be explained immediately."""
    if not playbook.get("enabled", True):
        return False, "playbook disabled"

    criteria = playbook.get("match", {})

    if "event_type" in criteria and event.get("event_type") not in criteria["event_type"]:
        return False, "event_type mismatch"

    if "severity" in criteria and event.get("severity") not in criteria["severity"]:
        return False, "severity mismatch"

    conditions = playbook.get("conditions", {})

    if conditions.get("source_ip_is_external") and not is_external(event.get("source_ip", "")):
        return False, "source address is internal"

    if conditions.get("requires_target_instance") and not event.get("target_instance_id"):
        return False, "no target instance id on event"

    threshold = conditions.get("threshold")
    if threshold:
        group_by = threshold.get("group_by", "source_ip")
        occurrences = count_recent(event.get(group_by, ""), threshold["window_minutes"])
        if occurrences < threshold["count"]:
            return False, (
                f"below threshold ({occurrences}/{threshold['count']} "
                f"in {threshold['window_minutes']}m)"
            )

    return True, "matched"


def dispatch(action: dict, event: dict, playbook: dict) -> bool:
    detail = {
        "action_params": action.get("params", {}),
        "event": event,
        "playbook_id": playbook["id"],
        "playbook_name": playbook["name"],
        "dispatched_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        response = events_client.put_events(Entries=[{
            "Source": "innovatech.soar",
            "DetailType": f"soar.action.{action['type']}",
            "Detail": json.dumps(detail),
            "EventBusName": EVENT_BUS,
        }])
        if response.get("FailedEntryCount", 0):
            log.error("EventBridge rejected the entry: %s", response)
            emit_metric("ActionsDispatchFailed", 1, ActionType=action["type"])
            return False

        log.info("Dispatched %s for %s (%s)", action["type"], event["event_id"], playbook["id"])
        emit_metric("ActionsDispatched", 1,
                    ActionType=action["type"], PlaybookId=playbook["id"])
        return True
    except Exception:
        log.exception("Dispatch failed for action %s", action["type"])
        emit_metric("ActionsDispatchFailed", 1, ActionType=action["type"])
        return False


def process(event: dict):
    matched_any = False

    for playbook in PLAYBOOKS["playbooks"]:
        matched, reason = matches(playbook, event)
        if not matched:
            log.debug("%s did not match %s: %s", playbook["id"], event["event_id"], reason)
            continue

        matched_any = True
        log.info("Event %s matched %s (%s)", event["event_id"], playbook["id"], playbook["name"])
        emit_metric("PlaybookMatched", 1, PlaybookId=playbook["id"])

        for action in playbook.get("actions", []):
            dispatch(action, event, playbook)

    if not matched_any:
        # Worth surfacing on the dashboard: a rising unmatched rate means the
        # rule set has drifted behind the threat landscape.
        log.info("No playbook matched event %s (%s)",
                 event["event_id"], event.get("event_type"))
        emit_metric("EventsUnmatched", 1, EventType=event.get("event_type", "unknown"))


def handler(lambda_event, context):
    """
    SQS batch handler using partial batch response: only genuinely failed
    messages are returned for retry, so one bad event cannot cause the whole
    batch to be redelivered.
    """
    failures = []

    for record in lambda_event.get("Records", []):
        try:
            process(json.loads(record["body"]))
        except Exception:
            log.exception("Processing failed for message %s", record["messageId"])
            emit_metric("EventsProcessingFailed", 1)
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}
