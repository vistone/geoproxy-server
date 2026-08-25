#!/usr/bin/env bats
# Mesh 控制面 TLS：证书/指纹生成、https 钉扎注册、明文策略、master 单元加固

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
	# 必须在 source _setup 之后重定义：按环境变量识别本前缀启动的 master（cwd 常为仓库根）
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
	# 断言前清空 host 相关：runner 的 hostname -f 可能是含点 FQDN，
	# 会被 gps_mesh_resolve_master_host 当作 MESH_MASTER_HOST 而改变 primary
	local primary
	primary=$(MESH_MASTER_HOST= TUIC_NAME= NODE_ID= gps_mesh_primary_join_url)
	[[ "$primary" == https://203.0.113.90:19527 ]]
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
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-tls.log" 2>&1 </dev/null 3>&- 4>&- &
	local mpid=$!
	# 不 disown：teardown 需按 PID 杀掉；关闭 3/4 避免拖住 bats 管道
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
	grep -q '^GPS_MESH_MASTER_TLS=1$' "$GPS_MESH_ENV"
	[ -f "$GPS_MESH_MASTER_UNIT_PATH" ]
	grep -q "EnvironmentFile=-${GPS_MESH_ENV}" "$GPS_MESH_MASTER_UNIT_PATH"
	# 不得再引用整个 state.env（凭证最小化）
	! grep -q 'state\.env' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'ProtectSystem=strict' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'MemoryDenyWriteExecute=true' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'ReadWritePaths=' "$GPS_MESH_MASTER_UNIT_PATH"
	grep -q 'CapabilityBoundingSet=$' "$GPS_MESH_MASTER_UNIT_PATH"
}

@test "ensure_master_tls hard-fails when openssl missing (no silent plaintext)" {
	export MESH_ROLE=master
	gps_mesh_defaults
	gps_mesh_ensure_dirs
	have_cmd() { [[ $1 != openssl ]]; }
	run gps_mesh_ensure_master_tls
	[ "$status" -ne 0 ]
	[[ "$output" == *"openssl"* ]] || [[ "$output" == *"TLS"* ]]
}

@test "join hints stay http without PIN when live control plane is plaintext" {
	export PORT=43103
	export UUID="00000000-0000-4000-8000-000000000203"
	export PASSWORD="tls-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.92"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="tls-token-plaintext-01"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	# 磁盘已有证书，但进程以 TLS=0 明文跑（模拟升级后旧进程未重启）
	local mport mpid=0
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_MASTER_PORT=$mport
	MESH_CLUSTER_TOKEN=tls-token-plaintext-01 GPS_MESH_PEERS="$GPS_MESH_PEERS" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" GPS_MESH_MASTER_TLS=0 \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$GPS_TEST_PREFIX/master-plain.log" 2>&1 </dev/null 3>&- 4>&- &
	mpid=$!
	# 用 EXIT 而非 RETURN：RETURN 会在 $() 内任意函数返回时误杀 master，
	# 导致 live scheme 探测回退到磁盘证书（https）。
	cleanup_plain() {
		[[ ${mpid:-0} -gt 0 ]] || return 0
		kill -TERM "$mpid" >/dev/null 2>&1 || true
		sleep 0.2
		kill -KILL "$mpid" >/dev/null 2>&1 || true
		mpid=0
	}
	trap cleanup_plain EXIT
	local i
	for i in $(seq 1 20); do
		curl -fsS --max-time 1 "http://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && break
		sleep 0.3
	done
	curl -fsS --max-time 2 "http://127.0.0.1:${mport}/v1/health" | grep -q '"ok": true'
	local hints primary
	hints=$(MESH_MASTER_HOST= TUIC_NAME= NODE_ID= MESH_MASTER_PORT=$mport gps_mesh_print_join_hints 2>&1)
	primary=$(MESH_MASTER_HOST= TUIC_NAME= NODE_ID= MESH_MASTER_PORT=$mport GPS_MESH_LIVE_SCHEME=http gps_mesh_primary_join_url)
	# 实际明文时不得误导成 https+PIN
	[[ "$primary" == http://203.0.113.92:${mport} ]]
	echo "$hints" | grep -q "GPS_MESH_MASTER=http://"
	! echo "$hints" | grep -q 'GPS_MESH_TLS_PIN='
	! echo "$hints" | grep -q 'GPS_MESH_MASTER=https://'
	cleanup_plain
	trap - EXIT
}

@test "mesh_master refuses to start when TLS required but cert generation fails" {
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	local peers="$GPS_TEST_PREFIX/peers-fail.json"
	printf '%s\n' '{"nodes":[]}' >"$peers"
	# PATH 仅含假 openssl，强制 ensure_tls 失败
	mkdir -p "$GPS_TEST_PREFIX/bin"
	cat >"$GPS_TEST_PREFIX/bin/openssl" <<'EOF'
#!/bin/bash
echo "openssl boom" >&2
exit 1
EOF
	chmod +x "$GPS_TEST_PREFIX/bin/openssl"
	run env PATH="$GPS_TEST_PREFIX/bin:/usr/bin:/bin" \
		MESH_CLUSTER_TOKEN=tls-fail-token-012345 GPS_MESH_PEERS="$peers" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		GPS_MESH_MASTER_TLS_CERT="$GPS_TEST_PREFIX/bad-tls.pem" \
		GPS_MESH_MASTER_TLS_KEY="$GPS_TEST_PREFIX/bad-tls.key" \
		GPS_MESH_TLS_FP="$GPS_TEST_PREFIX/bad-tls.fp" \
		python3 "$REPO_ROOT/scripts/mesh_master.py"
	[ "$status" -ne 0 ]
	[[ "$output" == *"TLS"* ]] || [[ "$output" == *"openssl"* ]] || [[ "$output" == *"失败"* ]]
}
