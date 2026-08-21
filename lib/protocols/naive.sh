#!/bin/bash
# NaiveProxy 入站（HTTPS）

gps_proto_naive_defaults() {
	gps_proto_ensure_password
	NAIVE_USERNAME=${NAIVE_USERNAME:-geoproxy}
}

gps_proto_naive_validate() {
	gps_proto_require_port_password
	[[ -n ${NAIVE_USERNAME:-} ]] || err "NAIVE_USERNAME 未设置"
	gps_validate_single_line "$NAIVE_USERNAME" || err "NAIVE_USERNAME 不能包含换行/回车/NUL"
}

gps_proto_naive_inbound_json() {
	local tag=$1 listen=$2
	local user pw cert_block
	user=$(gps_json_escape "${NAIVE_USERNAME:-geoproxy}")
	pw=$(gps_json_escape "$PASSWORD")
	cert_block=$(gps_proto_tls_cert_fields)
	cat <<EOF
    {
      "type": "naive",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "username": "${user}",
          "password": "${pw}"
        }
      ],
      "tls": {
        ${cert_block}
      }
    }
EOF
}

gps_proto_naive_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name user pw
	name=$(gps_urlencode "$(gps_proto_node_name)")
	user=$(gps_urlencode "${NAIVE_USERNAME:-geoproxy}")
	pw=$(gps_urlencode "$PASSWORD")
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'naive+https://%s:%s@%s:%s#%s\n' \
			"$user" "$pw" "$(host_for_url "$host")" "$PORT" "$name"
	done < <(gps_proto_each_public_host)
}
