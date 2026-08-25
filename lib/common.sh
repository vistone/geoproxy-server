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
	have_cmd logrotate || missing+=(logrotate)
	if ((${#missing[@]})); then
		if have_cmd apt-get; then
			# Debian 包名：iproute2 提供 ip
			local pkgs=()
			for m in "${missing[@]}"; do
				[[ $m == iproute2 ]] && pkgs+=(iproute2) || pkgs+=("$m")
			done
			apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
		elif have_cmd yum; then
			yum install -y -q curl openssl tar iproute logrotate
		elif have_cmd dnf; then
			dnf install -y -q curl openssl tar iproute logrotate
		else
			err "缺少依赖: ${missing[*]}，请手动安装"
		fi
	fi
}

# 缺 logrotate 时自动安装（跟随发行版包管理器）；装不上返回 1 由调用方降级
ensure_logrotate() {
	have_cmd logrotate && return 0
	msg "$(_cyan "安装") logrotate ..."
	if have_cmd apt-get; then
		apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq logrotate
	elif have_cmd yum; then
		yum install -y -q logrotate
	elif have_cmd dnf; then
		dnf install -y -q logrotate
	else
		return 1
	fi
	have_cmd logrotate
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

# 分享链接节点名：TUIC_NAME > hostname -f > hostname
gps_tuic_node_name() {
	local n=${TUIC_NAME:-}
	if [[ -z $n ]]; then
		n=$(hostname -f 2>/dev/null || true)
		n=${n%%$'\n'}
		if [[ -z $n || $n == localhost || $n == localhost.localdomain || $n == "(none)" ]]; then
			n=$(hostname 2>/dev/null || true)
			n=${n%%$'\n'}
		fi
		if [[ -z $n || $n == localhost || $n == "(none)" ]]; then
			n=geoproxy-tuic
		fi
	fi
	printf '%s' "$n"
}

# 百分号编码（节点名 fragment）
gps_urlencode() {
	local s=$1
	if have_cmd python3; then
		python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=".-_~"))' "$s"
		return
	fi
	local i c out="" LC_ALL=C
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[a-zA-Z0-9._~-]) out+=$c ;;
		*)
			printf -v c '%%%02X' "'$c"
			out+=$c
			;;
		esac
	done
	printf '%s' "$out"
}

# ---------- 输入校验 / JSON 转义 / 状态文件安全 ----------

