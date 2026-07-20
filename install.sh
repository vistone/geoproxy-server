#!/bin/bash
# 一键安装入口：
# - 本地 clone：直接调用同目录 geoproxy-server.sh
# - curl | bash：按版本号拉取完整仓库到临时目录再安装
set -euo pipefail

# 固定版本：安装/bootstrap 都钉死这个 tag，避免 main CDN 缓存旧脚本
GPS_VERSION="${GPS_VERSION:-v0.2.1}"
GPS_REPO_URL="${GPS_REPO_URL:-https://github.com/vistone/geoproxy-server.git}"
GPS_REPO_TAR="${GPS_REPO_TAR:-https://github.com/vistone/geoproxy-server/archive/refs/tags/${GPS_VERSION}.tar.gz}"

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

echo "检测到远程/管道安装，正在拉取 geoproxy-server $GPS_VERSION ..."
TMP=$(mktemp -d /tmp/gps-bootstrap.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
ROOT=$(_gps_fetch_repo "$TMP")
[[ -f $ROOT/geoproxy-server.sh ]] || {
  echo "错误: 拉取失败，缺少 geoproxy-server.sh (ROOT=$ROOT)" >&2
  exit 1
}
bash "$ROOT/geoproxy-server.sh" install "$@"
