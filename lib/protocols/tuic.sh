#!/bin/bash
# TUIC 入站协议模块（Phase 0 唯一注册协议）

# 生成单个 TUIC inbound JSON 片段（不含尾逗号）；用户可控值一律 JSON 转义
gps_proto_tuic_inbound_json() {
	local tag=$1 listen=$2
	local uuid pw cert key
	uuid=$(gps_json_escape "$UUID")
	pw=$(gps_json_escape "$PASSWORD")
	cert=$(gps_json_escape "$GPS_CERT")
	key=$(gps_json_escape "$GPS_KEY")
	cat <<EOF
    {
      "type": "tuic",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${uuid}",
          "password": "${pw}"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": true,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "certificate_path": "${cert}",
        "key_path": "${key}",
        "alpn": ["h3"]
      }
    }
EOF
}

# 严格校验（install / 未来 change protocol）；write_config 仍只要求非空
gps_proto_tuic_validate() {
	[[ -n ${PORT:-} && -n ${UUID:-} && -n ${PASSWORD:-} ]] || err "PORT/UUID/PASSWORD 未设置"
	gps_validate_port "$PORT" || err "无效端口: $PORT（需 1-65535）"
	gps_validate_uuid "$UUID" || err "无效 UUID: $UUID（示例: $(gen_uuid)）"
	gps_validate_single_line "$PASSWORD" || err "密码不能包含换行/回车/NUL"
	gps_validate_single_line "${TUIC_NAME:-}" || err "节点名不能包含换行/回车/NUL"
}

# 打印一条 TUIC URL；节点名放在 #fragment，不是 query 的 name=；凭证百分号编码
_gps_tuic_one_url() {
	local host=$1
	[[ -n $host ]] || return 1
	local name u pw
	name=$(gps_urlencode "$(gps_tuic_node_name)")
	u=$(gps_urlencode "$UUID")
	pw=$(gps_urlencode "$PASSWORD")
	printf 'tuic://%s:%s@%s:%s/?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr&udp_relay_mode=native#%s\n' \
		"$u" "$pw" "$(host_for_url "$host")" "$PORT" "$name"
}

# 输出所有可用 URL（v4 / v6），自适应；至少一行
gps_tuic_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local printed=0
	local v4=${PUBLIC_IP:-} v6=${PUBLIC_IP6:-}

	if [[ -z $v4 ]]; then
		v4=$(detect_public_ipv4) || true
	fi
	if [[ -z $v6 ]]; then
		v6=$(detect_public_ipv6) || true
	fi

	if [[ -n $v4 ]]; then
		_gps_tuic_one_url "$v4"
		printed=1
	fi
	if [[ -n $v6 ]]; then
		_gps_tuic_one_url "$v6"
		printed=1
	fi
	if ((printed == 0)); then
		warn "未探测到公网 IPv4/IPv6，请: change ip <v4> 和/或 change ip6 <v6>"
		_gps_tuic_one_url "YOUR_PUBLIC_IP"
	fi
}

# 兼容旧调用：优先 v4，否则 v6
gps_tuic_url() {
	local first=""
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		first=$line
		break
	done < <(gps_tuic_urls)
	[[ -n $first ]] || err "无可用 TUIC URL"
	printf '%s\n' "$first"
}

# 注册表接口名（与 gps_tuic_* 等价，供 gps_proto_share_urls 分发）
gps_proto_tuic_share_urls() {
	gps_tuic_urls
}
