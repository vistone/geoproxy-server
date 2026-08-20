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

# IPv6 校验边界：manual=用户输入（缺 python3 直接报错）；auto=探测值（缺 python3 降级告警）
gps_check_ipv6() {
	local ip=$1 src=${2:-manual} rc=0
	gps_validate_ipv6 "$ip" || rc=$?
	if ((rc == 0)); then
		return 0
	fi
	if ((rc == 2)); then
		if [[ $src == manual ]]; then
			err "校验 IPv6 需要 python3: apt install python3（或 yum/dnf install python3）"
		fi
		warn "缺 python3，跳过 IPv6 严格校验: $ip"
		return 0
	fi
	err "不是合法 IPv6: $ip"
}

gps_cmd_install() {
	gps_parse_install_args "$@"
	if [[ -n $INSTALL_PREFIX ]]; then
		GPS_TEST_PREFIX=$INSTALL_PREFIX
		# 前缀安装必须无条件走无 systemd 模式，不吃外部环境值
		GPS_NO_SYSTEMD=1
		gps_apply_paths
		export GPS_TEST_PREFIX GPS_NO_SYSTEMD
		msg "$(_cyan "测试/前缀安装") prefix=$GPS_TEST_PREFIX no_systemd=$GPS_NO_SYSTEMD"
	fi
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
		need_systemd
	fi
	ensure_deps

	# CLI 显式参数优先；其余从已有 state.env 继承，避免重装抹掉 UUID/KiwiVM
	local cli_port=$PORT cli_uuid=$UUID cli_pw=$PASSWORD cli_ip=$PUBLIC_IP cli_ip6=$PUBLIC_IP6
	local had_state=0
	if [[ -f $GPS_STATE ]]; then
		had_state=1
		load_state || true
		[[ -n $cli_port ]] && PORT=$cli_port
		[[ -n $cli_uuid ]] && UUID=$cli_uuid
		[[ -n $cli_pw ]] && PASSWORD=$cli_pw
		[[ -n $cli_ip ]] && PUBLIC_IP=$cli_ip
		[[ -n $cli_ip6 ]] && PUBLIC_IP6=$cli_ip6
		warn "检测到已安装配置: $GPS_STATE（保留端口/UUID/KiwiVM 凭证）"
		if [[ -t 0 ]]; then
			confirm_yes "保留配置并重装脚本与服务?" || err "已取消"
		else
			msg "非交互：保留已有配置，刷新脚本与服务"
		fi
		if [[ -z ${GPS_TEST_PREFIX:-} && ${GPS_NO_FETCH_SELF:-0} != 1 ]]; then
			gps_reinstall_fetch_self
		fi
	else
		gps_kiwi_load_persist
		if [[ -n ${KIWI_VEID:-} ]]; then
			msg "$(_cyan "已恢复长期保存的 KiwiVM") veid=$KIWI_VEID"
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
	# shellcheck disable=SC2034  # INSTALLED_AT 由 url.sh 的 gps_cmd_info 读取
	INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	LOG_LEVEL=${LOG_LEVEL:-debug}

	# 落盘前统一校验所有边界输入
	gps_validate_port "$PORT" || err "无效端口: $PORT（需 1-65535）"
	gps_validate_uuid "$UUID" || err "无效 UUID: $UUID（示例: $(gen_uuid)）"
	gps_validate_single_line "$PASSWORD" || err "密码不能包含换行/回车/NUL"
	gps_validate_single_line "${TUIC_NAME:-}" || err "节点名不能包含换行/回车/NUL"
	if [[ -n ${PUBLIC_IP:-} ]]; then
		gps_validate_ipv4 "$PUBLIC_IP" || err "无效 IPv4: $PUBLIC_IP（四段 0-255）"
	fi
	if [[ -n ${PUBLIC_IP6:-} ]]; then
		# 用户显式 --ip6 必须可校验；探测值缺 python3 时降级告警
		if [[ -n $cli_ip6 ]]; then
			gps_check_ipv6 "$PUBLIC_IP6" manual
		else
			gps_check_ipv6 "$PUBLIC_IP6" auto
		fi
	fi

	gps_write_config
	save_state
	gps_install_unit
	gps_install_entrypoint
	gps_restart_svc

	# 已有 KiwiVM（含卸载后恢复的长期凭证）时立刻拉一次用量，避免 last=?%
	if [[ -n ${KIWI_VEID:-} && -n ${KIWI_API_KEY:-} ]]; then
		gps_cmd_traffic_check || true
		load_state 2>/dev/null || true
	fi

	msg
	msg "$(_green "安装完成")"
	[[ $had_state -eq 1 ]] && msg "已保留原配置；管理脚本 $GPS_SH_VER"
	gps_cmd_info
	msg
	gps_cmd_url
}

