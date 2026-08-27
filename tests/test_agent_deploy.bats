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
	grep -q '^GPS_AGENT_BIND=127.0.0.1' "$GPS_AGENT_ENV"
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
	# agent 是明文 HTTP（非 TLS）：提示必须用 http:// 而非 https://
	grep -q "http://IP:19528" <<<"$out"
	! grep -q "https://IP:19528" <<<"$out"
}

@test "agent 移除函数删除单元文件" {
	gps_install_agent_units_files_only
	[ -f "$GPS_AGENT_UNIT_PATH" ]
	gps_remove_agent_units
	[ ! -f "$GPS_AGENT_UNIT_PATH" ]
}

@test "agent ensure 幂等创建 token 与单元文件（升级路径修复）" {
	# 模拟从旧版（无 agent.env / 无单元）升级后调用 agent ensure
	gps_cmd_agent ensure
	[ -f "$GPS_AGENT_ENV" ]
	check_perm_600 "$GPS_AGENT_ENV"
	grep -q '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV"
	[ -f "$GPS_AGENT_UNIT_PATH" ]
	# 幂等：再次调用不覆盖 token
	local tok
	tok=$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)
	gps_cmd_agent ensure
	[ "$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)" = "$tok" ]
}

@test "agent CLI：token 在凭证缺失时自动 ensure（旧版升级路径）" {
	# 模拟旧版升级后 agent.env 不存在：agent token 应自动创建而非报错
	rm -f "$GPS_AGENT_ENV"
	local tok_from_file
	run gps_cmd_agent token
	[ "$status" -eq 0 ]
	[ -f "$GPS_AGENT_ENV" ]
	grep -q '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV"
	tok_from_file=$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)
	[[ -n $tok_from_file ]]
	[[ "$output" == "$tok_from_file" ]]
	# 幂等：已有 token 不被覆盖
	local before=$tok_from_file
	run gps_cmd_agent token
	[[ "$output" == "$before" ]]
}

@test "change agent-bind updates env and keeps token" {
	export PORT=43901
	export UUID="00000000-0000-4000-8000-000000000901"
	export PASSWORD="agent-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.91"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	save_state
	gps_install_agent_units_files_only
	local tok before
	tok=$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)
	gps_cmd_change agent-bind 0.0.0.0
	grep -q '^GPS_AGENT_BIND=0.0.0.0' "$GPS_AGENT_ENV"
	[ "$(grep '^GPS_AGENT_TOKEN=' "$GPS_AGENT_ENV" | cut -d= -f2)" = "$tok" ]
	gps_cmd_change agent-bind 127.0.0.1
	grep -q '^GPS_AGENT_BIND=127.0.0.1' "$GPS_AGENT_ENV"
}
