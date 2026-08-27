# Task 1 报告：状态变量、默认值与在线对端判定

- 状态：**DONE**
- Commit：`714b66535cf1082f30ce2f9d14ddbd924343867c`（分支 `feat/mesh-failover`）
- 日期：2026-08-25

## 做了什么

按 brief 逐字实现（TDD 红 → 绿 → 提交）：

1. **新增测试** `tests/test_mesh_failover.bats`（4 个用例，逐字使用 brief 代码）：
   - `failover defaults are off with standard probe`：`MESH_FAILOVER=0`、`MESH_FAILOVER_PROBE=https://www.gstatic.com/generate_204`
   - `has_live_peer is false without peers`：仅本机条目时 `gps_mesh_has_live_peer` 返回非 0
   - `has_live_peer is true with an online peer`：存在非本机 peer 时返回 0
   - `state persists failover variables`：`save_state` / `load_state` 往返保持 `MESH_FAILOVER` 与 `MESH_FAILOVER_PROBE`

2. **`lib/mesh/_common.sh`**：`gps_mesh_defaults()` 在 `MESH_WG_LIVE_ONLY`（brief 引用行号 240）之后追加：
   - `MESH_FAILOVER=${MESH_FAILOVER:-0}`
   - `MESH_FAILOVER_PROBE=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}`

3. **`lib/common.sh`**：`gps_save_state_unlocked()` 在 `MESH_L7_OUTBOUNDS_JSON` 行后追加持久化：
   - `gps_env_assign MESH_FAILOVER "${MESH_FAILOVER:-0}"`
   - `gps_env_assign MESH_FAILOVER_PROBE "${MESH_FAILOVER_PROBE:-}"`

4. **`lib/mesh/wireguard.sh`**：文件尾部（`gps_mesh_outbounds_json` 之前）新增 `gps_mesh_has_live_peer()`，逐字使用 brief 代码：无参数；`MESH_PEER_STALE_SEC`（默认 180）与 `GPS_MESH_PEERS` 由既有全局提供；python3 判定非本机且心跳在线（或无心跳字段）的 peer，返回 0=存在、1=否则（含 peers 文件缺失 / JSON 解析失败）。

## 测试输出

**红（实现前）** `bats --tap tests/test_mesh_failover.bats`：

