#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "save_state writes state.env with expected keys and permissions" {
	export PORT=22222
	export UUID="save-uuid"
	export PASSWORD="save-pass"
	export PUBLIC_IP="9.9.9.9"
	export PUBLIC_IP6="::1"
	save_state
	[ -f "$GPS_STATE" ]
	run grep '^PORT=' "$GPS_STATE"
	[ "$status" -eq 0 ]
	run grep '^UUID=' "$GPS_STATE"
	[ "$status" -eq 0 ]
	run grep '^PUBLIC_IP=' "$GPS_STATE"
	[ "$status" -eq 0 ]
	check_perm_600 "$GPS_STATE"
}

@test "save_state persists traffic byte quota fields for agent reporting" {
	export TRAFFIC_USED_BYTES=246000000
	export TRAFFIC_LIMIT_BYTES=1000000000
	export TRAFFIC_MULT=1
	export TRAFFIC_RESET=1756742400
	TRAFFIC_LAST_PCT=24.6
	save_state
	for k in TRAFFIC_USED_BYTES TRAFFIC_LIMIT_BYTES TRAFFIC_MULT TRAFFIC_RESET; do
		run grep "^${k}=" "$GPS_STATE"
		[ "$status" -eq 0 ]
	done
	# agent 依赖字节字段计算 usedBytes/quotaBytes，仅百分比不足以还原绝对值
	run grep '^TRAFFIC_USED_BYTES=246000000' "$GPS_STATE"
	[ "$status" -eq 0 ]
}

@test "state reload preserves shell metacharacters as data" {
	PASSWORD='literal$(not-a-command); "quoted"'
	run save_state
	[ "$status" -eq 0 ]
	PASSWORD=''
	# load_state 必须直接调用：其赋值要留在当前 shell
	load_state
	[ "$PASSWORD" = 'literal$(not-a-command); "quoted"' ]
}

@test "save_state atomically replaces state and leaves no temp files" {
	mkdir -p "$GPS_ETC"
	printf 'OLD=1\n' >"$GPS_STATE"
	export PORT=33333
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD=atomic-pass
	run save_state
	[ "$status" -eq 0 ]
	# 旧内容被整体替换，不残留 OLD=
	run grep '^OLD=' "$GPS_STATE"
	[ "$status" -ne 0 ]
	run grep '^PORT=33333' "$GPS_STATE"
	[ "$status" -eq 0 ]
	# 新内容是完整键集
	for k in PROTOCOL UUID PASSWORD TRAFFIC_WARN_PCT TRAFFIC_STOP_PCT GPS_TEST_PREFIX TUIC_NAME; do
		run grep "^${k}=" "$GPS_STATE"
		[ "$status" -eq 0 ]
	done
	grep -q '^PROTOCOL=tuic$' "$GPS_STATE"
	# 无残留临时文件
	leftovers=$(find "$GPS_ETC" -name 'state.env.tmp.*' 2>/dev/null | wc -l)
	[ "$leftovers" -eq 0 ]
}

@test "state writes are serialized by the project lock" {
	mkdir -p "$GPS_ETC"
	export PORT=44444
	# 后台 shell 持锁 1 秒后释放（与实现同一把锁）
	(
		# shellcheck source=../lib/common.sh
		source "$REPO_ROOT/lib/common.sh"
		gps_state_lock_acquire
		sleep 1
		gps_state_lock_release
	) &
	holder=$!
	sleep 0.3
	t0=$(date +%s%N)
	run save_state
	[ "$status" -eq 0 ]
	t1=$(date +%s%N)
	wait "$holder"
	elapsed_ms=$(((t1 - t0) / 1000000))
	# save_state 必须等后台释放锁（后台至少还持锁 ~0.7s）
	[ "$elapsed_ms" -ge 500 ]
}

@test "ports are limited to 1 through 65535" {
	gps_validate_port 1
	gps_validate_port 65535
	! gps_validate_port 0
	! gps_validate_port 65536
	! gps_validate_port 12x
}

@test "IPv4 validation rejects out-of-range octets" {
	gps_validate_ipv4 203.0.113.8
	! gps_validate_ipv4 999.0.0.1
	! gps_validate_ipv4 1.2.3
	gps_validate_ipv4 0.0.0.0
	gps_validate_ipv4 255.255.255.255
	! gps_validate_ipv4 256.1.1.1
}
