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
      "mtu": ${MESH_WG_MTU},
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
	# v0.2.68 起 WG 仅做节点互联：peers 只持有 overlay /32，绝不授予 0.0.0.0/0 等默认路由
	NODE_ID="${NODE_ID:-}" \
		MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" \
		MESH_WG_LIVE_ONLY="${MESH_WG_LIVE_ONLY:-1}" \
		python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
self_id = os.environ.get("NODE_ID") or ""
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
        "allowed_ips": [overlay + "/32"],
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

# 与 WG peers 渲染同过滤口径的 overlay /32 清单（每行一个）。
# 供路由规则精确匹配：目的地只送进「mesh 内真实存在」的地址，避免整段 /16 劫持同网段真实目的地。
gps_mesh_peer_overlay_cidrs() {
	gps_mesh_ensure_dirs
	if [[ ! -f ${GPS_MESH_PEERS:-} ]]; then
		return 0
	fi
	have_cmd python3 || return 0
	NODE_ID="${NODE_ID:-}" MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" \
		MESH_WG_LIVE_ONLY="${MESH_WG_LIVE_ONLY:-1}" \
		python3 - "$GPS_MESH_PEERS" <<'PY'
import ipaddress, json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
self_id = os.environ.get("NODE_ID") or ""
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
live_only = (os.environ.get("MESH_WG_LIVE_ONLY") or "1") != "0"
now = datetime.now(timezone.utc)

def alive(n):
    ls = n.get("last_seen") or ""
    if not ls:
        return True
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return False
    return (now - ts).total_seconds() <= stale

with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
seen = set()
for n in doc.get("nodes") or []:
    nid = n.get("node_id") or ""
    if not nid or nid == self_id:
        continue
    if int(n.get("tripped") or 0):
        continue
    if live_only and not alive(n):
        continue
    if not (n.get("public_key") or ""):
        continue
    raw = (n.get("overlay_ip") or "").split("/")[0]
    try:
        ip = ipaddress.ip_address(raw)
    except ValueError:
        continue
    if ip.version != 4:
        continue
    key = f"{ip}/32"
    if key not in seen:
        seen.add(key)
        print(key)
PY
}

gps_mesh_route_json() {
	gps_profile_normalize
	gps_mesh_defaults
	local prefix
	prefix=$(gps_json_escape "${MESH_OVERLAY_PREFIX}")
	# v0.2.68 起 WG 仅做节点互联：代理出口恒为 direct（不再有 mesh-exit / mesh-failover）
	# 目的地规则只收敛到 peer 实际持有的 overlay /32：
	# 整段 /16 会把同网段的真实目的地（云内网/K8s service CIDR 等）也劫持进 WG 黑洞
	local dest_rule="" cidr line first=1
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		if ((first)); then
			first=0
		else
			cidr+=','
		fi
		cidr+="$(printf '"%s"' "$(gps_json_escape "$line")")"
	done < <(gps_mesh_peer_overlay_cidrs)
	if [[ -n ${cidr:-} ]]; then
		dest_rule=$(printf ',\n      {\n        "ip_cidr": [%s],\n        "outbound": "wg-ep"\n      }' "$cidr")
	fi
	cat <<EOF
  "route": {
    "rules": [
      {
        "source_ip_cidr": ["${prefix}"],
        "outbound": "direct"
      }${dest_rule}
    ],
    "final": "direct"
  }
EOF
}

gps_mesh_outbounds_json() {
	# 始终至少有 direct；L7 hop 占位（MESH_L7_DETOUR_JSON 高级用户/后续）
	# v0.2.68 起 WG 不承载代理流量：无 urltest 探测组，出口恒 direct
	local extra=${MESH_L7_OUTBOUNDS_JSON:-}
	if [[ -n ${extra//[[:space:]]/} ]]; then
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    },
${extra}
EOF
	else
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }
EOF
	fi
}
