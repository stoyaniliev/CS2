"""
Rule engine tests.

This is the component that decides whether the system acts, so the matching
logic and the safety-relevant defaults are what these tests pin down. The
threshold and external-address checks in particular are what stop a single
mistyped password from getting somebody blocked.
"""
import unittest
from unittest.mock import MagicMock, patch

from base import load

engine = load("rule-engine", "handler")


def event(**kw):
    base = {
        "event_id": "e1", "received_at": "2026-08-22T14:00:00+00:00",
        "source": "syslog", "event_type": "ssh_auth_failure", "severity": "high",
        "source_ip": "203.0.113.66", "target_host": "corp-server",
        "target_instance_id": "", "description": "", "raw": {},
    }
    base.update(kw)
    return base


def playbook(pid):
    return next(p for p in engine.PLAYBOOKS["playbooks"] if p["id"] == pid)


class ExternalAddressCheck(unittest.TestCase):
    def test_public_address_is_external(self):
        self.assertTrue(engine.is_external("203.0.113.66"))

    def test_private_ranges_are_internal(self):
        for ip in ["10.1.10.5", "172.16.0.9", "192.168.100.20"]:
            with self.subTest(ip=ip):
                self.assertFalse(engine.is_external(ip))

    def test_unparseable_is_treated_as_internal(self):
        """Fails safe: a malformed address must never trigger a block."""
        for bad in ["unknown", "", "not-an-ip", "999.1.1.1"]:
            with self.subTest(bad=bad):
                self.assertFalse(engine.is_external(bad))


class PlaybookMatching(unittest.TestCase):
    def test_brute_force_matches_when_threshold_met(self):
        with patch.object(engine, "count_recent", return_value=5):
            matched, reason = engine.matches(playbook("PB-001"), event())
        self.assertTrue(matched, reason)

    def test_brute_force_held_below_threshold(self):
        with patch.object(engine, "count_recent", return_value=3):
            matched, reason = engine.matches(playbook("PB-001"), event())
        self.assertFalse(matched)
        self.assertIn("threshold", reason)

    def test_internal_address_never_matches_brute_force(self):
        with patch.object(engine, "count_recent", return_value=50):
            matched, reason = engine.matches(playbook("PB-001"), event(source_ip="10.1.10.5"))
        self.assertFalse(matched)
        self.assertIn("internal", reason)

    def test_wrong_event_type_does_not_match(self):
        matched, reason = engine.matches(playbook("PB-001"), event(event_type="disk_full"))
        self.assertFalse(matched)
        self.assertIn("event_type", reason)

    def test_low_severity_does_not_match(self):
        with patch.object(engine, "count_recent", return_value=99):
            matched, reason = engine.matches(playbook("PB-001"), event(severity="low"))
        self.assertFalse(matched)
        self.assertIn("severity", reason)

    def test_quarantine_requires_an_instance_id(self):
        ev = event(event_type="privilege_escalation_attempt", severity="critical")
        matched, reason = engine.matches(playbook("PB-002"), ev)
        self.assertFalse(matched)
        self.assertIn("instance", reason)

    def test_quarantine_matches_with_instance_id(self):
        ev = event(event_type="privilege_escalation_attempt", severity="critical",
                   target_instance_id="i-049e95348a865e18d")
        matched, reason = engine.matches(playbook("PB-002"), ev)
        self.assertTrue(matched, reason)

    def test_disabled_playbook_never_matches(self):
        pb = dict(playbook("PB-001"))
        pb["enabled"] = False
        matched, reason = engine.matches(pb, event())
        self.assertFalse(matched)
        self.assertIn("disabled", reason)


class CorrelationFailsClosed(unittest.TestCase):
    def test_query_failure_returns_one(self):
        """A database problem must not cause a threshold rule to fire."""
        engine.table.query.side_effect = RuntimeError("boom")
        try:
            self.assertEqual(engine.count_recent("203.0.113.66", 5), 1)
        finally:
            engine.table.query.side_effect = None

    def test_unknown_address_is_not_counted(self):
        self.assertEqual(engine.count_recent("unknown", 5), 0)


class Dispatch(unittest.TestCase):
    def setUp(self):
        engine.events_client.reset_mock()
        engine.events_client.put_events.return_value = {"FailedEntryCount": 0}

    def test_availability_alert_notifies_but_does_not_contain(self):
        """PB-004 is notify-only on purpose: isolating an unhealthy host
        would turn a partial outage into a total one."""
        ev = event(event_type="ServiceDown", severity="high",
                   target_instance_id="i-049e95348a865e18d")
        engine.process(ev)
        dispatched = [c.kwargs["Entries"][0]["DetailType"]
                      for c in engine.events_client.put_events.call_args_list]
        self.assertIn("soar.action.notify", dispatched)
        self.assertNotIn("soar.action.quarantine_host", dispatched)

    def test_brute_force_dispatches_block_and_notify(self):
        with patch.object(engine, "count_recent", return_value=5):
            engine.process(event())
        dispatched = [c.kwargs["Entries"][0]["DetailType"]
                      for c in engine.events_client.put_events.call_args_list]
        self.assertIn("soar.action.block_ip", dispatched)
        self.assertIn("soar.action.notify", dispatched)

    def test_unmatched_event_dispatches_nothing(self):
        engine.process(event(event_type="something_nobody_handles", severity="low"))
        engine.events_client.put_events.assert_not_called()


class BatchHandling(unittest.TestCase):
    def test_bad_message_reported_without_failing_the_batch(self):
        result = engine.handler({"Records": [
            {"messageId": "good", "body": '{"event_type":"noop","severity":"low"}'},
            {"messageId": "bad", "body": "{not json"},
        ]}, None)
        ids = [f["itemIdentifier"] for f in result["batchItemFailures"]]
        self.assertEqual(ids, ["bad"])


class PlaybookIntegrity(unittest.TestCase):
    def test_ids_are_unique(self):
        ids = [p["id"] for p in engine.PLAYBOOKS["playbooks"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_action_is_implemented(self):
        known = {"block_ip", "quarantine_host", "notify"}
        for p in engine.PLAYBOOKS["playbooks"]:
            for a in p.get("actions", []):
                with self.subTest(playbook=p["id"], action=a["type"]):
                    self.assertIn(a["type"], known)

    def test_every_playbook_has_match_criteria(self):
        for p in engine.PLAYBOOKS["playbooks"]:
            with self.subTest(playbook=p["id"]):
                self.assertTrue(p.get("match"))


if __name__ == "__main__":
    unittest.main()
