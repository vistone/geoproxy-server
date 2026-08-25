#!/bin/bash
# systemd / 无 root 前缀模式下的进程管理

gps_install_unit() {
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
		msg "$(_cyan "跳过 systemd")（--no-systemd / 测试前缀模式）"
		mkdir -p "$(dirname "$GPS_PID_FILE")"
		gps_install_logrotate
		gps_install_mesh_units_files_only
		return 0
	fi
	need_systemd
	local tpl="${GPS_TMPL}/geoproxy-tuic.service"
	[[ -f $tpl ]] || err "缺少 unit 模板: $tpl"
	mkdir -p "$(dirname "$GPS_UNIT_PATH")"
	local bin=${GPS_BIN_LINK:-/usr/local/bin/geoproxy-server}
	sed -e "s|__CORE_BIN__|${GPS_CORE_BIN}|g" \
		-e "s|__CONFIG__|${GPS_CONFIG}|g" \
		-e "s|__LOG__|${GPS_LOG}|g" \
		-e "s|__ETC_DIR__|${GPS_ETC}|g" \
		-e "s|__LOG_DIR__|${GPS_LOG_DIR}|g" \
		-e "s|__BIN__|${bin}|g" \
		"$tpl" >"$GPS_UNIT_PATH"
	gps_install_traffic_timer
	gps_install_mesh_units
	gps_install_logrotate
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		systemctl daemon-reload
		systemctl enable "$GPS_SERVICE" >/dev/null
	else
		msg "$(_yellow "测试前缀下已写入 unit 文件，未 enable 系统 systemd")"
	fi
}

# 仅写 unit 文件（测试前缀 / no-systemd）
gps_install_mesh_units_files_only() {
	gps_mesh_defaults 2>/dev/null || true
	local bin=${GPS_BIN_LINK:-/usr/local/bin/geoproxy-server}
	local mtpl="${GPS_TMPL}/geoproxy-mesh-master.service"
	local stpl="${GPS_TMPL}/geoproxy-mesh-sync.service"
	local ttpl="${GPS_TMPL}/geoproxy-mesh-sync.timer"
	# master 专用最小凭证：只含 token，网络服务不再接触整个 state.env
	if [[ -n ${GPS_MESH_DIR:-} ]]; then
		local tok=${MESH_CLUSTER_TOKEN:-}
		if [[ -z $tok && -f ${GPS_MESH_TOKEN_FILE:-} ]]; then
			tok=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
		fi
		if [[ -n $tok ]]; then
			umask 077
			{
				printf 'MESH_CLUSTER_TOKEN=%s\n' "$tok"
				printf 'GPS_MESH_MASTER_BIND=%s\n' "${GPS_MESH_MASTER_BIND:-0.0.0.0}"
				printf 'GPS_MESH_MASTER_PORT=%s\n' "${MESH_MASTER_PORT:-${GPS_MESH_MASTER_PORT:-19527}}"
				printf 'GPS_MESH_MASTER_TLS=%s\n' "${GPS_MESH_MASTER_TLS:-1}"
			} >"$GPS_MESH_ENV"
			chmod 600 "$GPS_MESH_ENV" 2>/dev/null || true
		fi
	fi
	mkdir -p "$(dirname "${GPS_MESH_MASTER_UNIT_PATH:-/tmp/x}")" 2>/dev/null || true
	if [[ -f $mtpl && -n ${GPS_MESH_MASTER_UNIT_PATH:-} ]]; then
		sed -e "s|__GPS_STATE__|${GPS_STATE}|g" \
			-e "s|__GPS_MESH_ENV__|${GPS_MESH_ENV}|g" \
			-e "s|__GPS_MESH_DIR__|${GPS_MESH_DIR}|g" \
			-e "s|__GPS_MESH_PEERS__|${GPS_MESH_PEERS}|g" \
			-e "s|__MESH_MASTER_PY__|${GPS_MESH_MASTER_PY}|g" \
			"$mtpl" >"$GPS_MESH_MASTER_UNIT_PATH"
	fi
	if [[ -f $stpl && -n ${GPS_MESH_SYNC_UNIT_PATH:-} ]]; then
		sed -e "s|__BIN__|${bin}|g" \
			-e "s|__ETC_DIR__|${GPS_ETC}|g" \
			-e "s|__LOG_DIR__|${GPS_LOG_DIR}|g" \
			"$stpl" >"$GPS_MESH_SYNC_UNIT_PATH"
	fi
	if [[ -f $ttpl && -n ${GPS_MESH_SYNC_TIMER_PATH:-} ]]; then
		local sec=${MESH_SYNC_SEC:-60}
		[[ $sec =~ ^[0-9]+$ ]] || sec=60
		((sec < 15)) && sec=15
		sed -e "s|__SYNC_SEC__|${sec}|g" "$ttpl" >"$GPS_MESH_SYNC_TIMER_PATH"
	fi
}

