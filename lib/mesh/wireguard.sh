#!/bin/bash
# WireGuard endpoint 密钥与 JSON 渲染

gps_mesh_gen_wg_keypair() {
	# 密钥必须由核心真实生成；核心缺失/失败一律报错，绝不回落到占位密钥
	[[ -x ${GPS_CORE_BIN:-} ]] || return 1
	"$GPS_CORE_BIN" generate wg-keypair 2>/dev/null
}

gps_mesh_ensure_wg_keys() {
	if [[ -z ${WG_PRIVATE_KEY:-} || -z ${WG_PUBLIC_KEY:-} ]]; then
		local out priv pub
		out=$(gps_mesh_gen_wg_keypair) || err "生成 WireGuard 密钥失败（需要已安装的 sing-box 核心: ${GPS_CORE_BIN:-?}）"
		priv=$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/{print $2; exit}' | tr -d '[:space:]')
		pub=$(printf '%s\n' "$out" | awk -F': ' '/PublicKey/{print $2; exit}' | tr -d '[:space:]')
		[[ -n $priv && -n $pub ]] || err "解析 WireGuard 密钥失败"
		WG_PRIVATE_KEY=$priv
		WG_PUBLIC_KEY=$pub
	fi
	gps_validate_single_line "$WG_PRIVATE_KEY" || err "WG_PRIVATE_KEY 非法"
	gps_validate_single_line "$WG_PUBLIC_KEY" || err "WG_PUBLIC_KEY 非法"
}

