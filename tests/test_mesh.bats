#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
}

@test "edge profile config has no endpoints or route" {
	export PORT=43001
	export UUID="00000000-0000-4000-8000-000000000100"
	export PASSWORD="edge-pass"
	export PROTOCOL=tuic
	export PROFILE=edge
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	run gps_write_config
	[ "$status" -eq 0 ]
	run grep -q '"endpoints"' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	run grep -q '"route"' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	grep -q '"type": "direct"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "mesh init creates wg endpoint and peers file" {
	export PORT=43002
	export UUID="00000000-0000-4000-8000-000000000101"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.10"
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	gps_write_config
	save_state
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1 --wg-port 51820
	[ "$PROFILE" = "mesh-member" ]
	[ -f "$GPS_MESH_PEERS" ]
	grep -q '"type": "wireguard"' "$GPS_CONFIG"
	grep -q '"tag": "wg-ep"' "$GPS_CONFIG"
	grep -q '"route"' "$GPS_CONFIG"
	grep -q '10.66.0.0/16' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "peer add and export/import roundtrip" {
	export PORT=43003
	export UUID="00000000-0000-4000-8000-000000000102"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.11"
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	run gps_mesh_export
	[ "$status" -eq 0 ]
	[[ "$output" == *tile-b* ]]
	local dump=$GPS_TEST_PREFIX/peers-out.json
	gps_mesh_export >"$dump"
	# wipe remote peer and re-import
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
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1
	gps_mesh_peer_add tile-exit --pubkey "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=" --overlay-ip 10.66.0.9 --endpoint 203.0.113.99:51820 --exit
	MESH_EXIT_NODE_ID=tile-exit
	gps_write_config
	grep -q '0.0.0.0/0' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "change profile mesh-member persists" {
	export PORT=43005
	export UUID="00000000-0000-4000-8000-000000000104"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PROFILE=edge
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	gps_write_config
	save_state
	run gps_cmd_change profile mesh-member
	[ "$status" -eq 0 ]
	grep -q '^PROFILE=mesh-member$' "$GPS_STATE"
	grep -q wireguard "$GPS_CONFIG"
}

@test "anti-loop rejects self as mesh-exit" {
	export PORT=43006
	export UUID="00000000-0000-4000-8000-000000000105"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	gps_mesh_cmd_init --node-id tile-self --overlay-ip 10.66.0.7
	run gps_cmd_change mesh-exit tile-self
	[ "$status" -ne 0 ]
}
