#!/bin/bash
# 生成 / 校验代理配置（入站插件 + 可选 mesh endpoints/route）

gps_write_config() {
	gps_protocol_normalize
	gps_protocol_defaults
	gps_profile_normalize
	[[ -n ${PORT:-} ]] || err "PORT 未设置"
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

	local log_level=${LOG_LEVEL:-debug}
	case $log_level in
	trace | debug | info | warn | error | fatal | panic) ;;
	*) log_level=debug ;;
	esac
	LOG_LEVEL=$log_level
	local log_out
	log_out=$(gps_json_escape "$GPS_LOG")

	local extra=""
	extra=$(gps_proto_extra_inbounds 2>/dev/null || true)
	local inbounds_block=$inbounds
	if [[ -n ${extra//[[:space:]]/} ]]; then
		inbounds_block="${inbounds},
${extra}"
	fi

	local endpoints_block=""
	endpoints_block=$(gps_mesh_endpoints_json 2>/dev/null || true)
	local outbounds_block
	outbounds_block=$(gps_mesh_outbounds_json)
	local route_block=""
	route_block=$(gps_mesh_route_json 2>/dev/null || true)

	# 组装：始终含 endpoints/route（WireGuard mesh）
	local endpoints_section="" route_comma=""
	if [[ -n ${endpoints_block//[[:space:]]/} ]]; then
		endpoints_section=$(printf '  "endpoints": [\n%s\n  ],\n' "$endpoints_block")
	fi
	if [[ -n ${route_block//[[:space:]]/} ]]; then
		route_comma=","
	fi

	cat >"$GPS_CONFIG" <<EOF
{
  "log": {
    "level": "${log_level}",
    "timestamp": true,
    "output": "${log_out}"
  },
${endpoints_section}  "inbounds": [
${inbounds_block}
  ],
  "outbounds": [
${outbounds_block}
  ]${route_comma}
${route_block}
}
EOF
	# 若无 route，上面可能留下多余空行；清理尾部孤立逗号已用 route_comma 处理
	# 无 route 时 JSON 以 outbounds 闭合；有 route 时 route_block 自带 "route":{...}
	chmod 600 "$GPS_CONFIG"
	# 无 route 时文件末尾可能是 `  ]\n}` — OK
	# 有 route 时 `  ],\n  "route": {...}\n}` — OK；但 route_block 缩进需正确
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
