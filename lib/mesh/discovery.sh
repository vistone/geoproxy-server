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
	body=$(
		MESH_OVERLAY_IP="$MESH_OVERLAY_IP" NODE_ID="$NODE_ID" WG_PUBLIC_KEY="$WG_PUBLIC_KEY" \
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

	if ! gps_mesh_curl "${url}/v1/register" \
		-H "Content-Type: application/json" \
		-d "$body" \
		-o "$tmp"; then
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
	if ! gps_mesh_curl "${url}/v1/peers" -o "$tmp"; then
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
	# shellcheck disable=SC2034  # PROFILE 由 gps_profile_normalize 读取
	PROFILE=mesh-member
	gps_profile_normalize
	gps_mesh_ensure_node_id
	gps_mesh_defaults
	gps_mesh_ensure_wg_keys
	# 启动路径默认 2–3s：15s curl 会让 ExecStartPre 被下一次 restart TERM 成 failed
	if [[ -z ${GPS_MESH_CURL_MAX_TIME:-} ]]; then
		GPS_MESH_CURL_MAX_TIME=3
		GPS_MESH_CURL_CONNECT_TIMEOUT=${GPS_MESH_CURL_CONNECT_TIMEOUT:-2}
	fi

	if [[ $MESH_ROLE == master ]]; then
		MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
		gps_mesh_ensure_overlay_ip
		gps_mesh_ensure_cluster_token
		gps_mesh_ensure_master_tls
		gps_mesh_peers_upsert_self
		gps_mesh_resolve_master_host
		MESH_MASTER_URL=$(gps_mesh_primary_join_url)
		gps_mesh_expose_control_plane
	else
		if gps_mesh_register_and_pull; then
			msg "$(_cyan "mesh") 已向 Master 注册并拉取 peers"
		else
			warn "无法联系 Master（${MESH_MASTER_URL:-?}）；使用本地 peers（若有）
请到 Master 上确认 TCP ${MESH_MASTER_PORT:-19527}（mesh 控制面）已对外放行（本机防火墙 + 云安全组）。脚本只能管本机防火墙。"
			gps_mesh_ensure_overlay_ip
			gps_mesh_peers_load_or_init || warn "无法初始化本地 peers（${GPS_MESH_PEERS:-?}）"
			gps_mesh_peers_upsert_self || warn "无法写入本地 peers（只读沙箱？检查 systemd ReadWritePaths 含 ${GPS_ETC:-/etc/geoproxy-server}）"
		fi
	fi
	gps_mesh_expose_wg_data_plane
	gps_write_config || warn "无法写入 ${GPS_CONFIG:-config}（只读沙箱？检查 systemd ReadWritePaths）"
}

# 周期同步：成员 register+pull；Master 仅 upsert self。WG 配置变更才重启。
gps_mesh_sync_master() {
	[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	gps_mesh_defaults
	# 周期同步可用完整超时；ensure 启动路径默认 3s
	if [[ -z ${GPS_MESH_CURL_MAX_TIME:-} ]]; then
		GPS_MESH_CURL_MAX_TIME=15
		GPS_MESH_CURL_CONNECT_TIMEOUT=${GPS_MESH_CURL_CONNECT_TIMEOUT:-15}
	fi
	local before after
	before=""
	[[ -f $GPS_CONFIG ]] && before=$(cksum "$GPS_CONFIG" 2>/dev/null | awk '{print $1" "$2}')

	gps_mesh_ensure_boot
	save_state 2>/dev/null || true

	after=""
	[[ -f $GPS_CONFIG ]] && after=$(cksum "$GPS_CONFIG" 2>/dev/null | awk '{print $1" "$2}')

	# 只看 config.json：peers.json 的 last_seen 每次 upsert 都会变，不能据此重启代理
	if [[ ${GPS_MESH_SYNC_RESTART:-1} == 1 && $before != "$after" ]]; then
		gps_restart_svc 2>/dev/null || true
	fi
}
