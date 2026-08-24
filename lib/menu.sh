#!/bin/bash
# 交互菜单

gps_menu() {
	while true; do
		echo
		msg "$(_cyan "======== GeoProxy Server $GPS_SH_VER ========")"
		if [[ -f $GPS_STATE ]]; then
			load_state 2>/dev/null || true
			gps_traffic_defaults 2>/dev/null || true
			local trip=""
			[[ ${TRAFFIC_TRIPPED:-0} == 1 ]] && trip=" $(_red TRIPPED)"
			msg "  状态: $(gps_svc_status_line)  协议: ${PROTOCOL:-tuic}  组网: ${MESH_ROLE:-master}  端口: ${PORT:-?}  流量: ${TRAFFIC_LAST_PCT:-?}%${trip}"
		else
			msg " 状态: $(_yellow "未安装")"
		fi
		msg "--------------------------------------------"
		msg "  1) 安装 / 重装（保留配置，拉取最新脚本）"
		msg "  2) 查看信息"
		msg "  3) 显示分享 URL（IPv4/IPv6）"
		msg "  4) 二维码"
		msg "  5) 修改端口"
		msg "  6) 修改 UUID"
		msg "  7) 修改密码"
		msg "  8) 切换入站协议"
		msg "  9) 修改公网 IPv4"
		msg " 10) 修改公网 IPv6"
		msg " 11) 重探双栈公网地址 (ips)"
		msg " 12) 启动 / 停止 / 重启"
		msg " 13) 查看日志（跟随，看进站/出站）"
		msg " 14) 设置日志级别"
		msg " 15) 配置 KiwiVM（VEID / API Key）"
		msg " 16) 查看流量 / 阈值"
		msg " 17) 立即流量检查"
		msg " 18) 流量熔断恢复 (resume)"
		msg " 19) 修改流量告警/停服阈值"
		msg " 20) 升级管理脚本（geoproxy-server）"
		msg " 21) 升级 sing-box 核心"
		msg " 22) 启用 BBR"
		msg " 23) 健康检查 doctor"
		msg " 24) 列出协议"
		msg " 25) Mesh 状态"
		msg " 26) Mesh 角色（Master / Node，相互发现）"
		msg " 27) 设置 mesh-exit 跳板"
		msg " 28) 卸载"
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
			gps_cmd_protocols
			read -r -p "协议 id: " proto
			[[ -n $proto ]] && gps_cmd_change protocol "$proto"
			;;
		9)
			read -r -p "公网 IPv4 (空=自动探测): " ip
			gps_cmd_change ip "${ip:-auto}"
			;;
		10)
			read -r -p "公网 IPv6 (空=自动探测): " ip6
			gps_cmd_change ip6 "${ip6:-auto}"
			;;
		11) gps_cmd_change ips ;;
		12)
			read -r -p "start / stop / restart: " a
			case $a in
			start) gps_svc_boot && msg "ok" || true ;;
			stop) gps_svc_halt && msg "ok" || true ;;
			restart) gps_restart_svc && msg "ok" || true ;;
			*) warn "无效操作" ;;
			esac
			;;
		13)
			msg "跟随日志中…（Ctrl+C 返回菜单）"
			gps_cmd_log -f || true
			;;
		14)
			read -r -p "日志级别 [debug]: " lv
			gps_cmd_change log "${lv:-debug}"
			;;
		15)
			read -r -p "VEID: " veid
			read -r -p "API Key: " key
			gps_cmd_change kiwivm "$veid" "$key"
			;;
		16) gps_cmd_traffic status || true ;;
		17) gps_cmd_traffic check || true ;;
		18) gps_cmd_traffic resume || true ;;
		19)
			read -r -p "告警阈值% [80]: " w
			read -r -p "停服阈值% [95]: " s
			[[ -n $w ]] && gps_cmd_change traffic-warn "$w"
			[[ -n $s ]] && gps_cmd_change traffic-stop "$s"
			;;
		20)
			msg "将从 GitHub 升级 geoproxy-server 管理脚本（保留配置）"
			gps_cmd_upgrade self
			;;
		21)
			msg "将升级到最新稳定版 sing-box"
			gps_cmd_upgrade core
			;;
		22) gps_enable_bbr ;;
		23) gps_doctor || true ;;
		24) gps_cmd_protocols ;;
		25)
			gps_mesh_cmd_show || true
			;;
		26)
			gps_mesh_menu_role || true
			;;
		27)
			read -r -p "mesh-exit node_id (none=清除): " eid
			[[ -n $eid ]] && gps_cmd_change mesh-exit "$eid"
			;;
		28)
			gps_cmd_uninstall || true
			;;
		0 | q | quit | exit) exit 0 ;;
		*) warn "无效选项" ;;
		esac
	done
}
