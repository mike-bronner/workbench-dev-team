#!/usr/bin/env python3
"""A fake The Index for bin/test-dispatch-tick.sh: a local HTTP server that
answers POST /mcp as laravel/mcp does (a bare JSON-RPC tools/call, a plain JSON
reply) and POST /oauth/token as Passport's client_credentials grant does.

Usage: fake-index.py <scenario.json> <log.jsonl> <port file>

It binds 127.0.0.1 on a free port and writes the port to <port file>. It reads
the scenario on every request, so a test rewrites it between ticks. Every
request is appended to the log as one JSON line: its path, its Authorization
header, and its body (the JSON-RPC request, or the form fields).

The scenario:
  "token":        the token reply, {"status": 200, "body": {...}}. Default: a
                  token "tok-1" with a year's expires_in.
  "valid_tokens": when present, a /mcp call whose bearer token is not in this
                  list gets HTTP 401.
  "tools":        one answer per tool name. The key "<name>#claimed" answers a
                  call whose arguments set include_claimed. An answer is one of
                    {"result": X}          the tool's JSON X, as content text
                    {"isError": "text"}    a tool error
                    {"rpcError": {...}}    a JSON-RPC error object
                    {"status": N, "raw": "body"}  any HTTP reply
                  A tool with no answer returns no items (a list) or {"ok": true}.
"""

import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO, LOG, PORT_FILE = sys.argv[1], sys.argv[2], sys.argv[3]


def scenario():
    try:
        with open(SCENARIO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        auth = self.headers.get("Authorization")
        world = scenario()
        if self.path == "/oauth/token":
            log({"path": self.path, "auth": auth, "form": dict(urllib.parse.parse_qsl(raw))})
            token = world.get("token", {"status": 200, "body": {"token_type": "Bearer", "expires_in": 31536000, "access_token": "tok-1"}})
            return self.reply(token.get("status", 200), token.get("body", {}))
        if self.path != "/mcp":
            return self.reply(404, {"message": "not found"})
        try:
            request = json.loads(raw)
        except ValueError:
            request = None
        log({"path": self.path, "auth": auth, "body": request})
        valid = world.get("valid_tokens")
        if valid is not None and auth not in ["Bearer " + t for t in valid]:
            return self.reply(401, {"message": "Unauthenticated."})
        params = (request or {}).get("params") or {}
        name = params.get("name", "")
        arguments = params.get("arguments") or {}
        tools = world.get("tools", {})
        key = name + "#claimed" if arguments.get("include_claimed") else name
        answer = tools.get(key, tools.get(name))
        if answer is None:
            answer = {"result": {"count": 0, "items": []} if name.startswith("list_") else {"ok": True}}
        rid = (request or {}).get("id")
        if "status" in answer:
            return self.reply(answer["status"], answer.get("raw", ""), answer.get("contentType", "application/json"))
        if "rpcError" in answer:
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": answer["rpcError"]})
        if "isError" in answer:
            result = {"content": [{"type": "text", "text": answer["isError"]}], "isError": True}
        else:
            result = {"content": [{"type": "text", "text": json.dumps(answer["result"])}], "isError": False}
        return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": result})


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
# The rename is the last step, so a reader never sees half a port.
os.replace(PORT_FILE + ".tmp", PORT_FILE)
server.serve_forever()
