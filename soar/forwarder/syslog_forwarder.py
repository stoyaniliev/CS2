"""
On-premises syslog forwarder.

Runs on the simulated corporate server. Tails the authentication log, and posts
anything security-relevant to the SOAR ingest endpoint.

This is the on-premises half of REQ-NCA-P2-06. The cloud sources (Alertmanager,
CloudWatch) push to the same endpoint, and the collector normalises all three
into one event schema, so nothing downstream knows or cares which produced a
given event.

Deliberately small and dependency-free. An agent on a corporate server is a
thing that has to keep running unattended, and every library it pulls in is
something that can break it or need patching. The standard library is enough
for tail, match and POST.
"""

import json
import logging
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

INGEST_URL = os.environ.get("SOAR_INGEST_URL", "")
WATCH_FILE = os.environ.get("WATCH_FILE", "/var/log/auth.log")
STATE_FILE = Path(os.environ.get("STATE_FILE", "/var/lib/soar-forwarder/offset"))
HOSTNAME = os.environ.get("REPORT_AS", socket.gethostname())
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "2"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("soar-forwarder")

# Only lines worth sending. Forwarding an entire auth log would bury real
# events in noise and cost money in Lambda invocations for nothing.
INTERESTING = [
    re.compile(r"Failed (?:password|publickey) for .* from \d{1,3}(?:\.\d{1,3}){3}"),
    re.compile(r"Invalid user .* from \d{1,3}(?:\.\d{1,3}){3}"),
    re.compile(r"authentication failure.*user="),
    re.compile(r"POSSIBLE BREAK-IN ATTEMPT"),
]

SEVERITY = [
    (re.compile(r"POSSIBLE BREAK-IN ATTEMPT"), "critical"),
    (re.compile(r"authentication failure"), "high"),
    (re.compile(r"Failed password|Invalid user"), "high"),
]


def severity_of(line: str) -> str:
    for pattern, sev in SEVERITY:
        if pattern.search(line):
            return sev
    return "medium"


def read_offset() -> int:
    try:
        return int(STATE_FILE.read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def write_offset(offset: int) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(str(offset))


def post(line: str) -> bool:
    payload = json.dumps({
        "host": HOSTNAME,
        "severity": severity_of(line),
        "message": line.strip(),
    }).encode()

    request = urllib.request.Request(
        INGEST_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if response.status == 200:
                return True
            log.warning("ingest returned HTTP %s", response.status)
            return False
    except urllib.error.HTTPError as exc:
        log.error("ingest rejected the event: HTTP %s", exc.code)
        return False
    except (urllib.error.URLError, ssl.SSLError, TimeoutError) as exc:
        log.error("ingest unreachable: %s", exc)
        return False


def tail():
    """
    Follow the file from the last recorded offset.

    The offset is persisted so a restart does not replay the whole log, and a
    shrinking file is treated as rotation and re-read from the start.
    """
    offset = read_offset()
    log.info("watching %s from offset %d, reporting as %s", WATCH_FILE, offset, HOSTNAME)
    log.info("ingest endpoint %s", INGEST_URL)

    while True:
        try:
            size = os.path.getsize(WATCH_FILE)
        except FileNotFoundError:
            time.sleep(POLL_SECONDS)
            continue

        if size < offset:
            log.info("file shrank, treating as rotation")
            offset = 0

        if size > offset:
            with open(WATCH_FILE, "r", errors="replace") as fh:
                fh.seek(offset)
                for line in fh:
                    if not line.endswith("\n"):
                        break            # partial write, pick it up next pass
                    if any(p.search(line) for p in INTERESTING):
                        if post(line):
                            log.info("forwarded: %s", line.strip()[:120])
                        else:
                            # Do not advance past a line we failed to deliver.
                            write_offset(offset)
                            time.sleep(POLL_SECONDS)
                            break
                    offset = fh.tell()
                else:
                    write_offset(offset)

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    if not INGEST_URL:
        log.error("SOAR_INGEST_URL is not set")
        sys.exit(1)
    try:
        tail()
    except KeyboardInterrupt:
        log.info("stopping")
