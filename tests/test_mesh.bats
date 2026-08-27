#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
	# source _setup 之后重定义：按 GPS_MESH_PEERS 识别本前缀 master（cwd 常为仓库根）
	teardown() {
		local pid
		for pid in $(pgrep -f 'scripts/mesh_master.py' 2>/dev/null || true); do
			if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -q "GPS_MESH_PEERS=${GPS_TEST_PREFIX}"; then
				kill -KILL "$pid" >/dev/null 2>&1 || true
			fi
		done
		rm -rf "$GPS_TEST_PREFIX"
	}
}

@test "default ensure boot always has wireguard endpoints" {
	export PORT=43001
	export UUID="00000000-0000-4000-8000-000000000100"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.10"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	grep -q '"type": "wireguard"' "$GPS_CONFIG"
	grep -q '"tag": "wg-ep"' "$GPS_CONFIG"
	grep -q '"route"' "$GPS_CONFIG"
	grep -q '10.66.0.0/16' "$GPS_CONFIG"
	[ -f "$GPS_MESH_PEERS" ]
	[ -n "$MESH_CLUSTER_TOKEN" ]
	[ "$MESH_OVERLAY_IP" = "10.66.0.1" ]
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "mesh init creates wg endpoint and peers file" {
	export PORT=43002
	export UUID="00000000-0000-4000-8000-000000000101"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.10"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_write_config
	save_state
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1 --wg-port 51820
	[ "$MESH_ROLE" = "master" ]
	[ -f "$GPS_MESH_PEERS" ]
	grep -q '"type": "wireguard"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "peer add and export/import roundtrip" {
	export PORT=43003
	export UUID="00000000-0000-4000-8000-000000000102"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.11"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	run gps_mesh_export
	[ "$status" -eq 0 ]
	[[ "$output" == *tile-b* ]]
	local dump=$GPS_TEST_PREFIX/peers-out.json
	gps_mesh_export >"$dump"
	gps_mesh_peer_rm tile-b
	run grep tile-b "$GPS_MESH_PEERS"
	[ "$status" -ne 0 ]
	gps_mesh_import "$dump"
	grep -q tile-b "$GPS_MESH_PEERS"
}

@test "mesh-exit adds default route only to that peer" {
	export PORT=43004
	export UUID="00000000-0000-4000-8000-000000000103"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.13"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-exit --pubkey "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=" --overlay-ip 10.66.0.9 --endpoint 203.0.113.99:51820 --exit
	MESH_EXIT_NODE_ID=tile-exit
	gps_write_config
	grep -q '0.0.0.0/0' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "anti-loop rejects self as mesh-exit" {
	export PORT=43006
	export UUID="00000000-0000-4000-8000-000000000105"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-self --overlay-ip 10.66.0.7
	run gps_cmd_change mesh-exit tile-self
	[ "$status" -ne 0 ]
}

@test "master registry register and member pull" {
	export PORT=43007
	export UUID="00000000-0000-4000-8000-000000000106"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.20"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="test-token-aabb"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state

	local master_peers=$GPS_MESH_PEERS
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=test-token-aabb GPS_MESH_PEERS="$master_peers" GPS_MESH_MASTER_TLS=0 \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-test.log" 2>&1 </dev/null 3>&- 4>&- &
	local mpid=$!
	# 不 disown；关闭 bats 管道 FD，避免套件收尾挂起
	# wait until health responds (max ~3s)
	local i
	for i in 1 2 3 4 5 6; do
		curl -fsS --max-time 1 "http://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.5
	done
	curl -fsS --max-time 2 "http://127.0.0.1:${mport}/v1/health" >"$GPS_TEST_PREFIX/health.json"
	grep -q '"ok": true' "$GPS_TEST_PREFIX/health.json"

	# member-like register via API (same as gps_mesh_register_and_pull)
	local resp
	resp=$(mktemp)
	curl -fsS --max-time 5 \
		-H "Authorization: Bearer test-token-aabb" \
		-H "Content-Type: application/json" \
		-d '{"node_id":"tile-member","public_key":"EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=","endpoint":"203.0.113.21:51820","overlay_ip":"10.66.0.5","roles":["edge"]}' \
		"http://127.0.0.1:${mport}/v1/register" -o "$resp"
	grep -q tile-member "$resp"
	grep -q tile-member "$master_peers"
	# member pull
	MESH_ROLE=member MESH_MASTER_URL="http://127.0.0.1:${mport}" MESH_CLUSTER_TOKEN=test-token-aabb \
		NODE_ID=tile-member WG_PUBLIC_KEY="EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=" \
		WG_PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE=" \
		MESH_OVERLAY_IP=10.66.0.5 \
		gps_mesh_register_and_pull
	grep -q tile-member "$GPS_MESH_PEERS"
	# 输入加固：坏 keepalive → 400；出前缀 overlay → 改派（不得回显 8.8.8.8）
	local code oob
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
		-H "Authorization: Bearer test-token-aabb" \
		-d '{"node_id":"tile-bad","public_key":"Pk9=","keepalive":"oops"}' \
		"http://127.0.0.1:${mport}/v1/register")
	[ "$code" = "400" ]
	oob=$(curl -fsS --max-time 3 \
		-H "Authorization: Bearer test-token-aabb" \
		-d '{"node_id":"tile-oob","public_key":"Pk8=","overlay_ip":"8.8.8.8"}' \
		"http://127.0.0.1:${mport}/v1/register")
	[[ "$oob" != *'"overlay_ip": "8.8.8.8"'* ]]
	echo "$oob" | grep -q '"overlay_ip": "10\.66\.0\.'
	rm -f "$resp"

	kill -TERM "$mpid" >/dev/null 2>&1 || true
	sleep 0.2
	kill -KILL "$mpid" >/dev/null 2>&1 || true
}

@test "mesh show auto-ensures keys and join url" {
	export PORT=43009
	export UUID="00000000-0000-4000-8000-000000000108"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.50"
	export PUBLIC_IP6="2001:db8::50"
	export TUIC_NAME="tile3.zeromaps.cn"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=dual
		HAS_V4=1
		HAS_V6=1
	}
	save_state
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/mesh-show.out"
	grep -q 'tile3.zeromaps.cn:19527' "$GPS_TEST_PREFIX/mesh-show.out"
	grep -q '203.0.113.50:19527' "$GPS_TEST_PREFIX/mesh-show.out"
	grep -q '\[2001:db8::50\]:19527' "$GPS_TEST_PREFIX/mesh-show.out"
	grep -q 'WG 内部虚拟网' "$GPS_TEST_PREFIX/mesh-show.out"
	! grep -q 'master URL:  local' "$GPS_TEST_PREFIX/mesh-show.out"
	grep -q 'WG public:' "$GPS_TEST_PREFIX/mesh-show.out"
	! grep -q 'WG public:   （未生成）' "$GPS_TEST_PREFIX/mesh-show.out"
	grep -q 'overlay:     10.66.0' "$GPS_TEST_PREFIX/mesh-show.out"
	[ -f "$GPS_MESH_PEERS" ]
}

