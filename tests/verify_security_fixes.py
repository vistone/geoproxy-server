#!/usr/bin/env python3
"""验证 Python 侧安全修复（跨平台，Windows/Linux 均可运行）"""

import re
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def check(label, condition, detail=""):
    mark = "PASS" if condition else "FAIL"
    print(f"[{mark}] {label}")
    if detail:
        print(f"       {detail}")

print("=" * 60)
print("GeoProxy Server — Python 侧安全修复验证")
print("=" * 60)

# ─── geoagent.py ──────────────────────────────────────────
print("\n── geoagent.py ──")

with open(os.path.join(REPO, "scripts", "geoagent.py")) as f:
    ga_src = f.read()

m = re.search(r'HOST = os\.environ\.get\("GPS_AGENT_BIND",\s*"([^"]+)"\)', ga_src)
bind = m.group(1) if m else "NOT_FOUND"
check("C-01: 默认绑定 127.0.0.1", bind == "127.0.0.1", f"当前默认值: {bind}")

m = re.search(r'ALLOW_IPS_RAW = os\.environ\.get\("GPS_AGENT_ALLOW_IPS",\s*"([^"]+)"\)', ga_src)
allow = m.group(1) if m else "NOT_FOUND"
check("C-01: 默认 IP 白名单仅本机",
      allow == "127.0.0.1,::1",
      f"当前默认值: {allow}")

check("M-06: 速率限制器存在", "class RateLimiter" in ga_src)
check("C-01: IP 白名单方法存在", "_ip_allowed" in ga_src)
check("M-06: 认证失败速率限制", "_AUTH_FAIL_LIMIT" in ga_src)

# 检查 do_GET / do_POST 中是否调用了 _ip_allowed
get_idx = ga_src.find("def do_GET")
post_idx = ga_src.find("def do_POST")
get_body = ga_src[get_idx:post_idx] if get_idx >= 0 and post_idx >= 0 else ""
check("C-01: do_GET 调用 IP 白名单", "_ip_allowed()" in get_body)
check("C-01: do_POST 调用 IP 白名单", "_ip_allowed()" in ga_src[post_idx:post_idx+2000])

# 检查速率限制调用
check("M-06: do_GET 调用速率限制", "_rate_limit_check" in get_body)

# ─── mesh_master.py ───────────────────────────────────────
print("\n── mesh_master.py ──")

with open(os.path.join(REPO, "scripts", "mesh_master.py")) as f:
    mm_src = f.read()

check("M-06: 速率限制器存在", "class RateLimiter" in mm_src)
check("H-02: stale 节点清理函数", "def cleanup_stale" in mm_src)

# health 端点
health_match = re.search(
    r'path == "/v1/health".*?return',
    mm_src, re.DOTALL)
if health_match:
    h_section = health_match.group()
    leak = any(k in h_section for k in ['"role"', '"prefix"', '"stale_sec"', "prefix=str(PREFIX)"])
    check("H-05: health 端点无信息泄露", not leak,
          "响应仅含 ok 字段" if not leak else "检测到敏感字段")
else:
    check("H-05: health 端点可定位", False)

# 分配池
m = re.search(r'MESH_ALLOC_PREFIXLEN.*?"(\d+)"', mm_src)
alloc = m.group(1) if m else None
check("H-02: Overlay 分配池 ≤ /24",
      alloc is not None and int(alloc) <= 24,
      f"当前 prefixlen: {alloc}")

# 证书有效期
m = re.search(r'"-days",\s*"(\d+)"', mm_src)
days = m.group(1) if m else None
check("M-03: 证书有效期 ≤ 365 天",
      days is not None and int(days) <= 365,
      f"当前天数: {days}")

# register 中调用 cleanup_stale
# 找到 register 入口，往后扫描 200 行
lines = mm_src.split('\n')
reg_line = None
for i, line in enumerate(lines):
    if '/v1/register' in line and 'path' in line:
        reg_line = i
        break
found_cleanup = False
if reg_line is not None:
    for line in lines[reg_line:reg_line+200]:
        if 'cleanup_stale' in line:
            found_cleanup = True
            break
check("H-02: register 中调用 stale 清理", found_cleanup)

# ─── 语法检查 ─────────────────────────────────────────────
print("\n── 语法检查 ──")

import py_compile
for script in ["scripts/geoagent.py", "scripts/mesh_master.py"]:
    path = os.path.join(REPO, script)
    try:
        py_compile.compile(path, doraise=True)
        check(f"{script} 语法正确", True)
    except py_compile.PyCompileError as e:
        check(f"{script} 语法正确", False, str(e))

# ─── Bash 侧静态检查（源码 grep） ─────────────────────────
print("\n── Bash 侧静态检查（源码扫描）──")

# H-01
with open(os.path.join(REPO, "lib", "mesh", "_common.sh")) as f:
    mc_src = f.read()
check("H-01: 使用 gps_validate_ipv4 做严格校验",
      "gps_validate_ipv4" in mc_src and "127.*" in mc_src)

# H-04
with open(os.path.join(REPO, "lib", "common.sh")) as f:
    cm_src = f.read()
# gps_source_env 函数中不应有 set -a
srcenv_match = re.search(r'gps_source_env\(\).*?^\}', cm_src, re.DOTALL | re.MULTILINE)
if srcenv_match:
    has_set_a = 'set -a' in srcenv_match.group()
    check("H-04: gps_source_env 不再使用 set -a", not has_set_a)
else:
    check("H-04: 定位 gps_source_env 函数", False)

# M-05
randport_match = re.search(r'^rand_port\(\).*?^\}', cm_src, re.DOTALL | re.MULTILINE)
if randport_match:
    has_urandom = '/dev/urandom' in randport_match.group()
    check("M-05: rand_port 使用 /dev/urandom", has_urandom)
else:
    check("M-05: 定位 rand_port 函数", False)

# H-03
with open(os.path.join(REPO, "lib", "download.sh")) as f:
    dl_src = f.read()
check("H-03: 脚本树校验有关键文件检查",
      "required" in dl_src and "geoproxy-server.sh" in dl_src and "bash -n" in dl_src)

# M-03 tls.sh
with open(os.path.join(REPO, "lib", "tls.sh")) as f:
    tls_src = f.read()
m = re.search(r' -days (\d+) ', tls_src)
tls_days = m.group(1) if m else None
check("M-03: lib/tls.sh 证书有效期 ≤ 365",
      tls_days is not None and int(tls_days) <= 365,
      f"当前天数: {tls_days}")

# M-03 mesh _common.sh
m = re.search(r'-days\s+(\d+)', mc_src)
mesh_days = m.group(1) if m else None
check("M-03: mesh/_common.sh 证书有效期 ≤ 365",
      mesh_days is not None and int(mesh_days) <= 365,
      f"当前天数: {mesh_days}")

# ─── 汇总 ─────────────────────────────────────────────────
print("\n" + "=" * 60)
print("验证完成。请在 Linux 环境下运行：")
print("  sudo bash tests/verify_security_fixes.sh")
print("以执行完整的运行时集成测试。")
print("=" * 60)
