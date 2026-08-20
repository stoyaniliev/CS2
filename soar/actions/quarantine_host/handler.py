"""
Response action: isolate a compromised host.

Replaces the instance's security groups with a group that has no ingress and no
egress rules. The instance keeps running and its disk stays intact, so memory
and disk forensics remain possible, but it can neither be reached nor call out
to a command-and-control endpoint.

Preferred over stopping the instance, which destroys volatile evidence, and
over terminating it, which destroys everything.

Two safety gates, because this action is destructive to availability:
  1. The instance must carry the tag SOARable=true.
  2. Instances tagged Role=k3s-server or Role=hybrid-gateway are never touched,
     since isolating those would disable the SOAR system itself.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
dynamodb = boto3.resource("dynamodb")

QUARANTINE_SG_ID = os.environ["QUARANTINE_SG_ID"]
QUARANTINE_TABLE = os.environ["QUARANTINE_TABLE"]
PROTECTED_ROLES = {"k3s-server", "hybrid-gateway"}

quarantines = dynamodb.Table(QUARANTINE_TABLE)


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
    instance_id = src.get("target_instance_id", "")

    if not instance_id:
        emit_metric("ActionsSkipped", 1, ActionType="quarantine_host", Reason="no_instance_id")
        return {"status": "skipped", "reason": "event carried no target instance id"}

    try:
        reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    except ec2.exceptions.ClientError:
        log.exception("Instance %s could not be described", instance_id)
        emit_metric("ActionsFailed", 1, ActionType="quarantine_host")
        return {"status": "failed", "reason": "instance not found", "instance_id": instance_id}

    instance = reservations[0]["Instances"][0]
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}

    if tags.get("Role") in PROTECTED_ROLES:
        log.error("Refusing to quarantine infrastructure host %s (%s)", instance_id, tags.get("Role"))
        emit_metric("ActionsSkipped", 1, ActionType="quarantine_host", Reason="protected_role")
        return {"status": "skipped", "reason": "protected infrastructure host"}

    if tags.get("SOARable") != "true":
        log.warning("Instance %s is not marked SOARable; refusing", instance_id)
        emit_metric("ActionsSkipped", 1, ActionType="quarantine_host", Reason="not_soarable")
        return {"status": "skipped", "reason": "instance not tagged SOARable=true"}

    original_sgs = [g["GroupId"] for g in instance["SecurityGroups"]]

    if original_sgs == [QUARANTINE_SG_ID]:
        emit_metric("ActionsSkipped", 1, ActionType="quarantine_host", Reason="already_quarantined")
        return {"status": "already_quarantined", "instance_id": instance_id}

    try:
        ec2.modify_instance_attribute(InstanceId=instance_id, Groups=[QUARANTINE_SG_ID])
    except Exception:
        log.exception("Failed to quarantine %s", instance_id)
        emit_metric("ActionsFailed", 1, ActionType="quarantine_host")
        raise

    # The original groups are stored so the host can be restored deliberately,
    # rather than an operator having to guess what it used to have.
    quarantines.put_item(Item={
        "instance_id": instance_id,
        "quarantined_at": datetime.now(timezone.utc).isoformat(),
        "original_security_groups": original_sgs,
        "quarantine_sg": QUARANTINE_SG_ID,
        "playbook_id": detail.get("playbook_id", ""),
        "event_id": src.get("event_id", ""),
        "reason": src.get("description", "")[:300],
        "status": "quarantined",
    })

    log.warning("QUARANTINED %s (was %s)", instance_id, original_sgs)
    emit_metric("ActionsExecuted", 1, ActionType="quarantine_host")

    return {"status": "quarantined", "instance_id": instance_id,
            "original_security_groups": original_sgs}
