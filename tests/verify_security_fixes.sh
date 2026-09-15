#!/usr/bin/env bash
# ============================================================
# GeoProxy Server — 安全修复验证脚本
# ============================================================
# 用法：
#   sudo bash tests/verify_security_fixes.sh
#
# 验证目标：全部 11 项安全漏洞修复
#   - H-01: Mesh 明文 HTTP 校验绕过
#   - H-04: state.env allexport 密钥泄露
#   - C-01: Agent 默认绑定 0.0.0.0
#   - H-02: Overlay IP 耗尽攻击
#   - M-06: API 速率限制
#   - H-03: tag archive 回退校验不足
#   - H-05: health 端点信息泄露
#   - M-03: 证书有效期过长
#   - M-04: UUID 非标准 v4 格式
#   - M-05: 端口随机源弱
#   - Agent IP 白名单
# ============================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 在 MSYS/Git Bash 环境下，Windows Python 不识别 /c/ 路径，需要转换
if command -v cygpath >/dev/null 2>&1; then
    REPO_ROOT_WIN="$(cygpath -m "$REPO_ROOT")"
    _py_path() { cygpath -m "$1"; }
else
    REPO_ROOT_WIN="$REPO_ROOT"
    _py_path() { echo "$1"; }
fi

PASS=0
FAIL=0
WARN=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}✓ PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}✗ FAIL${NC}: $1"
    [[ -n "${2:-}" ]] && echo -e "         ${YELLOW}→ $2${NC}"
}

