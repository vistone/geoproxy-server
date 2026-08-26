#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/traffic.sh  # gps_mask_key（agent status 脱敏显示）
	source "$REPO_ROOT/lib/traffic.sh"
	gps_restart_svc() { :; }
	gps_fw_allow_tcp() {
		GPS_FW_CALLS+=("$1:$2")
		return 0
	}
	GPS_FW_CALLS=()
	teardown() {
		rm -rf "$GPS_TEST_PREFIX"
	}
}

@test "agent 单元文件生成且含正确替换；token 0600" {
	gps_install_agent_units_files_only
	[ -f "$GPS_AGENT_UNIT_PATH" ]
	grep -q "Description=GeoProxy agent" "$GPS_AGENT_UNIT_PATH"
	grep -q "geoagent.py" "$GPS_AGENT_UNIT_PATH"
	# 不再有 '+' 前缀：否则 systemd 整体跳过沙箱硬化（ProtectSystem/PrivateTmp/NoNewPrivileges 等全部失效）
	! grep -q "ExecStart=+" "$GPS_AGENT_UNIT_PATH"
	grep -q "ExecStart=/usr/bin/env python3" "$GPS_AGENT_UNIT_PATH"
	grep -q "GPS_AGENT_TOKEN" "$GPS_AGENT_ENV"
	grep -q "GPS_AGENT_PORT" "$GPS_AGENT_ENV"
	check_perm_600 "$GPS_AGENT_ENV"
	# 二次调用不覆盖既有 token
	local tok
	tok=$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)
	gps_install_agent_units_files_only
	[ "$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)" = "$tok" ]
}

@test "agent CLI：status 与 token 输出" {
	gps_install_agent_units_files_only
	# 加载 agent.env 后 token 可见（脱敏/明文）
	gps_source_env "$GPS_AGENT_ENV"
	local t
	t=$(gps_cmd_agent token)
	[ "$t" = "$GPS_AGENT_TOKEN" ]
	# grep -q 提前关管道会与上游写端竞态（pipefail 下 SIGPIPE 141），先捕获再断言
	local out
	out=$(gps_cmd_agent status)
	grep -q "Token:" <<<"$out"
	grep -q "19528" <<<"$out"
}

@test "agent 移除函数删除单元文件" {
	gps_install_agent_units_files_only
	[ -f "$GPS_AGENT_UNIT_PATH" ]
	gps_remove_agent_units
	[ ! -f "$GPS_AGENT_UNIT_PATH" ]
}
