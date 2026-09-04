#!/usr/bin/env bats
# 路由目的地收敛到 peer /32、exit 健康门禁（握手证据 → 暂停 → 冷却复通）、空端点守卫、MTU

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
}

route_init() {
	export PORT=${PORT:-43901}
	export UUID="00000000-0000-4000-8000-000000000301"
	export PASSWORD="route-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.5"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1 >/dev/null
}

@test "route destination rules narrow to peer /32 not the whole overlay prefix" {
	route_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_mesh_peer_add tile-c --pubkey "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" --overlay-ip 10.66.0.7 --endpoint 203.0.113.13:51820
	gps_write_config
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
dest = [r for r in cfg["route"]["rules"] if "ip_cidr" in r]
assert dest, "destination rule missing"
cidrs = set(dest[0]["ip_cidr"])
assert cidrs == {"10.66.0.2/32", "10.66.0.7/32"}, cidrs
assert "10.66.0.0/16" not in cidrs, "must not hijack the whole overlay prefix"
src = [r for r in cfg["route"]["rules"] if "source_ip_cidr" in r]
assert src and src[0]["source_ip_cidr"] == ["10.66.0.0/16"], src
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "route omits wg-ep rule when no other peers exist" {
	route_init
	gps_write_config
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
dest = [r for r in cfg["route"]["rules"] if "ip_cidr" in r]
assert not dest, f"unexpected destination rule: {dest}"
assert cfg["route"]["final"] == "direct", cfg["route"]["final"]
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "tripped peer excluded from route rules and wg peers" {
	route_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	python3 - "$GPS_MESH_PEERS" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for n in doc["nodes"]:
    if n.get("node_id") == "tile-b":
        n["tripped"] = 1
json.dump(doc, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
	gps_write_config
	! grep -q '10\.66\.0\.2/32' "$GPS_CONFIG"
}

@test "exit peer without endpoint gets no default route" {
	route_init
	gps_mesh_peer_add tile-exit --pubkey "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=" --overlay-ip 10.66.0.10
	python3 - "$GPS_MESH_PEERS" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for n in doc["nodes"]:
    if n.get("node_id") == "tile-exit":
        n["roles"] = ["edge", "exit"]
json.dump(doc, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
	MESH_EXIT_NODE_ID=tile-exit
	gps_write_config 2>/dev/null
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
wg = [e for e in cfg["endpoints"] if e["type"] == "wireguard"][0]
exits = [p for p in wg["peers"] if "0.0.0.0/0" in p.get("allowed_ips", [])]
assert not exits, "empty-endpoint exit must not carry 0.0.0.0/0"
peer = [p for p in wg["peers"] if p["public_key"].startswith("EEEE")]
assert peer and peer[0]["allowed_ips"] == ["10.66.0.10/32"], peer
PY
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "change mesh-mtu validates range and renders" {
	route_init
	run gps_cmd_change mesh-mtu 1380
	[ "$status" -eq 0 ]
	grep -Eq '^MESH_WG_MTU="?1380"?$' "$GPS_STATE"
	grep -q '"mtu": 1380' "$GPS_CONFIG"
	run gps_cmd_change mesh-mtu 100
	[ "$status" -ne 0 ]
	run gps_cmd_change mesh-mtu abc
	[ "$status" -ne 0 ]
}

@test "exit health gate suspends on handshake failures and recovers after cooldown" {
	route_init
	gps_mesh_peer_add tile-exit --pubkey "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=" --overlay-ip 10.66.0.9 --endpoint 203.0.113.99:51820 --exit
	MESH_EXIT_NODE_ID=tile-exit
	gps_write_config 2>/dev/null
	grep -q '0\.0\.0\.0/0' "$GPS_CONFIG"
	# 伪造 sing-box 日志：exit 公钥前缀 DDDD 握手失败（parser 按公钥前 4 字符匹配）
	{
		for i in 1 2 3 4 5; do
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DEBUG wireguard: peer(DDDD) handshake did not complete after 5 seconds"
		done
	} >>"$GPS_LOG"
	# 3 个周期累计失败 → SUSPENDED=1
	gps_mesh_exit_health_gate 2>/dev/null
	gps_mesh_exit_health_gate 2>/dev/null
	run gps_mesh_exit_health_gate
	[ "$status" -eq 0 ]
	grep -q '^SUSPENDED=1$' "$GPS_MESH_EXIT_HEALTH"
	# 暂停后渲染不再下发默认路由
	gps_write_config 2>/dev/null
	! grep -q '0\.0\.0\.0/0' "$GPS_CONFIG"
	# 冷却到期（回拨 SUSPENDED_AT）→ 复通观察窗，默认路由恢复
	local old
	old=$(($(date +%s) - 700))
	sed -i "s/^SUSPENDED_AT=.*/SUSPENDED_AT=${old}/" "$GPS_MESH_EXIT_HEALTH"
	gps_mesh_exit_health_gate 2>/dev/null
	grep -q '^SUSPENDED=0$' "$GPS_MESH_EXIT_HEALTH"
	grep -q '^STRIKE=1$' "$GPS_MESH_EXIT_HEALTH"
	gps_write_config 2>/dev/null
	grep -q '0\.0\.0\.0/0' "$GPS_CONFIG"
	# 复通后再次出现失败证据 → 立即重新暂停（阈值 1）
	gps_mesh_exit_health_gate 2>/dev/null
	grep -q '^SUSPENDED=1$' "$GPS_MESH_EXIT_HEALTH"
}
