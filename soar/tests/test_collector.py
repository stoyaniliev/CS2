"""
Collector tests.

The collector is the only component that sees raw source formats, so the parsing
rules are what matter here. A regression would silently misclassify events and
stop playbooks matching, with no error anywhere.
"""
import json
import unittest

from base import load, ALERTMANAGER, SYSLOG

collector = load("collector", "handler")


class SyslogParsing(unittest.TestCase):
    def test_failed_ssh_password_is_classified(self):
        e = collector.parse_syslog(SYSLOG)[0]
        self.assertEqual(e["event_type"], "ssh_auth_failure")
        self.assertEqual(e["source_ip"], "203.0.113.66")
        self.assertEqual(e["severity"], "high")
        self.assertEqual(e["raw"]["user"], "root")

    def test_sudo_failure_is_privilege_escalation(self):
        e = collector.parse_syslog({
            "host": "corp-server",
            "message": "sudo: pam_unix(sudo:auth): authentication failure; user=stoyan",
        })[0]
        self.assertEqual(e["event_type"], "privilege_escalation_attempt")
        self.assertEqual(e["severity"], "high")

    def test_invalid_user_is_classified_with_its_source(self):
        """The forwarder sends these, so the collector must handle them.
        Falling through to syslog_generic would lose the source address and
        no playbook could act."""
        e = collector.parse_syslog({
            "host": "corp-server",
            "message": ("Aug 23 11:04:02 corp-server sshd[901]: Invalid user "
                        "admin from 10.0.0.94 port 40122"),
        })[0]
        self.assertEqual(e["event_type"], "ssh_auth_failure")
        self.assertEqual(e["source_ip"], "10.0.0.94")
        self.assertEqual(e["severity"], "high")

    def test_break_in_warning_is_critical(self):
        e = collector.parse_syslog({
            "host": "corp-server",
            "message": ("reverse mapping checking getaddrinfo for host [203.0.113.9] "
                        "failed - POSSIBLE BREAK-IN ATTEMPT!"),
        })[0]
        self.assertEqual(e["event_type"], "ssh_auth_failure")
        self.assertEqual(e["source_ip"], "203.0.113.9")
        self.assertEqual(e["severity"], "critical")

    def test_every_pattern_the_forwarder_sends_is_classified(self):
        """Guards the contract between the two components. If the forwarder
        learns a new pattern and the collector does not, events arrive
        unclassified and silently do nothing."""
        samples = [
            "sshd[1]: Failed password for root from 203.0.113.66 port 22 ssh2",
            "sshd[1]: Invalid user admin from 203.0.113.66 port 22",
            "sudo: pam_unix(sudo:auth): authentication failure; user=stoyan",
        ]
        for msg in samples:
            with self.subTest(msg=msg[:40]):
                e = collector.parse_syslog({"host": "corp-server", "message": msg})[0]
                self.assertNotEqual(e["event_type"], "syslog_generic",
                                    f"forwarder sends this but collector does not classify it: {msg}")

    def test_unrecognised_line_is_kept_not_dropped(self):
        """An event with no rule yet is a coverage gap, not noise to discard."""
        events = collector.parse_syslog({"host": "h", "message": "Started daily cleanup."})
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event_type"], "syslog_generic")

    def test_source_ip_is_never_empty(self):
        """DynamoDB indexes source_ip. An empty value would break correlation."""
        e = collector.parse_syslog({"host": "h", "message": "nothing useful"})[0]
        self.assertEqual(e["source_ip"], "unknown")


class AlertmanagerParsing(unittest.TestCase):
    def test_only_firing_alerts_are_ingested(self):
        self.assertEqual(len(collector.parse_alertmanager(ALERTMANAGER)), 1)

    def test_soar_event_type_label_wins_over_alertname(self):
        e = collector.parse_alertmanager(ALERTMANAGER)[0]
        self.assertEqual(e["event_type"], "ServiceDown")

    def test_falls_back_to_alertname(self):
        e = collector.parse_alertmanager({
            "receiver": "soar-ingest",
            "alerts": [{"status": "firing",
                        "labels": {"alertname": "HostLowDisk", "severity": "warning"},
                        "annotations": {}}],
        })[0]
        self.assertEqual(e["event_type"], "HostLowDisk")
        self.assertEqual(e["severity"], "medium")


class SeverityNormalisation(unittest.TestCase):
    def test_mapping(self):
        cases = [("crit", "critical"), ("emergency", "critical"), ("err", "high"),
                 ("warning", "medium"), ("notice", "low"), ("nonsense", "medium"),
                 (None, "medium"), ("CRITICAL", "critical")]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(collector._normalise_severity(raw), expected)


class SourceDetection(unittest.TestCase):
    def test_alertmanager(self):
        self.assertEqual(collector.detect_and_parse(ALERTMANAGER)[0]["source"], "alertmanager")

    def test_syslog(self):
        self.assertEqual(collector.detect_and_parse(SYSLOG)[0]["source"], "syslog")

    def test_cloudwatch(self):
        e = collector.detect_and_parse({"AlarmName": "x", "NewStateValue": "ALARM"})[0]
        self.assertEqual(e["source"], "cloudwatch")
        self.assertEqual(e["severity"], "high")

    def test_direct(self):
        e = collector.detect_and_parse({
            "event_type": "port_scan_detected", "severity": "high", "source_ip": "1.2.3.4"})[0]
        self.assertEqual(e["source"], "direct")


class Handler(unittest.TestCase):
    def setUp(self):
        collector.table.reset_mock()
        collector.sqs.reset_mock()

    def test_malformed_json_is_rejected(self):
        r = collector.handler({"body": "{not json"}, None)
        self.assertEqual(r["statusCode"], 400)

    def test_valid_event_is_accepted_and_queued(self):
        r = collector.handler({"body": json.dumps(SYSLOG)}, None)
        self.assertEqual(r["statusCode"], 200)
        self.assertEqual(json.loads(r["body"])["accepted"], 1)
        collector.sqs.send_message.assert_called_once()

    def test_event_is_stored_as_well_as_queued(self):
        """A queue failure must not lose the audit record."""
        collector.handler({"body": json.dumps(SYSLOG)}, None)
        self.assertTrue(collector.table.put_item.called)


if __name__ == "__main__":
    unittest.main()
