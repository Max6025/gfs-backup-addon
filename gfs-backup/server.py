#!/usr/bin/env python3
"""HTTP-Server für GFS Backup Addon."""

import json
import os
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

STATUS_FILE = "/tmp/gfs_status.json"
PORT = 8099


def read_status() -> dict:
    try:
        with open(STATUS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"error": "Noch kein Status verfügbar"}


class GFSHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == "/status":
            status = read_status()
            body = json.dumps(status).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/command":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                cmd = data.get("command", "")
                if cmd:
                    # Befehl via Flag-Datei an run.sh weitergeben
                    ts = datetime.now().strftime('%H%M%S%f')
                    flag = f"/tmp/gfs_cmd_{ts}"
                    with open(flag, "w") as f:
                        f.write(cmd)
                    print(f"[Server] Befehl: {cmd}")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps({"result": "ok", "command": cmd}).encode())
                else:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'{"error": "Kein Befehl"}')
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), GFSHandler)
    print(f"[Server] GFS HTTP-Server läuft auf Port {PORT}")
    server.serve_forever()
