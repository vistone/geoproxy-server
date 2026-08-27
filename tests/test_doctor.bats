#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/doctor.sh
	source "$REPO_ROOT/lib/doctor.sh"
}

@test "disk usage percent is an integer between 0 and 100" {
	pct=$(gps_disk_usage_pct "$GPS_LOG_DIR")
	[ -n "$pct" ]
	[[ "$pct" =~ ^[0-9]+$ ]]
	[ "$pct" -ge 0 ]
	[ "$pct" -le 100 ]
}

@test "disk usage percent fails for missing directory" {
	! gps_disk_usage_pct "$BATS_TEST_TMPDIR/definitely-missing-dir"
}

@test "doctor master reports mesh control plane listen and cloud security group" {
	export PORT=43201
	export UUID="00000000-0000-4000-8000-000000000301"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.77"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-token-01234567"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	run gps_doctor
	[[ "$output" == *"0.0.0.0:19527"* ]]
	[[ "$output" == *"TCP 19527"* ]]
	[[ "$output" == *"云安全组"* ]]
	[[ "$output" == *"UDP 51820"* ]]
	[[ "$output" == *"WG 数据面"* ]]
	[[ "$output" == *"组网连通性摘要"* ]]
	[[ "$output" == *"不等于 WG 隧道已打通"* ]]
}

@test "doctor probes https health when master TLS certs exist" {
	export PORT=43202
	export UUID="00000000-0000-4000-8000-000000000302"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.78"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-tls-token-0123"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	[ -f "$GPS_MESH_TLS_CERT" ]
	local hp=${MESH_MASTER_PORT:-19527}
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
	run gps_doctor
	# 菜单 23 须显式打出本机 https health URL（运维可对照手敲 curl）
	[[ "$output" == *"https://127.0.0.1:${hp}/v1/health"* ]]
	[[ "$output" == *"OK"* ]]
}

@test "doctor flags plaintext mesh-master when certs exist but only http responds" {
	export PORT=43203
	export UUID="00000000-0000-4000-8000-000000000303"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.79"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-plain-token-012"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local hp=${MESH_MASTER_PORT:-19527}
	curl() {
		local arg
		for arg in "$@"; do
			case $arg in
			https://*) return 1 ;;
			http://*) return 0 ;;
			esac
		done
		return 1
	}
	run gps_doctor
	# 不得把明文误报成 OK
	! [[ "$output" == *"OK"*"https://127.0.0.1:${hp}/v1/health"* ]]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"明文"* ]] || [[ "$output" == *"http://127.0.0.1:${hp}/v1/health"* ]]
}

@test "health probe retries until mesh-master responds" {
	export PORT=43205
	export UUID="00000000-0000-4000-8000-000000000305"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.81"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-retry-token-012"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	local hp=${MESH_MASTER_PORT:-19527}
	local count_file="$GPS_TEST_PREFIX/health-retry.n"
	: >"$count_file"
	curl() {
		local arg
		for arg in "$@"; do
			case $arg in
			https://*)
				echo 1 >>"$count_file"
				[[ $(wc -l <"$count_file") -ge 3 ]] && return 0
				return 1
				;;
			http://*) return 1 ;;
			esac
		done
		return 1
	}
	GPS_MESH_HEALTH_WAIT=2 run gps_mesh_print_local_health "$hp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"OK"* ]]
	[[ "$output" == *"https://127.0.0.1:${hp}/v1/health"* ]]
	[[ $(wc -l <"$count_file") -ge 3 ]]
}

@test "doctor FAILs when TLS certs exist but neither https nor http health responds" {
	export PORT=43204
	export UUID="00000000-0000-4000-8000-000000000304"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.80"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-down-token-0123"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	[ -f "$GPS_MESH_TLS_CERT" ]
	local hp=${MESH_MASTER_PORT:-19527}
	curl() { return 1; }
	run gps_doctor
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"https://127.0.0.1:${hp}/v1/health"* ]]
	[[ "$output" == *"无响应"* ]]
	# 不得把宕机误报成 OK（同色行内不得出现 OK + health URL）
	! echo "$output" | grep -E 'OK[[:space:]].*https://127\.0\.0\.1:'"${hp}"'/v1/health'
}

_member_doctor_setup() {
	export PORT=${1:-43301}
	export UUID="00000000-0000-4000-8000-$(printf '%012x' "$PORT")"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.100"
	export MESH_ROLE=member
	export MESH_CLUSTER_TOKEN="doctor-member-token-012345"
	export WG_PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE="
	export WG_PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE="
	export MESH_OVERLAY_IP=10.66.0.10
	export NODE_ID=doc-member
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_register_and_pull() { return 1; }
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
}

@test "doctor member FAILs on public http MESH_MASTER_URL" {
	_member_doctor_setup 43301
	export MESH_MASTER_URL="http://203.0.113.100:19527"
	save_state
	run gps_doctor
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"http://203.0.113.100:19527"* ]]
	[[ "$output" == *"明文"* ]]
}

@test "doctor member WARNs when https Master lacks MESH_TLS_PIN" {
	_member_doctor_setup 43302
	export MESH_MASTER_URL="https://203.0.113.101:19527"
	unset MESH_TLS_PIN
	save_state
	curl() { return 1; }
	run gps_doctor
	[[ "$output" == *"WARN"* ]]
	[[ "$output" == *"MESH_TLS_PIN"* ]]
}

