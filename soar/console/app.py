"""
SOAR Console.

A read-only view of what the SOAR system has seen and done, running as a
container on the k3s platform. It exists because the operational record lives
across three DynamoDB tables and CloudWatch, and during an incident nobody
wants to open four console tabs to answer "what just happened and what did we
do about it".

Read-only by design. Its IAM permissions do not include writing to any table or
modifying any resource, so a flaw in the web layer cannot be used to release a
quarantined host or lift a block.

Built on the standard library HTTP server rather than a web framework: the
whole surface is four endpoints, and every dependency in a container that
serves an internal dashboard is a dependency to patch.
"""
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3

REGION = os.environ.get("AWS_REGION", "eu-central-1")
EVENTS_TABLE = os.environ.get("EVENTS_TABLE", "innovatech-soar-events")
BLOCKS_TABLE = os.environ.get("BLOCKS_TABLE", "innovatech-soar-blocks")
QUARANTINE_TABLE = os.environ.get("QUARANTINE_TABLE", "innovatech-soar-quarantines")
PORT = int(os.environ.get("PORT", "8080"))
VERSION = os.environ.get("APP_VERSION", "dev")

dynamodb = boto3.resource("dynamodb", region_name=REGION)


def scan(table_name, limit=50):
    try:
        items = dynamodb.Table(table_name).scan(Limit=limit).get("Items", [])
        return sorted(
            items,
            key=lambda i: str(i.get("received_at") or i.get("blocked_at")
                              or i.get("quarantined_at") or ""),
            reverse=True,
        )
    except Exception as exc:
        return [{"error": str(exc)}]


