#!/usr/bin/env python3
"""GeoProxy agent — v2rayA 节点池上报/控制面 (:19528)。

- GET /v1/status ：只读 state.env / /proc / ss，无副作用
- POST /v1/control：控制动作经 geoproxy-server CLI 落地（Task 3 实现）
- 所有端点要求 Authorization: Bearer <GPS_AGENT_TOKEN>
"""
from __future__ import annotations

import hmac
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    try:
        return int(raw) if raw else default
    except ValueError:
        sys.stderr.write("geoagent: 环境变量 %s=%r 不是整数\n" % (name, raw))
        raise SystemExit(2)


STATE_PATH = Path(os.environ.get("GPS_STATE", "/etc/geoproxy-server/state.env"))
PEERS_PATH = Path(os.environ.get("GPS_MESH_PEERS", "/etc/geoproxy-server/mesh/peers.json"))
VERSION_PATH = Path(os.environ.get("GPS_VERSION_FILE", "/usr/local/lib/geoproxy-server/VERSION"))
TOKEN = os.environ.get("GPS_AGENT_TOKEN", "")
HOST = os.environ.get("GPS_AGENT_BIND", "127.0.0.1")
PORT = _env_int("GPS_AGENT_PORT", 19528)
MAX_BODY = _env_int("GPS_AGENT_MAX_BODY", 8192)
CLI = os.environ.get("GPS_AGENT_CLI", "/usr/local/bin/geoproxy-server")
PROBE_URL = os.environ.get("GPS_AGENT_PROBE_URL", "https://www.gstatic.com/generate_204")
LOCK = threading.Lock()
_PROBE_CACHE = {"at": 0.0, "ms": None}


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------- state.env / peers / 系统指标（只读） ----------

def parse_env_file(path: Path) -> dict:
    """解析 state.env（gps_env_assign %q 输出）为 dict；缺失/损坏容错。"""
    out: dict = {}
    if not path.is_file():
        return out
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if not key:
            continue
        val = val.strip()
        try:
            out[key] = shlex.split(val)[0] if val else ""
        except (ValueError, IndexError):
            out[key] = val
    return out


def load_peers() -> list:
    if not PEERS_PATH.is_file():
        return []
    try:
        with PEERS_PATH.open(encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    return doc.get("nodes") or []


def read_version() -> str:
    try:
        return VERSION_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def load1() -> float:
    try:
        with open("/proc/loadavg") as f:
            return float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0


def _cpu_sample():
    try:
        with open("/proc/stat") as f:
            line = f.readline()
    except OSError:
        return None
    parts = line.split()
    if not parts or parts[0] != "cpu" or len(parts) < 5:
        return None
    try:
        nums = [int(x) for x in parts[1:]]
    except ValueError:
        return None
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    return sum(nums), idle


def cpu_pct() -> float:
    a = _cpu_sample()
    time.sleep(1.0)
    b = _cpu_sample()
    if not a or not b:
        return 0.0
    dt = b[0] - a[0]
    if dt <= 0:
        return 0.0
    return round(100.0 * (1 - (b[1] - a[1]) / dt), 1)


def mem_pct() -> float:
    total = avail = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1])
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1])
                if total and avail:
                    break
    except (OSError, ValueError, IndexError):
        return 0.0
    if total <= 0:
        return 0.0
    return round(100.0 * (total - avail) / total, 1)


