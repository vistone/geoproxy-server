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
