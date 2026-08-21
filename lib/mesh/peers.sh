#!/bin/bash
# peers.json 读写、导出/导入/同步

gps_mesh_peers_empty_doc() {
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{\n  "schema": 1,\n  "updated_at": "%s",\n  "nodes": []\n}\n' "$now"
}

gps_mesh_peers_load_or_init() {
	gps_mesh_ensure_dirs
	if [[ ! -f $GPS_MESH_PEERS ]]; then
		gps_mesh_peers_empty_doc >"$GPS_MESH_PEERS"
		chmod 600 "$GPS_MESH_PEERS"
	fi
}

# 将本机写入 peers 文档（upsert self）
gps_mesh_peers_upsert_self() {
	gps_mesh_ensure_node_id
	gps_mesh_ensure_wg_keys
	gps_mesh_ensure_overlay_ip
	gps_mesh_defaults
	gps_mesh_peers_load_or_init
	local ep=""
	if [[ -n ${PUBLIC_IP:-} ]]; then
		ep="${PUBLIC_IP}:${WG_LISTEN_PORT}"
	elif [[ -n ${PUBLIC_IP6:-} ]]; then
		ep="[${PUBLIC_IP6}]:${WG_LISTEN_PORT}"
	fi
	have_cmd python3 || err "mesh 需要 python3"
	NODE_ID="$NODE_ID" WG_PUBLIC_KEY="$WG_PUBLIC_KEY" MESH_OVERLAY_IP="$MESH_OVERLAY_IP" \
		ENDPOINT="$ep" ROLES="${MESH_ROLES:-edge}" \
		python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
nodes = doc.setdefault("nodes", [])
nid = os.environ["NODE_ID"]
roles = [r for r in (os.environ.get("ROLES") or "edge").replace(",", " ").split() if r]
entry = {
    "node_id": nid,
    "public_key": os.environ["WG_PUBLIC_KEY"],
    "endpoint": os.environ.get("ENDPOINT") or "",
    "overlay_ip": os.environ["MESH_OVERLAY_IP"],
    "roles": roles or ["edge"],
    "keepalive": 25,
    "last_seen": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
out = [n for n in nodes if n.get("node_id") != nid]
out.append(entry)
doc["nodes"] = out
doc["schema"] = 1
doc["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

gps_mesh_peer_add() {
	local nid=$1
	shift
	local pubkey="" endpoint="" overlay="" is_exit=0 keepalive=25
	while [[ $# -gt 0 ]]; do
		case $1 in
		--pubkey)
			pubkey=$2
			shift 2
			;;
		--endpoint)
			endpoint=$2
			shift 2
			;;
		--overlay-ip | --overlay)
			overlay=$2
			shift 2
			;;
		--exit)
			is_exit=1
			shift
			;;
		--keepalive)
			keepalive=$2
			shift 2
			;;
		*) err "未知参数: $1" ;;
		esac
	done
	[[ -n $nid && -n $pubkey && -n $overlay ]] || err "用法: mesh peer add <id> --pubkey K --overlay-ip IP [--endpoint H:P] [--exit]"
	gps_validate_single_line "$nid" || err "node_id 非法"
	gps_validate_single_line "$pubkey" || err "pubkey 非法"
	overlay=${overlay%%/*}
	gps_validate_ipv4 "$overlay" || err "无效 overlay-ip: $overlay"
	gps_mesh_peers_load_or_init
	have_cmd python3 || err "mesh 需要 python3"
	NID="$nid" PUB="$pubkey" EP="$endpoint" OV="$overlay" EXIT="$is_exit" KA="$keepalive" \
		python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
nodes = [n for n in doc.get("nodes", []) if n.get("node_id") != os.environ["NID"]]
roles = ["edge"]
if os.environ.get("EXIT") == "1":
    roles.append("exit")
nodes.append({
    "node_id": os.environ["NID"],
    "public_key": os.environ["PUB"],
    "endpoint": os.environ.get("EP") or "",
    "overlay_ip": os.environ["OV"],
    "roles": roles,
    "keepalive": int(os.environ.get("KA") or 25),
})
doc["nodes"] = nodes
doc["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

gps_mesh_peer_rm() {
	local nid=$1
	[[ -n $nid ]] || err "用法: mesh peer rm <node_id>"
	gps_mesh_peers_load_or_init
	NID="$nid" python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys, datetime
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)
doc["nodes"] = [n for n in doc.get("nodes", []) if n.get("node_id") != os.environ["NID"]]
doc["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

# 合并远端文档到本地（按 node_id upsert；保留本机自条目优先用本地密钥）
gps_mesh_peers_merge_file() {
	local src=$1
	[[ -f $src ]] || err "找不到 peers 文件: $src"
	gps_mesh_peers_load_or_init
	gps_mesh_ensure_node_id
	have_cmd python3 || err "mesh 需要 python3"
	# 防环：合并后若出现两个 exit 且本机 MESH_EXIT 指向非 exit，仅警告；双向 default 在渲染期拒绝
	SELF="$NODE_ID" python3 - "$GPS_MESH_PEERS" "$src" <<'PY'
import json, os, sys, datetime
local_path, remote_path = sys.argv[1], sys.argv[2]
with open(local_path, "r", encoding="utf-8") as f:
    local = json.load(f)
with open(remote_path, "r", encoding="utf-8") as f:
    remote = json.load(f)
self_id = os.environ.get("SELF") or ""
by = {n["node_id"]: n for n in local.get("nodes", []) if n.get("node_id")}
for n in remote.get("nodes", []) or []:
    nid = n.get("node_id")
    if not nid:
        continue
    if nid == self_id and nid in by:
        # 保留本地自描述，但可更新 endpoint
        if n.get("endpoint"):
            by[nid]["endpoint"] = n["endpoint"]
        continue
    by[nid] = n
local["nodes"] = list(by.values())
local["schema"] = 1
local["updated_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
# 防环粗检：多个 roles 含 exit 时允许（选谁当 exit 由 MESH_EXIT_NODE_ID 决定）
tmp = local_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(local, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, local_path)
PY
}

gps_mesh_export() {
	gps_mesh_peers_upsert_self
	cat "$GPS_MESH_PEERS"
}

gps_mesh_import() {
	local src=${1:--}
	local tmp
	tmp=$(mktemp)
	if [[ $src == - ]]; then
		cat >"$tmp"
	else
		[[ -f $src ]] || err "文件不存在: $src"
		cp -f "$src" "$tmp"
	fi
	python3 -m json.tool "$tmp" >/dev/null || err "无效 JSON"
	gps_mesh_peers_merge_file "$tmp"
	rm -f "$tmp"
	msg "$(_green "已合并 peers") → $GPS_MESH_PEERS"
}

gps_mesh_sync() {
	local src=$1
	[[ -n $src ]] || err "用法: mesh sync <url-or-file>"
	local tmp
	tmp=$(mktemp)
	if [[ $src == https://* || $src == http://* ]]; then
		curl -fsSL --max-time 30 "$src" -o "$tmp" || err "下载失败: $src"
	else
		[[ -f $src ]] || err "文件不存在: $src"
		cp -f "$src" "$tmp"
	fi
	python3 -m json.tool "$tmp" >/dev/null || err "无效 JSON"
	gps_mesh_peers_merge_file "$tmp"
	rm -f "$tmp"
	msg "$(_green "mesh sync 完成") peers=$GPS_MESH_PEERS"
}
