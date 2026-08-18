# GeoProxy Server 设计说明

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
