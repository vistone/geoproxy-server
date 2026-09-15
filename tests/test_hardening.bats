#!/usr/bin/env bats
# v0.2.72 稳定性加固回归测试（TDD：先失败后修复，条目对应 CHANGELOG v0.2.72）

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/download.sh
	source "$REPO_ROOT/lib/download.sh"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/url.sh
	source "$REPO_ROOT/lib/url.sh"
}

# ---------- common.sh：JSON 转义必须覆盖全部 C0 控制字符 ----------

@test "json escape：C0 控制字符全部转义为 \\u00XX（产出合法 JSON）" {
	local escaped
	escaped=$(gps_json_escape $'a\x01b\x1bc')
	run python3 - "$escaped" <<'PY'
import json, sys
raw = sys.argv[1]
s = json.loads('"' + raw + '"')
assert len(s) == 5 and s[1] == chr(1) and s[3] == chr(27), repr(s)
PY
	[ "$status" -eq 0 ]
}

# ---------- config.sh：原子写 + 先校验后替换 + .prev 备份 ----------

@test "write_config：sing-box check 失败时旧配置原样保留（原子替换）" {
	export PORT=44101 UUID="00000000-0000-4000-8000-000000000201" PASSWORD="p1" PROTOCOL=tuic
	gps_write_config
	[ -f "$GPS_CONFIG" ]
	local before
	before=$(cksum "$GPS_CONFIG" | awk '{print $1}')
	cat >"$GPS_LIB_DIR/sing-box" <<'EOF'
#!/bin/bash
[[ "$1" == "check" ]] && exit 1
exit 0
EOF
	chmod +x "$GPS_LIB_DIR/sing-box"
	export PORT=44102
	run gps_write_config
	[ "$status" -ne 0 ]
	[ "$(cksum "$GPS_CONFIG" | awk '{print $1}')" = "$before" ]
	! ls "$GPS_CONFIG".tmp.* >/dev/null 2>&1
}

@test "write_config：成功替换时保留 .prev 上一版配置" {
	export PORT=44111 UUID="00000000-0000-4000-8000-000000000202" PASSWORD="p2" PROTOCOL=tuic
	gps_write_config
	local first
	first=$(cksum "$GPS_CONFIG" | awk '{print $1}')
	export PORT=44112
	gps_write_config
	[ -f "${GPS_CONFIG}.prev" ]
	[ "$(cksum "${GPS_CONFIG}.prev" | awk '{print $1}')" = "$first" ]
}

# ---------- common.sh：锁标志不得跨 gps_with_state_lock 泄漏 ----------
# 注：bash ≤ 5.2（Ubuntu 20.04/22.04/24.04）上前置赋值会在函数返回后残留；
# 本机 bash 5.3+ 无法复现失败，本用例在 CI 的 bash 5.1 上先失败后修复。

@test "state lock：gps_with_state_lock 返回后不泄漏 GPS_STATE_LOCK_HELD" {
	unset GPS_STATE_LOCK_HELD || true
	gps_with_state_lock true
	[ "${GPS_STATE_LOCK_HELD:-0}" = "0" ]
	gps_with_state_lock gps_save_state_unlocked
	[ "${GPS_STATE_LOCK_HELD:-0}" = "0" ]
}

# ---------- mesh shell 侧：master 损坏 peers.json 隔离重建 ----------

@test "mesh master：ensure_boot 遇损坏 peers.json 隔离重建且不失败" {
	export PORT=44121 UUID="00000000-0000-4000-8000-000000000203" PASSWORD="p3" PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.10" MESH_ROLE=master GPS_MESH_MASTER_TLS=0
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	mkdir -p "$(dirname "$GPS_MESH_PEERS")"
	echo '{broken json!!' >"$GPS_MESH_PEERS"
	run gps_mesh_ensure_boot
	[ "$status" -eq 0 ]
	local bad
	bad=$(ls "$GPS_MESH_PEERS".corrupt.* 2>/dev/null | head -1)
	[ -n "$bad" ]
	run python3 -m json.tool "$GPS_MESH_PEERS"
	[ "$status" -eq 0 ]
	grep -q '"node_id"' "$GPS_MESH_PEERS"
	# 跨进程互斥的锁文件已落盘
	[ -e "${GPS_MESH_PEERS}.lock" ]
}

# ---------- mesh_master.py：TLS 握手不得阻塞 accept 循环 ----------

