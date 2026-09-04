#!/usr/bin/env bats
# 路由目的地收敛到 peer /32、熔断排除、MTU；v0.2.68 起 WG 不承载代理流量（出口恒 direct）

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

@test "no peer ever receives default-route allowed_ips even as exit role" {
	route_init
	gps_mesh_peer_add tile-exit --pubkey "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=" --overlay-ip 10.66.0.10 --endpoint 203.0.113.99:51820 --exit
	MESH_EXIT_NODE_ID=tile-exit
	gps_write_config 2>/dev/null
	python3 - "$GPS_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
wg = [e for e in cfg["endpoints"] if e["type"] == "wireguard"][0]
for p in wg["peers"]:
    assert "0.0.0.0/0" not in p.get("allowed_ips", []), p
    assert "::/0" not in p.get("allowed_ips", []), p
peer = [p for p in wg["peers"] if p["public_key"].startswith("EEEE")]
assert peer and peer[0]["allowed_ips"] == ["10.66.0.10/32"], peer
assert cfg["route"]["final"] == "direct", cfg["route"]["final"]
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
