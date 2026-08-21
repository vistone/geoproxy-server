#!/bin/bash
# Hysteria v1 入站

gps_proto_hysteria_defaults() {
	gps_proto_ensure_password
	HY_UP_MBPS=${HY_UP_MBPS:-100}
	HY_DOWN_MBPS=${HY_DOWN_MBPS:-100}
}

gps_proto_hysteria_validate() {
	gps_proto_require_port_password
	[[ ${HY_UP_MBPS:-} =~ ^[0-9]+$ ]] || err "HY_UP_MBPS 须为非负整数"
	[[ ${HY_DOWN_MBPS:-} =~ ^[0-9]+$ ]] || err "HY_DOWN_MBPS 须为非负整数"
	gps_validate_single_line "${HY_OBFS:-}" || err "HY_OBFS 不能包含换行/回车/NUL"
}

gps_proto_hysteria_inbound_json() {
	local tag=$1 listen=$2
	local pw cert_block obfs_line=""
	pw=$(gps_json_escape "$PASSWORD")
	cert_block=$(gps_proto_tls_cert_fields '["h3"]')
	if [[ -n ${HY_OBFS:-} ]]; then
		obfs_line=$(printf ',\n      "obfs": "%s"' "$(gps_json_escape "$HY_OBFS")")
	fi
	cat <<EOF
    {
      "type": "hysteria",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "up_mbps": ${HY_UP_MBPS},
      "down_mbps": ${HY_DOWN_MBPS},
      "users": [
        {
          "auth_str": "${pw}"
        }
      ]${obfs_line},
      "tls": {
        ${cert_block}
      }
    }
EOF
}

gps_proto_hysteria_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name pw
	name=$(gps_urlencode "$(gps_proto_node_name)")
	pw=$(gps_urlencode "$PASSWORD")
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'hysteria://%s:%s/?auth=%s&insecure=1&upmbps=%s&downmbps=%s#%s\n' \
			"$(host_for_url "$host")" "$PORT" "$pw" "${HY_UP_MBPS}" "${HY_DOWN_MBPS}" "$name"
	done < <(gps_proto_each_public_host)
}
