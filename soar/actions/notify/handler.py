"""
Response action: notify the operations team.

The lowest-risk action in the set, and therefore the one every playbook can
safely include. Message body is written for a human reading it on a phone at
03:00: what happened, where, and what the system already did about it.
"""
import json
import logging
import os
import time

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

sns = boto3.client("sns")
TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

PRIORITY_PREFIX = {
    "critical": "CRITICAL", "high": "HIGH",
    "medium": "MEDIUM", "low": "INFO",
}


def emit_metric(name, value, **dims):
    print(json.dumps({
        "_aws": {"Timestamp": int(time.time() * 1000),
                 "CloudWatchMetrics": [{"Namespace": "Innovatech/SOAR",
                                        "Dimensions": [list(dims.keys())] if dims else [[]],
                                        "Metrics": [{"Name": name, "Unit": "Count"}]}]},
        **dims, name: value}))


def handler(event, context):
    detail = event["detail"]
    src = detail["event"]
    params = detail.get("action_params", {})

    priority = params.get("priority", "medium")
    subject = params.get("subject", "[SOAR] Security event")[:100]

    body = f"""{PRIORITY_PREFIX.get(priority, 'INFO')} - Innovatech SOAR

Playbook   : {detail.get('playbook_id', 'n/a')} - {detail.get('playbook_name', 'n/a')}
Event ID   : {src.get('event_id', 'n/a')}
Type       : {src.get('event_type', 'n/a')}
Severity   : {src.get('severity', 'n/a')}
Detected   : {src.get('received_at', 'n/a')}
Source     : {src.get('source', 'n/a')}
Source IP  : {src.get('source_ip', 'n/a')}
Target     : {src.get('target_host', 'n/a')} {src.get('target_instance_id', '')}

Description
{src.get('description', 'No description provided.')}

This message was generated automatically by the Innovatech SOAR system.
Response actions for this playbook have already been executed; review the
SOAR Operations dashboard in Grafana for their outcome.
"""

    try:
        response = sns.publish(TopicArn=TOPIC_ARN, Subject=subject, Message=body)
    except Exception:
        log.exception("SNS publish failed")
        emit_metric("ActionsFailed", 1, ActionType="notify")
        raise

    log.info("Notified: %s (%s)", subject, response["MessageId"])
    emit_metric("ActionsExecuted", 1, ActionType="notify")
    return {"status": "notified", "message_id": response["MessageId"]}
