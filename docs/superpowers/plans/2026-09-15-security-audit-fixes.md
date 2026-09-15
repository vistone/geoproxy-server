# 安全漏洞修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复安全审计中发现的全部漏洞，按 P0 → P1 → P2 → P3 优先级顺序实施。

**Architecture:** 每个漏洞作为独立任务，先写失败测试，再修复实现，最后全量测试验证。修改遵循项目既有模式（Bash 函数 + Python 服务 + BATS 测试）。

**Tech Stack:** Bash 4+ / Python 3 / BATS / systemd / WireGuard

## Global Constraints

- 版本号规则：严格 patch+1，修改代码但不发布版本，VERSION 保持不变
- 代码质量门槛：`bats --tap tests` 全通过、shellcheck 无 error、shfmt 无漂移
- 新增/修改行为必须同步补充 `tests/*.bats` 用例
- 密钥/凭证相关：禁止占位密钥回退、禁止把凭证写进进程 argv
- 所有状态文件权限 600，敏感目录 700
- Bash 函数使用 `gps_` 前缀（公共）/ `_gps_` 前缀（私有）

---

## 任务清单（按优先级）

| 优先级 | 任务 | 漏洞编号 | 估计工作量 |
|--------|------|----------|------------|
| P0 | Mesh 明文 HTTP 校验绕过 | H-01 | 小 |
| P0 | state.env allexport 密钥泄露 | H-04 | 中 |
| P1 | Agent 默认绑定 0.0.0.0 | C-01 | 小 |
| P1 | Overlay IP 耗尽攻击 | H-02 | 中 |
| P1 | API 速率限制缺失 | M-06 | 中 |
| P2 | tag archive 回退校验不足 | H-03 | 小 |
| P2 | health 端点信息泄露 | H-05 | 小 |
| P2 | JSON 转义不完整 | M-02 | 小 |
| P3 | 其余 Medium/Low 问题 | M-01~07, L-01~06 | 按需 |

---

### Task 1: 修复 H-01 — Mesh 明文 HTTP 校验绕过

**Files:**
- Modify: `lib/mesh/_common.sh` (gps_mesh_url_is_loopback 函数)
- Test: `tests/test_mesh_tls.bats`

**Interfaces:**
- Consumes: `gps_validate_ipv4` (from lib/common.sh)
- Produces: 严格的回环地址检测，防止 `127.x.y.z.attacker.com` 绕过

**Problem:** 当前实现用 bash glob `127.*` 匹配 host，任何以 `127.` 开头的字符串都会被当作回环地址，包括 `127.0.0.1.attacker.com`。

**Fix:** 用严格的 IP 校验替代 glob 匹配。先尝试解析为 IPv4，校验通过后再检查是否在 127.0.0.0/8。

- [ ] **Step 1: 写失败测试**

在 `tests/test_mesh_tls.bats` 中追加：

