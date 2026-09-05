#!/usr/bin/env bats
# 服务稳定性：升级失败零影响、集群跟版失败冷却、mesh-sync 重启节流

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/cmd.sh
	source "$REPO_ROOT/lib/cmd.sh"
	# shellcheck source=../lib/download.sh
	source "$REPO_ROOT/lib/download.sh"
	# shellcheck source=../lib/systemd.sh
	source "$REPO_ROOT/lib/systemd.sh" 2>/dev/null || true
	gps_restart_svc() { :; }
}

stable_init() {
	export PORT=${PORT:-43951}
	export UUID="00000000-0000-4000-8000-000000000401"
	export PASSWORD="stab-pass"
	export PROTOCOL=tuic
	export PUBLIC_IP="203.0.113.7"
	export MESH_ROLE=member
	export MESH_CLUSTER_AUTO_UPGRADE=1
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	mkdir -p "${GPS_LIB_DIR}/scripts"
	printf 'v0.2.60\n' >"${GPS_LIB_DIR}/scripts/VERSION"
	gps_mesh_ensure_dirs
}

@test "upgrade self fetch failure never halts the service" {
	stable_init
	save_state
	local halted=0
	gps_svc_halt() { halted=1; }
	gps_self_fetch_tree() { return 1; }
	run gps_cmd_upgrade_self --ver v9.9.9
	[ "$status" -ne 0 ]
	[[ "$output" == *"服务未受影响"* ]]
	[ "$halted" -eq 0 ]
}

@test "cluster schedule skips while failure cooldown is fresh" {
	stable_init
	printf 'FAILED_AT=%s\n' "$(date +%s)" >"${GPS_MESH_DIR}/upgrade-cooldown"
	gps_mesh_cluster_schedule_upgrade v0.2.65
	[[ ! -f ${GPS_MESH_UPGRADE_PENDING} ]]
}

@test "cluster schedule resumes after cooldown expires and clears it on success" {
	stable_init
	printf 'FAILED_AT=%s\n' "$(($(date +%s) - 700))" >"${GPS_MESH_DIR}/upgrade-cooldown"
	gps_cmd_upgrade_self() { echo ok >>"${GPS_TEST_PREFIX}/upgraded.log"; }
	gps_mesh_cluster_schedule_upgrade v0.2.65
	[[ -f ${GPS_TEST_PREFIX}/upgraded.log ]]
	[[ ! -f ${GPS_MESH_UPGRADE_PENDING} ]]
	[[ ! -f ${GPS_MESH_DIR}/upgrade-cooldown ]]
}

@test "upgrade cluster failure writes cooldown and keeps pending" {
	stable_init
	printf 'v0.2.65\n' >"${GPS_MESH_UPGRADE_PENDING}"
	gps_cmd_upgrade_self() { return 1; }
	run gps_mesh_cmd_upgrade_cluster
	[ "$status" -ne 0 ]
	[[ "$output" == *"冷却"* ]]
	[[ -f ${GPS_MESH_DIR}/upgrade-cooldown ]]
	grep -q '^FAILED_AT=[0-9]*$' "${GPS_MESH_DIR}/upgrade-cooldown"
	[[ -f ${GPS_MESH_UPGRADE_PENDING} ]]
}

@test "sync restart throttled inside minimum interval" {
	export MESH_ROLE=master
	detect_local_stack() {
		STACK_MODE=v4only
		HAS_V4=1
		HAS_V6=0
	}
	gps_mesh_cmd_init --node-id tile-a --overlay-ip 10.66.0.1 >/dev/null
	local rslog="${GPS_TEST_PREFIX}/rs.log"
	rm -f "$rslog"
	gps_restart_svc() { echo x >>"$rslog"; }
	# 服务视为在跑
	gps_svc() { return 0; }
	# 首次：无 config → ensure 写出 → 变更；last-sync-restart 刚写 → 节流
	mkdir -p "$GPS_MESH_DIR"
	rm -f "$GPS_CONFIG" "${GPS_MESH_DIR}/last-sync-restart"
	date +%s >"${GPS_MESH_DIR}/last-sync-restart"
	local out
	out=$(gps_mesh_sync_master 2>&1) || true
	[[ "$out" == *"本轮跳过重启"* ]]
	[[ ! -f $rslog ]]
	# 冷却窗外：再来一次变更（config 与 peers 不一致 → ensure 重写）→ 允许重启
	printf '0\n' >"${GPS_MESH_DIR}/last-sync-restart"
	gps_mesh_peer_add tile-b --pubkey "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=" --overlay-ip 10.66.0.2 --endpoint 203.0.113.12:51820 >/dev/null
	gps_write_config 2>/dev/null || true
	gps_mesh_peer_rm tile-b >/dev/null 2>&1 || true
	out=$(gps_mesh_sync_master 2>&1) || true
	[[ -f $rslog ]]
	[ "$(wc -l <"$rslog" | tr -d '[:space:]')" -eq 1 ]
	[[ "$out" == *"重启 ${GPS_SERVICE}"* ]]
}
