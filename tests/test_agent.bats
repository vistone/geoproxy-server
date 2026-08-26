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
case "$*" in
"traffic trip"|"traffic resume"|"change traffic-warn "*|"change traffic-stop "*|"change traffic-interval "*) exit 0 ;;
*) exit 1 ;;
esac
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

@test "agent control：trip/resume 调 CLI；未知 action 400" {
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"trip"}'
	[ "$status" -eq 0 ]
	grep -q "FAKE-CLI traffic trip" "$GPS_TEST_PREFIX/fake-cli.log"
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"resume"}'
	grep -q "FAKE-CLI traffic resume" "$GPS_TEST_PREFIX/fake-cli.log"
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"bogus"}'
	run python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',''))" <<<"$output"
	[[ "$output" == *unknown* ]]
}

@test "agent control：set-thresholds 校验与落地" {
	# 非法：warn >= stop
	run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"set-thresholds","warnPct":90,"stopPct":80}'
	[ "$output" = "400" ]
	# 非法：越界
	run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"set-thresholds","warnPct":101,"stopPct":95}'
	[ "$output" = "400" ]
	# 合法
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"set-thresholds","warnPct":80,"stopPct":95}'
	grep -q "FAKE-CLI change traffic-warn 80" "$GPS_TEST_PREFIX/fake-cli.log"
	grep -q "FAKE-CLI change traffic-stop 95" "$GPS_TEST_PREFIX/fake-cli.log"
}

@test "agent control：set-check-interval 校验与落地" {
	# seconds < 60 → 400
	run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"set-check-interval","seconds":30}'
	[ "$output" = "400" ]
	# 合法
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"set-check-interval","seconds":300}'
	grep -q "FAKE-CLI change traffic-interval 300" "$GPS_TEST_PREFIX/fake-cli.log"
}

@test "agent control：CLI 失败返回 500 且错误去敏" {
	# 换成总是失败的 CLI（stderr 带假 API Key，验证去敏）
	cat >"$GPS_AGENT_CLI" <<'EOF'
#!/bin/bash
echo "key=kiwi_secret_key_123456789" >&2
exit 1
EOF
	chmod +x "$GPS_AGENT_CLI"
	run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"trip"}'
	[ "$output" = "500" ]
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"trip"}'
	run python3 -c "import json,sys; print(json.load(sys.stdin)['error'])" <<<"$output"
	! grep -q "kiwi_secret_key_123456789" <<<"$output"
	grep -q "key=\*\*\*\*" <<<"$output"
}

@test "agent control：错误响应不回显 key" {
	run curl -s -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"bogus"}'
	run python3 -c "import json,sys; print(json.load(sys.stdin)['error'])" <<<"$output"
	! grep -q "kiwi_secret_key_123456789" <<<"$output"
}

@test "agent control：state 缺失返回 503" {
	mv "$GPS_STATE" "$GPS_STATE.bak"
	run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${GPS_AGENT_PORT}/v1/control" \
		-H "Authorization: Bearer $GPS_AGENT_TOKEN" -H "Content-Type: application/json" \
		-d '{"action":"trip"}'
	mv "$GPS_STATE.bak" "$GPS_STATE"
	[ "$output" = "503" ]
}
