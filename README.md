# GeoProxy Server（VPS 端）

面向 **GeoProxy** 的 VPS 一键部署与管理脚本：每台机器只跑 **一个** sing-box 实例，**仅 TUIC 入站 → direct 出站**。

发布号以仓库内 [`VERSION`](./VERSION) 和 [GitHub Releases](https://github.com/vistone/geoproxy-server/releases/latest) 为准。  
**README 不写死版本号**；安装 / 升级默认拉取最新 Release。

设计说明：

- [`docs/superpowers/specs/2026-07-20-geoproxy-server-vps-design.md`](../../docs/superpowers/specs/2026-07-20-geoproxy-server-vps-design.md)
- 流量熔断：[`docs/superpowers/specs/2026-07-20-geoproxy-server-traffic-guard-design.md`](../../docs/superpowers/specs/2026-07-20-geoproxy-server-traffic-guard-design.md)

## 特点

- 菜单优先，CLI 为辅
- **可自升级管理脚本**（`upgrade self`）与 **sing-box 核心**（`upgrade core`）
- 自动下载最新稳定版 sing-box（不锁定 sing-box 版本号）
- **IPv4 / IPv6 自适应** 监听与 TUIC URL（节点名在 `#fragment`）
- 自签 TLS（`alpn=h3`），默认 UUID=密码、BBR
- systemd：`geoproxy-tuic` + **KiwiVM 流量定时检查**（默认 80% 告警 / 95% 停服）
- 默认日志 **debug**（可见进站/出站）

## 要求

- root、systemd、amd64/arm64
- 可访问 GitHub Releases（sing-box / 本仓库）与 `api.64clouds.com`（流量熔断）

## 安装

始终从 `main` 拉 `install.sh`，由脚本解析 **最新 Release tag**（不要把 tag 写进这一条）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/main/install.sh)
```

或：

```bash
git clone --depth 1 https://github.com/vistone/geoproxy-server.git /tmp/geoproxy-server \
  && sudo bash /tmp/geoproxy-server/install.sh \
  && rm -rf /tmp/geoproxy-server
```

指定某版（仅排障）：`GPS_VERSION=vX.Y.Z sudo -E bash install.sh`

本 monorepo：`sudo bash scripts/geoproxy-server/install.sh`

## 升级

```bash
# 管理脚本 → GitHub 最新 Release（保留配置 / 证书 / KiwiVM 凭证）
geoproxy-server upgrade          # 默认 = upgrade self
geoproxy-server upgrade self
geoproxy-server upgrade self --force

# 只升级 sing-box
geoproxy-server upgrade core

# 两者都升
geoproxy-server upgrade all
```

版本更新会先 **stop 并清掉旧进程**，换上新文件后再 **start**（不用旧进程 restart）。  
从菜单升级后会 **exec 新脚本**，丢掉已加载的旧函数，重新画出菜单。

菜单 **19** 与上面等价。不要写 `--ver v0.2.x`，否则会钉在旧版。

入口脚本已丢失时（不要用坏掉的 `/usr/local/bin/geoproxy-server`）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/main/install.sh)
```

会保留 `/etc/geoproxy-server`。若仍有备份：`cp -a /usr/local/lib/geoproxy-server/scripts.prev/. /usr/local/lib/geoproxy-server/scripts/`

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
月配额与重置时间来自 KiwiVM `getServiceInfo`（`plan_monthly_data`、`data_next_reset`）。  
≥告警写日志；≥停服则 `stop geoproxy-tuic` 并置 `TRAFFIC_TRIPPED=1`。  
用量低于停服线后（含月流量重置），`traffic check` / `start` / `restart` 会**自动清除熔断并恢复服务**；仍可用 `traffic resume` 手动恢复。

## TUIC 分享链接

节点名写在 URL **fragment**（`#` 后面），不要用 query 的 `name=`：

```text
tuic://UUID:PASSWORD@IP:PORT/?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr&udp_relay_mode=native#tile1.spacexway.com
```

默认用本机 `hostname -f`。自定义：

```bash
geoproxy-server change name tile1.spacexway.com
geoproxy-server url
```

自签证书仍带 `insecure=1`（GeoProxy / 多数客户端需要）。有正式证书时再自行改 `allow_insecure=false`。

## CLI

```text
geoproxy-server install | uninstall | status | start | stop | restart
geoproxy-server info | url | qr | log | doctor | bbr
geoproxy-server upgrade [self|core|all]
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
