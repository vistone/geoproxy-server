#!/bin/bash
# Mesh 公共：角色、路径、节点 ID

# 兼容旧 PROFILE：组网始终启用；edge 仅作遗留值，写配置时视为 mesh
gps_profile_normalize() {
	PROFILE=${PROFILE:-mesh-member}
	PROFILE=$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]')
	case $PROFILE in
	edge)
		PROFILE=mesh-member
		;;
	mesh-member | mesh_member)
		PROFILE=mesh-member
		;;
	*)
		err "无效 PROFILE: ${PROFILE}（已废弃；组网始终启用）"
		;;
	esac
}

gps_mesh_role_normalize() {
	MESH_ROLE=${MESH_ROLE:-master}
	MESH_ROLE=$(printf '%s' "$MESH_ROLE" | tr '[:upper:]' '[:lower:]')
	case $MESH_ROLE in
	master | member) ;;
	*)
		err "无效 MESH_ROLE: ${MESH_ROLE}（可用: master | member）"
		;;
	esac
}

gps_mesh_ensure_dirs() {
	mkdir -p "$GPS_MESH_DIR"
	chmod 700 "$GPS_MESH_DIR" 2>/dev/null || true
}

# ---------- Master 控制面 TLS：自签证书 + 公钥指纹钉扎 ----------

# 计算并落盘公钥指纹（curl --pinnedpubkey 格式：sha256//BASE64）
gps_mesh_write_tls_fp() {
	[[ -f ${GPS_MESH_TLS_CERT:-} ]] || return 1
	local pin
	pin=$(openssl x509 -in "$GPS_MESH_TLS_CERT" -pubkey -noout 2>/dev/null |
		openssl pkey -pubin -outform DER 2>/dev/null |
		openssl dgst -sha256 -binary 2>/dev/null |
		base64 | tr -d '\n') || return 1
	[[ -n $pin ]] || return 1
	umask 077
	printf 'sha256//%s\n' "$pin" >"$GPS_MESH_TLS_FP"
	chmod 600 "$GPS_MESH_TLS_FP" 2>/dev/null || true
}

# Master 侧确保证书存在（与 mesh_master.py 的 ensure_tls 等价；幂等）
# 默认必须 TLS：失败即退出，禁止默默退回明文。
gps_mesh_ensure_master_tls() {
	# 显式关闭时跳过（仅调试；公网加入仍会被 https 策略拒绝）
	[[ ${GPS_MESH_MASTER_TLS:-1} != 0 ]] || return 0
	gps_mesh_ensure_dirs
	[[ -f $GPS_MESH_TLS_FP && -f $GPS_MESH_TLS_CERT && -f $GPS_MESH_TLS_KEY ]] && return 0
	if ! have_cmd openssl; then
		err "缺 openssl：mesh 控制面默认必须启用 TLS（仅调试可设 GPS_MESH_MASTER_TLS=0）"
	fi
	umask 077
	if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$GPS_MESH_TLS_KEY" -out "$GPS_MESH_TLS_CERT" \
		-days 3650 -nodes -subj /CN=geoproxy-mesh >/dev/null 2>&1; then
		err "生成 mesh TLS 证书失败：拒绝以明文启动控制面（仅调试可设 GPS_MESH_MASTER_TLS=0）"
	fi
	chmod 600 "$GPS_MESH_TLS_CERT" "$GPS_MESH_TLS_KEY"
	gps_mesh_write_tls_fp || err "写入 mesh TLS 指纹失败"
}

# 磁盘上是否具备 master 证书（且未显式关闭 TLS）
gps_mesh_master_tls_on() {
	[[ ${GPS_MESH_MASTER_TLS:-1} != 0 ]] || return 1
	[[ -f ${GPS_MESH_TLS_CERT:-} && -f ${GPS_MESH_TLS_KEY:-} ]]
}

# 本机 Master 控制面 /v1/health 单次探测（tls=1 时用 curl -k）
_gps_mesh_curl_local_health() {
	local url=$1 tls=${2:-0}
	if [[ $tls == 1 ]]; then
		curl -ksS --connect-timeout 1 --max-time 2 "$url" >/dev/null 2>&1
	else
		curl -fsS --connect-timeout 1 --max-time 2 "$url" >/dev/null 2>&1
	fi
}

# 本机 Master 控制面 /v1/health 自检（doctor / mesh show / 升主后）。
# 有证书时优先 https（curl -k）；成功打印完整 URL + OK。
# mesh-master 刚 restart 时可能尚未 listen：默认重试 GPS_MESH_HEALTH_WAIT 秒（0=不重试）。
# 返回：0=健康，1=证书在但仅明文 HTTP，2=两端（或唯一应通端）无响应。
gps_mesh_print_local_health() {
	local port=${1:-${MESH_MASTER_PORT:-19527}}
	local https_url="https://127.0.0.1:${port}/v1/health"
	local http_url="http://127.0.0.1:${port}/v1/health"
	local wait=${GPS_MESH_HEALTH_WAIT:-8} end
	if ! have_cmd curl; then
		msg "  $(_red FAIL) 无 curl，无法探测 ${https_url}"
		return 2
	fi
	end=$((SECONDS + wait))
	while :; do
		if gps_mesh_master_tls_on; then
			if _gps_mesh_curl_local_health "$https_url" 1; then
				msg "  $(_green OK)  ${https_url}"
				return 0
			fi
			if _gps_mesh_curl_local_health "$http_url" 0; then
				msg "  $(_red FAIL) ${http_url} 仍为明文（证书已存在）。请: systemctl restart ${GPS_MESH_MASTER_SERVICE:-geoproxy-mesh-master}"
				return 1
			fi
		elif _gps_mesh_curl_local_health "$http_url" 0; then
			msg "  $(_green OK)  ${http_url}"
			return 0
		fi
		((SECONDS >= end)) && break
		sleep 0.2
	done
	if gps_mesh_master_tls_on; then
		msg "  $(_red FAIL) ${https_url} 无响应（HTTP 亦不通）"
	else
		msg "  $(_red FAIL) ${http_url} 无响应"
	fi
	return 2
}

# Member 侧探测远程 Master /v1/health（doctor；短超时与 boot 路径一致）
gps_mesh_print_member_health() {
	local url=${MESH_MASTER_URL:-}
	[[ -n $url ]] || return 2
	local health_url="${url%/}/v1/health"
	if ! have_cmd curl; then
		msg "  $(_red FAIL) 无 curl，无法探测 ${health_url}"
		return 2
	fi
	local rc=0
	GPS_MESH_CURL_MAX_TIME=3 GPS_MESH_CURL_CONNECT_TIMEOUT=${GPS_MESH_CURL_CONNECT_TIMEOUT:-2} \
		gps_mesh_curl "$health_url" -o /dev/null >/dev/null 2>&1 || rc=$?
	if [[ $rc -eq 0 ]]; then
		msg "  $(_green OK)  ${health_url}"
		return 0
	fi
	msg "  $(_red FAIL) ${health_url} 无响应（请到 Master 确认 TCP ${MESH_MASTER_PORT:-19527} 已对外放行：本机防火墙 + 云安全组）"
	return 2
}

# 探测本机控制面实际 scheme：证书在但进程仍明文时返回 http，避免 join 命令误导
# 仅供 mesh show / print_join_hints；ensure 路径勿调用（避免到处 curl）。
gps_mesh_live_control_scheme() {
	local port=${1:-${MESH_MASTER_PORT:-19527}}
	if [[ -n ${GPS_MESH_LIVE_SCHEME:-} ]]; then
		printf '%s\n' "$GPS_MESH_LIVE_SCHEME"
		return 0
	fi
	if ! have_cmd curl; then
		gps_mesh_master_tls_on && {
			printf 'https\n'
			return 0
		}
		printf 'http\n'
		return 0
	fi
	# connect-timeout 防止对端半开拖死
	if curl -ksS --connect-timeout 1 --max-time 2 "https://127.0.0.1:${port}/v1/health" >/dev/null 2>&1; then
		printf 'https\n'
		return 0
	fi
	if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:${port}/v1/health" >/dev/null 2>&1; then
		printf 'http\n'
		return 0
	fi
	# 本机未起进程（测试前缀 / 尚未 enable）：回退到磁盘证书判断
	gps_mesh_master_tls_on && {
		printf 'https\n'
		return 0
	}
	printf 'http\n'
}

# ---------- Master URL 策略：公网必须 https；明文仅限 loopback ----------

gps_mesh_url_is_loopback() {
	local low=${1,,}
	[[ $low == 127.* || $low == localhost || $low == localhost.* || $low == ::1 || $low == \[::1\] ]]
}

