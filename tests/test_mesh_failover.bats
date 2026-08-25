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

@test "has_live_peer honors fresh and stale last_seen" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	# 直接改写 peers 文件里该 peer 的 last_seen：先写当前 UTC 时间（fresh → 在线）
	python3 - "$GPS_MESH_PEERS" <<'PY'
import json, sys, datetime
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
for n in doc["nodes"]:
    if n.get("node_id") == "tile-b":
        n["last_seen"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
	run gps_mesh_has_live_peer
	[ "$status" -eq 0 ]
	# 再写 200 秒前（超过 MESH_PEER_STALE_SEC=180 过期窗口 → 无在线 peer）
	python3 - "$GPS_MESH_PEERS" <<'PY'
import json, sys, datetime
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
for n in doc["nodes"]:
    if n.get("node_id") == "tile-b":
        n["last_seen"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=200)).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
	run gps_mesh_has_live_peer
	[ "$status" -ne 0 ]
}

@test "state persists failover variables" {
	mesh_init
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.google.com/generate_204"
	save_state
	# state.env 是 shell 赋值格式（%q 序列化，值无特殊字符时不带引号）；grep -E 宽松匹配两种形式
	grep -Eq '^MESH_FAILOVER="?1"?$' "$GPS_STATE"
	grep -Eq '^MESH_FAILOVER_PROBE="?https://www.google.com/generate_204"?$' "$GPS_STATE"
	# 回载语义：unset 后 load_state 应还原两个变量（不依赖 shell 残留）
	unset MESH_FAILOVER MESH_FAILOVER_PROBE
	load_state
	[ "$MESH_FAILOVER" = "1" ]
	[ "$MESH_FAILOVER_PROBE" = "https://www.google.com/generate_204" ]
}

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

@test "change mesh-failover on persists state and renders" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_cmd_change mesh-failover on
	grep -Eq '^MESH_FAILOVER="?1"?$' "$GPS_STATE"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
}

@test "change mesh-failover off restores legacy rendering" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_cmd_change mesh-failover off
	grep -Eq '^MESH_FAILOVER="?0"?$' "$GPS_STATE"
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
}

@test "change mesh-failover on conflicts with mesh-exit" {
	mesh_init
	MESH_EXIT_NODE_ID=tile-exit
	save_state
	run gps_cmd_change mesh-failover on
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-exit conflicts with failover on" {
	mesh_init
	MESH_FAILOVER=1
	save_state
	run gps_cmd_change mesh-exit tile-b
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-failover-probe validates url and persists" {
	mesh_init
	gps_cmd_change mesh-failover-probe https://www.google.com/generate_204
	grep -Eq '^MESH_FAILOVER_PROBE="?https://www.google.com/generate_204"?$' "$GPS_STATE"
	run gps_cmd_change mesh-failover-probe ftp://bad
	[ "$status" -ne 0 ]
	run gps_cmd_change mesh-failover-probe "https://ok
evil"
	[ "$status" -ne 0 ]
}