```
1..4
not ok 1 failover defaults are off with standard probe
#   `[ "$MESH_FAILOVER" = "0" ]' failed
# 行 30: MESH_FAILOVER: 未绑定的变量
ok 2 has_live_peer is false without peers
not ok 3 has_live_peer is true with an online peer
#   `[ "$status" -eq 0 ]' failed
# 监听模式 STACK_MODE=v4only → 0.0.0.0
# mesh init 完成 role=master node_id=tile-a overlay=10.66.0.1 wg_port=51820
# 公钥: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE=
ok 4 state persists failover variables
BW01: run 的 gps_mesh_has_live_peer 以 127（command not found）退出（×2）
```

与 brief 预期一致：测试 1 因 `gps_mesh_defaults` 未设默认值失败，测试 3 因 `gps_mesh_has_live_peer: command not found` 失败。BW01 警告为 `run` 对未定义命令的提示，实现后消失。

**绿（实现后）**：

```
1..4
ok 1 failover defaults are off with standard probe
ok 2 has_live_peer is false without peers
ok 3 has_live_peer is true with an online peer
ok 4 state persists failover variables
```

**门禁**：

- `bats --tap tests`：**126/126 PASS**（含新增 4 例；`not ok` 计数为 0）
- `shellcheck -x`（CI 同款：`git ls-files '*.sh' | xargs shellcheck -x`）：**PASS**（三个改动 .sh 零发现；测试 .bats 不在 CI lint 范围）
- `shfmt -d .`（本地 v3.13.1 = CI 固定版本）：**无漂移**
- `bash -n`：三个改动 .sh 全部通过
- `git diff --check`：PASS

## 自审发现

1. **heredoc 缩进陷阱**：初版编辑给 `gps_mesh_has_live_peer` 的 heredoc 内 Python 行加了前导 tab（`<<'PY'` 是引号 heredoc，前导空白是字面内容，会导致 Python `TabError`/缩进错乱）。自审时发现并重写为顶格（与既有 `gps_mesh_peers_endpoint_json` 的 heredoc 风格、brief 逐字代码一致）。
2. **函数体缩进风格**：初版函数体用了 2 tab，与仓库 1 tab 风格及 shfmt 不符，已修正；`shfmt -d .` 全仓库确认无漂移。
3. **测试 2 红阶段即通过**：`run gps_mesh_has_live_peer`（命令不存在）返回 127，断言 `-ne 0` 天然成立；测试 4（state 持久化）在红阶段也通过，因为当前 shell 已设了期望值、`load_state` 不会清掉未持久化的变量。二者属 brief 固有测试设计，按"逐字使用"保留；实现后所有用例仍全绿，语义正确。
4. **提交范围**：按 brief 精确命令只 add 4 个文件，`docs/superpowers/briefs/` 与 `.superpowers/` 保持未跟踪、未提交。

## 遇到的问题

- 无阻塞问题。heredoc 缩进问题在实现后、提交前通过自审 + `shfmt -d` 捕获并修复。
- 环境说明：bats / shellcheck / shfmt 均位于 `~/.local/bin`，shfmt 版本 v3.13.1 与 CI 固定版本一致。

---

# Task 1 审查修复：补强测试断言与 python3 检查

- 状态：**DONE**
- Commit：`ff149d80c8e16a416d8102b4dc0f0b14c8895d2a`（分支 `feat/mesh-failover`，仅含 `lib/mesh/wireguard.sh` 与 `tests/test_mesh_failover.bats` 两个文件）
- 日期：2026-08-25

## 修复内容（审查 4 项）

1. **测试 4 伪断言**（`tests/test_mesh_failover.bats`）：`state persists failover variables` 由「save_state → load_state → 断言 shell 变量」改为「save_state → 直接 `grep -Eq` 断言 `$GPS_STATE` 文件内容」。`load_state` 只叠加不清理，旧写法在 save_state 什么都没写时也会通过；新写法验证的是写入事实。state.env 为 `gps_env_assign`（`printf '%s=%q\n'`）生成，值无特殊字符时**不带引号**（实测 `MESH_FAILOVER=1`、`MESH_FAILOVER_PROBE=https://www.google.com/generate_204`），故 grep 模式同时兼容带引号/不带引号两种形式（`"?1"?`）。
2. **测试 3 只覆盖兜底分支**：新增用例 `has_live_peer honors fresh and stale last_seen`：`mesh_init` + `gps_mesh_peer_add`（peer_add 不写 last_seen，天然先走「无心跳字段视为可用」兜底）后，用 python3 直接改写 `$GPS_MESH_PEERS` 中该 peer 的 `last_seen`——先写当前 UTC 时间（`%Y-%m-%dT%H:%M:%SZ`，断言 `status -eq 0`），再写 200 秒前（超过 `MESH_PEER_STALE_SEC=180`，断言 `status -ne 0`）。strptime 解析、`<= stale` 窗口、过期判定均被真实覆盖（fresh 断言若 strptime 失败会先失败，非「测试测错方向」）。
3. **Minor** `lib/mesh/wireguard.sh`：`gps_mesh_has_live_peer` 在文件存在性检查后追加 `have_cmd python3 || return 1`（与兄弟函数 `gps_mesh_peers_endpoint_json` 的检查位置一致；此处用 `return 1` 而非 `err`，因为本函数是谓词式状态返回）。
4. **Minor**：`gps_mesh_has_live_peer` 的 python 内 `json.load(open(path, encoding="utf-8"))` 改为 `with open(path, "r", encoding="utf-8") as f: doc = json.load(f)`（不关闭句柄 → 显式 with 块），与同文件 `gps_mesh_peers_endpoint_json` 风格一致。

## 测试输出

**目标文件** `bats --tap tests/test_mesh_failover.bats`：**5/5 PASS**

```
1..5
ok 1 failover defaults are off with standard probe
ok 2 has_live_peer is false without peers
ok 3 has_live_peer is true with an online peer
ok 4 has_live_peer honors fresh and stale last_seen
ok 5 state persists failover variables
```

**回归** `bats --tap tests/test_mesh.bats`：**27/27 PASS**；全量 `bats --tap tests`：**127/127 PASS**（126 + 新增 1 例）。

**门禁**：`shellcheck -x lib/mesh/wireguard.sh` rc=0（无 error）；`shfmt -d lib/mesh/wireguard.sh tests/test_mesh_failover.bats` 与全仓库 `shfmt -d .` 均无漂移；`bash -n lib/mesh/wireguard.sh` 通过。

## 过程中发现与注意点

- **bats 不可并行跑共享 tmp 的测试文件**：`tests/_setup.bash` 与 `teardown` 都以 `rm -rf "$GPS_TEST_PREFIX"`（默认 `tests/tmp`）为界，两个 bats 文件并行时互相删对方正在用的 sing-box / config.json，导致串台报「sing-box 未安装 / config.json 不存在」。串行运行即恢复全绿。
- **grep -E 转义陷阱**：初版在 bats 文件里写了 `www\\.google`（JSON 转义后为字面 `\\.`），grep -E 将其解释为「字面反斜杠 + 任意字符」，与文件内容不匹配；按「宽松匹配」改为不转义点号（`.` 匹配任意字符，含自身）后通过。
- `gps_mesh_peer_add` 写入的节点**不含** `last_seen` 字段，旧测试 3 的兜底分支仍由原用例覆盖；新用例把三条判定路径（无字段 → 兜底可用、fresh → 可用、stale → 不可用）全部覆盖。
