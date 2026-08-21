#!/bin/bash
# Master 发现：注册、拉 peers、开机 ensure

gps_mesh_endpoint_hint() {
	gps_mesh_defaults
	if [[ -n ${PUBLIC_IP:-} ]]; then
		printf '%s:%s' "$PUBLIC_IP" "$WG_LISTEN_PORT"
	elif [[ -n ${PUBLIC_IP6:-} ]]; then
		printf '[%s]:%s' "$PUBLIC_IP6" "$WG_LISTEN_PORT"
	else
		printf ''
	fi
}

# POST register；成功则合并 peers 并更新本机 overlay；失败返回非 0
gps_mesh_register_and_pull() {
	gps_mesh_role_normalize
	gps_mesh_ensure_node_id
	gps_mesh_ensure_wg_keys
	gps_mesh_defaults
	local url=${MESH_MASTER_URL:-}
	[[ -n $url ]] || return 1
	url=${url%/}
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || {
		[[ -f ${GPS_MESH_TOKEN_FILE:-} ]] && MESH_CLUSTER_TOKEN=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
	}
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || return 1

	# 成员可带偏好 overlay；Master 冲突时改派
	if [[ -z ${MESH_OVERLAY_IP:-} ]]; then
		gps_mesh_ensure_overlay_ip
	else
		MESH_OVERLAY_IP=${MESH_OVERLAY_IP%%/*}
	fi

	local ep body tmp
	ep=$(gps_mesh_endpoint_hint)
	tmp=$(mktemp)
	body=$(MESH_OVERLAY_IP="$MESH_OVERLAY_IP" NODE_ID="$NODE_ID" WG_PUBLIC_KEY="$WG_PUBLIC_KEY" \
		ENDPOINT="$ep" ROLES="${MESH_ROLES:-edge}" python3 - <<'PY'
import json, os
print(json.dumps({
    "node_id": os.environ["NODE_ID"],
    "public_key": os.environ["WG_PUBLIC_KEY"],
    "endpoint": os.environ.get("ENDPOINT") or "",
    "overlay_ip": os.environ.get("MESH_OVERLAY_IP") or "",
    "roles": [r for r in (os.environ.get("ROLES") or "edge").replace(",", " ").split() if r] or ["edge"],
    "keepalive": 25,
}, ensure_ascii=False))
PY
	) || {
		rm -f "$tmp"
		return 1
	}

	if ! curl -fsSL --max-time 15 \
		-H "Authorization: Bearer ${MESH_CLUSTER_TOKEN}" \
		-H "Content-Type: application/json" \
		-d "$body" \
		"${url}/v1/register" -o "$tmp"; then
		rm -f "$tmp"
		return 1
	fi

	python3 -m json.tool "$tmp" >/dev/null 2>&1 || {
		rm -f "$tmp"
		return 1
	}

	gps_mesh_ensure_dirs
	# 应用分配的 overlay + 写入 peers 快照
	eval "$(
		NODE_ID="$NODE_ID" python3 - "$tmp" "$GPS_MESH_PEERS" <<'PY'
import json, os, sys, shlex
resp_path, peers_path = sys.argv[1], sys.argv[2]
with open(resp_path, encoding="utf-8") as f:
    resp = json.load(f)
node = resp.get("node") or {}
peers = resp.get("peers")
if peers is None:
    peers = {"schema": 1, "nodes": []}
overlay = (node.get("overlay_ip") or "").split("/")[0]
with open(peers_path, "w", encoding="utf-8") as f:
    json.dump(peers, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(peers_path, 0o600)
if overlay:
    print("MESH_OVERLAY_IP=" + shlex.quote(overlay))
PY
	)"
	rm -f "$tmp"
	return 0
}

# 仅 GET peers（备用）
gps_mesh_pull_peers() {
	local url=${MESH_MASTER_URL:-}
	[[ -n $url ]] || return 1
	url=${url%/}
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || {
		[[ -f ${GPS_MESH_TOKEN_FILE:-} ]] && MESH_CLUSTER_TOKEN=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
	}
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || return 1
	local tmp
	tmp=$(mktemp)
	if ! curl -fsSL --max-time 15 \
		-H "Authorization: Bearer ${MESH_CLUSTER_TOKEN}" \
		"${url}/v1/peers" -o "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	python3 -m json.tool "$tmp" >/dev/null 2>&1 || {
		rm -f "$tmp"
		return 1
	}
	gps_mesh_peers_merge_file "$tmp"
	rm -f "$tmp"
}

# 开机 / ExecStartPre：始终准备 WG + peers（不重启服务）
gps_mesh_ensure_boot() {
	gps_mesh_role_normalize
	PROFILE=mesh-member
	gps_profile_normalize
	gps_mesh_ensure_node_id
	gps_mesh_defaults
	gps_mesh_ensure_wg_keys

	if [[ $MESH_ROLE == master ]]; then
		MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
		gps_mesh_ensure_overlay_ip
		gps_mesh_ensure_cluster_token
		gps_mesh_peers_upsert_self
		gps_mesh_resolve_master_host
		MESH_MASTER_URL=$(gps_mesh_primary_join_url)
	else
		if gps_mesh_register_and_pull; then
			msg "$(_cyan "mesh") 已向 Master 注册并拉取 peers"
		else
			warn "无法联系 Master（${MESH_MASTER_URL:-?}）；使用本地 peers（若有）"
			gps_mesh_ensure_overlay_ip
			gps_mesh_peers_load_or_init
			gps_mesh_peers_upsert_self
		fi
	fi
	gps_write_config
}

# 周期同步：成员 register+pull；Master 仅 upsert self。peers/config 变更则重启。
gps_mesh_sync_master() {
	[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	gps_mesh_defaults
	local before after
	before=""
	[[ -f $GPS_MESH_PEERS ]] && before=$(cksum "$GPS_MESH_PEERS" 2>/dev/null | awk '{print $1" "$2}')
	[[ -f $GPS_CONFIG ]] && before="${before}|$(cksum "$GPS_CONFIG" 2>/dev/null | awk '{print $1" "$2}')"

	if [[ $MESH_ROLE == master ]]; then
		gps_mesh_ensure_boot
	else
		gps_mesh_ensure_boot
	fi
	save_state 2>/dev/null || true

	after=""
	[[ -f $GPS_MESH_PEERS ]] && after=$(cksum "$GPS_MESH_PEERS" 2>/dev/null | awk '{print $1" "$2}')
	[[ -f $GPS_CONFIG ]] && after="${after}|$(cksum "$GPS_CONFIG" 2>/dev/null | awk '{print $1" "$2}')"

	# ExecStartPre 场景：调用方不重启；timer 场景需要时重启
	if [[ ${GPS_MESH_SYNC_RESTART:-1} == 1 && $before != "$after" ]]; then
		gps_restart_svc 2>/dev/null || true
	fi
}