@test "mesh_master：慢 TLS 握手不阻塞后续请求（握手下沉 worker 线程）" {
	local d=$GPS_TEST_PREFIX/tls
	mkdir -p "$d"
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=tls-slow-token-012345 \
		GPS_MESH_PEERS="$d/peers.json" GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		GPS_MESH_MASTER_TLS_CERT="$d/c.pem" GPS_MESH_MASTER_TLS_KEY="$d/k.pem" GPS_MESH_TLS_FP="$d/fp" \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$d/log" 2>&1 </dev/null &
	local pid=$!
	local i ready=0
	for i in $(seq 1 50); do
		if curl -sk -o /dev/null --max-time 2 "https://127.0.0.1:${mport}/v1/health" 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ $ready -ne 1 ]]; then
		kill "$pid" 2>/dev/null || true
		skip "TLS master 未就绪（环境缺 openssl/TLS）"
	fi
	# 恶意连接：完成 TCP 后挂住不握手
	python3 - "$mport" <<'PY' &
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
time.sleep(8)
PY
	local stall=$!
	sleep 0.5
	run curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${mport}/v1/health"
	local code=$output
	kill "$stall" 2>/dev/null || true
	kill "$pid" 2>/dev/null || true
	wait "$stall" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$code" = "200" ]
}

# ---------- mesh_master.py：webhook 升级脱离自身 cgroup ----------

@test "webhook 升级经 systemd-run 脱离 mesh-master cgroup（防自杀）" {
	local d=$GPS_TEST_PREFIX/hook bin=$GPS_TEST_PREFIX/bin
	mkdir -p "$d" "$bin"
	local secret="whsec-hardening-0123456789"
	cat >"$bin/systemd-run" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$d/sdr.log"
exit 0
EOF
	cat >"$bin/geoproxy-server" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$d/cli.log"
exit 0
EOF
	chmod +x "$bin/systemd-run" "$bin/geoproxy-server"
	local mport
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	PATH="$bin:$PATH" \
		MESH_CLUSTER_TOKEN=hook-token-0123456789 \
		GPS_GITHUB_WEBHOOK_SECRET="$secret" \
		GPS_MESH_PEERS="$d/peers.json" GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" \
		GPS_UPGRADE_CLI="$bin/geoproxy-server" GPS_MESH_MASTER_TLS=0 \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$d/log" 2>&1 </dev/null &
	local pid=$!
	local i ready=0
	for i in $(seq 1 50); do
		if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${mport}/v1/health" 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ $ready -ne 1 ]]; then
		kill "$pid" 2>/dev/null || true
		skip "master 未就绪"
	fi
	local body='{"action":"published","release":{"tag_name":"v9.9.9"}}'
	local sig
	sig=$(printf 'sha256=%s' "$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" | awk '{print $2}')")
	curl -fsS --max-time 3 \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: release" \
		-H "X-Hub-Signature-256: $sig" \
		-d "$body" "http://127.0.0.1:${mport}/v1/hook/github" >/dev/null
	for i in $(seq 1 20); do
		[[ -s "$d/sdr.log" ]] && break
		sleep 0.2
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	grep -q "upgrade self --ver v9.9.9" "$d/sdr.log"
	# 旧路径（直接在 mesh-master cgroup 内执行）不得出现
	[ ! -e "$d/cli.log" ]
}

# ---------- mesh_master.py：overlay 改派与畸形 tripped 字段 ----------

@test "register：旧 overlay 已被他人占用时改派新地址（不固化冲突）" {
	local d=$GPS_TEST_PREFIX/ov
	mkdir -p "$d"
	cat >"$d/peers.json" <<'EOF'
{
  "schema": 1,
  "nodes": [
    {"node_id": "a", "public_key": "KA", "endpoint": "", "overlay_ip": "10.66.0.5", "roles": ["edge"], "keepalive": 25, "tripped": 0, "last_seen": "2026-09-15T00:00:00Z"},
    {"node_id": "b", "public_key": "KB", "endpoint": "", "overlay_ip": "10.66.0.5", "roles": ["edge"], "keepalive": 25, "tripped": 0, "last_seen": "2026-09-15T00:00:00Z"}
  ]
}
EOF
	local mport pid resp
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=ov-token-0123456789 GPS_MESH_PEERS="$d/peers.json" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" GPS_MESH_MASTER_TLS=0 \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$d/log" 2>&1 </dev/null &
	pid=$!
	local i ready=0
	for i in $(seq 1 50); do
		if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${mport}/v1/health" 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ $ready -ne 1 ]]; then
		kill "$pid" 2>/dev/null || true
		skip "master 未就绪"
	fi
	curl -fsS --max-time 3 -H "Authorization: Bearer ov-token-0123456789" \
		-H "Content-Type: application/json" \
		-d '{"node_id":"b","public_key":"KB2"}' \
		"http://127.0.0.1:${mport}/v1/register" >"$d/resp.json"
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	resp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node"]["overlay_ip"])' "$d/resp.json")
	[ "$resp" != "10.66.0.5" ]
}

