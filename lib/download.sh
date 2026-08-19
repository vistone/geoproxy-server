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

# 从任意仓库的 GitHub Release API 取资产 sha256 摘要（digest 由 GitHub 计算）
gps_repo_asset_digest() {
	local repo=$1 tag=$2 asset=$3
	have_cmd python3 || err "需要 python3 解析 GitHub API（用于校验下载完整性）"
	local digest
	digest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${repo}/releases/tags/${tag}" |
		python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for a in d.get("assets") or []:
    if a.get("name") == sys.argv[1]:
        g = a.get("digest") or ""
        print(g.split(":", 1)[1] if g.startswith("sha256:") else g)
        sys.exit(0)
sys.exit(1)' "$asset") || return 1
	[[ -n $digest ]] || return 1
	printf '%s' "$digest"
}

# sing-box 核心资产摘要
gps_core_asset_digest() {
	gps_repo_asset_digest SagerNet/sing-box "$1" "$2"
}

# 校验归档：清单中该资产必须恰好一行且 sha256 一致（缺失/重复/不匹配都拒绝）
gps_verify_core_archive() {
	local archive=$1 manifest=$2 asset=$3
	[[ -f $archive ]] || err "归档不存在: $archive"
	[[ -f $manifest ]] || err "校验清单不存在: $manifest"
	local count expected actual
	count=$(awk -v a="$asset" '$2==a{n++} END{print n+0}' "$manifest")
	[[ $count -eq 1 ]] || err "校验清单异常: ${asset} 条目数=${count}（应为 1），拒绝解压"
	expected=$(awk -v a="$asset" '$2==a{print $1; exit}' "$manifest")
	actual=$(sha256sum "$archive" | awk '{print $1}')
	[[ ${expected,,} == "${actual,,}" ]] || err "sha256 校验失败: $asset（清单=${expected} 实际=${actual}），拒绝解压"
	msg "$(_green "sha256 校验通过") $asset"
}

# 装入新核心；旧二进制保留为 .prev 供失败回滚
gps_install_core_from() {
	local bin=$1
	mkdir -p "$GPS_LIB_DIR"
	if [[ -x $GPS_CORE_BIN ]]; then
		mv -f "$GPS_CORE_BIN" "${GPS_CORE_BIN}.prev"
	fi
	install -m 755 "$bin" "$GPS_CORE_BIN"
}

# 回滚到上一版核心；无 .prev（首次安装）返回 1
gps_rollback_core() {
	[[ -x ${GPS_CORE_BIN}.prev ]] || return 1
	mv -f "${GPS_CORE_BIN}.prev" "$GPS_CORE_BIN"
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
	# 解压前先做完整性校验：GitHub API digest → 本地 sha256 对比
	local asset="${name}.tar.gz" digest
	if ! digest=$(gps_core_asset_digest "$tag" "$asset"); then
		rm -rf "$tmp"
		err "无法获取 ${asset} 的 sha256 摘要（GitHub API），已中止；请稍后重试或检查网络"
	fi
	printf '%s  %s\n' "$digest" "$asset" >"${tmp}/sha256sums.txt"
	gps_verify_core_archive "${tmp}/sb.tar.gz" "${tmp}/sha256sums.txt" "$asset"
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
	gps_install_core_from "$bin"
	rm -rf "$tmp"
	CORE_VER="$ver"
	msg "$(_green "已安装") $GPS_CORE_BIN ($tag)"
}

# ---------- geoproxy-server 脚本自身升级 ----------

gps_self_latest_tag() {
	curl -fsSL --max-time 20 \
		"https://api.github.com/repos/${GPS_SELF_REPO}/releases/latest" |
		grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 |
		sed -E 's/.*"?(v[^"]+)"?.*/\1/' | grep -oE 'v[0-9.]+' | head -1
}

