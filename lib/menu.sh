#!/bin/bash
# 交互菜单

gps_menu() {
	while true; do
		echo
		msg "$(_cyan "======== GeoProxy Server $GPS_SH_VER ========")"
		if [[ -f $GPS_STATE ]]; then
			load_state 2>/dev/null || true
			msg " 状态: $(gps_svc_status_line)  端口: ${PORT:-?}  日志: $(gps_config_log_level 2>/dev/null || echo ?)  v4: ${PUBLIC_IP:-?}  v6: ${PUBLIC_IP6:-?}"
		else
			msg " 状态: $(_yellow "未安装")"
		fi
		msg "--------------------------------------------"
		msg "  1) 安装 / 重装"
		msg "  2) 查看信息"
		msg "  3) 显示 TUIC URL（IPv4/IPv6）"
		msg "  4) 二维码"
		msg "  5) 修改端口"
		msg "  6) 修改 UUID"
		msg "  7) 修改密码"
		msg "  8) 修改公网 IPv4"
		msg "  9) 修改公网 IPv6"
		msg " 10) 重探双栈公网地址 (ips)"
		msg " 11) 启动 / 停止 / 重启"
		msg " 12) 查看日志（跟随，看进站/出站）"
		msg " 13) 设置日志级别（debug=进/出站）"
		msg " 14) 升级 sing-box（最新）"
		msg " 15) 启用 BBR"
		msg " 16) 健康检查 doctor"
		msg " 17) 卸载"
		msg "  0) 退出"
		msg "--------------------------------------------"
		local c
		read -r -p "请选择: " c
		case $c in
		1) gps_cmd_install ;;
		2) gps_cmd_info ;;
		3) gps_cmd_url ;;
		4) gps_cmd_qr ;;
		5)
			read -r -p "新端口 (空=auto): " p
			gps_cmd_change port "${p:-auto}"
			;;
		6)
			read -r -p "新 UUID (空=auto): " u
			gps_cmd_change uuid "${u:-auto}"
			;;
		7)
			read -r -p "新密码 (空=auto): " pw
			gps_cmd_change passwd "${pw:-auto}"
			;;
		8)
			read -r -p "公网 IPv4 (空=自动探测): " ip
			gps_cmd_change ip "${ip:-auto}"
			;;
		9)
			read -r -p "公网 IPv6 (空=自动探测): " ip6
			gps_cmd_change ip6 "${ip6:-auto}"
			;;
		10) gps_cmd_change ips ;;
		11)
			read -r -p "start / stop / restart: " a
			case $a in
			start | stop | restart) gps_svc "$a" && msg "ok" ;;
			*) warn "无效操作" ;;
			esac
			;;
		12)
			msg "跟随日志中… 客户端连上后会出现 inbound/tuic 与 outbound/direct（Ctrl+C 返回菜单）"
			gps_cmd_log -f || true
			;;
		13)
			msg "级别说明: debug=进站/出站连接  info=仅启动  warn=几乎无输出"
			read -r -p "日志级别 [debug]: " lv
			gps_cmd_change log "${lv:-debug}"
			;;
		14)
			msg "将升级到最新稳定版 sing-box"
			gps_cmd_upgrade
			;;
		15) gps_enable_bbr ;;
		16) gps_doctor || true ;;
		17) gps_cmd_uninstall ;;
		0 | q | quit | exit) exit 0 ;;
		*) warn "无效选项" ;;
		esac
	done
}
