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
