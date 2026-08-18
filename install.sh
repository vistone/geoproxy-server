#!/bin/bash
# 一键安装入口：
# - 本地 clone：直接调用同目录 geoproxy-server.sh
# - curl | bash：按版本号拉取完整仓库到临时目录再安装
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
		echo "警告: git clone $GPS_VERSION 失败，改试 tarball ..." >&2
	fi

	if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
		curl -fsSL "$GPS_REPO_TAR" -o "$dest/src.tar.gz"
		tar -xzf "$dest/src.tar.gz" -C "$dest"
		root=$(_gps_find_root "$dest" || true)
		if [[ -n $root ]]; then
			echo "$root"
			return 0
		fi
		echo "错误: 解压后未找到 geoproxy-server.sh（目录内容如下）:" >&2
		find "$dest" -maxdepth 3 -type f >&2 || true
		exit 1
	fi

	echo "错误: 需要 git，或 curl+tar，才能远程安装" >&2
	exit 1
}

ROOT=""
if ROOT=$(_gps_here) && [[ -f $ROOT/geoproxy-server.sh ]]; then
	exec bash "$ROOT/geoproxy-server.sh" install "$@"
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
GPS_REPO_TAR="${GPS_REPO_TAR:-https://github.com/${GPS_SELF_REPO}/archive/refs/tags/${GPS_VERSION}.tar.gz}"

echo "检测到远程/管道安装，正在拉取 geoproxy-server $GPS_VERSION ..."
TMP=$(mktemp -d /tmp/gps-bootstrap.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ROOT=$(_gps_fetch_repo "$TMP")
[[ -f $ROOT/geoproxy-server.sh ]] || {
	echo "错误: 拉取失败，缺少 geoproxy-server.sh (ROOT=$ROOT)" >&2
	exit 1
}
bash "$ROOT/geoproxy-server.sh" install "$@"
