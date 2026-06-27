#!/usr/bin/env python3
"""Kleiner HTTP-Server für GFS Backup Addon – Status & Befehle."""

import json
import os
import subprocess
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

STATUS_FILE = "/tmp/gfs_status.json"
PORT = 8099


def read_status() -> dict:
    """Status-Datei lesen."""
    try:
        with open(STATUS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"error": "Noch kein Status verfügbar"}


def write_status(data: dict):
    """Status-Datei schreiben."""
    try:
        with open(STATUS_FILE, "w") as f:
            json.dump(data, f)
    except Exception as e:
        print(f"[Server] Status schreiben fehlgeschlagen: {e}")


def send_to_addon(command: str):
    """Befehl an run.sh weitergeben via Flag-Datei."""
    try:
        flag_file = f"/tmp/gfs_cmd_{command}_{datetime.now().strftime('%H%M%S')}"
        with open(flag_file, "w") as f:
            f.write(command)
    except Exception as e:
        print(f"[Server] Befehl schreiben fehlgeschlagen: {e}")


class GFSHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        pass  # Kein Log-Spam

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
                    send_to_addon(cmd)
                    print(f"[Server] Befehl empfangen: {cmd}")
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


def run():
    server = HTTPServer(("0.0.0.0", PORT), GFSHandler)
    print(f"[Server] GFS HTTP-Server läuft auf Port {PORT}")
    server.serve_forever()


if __name__ == "__main__":
    run()