def active_connections(port: str) -> int:
    """ss 统计到代理入站端口的 established 连接数（v4/v6）。"""
    if not port:
        return 0
    try:
        out = subprocess.run(
            ["ss", "-tn", "state", "established"],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return 0
    n = 0
    pat = re.compile(r":%s$" % re.escape(str(port)))
    for line in out.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 4:
            continue
        if pat.search(fields[3]):
            n += 1
    return n


def probe_latency() -> float | None:
    """best-effort 探测外网延迟；缓存 30s；失败返回 None。"""
    now = time.monotonic()
    if now - _PROBE_CACHE["at"] < 30:
        return _PROBE_CACHE["ms"]
    ms = None
    try:
        t0 = time.monotonic()
        p = subprocess.run(
            ["curl", "-fsS", "-o", "/dev/null", "--max-time", "3", PROBE_URL],
            capture_output=True, timeout=5,
        )
        if p.returncode == 0:
            ms = round((time.monotonic() - t0) * 1000, 1)
    except (OSError, subprocess.SubprocessError):
        pass
    _PROBE_CACHE.update(at=now, ms=ms)
    return ms


def _f(v, default: float = 0.0) -> float:
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _i(v, default: int = 0) -> int:
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _pct(v, default: float = 0.0) -> int | float:
    """百分比阈值：整数值返回 int（JSON 输出 80 而非 80.0），小数保留原样。"""
    f = _f(v, default)
    return int(f) if f == int(f) else f


def reset_to_rfc3339(v) -> str:
    if not v:
        return ""
    try:
        ts = int(v)
    except (TypeError, ValueError):
        return ""
    if ts <= 0:
        return ""
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def node_id(st: dict) -> str:
    n = (st.get("TUIC_NAME") or "").strip()
    if n:
        return n
    try:
        n = subprocess.run(["hostname", "-f"], capture_output=True, text=True, timeout=3).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        n = ""
    if not n or n in ("localhost", "localhost.localdomain", "(none)"):
        try:
            n = subprocess.run(["hostname"], capture_output=True, text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            n = ""
    return n or "geoproxy-tuic"


def build_status() -> dict:
    st = parse_env_file(STATE_PATH)
    limit = _f(st.get("TRAFFIC_LIMIT_BYTES"))
    mult = _f(st.get("TRAFFIC_MULT"), 1) or 1.0
    used = _f(st.get("TRAFFIC_USED_BYTES"))
    return {
        "node": {
            "id": node_id(st),
            "protocol": st.get("PROTOCOL") or "tuic",
            "version": read_version(),
        },
        "system": {
            "load1": load1(),
            "cpuPct": cpu_pct(),
            "memUsedPct": mem_pct(),
            "activeConnections": active_connections(st.get("PORT")),
        },
        "latency": {"target": PROBE_URL, "ms": probe_latency()},
        "traffic": {
            "usedBytes": int(used),
            "quotaBytes": int(limit * mult),
            "usedPct": _f(st.get("TRAFFIC_LAST_PCT")),
            "warnPct": _pct(st.get("TRAFFIC_WARN_PCT"), 80),
            "stopPct": _pct(st.get("TRAFFIC_STOP_PCT"), 95),
            "nextReset": reset_to_rfc3339(st.get("TRAFFIC_RESET")),
            "tripped": st.get("TRAFFIC_TRIPPED", "0") == "1",
            "trippedAt": st.get("TRAFFIC_TRIPPED_AT") or None,
            "checkSec": _i(st.get("TRAFFIC_CHECK_SEC"), 300),
        },
        "mesh": {"role": st.get("MESH_ROLE") or "master", "peerCount": len(load_peers())},
        "reportedAt": utc_now(),
    }


def _sanitize(s: str) -> str:
    """KiwiVM API Key 去敏：key=xxx… → key=****。"""
    return re.sub(r"(?i)(key=)[A-Za-z0-9_-]{4,}", r"\1****", s)


def run_cli(args: list, timeout: int = 30) -> tuple[bool, str]:
    """执行 geoproxy-server CLI；返回 (ok, error)。错误消息去敏且只留末 3 行。"""
    try:
        p = subprocess.run([CLI] + args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "cli 执行失败: %s" % e
    if p.returncode == 0:
        return True, ""
    msg = (p.stderr or p.stdout or "").strip().splitlines()
    return False, _sanitize("; ".join(msg[-3:]))


def handle_control(req: dict) -> tuple[int, dict]:
    action = req.get("action")
    if not isinstance(action, str) or not action:
        return 400, {"error": "action required"}
    if not STATE_PATH.is_file():
        return 503, {"error": "not installed"}
    if action == "trip":
        ok, e = run_cli(["traffic", "trip"])
    elif action == "resume":
        ok, e = run_cli(["traffic", "resume"])
    elif action == "set-thresholds":
        warn = req.get("warnPct")
        stop = req.get("stopPct")
        if not (isinstance(warn, (int, float)) and isinstance(stop, (int, float))):
            return 400, {"error": "set-thresholds requires warnPct and stopPct"}
        warn, stop = int(warn), int(stop)
        if not (1 <= warn < stop <= 100):
            return 400, {"error": "invalid thresholds: 1 <= warnPct < stopPct <= 100"}
        ok1, e1 = run_cli(["change", "traffic-warn", str(warn)])
        ok2, e2 = run_cli(["change", "traffic-stop", str(stop)])
        if not (ok1 and ok2):
            return 500, {"error": (e1 or e2) or "set-thresholds failed"}
        return 200, {"ok": True}
    elif action == "set-check-interval":
        sec = req.get("seconds")
        if not isinstance(sec, int):
            return 400, {"error": "set-check-interval requires integer seconds"}
        if sec < 60:
            return 400, {"error": "seconds must be >= 60"}
        ok, e = run_cli(["change", "traffic-interval", str(sec)])
    else:
        return 400, {"error": "unknown action: %s" % action}
    if not ok:
        return 500, {"error": e or "control failed"}
    return 200, {"ok": True}


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    timeout = 15  # 防 slowloris 挂死线程

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

    def _auth(self) -> bool:
        h = self.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            return False
        return hmac.compare_digest(h[7:].strip().encode(), TOKEN.encode())

    def _read_json(self) -> tuple[dict | None, int]:
        raw_len = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(raw_len)
        except ValueError:
            return None, 400
        if length < 0 or length > MAX_BODY:
            return None, 413
        raw = self.rfile.read(length) if length else b"{}"
        try:
            obj = json.loads(raw.decode() or "{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None, 400
        if not isinstance(obj, dict):
            return None, 400
        return obj, 200

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path != "/v1/status":
            self._send(404, {"error": "not found"})
            return
        if not self._auth():
            self._send(401, {"error": "unauthorized"})
            return
        try:
            self._send(200, build_status())
        except Exception as e:  # noqa: BLE001 — 状态构建失败不能打挂服务
            self._send(500, {"error": "status build failed: %s" % e})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path != "/v1/control":
            self._send(404, {"error": "not found"})
            return
        if not self._auth():
            self._send(401, {"error": "unauthorized"})
            return
        req, st = self._read_json()
        if st != 200:
            self._send(st, {"error": "bad request" if st == 400 else "body too large"})
            return
        code, body = handle_control(req)
        self._send(code, body)


def main() -> None:
    if not TOKEN:
        sys.stderr.write("geoagent: 拒绝启动 — GPS_AGENT_TOKEN 为空\n")
        raise SystemExit(2)
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write("geoagent listening on %s:%s state=%s\n" % (HOST, PORT, STATE_PATH))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
