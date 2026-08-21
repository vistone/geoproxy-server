#!/usr/bin/env python3
"""GeoProxy mesh master registry — POST /v1/register, GET /v1/peers, GET /v1/health."""
from __future__ import annotations

import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PEERS_PATH = Path(os.environ.get("GPS_MESH_PEERS", "/etc/geoproxy-server/mesh/peers.json"))
TOKEN = os.environ.get("MESH_CLUSTER_TOKEN", "")
HOST = os.environ.get("GPS_MESH_MASTER_BIND", "0.0.0.0")
PORT = int(os.environ.get("GPS_MESH_MASTER_PORT", "19527"))
PREFIX = os.environ.get("MESH_OVERLAY_PREFIX", "10.66.0.0/16")
LOCK = threading.Lock()


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def empty_doc() -> dict:
    return {"schema": 1, "updated_at": utc_now(), "nodes": []}


def load_doc() -> dict:
    if not PEERS_PATH.is_file():
        return empty_doc()
    with PEERS_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def save_doc(doc: dict) -> None:
    PEERS_PATH.parent.mkdir(parents=True, exist_ok=True)
    doc["schema"] = 1
    doc["updated_at"] = utc_now()
    tmp = PEERS_PATH.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    tmp.replace(PEERS_PATH)


def used_overlays(nodes: list) -> set[str]:
    out: set[str] = set()
    for n in nodes:
        ip = (n.get("overlay_ip") or "").split("/")[0]
        if ip:
            out.add(ip)
    return out


def alloc_overlay(used: set[str]) -> str:
    for i in range(2, 255):
        cand = f"10.66.0.{i}"
        if cand not in used:
            return cand
    raise RuntimeError("overlay pool exhausted")


def auth_ok(handler: BaseHTTPRequestHandler) -> bool:
    if not TOKEN:
        return True
    h = handler.headers.get("Authorization", "")
    if h.startswith("Bearer "):
        return h[7:].strip() == TOKEN
    return handler.headers.get("X-Mesh-Token", "") == TOKEN


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: dict | list | None = None) -> None:
        data = b"" if body is None else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/v1/health":
            self._send(200, {"ok": True, "role": "master", "prefix": PREFIX})
            return
        if path == "/v1/peers":
            if not auth_ok(self):
                self._send(401, {"error": "unauthorized"})
                return
            with LOCK:
                self._send(200, load_doc())
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path != "/v1/register":
            self._send(404, {"error": "not found"})
            return
        if not auth_ok(self):
            self._send(401, {"error": "unauthorized"})
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid json"})
            return
        nid = (req.get("node_id") or "").strip()
        pubkey = (req.get("public_key") or "").strip()
        if not nid or not pubkey:
            self._send(400, {"error": "node_id and public_key required"})
            return
        endpoint = (req.get("endpoint") or "").strip()
        roles = req.get("roles") or ["edge"]
        if not isinstance(roles, list):
            roles = ["edge"]
        want = (req.get("overlay_ip") or "").split("/")[0].strip()
        keepalive = int(req.get("keepalive") or 25)

        with LOCK:
            doc = load_doc()
            prev = list(doc.get("nodes", []))
            nodes = [n for n in prev if n.get("node_id") != nid]
            used = used_overlays(nodes)
            old = next((n for n in prev if n.get("node_id") == nid), None)
            if want and want not in used:
                overlay = want
            elif old and (old.get("overlay_ip") or "").split("/")[0]:
                overlay = (old.get("overlay_ip") or "").split("/")[0]
            else:
                overlay = alloc_overlay(used)
            entry = {
                "node_id": nid,
                "public_key": pubkey,
                "endpoint": endpoint,
                "overlay_ip": overlay,
                "roles": roles,
                "keepalive": keepalive,
            }
            nodes.append(entry)
            doc["nodes"] = nodes
            save_doc(doc)
            self._send(200, {"node": entry, "peers": doc})


def main() -> None:
    if not TOKEN:
        sys.stderr.write("warning: MESH_CLUSTER_TOKEN empty — registry open\n")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write("mesh-master listening on %s:%s peers=%s\n" % (HOST, PORT, PEERS_PATH))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
