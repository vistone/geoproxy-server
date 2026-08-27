# Task 2 报告：sing-box 配置渲染（loadbalance 组 + 防环规则）

- 分支：`feat/mesh-failover`（HEAD 前置：`ff149d80`）
- 日期：2026-08-25
- 状态：DONE

## 变更内容

- `lib/mesh/wireguard.sh`
  - `gps_mesh_route_json`：`final` 在 `MESH_FAILOVER=1` 且 `gps_mesh_has_live_peer` 成功时指向 `mesh-failover`，否则保持 `direct`；`route.rules` 恒为 `[{source_ip_cidr: [prefix] → direct}, {ip_cidr: [prefix] → wg-ep}]`，source 防环规则置顶。
  - `gps_mesh_outbounds_json`：`MESH_FAILOVER=1` 且存在在线 peer 时，在 `direct` 之后插入 `loadbalance`（`strategy: url-test`）探测组，destinations = {direct, wg-ep}，url 用 `MESH_FAILOVER_PROBE`（默认 gstatic `generate_204`），interval 30s、tolerance 0；`MESH_L7_OUTBOUNDS_JSON`（extra）分支保持不变且组合后 JSON 合法。
- `tests/test_mesh_failover.bats`：按 brief 追加 3 个渲染用例（failover off 防环规则 / failover on loadbalance+顺序 / 无 peer 保持 direct-only）。

### 与 brief 的唯一差异

- brief 中 `failover=$(cat <<EOF ... EOF)` 原样写法不满足项目 shfmt 门禁（`shfmt -d` 报漂移），按 shfmt 规范改为 `failover=$(\n\t\t\tcat <<EOF ... EOF\n\t\t)`。heredoc 内容逐字不变（JSON 输出与 brief 语义完全等价），shellcheck 0 error、shfmt 无漂移、`bash -n`、`git diff --check` 均通过。

## TDD 过程

### 红阶段（Step 2）

`bats --tap tests/test_mesh_failover.bats`（追加测试后、实现前）：

