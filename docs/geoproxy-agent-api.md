# GeoProxy Agent API 契约

客户端（v2rayA 节点池）与 VPS 端 agent 的通信契约。agent 由 geoproxy-server 仓库按此实现。

- 监听：TCP `:19528`（与 mesh 控制面 `:19527` 独立）
- 鉴权：所有端点要求 `Authorization: Bearer <token>`
- 数据来源：KiwiVM 熔断状态（`TRAFFIC_TRIPPED` 等）+ sing-box 运行时 API（活跃连接数）+ 系统指标

## GET /v1/status

响应 200：

```json
{
  "node": { "id": "tile1.spacexway.com", "protocol": "tuic", "version": "0.2.40" },
  "system": { "load1": 0.35, "cpuPct": 5.2, "memUsedPct": 42.1, "activeConnections": 23 },
  "latency": { "target": "https://www.gstatic.com/generate_204", "ms": 18 },
  "traffic": {
    "usedBytes": 123456789,
    "quotaBytes": 1099511627776,
    "usedPct": 11.2,
    "warnPct": 80,
    "stopPct": 95,
    "nextReset": "2026-09-01T00:00:00Z",
    "tripped": false,
    "trippedAt": null,
    "checkSec": 300
  },
  "mesh": { "role": "master", "peerCount": 4 },
  "reportedAt": "2026-08-25T10:00:00Z"
}
```

- `traffic.usedPct = data_counter / (plan_monthly_data × monthly_data_multiplier)`
- `tripped` 对应 `TRAFFIC_TRIPPED=1`（KiwiVM 95% 熔断已停服）
- 鉴权失败返回 401；未就绪返回 503；客户端超时上限 10s

## POST /v1/control

请求体（`Content-Type: application/json`）：

| action | 附加字段 | 语义 |
|---|---|---|
| `trip` | 无 | 立即熔断（停止代理服务） |
| `resume` | 无 | 解除熔断并恢复服务（先验未超停服线） |
| `set-thresholds` | `warnPct`、`stopPct`（0-100） | 修改告警/停服阈值 |
| `set-check-interval` | `seconds`（≥60） | 修改 KiwiVM 检查间隔 |

响应 200 表示已接受；错误时返回 4xx/5xx + JSON `{"error": "..."}`。

## 客户端（v2rayA）验证路径

1. 在 v2rayA 中导入/添加 2 台以上 VPS 节点（TUIC 等）
2. 设置 → 节点池 → 新建：勾选节点，填 Agent 地址/Token，门槛默认 90%
3. mock agent 返回 `usedPct=95` → 观察该成员"已摘除"，balancer 只含其余成员
4. mock agent 返回 `usedPct=50` → 观察成员自动"在池"
5. 点击"熔断/恢复"→ agent 收到 `POST /v1/control`，UI 反馈成功/失败
6. 关闭 agent → 成员"离线"，但不被摘除（fail-open）
