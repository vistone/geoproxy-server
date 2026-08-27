#!/bin/bash
set -euo pipefail
# Test setup for geoproxy-server bats tests
# Determine repo root (works inside bats where BATS_TEST_DIRNAME is set)
if [[ -n "${BATS_TEST_DIRNAME:-}" ]]; then
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
else
	REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
export REPO_ROOT
export GPS_TEST_PREFIX="${GPS_TEST_PREFIX:-$REPO_ROOT/tests/tmp}"
export GPS_NO_SYSTEMD=1
# 测试里 mock curl 时不等待 mesh-master 就绪（生产默认 8s）
export GPS_MESH_HEALTH_WAIT=0
# Ensure clean tmp
rm -rf "$GPS_TEST_PREFIX"
mkdir -p "$GPS_TEST_PREFIX"
# Source paths to populate GPS_* variables
# shellcheck source=lib/paths.sh
source "$REPO_ROOT/lib/paths.sh"
# override GPS_ROOT to repo root for sources
GPS_ROOT="$REPO_ROOT"
# Source common, tls and config; silence outputs
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=lib/tls.sh
source "$REPO_ROOT/lib/tls.sh"
# shellcheck source=lib/protocols/_registry.sh
source "$REPO_ROOT/lib/protocols/_registry.sh"
# shellcheck source=lib/mesh/_registry.sh
source "$REPO_ROOT/lib/mesh/_registry.sh"
# shellcheck source=lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# Create fake sing-box binary that supports 'check'
mkdir -p "$GPS_LIB_DIR"
cat >"$GPS_LIB_DIR/sing-box" <<'EOF'
#!/bin/bash
# minimal fake sing-box for tests
if [[ "$1" == "check" ]]; then
  exit 0
fi
if [[ "$1" == "generate" && "$2" == "uuid" ]]; then
  echo "00000000-0000-4000-8000-000000000000"
  exit 0
fi
if [[ "$1" == "generate" && "$2" == "reality-keypair" ]]; then
  echo "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE"
  echo "PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE"
  exit 0
fi
if [[ "$1" == "generate" && "$2" == "wg-keypair" ]]; then
  echo "PrivateKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE="
  echo "PublicKey: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE="
  exit 0
fi
if [[ "$1" == "generate" && "$2" == "rand" ]]; then
  n=16
  for a in "$@"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then n="$a"; fi
  done
  openssl rand -base64 "$n" | tr -d '\n'
  exit 0
fi
exit 0
EOF
chmod +x "$GPS_LIB_DIR/sing-box"
# Ensure log dir and pid dir exist
mkdir -p "$GPS_LOG_DIR"
mkdir -p "$(dirname "$GPS_PID_FILE")"
mkdir -p "$GPS_TLS_DIR"
# Provide dummy cert/key for gps_ensure_tls if called
cat >"$GPS_CERT" <<'EOF'
-----TEST CERT-----
EOF
cat >"$GPS_KEY" <<'EOF'
-----TEST KEY-----
EOF
chmod 600 "$GPS_CERT" "$GPS_KEY"
# Default minimal identity values to satisfy save_state/gps_write_config
export PORT=${PORT:-12345}
export UUID=${UUID:-test-uuid}
export PASSWORD=${PASSWORD:-test-pass}

# NTFS (Git Bash / Windows) does not honor chmod 600; only assert mode on POSIX
check_perm_600() {
	if [[ -n ${MSYSTEM:-} ]]; then
		return 0
	fi
	local p
	p=$(stat -c %a "$1")
	[ "$p" -eq 600 ]
}

# bats 每个测试结束后清理：只删测试前缀，绝不越界
teardown() {
	rm -rf "$GPS_TEST_PREFIX"
}
