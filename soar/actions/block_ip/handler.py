"""
Response action: block a source IP at the network ACL.

A network ACL is used rather than a security group because ACLs are stateless
and evaluate DENY before ALLOW, so a block takes effect on existing flows as
well as new ones. Security groups have no deny concept at all.

Verifiable in the console within seconds of firing: VPC > Network ACLs >
Inbound rules shows a numbered DENY entry for the offending address.
"""
import ipaddress
import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
dynamodb = boto3.resource("dynamodb")

NACL_ID = os.environ["PLATFORM_NACL_ID"]
BLOCKS_TABLE = os.environ["BLOCKS_TABLE"]

# Rule numbers below 100 are reserved for static baseline rules, keeping
# operator-authored policy visually separate from machine-authored policy.
RULE_MIN, RULE_MAX = 100, 400

blocks = dynamodb.Table(BLOCKS_TABLE)

# Never block these, whatever a rule says. An automated system that can lock
# its own operators out of the environment is more dangerous than the attack.
NEVER_BLOCK = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
]


def emit_metric(name, value, **dims):
    print(json.dumps({
        "_aws": {"Timestamp": int(time.time() * 1000),
                 "CloudWatchMetrics": [{"Namespace": "Innovatech/SOAR",
                                        "Dimensions": [list(dims.keys())] if dims else [[]],
                                        "Metrics": [{"Name": name, "Unit": "Count"}]}]},
        **dims, name: value}))


def is_protected(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True  # unparseable: refuse
    return any(addr in net for net in NEVER_BLOCK)


def next_rule_number(entries) -> int:
    used = {e["RuleNumber"] for e in entries
            if e.get("Egress") is False and RULE_MIN <= e["RuleNumber"] <= RULE_MAX}
    for n in range(RULE_MIN, RULE_MAX):
        if n not in used:
            return n
    raise RuntimeError("No free NACL rule numbers; the block list needs pruning")


def handler(event, context):
    detail = event["detail"]
    src = detail["event"]
    params = detail.get("action_params", {})
    ip = src.get("source_ip", "")

    if is_protected(ip):
        log.warning("Refusing to block protected or invalid address %s", ip)
        emit_metric("ActionsSkipped", 1, ActionType="block_ip", Reason="protected_range")
        return {"status": "skipped", "reason": "protected or invalid address", "ip": ip}

    cidr = f"{ip}/32"
    duration = int(params.get("duration_minutes", 60))

    acl = ec2.describe_network_acls(NetworkAclIds=[NACL_ID])["NetworkAcls"][0]
    entries = acl["Entries"]

    for entry in entries:
        if entry.get("CidrBlock") == cidr and entry.get("RuleAction") == "deny" \
           and entry.get("Egress") is False:
            log.info("%s already blocked by rule %s", cidr, entry["RuleNumber"])
            emit_metric("ActionsSkipped", 1, ActionType="block_ip", Reason="already_blocked")
            return {"status": "already_blocked", "ip": ip, "rule_number": entry["RuleNumber"]}

    rule_number = next_rule_number(entries)
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=duration)

    try:
        ec2.create_network_acl_entry(
            NetworkAclId=NACL_ID,
            RuleNumber=rule_number,
            Protocol="-1",
            RuleAction="deny",
            Egress=False,
            CidrBlock=cidr,
        )
    except Exception:
        log.exception("Failed to create NACL entry for %s", cidr)
        emit_metric("ActionsFailed", 1, ActionType="block_ip")
        raise

    # Recorded so the scheduled expiry function can lift the block later, and
    # so every automated change has an audit trail with a reason attached.
    blocks.put_item(Item={
        "cidr": cidr,
        "rule_number": rule_number,
        "nacl_id": NACL_ID,
        "blocked_at": datetime.now(timezone.utc).isoformat(),
        "expires_at_iso": expires_at.isoformat(),
        "expires_at": int(expires_at.timestamp()),
        "playbook_id": detail.get("playbook_id", ""),
        "event_id": src.get("event_id", ""),
        "reason": src.get("description", "")[:300],
        "status": "active",
    })

    log.info("BLOCKED %s as NACL rule %s for %s minutes", cidr, rule_number, duration)
    emit_metric("ActionsExecuted", 1, ActionType="block_ip")

    return {"status": "blocked", "ip": ip, "cidr": cidr,
            "rule_number": rule_number, "expires_at": expires_at.isoformat()}
