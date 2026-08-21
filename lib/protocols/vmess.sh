#!/bin/bash
# VMess 入站（自签 TLS）

gps_proto_vmess_defaults() {
	gps_proto_ensure_uuid
}

gps_proto_vmess_validate() {
	gps_proto_require_port_uuid
}

gps_proto_vmess_inbound_json() {
	local tag=$1 listen=$2
	local uuid_e cert_block
	uuid_e=$(gps_json_escape "$UUID")
	cert_block=$(gps_proto_tls_cert_fields)
	cat <<EOF
    {
      "type": "vmess",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${uuid_e}",
          "alterId": 0
        }
      ],
      "tls": {
        ${cert_block}
      }
    }
EOF
}

gps_proto_vmess_share_urls() {
	load_state || err "未安装或缺少 state.env（请先 install）"
	local host name uuid_v b64
	name=$(gps_proto_node_name)
	uuid_v=$UUID
	while IFS= read -r host; do
		[[ -n $host ]] || continue
		# v2rayN 风格 vmess://base64(json)
		if have_cmd python3; then
			b64=$(
				NODE_NAME="$name" UUID="$uuid_v" HOST="$host" PORT="$PORT" python3 - <<'PY'
import base64, json, os
cfg = {
  "v": "2",
  "ps": os.environ["NODE_NAME"],
  "add": os.environ["HOST"],
  "port": str(os.environ["PORT"]),
  "id": os.environ["UUID"],
  "aid": "0",
  "scy": "auto",
  "net": "tcp",
  "type": "none",
  "tls": "tls",
  "allowInsecure": 1,
}
print(base64.b64encode(json.dumps(cfg, ensure_ascii=False).encode()).decode())
PY
			)
		else
			warn "生成 vmess:// 需要 python3；改为 export 行"
			printf 'export:vmess uuid=%s host=%s port=%s tls=1 insecure=1 name=%s\n' \
				"$uuid_v" "$(host_for_url "$host")" "$PORT" "$(gps_urlencode "$name")"
			continue
		fi
		printf 'vmess://%s\n' "$b64"
	done < <(gps_proto_each_public_host)
}
