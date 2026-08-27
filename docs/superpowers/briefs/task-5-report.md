# Task 5 报告：版本、文档与全量门禁（发布 v0.2.41）

- 状态：完成 ✅
- 分支：`feat/mesh-failover`（HEAD 提交见下）
- 日期：2026-08-25

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `VERSION` | `v0.2.40` → `v0.2.41`（patch+1，遵守 `AGENTS.md`） |
| `CHANGELOG.md` | 顶部追加 `## v0.2.41 - 2026-08-25`，含功能摘要行 + 4 条要点（loadbalance 探测组、防环置顶、probe 可配 + 与 mesh-exit 互斥、`mesh show`/`doctor` 展示 + 无对端降级），风格对齐 v0.2.38-40 的「摘要行 + 列表」惯例 |
| `README.md` | ① 特点区 Mesh 行补充 `change mesh-failover`；② Mesh 组网章节代码块补充 `change mesh-failover on|off` / `change mesh-failover-probe <url>` 用法，并说明「本机直连优先 + 对端兜底」、与 mesh-exit 互斥、每台机器仍只跑一个 sing-box 实例 |
| `tests/test_mesh_failover.bats` | 扩展现有用例「failover on renders loadbalance group, final and anti-loop order」：新增 python3 结构化断言（loadbalance 组内层字段） |

未修改 spec/plan/brief 文档；仅上述 4 个文件进入本次提交。

## 测试补强说明（Minor backlog）

在既有用例内扩展（未新增用例号），新增断言：

- 恰好存在一个 `tag=mesh-failover` 的 outbound
- `type=loadbalance`、`strategy=url-test`
- `destinations` 顺序为 `["direct", "wg-ep"]`
- `url` == 默认探测地址 `https://www.gstatic.com/generate_204`
- `interval` == `"30s"`、`tolerance` == 0
- `route.final` == `"mesh-failover"`，且 `route.rules[0]` 为 `source_ip_cidr` 防环规则（置顶）

## 全量门禁输出摘要

| 门禁 | 命令 | 结果 |
|------|------|------|
| 语法 | `bash -n geoproxy-server.sh lib/*.sh lib/*/*.sh scripts/*.py`（fallback 分支未触发） | ✅ exit 0 |
| 单文件测试 | `bats --tap tests/test_mesh_failover.bats` | ✅ 14/14 |
| 全量测试 | `bats --tap tests` | ✅ **136/136** |
| 静态检查 | `shellcheck geoproxy-server.sh lib/*.sh lib/mesh/*.sh lib/protocols/*.sh` | ✅ 无 error |
| 格式 | `shfmt -d geoproxy-server.sh lib tests scripts` | ✅ 无 diff |
| 空白 | `git diff --check` | ✅ 无 whitespace 错误 |

测试总数：**136**（Task 5 为增强既有用例，未新增用例，总数保持 136；此前 Task 1-4 基线即 136）。

## 提交

- 提交信息：`release: v0.2.41 mesh-failover（本机直连优先 + 故障自动切换对端出口）`
- 仅 add：`VERSION`、`CHANGELOG.md`、`README.md`、`tests/test_mesh_failover.bats`
- 未推送、未打 tag、未 merge（Step 5 由控制器在合并分支后执行）
