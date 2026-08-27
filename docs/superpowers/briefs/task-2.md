### Task 2: sing-box 配置渲染（loadbalance 组 + 防环规则）

**Files:**
- Modify: `lib/mesh/wireguard.sh:146-186`（`gps_mesh_route_json` 与 `gps_mesh_outbounds_json`）
- Test: `tests/test_mesh_failover.bats`（追加用例）

**Interfaces:**
- Consumes: Task 1 的 `MESH_FAILOVER` / `MESH_FAILOVER_PROBE` / `gps_mesh_has_live_peer`。
- Produces: 渲染行为——
  - `MESH_FAILOVER=1` 且有在线 peer：outbounds 含 `{"type":"loadbalance","tag":"mesh-failover","strategy":"url-test",...}`（destinations = direct + wg-ep）；`route.final` = `mesh-failover`。
  - 否则：与现状一致（final = `direct`，无 loadbalance 组）。
  - `route.rules` 恒为：`[{source_ip_cidr: [prefix] → direct}, {ip_cidr: [prefix] → wg-ep}]`（source 规则在前）。

- [ ] **Step 1: 追加失败测试**（追加到 `tests/test_mesh_failover.bats`）

```bash
@test "failover off renders legacy outbounds and route with anti-loop rule" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	gps_write_config
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	grep -q '"final": "direct"' "$GPS_CONFIG"
	grep -q 'source_ip_cidr' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "failover on renders loadbalance group, final and anti-loop order" {
	mesh_init
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820
	MESH_FAILOVER=1
	gps_write_config
	grep -q '"tag": "mesh-failover"' "$GPS_CONFIG"
	grep -q '"strategy": "url-test"' "$GPS_CONFIG"
	grep -q '"final": "mesh-failover"' "$GPS_CONFIG"
	local src_line ip_line
	src_line=$(grep -n 'source_ip_cidr' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	ip_line=$(grep -n '"ip_cidr"' "$GPS_CONFIG" | head -1 | cut -d: -f1)
	[ "$src_line" -lt "$ip_line" ]
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}

@test "failover on without peers keeps direct-only final" {
	mesh_init
	MESH_FAILOVER=1
	gps_write_config
	run grep -q 'mesh-failover' "$GPS_CONFIG"
	[ "$status" -ne 0 ]
	grep -q '"final": "direct"' "$GPS_CONFIG"
	run python3 -m json.tool "$GPS_CONFIG"
	[ "$status" -eq 0 ]
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 新增 3 个用例 FAIL（配置中无 loadbalance 组、无 source_ip_cidr、final 仍 direct）。

- [ ] **Step 3: 实现渲染**

替换 `lib/mesh/wireguard.sh` 中 `gps_mesh_outbounds_json` 与 `gps_mesh_route_json` 整个函数体：

```bash
gps_mesh_route_json() {
	gps_profile_normalize
	gps_mesh_defaults
	local prefix final_tag
	prefix=$(gps_json_escape "${MESH_OVERLAY_PREFIX}")
	final_tag=direct
	# mesh-failover：有在线对端时才把 final 指到探测组
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		final_tag=mesh-failover
	fi
	cat <<EOF
  "route": {
    "rules": [
      {
        "source_ip_cidr": ["${prefix}"],
        "outbound": "direct"
      },
      {
        "ip_cidr": ["${prefix}"],
        "outbound": "wg-ep"
      }
    ],
    "final": "${final_tag}"
  }
EOF
}

gps_mesh_outbounds_json() {
	# 始终至少有 direct；L7 hop 占位（MESH_L7_DETOUR_JSON 高级用户/后续）
	local extra=${MESH_L7_OUTBOUNDS_JSON:-}
	# mesh-failover：direct 之后插入 loadbalance 探测组（本机直连 ↔ WG 隧道）
	local failover=""
	if [[ ${MESH_FAILOVER:-0} == 1 ]] && gps_mesh_has_live_peer; then
		local probe=${MESH_FAILOVER_PROBE:-https://www.gstatic.com/generate_204}
		failover=$(cat <<EOF
,
    {
      "type": "loadbalance",
      "tag": "mesh-failover",
      "strategy": "url-test",
      "destinations": [
        { "outbound": "direct" },
        { "outbound": "wg-ep" }
      ],
      "url": "${probe}",
      "interval": "30s",
      "tolerance": 0
    }
EOF
)
	fi
	if [[ -n ${extra//[[:space:]]/} ]]; then
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover},
${extra}
EOF
	else
		cat <<EOF
    {
      "type": "direct",
      "tag": "direct"
    }${failover}
EOF
	fi
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bats --tap tests/test_mesh_failover.bats`
Expected: 7 个用例全部 PASS。

- [ ] **Step 5: 回归既有 mesh 测试**

Run: `bats --tap tests/test_mesh.bats tests/test_mesh_tls.bats`
Expected: 全部 PASS（渲染变化不应破坏现有用例；若有断言 `"final": "direct"` 或规则结构的用例失败，检查是否与新增 source 规则顺序相关并修正渲染而非削弱断言）。

- [ ] **Step 6: 提交**

```bash
git add lib/mesh/wireguard.sh tests/test_mesh_failover.bats
git commit -m "feat: mesh-failover sing-box 渲染（loadbalance 探测组 + source 防环规则）"
```

---