```
1..8
ok 1 failover defaults are off with standard probe
ok 2 has_live_peer is false without peers
ok 3 has_live_peer is true with an online peer
ok 4 has_live_peer honors fresh and stale last_seen
ok 5 state persists failover variables
not ok 6 failover off renders legacy outbounds and route with anti-loop rule
#   `grep -q 'source_ip_cidr' "$GPS_CONFIG"' failed
not ok 7 failover on renders loadbalance group, final and anti-loop order
#   `grep -q '"tag": "mesh-failover"' "$GPS_CONFIG"' failed
ok 8 failover on without peers keeps direct-only final
```

说明：用例 6/7 按预期失败（无 `source_ip_cidr`、无 loadbalance 组）。用例 8 在现状下即通过（无 peer 时 final 本就是 direct），作为防过度渲染的回归护栏保留。

### 绿阶段（Step 4）

实现后 8/8 全绿：

```
1..8
ok 1 failover defaults are off with standard probe
ok 2 has_live_peer is false without peers
ok 3 has_live_peer is true with an online peer
ok 4 has_live_peer honors fresh and stale last_seen
ok 5 state persists failover variables
ok 6 failover off renders legacy outbounds and route with anti-loop rule
ok 7 failover on renders loadbalance group, final and anti-loop order
ok 8 failover on without peers keeps direct-only final
```

### 回归（Step 5，串行执行）

`bats --tap tests/test_mesh.bats` → 27/27 PASS
`bats --tap tests/test_mesh_tls.bats` → 6/6 PASS

既有测试未与新增 source 防环规则顺序冲突（Step 5 风险项未触发；若触发，按 brief 优先保证防环语义、source 规则在最前）。

## 自审发现

1. **shfmt 漂移**（见上）：brief 逐字代码不满足项目 shfmt 门禁，已按规范形式重排，heredoc 输出逐字不变；重排后重跑 failover 用例确认仍全绿。
2. **extra（L7 outbounds）分支组合**（测试未覆盖）：手工渲染 4 种组合（failover × extra）均验证 `python3 -m json.tool` 通过，JSON 合法：
   - failover=1 + extra：loadbalance 组 + l7hop 并存；
   - failover=1 无 extra：`"final": "mesh-failover"`；
   - failover=0 + extra：仅 direct + l7hop；
   - failover=0 无 extra：`"final": "direct"`。
3. **`gps_mesh_has_live_peer` 调用点顺序**：`gps_mesh_route_json`/`gps_mesh_outbounds_json` 在文件中位于 `gps_mesh_has_live_peer` 之前，但 Bash 在调用时解析，且整个文件先被 source，无顺序问题（Task 1 既有测试已覆盖该函数）。
4. **无 peer 时零开销**：`MESH_FAILOVER=1` 但无在线 peer 时 loadbalance 组不渲染、final 保持 direct，与现状一致（等价于未开启），符合 brief「无在线 peer 时等价于现状」约束。

## 门禁（AGENTS.md）

- `bash -n lib/mesh/wireguard.sh` → OK
- `shellcheck -x lib/mesh/wireguard.sh` → 0 error
- `shfmt -d lib/mesh/wireguard.sh` → 无漂移
- `git diff --check` → 干净
- 未跑全量 `bats --tap tests`（Task 2 仅要求相关 + 回归；全量留待最终门禁阶段）

## 审查修复（Task 2 审查，HEAD fb0a818）

- 状态：DONE（2026-08-25）
- 提交：`fix: probe URL 渲染前 gps_json_escape 转义 + state 回载断言`

### 变更

1. **Important — `lib/mesh/wireguard.sh` `gps_mesh_outbounds_json` probe 转义**：`MESH_FAILOVER_PROBE` 将来可由 CLI/state.env 手工篡改，含 `"`、`\` 的 URL 会破坏 JSON。在 `local probe=${MESH_FAILOVER_PROBE:-...}` 之后、插入 heredoc 之前加 `probe=$(gps_json_escape "$probe")`，与同文件 `prefix=$(gps_json_escape ...)`（route 渲染）惯例一致；heredoc 中 `"url": "${probe}"` 保持逐字不变（变量已转义）。`$(...)`/反引号经变量展开插入时本就不被重扫描（无命令替换），`gps_json_escape` 负责 `"`/`\`/控制字符，保证 JSON 结构合法。
2. **Minor — `tests/test_mesh_failover.bats` "state persists failover variables" 回载断言**：grep 写入断言之后补 `unset MESH_FAILOVER MESH_FAILOVER_PROBE` → `load_state` → 断言两变量值正确（往返语义，不依赖 shell 残留），与 plan 原设计一致。

### 验证

- `bats --tap tests/test_mesh_failover.bats` → 8/8 PASS（含改造后的用例 5）
- `shellcheck -x lib/mesh/wireguard.sh` → 0 error；`shfmt -d lib/mesh/wireguard.sh tests/test_mesh_failover.bats` → 无漂移；`bash -n`、`git diff --check` → OK
- python3 转义渲染验证（测试环境 harness，未改测试用例）：构造特殊字符 probe 跑 `gps_write_config` 后 `python3 -m json.tool` 均通过：

```
JSON VALID  probe: https://x.example/$(id)"
  decoded url: 'https://x.example/$(id)\"'
JSON VALID  probe: https://x.example/$(id)"`echo pwned`\evil
  decoded url: 'https://x.example/$(id)\"`echo pwned`\\\\evil'
ALL VERIFIED
```

- `$(id)`、反引号载荷保持字面（不执行），`"` 不再破坏 JSON 结构。

### concerns

- **gps_json_escape 既有双倍转义**：`gps_json_escape` 对 `\` 输出 4 个反斜杠、对 `"` 输出 `\\\"`（3 反斜杠+引号），超出标准 JSON 转义一倍；解码后值会多出反斜杠（如上 decoded url 中 `"` → `\\"`、`\` → `\\\\`）。JSON 始终合法，probe 为管理员配置（非攻击者输入），影响仅是值保真度。该行为是共享函数既有实现（private key/prefix 等调用点因不含 `\`/`"` 未受影响），本次按要求直接复用，未改动 `gps_json_escape` 本身；若后续要求解码值精确往返，应单独修该函数并加单测。
- 未跑全量 `bats --tap tests`（本修复仅触及 wireguard.sh 渲染分支与一个用例断言，failover 套件 + 静态门禁已覆盖；全量留待最终门禁阶段）。
