#!/bin/bash
# VLESS + Reality 入站

gps_proto_vless_defaults() {
	gps_proto_ensure_uuid
	gps_proto_ensure_reality
	VLESS_FLOW=${VLESS_FLOW:-xtls-rprx-vision}
}

gps_proto_vless_validate() {
	gps_proto_require_port_uuid
	gps_proto_ensure_reality
	case ${VLESS_FLOW:-} in
	'' | xtls-rprx-vision) ;;
	*) err "无效 VLESS_FLOW: ${VLESS_FLOW}（可用: 空 或 xtls-rprx-vision）" ;;
	esac
}

gps_proto_vless_inbound_json() {
	local tag=$1 listen=$2
	local uuid_e flow sni priv sid
	uuid_e=$(gps_json_escape "$UUID")
	flow=$(gps_json_escape "${VLESS_FLOW:-xtls-rprx-vision}")
	sni=$(gps_json_escape "${REALITY_SERVER:-www.microsoft.com}")
	priv=$(gps_json_escape "$REALITY_PRIVATE_KEY")
	sid=$(gps_json_escape "$REALITY_SHORT_ID")
	cat <<EOF
    {
      "type": "vless",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${uuid_e}",
          "flow": "${flow}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${sni}",
            "server_port": 443
          },
          "private_key": "${priv}",
          "short_id": [
            "${sid}"
          ]
        }
      }
    }
EOF
}

gps_proto_vless_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name u sni pbk sid flow
	name=$(gps_urlencode "$(gps_proto_node_name)")
	u=$(gps_urlencode "$UUID")
	sni=$(gps_urlencode "${REALITY_SERVER:-www.microsoft.com}")
	pbk=$(gps_urlencode "${REALITY_PUBLIC_KEY}")
	sid=$(gps_urlencode "${REALITY_SHORT_ID}")
	flow=$(gps_urlencode "${VLESS_FLOW:-xtls-rprx-vision}")
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
			"$u" "$(host_for_url "$host")" "$PORT" "$flow" "$sni" "$pbk" "$sid" "$name"
	done < <(gps_proto_each_public_host)
}
