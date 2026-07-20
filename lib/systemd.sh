#!/bin/bash
# systemd / 无 root 前缀模式下的进程管理

gps_install_unit() {
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
		msg "$(_cyan "跳过 systemd")（--no-systemd / 测试前缀模式）"
		mkdir -p "$(dirname "$GPS_PID_FILE")"
		return 0
	fi
	need_systemd
	local tpl="${GPS_TMPL}/geoproxy-tuic.service"
	[[ -f $tpl ]] || err "缺少 unit 模板: $tpl"
	mkdir -p "$(dirname "$GPS_UNIT_PATH")"
	sed -e "s|__CORE_BIN__|${GPS_CORE_BIN}|g" \
		-e "s|__CONFIG__|${GPS_CONFIG}|g" \
		-e "s|__LOG__|${GPS_LOG}|g" \
		"$tpl" >"$GPS_UNIT_PATH"
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		systemctl daemon-reload
		systemctl enable "$GPS_SERVICE" >/dev/null
	else
		msg "$(_yellow "测试前缀下已写入 unit 文件，未 enable 系统 systemd")"
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

gps_svc() {
	local action=$1
	shift || true
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
	systemctl "$action" "$@" "$GPS_SERVICE"
}

gps_restart_svc() {
	gps_bump_log_level_if_quiet
	gps_check_config
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_svc restart
		return 0
	fi
	gps_svc restart
	sleep 0.5
	gps_svc is-active --quiet || err "服务启动失败，请查看: journalctl -u $GPS_SERVICE -n 50"
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
