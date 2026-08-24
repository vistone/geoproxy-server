#!/bin/bash
# 本机防火墙：放行 / 查询 TCP 端口
# 探测顺序：活动的 ufw → 活动的 firewalld → iptables → nft → none
# 不管云厂商安全组（阿里云/腾讯云/AWS 等需在控制台另行放行）。

# 当前后端名：ufw | firewalld | iptables | nft | none（始终 exit 0）
gps_fw_backend() {
	if have_cmd ufw && gps_fw_ufw_active; then
		printf '%s\n' ufw
	elif have_cmd firewall-cmd && gps_fw_firewalld_active; then
		printf '%s\n' firewalld
	elif have_cmd iptables; then
		printf '%s\n' iptables
	elif have_cmd nft; then
		printf '%s\n' nft
	else
		printf '%s\n' none
	fi
	return 0
}

gps_fw_ufw_active() {
	have_cmd ufw || return 1
	local st
	st=$(ufw status 2>/dev/null | head -n1) || return 1
	[[ $st == *[Aa]ctive* || $st == *活跃* || $st == *激活* ]]
}

gps_fw_firewalld_active() {
	have_cmd firewall-cmd || return 1
	firewall-cmd --state >/dev/null 2>&1
}

# 测试前缀默认不改宿主机；GPS_FW_FORCE=1 时走真实/mock 后端
gps_fw_skip_host() {
	[[ -n ${GPS_TEST_PREFIX:-} && ${GPS_FW_FORCE:-0} != 1 ]]
}

# 放行 TCP 端口。comment 仅用于 ufw。成功则写入 GPS_FW_LAST_ALLOW=PORT/tcp
gps_fw_allow_tcp() {
	local port=${1:-}
	local comment=${2:-geoproxy}
	gps_validate_port "$port" || return 1
	GPS_FW_LAST_ALLOW="${port}/tcp"
	GPS_FW_LAST_BACKEND=$(gps_fw_backend)
	if gps_fw_skip_host; then
		return 0
	fi
	case ${GPS_FW_LAST_BACKEND} in
	ufw) gps_fw_allow_ufw_tcp "$port" "$comment" ;;
	firewalld) gps_fw_allow_firewalld_tcp "$port" ;;
	iptables) gps_fw_allow_iptables_tcp "$port" ;;
	nft) gps_fw_allow_nft_tcp "$port" ;;
	none) return 0 ;;
	*) return 1 ;;
	esac
}

gps_fw_allow_ufw_tcp() {
	local port=$1 comment=$2
	ufw allow "${port}/tcp" comment "$comment" >/dev/null
}

gps_fw_allow_firewalld_tcp() {
	local port=$1
	# 同时写 runtime + permanent，避免 --reload 打断已有连接
	firewall-cmd --add-port="${port}/tcp" >/dev/null 2>&1 || true
	firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
	firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1
}

gps_fw_allow_iptables_tcp() {
	local port=$1
	if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
		iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
	fi
	if have_cmd ip6tables; then
		if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
			ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
		fi
	fi
	return 0
}

gps_fw_allow_nft_tcp() {
	local port=$1
	if gps_fw_nft_has_tcp "$port"; then
		return 0
	fi
	nft add rule inet filter input tcp dport "$port" accept >/dev/null 2>&1 && return 0
	nft add rule ip filter INPUT tcp dport "$port" accept >/dev/null 2>&1 && return 0
	return 1
}

gps_fw_nft_has_tcp() {
	local port=$1
	nft list ruleset 2>/dev/null | grep -qE "tcp dport ${port} .*accept"
}

# 本机规则是否已放行该 TCP 端口（none = 没有本机防火墙可拦，视为放行）
gps_fw_tcp_allowed() {
	local port=${1:-}
	gps_validate_port "$port" || return 1
	if gps_fw_skip_host; then
		[[ ${GPS_FW_LAST_ALLOW:-} == "${port}/tcp" ]]
		return
	fi
	local backend
	backend=$(gps_fw_backend)
	case $backend in
	ufw)
		ufw status 2>/dev/null | grep -qE "${port}/tcp" || return 1
		ufw status 2>/dev/null | grep -E "${port}/tcp" | grep -qiE 'ALLOW|允许'
		;;
	firewalld)
		firewall-cmd --query-port="${port}/tcp" >/dev/null 2>&1
		;;
	iptables)
		iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1
		;;
	nft)
		gps_fw_nft_has_tcp "$port"
		;;
	none)
		return 0
		;;
	*)
		return 1
		;;
	esac
}
