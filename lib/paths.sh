#!/bin/bash
# GeoProxy Server — 路径与常量（VPS 端单实例；默认入站协议 TUIC）
#
# 本地测试可设：
#   GPS_TEST_PREFIX=/tmp/geoproxy-test  或  install --prefix DIR --no-systemd

# shellcheck disable=SC2034  # 路径常量由 source 本文件的其他模块使用
GPS_NAME="geoproxy-server"
GPS_SERVICE="geoproxy-tuic"
GPS_TRAFFIC_SERVICE="geoproxy-traffic"
GPS_TRAFFIC_TIMER="geoproxy-traffic.timer"
GPS_MESH_MASTER_SERVICE="geoproxy-mesh-master"
GPS_MESH_SYNC_SERVICE="geoproxy-mesh-sync"
GPS_MESH_SYNC_TIMER="geoproxy-mesh-sync.timer"
GPS_MESH_MASTER_PORT="${GPS_MESH_MASTER_PORT:-19527}"
GPS_AGENT_SERVICE="geoproxy-agent"
GPS_AGENT_PORT="${GPS_AGENT_PORT:-19528}"
GPS_SELF_REPO="${GPS_SELF_REPO:-vistone/geoproxy-server}"
GPS_SELF_REPO_URL="${GPS_SELF_REPO_URL:-https://github.com/${GPS_SELF_REPO}.git}"

# 仓库内模板目录（相对本 lib 的上级）——先算 GPS_ROOT，版本只读 VERSION
GPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPS_TMPL="${GPS_ROOT}/templates"
GPS_SH_VER=$(tr -d '[:space:]' <"${GPS_ROOT}/VERSION" 2>/dev/null || echo unknown)

# 可被环境或 --prefix 覆盖
GPS_TEST_PREFIX="${GPS_TEST_PREFIX:-}"
GPS_NO_SYSTEMD="${GPS_NO_SYSTEMD:-0}"

gps_apply_paths() {
	if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
		local base="${GPS_TEST_PREFIX%/}"
		GPS_PREFIX="${base}/usr/local"
		GPS_ETC="${base}/etc/${GPS_NAME}"
		GPS_LOG_DIR="${base}/var/log/${GPS_NAME}"
		GPS_UNIT_PATH="${base}/etc/systemd/system/${GPS_SERVICE}.service"
		GPS_TRAFFIC_UNIT_PATH="${base}/etc/systemd/system/${GPS_TRAFFIC_SERVICE}.service"
		GPS_TRAFFIC_TIMER_PATH="${base}/etc/systemd/system/${GPS_TRAFFIC_TIMER}"
		GPS_MESH_MASTER_UNIT_PATH="${base}/etc/systemd/system/${GPS_MESH_MASTER_SERVICE}.service"
		GPS_MESH_SYNC_UNIT_PATH="${base}/etc/systemd/system/${GPS_MESH_SYNC_SERVICE}.service"
		GPS_MESH_SYNC_TIMER_PATH="${base}/etc/systemd/system/${GPS_MESH_SYNC_TIMER}"
		GPS_AGENT_UNIT_PATH="${base}/etc/systemd/system/geoproxy-agent.service"
		GPS_AGENT_ENV="${GPS_ETC}/agent.env"
		GPS_PID_FILE="${base}/var/run/${GPS_NAME}.pid"
		GPS_KIWI_PERSIST="${base}/etc/geoproxy-kiwivm.env"
		GPS_LOGROTATE_PATH="${base}/etc/logrotate.d/${GPS_NAME}"
	else
		GPS_PREFIX="/usr/local"
		GPS_ETC="/etc/${GPS_NAME}"
		GPS_LOG_DIR="/var/log/${GPS_NAME}"
		GPS_UNIT_PATH="/etc/systemd/system/${GPS_SERVICE}.service"
		GPS_TRAFFIC_UNIT_PATH="/etc/systemd/system/${GPS_TRAFFIC_SERVICE}.service"
		GPS_TRAFFIC_TIMER_PATH="/etc/systemd/system/${GPS_TRAFFIC_TIMER}"
		GPS_MESH_MASTER_UNIT_PATH="/etc/systemd/system/${GPS_MESH_MASTER_SERVICE}.service"
		GPS_MESH_SYNC_UNIT_PATH="/etc/systemd/system/${GPS_MESH_SYNC_SERVICE}.service"
		GPS_MESH_SYNC_TIMER_PATH="/etc/systemd/system/${GPS_MESH_SYNC_TIMER}"
		GPS_AGENT_UNIT_PATH="/etc/systemd/system/geoproxy-agent.service"
		GPS_AGENT_ENV="${GPS_ETC}/agent.env"
		GPS_PID_FILE="/var/run/${GPS_NAME}.pid"
		GPS_KIWI_PERSIST="/etc/geoproxy-kiwivm.env"
		GPS_LOGROTATE_PATH="/etc/logrotate.d/${GPS_NAME}"
	fi
	GPS_BIN_LINK="${GPS_PREFIX}/bin/${GPS_NAME}"
	GPS_LIB_DIR="${GPS_PREFIX}/lib/${GPS_NAME}"
	GPS_CORE_BIN="${GPS_LIB_DIR}/sing-box"
	GPS_STATE="${GPS_ETC}/state.env"
	GPS_CONFIG="${GPS_ETC}/config.json"
	GPS_TLS_DIR="${GPS_ETC}/tls"
	GPS_CERT="${GPS_TLS_DIR}/cert.pem"
	GPS_KEY="${GPS_TLS_DIR}/key.pem"
	GPS_LOG="${GPS_LOG_DIR}/sing-box.log"
	GPS_TRAFFIC_LOG="${GPS_LOG_DIR}/traffic.log"
	GPS_MESH_DIR="${GPS_ETC}/mesh"
	GPS_MESH_PEERS="${GPS_MESH_DIR}/peers.json"
	GPS_MESH_TOKEN_FILE="${GPS_MESH_DIR}/token"
	GPS_MESH_TLS_CERT="${GPS_MESH_DIR}/master-tls.pem"
	GPS_MESH_TLS_KEY="${GPS_MESH_DIR}/master-tls.key"
	GPS_MESH_TLS_FP="${GPS_MESH_DIR}/master-tls.fp"
	GPS_MESH_ENV="${GPS_MESH_DIR}/master.env"
	GPS_MESH_MASTER_PY="${GPS_ROOT}/scripts/mesh_master.py"
	GPS_AGENT_PY="${GPS_ROOT}/scripts/geoagent.py"
}

gps_apply_paths
