#!/usr/bin/env bats

setup() {
	export GPS_TEST_PREFIX="$BATS_TEST_DIRNAME/tmp-systemd-$$"
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh"
	_GPS_PREFIX=$GPS_TEST_PREFIX
	# _setup.bash 会覆盖 teardown；必须在 source 之后重设，避免测完误删空前缀
	teardown() { rm -rf "$_GPS_PREFIX"; }
}

@test "tuic unit template lets ExecStartPre run unsandboxed but not ignore failure" {
	local tpl="$REPO_ROOT/templates/geoproxy-tuic.service"
	# '+'：mesh ensure 需要写日志目录 / 放行防火墙，不能套主进程沙箱
	grep -qE '^ExecStartPre=\+__BIN__ mesh ensure$' "$tpl"
	# 不得用 '-' 忽略 ensure 失败（启动必须初始化组网）
	! grep -qE 'ExecStartPre=-' "$tpl"
}

@test "tuic unit template lets WireGuard/TUN work under sandbox" {
	local tpl="$REPO_ROOT/templates/geoproxy-tuic.service"
	# Go/sing-box 列举网卡与 WG 需要 netlink；仅 AF_INET 会让 run 立刻失败而 check 仍过
	grep -qE '^RestrictAddressFamilies=.*AF_NETLINK' "$tpl"
	# userspace WG 在无 gVisor 时强制系统 TUN；PrivateDevices 必须放行 /dev/net/tun
	grep -qE '^DeviceAllow=/dev/net/tun' "$tpl"
	grep -qE '^AmbientCapabilities=.*CAP_NET_ADMIN' "$tpl"
	grep -qE '^CapabilityBoundingSet=.*CAP_NET_ADMIN' "$tpl"
}

@test "tuic unit template ReadWritePaths includes etc, log dir and /run" {
	grep -qE '^ReadWritePaths=__ETC_DIR__ __LOG_DIR__ /run$' "$REPO_ROOT/templates/geoproxy-tuic.service"
}

@test "tuic unit template sends stdout/stderr to journal not a log file" {
	local tpl="$REPO_ROOT/templates/geoproxy-tuic.service"
	grep -qE '^StandardOutput=journal$' "$tpl"
	grep -qE '^StandardError=journal$' "$tpl"
	! grep -qE '^Standard(Output|Error)=append:' "$tpl"
}

@test "gps_install_unit renders ExecStartPre plus sandbox paths and capabilities" {
	GPS_NO_SYSTEMD=0
	need_systemd() { :; }
	gps_install_traffic_timer() { :; }
	gps_install_mesh_units() { :; }
	gps_install_logrotate() { :; }
	gps_install_unit
	grep -F "ExecStartPre=+${GPS_BIN_LINK} mesh ensure" "$GPS_UNIT_PATH"
	grep -F "ReadWritePaths=${GPS_ETC} ${GPS_LOG_DIR} /run" "$GPS_UNIT_PATH"
	grep -qE '^DeviceAllow=/dev/net/tun' "$GPS_UNIT_PATH"
	grep -qE 'CAP_NET_ADMIN' "$GPS_UNIT_PATH"
	grep -qE 'AF_NETLINK' "$GPS_UNIT_PATH"
	grep -qE '^StandardOutput=journal$' "$GPS_UNIT_PATH"
}

@test "gps_svc_dump_failure prints systemctl status and journalctl" {
	have_cmd() { [[ $1 == systemctl || $1 == journalctl ]]; }
	systemctl() {
		echo "Active: failed (Result: exit-code)"
		echo "ExecStartPre: mesh ensure (code=exited, status=1/FAILURE)"
		return 3
	}
	journalctl() {
		echo "mesh ensure: mkdir /var/log/geoproxy-server: Permission denied"
	}
	run gps_svc_dump_failure
	[ "$status" -eq 0 ]
	[[ "$output" == *"Active: failed"* ]]
	[[ "$output" == *"Permission denied"* ]]
	[[ "$output" == *"journalctl"* ]]
}

@test "gps_svc_dump_failure cats sing-box log file even when journalctl exists" {
	have_cmd() { [[ $1 == systemctl || $1 == journalctl ]]; }
	mkdir -p "$GPS_LOG_DIR"
	printf '%s\n' 'FATAL[0000] create WireGuard device: open /dev/net/tun: no such file or directory' >"$GPS_LOG"
	systemctl() {
		echo "Main process exited, code=exited, status=1/FAILURE"
		return 3
	}
	journalctl() {
		echo "systemd: Main process exited, code=exited, status=1/FAILURE"
	}
	run gps_svc_dump_failure
	[ "$status" -eq 0 ]
	[[ "$output" == *"create WireGuard device"* ]]
	[[ "$output" == *"/dev/net/tun"* ]]
}

