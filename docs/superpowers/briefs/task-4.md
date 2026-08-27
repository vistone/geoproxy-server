### Task 4: `mesh show` 与 `doctor` 展示 failover 状态

**Files:**
- Modify: `lib/mesh/cli.sh:180`（`gps_mesh_cmd_show` 输出加一行）
- Modify: `lib/doctor.sh:137-152`（mesh master 检查块加一行）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `MESH_FAILOVER` / `MESH_FAILOVER_PROBE`。
- Produces: `mesh show` 输出含 `failover:  0/1  probe=<url>`；`doctor` 输出含 `mesh-failover: on/off`。

- [ ] **Step 1: 追加失败测试**

```bash
@test "mesh show displays failover state" {
	mesh_init
	MESH_FAILOVER=1
	MESH_FAILOVER_PROBE="https://www.google.com/generate_204"
	run gps_mesh_cmd_show
	[ "$status" -eq 0 ]
	[[ "$output" == *"failover:"* ]]
	[[ "$output" == *"mesh-failover"* ]]
	[[ "$output" == *"https://www.google.com/generate_204"* ]]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增用例 FAIL（输出无 failover 行）。

- [ ] **Step 3: 实现展示**

`lib/mesh/cli.sh` 中 `msg "  mesh-exit:   ${MESH_EXIT_NODE_ID:-none}"` 之后追加：

```bash
	msg "  failover:    ${MESH_FAILOVER:-0}  probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}"
```

`lib/doctor.sh` 的 mesh 检查块中 `gps_mesh_print_control_plane_status 2>/dev/null || true` 之前追加：

```bash
		msg "  $(_green OK)  mesh-failover=${MESH_FAILOVER:-0}（本机直连优先，故障自动切对端）"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 13 个用例全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/mesh/cli.sh lib/doctor.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh show / doctor 展示 mesh-failover 状态"
```

---

