#!/usr/bin/env bash
# GeoProxy Server — Cloud Agent 开发环境依赖安装（幂等）
#
# 安装 CI（.github/workflows/ci.yml）使用的三件套（版本 / 校验和保持一致）：
#   - shfmt      v3.13.1  （格式检查）
#   - shellcheck v0.11.0  （静态检查）
#   - bats       v1.14.0  （测试框架）
#
# 与 lib/download.sh / CI 同一信任模型：二进制按官方 sha256 digest 校验。
# 升级版本时同步更新此处 SHA（来自 GitHub Release API 的 digest 字段）与 CI。
set -euo pipefail

SHFMT_VERSION="v3.13.1"
SHFMT_SHA256="fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1"
SHELLCHECK_VERSION="v0.11.0"
SHELLCHECK_SHA256="8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198"
BATS_VERSION="v1.14.0"

BIN_DIR="/usr/local/bin"
BATS_SRC_DIR="/usr/local/lib/bats-src"

log() { printf '[install] %s\n' "$*"; }

# 非 root 时用 sudo；两者都不可用则直接失败（不静默降级）
if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	echo "[install] 需要 root 或 sudo 才能写入 $BIN_DIR" >&2
	exit 1
fi

# 仅支持 x86_64（与 CI 固定的 amd64 二进制一致）
arch="$(uname -m)"
if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
	echo "[install] 仅支持 x86_64，当前架构为 $arch" >&2
	exit 1
fi

check_sha() { # $1=期望sha256hex $2=文件
	local actual
	actual="$(sha256sum "$2" | awk '{print $1}')"
	if [ "${1,,}" != "${actual,,}" ]; then
		echo "[install] digest 不匹配: $2 (expected=$1 actual=$actual)" >&2
		exit 1
	fi
}

install_shfmt() {
	if command -v shfmt >/dev/null 2>&1 && [ "$(shfmt --version 2>/dev/null)" = "$SHFMT_VERSION" ]; then
		log "shfmt $SHFMT_VERSION 已安装，跳过"
		return 0
	fi
	log "安装 shfmt $SHFMT_VERSION"
	local tmp
	tmp="$(mktemp)"
	curl -fsSL --retry 3 -o "$tmp" \
		"https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64"
	check_sha "$SHFMT_SHA256" "$tmp"
	$SUDO install -m 755 "$tmp" "$BIN_DIR/shfmt"
	rm -f "$tmp"
}

install_shellcheck() {
	if command -v shellcheck >/dev/null 2>&1 &&
		shellcheck --version 2>/dev/null | grep -q "version: ${SHELLCHECK_VERSION#v}"; then
		log "shellcheck $SHELLCHECK_VERSION 已安装，跳过"
		return 0
	fi
	log "安装 shellcheck $SHELLCHECK_VERSION"
	local tmp
	tmp="$(mktemp --suffix=.tar.xz)"
	curl -fsSL --retry 3 -o "$tmp" \
		"https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"
	check_sha "$SHELLCHECK_SHA256" "$tmp"
	$SUDO tar -xJf "$tmp" -C "$BIN_DIR" --strip-components=1 \
		"shellcheck-${SHELLCHECK_VERSION}/shellcheck"
	rm -f "$tmp"
}

install_bats() {
	if command -v bats >/dev/null 2>&1 &&
		bats --version 2>/dev/null | grep -q "${BATS_VERSION#v}"; then
		log "bats $BATS_VERSION 已安装，跳过"
		return 0
	fi
	log "安装 bats $BATS_VERSION"
	# bats 上游只发布源码归档（无官方 digest），按 tag git clone（TLS + GitHub 签出）
	$SUDO rm -rf "$BATS_SRC_DIR"
	$SUDO git clone --depth 1 --branch "$BATS_VERSION" \
		https://github.com/bats-core/bats-core.git "$BATS_SRC_DIR"
	$SUDO ln -sf "$BATS_SRC_DIR/bin/bats" "$BIN_DIR/bats"
}

install_shfmt
install_shellcheck
install_bats

log "版本核对："
shfmt --version
shellcheck --version | sed -n '1,2p'
bats --version
log "开发环境依赖就绪。"
