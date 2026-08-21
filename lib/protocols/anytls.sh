#!/bin/bash
# AnyTLS 入站

gps_proto_anytls_defaults() {
	gps_proto_ensure_password
}

gps_proto_anytls_validate() {
	gps_proto_require_port_password
}

gps_proto_anytls_inbound_json() {
	local tag=$1 listen=$2
	local pw cert_block
	pw=$(gps_json_escape "$PASSWORD")
	cert_block=$(gps_proto_tls_cert_fields)
	cat <<EOF
    {
      "type": "anytls",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${pw}"
        }
      ],
      "tls": {
        ${cert_block}
      }
    }
EOF
}

gps_proto_anytls_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name pw
	name=$(gps_urlencode "$(gps_proto_node_name)")
	pw=$(gps_urlencode "$PASSWORD")
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		# 尚无统一官方 scheme：export 行 + 兼容 anytls:// 尝试
		printf 'anytls://%s@%s:%s/?insecure=1#%s\n' \
			"$pw" "$(host_for_url "$host")" "$PORT" "$name"
	done < <(gps_proto_each_public_host)
}
