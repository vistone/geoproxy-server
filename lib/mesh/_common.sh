#!/bin/bash
# Mesh 公共：PROFILE、路径、节点 ID

gps_profile_normalize() {
	PROFILE=${PROFILE:-edge}
	PROFILE=$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')
	case $PROFILE in
	edge | mesh-member | mesh_member)
		if [[ $PROFILE == mesh_member ]]; then
			PROFILE=mesh-member
		fi
		;;
	*)
		err "无效 PROFILE: ${PROFILE}（可用: edge | mesh-member）"
		;;
	esac
}

gps_mesh_ensure_dirs() {
	mkdir -p "$GPS_MESH_DIR"
	chmod 700 "$GPS_MESH_DIR" 2>/dev/null || true
}

gps_mesh_ensure_node_id() {
	if [[ -z ${NODE_ID:-} ]]; then
		NODE_ID=$(gps_tuic_node_name | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//;s/-$//')
		[[ -n $NODE_ID ]] || NODE_ID="node-$(hostname 2>/dev/null | tr -cs 'a-zA-Z0-9' '-' | head -c 24)"
		[[ -n $NODE_ID ]] || NODE_ID="node1"
	fi
	gps_validate_single_line "$NODE_ID" || err "NODE_ID 非法"
}

# 默认 overlay 前缀与本机 /32
gps_mesh_defaults() {
	MESH_OVERLAY_PREFIX=${MESH_OVERLAY_PREFIX:-10.66.0.0/16}
	WG_LISTEN_PORT=${WG_LISTEN_PORT:-51820}
	gps_validate_port "$WG_LISTEN_PORT" || err "无效 WG_LISTEN_PORT: $WG_LISTEN_PORT"
}
