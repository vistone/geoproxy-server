# GeoProxy Server（VPS 端）设计

日期：2026-07-20  
状态：已确认，实现中  
范围：仅 VPS 端运维脚本（不做本地 GeoProxy Go 进程）

## 目标

在每台 VPS 上以**单实例**方式部署 sing-box：**TUIC 入站 → direct 出站**，供本地 GeoProxy 出站连接。  
脚本路径：`scripts/geoproxy-server/`。旧 `scripts/sing-box-server/` 仅作参考，不改不删。

## 决策

| 项 | 选择 |
|----|------|
| 协议 | 仅 TUIC |
| 实例 | 每机一个 `geoproxy-tuic.service` |
| 交互 | 菜单优先，CLI 为辅 |
| sing-box 版本 | **始终默认最新稳定版**（GitHub latest）；禁止在文档/默认参数写死版本号 |
| 地址族 | **IPv4/IPv6 自适应**：双栈监听 `0.0.0.0`+`::`；公网地址分别探测并输出 URL |
| TLS | 自签证书，`alpn=h3`，客户端 `insecure=1` |
| 凭证 | 默认 UUID=密码（可分开修改） |
| 拥塞控制 | `bbr` |

## 系统布局

| 路径 | 用途 |
|------|------|
| `/usr/local/bin/geoproxy-server` | 入口 |
| `/usr/local/lib/geoproxy-server/sing-box` | sing-box 二进制 |
| `/etc/geoproxy-server/config.json` | 运行配置 |
| `/etc/geoproxy-server/state.env` | PORT/UUID/PASSWORD/PUBLIC_IP（600） |
| `/etc/geoproxy-server/tls/{cert,key}.pem` | 自签证书 |
| `/var/log/geoproxy-server/sing-box.log` | 日志 |
| `geoproxy-tuic.service` | systemd 单元 |

## 非目标

- 本地 GeoProxy 主进程、批量 SSH 编排
- 多协议、多实例、Caddy、Let’s Encrypt、OpenRC
- 修改旧 233boy 脚本

## 验收

- `install` 后 `doctor` 通过，`url` 可贴进 GeoProxy 配置
- `change port` / `upgrade` / `uninstall` 行为符合 README