@test "change mesh-master-host sets domain join url first" {
	export PORT=43010
	export UUID="00000000-0000-4000-8000-000000000109"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.60"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_cmd_change mesh-master-host mesh.example.com
	grep -q '^MESH_MASTER_HOST=mesh.example.com$' "$GPS_STATE" || grep -q "MESH_MASTER_HOST='mesh.example.com'" "$GPS_STATE"
	primary=$(MESH_MASTER_HOST=mesh.example.com PUBLIC_IP=203.0.113.60 MESH_MASTER_PORT=19527 gps_mesh_primary_join_url)
	[[ "$primary" == "https://mesh.example.com:19527" ]]
}

@test "normalize master url supports domain v4 v6" {
	[[ "$(gps_mesh_normalize_master_url tile3.zeromaps.cn)" == "https://tile3.zeromaps.cn:19527" ]]
	[[ "$(gps_mesh_normalize_master_url 65.49.192.85)" == "https://65.49.192.85:19527" ]]
	[[ "$(gps_mesh_normalize_master_url '2607:8700::2')" == "https://[2607:8700::2]:19527" ]]
	[[ "$(gps_mesh_normalize_master_url 'http://ex.com:19527')" == "http://ex.com:19527" ]]
	[[ "$(gps_mesh_normalize_master_url 'https://ex.com:19527')" == "https://ex.com:19527" ]]
}

