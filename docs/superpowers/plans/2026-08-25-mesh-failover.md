# mesh-failover（本机直连优先 + 故障自动切换对端出口）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 WireGuard mesh 组网之上，为每台机器增加"本机直连优先、本机出口故障时自动切到对端出口兜底、恢复后自动回切"的能力，且平时零隧道流量开销。

**Architecture:** 在 sing-box 配置渲染层（`lib/mesh/wireguard.sh`）把出口从写死的 `direct` 改为"sing-box 原生 `loadbalance`（strategy: url-test）探测组 { direct, wg-ep }"，探测地址默认 gstatic `generate_204`；新增 `source_ip_cidr: [10.66.0.0/16] → direct` 防环规则（来自隧道的数据强制走本机直连，杜绝 A↔B 循环）。通过 `change mesh-failover on|off` 开关，状态持久化到 `state.env`。

**Tech Stack:** Bash, Bats, sing-box, WireGuard, python3（心跳判定）, ShellCheck, shfmt。

## Global Constraints

- 版本：`v0.2.40` → `v0.2.41`（只 patch+1，遵守 `AGENTS.md`）。
- `MESH_FAILOVER` 默认 `0`（必须显式 `change mesh-failover on` 开启）。
- 探测地址默认 `https://www.gstatic.com/generate_204`（`MESH_FAILOVER_PROBE`）。
- 与 `mesh-exit` 互斥（双向校验：开启 failover 时拒绝设置 mesh-exit，设置 mesh-exit 时拒绝开启 failover）。
- 防环规则 `source_ip_cidr: [<MESH_OVERLAY_PREFIX>] → direct` **始终渲染**并置于 rules 最前。
- 无在线 peer 时：loadbalance 组内只有 `direct`（等价于现状），`final` 保持 `direct`。
- 全量门禁：`bats --tap tests` 全绿、shellcheck 无 error、shfmt 无漂移、`bash -n`、`git diff --check`。
- 密钥/凭证不得写进进程 argv（本功能不新增凭证，遵守既有约定）。
- 每次提交前运行相关 bats；最终门禁前跑全量。

---

### Task 1: 状态变量、默认值与在线对端判定

**Files:**
- Modify: `lib/mesh/_common.sh:230-240`（`gps_mesh_defaults` 加默认值）
- Modify: `lib/common.sh:469-473`（`gps_save_state_unlocked` 加持久化）
- Modify: `lib/mesh/wireguard.sh`（新增 `gps_mesh_has_live_peer`）
- Create: `tests/test_mesh_failover.bats`

**Interfaces:**
- Produces:
  - 变量 `MESH_FAILOVER`（0/1，默认 0）、`MESH_FAILOVER_PROBE`（默认 `https://www.gstatic.com/generate_204`），由 `gps_mesh_defaults()` 兜底、`save_state` 持久化到 `state.env`。
  - `gps_mesh_has_live_peer()`：无参数；`MESH_PEER_STALE_SEC`（默认 180）与 `GPS_MESH_PEERS` 由既有全局提供。返回 0=存在非本机且心跳在线（或无心跳字段的）peer，1=否则。

- [ ] **Step 1: 写失败测试** `tests/test_mesh_failover.bats`

```bash
#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
}

# 公共初始化：master 角色 + 假公网 IP + v4only 栈
mesh_init() {
	export PORT=${PORT:-43011}
	export UUID="00000000-0000-4000-8000-000000000201"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.10"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1 --wg-port 51820
}

@test "failover defaults are off with standard probe" {
	gps_mesh_defaults
	[ "$MESH_FAILOVER" = "0" ]
	[ "$MESH_FAILOVER_PROBE" = "https://www.gstatic.com/generate_204" ]
}

@test "has_live_peer is false without peers" {
	mesh_init
	run gps_mesh_has_live_peer
	[ "$status" -ne 0 ]
}

@test "has_live_peer is true with an online peer" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	run gps_mesh_has_live_peer
	[ "$status" -eq 0 ]
}

@test "state persists failover variables" {
	mesh_init
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.google.com/generate_204"
	save_state
	load_state
	[ "$MESH_FAILOVER" = "1" ]
	[ "$MESH_FAILOVER_PROBE" = "https://www.google.com/generate_204" ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: FAIL——`MESH_FAILOVER` 为空/`0` 不成立（`gps_mesh_defaults` 未设置默认值）、`gps_mesh_has_live_peer: command not found`。

- [ ] **Step 3: 实现默认值与持久化**

`lib/mesh/_common.sh` 的 `gps_mesh_defaults()` 末尾追加：

```bash
	MESH_FAILOVER=${MESH_FAILOVER:-0}
	MESH_FAILOVER_PROBE=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}