@test "gps_svc start dumps journal when systemctl fails" {
	GPS_TEST_PREFIX=
	GPS_NO_SYSTEMD=0
	need_systemd() { :; }
	load_state() { :; }
	gps_assert_not_tripped() { :; }
	have_cmd() { [[ $1 == systemctl || $1 == journalctl ]]; }
	systemctl() {
		if [[ $1 == start || $1 == restart ]]; then
			echo "Job for geoproxy-tuic.service failed because the control process exited with error code." >&2
			return 1
		fi
		if [[ $1 == status ]]; then
			echo "Active: failed (Result: exit-code)"
			echo "Process: ExecStartPre (code=exited, status=1/FAILURE)"
			return 3
		fi
		return 0
	}
	journalctl() {
		echo "journal: mesh ensure exited 1"
	}
	run gps_svc start
	[ "$status" -ne 0 ]
	[[ "$output" == *"Active: failed"* ]]
	[[ "$output" == *"journal: mesh ensure exited 1"* ]]
}

@test "menu 12 start/stop/restart uses boot halt restart_svc" {
	grep -qE '^[[:space:]]*start\) gps_svc_boot' "$REPO_ROOT/lib/menu.sh"
	grep -qE '^[[:space:]]*stop\) gps_svc_halt' "$REPO_ROOT/lib/menu.sh"
	grep -qE '^[[:space:]]*restart\) gps_restart_svc' "$REPO_ROOT/lib/menu.sh"
	! grep -qE 'start \| stop \| restart\) gps_svc "\$a"' "$REPO_ROOT/lib/menu.sh"
}

@test "menu exposes agent status/token viewer (29)" {
	# 菜单必须有 Agent 查看入口，且调用 gps_cmd_agent（用户无需再手动运行 agent token）
	grep -qE '29\)' "$REPO_ROOT/lib/menu.sh"
	grep -qE '29\).*[Aa]gent' "$REPO_ROOT/lib/menu.sh"
	grep -qE 'gps_cmd_agent' "$REPO_ROOT/lib/menu.sh"
	# 29 分支必须直接展示完整 Token（不经过打码+交互询问）
	grep -qE 'gps_cmd_agent token' "$REPO_ROOT/lib/menu.sh"
}

@test "mesh-sync unit can write /etc/geoproxy-server even under ProtectSystem" {
	local tpl="$REPO_ROOT/templates/geoproxy-mesh-sync.service"
	grep -qE '^ExecStart=\+__BIN__ mesh sync-master$' "$tpl"
	grep -qE '^ProtectSystem=strict$' "$tpl"
	grep -qE '^ReadWritePaths=__ETC_DIR__' "$tpl"
}

@test "gps_install_mesh_units_files_only renders mesh-sync write paths" {
	export MESH_CLUSTER_TOKEN="sync-token-0123456789"
	gps_mesh_defaults
	gps_mesh_ensure_dirs
	gps_install_mesh_units_files_only
	grep -F "ExecStart=+${GPS_BIN_LINK} mesh sync-master" "$GPS_MESH_SYNC_UNIT_PATH"
	grep -qE '^ProtectSystem=strict$' "$GPS_MESH_SYNC_UNIT_PATH"
	grep -F "ReadWritePaths=${GPS_ETC}" "$GPS_MESH_SYNC_UNIT_PATH"
}

@test "gps_install_mesh_units restarts mesh-master not only enable --now" {
	export MESH_ROLE=master
	export MESH_CLUSTER_TOKEN="restart-token-0123456789"
	gps_mesh_defaults
	gps_mesh_ensure_dirs
	local log="$GPS_TEST_PREFIX/systemctl-mesh.log"
	: >"$log"
	need_systemd() { :; }
	systemctl() {
		printf '%s\n' "$*" >>"$log"
		return 0
	}
	# 路径仍指向测试前缀；清空 GPS_TEST_PREFIX 仅用于走生产 enable/restart 分支
	local saved_prefix=$GPS_TEST_PREFIX
	GPS_TEST_PREFIX=
	GPS_NO_SYSTEMD=0
	gps_install_mesh_units
	GPS_TEST_PREFIX=$saved_prefix
	grep -E 'enable' "$log"
	# 升级后必须 restart，否则旧明文进程继续占端口
	grep -E 'restart.*(geoproxy-mesh-master|'"$GPS_MESH_MASTER_SERVICE"')' "$log"
}
