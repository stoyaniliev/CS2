"""
Scheduled cleanup: lift expired IP blocks.

Without this, every block is permanent and the NACL fills up until the 20-rule
default quota is exhausted and no further blocks are possible. Runs every five
minutes on an EventBridge schedule.
"""
import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
blocks = boto3.resource("dynamodb").Table(os.environ["BLOCKS_TABLE"])


def emit_metric(name, value, **dims):
    print(json.dumps({
        "_aws": {"Timestamp": int(time.time() * 1000),
                 "CloudWatchMetrics": [{"Namespace": "Innovatech/SOAR",
                                        "Dimensions": [list(dims.keys())] if dims else [[]],
                                        "Metrics": [{"Name": name, "Unit": "Count"}]}]},
        **dims, name: value}))


def handler(event, context):
    now = int(time.time())
    expired = blocks.scan(
        FilterExpression=Attr("status").eq("active") & Attr("expires_at").lt(now)
    ).get("Items", [])

    lifted = 0
    for item in expired:
        try:
            ec2.delete_network_acl_entry(
                NetworkAclId=item["nacl_id"],
                RuleNumber=int(item["rule_number"]),
                Egress=False,
            )
        except ec2.exceptions.ClientError as exc:
            # Already gone is a success, not a failure.
            if "InvalidNetworkAclEntry.NotFound" not in str(exc):
                log.exception("Could not remove rule %s", item["rule_number"])
                continue

        blocks.update_item(
            Key={"cidr": item["cidr"]},
            UpdateExpression="SET #s = :s, lifted_at = :t",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "expired",
                ":t": datetime.now(timezone.utc).isoformat(),
            },
        )
        lifted += 1
        log.info("Lifted expired block on %s", item["cidr"])

    emit_metric("BlocksExpired", lifted)
    return {"lifted": lifted}
