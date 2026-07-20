#!/bin/bash
# GeoProxy Server — VPS 端入口（菜单优先 / CLI 为辅）
set -euo pipefail

GPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$GPS_ROOT/lib/paths.sh"
# 覆盖 GPS_ROOT（paths.sh 会按 lib 上级重算，与此处一致）
GPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPS_TMPL="${GPS_ROOT}/templates"

# shellcheck source=lib/common.sh
source "$GPS_ROOT/lib/common.sh"
# shellcheck source=lib/download.sh
source "$GPS_ROOT/lib/download.sh"
# shellcheck source=lib/tls.sh
source "$GPS_ROOT/lib/tls.sh"
# shellcheck source=lib/config.sh
source "$GPS_ROOT/lib/config.sh"
# shellcheck source=lib/systemd.sh
source "$GPS_ROOT/lib/systemd.sh"
# shellcheck source=lib/doctor.sh
source "$GPS_ROOT/lib/doctor.sh"
# shellcheck source=lib/url.sh
source "$GPS_ROOT/lib/url.sh"
# shellcheck source=lib/bbr.sh
source "$GPS_ROOT/lib/bbr.sh"
# shellcheck source=lib/traffic.sh
source "$GPS_ROOT/lib/traffic.sh"
# shellcheck source=lib/cmd.sh
source "$GPS_ROOT/lib/cmd.sh"
# shellcheck source=lib/menu.sh
source "$GPS_ROOT/lib/menu.sh"

main() {
  if [[ $# -eq 0 ]]; then
    gps_menu
    return
  fi
  local cmd=$1
  shift
  case $cmd in
    install) gps_cmd_install "$@" ;;
    uninstall | un) gps_cmd_uninstall "$@" ;;
    start | stop | restart)
      if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
        need_root
      fi
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      load_state 2>/dev/null || true
      gps_svc "$cmd"
      ;;
    info | i)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_info
      ;;
    url)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_url
      ;;
    qr)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_qr
      ;;
    log)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_log "$@"
      ;;
    doctor)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_doctor
      ;;
    status)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_svc status --no-pager || true
      ;;
    change)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_change "$@"
      ;;
    traffic)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_traffic "$@"
      ;;
    upgrade)
      [[ -n ${GPS_TEST_PREFIX:-} ]] && gps_apply_paths
      gps_cmd_upgrade "$@"
      ;;
    bbr) gps_enable_bbr ;;
    help | h | -h | --help) gps_help ;;
    version | v | -v | --version) msg "$GPS_NAME $GPS_SH_VER" ;;
    menu) gps_menu ;;
    *)
      warn "未知命令: $cmd"
      gps_help
      exit 1
      ;;
  esac
}

main "$@"
