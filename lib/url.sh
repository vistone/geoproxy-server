#!/bin/bash
# URL / 二维码 / 信息（双栈；协议无关分发）

gps_cmd_url() {
	load_state 2>/dev/null || true
	gps_protocol_normalize 2>/dev/null || true
	msg "$(_cyan "分享 URL")（协议=${PROTOCOL:-tuic}；IPv4/IPv6 自适应）:"
	gps_proto_share_urls | while IFS= read -r u; do
		if [[ $u == *"@"*\[* ]] || [[ $u == *\[*\]* ]]; then
			msg "  $(_cyan IPv6) $u"
		else
			msg "  $(_cyan IPv4) $u"
		fi
	done
}

gps_cmd_qr() {
	local u has_qr=0
	if have_cmd qrencode; then
		has_qr=1
	else
		warn "未安装 qrencode，仅打印 URL。可: apt install qrencode"
	fi
	local n=0
	while IFS= read -r u; do
		[[ -n $u ]] || continue
		n=$((n + 1))
		if [[ $u == *"@"*\[* ]] || [[ $u == *\[*\]* ]]; then
			msg
			msg "$(_cyan "IPv6 二维码")"
		else
			msg
			msg "$(_cyan "IPv4 二维码")"
		fi
		msg "$u"
		if [[ $has_qr -eq 1 ]]; then
			qrencode -t ANSIUTF8 "$u"
		fi
	done < <(gps_proto_share_urls)
	if [[ $n -eq 0 ]]; then
		err "无可用分享 URL"
	fi
}

gps_cmd_info() {
	load_state || err "未安装"
	detect_local_stack
	gps_protocol_normalize 2>/dev/null || true
	msg "$(_cyan "GeoProxy Server") $GPS_SH_VER"
	msg "  服务:     $GPS_SERVICE  ($(gps_svc_status_line))"
	msg "  核心:     $GPS_CORE_BIN  (ver=${CORE_VER:-?})"
	msg "  配置:     $GPS_CONFIG"
	msg "  端口:     $PORT"
	msg "  入站协议: ${PROTOCOL:-tuic}"
	msg "  PROFILE:   ${PROFILE:-edge}"
	msg "  协议栈:   ${STACK_MODE:-?}（本机 v4=${HAS_V4} v6=${HAS_V6}）"
	msg "  UUID:     ${UUID:-（无）}"
	if [[ -n ${PASSWORD:-} ]]; then
		msg "  密码:     ${PASSWORD:0:8}********"
	else
		msg "  密码:     （无）"
	fi
	msg "  节点名:   $(gps_proto_node_name)"
	msg "  公网 IPv4:${PUBLIC_IP:-（未设置）}"
	msg "  公网 IPv6:${PUBLIC_IP6:-（未设置）}"
	msg "  日志级别: $(gps_config_log_level 2>/dev/null || echo "${LOG_LEVEL:-debug}")（进/出站连接需 debug）"
	msg "  日志文件: $GPS_LOG"
	gps_traffic_defaults 2>/dev/null || true
	if [[ -n ${KIWI_VEID:-} ]]; then
		msg "  KiwiVM:   veid=$KIWI_VEID key=$(gps_mask_key "${KIWI_API_KEY:-}")"
		msg "  流量:     last=${TRAFFIC_LAST_PCT:-?}% warn=${TRAFFIC_WARN_PCT}% stop=${TRAFFIC_STOP_PCT}% tripped=${TRAFFIC_TRIPPED}"
	else
		msg "  KiwiVM:   （未配置 — change kiwivm <veid> <api_key>）"
	fi
	msg "  安装于:   ${INSTALLED_AT:-?}"
}
