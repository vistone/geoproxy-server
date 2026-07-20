#!/bin/bash
# CLI 子命令

gps_parse_install_args() {
	PORT=""
	UUID=""
	PASSWORD=""
	PUBLIC_IP=""
	PUBLIC_IP6=""
	CORE_VER_ARG=""
	INSTALL_PREFIX=""
	while [[ $# -gt 0 ]]; do
		case $1 in
		--port)
			PORT=$2
			shift 2
			;;
		--uuid)
			UUID=$2
			PASSWORD=${PASSWORD:-$2}
			shift 2
			;;
		--passwd | --password)
			PASSWORD=$2
			shift 2
			;;
		--ip)
			PUBLIC_IP=$2
			shift 2
			;;
		--ip6)
			PUBLIC_IP6=$2
			shift 2
			;;
		--ver)
			CORE_VER_ARG=$2
			shift 2
			;;
		--prefix)
			INSTALL_PREFIX=$2
			shift 2
			;;
		--no-systemd)
			GPS_NO_SYSTEMD=1
			shift
			;;
		-h | --help)
			gps_help_install
			exit 0
			;;
		*)
			err "未知参数: $1"
			;;
		esac
	done
}

gps_help_install() {
	cat <<EOF
Usage: $GPS_NAME install [options]
  --port N       UDP 端口（默认随机）
  --uuid U       UUID（默认自动生成；密码默认与 UUID 相同）
  --passwd P     密码（默认等于 UUID）
  --ip IP        公网 IPv4（默认自动探测）
  --ip6 IP       公网 IPv6（默认自动探测）
  --prefix DIR   安装到 DIR（本地测试，可无 root）
  --no-systemd   不用 systemd，前台后台拉起 sing-box（配合 --prefix）
  --ver TAG      仅排障：指定 sing-box 版本；默认省略，始终装最新稳定版

说明: 本机双栈时自动监听 0.0.0.0 + ::；有哪个公网地址就输出哪个 TUIC URL。
EOF
}

gps_cmd_install() {
	gps_parse_install_args "$@"
	if [[ -n $INSTALL_PREFIX ]]; then
		GPS_TEST_PREFIX=$INSTALL_PREFIX
		gps_apply_paths
		GPS_NO_SYSTEMD=${GPS_NO_SYSTEMD:-1}
		export GPS_TEST_PREFIX GPS_NO_SYSTEMD
		msg "$(_cyan "测试/前缀安装") prefix=$GPS_TEST_PREFIX no_systemd=$GPS_NO_SYSTEMD"
	fi
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
		need_systemd
	fi
	ensure_deps

	if [[ -f $GPS_STATE ]]; then
		warn "检测到已安装配置: $GPS_STATE"
		if [[ -t 0 ]]; then
			confirm_yes "覆盖并重装?" || err "已取消"
		else
			msg "非交互：覆盖已有配置"
		fi
	fi

	gps_download_core "${CORE_VER_ARG:-latest}"

	[[ -n $PORT ]] || PORT=$(rand_port)
	[[ -n $UUID ]] || UUID=$(gen_uuid)
	[[ -n $PASSWORD ]] || PASSWORD=$UUID
	detect_local_stack
	if [[ -z ${PUBLIC_IP:-} || -z ${PUBLIC_IP6:-} ]]; then
		detect_public_ips || warn "公网地址探测不完整，可稍后: change ip / change ip6 / change ips"
	fi
	[[ -z ${PUBLIC_IP:-} ]] && PUBLIC_IP=$(detect_public_ipv4) || true
	[[ -z ${PUBLIC_IP6:-} ]] && PUBLIC_IP6=$(detect_public_ipv6) || true
	INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	LOG_LEVEL=${LOG_LEVEL:-debug}

	gps_write_config
	save_state
	gps_install_unit
	gps_install_entrypoint
	gps_restart_svc

	msg
	msg "$(_green "安装完成")"
	gps_cmd_info
	msg
	gps_cmd_url
}