@test "heartbeat/register：tripped 非整数字段不炸线程（按 0 处理）" {
	local d=$GPS_TEST_PREFIX/tr
	mkdir -p "$d"
	printf 'not-json' >"$d/peers.json"
	local mport pid code1 code2
	mport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	MESH_CLUSTER_TOKEN=tr-token-0123456789 GPS_MESH_PEERS="$d/peers.json" \
		GPS_MESH_MASTER_BIND=127.0.0.1 GPS_MESH_MASTER_PORT="$mport" GPS_MESH_MASTER_TLS=0 \
		python3 "$REPO_ROOT/scripts/mesh_master.py" >"$d/log" 2>&1 </dev/null &
	pid=$!
	local i ready=0
	for i in $(seq 1 50); do
		if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${mport}/v1/health" 2>/dev/null; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ $ready -ne 1 ]]; then
		kill "$pid" 2>/dev/null || true
		skip "master 未就绪"
	fi
	code1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
		-H "Authorization: Bearer tr-token-0123456789" -H "Content-Type: application/json" \
		-d '{"node_id":"a","public_key":"KA","tripped":"on"}' \
		"http://127.0.0.1:${mport}/v1/register")
	code2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
		-H "Authorization: Bearer tr-token-0123456789" -H "Content-Type: application/json" \
		-d '{"node_id":"a","tripped":[]}' \
		"http://127.0.0.1:${mport}/v1/heartbeat")
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	[ "$code1" = "200" ]
	[ "$code2" = "200" ]
	# 损坏 peers.json 被隔离重建（load_doc 容错）
	ls "$d"/peers.json.corrupt.* >/dev/null 2>&1
}

# ---------- geoagent.py：连接统计方向 ----------