gps_mesh_ensure_overlay_ip() {
	gps_mesh_defaults
	if [[ -z ${MESH_OVERLAY_IP:-} ]]; then
		# 从 NODE_ID 哈希出 2..254，避免 .0/.1 广播语义混淆；.1 保留给首节点手工指定
		local h n
		h=$(printf '%s' "${NODE_ID:-node}" | cksum 2>/dev/null | awk '{print $1}')
		n=$((h % 253 + 2))
		MESH_OVERLAY_IP="10.66.0.${n}"
	fi
	# 存主机地址；配置里写成 /32
	MESH_OVERLAY_IP=${MESH_OVERLAY_IP%%/*}
	gps_validate_ipv4 "$MESH_OVERLAY_IP" || err "无效 MESH_OVERLAY_IP: $MESH_OVERLAY_IP"
}

# 渲染 endpoints 数组内容；组网始终启用
gps_mesh_endpoints_json() {
	gps_profile_normalize
	gps_mesh_ensure_node_id
	gps_mesh_ensure_wg_keys
	gps_mesh_ensure_overlay_ip
	gps_mesh_defaults

	local priv addr peers_json
	priv=$(gps_json_escape "$WG_PRIVATE_KEY")
	addr=$(gps_json_escape "${MESH_OVERLAY_IP}/32")
	peers_json=$(gps_mesh_peers_endpoint_json)
	cat <<EOF
    {
      "type": "wireguard",
      "tag": "wg-ep",
      "system": false,
      "mtu": 1408,
      "address": ["${addr}"],
      "private_key": "${priv}",
      "listen_port": ${WG_LISTEN_PORT},
      "peers": [
${peers_json}
      ]
    }
EOF
}

# 从 peers.json 生成 peers 数组元素（逗号分隔）；无文件则空
gps_mesh_peers_endpoint_json() {
	gps_mesh_ensure_dirs
	if [[ ! -f ${GPS_MESH_PEERS:-} ]]; then
		return 0
	fi
	have_cmd python3 || err "mesh peers 渲染需要 python3"
	NODE_ID="${NODE_ID:-}" MESH_EXIT_NODE_ID="${MESH_EXIT_NODE_ID:-}" \
		MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" \
		MESH_WG_LIVE_ONLY="${MESH_WG_LIVE_ONLY:-1}" \
		python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
self_id = os.environ.get("NODE_ID") or ""
exit_id = os.environ.get("MESH_EXIT_NODE_ID") or ""
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
live_only = (os.environ.get("MESH_WG_LIVE_ONLY") or "1") != "0"
now = datetime.now(timezone.utc)

def alive(n):
    ls = n.get("last_seen") or ""
    if not ls:
        return True  # 手工 peer / 旧条目：无心跳字段仍纳入 WG
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return False
    return (now - ts).total_seconds() <= stale

with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
nodes = doc.get("nodes") or []
parts = []
default_count = 0
for n in nodes:
    nid = n.get("node_id") or ""
    if not nid or nid == self_id:
        continue
    # 熔断节点（TRAFFIC_TRIPPED=1）不加入 WG 组网：服务已停，握手只会徒劳重试
    if int(n.get("tripped") or 0):
        continue
    if live_only and not alive(n):
        continue
    pk = n.get("public_key") or ""
    if not pk:
        continue
    overlay = (n.get("overlay_ip") or "").split("/")[0]
    if not overlay:
        continue
    endpoint = n.get("endpoint") or ""
    keepalive = int(n.get("keepalive") or 25)
    allowed = [overlay + "/32"]
    if exit_id and nid == exit_id:
        if default_count:
            raise SystemExit("anti-loop: multiple default-route peers")
        allowed.extend(["0.0.0.0/0", "::/0"])
        default_count += 1
    ep_host, ep_port = "", 0
    if endpoint:
        if endpoint.startswith("["):
            br = endpoint.rfind("]")
            ep_host = endpoint[1:br]
            ep_port = int(endpoint[br+2:])
        else:
            host, _, port = endpoint.rpartition(":")
            ep_host, ep_port = host, int(port or 0)
    peer = {
        "public_key": pk,
        "allowed_ips": allowed,
        "persistent_keepalive_interval": keepalive,
    }
    if ep_host and ep_port:
        peer["address"] = ep_host
        peer["port"] = ep_port
    blob = json.dumps(peer, ensure_ascii=False, indent=2)
    indented = "\n".join("        " + line for line in blob.splitlines())
    parts.append(indented)
print(",\n".join(parts))
PY
}

gps_mesh_route_json() {
	gps_profile_normalize
	gps_mesh_defaults
	local prefix final_tag
	prefix=$(gps_json_escape "${MESH_OVERLAY_PREFIX}")
	final_tag=direct
	# mesh-failover：有在线对端时才把 final 指到探测组
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		final_tag=mesh-failover
	fi
	cat <<EOF
  "route": {
    "rules": [
      {
        "source_ip_cidr": ["${prefix}"],
        "outbound": "direct"
      },
      {
        "ip_cidr": ["${prefix}"],
        "outbound": "wg-ep"
      }
    ],
    "final": "${final_tag}"
  }
EOF
}

# 是否存在非本机且心跳在线的 peer（与 peers 渲染的 alive 判定一致；无心跳字段视为可用）
gps_mesh_has_live_peer() {
	local self=${NODE_ID:-}
	[[ -f ${GPS_MESH_PEERS:-} ]] || return 1
	have_cmd python3 || return 1
	MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" python3 - "$GPS_MESH_PEERS" "$self" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, self_id = sys.argv[1], sys.argv[2]
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
now = datetime.now(timezone.utc)
for n in doc.get("nodes") or []:
    if (n.get("node_id") or "") == self_id:
        continue
    ls = n.get("last_seen") or ""
    if not ls:
        sys.exit(0)
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    if (now - ts).total_seconds() <= stale:
        sys.exit(0)
sys.exit(1)
PY
}

gps_mesh_outbounds_json() {
	# 始终至少有 direct；L7 hop 占位（MESH_L7_DETOUR_JSON 高级用户/后续）
	local extra=${MESH_L7_OUTBOUNDS_JSON:-}
	# mesh-failover：direct 之后插入 urltest 探测组（本机直连 ↔ WG 隧道）
	local failover=""
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		local probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}
		# probe 可被 CLI/state.env 手工篡改，渲染前 JSON 转义，防破坏 JSON 或注入
		probe=$(gps_json_escape "$probe")
		failover=$(
			cat <<EOF
,
    {
      "type": "urltest",
      "tag": "mesh-failover",
      "outbounds": [
        "direct",
        "wg-ep"
      ],
      "url": "${probe}",
      "interval": "30s",
      "tolerance": 0
    }
EOF
		)
	fi
	if [[ -n ${extra//[[:space:]]/} ]]; then
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover},
${extra}
EOF
	else
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover}
EOF
	fi
}
