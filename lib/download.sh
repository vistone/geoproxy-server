#!/bin/bash
# 下载 / 安装 sing-box 二进制

gps_latest_tag() {
  curl -fsSL --max-time 20 \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest" |
    grep -oE '"tag_name":\s*"v[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)".*/\1/'
}

# 已安装核心版本号（无 v 前缀）；优先读二进制，回退 state.env
gps_core_ver_installed() {
  local v=""
  if [[ -x ${GPS_CORE_BIN:-} ]]; then
    v=$("$GPS_CORE_BIN" version 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
  fi
  if [[ -z $v && -n ${CORE_VER:-} ]]; then
    v=${CORE_VER#v}
  fi
  echo "$v"
}

# 解析目标版本：latest → GitHub 最新 tag；去掉 v 前缀
gps_resolve_core_ver() {
  local ver=${1:-latest}
  if [[ -z $ver || $ver == latest ]]; then
    ver=$(gps_latest_tag) || err "无法获取 sing-box 最新版本（GitHub API）"
  fi
  echo "${ver#v}"
}

gps_download_core() {
  local ver=$1
  local force=${2:-0}
  local arch
  arch=$(detect_arch)
  ensure_deps

  ver=$(gps_resolve_core_ver "$ver")
  local tag="v${ver}"
  local cur
  cur=$(gps_core_ver_installed)
  if [[ $force -eq 0 && -n $cur && $cur == "$ver" && -x ${GPS_CORE_BIN:-} ]]; then
    CORE_VER="$ver"
    msg "$(_green "已是最新") sing-box ${tag}，跳过下载"
    return 0
  fi

  local name="sing-box-${ver}-linux-${arch}"
  local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${name}.tar.gz"
  local tmp
  tmp=$(mktemp -d)
  msg "$(_cyan "下载") sing-box ${tag} (${arch}) ..."
  if ! curl -fL --progress-bar --max-time 300 -o "${tmp}/sb.tar.gz" "$url"; then
    rm -rf "$tmp"
    err "下载失败: $url"
  fi
  tar -xzf "${tmp}/sb.tar.gz" -C "$tmp" || {
    rm -rf "$tmp"
    err "解压失败"
  }
  local bin
  bin=$(find "$tmp" -type f -name sing-box | head -1)
  [[ -n $bin && -x $bin ]] || {
    rm -rf "$tmp"
    err "归档中未找到 sing-box 二进制"
  }
  mkdir -p "$GPS_LIB_DIR"
  install -m 755 "$bin" "$GPS_CORE_BIN"
  rm -rf "$tmp"
  CORE_VER="$ver"
  msg "$(_green "已安装") $GPS_CORE_BIN ($tag)"
}

# ---------- geoproxy-server 脚本自身升级 ----------

gps_self_latest_tag() {
  curl -fsSL --max-time 20 \
    "https://api.github.com/repos/${GPS_SELF_REPO}/releases/latest" |
    grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 |
    sed -E 's/.*"?(v[^"]+)"?.*/\1/' | grep -oE 'v[0-9.]+' | head -1
}

gps_self_resolve_ver() {
  local ver=${1:-latest}
  if [[ -z $ver || $ver == latest ]]; then
    ver=$(gps_self_latest_tag) || err "无法获取 ${GPS_SELF_REPO} 最新版本"
  fi
  [[ $ver == v* ]] || ver="v${ver}"
  echo "$ver"
}

# 从远程 tag 拉取脚本树到 stdout 路径（打印仓库根目录）
gps_self_fetch_tree() {
  local tag=$1
  local dest=$2
  mkdir -p "$dest"
  local url="https://github.com/${GPS_SELF_REPO}/archive/refs/tags/${tag}.tar.gz"
  msg "$(_cyan "下载") ${GPS_SELF_REPO} ${tag} ..."
  curl -fsSL --max-time 120 "$url" -o "${dest}/src.tar.gz" || err "下载失败: $url"
  tar -xzf "${dest}/src.tar.gz" -C "$dest" || err "解压失败"
  local script
  script=$(find "$dest" -mindepth 1 -name geoproxy-server.sh -type f | head -1 || true)
  [[ -n $script && -f $script ]] || err "归档中未找到 geoproxy-server.sh"
  cd "$(dirname "$script")" && pwd -P
}

# 用 src_root 覆盖已安装脚本（保留 state/config/tls/sing-box）
gps_self_install_tree() {
  local src_root=$1
  [[ -f $src_root/geoproxy-server.sh ]] || err "无效脚本树: $src_root"
  mkdir -p "$GPS_LIB_DIR"
  local staging="${GPS_LIB_DIR}/.scripts.staging.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -a "$src_root/." "$staging/"
  # 原子替换
  rm -rf "${GPS_LIB_DIR}/scripts.prev"
  if [[ -d ${GPS_LIB_DIR}/scripts ]]; then
    mv "${GPS_LIB_DIR}/scripts" "${GPS_LIB_DIR}/scripts.prev"
  fi
  mv "$staging" "${GPS_LIB_DIR}/scripts"
  GPS_ROOT="${GPS_LIB_DIR}/scripts"
  GPS_TMPL="${GPS_ROOT}/templates"
  # 只写入口，不再从 GPS_ROOT 全量拷（已在上面拷好）
  mkdir -p "$(dirname "$GPS_BIN_LINK")"
  cat >"$GPS_BIN_LINK" <<EOF
#!/bin/bash
export GPS_TEST_PREFIX='${GPS_TEST_PREFIX:-}'
export GPS_NO_SYSTEMD='${GPS_NO_SYSTEMD:-0}'
exec bash "${GPS_LIB_DIR}/scripts/geoproxy-server.sh" "\$@"
EOF
  chmod 755 "$GPS_BIN_LINK"
  # 刷新 systemd 单元（不改 state.env）
  if [[ ${GPS_NO_SYSTEMD:-0} != 1 && -z ${GPS_TEST_PREFIX:-} ]]; then
    local tpl="${GPS_TMPL}/geoproxy-tuic.service"
    if [[ -f $tpl ]]; then
      sed -e "s|__CORE_BIN__|${GPS_CORE_BIN}|g" \
        -e "s|__CONFIG__|${GPS_CONFIG}|g" \
        -e "s|__LOG__|${GPS_LOG}|g" \
        "$tpl" >"$GPS_UNIT_PATH"
    fi
    gps_install_traffic_timer 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  elif [[ -n ${GPS_TEST_PREFIX:-} || ${GPS_NO_SYSTEMD:-0} == 1 ]]; then
    # 测试前缀也写 timer 文件（不 enable）
    gps_install_traffic_timer 2>/dev/null || true
  fi
  SCRIPT_VER=$(cat "${GPS_ROOT}/VERSION" 2>/dev/null || echo "$GPS_SH_VER")
  SCRIPT_VER=${SCRIPT_VER//$'\n'/}
  GPS_SH_VER=$SCRIPT_VER
}

gps_cmd_upgrade_self() {
  if [[ -z ${GPS_TEST_PREFIX:-} ]]; then
    need_root
  fi
  local ver=latest
  local force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --ver)
        ver=$2
        shift 2
        ;;
      --force | -f)
        force=1
        shift
        ;;
      *) err "未知参数: $1（用法: upgrade self [--ver TAG] [--force]）" ;;
    esac
  done
  load_state || err "未安装"
  ensure_deps
  ver=$(gps_self_resolve_ver "$ver")
  local cur=$GPS_SH_VER
  if [[ -f ${GPS_LIB_DIR}/scripts/VERSION ]]; then
    cur=$(tr -d '[:space:]' <"${GPS_LIB_DIR}/scripts/VERSION")
  fi
  if [[ $force -eq 0 && $cur == "$ver" ]]; then
    msg "$(_green "无需升级") 脚本已是 $cur"
    return 0
  fi
  local tmp root
  tmp=$(mktemp -d /tmp/gps-self-upgrade.XXXXXX)
  trap 'rm -rf "'"$tmp"'"' RETURN
  root=$(gps_self_fetch_tree "$ver" "$tmp")
  gps_self_install_tree "$root"
  save_state
  msg "$(_green "脚本已升级") $cur → $GPS_SH_VER"
  msg "配置/证书/凭证未改动；可用: $GPS_NAME version / doctor / traffic"
}
