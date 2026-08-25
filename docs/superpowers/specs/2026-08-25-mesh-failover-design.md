# GeoProxy Server mesh 出口自动故障切换（mesh-failover）设计

## Goal

在已有 WireGuard mesh 自动组网（v0.2.25+）之上，为每台机器增加**本机直连优先、故障自动切换对端出口**的能力：平时零隧道流量开销，本机公网出口故障时自动借道对端出口兜底，恢复后自动回切。同时严格控制流量成本——**隧道流量走公网、会双倍计入两端 VPS 配额**，因此默认策略必须是"本机直连优先"，活跃均衡仅作为后续可选增强。

## 背景与现状（v0.2.40）

- 每台 VPS 一个 sing-box 实例；默认 `TUIC → direct`；mesh 组网随主服务开机启用（WireGuard overlay，默认网段 `10.66.0.0/16`）。
- 现有 mesh 能力：自动发现、心跳（180s 过期）、在线节点自动写入 `wg-ep` 出站；`change mesh-exit <node_id>` 提供"默认路由全走对端"的单选跳板（有防环，仅允许一个 exit）。
- 当前 `route.final` 写死为 `direct`（本机公网出口），**没有出口故障切换/自动兜底能力**。
- 流量监控 `traffic.sh`（KiwiVM）按单机独立统计与熔断，无跨机共享池。

## 流量成本模型（设计前提）

WireGuard 隧道走公网 UDP 51820，隧道内流量在两台 VPS 上**各自计入公网流量配额**。客户端经 A 机下载 1GB 时：

| 出口方式 | A 机计数 | B 机计数 | 合计 |
|---|---|---|---|
| A 本机直连 | 2GB | 0 | 2GB |
| A → WG 隧道 → B 出口 | 2GB | 2GB | 4GB |

**结论：跳板/隧道兜底会使总配额消耗翻倍。** 因此本设计默认"本机直连优先"，隧道仅在故障时启用（兜底），不做日常活跃均衡。

## 功能设计

### 行为

- 开启后，每台机器出口变为自动探测组：`{ 本机 direct, WG 隧道 wg-ep → 对端出口 }`。
- 本机直连可用（探测延迟最低）→ 100% 走本机，隧道闲置，零额外计费。
- 本机直连探测失败 → 约 30~60s 内自动切到隧道走对端出口；本机恢复后自动回切。
- 仅当 peers 中存在 ≥1 个在线节点时才把 `wg-ep` 纳入探测组；单机/无在线 peer 时组内只有 `direct`（等价于现状）。

### 配置接口

```bash
geoproxy-server change mesh-failover on|off          # 开启/关闭，状态存 state.env（MESH_FAILOVER）
geoproxy-server change mesh-failover-probe <url>     # 可选：自定义探测地址（默认 gstatic generate_204）
geoproxy-server mesh show                            # 显示 failover 状态（含探测地址、目标组）
geoproxy-server doctor                               # 校验配置与渲染一致性
```

- 新增状态变量：`MESH_FAILOVER`（0/1，默认 0）、`MESH_FAILOVER_PROBE`（默认 `https://www.gstatic.com/generate_204`），写入 `state.env`（复用 `gps_env_assign` / `gps_atomic_write_env`）。
- **默认关闭**：探测地址在部分网络（如中国大陆 VPS 访问 gstatic）可能不可达，开启后会把直连误判为故障导致流量全切隧道（双倍计费）。必须显式开启。
- **与 `mesh-exit` 互斥**：`mesh-exit` 把默认路由全量指向对端（WG peer 内核层 allowed_ips 0.0.0.0/0），与 failover 组叠加会造成双跳/语义冲突。`change mesh-failover on` 时若 `MESH_EXIT_NODE_ID` 非空，报错并提示先 `change mesh-exit none`；`change mesh-exit` 设置时若 failover 已开启，同样报错并提示先关闭。

### 技术实现（改动集中在 `lib/mesh/wireguard.sh`）

`gps_mesh_outbounds_json()`：
- `MESH_FAILOVER=1` 且存在在线 peer 时，在 `direct` 之后追加 loadbalance 出站：

