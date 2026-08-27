#!/usr/bin/env bats
# Mesh Master GitHub Release webhook：签名校验与 upgrade self 触发

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
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

_github_sig() {
	local body=$1 secret=$2
	printf 'sha256=%s' "$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" | awk '{print $2}')"
}

_start_master() {
	local secret=${1:-} upgrade_cli=${2:-}
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	local -a env=(MESH_CLUSTER_TOKEN=wh-token-0123456789abcdef
		GPS_MESH_PEERS="$GPS_MESH_PEERS"
		GPS_MESH_MASTER_TLS=0
		GPS_MESH_MASTER_BIND=127.0.0.1
		GPS_MESH_MASTER_PORT="$mport")
	[[ -n $secret ]] && env+=(GPS_GITHUB_WEBHOOK_SECRET="$secret")
	[[ -n $upgrade_cli ]] && env+=(GPS_UPGRADE_CLI="$upgrade_cli")
	: >"$GPS_TEST_PREFIX/upgrade-calls.log"
	env "${env[@]}" python3 "$REPO_ROOT/scripts/mesh_master.py" \
		>"$GPS_TEST_PREFIX/webhook-master.log" 2>&1 </dev/null 3>&- 4>&- &
	WH_MPID=$!
	WH_MPORT=$mport
	local i
	for i in 1 2 3 4 5 6 7 8; do
		curl -fsS --max-time 1 "http://127.0.0.1:${mport}/v1/health" >/dev/null 2>&1 && return 0
		sleep 0.3
	done
	return 1
}

_stop_master() {
	kill -TERM "${WH_MPID:-}" >/dev/null 2>&1 || true
	sleep 0.2
	kill -KILL "${WH_MPID:-}" >/dev/null 2>&1 || true
}

@test "webhook returns 503 when secret not configured" {
	export PORT=43201
	export UUID="00000000-0000-4000-8000-000000000301"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.201"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	_start_master "" ""
	local code
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
		-H "Content-Type: application/json" \
		-d '{"zen":"ping"}' \
		"http://127.0.0.1:${WH_MPORT}/v1/hook/github")
	[ "$code" = "503" ]
	_stop_master
}

@test "webhook rejects invalid signature" {
	export PORT=43202
	export UUID="00000000-0000-4000-8000-000000000302"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.202"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	_start_master "correct-secret" ""
	local body='{"zen":"test"}'
	local code
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: ping" \
		-H "X-Hub-Signature-256: sha256=deadbeef" \
		-d "$body" \
		"http://127.0.0.1:${WH_MPORT}/v1/hook/github")
	[ "$code" = "401" ]
	_stop_master
}

@test "webhook ping accepts valid signature" {
	export PORT=43203
	export UUID="00000000-0000-4000-8000-000000000303"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.203"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local secret="whsec-test-ping-0123456789"
	_start_master "$secret" ""
	local body='{"zen":"hook ping"}'
	local sig resp
	sig=$(_github_sig "$body" "$secret")
	resp=$(curl -fsS --max-time 3 \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: ping" \
		-H "X-Hub-Signature-256: $sig" \
		-d "$body" \
		"http://127.0.0.1:${WH_MPORT}/v1/hook/github")
	echo "$resp" | grep -q '"pong": true'
	_stop_master
}

@test "webhook release published triggers upgrade self with tag" {
	export PORT=43204
	export UUID="00000000-0000-4000-8000-000000000304"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.204"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local mock="$GPS_TEST_PREFIX/mock-upgrade.sh"
	cat >"$mock" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GPS_TEST_PREFIX/upgrade-calls.log"
exit 0
EOF
	chmod +x "$mock"
	local secret="whsec-release-test-0123456789"
	_start_master "$secret" "$mock"
	local body='{"action":"published","release":{"tag_name":"v0.2.62"}}'
	local sig resp code
	sig=$(_github_sig "$body" "$secret")
	resp=$(curl -fsS --max-time 3 \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: release" \
		-H "X-Hub-Signature-256: $sig" \
		-d "$body" \
		"http://127.0.0.1:${WH_MPORT}/v1/hook/github")
	echo "$resp" | grep -q '"upgrade": "v0.2.62"'
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[[ -s "$GPS_TEST_PREFIX/upgrade-calls.log" ]] && break
		sleep 0.2
	done
	grep -q 'upgrade self --ver v0.2.62' "$GPS_TEST_PREFIX/upgrade-calls.log"
	_stop_master
}

@test "webhook ignores release created (not published)" {
	export PORT=43205
	export UUID="00000000-0000-4000-8000-000000000305"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.205"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local mock="$GPS_TEST_PREFIX/mock-upgrade2.sh"
	cat >"$mock" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GPS_TEST_PREFIX/upgrade-calls2.log"
exit 0
EOF
	chmod +x "$mock"
	local secret="whsec-created-test-0123456789"
	_start_master "$secret" "$mock"
	local body='{"action":"created","release":{"tag_name":"v0.2.62"}}'
	local sig resp
	sig=$(_github_sig "$body" "$secret")
	resp=$(curl -fsS --max-time 3 \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: release" \
		-H "X-Hub-Signature-256: $sig" \
		-d "$body" \
		"http://127.0.0.1:${WH_MPORT}/v1/hook/github")
	echo "$resp" | grep -q '"ignored": true'
	[[ ! -s "$GPS_TEST_PREFIX/upgrade-calls2.log" ]]
	_stop_master
}

@test "mesh webhook set-secret writes master.env and state" {
	export PORT=43206
	export UUID="00000000-0000-4000-8000-000000000306"
	export PASSWORD="wh-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.206"
	export TUIC_NAME="tile3.zeromaps.cn"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="wh-token-0123456789abcdef"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_mesh_webhook_set_secret "my-webhook-secret-0123456789abcdef" \
		>"$GPS_TEST_PREFIX/webhook-set.out" 2>&1
	grep -q '^GPS_GITHUB_WEBHOOK_SECRET=my-webhook-secret-0123456789abcdef$' "$GPS_MESH_ENV"
	grep -q 'GPS_GITHUB_WEBHOOK_SECRET' "$GPS_STATE"
	gps_mesh_webhook_show >"$GPS_TEST_PREFIX/webhook-show.out"
	grep -q '/v1/hook/github' "$GPS_TEST_PREFIX/webhook-show.out"
	grep -q 'tile3.zeromaps.cn:19527/v1/hook/github' "$GPS_TEST_PREFIX/webhook-show.out"
}
