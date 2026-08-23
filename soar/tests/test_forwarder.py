"""
Forwarder agent tests.

The forwarder had no tests, and shipped with a defect that made it crash on the
very first line it tried to forward: it called tell() while iterating the file
object, which Python disallows because the iterator reads ahead in blocks.

The agent ran, logged that it was watching the file, and died. systemd restarted
it 371 times before anyone looked. These tests exercise the real tail loop
against a real file so that failure mode cannot return.
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from base import ROOT

sys.path.insert(0, str(ROOT / "forwarder"))


class ForwarderTail(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = Path(self.dir) / "auth.log"
        self.state = Path(self.dir) / "offset"
        self.log.write_text("")

        os.environ["SOAR_INGEST_URL"] = "https://example.invalid/events"
        os.environ["WATCH_FILE"] = str(self.log)
        os.environ["STATE_FILE"] = str(self.state)
        os.environ["POLL_SECONDS"] = "0"

        sys.modules.pop("syslog_forwarder", None)
        import syslog_forwarder
        self.fw = syslog_forwarder

    def _run_one_pass(self, posted):
        """Run the tail loop for a single pass, then stop it."""
        calls = {"n": 0}

        def fake_sleep(_):
            calls["n"] += 1
            if calls["n"] >= 1:
                raise KeyboardInterrupt

        with patch.object(self.fw, "post", side_effect=lambda l: posted.append(l) or True), \
             patch.object(self.fw.time, "sleep", side_effect=fake_sleep):
            try:
                self.fw.tail()
            except KeyboardInterrupt:
                pass

    def test_forwards_interesting_lines_without_crashing(self):
        """The regression test. The old implementation raised
        OSError: telling position disabled by next() call here."""
        self.log.write_text(
            "Aug 23 13:58:48 corp-server sshd[1]: Invalid user admin from 10.0.0.71 port 42850\n"
            "Aug 23 13:58:49 corp-server systemd[1]: Started something harmless.\n"
            "Aug 23 13:58:50 corp-server sshd[2]: Failed password for root from 203.0.113.66 port 22 ssh2\n"
        )
        posted = []
        self._run_one_pass(posted)
        self.assertEqual(len(posted), 2, "both security lines should be forwarded")
        self.assertIn("Invalid user admin", posted[0])
        self.assertIn("Failed password", posted[1])

    def test_uninteresting_lines_are_ignored(self):
        self.log.write_text("Aug 23 13:58:49 corp-server systemd[1]: Started a timer.\n")
        posted = []
        self._run_one_pass(posted)
        self.assertEqual(posted, [])

    def test_offset_is_recorded_so_a_restart_does_not_replay(self):
        self.log.write_text(
            "Aug 23 13:58:48 corp-server sshd[1]: Invalid user admin from 10.0.0.71 port 1\n")
        posted = []
        self._run_one_pass(posted)
        self.assertTrue(self.state.exists())
        self.assertEqual(int(self.state.read_text()), self.log.stat().st_size)

    def test_only_new_lines_are_forwarded_on_a_second_pass(self):
        self.log.write_text(
            "Aug 23 13:58:48 corp-server sshd[1]: Invalid user admin from 10.0.0.71 port 1\n")
        first = []
        self._run_one_pass(first)

        with self.log.open("a") as fh:
            fh.write("Aug 23 13:59:10 corp-server sshd[2]: Invalid user oracle from 10.0.0.71 port 2\n")
        second = []
        self._run_one_pass(second)

        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 1)
        self.assertIn("oracle", second[0])

    def test_rotation_is_detected_and_the_file_reread(self):
        self.log.write_text(
            "Aug 23 13:58:48 corp-server sshd[1]: Invalid user admin from 10.0.0.71 port 1\n")
        self._run_one_pass([])

        # rotated: a shorter file at the same path
        self.log.write_text(
            "Aug 23 14:10:00 corp-server sshd[9]: Invalid user new from 10.0.0.71 port 3\n")
        posted = []
        self._run_one_pass(posted)
        self.assertEqual(len(posted), 1)
        self.assertIn("new", posted[0])

    def test_partial_line_is_not_forwarded_until_complete(self):
        self.log.write_text("Aug 23 13:58:48 corp-server sshd[1]: Invalid user admin from 10.0.0.71")
        posted = []
        self._run_one_pass(posted)
        self.assertEqual(posted, [], "a line without a newline is still being written")


class Severity(unittest.TestCase):
    def setUp(self):
        os.environ["SOAR_INGEST_URL"] = "https://example.invalid/events"
        sys.modules.pop("syslog_forwarder", None)
        import syslog_forwarder
        self.fw = syslog_forwarder

    def test_break_in_is_critical(self):
        self.assertEqual(self.fw.severity_of("POSSIBLE BREAK-IN ATTEMPT!"), "critical")

    def test_failed_password_is_high(self):
        self.assertEqual(self.fw.severity_of("Failed password for root"), "high")

    def test_unknown_defaults_to_medium(self):
        self.assertEqual(self.fw.severity_of("something else entirely"), "medium")


if __name__ == "__main__":
    unittest.main()