def summary():
    events = scan(EVENTS_TABLE, 200)
    blocks = scan(BLOCKS_TABLE, 100)
    quarantines = scan(QUARANTINE_TABLE, 100)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "version": VERSION,
        "counts": {
            "events": len(events),
            "active_blocks": sum(1 for b in blocks if b.get("status") == "active"),
            "quarantined_hosts": sum(1 for q in quarantines if q.get("status") == "quarantined"),
        },
        "events": events[:25],
        "blocks": blocks,
        "quarantines": quarantines,
    }


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Innovatech SOAR Console</title>
<meta http-equiv="refresh" content="30">
<style>
 body{font:14px/1.5 -apple-system,Segoe UI,Helvetica,Arial,sans-serif;margin:0;background:#0f172a;color:#e2e8f0}
 header{background:#1e293b;padding:18px 28px;border-bottom:1px solid #334155}
 h1{margin:0;font-size:18px;font-weight:600}
 .sub{color:#94a3b8;font-size:12px;margin-top:4px}
 main{padding:24px 28px;max-width:1200px}
 .cards{display:flex;gap:16px;margin-bottom:28px;flex-wrap:wrap}
 .card{background:#1e293b;border:1px solid #334155;border-radius:8px;padding:16px 20px;min-width:150px}
 .n{font-size:28px;font-weight:600}
 .l{color:#94a3b8;font-size:12px;text-transform:uppercase;letter-spacing:.4px}
 .card.alert .n{color:#f87171}
 h2{font-size:14px;text-transform:uppercase;letter-spacing:.5px;color:#94a3b8;margin:28px 0 10px}
 table{width:100%;border-collapse:collapse;background:#1e293b;border-radius:8px;overflow:hidden}
 th{text-align:left;padding:10px 14px;background:#334155;font-size:11px;text-transform:uppercase;color:#cbd5e1}
 td{padding:9px 14px;border-top:1px solid #334155;font-size:13px}
 td.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
 .sev{padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600}
 .critical{background:#7f1d1d;color:#fecaca}.high{background:#7c2d12;color:#fed7aa}
 .medium{background:#78350f;color:#fde68a}.low{background:#334155;color:#cbd5e1}
 .active{color:#f87171;font-weight:600}.expired{color:#64748b}
 .empty{color:#64748b;padding:14px}
 footer{color:#64748b;font-size:11px;padding:20px 28px}
</style></head><body>
<header><h1>Innovatech SOAR Console</h1>
<div class="sub">Read-only view of the automated response record. Refreshes every 30 seconds.</div></header>
<main>
<div class="cards">
 <div class="card"><div class="n">__EVENTS__</div><div class="l">Events stored</div></div>
 <div class="card alert"><div class="n">__BLOCKS__</div><div class="l">Active blocks</div></div>
 <div class="card alert"><div class="n">__QUARANTINES__</div><div class="l">Hosts isolated</div></div>
</div>
<h2>Active network blocks</h2>__BLOCKS_TABLE__
<h2>Quarantined hosts</h2>__QUARANTINE_TABLE__
<h2>Recent events</h2>__EVENTS_TABLE__
</main>
<footer>Version __VERSION__ &middot; generated __GENERATED__</footer>
</body></html>"""


def table(rows, columns):
    if not rows:
        return '<div class="empty">Nothing recorded.</div>'
    head = "".join(f"<th>{c[0]}</th>" for c in columns)
    body = ""
    for r in rows:
        cells = ""
        for _, key, cls in columns:
            v = str(r.get(key, ""))
            if key == "severity":
                v = f'<span class="sev {v}">{v}</span>'
            if key == "status":
                v = f'<span class="{v}">{v}</span>'
            cells += f'<td class="{cls}">{v}</td>'
        body += f"<tr>{cells}</tr>"
    return f"<table><tr>{head}</tr>{body}</table>"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            self._send(200, "ok", "text/plain")
            return

        if self.path == "/api/summary":
            self._send(200, json.dumps(summary(), default=str), "application/json")
            return

        if self.path in ("/", "/index.html"):
            try:
                s = summary()
                # Token substitution rather than str.format(): the stylesheet is
                # full of braces and format() reads each one as a field.
                subs = {
                    "__EVENTS__": s["counts"]["events"],
                    "__BLOCKS__": s["counts"]["active_blocks"],
                    "__QUARANTINES__": s["counts"]["quarantined_hosts"],
                    "__VERSION__": s["version"],
                    "__GENERATED__": s["generated_at"],
                    "__BLOCKS_TABLE__": table(s["blocks"], [
                        ("Address", "cidr", "mono"), ("NACL rule", "rule_number", "mono"),
                        ("Playbook", "playbook_id", ""), ("Status", "status", ""),
                        ("Expires", "expires_at_iso", "mono")]),
                    "__QUARANTINE_TABLE__": table(s["quarantines"], [
                        ("Instance", "instance_id", "mono"), ("Isolated at", "quarantined_at", "mono"),
                        ("Playbook", "playbook_id", ""), ("Status", "status", ""),
                        ("Reason", "reason", "")]),
                    "__EVENTS_TABLE__": table(s["events"], [
                        ("Received", "received_at", "mono"), ("Type", "event_type", ""),
                        ("Severity", "severity", ""), ("Source IP", "source_ip", "mono"),
                        ("Target", "target_host", "")]),
                }
                html = PAGE
                for token, value in subs.items():
                    html = html.replace(token, str(value))
                self._send(200, html, "text/html; charset=utf-8")
            except Exception as exc:
                # Return a readable error rather than closing the connection,
                # which the browser reports only as an empty response.
                import traceback
                traceback.print_exc()
                self._send(500, f"<pre>console error: {exc}</pre>", "text/html; charset=utf-8")
            return

        self._send(404, "not found", "text/plain")

    def log_message(self, fmt, *args):
        # Keep container logs to request lines only, in a form Loki can parse.
        print(f'{self.address_string()} "{fmt % args}"', flush=True)


if __name__ == "__main__":
    print(f"SOAR console {VERSION} listening on {PORT}, region {REGION}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
# pipeline verification run
