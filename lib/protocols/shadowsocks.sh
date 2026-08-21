#!/bin/bash
# Shadowsocks 入站（默认 2022-blake3-aes-128-gcm）

gps_proto_shadowsocks_defaults() {
	gps_proto_ensure_ss_password
}

gps_proto_shadowsocks_validate() {
	[[ -n ${PORT:-} ]] || err "PORT 未设置"
	gps_validate_port "$PORT" || err "无效端口: $PORT（需 1-65535）"
	SS_METHOD=${SS_METHOD:-2022-blake3-aes-128-gcm}
	[[ -n ${SS_PASSWORD:-} ]] || err "SS_PASSWORD 未设置"
	gps_validate_single_line "$SS_METHOD" || err "SS_METHOD 非法"
	gps_validate_single_line "$SS_PASSWORD" || err "SS_PASSWORD 不能包含换行/回车/NUL"
	gps_validate_single_line "${TUIC_NAME:-}" || err "节点名不能包含换行/回车/NUL"
	case $SS_METHOD in
	2022-blake3-aes-128-gcm | 2022-blake3-aes-256-gcm | 2022-blake3-chacha20-poly1305 | \
		aes-128-gcm | aes-192-gcm | aes-256-gcm | chacha20-ietf-poly1305 | xchacha20-ietf-poly1305 | none) ;;
	*) err "不支持的 SS_METHOD: $SS_METHOD" ;;
	esac
}

gps_proto_shadowsocks_inbound_json() {
	local tag=$1 listen=$2
	local method pw
	method=$(gps_json_escape "${SS_METHOD:-2022-blake3-aes-128-gcm}")
	pw=$(gps_json_escape "$SS_PASSWORD")
	cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "method": "${method}",
      "password": "${pw}"
    }
EOF
}

gps_proto_shadowsocks_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name method pw b64
	name=$(gps_urlencode "$(gps_proto_node_name)")
	method=${SS_METHOD:-2022-blake3-aes-128-gcm}
	pw=$SS_PASSWORD
	# SIP002: ss://base64(method:password)@host:port#name
	if have_cmd python3; then
		b64=$(python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))' "${method}:${pw}")
	else
		b64=$(printf '%s' "${method}:${pw}" | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')
	fi
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'ss://%s@%s:%s#%s\n' "$b64" "$(host_for_url "$host")" "$PORT" "$name"
	done < <(gps_proto_each_public_host)
}
