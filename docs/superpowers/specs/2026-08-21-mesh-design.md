# GeoProxy Mesh Design (Always-on WG + Master Discovery)

## Goal

每台 VPS 随 `geoproxy-tuic` **开机即带 WireGuard mesh**；集群中恰好一台 **Master** 做节点登记与 peer 下发，成员开机自动注册并拉取名单。数据面去中心（WG 全互连）；Master 不转发业务流量。

| Version | Scope |
|---------|--------|
| **v0.2.24** | 手工 peers / PROFILE 门控的 WG（过渡） |
| **v0.2.25** | Always-on mesh + Master HTTP 登记 + sync timer |

## Product invariants

1. One sing-box process per host（入站 + WG endpoint）。
2. 组网默认开启；无需 `mesh init` / `change profile`。
3. 控制面：仅 Master 跑 `geoproxy-mesh-master`（HTTP + token）。
4. Hardening（JSON escape、atomic state、checksum 升级、KiwiVM）不变。
5. Master 宕机：已有 peers 的节点继续互通；新节点无法加入直至恢复。

## Roles

| Role | Install | Control plane |
|------|---------|---------------|
| **master** | 无 `GPS_MESH_MASTER` | enable `geoproxy-mesh-master`；token 自动生成 |
| **member** | `GPS_MESH_MASTER` + `GPS_MESH_TOKEN` | 不启 master unit；`mesh ensure` 注册+拉 peers |

## Discovery API

- Listen: `0.0.0.0:19527`（`MESH_MASTER_PORT` / `GPS_MESH_MASTER_PORT`）
- Auth: `Authorization: Bearer <MESH_CLUSTER_TOKEN>`
- `POST /v1/register` — upsert；overlay 冲突则 Master 分配；响应含 peers 快照
- `GET /v1/peers` — 完整 `peers.json` schema
- `GET /v1/health` — 无鉴权

实现：`scripts/mesh_master.py`。

## Boot sequence

1. `geoproxy-tuic` `ExecStartPre=-… mesh ensure`
2. ensure：密钥 / overlay →（member）register+pull → 写 `config.json`
3. sing-box 启动
4. `geoproxy-mesh-sync.timer`（默认 60s）→ `mesh sync-master`

## WireGuard overlay

- Prefix default: `10.66.0.0/16`
- Master 默认 overlay：`10.66.0.1`
- Endpoint tag: `wg-ep`
- Peer `allowed_ips`：peer `/32`；仅当 `MESH_EXIT_NODE_ID` 指向该 peer 时附加 `0.0.0.0/0`

## Peer schema

同 v0.2.24：`/etc/geoproxy-server/mesh/peers.json`（schema=1）。Token 文件：`mesh/token`。

## Multi-hop / anti-loop

与 v0.2.24 相同：`change mesh-exit`；禁止 exit=自己；至多一个 default-route peer。

## CLI

```text
geoproxy-server mesh ensure | sync-master | show | export | import | sync | peer | hop
# 安装成员:
GPS_MESH_MASTER=http://IP:19527 GPS_MESH_TOKEN=... bash install.sh
geoproxy-server change mesh-exit <node_id|none>
```

## Non-goals (this version)

- Master HA / 多 Master
- DHT、无 Master 公网发现
- Tailscale/Headscale
- 默认把 Master 当流量跳板
