#!/bin/bash
# mesh 子命令

gps_cmd_mesh() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	load_state 2>/dev/null || true
	local sub=${1:-show}
	shift || true
	case $sub in
	ensure | boot)
		GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
		save_state
		;;
	join | join-export)
		if [[ $sub == join-export ]]; then
			gps_mesh_join_export
		else
			gps_mesh_become_member "$@"
		fi
		;;
	role | set-role)
		local r=${1:-}
		shift || true
		case $r in
		master) gps_mesh_become_master ;;
		member | node)
			gps_mesh_become_member "$@"
			;;
		*) err "用法: mesh role master | mesh role member <Master地址> <TOKEN>" ;;
		esac
		;;
	sync-master | sync_master)
		GPS_MESH_SYNC_RESTART=1 gps_mesh_sync_master
		;;
	init) gps_mesh_cmd_init "$@" ;;
	show | status) gps_mesh_cmd_show "$@" ;;
	connectivity) gps_mesh_cmd_connectivity "$@" ;;
	remediate) gps_mesh_cmd_remediate "$@" ;;
	menu-role) gps_mesh_menu_role ;;
	port-checklist | ports | firewall-ports) gps_mesh_print_port_checklist ;;
	migrate-tls | migrate_tls) gps_mesh_migrate_tls "$@" ;;
	token)
		local top=${1:-}
		shift || true
		case $top in
		rotate) gps_mesh_token_rotate ;;
		*) err "用法: mesh token rotate" ;;
		esac
		;;
	webhook)
		local top=${1:-show}
		shift || true
		case $top in
		set-secret) gps_mesh_webhook_set_secret "$@" ;;
		show) gps_mesh_webhook_show ;;
		*) err "用法: mesh webhook set-secret [SECRET] | mesh webhook show" ;;
		esac
		;;
	peer)
		local op=${1:-}
		shift || true
		case $op in
		add) gps_mesh_peer_add "$@" ;;
		rm | remove | del) gps_mesh_peer_rm "$@" ;;
		*) err "用法: mesh peer add|rm ..." ;;
		esac
		gps_write_config
		save_state
		gps_restart_svc
		;;
	export) gps_mesh_export ;;
	import)
		gps_mesh_import "$@"
		gps_write_config
		save_state
		gps_restart_svc
		;;
	sync)
		gps_mesh_sync "$@"
		gps_write_config
		save_state
		gps_restart_svc
		;;
	hop)
		local frag=${1:-}
		if [[ -z $frag || $frag == none || $frag == clear ]]; then
			# shellcheck disable=SC2034
			MESH_L7_OUTBOUNDS_JSON=""
		else
			[[ -f $frag ]] || err "找不到文件: $frag"
			# shellcheck disable=SC2034  # MESH_L7_OUTBOUNDS_JSON 由 config 渲染读取
			MESH_L7_OUTBOUNDS_JSON=$(cat "$frag")
		fi
		gps_write_config
		save_state
		gps_restart_svc
		msg "$(_green "mesh hop") 已更新"
		;;
	help | -h | --help) gps_mesh_help ;;
	*)
		gps_mesh_help
		err "未知 mesh 子命令: $sub"
		;;
	esac
}

gps_mesh_help() {
	cat <<EOF
$GPS_NAME mesh — WireGuard 组网（随主服务开机；Master 发现）

  mesh ensure              # 开机/ExecStartPre：密钥 + 注册/拉 peers + 写配置
  mesh sync-master         # 周期：再注册并拉 peers（有变更则重启）
  mesh show
  mesh connectivity        # 组网连通性摘要（公网 UDP / WG 流量 / overlay 10.66.x）
  mesh remediate           # 本机 WG 数据面自动修复（防火墙 + 未 listen 则重启）
  mesh role master         # 本机升为 Master
  mesh role member <地址> <TOKEN>   # 本机加入为 Node
  mesh join <地址> <TOKEN> # 同上
  mesh join-export         # Master：导出 join.cmd 路径与脱敏预览
  mesh port-checklist      # 防火墙端口清单（Master/Member checklist）
  mesh migrate-tls [join]  # Member：修复 http/PIN/连通性（可粘贴 join 整行）
  mesh token rotate        # Master：轮换集群 TOKEN（Member 须重 join）
  mesh webhook set-secret  # Master：配置 GitHub Release webhook secret
  mesh webhook show        # Master：webhook URL 与配置说明
  mesh export | import | sync <url-or-file>
  mesh peer add|rm ...
  mesh hop <json-file|none>

Master 地址支持域名 / IPv4 / IPv6。菜单: 26) Mesh 角色
跳板: change mesh-exit <node_id|none>
EOF
}

gps_mesh_cmd_init() {
	# 兼容旧 CLI：参数覆盖后走 ensure
	local overlay="" wgport="" nid=""
	while [[ $# -gt 0 ]]; do
		case $1 in
		--overlay-ip)
			overlay=$2
			shift 2
			;;
		--wg-port)
			wgport=$2
			shift 2
			;;
		--node-id)
			nid=$2
			shift 2
			;;
		*) err "未知参数: $1" ;;
		esac
	done
	[[ -n $nid ]] && NODE_ID=$nid
	[[ -n $overlay ]] && MESH_OVERLAY_IP=$overlay
	[[ -n $wgport ]] && WG_LISTEN_PORT=$wgport
	MESH_ROLE=${MESH_ROLE:-master}
	gps_mesh_bootstrap_from_env 2>/dev/null || {
		gps_mesh_role_normalize
		# shellcheck disable=SC2034  # PROFILE 由 gps_profile_normalize 读取
		PROFILE=mesh-member
		gps_mesh_defaults
		if [[ $MESH_ROLE == master ]]; then
			MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
			gps_mesh_ensure_cluster_token
		fi
	}
	[[ -n $nid ]] && NODE_ID=$nid
	[[ -n $overlay ]] && MESH_OVERLAY_IP=$overlay
	[[ -n $wgport ]] && WG_LISTEN_PORT=$wgport
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_restart_svc
	msg "$(_green "mesh init 完成") role=$MESH_ROLE node_id=$NODE_ID overlay=$MESH_OVERLAY_IP wg_port=$WG_LISTEN_PORT"
	msg "公钥: $WG_PUBLIC_KEY"
}

