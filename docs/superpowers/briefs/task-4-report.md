# Task 4 报告：`mesh show` 与 `doctor` 展示 failover 状态

- **分支**: `feat/mesh-failover`（HEAD 基线 `405e2d7`）
- **任务**: docs/superpowers/briefs/task-4.md（Task 0 全局约束见 docs/superpowers/briefs/task-0.md）
- **状态**: ✅ 完成（红→绿，门禁全过）

## 改动清单

| 文件 | 改动 |
|---|---|
| `lib/mesh/cli.sh` | `gps_mesh_cmd_show` 中 `msg "  mesh-exit:   ..."` 之后追加一行 failover 状态（见下方"与 brief 的差异"） |
| `lib/doctor.sh` | mesh master 检查块内、`gps_mesh_print_control_plane_status 2>/dev/null || true` **之前**（`check` 系列之后）追加 `msg "  $(_green OK)  mesh-failover=${MESH_FAILOVER:-0}（本机直连优先，故障自动切对端）"`（与 brief 逐字一致） |
| `tests/test_mesh_failover.bats` | 追加用例 `mesh show displays failover state`（brief 原样 + 一行 `save_state`，见下） |

## TDD 红→绿记录

### 红（Step 2：仅追加测试，未实现）

```
1..14
ok 1-13（既有 13 个用例全过）
not ok 14 mesh show displays failover state
#   `[[ "$output" == *"failover:"* ]]' failed
```

失败点：show 输出无 failover 行（实现未加）。

### 逐字实现后的中间结果（brief 实现行 + brief 测试）

按 brief 逐字实现 `msg "  failover:    ${MESH_FAILOVER:-0}  probe=..."` 后重跑：

```
not ok 14 mesh show displays failover state
#   `[[ "$output" == *"mesh-failover"* ]]' failed
```

断言 1（`failover:`）通过，断言 2（`mesh-failover`）仍失败——**brief 自身测试与实现不一致**（详见自审发现）。

### 绿（Step 4：修正后）

```
1..14
ok 1 … ok 14（14/14 全部 PASS）
```

## 与 brief 的差异（自审发现，两处均为让 brief 自带测试真正变绿的最小修正）

1. **`lib/mesh/cli.sh` 行前缀 `failover:` → `mesh-failover:`**

   brief 实现行：
   ```bash
   msg "  failover:    ${MESH_FAILOVER:-0}  probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}"
   ```
   实际采用：
   ```bash
   msg "  mesh-failover: ${MESH_FAILOVER:-0}  probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}"
   ```
   原因：brief 自带测试断言 `[[ "$output" == *"mesh-failover"* ]]`，而 brief 自己的实现行只含 `failover:` 字面串，**逐字组合必红**（已实证）。`mesh-failover:` 同时满足测试全部三条断言（`failover:` 是其子串、含 `mesh-failover`、含 probe），且仍符合 brief "Produces" 规格（`mesh show 输出含 failover: 0/1 probe=<url>`）。

2. **测试补一行 `save_state`（设置变量后、`run` 前）**

   brief 测试在 `MESH_FAILOVER=1` / `MESH_FAILOVER_PROBE=...` 之后直接 `run gps_mesh_cmd_show`。但 `gps_mesh_cmd_show` 内部先 `load_state`（无条件 source state.env，见 `gps_source_env`），会把 shell 变量覆盖回 `mesh_init` 时持久化的 `MESH_FAILOVER=0` / gstatic 默认探测地址——导致 probe 断言（google URL）必然失败。补 `save_state` 与本套件既有模式一致（`test_doctor.bats` 的 doctor 用例、`test_mesh.bats` 的 show 用例全部先 `save_state` 再运行）。

   未改测试任何断言，断言保持 brief 原样三条。

## 门禁验证

| 门禁 | 命令 | 结果 |
|---|---|---|
| 单文件测试 | `bats --tap tests/test_mesh_failover.bats` | 14/14 PASS |
| 全量测试 | `bats --tap tests` | 136/136 PASS |
| shellcheck | `git ls-files '*.sh' \| xargs shellcheck -x`（CI 同款） | 无 error |
| shfmt | `shfmt -d .`（v3.13.1，CI 固定版） | 无漂移（0 diff） |
| bash -n | `bash -n lib/mesh/cli.sh lib/doctor.sh` | 通过 |
| git diff --check | `git diff --check` | 通过 |

说明：`bash -n tests/test_mesh_failover.bats` 报 `@test` 语法错，经 `git show HEAD:` 验证为 bats 文件固有现象（HEAD 原文件同样报错），非本次改动引入；CI 亦只对 `*.sh` 做 shellcheck，bats 文件由 bats 运行时校验。

## 行为验证（额外）

- `mesh show`（MESH_FAILOVER=1、自定义 probe）输出行：`mesh-failover: 1  probe=https://www.google.com/generate_204`（测试 14 覆盖）
- `gps_doctor` 输出行：`  OK  mesh-failover=1（本机直连优先，故障自动切对端）`（实测确认渲染位置在 control_plane_status 之前）

## 提交

```bash
git add lib/mesh/cli.sh lib/doctor.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh show / doctor 展示 mesh-failover 状态"
```

按 brief 只提交上述三个文件；本报告与 `.superpowers/` / `docs/superpowers/briefs/` 保持未跟踪。
