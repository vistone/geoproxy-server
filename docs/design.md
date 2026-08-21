# GeoProxy Server 设计说明

## 产品模型

- 每台 VPS **一个** sing-box 实例。
- 入站由协议插件渲染，出站固定为 `direct`（出口节点，不是客户端分流器）。
- **当前（v0.2.21 / Phase 0）** 已注册协议仅有 **TUIC**；`state.env` 中 `PROTOCOL` 缺省为 `tuic`（旧安装无该字段时同样按 tuic 加载）。
- 运维骨架（双栈监听、自签 TLS、KiwiVM 熔断、自升级与核心校验、输入/JSON/state 加固）与具体协议解耦。

协议插件设计：[`docs/superpowers/specs/2026-08-21-protocol-plugin-design.md`](./superpowers/specs/2026-08-21-protocol-plugin-design.md)
Phase 0 实施计划：[`docs/superpowers/plans/2026-08-21-protocol-plugin-phase0.md`](./superpowers/plans/2026-08-21-protocol-plugin-phase0.md)

后续阶段（未实施）：Hysteria2 / VLESS+Reality 等服务端入站；明确不支持将本产品改造成 tun/tproxy 客户端。

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
