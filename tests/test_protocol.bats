#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "legacy state without PROTOCOL loads as tuic" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-1"
	unset PROTOCOL || true
	# 模拟旧 state：无 PROTOCOL 行
	umask 077
	mkdir -p "$GPS_ETC"
	{
		gps_env_assign PORT "$PORT"
		gps_env_assign UUID "$UUID"
		gps_env_assign PASSWORD "$PASSWORD"
		gps_env_assign GPS_TEST_PREFIX "$GPS_TEST_PREFIX"
		gps_env_assign GPS_NO_SYSTEMD 1
	} | gps_atomic_write_env "$GPS_STATE"
	unset PROTOCOL || true
	load_state
	[ "$PROTOCOL" = "tuic" ]
}

@test "save_state persists PROTOCOL=tuic by default" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-1"
	unset PROTOCOL || true
	save_state
	grep -q '^PROTOCOL=tuic$' "$GPS_STATE"
}

@test "gps_protocol_normalize rejects unknown protocol" {
	PROTOCOL=not-a-real-proto
	run gps_protocol_normalize
	[ "$status" -ne 0 ]
	[[ "$output" == *"不支持的协议"* ]]
}

@test "gps_write_config still emits type tuic via plugin" {
	export PORT=43210
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-plugin"
	export PROTOCOL=tuic
	export LOG_LEVEL=info
	STACK_MODE=v4only
	HAS_V4=1
	HAS_V6=0
	detect_local_stack() { STACK_MODE=v4only; HAS_V4=1; HAS_V6=0; }
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "tuic"' "$GPS_CONFIG"
	grep -q 'tuic-in-v4' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "gps_protocol_list includes tuic only" {
	run gps_protocol_list
	[ "$status" -eq 0 ]
	[ "$output" = "tuic" ]
}

@test "gps_proto_tuic_validate rejects bad uuid" {
	PORT=12345
	UUID=not-a-uuid
	PASSWORD=pass
	run gps_proto_tuic_validate
	[ "$status" -ne 0 ]
}