@test "paste full join command parses master and token" {
	local line='GPS_MESH_MASTER=http://tile3.zeromaps.cn:19527 GPS_MESH_TOKEN=cf419e550b07e06d963d2b4add62a0ab96e00336a17a721f bash install.sh'
	gps_mesh_parse_join_input "$line"
	[[ "$__MESH_PARSE_URL" == "http://tile3.zeromaps.cn:19527" ]]
	[[ "$__MESH_PARSE_TOKEN" == "cf419e550b07e06d963d2b4add62a0ab96e00336a17a721f" ]]
	[[ "$(gps_mesh_normalize_master_url "$line")" == "http://tile3.zeromaps.cn:19527" ]]
	run gps_mesh_normalize_master_url 'http://[GPS_MESH_MASTER=http://x:19527GPS_MESH_TOKEN=abashinstall.sh]:19527'
	[ "$status" -ne 0 ]
}

@test "mesh role member registers via join url" {
	export PORT=43011
	export UUID="00000000-0000-4000-8000-000000000110"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.70"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="join-token-xyz-0123456789"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local master_peers=$GPS_MESH_PEERS
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=join-token-xyz-0123456789 GPS_MESH_PEERS="$master_peers" GPS_MESH_MASTER_TLS=0 \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/join-test.log" 2>&1 </dev/null 3>&- 4>&- &
	local mpid=$!
	# 不 disown；关闭 bats 管道 FD，避免套件收尾挂起
	local i
	for i in 1 2 3 4 5 6; do
		curl -fsS --max-time 1 "http://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.4
	done
	# 切换为 member（同前缀；换 NODE_ID 以在 Master peers 中出现新节点）
	gps_restart_svc() { :; }
	NODE_ID=tile-node-b
	# become_member 内 load_state 会盖掉 NODE_ID，先写入 state
	save_state
	gps_mesh_become_member "http://127.0.0.1:${mport}" "join-token-xyz-0123456789"
	[ "$MESH_ROLE" = "member" ]
	[[ "$MESH_MASTER_URL" == http://127.0.0.1:${mport} ]]
	# load_state 后 NODE_ID 仍为写入 state 的 tile-node-b
	grep -q tile-node-b "$master_peers"
	kill -TERM "$mpid" >/dev/null 2>&1 || true
	sleep 0.2
	kill -KILL "$mpid" >/dev/null 2>&1 || true
}

@test "register sets last_seen and show lists online nodes" {
	export PORT=43012
	export UUID="00000000-0000-4000-8000-000000000111"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.80"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="hb-token"
	export NODE_ID=tile-master-hb
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	grep -q last_seen "$GPS_MESH_PEERS"
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/hb-show.out"
	grep -q '节点列表' "$GPS_TEST_PREFIX/hb-show.out"
	grep -q '在线' "$GPS_TEST_PREFIX/hb-show.out"
	grep -q tile-master-hb "$GPS_TEST_PREFIX/hb-show.out"
}

@test "tuic unit template includes mesh ensure ExecStartPre" {
	grep -q 'mesh ensure' "$REPO_ROOT/templates/geoproxy-tuic.service"
	grep -q '__BIN__' "$REPO_ROOT/templates/geoproxy-tuic.service"
	# 不得用 '-' 忽略 ensure 失败（启动必须初始化组网）
	! grep -qE 'ExecStartPre=-' "$REPO_ROOT/templates/geoproxy-tuic.service"
}

@test "wg keypair generation fails hard without sing-box core" {
	GPS_CORE_BIN=/nonexistent/sing-box
	run gps_mesh_ensure_wg_keys
	[ "$status" -ne 0 ]
	[[ "$output" == *"生成 WireGuard 密钥失败"* ]]
}

@test "plaintext non-loopback master rejected at request time" {
	export MESH_CLUSTER_TOKEN="test-token-aabb"
	run gps_mesh_curl "http://203.0.113.9:19527/v1/peers"
	[ "$status" -ne 0 ]
	[[ "$output" == *"拒绝明文 http"* ]]
	# loopback 明文放行（curl 因无服务而失败，但不是策略拒绝）
	local out=""
	out=$(MESH_CLUSTER_TOKEN="test-token-aabb" gps_mesh_curl "http://127.0.0.1:1/v1/peers" 2>&1) || true
	[[ "$out" != *"拒绝明文"* ]]
}

@test "become member rejects plaintext public master interactively" {
	export PORT=43013
	export UUID="00000000-0000-4000-8000-000000000112"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	gps_restart_svc() { :; }
	run gps_mesh_become_member "http://203.0.113.9:19527" "token-0123456789abcdef"
	[ "$status" -ne 0 ]
	[[ "$output" == *"拒绝明文"* ]]
}

@test "mesh show member displays remote MESH_MASTER_URL not local hostname" {
	export PORT=43014
	export UUID="00000000-0000-4000-8000-000000000113"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.10"
	export TUIC_NAME="www.member.example"
	export NODE_ID="www"
	export MESH_ROLE=member
	export MESH_MASTER_URL="https://tile3.zeromaps.cn:19527"
	export MESH_CLUSTER_TOKEN="member-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_register_and_pull() { return 1; }
	save_state
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/member-show.out" 2>&1
	grep -q 'master URL:  https://tile3.zeromaps.cn:19527' "$GPS_TEST_PREFIX/member-show.out"
	! grep -q 'master URL:  https://www.member.example' "$GPS_TEST_PREFIX/member-show.out"
	! grep -q '供其它机器加入' "$GPS_TEST_PREFIX/member-show.out"
}

@test "master join hints name tcp 19527 control plane and cloud security group" {
	export PORT=43015
	export UUID="00000000-0000-4000-8000-000000000114"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.55"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="hint-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	run gps_mesh_print_join_hints
	[ "$status" -eq 0 ]
	[[ "$output" == *"TCP 19527"* ]]
	[[ "$output" == *"mesh 控制面"* ]]
	[[ "$output" == *"云安全组"* ]]
	[[ "$output" != *"WG 51820"* ]] || [[ "$output" == *"不是"* ]]
}

@test "master ensure boot records mesh control plane tcp allow" {
	export PORT=43016
	export UUID="00000000-0000-4000-8000-000000000115"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.56"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_FW_LAST_ALLOW=""
	GPS_FW_LAST_ALLOW_UDP=""
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	[ "$GPS_FW_LAST_ALLOW" = "19527/tcp" ]
	[ "$GPS_FW_LAST_ALLOW_UDP" = "51820/udp" ]
}

@test "member ensure boot does not open recruiting port and warns about master 19527" {
	export PORT=43017
	export UUID="00000000-0000-4000-8000-000000000116"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.20"
	export MESH_ROLE=member
	export MESH_MASTER_URL="http://127.0.0.1:1"
	export MESH_CLUSTER_TOKEN="member-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_register_and_pull() { return 1; }
	GPS_FW_LAST_ALLOW=""
	GPS_FW_LAST_ALLOW_UDP=""
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot >"$GPS_TEST_PREFIX/member-boot.out" 2>&1
	[ -z "${GPS_FW_LAST_ALLOW:-}" ]
	[ "$GPS_FW_LAST_ALLOW_UDP" = "51820/udp" ]
	grep -q '无法联系 Master' "$GPS_TEST_PREFIX/member-boot.out"
	grep -q 'TCP 19527' "$GPS_TEST_PREFIX/member-boot.out"
	grep -q '云安全组' "$GPS_TEST_PREFIX/member-boot.out"
	! grep -q '供其它机器加入' "$GPS_TEST_PREFIX/member-boot.out"
}

@test "mesh show master reports listen bind firewall and join url" {
	export PORT=43018
	export UUID="00000000-0000-4000-8000-000000000117"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.57"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	curl() {
		local arg
		for arg in "$@"; do
			case $arg in
			https://*) return 0 ;;
			http://*) return 1 ;;
			esac
		done
		return 1
	}
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/master-show-fw.out" 2>&1
	grep -q '0.0.0.0:19527' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q 'TCP 19527' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q 'mesh 控制面' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q '云安全组' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q '203.0.113.57:19527' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q 'https://127.0.0.1:19527/v1/health' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q 'UDP 51820' "$GPS_TEST_PREFIX/master-show-fw.out"
	grep -q 'WG 数据面' "$GPS_TEST_PREFIX/master-show-fw.out"
}

@test "mesh show member reports wg udp data plane firewall status" {
	export PORT=43019
	export UUID="00000000-0000-4000-8000-000000000118"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.21"
	export MESH_ROLE=member
	export MESH_MASTER_URL="https://203.0.113.57:19527"
	export MESH_CLUSTER_TOKEN="member-wg-token-0123456789"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_register_and_pull() { return 0; }
	save_state
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/member-wg-fw.out" 2>&1
	grep -q 'UDP 51820' "$GPS_TEST_PREFIX/member-wg-fw.out"
	grep -q 'WG 数据面' "$GPS_TEST_PREFIX/member-wg-fw.out"
	grep -q '云安全组' "$GPS_TEST_PREFIX/member-wg-fw.out"
}

_gps_curl_arg_after() {
	local flag=$1 file=$2
	awk -v f="$flag" '$0==f{getline; print; exit}' "$file"
}

@test "gps_mesh_curl default timeout is 15s and honors GPS_MESH_CURL_MAX_TIME" {
	curl() {
		local a
		: >"$GPS_TEST_PREFIX/curl.args"
		for a in "$@"; do
			printf '%s\n' "$a" >>"$GPS_TEST_PREFIX/curl.args"
		done
		return 7
	}
	export MESH_CLUSTER_TOKEN="tok-0123456789abcdef"
	run gps_mesh_curl "http://127.0.0.1:1/v1/peers"
	[ "$(_gps_curl_arg_after --max-time "$GPS_TEST_PREFIX/curl.args")" = "15" ]
	[ "$(_gps_curl_arg_after --connect-timeout "$GPS_TEST_PREFIX/curl.args")" = "15" ]

	GPS_MESH_CURL_MAX_TIME=3 GPS_MESH_CURL_CONNECT_TIMEOUT=2 \
		gps_mesh_curl "http://127.0.0.1:1/v1/peers" || true
	[ "$(_gps_curl_arg_after --max-time "$GPS_TEST_PREFIX/curl.args")" = "3" ]
	[ "$(_gps_curl_arg_after --connect-timeout "$GPS_TEST_PREFIX/curl.args")" = "2" ]
}

@test "member ensure boot probes master with 2-3s curl timeout not 15s" {
	export PORT=43019
	export UUID="00000000-0000-4000-8000-000000000118"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.21"
	export MESH_ROLE=member
	export MESH_MASTER_URL="http://127.0.0.1:1"
	export MESH_CLUSTER_TOKEN="member-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	curl() {
		local a
		: >"$GPS_TEST_PREFIX/curl.args"
		for a in "$@"; do
			printf '%s\n' "$a" >>"$GPS_TEST_PREFIX/curl.args"
		done
		return 7
	}
	unset GPS_MESH_CURL_MAX_TIME GPS_MESH_CURL_CONNECT_TIMEOUT
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot >"$GPS_TEST_PREFIX/member-fast.out" 2>&1
	local max conn
	max=$(_gps_curl_arg_after --max-time "$GPS_TEST_PREFIX/curl.args")
	conn=$(_gps_curl_arg_after --connect-timeout "$GPS_TEST_PREFIX/curl.args")
	[[ "$max" =~ ^[0-9]+$ ]]
	[[ "$conn" =~ ^[0-9]+$ ]]
	((max <= 3))
	((conn <= 3))
	grep -q '无法联系 Master' "$GPS_TEST_PREFIX/member-fast.out"
	grep -q 'TCP 19527' "$GPS_TEST_PREFIX/member-fast.out"
}

