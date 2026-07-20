#!/bin/bash
# 一键安装入口：
# - 本地 clone：直接调用同目录 geoproxy-server.sh
# - curl | bash：自动拉取完整仓库到临时目录再安装
set -euo pipefail

GPS_REPO_URL="${GPS_REPO_URL:-https://github.com/vistone/geoproxy-server.git}"
GPS_REPO_TAR="${GPS_REPO_TAR:-https://github.com/vistone/geoproxy-server/archive/refs/heads/main.tar.gz}"

_gps_here() {
	# BASH_SOURCE 在 process substitution 下可能是 /dev/fd/63，不能当仓库根
	local src=${BASH_SOURCE[0]:-}
	if [[ -z $src || $src == /dev/fd/* || $src == /proc/self/fd/* ]]; then
		return 1
	fi
	local dir
	dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd -P) || return 1
	echo "$dir"
}

_gps_fetch_repo() {
	local dest=$1
	mkdir -p "$dest"
	if command -v git >/dev/null 2>&1; then
		git clone --depth 1 "$GPS_REPO_URL" "$dest/repo" >/dev/null
		echo "$dest/repo"
		return 0
	fi
	if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
		curl -fsSL "$GPS_REPO_TAR" -o "$dest/src.tar.gz"
		tar -xzf "$dest/src.tar.gz" -C "$dest"
		local dir
		dir=$(find "$dest" -maxdepth 1 -type d -name 'geoproxy-server-*' | head -1)
		[[ -n $dir && -f $dir/geoproxy-server.sh ]] || {
			echo "错误: 解压后未找到 geoproxy-server.sh" >&2
			exit 1
		}
		echo "$dir"
		return 0
	fi
	echo "错误: 需要 git，或 curl+tar，才能远程安装" >&2
	exit 1
}

ROOT=""
if ROOT=$(_gps_here) && [[ -f $ROOT/geoproxy-server.sh ]]; then
	exec bash "$ROOT/geoproxy-server.sh" install "$@"
fi

echo "检测到远程/管道安装，正在拉取 geoproxy-server ..."
TMP=$(mktemp -d /tmp/geoproxy-server-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ROOT=$(_gps_fetch_repo "$TMP")
[[ -f $ROOT/geoproxy-server.sh ]] || {
	echo "错误: 拉取失败，缺少 geoproxy-server.sh" >&2
	exit 1
}
# 不用 exec：安装会把脚本拷到 /usr/local，结束后 trap 清理临时目录
bash "$ROOT/geoproxy-server.sh" install "$@"