```

`lib/common.sh` 的 `gps_save_state_unlocked()` 中 `MESH_L7_OUTBOUNDS_JSON` 行之后追加：

```bash
		gps_env_assign MESH_FAILOVER "${MESH_FAILOVER:-0}"
		gps_env_assign MESH_FAILOVER_PROBE "${MESH_FAILOVER_PROBE:-}"
```

- [ ] **Step 4: 实现 `gps_mesh_has_live_peer`**

`lib/mesh/wireguard.sh` 末尾追加（放在 `gps_mesh_endpoints_json` 之前或文件尾部均可）：

```bash
# 是否存在非本机且心跳在线的 peer（与 peers 渲染的 alive 判定一致；无心跳字段视为可用）
gps_mesh_has_live_peer() {
	local self=${NODE_ID:-}
	[[ -f ${GPS_MESH_PEERS:-} ]] || return 1
	MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" python3 - "$GPS_MESH_PEERS" "$self" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, self_id = sys.argv[1], sys.argv[2]
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
try:
    doc = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(1)
now = datetime.now(timezone.utc)
for n in doc.get("nodes") or []:
    if (n.get("node_id") or "") == self_id:
        continue
    ls = n.get("last_seen") or ""
    if not ls:
        sys.exit(0)
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    if (now - ts).total_seconds() <= stale:
        sys.exit(0)
sys.exit(1)
PY
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 4 个用例全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add lib/mesh/_common.sh lib/common.sh lib/mesh/wireguard.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh-failover 状态变量与在线对端判定（MESH_FAILOVER / gps_mesh_has_live_peer）"
```

---

### Task 2: sing-box 配置渲染（loadbalance 组 + 防环规则）

**Files:**
- Modify: `lib/mesh/wireguard.sh:146-186`（`gps_mesh_route_json` 与 `gps_mesh_outbounds_json`）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `MESH_FAILOVER` / `MESH_FAILOVER_PROBE` / `gps_mesh_has_live_peer`。
- Produces: 渲染行为——
  - `MESH_FAILOVER=1` 且有在线 peer：outbounds 含 `{"type":"loadbalance","tag":"mesh-failover","strategy":"url-test",...}`（destinations = direct + wg-ep）；`route.final` = `mesh-failover`。
  - 否则：与现状一致（final = `direct`，无 loadbalance 组）。
  - `route.rules` 恒为：`[{source_ip_cidr: [prefix] → direct}, {ip_cidr: [prefix] → wg-ep}]`（source 规则在前）。

- [ ] **Step 1: 追加失败测试**（追加到 `tests/test_mesh_failover.bats`）

```bash
@test "failover off renders legacy outbounds and route with anti-loop rule" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_write_config
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	grep -q '"final": "direct"' "$GPS_CONFIG"
	grep -q 'source_ip_cidr' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "failover on renders loadbalance group, final and anti-loop order" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_write_config
	grep -q '"tag": "mesh-failover"' "$GPS_CONFIG"
	grep -q '"strategy": "url-test"' "$GPS_CONFIG"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
	local src_line ip_line
	src_line=$(grep -n 'source_ip_cidr' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	ip_line=$(grep -n '"ip_cidr"' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	[ "$src_line" -lt "$ip_line" ]
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "failover on without peers keeps direct-only final" {
	mesh_init
	MESH_FAILOVER=1
	gps_write_config
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	grep -q '"final": "direct"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增 3 个用例 FAIL（配置中无 loadbalance 组、无 source_ip_cidr、final 仍 direct）。

- [ ] **Step 3: 实现渲染**

替换 `lib/mesh/wireguard.sh` 中 `gps_mesh_outbounds_json` 与 `gps_mesh_route_json` 整个函数体：

```bash
gps_mesh_route_json() {
	gps_profile_normalize
	gps_mesh_defaults
	local prefix final_tag
	prefix=$(gps_json_escape "${MESH_OVERLAY_PREFIX}")
	final_tag=direct
	# mesh-failover：有在线对端时才把 final 指到探测组
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		final_tag=mesh-failover
	fi
	cat <<EOF
  "route": {
    "rules": [
      {
        "source_ip_cidr": ["${prefix}"],
        "outbound": "direct"
      },
      {
        "ip_cidr": ["${prefix}"],
        "outbound": "wg-ep"
      }
    ],
    "final": "${final_tag}"
  }
EOF
}

gps_mesh_outbounds_json() {
	# 始终至少有 direct；L7 hop 占位（MESH_L7_DETOUR_JSON 高级用户/后续）
	local extra=${MESH_L7_OUTBOUNDS_JSON:-}
	# mesh-failover：direct 之后插入 loadbalance 探测组（本机直连 ↔ WG 隧道）
	local failover=""
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		local probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}
		failover=$(cat <<EOF
,
    {
      "type": "loadbalance",
      "tag": "mesh-failover",
      "strategy": "url-test",
      "destinations": [
        { "outbound": "direct" },
        { "outbound": "wg-ep" }
      ],
      "url": "${probe}",
      "interval": "30s",
      "tolerance": 0
    }
EOF
)
	fi
	if [[ -n ${extra//[[:space:]]/} ]]; then
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover},
${extra}
EOF
	else
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover}
EOF
	fi
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 7 个用例全部 PASS。

- [ ] **Step 5: 回归既有 mesh 测试**

Run: `bats --tap tests/test_mesh.bats tests/test_mesh_tls.bats`
Expected: 全部 PASS（渲染变化不应破坏现有用例；若有断言 `"final": "direct"` 或规则结构的用例失败，检查是否与新增 source 规则顺序相关并修正渲染而非削弱断言）。

- [ ] **Step 6: 提交**

```bash
git add lib/mesh/wireguard.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh-failover sing-box 渲染（loadbalance 探测组 + source 防环规则）"
```

---

### Task 3: CLI（`change mesh-failover` / `mesh-failover-probe` / mesh-exit 互斥）

**Files:**
- Modify: `lib/cmd.sh:521-536`（`mesh-exit` 分支加互斥）、`lib/cmd.sh`（新增两个 case 分支，置于 `mesh-exit` 之后）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1/2 的渲染与判定。
- Produces:
  - `gps_cmd_change mesh-failover on|off`：校验值合法；on 时校验 `MESH_EXIT_NODE_ID` 为空（冲突则 `err`）；设置 `MESH_FAILOVER`；`gps_write_config; save_state; gps_restart_svc`；输出 `mesh-failover → 1/0`。
  - `gps_cmd_change mesh-failover-probe <url>`：校验单行、`http(s)://` 开头；设置 `MESH_FAILOVER_PROBE`；同上保存。
  - `change mesh-exit <id>` 在 `MESH_FAILOVER=1` 且设置非 none 时 `err` 冲突。

- [ ] **Step 1: 追加失败测试**

```bash
@test "change mesh-failover on persists state and renders" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_cmd_change mesh-failover on
	grep -q '^MESH_FAILOVER="1"' "$GPS_STATE"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
}

@test "change mesh-failover off restores legacy rendering" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_cmd_change mesh-failover off
	grep -q '^MESH_FAILOVER="0"' "$GPS_STATE"
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
}

@test "change mesh-failover on conflicts with mesh-exit" {
	mesh_init
	MESH_EXIT_NODE_ID=tile-exit
	run gps_cmd_change mesh-failover on
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-exit conflicts with failover on" {
	mesh_init
	MESH_FAILOVER=1
	run gps_cmd_change mesh-exit tile-b
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-failover-probe validates url and persists" {
	mesh_init
	gps_cmd_change mesh-failover-probe https://www.google.com/generate_204
	grep -q '^MESH_FAILOVER_PROBE="https://www.google.com/generate_204"' "$GPS_STATE"
	run gps_cmd_change mesh-failover-probe ftp://bad
	[ "$status" -ne 0 ]
	run gps_cmd_change mesh-failover-probe "https://ok
evil"
	[ "$status" -ne 0 ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增 5 个用例 FAIL（`change` 未知参数报错）。

- [ ] **Step 3: 实现 CLI**

`lib/cmd.sh` 的 `mesh-exit` 分支内、`[[ $eid != "${NODE_ID:-}" ]] || err ...` 之后插入互斥校验：

```bash
			[[ ${MESH_FAILOVER:-0} != 1 ]] || err "与 mesh-failover 冲突：请先 change mesh-failover off 再设置 mesh-exit"
```

`mesh-exit` 分支之后新增两个 case 分支：

```bash
	mesh-failover | failover)
		local v=${1:-}
		[[ $v == on || $v == off || $v == 1 || $v == 0 ]] || err "用法: change mesh-failover on|off"
		if [[ $v == on || $v == 1 ]]; then
			[[ -z ${MESH_EXIT_NODE_ID:-} ]] || err "与 mesh-exit 冲突：请先 change mesh-exit none 再开启 mesh-failover"
			MESH_FAILOVER=1
			if ! gps_mesh_has_live_peer 2>/dev/null; then
				warn "当前无在线对端节点，failover 开启后暂无可兜底出口（新增节点后自动生效）"
			fi
		else
			MESH_FAILOVER=0
		fi
		gps_write_config
		save_state
		gps_restart_svc
		msg "$(_green "mesh-failover") → ${MESH_FAILOVER}"
		return 0
		;;
	mesh-failover-probe | failover-probe)
		local u=${1:-}
		[[ -n $u ]] || err "用法: change mesh-failover-probe <url>"
		gps_validate_single_line "$u" || err "探测地址不能包含换行/回车/NUL"
		[[ $u == http://* || $u == https://* ]] || err "探测地址需以 http:// 或 https:// 开头"
		MESH_FAILOVER_PROBE=$u
		gps_write_config
		save_state
		gps_restart_svc
		msg "$(_green "failover 探测地址") → ${MESH_FAILOVER_PROBE}"
		return 0
		;;
```

同时在 `change` 的兜底用法行（`*) err "用法: change port|uuid|...`）中追加 `mesh-failover|mesh-failover-probe`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 12 个用例全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/cmd.sh tests/test_mesh_failover.bats
git commit -m "feat: change mesh-failover / mesh-failover-probe CLI 与 mesh-exit 互斥"
```

---

### Task 4: `mesh show` 与 `doctor` 展示 failover 状态

**Files:**
- Modify: `lib/mesh/cli.sh:180`（`gps_mesh_cmd_show` 输出加一行）
- Modify: `lib/doctor.sh:137-152`（mesh master 检查块加一行）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `MESH_FAILOVER` / `MESH_FAILOVER_PROBE`。
- Produces: `mesh show` 输出含 `failover:  0/1  probe=<url>`；`doctor` 输出含 `mesh-failover: on/off`。

- [ ] **Step 1: 追加失败测试**

```bash
@test "mesh show displays failover state" {
	mesh_init
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.google.com/generate_204"
	run gps_mesh_cmd_show
	[ "$status" -eq 0 ]
	[[ "$output" == *"failover:"* ]]
	[[ "$output" == *"mesh-failover"* ]]
	[[ "$output" == *"https://www.google.com/generate_204"* ]]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增用例 FAIL（输出无 failover 行）。

- [ ] **Step 3: 实现展示**

`lib/mesh/cli.sh` 中 `msg "  mesh-exit:   ${MESH_EXIT_NODE_ID:-none}"` 之后追加：

```bash
	msg "  failover:    ${MESH_FAILOVER:-0}  probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}"
```

`lib/doctor.sh` 的 mesh 检查块中 `gps_mesh_print_control_plane_status 2>/dev/null || true` 之前追加：

```bash
		msg "  $(_green OK)  mesh-failover=${MESH_FAILOVER:-0}（本机直连优先，故障自动切对端）"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 13 个用例全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/mesh/cli.sh lib/doctor.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh show / doctor 展示 mesh-failover 状态"
```

---

### Task 5: 版本、文档与全量门禁（发布 v0.2.41）

**Files:**
- Modify: `VERSION`（`v0.2.40` → `v0.2.41`）
- Modify: `CHANGELOG.md`（顶部追加 `## v0.2.41 - 2026-08-25`）
- Modify: `README.md`（mesh 能力 + `change mesh-failover` 用法；版本号引用不写死，按现有惯例）

**Interfaces:** 无新接口，纯发布收尾。

- [ ] **Step 1: 更新版本文件**

`VERSION` 内容改为 `v0.2.41`。

- [ ] **Step 2: 更新 CHANGELOG**

`CHANGELOG.md` 顶部插入（按既有条目风格）：

```markdown
## v0.2.41 - 2026-08-25

- 新增 mesh 出口自动故障切换（`change mesh-failover on|off`）：本机直连优先，本机出口故障时自动切到对端出口兜底，恢复后自动回切；平时零隧道流量开销。
- 防环：来自 WG 隧道（overlay 网段）的流量强制走本机直连，杜绝 A↔B 兜底/探活循环。
- 探测地址可配（`change mesh-failover-probe <url>`，默认 `https://www.gstatic.com/generate_204`）；与 `mesh-exit` 互斥。
- `mesh show` / `doctor` 展示 failover 状态。
```

- [ ] **Step 3: 更新 README**

在 README mesh 相关章节补充 `change mesh-failover on|off` 与 `change mesh-failover-probe <url>` 用法（保留"每台机器只跑一个 sing-box 实例"的产品模型，说明出口在开启后为"本机直连优先 + 对端兜底"）。

- [ ] **Step 4: 全量门禁**

Run:
```bash
bash -n geoproxy-server.sh lib/*.sh lib/*/*.sh scripts/*.py 2>/dev/null || bash -n geoproxy-server.sh lib/*.sh lib/mesh/*.sh lib/protocols/*.sh
bats --tap tests
shellcheck geoproxy-server.sh lib/*.sh lib/mesh/*.sh lib/protocols/*.sh
shfmt -d geoproxy-server.sh lib tests scripts
git diff --check
```
Expected: 全部通过（bats 全绿；shellcheck 无 error；shfmt 无 diff 输出；`git diff --check` 无 whitespace 错误）。若有 shfmt/shellcheck 报错，就地修正并重跑。

- [ ] **Step 5: 提交并推送，打 tag**

```bash
git add -A
git commit -m "release: v0.2.41 mesh-failover（本机直连优先 + 故障自动切换对端出口）"
git push origin main
git tag v0.2.41
git push origin v0.2.41
```
Expected: push 成功；GitHub Actions `release.yml` 自动校验 `VERSION == tag` 并创建 Release（含 `geoproxy-server-v0.2.41.tar.gz` 与 `.sha256`）。

---

## Self-Review

**Spec 覆盖核对：**
- 行为（本机直连优先/故障切换/回切/单机降级）→ Task 2 渲染 + url-test 语义 ✅
- 配置接口（`change mesh-failover on|off`、`mesh-failover-probe`、`mesh show`、`doctor`）→ Task 3 + Task 4 ✅
- 默认关闭、与 mesh-exit 互斥 → Task 1 默认值 + Task 3 双向校验 ✅
- 防环 `source_ip_cidr` 置顶 → Task 2 ✅（且恒渲染，比 spec 更稳）
- 无在线 peer 降级 → Task 2 测试 ✅
- 探测地址校验 → Task 3 ✅
- 测试（6 组 spec 用例 → 计划拆为 13 个 bats 用例）✅
- 版本 v0.2.41 / CHANGELOG / README / 门禁 / 推送 tag → Task 5 ✅
- YAGNI 排除项（活跃均衡/配额驱动/按目标分流/clash_api）→ 计划未引入 ✅

**占位符扫描：** 无 TBD/TODO；所有代码步骤含完整实现。✅

**类型/命名一致性：** `MESH_FAILOVER`、`MESH_FAILOVER_PROBE`、`gps_mesh_has_live_peer`、`mesh-failover`（tag 与命令）在各任务间一致。✅

**风险说明（执行时注意）：**
- Task 2 Step 5 若 `test_mesh.bats` 中既有断言与新增 source 规则顺序冲突，优先调整渲染顺序保证防环语义，再确认既有断言仍成立。
- Task 3 的 `change mesh-failover on` 会执行 `gps_restart_svc`（测试中已 mock 为空）。
