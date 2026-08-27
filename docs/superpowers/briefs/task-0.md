# mesh-failover（本机直连优先 + 故障自动切换对端出口）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 WireGuard mesh 组网之上，为每台机器增加"本机直连优先、本机出口故障时自动切到对端出口兜底、恢复后自动回切"的能力，且平时零隧道流量开销。

**Architecture:** 在 sing-box 配置渲染层（`lib/mesh/wireguard.sh`）把出口从写死的 `direct` 改为"sing-box 原生 `loadbalance`（strategy: url-test）探测组 { direct, wg-ep }"，探测地址默认 gstatic `generate_204`；新增 `source_ip_cidr: [10.66.0.0/16] → direct` 防环规则（来自隧道的数据强制走本机直连，杜绝 A↔B 循环）。通过 `change mesh-failover on|off` 开关，状态持久化到 `state.env`。

**Tech Stack:** Bash, Bats, sing-box, WireGuard, python3（心跳判定）, ShellCheck, shfmt。

## Global Constraints

- 版本：`v0.2.40` → `v0.2.41`（只 patch+1，遵守 `AGENTS.md`）。
- `MESH_FAILOVER` 默认 `0`（必须显式 `change mesh-failover on` 开启）。
- 探测地址默认 `https://www.gstatic.com/generate_204`（`MESH_FAILOVER_PROBE`）。
- 与 `mesh-exit` 互斥（双向校验：开启 failover 时拒绝设置 mesh-exit，设置 mesh-exit 时拒绝开启 failover）。
- 防环规则 `source_ip_cidr: [<MESH_OVERLAY_PREFIX>] → direct` **始终渲染**并置于 rules 最前。
- 无在线 peer 时：loadbalance 组内只有 `direct`（等价于现状），`final` 保持 `direct`。
- 全量门禁：`bats --tap tests` 全绿、shellcheck 无 error、shfmt 无漂移、`bash -n`、`git diff --check`。
- 密钥/凭证不得写进进程 argv（本功能不新增凭证，遵守既有约定）。
- 每次提交前运行相关 bats；最终门禁前跑全量。

---

