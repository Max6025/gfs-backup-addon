#!/usr/bin/env python3
"""HTTP + WebSocket Server für GFS Backup Addon."""

import json
import os
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

STATUS_FILE = "/tmp/gfs_status.json"
HTTP_PORT = 8099
WS_PORT = 8098

# WebSocket Clients
_ws_clients = []
_ws_lock = threading.Lock()


def read_status() -> dict:
    try:
        with open(STATUS_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"error": "Noch kein Status verfügbar"}


def notify_clients():
    """Alle WebSocket-Clients über Status-Änderung informieren."""
    status = read_status()
    payload = json.dumps({"type": "status_update", "data": status})
    frame = _ws_encode(payload)
    dead = []
    with _ws_lock:
        for client in _ws_clients:
            try:
                client.sendall(frame)
            except Exception:
                dead.append(client)
        for d in dead:
            _ws_clients.remove(d)


def _ws_encode(message: str) -> bytes:
    """WebSocket Frame kodieren (RFC 6455)."""
    msg = message.encode("utf-8")
    length = len(msg)
    if length < 126:
        header = bytes([0x81, length])
    elif length < 65536:
        header = bytes([0x81, 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([0x81, 127]) + length.to_bytes(8, "big")
    return header + msg


def _ws_handshake(conn, request_data: str) -> bool:
    """WebSocket Handshake durchführen."""
    import base64, hashlib
    key = ""
    for line in request_data.split("\r\n"):
        if "Sec-WebSocket-Key" in line:
            key = line.split(": ")[1].strip()
            break
    if not key:
        return False
    magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    accept = base64.b64encode(
        hashlib.sha1((key + magic).encode()).digest()
    ).decode()
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    conn.sendall(response.encode())
    return True


def _ws_client_handler(conn, addr):
    """Einen WebSocket-Client verwalten."""
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(1024)
            if not chunk:
                return
            data += chunk
        if not _ws_handshake(conn, data.decode("utf-8", errors="ignore")):
            return
        with _ws_lock:
            _ws_clients.append(conn)
        print(f"[WS] Client verbunden: {addr}")
        # Sofort aktuellen Status senden
        try:
            conn.sendall(_ws_encode(json.dumps({"type": "status_update", "data": read_status()})))
        except Exception:
            pass
        # Verbindung offen halten (Ping alle 30s)
        while True:
            time.sleep(30)
            try:
                conn.sendall(bytes([0x89, 0x00]))  # Ping frame
            except Exception:
                break
    except Exception as e:
        print(f"[WS] Client Fehler: {e}")
    finally:
        with _ws_lock:
            if conn in _ws_clients:
                _ws_clients.remove(conn)
        try:
            conn.close()
        except Exception:
            pass
        print(f"[WS] Client getrennt: {addr}")


def _ws_server():
    """WebSocket-Server starten."""
    import socket
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", WS_PORT))
    server.listen(10)
    print(f"[WS] WebSocket-Server läuft auf Port {WS_PORT}")
    while True:
        try:
            conn, addr = server.accept()
            t = threading.Thread(target=_ws_client_handler, args=(conn, addr), daemon=True)
            t.start()
        except Exception as e:
            print(f"[WS] Server Fehler: {e}")


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
                    ts = datetime.now().strftime('%H%M%S%f')
                    flag = f"/tmp/gfs_cmd_{ts}"
                    with open(flag, "w") as f:
                        f.write(cmd)
                    print(f"[HTTP] Befehl: {cmd}")
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
    # WebSocket-Server in eigenem Thread
    ws_thread = threading.Thread(target=_ws_server, daemon=True)
    ws_thread.start()

    # HTTP-Server
    server = HTTPServer(("0.0.0.0", HTTP_PORT), GFSHandler)
    print(f"[HTTP] GFS HTTP-Server läuft auf Port {HTTP_PORT}")
    server.serve_forever()


# notify_clients von außen aufrufbar machen
if __name__ == "__main__":
    run()
