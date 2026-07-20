# GeoProxy Server（VPS 端）

面向 **GeoProxy** 的 VPS 一键部署与管理脚本：每台机器只跑 **一个** sing-box 实例，**仅 TUIC 入站 → direct 出站**。

设计说明：[docs/design.md](docs/design.md)

## 特点

- 菜单优先，CLI 为辅
- 自动下载 **最新稳定版** sing-box（不锁定版本号）
- **IPv4 / IPv6 自适应**：双栈监听（`bindv6only=0` 时用 `::` 双栈；否则 `0.0.0.0` + `::`），有哪个公网地址就输出哪个 TUIC URL
- 自签 TLS（`alpn=h3`），默认 UUID=密码、BBR 拥塞控制
- systemd 服务 `geoproxy-tuic`
- 默认日志 **debug**（可见进站/出站连接）；`doctor` 健康检查；`url` 可贴进本地 GeoProxy

## 要求

- root
- systemd
- amd64 / arm64
- 网络可访问 GitHub Releases（下载 sing-box）

## 安装

```bash
git clone https://github.com/vistone/geoproxy-server.git
cd geoproxy-server
sudo bash install.sh

# 可选参数：
sudo bash install.sh --port 5789 --uuid <UUID> --ip <IPv4> --ip6 <IPv6>
```

一键安装（推荐，不依赖 raw CDN 缓存）：

```bash
git clone --depth 1 https://github.com/vistone/geoproxy-server.git /tmp/geoproxy-server \
  && sudo bash /tmp/geoproxy-server/install.sh \
  && rm -rf /tmp/geoproxy-server
```

或（`install.sh` 会自动拉取完整仓库；若 raw CDN 仍缓存旧版，请用上面的 clone 方式）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vistone/geoproxy-server/ccf18d8/install.sh)
```

安装后：

```bash
geoproxy-server          # 交互菜单
geoproxy-server url
geoproxy-server doctor
geoproxy-server log      # 默认跟随；有客户端流量可见 inbound/outbound
```

## CLI

```text
geoproxy-server install [--port N] [--uuid U] [--passwd P] [--ip V4] [--ip6 V6]
geoproxy-server uninstall [-y]
geoproxy-server status | start | stop | restart
geoproxy-server info | url | qr | log [--once]
geoproxy-server change port|uuid|passwd|ip|ip6|ips|log [值|auto]
geoproxy-server upgrade [--force]
geoproxy-server doctor
geoproxy-server bbr
geoproxy-server help | version
```

> `install` / `upgrade` **默认对齐 GitHub 最新稳定版**。  
> `upgrade` 若本地已是最新则**跳过下载**；需要重装时用 `--force`。  
> 默认日志级别 **debug**；`change log info` 可降级。  
> `url` 分别打印 IPv4 / IPv6（若可得）。

## 路径

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/geoproxy-server` | 命令入口 |
| `/usr/local/lib/geoproxy-server/sing-box` | 核心二进制 |
| `/etc/geoproxy-server/config.json` | 配置 |
| `/etc/geoproxy-server/state.env` | 状态（权限 600） |
| `/etc/geoproxy-server/tls/` | 自签证书 |
| `/var/log/geoproxy-server/sing-box.log` | 日志 |
| `geoproxy-tuic.service` | systemd 单元 |

## 与本地 GeoProxy 对接

```text
tuic://<uuid>:<password>@1.2.3.4:<port>?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr
tuic://<uuid>:<password>@[2001:db8::1]:<port>?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr
```

本地 GeoProxy 按地址族选用对应 URL。VPS 端**不做**路由、DNS 分流或流量统计。

## License

MIT
