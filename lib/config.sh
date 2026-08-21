#!/bin/bash
# 生成 / 校验代理配置（IPv4/IPv6 自适应监听；入站由协议插件渲染）

gps_write_config() {
	gps_protocol_normalize
	# 与历史行为一致：此处只要求凭证非空；严格格式由 install/change 校验
	[[ -n ${PORT:-} && -n ${UUID:-} && -n ${PASSWORD:-} ]] || err "PORT/UUID/PASSWORD 未设置"
	gps_ensure_tls
	mkdir -p "$GPS_ETC" "$GPS_LOG_DIR"
	detect_local_stack

	# Linux: bindv6only=0 时 listen :: 已是双栈，再绑 0.0.0.0 会 EADDRINUSE
	local bindv6only=0
	if [[ -r /proc/sys/net/ipv6/bindv6only ]]; then
		bindv6only=$(cat /proc/sys/net/ipv6/bindv6only)
	fi

	local inbounds=""
	case $STACK_MODE in
	dual)
		if [[ $bindv6only == 1 ]]; then
			inbounds="$(gps_proto_inbound_json "${PROTOCOL}-in-v4" 0.0.0.0),
$(gps_proto_inbound_json "${PROTOCOL}-in-v6" ::)"
			msg "$(_cyan "监听模式") STACK_MODE=dual bindv6only=1 → 0.0.0.0 + ::"
		else
			# 单一 :: 双栈 socket，同时接 IPv4-mapped 与 IPv6
			inbounds="$(gps_proto_inbound_json "${PROTOCOL}-in-dual" ::)"
			msg "$(_cyan "监听模式") STACK_MODE=dual bindv6only=0 → ::（双栈）"
		fi
		;;
	v6only)
		inbounds="$(gps_proto_inbound_json "${PROTOCOL}-in-v6" ::)"
		msg "$(_cyan "监听模式") STACK_MODE=v6only → ::"
		;;
	*)
		inbounds="$(gps_proto_inbound_json "${PROTOCOL}-in-v4" 0.0.0.0)"
		msg "$(_cyan "监听模式") STACK_MODE=v4only → 0.0.0.0"
		;;
	esac

	# debug：可看到进站/出站连接；info 仅启动信息；warn 几乎为空
	local log_level=${LOG_LEVEL:-debug}
	case $log_level in
	trace | debug | info | warn | error | fatal | panic) ;;
	*) log_level=debug ;;
	esac
	LOG_LEVEL=$log_level
	local log_out
	log_out=$(gps_json_escape "$GPS_LOG")
	cat >"$GPS_CONFIG" <<EOF
{
  "log": {
    "level": "${log_level}",
    "timestamp": true,
    "output": "${log_out}"
  },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
	chmod 600 "$GPS_CONFIG"
	gps_check_config
}

# 从 config.json 读出当前 level
gps_config_log_level() {
	[[ -f ${GPS_CONFIG:-} ]] || {
		echo "${LOG_LEVEL:-debug}"
		return 0
	}
	grep -oE '"level"[[:space:]]*:[[:space:]]*"[a-z]+"' "$GPS_CONFIG" | head -1 |
		sed -E 's/.*"([a-z]+)".*/\1/' || echo "${LOG_LEVEL:-debug}"
}

# 写入日志级别并校验；调用方负责 save_state / restart
gps_set_log_level() {
	local level=${1:-debug}
	case $level in
	trace | debug | info | warn | error | fatal | panic) ;;
	*) err "无效日志级别: $level（可用: trace debug info warn error fatal panic）" ;;
	esac
	LOG_LEVEL=$level
	[[ -f $GPS_CONFIG ]] || err "配置不存在，请先 install"
	if grep -qE '"level"[[:space:]]*:' "$GPS_CONFIG"; then
		sed -i -E "s/\"level\"[[:space:]]*:[[:space:]]*\"[a-z]+\"/\"level\": \"${level}\"/" "$GPS_CONFIG"
	else
		err "配置中缺少 log.level"
	fi
	gps_check_config
	msg "$(_green "日志级别") → $level（进站/出站连接建议 debug）"
}

# 旧安装默认 warn/info → 抬到 debug（用户显式设置过级别则不动）
gps_bump_log_level_if_quiet() {
	[[ ${LOG_LEVEL_EXPLICIT:-0} == 1 ]] && return 0
	[[ -f ${GPS_CONFIG:-} ]] || return 0
	local cur
	cur=$(gps_config_log_level)
	case $cur in
	debug | trace) return 0 ;;
	warn | error | fatal | panic | info | "")
		gps_set_log_level debug
		;;
	esac
}

gps_check_config() {
	[[ -x $GPS_CORE_BIN ]] || err "sing-box 未安装: $GPS_CORE_BIN"
	[[ -f $GPS_CONFIG ]] || err "配置不存在: $GPS_CONFIG"
	"$GPS_CORE_BIN" check -c "$GPS_CONFIG" || err "sing-box check 失败"
}
