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
- **Mesh**：随主服务开机；首台为 Master，成员用 `GPS_MESH_MASTER`+`GPS_MESH_TOKEN` 加入；`change mesh-exit` 跳板；`change mesh-failover` 出口故障自动切换（本机直连优先 + 对端兜底）
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

## 上报 Agent（v2rayA 节点池）

随主服务安装默认启用 `geoproxy-agent.service`（默认监听 `0.0.0.0:19528/tcp`，Bearer Token 鉴权，供 v2rayA 远程节点池访问），
供 v2rayA 客户端"节点池"功能轮询流量状态与远程控制：

- 契约：[`docs/geoproxy-agent-api.md`](./docs/geoproxy-agent-api.md)
- 查看/复制 Token（供 v2rayA 池成员配置）：

```
geoproxy-server agent
geoproxy-server agent token
geoproxy-server change agent-bind 127.0.0.1   # 可选收紧为仅本机（v2rayA 远程将无法访问）
```

- 旧版升级后 agent 未就绪时执行 `geoproxy-server agent ensure`（幂等重建凭证与单元；`upgrade` 已自动调用）。

- v2rayA 池成员填写：Agent 地址 `http://<本机IP>:19528` + 上述 Token（当前仅 HTTP，勿填 https）；
  未配置 KiwiVM 时 `usedPct=0`，客户端仅做延迟均衡；配置 KiwiVM 后流量硬门槛（默认 90%）生效。
- 防火墙已自动放行 19528（ufw/firewalld/iptables/nft）；云厂商安全组需在控制台同样放行。
- 熔断阈值/恢复语义（`traffic trip`、`traffic resume` 等）见上文[流量熔断（KiwiVM）](#流量熔断kiwivm)章节。

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
geoproxy-server mesh port-checklist   # 防火墙端口清单（菜单 30）
geoproxy-server mesh migrate-tls        # Member：修复 http/PIN/连通性
geoproxy-server mesh token rotate       # Master：轮换集群 TOKEN
geoproxy-server mesh webhook set-secret # Master：GitHub Release 自动升级 webhook
geoproxy-server mesh webhook show       # Master：webhook URL 与配置说明
geoproxy-server mesh export

# 可选：指定 L3 出口跳板
geoproxy-server change mesh-exit <node_id>

# 可选：WG MTU（默认 1408；路径受限/大包黑洞时调小）
geoproxy-server change mesh-mtu 1380

# 可选：出口故障自动切换（默认关闭；本机直连优先，故障时自动切对端出口兜底，恢复后回切）
geoproxy-server change mesh-failover on
geoproxy-server change mesh-failover off

# 可选：自定义故障探测地址（默认 https://www.gstatic.com/generate_204）
geoproxy-server change mesh-failover-probe <url>
```

`mesh-exit` 与 `mesh-failover` 可组合：urltest 在「本机直连 ↔ exit 隧道」间择优（tolerance 100ms，不掐断存量连接）。
`mesh-exit` 自带数据面健康门禁：以 sing-box 握手成败为证据，连续失败自动暂停出口路由（流量回落本机 direct，
冷却后自动重试），隧道死掉不再黑洞全部流量。
mesh 目的地路由只匹配 peers 实际持有的 overlay /32（不再整段劫持 `10.66.0.0/16`）。
每台机器依然只跑 **一个** sing-box 实例，探测组与防环规则都在同一个实例内完成。

自 v0.2.33 起拒绝向**非本机** Master 发起明文 `http://` 注册（TOKEN/公钥会明文过网）。
旧成员升级后请重新执行上面临入流程；仅 loopback 明文仍放行（排障用）。

### GitHub Release 自动升级（Master）

发布新版本后，可在 GitHub 仓库 **Settings → Webhooks** 配置 webhook，让 Master 节点自动执行 `upgrade self`，无需逐台 SSH。

```bash
# 1) Master 上生成并保存 webhook secret（写入 state.env + master.env）
geoproxy-server mesh webhook set-secret
# 或指定 secret：mesh webhook set-secret 'your-long-random-secret'

# 2) 查看要填到 GitHub 的 URL 与说明
geoproxy-server mesh webhook show
```

GitHub Webhook 配置要点：

| 项 | 值 |
|----|-----|
| Payload URL | `https://<Master域名或IP>:19527/v1/hook/github`（与 join 命令同 host，TLS 自签） |
| Content type | `application/json` |
| Secret | 与 `mesh webhook set-secret` 输出一致 |
| 事件 | **Release** → 勾选 **Published**（推荐） |

校验：`X-Hub-Signature-256` HMAC SHA256；secret 仅存于 `master.env`（600），不进 argv。

**Member 集群自动升级（v0.2.65+）**：GitHub Release → Master webhook 写入 `cluster-version.json` 并自升级；Member 每 `mesh-sync`（默认 60s）注册时读取 `cluster.target_version`，若与本地脚本版本不一致则自动 `upgrade self --ver <tag>`。关闭：`geoproxy-server change cluster-auto-upgrade off`。

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
