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

@test "failover on renders urltest group, final and anti-loop order" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_write_config
	grep -q '"tag": "mesh-failover"' "$GPS_CONFIG"
	grep -q '"type": "urltest"' "$GPS_CONFIG"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
	local src_line ip_line
	src_line=$(grep -n 'source_ip_cidr' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	ip_line=$(grep -n '"ip_cidr"' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	[ "$src_line" -lt "$ip_line" ]
	# 结构化断言 urltest 组内层字段：outbounds 标签顺序、url=probe、interval、tolerance、
	# interrupt_exist_connections、防环规则置顶
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
groups = [o for o in cfg["outbounds"] if o.get("tag") == "mesh-failover"]
assert len(groups) == 1, f"expected exactly one mesh-failover outbound, got {len(groups)}"
g = groups[0]
assert g["type"] == "urltest", g["type"]
assert g["outbounds"] == ["direct", "wg-ep"], g["outbounds"]
assert g["url"] == "https://www.gstatic.com/generate_204", g["url"]
assert g["interval"] == "30s", g["interval"]
assert g["tolerance"] == 100, g["tolerance"]
assert g["interrupt_exist_connections"] is False, g["interrupt_exist_connections"]
assert cfg["route"]["final"] == "mesh-failover", cfg["route"]["final"]
rules = cfg["route"]["rules"]
assert rules and "source_ip_cidr" in rules[0], "anti-loop rule must be first"
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "failover on without peers still renders stable urltest final" {
	mesh_init
	MESH_FAILOVER=1
	gps_write_config
	# final 恒定指向探测组：不随 peer 存亡翻转（无 peer 时 wg-ep 探测必失败，urltest 选 direct）
	grep -q '"tag": "mesh-failover"' "$GPS_CONFIG"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
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

@test "failover and mesh-exit can coexist (urltest over direct vs exit tunnel)" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_cmd_change mesh-failover on
	MESH_EXIT_NODE_ID=tile-b gps_write_config
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
# urltest 组与 final
g = [o for o in cfg["outbounds"] if o.get("tag") == "mesh-failover"]
assert len(g) == 1, "failover group missing"
assert cfg["route"]["final"] == "mesh-failover", cfg["route"]["final"]
# exit peer 仍持有默认路由
wg = [e for e in cfg["endpoints"] if e["type"] == "wireguard"][0]
exits = [p for p in wg["peers"] if "0.0.0.0/0" in p.get("allowed_ips", [])]
assert len(exits) == 1, f"exit peer default-route missing: {len(exits)}"
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "change mesh-exit allowed while failover on" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	save_state
	run gps_cmd_change mesh-exit tile-b
	[ "$status" -eq 0 ]
	grep -Eq '^MESH_EXIT_NODE_ID="?tile-b"?$' "$GPS_STATE"
	grep -q '0.0.0.0/0' "$GPS_CONFIG"
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

@test "mesh show displays failover state" {
	mesh_init
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.google.com/generate_204"
	save_state
	run gps_mesh_cmd_show
	[ "$status" -eq 0 ]
	[[ "$output" == *"failover:"* ]]
	[[ "$output" == *"mesh-failover"* ]]
	[[ "$output" == *"https://www.google.com/generate_204"* ]]
}
