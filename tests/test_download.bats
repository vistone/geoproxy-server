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
