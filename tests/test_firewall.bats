#!/usr/bin/env bats
# 本机防火墙后端探测与放行（测试前缀不改宿主机规则）

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
}

@test "firewall backend prefers active ufw over firewalld and iptables" {
	have_cmd() {
		case $1 in
		ufw | firewall-cmd | iptables | nft) return 0 ;;
		*) type -P "$1" >/dev/null 2>&1 ;;
		esac
	}
	gps_fw_ufw_active() { return 0; }
	gps_fw_firewalld_active() { return 0; }
	[[ "$(gps_fw_backend)" == ufw ]]
}

@test "firewall backend uses firewalld when ufw is inactive" {
	have_cmd() {
		case $1 in
		firewall-cmd | iptables) return 0 ;;
		ufw | nft) return 1 ;;
		*) type -P "$1" >/dev/null 2>&1 ;;
		esac
	}
	gps_fw_ufw_active() { return 1; }
	gps_fw_firewalld_active() { return 0; }
	[[ "$(gps_fw_backend)" == firewalld ]]
}

@test "firewall backend falls back to iptables then nft then none" {
	have_cmd() {
		case $1 in
		iptables) return 0 ;;
		ufw | firewall-cmd | nft) return 1 ;;
		*) type -P "$1" >/dev/null 2>&1 ;;
		esac
	}
	gps_fw_ufw_active() { return 1; }
	gps_fw_firewalld_active() { return 1; }
	[[ "$(gps_fw_backend)" == iptables ]]

	have_cmd() {
		case $1 in
		nft) return 0 ;;
		ufw | firewall-cmd | iptables) return 1 ;;
		*) type -P "$1" >/dev/null 2>&1 ;;
		esac
	}
	[[ "$(gps_fw_backend)" == nft ]]

	have_cmd() {
		case $1 in
		ufw | firewall-cmd | iptables | nft) return 1 ;;
		*) type -P "$1" >/dev/null 2>&1 ;;
		esac
	}
	[[ "$(gps_fw_backend)" == none ]]
}

@test "allow tcp under test prefix records intent without calling host firewall" {
	GPS_FW_LAST_ALLOW=""
	GPS_FW_RAN=""
	ufw() { GPS_FW_RAN=ufw; }
	iptables() { GPS_FW_RAN=iptables; }
	firewall-cmd() { GPS_FW_RAN=firewalld; }
	nft() { GPS_FW_RAN=nft; }
	gps_fw_allow_tcp 19527 "geoproxy-mesh-control"
	[ "$GPS_FW_LAST_ALLOW" = "19527/tcp" ]
	[ -z "${GPS_FW_RAN:-}" ]
}

@test "allow tcp with GPS_FW_FORCE dispatches to mocked ufw" {
	have_cmd() {
		[[ $1 == ufw ]] && return 0
		type -P "$1" >/dev/null 2>&1
	}
	gps_fw_ufw_active() { return 0; }
	GPS_FW_UFW_ARGS=""
	ufw() {
		GPS_FW_UFW_ARGS="$*"
		return 0
	}
	GPS_FW_FORCE=1 gps_fw_allow_tcp 19527 "geoproxy-mesh-control"
	[[ "$GPS_FW_UFW_ARGS" == *"19527/tcp"* ]]
}

@test "tcp allowed under test prefix follows last allow record" {
	GPS_FW_LAST_ALLOW=""
	! gps_fw_tcp_allowed 19527
	gps_fw_allow_tcp 19527 "x"
	gps_fw_tcp_allowed 19527
	! gps_fw_tcp_allowed 443
}

@test "allow udp under test prefix records intent without calling host firewall" {
	GPS_FW_LAST_ALLOW_UDP=""
	GPS_FW_RAN=""
	ufw() { GPS_FW_RAN=ufw; }
	iptables() { GPS_FW_RAN=iptables; }
	firewall-cmd() { GPS_FW_RAN=firewalld; }
	nft() { GPS_FW_RAN=nft; }
	gps_fw_allow_udp 51820 "geoproxy-mesh-wg"
	[ "$GPS_FW_LAST_ALLOW_UDP" = "51820/udp" ]
	[ -z "${GPS_FW_RAN:-}" ]
}

@test "allow udp with GPS_FW_FORCE dispatches to mocked ufw" {
	have_cmd() {
		[[ $1 == ufw ]] && return 0
		type -P "$1" >/dev/null 2>&1
	}
	gps_fw_ufw_active() { return 0; }
	GPS_FW_UFW_ARGS=""
	ufw() {
		GPS_FW_UFW_ARGS="$*"
		return 0
	}
	GPS_FW_FORCE=1 gps_fw_allow_udp 51820 "geoproxy-mesh-wg"
	[[ "$GPS_FW_UFW_ARGS" == *"51820/udp"* ]]
}

@test "udp allowed under test prefix follows last allow record" {
	GPS_FW_LAST_ALLOW_UDP=""
	! gps_fw_udp_allowed 51820
	gps_fw_allow_udp 51820 "x"
	gps_fw_udp_allowed 51820
	! gps_fw_udp_allowed 443
}