gps_validate_port() {
	[[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

gps_validate_uuid() {
	[[ ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]
}

gps_validate_single_line() {
	# bash 变量无法容纳 NUL，只需挡住换行/回车
	[[ ${1:-} != *$'\n'* && ${1:-} != *$'\r'* ]]
}

# 严格 IPv4：四段且每段 0-255
gps_validate_ipv4() {
	local ip=${1:-} o
	[[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	for o in "${BASH_REMATCH[@]:1}"; do
		((10#$o >= 0 && 10#$o <= 255)) || return 1
	done
	return 0
}

# 严格 IPv6：python3 ipaddress。返回 2 表示缺 python3 无法校验（调用方给可操作提示）
gps_validate_ipv6() {
	local ip=${1:-}
	[[ -n $ip ]] || return 1
	have_cmd python3 || return 2
	python3 -c 'import ipaddress,sys
try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    sys.exit(1)' "$ip"
}

# 流量阈值必须都在 1-100 且告警 < 停服
gps_validate_traffic_thresholds() {
	local warn=${1:-} stop=${2:-}
	[[ $warn =~ ^[0-9]+$ && $stop =~ ^[0-9]+$ ]] || return 1
	((10#$warn >= 1 && 10#$warn <= 100 && 10#$stop >= 1 && 10#$stop <= 100)) || return 1
	((10#$warn < 10#$stop))
}

# ---------- 状态互斥锁：flock 优先，无 flock 时 mkdir 自旋回退 ----------

# 同进程持锁：获取后返回，锁保持到 gps_state_lock_release 或进程退出
gps_state_lock_acquire() {
	mkdir -p "$GPS_ETC"
	if have_cmd flock; then
		exec 9>>"${GPS_ETC}/state.lock"
		flock -x 9
		return 0
	fi
	local d="${GPS_ETC}/state.lock.dir" i
	for i in $(seq 1 300); do
		mkdir "$d" 2>/dev/null && return 0
		sleep 0.1
	done
	err "获取状态锁超时: $d（若确认无其他实例可删除后重试）"
}

gps_state_lock_release() {
	if have_cmd flock; then
		exec 9>&- 2>/dev/null || true
	else
		rmdir "${GPS_ETC}/state.lock.dir" 2>/dev/null || true
	fi
}

# 串行化状态/timer 变更。在当前 shell 持锁执行（保留变量写回）；
# 已持锁（同进程）则直接执行，防自死锁。
gps_with_state_lock() {
	if [[ ${GPS_STATE_LOCK_HELD:-0} == 1 ]]; then
		"$@"
		return $?
	fi
	mkdir -p "$GPS_ETC"
	if have_cmd flock; then
		exec 9>>"${GPS_ETC}/state.lock"
		flock -x 9
	else
		gps_state_lock_acquire
	fi
	local rc=0
	GPS_STATE_LOCK_HELD=1 "$@" || rc=$?
	gps_state_lock_release
	return "$rc"
}

# JSON 字符串转义：反斜杠/引号/控制字符（\b \f \n \r \t）
gps_json_escape() {
	local s=$1 out='' i c
	local LC_ALL=C
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		# shellcheck disable=SC1003  # case 模式里的 \\ 是反斜杠字符本身
		case $c in
		\\) out+='\\\\' ;;
		\") out+='\\\"' ;;
		$'\b') out+='\b' ;;
		$'\f') out+='\f' ;;
		$'\n') out+='\n' ;;
		$'\r') out+='\r' ;;
		$'\t') out+='\t' ;;
		*) out+=$c ;;
		esac
	done
	printf '%s' "$out"
}

# %q 序列化一行 KEY=VALUE，source 时按字面值还原（防注入）
gps_env_assign() {
	printf '%s=%q\n' "$1" "${2:-}"
}

# 同目录临时文件 + mv 原子写入（读端不会看到半写的文件）
gps_atomic_write_env() {
	local dest=$1 tmp
	mkdir -p "$(dirname "$dest")"
	tmp=$(mktemp "${dest}.tmp.XXXXXX") || err "无法创建临时文件: ${dest}.tmp.*"
	cat >"$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$dest"
}

# source 前的安全检查：拒绝符号链接；生产模式要求属主=当前用户且无组/其他写
gps_source_env() {
	local f=$1
	[[ -f $f ]] || return 1
	[[ ! -L $f ]] || err "拒绝加载符号链接状态文件: $f"
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		local mode owner
		mode=$(stat -c '%a' "$f" 2>/dev/null || echo 0)
		if [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 8#022) != 0)); then
			err "状态文件权限过宽 (${mode}): $f（应为 600）"
		fi
		owner=$(stat -c '%u' "$f" 2>/dev/null || echo -1)
		[[ $owner == "$EUID" ]] || err "状态文件属主不是当前用户: $f"
	fi
	set -a
	# shellcheck disable=SC1090
	source "$f"
	set +a
	return 0
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
	gps_source_env "$GPS_STATE"
	PUBLIC_IP=${PUBLIC_IP:-}
	PUBLIC_IP6=${PUBLIC_IP6:-}
	# 旧安装无 PROTOCOL → tuic；未知值在写配置前由 gps_protocol_normalize 拒绝
	PROTOCOL=${PROTOCOL:-tuic}
	PROFILE=${PROFILE:-mesh-member}
	# 恢复测试前缀路径
	if [[ -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_apply_paths
	fi
	GPS_NO_SYSTEMD=${GPS_NO_SYSTEMD:-0}
	gps_kiwi_load_persist
	return 0
}

# KiwiVM 凭证长期保存（卸载不删 /etc/geoproxy-kiwivm.env）
gps_kiwi_load_persist() {
	local f=${GPS_KIWI_PERSIST:-}
	[[ -n $f ]] || return 0
	gps_source_env "$f" || return 0
}

gps_kiwi_save_persist() {
	local f=${GPS_KIWI_PERSIST:-}
	[[ -n $f ]] || return 0
	[[ -n ${KIWI_VEID:-} && -n ${KIWI_API_KEY:-} ]] || return 0
	umask 077
	{
		gps_env_assign KIWI_VEID "$KIWI_VEID"
		gps_env_assign KIWI_API_KEY "$KIWI_API_KEY"
		gps_env_assign KIWI_API_BASE "${KIWI_API_BASE:-https://api.64clouds.com/v1}"
	} | gps_atomic_write_env "$f"
}

# 私有：无锁写入。调用方须经 save_state（持锁）或确认单线程。
gps_save_state_unlocked() {
	umask 077
	mkdir -p "$GPS_ETC"
	# 流量相关默认值
	KIWI_API_BASE=${KIWI_API_BASE:-https://api.64clouds.com/v1}
	TRAFFIC_WARN_PCT=${TRAFFIC_WARN_PCT:-80}
	TRAFFIC_STOP_PCT=${TRAFFIC_STOP_PCT:-95}
	TRAFFIC_CHECK_SEC=${TRAFFIC_CHECK_SEC:-300}
	TRAFFIC_TRIPPED=${TRAFFIC_TRIPPED:-0}
	PROTOCOL=${PROTOCOL:-tuic}
	{
		gps_env_assign PROTOCOL "${PROTOCOL}"
		gps_env_assign PORT "${PORT:-}"
		gps_env_assign UUID "${UUID:-}"
		gps_env_assign PASSWORD "${PASSWORD:-}"
		gps_env_assign PUBLIC_IP "${PUBLIC_IP:-}"
		gps_env_assign PUBLIC_IP6 "${PUBLIC_IP6:-}"
		gps_env_assign STACK_MODE "${STACK_MODE:-}"
		gps_env_assign LOG_LEVEL "${LOG_LEVEL:-debug}"
		gps_env_assign LOG_LEVEL_EXPLICIT "${LOG_LEVEL_EXPLICIT:-0}"
		gps_env_assign CORE_VER "${CORE_VER:-}"
		gps_env_assign KIWI_VEID "${KIWI_VEID:-}"
		gps_env_assign KIWI_API_KEY "${KIWI_API_KEY:-}"
		gps_env_assign KIWI_API_BASE "${KIWI_API_BASE}"
		gps_env_assign TRAFFIC_WARN_PCT "${TRAFFIC_WARN_PCT}"
		gps_env_assign TRAFFIC_STOP_PCT "${TRAFFIC_STOP_PCT}"
		gps_env_assign TRAFFIC_CHECK_SEC "${TRAFFIC_CHECK_SEC}"
		gps_env_assign TRAFFIC_TRIPPED "${TRAFFIC_TRIPPED}"
		if [[ -n ${TRAFFIC_TRIPPED_AT:-} ]]; then
			gps_env_assign TRAFFIC_TRIPPED_AT "${TRAFFIC_TRIPPED_AT}"
		fi
		gps_env_assign TRAFFIC_LAST_PCT "${TRAFFIC_LAST_PCT:-}"
		gps_env_assign TRAFFIC_LAST_CHECK "${TRAFFIC_LAST_CHECK:-}"
		gps_env_assign TRAFFIC_LAST_ERROR "${TRAFFIC_LAST_ERROR:-}"
		gps_env_assign GPS_TEST_PREFIX "${GPS_TEST_PREFIX:-}"
		gps_env_assign GPS_NO_SYSTEMD "${GPS_NO_SYSTEMD:-0}"
		gps_env_assign INSTALLED_AT "${INSTALLED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
		gps_env_assign TUIC_NAME "${TUIC_NAME:-}"
		gps_env_assign SS_METHOD "${SS_METHOD:-}"
		gps_env_assign SS_PASSWORD "${SS_PASSWORD:-}"
		gps_env_assign REALITY_PRIVATE_KEY "${REALITY_PRIVATE_KEY:-}"
		gps_env_assign REALITY_PUBLIC_KEY "${REALITY_PUBLIC_KEY:-}"
		gps_env_assign REALITY_SHORT_ID "${REALITY_SHORT_ID:-}"
		gps_env_assign REALITY_SERVER "${REALITY_SERVER:-}"
		gps_env_assign VLESS_FLOW "${VLESS_FLOW:-}"
		gps_env_assign HY_UP_MBPS "${HY_UP_MBPS:-}"
		gps_env_assign HY_DOWN_MBPS "${HY_DOWN_MBPS:-}"
		gps_env_assign HY_OBFS "${HY_OBFS:-}"
		gps_env_assign NAIVE_USERNAME "${NAIVE_USERNAME:-}"
		gps_env_assign SNELL_VERSION "${SNELL_VERSION:-}"
		gps_env_assign SHADOWTLS_VERSION "${SHADOWTLS_VERSION:-}"
		gps_env_assign SHADOWTLS_HANDSHAKE "${SHADOWTLS_HANDSHAKE:-}"
		gps_env_assign SHADOWTLS_INNER_PORT "${SHADOWTLS_INNER_PORT:-}"
		gps_env_assign PROFILE "${PROFILE:-mesh-member}"
		gps_env_assign MESH_ROLE "${MESH_ROLE:-master}"
		gps_env_assign MESH_MASTER_URL "${MESH_MASTER_URL:-}"
		gps_env_assign MESH_MASTER_HOST "${MESH_MASTER_HOST:-}"
		gps_env_assign MESH_TLS_PIN "${MESH_TLS_PIN:-}"
		gps_env_assign MESH_CLUSTER_TOKEN "${MESH_CLUSTER_TOKEN:-}"
		gps_env_assign MESH_MASTER_PORT "${MESH_MASTER_PORT:-}"
		gps_env_assign MESH_SYNC_SEC "${MESH_SYNC_SEC:-}"
		gps_env_assign MESH_PEER_STALE_SEC "${MESH_PEER_STALE_SEC:-}"
		gps_env_assign MESH_WG_LIVE_ONLY "${MESH_WG_LIVE_ONLY:-}"
		gps_env_assign NODE_ID "${NODE_ID:-}"
		gps_env_assign WG_PRIVATE_KEY "${WG_PRIVATE_KEY:-}"
		gps_env_assign WG_PUBLIC_KEY "${WG_PUBLIC_KEY:-}"
		gps_env_assign WG_LISTEN_PORT "${WG_LISTEN_PORT:-}"
		gps_env_assign MESH_OVERLAY_IP "${MESH_OVERLAY_IP:-}"
		gps_env_assign MESH_OVERLAY_PREFIX "${MESH_OVERLAY_PREFIX:-}"
		gps_env_assign MESH_EXIT_NODE_ID "${MESH_EXIT_NODE_ID:-}"
		gps_env_assign MESH_ROLES "${MESH_ROLES:-}"
		gps_env_assign MESH_L7_OUTBOUNDS_JSON "${MESH_L7_OUTBOUNDS_JSON:-}"
		gps_env_assign MESH_FAILOVER "${MESH_FAILOVER:-0}"
		gps_env_assign MESH_FAILOVER_PROBE "${MESH_FAILOVER_PROBE:-}"
	} | gps_atomic_write_env "$GPS_STATE"
	gps_kiwi_save_persist
}

# 公共：持项目锁写状态（timer 与 CLI 的所有变更入口）
save_state() {
	gps_with_state_lock gps_save_state_unlocked
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