gps_install_mesh_units() {
	gps_mesh_role_normalize 2>/dev/null || MESH_ROLE=${MESH_ROLE:-master}
	gps_mesh_defaults 2>/dev/null || true
	gps_install_mesh_units_files_only
	if [[ -n ${GPS_TEST_PREFIX:-} || ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
		return 0
	fi
	systemctl daemon-reload 2>/dev/null || true
	if [[ ${MESH_ROLE:-master} == master ]]; then
		# enable 不够：已在跑的旧明文进程不会换新代码/TLS，必须 restart
		systemctl enable "$GPS_MESH_MASTER_SERVICE" >/dev/null 2>&1 ||
			systemctl enable geoproxy-mesh-master.service >/dev/null 2>&1 || true
		systemctl restart "$GPS_MESH_MASTER_SERVICE" >/dev/null 2>&1 ||
			systemctl restart geoproxy-mesh-master.service >/dev/null 2>&1 || true
		msg "$(_cyan "mesh-master") 已启用（登记面 ${GPS_MESH_MASTER_BIND:-0.0.0.0}:${MESH_MASTER_PORT:-19527}/tcp，mesh 控制面）"
	else
		systemctl disable --now geoproxy-mesh-master.service >/dev/null 2>&1 || true
	fi
	systemctl enable --now "$GPS_MESH_SYNC_TIMER" >/dev/null 2>&1 ||
		systemctl enable --now geoproxy-mesh-sync.timer >/dev/null 2>&1 || true
	msg "$(_cyan "mesh-sync") timer 已启用（每 ${MESH_SYNC_SEC:-60}s）"
}

gps_remove_mesh_units() {
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		rm -f "${GPS_MESH_MASTER_UNIT_PATH:-}" "${GPS_MESH_SYNC_UNIT_PATH:-}" "${GPS_MESH_SYNC_TIMER_PATH:-}"
		return 0
	fi
	if have_cmd systemctl; then
		systemctl disable --now geoproxy-mesh-sync.timer >/dev/null 2>&1 || true
		systemctl disable --now geoproxy-mesh-sync.service >/dev/null 2>&1 || true
		systemctl disable --now geoproxy-mesh-master.service >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/geoproxy-mesh-master.service \
			/etc/systemd/system/geoproxy-mesh-sync.service \
			/etc/systemd/system/geoproxy-mesh-sync.timer
		systemctl daemon-reload 2>/dev/null || true
	fi
}

# 日志轮转：sing-box 以 append fd 持有日志，必须 copytruncate
gps_install_logrotate() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]] && ! have_cmd logrotate; then
		# 生产模式缺 logrotate：自动安装；装不上也照写配置（装好后即生效）
		if ! ensure_logrotate; then
			warn "logrotate 自动安装失败（无可用包管理器或网络问题）；轮转配置仍会写入，手动安装后自动生效"
		fi
	fi
	local tpl="${GPS_TMPL}/logrotate.conf"
	[[ -f $tpl ]] || err "缺少 logrotate 模板: $tpl"
	mkdir -p "$(dirname "$GPS_LOGROTATE_PATH")"
	sed -e "s|__LOG__|${GPS_LOG}|g" \
		-e "s|__TRAFFIC_LOG__|${GPS_TRAFFIC_LOG}|g" \
		"$tpl" >"$GPS_LOGROTATE_PATH"
	chmod 644 "$GPS_LOGROTATE_PATH"
	msg "$(_cyan "日志轮转") 已配置: $GPS_LOGROTATE_PATH（weekly / maxsize）"
}

