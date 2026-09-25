#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/download.sh
	source "$REPO_ROOT/lib/download.sh"
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
	gps_mesh_ensure_boot() { :; }
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

@test "reinstall after-self-update skips confirm and fetch" {
	export PORT=43111
	export UUID="00000000-0000-4000-8000-000000000211"
	export PASSWORD="u-pass"
	export PROTOCOL=tuic
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	mkdir -p "$GPS_ETC"
	# 最小合法 state（load_state 能读即可）
	PORT=43111 UUID=00000000-0000-4000-8000-000000000211 PASSWORD=u-pass PROTOCOL=tuic \
		INSTALLED_AT=2026-01-01T00:00:00Z LOG_LEVEL=warn STACK_MODE=v4only \
		save_state
	local side="$GPS_TEST_PREFIX/reinstall-side.log"
	: >"$side"
	gps_reinstall_fetch_self() { echo fetch >>"$side"; }
	confirm_yes() {
		echo confirm >>"$side"
		return 0
	}
	ensure_deps() { :; }
	gps_download_core() { :; }
	gps_protocol_normalize() { :; }
	gps_protocol_defaults() { :; }
	gps_protocol_validate() { :; }
	gps_mesh_bootstrap_from_env() { :; }
	gps_mesh_ensure_boot() { :; }
	gps_validate_port() { return 0; }
	gps_validate_uuid() { return 0; }
	gps_validate_single_line() { return 0; }
	save_state() { :; }
	gps_install_unit() { :; }
	gps_install_entrypoint() { :; }
	gps_restart_svc() { :; }
	gps_cmd_info() { :; }
	gps_cmd_url() { :; }
	detect_public_ips() { :; }
	detect_public_ipv4() { :; }
	detect_public_ipv6() { :; }
	# 同 shell 调用，函数 mock 与 side 文件才生效
	local out
	out=$(gps_cmd_install --after-self-update 2>&1)
	[[ ! -s $side ]]
	[[ "$out" == *"已切换到新脚本"* || "$out" == *"继续安装"* ]]
}

@test "uninstall removes prefix tree, entrypoint and logrotate config" {
	export PORT=43110
	export UUID="00000000-0000-4000-8000-000000000210"
	export PASSWORD="u-pass"
	export PROTOCOL=tuic
	detect_local_stack() { STACK_MODE=v4only; }
	gps_write_config
	save_state
	gps_install_logrotate
	gps_install_mesh_units_files_only
	[ -f "$GPS_LOGROTATE_PATH" ]
	[ -f "$GPS_MESH_MASTER_UNIT_PATH" ]
	run gps_cmd_uninstall -y
	[ "$status" -eq 0 ]
	[ ! -e "$GPS_TEST_PREFIX" ]
}
