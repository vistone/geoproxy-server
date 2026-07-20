#!/bin/bash
# KiwiVM 流量检测与熔断

gps_bytes_human() {
	local b=${1:-0}
	awk -v b="$b" 'BEGIN{
		if (b<1024){printf "%d B", b; exit}
		if (b<1048576){printf "%.2f KiB", b/1024; exit}
		if (b<1073741824){printf "%.2f MiB", b/1048576; exit}
		if (b<1099511627776){printf "%.2f GiB", b/1073741824; exit}
		printf "%.2f TiB", b/1099511627776
	}'
}

gps_mask_key() {
	local k=${1:-}
	local n=${#k}
	if ((n <= 4)); then
		echo "****"
		return
	fi
	echo "${k:0:2}****${k: -2}"
}

gps_traffic_defaults() {
	KIWI_API_BASE=${KIWI_API_BASE:-https://api.64clouds.com/v1}
	TRAFFIC_WARN_PCT=${TRAFFIC_WARN_PCT:-80}
	TRAFFIC_STOP_PCT=${TRAFFIC_STOP_PCT:-95}
	TRAFFIC_CHECK_SEC=${TRAFFIC_CHECK_SEC:-300}
	TRAFFIC_TRIPPED=${TRAFFIC_TRIPPED:-0}
	TRAFFIC_LAST_PCT=${TRAFFIC_LAST_PCT:-}
	TRAFFIC_LAST_CHECK=${TRAFFIC_LAST_CHECK:-}
	TRAFFIC_LAST_ERROR=${TRAFFIC_LAST_ERROR:-}
	KIWI_VEID=${KIWI_VEID:-}
	KIWI_API_KEY=${KIWI_API_KEY:-}
}

# 解析 getServiceInfo JSON → 输出: error|pct|used|limit|mult|reset|msg
gps_kiwi_parse_info() {
	local json=$1
	if have_cmd python3; then
		python3 - "$json" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception as e:
    print(f"1|0|0|0|1|0|json:{e}")
    sys.exit(0)
err = d.get("error", 1)
if err != 0:
    msg = str(d.get("message", "api_error")).replace("|", "/")
    print(f"{err}|0|0|0|1|0|{msg}")
    sys.exit(0)
used = int(d.get("data_counter") or 0)
limit = int(d.get("plan_monthly_data") or 0)
mult = float(d.get("monthly_data_multiplier") or 1) or 1.0
reset = int(d.get("data_next_reset") or 0)
denom = limit * mult
pct = 0.0 if denom <= 0 else (100.0 * used / denom)
print(f"0|{pct:.4f}|{used}|{limit}|{mult}|{reset}|ok")
PY
		return 0
	fi
	# 无 python3 时的粗糙回退
	local err used limit mult reset
	err=$(echo "$json" | grep -oE '"error"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo 1)
	used=$(echo "$json" | grep -oE '"data_counter"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo 0)
	limit=$(echo "$json" | grep -oE '"plan_monthly_data"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo 0)
	mult=$(echo "$json" | grep -oE '"monthly_data_multiplier"[[:space:]]*:[[:space:]]*[0-9.]+' | head -1 | grep -oE '[0-9.]+$' || echo 1)
	reset=$(echo "$json" | grep -oE '"data_next_reset"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+$' || echo 0)
	if [[ $err != 0 ]]; then
		echo "${err}|0|0|0|1|0|api_error"
		return 0
	fi
	local pct
	pct=$(awk -v u="$used" -v l="$limit" -v m="$mult" 'BEGIN{d=l*m; if(d<=0) print 0; else printf "%.4f", 100*u/d}')
	echo "0|${pct}|${used}|${limit}|${mult}|${reset}|ok"
}

gps_kiwi_fetch_info() {
	gps_traffic_defaults
	[[ -n $KIWI_VEID && -n $KIWI_API_KEY ]] || return 2
	local base=${KIWI_API_BASE%/}
	local url="${base}/getServiceInfo?veid=${KIWI_VEID}&api_key=${KIWI_API_KEY}"
	curl -fsSL --max-time 15 "$url" 2>/dev/null || return 1
}

gps_traffic_apply_parsed() {
	# 入参: error|pct|used|limit|mult|reset|msg
	local line=$1
	IFS='|' read -r KIWI_ERR TRAFFIC_LAST_PCT TRAFFIC_USED_BYTES TRAFFIC_LIMIT_BYTES TRAFFIC_MULT TRAFFIC_RESET TRAFFIC_MSG <<<"$line"
	TRAFFIC_LAST_CHECK=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	if [[ ${KIWI_ERR:-1} != 0 ]]; then
		TRAFFIC_LAST_ERROR=${TRAFFIC_MSG:-api_error}
	else
		TRAFFIC_LAST_ERROR=
	fi
}

gps_cmd_traffic_status() {
	load_state || err "未安装"
	gps_traffic_defaults
	msg "$(_cyan "流量熔断")"
	if [[ -z $KIWI_VEID || -z $KIWI_API_KEY ]]; then
		warn "未配置 KiwiVM：请 geoproxy-server change kiwivm <veid> <api_key>"
		return 0
	fi
	msg "  VEID:     $KIWI_VEID"
	msg "  API Key:  $(gps_mask_key "$KIWI_API_KEY")"
	msg "  API:      $KIWI_API_BASE"
	msg "  告警阈值: ${TRAFFIC_WARN_PCT}%"
	msg "  停服阈值: ${TRAFFIC_STOP_PCT}%"
	msg "  检查间隔: ${TRAFFIC_CHECK_SEC}s"
	msg "  熔断标记: ${TRAFFIC_TRIPPED}"
	if [[ -n $TRAFFIC_LAST_PCT ]]; then
		msg "  上次用量: ${TRAFFIC_LAST_PCT}%  @ ${TRAFFIC_LAST_CHECK:-?}"
	fi
	[[ -n $TRAFFIC_LAST_ERROR ]] && warn "  上次错误: $TRAFFIC_LAST_ERROR"

	local raw line
	if ! raw=$(gps_kiwi_fetch_info); then
		warn "实时拉取失败（展示缓存状态）"
		return 0
	fi
	line=$(gps_kiwi_parse_info "$raw")
	gps_traffic_apply_parsed "$line"
	save_state
	if [[ ${KIWI_ERR:-1} != 0 ]]; then
		warn "API error=${KIWI_ERR} ${TRAFFIC_LAST_ERROR}"
		return 0
	fi
	local reset_h="?"
	if [[ ${TRAFFIC_RESET:-0} =~ ^[0-9]+$ && $TRAFFIC_RESET -gt 0 ]]; then
		reset_h=$(date -u -d "@${TRAFFIC_RESET}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$TRAFFIC_RESET" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$TRAFFIC_RESET")
	fi
	msg "  已用:     $(gps_bytes_human "$TRAFFIC_USED_BYTES") ($TRAFFIC_USED_BYTES B)"
	msg "  限额:     $(gps_bytes_human "$TRAFFIC_LIMIT_BYTES") × ${TRAFFIC_MULT}"
	msg "  用量:     ${TRAFFIC_LAST_PCT}%"
	msg "  重置于:   $reset_h"
	local pct_int
	pct_int=$(awk -v p="$TRAFFIC_LAST_PCT" 'BEGIN{printf "%d", p+0}')
	if ((pct_int >= TRAFFIC_STOP_PCT)); then
		msg "  状态:     $(_red "应停服 (≥${TRAFFIC_STOP_PCT}%)")"
	elif ((pct_int >= TRAFFIC_WARN_PCT)); then
		msg "  状态:     $(_yellow "告警 (≥${TRAFFIC_WARN_PCT}%)")"
	else
		msg "  状态:     $(_green "正常")"
	fi
}

# timer / 手动：拉 API 并告警/停服
gps_cmd_traffic_check() {
	load_state 2>/dev/null || true
	gps_traffic_defaults
	if [[ -z ${KIWI_VEID:-} || -z ${KIWI_API_KEY:-} ]]; then
		msg "traffic check: 未配置 VEID/API_KEY，跳过"
		return 0
	fi

	local raw line
	if ! raw=$(gps_kiwi_fetch_info); then
		TRAFFIC_LAST_ERROR="curl_failed"
		TRAFFIC_LAST_CHECK=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		save_state 2>/dev/null || true
		warn "traffic check: API 请求失败，本轮不熔断"
		return 0
	fi
	line=$(gps_kiwi_parse_info "$raw")
	gps_traffic_apply_parsed "$line"
	save_state

	if [[ ${KIWI_ERR:-1} != 0 ]]; then
		warn "traffic check: API error=${KIWI_ERR} ${TRAFFIC_LAST_ERROR}，本轮不熔断"
		return 0
	fi
	if [[ ${TRAFFIC_LIMIT_BYTES:-0} -eq 0 ]]; then
		warn "traffic check: plan_monthly_data=0，跳过"
		return 0
	fi

	local pct_int
	pct_int=$(awk -v p="$TRAFFIC_LAST_PCT" 'BEGIN{printf "%d", p+0}')
	msg "traffic check: ${TRAFFIC_LAST_PCT}% (warn=${TRAFFIC_WARN_PCT} stop=${TRAFFIC_STOP_PCT} tripped=${TRAFFIC_TRIPPED})"

	if ((pct_int >= TRAFFIC_STOP_PCT)); then
		msg "$(_red "流量 ${TRAFFIC_LAST_PCT}% ≥ 停服阈值 ${TRAFFIC_STOP_PCT}%，停止 ${GPS_SERVICE}")"
		TRAFFIC_TRIPPED=1
		save_state
		gps_svc stop 2>/dev/null || true
		{
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) TRAFFIC_STOP pct=${TRAFFIC_LAST_PCT} stop=${TRAFFIC_STOP_PCT}"
		} >>"${GPS_LOG_DIR}/traffic.log" 2>/dev/null || true
		return 0
	fi

	if ((pct_int >= TRAFFIC_WARN_PCT)); then
		warn "流量 ${TRAFFIC_LAST_PCT}% ≥ 告警阈值 ${TRAFFIC_WARN_PCT}%"
		{
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) TRAFFIC_WARN pct=${TRAFFIC_LAST_PCT} warn=${TRAFFIC_WARN_PCT}"
		} >>"${GPS_LOG_DIR}/traffic.log" 2>/dev/null || true
		return 0
	fi
	return 0
}

gps_cmd_traffic_resume() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	load_state || err "未安装"
	gps_traffic_defaults
	[[ -n $KIWI_VEID && -n $KIWI_API_KEY ]] || err "未配置 KiwiVM，无法校验流量"

	local raw line
	raw=$(gps_kiwi_fetch_info) || err "API 请求失败，拒绝 resume"
	line=$(gps_kiwi_parse_info "$raw")
	gps_traffic_apply_parsed "$line"
	save_state
	[[ ${KIWI_ERR:-1} == 0 ]] || err "API error=${KIWI_ERR} ${TRAFFIC_LAST_ERROR}"

	local pct_int
	pct_int=$(awk -v p="$TRAFFIC_LAST_PCT" 'BEGIN{printf "%d", p+0}')
	if ((pct_int >= TRAFFIC_STOP_PCT)); then
		err "当前用量 ${TRAFFIC_LAST_PCT}% 仍 ≥ 停服阈值 ${TRAFFIC_STOP_PCT}%，拒绝 resume"
	fi

	TRAFFIC_TRIPPED=0
	save_state
	gps_svc start
	msg "$(_green "已 resume") 流量 ${TRAFFIC_LAST_PCT}%，${GPS_SERVICE} 已启动"
}

gps_cmd_traffic() {
	[[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
	local sub=${1:-status}
	shift || true
	case $sub in
	status | show | "") gps_cmd_traffic_status ;;
	check) gps_cmd_traffic_check "$@" ;;
	resume) gps_cmd_traffic_resume "$@" ;;
	*) err "用法: traffic [status|check|resume]" ;;
	esac
}

gps_assert_not_tripped() {
	gps_traffic_defaults
	if [[ ${TRAFFIC_TRIPPED:-0} == 1 ]]; then
		err "流量熔断中 (TRAFFIC_TRIPPED=1)。请: $GPS_NAME traffic resume"
	fi
}
