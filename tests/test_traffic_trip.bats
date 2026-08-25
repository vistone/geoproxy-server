#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/traffic.sh
	source "$REPO_ROOT/lib/traffic.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	export PORT=43101
	export UUID="00000000-0000-4000-8000-000000000301"
	export PASSWORD="trip-pass"
	export PROTOCOL=tuic
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	GPS_SVC_CALLS=()
	gps_svc() {
		GPS_SVC_CALLS+=("$1")
	}
	teardown() {
		rm -rf "$GPS_TEST_PREFIX"
	}
}

@test "traffic trip 置 TRIPPED=1、停服务、写日志" {
	export TRAFFIC_WARN_PCT=80 TRAFFIC_STOP_PCT=95 TRAFFIC_CHECK_SEC=300
	gps_cmd_traffic_trip
	[ "$TRAFFIC_TRIPPED" = "1" ]
	[ -n "$TRAFFIC_TRIPPED_AT" ]
	[ "${GPS_SVC_CALLS[*]}" = "stop" ]
	grep -q '^TRAFFIC_TRIPPED=1$' "$GPS_STATE"
	grep -q '^TRAFFIC_TRIPPED_AT=' "$GPS_STATE"
	grep -q "TRIP " "${GPS_LOG_DIR}/traffic.log"
}

@test "resume 清除 TRIPPED 与 TRIPPED_AT" {
	export TRAFFIC_TRIPPED=1
	TRAFFIC_TRIPPED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gps_traffic_resume_cleared manual
	[ "$TRAFFIC_TRIPPED" = "0" ]
	[ -z "$TRAFFIC_TRIPPED_AT" ]
	[ "${GPS_SVC_CALLS[*]}" = "start" ]
	grep -q '^TRAFFIC_TRIPPED=0$' "$GPS_STATE"
	! grep -q '^TRAFFIC_TRIPPED_AT=' "$GPS_STATE"
}

@test "traffic trip 在已熔断时幂等" {
	export TRAFFIC_TRIPPED=1
	gps_cmd_traffic_trip
	gps_cmd_traffic_trip
	[ "$TRAFFIC_TRIPPED" = "1" ]
	[ "${GPS_SVC_CALLS[*]}" = "stop stop" ]
}
