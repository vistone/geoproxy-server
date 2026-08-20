#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
}

@test "install --prefix enables no-systemd mode" {
	# 显式把 GPS_NO_SYSTEMD 置 0：前缀安装必须无条件强制为 1
	export GPS_NO_SYSTEMD=0
	ensure_deps() { :; }
	gps_download_core() { :; }
	rand_port() { printf 23456; }
	gen_uuid() { printf 00000000-0000-4000-8000-000000000000; }
	detect_local_stack() { STACK_MODE=v4only; }
	detect_public_ips() { :; }
	detect_public_ipv4() { :; }
	detect_public_ipv6() { :; }
	gps_write_config() { :; }
	save_state() { :; }
	gps_install_unit() { printf '%s' "$GPS_NO_SYSTEMD"; }
	gps_install_entrypoint() { :; }
	gps_restart_svc() { :; }
	gps_cmd_info() { :; }
	gps_cmd_url() { :; }
	run gps_cmd_install --prefix "$GPS_TEST_PREFIX/prefix"
	[ "$status" -eq 0 ]
	[[ "$output" == *1* ]]
}

@test "logrotate config is rendered for both logs with copytruncate" {
	gps_install_logrotate
	[ -f "$GPS_LOGROTATE_PATH" ]
	grep -q "^${GPS_LOG} {" "$GPS_LOGROTATE_PATH"
	grep -q "^${GPS_TRAFFIC_LOG} {" "$GPS_LOGROTATE_PATH"
	grep -q 'copytruncate' "$GPS_LOGROTATE_PATH"
	grep -q 'compress' "$GPS_LOGROTATE_PATH"
}

@test "missing logrotate is auto-installed and config is still written" {
	# 生产模式（无前缀）+ 无 logrotate：必须尝试自动安装，且配置照写
	GPS_TEST_PREFIX=
	have_cmd() { return 1; }
	ensure_logrotate_called=0
	ensure_logrotate() {
		ensure_logrotate_called=1
		return 0
	}
	gps_install_logrotate
	[ "$ensure_logrotate_called" -eq 1 ]
	[ -f "$GPS_LOGROTATE_PATH" ]
	grep -q 'copytruncate' "$GPS_LOGROTATE_PATH"
}

@test "ensure_logrotate succeeds when present and fails softly without a package manager" {
	have_cmd() { return 0; }
	ensure_logrotate
	have_cmd() { return 1; }
	run ensure_logrotate
	[ "$status" -ne 0 ]
}
