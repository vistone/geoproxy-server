#!/bin/bash
set -euo pipefail
# Test setup for geoproxy-server bats tests
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GPS_TEST_PREFIX="${GPS_TEST_PREFIX:-$REPO_ROOT/tests/tmp}"
export GPS_NO_SYSTEMD=1
# Ensure clean tmp
rm -rf "$GPS_TEST_PREFIX"
mkdir -p "$GPS_TEST_PREFIX"
# Source paths to populate GPS_* variables
# shellcheck source=lib/paths.sh
source "$REPO_ROOT/lib/paths.sh"
# override GPS_ROOT to repo root for sources
GPS_ROOT="$REPO_ROOT"
# Source common and config; silence outputs
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
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
# mimic generate uuid if asked
if [[ "$1" == "generate" && "$2" == "uuid" ]]; then
  echo "00000000-0000-0000-0000-000000000000"
  exit 0
fi
# default: exit 0
exit 0
EOF
chmod +x "$GPS_LIB_DIR/sing-box"
# Ensure log dir exists
mkdir -p "$GPS_LOG_DIR"
mkdir -p "$GPS_TLS_DIR"
# Provide dummy cert/key for gps_ensure_tls if called
cat >"$GPS_CERT" <<'EOF'
-----TEST CERT-----
EOF
cat >"$GPS_KEY" <<'EOF'
-----TEST KEY-----
EOF
chmod 600 "$GPS_CERT" "$GPS_KEY"
