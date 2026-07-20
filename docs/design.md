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
- 当 API 请求或响应解析失败时，保存错误信息但不熔断。
- 熔断期间，`start` 和 `restart` 被拒绝。必须执行
  `traffic resume`；该命令会重新校验实时用量低于停服阈值，才会清除熔断标记并启动服务。
