#!/bin/bash
# 一键安装入口：
# - 本地 clone：直接调用同目录 geoproxy-server.sh
# - 远程管道执行：按版本号拉取完整仓库到临时目录再安装
#
# 拉取优先级：git clone(TLS) → Release asset(sha256 校验) → tag archive(仅 GPS_INSTALL_ALLOW_UNVERIFIED=1)
set -euo pipefail

# 默认 latest：向 GitHub Releases 解析最新 tag。钉死某版：GPS_VERSION=vX.Y.Z
GPS_SELF_REPO="${GPS_SELF_REPO:-vistone/geoproxy-server}"
GPS_VERSION="${GPS_VERSION:-latest}"
GPS_REPO_URL="${GPS_REPO_URL:-https://github.com/${GPS_SELF_REPO}.git}"

_gps_latest_tag() {
	curl -fsSL --max-time 20 \
		"https://api.github.com/repos/${GPS_SELF_REPO}/releases/latest" |
		grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 |
		grep -oE 'v[0-9.]+' | head -1
}

# tag 基本校验：防路径注入（无斜杠、无 ..、字母数字与点横线）
_gps_valid_tag() {
	[[ ${1:-} =~ ^v[0-9A-Za-z][0-9A-Za-z.-]*$ ]]
}

_gps_here() {
	local src=${BASH_SOURCE[0]:-}
	if [[ -z $src || $src == /dev/fd/* || $src == /proc/self/fd/* ]]; then
		return 1
	fi
	local dir
	dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P) || return 1
	echo "$dir"
}

# 在 dest 下定位含 geoproxy-server.sh 的仓库根
_gps_find_root() {
	local dest=$1
	local script
	# -mindepth 1：避免临时目录名误匹配
	script=$(find "$dest" -mindepth 1 -name geoproxy-server.sh -type f 2>/dev/null | head -1 || true)
	[[ -n $script && -f $script ]] || return 1
	cd "$(dirname "$script")" && pwd -P
}

# 从 GitHub Release API 取资产 sha256 摘要（digest 由 GitHub 计算）
_gps_asset_digest() {
	local tag=$1 asset=$2 digest
	command -v python3 >/dev/null 2>&1 || return 1
	digest=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${GPS_SELF_REPO}/releases/tags/${tag}" |
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
sys.exit(1)' "$asset" 2>/dev/null) || return 1
	[[ -n $digest ]] || return 1
	printf '%s' "$digest"
}

_gps_fetch_repo() {
	local dest=$1
	mkdir -p "$dest"
	local root=""

	echo "拉取版本: $GPS_VERSION" >&2

	if command -v git >/dev/null 2>&1; then
		if git clone --depth 1 --branch "$GPS_VERSION" "$GPS_REPO_URL" "$dest/repo" >/dev/null 2>&1; then
			root=$(_gps_find_root "$dest/repo" || true)
			if [[ -n $root ]]; then
				echo "$root"
				return 0
			fi
		fi
		echo "警告: git clone $GPS_VERSION 失败，改试 release asset ..." >&2
	fi

	# Release asset：与 upgrade self 相同的信任模型（GitHub API digest → 本地 sha256 对比）
	if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
		local asset="geoproxy-server-${GPS_VERSION}.tar.gz"
		local aurl="https://github.com/${GPS_SELF_REPO}/releases/download/${GPS_VERSION}/${asset}"
		if curl -fsSL --max-time 120 "$aurl" -o "${dest}/src.tar.gz" 2>/dev/null; then
			local digest actual
			if ! digest=$(_gps_asset_digest "$GPS_VERSION" "$asset"); then
				echo "错误: 无法获取 ${asset} 的 sha256 摘要（GitHub API），已中止" >&2
				exit 1
			fi
			actual=$(sha256sum "${dest}/src.tar.gz" | awk '{print $1}')
			if [[ ${digest,,} != "${actual,,}" ]]; then
				echo "错误: sha256 校验失败: ${asset}（API=${digest} 实际=${actual}），拒绝执行" >&2
				exit 1
			fi
			echo "sha256 校验通过: ${asset}" >&2
			tar -xzf "${dest}/src.tar.gz" -C "$dest"
			root=$(_gps_find_root "$dest" || true)
			if [[ -n $root ]]; then
				echo "$root"
				return 0
			fi
			echo "错误: 解压后未找到 geoproxy-server.sh" >&2
			exit 1
		fi
		echo "警告: 无 release asset（${GPS_VERSION}），尝试 tag archive ..." >&2
	fi

	# tag archive 无法做摘要校验（GitHub 自动归档不发布 digest）：仅显式 opt-in 时使用
	if [[ ${GPS_INSTALL_ALLOW_UNVERIFIED:-0} == 1 ]]; then
		if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
			local turl="https://github.com/${GPS_SELF_REPO}/archive/refs/tags/${GPS_VERSION}.tar.gz"
			echo "警告: GPS_INSTALL_ALLOW_UNVERIFIED=1 — 使用未校验的 tag archive（仅排障）" >&2
			curl -fsSL --max-time 120 "$turl" -o "${dest}/src.tar.gz"
			tar -xzf "${dest}/src.tar.gz" -C "$dest"
			root=$(_gps_find_root "$dest" || true)
			if [[ -n $root ]]; then
				echo "$root"
				return 0
			fi
			echo "错误: 解压后未找到 geoproxy-server.sh（目录内容如下）:" >&2
			find "$dest" -maxdepth 3 -type f >&2 || true
			exit 1
		fi
	else
		echo "错误: 版本 ${GPS_VERSION} 无 release asset；如确需未校验的 tag archive，设 GPS_INSTALL_ALLOW_UNVERIFIED=1 后重试" >&2
		exit 1
	fi

	echo "错误: 需要 git，或 curl+python3+sha256sum（release asset 路径），才能远程安装" >&2
	exit 1
}

gps_bootstrap_main() {
	local root=""
	if root=$(_gps_here) && [[ -f $root/geoproxy-server.sh ]]; then
		exec bash "$root/geoproxy-server.sh" install "$@"
	fi

	# 管道安装才解析 latest，避免本地 clone 依赖 GitHub API
	if [[ $GPS_VERSION == latest || -z $GPS_VERSION ]]; then
		GPS_VERSION=$(_gps_latest_tag || true)
		[[ -n $GPS_VERSION ]] || {
			echo "错误: 无法从 GitHub 获取 ${GPS_SELF_REPO} 最新版本" >&2
			exit 1
		}
	fi
	[[ $GPS_VERSION == v* ]] || GPS_VERSION="v${GPS_VERSION}"
	_gps_valid_tag "$GPS_VERSION" || {
		echo "错误: 无效版本号: ${GPS_VERSION}（应为 vX.Y.Z 形式）" >&2
		exit 1
	}

	echo "检测到远程/管道安装，正在拉取 geoproxy-server $GPS_VERSION ..."
	local tmp
	tmp=$(mktemp -d /tmp/gps-bootstrap.XXXXXX)
	# 须立即展开路径：local tmp 在函数返回后不可见，EXIT trap 里 "$tmp" 会在 set -u 下报 unbound
	trap 'rm -rf "'"$tmp"'"' EXIT
	root=$(_gps_fetch_repo "$tmp")
	[[ -f $root/geoproxy-server.sh ]] || {
		echo "错误: 拉取失败，缺少 geoproxy-server.sh (ROOT=$root)" >&2
		exit 1
	}
	bash "$root/geoproxy-server.sh" install "$@"
}

# 仅直接执行时引导；被 source 时只暴露函数（供 bats 测试）
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	gps_bootstrap_main "$@"
fi
