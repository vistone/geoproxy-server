#!/bin/bash
# 生成 / 校验 TUIC 配置（IPv4/IPv6 自适应监听）

# 生成单个 inbound JSON 片段（不含尾逗号）
_gps_inbound_json() {
  local tag=$1 listen=$2
  cat <<EOF
    {
      "type": "tuic",
      "tag": "${tag}",
      "listen": "${listen}",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "${GPS_SERVICE}",
          "uuid": "${UUID}",
          "password": "${PASSWORD}"
        }
      ],
      "congestion_control": "bbr",
      "auth_timeout": "3s",
      "zero_rtt_handshake": true,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "certificate_path": "${GPS_CERT}",
        "key_path": "${GPS_KEY}",
        "alpn": ["h3"]
      }
    }
EOF
}

gps_write_config() {
  [[ -n $PORT && -n $UUID && -n $PASSWORD ]] || err "PORT/UUID/PASSWORD 未设置"
  gps_ensure_tls
  mkdir -p "$GPS_ETC" "$GPS_LOG_DIR"
  detect_local_stack

  # Linux: bindv6only=0 时 listen :: 已是双栈，再绑 0.0.0.0 会 EADDRINUSE
  local bindv6only=0
  if [[ -r /proc/sys/net/ipv6/bindv6only ]]; then
    bindv6only=$(cat /proc/sys/net/ipv6/bindv6only)
  fi

  local inbounds=""
  case $STACK_MODE in
    dual)
      if [[ $bindv6only == 1 ]]; then
        inbounds="$(_gps_inbound_json tuic-in-v4 0.0.0.0),
$(_gps_inbound_json tuic-in-v6 ::)"
        msg "$(_cyan "监听模式") STACK_MODE=dual bindv6only=1 → 0.0.0.0 + ::"
      else
        # 单一 :: 双栈 socket，同时接 IPv4-mapped 与 IPv6
        inbounds="$(_gps_inbound_json tuic-in-dual ::)"
        msg "$(_cyan "监听模式") STACK_MODE=dual bindv6only=0 → ::（双栈）"
      fi
      ;;
    v6only)
      inbounds="$(_gps_inbound_json tuic-in-v6 ::)"
      msg "$(_cyan "监听模式") STACK_MODE=v6only → ::"
      ;;
    *)
      inbounds="$(_gps_inbound_json tuic-in-v4 0.0.0.0)"
      msg "$(_cyan "监听模式") STACK_MODE=v4only → 0.0.0.0"
      ;;
  esac

  # debug：可看到进站/出站连接；info 仅启动信息；warn 几乎为空
  local log_level=${LOG_LEVEL:-debug}
  case $log_level in
    trace | debug | info | warn | error | fatal | panic) ;;
    *) log_level=debug ;;
  esac
  LOG_LEVEL=$log_level
  cat >"$GPS_CONFIG" <<EOF
{
  "log": {
    "level": "${log_level}",
    "timestamp": true,
    "output": "${GPS_LOG}"
  },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  chmod 600 "$GPS_CONFIG"
  gps_check_config
}

# 从 config.json 读出当前 level
gps_config_log_level() {
  [[ -f ${GPS_CONFIG:-} ]] || {
    echo "${LOG_LEVEL:-debug}"
    return 0
  }
  grep -oE '"level"[[:space:]]*:[[:space:]]*"[a-z]+"' "$GPS_CONFIG" | head -1 |
    sed -E 's/.*"([a-z]+)".*/\1/' || echo "${LOG_LEVEL:-debug}"
}

# 写入日志级别并校验；调用方负责 save_state / restart
gps_set_log_level() {
  local level=${1:-debug}
  case $level in
    trace | debug | info | warn | error | fatal | panic) ;;
    *) err "无效日志级别: $level（可用: trace debug info warn error fatal panic）" ;;
  esac
  LOG_LEVEL=$level
  [[ -f $GPS_CONFIG ]] || err "配置不存在，请先 install"
  if grep -qE '"level"[[:space:]]*:' "$GPS_CONFIG"; then
    sed -i -E "s/\"level\"[[:space:]]*:[[:space:]]*\"[a-z]+\"/\"level\": \"${level}\"/" "$GPS_CONFIG"
  else
    err "配置中缺少 log.level"
  fi
  gps_check_config
  msg "$(_green "日志级别") → $level（进站/出站连接建议 debug）"
}

# 旧安装默认 warn/info → 抬到 debug，否则看不到进/出站连接
gps_bump_log_level_if_quiet() {
  [[ -f ${GPS_CONFIG:-} ]] || return 0
  local cur
  cur=$(gps_config_log_level)
  case $cur in
    debug | trace) return 0 ;;
    warn | error | fatal | panic | info | "")
      gps_set_log_level debug
      ;;
  esac
}

gps_check_config() {
  [[ -x $GPS_CORE_BIN ]] || err "sing-box 未安装: $GPS_CORE_BIN"
  [[ -f $GPS_CONFIG ]] || err "配置不存在: $GPS_CONFIG"
  "$GPS_CORE_BIN" check -c "$GPS_CONFIG" || err "sing-box check 失败"
}

# 打印一条 TUIC URL；host 已是裸地址
_gps_one_url() {
  local host=$1
  [[ -n $host ]] || return 1
  # Format: tuic://<uuid>:<password>@<host>:<port>?params
  # Include a name field so clients can display a friendly label (use service name)
  local name=${GPS_SERVICE:-geoproxy-tuic}
  printf 'tuic://%s:%s@%s:%s?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr&name=%s\n'     "$UUID" "$PASSWORD" "$(host_for_url "$host")" "$PORT" "$name"
}


# 输出所有可用 URL（v4 / v6），自适应；至少一行
gps_tuic_urls() {
  load_state || err "未安装或缺少 state.env（请先 install）"
  local printed=0
  local v4=${PUBLIC_IP:-} v6=${PUBLIC_IP6:-}

  if [[ -z $v4 ]]; then
    v4=$(detect_public_ipv4) || true
  fi
  if [[ -z $v6 ]]; then
    v6=$(detect_public_ipv6) || true
  fi

  if [[ -n $v4 ]]; then
    _gps_one_url "$v4"
    printed=1
  fi
  if [[ -n $v6 ]]; then
    _gps_one_url "$v6"
    printed=1
  fi
  if ((printed == 0)); then
    warn "未探测到公网 IPv4/IPv6，请: change ip <v4> 和/或 change ip6 <v6>"
    _gps_one_url "YOUR_PUBLIC_IP"
  fi
}

# 兼容旧调用：优先 v4，否则 v6
gps_tuic_url() {
  local first=""
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    first=$line
    break
  done < <(gps_tuic_urls)
  [[ -n $first ]] || err "无可用 TUIC URL"
  printf '%s\n' "$first"
}
