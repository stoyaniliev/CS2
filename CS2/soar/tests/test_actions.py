"""
Response action tests.

These cover the refusal conditions rather than the happy paths. For a system
permitted to change production on its own, the guards are the safety-critical
code, and an untested guard is an assumption.
"""
import unittest
from unittest.mock import MagicMock

from base import load

block = load("actions/block_ip", "handler")
quarantine = load("actions/quarantine_host", "handler")
notify = load("actions/notify", "handler")


def detail(**event_fields):
    ev = {"event_id": "e1", "source_ip": "203.0.113.66", "description": "test",
          "target_instance_id": "", "event_type": "ssh_auth_failure",
          "severity": "high", "received_at": "2026-08-22T14:00:00+00:00",
          "source": "syslog", "target_host": "h"}
    ev.update(event_fields)
    return {"detail": {"event": ev, "action_params": {}, "playbook_id": "PB-001",
                       "playbook_name": "test"}}


class BlockIpGuards(unittest.TestCase):
    def test_refuses_private_ranges(self):
        """An automated blocker that can be induced to block internal addresses
        can lock its own operators out of the environment."""
        for ip in ["10.1.10.5", "172.16.0.9", "192.168.100.20", "127.0.0.1"]:
            with self.subTest(ip=ip):
                self.assertTrue(block.is_protected(ip))

    def test_allows_public_addresses(self):
        self.assertFalse(block.is_protected("203.0.113.66"))

    def test_refuses_unparseable_addresses(self):
        for bad in ["", "unknown", "not-an-ip"]:
            with self.subTest(bad=bad):
                self.assertTrue(block.is_protected(bad))

    def test_protected_address_is_skipped_not_blocked(self):
        result = block.handler(detail(source_ip="10.1.10.5"), None)
        self.assertEqual(result["status"], "skipped")
        block.ec2.create_network_acl_entry.assert_not_called()


class RuleNumberAllocation(unittest.TestCase):
    def test_first_free_number_is_used(self):
        entries = [{"RuleNumber": 100, "Egress": False},
                   {"RuleNumber": 101, "Egress": False}]
        self.assertEqual(block.next_rule_number(entries), 102)

    def test_egress_rules_do_not_consume_ingress_numbers(self):
        entries = [{"RuleNumber": 100, "Egress": True}]
        self.assertEqual(block.next_rule_number(entries), 100)

    def test_exhaustion_raises_rather_than_overwriting(self):
        entries = [{"RuleNumber": n, "Egress": False} for n in range(100, 400)]
        with self.assertRaises(RuntimeError):
            block.next_rule_number(entries)


class QuarantineGuards(unittest.TestCase):
    def setUp(self):
        quarantine.ec2.reset_mock()

    def _instance(self, tags, sgs=("sg-normal",)):
        quarantine.ec2.describe_instances.return_value = {
            "Reservations": [{"Instances": [{
                "Tags": [{"Key": k, "Value": v} for k, v in tags.items()],
                "SecurityGroups": [{"GroupId": g} for g in sgs],
            }]}]
        }

    def test_refuses_instance_without_soarable_tag(self):
        self._instance({"Name": "some-host"})
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["status"], "skipped")
        quarantine.ec2.modify_instance_attribute.assert_not_called()

    def test_refuses_the_k3s_server(self):
        """The system must not be able to isolate the infrastructure it runs on."""
        self._instance({"SOARable": "true", "Role": "k3s-server"})
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["status"], "skipped")
        self.assertIn("protected", r["reason"])
        quarantine.ec2.modify_instance_attribute.assert_not_called()

    def test_refuses_the_hybrid_gateway(self):
        self._instance({"SOARable": "true", "Role": "hybrid-gateway"})
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["status"], "skipped")
        quarantine.ec2.modify_instance_attribute.assert_not_called()

    def test_skips_when_no_instance_id_present(self):
        r = quarantine.handler(detail(), None)
        self.assertEqual(r["status"], "skipped")

    def test_already_quarantined_is_idempotent(self):
        self._instance({"SOARable": "true", "Role": "demo-target"},
                       sgs=(quarantine.QUARANTINE_SG_ID,))
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["status"], "already_quarantined")
        quarantine.ec2.modify_instance_attribute.assert_not_called()

    def test_tagged_instance_is_isolated(self):
        self._instance({"SOARable": "true", "Role": "demo-target"})
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["status"], "quarantined")
        quarantine.ec2.modify_instance_attribute.assert_called_once()
        kwargs = quarantine.ec2.modify_instance_attribute.call_args.kwargs
        self.assertEqual(kwargs["Groups"], [quarantine.QUARANTINE_SG_ID])

    def test_original_groups_are_recorded_for_restoration(self):
        self._instance({"SOARable": "true", "Role": "demo-target"}, sgs=("sg-a", "sg-b"))
        r = quarantine.handler(detail(target_instance_id="i-123"), None)
        self.assertEqual(r["original_security_groups"], ["sg-a", "sg-b"])


class Notify(unittest.TestCase):
    def test_publishes_with_playbook_context(self):
        notify.sns.reset_mock()
        notify.sns.publish.return_value = {"MessageId": "m1"}
        r = notify.handler(detail(), None)
        self.assertEqual(r["status"], "notified")
        body = notify.sns.publish.call_args.kwargs["Message"]
        self.assertIn("PB-001", body)
        self.assertIn("203.0.113.66", body)


if __name__ == "__main__":
    unittest.main()
