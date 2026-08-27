### Task 5: 版本、文档与全量门禁（发布 v0.2.41）

**Files:**
- Modify: `VERSION`（`v0.2.40` → `v0.2.41`）
- Modify: `CHANGELOG.md`（顶部追加 `## v0.2.41 - 2026-08-25`）
- Modify: `README.md`（mesh 能力 + `change mesh-failover` 用法；版本号引用不写死，按现有惯例）

**Interfaces:** 无新接口，纯发布收尾。

- [ ] **Step 1: 更新版本文件**

`VERSION` 内容改为 `v0.2.41`。

- [ ] **Step 2: 更新 CHANGELOG**

`CHANGELOG.md` 顶部插入（按既有条目风格）：

```markdown
## v0.2.41 - 2026-08-25

- 新增 mesh 出口自动故障切换（`change mesh-failover on|off`）：本机直连优先，本机出口故障时自动切到对端出口兜底，恢复后自动回切；平时零隧道流量开销。
- 防环：来自 WG 隧道（overlay 网段）的流量强制走本机直连，杜绝 A↔B 兜底/探活循环。
- 探测地址可配（`change mesh-failover-probe <url>`，默认 `https://www.gstatic.com/generate_204`）；与 `mesh-exit` 互斥。
- `mesh show` / `doctor` 展示 failover 状态。
```

- [ ] **Step 3: 更新 README**

在 README mesh 相关章节补充 `change mesh-failover on|off` 与 `change mesh-failover-probe <url>` 用法（保留"每台机器只跑一个 sing-box 实例"的产品模型，说明出口在开启后为"本机直连优先 + 对端兜底"）。

- [ ] **Step 4: 全量门禁**

Run:
```bash
bash -n geoproxy-server.sh lib/*.sh lib/*/*.sh scripts/*.py 2>/dev/null || bash -n geoproxy-server.sh lib/*.sh lib/mesh/*.sh lib/protocols/*.sh
bats --tap tests
shellcheck geoproxy-server.sh lib/*.sh lib/mesh/*.sh lib/protocols/*.sh
shfmt -d geoproxy-server.sh lib tests scripts
git diff --check
```
Expected: 全部通过（bats 全绿；shellcheck 无 error；shfmt 无 diff 输出；`git diff --check` 无 whitespace 错误）。若有 shfmt/shellcheck 报错，就地修正并重跑。

- [ ] **Step 5: 提交并推送，打 tag**

```bash
git add -A
git commit -m "release: v0.2.41 mesh-failover（本机直连优先 + 故障自动切换对端出口）"
git push origin main
git tag v0.2.41
git push origin v0.2.41
```
Expected: push 成功；GitHub Actions `release.yml` 自动校验 `VERSION == tag` 并创建 Release（含 `geoproxy-server-v0.2.41.tar.gz` 与 `.sha256`）。

---

## Self-Review

**Spec 覆盖核对：**
- 行为（本机直连优先/故障切换/回切/单机降级）→ Task 2 渲染 + url-test 语义 ✅
- 配置接口（`change mesh-failover on|off`、`mesh-failover-probe`、`mesh show`、`doctor`）→ Task 3 + Task 4 ✅
- 默认关闭、与 mesh-exit 互斥 → Task 1 默认值 + Task 3 双向校验 ✅
- 防环 `source_ip_cidr` 置顶 → Task 2 ✅（且恒渲染，比 spec 更稳）
- 无在线 peer 降级 → Task 2 测试 ✅
- 探测地址校验 → Task 3 ✅
- 测试（6 组 spec 用例 → 计划拆为 13 个 bats 用例）✅
- 版本 v0.2.41 / CHANGELOG / README / 门禁 / 推送 tag → Task 5 ✅
- YAGNI 排除项（活跃均衡/配额驱动/按目标分流/clash_api）→ 计划未引入 ✅

**占位符扫描：** 无 TBD/TODO；所有代码步骤含完整实现。✅

**类型/命名一致性：** `MESH_FAILOVER`、`MESH_FAILOVER_PROBE`、`gps_mesh_has_live_peer`、`mesh-failover`（tag 与命令）在各任务间一致。✅

**风险说明（执行时注意）：**
- Task 2 Step 5 若 `test_mesh.bats` 中既有断言与新增 source 规则顺序冲突，优先调整渲染顺序保证防环语义，再确认既有断言仍成立。
- Task 3 的 `change mesh-failover on` 会执行 `gps_restart_svc`（测试中已 mock 为空）。
