#!/usr/bin/env bats
# Mesh 控制面 TLS：证书/指纹生成、https 钉扎注册、明文策略、master 单元加固

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
}

@test "master tls cert and pin generated, join urls use https" {
	export PORT=43101
	export UUID="00000000-0000-4000-8000-000000000201"
	export PASSWORD="tls-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.90"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="tls-token-0123456789"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	[ -f "$GPS_MESH_TLS_CERT" ]
	[ -f "$GPS_MESH_TLS_KEY" ]
	check_perm_600 "$GPS_MESH_TLS_KEY"
	[ -f "$GPS_MESH_TLS_FP" ]
	check_perm_600 "$GPS_MESH_TLS_FP"
	grep -q '^sha256//' "$GPS_MESH_TLS_FP"
	# 捕获后再 grep：管道 grep -q 提前退出会 SIGPIPE（pipefail 下 CI 必现）
	local hints
	hints=$(gps_mesh_print_join_hints 2>&1)
	echo "$hints" | grep -q 'GPS_MESH_TLS_PIN=sha256//'
	[[ "$(gps_mesh_primary_join_url)" == https://203.0.113.90:19527 ]]
}

@test "member registers over https with pinned pubkey" {
	export PORT=43102
	export UUID="00000000-0000-4000-8000-000000000202"
	export PASSWORD="tls-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.91"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="tls-token-0123456789"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=tls-token-0123456789 GPS_MESH_PEERS="$GPS_MESH_PEERS" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-tls.log" 2>&1 </dev/null &
	local mpid=$!
	disown "$mpid" 2>/dev/null || true
	local pin i
	pin=""
	for i in $(seq 1 20); do
		[ -s "$GPS_MESH_TLS_FP" ] && pin=$(tr -d '[:space:]' <"$GPS_MESH_TLS_FP")
		[ -n "$pin" ] && break
		sleep 0.3
	done
	[ -n "$pin" ]
	for i in $(seq 1 20); do
		curl -ksS --max-time 2 "https://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.3
	done
	# 正确指纹放行；错误指纹必须被拒（curl 90）
	local health
	health=$(curl -sS -k --pinnedpubkey "$pin" --max-time 3 "https://127.0.0.1:${mport}/v1/health")
	echo "$health" | grep -q '"ok": true'
	if curl -ksS --pinnedpubkey "sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
		--max-time 3 "https://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1; then
		kill -KILL "$mpid" 2>/dev/null || true
		return 1
	fi
	# 成员经 gps_mesh_curl 注册（https + 钉扎 + token 头文件）
	NODE_ID=tile-tls-member
	MESH_ROLE=member
	MESH_MASTER_URL="https://127.0.0.1:${mport}"
	MESH_TLS_PIN="$pin"
	MESH_CLUSTER_TOKEN=tls-token-0123456789
	MESH_OVERLAY_IP=""
	gps_mesh_ensure_wg_keys >/dev/null
	gps_mesh_register_and_pull
	grep -q tile-tls-member "$GPS_MESH_PEERS"
	kill -TERM "$mpid" >/dev/null 2>&1 || true
	sleep 0.2
	kill -KILL "$mpid" >/dev/null 2>&1 || true
}

@test "master unit uses dedicated env file and sandboxing" {
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="tls-token-0123456789"
	gps_mesh_defaults
	gps_mesh_ensure_dirs
	gps_install_mesh_units_files_only
	[ -f "$GPS_MESH_ENV" ]
	check_perm_600 "$GPS_MESH_ENV"
	grep -q '^MESH_CLUSTER_TOKEN=tls-token-0123456789$' "$GPS_MESH_ENV"
	[ -f "$GPS_MESH_MASTER_UNIT_PATH" ]
	grep -q "EnvironmentFile=-${GPS_MESH_ENV}" "$GPS_MESH_MASTER_UNIT_PATH"
	# 不得再引用整个 state.env（凭证最小化）
	! grep -q 'state\.env' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'ProtectSystem=strict' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'MemoryDenyWriteExecute=true' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'ReadWritePaths=' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'CapabilityBoundingSet=$' "$GPS_MESH_MASTER_UNIT_PATH"
}
