#!/usr/bin/env bats
# Master cluster.target_version → Member 自动 upgrade-cluster

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	gps_restart_svc() { :; }
	gps_cmd_upgrade_self() {
		echo "$*" >>"${GPS_TEST_PREFIX}/upgrade-self.log"
	}
	export -f gps_cmd_upgrade_self
	teardown() {
		rm -rf "$GPS_TEST_PREFIX"
	}
}

@test "register response cluster target schedules member upgrade" {
	export PORT=43100
	export UUID="00000000-0000-4000-8000-000000000200"
	export PASSWORD="mesh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.90"
	export MESH_ROLE=member
	export MESH_CLUSTER_AUTO_UPGRADE=1
	export MESH_CLUSTER_TOKEN="cluster-tok-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	mkdir -p "${GPS_LIB_DIR}/scripts"
	printf 'v0.2.60\n' >"${GPS_LIB_DIR}/scripts/VERSION"
	WG_PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	WG_PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
	MESH_OVERLAY_IP=10.66.0.2
	NODE_ID=tile-member
	gps_mesh_ensure_dirs
	save_state
	local mport mock
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_MASTER_URL="http://127.0.0.1:${mport}"
	export MESH_MASTER_URL NODE_ID WG_PRIVATE_KEY WG_PUBLIC_KEY MESH_OVERLAY_IP
	save_state
	mock="$GPS_TEST_PREFIX/mock-master.py"
	cat >"$mock" <<PY
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
port = int(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return
    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(ln)
        body = json.dumps({
            "node": {"node_id": "tile-member", "overlay_ip": "10.66.0.2"},
            "peers": {"schema": 1, "nodes": []},
            "cluster": {"target_version": "v0.2.65", "auto_upgrade": True},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
	python3 "$mock" "$mport" &
	local mpid=$!
	sleep 1
	gps_mesh_register_and_pull
	kill "$mpid" 2>/dev/null || true
	wait "$mpid" 2>/dev/null || true
	grep -q '\-\-ver v0.2.65' "${GPS_TEST_PREFIX}/upgrade-self.log"
}

@test "cluster schedule skips when already on target version" {
	export MESH_ROLE=member
	export MESH_CLUSTER_AUTO_UPGRADE=1
	mkdir -p "${GPS_LIB_DIR}/scripts"
	printf 'v0.2.65\n' >"${GPS_LIB_DIR}/scripts/VERSION"
	gps_mesh_cluster_schedule_upgrade "v0.2.65"
	[[ ! -f ${GPS_MESH_UPGRADE_PENDING} ]]
}

@test "cluster schedule respects auto upgrade off" {
	export MESH_ROLE=member
	export MESH_CLUSTER_AUTO_UPGRADE=0
	mkdir -p "${GPS_LIB_DIR}/scripts"
	printf 'v0.2.60\n' >"${GPS_LIB_DIR}/scripts/VERSION"
	gps_mesh_cluster_schedule_upgrade "v0.2.65"
	[[ ! -f ${GPS_MESH_UPGRADE_PENDING} ]]
}
