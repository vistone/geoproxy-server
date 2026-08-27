#!/usr/bin/env python3
"""GeoProxy mesh master registry — POST /v1/register, POST /v1/heartbeat, GET /v1/peers, GET /v1/health.

POST /v1/hook/github：GitHub Release webhook（HMAC SHA256 签名校验）触发 upgrade self。
默认以自签 TLS 证书提供服务（节点端用证书公钥指纹钉扎），并校验所有注册输入。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import ssl
import subprocess
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    try:
        return int(raw) if raw else default
    except ValueError:
        sys.stderr.write("mesh-master: 环境变量 %s=%r 不是整数\n" % (name, raw))
        raise SystemExit(2)


PEERS_PATH = Path(os.environ.get("GPS_MESH_PEERS", "/etc/geoproxy-server/mesh/peers.json"))
TOKEN = os.environ.get("MESH_CLUSTER_TOKEN", "")
WEBHOOK_SECRET = os.environ.get("GPS_GITHUB_WEBHOOK_SECRET", "")
UPGRADE_CLI = os.environ.get("GPS_UPGRADE_CLI", "/usr/local/bin/geoproxy-server")
HOST = os.environ.get("GPS_MESH_MASTER_BIND", "0.0.0.0")
PORT = _env_int("GPS_MESH_MASTER_PORT", 19527)
try:
    PREFIX = ipaddress.ip_network(os.environ.get("MESH_OVERLAY_PREFIX", "10.66.0.0/16"), strict=False)
except ValueError as e:
    sys.stderr.write("mesh-master: 无效 MESH_OVERLAY_PREFIX: %s\n" % e)
    raise SystemExit(2)
STALE_SEC = _env_int("MESH_PEER_STALE_SEC", 180)
MAX_BODY = _env_int("GPS_MESH_MAX_BODY", 65536)
ALLOW_OPEN = os.environ.get("GPS_MESH_ALLOW_OPEN", "0") == "1"
TLS_ENABLED = os.environ.get("GPS_MESH_MASTER_TLS", "1") != "0"
TLS_CERT = Path(os.environ.get("GPS_MESH_MASTER_TLS_CERT") or PEERS_PATH.parent / "master-tls.pem")
TLS_KEY = Path(os.environ.get("GPS_MESH_MASTER_TLS_KEY") or PEERS_PATH.parent / "master-tls.key")
TLS_FP_FILE = Path(os.environ.get("GPS_MESH_TLS_FP") or PEERS_PATH.parent / "master-tls.fp")
LOCK = threading.Lock()
_UPGRADE_LOCK = threading.Lock()
_UPGRADE_RUNNING = False
_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")

# 首个 /24 内分配（与旧版行为一致）；.1 保留给 Master 自身
_ALLOC_NET = PREFIX if PREFIX.prefixlen >= 24 else ipaddress.ip_network(
    "%s/24" % PREFIX.network_address, strict=False)
_MASTER_HOST = PREFIX.network_address + 1
_RESERVED = {PREFIX.network_address, PREFIX.broadcast_address, _MASTER_HOST}
_NODE_ID_MAX = 64
_FIELD_MAX = 256


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def is_alive(last_seen: str | None, now: datetime | None = None) -> bool:
    ts = parse_utc(last_seen)
    if ts is None:
        return False
    now = now or datetime.now(timezone.utc)
    return (now - ts).total_seconds() <= STALE_SEC


def annotate_alive(doc: dict) -> dict:
    now = datetime.now(timezone.utc)
    out = dict(doc)
    nodes = []
    for n in doc.get("nodes") or []:
        nn = dict(n)
        nn["alive"] = is_alive(n.get("last_seen"), now)
        nodes.append(nn)
    out["nodes"] = nodes
    out["stale_sec"] = STALE_SEC
    return out


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
        try:
            ip = ipaddress.ip_address((n.get("overlay_ip") or "").split("/")[0])
        except ValueError:
            continue
        out.add(str(ip))
    return out


def overlay_policy_ok(want: str) -> bool:
    """overlay 必须位于 PREFIX 内且避开网络/广播/Master 保留地址。"""
    try:
        ip = ipaddress.ip_address(want)
    except ValueError:
        return False
    return ip in PREFIX and ip not in _RESERVED


def alloc_overlay(used: set[str]) -> str:
    for cand in _ALLOC_NET.hosts():
        if cand == _MASTER_HOST:
            continue
        if str(cand) not in used:
            return str(cand)
    raise RuntimeError("overlay pool exhausted (prefix=%s)" % PREFIX)


def _clean(s, limit: int) -> str | None:
    """单行、可打印、限长；返回规范化值或 None。"""
    if not isinstance(s, str):
        return None
    s = s.strip()
    if not s or len(s) > limit:
        return None
    if any(c.isspace() or ord(c) < 0x20 or ord(c) == 0x7F for c in s):
        return None
    return s


# ---------- GitHub Release webhook → upgrade self ----------

def verify_github_signature(raw: bytes, sig_hdr: str) -> bool:
    """校验 X-Hub-Signature-256: sha256=<hex>（HMAC SHA256）。"""
    if not WEBHOOK_SECRET or not sig_hdr.startswith("sha256="):
        return False
    expected = hmac.new(WEBHOOK_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(sig_hdr[7:], expected)


def extract_release_tag(event: str, payload: dict) -> str | None:
    """从 release published 或 push tag 事件提取 vX.Y.Z tag；其它事件返回 None。"""
    tag = ""
    if event == "release":
        if payload.get("action") != "published":
            return None
        tag = ((payload.get("release") or {}).get("tag_name") or "").strip()
    elif event == "push":
        ref = (payload.get("ref") or "").strip()
        if not ref.startswith("refs/tags/"):
            return None
        tag = ref[len("refs/tags/"):].strip()
    else:
        return None
    return tag if _TAG_RE.fullmatch(tag) else None


def _run_upgrade(tag: str) -> None:
    global _UPGRADE_RUNNING
    try:
        subprocess.run(
            [UPGRADE_CLI, "upgrade", "self", "--ver", tag],
            capture_output=True,
            timeout=900,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as e:
        sys.stderr.write("mesh-master webhook upgrade failed: %s\n" % e)
    finally:
        with _UPGRADE_LOCK:
            _UPGRADE_RUNNING = False


def schedule_upgrade(tag: str) -> tuple[int, dict]:
    """后台触发 upgrade self；立即返回，避免 GitHub webhook 超时。"""
    global _UPGRADE_RUNNING
    with _UPGRADE_LOCK:
        if _UPGRADE_RUNNING:
            return 409, {"error": "upgrade already in progress"}
        _UPGRADE_RUNNING = True
    threading.Thread(target=_run_upgrade, args=(tag,), daemon=True).start()
    return 202, {"ok": True, "upgrade": tag, "status": "scheduled"}


def auth_ok(handler: BaseHTTPRequestHandler) -> bool:
    if not TOKEN:
        return True
    h = handler.headers.get("Authorization", "")
    if h.startswith("Bearer "):
        return hmac.compare_digest(h[7:].strip().encode(), TOKEN.encode())
    t = handler.headers.get("X-Mesh-Token", "")
    return hmac.compare_digest(t.strip().encode(), TOKEN.encode())


# ---------- 自签 TLS：证书生成与公钥指纹（curl --pinnedpubkey 格式） ----------

def _run(argv: list[str], stdin_data: bytes | None = None) -> bytes:
    p = subprocess.run(argv, input=stdin_data, capture_output=True, check=False)
    if p.returncode != 0:
        raise RuntimeError("%s 失败: %s" % (argv[0], p.stderr.decode(errors="replace").strip()))
    return p.stdout


def tls_pubkey_pin() -> str:
    """sha256//<base64(DER 公钥)>，与 curl --pinnedpubkey 语义一致。"""
    pem = _run(["openssl", "x509", "-in", str(TLS_CERT), "-pubkey", "-noout"])
    der = _run(["openssl", "pkey", "-pubin", "-outform", "DER"], stdin_data=pem)
    return "sha256//" + base64.b64encode(hashlib.sha256(der).digest()).decode()


