### Task 3: CLI（`change mesh-failover` / `mesh-failover-probe` / mesh-exit 互斥）

**Files:**
- Modify: `lib/cmd.sh:521-536`（`mesh-exit` 分支加互斥）、`lib/cmd.sh`（新增两个 case 分支，置于 `mesh-exit` 之后）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1/2 的渲染与判定。
- Produces:
  - `gps_cmd_change mesh-failover on|off`：校验值合法；on 时校验 `MESH_EXIT_NODE_ID` 为空（冲突则 `err`）；设置 `MESH_FAILOVER`；`gps_write_config; save_state; gps_restart_svc`；输出 `mesh-failover → 1/0`。
  - `gps_cmd_change mesh-failover-probe <url>`：校验单行、`http(s)://` 开头；设置 `MESH_FAILOVER_PROBE`；同上保存。
  - `change mesh-exit <id>` 在 `MESH_FAILOVER=1` 且设置非 none 时 `err` 冲突。

- [ ] **Step 1: 追加失败测试**

```bash
@test "change mesh-failover on persists state and renders" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_cmd_change mesh-failover on
	grep -q '^MESH_FAILOVER="1"' "$GPS_STATE"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
}

@test "change mesh-failover off restores legacy rendering" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_cmd_change mesh-failover off
	grep -q '^MESH_FAILOVER="0"' "$GPS_STATE"
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
}

@test "change mesh-failover on conflicts with mesh-exit" {
	mesh_init
	MESH_EXIT_NODE_ID=tile-exit
	run gps_cmd_change mesh-failover on
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-exit conflicts with failover on" {
	mesh_init
	MESH_FAILOVER=1
	run gps_cmd_change mesh-exit tile-b
	[ "$status" -ne 0 ]
	[[ "$output" == *冲突* ]]
}

@test "change mesh-failover-probe validates url and persists" {
	mesh_init
	gps_cmd_change mesh-failover-probe https://www.google.com/generate_204
	grep -q '^MESH_FAILOVER_PROBE="https://www.google.com/generate_204"' "$GPS_STATE"
	run gps_cmd_change mesh-failover-probe ftp://bad
	[ "$status" -ne 0 ]
	run gps_cmd_change mesh-failover-probe "https://ok
evil"
	[ "$status" -ne 0 ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增 5 个用例 FAIL（`change` 未知参数报错）。

- [ ] **Step 3: 实现 CLI**

`lib/cmd.sh` 的 `mesh-exit` 分支内、`[[ $eid != "${NODE_ID:-}" ]] || err ...` 之后插入互斥校验：

```bash
			[[ ${MESH_FAILOVER:-0} != 1 ]] || err "与 mesh-failover 冲突：请先 change mesh-failover off 再设置 mesh-exit"
```

`mesh-exit` 分支之后新增两个 case 分支：

```bash
	mesh-failover | failover)
		local v=${1:-}
		[[ $v == on || $v == off || $v == 1 || $v == 0 ]] || err "用法: change mesh-failover on|off"
		if [[ $v == on || $v == 1 ]]; then
			[[ -z ${MESH_EXIT_NODE_ID:-} ]] || err "与 mesh-exit 冲突：请先 change mesh-exit none 再开启 mesh-failover"
			MESH_FAILOVER=1
			if ! gps_mesh_has_live_peer 2>/dev/null; then
				warn "当前无在线对端节点，failover 开启后暂无可兜底出口（新增节点后自动生效）"
			fi
		else
			MESH_FAILOVER=0
		fi
		gps_write_config
		save_state
		gps_restart_svc
		msg "$(_green "mesh-failover") → ${MESH_FAILOVER}"
		return 0
		;;
	mesh-failover-probe | failover-probe)
		local u=${1:-}
		[[ -n $u ]] || err "用法: change mesh-failover-probe <url>"
		gps_validate_single_line "$u" || err "探测地址不能包含换行/回车/NUL"
		[[ $u == http://* || $u == https://* ]] || err "探测地址需以 http:// 或 https:// 开头"
		MESH_FAILOVER_PROBE=$u
		gps_write_config
		save_state
		gps_restart_svc
		msg "$(_green "failover 探测地址") → ${MESH_FAILOVER_PROBE}"
		return 0
		;;
```

同时在 `change` 的兜底用法行（`*) err "用法: change port|uuid|...`）中追加 `mesh-failover|mesh-failover-probe`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 12 个用例全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/cmd.sh tests/test_mesh_failover.bats
git commit -m "feat: change mesh-failover / mesh-failover-probe CLI 与 mesh-exit 互斥"
```

---

