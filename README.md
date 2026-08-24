# GeoProxy Server（VPS 端）

面向 **GeoProxy** 的 VPS 一键部署与管理脚本：每台机器只跑 **一个** sing-box 实例；默认 **TUIC → direct**，可选 **WireGuard mesh** 多机互连与跳转。

发布号以仓库内 [`VERSION`](./VERSION) 和 [GitHub Releases](https://github.com/vistone/geoproxy-server/releases/latest) 为准。  
**README 不写死版本号**；安装 / 升级默认拉取最新 Release。

设计说明：

- [`docs/design.md`](./docs/design.md)（产品模型、协议矩阵、Mesh、KiwiVM）
- 发布规则（版本号 patch+1、必须推送 GitHub）：[`docs/RELEASING.md`](./docs/RELEASING.md)
- 开发规则书：[`AGENTS.md`](./AGENTS.md)
- 协议插件：[`docs/superpowers/specs/2026-08-21-protocol-plugin-design.md`](./docs/superpowers/specs/2026-08-21-protocol-plugin-design.md)
- 多协议：[`docs/superpowers/specs/2026-08-21-multi-protocol-design.md`](./docs/superpowers/specs/2026-08-21-multi-protocol-design.md)
- Mesh 组网：[`docs/superpowers/specs/2026-08-21-mesh-design.md`](./docs/superpowers/specs/2026-08-21-mesh-design.md)
- 加固：[`docs/superpowers/specs/2026-08-19-geoproxy-server-hardening-design.md`](./docs/superpowers/specs/2026-08-19-geoproxy-server-hardening-design.md)

## 特点

- 菜单优先，CLI 为辅
- **可自升级管理脚本**（`upgrade self`）与 **sing-box 核心**（`upgrade core`）
- 自动下载最新稳定版 sing-box（不锁定 sing-box 版本号）
- **IPv4 / IPv6 自适应** 监听与分享 URL（节点名在 `#fragment`）
- 自签 TLS（按协议）；TUIC 默认 UUID=密码、BBR
- 入站协议可切换（`change protocol` / `protocols`）
- **Mesh**：随主服务开机；首台为 Master，成员用 `GPS_MESH_MASTER`+`GPS_MESH_TOKEN` 加入；`change mesh-exit` 跳板
- systemd：`geoproxy-tuic` + **KiwiVM 流量定时检查**（默认 80% 告警 / 95% 停服）
- 默认日志 **debug**（可见进站/出站）

## 要求

- root、systemd、amd64/arm64
- 可访问 GitHub Releases（sing-box / 本仓库）与 `api.64clouds.com`（流量熔断）
- curl ≥ 7.55（mesh 请求经 header 文件传 TOKEN）；python3、openssl（mesh 与校验需要）

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

# 凭证写入 /etc/geoproxy-kiwivm.env，卸载后仍保留；重装会自动恢复
# 彻底忘掉凭证：geoproxy-server uninstall --purge

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

## TUIC / 分享链接

节点名写在 URL **fragment**（`#` 后面）。TUIC 示例：

```text
tuic://UUID:PASSWORD@IP:PORT/?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr&udp_relay_mode=native#tile1.spacexway.com
```

其它协议由 `geoproxy-server url` 按当前 `PROTOCOL` 生成（如 `hy2://`、`vless://`、`trojan://`、`ss://`）。

```bash
geoproxy-server protocols
geoproxy-server change protocol hysteria2
geoproxy-server change name tile1.spacexway.com
geoproxy-server url
```

## CLI

```text
geoproxy-server install | uninstall | status | start | stop | restart
geoproxy-server info | url | qr | log | doctor | bbr | protocols | mesh
geoproxy-server upgrade [self|core|all]
geoproxy-server change …
geoproxy-server traffic [status|check|resume]
geoproxy-server version
```

## Mesh 组网（开机自动 + Master 发现，控制面 TLS）

Master 登记面默认监听 `0.0.0.0:19527/tcp`（自签 TLS）。升为 Master / 安装 / `mesh ensure` 时脚本会
**自动放行本机防火墙 TCP 19527**（活动的 ufw → firewalld → iptables → nft）。这是组网控制面，
不是代理端口，也不是 WG `51820`。云厂商安全组脚本改不了，需在控制台同样放行，否则 Node 会
`Connection timed out`。加入命令内含证书公钥指纹（`GPS_MESH_TLS_PIN`），节点端
`curl --pinnedpubkey` 钉扎，TOKEN 不明文过网。

```bash
# 首台（Master）— 普通安装即可
bash install.sh
# 安装结束会打印加入命令（https 地址 + TLS 指纹 + TOKEN）

# 其它节点（Member）— 直接粘贴 Master 打印的整行
GPS_MESH_MASTER=https://MASTER_IP:19527 GPS_MESH_TLS_PIN=sha256//... GPS_MESH_TOKEN=... bash install.sh

# 排障
geoproxy-server mesh show
geoproxy-server mesh export

# 可选：指定 L3 出口跳板
geoproxy-server change mesh-exit <node_id>
```

自 v0.2.33 起拒绝向**非本机** Master 发起明文 `http://` 注册（TOKEN/公钥会明文过网）。
旧成员升级后请重新执行上面临入流程；仅 loopback 明文仍放行（排障用）。

## 路径

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/geoproxy-server` | 入口 |
| `/etc/geoproxy-server/state.env` | 状态（含 KiwiVM，600） |
| `/etc/geoproxy-server/mesh/peers.json` | 组网 peers |
| `/etc/geoproxy-server/mesh/master.env` | 仅 Master：登记服务专用凭证（600） |
| `/etc/geoproxy-server/mesh/master-tls.*` | 仅 Master：控制面自签证书与指纹 |
| `/var/log/geoproxy-server/sing-box.log` | 代理日志 |
| `/var/log/geoproxy-server/traffic.log` | 熔断日志 |
| `geoproxy-tuic.service` | 代理（含 mesh ensure） |
| `geoproxy-mesh-master.service` | 仅 Master：登记 API |
| `geoproxy-mesh-sync.timer` | 周期注册/拉 peers |
| `geoproxy-traffic.timer` | 流量检查 |
