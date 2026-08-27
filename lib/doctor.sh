#!/bin/bash
# 健康检查（含双栈）

# 目录所在分区使用率（0-100 整数）；取不到返回 1
gps_disk_usage_pct() {
	local dir=${1:-$GPS_LOG_DIR}
	local p
	p=$(df -P "$dir" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}') || return 1
	[[ $p =~ ^[0-9]+$ ]] || return 1
	echo "$p"
}

gps_doctor() {
	local ok=0 fail=0
	check() {
		local name=$1
		shift
		if "$@"; then
			msg "  $(_green OK)  $name"
			ok=$((ok + 1))
		else
			msg "  $(_red FAIL) $name"
			fail=$((fail + 1))
		fi
	}
	warn_item() {
		msg "  $(_yellow WARN) $1"
	}

	msg "$(_cyan "== GeoProxy Server doctor ==")"
	detect_local_stack
	msg "  本机栈: STACK_MODE=${STACK_MODE} HAS_V4=${HAS_V4} HAS_V6=${HAS_V6}"

	# 日志目录所在分区：写满会导致 sing-box / state 全部写失败
	local dpct
	if dpct=$(gps_disk_usage_pct "$GPS_LOG_DIR"); then
		if ((dpct >= 95)); then
			msg "  $(_red FAIL) 磁盘使用 ${dpct}%（日志分区 ${GPS_LOG_DIR}）— 清理或扩容"
			fail=$((fail + 1))
		elif ((dpct >= 90)); then
			warn_item "磁盘使用 ${dpct}%（日志分区）— 建议清理，写满会导致服务不可用"
		else
			msg "  $(_green OK)  磁盘使用 ${dpct}%"
			ok=$((ok + 1))
		fi
	else
		warn_item "无法读取磁盘使用率（df）"
	fi

	check "systemd 可用" need_systemd_ok
	check "sing-box 二进制可执行" test -x "$GPS_CORE_BIN"
	check "配置文件存在" test -f "$GPS_CONFIG"
	check "state.env 存在" test -f "$GPS_STATE"
	check "TLS 证书存在" test -f "$GPS_CERT"
	check "TLS 私钥存在" test -f "$GPS_KEY"
	if [[ -x $GPS_CORE_BIN && -f $GPS_CONFIG ]]; then
		check "sing-box check" "$GPS_CORE_BIN" check -c "$GPS_CONFIG"
	else
		msg "  $(_yellow SKIP) sing-box check（缺二进制或配置）"
	fi
	if have_cmd systemctl && [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
		check "服务 active" systemctl is-active --quiet "$GPS_SERVICE"
	elif [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		check "sing-box 进程 (no-systemd)" gps_pid_running
	fi
	if load_state 2>/dev/null; then
		check "PORT 已设置 ($PORT)" test -n "$PORT"
		if [[ -n $PORT ]] && have_cmd ss; then
			# IPv4 UDP
			if ((HAS_V4)); then
				if ss -lun4 2>/dev/null | grep -qE ":${PORT}\\b" || ss -lun | grep -qE "0\\.0\\.0\\.0:${PORT}\\b|\\*:${PORT}\\b"; then
					msg "  $(_green OK)  UDP IPv4 监听 :$PORT"
					ok=$((ok + 1))
				else
					# 部分系统 ss -lun 合并显示
					if ss -lun | grep -qE ":${PORT}\\b"; then
						msg "  $(_green OK)  UDP 监听 :$PORT（未区分族）"
						ok=$((ok + 1))
					else
						msg "  $(_red FAIL) UDP IPv4 监听 :$PORT"
						fail=$((fail + 1))
					fi
				fi
			fi
			if ((HAS_V6)); then
				if ss -lun6 2>/dev/null | grep -qE ":${PORT}\\b" || ss -lun | grep -qE "\\[::\\]:${PORT}|:::${PORT}|\\*:${PORT}\\b"; then
					msg "  $(_green OK)  UDP IPv6 监听 :$PORT"
					ok=$((ok + 1))
				else
					warn_item "UDP IPv6 监听 :$PORT 未看到（若仅有 IPv4 公网可忽略）"
				fi
			fi
		fi
		if [[ -n ${PUBLIC_IP:-} ]]; then
			msg "  $(_green OK)  PUBLIC_IP(v4)=${PUBLIC_IP}"
			ok=$((ok + 1))
		else
			warn_item "PUBLIC_IP(v4) 未设置 — change ip <v4> 或依赖自动探测"
		fi
		if [[ -n ${PUBLIC_IP6:-} ]]; then
			msg "  $(_green OK)  PUBLIC_IP6=${PUBLIC_IP6}"
			ok=$((ok + 1))
		else
			warn_item "PUBLIC_IP6 未设置 — 无 IPv6 公网时可忽略；有则: change ip6 <v6>"
		fi
		if [[ -z ${PUBLIC_IP:-} && -z ${PUBLIC_IP6:-} ]]; then
			msg "  $(_red FAIL) 无任何公网地址（url 无法对接 GeoProxy）"
			fail=$((fail + 1))
		fi
		gps_traffic_defaults
		if [[ -n ${KIWI_VEID:-} && -n ${KIWI_API_KEY:-} ]]; then
			msg "  $(_green OK)  KiwiVM 已配置 veid=$KIWI_VEID"
			[[ -f ${GPS_KIWI_PERSIST:-} ]] && msg "  长期凭证: $GPS_KIWI_PERSIST（卸载后保留）"
			ok=$((ok + 1))
			msg "  流量阈值: warn=${TRAFFIC_WARN_PCT}% stop=${TRAFFIC_STOP_PCT}% tripped=${TRAFFIC_TRIPPED} last=${TRAFFIC_LAST_PCT:-?}%"
			if [[ ${TRAFFIC_TRIPPED:-0} == 1 ]]; then
				warn_item "流量熔断中 — 用量低于停服线后将自动恢复，或: traffic resume"
			fi
			if have_cmd systemctl && [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
				if systemctl is-active --quiet geoproxy-traffic.timer 2>/dev/null; then
					msg "  $(_green OK)  geoproxy-traffic.timer active"
					ok=$((ok + 1))
				else
					warn_item "geoproxy-traffic.timer 未 active — change kiwivm 后会启用"
				fi
			fi
		else
			warn_item "未配置 KiwiVM（流量熔断未启用）— change kiwivm <veid> <api_key>"
		fi
	fi
	# Mesh（始终启用）
	if load_state 2>/dev/null; then
		gps_mesh_role_normalize 2>/dev/null || true
		check "mesh peers 文件" test -f "$GPS_MESH_PEERS"
		check "WG 公钥已设置" test -n "${WG_PUBLIC_KEY:-}"
		check "overlay IP 已设置" test -n "${MESH_OVERLAY_IP:-}"
		msg "  $(_green OK)  MESH_ROLE=${MESH_ROLE:-?}"
		ok=$((ok + 1))
		if [[ ${MESH_ROLE:-} == master ]]; then
			check "mesh cluster token" test -n "${MESH_CLUSTER_TOKEN:-}"
			local hp=${MESH_MASTER_PORT:-19527}
			local health_rc=0
			gps_mesh_print_local_health "$hp" || health_rc=$?
			case $health_rc in
			0) ok=$((ok + 1)) ;;
			*) fail=$((fail + 1)) ;;
			esac
			msg "  $(_green OK)  mesh-failover=${MESH_FAILOVER:-0}（本机直连优先，故障自动切对端）"
			gps_mesh_print_control_plane_status 2>/dev/null || true
		elif [[ ${MESH_ROLE:-} == member ]]; then
			check "MESH_MASTER_URL 已设置" test -n "${MESH_MASTER_URL:-}"
			local member_http_public=0
			if [[ -n ${MESH_MASTER_URL:-} && ${MESH_MASTER_URL} == http://* ]]; then
				local mhost
				mhost=$(gps_mesh_url_host "$MESH_MASTER_URL")
				if ! gps_mesh_url_is_loopback "$mhost"; then
					msg "  $(_red FAIL) 明文 http 公网 Master: ${MESH_MASTER_URL}"
					fail=$((fail + 1))
					member_http_public=1
				fi
			fi
			if [[ -n ${MESH_MASTER_URL:-} && ${MESH_MASTER_URL} == https://* && -z ${MESH_TLS_PIN:-} ]]; then
				warn_item "https Master 未配置 MESH_TLS_PIN（自签证书将校验失败；请在 Master 上 mesh show 获取 GPS_MESH_TLS_PIN）"
			fi
			if [[ -n ${MESH_MASTER_URL:-} && member_http_public -eq 0 ]]; then
				local mh_rc=0
				gps_mesh_print_member_health || mh_rc=$?
				case $mh_rc in
				0) ok=$((ok + 1)) ;;
				*) fail=$((fail + 1)) ;;
				esac
			fi
			msg "  若 Node 连不上 Master：到 Master 上确认 TCP ${MESH_MASTER_PORT:-19527} 已对外放行（本机防火墙 + 云安全组）"
		fi
		if [[ -n ${MESH_EXIT_NODE_ID:-} && $MESH_EXIT_NODE_ID == "${NODE_ID:-}" ]]; then
			msg "  $(_red FAIL) mesh-exit 指向自己（环路风险）"
			fail=$((fail + 1))
		elif [[ -n ${MESH_EXIT_NODE_ID:-} ]]; then
			msg "  $(_green OK)  mesh-exit=$MESH_EXIT_NODE_ID"
			ok=$((ok + 1))
		fi
		if [[ -n ${WG_LISTEN_PORT:-} ]] && have_cmd ss; then
			if ss -lun 2>/dev/null | grep -qE ":${WG_LISTEN_PORT}\\b"; then
				msg "  $(_green OK)  WG UDP 监听 :$WG_LISTEN_PORT"
				ok=$((ok + 1))
			else
				warn_item "WG UDP :${WG_LISTEN_PORT} 未看到（服务未起）"
			fi
		fi
		gps_mesh_print_wg_data_plane_status 2>/dev/null || true
	fi
	msg
	msg "结果: ok=$ok fail=$fail"
	((fail == 0))
}

need_systemd_ok() {
	have_cmd systemctl
}