gps_install_entrypoint() {
	mkdir -p "$(dirname "$GPS_BIN_LINK")"
	local src="${GPS_ROOT}/geoproxy-server.sh"
	[[ -f $src ]] || err "找不到入口脚本: $src"
	mkdir -p "$GPS_LIB_DIR/scripts"
	rm -rf "${GPS_LIB_DIR}/scripts/"*
	cp -a "$GPS_ROOT/." "${GPS_LIB_DIR}/scripts/"
	cat >"$GPS_BIN_LINK" <<EOF
#!/bin/bash
export GPS_TEST_PREFIX='${GPS_TEST_PREFIX:-}'
export GPS_NO_SYSTEMD='${GPS_NO_SYSTEMD:-0}'
exec bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" "\$@"
EOF
	chmod 755 "$GPS_BIN_LINK"
}

gps_cmd_uninstall() {
	local force=0
	[[ ${1:-} == -y || ${1:-} == --yes ]] && force=1
	# 允许通过环境恢复前缀
	if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_apply_paths
	elif [[ -f /etc/geoproxy-server/state.env ]]; then
		# shellcheck disable=SC1091
		set -a
		# shellcheck source=/dev/null
		source /etc/geoproxy-server/state.env 2>/dev/null || true
		set +a
		[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	fi
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	if ((force == 0)); then
		if [[ -t 0 ]]; then
			confirm_yes "确认卸载 $GPS_NAME（停止服务并删除配置）?" || err "已取消"
		fi
	fi
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_stop_bg 2>/dev/null || true
		gps_remove_traffic_timer 2>/dev/null || true
	elif have_cmd systemctl; then
		gps_remove_traffic_timer 2>/dev/null || true
		systemctl stop "$GPS_SERVICE" 2>/dev/null || true
		systemctl disable "$GPS_SERVICE" 2>/dev/null || true
		rm -f "$GPS_UNIT_PATH"
		systemctl daemon-reload 2>/dev/null || true
	fi
	rm -f "$GPS_BIN_LINK"
	if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
		rm -rf "$GPS_TEST_PREFIX"
	else
		rm -rf "$GPS_ETC" "$GPS_LIB_DIR" "$GPS_LOG_DIR"
	fi
	msg "$(_green "已卸载")"
}

gps_cmd_upgrade() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	# 默认升级脚本；upgrade core → 只升 sing-box；upgrade all → 两者
	local target=self
	if [[ $# -gt 0 ]]; then
		case $1 in
		self | script | scripts)
			target=self
			shift
			;;
		core | sing-box | singbox)
			target=core
			shift
			;;
		all | both)
			target=all
			shift
			;;
		--ver | --force | -f)
			# 无子命令时默认 self，参数留给 self
			target=self
			;;
		*)
			err "用法: upgrade [self|core|all] [--ver TAG] [--force]"
			;;
		esac
	fi
	case $target in
	self) gps_cmd_upgrade_self "$@" ;;
	core) gps_cmd_upgrade_core "$@" ;;
	all)
		gps_cmd_upgrade_self "$@"
		gps_cmd_upgrade_core "$@"
		;;
	esac
}

gps_cmd_upgrade_core() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	local ver=latest
	local force=0
	while [[ $# -gt 0 ]]; do
		case $1 in
		--ver)
			ver=$2
			shift 2
			;;
		--force | -f)
			force=1
			shift
			;;
		*) err "未知参数: $1（用法: upgrade core [--ver TAG] [--force]）" ;;
		esac
	done
	load_state || err "未安装"
	local before
	before=$(gps_core_ver_installed)
	gps_download_core "$ver" "$force"
	save_state
	if [[ $force -eq 0 && -n $before && $before == "${CORE_VER}" ]]; then
		msg "$(_green "无需升级") sing-box 当前已是 v${CORE_VER}"
		return 0
	fi
	gps_restart_svc
	msg "$(_green "升级完成") sing-box=$CORE_VER"
}