# 重装时从 GitHub 拉取最新管理脚本（避免从已安装目录拷贝自己）
gps_reinstall_fetch_self() {
	local ver tmp root
	ver=$(gps_self_resolve_ver latest)
	msg "$(_cyan "拉取最新管理脚本") $ver ..."
	tmp=$(mktemp -d /tmp/gps-self-upgrade.XXXXXX)
	root=$(gps_self_fetch_tree "$ver" "$tmp")
	gps_self_install_tree "$root"
	rm -rf "$tmp"
}

gps_install_entrypoint() {
	mkdir -p "$(dirname "$GPS_BIN_LINK")" "$GPS_LIB_DIR"
	local src="${GPS_ROOT}/geoproxy-server.sh"
	[[ -f $src ]] || err "找不到入口脚本: $src"

	local dest="${GPS_LIB_DIR}/scripts"
	local src_real dest_real=""
	src_real=$(cd "$GPS_ROOT" && pwd -P)
	if [[ -d $dest ]]; then
		dest_real=$(cd "$dest" && pwd -P 2>/dev/null || true)
	fi

	# 已在目标目录运行：禁止 rm/cp 自己（v0.2.4 菜单重装会删光脚本）
	if [[ -n $dest_real && $src_real == "$dest_real" ]]; then
		msg "$(_cyan "脚本树已在") $dest，跳过拷贝"
	else
		local staging="${GPS_LIB_DIR}/.scripts.staging.$$"
		rm -rf "$staging"
		mkdir -p "$staging"
		cp -a "$GPS_ROOT/." "$staging/"
		rm -rf "${GPS_LIB_DIR}/scripts.prev"
		if [[ -d $dest ]]; then
			mv "$dest" "${GPS_LIB_DIR}/scripts.prev"
		fi
		mv "$staging" "$dest"
		GPS_ROOT="$dest"
		# shellcheck disable=SC2034  # GPS_TMPL 由其他模块读取
		GPS_TMPL="${GPS_ROOT}/templates"
	fi

	cat >"$GPS_BIN_LINK" <<EOF
#!/bin/bash
export GPS_TEST_PREFIX='${GPS_TEST_PREFIX:-}'
export GPS_NO_SYSTEMD='${GPS_NO_SYSTEMD:-0}'
exec bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" "\$@"
EOF
	chmod 755 "$GPS_BIN_LINK"
}

gps_cmd_uninstall() {
	local force=0 purge=0
	while [[ $# -gt 0 ]]; do
		case $1 in
		-y | --yes) force=1 ;;
		--purge) purge=1 ;;
		*) err "用法: uninstall [-y] [--purge]" ;;
		esac
		shift
	done
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
	gps_apply_paths
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	if ((force == 0)); then
		if [[ -t 0 ]]; then
			if ! confirm_yes "确认卸载 $GPS_NAME（停止服务并删除配置；KiwiVM 凭证会保留）?"; then
				warn "已取消卸载"
				return 1
			fi
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
	if ((purge == 1)); then
		rm -f "$GPS_KIWI_PERSIST"
		msg "已同时删除 KiwiVM 长期凭证 $GPS_KIWI_PERSIST"
	elif [[ -f ${GPS_KIWI_PERSIST:-} ]]; then
		msg "KiwiVM 凭证已保留: $GPS_KIWI_PERSIST"
		msg "彻底清除凭证: $GPS_NAME uninstall --purge"
	fi
	# 必须在此进程退出：卸载会删掉正在运行的脚本树，函数返回值可能非 0，
	# 菜单里 if uninstall; then exit 无法触发，会继续画菜单。
	if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
		return 0
	fi
	exit 0
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
	gps_reexec_if_menu
}