# 提取 URL 的 host（去掉端口/路径；[v6] 去括号）
gps_mesh_url_host() {
	local rest=${1#*://}
	if [[ $rest == \[*\]* ]]; then
		local host=${rest#\[*}
		printf '%s' "${host%%\]*}"
		return 0
	fi
	printf '%s' "${rest%%[:/]*}"
}

gps_mesh_require_https_or_loopback() {
	local url=${1:-}
	case $url in
	http://*)
		local host
		host=$(gps_mesh_url_host "$url")
		if ! gps_mesh_url_is_loopback "$host"; then
			err "拒绝明文 http 连接非本机 Master: $url
集群 TOKEN 与节点公钥会明文过公网（可被窃取/篡改）。
请在 Master 上执行 mesh show，用打印的 https://... 与 GPS_MESH_TLS_PIN=... 整行重新加入。"
		fi
		;;
	https://*) ;;
	*)
		err "Master URL 必须以 http:// 或 https:// 开头: $url"
		;;
	esac
}

# 统一请求入口：TLS 策略 + 指纹钉扎 + TOKEN 不进 argv（curl -H @file）
# 注意：明文拒绝在此为非致命（warn+失败）——register 可能运行在 ExecStartPre，
# 不能因遗留 http 配置阻断代理服务本身；交互路径用 gps_mesh_require_https_or_loopback 硬拒绝。
gps_mesh_curl() {
	local url=$1
	shift
	case $url in
	http://*)
		local host
		host=$(gps_mesh_url_host "$url")
		if ! gps_mesh_url_is_loopback "$host"; then
			warn "拒绝明文 http 连接非本机 Master: $url
集群 TOKEN 与节点公钥会明文过公网。请在 Master 上执行 mesh show，
用打印的 https://... 与 GPS_MESH_TLS_PIN=... 整行重新加入。"
			return 1
		fi
		;;
	https://*) ;;
	*)
		warn "Master URL 必须以 http:// 或 https:// 开头: $url"
		return 1
		;;
	esac
	if [[ $url == https://* && -z ${MESH_TLS_PIN:-} ]]; then
		warn "https Master 未配置指纹（MESH_TLS_PIN），走系统 CA 校验"
	fi
	local max_t=${GPS_MESH_CURL_MAX_TIME:-15}
	local conn_t=${GPS_MESH_CURL_CONNECT_TIMEOUT:-$max_t}
	local -a args=(-fsSL --connect-timeout "$conn_t" --max-time "$max_t")
	if [[ $url == https://* && -n ${MESH_TLS_PIN:-} ]]; then
		args+=(-k --pinnedpubkey "${MESH_TLS_PIN}")
	fi
	local hf=""
	if [[ -n ${MESH_CLUSTER_TOKEN:-} ]]; then
		hf=$(mktemp)
		printf 'Authorization: Bearer %s\n' "$MESH_CLUSTER_TOKEN" >"$hf"
		args+=(-H @"$hf")
	fi
	local rc=0
	curl "${args[@]}" "$@" "$url" || rc=$?
	[[ -n $hf ]] && rm -f "$hf"
	return "$rc"
}

gps_mesh_ensure_node_id() {
	if [[ -z ${NODE_ID:-} ]]; then
		NODE_ID=$(gps_tuic_node_name | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//;s/-$//')
		[[ -n $NODE_ID ]] || NODE_ID="node-$(hostname 2>/dev/null | tr -cs 'a-zA-Z0-9' '-' | head -c 24)"
		[[ -n $NODE_ID ]] || NODE_ID="node1"
	fi
	gps_validate_single_line "$NODE_ID" || err "NODE_ID 非法"
}

# 默认 overlay 前缀与本机 /32
gps_mesh_defaults() {
	MESH_OVERLAY_PREFIX=${MESH_OVERLAY_PREFIX:-10.66.0.0/16}
	WG_LISTEN_PORT=${WG_LISTEN_PORT:-51820}
	MESH_MASTER_PORT=${MESH_MASTER_PORT:-${GPS_MESH_MASTER_PORT:-19527}}
	MESH_SYNC_SEC=${MESH_SYNC_SEC:-60}
	MESH_PEER_STALE_SEC=${MESH_PEER_STALE_SEC:-180}
	MESH_WG_LIVE_ONLY=${MESH_WG_LIVE_ONLY:-1}
	MESH_WG_MTU=${MESH_WG_MTU:-1408}
	gps_validate_port "$WG_LISTEN_PORT" || err "无效 WG_LISTEN_PORT: $WG_LISTEN_PORT"
	gps_validate_port "$MESH_MASTER_PORT" || err "无效 MESH_MASTER_PORT: $MESH_MASTER_PORT"
	# WG MTU 1280（IPv6 最小）到 1500（以太网上限）；路径受限时可调小缓解大包黑洞
	[[ $MESH_WG_MTU =~ ^[0-9]+$ ]] || err "无效 MESH_WG_MTU: $MESH_WG_MTU"
	((10#$MESH_WG_MTU >= 1280 && 10#$MESH_WG_MTU <= 1500)) || err "MESH_WG_MTU 需在 1280-1500: $MESH_WG_MTU"
}

# 只读 state.env 中的熔断标记（1/0）。绝不 source 整个 state.env：
# load_state 会把 save_state 之后才生成/更新的变量（NODE_ID / WG 公钥 / overlay 等）
# 用空值覆盖，导致 mesh 注册/配置渲染失败。
gps_traffic_tripped_from_state() {
	local v=0
	if [[ -f ${GPS_STATE:-} ]]; then
		v=$(sed -n 's/^TRAFFIC_TRIPPED=//p' "$GPS_STATE" 2>/dev/null | tail -1)
	fi
	[[ $v == 1 ]] && echo 1 || echo 0
}

gps_mesh_ensure_cluster_token() {
	if [[ -z ${MESH_CLUSTER_TOKEN:-} ]]; then
		if [[ -f ${GPS_MESH_TOKEN_FILE:-} ]]; then
			MESH_CLUSTER_TOKEN=$(tr -d '[:space:]' <"$GPS_MESH_TOKEN_FILE")
		fi
	fi
	if [[ -z ${MESH_CLUSTER_TOKEN:-} ]]; then
		if have_cmd openssl; then
			MESH_CLUSTER_TOKEN=$(openssl rand -hex 24)
		else
			MESH_CLUSTER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
		fi
	fi
	gps_mesh_ensure_dirs
	umask 077
	printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
	chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
}

# 主机名是否适合作为 Master 域名（含点、非纯 IP）
gps_mesh_looks_like_hostname() {
	local h=${1:-}
	[[ -n $h ]] || return 1
	[[ $h == *.* ]] || return 1
	gps_validate_ipv4 "$h" 2>/dev/null && return 1
	# 粗判：含冒号则当 IPv6
	[[ $h == *:* ]] && return 1
	return 0
}

# 解析 MESH_MASTER_HOST：显式值优先；否则沿用像域名的 TUIC_NAME / NODE_ID
gps_mesh_resolve_master_host() {
	if [[ -n ${MESH_MASTER_HOST:-} ]]; then
		return 0
	fi
	if [[ -n ${TUIC_NAME:-} ]] && gps_mesh_looks_like_hostname "$TUIC_NAME"; then
		MESH_MASTER_HOST=$TUIC_NAME
		return 0
	fi
	if [[ -n ${NODE_ID:-} ]] && gps_mesh_looks_like_hostname "$NODE_ID"; then
		MESH_MASTER_HOST=$NODE_ID
	fi
}

# 输出 Master 对外 join 基址（每行一个，双栈+域名）
# 默认按磁盘证书；打印加入命令时用 GPS_MESH_LIVE_SCHEME 覆盖（避免 ensure 路径到处 curl）
gps_mesh_join_urls() {
	gps_mesh_defaults
	gps_mesh_resolve_master_host
	local port=${MESH_MASTER_PORT:-19527}
	local scheme=http
	if [[ -n ${GPS_MESH_LIVE_SCHEME:-} ]]; then
		scheme=$GPS_MESH_LIVE_SCHEME
	elif gps_mesh_master_tls_on; then
		scheme=https
	fi
	local -a urls=()
	if [[ -n ${MESH_MASTER_HOST:-} ]]; then
		urls+=("${scheme}://${MESH_MASTER_HOST}:${port}")
	fi
	if [[ -n ${PUBLIC_IP:-} ]]; then
		urls+=("${scheme}://${PUBLIC_IP}:${port}")
	fi
	if [[ -n ${PUBLIC_IP6:-} ]]; then
		urls+=("${scheme}://[${PUBLIC_IP6}]:${port}")
	fi
	if ((${#urls[@]} == 0)); then
		urls+=("${scheme}://127.0.0.1:${port}")
	fi
	# 去重保序
	local u seen=""
	for u in "${urls[@]}"; do
		[[ " $seen " == *" $u "* ]] && continue
		printf '%s\n' "$u"
		seen+=" $u"
	done
}

gps_mesh_primary_join_url() {
	# 读完全部行再取首元素：read+break 会提前关闭管道，
	# 写端 printf 在 set -o pipefail 下触发 SIGPIPE(141)（CI 必现）。
	local -a urls=()
	local u
	while IFS= read -r u; do
		urls+=("$u")
	done < <(gps_mesh_join_urls)
	printf '%s\n' "${urls[0]:-}"
}

# Master：放行控制面 TCP（幂等；默认安静，避免 sync timer 刷屏）
gps_mesh_expose_control_plane() {
	[[ ${MESH_ROLE:-} == master ]] || return 0
	gps_mesh_defaults 2>/dev/null || true
	local port=${MESH_MASTER_PORT:-19527}
	if gps_fw_allow_tcp "$port" "geoproxy-mesh-control"; then
		return 0
	fi
	warn "未能放行 TCP ${port}（mesh 控制面）。请手工放行本机防火墙，并在云安全组放行同一端口。"
	return 0
}

# Master / Member：放行 WG 数据面 UDP（幂等）
gps_mesh_expose_wg_data_plane() {
	gps_mesh_defaults 2>/dev/null || true
	local port=${WG_LISTEN_PORT:-51820}
	if gps_fw_allow_udp "$port" "geoproxy-mesh-wg"; then
		return 0
	fi
	warn "未能放行 UDP ${port}（WG 数据面）。请手工放行本机防火墙，并在云安全组放行同一端口。"
	return 0
}

# Master：监听地址 / 本机防火墙 / 云安全组（member 不打印招人端口）
gps_mesh_print_control_plane_status() {
	[[ ${MESH_ROLE:-} == master ]] || return 0
	gps_mesh_defaults 2>/dev/null || true
	local port=${MESH_MASTER_PORT:-19527}
	local bind=${GPS_MESH_MASTER_BIND:-0.0.0.0}
	local backend
	backend=$(gps_fw_backend)
	msg "  控制面监听: ${bind}:${port}/tcp（mesh 控制面，供其它机器加入；不是代理端口，也不是 WG 51820）"
	if [[ $bind == 127.0.0.1 || $bind == ::1 ]]; then
		msg "  $(_yellow "注意") 控制面只绑本机 ${bind}，其它机器无法加入"
	fi
	if gps_fw_tcp_allowed "$port"; then
		if [[ $backend == none ]]; then
			msg "  本机防火墙: 已放行 TCP ${port}（未检测到 ufw/firewalld/iptables/nft 活动规则；本机无防火墙可拦）"
		else
			msg "  本机防火墙: 已放行 TCP ${port}（${backend}）"
		fi
	else
		msg "  本机防火墙: 未放行 TCP ${port}（${backend}）— 其它机器加入会 Connection timed out"
	fi
	msg "  云安全组: 脚本无法修改；请在云控制台同样放行 TCP ${port}，否则 Node 会 Connection timed out"
}

# Master / Member：WG 数据面 UDP 监听与防火墙（与控制面 TCP 19527 并列说明）
gps_mesh_print_wg_data_plane_status() {
	gps_mesh_defaults 2>/dev/null || true
	local port=${WG_LISTEN_PORT:-51820}
	local backend
	backend=$(gps_fw_backend)
	msg "  WG 数据面: 0.0.0.0:${port}/udp（WireGuard 隧道，供 mesh 节点互通；不是代理端口，也不是控制面 TCP ${MESH_MASTER_PORT:-19527}）"
	if gps_fw_udp_allowed "$port"; then
		if [[ $backend == none ]]; then
			msg "  本机防火墙: 已放行 UDP ${port}（未检测到 ufw/firewalld/iptables/nft 活动规则；本机无防火墙可拦）"
		else
			msg "  本机防火墙: 已放行 UDP ${port}（${backend}）"
		fi
	else
		msg "  本机防火墙: 未放行 UDP ${port}（${backend}）— WG 握手可能失败"
	fi
	msg "  云安全组: 脚本无法修改；请在云控制台同样放行 UDP ${port}，否则 mesh 节点无法建立 WG 隧道"
}

# 解析 peers endpoint：host port（支持 [v6]:port）
gps_mesh_parse_endpoint() {
	local ep=$1
	python3 - "$ep" <<'PY'
import sys
ep = (sys.argv[1] or "").strip()
if not ep:
    raise SystemExit(1)
if ep.startswith("["):
    i = ep.rfind("]:")
    if i < 0:
        raise SystemExit(1)
    host, port = ep[1:i], ep[i + 2 :]
else:
    host, _, port = ep.rpartition(":")
if not host or not port.isdigit():
    raise SystemExit(1)
print(host)
print(port)
PY
}

# 公网 UDP 探测（WG 数据面；非 overlay ping）
gps_mesh_probe_udp_endpoint() {
	local ep=$1
	local host port
	[[ -n $ep ]] || return 1
	host=$(gps_mesh_parse_endpoint "$ep" 2>/dev/null | sed -n '1p') || return 1
	port=$(gps_mesh_parse_endpoint "$ep" 2>/dev/null | sed -n '2p') || return 1
	local tout=2
	[[ -n ${GPS_TEST_PREFIX:-} ]] && tout=0
	python3 - "$host" "$port" "$tout" <<'PY'
import socket, sys
host, port, tout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
for af in (socket.AF_INET, socket.AF_INET6):
    try:
        s = socket.socket(af, socket.SOCK_DGRAM)
        s.settimeout(tout)
        s.sendto(b"\x00", (host, port))
        s.close()
        raise SystemExit(0)
    except OSError:
        continue
raise SystemExit(1)
PY
}

# sing-box 是否在本地 UDP listen（userspace WG 为 UNCONN 态，需 -l）
gps_mesh_wg_listen_ok() {
	local wg_port=${WG_LISTEN_PORT:-51820}
	ss -ulnp "sport = :${wg_port}" 2>/dev/null | grep -q sing-box
}

# sing-box WG listen 口 UDP 累计字节（本机 51820 是否有动静）
gps_mesh_wg_socket_bytes() {
	local wg_port=${WG_LISTEN_PORT:-51820}
	local ssline
	ssline=$(ss -H -u -l -i "sport = :${wg_port}" 2>/dev/null | head -1)
	[[ -n $ssline ]] || ssline=$(ss -H -u -i "dport = :${wg_port}" 2>/dev/null | head -1)
	[[ -n $ssline ]] || return 1
	python3 - "$ssline" <<'PY'
import re, sys
line = sys.argv[1]
sent = recv = 0
m = re.search(r"bytes_sent:(\d+)", line)
if m:
    sent = int(m.group(1))
m = re.search(r"bytes_received:(\d+)", line)
if m:
    recv = int(m.group(1))
if sent == 0 and recv == 0:
    m = re.search(r"\bb(\d+)\b", line)
    if m:
        recv = int(m.group(1))
print(f"{sent} {recv}")
PY
}

# 近期 sing-box 日志中 wireguard 相关行数（流量/握手动静）
gps_mesh_wg_log_recent_count() {
	local n=${1:-80}
	local logf=${GPS_LOG:-}
	local cnt=0
	if [[ -f $logf ]]; then
		cnt=$(tail -n "$n" "$logf" 2>/dev/null | grep -ciE 'wireguard|wg-ep' || true)
		[[ ${cnt:-0} -gt 0 ]] && printf '%s' "$cnt" && return 0
	fi
	if have_cmd journalctl; then
		cnt=$(journalctl -u "${GPS_SERVICE:-geoproxy-tuic}" -n "$((n * 2))" --no-pager 2>/dev/null | grep -ciE 'wireguard|wg-ep' || true)
	fi
	printf '%s' "${cnt:-0}"
}

# 从 journal/日志解析 WG 握手：输出 HS_SUMMARY ok=N fail=N / HS_FAIL=node|overlay|ep / HS_OK=...
gps_mesh_wg_handshake_stats() {
	local peers_path=${GPS_MESH_PEERS:-}
	local config_path=${GPS_CONFIG:-}
	local svc=${GPS_SERVICE:-geoproxy-tuic}
	local logf=${GPS_LOG:-}
	[[ -f $peers_path && -f $config_path && -n ${NODE_ID:-} ]] || return 1
	have_cmd python3 || return 1
	NODE_ID="${NODE_ID:-}" GPS_LOG="${logf:-}" python3 - "$peers_path" "$config_path" "$svc" <<'PY'
import json, os, re, subprocess, sys

peers_path, config_path, svc = sys.argv[1], sys.argv[2], sys.argv[3]
self_id = os.environ.get("NODE_ID") or ""
logf = os.environ.get("GPS_LOG") or ""

def read_log(n=400):
    lines = []
    if os.path.isfile(logf):
        try:
            with open(logf, encoding="utf-8", errors="replace") as f:
                lines = f.readlines()[-n:]
        except OSError:
            pass
    if not lines:
        try:
            out = subprocess.check_output(
                ["journalctl", "-u", svc, "-n", str(n * 2), "--no-pager"],
                text=True,
                errors="replace",
            )
            lines = out.splitlines()
        except (OSError, subprocess.CalledProcessError):
            return []
    return lines

lines = read_log()
fail_p, ok_p = set(), set()
for line in lines:
    m = re.search(r"peer\(([A-Za-z0-9+/=]{4})", line)
    if not m:
        continue
    pref = m.group(1)
    low = line.lower()
    if "did not complete" in low or "stopped hearing" in low:
        fail_p.add(pref)
    if any(
        x in low
        for x in (
            "received handshake response",
            "receiving keepalive",
            "received handshake initiation",
            "sending handshake response",
        )
    ):
        ok_p.add(pref)

with open(peers_path, encoding="utf-8") as f:
    by_pk = {n.get("public_key", ""): n for n in json.load(f).get("nodes") or []}
with open(config_path, encoding="utf-8") as f:
    cfg = json.load(f)
wg = next((e for e in cfg.get("endpoints") or [] if e.get("type") == "wireguard"), None)
if not wg:
    sys.exit(0)
ok_n, fail_n = [], []
for p in wg.get("peers") or []:
    pk = p.get("public_key") or ""
    if not pk:
        continue
    pref = pk[:4]
    n = by_pk.get(pk, {})
    nid = n.get("node_id") or "?"
    overlay = (n.get("overlay_ip") or "").split("/")[0] or "?"
    ep = n.get("endpoint") or ""
    if not ep and p.get("address"):
        ep = f"{p.get('address')}:{p.get('port') or 51820}"
    row = f"{nid}|{overlay}|{ep}"
    if pref in ok_p:
        ok_n.append(row)
    elif pref in fail_p and pref not in ok_p:
        fail_n.append(row)
print(f"HS_SUMMARY ok={len(ok_n)} fail={len(fail_n)}")
for row in fail_n:
    print(f"HS_FAIL={row}")
for row in ok_n[:5]:
    print(f"HS_OK={row}")
PY
}

# 本机 WG 数据面：自动放行防火墙；未 listen 则重启 sing-box（doctor / mesh remediate）
gps_mesh_remediate_local_wg() {
	gps_mesh_defaults 2>/dev/null || true
	local wg_port=${WG_LISTEN_PORT:-51820}
	gps_mesh_expose_wg_data_plane 2>/dev/null || true
	if [[ ${MESH_ROLE:-} == master ]]; then
		gps_mesh_expose_control_plane 2>/dev/null || true
	fi
	if gps_mesh_wg_listen_ok; then
		msg "  WG 修复: $(_green OK) sing-box 已在 UDP ${wg_port} 监听"
		return 0
	fi
	warn "WG 修复: sing-box 未在 UDP ${wg_port} 监听，尝试重启 ${GPS_SERVICE:-geoproxy-tuic}…"
	if declare -F gps_restart_svc >/dev/null 2>&1; then
		gps_restart_svc 2>/dev/null || true
		sleep 2
	fi
	if gps_mesh_wg_listen_ok; then
		msg "  WG 修复: $(_green OK) 重启后已在 UDP ${wg_port} 监听"
		return 0
	fi
	warn "WG 修复: 仍无 UDP ${wg_port} 监听 — 请检查 geoproxy-tuic 日志与 config.json endpoints"
	return 1
}

# mesh show / doctor：登记心跳 vs WG 配置 vs 公网 UDP 数据面（非 overlay ping）
gps_mesh_print_connectivity_summary() {
	gps_mesh_role_normalize 2>/dev/null || true
	gps_mesh_defaults 2>/dev/null || true
	gps_mesh_ensure_node_id 2>/dev/null || true
	local wg_port=${WG_LISTEN_PORT:-51820}
	msg "  $(_cyan "组网连通性摘要"):"
	msg "    说明: 「在线」= Master 心跳；$(_cyan "10.66.0.x") = 隧道内 overlay（非公网）。节点互联走 公网 UDP ${wg_port}；代理流量不经 WG（出口恒 direct）。"
	local my_overlay=${MESH_OVERLAY_IP:-?}
	msg "    本机 overlay: $(_cyan "${my_overlay}")（经 wg-ep 与其它 peer 的 overlay /32 互联；仅节点管理面，不承载代理流量）"
	if [[ ! -f ${GPS_MESH_PEERS:-} ]] || ! have_cmd python3; then
		msg "    （无 peers 文件或 python3，跳过统计）"
		return 0
	fi
	local stats total=0 alive=0 wg_peers="?"
	local -a peer_lines=()
	stats=$(
		NODE_ID="${NODE_ID:-}" MESH_PEER_STALE_SEC="${MESH_PEER_STALE_SEC:-180}" \
			GPS_CONFIG="${GPS_CONFIG:-}" python3 - "$GPS_MESH_PEERS" <<'PY'
import json, os, sys
from datetime import datetime, timezone

path = sys.argv[1]
config_path = os.environ.get("GPS_CONFIG") or ""
self_id = os.environ.get("NODE_ID") or ""
stale = int(os.environ.get("MESH_PEER_STALE_SEC") or 180)
now = datetime.now(timezone.utc)

def alive(n):
    ls = n.get("last_seen") or ""
    if not ls:
        return True
    try:
        ts = datetime.strptime(ls, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return False
    return (now - ts).total_seconds() <= stale

with open(path, encoding="utf-8") as f:
    doc = json.load(f)
nodes = doc.get("nodes") or []
total = len(nodes)
alive_n = 0
candidates = []
for n in nodes:
    nid = n.get("node_id") or ""
    if nid == self_id:
        alive_n += 1
        continue
    if alive(n):
        alive_n += 1
        overlay = (n.get("overlay_ip") or "").split("/")[0]
        endpoint = (n.get("endpoint") or "").strip()
        if overlay:
            priority = 0 if overlay == "10.66.0.1" else 1
            candidates.append((priority, overlay, endpoint, nid))
candidates.sort()
wg_peers = "?"
if config_path:
    try:
        with open(config_path, encoding="utf-8") as f:
            cfg = json.load(f)
        for ep in cfg.get("endpoints") or []:
            if ep.get("type") == "wireguard":
                wg_peers = str(len(ep.get("peers") or []))
                break
    except Exception:
        wg_peers = "?"
print(f"TOTAL={total}")
print(f"ALIVE={alive_n}")
print(f"WG_PEERS={wg_peers}")
for _, overlay, endpoint, nid in candidates:
    print(f"PEER={overlay}|{endpoint}|{nid}")
PY
	) || {
		msg "    （无法解析 peers）"
		return 0
	}
	while IFS= read -r line; do
		case $line in
		TOTAL=*) total=${line#TOTAL=} ;;
		ALIVE=*) alive=${line#ALIVE=} ;;
		WG_PEERS=*) wg_peers=${line#WG_PEERS=} ;;
		PEER=*)
			peer_lines+=("${line#PEER=}")
			;;
		esac
	done <<<"$stats"
	msg "    登记节点: ${total}  心跳在线: ${alive}"
	if [[ $wg_peers == "?" ]]; then
		msg "    WG 配置 peer 数: （无法读取 config.json）"
	else
		msg "    WG 配置 peer 数: ${wg_peers}（sing-box config.json；通常仅含心跳在线节点）"
	fi
	local ep_sent=0 ep_fail=0 ep_skip=0
	local wg_sent=0 wg_recv=0 wg_log=0
	local hs_ok=0 hs_fail=0
	local -a hs_fail_lines=()
	local b1
	if gps_mesh_wg_listen_ok; then
		msg "    WG 监听 UDP ${wg_port}: $(_green OK)（sing-box 已在 0.0.0.0:${wg_port} / [::]:${wg_port} 监听）"
	else
		msg "    WG 监听 UDP ${wg_port}: $(_red FAIL)（sing-box 未监听；运行 geoproxy-server mesh remediate 或菜单 23 doctor）"
	fi
	if b1=$(gps_mesh_wg_socket_bytes 2>/dev/null); then
		read -r wg_sent wg_recv <<<"$b1"
	fi
	wg_log=$(gps_mesh_wg_log_recent_count 100 2>/dev/null || echo 0)
	if [[ ${wg_sent:-0} -gt 0 || ${wg_recv:-0} -gt 0 ]]; then
		msg "    WG 流量统计: $(_green "有流量")  bytes_sent=${wg_sent} bytes_received=${wg_recv}"
	elif [[ ${wg_log:-0} -gt 0 ]]; then
		msg "    WG 流量统计: $(_yellow "待观察")  近期 ${wg_log} 条 wireguard 日志"
	else
		msg "    WG 流量统计: $(_yellow "暂无")  （UNCONN 监听口无 bytes；以握手日志为准）"
	fi
	local hs_out hs_line
	if hs_out=$(gps_mesh_wg_handshake_stats 2>/dev/null); then
		while IFS= read -r hs_line; do
			case $hs_line in
			HS_SUMMARY*)
				hs_ok=${hs_line#*ok=}
				hs_ok=${hs_ok%% fail=*}
				hs_fail=${hs_line#*fail=}
				;;
			HS_FAIL=*)
				hs_fail_lines+=("${hs_line#HS_FAIL=}")
				;;
			esac
		done <<<"$hs_out"
		if [[ ${hs_ok:-0} -gt 0 || ${hs_fail:-0} -gt 0 ]]; then
			msg "    WG 握手（journal 解析）: $(_green "${hs_ok}") 已通  $(_red "${hs_fail}") 失败"
			local hf nid ov ep
			for hf in "${hs_fail_lines[@]}"; do
				nid=${hf%%|*}
				local rest=${hf#*|}
				ov=${rest%%|*}
				ep=${rest##*|}
				msg "      $(_red FAIL) $(_cyan "${ov}") ← ${nid}  endpoint=${ep}"
				msg "        修复: 在该节点运行 geoproxy-server mesh remediate；云控制台放行 UDP ${wg_port} 入站"
			done
		fi
	fi
	if ((${#peer_lines[@]} == 0)); then
		msg "    数据面探测: $(_yellow SKIP)（无其它在线节点可测）"
		ep_skip=1
	else
		msg "    数据面探测（公网 endpoint → overlay $(_cyan "10.66.x")）:"
		local pl overlay endpoint nid
		for pl in "${peer_lines[@]}"; do
			overlay=${pl%%|*}
			local rest=${pl#*|}
			endpoint=${rest%%|*}
			nid=${rest##*|}
			msg "      $(_cyan "${overlay}") ← ${nid}"
			if [[ -z $endpoint ]]; then
				msg "        公网 endpoint: $(_yellow SKIP)（未登记 endpoint）"
				ep_skip=$((ep_skip + 1))
			elif gps_mesh_probe_udp_endpoint "$endpoint"; then
				msg "        公网 UDP ${endpoint}: $(_yellow "已发包")（盲发无回执，不能证明可达；以 WG 握手统计为准）"
				ep_sent=$((ep_sent + 1))
			else
				msg "        公网 UDP ${endpoint}: $(_red FAIL)（发包即失败：endpoint 域名解析或本机出网异常）"
				ep_fail=$((ep_fail + 1))
			fi
		done
	fi
	if [[ $wg_peers == "0" && $alive -le 1 ]]; then
		msg "    判定: $(_yellow "仅本机或未配置 WG peer")（组网尚未建立）"
	elif [[ ${hs_fail:-0} -gt 0 && ${hs_ok:-0} -gt 0 ]]; then
		msg "    判定: $(_yellow "部分 peer WG 握手失败")（${hs_ok} 通 / ${hs_fail} 失败；见上方失败列表）"
	elif [[ ${hs_fail:-0} -gt 0 && ${hs_ok:-0} -eq 0 ]]; then
		msg "    判定: $(_red "WG 握手全部失败")（查对端 UDP ${wg_port} 与 geoproxy-tuic 是否运行）"
	elif [[ ${hs_ok:-0} -gt 0 && ${hs_fail:-0} -eq 0 ]]; then
		msg "    判定: $(_green "数据面可能流通")（${hs_ok} 个 peer WG 握手已通；仅 overlay /32 互联，代理不经 WG）"
	elif [[ $ep_sent -gt 0 && (${wg_sent:-0} -gt 0 || ${wg_recv:-0} -gt 0 || ${wg_log:-0} -gt 5) ]]; then
		msg "    判定: $(_yellow "WG 握手待确认")（已向对端发出 UDP 探测包 + WG 端口有流量/日志动静，但无握手成功记录）"
	elif [[ $ep_sent -gt 0 ]]; then
		msg "    判定: $(_yellow "WG 握手待确认")（UDP 探测包已发出但无回执；看上方握手统计）"
	elif [[ $ep_fail -gt 0 ]]; then
		msg "    判定: $(_red "公网 UDP 不可达")（发包失败：endpoint 域名/本机出网异常；云 SG 拦截 UDP 的表现是发包成功但握手失败）"
		msg "    提示: overlay $(_cyan "10.66.x") 互联依赖公网 UDP ${wg_port} 加密传输"
	elif [[ $ep_skip -ge 1 && $wg_peers != "0" && $wg_peers != "?" ]]; then
		msg "    判定: $(_yellow "WG 已配置 ${wg_peers} 个 peer")（未探测 endpoint；请菜单 30 查端口清单）"
	fi
}

# Agent 是否已配置（agent.env 含 token）
gps_mesh_agent_enabled() {
	local envf=${GPS_AGENT_ENV:-${GPS_ETC}/agent.env}
	[[ -f $envf ]] || return 1
	local tok
	tok=$(grep -E '^GPS_AGENT_TOKEN=' "$envf" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
	[[ -n $tok ]]
}

# Agent 监听与防火墙（port checklist / doctor 复用）
gps_mesh_print_agent_port_status() {
	gps_mesh_agent_enabled || return 0
	local envf=${GPS_AGENT_ENV:-${GPS_ETC}/agent.env}
	gps_source_env "$envf" 2>/dev/null || true
	local bind=${GPS_AGENT_BIND:-0.0.0.0} port=${GPS_AGENT_PORT:-19528} backend
	backend=$(gps_fw_backend)
	msg "  Agent: ${bind}:${port}/tcp（明文 HTTP，v2rayA 节点池；非 mesh 控制面 ${MESH_MASTER_PORT:-19527}）"
	if [[ $bind == 127.0.0.1 || $bind == ::1 ]]; then
		msg "  本机防火墙: 仅本机 ${bind}，通常无需云 SG 放行"
		return 0
	fi
	if [[ $bind == 0.0.0.0 || $bind == "*" ]]; then
		if gps_fw_tcp_allowed "$port"; then
			if [[ $backend == none ]]; then
				msg "  本机防火墙: 已放行 TCP ${port}（未检测到活动防火墙）"
			else
				msg "  本机防火墙: 已放行 TCP ${port}（${backend}）"
			fi
		else
			msg "  本机防火墙: 未放行 TCP ${port}（${backend}）— v2rayA 远程可能连不上"
		fi
		msg "  云安全组: 请放行 TCP ${port}（明文 HTTP；请确保 TOKEN 强度、仅放行可信源）"
	fi
}

# 结构化端口清单（运维 checklist；Master / Member 按角色区分）
gps_mesh_print_port_checklist() {
	load_state 2>/dev/null || true
	gps_mesh_role_normalize 2>/dev/null || true
	gps_mesh_defaults 2>/dev/null || true
	local role=${MESH_ROLE:-?} proxy=${PORT:-?} mport=${MESH_MASTER_PORT:-19527} wg=${WG_LISTEN_PORT:-51820}
	msg "$(_cyan "=== Mesh 防火墙端口清单（可复制 checklist）===")"
	msg "角色: ${role}  协议: ${PROTOCOL:-tuic}  生成: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	msg "--------------------------------------------"
	msg "[ ] UDP ${proxy}/udp — 代理入站（GeoProxy 客户端连此端口，非 mesh）"
	if [[ -n ${PORT:-} ]]; then
		local backend
		backend=$(gps_fw_backend)
		if gps_fw_udp_allowed "$PORT"; then
			msg "    本机: 已放行（${backend}）"
		else
			msg "    本机: 未放行（${backend}）"
		fi
		msg "    云 SG: 放行 UDP ${proxy}"
	fi
	msg "[ ] UDP ${wg}/udp — WireGuard mesh 数据面（节点间隧道）"
	gps_mesh_print_wg_data_plane_status 2>/dev/null || true
	if [[ $role == master ]]; then
		msg "[ ] TCP ${mport}/tcp — mesh 控制面（供 Member 注册/拉 peers；非代理 ${proxy}）"
		gps_mesh_print_control_plane_status 2>/dev/null || true
	else
		msg "[ ] 出站到 Master TCP ${mport} — Member 无需在本机监听控制面"
		msg "    Master URL: ${MESH_MASTER_URL:-（未设置）}"
		msg "    若连不上：到 Master 确认 TCP ${mport} 已放行（本机防火墙 + 云 SG）"
	fi
	if gps_mesh_agent_enabled; then
		msg "[ ] TCP ${GPS_AGENT_PORT:-19528}/tcp — Agent（若启用）"
		gps_mesh_print_agent_port_status 2>/dev/null || true
	fi
	msg "--------------------------------------------"
	msg "云安全组需在各云控制台手工放行；本脚本仅管理本机 ufw/firewalld/iptables/nft。"
}

# Member：检测 TLS/连通性问题（stdout 每行一个 issue 标签；返回 issue 数）
gps_mesh_migrate_tls_detect() {
	local n=0
	[[ ${MESH_ROLE:-} == member ]] || return 0
	[[ -n ${MESH_MASTER_URL:-} ]] || {
		printf '%s\n' "no_master_url"
		return 1
	}
	if [[ ${MESH_MASTER_URL} == http://* ]]; then
		local mhost
		mhost=$(gps_mesh_url_host "$MESH_MASTER_URL")
		if ! gps_mesh_url_is_loopback "$mhost"; then
			printf '%s\n' "http_public"
			n=$((n + 1))
		fi
	fi
	if [[ ${MESH_MASTER_URL} == https://* && -z ${MESH_TLS_PIN:-} ]]; then
		printf '%s\n' "https_no_pin"
		n=$((n + 1))
	fi
	local health_url="${MESH_MASTER_URL%/}/v1/health"
	if have_cmd curl; then
		local rc=0
		GPS_MESH_CURL_MAX_TIME=3 GPS_MESH_CURL_CONNECT_TIMEOUT=${GPS_MESH_CURL_CONNECT_TIMEOUT:-2} \
			gps_mesh_curl "$health_url" -o /dev/null >/dev/null 2>&1 || rc=$?
		if [[ $rc -ne 0 ]]; then
			printf '%s\n' "master_unreachable"
			n=$((n + 1))
		fi
	else
		printf '%s\n' "no_curl"
		n=$((n + 1))
	fi
	return "$n"
}

# Member：交互式修复 TLS/连通性（可传入 join 整行非交互）
gps_mesh_migrate_tls() {
	local join_line=${1:-}
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	[[ ${MESH_ROLE:-} == member ]] || err "migrate-tls 仅 Member 可执行"
	gps_mesh_defaults
	local -a issues=()
	local issue
	while IFS= read -r issue; do
		[[ -n $issue ]] && issues+=("$issue")
	done < <(gps_mesh_migrate_tls_detect || true)
	if ((${#issues[@]} == 0)); then
		msg "$(_green "无需修复") Master URL / TLS 钉扎 / 连通性正常"
		return 0
	fi
	msg "$(_cyan "检测到问题"):"
	for issue in "${issues[@]}"; do
		case $issue in
		http_public) msg "  - 公网明文 http Master（应改用 https + PIN）" ;;
		https_no_pin) msg "  - https Master 缺少 MESH_TLS_PIN" ;;
		master_unreachable)
			msg "  - 无法访问 Master /v1/health（防火墙 / 云 SG / 地址错误）"
			;;
		no_master_url) msg "  - 未设置 MESH_MASTER_URL" ;;
		no_curl) msg "  - 无 curl，无法探测" ;;
		*) msg "  - $issue" ;;
		esac
	done
	if [[ -z $join_line && -t 0 ]]; then
		msg ""
		msg "请粘贴 Master 上 ${GPS_MESH_JOIN_CMD:-join.cmd} 的整行，或 mesh show 打印的 join 命令:"
		msg "  GPS_MESH_MASTER=https://... GPS_MESH_TLS_PIN=sha256//... GPS_MESH_TOKEN=... bash install.sh"
		printf '%s' "粘贴整行（空=取消）: "
		read -r join_line
	fi
	if [[ -z $join_line ]]; then
		warn "未提供 join 命令，无法自动修复。"
		msg "下一步:"
		msg "  1) 到 Master 菜单 25 / mesh join-export 获取 join.cmd"
		msg "  2) 确认 Master 云安全组已放行 TCP ${MESH_MASTER_PORT:-19527}"
		msg "  3) 重试: geoproxy-server mesh migrate-tls"
		return 1
	fi
	gps_mesh_become_member "$join_line" ""
	GPS_MESH_SYNC_RESTART=1 gps_mesh_sync_master
	msg "$(_green "migrate-tls 完成") 已更新 Master URL / TLS PIN / TOKEN 并 sync-master"
}

# Master：轮换集群 TOKEN（旧 token 立即失效；Member 须重新 join）
gps_mesh_token_rotate() {
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	[[ ${MESH_ROLE:-} == master ]] || err "token rotate 仅 Master 可执行"
	if [[ -t 0 && ${GPS_MESH_TOKEN_ROTATE_YES:-} != 1 ]]; then
		msg "$(_yellow "警告") 轮换后所有 Member 必须用新 join 命令重新加入。"
		confirm_yes "确认轮换集群 TOKEN?" || err "已取消"
	fi
	local old=${MESH_CLUSTER_TOKEN:-}
	if have_cmd openssl; then
		MESH_CLUSTER_TOKEN=$(openssl rand -hex 24)
	else
		MESH_CLUSTER_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
	fi
	gps_mesh_ensure_dirs
	umask 077
	printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
	chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
	save_state
	gps_install_mesh_units 2>/dev/null || true
	gps_mesh_write_join_cmd
	msg "$(_green "集群 TOKEN 已轮换")"
	[[ -n $old ]] && msg "  旧 TOKEN: $(gps_mesh_mask_token "$old")（已失效）"
	msg "  新 TOKEN: $(gps_mesh_mask_token "$MESH_CLUSTER_TOKEN")"
	gps_mesh_join_export
}

# Master：GitHub Release webhook 公网 URL（TLS 控制面 + /v1/hook/github）
gps_mesh_webhook_url() {
	local base
	base=$(gps_mesh_primary_join_url 2>/dev/null || true)
	[[ -n $base ]] || base="https://127.0.0.1:${MESH_MASTER_PORT:-19527}"
	printf '%s/v1/hook/github' "${base%/}"
}

# Master：设置 GitHub webhook secret（写入 state.env + master.env 并 restart mesh-master）
gps_mesh_webhook_set_secret() {
	local sec=${1:-}
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	[[ ${MESH_ROLE:-} == master ]] || err "webhook 仅 Master 可配置"
	if [[ -z $sec ]]; then
		if have_cmd openssl; then
			sec=$(openssl rand -hex 32)
		else
			sec=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
		fi
		msg "已生成新 webhook secret（请复制到 GitHub Hook Secret）"
	fi
	sec=$(printf '%s' "$sec" | tr -d '[:space:]')
	((${#sec} >= 16)) || err "secret 至少 16 字符"
	GPS_GITHUB_WEBHOOK_SECRET=$sec
	save_state
	gps_install_mesh_units 2>/dev/null || gps_install_mesh_units_files_only
	msg "$(_green "GitHub webhook secret 已设置")"
	gps_mesh_webhook_show
}

# Master：展示 webhook 配置说明（secret 脱敏）
gps_mesh_webhook_show() {
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	gps_mesh_defaults 2>/dev/null || true
	gps_mesh_resolve_master_host 2>/dev/null || true
	[[ ${MESH_ROLE:-} == master ]] || err "webhook 仅 Master 可查看"
	local url masked
	url=$(gps_mesh_webhook_url)
	msg "$(_cyan "GitHub Release webhook（Master 自动 upgrade self）")"
	msg "  URL:    ${url}"
	msg "  事件:   Release → published（推荐）；亦接受 push tag v*"
	if [[ -n ${GPS_GITHUB_WEBHOOK_SECRET:-} ]]; then
		masked=$(gps_mesh_mask_token "$GPS_GITHUB_WEBHOOK_SECRET")
		msg "  Secret: ${masked}（已配置；完整值见 ${GPS_MESH_ENV}）"
	else
		msg "  Secret: （未配置）— geoproxy-server mesh webhook set-secret"
	fi
	msg "  说明:   GitHub Release 后 Master 自动 upgrade self；Member 经 mesh-sync 同步 cluster 目标版本并自动升级"
	msg "  Member: mesh-sync 每 ${MESH_SYNC_SEC:-60}s 拉取 cluster.target_version；可用 change cluster-auto-upgrade 0 关闭"
}

# 已安装脚本版本（VPS 上 lib/scripts/VERSION）
gps_mesh_installed_version() {
	if [[ -f ${GPS_LIB_DIR}/scripts/VERSION ]]; then
		tr -d '[:space:]' <"${GPS_LIB_DIR}/scripts/VERSION"
	else
		printf '%s' "${GPS_SH_VER:-unknown}"
	fi
}

# Member：Master 广播的目标版本与本地不一致时，调度 upgrade-cluster unit
# 升级失败冷却：冷却窗内不再调度（防「每分钟停服重试」式慢性断线）
gps_mesh_cluster_upgrade_cooling() {
	local f="${GPS_MESH_DIR}/upgrade-cooldown"
	[[ -f $f ]] || return 1
	local last
	last=$(sed -n 's/^FAILED_AT=//p' "$f" 2>/dev/null | tail -1)
	[[ $last =~ ^[0-9]+$ ]] || return 1
	local now
	now=$(date +%s)
	((now - last < ${MESH_CLUSTER_UPGRADE_RETRY_SEC:-600}))
}

gps_mesh_cluster_schedule_upgrade() {
	local target=${1:-}
	gps_mesh_role_normalize 2>/dev/null || true
	[[ ${MESH_ROLE:-} == member ]] || return 0
	[[ ${MESH_CLUSTER_AUTO_UPGRADE:-1} == 1 ]] || return 0
	# 上次升级失败后的冷却窗内不调度（失败原因见 geoproxy-mesh-upgrade journal）
	if gps_mesh_cluster_upgrade_cooling; then
		return 0
	fi
	target=$(printf '%s' "$target" | tr -d '[:space:]')
	[[ -n $target && $target == v*.*.* ]] || return 0
	local cur
	cur=$(gps_mesh_installed_version)
	[[ $cur != "$target" ]] || return 0
	local pending=${GPS_MESH_UPGRADE_PENDING:-${GPS_MESH_DIR}/upgrade-pending}
	gps_mesh_ensure_dirs 2>/dev/null || true
	printf '%s\n' "$target" >"$pending"
	chmod 600 "$pending" 2>/dev/null || true
	if [[ ${GPS_NO_SYSTEMD:-0} == 1 || -n ${GPS_TEST_PREFIX:-} ]]; then
		gps_mesh_cmd_upgrade_cluster "$target" 2>/dev/null || true
		return 0
	fi
	if have_cmd systemctl; then
		systemctl start "${GPS_MESH_UPGRADE_SERVICE:-geoproxy-mesh-upgrade}.service" 2>/dev/null ||
			warn "无法启动 ${GPS_MESH_UPGRADE_SERVICE}（请 upgrade self 安装 unit）"
	fi
}

# mesh-sync / geoproxy-mesh-upgrade.service：执行 pending 集群升级
gps_mesh_cmd_upgrade_cluster() {
	if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
		need_root
	fi
	load_state 2>/dev/null || true
	gps_mesh_role_normalize 2>/dev/null || true
	local pending=${GPS_MESH_UPGRADE_PENDING:-${GPS_MESH_DIR}/upgrade-pending}
	local tag
	if [[ -f $pending ]]; then
		tag=$(tr -d '[:space:]' <"$pending")
	elif [[ -n ${1:-} ]]; then
		tag=$(printf '%s' "$1" | tr -d '[:space:]')
	else
		err "无待升级版本（${pending} 不存在）"
	fi
	[[ -n $tag && $tag == v*.*.* ]] || {
		rm -f "$pending"
		err "无效 cluster 目标版本: ${tag:-?}"
	}
	local cur
	cur=$(gps_mesh_installed_version)
	if [[ $cur == "$tag" ]]; then
		rm -f "$pending"
		msg "$(_green "无需升级") 脚本已是 $cur（Master 目标版本）"
		return 0
	fi
	msg "$(_cyan "集群自动升级") Master 目标 ${tag}，本机 ${cur} → 开始 upgrade self…"
	# 子 shell 捕获 err(exit 1)：失败写冷却标记，成员在冷却窗内不再反复停服重试
	if ! (gps_cmd_upgrade_self --ver "$tag"); then
		gps_mesh_ensure_dirs 2>/dev/null || true
		printf 'FAILED_AT=%s\n' "$(date +%s)" >"${GPS_MESH_DIR}/upgrade-cooldown"
		chmod 600 "${GPS_MESH_DIR}/upgrade-cooldown" 2>/dev/null || true
		err "集群升级失败（服务已由 upgrade self 恢复/未受影响）；$((${MESH_CLUSTER_UPGRADE_RETRY_SEC:-600} / 60)) 分钟冷却后再试"
	fi
	rm -f "$pending" "${GPS_MESH_DIR}/upgrade-cooldown"
}

# 控制台打印时对集群 TOKEN 脱敏（前 8 字符 + ********）
gps_mesh_mask_token() {
	local k=${1:-}
	local n=${#k}
	if ((n <= 8)); then
		echo "********"
		return
	fi
	echo "${k:0:8}********"
}

# 将完整 join 行中的 TOKEN 替换为脱敏值
gps_mesh_mask_join_line() {
	local line=${1:-}
	local tok masked
	tok=$(printf '%s' "$line" | sed -n 's/.*GPS_MESH_TOKEN=\([^[:space:]]*\).*/\1/p' | head -n1)
	[[ -n $tok ]] || {
		printf '%s\n' "$line"
		return
	}
	masked=$(gps_mesh_mask_token "$tok")
	printf '%s\n' "${line/GPS_MESH_TOKEN=$tok/GPS_MESH_TOKEN=$masked}"
}

# 组装单行加入命令（含完整 TOKEN）
gps_mesh_format_join_line() {
	local u=${1:-} pin_part=${2:-}
	printf 'GPS_MESH_MASTER=%s %sGPS_MESH_TOKEN=%s bash install.sh\n' "$u" "$pin_part" "$MESH_CLUSTER_TOKEN"
}

# 解析当前 live scheme 与 TLS PIN 前缀（写入 __MESH_JOIN_SCHEME / __MESH_JOIN_PIN_PART）
gps_mesh_join_scheme_pin() {
	local port=${1:-${MESH_MASTER_PORT:-19527}}
	__MESH_JOIN_SCHEME=$(gps_mesh_live_control_scheme "$port")
	__MESH_JOIN_PIN_PART=""
	if [[ ${__MESH_JOIN_SCHEME} == https && -f ${GPS_MESH_TLS_FP:-} ]]; then
		local pin
		pin=$(tr -d '[:space:]' <"$GPS_MESH_TLS_FP")
		[[ -n $pin ]] && __MESH_JOIN_PIN_PART="GPS_MESH_TLS_PIN=${pin} "
	fi
}

# Master：落盘完整 join 行到 join.cmd（0600）
gps_mesh_write_join_cmd() {
	[[ ${MESH_ROLE:-} == master ]] || return 0
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || return 0
	gps_mesh_ensure_dirs
	local port=${MESH_MASTER_PORT:-19527} u
	gps_mesh_join_scheme_pin "$port"
	u=$(GPS_MESH_LIVE_SCHEME=$__MESH_JOIN_SCHEME gps_mesh_primary_join_url)
	[[ -n $u ]] || return 0
	umask 077
	gps_mesh_format_join_line "$u" "$__MESH_JOIN_PIN_PART" >"$GPS_MESH_JOIN_CMD"
	chmod 600 "$GPS_MESH_JOIN_CMD" 2>/dev/null || true
}

# Master：打印 join.cmd 路径、权限与脱敏预览
gps_mesh_join_export() {
	[[ ${MESH_ROLE:-} == master ]] || err "仅 Master 可导出加入文件"
	load_state 2>/dev/null || true
	gps_mesh_role_normalize
	gps_mesh_defaults
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || gps_mesh_ensure_cluster_token
	gps_mesh_write_join_cmd
	[[ -f ${GPS_MESH_JOIN_CMD:-} ]] || err "无法写入 ${GPS_MESH_JOIN_CMD:-join.cmd}"
	local perm preview
	perm=$(stat -c %a "$GPS_MESH_JOIN_CMD" 2>/dev/null || echo "?")
	preview=$(gps_mesh_mask_join_line "$(cat "$GPS_MESH_JOIN_CMD")")
	msg "$(_cyan "Mesh 加入文件")"
	msg "  路径: ${GPS_MESH_JOIN_CMD}"
	msg "  权限: ${perm}（应为 600）"
	msg "  预览: ${preview}"
	msg "  Member 可将文件内容粘贴到菜单 26 或 mesh join"
}

# 打印成员加入命令（全部可用地址）；仅在实测 https 时附带公钥指纹
gps_mesh_print_join_hints() {
	[[ ${MESH_ROLE:-} == master ]] || return 0
	[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || return 0
	local u masked
	local port=${MESH_MASTER_PORT:-19527}
	gps_mesh_join_scheme_pin "$port"
	if [[ ${__MESH_JOIN_SCHEME} == http ]] && gps_mesh_master_tls_on; then
		warn "控制面证书已在磁盘，但本机 :${port} 仍为明文 HTTP。请执行: systemctl restart ${GPS_MESH_MASTER_SERVICE:-geoproxy-mesh-master}"
	fi
	gps_mesh_write_join_cmd
	gps_mesh_expose_control_plane
	masked=$(gps_mesh_mask_token "$MESH_CLUSTER_TOKEN")
	msg "$(_cyan "其它节点加入组网")（IPv4 / IPv6 / 域名任选其一可通即可）:"
	while IFS= read -r u; do
		[[ -n $u ]] || continue
		msg "  GPS_MESH_MASTER=${u} ${__MESH_JOIN_PIN_PART}GPS_MESH_TOKEN=${masked} bash install.sh"
	done < <(GPS_MESH_LIVE_SCHEME=$__MESH_JOIN_SCHEME gps_mesh_join_urls)
	msg "  完整命令（含 TOKEN）: ${GPS_MESH_JOIN_CMD}（权限 600）；或 geoproxy-server mesh join-export"
	gps_mesh_print_control_plane_status
	gps_mesh_print_wg_data_plane_status
	# 与菜单 23 doctor 同款本机 health 一行，避免运维再手敲 curl
	gps_mesh_print_local_health "$port" || true
}

# 从「整行加入命令」或「地址 + TOKEN」解析出 url/token/pin（写入全局 __MESH_PARSE_URL / __MESH_PARSE_TOKEN / __MESH_PARSE_PIN）
gps_mesh_parse_join_input() {
	local blob=${1:-}
	__MESH_PARSE_URL=""
	__MESH_PARSE_TOKEN=""
	__MESH_PARSE_PIN=""
	[[ -n $blob ]] || return 1
	# 粘贴了完整命令：GPS_MESH_MASTER=... [GPS_MESH_TLS_PIN=...] GPS_MESH_TOKEN=...
	if [[ $blob == *GPS_MESH_MASTER=* ]]; then
		__MESH_PARSE_URL=$(printf '%s' "$blob" | sed -n 's/.*GPS_MESH_MASTER=\([^[:space:]]*\).*/\1/p' | head -n1)
		__MESH_PARSE_TOKEN=$(printf '%s' "$blob" | sed -n 's/.*GPS_MESH_TOKEN=\([^[:space:]]*\).*/\1/p' | head -n1)
		__MESH_PARSE_PIN=$(printf '%s' "$blob" | sed -n 's/.*GPS_MESH_TLS_PIN=\([^[:space:]]*\).*/\1/p' | head -n1)
		[[ -n $__MESH_PARSE_URL ]] || return 1
		return 0
	fi
	# 仅 URL
	__MESH_PARSE_URL=$blob
	return 0
}

# 是否像合法 IPv6（十六进制与冒号，可选压缩）
gps_mesh_looks_like_ipv6() {
	local h=${1:-}
	[[ -n $h ]] || return 1
	[[ $h == *:* ]] || return 1
	[[ $h =~ ^[0-9A-Fa-f:]+$ ]] || return 1
	local colons=${h//[^:]/}
	((${#colons} >= 2))
}

# 把用户输入规范成 http(s)://host:port（支持域名 / IPv4 / IPv6 / 已带协议）
# 裸地址默认 https（Master 自签证书是常态）；http 仅建议 loopback
gps_mesh_normalize_master_url() {
	local raw=${1:-}
	# 保留空格以便检测整行粘贴；先尝试解析命令行
	if [[ $raw == *GPS_MESH_MASTER=* ]]; then
		gps_mesh_parse_join_input "$raw" || err "无法从粘贴内容解析 GPS_MESH_MASTER"
		raw=$__MESH_PARSE_URL
	fi
	raw=$(printf '%s' "$raw" | tr -d '[:space:]')
	[[ -n $raw ]] || err "Master 地址不能为空"
	# 拒绝把整段命令误当地址
	case $raw in
	*GPS_MESH_* | *TOKEN=* | *install.sh* | *bash*)
		err "Master 地址无效：请只填域名/IP，或粘贴完整一行「GPS_MESH_MASTER=... GPS_MESH_TOKEN=...」"
		;;
	esac
	((${#raw} < 256)) || err "Master 地址过长，请检查是否误粘贴了整段命令"
	gps_mesh_defaults
	local port=${MESH_MASTER_PORT:-19527}
	local scheme=https
	if [[ $raw == http://* || $raw == https://* ]]; then
		# 再拦一次被包进 URL 的垃圾
		case $raw in
		*GPS_MESH_* | *TOKEN=* | *install.sh*)
			err "Master URL 无效（含命令残留），请重新填写"
			;;
		esac
		printf '%s\n' "${raw%/}"
		return 0
	fi
	# [v6] 或 [v6]:port
	if [[ $raw == \[*\]* ]]; then
		if [[ $raw == \[*\]:* ]]; then
			printf '%s://%s\n' "$scheme" "$raw"
		else
			printf '%s://%s:%s\n' "$scheme" "$raw" "$port"
		fi
		return 0
	fi
	# 裸 IPv6
	if gps_mesh_looks_like_ipv6 "$raw"; then
		printf '%s://[%s]:%s\n' "$scheme" "$raw" "$port"
		return 0
	fi
	# host:port 或 host（IPv4 / 域名）— 单冒号才当 port
	local colons=${raw//[^:]/}
	if ((${#colons} == 1)); then
		printf '%s://%s\n' "$scheme" "$raw"
	elif ((${#colons} == 0)); then
		printf '%s://%s:%s\n' "$scheme" "$raw" "$port"
	else
		err "无法识别 Master 地址: $raw（域名/IPv4/IPv6 或 http(s)://...）"
	fi
}

gps_mesh_become_master() {
	load_state 2>/dev/null || true
	MESH_ROLE=master
	gps_mesh_role_normalize
	PROFILE=mesh-member
	MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
	gps_mesh_defaults
	gps_mesh_ensure_cluster_token
	gps_mesh_ensure_master_tls
	gps_mesh_resolve_master_host
	# 先重启 mesh-master 再 ensure：否则探测仍看到旧明文进程，会把 join URL 写成 http
	gps_install_mesh_units 2>/dev/null || true
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_restart_svc
	msg "$(_green "本机已设为 Master")"
	gps_mesh_print_join_hints
}

gps_mesh_become_member() {
	local url=${1:-}
	local token=${2:-}
	local pin=${3:-}
	[[ -n $url ]] || err "用法: mesh join <Master地址> <TOKEN>"
	# 整行粘贴时自动拆出 TOKEN / TLS 指纹
	if [[ $url == *GPS_MESH_MASTER=* ]] || [[ -z $token && $url == *GPS_MESH_TOKEN=* ]]; then
		gps_mesh_parse_join_input "$url" || err "无法解析加入命令"
		url=$__MESH_PARSE_URL
		[[ -n $token ]] || token=$__MESH_PARSE_TOKEN
		[[ -n $pin ]] || pin=$__MESH_PARSE_PIN
	fi
	[[ -n $token ]] || err "需要集群 TOKEN（在 Master 的 mesh show 中查看）"
	load_state 2>/dev/null || true
	MESH_ROLE=member
	gps_mesh_role_normalize
	PROFILE=mesh-member
	MESH_MASTER_URL=$(gps_mesh_normalize_master_url "$url")
	MESH_CLUSTER_TOKEN=$token
	# 交互场景硬拒绝明文公网 Master（后台 register 只 warn，见 gps_mesh_curl）
	gps_mesh_require_https_or_loopback "$MESH_MASTER_URL"
	if [[ -n $pin ]]; then
		[[ $pin =~ ^sha256//[A-Za-z0-9+/=]+$ ]] || err "TLS 指纹格式非法（应为 sha256//BASE64）"
		MESH_TLS_PIN=$pin
	fi
	# 去掉 TOKEN 里可能粘上的 bash/install 残留
	MESH_CLUSTER_TOKEN=${MESH_CLUSTER_TOKEN%%bash*}
	MESH_CLUSTER_TOKEN=${MESH_CLUSTER_TOKEN%%install*}
	MESH_CLUSTER_TOKEN=$(printf '%s' "$MESH_CLUSTER_TOKEN" | tr -d '[:space:]')
	[[ ${#MESH_CLUSTER_TOKEN} -ge 16 ]] || err "TOKEN 看起来不对，请从 Master「mesh show」复制"
	gps_mesh_ensure_dirs
	umask 077
	printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
	chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
	GPS_MESH_SYNC_RESTART=0 gps_mesh_ensure_boot
	save_state
	gps_install_mesh_units 2>/dev/null || true
	gps_restart_svc
	msg "$(_green "本机已设为 Node/成员") Master=$MESH_MASTER_URL"
	msg "将向 Master 注册并拉取 peers，实现相互发现"
}

# 菜单：选择 Master 或 Node 并填写
gps_mesh_menu_role() {
	load_state 2>/dev/null || true
	# 展示时若 Master URL 已损坏，给出提示
	local show_url=${MESH_MASTER_URL:-—}
	if [[ $show_url == *GPS_MESH_* || $show_url == *install.sh* || ${#show_url} -gt 120 ]]; then
		show_url="（当前配置已损坏，请选 2 重新填写）"
	fi
	msg "$(_cyan "Mesh 角色")"
	msg "  当前: MESH_ROLE=${MESH_ROLE:-?}  Master=${show_url}"
	msg "  1) 本机作为 Master（其它机器来加入）"
	msg "  2) 本机作为 Node（加入已有 Master）"
	msg "  3) Member：TLS/连通性修复 (migrate-tls)"
	if [[ ${MESH_ROLE:-} == master ]]; then
		msg "  4) Master：轮换集群 TOKEN（Member 须重 join）"
	fi
	msg "  0) 返回"
	local c
	printf '%s' "请选择: "
	read -r c
	case $c in
	1)
		gps_mesh_become_master
		;;
	2)
		local line url token
		msg "任选一种填写方式:"
		msg "  A) 粘贴 Master 上打印的整行（推荐）:"
		msg "     GPS_MESH_MASTER=https://... GPS_MESH_TLS_PIN=sha256//... GPS_MESH_TOKEN=... bash install.sh"
		msg "  B) 分开填写：先地址（仅域名/IP），再 TOKEN"
		printf '%s' "粘贴整行 或 只填 Master 地址: "
		read -r line
		if [[ $line == *GPS_MESH_MASTER=* ]]; then
			gps_mesh_become_member "$line" ""
		else
			printf '%s' "集群 TOKEN: "
			read -r token
			gps_mesh_become_member "$line" "$token"
		fi
		;;
	3)
		gps_mesh_migrate_tls
		;;
	4)
		if [[ ${MESH_ROLE:-} == master ]]; then
			gps_mesh_token_rotate
		else
			warn "无效选项"
		fi
		;;
	0 | "") ;;
	*) warn "无效选项" ;;
	esac
}

# 安装时根据环境决定角色（零菜单）
gps_mesh_bootstrap_from_env() {
	# 显式 GPS_MESH_MASTER → 成员；否则已有 MESH_ROLE 保留；全新默认 master
	if [[ -n ${GPS_MESH_MASTER:-} ]]; then
		MESH_ROLE=member
		MESH_MASTER_URL=${GPS_MESH_MASTER%/}
		if [[ -n ${GPS_MESH_TOKEN:-} ]]; then
			MESH_CLUSTER_TOKEN=$GPS_MESH_TOKEN
		fi
		if [[ -n ${GPS_MESH_TLS_PIN:-} ]]; then
			MESH_TLS_PIN=$GPS_MESH_TLS_PIN
		fi
		[[ -n ${MESH_CLUSTER_TOKEN:-} ]] || err "成员安装需要 GPS_MESH_TOKEN（或 MESH_CLUSTER_TOKEN）与 GPS_MESH_MASTER"
	elif [[ -z ${MESH_ROLE:-} ]]; then
		MESH_ROLE=master
	fi
	gps_mesh_role_normalize
	PROFILE=mesh-member
	gps_profile_normalize
	gps_mesh_defaults
	if [[ $MESH_ROLE == master ]]; then
		MESH_OVERLAY_IP=${MESH_OVERLAY_IP:-10.66.0.1}
		gps_mesh_ensure_cluster_token
		gps_mesh_ensure_master_tls
		gps_mesh_resolve_master_host
		MESH_MASTER_URL=$(gps_mesh_primary_join_url)
	else
		[[ -n ${MESH_MASTER_URL:-} ]] || err "成员需要 MESH_MASTER_URL 或 GPS_MESH_MASTER"
		# 安装上下文用户在场：明文公网 Master 直接拒绝
		gps_mesh_require_https_or_loopback "${MESH_MASTER_URL}"
		if [[ -n ${MESH_TLS_PIN:-} ]]; then
			[[ $MESH_TLS_PIN =~ ^sha256//[A-Za-z0-9+/=]+$ ]] || err "GPS_MESH_TLS_PIN 格式非法（应为 sha256//BASE64）"
		fi
		gps_mesh_ensure_dirs
		if [[ -n ${MESH_CLUSTER_TOKEN:-} ]]; then
			umask 077
			printf '%s\n' "$MESH_CLUSTER_TOKEN" >"$GPS_MESH_TOKEN_FILE"
			chmod 600 "$GPS_MESH_TOKEN_FILE" 2>/dev/null || true
		fi
	fi
}