@test "doctor member FAILs when master health probe times out" {
	_member_doctor_setup 43303
	export MESH_MASTER_URL="https://203.0.113.102:19527"
	export MESH_TLS_PIN="sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	save_state
	curl() { return 28; }
	run gps_doctor
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"https://203.0.113.102:19527/v1/health"* ]]
	[[ "$output" == *"TCP 19527"* ]]
	[[ "$output" == *"云安全组"* ]]
}

@test "doctor member OK when master health responds" {
	_member_doctor_setup 43304
	export MESH_MASTER_URL="https://203.0.113.103:19527"
	export MESH_TLS_PIN="sha256//BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
	save_state
	curl() {
		local arg
		for arg in "$@"; do
			case $arg in
			https://*) return 0 ;;
			esac
		done
		return 1
	}
	run gps_doctor
	[[ "$output" == *"OK"* ]]
	[[ "$output" == *"https://203.0.113.103:19527/v1/health"* ]]
}

_doctor_systemd_begin() {
	have_cmd() { [[ $1 == systemctl ]]; }
	_DOCTOR_SAVED_PREFIX=$GPS_TEST_PREFIX
	GPS_TEST_PREFIX=
	GPS_NO_SYSTEMD=0
}

_doctor_systemd_end() {
	GPS_TEST_PREFIX=${_DOCTOR_SAVED_PREFIX:-}
	GPS_NO_SYSTEMD=1
	unset -f have_cmd systemctl 2>/dev/null || true
}

@test "doctor OK when geoproxy-agent enabled and active" {
	export PORT=43401
	export UUID="00000000-0000-4000-8000-00000000043401"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.201"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 0 ;;
		"is-active --quiet geoproxy-agent.service") return 0 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ "$output" == *"OK"*"geoproxy-agent.service active"* ]]
}

@test "doctor FAILs inactive geoproxy-agent when unit enabled" {
	export PORT=43402
	export UUID="00000000-0000-4000-8000-00000000043402"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.202"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 0 ;;
		"is-active --quiet geoproxy-agent.service") return 1 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[ "$status" -ne 0 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"geoproxy-agent.service 未 active"* ]]
	[[ "$output" == *"systemctl restart geoproxy-agent"* ]]
}

@test "doctor skips geoproxy-agent when unit not enabled" {
	export PORT=43403
	export UUID="00000000-0000-4000-8000-00000000043403"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.203"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 1 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ ! "$output" == *"geoproxy-agent.service active"* ]]
	[[ ! "$output" == *"geoproxy-agent.service 未 active"* ]]
}

@test "doctor member OK when mesh-sync.timer enabled and active" {
	_member_doctor_setup 43404
	export MESH_MASTER_URL="https://203.0.113.204:19527"
	export MESH_TLS_PIN="sha256//CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
	save_state
	curl() {
		case "$1" in
		https://*) return 0 ;;
		esac
		return 1
	}
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 1 ;;
		"is-enabled --quiet geoproxy-mesh-sync.timer") return 0 ;;
		"is-active --quiet geoproxy-mesh-sync.timer") return 0 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ "$output" == *"OK"*"geoproxy-mesh-sync.timer active"* ]]
}

@test "doctor member FAILs inactive mesh-sync.timer when enabled" {
	_member_doctor_setup 43405
	export MESH_MASTER_URL="https://203.0.113.205:19527"
	export MESH_TLS_PIN="sha256//DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD="
	save_state
	curl() { return 1; }
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 1 ;;
		"is-enabled --quiet geoproxy-mesh-sync.timer") return 0 ;;
		"is-active --quiet geoproxy-mesh-sync.timer") return 1 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"geoproxy-mesh-sync.timer 未 active"* ]]
	[[ "$output" == *"systemctl restart geoproxy-mesh-sync.timer"* ]]
}

@test "doctor master checks mesh-sync.timer when enabled" {
	export PORT=43406
	export UUID="00000000-0000-4000-8000-00000000043406"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.206"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-sync-timer-token"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	curl() {
		case "$1" in
		http://*) return 0 ;;
		esac
		return 1
	}
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 1 ;;
		"is-enabled --quiet geoproxy-mesh-sync.timer") return 0 ;;
		"is-active --quiet geoproxy-mesh-sync.timer") return 0 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ "$output" == *"OK"*"geoproxy-mesh-sync.timer active"* ]]
}

@test "doctor warns when agent binds 0.0.0.0 public" {
	export PORT=43407
	export UUID="00000000-0000-4000-8000-00000000043407"
	export PASSWORD="doc-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.207"
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="doctor-agent-bind-token"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	umask 077
	{
		printf 'GPS_AGENT_TOKEN=%s\n' "doctor-agent-bind-tok-0123456789"
		printf 'GPS_AGENT_BIND=%s\n' "0.0.0.0"
		printf 'GPS_AGENT_PORT=%s\n' "19528"
	} >"$GPS_AGENT_ENV"
	chmod 600 "$GPS_AGENT_ENV" 2>/dev/null || true
	curl() {
		case "$1" in
		http://*) return 0 ;;
		esac
		return 1
	}
	_doctor_systemd_begin
	systemctl() {
		case "$*" in
		"is-active --quiet geoproxy-tuic") return 0 ;;
		"is-enabled --quiet geoproxy-agent.service") return 1 ;;
		"is-enabled --quiet geoproxy-mesh-sync.timer") return 1 ;;
		esac
		return 0
	}
	run gps_doctor
	_doctor_systemd_end
	[[ "$output" == *"WARN"*"agent 监听 0.0.0.0"* ]]
	[[ "$output" == *"v2rayA"* ]]
	! [[ "$output" == *"FAIL) agent 监听 0.0.0.0"* ]]
}