gps_self_resolve_ver() {
	local ver=${1:-latest}
	if [[ -z $ver || $ver == latest ]]; then
		ver=$(gps_self_latest_tag) || err "无法获取 ${GPS_SELF_REPO} 最新版本"
	fi
	[[ $ver == v* ]] || ver="v${ver}"
	echo "$ver"
}

# 校验 release asset：GitHub API digest 与本地 sha256 必须一致
gps_verify_release_asset() {
	local archive=$1 tag=$2 asset=$3
	local digest
	if ! digest=$(gps_repo_asset_digest "${GPS_SELF_REPO}" "$tag" "$asset"); then
		err "无法获取 ${asset} 的 sha256 摘要（GitHub API），拒绝安装"
	fi
	printf '%s  %s\n' "$digest" "$asset" >"${archive}.sha256sums"
	gps_verify_core_archive "$archive" "${archive}.sha256sums" "$asset"
}

# 解出的脚本树 VERSION 必须与目标 tag 一致（防串包/缓存/半包）
gps_verify_tree_version() {
	local root=$1 tag=$2 v
	v=$(tr -d '[:space:]' <"${root}/VERSION" 2>/dev/null || echo "")
	[[ -n $v ]] || err "脚本树缺少 VERSION 文件，拒绝安装"
	[[ $v == "$tag" ]] || err "脚本树 VERSION(${v}) 与目标版本(${tag})不一致，拒绝安装"
}

# 从远程 tag 拉取脚本树；仅把仓库根打印到 stdout（日志走 stderr）
# 优先 Release asset（sha256 校验）；旧版本 Release 无 asset 时回退 tag archive（VERSION-tag 一致性校验）
gps_self_fetch_tree() {
	local tag=$1
	local dest=$2
	mkdir -p "$dest"
	local asset="geoproxy-server-${tag}.tar.gz"
	local aurl="https://github.com/${GPS_SELF_REPO}/releases/download/${tag}/${asset}"
	local turl="https://github.com/${GPS_SELF_REPO}/archive/refs/tags/${tag}.tar.gz"
	if curl -fsSL --max-time 120 "$aurl" -o "${dest}/src.tar.gz" 2>/dev/null; then
		echo -e "$(_cyan "下载") ${GPS_SELF_REPO} ${tag} (release asset, sha256 校验) ..." >&2
		# stdout 是数据通道（只回传树根），校验消息全部转 stderr
		gps_verify_release_asset "${dest}/src.tar.gz" "$tag" "$asset" >&2
	else
		echo -e "$(_yellow "无 release asset，回退 tag archive（仅 VERSION 一致性校验）") ${tag}" >&2
		curl -fsSL --max-time 120 "$turl" -o "${dest}/src.tar.gz" || err "下载失败: $turl"
	fi
	tar -xzf "${dest}/src.tar.gz" -C "$dest" || err "解压失败"
	local script root
	script=$(find "$dest" -mindepth 1 -name geoproxy-server.sh -type f | head -1 || true)
	[[ -n $script && -f $script ]] || err "归档中未找到 geoproxy-server.sh"
	root=$(cd "$(dirname "$script")" && pwd -P)
	gps_verify_tree_version "$root" "$tag"
	echo "$root"
}