@test "member ensure boot does not abort when local peers write fails" {
	# ExecStartPre 走 set -e；fallback 写 peers 失败（ProtectSystem EROFS）不得让 ensure 非 0
	awk '/无法联系 Master/,/^[[:space:]]*fi$/' "$REPO_ROOT/lib/mesh/discovery.sh" |
		grep -qE 'gps_mesh_peers_load_or_init \|\|'
	awk '/无法联系 Master/,/^[[:space:]]*fi$/' "$REPO_ROOT/lib/mesh/discovery.sh" |
		grep -qE 'gps_mesh_peers_upsert_self \|\|'
}

@test "mesh sync-master does not restart proxy when master is unreachable" {
	export PORT=43021
	export UUID="00000000-0000-4000-8000-000000000120"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.23"
	export MESH_ROLE=member
	export MESH_MASTER_URL="http://127.0.0.1:1"
	export MESH_CLUSTER_TOKEN="member-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_register_and_pull() { return 1; }
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot >/dev/null 2>&1
	local restarted=0
	gps_restart_svc() { restarted=1; }
	GPS_MESH_SYNC_RESTART=1 gps_mesh_sync_master >/dev/null 2>&1
	[ "$restarted" -eq 0 ]
}

@test "mesh sync-master restarts when remote peers change the WG config" {
	export PORT=43022
	export UUID="00000000-0000-4000-8000-000000000121"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.58"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot >/dev/null 2>&1
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	local restarted=0
	gps_restart_svc() { restarted=1; }
	GPS_MESH_SYNC_RESTART=1 gps_mesh_sync_master >/dev/null 2>&1
	[ "$restarted" -eq 1 ]
}