```bash
@test "mesh loopback detection rejects 127.0.0.1.attacker.com" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "127.0.0.1.attacker.com"
    [ "$status" -ne 0 ]
}

@test "mesh loopback detection accepts 127.0.0.1" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "127.0.0.1"
    [ "$status" -eq 0 ]
}

@test "mesh loopback detection accepts 127.1.2.3" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "127.1.2.3"
    [ "$status" -eq 0 ]
}

@test "mesh loopback detection accepts ::1" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "::1"
    [ "$status" -eq 0 ]
}

@test "mesh loopback detection accepts [::1]" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "[::1]"
    [ "$status" -eq 0 ]
}

@test "mesh loopback detection rejects 8.8.8.8" {
    source lib/mesh/_common.sh
    run gps_mesh_url_is_loopback "8.8.8.8"
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: 运行测试确认失败**

运行：`bats tests/test_mesh_tls.bats --filter "loopback detection rejects 127.0.0.1.attacker.com"`
预期：FAIL（glob 匹配导致返回 0）

- [ ] **Step 3: 实现修复**

将 `gps_mesh_url_is_loopback` 替换为：

```bash
gps_mesh_url_is_loopback() {
    local low=${1,,}
    [[ $low == \[::1\] ]] && return 0
    if gps_validate_ipv4 "$low" 2>/dev/null; then
        [[ $low == 127.* ]] && return 0
    fi
    [[ $low == localhost || $low == localhost.* || $low == ::1 ]]
}
```

- [ ] **Step 4: 运行测试确认通过**

运行：`bats tests/test_mesh_tls.bats`
预期：全部 PASS

- [ ] **Step 5: 运行 shellcheck**

运行：`shellcheck lib/mesh/_common.sh`
预期：无 error

---

### Task 2: 修复 H-04 — state.env allexport 密钥泄露

**Files:**
- Modify: `lib/common.sh` (gps_source_env 函数)
- Test: `tests/test_state.bats`

**Problem:** `gps_source_env` 使用 `set -a` + `source`，导致所有 state 变量（含密钥）都被 export 到子进程环境。

**Fix:** 去掉 `set -a`，改为纯 source（不 export）。检查所有调用子进程的地方，确认是否有依赖环境变量传递的，如有则改为显式传参。

- [ ] **Step 1: 审计所有依赖环境变量的子进程调用**

全文搜索以下模式，确认哪些子进程依赖 state 变量：
- `python3` 调用（mesh_master.py, geoagent.py）
- `sing-box` 调用
- `curl` 调用
- `openssl` 调用

方法：`grep -n "python3\|sing-box\|curl\|openssl" lib/*.sh lib/**/*.sh`

重点关注：
- `scripts/mesh_master.py`：从环境读取 state？
- `scripts/geoagent.py`：从环境读取 state？
- `gps_mesh_curl`：TOKEN 通过 header 文件传递（不依赖 env）✓
- `gps_download_core` / `gps_self_fetch_tree`：curl 直接用参数 ✓

结论：需要检查 Python 脚本的环境变量依赖。

- [ ] **Step 2: 检查 Python 脚本环境变量依赖**

读取 `scripts/mesh_master.py` 和 `scripts/geoagent.py`，搜索 `os.environ` / `os.getenv`，列出所有依赖的环境变量。

对于 mesh_master.py，预期依赖：
- `STATE_FILE` / `PEERS_FILE` / `MESH_DIR` 等路径
- `MESH_CLUSTER_TOKEN` / `MESH_GITHUB_WEBHOOK_SECRET` 等密钥
- `MESH_OVERLAY_PREFIX` / `MESH_STALE_SEC` 等配置

对于 geoagent.py，预期依赖：
- `STATE_FILE` / `CONFIG_FILE` 等路径
- `AGENT_TOKEN`
- 代理端口等

这些变量当前通过 EnvironmentFile（systemd）传递，不是通过 shell export。需要确认。

**关键发现：** systemd 的 EnvironmentFile 本身就会把变量设为进程环境变量。所以即使去掉 bash 的 `set -a`，Python 服务通过 systemd 启动时仍然能读到这些变量（通过 EnvironmentFile）。

只有在 bash 脚本中直接调用 Python（如 `gps_cmd_agent_on` 中直接启动 agent 用于测试）时，才需要显式传递环境变量。

- [ ] **Step 3: 写失败测试**

在 `tests/test_state.bats` 中追加：

```bash
@test "gps_source_env does not export variables" {
    GPS_TEST_PREFIX="$BATS_TEST_TMPDIR"
    gps_apply_paths
    mkdir -p "$GPS_ETC"
    echo 'SECRET_KEY=supersecret' > "$GPS_STATE"
    chmod 600 "$GPS_STATE"

    gps_source_env "$GPS_STATE"

    # 变量在当前 shell 中应该可用
    [ "$SECRET_KEY" = "supersecret" ]

    # 但不应出现在子进程环境中
    local child_output
    child_output=$(env | grep -c '^SECRET_KEY=' || true)
    [ "$child_output" -eq 0 ]
}
```

- [ ] **Step 4: 运行测试确认失败**

运行：`bats tests/test_state.bats --filter "does not export variables"`
预期：FAIL（allexport 导致子进程能看到 SECRET_KEY）

- [ ] **Step 5: 实现修复**

修改 `gps_source_env`，去掉 `set -a` / `set +a`：

```bash
gps_source_env() {
    local f=${1:-$GPS_STATE}
    [[ -f $f ]] || return 0
    local owner perms
    owner=$(stat -c '%u' "$f" 2>/dev/null) || err "无法 stat 状态文件"
    perms=$(stat -c '%a' "$f" 2>/dev/null) || err "无法 stat 状态文件"
    [[ -L $f ]] && err "拒绝加载符号链接状态文件: $f"
    [[ ${#perms} -eq 3 && ${perms:1:1} -le 0 && ${perms:2:1} -le 0 ]] || err "状态文件权限过宽 ($perms)，拒绝加载: $f"
    [[ $owner -eq 0 || $owner -eq $(id -u) ]] || err "状态文件异属主 (uid=$owner)，拒绝加载: $f"
    source "$f"
    return 0
}
```

- [ ] **Step 6: 检查并修复所有依赖环境变量的 bash→子进程调用**

逐个检查：

1. **`scripts/mesh_master.py` 启动方式**：
   - systemd：通过 EnvironmentFile 传递 ✓ 无需修改
   - 测试模式：直接 `python3` 调用 → 需要在调用处显式传递关键变量

2. **`scripts/geoagent.py` 启动方式**：
   - systemd：通过 EnvironmentFile 传递 ✓ 无需修改
   - 测试模式：同上

3. **`sing-box` 调用**：
   - sing-box 从配置文件读取，不依赖环境变量 ✓

4. **`curl` 调用**：
   - TOKEN 通过 `@header_file` 传递 ✓
   - 其他参数都在命令行 ✓

5. **`openssl` 调用**：
   - 不依赖 state 环境变量 ✓

需要修改的地方：
- `gps_cmd_agent_on` / `gps_start_agent_foreground` 等直接启动 Python 的地方
- `gps_mesh_master_start` 等直接启动 mesh_master 的地方

修改方式：在 python3 命令前加上必要的环境变量赋值（仅传递需要的，不一股脑全传）。

- [ ] **Step 7: 运行全部测试确认通过**

运行：`bats tests/test_state.bats tests/test_mesh_tls.bats tests/test_agent.bats tests/test_mesh.bats`
预期：全部 PASS

- [ ] **Step 8: 运行 shellcheck**

运行：`shellcheck lib/common.sh`
预期：无 error

---

### Task 3: 修复 C-01 — Agent 默认绑定 0.0.0.0

**Files:**
- Modify: `lib/paths.sh` (GPS_AGENT_BIND 默认值)
- Modify: `scripts/geoagent.py` (添加源 IP 白名单)
- Modify: `lib/agent.sh` (agent enable/start 逻辑)
- Test: `tests/test_agent.bats`

**Problem:** Agent 默认绑定 `0.0.0.0:19528`，公网暴露，攻击面大。

**Fix:** 
1. 默认绑定改为 `127.0.0.1`
2. 增加源 IP 白名单配置
3. 在 doctor 中增加 agent 安全检查

- [ ] **Step 1: 写失败测试**

在 `tests/test_agent.bats` 中追加：

```bash
@test "agent default bind is 127.0.0.1" {
    GPS_TEST_PREFIX="$BATS_TEST_TMPDIR"
    gps_apply_paths
    load_state
    [ "$AGENT_BIND" = "127.0.0.1" ]
}

@test "agent rejects request from non-whitelisted IP" {
    # 启动 agent，绑定 127.0.0.1 + 白名单
    # 从非白名单 IP 访问应被拒绝
    # （这个测试可能需要 mock，或者改为单元测试 IP 检查函数）
}
```

- [ ] **Step 2: 修改默认绑定地址**

在 `lib/paths.sh` 或 `lib/agent.sh` 的默认值设置中：

将 `AGENT_BIND` 默认值从 `0.0.0.0` 改为 `127.0.0.1`

- [ ] **Step 3: 在 geoagent.py 中实现源 IP 白名单**

在 `GeoAgentHandler` 的 `_check_auth` 或新的 `_check_source_ip` 方法中：

```python
def _check_source_ip(self):
    allow_raw = os.environ.get("AGENT_ALLOW_IPS", "127.0.0.1,::1")
    allowed = [ip.strip() for ip in allow_raw.split(",") if ip.strip()]
    if not allowed:
        return True
    client_ip = self.client_address[0]
    # 处理 IPv4-mapped IPv6
    if client_ip.startswith("::ffff:"):
        client_ip = client_ip[7:]
    return client_ip in allowed
```

在 `do_GET` / `do_POST` 的认证检查之前增加源 IP 检查。

- [ ] **Step 4: 修改 agent enable 命令支持自定义绑定**

`change agent-bind` 命令已存在，确保其正常工作。

- [ ] **Step 5: 运行测试确认通过**

运行：`bats tests/test_agent.bats`
预期：全部 PASS

---

### Task 4: 修复 H-02 — Overlay IP 耗尽攻击

**Files:**
- Modify: `scripts/mesh_master.py` (alloc_overlay + 速率限制 + stale 清理)
- Test: `tests/test_mesh.bats`

**Problem:** 
1. 注册无速率限制，可注册 253 个不同 node_id 耗尽 /24 IP 池
2. 没有 stale 节点自动清理

**Fix:**
1. 扩大默认地址池到 /20（4093 个可用 IP）
2. 增加节点注册速率限制（同 IP 每分钟最多 5 次）
3. 增加 stale 节点自动清理（过期节点从 peers 中移除，释放 IP）

- [ ] **Step 1: 写失败测试**

在 `tests/test_mesh.bats` 中追加：

```bash
@test "mesh master rejects rapid registrations from same IP" {
    # 启动 mesh master
    # 连续注册 10 次，从第 6 次开始应返回 429
}

@test "mesh master reclaims IP from stale node" {
    # 注册一个节点，标记为 stale
    # 新节点注册应能复用该 IP
}
```

- [ ] **Step 2: 实现速率限制**

在 mesh_master.py 中增加 `RateLimiter` 类：

```python
class RateLimiter:
    def __init__(self, max_requests=5, window_sec=60):
        self.max_requests = max_requests
        self.window_sec = window_sec
        self.hits = {}  # ip -> [timestamps]

    def check(self, ip):
        now = time.time()
        if ip not in self.hits:
            self.hits[ip] = []
        self.hits[ip] = [t for t in self.hits[ip] if now - t < self.window_sec]
        if len(self.hits[ip]) >= self.max_requests:
            return False
        self.hits[ip].append(now)
        return True
```

在 `do_POST` / `do_GET` 中调用，超限返回 429。

- [ ] **Step 3: 实现 stale 节点清理**

在 `_load_peers` 或每次 register 时清理 stale 节点：

```python
def _cleanup_stale(self):
    now = datetime.utcnow()
    if not self.peers.get("nodes"):
        return
    active = []
    for node in self.peers["nodes"]:
        last_seen = node.get("last_seen", "")
        try:
            dt = datetime.fromisoformat(last_seen.replace("Z", "+00:00")).replace(tzinfo=None)
            if (now - dt).total_seconds() < self.stale_sec:
                active.append(node)
        except (ValueError, TypeError):
            active.append(node)  # 解析失败的保留
    if len(active) != len(self.peers["nodes"]):
        self.peers["nodes"] = active
        self._save_peers()
```

- [ ] **Step 4: 扩大默认地址池**

将 `MESH_OVERLAY_PREFIX` 默认值从 `10.66.0.0/16` 保持不变，但 `alloc_overlay` 的分配范围从 `/24` 扩大到 `/20`（可用 4093 个）。

或者直接用完整 /16（65534 个可用 IP）。

- [ ] **Step 5: 运行测试确认通过**

运行：`bats tests/test_mesh.bats`
预期：全部 PASS

---

### Task 5: 修复 M-06 — API 速率限制缺失

**Files:**
- Modify: `scripts/mesh_master.py`（已在 Task 4 中部分覆盖）
- Modify: `scripts/geoagent.py`
- Test: `tests/test_agent.bats` + `tests/test_mesh.bats`

**Problem:** 两个 Python 服务都无限速，可暴力破解 token 或耗尽线程。

**Fix:**
1. mesh_master.py：Task 4 已实现注册接口限速，补充其他接口限速
2. geoagent.py：增加全局速率限制 + 认证失败限速

- [ ] **Step 1: 在 geoagent.py 中实现速率限制**

复制 `RateLimiter` 类（或抽取公共模块，但两个脚本独立运行，直接复制更简单）。

对所有请求做全局限速（如 60 req/min/IP）。
对认证失败做更严格的限速（如 5 次失败后封禁 10 分钟）。

- [ ] **Step 2: 在 mesh_master.py 中补充所有接口限速**

除了 register，heartbeat / peers / webhook 也应有限速。
webhook 因为有 HMAC 签名且来自 GitHub，可以放宽或单独配置。

- [ ] **Step 3: 写测试并验证**

补充测试用例。

---

### Task 6: 修复 H-03 — tag archive 回退校验不足

**Files:**
- Modify: `lib/download.sh` (gps_self_fetch_tree + install.sh 中对应逻辑)
- Test: `tests/test_download.bats`

**Problem:** 升级回退到 tag archive 时，仅校验 VERSION 文件内容与目标 tag 是否一致，不做密码学校验。

**Fix:**
1. 移除 tag archive 回退路径，强制使用 release asset
2. 或者：使用 GPG 签名校验（如果项目有签名密钥）
3. install.sh 中同样处理

**推荐方案**：移除回退路径，因为：
- 所有版本都应该有 release asset（CI 自动生成）
- 回退路径降低了安全性

但需要考虑：旧版本可能没有 release asset。可以限定只有某个版本之后的版本才走 asset 路径。

- [ ] **Step 1: 写失败测试**

在 `tests/test_download.bats` 中追加：

```bash
@test "upgrade self rejects tag archive without sha256" {
    # mock release asset 不存在
    # 应报错退出，而不是回退到 tag archive
}
```

- [ ] **Step 2: 移除 tag archive 回退**

在 `gps_self_fetch_tree` 中：
- 删除 `turl=...` 的构造
- 删除 `curl ... "$turl"` 回退路径
- release asset 下载失败直接报错

在 `install.sh` 中同样处理。

- [ ] **Step 3: 移除 GPS_INSTALL_ALLOW_UNVERIFIED**

删除 `GPS_INSTALL_ALLOW_UNVERIFIED=1` 跳过校验的能力。

- [ ] **Step 4: 运行测试确认通过**

运行：`bats tests/test_download.bats`
预期：全部 PASS

---

### Task 7: 修复 H-05 — health 端点信息泄露

**Files:**
- Modify: `scripts/mesh_master.py` (do_GET /v1/health)
- Test: `tests/test_mesh.bats`

**Problem:** `/v1/health` 无需认证，返回 role、prefix、stale_sec 等内部信息，可被用于指纹识别。

**Fix:**
1. health 端点只返回 `{"ok": true}`
2. 详细健康信息移到需要认证的端点（如 `/v1/status`）

- [ ] **Step 1: 写失败测试**

```bash
@test "mesh master /v1/health returns minimal info" {
    # 请求 /v1/health
    # 返回 JSON 中只有 ok 字段，没有 role/prefix/stale_sec
}
```

- [ ] **Step 2: 修改 health 端点**

将 `/v1/health` 的响应改为仅 `{"ok": true}`。

- [ ] **Step 3: 运行测试确认通过**

运行：`bats tests/test_mesh.bats --filter "health"`
预期：PASS

---

### Task 8: 修复 M-02 — JSON 转义不完整

**Files:**
- Modify: `lib/common.sh` (gps_json_escape)
- Test: `tests/test_state.bats` 或 `tests/test_config.bats`

**Problem:** `gps_json_escape` 只转义 7 个字符，不转义其他控制字符（U+0000 ~ U+001F）。

**Fix:** 使用 python3 做 JSON 序列化（项目已经依赖 python3）。

- [ ] **Step 1: 写失败测试**

```bash
@test "gps_json_escape escapes all control characters" {
    local input=$'\x00\x01\x02\x1f'
    local result
    result=$(gps_json_escape "$input")
    # 每个控制字符都应被转义为 \u00XX
    [[ $result == \\u0000* ]]
}
```

- [ ] **Step 2: 实现修复**

```bash
gps_json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]), end="")' "$1"
}
```

- [ ] **Step 3: 运行测试确认通过**

运行：`bats tests/test_state.bats --filter "json_escape"`
预期：PASS

**注意**：性能考虑。如果在循环中大量调用，每次 fork python3 可能较慢。但实际使用中 json_escape 主要用于配置生成，调用次数有限。

---

### Task 9: 修复 P3 级别问题（批量）

**Files:** 多个
- M-01: `lib/common.sh` (is_ipv4 → 统一用 gps_validate_ipv4)
- M-03: `lib/tls.sh` + `lib/mesh/_common.sh` + `scripts/mesh_master.py` (证书有效期)
- M-04: `lib/common.sh` (gen_uuid 回退路径)
- M-05: `lib/common.sh` (rand_port 随机源)
- M-07: `README.md` (install.sh 供应链风险 - 提供校验方式)
- L-01: `lib/common.sh` (自旋锁死锁检测)
- L-02: logrotate 配置
- L-05: `lib/traffic.sh` (grep 回退解析 - 可接受，标记已知风险)
- L-06: TUIC UUID=密码 - 文档说明即可

按需要挑选修复，优先修复代码改动小、收益高的。

- [ ] **Step 1: 修复 M-05 — rand_port 使用 /dev/urandom**

```bash
rand_port() {
    local p
    for _ in $(seq 1 40); do
        p=$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))
        if ! ss -lun | awk '{print $5}' | grep -qE ":${p}\$"; then
            echo "$p"
            return 0
        fi
    done
    echo $((30000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 10000))
}
```

- [ ] **Step 2: 修复 M-04 — gen_uuid v4 格式**

```bash
# 回退路径生成标准 v4 UUID
openssl rand -hex 16 | sed 's/\(........\)\(....\)4\([0-9a-f]\{3\}\)[89ab]\(....\)\(............\)/\1-\2-4\3-\4-\5/'
```

- [ ] **Step 3: 修复 M-03 — 证书有效期缩短为 1 年**

将 3650 改为 365。

- [ ] **Step 4: 修复 L-02 — logrotate 明确文件权限**

确保 logrotate 配置中有 `create 600 root root`。

- [ ] **Step 5: 运行全量测试**

运行：`bats --tap tests`
预期：全部 PASS

---

### Task 10: 全量测试与 shellcheck

- [ ] **Step 1: 运行全量 BATS 测试**

运行：`bats --tap tests`
预期：全部通过

- [ ] **Step 2: 运行 shellcheck**

运行：`shellcheck -S error geoproxy-server.sh install.sh lib/*.sh lib/protocols/*.sh lib/mesh/*.sh`
预期：无 error

- [ ] **Step 3: 运行 shfmt 检查格式**

运行：`shfmt -d -i=4 -ci -sr -bn -kp geoproxy-server.sh install.sh lib/`
预期：无漂移

---

## 修复后验证清单

- [ ] 所有新增测试通过
- [ ] 全量 bats 测试通过
- [ ] shellcheck 无 error
- [ ] shfmt 无漂移
- [ ] 手动 smoke test（安装 → 启动 → mesh join → upgrade）
- [ ] 更新 SECURITY_AUDIT.md 标记已修复项
