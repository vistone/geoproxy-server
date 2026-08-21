#!/bin/bash
# Snell 入站

gps_proto_snell_defaults() {
	gps_proto_ensure_password
	SNELL_VERSION=${SNELL_VERSION:-4}
}

gps_proto_snell_validate() {
	gps_proto_require_port_password
	case ${SNELL_VERSION:-4} in
	1 | 2 | 3 | 4) ;;
	*) err "SNELL_VERSION 须为 1-4" ;;
	esac
}

gps_proto_snell_inbound_json() {
	local tag=$1 listen=$2
	local pw ver
	pw=$(gps_json_escape "$PASSWORD")
	ver=${SNELL_VERSION:-4}
	cat <<EOF
    {
      "type": "snell",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "geoproxy",
          "auth": "${pw}"
        }
      ],
      "version": ${ver}
    }
EOF
}

gps_proto_snell_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name pw ver
	name=$(gps_urlencode "$(gps_proto_node_name)")
	pw=$(gps_urlencode "$PASSWORD")
	ver=${SNELL_VERSION:-4}
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		printf 'snell://%s@%s:%s?version=%s#%s\n' \
			"$pw" "$(host_for_url "$host")" "$PORT" "$ver" "$name"
	done < <(gps_proto_each_public_host)
}
