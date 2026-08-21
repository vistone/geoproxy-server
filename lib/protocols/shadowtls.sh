#!/bin/bash
# ShadowTLS v3 外层 + 本机 Shadowsocks 内层（detour）

gps_proto_shadowtls_defaults() {
	gps_proto_ensure_password
	gps_proto_ensure_ss_password
	SHADOWTLS_VERSION=${SHADOWTLS_VERSION:-3}
	SHADOWTLS_HANDSHAKE=${SHADOWTLS_HANDSHAKE:-www.microsoft.com}
	# 内层 SS 固定本机端口，避免与公网 PORT 冲突
	if [[ -z ${SHADOWTLS_INNER_PORT:-} ]]; then
		SHADOWTLS_INNER_PORT=$((PORT % 30000 + 35000))
		# 与公网端口相同则偏移
		if [[ $SHADOWTLS_INNER_PORT -eq $PORT ]]; then
			SHADOWTLS_INNER_PORT=$((PORT + 1))
		fi
	fi
}

gps_proto_shadowtls_validate() {
	gps_proto_require_port_password
	gps_proto_ensure_ss_password
	case ${SHADOWTLS_VERSION:-3} in
	3) ;;
	*) err "本产品 ShadowTLS 仅支持 version=3（当前: ${SHADOWTLS_VERSION}）" ;;
	esac
	[[ -n ${SHADOWTLS_HANDSHAKE:-} ]] || err "SHADOWTLS_HANDSHAKE 未设置"
	gps_validate_single_line "$SHADOWTLS_HANDSHAKE" || err "SHADOWTLS_HANDSHAKE 非法"
	gps_validate_port "${SHADOWTLS_INNER_PORT}" || err "无效 SHADOWTLS_INNER_PORT"
}

# 外层 ShadowTLS（公网 listen）
gps_proto_shadowtls_inbound_json() {
	local tag=$1 listen=$2
	local pw hs
	pw=$(gps_json_escape "$PASSWORD")
	hs=$(gps_json_escape "${SHADOWTLS_HANDSHAKE:-www.microsoft.com}")
	cat <<EOF
    {
      "type": "shadowtls",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "version": 3,
      "users": [
        {
          "name": "geoproxy",
          "password": "${pw}"
        }
      ],
      "handshake": {
        "server": "${hs}",
        "server_port": 443
      },
      "strict_mode": true,
      "detour": "ss-inner"
    }
EOF
}

# 内层 SS：只生成一次（由 registry extra_inbounds 调用）
gps_proto_shadowtls_extra_inbounds() {
	local method pw
	method=$(gps_json_escape "${SS_METHOD:-2022-blake3-aes-128-gcm}")
	pw=$(gps_json_escape "$SS_PASSWORD")
	cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "ss-inner",
      "listen": "127.0.0.1",
      "listen_port": ${SHADOWTLS_INNER_PORT},
      "method": "${method}",
      "password": "${pw}"
    }
EOF
}

gps_proto_shadowtls_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name
	name=$(gps_urlencode "$(gps_proto_node_name)")
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'export:shadowtls host=%s port=%s password=%s handshake=%s version=3 detour=ss method=%s ss_password=%s#%s\n' \
			"$(host_for_url "$host")" "$PORT" "$(gps_urlencode "$PASSWORD")" \
			"$(gps_urlencode "${SHADOWTLS_HANDSHAKE}")" \
			"$(gps_urlencode "${SS_METHOD:-2022-blake3-aes-128-gcm}")" \
			"$(gps_urlencode "$SS_PASSWORD")" "$name"
	done < <(gps_proto_each_public_host)
}
