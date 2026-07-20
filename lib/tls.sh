#!/bin/bash
# 自签 TLS 证书

gps_ensure_tls() {
  mkdir -p "$GPS_TLS_DIR"
  chmod 700 "$GPS_TLS_DIR"
  if [[ -f $GPS_CERT && -f $GPS_KEY ]]; then
    return 0
  fi
  ensure_deps
  msg "$(_cyan "生成") 自签 TLS 证书 ..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$GPS_KEY" -out "$GPS_CERT" -days 3650 -nodes \
    -subj "/CN=geoproxy-tuic" >/dev/null 2>&1 ||
    openssl req -x509 -newkey rsa:2048 \
      -keyout "$GPS_KEY" -out "$GPS_CERT" -days 3650 -nodes \
      -subj "/CN=geoproxy-tuic" >/dev/null 2>&1 ||
    err "openssl 生成证书失败"
  chmod 600 "$GPS_KEY"
  chmod 644 "$GPS_CERT"
}

gps_rotate_tls() {
  rm -f "$GPS_CERT" "$GPS_KEY"
  gps_ensure_tls
}
