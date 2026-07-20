#!/bin/bash
# GeoProxy Server — 通用工具（含 IPv4/IPv6 自适应）

red='\e[31m'
yellow='\e[33m'
green='\e[92m'
cyan='\e[96m'
gray='\e[90m'
none='\e[0m'

_red() { echo -e "${red}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
_gray() { echo -e "${gray}$*${none}"; }

err() {
  echo -e "\n$(_red "错误:") $*\n" >&2
  exit 1
}

warn() {
  echo -e "\n$(_yellow "警告:") $*\n" >&2
}

msg() {
  echo -e "$*"
}

need_root() {
  [[ $EUID -eq 0 ]] || err "请使用 root 运行（sudo -i 或 sudo bash）"
}

detect_arch() {
  case $(uname -m) in
    amd64 | x86_64) echo amd64 ;;
    *aarch64* | *armv8*) echo arm64 ;;
    *) err "仅支持 amd64 / arm64，当前: $(uname -m)" ;;
  esac
}

need_systemd() {
  type -P systemctl >/dev/null 2>&1 || err "需要 systemd（systemctl）"
}

have_cmd() {
  type -P "$1" >/dev/null 2>&1
}

ensure_deps() {
  local missing=()
  have_cmd curl || missing+=(curl)
  have_cmd openssl || missing+=(openssl)
  have_cmd tar || missing+=(tar)
  have_cmd ip || missing+=(iproute2)
  if ((${#missing[@]})); then
    if have_cmd apt-get; then
      # Debian 包名：iproute2 提供 ip
      local pkgs=()
      for m in "${missing[@]}"; do
        [[ $m == iproute2 ]] && pkgs+=(iproute2) || pkgs+=("$m")
      done
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    elif have_cmd yum; then
      yum install -y -q curl openssl tar iproute
    elif have_cmd dnf; then
      dnf install -y -q curl openssl tar iproute
    else
      err "缺少依赖: ${missing[*]}，请手动安装"
    fi
  fi
}

is_ipv4() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_ipv6() {
  # 粗检：含冒号且非 IPv4
  [[ $1 == *:* ]] && ! is_ipv4 "$1"
}

# URL 里 IPv6 必须加方括号
host_for_url() {
  local h=$1
  if is_ipv6 "$h"; then
    # 去掉已有括号
    h=${h#\[}
    h=${h%\]}
    echo "[$h]"
  else
    echo "$h"
  fi
}

# 本机协议栈：HAS_V4 / HAS_V6 / STACK_MODE=dual|v4only|v6only
detect_local_stack() {
  HAS_V4=0
  HAS_V6=0
  if have_cmd ip; then
    ip -4 addr show scope global 2>/dev/null | grep -q 'inet ' && HAS_V4=1
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && HAS_V6=1
  fi
  # 无全局地址时仍可能只有链路本地；回退：内核是否编译了 IPv6
  if ((HAS_V6 == 0)) && [[ -e /proc/net/if_inet6 ]]; then
    # 有 IPv6 栈但可能尚未分配公网地址，仍允许 listen ::
    HAS_V6=1
  fi
  # 几乎所有 VPS 都应能听 IPv4
  ((HAS_V4 == 0)) && HAS_V4=1

  if ((HAS_V4 && HAS_V6)); then
    STACK_MODE=dual
  elif ((HAS_V6)); then
    STACK_MODE=v6only
  else
    STACK_MODE=v4only
  fi
}

detect_public_ipv4() {
  local ip
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
    is_ipv4 "$ip" && {
      echo "$ip"
      return 0
    }
  done
  return 1
}

detect_public_ipv6() {
  local ip
  for url in \
    "https://api6.ipify.org" \
    "https://ipv6.icanhazip.com" \
    "https://ifconfig.co"; do
    ip=$(curl -6 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
    # ifconfig.co 可能返回 v4；过滤
    is_ipv6 "$ip" && {
      echo "$ip"
      return 0
    }
  done
  return 1
}

# 自适应探测：能拿到啥记啥，互不阻塞
detect_public_ips() {
  local v4="" v6=""
  v4=$(detect_public_ipv4) || true
  v6=$(detect_public_ipv6) || true
  PUBLIC_IP=${PUBLIC_IP:-$v4}
  PUBLIC_IP6=${PUBLIC_IP6:-$v6}
  if [[ -z ${PUBLIC_IP:-} && -z ${PUBLIC_IP6:-} ]]; then
    return 1
  fi
  return 0
}

load_state() {
  [[ -f $GPS_STATE ]] || return 1
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$GPS_STATE"
  set +a
  PUBLIC_IP=${PUBLIC_IP:-}
  PUBLIC_IP6=${PUBLIC_IP6:-}
  # 恢复测试前缀路径
  if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
    gps_apply_paths
  fi
  GPS_NO_SYSTEMD=${GPS_NO_SYSTEMD:-0}
  return 0
}

save_state() {
  umask 077
  mkdir -p "$GPS_ETC"
  # 流量相关默认值
  KIWI_API_BASE=${KIWI_API_BASE:-https://api.64clouds.com/v1}
  TRAFFIC_WARN_PCT=${TRAFFIC_WARN_PCT:-80}
  TRAFFIC_STOP_PCT=${TRAFFIC_STOP_PCT:-95}
  TRAFFIC_CHECK_SEC=${TRAFFIC_CHECK_SEC:-300}
  TRAFFIC_TRIPPED=${TRAFFIC_TRIPPED:-0}
  cat >"$GPS_STATE" <<EOF
PORT=${PORT}
UUID=${UUID}
PASSWORD=${PASSWORD}
PUBLIC_IP=${PUBLIC_IP:-}
PUBLIC_IP6=${PUBLIC_IP6:-}
STACK_MODE=${STACK_MODE:-}
LOG_LEVEL=${LOG_LEVEL:-debug}
CORE_VER=${CORE_VER:-}
KIWI_VEID=${KIWI_VEID:-}
KIWI_API_KEY=${KIWI_API_KEY:-}
KIWI_API_BASE=${KIWI_API_BASE}
TRAFFIC_WARN_PCT=${TRAFFIC_WARN_PCT}
TRAFFIC_STOP_PCT=${TRAFFIC_STOP_PCT}
TRAFFIC_CHECK_SEC=${TRAFFIC_CHECK_SEC}
TRAFFIC_TRIPPED=${TRAFFIC_TRIPPED}
TRAFFIC_LAST_PCT=${TRAFFIC_LAST_PCT:-}
TRAFFIC_LAST_CHECK=${TRAFFIC_LAST_CHECK:-}
TRAFFIC_LAST_ERROR=${TRAFFIC_LAST_ERROR:-}
GPS_TEST_PREFIX=${GPS_TEST_PREFIX:-}
GPS_NO_SYSTEMD=${GPS_NO_SYSTEMD:-0}
INSTALLED_AT=${INSTALLED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
EOF
  chmod 600 "$GPS_STATE"
}

rand_port() {
  local p
  for _ in $(seq 1 40); do
    p=$((20000 + RANDOM % 40000))
    if ! ss -lun | awk '{print $5}' | grep -qE ":${p}\$"; then
      echo "$p"
      return 0
    fi
  done
  echo $((30000 + RANDOM % 10000))
}

gen_uuid() {
  if [[ -x $GPS_CORE_BIN ]]; then
    "$GPS_CORE_BIN" generate uuid 2>/dev/null && return 0
  fi
  if have_cmd uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
}

confirm_yes() {
  local prompt=${1:-确认继续?}
  local ans
  read -r -p "$prompt [y/N] " ans
  [[ $ans == y || $ans == Y || $ans == yes ]]
}
