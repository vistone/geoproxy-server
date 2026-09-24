#!/usr/bin/env python3
"""GeoProxy mesh master registry — POST /v1/register, POST /v1/heartbeat, GET /v1/peers, GET /v1/health.

POST /v1/hook/github：GitHub Release webhook（HMAC SHA256 签名校验）触发 upgrade self。
GET /v1/hook/github：返回 webhook 端点说明（浏览器探测用；实际投递须 POST）。
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
import shutil
import ssl
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

try:
    import fcntl
except ImportError:  # 非 Linux（本地测试环境）无 fcntl
    fcntl = None


# ---------- 速率限制 ----------

class RateLimiter:
    """滑动窗口速率限制器：每 IP 每 window_sec 秒最多 max_requests 次。"""

    def __init__(self, max_requests: int, window_sec: float):
        self.max_requests = max_requests
        self.window_sec = window_sec
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def check(self, ip: str) -> bool:
        now = time.monotonic()
        with self._lock:
            bucket = self._hits.setdefault(ip, [])
            # 清理过期条目
            cutoff = now - self.window_sec
            while bucket and bucket[0] < cutoff:
                bucket.pop(0)
            if not bucket:
                # 空桶回收，避免扫描 IP 导致 dict 膨胀
                self._hits.pop(ip, None)
                bucket = self._hits.setdefault(ip, [])
            if len(bucket) >= self.max_requests:
                return False
            bucket.append(now)
            return True


_REGISTER_LIMIT = RateLimiter(
    int(os.environ.get("GPS_MESH_REGISTER_RATE", "10")),
    float(os.environ.get("GPS_MESH_REGISTER_WINDOW", "60")),
)
_HEARTBEAT_LIMIT = RateLimiter(
    int(os.environ.get("GPS_MESH_HEARTBEAT_RATE", "60")),
    float(os.environ.get("GPS_MESH_HEARTBEAT_WINDOW", "60")),
)
_GENERAL_LIMIT = RateLimiter(
    int(os.environ.get("GPS_MESH_GENERAL_RATE", "60")),
    float(os.environ.get("GPS_MESH_GENERAL_WINDOW", "60")),
)
_WEBHOOK_LIMIT = RateLimiter(
    int(os.environ.get("GPS_MESH_WEBHOOK_RATE", "20")),
    float(os.environ.get("GPS_MESH_WEBHOOK_WINDOW", "60")),
)
# N-04：近期 delivery id 去重（防签名请求重放）
_WEBHOOK_SEEN: dict[str, float] = {}
_WEBHOOK_SEEN_LOCK = threading.Lock()
_WEBHOOK_SEEN_TTL = float(os.environ.get("GPS_MESH_WEBHOOK_DELIVERY_TTL", "3600"))


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    try:
        return int(raw) if raw else default
    except ValueError:
        sys.stderr.write("mesh-master: 环境变量 %s=%r 不是整数\n" % (name, raw))
        raise SystemExit(2)


PEERS_PATH = Path(os.environ.get("GPS_MESH_PEERS", "/etc/geoproxy-server/mesh/peers.json"))
CLUSTER_VERSION_PATH = Path(
    os.environ.get("GPS_MESH_CLUSTER_VERSION", str(PEERS_PATH.parent / "cluster-version.json"))
)
TOKEN = os.environ.get("MESH_CLUSTER_TOKEN", "")
WEBHOOK_SECRET = os.environ.get("GPS_GITHUB_WEBHOOK_SECRET", "")
VERSION_PATH = Path(os.environ.get("GPS_VERSION_FILE", "/usr/local/lib/geoproxy-server/VERSION"))
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

# 分配池大小：可通过 MESH_ALLOC_PREFIXLEN 控制；默认 /20（4093 个可用地址）
_ALLOC_PREFIXLEN = int(os.environ.get("MESH_ALLOC_PREFIXLEN", "20"))
if _ALLOC_PREFIXLEN < 16 or _ALLOC_PREFIXLEN > 30:
    _ALLOC_PREFIXLEN = 20
if PREFIX.prefixlen < _ALLOC_PREFIXLEN:
    _ALLOC_NET = ipaddress.ip_network(
        "%s/%d" % (PREFIX.network_address, _ALLOC_PREFIXLEN), strict=False)
else:
    _ALLOC_NET = PREFIX
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
    try:
        with PEERS_PATH.open("r", encoding="utf-8") as f:
            doc = json.load(f)
        if not isinstance(doc, dict):
            raise ValueError("peers doc is not an object")
        return doc
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        # 损坏隔离重建：否则每个注册请求都崩、健康检查却依旧 200（监控失明）。
        # 成员每 60s 幂等重新注册，注册面自动恢复。
        bak = PEERS_PATH.with_name("%s.corrupt.%s" % (PEERS_PATH.name, utc_now().replace("-", "").replace(":", "")))
        try:
            PEERS_PATH.replace(bak)
        except OSError:
            pass
        sys.stderr.write("mesh-master: peers.json 损坏，已隔离为 %s 并重建（成员会自动重新注册）\n" % bak.name)
        return empty_doc()


class _PeersFileLock:
    """peers.json 跨进程互斥：shell 侧（mesh-sync timer / CLI）与本进程共用同一把锁文件。"""

    def __enter__(self) -> "_PeersFileLock":
        self.lf = open(str(PEERS_PATH) + ".lock", "a")
        if fcntl is not None:
            fcntl.lockf(self.lf, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc) -> None:
        if fcntl is not None:
            try:
                fcntl.lockf(self.lf, fcntl.LOCK_UN)
            except OSError:
                pass
        self.lf.close()


def save_doc(doc: dict) -> None:
    PEERS_PATH.parent.mkdir(parents=True, exist_ok=True)
    doc["schema"] = 1
    doc["updated_at"] = utc_now()
    tmp = PEERS_PATH.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())  # 断电不落半截/空文件（kill -9 由 rename 原子性兜底）
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


def cleanup_stale(nodes: list) -> list:
    """移除超过 STALE_SEC * 2 未心跳的节点，释放 overlay IP。"""
    now = datetime.now(timezone.utc)
    alive = []
    for n in nodes:
        ts = parse_utc(n.get("last_seen"))
        if ts is None:
            # 无 last_seen 的保留（可能是手动导入的）
            alive.append(n)
            continue
        if (now - ts).total_seconds() <= STALE_SEC * 10:
            alive.append(n)
    return alive


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
        argv = [UPGRADE_CLI, "upgrade", "self", "--ver", tag]
        if not shutil.which("systemd-run"):
            # 禁止同 cgroup 回退：升级链会 restart mesh-master，KillMode 会杀掉升级进程
            # → gps_svc_boot 永不执行 → 代理停机不自愈
            sys.stderr.write(
                "mesh-master: systemd-run 不可用，拒绝同 cgroup 升级（tag=%s）；"
                "请安装 systemd 或手动 upgrade self\n" % tag)
            return
        # 唯一 unit 名：避免固定名冲突导致升级永不执行且无回退
        unit = "gps-webhook-upgrade-%s-%d" % (
            re.sub(r"[^A-Za-z0-9_-]", "", tag)[:32] or "tag",
            int(time.time()),
        )
        esc = ["systemd-run", "--collect", "--quiet", "--wait",
               "--unit=%s" % unit] + argv
        try:
            p = subprocess.run(esc, capture_output=True, timeout=900, check=False)
        except OSError as e:
            sys.stderr.write(
                "mesh-master: systemd-run 执行失败，拒绝同 cgroup 回退: %s\n" % e)
            return
        if p.returncode != 0:
            sys.stderr.write("mesh-master webhook upgrade rc=%s stderr=%s\n" % (
                p.returncode, (p.stderr or b"").decode(errors="replace")[-2000:]))
    except (OSError, subprocess.SubprocessError) as e:
        sys.stderr.write("mesh-master webhook upgrade failed: %s\n" % e)
    finally:
        with _UPGRADE_LOCK:
            _UPGRADE_RUNNING = False


def load_cluster_target() -> str | None:
    if not CLUSTER_VERSION_PATH.is_file():
        return None
    try:
        with CLUSTER_VERSION_PATH.open("r", encoding="utf-8") as f:
            doc = json.load(f)
        tag = (doc.get("target_version") or "").strip()
        return tag if _TAG_RE.fullmatch(tag) else None
    except (OSError, json.JSONDecodeError, TypeError):
        return None


def save_cluster_target(tag: str) -> None:
    if not _TAG_RE.fullmatch(tag):
        return
    CLUSTER_VERSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    doc = {"target_version": tag, "set_at": utc_now()}
    tmp = CLUSTER_VERSION_PATH.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(CLUSTER_VERSION_PATH)
    try:
        os.chmod(CLUSTER_VERSION_PATH, 0o600)
    except OSError:
        pass


def cluster_payload() -> dict:
    tag = load_cluster_target()
    if not tag:
        return {"cluster": {"target_version": None, "auto_upgrade": True}}
    return {"cluster": {"target_version": tag, "auto_upgrade": True}}


def load_local_version() -> str | None:
    """读本地脚本版本（GPS_VERSION_FILE）；缺失/损坏返回 None（守卫退化为放行）。"""
    try:
        with VERSION_PATH.open("r", encoding="utf-8") as f:
            v = f.read().strip()
    except OSError:
        return None
    return v if _TAG_RE.fullmatch(v) else None


def _semver_key(tag: str) -> tuple[int, int, int] | None:
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def schedule_upgrade(tag: str) -> tuple[int, dict]:
    """后台触发 upgrade self；立即返回，避免 GitHub webhook 超时。"""
    global _UPGRADE_RUNNING
    # 降级/同版重放防护：签名正确的旧 release 报文被重放时不得触发降级
    # （cluster-version.json 还会传导给成员自动升级）。确需降级请手动 upgrade self --ver。
    local = load_local_version()
    lk = _semver_key(local) if local else None
    tk = _semver_key(tag)
    if lk is not None and tk is not None and tk <= lk:
        sys.stderr.write("mesh-master: webhook 拒绝降级/重复 %s（本地 %s）；如确需降级请手动 upgrade self --ver\n" % (tag, local))
        return 200, {"ok": True, "ignored": "downgrade", "target": tag, "local": local, **cluster_payload()}
    save_cluster_target(tag)
    with _UPGRADE_LOCK:
        if _UPGRADE_RUNNING:
            return 409, {"error": "upgrade already in progress"}
        _UPGRADE_RUNNING = True
    threading.Thread(target=_run_upgrade, args=(tag,), daemon=True).start()
    return 202, {"ok": True, "upgrade": tag, "status": "scheduled", **cluster_payload()}


def _int_or_zero(v) -> int:
    """心跳/注册里的 tripped 等整数字段容错：畸形值按 0 处理，不炸 handler 线程。"""
    try:
        return int(v) if v else 0
    except (TypeError, ValueError):
        return 0


def _token_eq(a: bytes, b: bytes) -> bool:
    """恒定时间比较；长度不等直接 False（compare_digest 否则抛 ValueError）。"""
    if len(a) != len(b):
        return False
    return hmac.compare_digest(a, b)


def auth_ok(handler: BaseHTTPRequestHandler) -> bool:
    if not TOKEN:
        return True
    h = handler.headers.get("Authorization", "")
    if h.startswith("Bearer "):
        return _token_eq(h[7:].strip().encode(), TOKEN.encode())
    t = handler.headers.get("X-Mesh-Token", "")
    return _token_eq(t.strip().encode(), TOKEN.encode())


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
            "-days", "365", "-nodes", "-subj", "/CN=geoproxy-mesh",
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
        if not self._rate_limit_check(_WEBHOOK_LIMIT):
            return
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
        # N-04：同一 X-GitHub-Delivery 只接受一次
        delivery = (self.headers.get("X-GitHub-Delivery") or "").strip()
        if delivery:
            now = time.monotonic()
            with _WEBHOOK_SEEN_LOCK:
                cutoff = now - _WEBHOOK_SEEN_TTL
                for k, ts in list(_WEBHOOK_SEEN.items()):
                    if ts < cutoff:
                        del _WEBHOOK_SEEN[k]
                if delivery in _WEBHOOK_SEEN:
                    self._send(200, {"ok": True, "duplicate": True})
                    return
                _WEBHOOK_SEEN[delivery] = now
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
        # 仅 release published；push tag 易被旧签名重放诱导降级
        if event != "release":
            self._send(200, {"ok": True, "ignored": True, "event": event})
            return
        tag = extract_release_tag(event, payload)
        if not tag:
            self._send(200, {"ok": True, "ignored": True, "event": event})
            return
        code, body = schedule_upgrade(tag)
        self._send(code, body)

    def _client_ip(self) -> str:
        ip = self.client_address[0]
        if ip.startswith("::ffff:"):
            ip = ip[7:]
        return ip

    def _rate_limit_check(self, limiter: RateLimiter) -> bool:
        if not limiter.check(self._client_ip()):
            self._send(429, {"error": "rate limit exceeded"})
            return False
        return True

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/v1/health":
            if not self._rate_limit_check(_GENERAL_LIMIT):
                return
            self._send(200, {"ok": True})
            return
        if path == "/v1/hook/github":
            if not self._rate_limit_check(_WEBHOOK_LIMIT):
                return
            # N-03：不暴露 configured，避免侦察 webhook 是否启用
            self._send(200, {
                "ok": True,
                "endpoint": "github webhook",
                "method": "POST required",
            })
            return
        if path == "/v1/peers":
            if not self._rate_limit_check(_GENERAL_LIMIT):
                return
            if not auth_ok(self):
                self._send(401, {"error": "unauthorized"})
                return
            # 锁内只组装不发送：慢客户端的 socket 写最多阻塞到 timeout，不能拖住所有写路径
            with LOCK:
                body = {**annotate_alive(load_doc()), **cluster_payload()}
            self._send(200, body)
            return
        if path == "/v1/cluster":
            if not self._rate_limit_check(_GENERAL_LIMIT):
                return
            if not auth_ok(self):
                self._send(401, {"error": "unauthorized"})
                return
            self._send(200, {"ok": True, **cluster_payload()})
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
        limiter = _HEARTBEAT_LIMIT if path == "/v1/heartbeat" else _REGISTER_LIMIT
        if not self._rate_limit_check(limiter):
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
            body = None
            code = 404
            with LOCK, _PeersFileLock():
                doc = load_doc()
                for n in doc.get("nodes") or []:
                    if n.get("node_id") == nid:
                        n["last_seen"] = utc_now()
                        ep = _clean(req.get("endpoint"), _FIELD_MAX)
                        if ep:
                            n["endpoint"] = ep
                        n["tripped"] = 1 if _int_or_zero(req.get("tripped")) else 0
                        save_doc(doc)
                        body = {"ok": True, "peers": annotate_alive(doc), **cluster_payload()}
                        code = 200
                        break
            # 锁外发送：慢客户端不能拖住 register/heartbeat 写路径
            if code == 200:
                self._send(200, body)
            else:
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

        with LOCK, _PeersFileLock():
            doc = load_doc()
            prev = list(doc.get("nodes", []))
            # 每次注册时清理长期失活节点，释放 overlay IP（H-02）
            cleaned = cleanup_stale(prev)
            nodes = [n for n in cleaned if n.get("node_id") != nid]
            used = used_overlays(nodes)
            old = next((n for n in prev if n.get("node_id") == nid), None)
            old_ip = (old.get("overlay_ip") or "").split("/")[0] if old else ""
            if want_raw and overlay_policy_ok(want_raw) and want_raw not in used:
                overlay = want_raw
            elif old_ip and overlay_policy_ok(old_ip) and old_ip not in used:
                # 旧 IP 已被其他节点占用（并发/导入造成的冲突）时改派新地址，避免冲突固化
                overlay = old_ip
            else:
                try:
                    overlay = alloc_overlay(used)
                except RuntimeError:
                    self._send(503, {"error": "overlay pool exhausted"})
                    return
            entry = {
                "node_id": nid,
                "public_key": pubkey,
                "endpoint": endpoint,
                "overlay_ip": overlay,
                "roles": roles,
                "keepalive": keepalive,
                "tripped": 1 if _int_or_zero(req.get("tripped")) else 0,
                "last_seen": utc_now(),
            }
            nodes.append(entry)
            doc["nodes"] = nodes
            save_doc(doc)
            body = {"node": entry, "peers": annotate_alive(doc), **cluster_payload()}
        self._send(200, body)


class _TLSThreadingHTTPServer(ThreadingHTTPServer):
    """TLS 握手在 worker 线程执行且带超时。

    旧实现把 TLS wrap 在监听 socket 上：SSLSocket.accept() 会在 serve_forever 的
    主线程内同步完成握手，任意外部地址只连不发 ClientHello 即可无限期冻结整个
    注册面（register/heartbeat/health 全部无响应且 systemd 无感知）。
    """

    daemon_threads = True
    handshake_timeout = 10.0

    def __init__(self, addr, handler, ssl_ctx=None):
        self.ssl_ctx = ssl_ctx
        super().__init__(addr, handler)

    def finish_request(self, request, client_address):
        if self.ssl_ctx is not None:
            try:
                tls = self.ssl_ctx.wrap_socket(
                    request, server_side=True, do_handshake_on_connect=False)
                tls.settimeout(self.handshake_timeout)
                tls.do_handshake()
                request = tls
            except (ssl.SSLError, OSError):
                return  # 无效/超时握手：静默丢弃，不进 handle_error 刷日志
        super().finish_request(request, client_address)


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
    ctx = None
    if pin:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(str(TLS_CERT), str(TLS_KEY))
    httpd = _TLSThreadingHTTPServer((HOST, PORT), Handler, ctx)
    if pin:
        sys.stderr.write("mesh-master listening on %s:%s peers=%s tls=on pin=%s\n" % (HOST, PORT, PEERS_PATH, pin))
    else:
        sys.stderr.write("mesh-master listening on %s:%s peers=%s tls=OFF (GPS_MESH_MASTER_TLS=0)\n" % (HOST, PORT, PEERS_PATH))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
