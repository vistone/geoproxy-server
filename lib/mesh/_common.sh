#!/bin/bash
# Mesh 公共：角色、路径、节点 ID

# 兼容旧 PROFILE：组网始终启用；edge 仅作遗留值，写配置时视为 mesh
gps_profile_normalize() {
	PROFILE=${PROFILE:-mesh-member}
	PROFILE=$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')
	case $PROFILE in
	edge)
		PROFILE=mesh-member
		;;
	mesh-member | mesh_member)
		PROFILE=mesh-member
		;;
	*)
		err "无效 PROFILE: ${PROFILE}（已废弃；组网始终启用）"
		;;
	esac
}

gps_mesh_role_normalize() {
	MESH_ROLE=${MESH_ROLE:-master}
	MESH_ROLE=$(printf '%s' "$MESH_ROLE" | tr '[:upper:]' '[:lower:]')
	case $MESH_ROLE in
	master | member) ;;
	*)
		err "无效 MESH_ROLE: ${MESH_ROLE}（可用: master | member）"
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
	MESH_MASTER_PORT=${MESH_MASTER_PORT:-${GPS_MESH_MASTER_PORT:-19527}}
	MESH_SYNC_SEC=${MESH_SYNC_SEC:-60}
	MESH_PEER_STALE_SEC=${MESH_PEER_STALE_SEC:-180}
	MESH_WG_LIVE_ONLY=${MESH_WG_LIVE_ONLY:-1}
	gps_validate_port "$WG_LISTEN_PORT" || err "无效 WG_LISTEN_PORT: $WG_LISTEN_PORT"
	gps_validate_port "$MESH_MASTER_PORT" || err "无效 MESH_MASTER_PORT: $MESH_MASTER_PORT"
}

gps_mesh_ensure_cluster_token() {
	if [[ -z ${MESH_CLUSTER_TOKEN:-} ]]; then
		if [[ -f ${GPS_MESH_TOKEN_FILE:-} ]]; then
			MESH_CLUSTER_TOKEN=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
		fi
	fi
	if [[ -z ${MESH_CLUSTER_TOKEN:-} ]]; then
		if have_cmd openssl; then
			MESH_CLUSTER_TOKEN=$(openssl rand -hex 24)
		else
			MESH_CLUSTER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
		fi
	fi
	gps_mesh_ensure_dirs
	umask 077
	printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
	chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
}

# 主机名是否适合作为 Master 域名（含点、非纯 IP）
gps_mesh_looks_like_hostname() {
	local h=${1:-}
	[[ -n $h ]] || return 1
	[[ $h == *.* ]] || return 1
	gps_validate_ipv4 "$h" 2>/dev/null && return 1
	# 粗判：含冒号则当 IPv6
	[[ $h == *:* ]] && return 1
	return 0
}

# 解析 MESH_MASTER_HOST：显式值优先；否则沿用像域名的 TUIC_NAME / NODE_ID
gps_mesh_resolve_master_host() {
	if [[ -n ${MESH_MASTER_HOST:-} ]]; then
		return 0
	fi
	if [[ -n ${TUIC_NAME:-} ]] && gps_mesh_looks_like_hostname "$TUIC_NAME"; then
		MESH_MASTER_HOST=$TUIC_NAME
		return 0
	fi
	if [[ -n ${NODE_ID:-} ]] && gps_mesh_looks_like_hostname "$NODE_ID"; then
		MESH_MASTER_HOST=$NODE_ID
	fi
}