@test "mesh sync-master keeps 15s curl timeout for periodic register" {
	export PORT=43023
	export UUID="00000000-0000-4000-8000-000000000122"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.24"
	export MESH_ROLE=member
	export MESH_MASTER_URL="http://127.0.0.1:1"
	export MESH_CLUSTER_TOKEN="member-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	curl() {
		local a
		: >"$GPS_TEST_PREFIX/curl.args"
		for a in "$@"; do
			printf '%s\n' "$a" >>"$GPS_TEST_PREFIX/curl.args"
		done
		return 7
	}
	unset GPS_MESH_CURL_MAX_TIME GPS_MESH_CURL_CONNECT_TIMEOUT
	GPS_MESH_SYNC_RESTART=0 gps_mesh_sync_master >/dev/null 2>&1 || true
	[ "$(_gps_curl_arg_after --max-time "$GPS_TEST_PREFIX/curl.args")" = "15" ]
}

@test "master writes join.cmd 0600 with https PIN and full token" {
	export PORT=43020
	export UUID="00000000-0000-4000-8000-000000000120"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.60"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="ab742daa0123456789abcdef0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	[ -f "$GPS_MESH_JOIN_CMD" ]
	check_perm_600 "$GPS_MESH_JOIN_CMD"
	local body
	body=$(cat "$GPS_MESH_JOIN_CMD")
	[[ "$body" == *https://* ]]
	[[ "$body" == *GPS_MESH_TLS_PIN=sha256//* ]]
	[[ "$body" == *GPS_MESH_TOKEN=ab742daa0123456789abcdef0123456789abcdef* ]]
	[[ "$body" == *bash\ install.sh* ]]
}

@test "master join hints mask token and join-export shows path" {
	export PORT=43021
	export UUID="00000000-0000-4000-8000-000000000121"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.61"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="ab742daa0123456789abcdef0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	run gps_mesh_print_join_hints
	[ "$status" -eq 0 ]
	[[ "$output" == *ab742daa********* ]]
	[[ "$output" != *ab742daa0123456789abcdef0123456789abcdef* ]]
	[[ "$output" == *join.cmd* ]]
	run gps_mesh_join_export
	[ "$status" -eq 0 ]
	[[ "$output" == *"$GPS_MESH_JOIN_CMD"* ]]
	[[ "$output" == *600* ]]
	[[ "$output" == *ab742daa********* ]]
}

@test "mesh port-checklist shows role-specific ports" {
	export PORT=43024
	export UUID="00000000-0000-4000-8000-000000000123"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.62"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="checklist-token-0123456789"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	run gps_mesh_print_port_checklist
	[ "$status" -eq 0 ]
	[[ "$output" == *checklist* ]]
	[[ "$output" == *UDP\ 43024* ]]
	[[ "$output" == *19527* ]]
	[[ "$output" == *51820* ]]
	[[ "$output" == *控制面* ]]
}

@test "member migrate-tls detects http public and fixes from join line" {
	export PORT=43025
	export UUID="00000000-0000-4000-8000-000000000124"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="198.51.100.25"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="migrate-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local mport pin join_line
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=migrate-token-0123456789ab GPS_MESH_PEERS="$GPS_MESH_PEERS" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-migrate.log" 2>&1 </dev/null 3>&- 4>&- &
	local mpid=$!
	local i
	for i in $(seq 1 20); do
		curl -fsS --max-time 1 -k "https://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.2
	done
	pin=$(tr -d '[:space:]' <"$GPS_MESH_TLS_FP")
	join_line="GPS_MESH_MASTER=https://127.0.0.1:${mport} GPS_MESH_TLS_PIN=${pin} GPS_MESH_TOKEN=migrate-token-0123456789ab bash install.sh"

	export MESH_ROLE=member
	export MESH_MASTER_URL="http://198.51.100.1:${mport}"
	export MESH_CLUSTER_TOKEN="old-wrong-token-0123456789"
	export MESH_TLS_PIN=""
	save_state
	run gps_mesh_migrate_tls_detect
	[ "$status" -ne 0 ]
	[[ "$output" == *http_public* ]]

	gps_restart_svc() { :; }
	curl() {
		command curl "$@"
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_migrate_tls "$join_line"
	[[ "$MESH_MASTER_URL" == https://127.0.0.1:${mport} ]]
	[[ "$MESH_TLS_PIN" == "$pin" ]]
	[[ "$MESH_CLUSTER_TOKEN" == migrate-token-0123456789ab ]]

	kill -TERM "$mpid" >/dev/null 2>&1 || true
	kill -KILL "$mpid" >/dev/null 2>&1 || true
}

@test "master token rotate invalidates old token on register API" {
	export PORT=43026
	export UUID="00000000-0000-4000-8000-000000000125"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.63"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="rotate-old-token-0123456789ab"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local mport old_tok
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	old_tok=$MESH_CLUSTER_TOKEN
	MESH_CLUSTER_TOKEN=$old_tok GPS_MESH_PEERS="$GPS_MESH_PEERS" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-rotate.log" 2>&1 </dev/null 3>&- 4>&- &
	local mpid=$!
	local i
	for i in $(seq 1 20); do
		curl -fsS --max-time 1 -k "https://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.2
	done

	GPS_MESH_TOKEN_ROTATE_YES=1 gps_mesh_token_rotate >/dev/null
	local new_tok
	new_tok=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
	[[ "$new_tok" != "$old_tok" ]]
	grep -q "^MESH_CLUSTER_TOKEN=${new_tok}$" "$GPS_MESH_ENV"

	kill -TERM "$mpid" >/dev/null 2>&1 || true
	kill -KILL "$mpid" >/dev/null 2>&1 || true
	MESH_CLUSTER_TOKEN=$new_tok GPS_MESH_PEERS="$GPS_MESH_PEERS" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-rotate2.log" 2>&1 </dev/null 3>&- 4>&- &
	mpid=$!
	for i in $(seq 1 20); do
		curl -fsS --max-time 1 -k "https://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.2
	done

	local code
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 -k \
		-H "Authorization: Bearer ${old_tok}" \
		-H "Content-Type: application/json" \
		-d '{"node_id":"t-old","public_key":"PkOld=","endpoint":""}' \
		"https://127.0.0.1:${mport}/v1/register")
	[ "$code" = "401" ]
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 -k \
		-H "Authorization: Bearer ${new_tok}" \
		-H "Content-Type: application/json" \
		-d '{"node_id":"t-new","public_key":"PkNew=","endpoint":""}' \
		"https://127.0.0.1:${mport}/v1/register")
	[ "$code" = "200" ]
	[ -f "$GPS_MESH_JOIN_CMD" ]
	check_perm_600 "$GPS_MESH_JOIN_CMD"
	grep -q "$new_tok" "$GPS_MESH_JOIN_CMD"

	kill -TERM "$mpid" >/dev/null 2>&1 || true
	kill -KILL "$mpid" >/dev/null 2>&1 || true
}

@test "mesh show includes connectivity summary" {
	export PORT=43020
	export UUID="00000000-0000-4000-8000-000000000119"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.58"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-master --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-b --pubkey "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" \
		--overlay-ip 10.66.0.2 --endpoint 203.0.113.59:51820
	gps_write_config
	save_state
	gps_mesh_probe_udp_endpoint() { [[ ${1:-} == *203.0.113.59* ]]; }
	gps_mesh_wg_socket_bytes() { echo "1024 2048"; }
	gps_mesh_wg_listen_ok() { return 0; }
	gps_mesh_wg_handshake_stats() {
		echo "HS_SUMMARY ok=1 fail=0"
		echo "HS_OK=tile-b|10.66.0.2|203.0.113.59:51820"
	}
	export -f gps_mesh_probe_udp_endpoint gps_mesh_wg_socket_bytes gps_mesh_wg_listen_ok gps_mesh_wg_handshake_stats
	gps_mesh_cmd_show >"$GPS_TEST_PREFIX/show-conn.out" 2>&1
	grep -q '组网连通性摘要' "$GPS_TEST_PREFIX/show-conn.out"
	grep -q '10.66.0.x' "$GPS_TEST_PREFIX/show-conn.out"
	grep -q '登记节点:' "$GPS_TEST_PREFIX/show-conn.out"
	grep -q 'WG 配置 peer 数: 1' "$GPS_TEST_PREFIX/show-conn.out"
	grep -q '203.0.113.59:51820' "$GPS_TEST_PREFIX/show-conn.out"
	grep -q '数据面可能流通' "$GPS_TEST_PREFIX/show-conn.out"
}

@test "mesh connectivity endpoint fail hints udp 51820" {
	export PORT=43021
	export UUID="00000000-0000-4000-8000-000000000120"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.60"
	export MESH_ROLE=master
	export WG_LISTEN_PORT=51820
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-master --overlay-ip 10.66.0.1
	python3 - "$GPS_MESH_PEERS" <<'PY'
import json, datetime
from pathlib import Path
p = Path(__import__("sys").argv[1])
doc = json.loads(p.read_text(encoding="utf-8"))
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc["nodes"].append({
    "node_id": "tile-remote",
    "public_key": "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
    "endpoint": "203.0.113.61:51820",
    "overlay_ip": "10.66.0.3",
    "roles": ["edge"],
    "keepalive": 25,
    "last_seen": now,
})
p.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
	gps_write_config
	save_state
	gps_mesh_probe_udp_endpoint() { return 1; }
	gps_mesh_wg_socket_bytes() { return 1; }
	gps_mesh_wg_listen_ok() { return 0; }
	gps_mesh_wg_handshake_stats() { return 1; }
	export -f gps_mesh_probe_udp_endpoint gps_mesh_wg_socket_bytes gps_mesh_wg_listen_ok gps_mesh_wg_handshake_stats
	gps_mesh_cmd_connectivity >"$GPS_TEST_PREFIX/conn-fail.out" 2>&1
	grep -q '公网 UDP 不可达' "$GPS_TEST_PREFIX/conn-fail.out"
	grep -q 'UDP 51820' "$GPS_TEST_PREFIX/conn-fail.out"
}

@test "mesh connectivity skips probe when no peer" {
	export PORT=43022
	export UUID="00000000-0000-4000-8000-000000000121"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.62"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-only --overlay-ip 10.66.0.1
	save_state
	local old_path=$PATH
	PATH="$GPS_TEST_PREFIX/empty-bin:$PATH"
	mkdir -p "$GPS_TEST_PREFIX/empty-bin"
	gps_mesh_cmd_connectivity >"$GPS_TEST_PREFIX/conn-noping.out" 2>&1
	PATH=$old_path
	grep -q '仅本机或未配置 WG peer' "$GPS_TEST_PREFIX/conn-noping.out"
}

@test "mesh connectivity lists handshake failures" {
	export PORT=43023
	export UUID="00000000-0000-4000-8000-000000000122"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.63"
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-master --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-bad --pubkey "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=" \
		--overlay-ip 10.66.0.4 --endpoint 203.0.113.64:51820
	gps_write_config
	save_state
	gps_mesh_wg_listen_ok() { return 0; }
	gps_mesh_wg_handshake_stats() {
		echo "HS_SUMMARY ok=1 fail=1"
		echo "HS_FAIL=tile-bad|10.66.0.4|203.0.113.64:51820"
	}
	export -f gps_mesh_wg_listen_ok gps_mesh_wg_handshake_stats
	gps_mesh_cmd_connectivity >"$GPS_TEST_PREFIX/conn-hs.out" 2>&1
	grep -q 'WG 握手' "$GPS_TEST_PREFIX/conn-hs.out"
	grep -q 'tile-bad' "$GPS_TEST_PREFIX/conn-hs.out"
	grep -q '部分 peer WG 握手失败' "$GPS_TEST_PREFIX/conn-hs.out"
}
