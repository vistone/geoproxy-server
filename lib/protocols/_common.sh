#!/bin/bash
# 协议模块共享助手（TLS 片段、公网 host 迭代、凭证生成）

# 节点名：沿用 TUIC_NAME 字段（全协议共用）
gps_proto_node_name() {
	gps_tuic_node_name
}

# 标准自签证书 TLS 对象字段（不含外层花括号），可选 alpn JSON 数组字面量
gps_proto_tls_cert_fields() {
	local alpn_json=${1:-}
	local cert key
	cert=$(gps_json_escape "$GPS_CERT")
	key=$(gps_json_escape "$GPS_KEY")
	printf '"enabled": true,\n'
	printf '        "certificate_path": "%s",\n' "$cert"
	printf '        "key_path": "%s"' "$key"
	if [[ -n $alpn_json ]]; then
		printf ',\n        "alpn": %s' "$alpn_json"
	fi
	printf '\n'
}

# 迭代公网地址：有则打印；皆无则打印 YOUR_PUBLIC_IP 并 warn
gps_proto_each_public_host() {
	local v4=${PUBLIC_IP:-} v6=${PUBLIC_IP6:-} printed=0
	if [[ -z $v4 ]]; then
		v4=$(detect_public_ipv4) || true
	fi
	if [[ -z $v6 ]]; then
		v6=$(detect_public_ipv6) || true
	fi
	if [[ -n $v4 ]]; then
		printf '%s\n' "$v4"
		printed=1
	fi
	if [[ -n $v6 ]]; then
		printf '%s\n' "$v6"
		printed=1
	fi
	if ((printed == 0)); then
		warn "未探测到公网 IPv4/IPv6，请: change ip <v4> 和/或 change ip6 <v6>"
		printf '%s\n' "YOUR_PUBLIC_IP"
	fi
}

gps_proto_require_port_password() {
	[[ -n ${PORT:-} && -n ${PASSWORD:-} ]] || err "PORT/PASSWORD 未设置"
	gps_validate_port "$PORT" || err "无效端口: $PORT（需 1-65535）"
	gps_validate_single_line "$PASSWORD" || err "密码不能包含换行/回车/NUL"
	gps_validate_single_line "${TUIC_NAME:-}" || err "节点名不能包含换行/回车/NUL"
}

gps_proto_require_port_uuid() {
	[[ -n ${PORT:-} && -n ${UUID:-} ]] || err "PORT/UUID 未设置"
	gps_validate_port "$PORT" || err "无效端口: $PORT（需 1-65535）"
	gps_validate_uuid "$UUID" || err "无效 UUID: $UUID（示例: $(gen_uuid)）"
	gps_validate_single_line "${TUIC_NAME:-}" || err "节点名不能包含换行/回车/NUL"
}

gps_proto_ensure_password() {
	if [[ -z ${PASSWORD:-} ]]; then
		PASSWORD=$(gen_uuid)
	fi
}

gps_proto_ensure_uuid() {
	if [[ -z ${UUID:-} ]]; then
		UUID=$(gen_uuid)
	fi
}

# Shadowsocks 2022：16 字节 base64（aes-128-gcm）；可用核心或 openssl
gps_proto_gen_ss2022_password() {
	local n=${1:-16}
	if [[ -x ${GPS_CORE_BIN:-} ]]; then
		"$GPS_CORE_BIN" generate rand --base64 "$n" 2>/dev/null && return 0
	fi
	openssl rand -base64 "$n" 2>/dev/null | tr -d '\n'
}

gps_proto_ensure_ss_password() {
	SS_METHOD=${SS_METHOD:-2022-blake3-aes-128-gcm}
	if [[ -z ${SS_PASSWORD:-} ]]; then
		if [[ $SS_METHOD == 2022-* ]]; then
			SS_PASSWORD=$(gps_proto_gen_ss2022_password 16)
		else
			SS_PASSWORD=${PASSWORD:-$(gen_uuid)}
		fi
	fi
	PASSWORD=${PASSWORD:-$SS_PASSWORD}
}

# Reality 密钥对：PrivateKey: / PublicKey: 行；short_id 8 hex
gps_proto_gen_reality_keypair() {
	if [[ -x ${GPS_CORE_BIN:-} ]]; then
		"$GPS_CORE_BIN" generate reality-keypair 2>/dev/null && return 0
	fi
	# 测试/无核心：占位（非真实 X25519，仅供 JSON 形状测试）
	printf 'PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE\n'
	printf 'PublicKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE\n'
}

gps_proto_ensure_reality() {
	REALITY_SERVER=${REALITY_SERVER:-www.microsoft.com}
	gps_validate_single_line "$REALITY_SERVER" || err "REALITY_SERVER 不能包含换行/回车/NUL"
	if [[ -z ${REALITY_PRIVATE_KEY:-} || -z ${REALITY_PUBLIC_KEY:-} ]]; then
		local out priv pub
		out=$(gps_proto_gen_reality_keypair) || err "生成 Reality 密钥失败"
		priv=$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/{print $2; exit}')
		pub=$(printf '%s\n' "$out" | awk -F': ' '/PublicKey/{print $2; exit}')
		[[ -n $priv && -n $pub ]] || err "解析 Reality 密钥失败"
		REALITY_PRIVATE_KEY=$priv
		REALITY_PUBLIC_KEY=$pub
	fi
	if [[ -z ${REALITY_SHORT_ID:-} ]]; then
		REALITY_SHORT_ID=$(openssl rand -hex 4 2>/dev/null || printf '%s' "abcd1234")
	fi
	gps_validate_single_line "$REALITY_PRIVATE_KEY" || err "REALITY_PRIVATE_KEY 非法"
	gps_validate_single_line "$REALITY_PUBLIC_KEY" || err "REALITY_PUBLIC_KEY 非法"
	[[ ${REALITY_SHORT_ID} =~ ^[0-9a-fA-F]{0,16}$ ]] || err "REALITY_SHORT_ID 须为 ≤16 位十六进制"
}
