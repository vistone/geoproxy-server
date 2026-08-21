#!/bin/bash
# 协议注册表（Phase 0：仅 tuic）
# 设计：docs/superpowers/specs/2026-08-21-protocol-plugin-design.md

# shellcheck disable=SC2034  # 白名单供 list / 未来 CLI 使用
GPS_PROTOCOL_IDS=(tuic)

# 规范化 PROTOCOL；缺省 tuic；未知 id 失败（落盘前调用）
gps_protocol_normalize() {
	PROTOCOL=${PROTOCOL:-tuic}
	PROTOCOL=$(printf '%s' "$PROTOCOL" | tr '[:upper:]' '[:lower:]')
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

# 按当前 PROTOCOL 做字段校验（install / change 落盘前）
gps_protocol_validate() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_validate"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn"
	else
		err "协议模块缺少校验函数: $fn"
	fi
}

# 生成单个 inbound JSON 片段（不含尾逗号）
gps_proto_inbound_json() {
	gps_protocol_normalize
	local fn="gps_proto_${PROTOCOL}_inbound_json"
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn" "$@"
	else
		err "协议模块缺少 inbound 渲染: $fn"
	fi
}

# 分享链接（多行）；协议模块应实现 gps_proto_<id>_share_urls
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

# ---------- 加载已注册协议模块 ----------
_gps_protocols_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/protocols/tuic.sh
source "${_gps_protocols_dir}/tuic.sh"
unset _gps_protocols_dir
