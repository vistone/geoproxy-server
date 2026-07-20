#!/bin/bash
# GeoProxy Server — 路径与常量（VPS 端单实例 TUIC）
#
# 本地测试可设：
#   GPS_TEST_PREFIX=/tmp/geoproxy-test  或  install --prefix DIR --no-systemd

GPS_NAME="geoproxy-server"
GPS_SH_VER="v0.2.0"
GPS_SERVICE="geoproxy-tuic"
GPS_TRAFFIC_SERVICE="geoproxy-traffic"
GPS_TRAFFIC_TIMER="geoproxy-traffic.timer"

# 仓库内模板目录（相对本 lib 的上级）——先算 GPS_ROOT
GPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPS_TMPL="${GPS_ROOT}/templates"

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
		GPS_PID_FILE="${base}/var/run/${GPS_NAME}.pid"
	else
		GPS_PREFIX="/usr/local"
		GPS_ETC="/etc/${GPS_NAME}"
		GPS_LOG_DIR="/var/log/${GPS_NAME}"
		GPS_UNIT_PATH="/etc/systemd/system/${GPS_SERVICE}.service"
		GPS_TRAFFIC_UNIT_PATH="/etc/systemd/system/${GPS_TRAFFIC_SERVICE}.service"
		GPS_TRAFFIC_TIMER_PATH="/etc/systemd/system/${GPS_TRAFFIC_TIMER}"
		GPS_PID_FILE="/var/run/${GPS_NAME}.pid"
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
}

gps_apply_paths