# 用 src_root 覆盖已安装脚本（保留 state/config/tls/sing-box）
gps_self_install_tree() {
	local src_root=$1
	# $(fetch) 若混入日志，取最后一行作为路径
	src_root=${src_root##*$'\n'}
	src_root=${src_root%%$'\r'}
	[[ -f $src_root/geoproxy-server.sh ]] || err "无效脚本树: $src_root"
	mkdir -p "$GPS_LIB_DIR"
	local staging="${GPS_LIB_DIR}/.scripts.staging.$$"
	rm -rf "$staging"
	mkdir -p "$staging"
	cp -a "$src_root/." "$staging/"
	# 原子替换
	rm -rf "${GPS_LIB_DIR}/scripts.prev"
	if [[ -d ${GPS_LIB_DIR}/scripts ]]; then
		mv "${GPS_LIB_DIR}/scripts" "${GPS_LIB_DIR}/scripts.prev"
	fi
	mv "$staging" "${GPS_LIB_DIR}/scripts"
	GPS_ROOT="${GPS_LIB_DIR}/scripts"
	GPS_TMPL="${GPS_ROOT}/templates"
	# 只写入口，不再从 GPS_ROOT 全量拷（已在上面拷好）
	mkdir -p "$(dirname "$GPS_BIN_LINK")"
	cat >"$GPS_BIN_LINK" <<EOF
#!/bin/bash
export GPS_TEST_PREFIX='${GPS_TEST_PREFIX:-}'
export GPS_NO_SYSTEMD='${GPS_NO_SYSTEMD:-0}'
exec bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" "\$@"
EOF
	chmod 755 "$GPS_BIN_LINK"
	# 刷新 systemd 单元（不改 state.env）
	if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
		local tpl="${GPS_TMPL}/geoproxy-tuic.service"
		if [[ -f $tpl ]]; then
			sed -e "s|__CORE_BIN__|${GPS_CORE_BIN}|g" \
				-e "s|__CONFIG__|${GPS_CONFIG}|g" \
				-e "s|__LOG__|${GPS_LOG}|g" \
				"$tpl" >"$GPS_UNIT_PATH"
		fi
		gps_install_traffic_timer 2>/dev/null || true
		gps_install_logrotate
		systemctl daemon-reload 2>/dev/null || true
	elif [[ -n ${GPS_TEST_PREFIX:-} || ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
		# 测试前缀也写 timer 文件（不 enable）
		gps_install_traffic_timer 2>/dev/null || true
		gps_install_logrotate
	fi
	SCRIPT_VER=$(cat "${GPS_ROOT}/VERSION" 2>/dev/null || echo "$GPS_SH_VER")
	SCRIPT_VER=${SCRIPT_VER//$'\n'/}
	GPS_SH_VER=$SCRIPT_VER
}

gps_cmd_upgrade_self() {
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
		*) err "未知参数: $1（用法: upgrade self [--ver TAG] [--force]）" ;;
		esac
	done
	load_state || err "未安装"
	ensure_deps
	ver=$(gps_self_resolve_ver "$ver")
	local cur=$GPS_SH_VER
	if [[ -f ${GPS_LIB_DIR}/scripts/VERSION ]]; then
		cur=$(tr -d '[:space:]' <"${GPS_LIB_DIR}/scripts/VERSION")
	fi
	if [[ $force -eq 0 && $cur == "$ver" ]]; then
		msg "$(_green "无需升级") 脚本已是 $cur"
		return 0
	fi
	# 先停干净再换文件，禁止在旧进程记忆上 restart
	gps_svc_halt
	local tmp root
	tmp=$(mktemp -d /tmp/gps-self-upgrade.XXXXXX)
	trap 'rm -rf "'"$tmp"'"' RETURN
	# $() 子 shell 捕获 fetch 的 err：失败时旧脚本未动，先拉回服务
	if root=$(gps_self_fetch_tree "$ver" "$tmp"); then :; else
		rm -rf "$tmp"
		trap - RETURN
		gps_svc_boot || true
		err "脚本拉取失败，已用旧脚本恢复服务；稍后重试或 upgrade self --ver <tag>"
	fi
	gps_self_install_tree "$root"
	save_state
	rm -rf "$tmp"
	trap - RETURN
	gps_svc_boot
	# shellcheck disable=SC2034  # 供 gps_reexec_if_menu 读取
	GPS_UPGRADE_DID_WORK=1
	msg "$(_green "脚本已升级") $cur → $GPS_SH_VER"
	msg "配置/证书/凭证未改动；已停止旧进程并用新脚本重新拉起服务"
}
