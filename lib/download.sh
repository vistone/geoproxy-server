#!/bin/bash
# 下载 / 安装 sing-box 二进制

gps_latest_tag() {
	curl -fsSL --max-time 20 \
		"https://api.github.com/repos/SagerNet/sing-box/releases/latest" |
		grep -oE '"tag_name":\s*"v[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/'
}

# 已安装核心版本号（无 v 前缀）；优先读二进制，回退 state.env
gps_core_ver_installed() {
	local v=""
	if [[ -x ${GPS_CORE_BIN:-} ]]; then
		v=$("$GPS_CORE_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
	fi
	if [[ -z $v && -n ${CORE_VER:-} ]]; then
		v=${CORE_VER#v}
	fi
	echo "$v"
}

# 解析目标版本：latest → GitHub 最新 tag；去掉 v 前缀
gps_resolve_core_ver() {
	local ver=${1:-latest}
	if [[ -z $ver || $ver == latest ]]; then
		ver=$(gps_latest_tag) || err "无法获取 sing-box 最新版本（GitHub API）"
	fi
	echo "${ver#v}"
}

gps_download_core() {
	local ver=$1
	local force=${2:-0}
	local arch
	arch=$(detect_arch)
	ensure_deps

	ver=$(gps_resolve_core_ver "$ver")
	local tag="v${ver}"
	local cur
	cur=$(gps_core_ver_installed)
	if [[ $force -eq 0 && -n $cur && $cur == "$ver" && -x ${GPS_CORE_BIN:-} ]]; then
		CORE_VER="$ver"
		msg "$(_green "已是最新") sing-box ${tag}，跳过下载"
		return 0
	fi

	local name="sing-box-${ver}-linux-${arch}"
	local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${name}.tar.gz"
	local tmp
	tmp=$(mktemp -d)
	msg "$(_cyan "下载") sing-box ${tag} (${arch}) ..."
	if ! curl -fL --progress-bar --max-time 300 -o "${tmp}/sb.tar.gz" "$url"; then
		rm -rf "$tmp"
		err "下载失败: $url"
	fi
	tar -xzf "${tmp}/sb.tar.gz" -C "$tmp" || {
		rm -rf "$tmp"
		err "解压失败"
	}
	local bin
	bin=$(find "$tmp" -type f -name sing-box | head -1)
	[[ -n $bin && -x $bin ]] || {
		rm -rf "$tmp"
		err "归档中未找到 sing-box 二进制"
	}
	mkdir -p "$GPS_LIB_DIR"
	install -m 755 "$bin" "$GPS_CORE_BIN"
	rm -rf "$tmp"
	CORE_VER="$ver"
	msg "$(_green "已安装") $GPS_CORE_BIN ($tag)"
}
