"""
Shared test setup.

The handlers read configuration from environment variables and create boto3
clients at import time, so both must be arranged before the module under test is
imported.

boto3 is replaced with a stub rather than mocked in place. That keeps the suite
runnable on any machine with only a Python interpreter, which matters for a
self-hosted runner where installing the AWS SDK is an avoidable dependency. The
tests here cover parsing, matching and decision logic; the AWS calls themselves
are covered by the end-to-end scripts against the real environment.
"""
import os
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

ROOT = Path(__file__).resolve().parents[1]

os.environ.update({
    "EVENTS_TABLE": "test-events",
    "INGEST_QUEUE_URL": "https://sqs.test/queue",
    "EVENT_BUS_NAME": "test-bus",
    "PLATFORM_NACL_ID": "acl-test",
    "BLOCKS_TABLE": "test-blocks",
    "QUARANTINE_SG_ID": "sg-quarantine",
    "QUARANTINE_TABLE": "test-quarantines",
    "SNS_TOPIC_ARN": "arn:aws:sns:eu-central-1:000000000000:test",
    "PLAYBOOK_PATH": str(ROOT / "playbooks" / "playbooks.json"),
    "AWS_DEFAULT_REGION": "eu-central-1",
})


def _install_boto3_stub():
    if "boto3" in sys.modules and getattr(sys.modules["boto3"], "_is_stub", False):
        return
    boto3 = types.ModuleType("boto3")
    boto3._is_stub = True
    boto3.client = MagicMock(name="boto3.client")
    boto3.resource = MagicMock(name="boto3.resource")

    # boto3.dynamodb.conditions.Key / Attr, used by the rule engine and expiry
    conditions = types.ModuleType("boto3.dynamodb.conditions")

    class _Expr:
        def __init__(self, *a, **k): pass
        def eq(self, *a): return self
        def gte(self, *a): return self
        def lt(self, *a): return self
        def __and__(self, other): return self

    conditions.Key = _Expr
    conditions.Attr = _Expr
    dynamodb_mod = types.ModuleType("boto3.dynamodb")
    dynamodb_mod.conditions = conditions
    boto3.dynamodb = dynamodb_mod

    sys.modules["boto3"] = boto3
    sys.modules["boto3.dynamodb"] = dynamodb_mod
    sys.modules["boto3.dynamodb.conditions"] = conditions


_install_boto3_stub()


def load(module_dir, module_name):
    """Import a handler with a fresh set of stubbed AWS clients."""
    import boto3
    boto3.client.reset_mock()
    boto3.resource.reset_mock()
    boto3.client.return_value = MagicMock()
    boto3.resource.return_value.Table.return_value = MagicMock()

    path = str(ROOT / module_dir)
    sys.path.insert(0, path)
    try:
        sys.modules.pop(module_name, None)
        return __import__(module_name)
    finally:
        sys.path.remove(path)


ALERTMANAGER = {
    "receiver": "soar-ingest",
    "status": "firing",
    "alerts": [
        {"status": "firing",
         "labels": {"alertname": "TargetDown", "severity": "high",
                    "soar_event_type": "ServiceDown", "instance": "10.1.11.193:9100"},
         "annotations": {"summary": "target unreachable"}},
        {"status": "resolved",
         "labels": {"alertname": "TargetDown", "severity": "high"},
         "annotations": {}},
    ],
}

SYSLOG = {
    "host": "corp-server",
    "severity": "err",
    "message": ("Aug 22 14:03:11 corp-server sshd[2211]: Failed password for "
                "invalid user root from 203.0.113.66 port 51022 ssh2"),
}
