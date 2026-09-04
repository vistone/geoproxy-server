#!/usr/bin/env bats
# v0.2.68：WireGuard 仅做节点互联 —— mesh-exit / mesh-failover 已移除，不得再影响代理出口

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

@test "change mesh-exit reports feature removed" {
	mesh_init
	run gps_cmd_change mesh-exit tile-b
	[ "$status" -ne 0 ]
	[[ "$output" == *"功能已移除"* ]]
}

@test "change mesh-failover reports feature removed" {
	mesh_init
	run gps_cmd_change mesh-failover on
	[ "$status" -ne 0 ]
	[[ "$output" == *"功能已移除"* ]]
}

@test "change mesh-failover-probe reports feature removed" {
	mesh_init
	run gps_cmd_change mesh-failover-probe https://www.google.com/generate_204
	[ "$status" -ne 0 ]
	[[ "$output" == *"功能已移除"* ]]
}

@test "legacy exit/failover state never renders urltest or default route" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820 --exit
	# 模拟旧版升级残留的状态
	MESH_EXIT_NODE_ID=tile-b
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.gstatic.com/generate_204"
	gps_write_config
	! grep -q 'mesh-failover' "$GPS_CONFIG"
	! grep -q 'urltest' "$GPS_CONFIG"
	! grep -q '0\.0\.0\.0/0' "$GPS_CONFIG"
	! grep -q '"::/0"' "$GPS_CONFIG"
	grep -q '"final": "direct"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "legacy exit state no longer persisted by save_state" {
	mesh_init
	MESH_EXIT_NODE_ID=tile-b
	MESH_FAILOVER=1
	save_state
	! grep -q '^MESH_EXIT_NODE_ID=' "$GPS_STATE"
	! grep -q '^MESH_FAILOVER=' "$GPS_STATE"
}

@test "ensure boot clears legacy exit config with warning" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_EXIT_NODE_ID=tile-b
	MESH_FAILOVER=1
	save_state
	local out
	out=$(GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot 2>&1) || true
	[[ "$out" == *"已忽略 mesh-exit/mesh-failover"* ]]
	# ensure_boot 在子 shell 中清空并 save_state：残留键不再写入 state.env
	! grep -q '^MESH_EXIT_NODE_ID=' "$GPS_STATE"
	! grep -q '^MESH_FAILOVER=' "$GPS_STATE"
	! grep -q '0\.0\.0\.0/0' "$GPS_CONFIG"
	grep -q '"final": "direct"' "$GPS_CONFIG"
}

@test "wg peers only carry overlay /32 allowed_ips" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820 --exit
	gps_write_config
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
wg = [e for e in cfg["endpoints"] if e["type"] == "wireguard"][0]
assert wg["peers"], "peer missing"
for p in wg["peers"]:
    assert p["allowed_ips"] == ["10.66.0.2/32"], p["allowed_ips"]
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}
