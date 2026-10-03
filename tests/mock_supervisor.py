#!/usr/bin/env python3
"""Mini-Mock der Supervisor-API für die lokalen Tests von deploy.sh.

Aufruf: mock_supervisor.py <port> <state.json> <requests.log>

state.json (wird bei jeder Anfrage neu gelesen, Tests können ihn ändern):
  {"installed": true, "update_available": false, "state": "started",
   "health": 200, "fail": {"/addons/local_x/rebuild": 403}}
Jede Anfrage wird als "METHODE PFAD [BODY]" in requests.log protokolliert.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, STATE_FILE, LOG_FILE = int(sys.argv[1]), sys.argv[2], sys.argv[3]


def state():
    with open(STATE_FILE) as f:
        return json.load(f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        auth = self.headers.get("Authorization", "")
        with open(LOG_FILE, "a") as f:
            f.write(f"{method} {self.path} {body}".rstrip() + f" AUTH={auth}\n")
        s = state()
        if self.path in s.get("fail", {}):
            return self.reply(s["fail"][self.path], {"result": "error", "message": "mock failure"})
        if self.path == "/health":
            return self.reply(s.get("health", 200), {"status": "healthy"})
        if self.path.endswith("/info"):
            data = {
                "version": "1.0.0" if s.get("installed", True) else None,
                "update_available": s.get("update_available", False),
                "state": s.get("state", "started") if s.get("installed", True) else "unknown",
            }
            return self.reply(200, {"result": "ok", "data": data})
        return self.reply(200, {"result": "ok", "data": {}})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
