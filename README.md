# GeoProxy Server（VPS 端）

面向 **GeoProxy** 的 VPS 一键部署与管理脚本：每台机器只跑 **一个** sing-box 实例，**仅 TUIC 入站 → direct 出站**。

当前脚本版本：**v0.2.0**

设计说明：

- [`docs/superpowers/specs/2026-07-20-geoproxy-server-vps-design.md`](../../docs/superpowers/specs/2026-07-20-geoproxy-server-vps-design.md)
- 流量熔断：[`docs/superpowers/specs/2026-07-20-geoproxy-server-traffic-guard-design.md`](../../docs/superpowers/specs/2026-07-20-geoproxy-server-traffic-guard-design.md)

## 特点

- 菜单优先，CLI 为辅
- 自动下载 **最新稳定版** sing-box（不锁定 sing-box 版本号）
- **IPv4 / IPv6 自适应** 监听与 TUIC URL
- 自签 TLS（`alpn=h3`），默认 UUID=密码、BBR
- systemd：`geoproxy-tuic` + **KiwiVM 流量定时检查**（默认 80% 告警 / 95% 停服）
- 默认日志 **debug**（可见进站/出站）

## 要求

- root、systemd、amd64/arm64
- 可访问 GitHub Releases（sing-box）与 `api.64clouds.com`（流量熔断）

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/v0.2.0/install.sh)
```

或：

```bash
git clone --depth 1 --branch v0.2.0 https://github.com/vistone/geoproxy-server.git /tmp/geoproxy-server \
  && sudo bash /tmp/geoproxy-server/install.sh \
  && rm -rf /tmp/geoproxy-server
```

本 monorepo：`sudo bash scripts/geoproxy-server/install.sh`

## 流量熔断（KiwiVM）

```bash
# 录入凭证（启用 geoproxy-traffic.timer）
geoproxy-server change kiwivm <VEID> <API_KEY>

# 查看 / 立即检查 / 熔断后恢复
geoproxy-server traffic
geoproxy-server traffic check
geoproxy-server traffic resume

# 改阈值与间隔（秒，≥60）
geoproxy-server change traffic-warn 80
geoproxy-server change traffic-stop 95
geoproxy-server change traffic-interval 300
```

用量：`data_counter / (plan_monthly_data × monthly_data_multiplier)`。  
≥告警写日志；≥停服则 `stop geoproxy-tuic` 并置 `TRAFFIC_TRIPPED=1`。  
熔断后普通 `start` 拒绝，须 `traffic resume`（且会再验未超停服线）。

## CLI

```text
geoproxy-server install | uninstall | status | start | stop | restart
geoproxy-server info | url | qr | log | doctor | bbr | upgrade
geoproxy-server change …
geoproxy-server traffic [status|check|resume]
geoproxy-server version
```

## 路径

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/geoproxy-server` | 入口 |
| `/etc/geoproxy-server/state.env` | 状态（含 KiwiVM，600） |
| `/var/log/geoproxy-server/sing-box.log` | 代理日志 |
| `/var/log/geoproxy-server/traffic.log` | 熔断日志 |
| `geoproxy-tuic.service` | 代理 |
| `geoproxy-traffic.timer` | 流量检查 |
