#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	export GPS_AGENT_PORT=${GPS_AGENT_PORT:-19599}
	export GPS_AGENT_TOKEN="test-token-123"
	export GPS_AGENT_CLI="$GPS_TEST_PREFIX/fake-cli"
	export GPS_STATE="$GPS_TEST_PREFIX/state.env"
	export GPS_MESH_PEERS="$GPS_TEST_PREFIX/peers.json"
	export GPS_VERSION_FILE="$GPS_TEST_PREFIX/VERSION"

	# 固定状态文件（模拟 state.env 的 %q 格式）
	cat >"$GPS_STATE" <<'EOF'
TRAFFIC_WARN_PCT=80
TRAFFIC_STOP_PCT=95
TRAFFIC_CHECK_SEC=300
TRAFFIC_TRIPPED=1
TRAFFIC_TRIPPED_AT=2026-08-25T00:00:00Z
TRAFFIC_USED_BYTES=1000
TRAFFIC_LIMIT_BYTES=10000
TRAFFIC_MULT=1
TRAFFIC_LAST_PCT=10.0
PROTOCOL=tuic
TUIC_NAME=tile3.example.com
MESH_ROLE=master
PORT=443
EOF
	printf 'v0.2.43\n' >"$GPS_VERSION_FILE"
	printf '{"schema":1,"nodes":[{"node_id":"a"},{"node_id":"b"}]}' >"$GPS_MESH_PEERS"
	cat >"$GPS_AGENT_CLI" <<'EOF'
#!/bin/bash
echo "FAKE-CLI $*" >>"$GPS_TEST_PREFIX/fake-cli.log"
exit 0
EOF
	chmod +x "$GPS_AGENT_CLI"

	teardown() {
		kill "$AGENT_PID" 2>/dev/null || true
		wait "$AGENT_PID" 2>/dev/null || true
		rm -rf "$GPS_TEST_PREFIX"
	}

	python3 "$REPO_ROOT/scripts/geoagent.py" >"$GPS_TEST_PREFIX/agent.log" 2>&1 &
	AGENT_PID=$!
	local i
	for i in $(seq 1 50); do
		if curl -fsS -o /dev/null "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status" -H "Authorization: Bearer $GPS_AGENT_TOKEN" 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

@test "agent 鉴权：无/错 token 401，正确 token 200" {
	run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status"
	[ "$output" = "401" ]
	run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status" -H "Authorization: Bearer wrong"
	[ "$output" = "401" ]
	run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status" -H "Authorization: Bearer $GPS_AGENT_TOKEN"
	[ "$output" = "200" ]
}

@test "agent status 字段齐全且映射正确" {
	run curl -s "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status" -H "Authorization: Bearer $GPS_AGENT_TOKEN"
	[ "$status" -eq 0 ]
	run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['node']['id']); print(d['node']['protocol']); print(d['traffic']['usedBytes']); print(d['traffic']['usedPct']); print(d['traffic']['warnPct']); print(d['traffic']['stopPct']); print(d['traffic']['checkSec']); print(d['traffic']['tripped']); print(d['traffic']['trippedAt']); print(d['mesh']['role']); print(d['mesh']['peerCount']); print(d['reportedAt'])" <<<"$output"
	[ "${lines[0]}" = "tile3.example.com" ]
	[ "${lines[1]}" = "tuic" ]
	[ "${lines[2]}" = "1000" ]
	[ "${lines[3]}" = "10.0" ]
	[ "${lines[4]}" = "80" ]
	[ "${lines[5]}" = "95" ]
	[ "${lines[6]}" = "300" ]
	[ "${lines[7]}" = "True" ]
	[ "${lines[8]}" = "2026-08-25T00:00:00Z" ]
	[ "${lines[9]}" = "master" ]
	[ "${lines[10]}" = "2" ]
	[ -n "${lines[11]}" ]
}

@test "agent status 无 state 文件时返回默认值不报错" {
	mv "$GPS_STATE" "$GPS_STATE.bak"
	run curl -s "http://127.0.0.1:${GPS_AGENT_PORT}/v1/status" -H "Authorization: Bearer $GPS_AGENT_TOKEN"
	mv "$GPS_STATE.bak" "$GPS_STATE"
	[ "$status" -eq 0 ]
	run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['traffic']['tripped']); print(d['traffic']['warnPct']); print(d['traffic']['stopPct']); print(d['node']['protocol'])" <<<"$output"
	[ "${lines[0]}" = "False" ]
	[ "${lines[1]}" = "80" ]
	[ "${lines[2]}" = "95" ]
	[ "${lines[3]}" = "tuic" ]
}

@test "agent 未知路径 404；token 为空拒绝启动" {
	run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GPS_AGENT_PORT}/v1/nope" -H "Authorization: Bearer $GPS_AGENT_TOKEN"
	[ "$output" = "404" ]
	# 空 token 拒绝启动（run 包裹：set -e 下裸失败命令会直接中止测试）
	run env GPS_AGENT_TOKEN= python3 "$REPO_ROOT/scripts/geoagent.py"
	[ "$status" -ne 0 ]
}
