# Task 3 报告：CLI（`change mesh-failover` / `mesh-failover-probe` / mesh-exit 互斥）

- 状态：**DONE**
- Commit：`405e2d7fbc856e6c185893a57840ba2286ca445e`（分支 `feat/mesh-failover`，仅含 `lib/cmd.sh` 与 `tests/test_mesh_failover.bats`）
- 日期：2026-08-25

## 做了什么

按 brief 逐字实现（TDD 红 → 绿 → 提交）：

1. **追加 5 个 CLI 测试**（`tests/test_mesh_failover.bats`，先逐字使用 brief 代码；其中 3 处因 brief 与既有 state 机制不符做了最小修正，见「自审发现」）：
   - `change mesh-failover on persists state and renders`：on 后 state 持久化 `MESH_FAILOVER=1` 且渲染 `"final": "mesh-failover"`
   - `change mesh-failover off restores legacy rendering`：off 后 state 归 0 且配置不再含 `mesh-failover`
   - `change mesh-failover on conflicts with mesh-exit`：已有 mesh-exit 时拒绝开启 failover，输出含「冲突」
   - `change mesh-exit conflicts with failover on`：failover 已开启时拒绝设置 mesh-exit，输出含「冲突」
   - `change mesh-failover-probe validates url and persists`：合法 URL 持久化；`ftp://bad`、含换行 URL 均拒绝

2. **`lib/cmd.sh`**（实现逐字使用 brief 代码）：
   - `mesh-exit` 分支内、`[[ $eid != "${NODE_ID:-}" ]] || err "不能将自己设为 mesh-exit（防环）"` 之后插入互斥校验（仅对非 none 设置生效，`mesh-exit none` 仍可清除）：
     ```bash
     [[ ${MESH_FAILOVER:-0} != 1 ]] || err "与 mesh-failover 冲突：请先 change mesh-failover off 再设置 mesh-exit"
     ```
   - `mesh-exit` 分支之后新增两个 case 分支（逐字）：
     - `mesh-failover | failover`：校验 `on|off|1|0`；on 时校验 `MESH_EXIT_NODE_ID` 为空（冲突则 `err`，消息含「冲突」），无在线对端时 `warn` 提示；设置 `MESH_FAILOVER` → `gps_write_config; save_state; gps_restart_svc` → 输出 `mesh-failover → 1/0`。
     - `mesh-failover-probe | failover-probe`：校验非空、`gps_validate_single_line`（挡换行/回车/NUL）、`http(s)://` 前缀；设置 `MESH_FAILOVER_PROBE` → 同上保存 → 输出探测地址。
   - `change` 兜底用法行追加 `mesh-failover|mesh-failover-probe`。

## 测试输出

**红（Step 2，追加测试后、实现前）** `bats --tap tests/test_mesh_failover.bats`：

```
1..13
ok 1 .. ok 8   （既有 8 例全过）
not ok 9  change mesh-failover on persists state and renders
#   `gps_cmd_change mesh-failover on' failed        （err: 用法: change port|uuid|... 未知参数）
not ok 10 change mesh-failover off restores legacy rendering
#   `gps_cmd_change mesh-failover off' failed       （同上）
not ok 11 change mesh-failover on conflicts with mesh-exit
#   `[[ "$output" == *冲突* ]]' failed              （err 输出为用法行，无「冲突」）
not ok 12 change mesh-exit conflicts with failover on
#   `[ "$status" -ne 0 ]' failed
not ok 13 change mesh-failover-probe validates url and persists
#   `gps_cmd_change mesh-failover-probe ...' failed （未知参数）
```

与 brief Step 2 预期一致：新增 5 例 FAIL（`change` 未知参数报错），既有 8 例 PASS。

**绿（Step 4，实现后）**：

```
1..13
ok 1  failover defaults are off with standard probe
ok 2  has_live_peer is false without peers
ok 3  has_live_peer is true with an online peer
ok 4  has_live_peer honors fresh and stale last_seen
ok 5  state persists failover variables
ok 6  failover off renders legacy outbounds and route with anti-loop rule
ok 7  failover on renders loadbalance group, final and anti-loop order
ok 8  failover on without peers keeps direct-only final
ok 9  change mesh-failover on persists state and renders
ok 10 change mesh-failover off restores legacy rendering
ok 11 change mesh-failover on conflicts with mesh-exit
ok 12 change mesh-exit conflicts with failover on
ok 13 change mesh-failover-probe validates url and persists
```

说明：brief 预期「12 个用例全部 PASS」；实际文件既有 8 例 + 新增 5 例 = **13 例**，全部 PASS（brief 的 12 为计数偏差）。

**门禁**：

- `bats --tap tests`：**135/135 PASS**（`not ok` 计数为 0，全量回归无破坏）
- `shellcheck -x lib/cmd.sh`（CI 同款：`git ls-files '*.sh' | xargs shellcheck -x`）：rc=0（零发现；`.bats` 不在 CI lint 范围）
- `shfmt -d lib/cmd.sh tests/test_mesh_failover.bats`：无漂移
- `bash -n lib/cmd.sh`：PASS
- `git diff --check`：PASS

## 自审发现

1. **brief 测试 1/2/5 的 state 断言带引号与实际格式不符**：`gps_save_state_unlocked` 用 `gps_env_assign`（`printf '%s=%q\n'`）写 state.env，实测简单值**不带引号**（`MESH_FAILOVER=1`、`MESH_FAILOVER_PROBE=https://www.google.com/generate_204`）。brief 的 `grep -q '^MESH_FAILOVER="1"'` / `'^MESH_FAILOVER="0"'` / `'^MESH_FAILOVER_PROBE="..."'` 硬性要求引号，实现后仍失败。修正为与既有 Task 1 用例同款宽松匹配 `grep -Eq '^MESH_FAILOVER="?1"?$'`（断言意图不变：持久化的值正确）。
2. **brief 测试 3/4 的互斥场景未真正触发**：`gps_cmd_change` 入口 `load_state`（重载 state.env）会把测试 shell 里刚设的 `MESH_EXIT_NODE_ID=tile-exit` / `MESH_FAILOVER=1` 覆盖为 state 中的默认值（实测：`tile-exit` → 空、`1` → `0`），互斥校验永远看不到冲突值。修正为设置后先 `save_state` 持久化（与真实 CLI 场景一致：互斥校验面向**已持久化**的 state），断言行保持不变。
3. **count 偏差**：brief 预期「12 用例全 PASS」，实际 8 既有 + 5 新增 = 13。属 brief 计数笔误，不影响语义。
4. **互斥校验只拦「设置非 none」**：`mesh-exit none` 在 failover 开启时仍允许（可先清除 exit 再开 failover），与 err 文案「请先 change mesh-exit none 再开启 mesh-failover」呼应，符合 brief 双向互斥意图。
5. **无在线 peer 的 warn 路径**：`change mesh-failover on` 在无 live peer 时打印 `warn`（stderr），不影响返回值与持久化；测试 9 的 peer 无 `last_seen`（兜底视为可用），未触发该分支，属正常。

## 遇到的问题

- **无阻塞问题**。唯一需要偏离 brief 的是上面 3 处测试写法与既有 state 机制不符（`%q` 不带引号、`load_state` 入口重载），均为 brief 测试代码缺陷而非实现缺陷；实现代码逐字采用 brief，互斥逻辑经修正后的用例真实命中。
- 环境说明：bats / shellcheck / shfmt 位于 `~/.local/bin`，shfmt v3.13.1 与 CI 固定版本一致；测试串行执行（brief 要求），未并行。