gps_mesh_cmd_show() {
	# 展示前自动 ensure，避免「未初始化」假象
	if [[ -n ${PORT:-} ]] || [[ -f ${GPS_STATE:-} ]]; then
		load_state 2>/dev/null || true
		GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
		save_state
	fi
	gps_mesh_role_normalize 2>/dev/null || true
	gps_profile_normalize 2>/dev/null || true
	gps_mesh_ensure_node_id 2>/dev/null || true
	gps_mesh_defaults 2>/dev/null || true
	gps_mesh_resolve_master_host 2>/dev/null || true
	local primary
	primary=$(gps_mesh_primary_join_url 2>/dev/null || true)
	msg "$(_cyan "Mesh")"
	msg "  MESH_ROLE:   ${MESH_ROLE:-?}"
	msg "  NODE_ID:     ${NODE_ID:-（未设置）}"
	msg "  overlay:     ${MESH_OVERLAY_IP:-?}  prefix=${MESH_OVERLAY_PREFIX:-10.66.0.0/16}  （WG 内部虚拟网，非公网）"
	msg "  WG listen:   ${WG_LISTEN_PORT:-51820}"
	msg "  WG public:   ${WG_PUBLIC_KEY:-（未生成）}"
	msg "  master host: ${MESH_MASTER_HOST:-（未设置，可用 change mesh-master-host）}"
	if [[ ${MESH_ROLE:-} == member ]]; then
		msg "  master URL:  ${MESH_MASTER_URL:-（未设置）}"
	else
		msg "  master URL:  ${primary:-${MESH_MASTER_URL:-?}}"
	fi
	if [[ -n ${PUBLIC_IP:-} || -n ${PUBLIC_IP6:-} ]]; then
		msg "  公网地址:    ${PUBLIC_IP:-—} / ${PUBLIC_IP6:-—}"
	fi
	if [[ ${MESH_ROLE:-} == master ]]; then
		gps_mesh_print_join_hints
		if [[ -n ${GPS_GITHUB_WEBHOOK_SECRET:-} ]]; then
			msg "  GitHub webhook: $(gps_mesh_webhook_url) （Release published → 自动 upgrade self）"
		else
			msg "  GitHub webhook: （未配置）mesh webhook set-secret"
		fi
	else
		gps_mesh_print_wg_data_plane_status
	fi
	msg "  mesh-exit:   ${MESH_EXIT_NODE_ID:-none}"
	msg "  mesh-failover: ${MESH_FAILOVER:-0}  probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}"
	msg "  心跳窗口:   ${MESH_PEER_STALE_SEC:-180}s（超时视为离线；仅在线节点写入 WG）"
	msg "  peers file:  ${GPS_MESH_PEERS:-}"
	if [[ -f ${GPS_MESH_PEERS:-} ]]; then
		msg "  节点列表（自动发现）:"
		NODE_ID="${NODE_ID:-}" MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" \
			python3 - "$GPS_MESH_PEERS" <<'PY' 2>/dev/null || msg "    （无法解析）"
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
self_id = os.environ.get("NODE_ID") or ""
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
now = datetime.now(timezone.utc)
doc = json.load(open(path, encoding="utf-8"))
nodes = doc.get("nodes") or []
if not nodes:
    print("    （尚无节点；Node 在菜单 26 加入后会出现在此）")
for n in nodes:
    nid = n.get("node_id") or "?"
    ls = n.get("last_seen") or ""
    if nid == self_id:
        status = "在线(本机)"
    elif not ls:
        status = "未知"
    else:
        try:
            ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            age = (now - ts).total_seconds()
            status = "在线" if age <= stale else "离线"
        except ValueError:
            status = "未知"
    roles = ",".join(n.get("roles") or []) or "-"
    ep = n.get("endpoint") or "-"
    print(f"    - [{status}] {nid}  overlay={n.get('overlay_ip')}  endpoint={ep}  last_seen={ls or '-'}  roles={roles}")
alive = 0
for n in nodes:
    nid = n.get("node_id") or ""
    if nid == self_id:
        alive += 1
        continue
    ls = n.get("last_seen") or ""
    if not ls:
        continue
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        if (now - ts).total_seconds() <= stale:
            alive += 1
    except ValueError:
        pass
print(f"    合计: {len(nodes)} 节点，心跳活动可用: {alive}")
PY
	fi
	gps_mesh_print_connectivity_summary
}

gps_mesh_cmd_connectivity() {
	load_state 2>/dev/null || true
	gps_mesh_role_normalize 2>/dev/null || true
	gps_mesh_ensure_node_id 2>/dev/null || true
	gps_mesh_defaults 2>/dev/null || true
	msg "$(_cyan "Mesh 组网连通性")"
	gps_mesh_print_connectivity_summary
}

gps_mesh_cmd_remediate() {
	load_state 2>/dev/null || true
	gps_mesh_role_normalize 2>/dev/null || true
	gps_mesh_ensure_node_id 2>/dev/null || true
	gps_mesh_defaults 2>/dev/null || true
	msg "$(_cyan "Mesh WG 数据面修复")（本机）"
	gps_mesh_remediate_local_wg || true
	msg ""
	gps_mesh_print_connectivity_summary
}