def ensure_tls() -> str | None:
    """证书缺失则生成（EC P-256，10 年）；始终刷新指纹文件。返回 pin（禁用 TLS 时为 None）。"""
    if not TLS_ENABLED:
        return None
    TLS_CERT.parent.mkdir(parents=True, exist_ok=True)
    if not (TLS_CERT.is_file() and TLS_KEY.is_file()):
        for p in (TLS_CERT, TLS_KEY):
            p.unlink(missing_ok=True)
        _run([
            "openssl", "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-keyout", str(TLS_KEY), "-out", str(TLS_CERT),
            "-days", "3650", "-nodes", "-subj", "/CN=geoproxy-mesh",
        ])
        os.chmod(TLS_KEY, 0o600)
        os.chmod(TLS_CERT, 0o600)
    pin = tls_pubkey_pin()
    tmp = TLS_FP_FILE.with_suffix(".tmp")
    tmp.write_text(pin + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(TLS_FP_FILE)
    return pin


class Handler(BaseHTTPRequestHandler):
    timeout = 30  # 防 slowloris 挂死线程

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

    def _read_raw_body(self) -> tuple[bytes | None, int]:
        """读原始请求体；返回 (raw, http_status)。"""
        raw_len = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(raw_len)
        except ValueError:
            return None, 400
        if length < 0 or length > MAX_BODY:
            return None, 413
        raw = self.rfile.read(length) if length else b"{}"
        return raw, 200

    def _read_json(self) -> tuple[dict | None, int]:
        """读请求体并解析 JSON；返回 (obj, http_status)，status==200 时 obj 有效。"""
        raw, st = self._read_raw_body()
        if st != 200 or raw is None:
            return None, st
        try:
            obj = json.loads(raw.decode() or "{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None, 400
        if not isinstance(obj, dict):
            return None, 400
        return obj, 200

    def _handle_github_webhook(self) -> None:
        if not WEBHOOK_SECRET:
            self._send(503, {"error": "webhook not configured"})
            return
        raw, st = self._read_raw_body()
        if st != 200 or raw is None:
            self._send(st, {"error": "bad request" if st == 400 else "body too large"})
            return
        sig = self.headers.get("X-Hub-Signature-256", "")
        if not verify_github_signature(raw, sig):
            self._send(401, {"error": "invalid signature"})
            return
        try:
            payload = json.loads(raw.decode() or "{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(400, {"error": "bad json"})
            return
        if not isinstance(payload, dict):
            self._send(400, {"error": "bad json"})
            return
        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            self._send(200, {"ok": True, "pong": True})
            return
        tag = extract_release_tag(event, payload)
        if not tag:
            self._send(200, {"ok": True, "ignored": True, "event": event})
            return
        code, body = schedule_upgrade(tag)
        self._send(code, body)

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/v1/health":
            self._send(200, {"ok": True, "role": "master", "prefix": str(PREFIX), "stale_sec": STALE_SEC})
            return
        if path == "/v1/peers":
            if not auth_ok(self):
                self._send(401, {"error": "unauthorized"})
                return
            with LOCK:
                self._send(200, annotate_alive(load_doc()))
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/v1/hook/github":
            self._handle_github_webhook()
            return
        if path not in ("/v1/register", "/v1/heartbeat"):
            self._send(404, {"error": "not found"})
            return
        if not auth_ok(self):
            self._send(401, {"error": "unauthorized"})
            return
        req, st = self._read_json()
        if st != 200:
            self._send(st, {"error": "bad request" if st == 400 else "body too large"})
            return

        nid = _clean(req.get("node_id"), _NODE_ID_MAX)
        if not nid:
            self._send(400, {"error": "node_id required (single line, <=%d chars)" % _NODE_ID_MAX})
            return

        if path == "/v1/heartbeat":
            with LOCK:
                doc = load_doc()
                for n in doc.get("nodes") or []:
                    if n.get("node_id") == nid:
                        n["last_seen"] = utc_now()
                        ep = _clean(req.get("endpoint"), _FIELD_MAX)
                        if ep:
                            n["endpoint"] = ep
                        save_doc(doc)
                        self._send(200, {"ok": True, "peers": annotate_alive(doc)})
                        return
                self._send(404, {"error": "unknown node; register first"})
            return

        pubkey = _clean(req.get("public_key"), 128)
        if not pubkey:
            self._send(400, {"error": "public_key required (single line, <=128 chars)"})
            return
        endpoint = _clean(req.get("endpoint"), _FIELD_MAX) or ""
        roles = req.get("roles")
        if roles is None:
            roles = ["edge"]
        if (not isinstance(roles, list) or not (1 <= len(roles) <= 8)
                or not all(isinstance(r, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,16}", r) for r in roles)):
            self._send(400, {"error": "roles must be a short list of tokens"})
            return
        try:
            keepalive = int(req.get("keepalive") or 25)
        except (TypeError, ValueError):
            self._send(400, {"error": "keepalive must be an integer"})
            return
        if not (0 <= keepalive <= 65535):
            self._send(400, {"error": "keepalive out of range (0-65535)"})
            return
        want_raw = (req.get("overlay_ip") or "").split("/")[0].strip()
        if want_raw:
            try:
                ipaddress.ip_address(want_raw)
            except ValueError:
                self._send(400, {"error": "overlay_ip is not a valid IP"})
                return

        with LOCK:
            doc = load_doc()
            prev = list(doc.get("nodes", []))
            nodes = [n for n in prev if n.get("node_id") != nid]
            used = used_overlays(nodes)
            old = next((n for n in prev if n.get("node_id") == nid), None)
            old_ip = (old.get("overlay_ip") or "").split("/")[0] if old else ""
            if want_raw and overlay_policy_ok(want_raw) and want_raw not in used:
                overlay = want_raw
            elif old_ip and overlay_policy_ok(old_ip):
                overlay = old_ip
            else:
                overlay = alloc_overlay(used)
            entry = {
                "node_id": nid,
                "public_key": pubkey,
                "endpoint": endpoint,
                "overlay_ip": overlay,
                "roles": roles,
                "keepalive": keepalive,
                "last_seen": utc_now(),
            }
            nodes.append(entry)
            doc["nodes"] = nodes
            save_doc(doc)
            self._send(200, {"node": entry, "peers": annotate_alive(doc)})


def main() -> None:
    if not TOKEN and not ALLOW_OPEN:
        sys.stderr.write("mesh-master: 拒绝启动 — MESH_CLUSTER_TOKEN 为空（开放注册表）。确需开放请设 GPS_MESH_ALLOW_OPEN=1\n")
        raise SystemExit(2)
    if not TOKEN:
        sys.stderr.write("warning: MESH_CLUSTER_TOKEN empty — registry OPEN (GPS_MESH_ALLOW_OPEN=1)\n")
    pin = None
    try:
        pin = ensure_tls()
    except Exception as e:
        sys.stderr.write(
            "mesh-master: TLS 启用失败（默认必须 TLS；仅调试可设 GPS_MESH_MASTER_TLS=0）: %s\n" % e
        )
        raise SystemExit(1)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    if pin:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(str(TLS_CERT), str(TLS_KEY))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        sys.stderr.write("mesh-master listening on %s:%s peers=%s tls=on pin=%s\n" % (HOST, PORT, PEERS_PATH, pin))
    else:
        sys.stderr.write("mesh-master listening on %s:%s peers=%s tls=OFF (GPS_MESH_MASTER_TLS=0)\n" % (HOST, PORT, PEERS_PATH))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
