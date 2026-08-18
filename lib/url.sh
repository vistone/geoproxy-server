#!/bin/bash
# URL / 二维码 / 信息（双栈）

gps_cmd_url() {
	msg "$(_cyan "TUIC URL")（IPv4/IPv6 自适应；复制到本地 GeoProxy 配置）:"
	gps_tuic_urls | while IFS= read -r u; do
		if [[ $u == *"@"*\[* ]]; then
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
		if [[ $u == *"@"*\[* ]]; then
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
	done < <(gps_tuic_urls)
	if [[ $n -eq 0 ]]; then
		err "无可用 TUIC URL"
	fi
}

gps_cmd_info() {
	load_state || err "未安装"
	detect_local_stack
	msg "$(_cyan "GeoProxy Server") $GPS_SH_VER"
	msg "  服务:     $GPS_SERVICE  ($(gps_svc_status_line))"
	msg "  核心:     $GPS_CORE_BIN  (ver=${CORE_VER:-?})"
	msg "  配置:     $GPS_CONFIG"
	msg "  端口:     $PORT"
	msg "  协议栈:   ${STACK_MODE:-?}（本机 v4=${HAS_V4} v6=${HAS_V6}）"
	msg "  UUID:     $UUID"
	msg "  密码:     ${PASSWORD:0:8}********"
	msg "  节点名:   $(gps_tuic_node_name)"
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
