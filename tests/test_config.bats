#!/usr/bin/env bats

setup() {
	# Source test setup helper using BATS_TEST_DIRNAME
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# gps_cmd_change（change log 测试）所在模块
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
}

@test "gps_write_config creates config with inbounds and outbounds and correct log level" {
	export PORT=43210
	export UUID="test-uuid-1234"
	export PASSWORD="test-pass-1234"
	export LOG_LEVEL="info"

	run gps_write_config
	[ "$status" -eq 0 ]
	[ -f "$GPS_CONFIG" ]
	run grep '"inbounds"' "$GPS_CONFIG"
	[ "$status" -eq 0 ]
	run grep '"outbounds"' "$GPS_CONFIG"
	[ "$status" -eq 0 ]
	run grep '"level"' "$GPS_CONFIG"
	[ "$status" -eq 0 ]
	run grep '"info"' "$GPS_CONFIG"
	[ "$status" -eq 0 ]
	# permissions
	check_perm_600 "$GPS_CONFIG"
}

@test "config escapes quote and backslash in password" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD='quoted"\\password'
	run gps_write_config
	[ "$status" -eq 0 ]
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "gps_tuic_urls prints at least one URL (using PUBLIC_IP fallback)" {
	export PORT=54321
	export UUID="u-1"
	export PASSWORD="p-1"
	export PUBLIC_IP="1.2.3.4"
	export PUBLIC_IP6=""
	export GPS_TEST_PREFIX="$GPS_TEST_PREFIX"

	# ensure state file exists
	run save_state
	[ "$status" -eq 0 ]

	run gps_tuic_urls
	[ "$status" -eq 0 ]
	[[ "$output" =~ "1.2.3.4" ]]
}

@test "bump respects an explicit log level and still upgrades quiet legacy installs" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-1"
	# 旧安装：config=info，无显式标记 → boot 时抬到 debug
	LOG_LEVEL=info
	LOG_LEVEL_EXPLICIT=0
	gps_write_config
	gps_bump_log_level_if_quiet
	grep -q '"level": "debug"' "$GPS_CONFIG"

	# 用户显式设置 warn → boot 不再覆盖
	LOG_LEVEL_EXPLICIT=1
	gps_set_log_level warn
	gps_bump_log_level_if_quiet
	grep -q '"level": "warn"' "$GPS_CONFIG"
}

@test "change log marks the level as explicit and persists it" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-1"
	LOG_LEVEL=debug
	gps_write_config
	save_state
	gps_restart_svc() { :; }
	gps_cmd_url() { :; }
	run gps_cmd_change log warn
	[ "$status" -eq 0 ]
	grep -q '"level": "warn"' "$GPS_CONFIG"
	grep -q '^LOG_LEVEL_EXPLICIT=1$' "$GPS_STATE"
}