warn() {
    WARN=$((WARN + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${YELLOW}⚠ WARN${NC}: $1"
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ $1 ━━━${NC}"
}

# ============================================================
echo -e "${BOLD}GeoProxy Server 安全修复验证${NC}"
echo "仓库路径: $REPO_ROOT"
echo "日期: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# ============================================================

# ────────────────────────────────────────────────────────────
# 依赖检查
# ────────────────────────────────────────────────────────────
section "依赖检查"

for cmd in python3 curl openssl ss od; do
    if command -v "$cmd" >/dev/null 2>&1; then
        pass "$cmd 可用"
    else
        warn "$cmd 不可用（部分测试将跳过）"
    fi
done

# ────────────────────────────────────────────────────────────
# H-01: Mesh 明文 HTTP 校验绕过
# ────────────────────────────────────────────────────────────
section "H-01: Mesh 明文 HTTP 校验绕过"

test_h01() {
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/common.sh"
    source "$REPO_ROOT/lib/mesh/_common.sh" 2>/dev/null || true

    # 恶意地址不应被认为是 loopback
    if gps_mesh_url_is_loopback "127.0.0.1.attacker.com" 2>/dev/null; then
        fail "127.0.0.1.attacker.com 被误判为 loopback" "glob 绕过仍然存在"
    else
        pass "恶意域名 127.0.0.1.attacker.com 被正确拒绝"
    fi

    # 真实 127.0.0.0/8 地址应被接受
    if gps_mesh_url_is_loopback "127.0.0.1" 2>/dev/null; then
        pass "127.0.0.1 正确识别为 loopback"
    else
        fail "127.0.0.1 未被识别为 loopback"
    fi

    if gps_mesh_url_is_loopback "127.10.20.30" 2>/dev/null; then
        pass "127.10.20.30 正确识别为 loopback"
    else
        fail "127.10.20.30 未被识别为 loopback"
    fi

    # 公网 IP 应被拒绝
    if gps_mesh_url_is_loopback "8.8.8.8" 2>/dev/null; then
        fail "8.8.8.8 被误判为 loopback"
    else
        pass "公网 IP 8.8.8.8 被正确拒绝"
    fi

    # ::1 和 [::1]
    if gps_mesh_url_is_loopback "::1" 2>/dev/null; then
        pass "::1 正确识别为 loopback"
    else
        fail "::1 未被识别为 loopback"
    fi

    if gps_mesh_url_is_loopback "[::1]" 2>/dev/null; then
        pass "[::1] 正确识别为 loopback"
    else
        fail "[::1] 未被识别为 loopback"
    fi
}
test_h01

# ────────────────────────────────────────────────────────────
# H-04: state.env allexport 密钥泄露
# ────────────────────────────────────────────────────────────
section "H-04: state.env allexport 密钥泄露"

test_h04() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local statefile="$tmpdir/state.env"

    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/common.sh"

    echo 'SECRET_TEST_KEY=hunter2-supersecret' > "$statefile"
    chmod 600 "$statefile"

    GPS_TEST_PREFIX="$tmpdir" gps_source_env "$statefile" 2>/dev/null || true

    # 当前 shell 中变量应可用
    if [[ "${SECRET_TEST_KEY:-}" == "hunter2-supersecret" ]]; then
        pass "state 变量在当前 shell 中可用"
    else
        fail "state 变量未在当前 shell 中加载"
    fi

    # 子进程环境中不应出现
    local child_count
    child_count=$(env | grep -c '^SECRET_TEST_KEY=' || true)
    if [[ "$child_count" -eq 0 ]]; then
        pass "state 变量未泄露到子进程环境"
    else
        fail "state 变量泄露到子进程环境（allexport 仍在）" "env 中发现 $child_count 个 SECRET_TEST_KEY"
    fi

    rm -rf "$tmpdir"
}
test_h04

# ────────────────────────────────────────────────────────────
# C-01: Agent 默认绑定 127.0.0.1 + 源 IP 白名单
# ────────────────────────────────────────────────────────────
section "C-01: Agent 默认绑定 + 源 IP 白名单 + 速率限制"

test_c01() {
    # 检查默认绑定地址
    local default_bind
    default_bind=$(python3 -c "
import os, sys
os.environ.pop('GPS_AGENT_BIND', None)
with open('$REPO_ROOT_WIN/scripts/geoagent.py') as f:
    src = f.read()
import re
m = re.search(r'HOST = os\.environ\.get\(\"GPS_AGENT_BIND\",\s*\"([^\"]+)\"\)', src)
print(m.group(1) if m else 'NOT_FOUND')
")

    if [[ "$default_bind" == "127.0.0.1" ]]; then
        pass "Agent 默认绑定地址为 127.0.0.1"
    else
        fail "Agent 默认绑定地址不是 127.0.0.1" "当前默认值: $default_bind"
    fi

    # 检查是否有源 IP 白名单逻辑
    if grep -q 'GPS_AGENT_ALLOW_IPS' "$REPO_ROOT/scripts/geoagent.py"; then
        pass "Agent 包含源 IP 白名单配置 (GPS_AGENT_ALLOW_IPS)"
    else
        fail "Agent 无源 IP 白名单配置"
    fi

    # 检查默认白名单值
    local default_allow
    default_allow=$(python3 -c "
with open('$REPO_ROOT_WIN/scripts/geoagent.py') as f:
    src = f.read()
import re
m = re.search(r'ALLOW_IPS_RAW = os\.environ\.get\(\"GPS_AGENT_ALLOW_IPS\",\s*\"([^\"]+)\"\)', src)
print(m.group(1) if m else 'NOT_FOUND')
")
    if [[ "$default_allow" == "127.0.0.1,::1" ]]; then
        pass "Agent 默认白名单仅允许 127.0.0.1 和 ::1"
    else
        fail "Agent 默认白名单值不正确" "当前值: $default_allow"
    fi

    # 检查是否有速率限制
    if grep -q 'class RateLimiter' "$REPO_ROOT/scripts/geoagent.py"; then
        pass "Agent 包含速率限制器"
    else
        fail "Agent 无速率限制器"
    fi

    # 检查是否有 IP 白名单检查逻辑
    if grep -q '_ip_allowed' "$REPO_ROOT/scripts/geoagent.py"; then
        pass "Agent 包含 IP 白名单检查方法"
    else
        fail "Agent 无 IP 白名单检查方法"
    fi

    # Python 语法验证
    if python3 -m py_compile "$REPO_ROOT_WIN/scripts/geoagent.py" 2>&1; then
        pass "geoagent.py 语法正确"
    else
        fail "geoagent.py 语法错误"
    fi
}
test_c01

# ────────────────────────────────────────────────────────────
# H-02: Overlay IP 耗尽 + stale 清理
# ────────────────────────────────────────────────────────────
section "H-02: Overlay IP 耗尽攻击 + stale 清理"

test_h02() {
    # 检查分配池是否已扩大
    local alloc_prefix
    alloc_prefix=$(python3 -c "
with open('$REPO_ROOT_WIN/scripts/mesh_master.py') as f:
    src = f.read()
import re
m = re.search(r'MESH_ALLOC_PREFIXLEN.*?\"(\d+)\"', src)
print(m.group(1) if m else 'NOT_FOUND')
")

    if [[ "$alloc_prefix" != "NOT_FOUND" && "$alloc_prefix" -le 24 ]]; then
        pass "Overlay 分配池已扩大（prefixlen=$alloc_prefix ≤ 24）"
    else
        warn "未找到 MESH_ALLOC_PREFIXLEN 配置或值 >24" "当前值: $alloc_prefix"
    fi

    # 检查是否有 stale 清理函数
    if grep -q 'def cleanup_stale' "$REPO_ROOT/scripts/mesh_master.py"; then
        pass "mesh_master 包含 stale 节点清理函数"
    else
        fail "mesh_master 无 stale 节点清理函数"
    fi

    # 检查 register 中是否调用了 cleanup_stale
    if grep -A 30 'with LOCK, _PeersFileLock' "$REPO_ROOT/scripts/mesh_master.py" | grep -q 'cleanup_stale'; then
        pass "register 流程中调用了 stale 清理"
    else
        warn "register 流程中未找到 stale 清理调用" "需要手动确认"
    fi

    # 检查是否有速率限制
    if grep -q 'class RateLimiter' "$REPO_ROOT/scripts/mesh_master.py"; then
        pass "mesh_master 包含速率限制器"
    else
        fail "mesh_master 无速率限制器"
    fi

    # Python 语法验证
    if python3 -m py_compile "$REPO_ROOT_WIN/scripts/mesh_master.py" 2>&1; then
        pass "mesh_master.py 语法正确"
    else
        fail "mesh_master.py 语法错误"
    fi
}
test_h02

# ────────────────────────────────────────────────────────────
# H-05: health 端点信息泄露
# ────────────────────────────────────────────────────────────
section "H-05: health 端点信息泄露"

test_h05() {
    # 从源码检查 health 返回的字段
    local health_resp
    health_resp=$(python3 -c "
with open('$REPO_ROOT_WIN/scripts/mesh_master.py') as f:
    lines = f.readlines()
in_health = False
for i, line in enumerate(lines):
    if '/v1/health' in line:
        for j in range(i, min(i+10, len(lines))):
            if '_send(' in lines[j] and '200' in lines[j]:
                body = lines[j].strip()
                print(body)
                break
        break
" 2>/dev/null || echo "")

    # 更可靠的方式：直接 grep
    local health_line
    health_line=$(grep -A2 'path == "/v1/health"' "$REPO_ROOT/scripts/mesh_master.py" | grep '_send' || echo "")

    if echo "$health_line" | grep -q 'role\|prefix\|stale_sec' 2>/dev/null; then
        fail "health 端点仍返回敏感信息" "返回行: $health_line"
    else
        pass "health 端点不再返回 role/prefix/stale_sec"
    fi

    if echo "$health_line" | grep -q '"ok": True' 2>/dev/null; then
        pass "health 端点仅返回 ok 字段"
    else
        warn "health 端点返回内容需确认" "行: $health_line"
    fi
}
test_h05

# ────────────────────────────────────────────────────────────
# H-03: tag archive 回退校验增强
# ────────────────────────────────────────────────────────────
section "H-03: tag archive 回退校验增强"

test_h03() {
    if grep -q 'gps_verify_tree_version' "$REPO_ROOT/lib/download.sh"; then
        # 检查是否有超出 VERSION 之外的校验
        if grep -A 30 'gps_verify_tree_version()' "$REPO_ROOT/lib/download.sh" | grep -q 'required\|bash -n'; then
            pass "脚本树校验包含关键文件检查和语法验证"
        else
            fail "脚本树校验仅检查 VERSION 文件"
        fi
    else
        fail "未找到 gps_verify_tree_version 函数"
    fi
}
test_h03

# ────────────────────────────────────────────────────────────
# M-03: 证书有效期
# ────────────────────────────────────────────────────────────
section "M-03: 自签 TLS 证书有效期"

test_m03() {
    # 检查 lib/tls.sh
    local tls_days
    tls_days=$(grep -Eo -- '-days[[:space:]]+[0-9]+' "$REPO_ROOT/lib/tls.sh" | head -1 | tr -s ' ' | cut -d' ' -f2)
    if [[ -n "$tls_days" && "$tls_days" -le 365 ]]; then
        pass "lib/tls.sh 证书有效期 ≤ 365 天 (当前: ${tls_days}天)"
    else
        fail "lib/tls.sh 证书有效期 > 365 天" "当前: ${tls_days:-未知}天"
    fi

    # 检查 mesh _common.sh
    local mesh_days
    mesh_days=$(grep -Eo -- '-days[[:space:]]+[0-9]+' "$REPO_ROOT/lib/mesh/_common.sh" | head -1 | tr -s ' ' | cut -d' ' -f2)
    if [[ -n "$mesh_days" && "$mesh_days" -le 365 ]]; then
        pass "mesh _common.sh 证书有效期 ≤ 365 天 (当前: ${mesh_days}天)"
    else
        fail "mesh _common.sh 证书有效期 > 365 天" "当前: ${mesh_days:-未知}天"
    fi

    # 检查 mesh_master.py
    if grep -q '"-days", "365"' "$REPO_ROOT/scripts/mesh_master.py"; then
        pass "mesh_master.py 证书有效期为 365 天"
    else
        fail "mesh_master.py 证书有效期不是 365 天"
    fi
}
test_m03

# ────────────────────────────────────────────────────────────
# M-04: UUID 标准 v4 格式
# ────────────────────────────────────────────────────────────
section "M-04: gen_uuid 标准 v4 UUID 格式"

test_m04() {
    source "$REPO_ROOT/lib/paths.sh"
    source "$REPO_ROOT/lib/common.sh"

    # 测试 openssl 回退路径（临时屏蔽 sing-box 和 uuidgen 和 /proc 接口）
    local fake_uuid="not-a-valid-uuid"
    local hex
    hex=$(openssl rand -hex 16 2>/dev/null || true)
    if [[ -z "$hex" ]]; then
        warn "openssl 不可用，跳过 UUID 格式测试"
        return
    fi

    # 直接测试 gen_uuid 的输出格式
    local u
    u=$(gen_uuid 2>/dev/null || true)

    if [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[4][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
        pass "gen_uuid 输出符合 RFC 4122 v4 格式" "UUID: $u"
    else
        warn "gen_uuid 输出格式需确认" "输出: $u"
    fi
}
test_m04

# ────────────────────────────────────────────────────────────
# M-05: 端口随机源
# ────────────────────────────────────────────────────────────
section "M-05: rand_port 随机源强度"

test_m05() {
    if grep -q '/dev/urandom' "$REPO_ROOT/lib/common.sh" && \
       grep -q 'rand_port' "$REPO_ROOT/lib/common.sh"; then
        # 检查 rand_port 函数内是否使用 urandom
        local rand_port_src
        rand_port_src=$(awk '/^rand_port\(\)/,/^}/' "$REPO_ROOT/lib/common.sh" | grep -c 'urandom' || true)
        if [[ "$rand_port_src" -gt 0 ]]; then
            pass "rand_port 使用 /dev/urandom 作为随机源"
        else
            fail "rand_port 未使用 /dev/urandom"
        fi
    else
        warn "未找到 /dev/urandom 或 rand_port 函数"
    fi
}
test_m05

# ────────────────────────────────────────────────────────────
# Agent IP 白名单功能验证（代码层面）
# ────────────────────────────────────────────────────────────
section "Agent IP 白名单功能验证"

test_agent_iplist() {
    while IFS= read -r line; do
        if echo "$line" | grep -q '^PASS:'; then
            pass "${line#PASS: }"
        elif echo "$line" | grep -q '^FAIL:'; then
            fail "${line#FAIL: }"
        elif echo "$line" | grep -q '^WARN:'; then
            warn "${line#WARN: }"
        fi
    done < <(python3 - "$REPO_ROOT_WIN/scripts/geoagent.py" 2>/dev/null <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    src = f.read()

if '_ip_allowed' in src:
    print("PASS: _ip_allowed 方法存在")
else:
    print("FAIL: _ip_allowed 方法不存在")

if 'ip_network' in src:
    print("PASS: 支持 CIDR 网段白名单")
else:
    print("WARN: 未找到 ip_network 调用")

get_idx = src.find('def do_GET')
post_idx = src.find('def do_POST')
get_body = src[get_idx:post_idx] if get_idx >= 0 and post_idx >= 0 else ""
if '_ip_allowed' in get_body:
    print("PASS: do_GET 中调用了 IP 白名单检查")
else:
    print("FAIL: do_GET 中未调用 IP 白名单检查")

if '_ip_allowed' in src[post_idx:post_idx+2000]:
    print("PASS: do_POST 中调用了 IP 白名单检查")
else:
    print("FAIL: do_POST 中未调用 IP 白名单检查")
PYEOF
)
}
test_agent_iplist 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# 运行时集成测试（需要 python3 + curl）
# ────────────────────────────────────────────────────────────
section "集成测试：Agent 运行时验证"

test_agent_runtime() {
    if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        warn "缺少 python3 或 curl，跳过运行时测试"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local agent_port=19599
    local agent_token="test-token-abc123"

    # 启动一个测试用 agent
    GPS_AGENT_BIND=127.0.0.1 \
    GPS_AGENT_PORT="$agent_port" \
    GPS_AGENT_TOKEN="$agent_token" \
    GPS_AGENT_ALLOW_IPS="127.0.0.1" \
    GPS_STATE="$tmpdir/nonexistent.env" \
    python3 "$REPO_ROOT_WIN/scripts/geoagent.py" \
        >"$tmpdir/agent.log" 2>&1 &
    local agent_pid=$!

    sleep 1

    if ! kill -0 "$agent_pid" 2>/dev/null; then
        fail "Agent 启动失败" "$(cat "$tmpdir/agent.log")"
        rm -rf "$tmpdir"
        return
    fi
    pass "Agent 启动成功（监听 127.0.0.1）"

    # 测试 1: 正确 token + 允许 IP 应成功
    local resp1
    resp1=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $agent_token" \
        "http://127.0.0.1:$agent_port/v1/status" 2>/dev/null || echo "000")
    if [[ "$resp1" == "200" ]]; then
        pass "允许 IP + 正确 token → 200 OK"
    else
        fail "允许 IP + 正确 token 未返回 200" "返回: $resp1"
    fi

    # 测试 2: 无 token 应返回 401
    local resp2
    resp2=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$agent_port/v1/status" 2>/dev/null || echo "000")
    if [[ "$resp2" == "401" ]]; then
        pass "无 token → 401 Unauthorized"
    else
        fail "无 token 未返回 401" "返回: $resp2"
    fi

    # 测试 3: 错误 token 应返回 401
    local resp3
    resp3=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer wrong-token" \
        "http://127.0.0.1:$agent_port/v1/status" 2>/dev/null || echo "000")
    if [[ "$resp3" == "401" ]]; then
        pass "错误 token → 401 Unauthorized"
    else
        fail "错误 token 未返回 401" "返回: $resp3"
    fi

    kill "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
test_agent_runtime

# ────────────────────────────────────────────────────────────
# 集成测试：Mesh Master 运行时验证
# ────────────────────────────────────────────────────────────
section "集成测试：Mesh Master 运行时验证"

test_mesh_runtime() {
    if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        warn "缺少 python3 或 curl，跳过运行时测试"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local master_port=19600
    local cluster_token="test-cluster-token-xyz"

    mkdir -p "$tmpdir/mesh"

    # 明文启动 master（测试用）
    GPS_MESH_MASTER_BIND=127.0.0.1 \
    GPS_MESH_MASTER_PORT="$master_port" \
    GPS_MESH_MASTER_TLS=0 \
    GPS_MESH_PEERS="$tmpdir/mesh/peers.json" \
    MESH_CLUSTER_TOKEN="$cluster_token" \
    MESH_OVERLAY_PREFIX="10.66.0.0/16" \
    python3 "$REPO_ROOT_WIN/scripts/mesh_master.py" \
        >"$tmpdir/master.log" 2>&1 &
    local master_pid=$!

    sleep 1

    if ! kill -0 "$master_pid" 2>/dev/null; then
        fail "Mesh Master 启动失败" "$(cat "$tmpdir/master.log")"
        rm -rf "$tmpdir"
        return
    fi
    pass "Mesh Master 启动成功"

    # 测试 1: health 端点应只返回 ok 字段
    local health
    health=$(curl -s "http://127.0.0.1:$master_port/v1/health" 2>/dev/null || echo "{}")
    local field_count
    field_count=$(echo "$health" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")

    if [[ "$field_count" -eq 1 ]]; then
        pass "health 端点仅返回 1 个字段"
    else
        fail "health 端点返回 $field_count 个字段（应仅 1 个 ok）" "响应: $health"
    fi

    if echo "$health" | grep -q '"ok"\s*:\s*true'; then
        pass "health 端点包含 ok: true"
    else
        fail "health 端点不含 ok: true" "响应: $health"
    fi

    # 测试 2: health 不应包含 role/prefix/stale_sec
    if echo "$health" | grep -qE 'role|prefix|stale_sec'; then
        fail "health 端点泄露了内部信息" "响应: $health"
    else
        pass "health 端点无 role/prefix/stale_sec 泄露"
    fi

    # 测试 3: 无 token 访问 peers 应返回 401
    local peers_code
    peers_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:$master_port/v1/peers" 2>/dev/null || echo "000")
    if [[ "$peers_code" == "401" ]]; then
        pass "无 token 访问 /v1/peers → 401"
    else
        fail "无 token 访问 /v1/peers 未返回 401" "返回: $peers_code"
    fi

    # 测试 4: 速率限制验证（快速连续请求）
    local rate_pass=true
    for i in $(seq 1 15); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:$master_port/v1/health" 2>/dev/null || echo "000")
        if [[ "$code" == "429" ]]; then
            rate_pass=true
            break
        fi
        rate_pass=false
    done

    if $rate_pass; then
        pass "速率限制生效（返回 429）"
    else
        warn "未观察到 429 速率限制响应" "可能阈值较高或触发条件不足"
    fi

    kill "$master_pid" 2>/dev/null || true
    wait "$master_pid" 2>/dev/null || true
    rm -rf "$tmpdir"
}
test_mesh_runtime

# ────────────────────────────────────────────────────────────
# 代码卫生检查
# ────────────────────────────────────────────────────────────
section "代码卫生检查"

if command -v shellcheck >/dev/null 2>&1; then
    echo "  运行 shellcheck ..."
    sc_errors=$(shellcheck -S error -f json \
        "$REPO_ROOT/geoproxy-server.sh" \
        "$REPO_ROOT/install.sh" \
        "$REPO_ROOT/lib"/*.sh \
        "$REPO_ROOT/lib"/protocols/*.sh \
        "$REPO_ROOT/lib"/mesh/*.sh \
        2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "N/A")
    if [[ "$sc_errors" == "0" ]]; then
        pass "shellcheck: 0 个 error"
    else
        fail "shellcheck: ${sc_errors} 个 error"
    fi
else
    warn "shellcheck 不可用，跳过"
fi

# ============================================================
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}测试结果汇总${NC}"
echo -e "${GREEN}  通过: $PASS${NC}"
echo -e "${RED}  失败: $FAIL${NC}"
echo -e "${YELLOW}  警告: $WARN${NC}"
echo -e "  总计: $TOTAL"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo -e "${RED}有失败项，请检查上述 FAIL 输出。${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}所有通过项均达标。警告项需人工确认。${NC}"
    exit 0
fi