gps_install_traffic_timer() {
	gps_with_state_lock _gps_install_traffic_timer_locked
}

_gps_install_traffic_timer_locked() {
	local sec=${TRAFFIC_CHECK_SEC:-300}
	[[ $sec =~ ^[0-9]+$ ]] || sec=300
	((sec < 60)) && sec=60
	TRAFFIC_CHECK_SEC=$sec
	local stpl="${GPS_TMPL}/geoproxy-traffic.service"
	local ttpl="${GPS_TMPL}/geoproxy-traffic.timer"
	[[ -f $stpl && -f $ttpl ]] || err "缺少 traffic timer 模板"
	mkdir -p "$(dirname "$GPS_TRAFFIC_UNIT_PATH")"
	local bin=${GPS_BIN_LINK:-/usr/local/bin/geoproxy-server}
	sed -e "s|/usr/local/bin/geoproxy-server|${bin}|g" "$stpl" >"$GPS_TRAFFIC_UNIT_PATH"
	sed -e "s|__CHECK_SEC__|${sec}|g" "$ttpl" >"$GPS_TRAFFIC_TIMER_PATH"
	if [[ -z ${GPS_TEST_PREFIX:-} && ${GPS_NO_SYSTEMD:-0} != 1 ]]; then
		systemctl daemon-reload
		# 有凭证才 enable timer；无凭证也装好 unit，避免以后再配时缺文件
		if [[ -n ${KIWI_VEID:-} && -n ${KIWI_API_KEY:-} ]]; then
			systemctl enable --now "$GPS_TRAFFIC_TIMER" >/dev/null 2>&1 || systemctl enable --now geoproxy-traffic.timer >/dev/null
			msg "$(_cyan "流量定时器") 已启用（每 ${sec}s）"
		else
			systemctl disable "$GPS_TRAFFIC_TIMER" >/dev/null 2>&1 || true
			msg "$(_yellow "流量定时器") 已安装但未启用（先: change kiwivm <veid> <key>）"
		fi
	fi
}

gps_remove_traffic_timer() {
	gps_with_state_lock _gps_remove_traffic_timer_locked
}

_gps_remove_traffic_timer_locked() {
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		rm -f "$GPS_TRAFFIC_UNIT_PATH" "$GPS_TRAFFIC_TIMER_PATH"
		return 0
	fi
	if have_cmd systemctl; then
		systemctl disable --now geoproxy-traffic.timer >/dev/null 2>&1 || true
		systemctl disable --now geoproxy-traffic.service >/dev/null 2>&1 || true
		rm -f /etc/systemd/system/geoproxy-traffic.service /etc/systemd/system/geoproxy-traffic.timer
		systemctl daemon-reload 2>/dev/null || true
	fi
}

gps_pid_running() {
	[[ -f $GPS_PID_FILE ]] || return 1
	local pid
	pid=$(cat "$GPS_PID_FILE" 2>/dev/null) || return 1
	[[ -n $pid ]] || return 1
	kill -0 "$pid" 2>/dev/null
}

gps_start_foreground_bg() {
	load_state 2>/dev/null || true
	if declare -F gps_mesh_ensure_boot >/dev/null 2>&1; then
		GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
		save_state 2>/dev/null || true
	fi
	gps_bump_log_level_if_quiet
	gps_check_config
	mkdir -p "$(dirname "$GPS_PID_FILE")" "$GPS_LOG_DIR"
	if gps_pid_running; then
		kill "$(cat "$GPS_PID_FILE")" 2>/dev/null || true
		sleep 0.3
	fi
	# 截断过大日志可选；保留历史。启动行写入便于「查看日志」立刻有内容
	{
		echo "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) starting sing-box ----"
	} >>"$GPS_LOG"
	nohup "$GPS_CORE_BIN" run -c "$GPS_CONFIG" >>"$GPS_LOG" 2>&1 &
	echo $! >"$GPS_PID_FILE"
	sleep 0.8
	if ! gps_pid_running; then
		msg "$(_red "sing-box 启动失败，最近日志:")"
		tail -n 30 "$GPS_LOG" 2>/dev/null || true
		err "sing-box 进程启动失败，见日志: $GPS_LOG"
	fi
}