# 输出 Master 对外 join 基址（每行一个 http://...:port），双栈+域名
# 优先顺序写入 MESH_MASTER_URL：域名 > IPv4 > IPv6 > loopback
gps_mesh_join_urls() {
	gps_mesh_defaults
	gps_mesh_resolve_master_host
	local port=${MESH_MASTER_PORT:-19527}
	local -a urls=()
	if [[ -n ${MESH_MASTER_HOST:-} ]]; then
		urls+=("http://${MESH_MASTER_HOST}:${port}")
	fi
	if [[ -n ${PUBLIC_IP:-} ]]; then
		urls+=("http://${PUBLIC_IP}:${port}")
	fi
	if [[ -n ${PUBLIC_IP6:-} ]]; then
		urls+=("http://[${PUBLIC_IP6}]:${port}")
	fi
	if ((${#urls[@]} == 0)); then
		urls+=("http://127.0.0.1:${port}")
	fi
	# 去重保序
	local u seen=""
	for u in "${urls[@]}"; do
		[[ " $seen " == *" $u "* ]] && continue
		printf '%s\n' "$u"
		seen+=" $u"
	done
}

gps_mesh_primary_join_url() {
	local first=""
	# 不用 head|pipe：set -o pipefail 下会 SIGPIPE(141)
	while IFS= read -r first; do
		break
	done < <(gps_mesh_join_urls)
	printf '%s\n' "$first"
}

# 打印成员加入命令（全部可用地址）
gps_mesh_print_join_hints() {
	[[ ${MESH_ROLE:-} == master ]] || return 0
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || return 0
	local u
	msg "$(_cyan "其它节点加入组网")（IPv4 / IPv6 / 域名任选其一可通即可）:"
	while IFS= read -r u; do
		[[ -n $u ]] || continue
		msg "  GPS_MESH_MASTER=${u} GPS_MESH_TOKEN=${MESH_CLUSTER_TOKEN} bash install.sh"
	done < <(gps_mesh_join_urls)
}

# 从「整行加入命令」或「地址 + TOKEN」解析出 url/token（写入全局 __MESH_PARSE_URL / __MESH_PARSE_TOKEN）
gps_mesh_parse_join_input() {
	local blob=${1:-}
	__MESH_PARSE_URL=""
	__MESH_PARSE_TOKEN=""
	[[ -n $blob ]] || return 1
	# 粘贴了完整命令：GPS_MESH_MASTER=... GPS_MESH_TOKEN=...
	if [[ $blob == *GPS_MESH_MASTER=* ]]; then
		__MESH_PARSE_URL=$(printf '%s' "$blob" | sed -n 's/.*GPS_MESH_MASTER=\([^[:space:]]*\).*/\1/p' | head -n1)
		__MESH_PARSE_TOKEN=$(printf '%s' "$blob" | sed -n 's/.*GPS_MESH_TOKEN=\([^[:space:]]*\).*/\1/p' | head -n1)
		[[ -n $__MESH_PARSE_URL ]] || return 1
		return 0
	fi
	# 仅 URL
	__MESH_PARSE_URL=$blob
	return 0
}

# 是否像合法 IPv6（十六进制与冒号，可选压缩）
gps_mesh_looks_like_ipv6() {
	local h=${1:-}
	[[ -n $h ]] || return 1
	[[ $h == *:* ]] || return 1
	[[ $h =~ ^[0-9A-Fa-f:]+$ ]] || return 1
	local colons=${h//[^:]/}
	((${#colons} >= 2))
}

# 把用户输入规范成 http://host:port（支持域名 / IPv4 / IPv6 / 已带 http）
gps_mesh_normalize_master_url() {
	local raw=${1:-}
	# 保留空格以便检测整行粘贴；先尝试解析命令行
	if [[ $raw == *GPS_MESH_MASTER=* ]]; then
		gps_mesh_parse_join_input "$raw" || err "无法从粘贴内容解析 GPS_MESH_MASTER"
		raw=$__MESH_PARSE_URL
	fi
	raw=$(printf '%s' "$raw" | tr -d '[:space:]')
	[[ -n $raw ]] || err "Master 地址不能为空"
	# 拒绝把整段命令误当地址
	case $raw in
	*GPS_MESH_* | *TOKEN=* | *install.sh* | *bash*)
		err "Master 地址无效：请只填域名/IP，或粘贴完整一行「GPS_MESH_MASTER=... GPS_MESH_TOKEN=...」"
		;;
	esac
	((${#raw} < 256)) || err "Master 地址过长，请检查是否误粘贴了整段命令"
	gps_mesh_defaults
	local port=${MESH_MASTER_PORT:-19527}
	if [[ $raw == http://* || $raw == https://* ]]; then
		# 再拦一次被包进 URL 的垃圾
		case $raw in
		*GPS_MESH_* | *TOKEN=* | *install.sh*)
			err "Master URL 无效（含命令残留），请重新填写"
			;;
		esac
		printf '%s\n' "${raw%/}"
		return 0
	fi
	# [v6] 或 [v6]:port
	if [[ $raw == \[*\]* ]]; then
		if [[ $raw == \[*\]:* ]]; then
			printf 'http://%s\n' "$raw"
		else
			printf 'http://%s:%s\n' "$raw" "$port"
		fi
		return 0
	fi
	# 裸 IPv6
	if gps_mesh_looks_like_ipv6 "$raw"; then
		printf 'http://[%s]:%s\n' "$raw" "$port"
		return 0
	fi
	# host:port 或 host（IPv4 / 域名）— 单冒号才当 port
	local colons=${raw//[^:]/}
	if ((${#colons} == 1)); then
		printf 'http://%s\n' "$raw"
	elif ((${#colons} == 0)); then
		printf 'http://%s:%s\n' "$raw" "$port"
	else
		err "无法识别 Master 地址: $raw（域名/IPv4/IPv6 或 http://...）"
	fi
}

gps_mesh_become_master() {
	load_state 2>/dev/null || true
	MESH_ROLE=master
	gps_mesh_role_normalize
	PROFILE=mesh-member
	MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
	gps_mesh_defaults
	gps_mesh_ensure_cluster_token
	gps_mesh_resolve_master_host
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_install_mesh_units 2>/dev/null || true
	gps_restart_svc
	msg "$(_green "本机已设为 Master")"
	gps_mesh_print_join_hints
}

gps_mesh_become_member() {
	local url=${1:-}
	local token=${2:-}
	[[ -n $url ]] || err "用法: mesh join <Master地址> <TOKEN>"
	# 整行粘贴时自动拆出 TOKEN
	if [[ $url == *GPS_MESH_MASTER=* ]] || [[ -z $token && $url == *GPS_MESH_TOKEN=* ]]; then
		gps_mesh_parse_join_input "$url" || err "无法解析加入命令"
		url=$__MESH_PARSE_URL
		[[ -n $token ]] || token=$__MESH_PARSE_TOKEN
	fi
	[[ -n $token ]] || err "需要集群 TOKEN（在 Master 的 mesh show 中查看）"
	load_state 2>/dev/null || true
	MESH_ROLE=member
	gps_mesh_role_normalize
	PROFILE=mesh-member
	MESH_MASTER_URL=$(gps_mesh_normalize_master_url "$url")
	MESH_CLUSTER_TOKEN=$token
	# 去掉 TOKEN 里可能粘上的 bash/install 残留
	MESH_CLUSTER_TOKEN=${MESH_CLUSTER_TOKEN%%bash*}
	MESH_CLUSTER_TOKEN=${MESH_CLUSTER_TOKEN%%install*}
	MESH_CLUSTER_TOKEN=$(printf '%s' "$MESH_CLUSTER_TOKEN" | tr -d '[:space:]')
	[[ ${#MESH_CLUSTER_TOKEN} -ge 16 ]] || err "TOKEN 看起来不对，请从 Master「mesh show」复制"
	gps_mesh_ensure_dirs
	umask 077
	printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
	chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_install_mesh_units 2>/dev/null || true
	gps_restart_svc
	msg "$(_green "本机已设为 Node/成员") Master=$MESH_MASTER_URL"
	msg "将向 Master 注册并拉取 peers，实现相互发现"
}

# 菜单：选择 Master 或 Node 并填写
gps_mesh_menu_role() {
	load_state 2>/dev/null || true
	# 展示时若 Master URL 已损坏，给出提示
	local show_url=${MESH_MASTER_URL:-—}
	if [[ $show_url == *GPS_MESH_* || $show_url == *install.sh* || ${#show_url} -gt 120 ]]; then
		show_url="（当前配置已损坏，请选 2 重新填写）"
	fi
	msg "$(_cyan "Mesh 角色")"
	msg "  当前: MESH_ROLE=${MESH_ROLE:-?}  Master=${show_url}"
	msg "  1) 本机作为 Master（其它机器来加入）"
	msg "  2) 本机作为 Node（加入已有 Master）"
	msg "  0) 返回"
	local c
	read -r -p "请选择: " c
	case $c in
	1)
		gps_mesh_become_master
		;;
	2)
		local line url token
		msg "任选一种填写方式:"
		msg "  A) 粘贴 Master 上打印的整行（推荐）:"
		msg "     GPS_MESH_MASTER=http://... GPS_MESH_TOKEN=... bash install.sh"
		msg "  B) 分开填写：先地址（仅域名/IP），再 TOKEN"
		read -r -p "粘贴整行 或 只填 Master 地址: " line
		if [[ $line == *GPS_MESH_MASTER=* ]]; then
			gps_mesh_become_member "$line" ""
		else
			read -r -p "集群 TOKEN: " token
			gps_mesh_become_member "$line" "$token"
		fi
		;;
	0 | "") ;;
	*) warn "无效选项" ;;
	esac
}

# 安装时根据环境决定角色（零菜单）
gps_mesh_bootstrap_from_env() {
	# 显式 GPS_MESH_MASTER → 成员；否则已有 MESH_ROLE 保留；全新默认 master
	if [[ -n ${GPS_MESH_MASTER:-} ]]; then
		MESH_ROLE=member
		MESH_MASTER_URL=${GPS_MESH_MASTER%/}
		if [[ -n ${GPS_MESH_TOKEN:-} ]]; then
			MESH_CLUSTER_TOKEN=$GPS_MESH_TOKEN
		fi
		[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || err "成员安装需要 GPS_MESH_TOKEN（或 MESH_CLUSTER_TOKEN）与 GPS_MESH_MASTER"
	elif [[ -z ${MESH_ROLE:-} ]]; then
		MESH_ROLE=master
	fi
	gps_mesh_role_normalize
	PROFILE=mesh-member
	gps_profile_normalize
	gps_mesh_defaults
	if [[ $MESH_ROLE == master ]]; then
		MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
		gps_mesh_ensure_cluster_token
		gps_mesh_resolve_master_host
		MESH_MASTER_URL=$(gps_mesh_primary_join_url)
	else
		[[ -n ${MESH_MASTER_URL:-} ]] || err "成员需要 MESH_MASTER_URL 或 GPS_MESH_MASTER"
		gps_mesh_ensure_dirs
		if [[ -n ${MESH_CLUSTER_TOKEN:-} ]]; then
			umask 077
			printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
			chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
		fi
	fi
}
