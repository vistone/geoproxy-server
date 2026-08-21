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
		gps_profile_normalize
		if [[ $PROFILE == mesh-member ]]; then
			gps_write_config
			save_state
			gps_restart_svc
		else
			save_state
			msg "peers 已更新；启用组网: change profile mesh-member"
		fi
		;;
	export) gps_mesh_export ;;
	import) gps_mesh_import "$@" ;;
	sync)
		gps_mesh_sync "$@"
		gps_profile_normalize
		if [[ $PROFILE == mesh-member ]]; then
			gps_write_config
			save_state
			gps_restart_svc
		else
			save_state
		fi
		;;
	hop)
		# L7：写入额外 outbound JSON 片段（高级）；空参数清除
		local frag=${1:-}
		if [[ -z $frag || $frag == none || $frag == clear ]]; then
			# shellcheck disable=SC2034  # 由 gps_mesh_outbounds_json / save_state 读取
			MESH_L7_OUTBOUNDS_JSON=""
			msg "$(_green "已清除 L7 hop outbounds")"
		else
			[[ -f $frag ]] || err "用法: mesh hop <json-file|none>（文件内容为 outbound 对象，可多个逗号分隔）"
			# shellcheck disable=SC2034
			MESH_L7_OUTBOUNDS_JSON=$(cat "$frag")
			msg "$(_green "已加载 L7 outbounds 片段")"
		fi
		gps_write_config
		save_state
		gps_restart_svc
		;;
	help | -h | --help) gps_mesh_help ;;
	*)
		warn "未知 mesh 子命令: $sub"
		gps_mesh_help
		exit 1
		;;
	esac
}

gps_mesh_help() {
	cat <<EOF
$GPS_NAME mesh — WireGuard 节点互连（PROFILE=mesh-member）

  mesh init [--overlay-ip IP] [--wg-port N] [--node-id ID]
  mesh show
  mesh peer add <id> --pubkey K --overlay-ip IP [--endpoint H:P] [--exit]
  mesh peer rm <id>
  mesh export
  mesh import <file|->
  mesh sync <url-or-file>
  mesh hop <json-file|none>   # L7 额外 outbound（可含 detour）

启用: change profile mesh-member
指定 L3 出口跳板: change mesh-exit <node_id|none>
EOF
}

gps_mesh_cmd_init() {
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
	gps_mesh_ensure_node_id
	gps_mesh_defaults
	gps_mesh_ensure_wg_keys
	gps_mesh_ensure_overlay_ip
	gps_mesh_peers_upsert_self
	PROFILE=mesh-member
	gps_profile_normalize
	gps_write_config
	save_state
	gps_restart_svc
	msg "$(_green "mesh init 完成") node_id=$NODE_ID overlay=$MESH_OVERLAY_IP wg_port=$WG_LISTEN_PORT"
	msg "公钥: $WG_PUBLIC_KEY"
	msg "导出给其它节点: $GPS_NAME mesh export"
}

gps_mesh_cmd_show() {
	gps_profile_normalize
	gps_mesh_ensure_node_id 2>/dev/null || true
	msg "$(_cyan "Mesh")"
	msg "  PROFILE:     ${PROFILE:-edge}"
	msg "  NODE_ID:     ${NODE_ID:-（未设置）}"
	msg "  overlay:     ${MESH_OVERLAY_IP:-?}  prefix=${MESH_OVERLAY_PREFIX:-10.66.0.0/16}"
	msg "  WG listen:   ${WG_LISTEN_PORT:-51820}"
	msg "  WG public:   ${WG_PUBLIC_KEY:-（未生成）}"
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
