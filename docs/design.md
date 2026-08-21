# GeoProxy Server 设计说明

## 产品模型

- 每台 VPS **一个** sing-box 实例；**一次只激活一个**入站协议（`PROTOCOL`）。
- **组网（v0.2.25+）**：随主服务开机启用 WireGuard mesh；**一台 Master** 做登记发现，其余为 Member。
- **默认协议仍为 TUIC**；可通过 `change protocol` / `install --protocol` 切换。

### 已注册入站协议

| 版本 | 协议 |
|------|------|
| v0.2.21+ | `tuic` |
| v0.2.22+ | `hysteria2` · `vless`（Reality）· `trojan` · `shadowsocks` |
| v0.2.23+ | `vmess` · `anytls` · `hysteria` · `naive` · `snell` · `shadowtls`（+ 内层 SS） |

### Mesh 组网（v0.2.25+）

- 规格：[`docs/superpowers/specs/2026-08-21-mesh-design.md`](./superpowers/specs/2026-08-21-mesh-design.md)
- 首台安装（无环境变量）→ `MESH_ROLE=master` + `geoproxy-mesh-master`
- 成员：`GPS_MESH_MASTER=http://IP:19527 GPS_MESH_TOKEN=...`
- 开机：`mesh ensure`（ExecStartPre）+ sync timer；CLI `mesh show|export` 排障
- L3 跳板：`change mesh-exit`；L7：`mesh hop`

### sing-box 能力对照（本产品启用范围）

| 模块 | 状态 |
|------|------|
| inbounds | 已插件化 |
| outbounds | `direct` + 可选 hop/`detour` |
| endpoints | 始终 WireGuard（mesh） |
| route | overlay→wg-ep |
| dns / services(DERP, realm) / Tailscale | 未默认启用（后续可选） |

### 明确不支持（非目标）

- 本机透明/虚拟网卡默认劫持：`tun` · `tproxy` · `redirect`（WG 用 endpoint，非系统全局 tun 抢路由）
- 非出口入站：`direct` inbound · `cloudflared`
- 对公网暴露的 `mixed` / `socks` / `http`
- Master 高可用 / DHT 无 Master 发现；默认不捆绑 Tailscale/Headscale

协议插件：[`docs/superpowers/specs/2026-08-21-protocol-plugin-design.md`](./superpowers/specs/2026-08-21-protocol-plugin-design.md)
多协议：[`docs/superpowers/specs/2026-08-21-multi-protocol-design.md`](./superpowers/specs/2026-08-21-multi-protocol-design.md)
Mesh：[`docs/superpowers/specs/2026-08-21-mesh-design.md`](./superpowers/specs/2026-08-21-mesh-design.md)

## KiwiVM 流量熔断

配置 `change kiwivm <veid> <api_key>` 后，`geoproxy-traffic.timer`
按 `TRAFFIC_CHECK_SEC`（默认 300 秒）调用 KiwiVM 的 `getServiceInfo`。
用量计算为：

```text
data_counter / (plan_monthly_data × monthly_data_multiplier)
```

- 达到 `TRAFFIC_WARN_PCT`（默认 80%）时，只记录告警。
- 达到 `TRAFFIC_STOP_PCT`（默认 95%）时，停止 `geoproxy-tuic` 并持久化
  `TRAFFIC_TRIPPED=1`。
- 月配额与重置时间来自 KiwiVM 字段 `plan_monthly_data`、`data_next_reset`
  （重置后 `data_counter` 归零，用量百分比回落）。
- 当 API 请求或响应解析失败时，保存错误信息但不熔断。
- 用量低于停服线时（含月流量重置后），`traffic check` 自动清除
  `TRAFFIC_TRIPPED` 并启动服务；`start`/`restart`/`upgrade core` 前也会尝试同样逻辑。
- 仍可用 `traffic resume` 手动恢复（会再验未超停服线）。