gps_cmd_change() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	load_state || err "未安装"
	local what=${1:-}
	shift || true
	case $what in
	port)
		local p=${1:-auto}
		[[ $p == auto ]] && p=$(rand_port)
		[[ $p =~ ^[0-9]+$ ]] || err "无效端口: $p"
		PORT=$p
		;;
	uuid)
		local u=${1:-auto}
		[[ $u == auto ]] && u=$(gen_uuid)
		UUID=$u
		# 若密码仍等于旧习惯，保持 UUID=密码可由用户显式改 passwd
		;;
	passwd | password)
		local pw=${1:-auto}
		[[ $pw == auto ]] && pw=$(gen_uuid)
		PASSWORD=$pw
		;;
	ip | ipv4)
		local ip=${1:-}
		if [[ -z $ip || $ip == auto ]]; then
			ip=$(detect_public_ipv4) || err "IPv4 探测失败，请: change ip <x.x.x.x>"
		fi
		is_ipv4 "$ip" || err "不是合法 IPv4: $ip"
		PUBLIC_IP=$ip
		;;
	ip6 | ipv6)
		local ip6=${1:-}
		if [[ -z $ip6 || $ip6 == auto ]]; then
			ip6=$(detect_public_ipv6) || err "IPv6 探测失败，请: change ip6 <addr>"
		fi
		is_ipv6 "$ip6" || err "不是合法 IPv6: $ip6"
		PUBLIC_IP6=$ip6
		;;
	ips)
		# 自适应重探双栈公网地址
		PUBLIC_IP=$(detect_public_ipv4) || PUBLIC_IP=${PUBLIC_IP:-}
		PUBLIC_IP6=$(detect_public_ipv6) || PUBLIC_IP6=${PUBLIC_IP6:-}
		[[ -n $PUBLIC_IP || -n $PUBLIC_IP6 ]] || err "未能探测到任何公网地址"
		detect_local_stack
		;;
	log | loglevel | level)
		local lv=${1:-debug}
		gps_set_log_level "$lv"
		save_state
		gps_restart_svc
		msg "有客户端连上后，日志会出现 inbound/... 与 outbound/direct/..."
		return 0
		;;
	kiwivm | kiwi)
		local veid=${1:-} key=${2:-}
		[[ -n $veid && -n $key ]] || err "用法: change kiwivm <veid> <api_key>"
		KIWI_VEID=$veid
		KIWI_API_KEY=$key
		KIWI_API_BASE=${KIWI_API_BASE:-https://api.64clouds.com/v1}
		gps_traffic_defaults
		save_state
		if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
			gps_install_traffic_timer
		fi
		msg "$(_green "已保存 KiwiVM") veid=$KIWI_VEID key=$(gps_mask_key "$KIWI_API_KEY")"
		gps_cmd_traffic_status || true
		return 0
		;;
	traffic-warn | warn-pct)
		local p=${1:-}
		[[ $p =~ ^[0-9]+$ && $p -ge 1 && $p -le 100 ]] || err "告警阈值需为 1-100"
		TRAFFIC_WARN_PCT=$p
		save_state
		msg "$(_green "告警阈值") → ${TRAFFIC_WARN_PCT}%"
		return 0
		;;
	traffic-stop | stop-pct)
		local p=${1:-}
		[[ $p =~ ^[0-9]+$ && $p -ge 1 && $p -le 100 ]] || err "停服阈值需为 1-100"
		TRAFFIC_STOP_PCT=$p
		save_state
		msg "$(_green "停服阈值") → ${TRAFFIC_STOP_PCT}%"
		return 0
		;;
	traffic-interval | interval)
		local s=${1:-}
		[[ $s =~ ^[0-9]+$ && $s -ge 60 ]] || err "间隔需为 ≥60 的秒数"
		TRAFFIC_CHECK_SEC=$s
		save_state
		if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
			gps_install_traffic_timer
		fi
		msg "$(_green "检查间隔") → ${TRAFFIC_CHECK_SEC}s"
		return 0
		;;
	*)
		err "用法: change port|uuid|passwd|ip|ip6|ips|log|kiwivm|traffic-warn|traffic-stop|traffic-interval ..."
		;;
	esac
	gps_write_config
	save_state
	gps_restart_svc
	gps_cmd_url
}

