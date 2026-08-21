#!/bin/bash
# 协议注册表
# 设计：docs/superpowers/specs/2026-08-21-protocol-plugin-design.md
#       docs/superpowers/specs/2026-08-21-multi-protocol-design.md

# 服务端入站白名单（Phase 1 / v0.4.0；Phase 2 在 v0.5.0 启用）
# shellcheck disable=SC2034
GPS_PROTOCOL_IDS=(
	tuic
	hysteria2
	vless
	trojan
	shadowsocks
)

# 规范化 PROTOCOL；缺省 tuic；未知 id 失败（落盘前调用）
gps_protocol_normalize() {
	PROTOCOL=${PROTOCOL:-tuic}
	PROTOCOL=$(printf '%s' "$PROTOCOL" | tr '[:upper:]' '[:lower:]')
	# 别名
	case $PROTOCOL in
	hy2 | hy) PROTOCOL=hysteria2 ;;
	ss) PROTOCOL=shadowsocks ;;
	st | shadow-tls) PROTOCOL=shadowtls ;;
	esac
	local id
	for id in "${GPS_PROTOCOL_IDS[@]}"; do
		if [[ $PROTOCOL == "$id" ]]; then
			return 0
		fi
	done
	err "不支持的协议: ${PROTOCOL}（当前可选: ${GPS_PROTOCOL_IDS[*]}）"
}

gps_protocol_list() {
	local id
	for id in "${GPS_PROTOCOL_IDS[@]}"; do
		printf '%s\n' "$id"
	done
}

gps_protocol_defaults() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_defaults"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn"
	fi
}

gps_protocol_validate() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_validate"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn"
	else
		err "协议模块缺少校验函数: $fn"
	fi
}

gps_proto_inbound_json() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_inbound_json"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn" "$@"
	else
		err "协议模块缺少 inbound 渲染: $fn"
	fi
}

# 可选：额外 inbound（如 ShadowTLS 内层），只调用一次
gps_proto_extra_inbounds() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_extra_inbounds"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn"
	fi
}

gps_proto_share_urls() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_share_urls"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn"
	else
		err "协议模块缺少分享链接: $fn"
	fi
}

gps_proto_share_url() {
	local first=""
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		first=$line
		break
	done < <(gps_proto_share_urls)
	[[ -n $first ]] || err "无可用分享链接"
	printf '%s\n' "$first"
}

# ---------- 加载共享助手与已注册协议模块 ----------
_gps_protocols_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/protocols/_common.sh
source "${_gps_protocols_dir}/_common.sh"
for _gps_proto_id in "${GPS_PROTOCOL_IDS[@]}"; do
	# shellcheck disable=SC1090
	source "${_gps_protocols_dir}/${_gps_proto_id}.sh"
done
unset _gps_protocols_dir _gps_proto_id