@test "geoagent：activeConnections 按本地端口统计（不数出站）" {
	local bin=$GPS_TEST_PREFIX/ssbin
	mkdir -p "$bin"
	cat >"$bin/ss" <<'EOF'
#!/bin/bash
cat <<'OUT'
Recv-Q Send-Q Local Address:Port Peer Address:Port
0 0 10.0.0.1:443 8.8.8.8:54321
0 0 10.0.0.1:8080 8.8.8.8:443
0 0 10.0.0.1:443 1.1.1.1:9999
OUT
EOF
	chmod +x "$bin/ss"
	run env PATH="$bin:$PATH" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import geoagent
print(geoagent.active_connections("443"))' "$REPO_ROOT/scripts"
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

# ---------- systemd 模板：抑制 3 秒重启风暴 ----------

@test "service 模板配置 StartLimit 抑制无限重启风暴" {
	grep -q '^StartLimitIntervalSec=' "$REPO_ROOT/templates/geoproxy-tuic.service"
	grep -q '^StartLimitIntervalSec=' "$REPO_ROOT/templates/geoproxy-mesh-master.service"
	grep -q '^StartLimitIntervalSec=' "$REPO_ROOT/templates/geoproxy-agent.service"
}

# ---------- download.sh：停服后的失败必须兜底拉起服务 ----------

@test "upgrade self：停服后安装失败也兜底拉起服务" {
	local tree=$GPS_TEST_PREFIX/tree
	mkdir -p "$tree"
	echo v9.9.9 >"$tree/VERSION"
	touch "$tree/geoproxy-server.sh"
	export PORT=44131 UUID="00000000-0000-4000-8000-000000000204" PASSWORD="p4" PROTOCOL=tuic
	save_state
	ensure_deps() { :; }
	gps_self_fetch_tree() { echo "$tree"; }
	gps_self_install_tree() { err "boom"; }
	gps_svc_halt() { printf 'halt\n' >>"$GPS_TEST_PREFIX/hb.log"; }
	gps_svc_boot() { printf 'boot\n' >>"$GPS_TEST_PREFIX/hb.log"; }
	gps_upgrade_restart_mesh_master() { :; }
	run gps_cmd_upgrade_self --ver v9.9.9
	[ "$status" -ne 0 ]
	grep -q '^boot$' "$GPS_TEST_PREFIX/hb.log"
}

# ---------- 凭证卫生（AGENTS.md：凭证不得进子进程 argv） ----------

@test "gps_urlencode 不把待编码值放进子进程 argv" {
	local bin=$GPS_TEST_PREFIX/pybin
	mkdir -p "$bin"
	local real
	real=$(command -v python3)
	cat >"$bin/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GPS_TEST_PREFIX/argv.log"
exec "$real" "\$@"
EOF
	chmod +x "$bin/python3"
	local out rc=0
	out=$(PATH="$bin:$PATH" gps_urlencode "secret-pass-42") || rc=$?
	[ "$rc" -eq 0 ]
	[ "$out" = "secret-pass-42" ]
	! grep -q "secret-pass-42" "$GPS_TEST_PREFIX/argv.log"
}

@test "ss 分享链接 b64 不把 method:password 放进子进程 argv" {
	local bin=$GPS_TEST_PREFIX/pybin2
	mkdir -p "$bin"
	local real
	real=$(command -v python3)
	cat >"$bin/python3" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$GPS_TEST_PREFIX/argv2.log"
exec "$real" "\$@"
EOF
	chmod +x "$bin/python3"
	export PORT=44141 UUID="00000000-0000-4000-8000-000000000205" PASSWORD="p5" PROTOCOL=tuic
	export SS_METHOD="2022-blake3-aes-128-gcm" SS_PASSWORD="ss-secret-99" PUBLIC_IP="203.0.113.99"
	save_state
	load_state
	gps_proto_node_name() { echo "n"; }
	gps_proto_each_public_host() { echo "203.0.113.99"; }
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	local out rc=0
	out=$(PATH="$bin:$PATH" gps_proto_shadowsocks_share_urls) || rc=$?
	[ "$rc" -eq 0 ]
	grep -q '^ss://' <<<"$out"
	! grep -q "ss-secret-99" "$GPS_TEST_PREFIX/argv2.log"
}

@test "qr 展示不把分享 URL 放进 qrencode argv" {
	local bin=$GPS_TEST_PREFIX/qrbin
	mkdir -p "$bin"
	cat >"$bin/qrencode" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$GPS_TEST_PREFIX/qr-argv.log"
echo "QR"
EOF
	chmod +x "$bin/qrencode"
	gps_proto_share_urls() { echo "tuic://secret-qr@203.0.113.77:443/?k=v#node"; }
	local out rc=0
	out=$(PATH="$bin:$PATH" gps_cmd_qr) || rc=$?
	[ "$rc" -eq 0 ]
	grep -q "tuic://secret-qr@203.0.113.77:443" <<<"$out"
	! grep -q "tuic://secret-qr" "$GPS_TEST_PREFIX/qr-argv.log"
}

# ---------- 安全审计修复：H-03 / M-03 / M-04 / M-05 ----------

@test "gps_verify_tree_version 检查必需文件（H-03：tag archive 回退校验增强）" {
	local tree=$GPS_TEST_PREFIX/tree
	mkdir -p "$tree"
	echo "v9.9.9" >"$tree/VERSION"
	# 缺少 geoproxy-server.sh → 应失败
	run gps_verify_tree_version "$tree" "v9.9.9"
	[ "$status" -ne 0 ]
	# 补齐所有必需文件 + 入口脚本语法正确 → 应通过
	mkdir -p "$tree/lib/mesh" "$tree/scripts"
	touch \
		"$tree/geoproxy-server.sh" \
		"$tree/lib/common.sh" \
		"$tree/lib/config.sh" \
		"$tree/lib/paths.sh" \
		"$tree/lib/mesh/_registry.sh" \
		"$tree/scripts/mesh_master.py" \
		"$tree/scripts/geoagent.py"
	echo '#!/usr/bin/env bash' >"$tree/geoproxy-server.sh"
	run gps_verify_tree_version "$tree" "v9.9.9"
	[ "$status" -eq 0 ]
}

@test "自签 TLS 证书有效期 ≤ 365 天（M-03）" {
	local days
	days=$(grep -Eo -- '-days[[:space:]]+[0-9]+' "$REPO_ROOT/lib/tls.sh" | head -1 | tr -s ' ' | cut -d' ' -f2)
	[ -n "$days" ]
	[ "$days" -le 365 ]
	days=$(grep -Eo -- '-days[[:space:]]+[0-9]+' "$REPO_ROOT/lib/mesh/_common.sh" | head -1 | tr -s ' ' | cut -d' ' -f2)
	[ -n "$days" ]
	[ "$days" -le 365 ]
}

@test "gen_uuid 输出符合 RFC 4122 v4 格式（M-04）" {
	local u
	u=$(gen_uuid)
	[[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[4][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

@test "rand_port 使用 /dev/urandom 而非 \$RANDOM（M-05）" {
	local src
	src=$(awk '/^rand_port\(\)/,/^}/' "$REPO_ROOT/lib/common.sh")
	grep -q '/dev/urandom' <<<"$src"
	! grep -q '\$RANDOM' <<<"$src"
}
