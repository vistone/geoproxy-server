#!/usr/bin/env bats

setup() {
	source "$BATS_TEST_DIRNAME/_setup.bash"
	# shellcheck source=../lib/download.sh
	source "$REPO_ROOT/lib/download.sh"
}

@test "core install keeps previous binary for rollback" {
	mkdir -p "$GPS_LIB_DIR"
	printf '#!/bin/bash\n# old-core\n' >"$BATS_TEST_TMPDIR/old-bin"
	printf '#!/bin/bash\n# new-core\n' >"$BATS_TEST_TMPDIR/new-bin"
	chmod +x "$BATS_TEST_TMPDIR/old-bin" "$BATS_TEST_TMPDIR/new-bin"
	install -m 755 "$BATS_TEST_TMPDIR/old-bin" "$GPS_CORE_BIN"
	gps_install_core_from "$BATS_TEST_TMPDIR/new-bin"
	[ -x "$GPS_CORE_BIN" ]
	grep -q 'new-core' "$GPS_CORE_BIN"
	[ -x "${GPS_CORE_BIN}.prev" ]
	grep -q 'old-core' "${GPS_CORE_BIN}.prev"
}

@test "core rollback restores previous binary and consumes it" {
	mkdir -p "$GPS_LIB_DIR"
	printf '#!/bin/bash\n# old-core\n' >"${GPS_CORE_BIN}.prev"
	printf '#!/bin/bash\n# new-core\n' >"$GPS_CORE_BIN"
	chmod +x "$GPS_CORE_BIN" "${GPS_CORE_BIN}.prev"
	gps_rollback_core
	grep -q 'old-core' "$GPS_CORE_BIN"
	[ ! -e "${GPS_CORE_BIN}.prev" ]
	# prev 已消耗：再次回滚应失败
	! gps_rollback_core
}

@test "first-ever core install leaves no prev" {
	mkdir -p "$GPS_LIB_DIR"
	rm -f "$GPS_CORE_BIN" "${GPS_CORE_BIN}.prev"
	printf '#!/bin/bash\n# first\n' >"$BATS_TEST_TMPDIR/first-bin"
	chmod +x "$BATS_TEST_TMPDIR/first-bin"
	gps_install_core_from "$BATS_TEST_TMPDIR/first-bin"
	[ -x "$GPS_CORE_BIN" ]
	[ ! -e "${GPS_CORE_BIN}.prev" ]
}

@test "archive verification rejects checksum mismatch" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	printf '%064d  sing-box-test-linux-amd64.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

@test "archive verification accepts exact checksum" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	sum=$(sha256sum "$BATS_TEST_TMPDIR/sb.tar.gz" | awk '{print $1}')
	printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum" >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -eq 0 ]
}

@test "archive verification rejects missing manifest entry" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	printf '%064d  other-asset.tar.gz\n' 0 >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

@test "archive verification rejects duplicate manifest entries" {
	printf archive-bytes >"$BATS_TEST_TMPDIR/sb.tar.gz"
	sum=$(sha256sum "$BATS_TEST_TMPDIR/sb.tar.gz" | awk '{print $1}')
	{
		printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum"
		printf '%s  sing-box-test-linux-amd64.tar.gz\n' "$sum"
	} >"$BATS_TEST_TMPDIR/sha256sums.txt"
	run gps_verify_core_archive "$BATS_TEST_TMPDIR/sb.tar.gz" "$BATS_TEST_TMPDIR/sha256sums.txt" sing-box-test-linux-amd64.tar.gz
	[ "$status" -ne 0 ]
}

@test "self tree version check accepts matching VERSION" {
	mkdir -p "$BATS_TEST_TMPDIR/tree-ok"
	printf 'v9.9.9\n' >"$BATS_TEST_TMPDIR/tree-ok/VERSION"
	gps_verify_tree_version "$BATS_TEST_TMPDIR/tree-ok" v9.9.9
}

@test "self tree version check rejects mismatched and missing VERSION" {
	mkdir -p "$BATS_TEST_TMPDIR/tree-bad"
	printf 'v1.2.3\n' >"$BATS_TEST_TMPDIR/tree-bad/VERSION"
	run gps_verify_tree_version "$BATS_TEST_TMPDIR/tree-bad" v9.9.9
	[ "$status" -ne 0 ]
	mkdir -p "$BATS_TEST_TMPDIR/tree-nov"
	run gps_verify_tree_version "$BATS_TEST_TMPDIR/tree-nov" v9.9.9
	[ "$status" -ne 0 ]
}

@test "release asset verification compares against repo digest" {
	printf asset-bytes >"$BATS_TEST_TMPDIR/src.tar.gz"
	# mock 仓库 digest 查询（不打网络）
	gps_repo_asset_digest() { printf '%064d' 0; }
	run gps_verify_release_asset "$BATS_TEST_TMPDIR/src.tar.gz" v9.9.9 geoproxy-server-v9.9.9.tar.gz
	[ "$status" -ne 0 ]
	gps_repo_asset_digest() { sha256sum "$BATS_TEST_TMPDIR/src.tar.gz" | awk '{print $1}'; }
	run gps_verify_release_asset "$BATS_TEST_TMPDIR/src.tar.gz" v9.9.9 geoproxy-server-v9.9.9.tar.gz
	[ "$status" -eq 0 ]
}
