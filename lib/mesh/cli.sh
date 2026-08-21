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
	sync-master | sync_master)
		GPS_MESH_SYNC_RESTART=1 gps_mesh_sync_master
		;;
	init) gps_mesh_cmd_init "$@" ;;
	show | status) gps_mesh_cmd_show "$@" ;;
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
  mesh export | import | sync <url-or-file>
  mesh peer add|rm ...     # 排障手工改 peers
  mesh hop <json-file|none>
  mesh init ...            # 兼容旧命令（等同 ensure + 可选覆盖）

安装：无 GPS_MESH_MASTER → 本机为 Master；成员：
  GPS_MESH_MASTER=http://IP或域名或[IPv6]:19527 GPS_MESH_TOKEN=... bash install.sh
Master 域名: change mesh-master-host <域名|none>（默认可沿用节点名若含点）
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
	msg "  master URL:  ${primary:-${MESH_MASTER_URL:-?}}"
	if [[ -n ${PUBLIC_IP:-} || -n ${PUBLIC_IP6:-} ]]; then
		msg "  公网地址:    ${PUBLIC_IP:-—} / ${PUBLIC_IP6:-—}"
	fi
	if [[ ${MESH_ROLE:-} == master ]]; then
		gps_mesh_print_join_hints
	fi
	msg "  mesh-exit:   ${MESH_EXIT_NODE_ID:-none}"
	msg "  peers file:  ${GPS_MESH_PEERS:-}"
	if [[ -f ${GPS_MESH_PEERS:-} ]]; then
		msg "  peers:"
		python3 - "$GPS_MESH_PEERS" <<'PY' 2>/dev/null || msg "    （无法解析）"
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for n in doc.get("nodes") or []:
    roles = ",".join(n.get("roles") or [])
    print(f"    - {n.get('node_id')} overlay={n.get('overlay_ip')} endpoint={n.get('endpoint') or '-'} roles={roles}")
PY
	fi
}
