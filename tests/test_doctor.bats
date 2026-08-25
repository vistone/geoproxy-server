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