gps_cmd_log() {
	[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	load_state 2>/dev/null || true

	# 默认跟随（方便看进/出站）；--once / -n 只打最近若干行
	local follow=1
	local once_lines=80
	while [[ $# -gt 0 ]]; do
		case $1 in
		-f | --follow) follow=1; shift ;;
		--once | -n)
			follow=0
			shift
			[[ ${1:-} =~ ^[0-9]+$ ]] && {
				once_lines=$1
				shift
			}
			;;
		*) shift ;;
		esac
	done

	# 级别不够时抬到 debug，否则看不到进站/出站
	local cur
	cur=$(gps_config_log_level 2>/dev/null || echo "")
	case $cur in
	debug | trace) ;;
	*)
		if [[ -f ${GPS_CONFIG:-} ]]; then
			msg "$(_cyan "当前级别") ${cur:-?} → 调整为 debug（才能看到进站/出站连接）"
			gps_set_log_level debug
			save_state
			if gps_svc is-active --quiet 2>/dev/null || gps_pid_running 2>/dev/null; then
				gps_restart_svc
				sleep 0.5
			fi
		fi
		;;
	esac

	local has_file=0
	[[ -f $GPS_LOG ]] && has_file=1
	local nonempty=0
	[[ $has_file -eq 1 && -s $GPS_LOG ]] && nonempty=1

	msg "$(_cyan "日志") level=$(gps_config_log_level)  file=$GPS_LOG"
	msg "有流量时可见: inbound/tuic[...] / outbound/direct[...] （Ctrl+C 退出跟随）"

	if ((follow)); then
		if [[ $has_file -eq 1 ]]; then
			[[ $nonempty -eq 0 ]] && warn "文件暂空：请用客户端连一下，进/出站才会刷出来"
			tail -n 30 -f "$GPS_LOG"
		elif [[ ${GPS_NO_SYSTEMD:-0} != 1 ]] && have_cmd journalctl; then
			journalctl -u "$GPS_SERVICE" -f
		else
			err "找不到日志: $GPS_LOG"
		fi
		return 0
	fi

	if [[ $nonempty -eq 1 ]]; then
		tail -n "$once_lines" "$GPS_LOG"
		return 0
	fi

	if [[ $has_file -eq 1 ]]; then
		warn "日志文件为空 — 无客户端连接时不会有进/出站记录"
	else
		warn "日志文件不存在: $GPS_LOG"
	fi

	if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]] && have_cmd journalctl; then
		msg "$(_cyan "journalctl") -u $GPS_SERVICE -n 40"
		journalctl -u "$GPS_SERVICE" -n 40 --no-pager 2>/dev/null || true
	fi
}

gps_help() {
	cat <<EOF
$GPS_NAME $GPS_SH_VER — GeoProxy VPS 端（单实例 TUIC）

Usage: $GPS_NAME [command] [args...]

无参数时进入交互菜单。

命令:
  install [--port N] [--uuid U] [--passwd P] [--ip V4] [--ip6 V6]
  uninstall [-y]
  status | start | stop | restart
  info | url | qr | log [--once]
  change port|uuid|passwd|ip|ip6|ips|log|kiwivm|traffic-warn|traffic-stop|traffic-interval ...
  traffic [status|check|resume]
  upgrade [self|core|all] [--ver TAG] [--force]
  doctor
  bbr
  help | version

说明:
  - upgrade / upgrade self：从 GitHub 升级本管理脚本（保留配置与 KiwiVM 凭证）
  - upgrade core：只升级 sing-box 核心
  - upgrade all：先脚本后核心
  - 流量熔断: change kiwivm <veid> <api_key>；默认 80% 告警 / 95% 停服；仅手动 resume
  - systemd timer 每 TRAFFIC_CHECK_SEC 秒执行 traffic check
  - 熔断后 start 会被拒绝，需 traffic resume
  - 默认日志 debug；IPv4/IPv6 自适应 TUIC URL
EOF
}