# 菜单内升级后：丢掉已 source 的旧函数，exec 新脚本
gps_reexec_if_menu() {
	[[ ${GPS_INVOKED_AS_MENU:-0} == 1 ]] || return 0
	[[ ${GPS_UPGRADE_DID_WORK:-0} == 1 ]] || return 0
	[[ -z ${GPS_TEST_PREFIX:-} ]] || return 0
	local script="${GPS_LIB_DIR}/scripts/geoproxy-server.sh"
	[[ -f $script ]] || return 0
	msg "$(_cyan "结束旧管理进程，启动新版菜单") $GPS_SH_VER"
	exec bash "$script"
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
	local before target
	before=$(gps_core_ver_installed)
	target=$(gps_resolve_core_ver "$ver")
	if [[ $force -eq 0 && -n $before && $before == "$target" && -x ${GPS_CORE_BIN:-} ]]; then
		CORE_VER=$before
		msg "$(_green "无需升级") sing-box 当前已是 v${CORE_VER}"
		return 0
	fi
	gps_svc_halt
	# 子 shell 捕获下载链路的 err（exit 1）：失败时旧核心未动，先拉回服务
	if (gps_download_core "$ver" "$force"); then :; else
		gps_svc_boot || true
		err "sing-box 下载/校验失败，已用旧核心恢复服务；稍后重试或 upgrade core --ver <tag>"
	fi
	# 新核心先过配置检查，不吃当前配置则回滚到旧核心
	if (gps_check_config); then :; else
		if gps_rollback_core; then
			msg "$(_yellow "新核心校验失败，已回滚旧核心")"
			(gps_check_config) || err "旧核心亦无法通过配置检查，请排查: $GPS_CONFIG"
		else
			err "新核心校验失败且无旧核心可回滚（首次安装后首次升级），请排查: $GPS_CONFIG"
		fi
		gps_svc_boot
		err "已回滚并恢复服务；可稍后重试或指定 --ver"
	fi
	save_state
	gps_svc_boot
	GPS_UPGRADE_DID_WORK=1
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
		gps_validate_port "$p" || err "无效端口: $p（需 1-65535）"
		PORT=$p
		;;
	uuid)
		local u=${1:-auto}
		[[ $u == auto ]] && u=$(gen_uuid)
		gps_validate_uuid "$u" || err "无效 UUID: $u（示例: $(gen_uuid)）"
		UUID=$u
		# 若密码仍等于旧习惯，保持 UUID=密码可由用户显式改 passwd
		;;
	passwd | password)
		local pw=${1:-auto}
		[[ $pw == auto ]] && pw=$(gen_uuid)
		gps_validate_single_line "$pw" || err "密码不能包含换行/回车/NUL"
		PASSWORD=$pw
		;;
	ip | ipv4)
		local ip=${1:-}
		if [[ -z $ip || $ip == auto ]]; then
			ip=$(detect_public_ipv4) || err "IPv4 探测失败，请: change ip <x.x.x.x>"
		fi
		gps_validate_single_line "$ip" || err "无效 IPv4: $ip"
		gps_validate_ipv4 "$ip" || err "不是合法 IPv4: $ip（四段 0-255）"
		PUBLIC_IP=$ip
		;;
	ip6 | ipv6)
		local ip6=${1:-}
		if [[ -z $ip6 || $ip6 == auto ]]; then
			ip6=$(detect_public_ipv6) || err "IPv6 探测失败，请: change ip6 <addr>"
		fi
		gps_validate_single_line "$ip6" || err "无效 IPv6: $ip6"
		gps_check_ipv6 "$ip6" manual
		PUBLIC_IP6=$ip6
		;;
	ips)
		# 自适应重探双栈公网地址
		PUBLIC_IP=$(detect_public_ipv4) || PUBLIC_IP=${PUBLIC_IP:-}
		PUBLIC_IP6=$(detect_public_ipv6) || PUBLIC_IP6=${PUBLIC_IP6:-}
		[[ -n $PUBLIC_IP || -n $PUBLIC_IP6 ]] || err "未能探测到任何公网地址"
		detect_local_stack
		;;
	name | remark | alias)
		local n=${1:-}
		[[ -n $n ]] || err "用法: change name <节点名>（写入 TUIC URL 的 #fragment，如 tile1.spacexway.com）"
		gps_validate_single_line "$n" || err "节点名不能包含换行/回车/NUL"
		TUIC_NAME=$n
		save_state
		msg "$(_green "节点名") → $TUIC_NAME"
		gps_cmd_url
		return 0
		;;
	log | loglevel | level)
		local lv=${1:-debug}
		gps_set_log_level "$lv"
		# 用户显式选择：boot 时不再被 gps_bump_log_level_if_quiet 抬回 debug
		# shellcheck disable=SC2034  # 由 gps_bump_log_level_if_quiet 读取
		LOG_LEVEL_EXPLICIT=1
		save_state
		gps_restart_svc
		msg "日志级别已生效（进程已重启）: $lv（进站/出站连接建议 debug）"
		return 0
		;;
	kiwivm | kiwi)
		local veid=${1:-} key=${2:-}
		[[ -n $veid && -n $key ]] || err "用法: change kiwivm <veid> <api_key>"
		gps_validate_single_line "$veid" || err "VEID 不能包含换行/回车/NUL"
		gps_validate_single_line "$key" || err "API_KEY 不能包含换行/回车/NUL"
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
		gps_validate_traffic_thresholds "$p" "${TRAFFIC_STOP_PCT:-95}" ||
			err "告警阈值需为 1-100 且小于停服阈值 ${TRAFFIC_STOP_PCT:-95}%"
		TRAFFIC_WARN_PCT=$p
		save_state
		msg "$(_green "告警阈值") → ${TRAFFIC_WARN_PCT}%"
		return 0
		;;
	traffic-stop | stop-pct)
		local p=${1:-}
		gps_validate_traffic_thresholds "${TRAFFIC_WARN_PCT:-80}" "$p" ||
			err "停服阈值需为 1-100 且大于告警阈值 ${TRAFFIC_WARN_PCT:-80}%"
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
		err "用法: change port|uuid|passwd|ip|ip6|ips|name|log|kiwivm|traffic-warn|traffic-stop|traffic-interval ..."
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
		-f | --follow)
			follow=1
			shift
			;;
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
  uninstall [-y] [--purge]
  status | start | stop | restart
  info | url | qr | log [--once]
  change port|uuid|passwd|ip|ip6|ips|name|log|kiwivm|traffic-warn|traffic-stop|traffic-interval ...
  traffic [status|check|resume]
  upgrade [self|core|all] [--ver TAG] [--force]
  doctor
  bbr
  help | version

说明:
  - upgrade / upgrade self：从 GitHub 升级本管理脚本（保留配置与 KiwiVM 凭证）
  - upgrade core：只升级 sing-box 核心
  - upgrade all：先脚本后核心
  - 流量熔断: change kiwivm <veid> <api_key>；默认 80% 告警 / 95% 停服；低于停服线自动恢复
  - systemd timer 每 TRAFFIC_CHECK_SEC 秒执行 traffic check
  - 熔断后用量低于停服线时自动恢复；仍可用 traffic resume
  - 默认日志 debug；TUIC URL 节点名在 #fragment（change name）
EOF
}
