#!/bin/bash
# 启用 BBR（若内核支持）

gps_enable_bbr() {
	need_root
	if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
		msg "$(_green "BBR 已启用")"
		return 0
	fi
	if ! grep -q tcp_bbr /proc/modules 2>/dev/null && ! modprobe tcp_bbr 2>/dev/null; then
		warn "无法加载 tcp_bbr 模块，请检查内核是否支持 BBR"
		return 1
	fi
	cat >/etc/sysctl.d/99-geoproxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
	sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-geoproxy-bbr.conf
	if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
		msg "$(_green "BBR 已启用")"
	else
		err "BBR 启用失败"
	fi
}
