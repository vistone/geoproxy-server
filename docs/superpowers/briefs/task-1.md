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