gps_stop_bg() {
	if gps_pid_running; then
		kill "$(cat "$GPS_PID_FILE")" 2>/dev/null || true
		rm -f "$GPS_PID_FILE"
	fi
}

# systemctl 失败时把 status/journal/日志文件打到终端，避免只剩 systemd 套话
gps_svc_dump_failure() {
	msg "$(_red "服务启动失败") $GPS_SERVICE — systemctl / journal / sing-box 日志:"
	if have_cmd systemctl; then
		systemctl status --no-pager -l "$GPS_SERVICE" 2>&1 || true
	fi
	if have_cmd journalctl; then
		msg "$(_cyan "journalctl") -u $GPS_SERVICE -n 80 --no-pager"
		journalctl -u "$GPS_SERVICE" -n 80 --no-pager --output=cat 2>&1 || true
	fi
	if [[ -n ${GPS_LOG:-} && -f $GPS_LOG ]]; then
		msg "$(_cyan "sing-box 日志") $GPS_LOG"
		tail -n 40 "$GPS_LOG" 2>/dev/null || true
	fi
}

gps_svc() {
	local action=$1
	shift || true
	if [[ $action == start || $action == restart ]]; then
		load_state 2>/dev/null || true
		gps_assert_not_tripped
	fi
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		case $action in
		start) gps_start_foreground_bg ;;
		stop) gps_stop_bg ;;
		restart)
			gps_stop_bg
			gps_start_foreground_bg
			;;
		status)
			if gps_pid_running; then
				msg "active (pid $(cat "$GPS_PID_FILE")) [no-systemd]"
			else
				msg "inactive [no-systemd]"
				return 3
			fi
			;;
		is-active)
			gps_pid_running
			;;
		*)
			err "无 systemd 模式下不支持: systemctl $action"
			;;
		esac
		return 0
	fi
	need_systemd
	if [[ $action == start || $action == restart ]]; then
		if systemctl "$action" "$@" "$GPS_SERVICE"; then
			return 0
		fi
		gps_svc_dump_failure
		return 1
	fi
	systemctl "$action" "$@" "$GPS_SERVICE"
}

# 停干净：不用 restart，避免沿用旧进程 / 旧 unit 记忆
gps_svc_halt() {
	msg "$(_cyan "停止") $GPS_SERVICE（清除旧进程）"
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_stop_bg
		return 0
	fi
	need_systemd
	systemctl stop "$GPS_SERVICE" 2>/dev/null || true
	for _ in $(seq 1 20); do
		systemctl is-active --quiet "$GPS_SERVICE" 2>/dev/null || break
		sleep 0.15
	done
	if systemctl is-active --quiet "$GPS_SERVICE" 2>/dev/null; then
		systemctl kill -s SIGKILL "$GPS_SERVICE" 2>/dev/null || true
		sleep 0.2
	fi
	systemctl reset-failed "$GPS_SERVICE" 2>/dev/null || true
	rm -f "$GPS_PID_FILE"
}

# 重新加载 unit 后全新 start（不调用 restart）
gps_svc_boot() {
	# 启动前强制组网身份/配置就绪（不依赖 unit 是否已含 ExecStartPre）
	load_state 2>/dev/null || true
	if declare -F gps_mesh_ensure_boot >/dev/null 2>&1; then
		GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
		save_state 2>/dev/null || true
	fi
	gps_bump_log_level_if_quiet
	gps_check_config
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_svc start
		return 0
	fi
	need_systemd
	systemctl daemon-reload 2>/dev/null || true
	gps_svc start || return 1
	sleep 0.5
	if ! gps_svc is-active --quiet; then
		gps_svc_dump_failure
		msg "$(_red "错误:") 服务启动失败（$GPS_SERVICE 未进入 active）" >&2
		return 1
	fi
}

gps_restart_svc() {
	gps_svc_halt
	gps_svc_boot
}

gps_svc_status_line() {
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		if gps_pid_running; then
			_green "active(pid)"
		else
			_yellow "inactive"
		fi
		return 0
	fi
	if systemctl is-active --quiet "$GPS_SERVICE" 2>/dev/null; then
		_green "active"
	elif systemctl is-failed --quiet "$GPS_SERVICE" 2>/dev/null; then
		_red "failed"
	else
		_yellow "inactive"
	fi
}
