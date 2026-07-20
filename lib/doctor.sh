#!/bin/bash
# 健康检查（含双栈）

gps_doctor() {
  local ok=0 fail=0
  check() {
    local name=$1
    shift
    if "$@"; then
      msg "  $(_green OK)  $name"
      ok=$((ok + 1))
    else
      msg "  $(_red FAIL) $name"
      fail=$((fail + 1))
    fi
  }
  warn_item() {
    msg "  $(_yellow WARN) $1"
  }

  msg "$(_cyan "== GeoProxy Server doctor ==")"
  detect_local_stack
  msg "  本机栈: STACK_MODE=${STACK_MODE} HAS_V4=${HAS_V4} HAS_V6=${HAS_V6}"

  check "systemd 可用" need_systemd_ok
  check "sing-box 二进制可执行" test -x "$GPS_CORE_BIN"
  check "配置文件存在" test -f "$GPS_CONFIG"
  check "state.env 存在" test -f "$GPS_STATE"
  check "TLS 证书存在" test -f "$GPS_CERT"
  check "TLS 私钥存在" test -f "$GPS_KEY"
  if [[ -x $GPS_CORE_BIN && -f $GPS_CONFIG ]]; then
    check "sing-box check" "$GPS_CORE_BIN" check -c "$GPS_CONFIG"
  else
    msg "  $(_yellow SKIP) sing-box check（缺二进制或配置）"
  fi
  if have_cmd systemctl && [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
    check "服务 active" systemctl is-active --quiet "$GPS_SERVICE"
  elif [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
    check "sing-box 进程 (no-systemd)" gps_pid_running
  fi
  if load_state 2>/dev/null; then
    check "PORT 已设置 ($PORT)" test -n "$PORT"
    if [[ -n $PORT ]] && have_cmd ss; then
      # IPv4 UDP
      if ((HAS_V4)); then
        if ss -lun4 2>/dev/null | grep -qE ":${PORT}\\b" || ss -lun | grep -qE "0\\.0\\.0\\.0:${PORT}\\b|\\*:${PORT}\\b"; then
          msg "  $(_green OK)  UDP IPv4 监听 :$PORT"
          ok=$((ok + 1))
        else
          # 部分系统 ss -lun 合并显示
          if ss -lun | grep -qE ":${PORT}\\b"; then
            msg "  $(_green OK)  UDP 监听 :$PORT（未区分族）"
            ok=$((ok + 1))
          else
            msg "  $(_red FAIL) UDP IPv4 监听 :$PORT"
            fail=$((fail + 1))
          fi
        fi
      fi
      if ((HAS_V6)); then
        if ss -lun6 2>/dev/null | grep -qE ":${PORT}\\b" || ss -lun | grep -qE "\\[::\\]:${PORT}|:::${PORT}|\\*:${PORT}\\b"; then
          msg "  $(_green OK)  UDP IPv6 监听 :$PORT"
          ok=$((ok + 1))
        else
          warn_item "UDP IPv6 监听 :$PORT 未看到（若仅有 IPv4 公网可忽略）"
        fi
      fi
    fi
    if [[ -n ${PUBLIC_IP:-} ]]; then
      msg "  $(_green OK)  PUBLIC_IP(v4)=${PUBLIC_IP}"
      ok=$((ok + 1))
    else
      warn_item "PUBLIC_IP(v4) 未设置 — change ip <v4> 或依赖自动探测"
    fi
    if [[ -n ${PUBLIC_IP6:-} ]]; then
      msg "  $(_green OK)  PUBLIC_IP6=${PUBLIC_IP6}"
      ok=$((ok + 1))
    else
      warn_item "PUBLIC_IP6 未设置 — 无 IPv6 公网时可忽略；有则: change ip6 <v6>"
    fi
    if [[ -z ${PUBLIC_IP:-} && -z ${PUBLIC_IP6:-} ]]; then
      msg "  $(_red FAIL) 无任何公网地址（url 无法对接 GeoProxy）"
      fail=$((fail + 1))
    fi
    gps_traffic_defaults
    if [[ -n ${KIWI_VEID:-} && -n ${KIWI_API_KEY:-} ]]; then
      msg "  $(_green OK)  KiwiVM 已配置 veid=$KIWI_VEID"
      ok=$((ok + 1))
      msg "  流量阈值: warn=${TRAFFIC_WARN_PCT}% stop=${TRAFFIC_STOP_PCT}% tripped=${TRAFFIC_TRIPPED} last=${TRAFFIC_LAST_PCT:-?}%"
      if [[ ${TRAFFIC_TRIPPED:-0} == 1 ]]; then
        warn_item "流量熔断中 — 需: traffic resume"
      fi
      if have_cmd systemctl && [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
        if systemctl is-active --quiet geoproxy-traffic.timer 2>/dev/null; then
          msg "  $(_green OK)  geoproxy-traffic.timer active"
          ok=$((ok + 1))
        else
          warn_item "geoproxy-traffic.timer 未 active — change kiwivm 后会启用"
        fi
      fi
    else
      warn_item "未配置 KiwiVM（流量熔断未启用）— change kiwivm <veid> <api_key>"
    fi
  fi
  msg
  msg "结果: ok=$ok fail=$fail"
  ((fail == 0))
}

need_systemd_ok() {
  have_cmd systemctl
}
