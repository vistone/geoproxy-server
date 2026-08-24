#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	gps_restart_svc() { :; }
}

@test "legacy state without PROTOCOL loads as tuic" {
	export PORT=12345
	export UUID="00000000-0000-4000-8000-000000000000"
	export PASSWORD="pass-1"
	unset PROTOCOL || true
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
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "tuic"' "$GPS_CONFIG"
	grep -q 'tuic-in-v4' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "phase1 protocol list includes hy2 vless trojan ss" {
	run gps_protocol_list
	[ "$status" -eq 0 ]
	[[ "$output" == *tuic* ]]
	[[ "$output" == *hysteria2* ]]
	[[ "$output" == *vless* ]]
	[[ "$output" == *trojan* ]]
	[[ "$output" == *shadowsocks* ]]
}

@test "phase2 protocol list includes vmess anytls hysteria naive snell shadowtls" {
	run gps_protocol_list
	[ "$status" -eq 0 ]
	for id in vmess anytls hysteria naive snell shadowtls; do
		[[ "$output" == *"$id"* ]]
	done
}

@test "vmess anytls hysteria naive snell configs render" {
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	export PORT=42001 UUID="00000000-0000-4000-8000-000000000010" PASSWORD="p2-pass"

	for proto in vmess anytls hysteria naive snell; do
		export PROTOCOL=$proto
		gps_protocol_defaults
		gps_protocol_validate
		run gps_write_config
		[ "$status" -eq 0 ]
		grep -q "\"type\": \"$proto\"" "$GPS_CONFIG"
		run python3 -m json.tool "$GPS_CONFIG"
		[ "$status" -eq 0 ]
	done
}

@test "shadowtls emits outer shadowtls and inner shadowsocks" {
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	export PORT=42002 PASSWORD="st-pass" PROTOCOL=shadowtls
	gps_protocol_defaults
	gps_protocol_validate
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "shadowtls"' "$GPS_CONFIG"
	grep -q '"tag": "ss-inner"' "$GPS_CONFIG"
	grep -q '"detour": "ss-inner"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "gps_proto_tuic_validate rejects bad uuid" {
	PORT=12345
	UUID=not-a-uuid
	PASSWORD=pass
	run gps_proto_tuic_validate
	[ "$status" -ne 0 ]
}

@test "hysteria2 config renders and shares hy2 URL" {
	export PORT=41234
	export PASSWORD="hy2-secret"
	export PROTOCOL=hysteria2
	export PUBLIC_IP="1.2.3.4"
	export PUBLIC_IP6=""
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_protocol_defaults
	gps_protocol_validate
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "hysteria2"' "$GPS_CONFIG"
	save_state
	run gps_proto_share_urls
	[ "$status" -eq 0 ]
	[[ "$output" == hy2://* ]]
}

@test "vless reality config renders" {
	export PORT=41235
	export UUID="00000000-0000-4000-8000-000000000001"
	export PROTOCOL=vless
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_protocol_defaults
	gps_protocol_validate
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "vless"' "$GPS_CONFIG"
	grep -q '"reality"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "trojan and shadowsocks configs render" {
	export PORT=41236
	export PASSWORD="trojan-pass"
	export PROTOCOL=trojan
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_protocol_defaults
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "trojan"' "$GPS_CONFIG"

	export PROTOCOL=shadowsocks
	gps_protocol_defaults
	gps_protocol_validate
	run gps_write_config
	[ "$status" -eq 0 ]
	grep -q '"type": "shadowsocks"' "$GPS_CONFIG"
	grep -q '2022-blake3-aes-128-gcm' "$GPS_CONFIG"
}

@test "change protocol switches inbound type" {
	export PORT=41237
	export UUID="00000000-0000-4000-8000-000000000002"
	export PASSWORD="switch-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="8.8.8.8"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_write_config
	save_state
	gps_cmd_url() { :; }
	run gps_cmd_change protocol hysteria2
	[ "$status" -eq 0 ]
	grep -q '^PROTOCOL=hysteria2$' "$GPS_STATE"
	grep -q '"type": "hysteria2"' "$GPS_CONFIG"
}

@test "reality keypair generation fails hard without sing-box core" {
	GPS_CORE_BIN=/nonexistent/sing-box
	unset REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY || true
	run gps_proto_ensure_reality
	[ "$status" -ne 0 ]
	[[ "$output" == *"生成 Reality 密钥失败"* ]]
}

@test "ss2022 key length follows method" {
	unset SS_PASSWORD
	SS_METHOD=2022-blake3-aes-256-gcm gps_proto_ensure_ss_password
	n=$(printf '%s' "$SS_PASSWORD" | base64 -d 2>/dev/null | wc -c)
	[ "$n" -eq 32 ]
	unset SS_PASSWORD
	SS_METHOD=2022-blake3-aes-128-gcm gps_proto_ensure_ss_password
	n=$(printf '%s' "$SS_PASSWORD" | base64 -d 2>/dev/null | wc -c)
	[ "$n" -eq 16 ]
}

@test "hy2 share url carries obfs password when enabled" {
	export PORT=41238
	export PASSWORD="hy2-obfs-pass"
	export PROTOCOL=hysteria2
	export PUBLIC_IP="1.2.3.4"
	export PUBLIC_IP6=""
	export HY_OBFS="obfs-sec"
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_protocol_defaults
	gps_protocol_validate
	save_state
	run gps_proto_share_urls
	[ "$status" -eq 0 ]
	[[ "$output" == *"obfs=salamander&obfs-password=obfs-sec"* ]]
}