```jsonc
{
  "type": "loadbalance",
  "tag": "mesh-failover",
  "strategy": "url-test",
  "destinations": [
    { "outbound": "direct" },
    { "outbound": "wg-ep" }
  ],
  "url": "<MESH_FAILOVER_PROBE>",
  "interval": "30s",
  "tolerance": 0
}
```

`gps_mesh_route_json()`：
- `MESH_FAILOVER=1` 时 `final` 从 `direct` 改为 `mesh-failover`。
- 新增**防环规则**置于规则列表最前：`source_ip_cidr: [<MESH_OVERLAY_PREFIX>]` → `direct`。语义：凡来源是 overlay 网段（即从 WG 隧道进来的）的流量，到本机后强制走本机自己的 `direct` 出口，绝不再扔回隧道——从根上杜绝 A↔B 探活/兜底流量循环。
- 现有 `ip_cidr: [<MESH_OVERLAY_PREFIX>] → wg-ep`（overlay 目标走隧道）保持不变，两条规则按"来源判定"与"目标判定"并存，互不冲突。

探测地址仅在本机直连探测路径上使用；对端收到隧道内探测流量后按防环规则直接 `direct` 出公网，因此探测结果代表"本机直连的真实可达性"，不会被对端转发干扰。

## 边界与错误处理

- `change mesh-failover on` 前置校验：`MESH_EXIT_NODE_ID` 为空；`GPS_MESH_PEERS` 中存在非本机在线节点（否则 warn 提示"无对端可兜底"，但仍允许开启——未来加节点后自动生效）。
- 探测地址校验：必须是 `http://` 或 `https://` 开头的合法 URL（单行，无换行/控制字符），拒绝空串与非法值。
- 配置渲染失败（如 sing-box check 失败）沿用现有 `gps_write_config` 的失败处理，不写坏 `config.json`，服务保持旧配置。
- 回切抖动：url-test 由 sing-box 内建处理（interval 内连续失败才切换，恢复后延迟最优即回切），无需自研抖动抑制。

## 测试（`tests/*.bats`）

1. `MESH_FAILOVER=1`（含在线 peer）：渲染含 `mesh-failover` loadbalance 组、`final` 指向它、防环 `source_ip_cidr` 规则存在且位于最前。
2. `MESH_FAILOVER=0`：渲染与现状逐字一致（防回归，diff 断言）。
3. `MESH_FAILOVER=1` 但无在线 peer：组内只有 `direct`，不含 `wg-ep`。
4. `change mesh-failover on` 与 `mesh-exit` 互斥：双向校验报错，状态不变。
5. `change mesh-failover-probe`：合法 URL 生效；非法/含控制字符拒绝。
6. `change mesh-failover on|off` 状态切换落盘 `state.env`（MESH_FAILOVER=1/0），关闭后渲染回退现状。

测试遵循项目规则：先写失败用例（红）再实现（绿）；修 bug 先写用例。

## 版本与发布

- 版本：`v0.2.40` → `v0.2.41`（patch+1，遵守 AGENTS.md 版本规则）。
- 同步更新：`VERSION`、`CHANGELOG.md`（顶部追加 `## v0.2.41 - 2026-08-25`）、`README.md`（mesh 能力说明与 `change mesh-failover` 用法）。
- 门禁：`bats --tap tests` 全绿、shellcheck 无 error、shfmt 无漂移。
- 提交并推送 `main`，打 tag `v0.2.41` 并推送，Release 由 GitHub Actions 自动创建（不手动建）。

## 明确不做（YAGNI）

- 活跃均衡（url-test 延迟均衡、双机流量分摊）——双倍计费，违背本设计前提，留作未来可选增强。
- KiwiVM 配额信号驱动切换（"超限→切对端"）——`traffic.sh` 已有熔断信号，未来可在本设计基础上叠加，首版不做。
- 按目标站点分流（geo/URL 级出口选择）——需更复杂的规则体系，非本设计范围。
- clash_api / 运行时零中断切换——引入本地 API 面与安全面，成本高，首版用配置重载（`gps_restart_svc`）即可。

## Verification

- 每项测试先演示现状行为，再在实现后通过（红→绿）。
- 最终门禁：`bash -n`、ShellCheck、shfmt、`bats --tap tests`、`git diff --check`。
