#!/bin/bash
# Hysteria2 入站

gps_proto_hysteria2_defaults() {
	gps_proto_ensure_password
	HY_UP_MBPS=${HY_UP_MBPS:-}
	HY_DOWN_MBPS=${HY_DOWN_MBPS:-}
}

gps_proto_hysteria2_validate() {
	gps_proto_require_port_password
	if [[ -n ${HY_UP_MBPS:-} ]]; then
		[[ ${HY_UP_MBPS} =~ ^[0-9]+$ ]] || err "HY_UP_MBPS 须为非负整数"
	fi
	if [[ -n ${HY_DOWN_MBPS:-} ]]; then
		[[ ${HY_DOWN_MBPS} =~ ^[0-9]+$ ]] || err "HY_DOWN_MBPS 须为非负整数"
	fi
	gps_validate_single_line "${HY_OBFS:-}" || err "HY_OBFS 不能包含换行/回车/NUL"
}

gps_proto_hysteria2_inbound_json() {
	local tag=$1 listen=$2
	local pw cert_block bandwidth="" obfs_block=""
	pw=$(gps_json_escape "$PASSWORD")
	cert_block=$(gps_proto_tls_cert_fields '["h3"]')
	if [[ -n ${HY_UP_MBPS:-} ]]; then
		bandwidth+=$(printf ',\n      "up_mbps": %s' "$HY_UP_MBPS")
	fi
	if [[ -n ${HY_DOWN_MBPS:-} ]]; then
		bandwidth+=$(printf ',\n      "down_mbps": %s' "$HY_DOWN_MBPS")
	fi
	if [[ -n ${HY_OBFS:-} ]]; then
		obfs_block=$(printf ',\n      "obfs": { "type": "salamander", "password": "%s" }' "$(gps_json_escape "$HY_OBFS")")
	fi
	cat <<EOF
    {
      "type": "hysteria2",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${pw}"
        }
      ]${bandwidth}${obfs_block},
      "tls": {
        ${cert_block}
      }
    }
EOF
}

gps_proto_hysteria2_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name pw obfs_q=""
	name=$(gps_urlencode "$(gps_proto_node_name)")
	pw=$(gps_urlencode "$PASSWORD")
	# URL 必须带上与 inbound 相同的 obfs 参数，否则启用混淆后客户端无法连接
	if [[ -n ${HY_OBFS:-} ]]; then
		obfs_q="&obfs=salamander&obfs-password=$(gps_urlencode "$HY_OBFS")"
	fi
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'hy2://%s@%s:%s/?insecure=1%s#%s\n' \
			"$pw" "$(host_for_url "$host")" "$PORT" "$obfs_q" "$name"
	done < <(gps_proto_each_public_host)
}
