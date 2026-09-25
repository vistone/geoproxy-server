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
	# 走 stderr：调用方用 $(...) 捕获 stdout 当路径，msg 到 stdout 会污染路径捕获
	msg "$(_green "sha256 校验通过") $asset" >&2
}

# $(cmd) 捕获路径时剥掉可能混入的日志行，只留最后一行
gps_stdout_path() {
	local s=$1
	s=${s##*$'\n'}
	s=${s%%$'\r'}
	# 去掉 ANSI 着色残留
	# shellcheck disable=SC2001
	s=$(printf '%s' "$s" | sed 's/\x1b\[[0-9;]*m//g')
	printf '%s' "$s"
}

# 装入新核心；旧二进制保留为 .prev 供失败回滚（先写 .new 再 mv，避免中断丢二进制）
gps_install_core_from() {
	local bin=$1
	bin=$(gps_stdout_path "$bin")
	[[ -n $bin && -f $bin ]] || err "核心二进制不存在或路径无效: ${bin:-<empty>}"
	mkdir -p "$GPS_LIB_DIR" || err "无法创建核心目录: $GPS_LIB_DIR"
	install -m 755 "$bin" "${GPS_CORE_BIN}.new" || err "安装核心失败: $bin → ${GPS_CORE_BIN}.new"
	if [[ -x $GPS_CORE_BIN ]]; then
		mv -f "$GPS_CORE_BIN" "${GPS_CORE_BIN}.prev"
	fi
	mv -f "${GPS_CORE_BIN}.new" "$GPS_CORE_BIN"
}

# 回滚到上一版核心；无 .prev（首次安装）返回 1
gps_rollback_core() {
	[[ -x ${GPS_CORE_BIN}.prev ]] || return 1
	mv -f "${GPS_CORE_BIN}.prev" "$GPS_CORE_BIN"
}

# 下载并校验 sing-box 到 dest_dir，stdout 仅打印二进制路径；不触碰 GPS_CORE_BIN。
# 供 upgrade core 的 fetch-then-swap：失败时服务零影响。
gps_fetch_core_to() {
	local ver=$1
	local force=${2:-0}
	local dest_dir=$3
	local arch
	arch=$(detect_arch)
	ensure_deps

	ver=$(gps_resolve_core_ver "$ver")
	local tag="v${ver}"
	local cur
	cur=$(gps_core_ver_installed)
	if [[ $force -eq 0 && -n $cur && $cur == "$ver" && -x ${GPS_CORE_BIN:-} ]]; then
		CORE_VER="$ver"
		msg "$(_green "已是最新") sing-box ${tag}，跳过下载" >&2
		printf '%s' "$GPS_CORE_BIN"
		return 0
	fi

	[[ -n $dest_dir ]] || err "gps_fetch_core_to: 缺少目标目录"
	mkdir -p "$dest_dir"

	local name="sing-box-${ver}-linux-${arch}"
	local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${name}.tar.gz"
	local tmp
	tmp=$(mktemp -d)
	msg "$(_cyan "下载") sing-box ${tag} (${arch}) ..." >&2
	if ! curl -fL --progress-bar --max-time 300 -o "${tmp}/sb.tar.gz" "$url"; then
		rm -rf "$tmp"
		err "下载失败: $url"
	fi
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
	install -m 755 "$bin" "${dest_dir}/sing-box"
	rm -rf "$tmp"
	CORE_VER="$ver"
	msg "$(_green "已下载并校验") ${dest_dir}/sing-box ($tag)" >&2
	printf '%s' "${dest_dir}/sing-box"
}

gps_download_core() {
	local ver=$1
	local force=${2:-0}
	local cur
	cur=$(gps_core_ver_installed)
	ver=$(gps_resolve_core_ver "$ver")
	if [[ $force -eq 0 && -n $cur && $cur == "$ver" && -x ${GPS_CORE_BIN:-} ]]; then
		CORE_VER="$ver"
		msg "$(_green "已是最新") sing-box v${ver}，跳过下载"
		return 0
	fi
	local tmp bin
	tmp=$(mktemp -d)
	# $() 捕获 fetch 的 err：失败时不碰已装核心
	if bin=$(gps_fetch_core_to "$ver" "$force" "$tmp"); then :; else
		rm -rf "$tmp"
		return 1
	fi
	bin=$(gps_stdout_path "$bin")
	# 已是最新时 fetch 可能返回现有 GPS_CORE_BIN
	if [[ $bin == "$GPS_CORE_BIN" ]]; then
		rm -rf "$tmp"
		return 0
	fi
	gps_install_core_from "$bin"
	rm -rf "$tmp"
	msg "$(_green "已安装") $GPS_CORE_BIN (v${CORE_VER})"
}

# ---------- geoproxy-server 脚本自身升级 ----------

# 升级后强制重启 mesh-master（不依赖升级前内存里的 gps_install_mesh_units）
# 调用方须已 load_state / 设好 MESH_ROLE；此处不再 load_state（避免从 state.env 把 GPS_TEST_PREFIX 拉回来）。
gps_upgrade_restart_mesh_master() {
	[[ ${MESH_ROLE:-master} == master ]] || return 0
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_install_mesh_units 2>/dev/null || true
		return 0
	fi
	need_systemd 2>/dev/null || true
	systemctl daemon-reload >/dev/null 2>&1 || true
	local svc=${GPS_MESH_MASTER_SERVICE:-geoproxy-mesh-master}
	if systemctl restart "$svc" >/dev/null 2>&1 ||
		systemctl restart geoproxy-mesh-master.service >/dev/null 2>&1; then
		msg "$(_cyan "mesh-master") 已重启（应用 TLS / 新脚本）"
	else
		warn "mesh-master restart 失败；请手动: systemctl restart geoproxy-mesh-master"
	fi
}

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

# 解出的脚本树 VERSION 必须与目标 tag 一致，且关键文件结构完整
gps_verify_tree_version() {
	local root=$1 tag=$2 v
	v=$(tr -d '[:space:]' <"${root}/VERSION" 2>/dev/null || echo "")
	[[ -n $v ]] || err "脚本树缺少 VERSION 文件，拒绝安装"
	[[ $v == "$tag" ]] || err "脚本树 VERSION(${v}) 与目标版本(${tag})不一致，拒绝安装"
	# 校验关键文件存在且非空，防止半包/截断归档
	local required=(
		"geoproxy-server.sh"
		"lib/common.sh"
		"lib/config.sh"
		"lib/paths.sh"
		"lib/mesh/_registry.sh"
		"scripts/mesh_master.py"
		"scripts/geoagent.py"
	)
	local f
	for f in "${required[@]}"; do
		[[ -s "${root}/${f}" ]] || err "脚本树缺少关键文件: ${f}（归档可能损坏）"
	done
	# 校验 bash 脚本语法（关键入口）
	bash -n "${root}/geoproxy-server.sh" 2>/dev/null ||
		err "脚本树入口语法错误（归档可能损坏）"
}

# 从远程 tag 拉取脚本树；仅把仓库根打印到 stdout（日志走 stderr）
# 优先 Release asset（sha256 校验）；tag archive 仅 GPS_INSTALL_ALLOW_UNVERIFIED=1（对齐 install.sh，N-07）
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
	elif [[ ${GPS_INSTALL_ALLOW_UNVERIFIED:-0} == 1 ]]; then
		echo -e "$(_yellow "GPS_INSTALL_ALLOW_UNVERIFIED=1 — 回退未校验 tag archive（仅排障）") ${tag}" >&2
		curl -fsSL --max-time 120 "$turl" -o "${dest}/src.tar.gz" || err "下载失败: $turl"
	else
		err "无 release asset（${tag}）；如确需未校验的 tag archive，设 GPS_INSTALL_ALLOW_UNVERIFIED=1 后重试"
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
export GPS_TEST_PREFIX=$(printf '%q' "${GPS_TEST_PREFIX:-}")
export GPS_NO_SYSTEMD=$(printf '%q' "${GPS_NO_SYSTEMD:-0}")
exec bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" "\$@"
EOF
	chmod 755 "$GPS_BIN_LINK"
	# 刷新 systemd 单元（不改 state.env）
	if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
		local tpl="${GPS_TMPL}/geoproxy-tuic.service"
		if [[ -f $tpl ]]; then
			local bin=${GPS_BIN_LINK:-/usr/local/bin/geoproxy-server}
			sed -e "s|__CORE_BIN__|${GPS_CORE_BIN}|g" \
				-e "s|__CONFIG__|${GPS_CONFIG}|g" \
				-e "s|__LOG__|${GPS_LOG}|g" \
				-e "s|__ETC_DIR__|${GPS_ETC}|g" \
				-e "s|__LOG_DIR__|${GPS_LOG_DIR}|g" \
				-e "s|__BIN__|${bin}|g" \
				"$tpl" | gps_atomic_write_file "$GPS_UNIT_PATH" 644
		fi
		gps_install_traffic_timer 2>/dev/null || true
		gps_install_mesh_units 2>/dev/null || true
		gps_install_agent_units 2>/dev/null || true
		gps_install_logrotate
		systemctl daemon-reload 2>/dev/null || true
	elif [[ -n ${GPS_TEST_PREFIX:-} || ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
		# 测试前缀也写 timer 文件（不 enable）
		gps_install_traffic_timer 2>/dev/null || true
		gps_install_mesh_units_files_only 2>/dev/null || true
		gps_install_agent_units_files_only 2>/dev/null || true
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
	gps_upgrade_lock_acquire || err "另一升级正在进行，请稍后重试"
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
		*)
			gps_upgrade_lock_release
			err "未知参数: $1（用法: upgrade self [--ver TAG] [--force]）"
			;;
		esac
	done
	load_state || {
		gps_upgrade_lock_release
		err "未安装"
	}
	ensure_deps
	ver=$(gps_self_resolve_ver "$ver")
	local cur=$GPS_SH_VER
	if [[ -f ${GPS_LIB_DIR}/scripts/VERSION ]]; then
		cur=$(tr -d '[:space:]' <"${GPS_LIB_DIR}/scripts/VERSION")
	fi
	if [[ $force -eq 0 && $cur == "$ver" ]]; then
		msg "$(_green "无需升级") 脚本已是 $cur"
		gps_upgrade_lock_release
		return 0
	fi
	# 稳定性关键路径：先下载并校验新脚本树，成功后才停服换树。
	local tmp root
	tmp=$(mktemp -d /tmp/gps-self-upgrade.XXXXXX)
	if root=$(gps_self_fetch_tree "$ver" "$tmp"); then :; else
		rm -rf "$tmp"
		gps_upgrade_lock_release
		err "脚本拉取失败（服务未受影响）；稍后重试或 upgrade self --ver <tag>"
	fi
	gps_svc_halt
	# 停服后任何异常退出都必须把服务拉回来，并释放升级锁
	trap 'gps_svc_boot >/dev/null 2>&1 || true; gps_upgrade_lock_release' EXIT
	gps_self_install_tree "$root"
	save_state
	rm -rf "$tmp"
	if [[ -x ${GPS_BIN_LINK:-} ]]; then
		"$GPS_BIN_LINK" mesh ensure || warn "mesh ensure 未成功（将在服务启动 ExecStartPre 再试）"
	elif [[ -f ${GPS_LIB_DIR}/scripts/geoproxy-server.sh ]]; then
		bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" mesh ensure || warn "mesh ensure 未成功（将在服务启动 ExecStartPre 再试）"
	fi
	if [[ -x ${GPS_BIN_LINK:-} ]]; then
		"$GPS_BIN_LINK" agent ensure 2>/dev/null || warn "agent ensure 未成功（可运行 geoproxy-server install 重建）"
	elif [[ -f ${GPS_LIB_DIR}/scripts/geoproxy-server.sh ]]; then
		bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" agent ensure 2>/dev/null || warn "agent ensure 未成功（可运行 geoproxy-server install 重建）"
	fi
	gps_upgrade_restart_mesh_master
	trap - EXIT
	if ! gps_svc_boot; then
		warn "升级后启动失败，重试一次…"
		gps_svc_boot || warn "服务仍未拉起，请手动: systemctl start ${GPS_SERVICE}"
	fi
	gps_upgrade_lock_release
	# shellcheck disable=SC2034
	GPS_UPGRADE_DID_WORK=1
	msg "$(_green "脚本已升级") $cur → $GPS_SH_VER"
	msg "配置/证书/凭证未改动；已停止旧进程并用新脚本重新拉起服务"
	if [[ ${MESH_ROLE:-master} == master ]]; then
		load_state 2>/dev/null || true
		msg "$(_cyan "组网 Master") overlay=${MESH_OVERLAY_IP:-?} wg=${WG_PUBLIC_KEY:-(未生成)}"
		gps_mesh_print_join_hints 2>/dev/null || true
	fi
}
